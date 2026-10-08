package miu

import (
	"bytes"
	"context"
	"crypto/sha256"
	"net"
	"strings"
	"sync/atomic"
	"time"

	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/transport/anytls/padding"
	"github.com/metacubex/mihomo/transport/vmess"

	"github.com/gofrs/uuid/v5"
	M "github.com/metacubex/sing/common/metadata"
	N "github.com/metacubex/sing/common/network"
)

type ClientConfig struct {
	PSK                      string
	ClientMetadata           string
	Vision                   bool // TCP to port 443 uses a dedicated connection handed over to XTLS-Vision
	RecvWindow               int  // per stream receive window in bytes, 0 = default
	IdleSessionCheckInterval time.Duration
	IdleSessionTimeout       time.Duration
	MinIdleSession           int
	Server                   M.Socksaddr
	Dialer                   N.Dialer
	TLSConfig                *vmess.TLSConfig
}

type Client struct {
	token          [authTokenLen]byte // sha256(psk string), the auth header
	visionSeed     uuid.UUID          // sha256(psk)[:16], the Vision seed of Vision, same on both ends
	clientMetadata string
	recvWindow     int64
	vision         bool
	// Vision: the server granted it once (only then data may go out before its
	// reply) / the server does not grant it (everything goes through MUX from then on)
	visionConfirmed atomic.Bool
	visionRefused   atomic.Bool
	spares          visionSpares
	tlsConfig       *vmess.TLSConfig
	dialer          N.Dialer
	server          M.Socksaddr
	pool            *sessionPool
	padding         atomic.Pointer[padding.PaddingFactory]
}

func NewClient(ctx context.Context, config ClientConfig) (*Client, error) {
	pskString := strings.TrimSpace(config.PSK)
	psk, err := decodePSK(pskString)
	if err != nil {
		return nil, err
	}
	seed := sha256.Sum256(psk)
	c := &Client{
		token:          authToken(pskString),
		visionSeed:     uuid.FromBytesOrNil(seed[:uuid.Size]),
		clientMetadata: config.ClientMetadata,
		recvWindow:     clampWindow(int64(config.RecvWindow)),
		vision:         config.Vision,
		tlsConfig:      config.TLSConfig,
		dialer:         config.Dialer,
		server:         config.Server,
	}
	// Initialize the padding state of this client
	padding.UpdatePaddingScheme(padding.DefaultPaddingScheme, &c.padding)
	c.pool = newSessionPool(ctx, c.newSession, config.IdleSessionCheckInterval, config.IdleSessionTimeout, config.MinIdleSession)
	return c, nil
}

// CreateProxy opens a TCP proxy connection to destination. With Vision enabled the
// mode is picked per connection: port 443 (the inner traffic is TLS almost for
// sure, so Vision has something to hand over) gets a dedicated Vision connection,
// everything else is a MUX stream. A server that does not grant Vision is
// remembered and only gets MUX streams afterwards.
func (c *Client) CreateProxy(ctx context.Context, destination M.Socksaddr) (net.Conn, error) {
	if c.useVision(destination) {
		conn, err := c.dialVision(ctx, destination)
		if err != errVisionRefused {
			return conn, err
		}
	}
	return c.CreateStream(ctx, destination)
}

func (c *Client) useVision(destination M.Socksaddr) bool {
	return c.vision && destination.Port == visionPort && !c.visionRefused.Load()
}

// refuseVision remembers that the server does not grant Vision.
func (c *Client) refuseVision() {
	c.visionConfirmed.Store(false)
	if c.visionRefused.CompareAndSwap(false, true) {
		log.Warnln("[Miu] %s does not grant Vision, falling back to MUX", c.server)
	}
}

// CreateStream opens a MUX stream to destination.
func (c *Client) CreateStream(ctx context.Context, destination M.Socksaddr) (net.Conn, error) {
	addr, err := destinationBytes(destination)
	if err != nil {
		return nil, err
	}
	stream, err := c.pool.CreateStream(ctx)
	if err != nil {
		return nil, err
	}
	// the first PSH of a stream carries the destination
	if err = stream.writeDestination(addr); err != nil {
		stream.Close()
		return nil, err
	}
	return stream, nil
}

func destinationBytes(destination M.Socksaddr) ([]byte, error) {
	var b bytes.Buffer
	if err := M.SocksaddrSerializer.WriteAddrPort(&b, destination); err != nil {
		return nil, err
	}
	return b.Bytes(), nil
}

// connect dials the server and finishes the outer TLS handshake.
func (c *Client) connect(ctx context.Context) (net.Conn, error) {
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

// authHeader is the first thing sent on a connection.
func (c *Client) authHeader() []byte {
	var paddingLen int
	if pad := c.padding.Load().GenerateRecordPayloadSizes(0); len(pad) > 0 {
		paddingLen = pad[0]
	}
	return buildAuthHeader(c.token, paddingLen)
}

func (c *Client) newSession(ctx context.Context) (*Session, error) {
	conn, err := c.connect(ctx)
	if err != nil {
		return nil, err
	}
	if _, err = conn.Write(c.authHeader()); err != nil {
		conn.Close()
		return nil, err
	}
	return newSession(conn, &c.padding, c.clientMetadata, c.recvWindow), nil
}

func (c *Client) Close() error {
	err := c.pool.Close()
	c.spares.close()
	return err
}
