package miu

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"sync"
	"time"

	"github.com/metacubex/mihomo/transport/anytls/padding"
	"github.com/metacubex/mihomo/transport/anytls/util"
	"github.com/metacubex/mihomo/transport/vless/vision"

	M "github.com/metacubex/sing/common/metadata"
)

// Vision: one connection, one stream. After SYNACK both ends drop the Miu framing
// and hand the connection over to XTLS-Vision, inner TLS 1.3 traffic then leaves
// the outer TLS and the server can splice it. Only the handshake is done here,
// the switching itself is the stock Vision implementation.

const (
	visionStreamID = 1

	// how long to wait for ServerSettings, and for a spare connection to come up
	visionHandshakeTimeout = 10 * time.Second

	// Prewarming: keep a few connections around that finished the outer handshake
	// and sent the auth header and Settings, a new stream just sends SYNVision on
	// one of them instead of waiting for a handshake.
	visionSpareMax = 2
	// a spare connection nobody used for this long is closed
	visionSpareTTL = 20 * time.Second
	// spares are only topped up when two Vision streams came within this long:
	// the odd background connection is not worth two more handshakes
	visionBurstWindow = 10 * time.Second
)

// With Vision enabled only TCP to this port uses it: the inner traffic is TLS almost
// for sure, so there is something to hand over. The other ports stay in the MUX
// session instead of paying an outer handshake for a stream that cannot go direct.
// (A variable only for the tests.)
var visionPort uint16 = 443

var errVisionRefused = errors.New("miu: server did not grant Vision")

type visionSpare struct {
	conn  net.Conn
	timer *time.Timer
}

// visionSpares holds the prewarmed Vision connections.
type visionSpares struct {
	mu       sync.Mutex
	ready    []*visionSpare
	pending  int
	lastDial time.Time
	closed   bool
}

// take returns the newest spare connection, nil when there is none.
func (p *visionSpares) take() net.Conn {
	p.mu.Lock()
	defer p.mu.Unlock()
	n := len(p.ready)
	if n == 0 {
		return nil
	}
	sp := p.ready[n-1]
	p.ready = p.ready[:n-1]
	sp.timer.Stop()
	return sp.conn
}

// demand records a Vision dial and returns how many spares to dial now, they
// are already counted as pending.
func (p *visionSpares) demand(now time.Time) int {
	p.mu.Lock()
	defer p.mu.Unlock()
	burst := !p.lastDial.IsZero() && now.Sub(p.lastDial) <= visionBurstWindow
	p.lastDial = now
	if !burst {
		return 0
	}
	n := visionSpareMax - len(p.ready) - p.pending
	if n <= 0 {
		return 0
	}
	p.pending += n
	return n
}

// settle hands in the result of one prewarm dial, conn is nil when it failed.
func (p *visionSpares) settle(conn net.Conn) {
	p.mu.Lock()
	p.pending--
	if conn == nil {
		p.mu.Unlock()
		return
	}
	if p.closed {
		p.mu.Unlock()
		conn.Close()
		return
	}
	sp := &visionSpare{conn: conn}
	sp.timer = time.AfterFunc(visionSpareTTL, func() { p.expire(sp) })
	p.ready = append(p.ready, sp)
	p.mu.Unlock()
}

func (p *visionSpares) expire(sp *visionSpare) {
	p.mu.Lock()
	for i, s := range p.ready {
		if s == sp {
			p.ready = append(p.ready[:i], p.ready[i+1:]...)
			p.mu.Unlock()
			sp.conn.Close()
			return
		}
	}
	p.mu.Unlock()
}

// close drops the spare connections, the ones still being dialed are closed as
// they come in.
func (p *visionSpares) close() {
	p.mu.Lock()
	ready := p.ready
	p.ready = nil
	p.closed = true
	p.mu.Unlock()
	for _, sp := range ready {
		sp.timer.Stop()
		sp.conn.Close()
	}
}

func readFrame(conn net.Conn) (cmd byte, sid uint32, data []byte, err error) {
	var hdr rawHeader
	if _, err = io.ReadFull(conn, hdr[:]); err != nil {
		return
	}
	if n := hdr.Length(); n > 0 {
		data = make([]byte, n)
		if _, err = io.ReadFull(conn, data); err != nil {
			return
		}
	}
	return hdr.Cmd(), hdr.StreamID(), data, nil
}

// awaitServerSettings reads up to ServerSettings: does the server speak miu and
// does it grant Vision.
func (c *Client) awaitServerSettings(conn net.Conn) (bool, error) {
	for {
		cmd, _, data, err := readFrame(conn)
		if err != nil {
			return false, fmt.Errorf("miu: read ServerSettings: %w", err)
		}
		switch cmd {
		case cmdServerSettings:
			m := util.StringMapFromBytes(data)
			return m["miu"] == "1" && m["vision"] == "1", nil
		case cmdUpdatePaddingScheme:
			padding.UpdatePaddingScheme(data, &c.padding)
		case cmdAlert:
			return false, fmt.Errorf("miu: alert from server: %s", string(data))
		}
	}
}

// awaitSynAck reads up to the SYNACK of the Vision stream.
func awaitSynAck(conn net.Conn) error {
	for {
		cmd, sid, data, err := readFrame(conn)
		if err != nil {
			return fmt.Errorf("miu: read SYNACK: %w", err)
		}
		switch cmd {
		case cmdSYNACK:
			if sid != visionStreamID {
				continue
			}
			if len(data) > 0 {
				return fmt.Errorf("remote: %s", string(data))
			}
			return nil
		case cmdAlert:
			return fmt.Errorf("miu: alert from server: %s", string(data))
		}
	}
}

// visionConn is the outer TLS connection as vision.Conn sees it. The client does
// not wait for the reply of the server before sending, so the frames in front of
// the Vision stream (ServerSettings unless already read, SYNACK) are still on the
// way back: handshake takes them off before the first read.
type visionConn struct {
	net.Conn
	handshake     func() error
	handshakeOnce sync.Once
	handshakeErr  error
}

func (c *visionConn) Read(b []byte) (int, error) {
	c.handshakeOnce.Do(func() {
		c.handshakeErr = c.handshake()
	})
	if c.handshakeErr != nil {
		return 0, c.handshakeErr
	}
	return c.Conn.Read(b)
}

// dialVisionConn dials a connection and writes in one go: the auth header,
// Settings and extra (the frames opening the stream, may be empty).
func (c *Client) dialVisionConn(ctx context.Context, extra []byte) (net.Conn, error) {
	conn, err := c.connect(ctx)
	if err != nil {
		return nil, err
	}
	f := newFrame(cmdSettings, 0)
	f.data = clientSettings(c.clientMetadata, c.padding.Load().Md5, c.recvWindow)
	if _, err = conn.Write(append(f.appendTo(c.authHeader()), extra...)); err != nil {
		conn.Close()
		return nil, err
	}
	return conn, nil
}

// prewarmVision is called once a Vision stream is on its way: spares are only
// dialed when the streams come in a burst.
func (c *Client) prewarmVision() {
	n := c.spares.demand(time.Now())
	for i := 0; i < n; i++ {
		go func() {
			// a spare outlives the request that triggered it, so it is not dialed
			// with the context of that request
			ctx, cancel := context.WithTimeout(c.pool.die, visionHandshakeTimeout)
			defer cancel()
			conn, err := c.dialVisionConn(ctx, nil)
			if err != nil {
				conn = nil
			}
			c.spares.settle(conn)
		}()
	}
}

// dialVision opens a Vision connection to destination. errVisionRefused means the
// server does not grant Vision and nothing of this stream went out yet, the caller
// then uses a MUX stream.
//
// Once the server granted Vision (visionConfirmed) its reply is not waited for any
// more: the frames opening the stream go out on a spare connection or along with
// the auth header, upstream data follows right away, and ServerSettings / SYNACK
// are taken off the way back before the first read. A server not confirmed yet costs
// one round trip for ServerSettings first: without Vision it takes SYNVision for a
// plain SYN and parses the Vision bytes behind it as frames, so nothing may be sent
// blindly.
func (c *Client) dialVision(ctx context.Context, destination M.Socksaddr) (net.Conn, error) {
	addr, err := destinationBytes(destination)
	if err != nil {
		return nil, err
	}
	psh := newFrame(cmdPSH, visionStreamID)
	psh.data = addr
	open := psh.appendTo(newFrame(cmdSYNVision, visionStreamID).appendTo(nil))

	confirmed := c.visionConfirmed.Load()
	var conn net.Conn
	needSettings := true
	if confirmed {
		if spare := c.spares.take(); spare != nil {
			if _, err = spare.Write(open); err == nil {
				conn = spare
			} else {
				spare.Close()
			}
		}
	}
	if conn == nil {
		var extra []byte
		if confirmed {
			extra = open
		}
		if conn, err = c.dialVisionConn(ctx, extra); err != nil {
			return nil, err
		}
		if !confirmed {
			deadline := time.Now().Add(visionHandshakeTimeout)
			if d, ok := ctx.Deadline(); ok && d.Before(deadline) {
				deadline = d
			}
			_ = conn.SetDeadline(deadline)
			granted, err := c.awaitServerSettings(conn)
			if err != nil {
				conn.Close()
				return nil, err
			}
			if !granted {
				conn.Close()
				c.refuseVision()
				return nil, errVisionRefused
			}
			c.visionConfirmed.Store(true)
			needSettings = false
			if _, err = conn.Write(open); err != nil {
				conn.Close()
				return nil, err
			}
			_ = conn.SetDeadline(time.Time{})
		}
	}

	vc, err := vision.NewConn(&visionConn{
		Conn: conn,
		handshake: func() error {
			if needSettings {
				granted, err := c.awaitServerSettings(conn)
				if err != nil {
					return err
				}
				if !granted {
					// the server turned Vision off in the meantime: what this stream
					// already sent is lost, the next ones use MUX
					c.refuseVision()
					return errors.New("miu: server no longer grants Vision")
				}
			}
			return awaitSynAck(conn)
		},
	}, conn, c.visionSeed)
	if err != nil {
		conn.Close()
		return nil, err
	}
	c.prewarmVision()
	return vc, nil
}
