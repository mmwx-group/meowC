package miu

import (
	"context"
	"errors"
	"io"
	"net"
	"sync"
	"sync/atomic"
	"time"

	"github.com/metacubex/mihomo/common/pool"
)

const (
	// A new stream waits this long for the first bytes of the app, they then
	// leave in one packet with OPEN. Without any, OPEN goes out alone: a protocol
	// where the server speaks first must not wait for this end.
	firstPayloadWait = 10 * time.Millisecond
	// On a lane from the pool a stream keeps what it sent until the server
	// answers, up to this much. Should the lane turn out to be dead, all of it
	// is sent again on a new one.
	replayLimit = 64 << 10
	// data taken into one packet
	maxPacket = 4 * maxData
	// how long an aborted stream waits for the END of the server before it gives
	// the lane up
	abortDrain = 3 * time.Second
	// how long Close gives the connection to take the one frame it writes
	closeGrace = 100 * time.Millisecond
)

// a read deadline that has a read under way return at once
var aLongTimeAgo = time.Unix(1, 0)

// errStale: the lane the downlink was reading from got replaced by the uplink.
var errStale = errors.New("miu: lane replaced")

// Stream implements net.Conn, it is the one stream a lane carries at a time:
//
//	OPEN, then in each direction DATA* (RAW + raw bytes)* END
//
// Once both directions are through END the lane goes back to the pool. Close
// before that aborts the stream: RESET, then the rest of the downlink is read and
// dropped in the background up to the END of the server, and the lane goes back
// all the same.
type Stream struct {
	c             *Client
	dest          []byte // payload of OPEN
	local, remote net.Addr

	// the ServerHello in the downlink says the inner connection is TLS 1.3, the
	// uplink needs to know
	tls13 atomic.Bool
	// a frame of this stream arrived: from here on it cannot move to another lane
	gotDown atomic.Bool
	// set under smu. From here on nothing new starts on the lane, and whoever
	// holds rmu or wmu lets go without delay.
	closed atomic.Bool

	// smu guards what both directions and Close look at
	smu      sync.Mutex
	l        *lane // nil while it is being replaced
	fail     error // why there is no lane any more
	upEnd    bool  // END is sent
	downEnd  bool  // END is received
	done     bool  // the lane is back in the pool and no longer ours
	rdl, wdl time.Time

	// uplink
	wmu    sync.Mutex
	opened bool // OPEN went out
	ended  bool // END is among what was pushed
	pkt    uint32
	raw    bool // past the inner handshake: raw segments from here on
	up     recScan
	keep   bool // sent holds all of the uplink so far
	sent   []byte
	werr   error
	timer  *time.Timer

	// downlink
	rmu       sync.Mutex
	rl        *lane
	head      [frameHead + 4]byte // header of the frame being read, and the body of a RAW frame
	headN     int
	ctl       []byte // payload of the control frame being read
	ctlN      int
	dataLeft  int   // of the current DATA frame
	rawLeft   int64 // of the current raw segment
	down      recScan
	committed bool
	eof       bool
	rerr      error
}

func newStream(c *Client, l *lane, dest []byte) *Stream {
	s := &Stream{
		c:      c,
		dest:   dest,
		local:  l.conn.LocalAddr(),
		remote: l.conn.RemoteAddr(),
		l:      l,
		rl:     l,
		pkt:    1,
		keep:   l.pooled,
	}
	s.up = recScan{tls13: &s.tls13, dead: !l.canRaw}
	s.down = recScan{tls13: &s.tls13, dead: !l.canRaw}
	s.timer = time.AfterFunc(firstPayloadWait, s.openAlone)
	return s
}

func isTimeout(err error) bool {
	var ne net.Error
	return errors.As(err, &ne) && ne.Timeout()
}

// ---- uplink ----

// Write implements net.Conn
func (s *Stream) Write(p []byte) (n int, err error) {
	if s.closed.Load() {
		return 0, io.ErrClosedPipe
	}
	s.wmu.Lock()
	defer s.wmu.Unlock()
	for len(p) > 0 {
		chunk := p
		limit := maxPacket
		if s.raw {
			limit = maxSeg
		}
		if len(chunk) > limit {
			chunk = chunk[:limit]
		}
		if err = s.push(chunk, false); err != nil {
			return n, err
		}
		n += len(chunk)
		p = p[len(chunk):]
	}
	return n, nil
}

// CloseWrite ends the uplink, the downlink goes on.
func (s *Stream) CloseWrite() error {
	if s.closed.Load() {
		return io.ErrClosedPipe
	}
	s.wmu.Lock()
	defer s.wmu.Unlock()
	if s.ended {
		return nil
	}
	return s.push(nil, true)
}

// openAlone sends OPEN when the app did not write in time.
func (s *Stream) openAlone() {
	s.wmu.Lock()
	defer s.wmu.Unlock()
	if !s.opened {
		_ = s.push(nil, false)
	}
}

// push sends the next piece of the uplink: p, then END when end is set. Should
// the lane fail, the stream moves to a new one if it still can. wmu must be held.
func (s *Stream) push(p []byte, end bool) error {
	if s.werr != nil {
		return s.werr
	}
	if s.ended {
		return io.ErrClosedPipe
	}
	s.smu.Lock()
	l := s.l
	s.smu.Unlock()
	if s.closed.Load() {
		return io.ErrClosedPipe
	}
	if s.keep {
		if s.gotDown.Load() || len(s.sent)+len(p) > replayLimit {
			s.keep, s.sent = false, nil
		} else {
			s.sent = append(s.sent, p...)
		}
	}
	s.ended = end

	err := s.send(l, p, end)
	if err != nil && !isTimeout(err) {
		// replacing sends everything pushed so far, this piece included
		_, err = s.replace(l, err)
	}
	if err != nil {
		s.werr = err
		return err
	}
	if end {
		s.smu.Lock()
		s.upEnd = true
		s.smu.Unlock()
		s.release()
	}
	return nil
}

// send writes one piece of the uplink to l. Data goes out as one packet of DATA
// frames, with OPEN in front of the first, while the inner TLS 1.3 handshake is
// looked for along the way. Once that is through it goes as raw segments, save
// for a small piece, which is a plain write of DATA frames.
func (s *Stream) send(l *lane, p []byte, end bool) error {
	if s.raw {
		var err error
		if len(p) >= rawMin {
			err = l.writeRaw(p)
		} else if len(p) > 0 {
			err = l.write(appendData(make([]byte, 0, frameHead+len(p)), p))
		}
		if err != nil {
			return err
		}
		if !end {
			return nil
		}
		p = nil
	}
	buf := pool.Get(len(s.dest) + len(p) + frameHead*(len(p)/maxData+3))
	b := buf[:0]
	if !s.opened {
		b = appendFrame(b, frOpen, s.dest)
	}
	b = appendData(b, p)
	sw := s.up.feed(p)
	err := l.writePacketEnd(s.pkt, b, end)
	_ = pool.Put(buf)
	if err != nil {
		return err
	}
	s.opened = true
	s.pkt++
	if !s.raw {
		s.raw = sw && l.peerRaw.Load()
	}
	return nil
}

// replace gets a failed lane out of the way and returns the one to go on with.
// Unless the other direction replaced it already, there is one only if the lane
// came from the pool (it may have died there unnoticed), the server has not
// answered anything on this stream yet and all of the uplink is still at hand:
// then that is sent again on a newly dialed lane. wmu must be held.
func (s *Stream) replace(old *lane, cause error) (*lane, error) {
	s.smu.Lock()
	if s.l != old {
		l, err := s.l, s.fail
		s.smu.Unlock()
		if l == nil && err == nil {
			err = io.ErrClosedPipe
		}
		return l, err
	}
	_, proto := cause.(protoError)
	if !s.keep || s.gotDown.Load() || s.closed.Load() || proto {
		if s.closed.Load() {
			cause = io.ErrClosedPipe
		} else if cause == io.EOF {
			cause = io.ErrUnexpectedEOF
		}
		s.fail = cause
		s.smu.Unlock()
		old.close()
		return nil, cause
	}
	s.l = nil // nothing arriving on old counts any more
	s.smu.Unlock()
	old.close()

	l, err := s.replay()
	s.smu.Lock()
	defer s.smu.Unlock()
	if err == nil && s.closed.Load() {
		l.close()
		err = io.ErrClosedPipe
	}
	if err != nil {
		s.fail = err
		return nil, err
	}
	s.l = l
	if !s.rdl.IsZero() {
		_ = l.conn.SetReadDeadline(s.rdl)
	}
	if !s.wdl.IsZero() {
		_ = l.conn.SetWriteDeadline(s.wdl)
	}
	s.keep, s.sent = false, nil
	s.opened, s.pkt = true, 2
	return l, nil
}

// replay dials a new lane and sends the uplink so far on it.
func (s *Stream) replay() (*lane, error) {
	ctx, cancel := context.WithTimeout(s.c.ctx, dialTimeout)
	defer cancel()
	l, err := s.c.dial(ctx)
	if err != nil {
		return nil, err
	}
	b := appendFrame(make([]byte, 0, len(s.dest)+len(s.sent)+frameHead*(len(s.sent)/maxData+3)), frOpen, s.dest)
	b = appendData(b, s.sent)
	if err = l.writePacketEnd(1, b, s.ended); err != nil {
		l.close()
		return nil, err
	}
	s.c.observe("replay")
	return l, nil
}

// ---- downlink ----

// Read implements net.Conn
func (s *Stream) Read(p []byte) (int, error) {
	if s.closed.Load() {
		return 0, io.ErrClosedPipe
	}
	s.rmu.Lock()
	defer s.rmu.Unlock()
	for {
		if s.eof {
			return 0, io.EOF
		}
		if s.rerr != nil {
			return 0, s.rerr
		}
		if len(p) == 0 {
			return 0, nil
		}
		n, err := s.readLane(s.rl, p)
		if err == nil {
			if n > 0 {
				return n, nil
			}
			continue
		}
		if s.closed.Load() {
			// Close had this read return, whoever settles the stream goes on
			// from here
			return 0, io.ErrClosedPipe
		}
		if isTimeout(err) {
			return 0, err // what is read so far of a frame stays, the next Read goes on
		}
		l, err := s.relane(s.rl, err)
		if err != nil {
			s.rerr = err
			return 0, err
		}
		s.follow(l)
	}
}

// follow moves the downlink over to l, a lane nothing was read from yet.
func (s *Stream) follow(l *lane) {
	s.rl, s.headN, s.ctl, s.dataLeft, s.rawLeft = l, 0, nil, 0, 0
	s.down = recScan{tls13: &s.tls13, dead: !l.canRaw}
}

// readLane reads from l until there is data for p or the downlink ended.
func (s *Stream) readLane(l *lane, p []byte) (int, error) {
	for !s.eof {
		switch {
		case s.dataLeft > 0:
			if len(p) > s.dataLeft {
				p = p[:s.dataLeft]
			}
			n, err := l.conn.Read(p)
			if n > 0 {
				s.dataLeft -= n
				s.down.feed(p[:n])
				return n, nil
			}
			if err != nil {
				return 0, err
			}
		case s.rawLeft > 0:
			if int64(len(p)) > s.rawLeft {
				p = p[:s.rawLeft]
			}
			n, err := l.readRaw(p)
			if n > 0 {
				s.rawLeft -= int64(n)
				return n, nil
			}
			if err != nil {
				return 0, err
			}
		default:
			if err := s.readFrame(l); err != nil {
				return 0, err
			}
		}
	}
	return 0, nil
}

// readFrame reads the next frame up to where its data starts: the payload of
// DATA and the bytes behind RAW are left on the lane. It can be resumed after a
// timeout.
func (s *Stream) readFrame(l *lane) error {
	if err := l.readMore(s.head[:frameHead], &s.headN); err != nil {
		return err
	}
	typ, n := s.head[0], int(s.head[1])<<8|int(s.head[2])
	switch typ {
	case frData:
		if !s.commit(l) {
			return errStale
		}
		s.dataLeft = n
	case frRaw:
		if n != 4 {
			return protoError("bad RAW frame")
		}
		size, err := l.readRawLen(&s.head, &s.headN)
		if err != nil {
			return err
		}
		if !s.commit(l) {
			return errStale
		}
		s.rawLeft = size
		s.c.observe("raw:in")
	case frEnd:
		if n != 0 {
			return protoError("bad END frame")
		}
		if !s.commit(l) {
			return errStale
		}
		s.eof = true
		s.smu.Lock()
		s.downEnd = true
		s.smu.Unlock()
		s.release()
	default:
		if s.ctl == nil {
			s.ctl, s.ctlN = make([]byte, n), 0
		}
		if err := l.readMore(s.ctl, &s.ctlN); err != nil {
			return err
		}
		payload := s.ctl
		s.ctl = nil
		if err := l.control(typ, payload); err != nil {
			return err
		}
	}
	s.headN = 0
	return nil
}

// commit takes the first frame of this stream arriving on l: the server answered,
// the stream stays on this lane. It fails when the uplink moved on already, the
// frame then is void.
func (s *Stream) commit(l *lane) bool {
	if !s.committed {
		s.smu.Lock()
		if s.committed = s.l == l; s.committed {
			s.gotDown.Store(true)
		}
		s.smu.Unlock()
	}
	return s.committed
}

// relane is replace for the downlink.
func (s *Stream) relane(old *lane, cause error) (*lane, error) {
	s.smu.Lock()
	l := s.l
	s.smu.Unlock()
	if l != nil && l != old {
		return l, nil
	}
	// whoever holds wmu now is writing to old or is replacing it: closing old
	// gets the former out of the way
	old.close()
	s.wmu.Lock()
	defer s.wmu.Unlock()
	return s.replace(old, cause)
}

// ---- both ----

// release hands the lane back once both directions are through END.
func (s *Stream) release() {
	s.smu.Lock()
	if !s.upEnd || !s.downEnd || s.done {
		s.smu.Unlock()
		return
	}
	s.done = true
	l := s.l
	_ = l.conn.SetDeadline(time.Time{})
	s.smu.Unlock()
	l.used = true
	s.c.put(l)
}

// Close implements net.Conn. It does not wait for the server: a stream that did
// not run to its end is aborted the way that keeps the lane (see settle), and
// calls still under way on the stream return right away.
func (s *Stream) Close() error {
	s.smu.Lock()
	if s.closed.Load() {
		s.smu.Unlock()
		return nil
	}
	s.closed.Store(true)
	l, done := s.l, s.done
	if l != nil && !done {
		// A read under way on the lane returns, its place in the frame is kept.
		_ = l.conn.SetReadDeadline(aLongTimeAgo)
	}
	s.smu.Unlock()
	s.timer.Stop()
	if done || l == nil {
		return nil // l == nil: it is being replaced, replace closes what it dials
	}
	if !s.wmu.TryLock() {
		// A write is under way. It cannot be cut short without leaving the lane
		// out of step, so the lane goes with it.
		l.close()
		return nil
	}
	last, err := s.endUplink(l)
	s.wmu.Unlock()
	switch {
	case err != nil:
		l.close()
	case last == frEnd:
		s.release()
	case last == 0 && s.rmu.TryLock():
		s.settle(l, false)
		s.rmu.Unlock()
	default:
		go func() {
			s.rmu.Lock()
			s.settle(l, last == frReset)
			s.rmu.Unlock()
		}()
	}
	return nil
}

// endUplink ends the uplink of a closed stream and tells with what: nothing when
// OPEN did not go out, END when the downlink is through END already, or else
// RESET, in place of END or behind it, for the server to stop the downlink. The
// frame is all that is written, a connection that does not take it within
// closeGrace is not worth keeping. wmu must be held.
func (s *Stream) endUplink(l *lane) (last byte, err error) {
	s.smu.Lock()
	cur, downEnd := s.l, s.downEnd
	s.smu.Unlock()
	if cur != l || s.werr != nil {
		return 0, io.ErrClosedPipe
	}
	if !s.opened {
		return 0, nil
	}
	last = frReset
	if downEnd {
		last = frEnd
	}
	s.ended = true
	_ = l.conn.SetWriteDeadline(time.Now().Add(closeGrace))
	if err = l.write(appendFrame(nil, last, nil)); err != nil {
		return 0, err
	}
	s.smu.Lock()
	s.upEnd = true
	s.smu.Unlock()
	if last == frReset {
		s.c.observe("reset")
	}
	return last, nil
}

// settle takes the lane of a closed stream to where it can carry another one,
// or closes it. Without reset nothing of the stream went out: the lane is as it
// came, unless a frame is half read. With reset the server was told to stop: the
// downlink is read and dropped up to its END, within the time the client allows.
// rmu must be held, nobody else reads from the lane meanwhile.
func (s *Stream) settle(l *lane, reset bool) {
	s.smu.Lock()
	done := s.done
	s.smu.Unlock()
	if done || l.closed.Load() {
		return
	}
	if s.rerr != nil {
		l.close()
		return
	}
	if !reset {
		if s.headN != 0 || s.ctl != nil || l.conn.SetDeadline(time.Time{}) != nil {
			l.close()
			return
		}
		s.smu.Lock()
		s.done = true
		s.smu.Unlock()
		s.c.put(l)
		return
	}
	if s.rl != l {
		s.follow(l) // the uplink moved to it and nobody read since
	}
	_ = l.conn.SetReadDeadline(time.Now().Add(s.c.drain))
	buf := pool.Get(16 << 10)
	defer pool.Put(buf)
	for !s.eof {
		if _, err := s.readLane(l, buf); err != nil {
			l.close()
			return
		}
	}
	// both directions are through END
	s.release()
}

func (s *Stream) SetReadDeadline(t time.Time) error {
	s.smu.Lock()
	defer s.smu.Unlock()
	s.rdl = t
	if s.l != nil && !s.done && !s.closed.Load() {
		return s.l.conn.SetReadDeadline(t)
	}
	return nil
}

func (s *Stream) SetWriteDeadline(t time.Time) error {
	s.smu.Lock()
	defer s.smu.Unlock()
	s.wdl = t
	if s.l != nil && !s.done && !s.closed.Load() {
		return s.l.conn.SetWriteDeadline(t)
	}
	return nil
}

func (s *Stream) SetDeadline(t time.Time) error {
	_ = s.SetWriteDeadline(t)
	return s.SetReadDeadline(t)
}

// LocalAddr satisfies net.Conn interface
func (s *Stream) LocalAddr() net.Addr {
	return s.local
}

// RemoteAddr satisfies net.Conn interface
func (s *Stream) RemoteAddr() net.Addr {
	return s.remote
}
