package outbound

import (
	"context"
	"fmt"
	"net"
	"strconv"

	N "github.com/metacubex/mihomo/common/net"
	"github.com/metacubex/mihomo/common/structure"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/transport/jls"
	"github.com/metacubex/mihomo/transport/restls"
	"github.com/metacubex/mihomo/transport/shadowtls"
	obfs "github.com/metacubex/mihomo/transport/simple-obfs"
	"github.com/metacubex/mihomo/transport/snell"
)

type Snell struct {
	*Base
	option          *SnellOption
	psk             []byte
	pool            *snell.Pool
	obfsOption      *simpleObfsOption
	shadowTLSOption *shadowtls.ShadowTLSOption
	restlsConfig    *restls.Config
	jlsConfig       *jls.ClientConfig
	version         int
	reuse           bool
	v6              *snell.V6Client // set for version 6 only
}

type SnellOption struct {
	BasicOption
	Name              string         `proxy:"name"`
	Server            string         `proxy:"server"`
	Port              int            `proxy:"port"`
	Psk               string         `proxy:"psk"`
	UDP               bool           `proxy:"udp,omitempty"`
	Version           int            `proxy:"version,omitempty"`
	Mode              string         `proxy:"mode,omitempty"` // version 6 only: default / unshaped / unsafe-raw
	Reuse             bool           `proxy:"reuse,omitempty"`
	ObfsOpts          map[string]any `proxy:"obfs-opts,omitempty"`
	ClientFingerprint string         `proxy:"client-fingerprint,omitempty"`
}

func (s *Snell) streamConnContext(ctx context.Context, c net.Conn) (*snell.Snell, error) {
	var err error
	switch s.obfsOption.Mode {
	case "tls":
		c = obfs.NewTLSObfs(c, s.obfsOption.Host)
	case "http":
		_, port, _ := net.SplitHostPort(s.addr)
		c = obfs.NewHTTPObfs(c, s.obfsOption.Host, port)
	case shadowtls.Mode:
		c, err = shadowtls.NewShadowTLS(ctx, c, s.shadowTLSOption)
		if err != nil {
			return nil, err
		}
	case restls.Mode:
		c, err = restls.NewRestls(ctx, c, s.restlsConfig)
		if err != nil {
			return nil, err
		}
	case jls.Mode:
		c, err = jls.NewClient(ctx, c, s.jlsConfig)
		if err != nil {
			return nil, err
		}
	}
	return snell.StreamConn(c, s.psk, s.version), nil
}

// streamConnV6 starts a version 6 request on c: a UDP tunnel, whose reply is
// awaited here, or a TCP stream.
func (s *Snell) streamConnV6(ctx context.Context, c net.Conn, metadata *C.Metadata) (_ net.Conn, err error) {
	if ctx.Done() != nil {
		done := N.SetupContextForConn(ctx, c)
		defer done(&err)
	}

	if metadata.NetWork == C.UDP {
		var pc *snell.V6PacketConn
		pc, err = s.v6.StreamPacketConn(c)
		if err != nil {
			return nil, err
		}
		return pc, nil
	}
	return s.v6.StreamConn(c, metadata.String(), metadata.DstPort)
}

// StreamConnContext implements C.ProxyAdapter
func (s *Snell) StreamConnContext(ctx context.Context, c net.Conn, metadata *C.Metadata) (net.Conn, error) {
	if s.v6 != nil {
		return s.streamConnV6(ctx, c, metadata)
	}
	c, err := s.streamConnContext(ctx, c)
	if err != nil {
		return nil, err
	}
	err = s.writeHeaderContext(ctx, c, metadata)
	return c, err
}

func (s *Snell) writeHeaderContext(ctx context.Context, c net.Conn, metadata *C.Metadata) (err error) {
	if ctx.Done() != nil {
		done := N.SetupContextForConn(ctx, c)
		defer done(&err)
	}

	if metadata.NetWork == C.UDP {
		err = snell.WriteUDPHeader(c, s.version)
		if err == nil && s.version >= snell.Version4 {
			if sc, ok := c.(*snell.Snell); ok {
				err = sc.ReadReply()
			}
		}
		return
	}
	err = snell.WriteHeaderWithReuse(c, metadata.String(), uint(metadata.DstPort), s.version, s.reuse)
	return
}

// dialContextV6 is DialContext for version 6.
func (s *Snell) dialContextV6(ctx context.Context, metadata *C.Metadata) (C.Conn, error) {
	if s.reuse {
		c, err := s.v6.DialContext(ctx, metadata.String(), metadata.DstPort)
		if err != nil {
			return nil, err
		}
		return NewConn(c, s), nil
	}

	c, err := s.dialer.DialContext(ctx, "tcp", s.addr)
	if err != nil {
		return nil, fmt.Errorf("%s connect error: %w", s.addr, err)
	}
	sc, err := s.streamConnV6(ctx, c, metadata)
	if err != nil {
		_ = c.Close()
		return nil, err
	}
	return NewConn(sc, s), nil
}

// DialContext implements C.ProxyAdapter
func (s *Snell) DialContext(ctx context.Context, metadata *C.Metadata) (_ C.Conn, err error) {
	if s.v6 != nil {
		return s.dialContextV6(ctx, metadata)
	}
	if s.reuse {
		c, err := s.pool.Get()
		if err != nil {
			return nil, err
		}

		if err = s.writeHeaderContext(ctx, c, metadata); err != nil {
			_ = c.Close()
			return nil, err
		}
		if pc, ok := c.(*snell.PoolConn); ok {
			pc.MarkReusable()
		}
		return NewConn(c, s), err
	}

	c, err := s.dialer.DialContext(ctx, "tcp", s.addr)
	if err != nil {
		return nil, fmt.Errorf("%s connect error: %w", s.addr, err)
	}

	defer func(c net.Conn) {
		safeConnClose(c, err)
	}(c)

	c, err = s.StreamConnContext(ctx, c, metadata)
	return NewConn(c, s), err
}

// ListenPacketContext implements C.ProxyAdapter
func (s *Snell) ListenPacketContext(ctx context.Context, metadata *C.Metadata) (_ C.PacketConn, err error) {
	if err = s.ResolveUDP(ctx, metadata); err != nil {
		return nil, err
	}
	c, err := s.dialer.DialContext(ctx, "tcp", s.addr)
	if err != nil {
		return nil, err
	}

	defer func(c net.Conn) {
		safeConnClose(c, err)
	}(c)

	c, err = s.StreamConnContext(ctx, c, metadata)
	if err != nil {
		return nil, err
	}

	pc := snell.PacketConn(c)
	return NewPacketConn(pc, s), nil
}

// SupportUOT implements C.ProxyAdapter
func (s *Snell) SupportUOT() bool {
	return true
}

// Close implements C.ProxyAdapter
func (s *Snell) Close() error {
	if s.v6 != nil {
		return s.v6.Close()
	}
	return nil
}

// ProxyInfo implements C.ProxyAdapter
func (s *Snell) ProxyInfo() C.ProxyInfo {
	info := s.Base.ProxyInfo()
	info.DialerProxy = s.option.DialerProxy
	return info
}

func NewSnell(option SnellOption) (*Snell, error) {
	addr := net.JoinHostPort(option.Server, strconv.Itoa(option.Port))
	psk := []byte(option.Psk)

	if option.Version == snell.Version6 {
		return newSnellV6(option, addr, psk)
	}

	decoder := structure.NewDecoder(structure.Option{TagName: "obfs", WeaklyTypedInput: true})
	obfsOption := &simpleObfsOption{Host: "bing.com"}
	if err := decoder.Decode(option.ObfsOpts, obfsOption); err != nil {
		return nil, fmt.Errorf("snell %s initialize obfs error: %w", addr, err)
	}

	var shadowTLSOpt *shadowtls.ShadowTLSOption
	var restlsConfig *restls.Config
	var jlsConfig *jls.ClientConfig
	switch obfsOption.Mode {
	case "tls", "http", "":
		break
	case shadowtls.Mode:
		opt := &shadowTLSOption{
			Version: 2,
		}
		if err := decoder.Decode(option.ObfsOpts, opt); err != nil {
			return nil, fmt.Errorf("snell %s initialize shadow-tls-plugin error: %w", addr, err)
		}

		shadowTLSOpt = &shadowtls.ShadowTLSOption{
			Password:          opt.Password,
			Host:              opt.Host,
			Fingerprint:       opt.Fingerprint,
			Certificate:       opt.Certificate,
			PrivateKey:        opt.PrivateKey,
			ClientFingerprint: option.ClientFingerprint,
			SkipCertVerify:    opt.SkipCertVerify,
			NameCertVerify:    opt.NameCertVerify,
			Version:           opt.Version,
		}

		if opt.ALPN != nil { // structure's Decode will ensure value not nil when input has value even it was set an empty array
			shadowTLSOpt.ALPN = opt.ALPN
		} else {
			shadowTLSOpt.ALPN = shadowtls.DefaultALPN
		}
	case restls.Mode:
		opt := &restlsOption{}
		if err := decoder.Decode(option.ObfsOpts, opt); err != nil {
			return nil, fmt.Errorf("snell %s initialize restls-plugin error: %w", addr, err)
		}

		var err error
		restlsConfig, err = restls.NewRestlsConfig(opt.Host, opt.Password, opt.VersionHint, opt.RestlsScript, option.ClientFingerprint)
		if err != nil {
			return nil, fmt.Errorf("snell %s initialize restls-plugin error: %w", addr, err)
		}
		restlsConfig.InsecureSkipVerify = opt.SkipCertVerify
		if opt.Fingerprint != "" {
			if err = restls.SetFingerprint(restlsConfig, opt.Fingerprint, opt.NameCertVerify); err != nil {
				return nil, fmt.Errorf("snell %s initialize restls-plugin error: %w", addr, err)
			}
		} else if opt.NameCertVerify != "" {
			restls.SetNameCertVerify(restlsConfig, opt.NameCertVerify)
		}
		restlsConfig.ForceTLS12 = opt.ForceTLS12
	case jls.Mode:
		opt := &jlsOption{}
		if err := decoder.Decode(option.ObfsOpts, opt); err != nil {
			return nil, fmt.Errorf("snell %s initialize jls-plugin error: %w", addr, err)
		}

		var err error
		jlsConfig, err = jls.NewClientConfig(opt.Host, opt.Username, opt.Password, opt.ALPN)
		if err != nil {
			return nil, fmt.Errorf("snell %s initialize jls-plugin error: %w", addr, err)
		}
		jlsConfig.ClientFingerprint = option.ClientFingerprint
	default:
		return nil, fmt.Errorf("snell %s obfs mode error: %s", addr, obfsOption.Mode)
	}

	// backward compatible
	if option.Version == 0 {
		option.Version = snell.DefaultSnellVersion
	}
	if option.Version == snell.Version5 {
		// Snell v5 servers are backward-compatible with v4 clients.
		option.Version = snell.Version4
	}
	reuse := option.Version == snell.Version2 || (option.Version == snell.Version4 && option.Reuse)
	switch option.Version {
	case snell.Version1, snell.Version2:
		if option.UDP {
			return nil, fmt.Errorf("snell version %d not support UDP", option.Version)
		}
	case snell.Version3, snell.Version4:
	default:
		return nil, fmt.Errorf("snell version error: %d", option.Version)
	}

	s := &Snell{
		Base: NewBase(BaseOption{
			Name:         option.Name,
			Addr:         addr,
			Type:         C.Snell,
			ProviderName: option.ProviderName,
			UDP:          option.UDP,
			TFO:          option.TFO,
			MPTCP:        option.MPTCP,
			Interface:    option.Interface,
			RoutingMark:  option.RoutingMark,
			Prefer:       option.IPVersion,
		}),
		option:          &option,
		psk:             psk,
		obfsOption:      obfsOption,
		shadowTLSOption: shadowTLSOpt,
		restlsConfig:    restlsConfig,
		jlsConfig:       jlsConfig,
		version:         option.Version,
		reuse:           reuse,
	}
	s.dialer = option.NewDialer(s.DialOptions())

	if s.reuse {
		s.pool = snell.NewPool(func(ctx context.Context) (*snell.Snell, error) {
			c, err := s.dialer.DialContext(ctx, "tcp", addr)
			if err != nil {
				return nil, err
			}

			sc, err := s.streamConnContext(ctx, c)
			if err != nil {
				_ = c.Close()
				return nil, err
			}
			return sc, nil
		})
	}
	return s, nil
}

// newSnellV6 builds a version 6 outbound. Version 6 has no obfs layer: its
// default mode shapes the traffic itself. obfs-opts is ignored rather than
// rejected, so a node that carries it by mistake does not fail the whole
// config.
func newSnellV6(option SnellOption, addr string, psk []byte) (*Snell, error) {
	mode, err := snell.ParseV6Mode(option.Mode)
	if err != nil {
		return nil, fmt.Errorf("snell %s: %w", addr, err)
	}

	s := &Snell{
		Base: NewBase(BaseOption{
			Name:         option.Name,
			Addr:         addr,
			Type:         C.Snell,
			ProviderName: option.ProviderName,
			UDP:          option.UDP,
			TFO:          option.TFO,
			MPTCP:        option.MPTCP,
			Interface:    option.Interface,
			RoutingMark:  option.RoutingMark,
			Prefer:       option.IPVersion,
		}),
		option:     &option,
		psk:        psk,
		obfsOption: &simpleObfsOption{},
		version:    snell.Version6,
		reuse:      option.Reuse,
	}
	s.dialer = option.NewDialer(s.DialOptions())

	s.v6, err = snell.NewV6Client(snell.V6Option{
		PSK:   psk,
		Mode:  mode,
		Reuse: option.Reuse,
		Dial: func(ctx context.Context) (net.Conn, error) {
			c, err := s.dialer.DialContext(ctx, "tcp", addr)
			if err != nil {
				return nil, fmt.Errorf("%s connect error: %w", addr, err)
			}
			return c, nil
		},
	})
	if err != nil {
		return nil, fmt.Errorf("snell %s: %w", addr, err)
	}
	return s, nil
}
