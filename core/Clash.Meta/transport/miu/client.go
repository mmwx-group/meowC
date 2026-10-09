package miu

import (
	"bytes"
	"context"
	"net"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/metacubex/mihomo/transport/anytls/padding"
	"github.com/metacubex/mihomo/transport/vmess"

	M "github.com/metacubex/sing/common/metadata"
	N "github.com/metacubex/sing/common/network"
)

type ClientConfig struct {
	PSK string
	// how long an idle lane is kept (the few put back last stay longer), and how
	// many idle lanes are prewarmed while streams keep coming, 0 = default
	IdleSessionTimeout time.Duration
	MinIdleSession     int
	Server             M.Socksaddr
	Dialer             N.Dialer
	TLSConfig          *vmess.TLSConfig
}

type Client struct {
	token     [authTokenLen]byte // sha256(psk string), the auth header
	tlsConfig *vmess.TLSConfig
	dialer    N.Dialer
	server    M.Socksaddr
	padding   atomic.Pointer[padding.PaddingFactory]

	// connect dials the server and finishes the outer handshake
	connect func(ctx context.Context) (net.Conn, error)
	// ctx ends with Close, the dials not made for a request run on it
	ctx    context.Context
	cancel context.CancelFunc

	laneIdle, warmIdle time.Duration
	minIdle            int
	// how long an aborted stream waits for the END of the server
	drain time.Duration

	mu       sync.Mutex
	idle     []idleLane // oldest first
	pending  int        // prewarm dials under way
	lastOpen time.Time
	sweeper  *time.Timer
	closed   bool

	// set by the tests only: lanes dialed and reused, raw segments, replays, resets
	observer func(event string)
}

func NewClient(ctx context.Context, config ClientConfig) (*Client, error) {
	psk := strings.TrimSpace(config.PSK)
	if err := checkPSK(psk); err != nil {
		return nil, err
	}
	c := &Client{
		token:     authToken(psk),
		tlsConfig: config.TLSConfig,
		dialer:    config.Dialer,
		server:    config.Server,
		laneIdle:  defaultLaneIdle,
		warmIdle:  warmLaneIdle,
		drain:     abortDrain,
		minIdle:   defaultMinIdle,
	}
	c.connect = c.connectTLS
	c.ctx, c.cancel = context.WithCancel(ctx)
	if config.IdleSessionTimeout > 0 {
		c.laneIdle = config.IdleSessionTimeout
	}
	if config.MinIdleSession > 0 {
		c.minIdle = config.MinIdleSession
	}
	// Initialize the padding state of this client
	padding.UpdatePaddingScheme(padding.DefaultPaddingScheme, &c.padding)
	return c, nil
}

func (c *Client) observe(event string) {
	if c.observer != nil {
		c.observer(event)
	}
}

// CreateProxy opens a stream to destination, TCP or the UoT magic address. It
// returns once a lane is at hand: on a warm one that is right away, the server is
// not asked and does not answer, a destination it cannot reach shows as EOF.
func (c *Client) CreateProxy(ctx context.Context, destination M.Socksaddr) (net.Conn, error) {
	var addr bytes.Buffer
	if err := M.SocksaddrSerializer.WriteAddrPort(&addr, destination); err != nil {
		return nil, err
	}
	l, err := c.get(ctx)
	if err != nil {
		return nil, err
	}
	return newStream(c, l, addr.Bytes()), nil
}

func (c *Client) connectTLS(ctx context.Context) (net.Conn, error) {
	conn, err := c.dialer.DialContext(ctx, N.NetworkTCP, c.server)
	if err != nil {
		return nil, err
	}

	tlsConn, err := vmess.StreamTLSConn(ctx, conn, c.tlsConfig)
	if err != nil {
		conn.Close()
		return nil, err
	}
	return tlsConn, nil
}

// hello is the first thing sent on a lane: the auth header, its padding and the
// Settings frame.
func (c *Client) hello(l *lane) []byte {
	scheme := c.padding.Load()
	paddingLen := authPadding(scheme)
	b := appendAuthHeader(make([]byte, 0, authTokenLen+2+paddingLen+64), c.token, paddingLen)
	return appendFrame(b, frSettings, l.settings(scheme.Md5))
}

// dial brings up a new lane: the outer handshake, then the hello in one write.
// No reply is waited for, the lane can carry a stream right away.
func (c *Client) dial(ctx context.Context) (*lane, error) {
	conn, err := c.connect(ctx)
	if err != nil {
		return nil, err
	}
	l := newLane(c, conn)
	if err = l.write(c.hello(l)); err != nil {
		l.close()
		return nil, err
	}
	c.observe("lane:dial")
	return l, nil
}

// Close closes the lanes in the pool. A lane still carrying a stream is closed
// when that stream lets go of it.
func (c *Client) Close() error {
	c.cancel()
	c.mu.Lock()
	idle := c.idle
	c.idle = nil
	c.closed = true
	if c.sweeper != nil {
		c.sweeper.Stop()
		c.sweeper = nil
	}
	c.mu.Unlock()
	for _, it := range idle {
		it.l.close()
	}
	return nil
}
