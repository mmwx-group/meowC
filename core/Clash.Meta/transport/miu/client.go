package miu

import (
	"bytes"
	"context"
	"crypto/sha256"
	"net"
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
	Vision                   bool // TCP uses a dedicated connection handed over to XTLS-Vision
	RecvWindow               int  // per stream receive window in bytes, 0 = default
	IdleSessionCheckInterval time.Duration
	IdleSessionTimeout       time.Duration
	MinIdleSession           int
	Server                   M.Socksaddr
	Dialer                   N.Dialer
	TLSConfig                *vmess.TLSConfig
}

type Client struct {
	psk            []byte
	visionSeed     uuid.UUID // sha256(psk)[:16], the Vision seed of Vision, same on both ends
	clientMetadata string
	recvWindow     int64
	vision         bool
	visionRefused  atomic.Bool // the server does not grant Vision
	tlsConfig      *vmess.TLSConfig
	dialer         N.Dialer
	server         M.Socksaddr
	pool           *sessionPool
	padding        atomic.Pointer[padding.PaddingFactory]
}

func NewClient(ctx context.Context, config ClientConfig) (*Client, error) {
	psk, err := decodePSK(config.PSK)
	if err != nil {
		return nil, err
	}
	seed := sha256.Sum256(psk)
	c := &Client{
		psk:            psk,
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

// CreateProxy opens a TCP proxy connection to destination, with Vision when it
// is enabled and granted by the server, as a MUX stream otherwise.
func (c *Client) CreateProxy(ctx context.Context, destination M.Socksaddr) (net.Conn, error) {
	if c.vision && !c.visionRefused.Load() {
		conn, err := c.dialVision(ctx, destination)
		if err != errVisionRefused {
			return conn, err
		}
		if c.visionRefused.CompareAndSwap(false, true) {
			log.Warnln("[Miu] %s does not grant Vision, falling back to MUX", c.server)
		}
	}
	return c.CreateStream(ctx, destination)
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

// connect dials the server, finishes the outer TLS handshake and sends the auth
// header. The returned ekm is nil when the transport has no exporter.
func (c *Client) connect(ctx context.Context) (net.Conn, []byte, error) {
	conn, err := c.dialer.DialContext(ctx, N.NetworkTCP, c.server)
	if err != nil {
		return nil, nil, err
	}

	tlsConn, err := vmess.StreamTLSConn(ctx, conn, c.tlsConfig)
	if err != nil {
		conn.Close()
		return nil, nil, err
	}

	var paddingLen int
	if pad := c.padding.Load().GenerateRecordPayloadSizes(0); len(pad) > 0 {
		paddingLen = pad[0]
	}
	ekm := exportKeyingMaterial(tlsConn)
	if _, err = tlsConn.Write(buildAuthHeader(c.psk, ekm, paddingLen)); err != nil {
		tlsConn.Close()
		return nil, nil, err
	}
	return tlsConn, ekm, nil
}

func (c *Client) newSession(ctx context.Context) (*Session, error) {
	conn, ekm, err := c.connect(ctx)
	if err != nil {
		return nil, err
	}
	return newSession(conn, &c.padding, c.clientMetadata, c.psk, ekm, c.recvWindow), nil
}

func (c *Client) Close() error {
	return c.pool.Close()
}
