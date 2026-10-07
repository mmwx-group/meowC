package outbound

import (
	"context"
	"errors"
	"net"
	"strconv"
	"time"

	N "github.com/metacubex/mihomo/common/net"
	"github.com/metacubex/mihomo/component/proxydialer"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/transport/miu"
	"github.com/metacubex/mihomo/transport/vmess"

	M "github.com/metacubex/sing/common/metadata"
	"github.com/metacubex/sing/common/uot"
)

type Miu struct {
	*Base
	client *miu.Client
	option *MiuOption
}

type MiuOption struct {
	BasicOption
	Name                     string         `proxy:"name"`
	Server                   string         `proxy:"server"`
	Port                     int            `proxy:"port"`
	PSK                      string         `proxy:"psk"`
	ALPN                     []string       `proxy:"alpn,omitempty"`
	SNI                      string         `proxy:"sni,omitempty"`
	ServerName               string         `proxy:"servername,omitempty"`
	ECHOpts                  ECHOptions     `proxy:"ech-opts,omitempty"`
	RealityOpts              RealityOptions `proxy:"reality-opts,omitempty"`
	ClientFingerprint        string         `proxy:"client-fingerprint,omitempty"`
	SkipCertVerify           bool           `proxy:"skip-cert-verify,omitempty"`
	NameCertVerify           string         `proxy:"name-cert-verify,omitempty"`
	Fingerprint              string         `proxy:"fingerprint,omitempty"`
	Certificate              string         `proxy:"certificate,omitempty"`
	PrivateKey               string         `proxy:"private-key,omitempty"`
	UDP                      bool           `proxy:"udp,omitempty"`
	Direct                   bool           `proxy:"direct,omitempty"`
	RecvWindow               int            `proxy:"recv-window,omitempty"`
	ClientMetadata           string         `proxy:"client-metadata,omitempty"`
	IdleSessionCheckInterval int            `proxy:"idle-session-check-interval,omitempty"`
	IdleSessionTimeout       int            `proxy:"idle-session-timeout,omitempty"`
	MinIdleSession           int            `proxy:"min-idle-session,omitempty"`
}

func (t *Miu) DialContext(ctx context.Context, metadata *C.Metadata) (_ C.Conn, err error) {
	c, err := t.client.CreateProxy(ctx, M.ParseSocksaddrHostPort(metadata.String(), metadata.DstPort))
	if err != nil {
		return nil, err
	}
	return NewConn(c, t), nil
}

func (t *Miu) ListenPacketContext(ctx context.Context, metadata *C.Metadata) (_ C.PacketConn, err error) {
	if err = t.ResolveUDP(ctx, metadata); err != nil {
		return nil, err
	}

	// UDP always rides a MUX stream
	c, err := t.client.CreateStream(ctx, uot.RequestDestination(2))
	if err != nil {
		return nil, err
	}

	// create uot on tcp
	destination := M.SocksaddrFromNet(metadata.UDPAddr())
	return NewPacketConn(N.NewThreadSafePacketConn(uot.NewLazyConn(c, uot.Request{Destination: destination})), t), nil
}

// SupportUOT implements C.ProxyAdapter
func (t *Miu) SupportUOT() bool {
	return true
}

// ProxyInfo implements C.ProxyAdapter
func (t *Miu) ProxyInfo() C.ProxyInfo {
	info := t.Base.ProxyInfo()
	info.DialerProxy = t.option.DialerProxy
	return info
}

// Close implements C.ProxyAdapter
func (t *Miu) Close() error {
	return t.client.Close()
}

func NewMiu(option MiuOption) (*Miu, error) {
	addr := net.JoinHostPort(option.Server, strconv.Itoa(option.Port))
	outbound := &Miu{
		Base: NewBase(BaseOption{
			Name:         option.Name,
			Addr:         addr,
			Type:         C.Miu,
			ProviderName: option.ProviderName,
			UDP:          option.UDP,
			TFO:          option.TFO,
			MPTCP:        option.MPTCP,
			Interface:    option.Interface,
			RoutingMark:  option.RoutingMark,
			Prefer:       option.IPVersion,
		}),
		option: &option,
	}
	outbound.dialer = option.NewDialer(outbound.DialOptions())
	singDialer := proxydialer.NewSingDialer(outbound.dialer)

	echConfig, err := option.ECHOpts.Parse()
	if err != nil {
		return nil, err
	}
	realityConfig, err := option.RealityOpts.Parse()
	if err != nil {
		return nil, err
	}
	if realityConfig != nil && option.ClientFingerprint == "" {
		return nil, errors.New("REALITY is based on uTLS, please set a client-fingerprint")
	}
	tlsConfig := &vmess.TLSConfig{
		Host:              option.SNI,
		SkipCertVerify:    option.SkipCertVerify,
		NameCertVerify:    option.NameCertVerify,
		NextProtos:        option.ALPN,
		FingerPrint:       option.Fingerprint,
		Certificate:       option.Certificate,
		PrivateKey:        option.PrivateKey,
		ClientFingerprint: option.ClientFingerprint,
		ECH:               echConfig,
		Reality:           realityConfig,
	}
	if tlsConfig.Host == "" {
		tlsConfig.Host = option.ServerName
	}
	if tlsConfig.Host == "" {
		tlsConfig.Host = option.Server
	}

	client, err := miu.NewClient(context.TODO(), miu.ClientConfig{
		PSK:                      option.PSK,
		ClientMetadata:           option.ClientMetadata,
		Direct:                   option.Direct,
		RecvWindow:               option.RecvWindow,
		IdleSessionCheckInterval: time.Duration(option.IdleSessionCheckInterval) * time.Second,
		IdleSessionTimeout:       time.Duration(option.IdleSessionTimeout) * time.Second,
		MinIdleSession:           option.MinIdleSession,
		Server:                   M.ParseSocksaddrHostPort(option.Server, uint16(option.Port)),
		Dialer:                   singDialer,
		TLSConfig:                tlsConfig,
	})
	if err != nil {
		return nil, err
	}
	outbound.client = client

	return outbound, nil
}
