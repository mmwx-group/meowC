package miu

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	stdtls "crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"math/big"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	tlsC "github.com/metacubex/mihomo/component/tls"
	"github.com/metacubex/mihomo/transport/vmess"

	M "github.com/metacubex/sing/common/metadata"
	N "github.com/metacubex/sing/common/network"
	"github.com/metacubex/sing/common/uot"
)

// Live test against the reference server, skipped unless MIU_LIVE_MIUX points at
// its binary. In the miu repository:
//
//	go build -o /tmp/miux ./cmd/miux
//	MIU_LIVE_MIUX=/tmp/miux go test ./transport/miu/ -run TestLive -v
//
// The test starts the server itself, on ports of its own choosing.

func liveCert(t *testing.T) (certPEM, keyPEM []byte, pair stdtls.Certificate) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "localhost"},
		DNSNames:     []string{"localhost"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	keyDER, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	certPEM = pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyPEM = pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER})
	if pair, err = stdtls.X509KeyPair(certPEM, keyPEM); err != nil {
		t.Fatal(err)
	}
	return
}

func livePEMLines(b []byte) string {
	out, _ := json.Marshal(strings.Split(strings.TrimSpace(string(b)), "\n"))
	return string(out)
}

func liveFreePort(t *testing.T) int {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	return ln.Addr().(*net.TCPAddr).Port
}

func liveServe(t *testing.T, ln net.Listener, handle func(net.Conn)) M.Socksaddr {
	t.Helper()
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				handle(conn)
			}()
		}
	}()
	return M.ParseSocksaddrHostPort("127.0.0.1", uint16(ln.Addr().(*net.TCPAddr).Port))
}

// liveEcho echoes until the client is done.
func liveEcho(conn net.Conn) {
	_, _ = io.Copy(conn, conn)
}

// liveEchoN reads a length, echoes that many bytes and closes: the downlink
// ends first.
func liveEchoN(conn net.Conn) {
	var head [4]byte
	if _, err := io.ReadFull(conn, head[:]); err != nil {
		return
	}
	_, _ = io.CopyN(conn, conn, int64(binary.BigEndian.Uint32(head[:])))
}

// liveFlood writes without end, a pattern that tells where in the stream a byte
// belongs.
func liveFlood(conn net.Conn) {
	chunk := make([]byte, 128*251)
	for i := range chunk {
		chunk[i] = byte(i % 251)
	}
	for {
		if _, err := conn.Write(chunk); err != nil {
			return
		}
	}
}

// liveFlooded reads n bytes of a flood and checks them.
func liveFlooded(r io.Reader, n int) error {
	got := make([]byte, n)
	if _, err := io.ReadFull(r, got); err != nil {
		return fmt.Errorf("download of %d bytes: %w", n, err)
	}
	for i, b := range got {
		if b != byte(i%251) {
			return fmt.Errorf("download corrupted at byte %d", i)
		}
	}
	return nil
}

func liveUDPEcho(t *testing.T) M.Socksaddr {
	t.Helper()
	pc, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { pc.Close() })
	go func() {
		b := make([]byte, 2048)
		for {
			n, addr, err := pc.ReadFrom(b)
			if err != nil {
				return
			}
			_, _ = pc.WriteTo(b[:n], addr)
		}
	}()
	return M.ParseSocksaddrHostPort("127.0.0.1", uint16(pc.LocalAddr().(*net.UDPAddr).Port))
}

// liveDelay forwards to target and holds back the way from the server to the
// client by delay, it returns the port to connect to.
func liveDelay(t *testing.T, target string, delay time.Duration) int {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	type chunk struct {
		due  time.Time
		data []byte
	}
	liveServe(t, ln, func(client net.Conn) {
		server, err := net.Dial("tcp", target)
		if err != nil {
			return
		}
		defer server.Close()
		go func() {
			_, _ = io.Copy(server, client)
			server.Close()
		}()
		queue := make(chan chunk, 4096)
		go func() {
			defer close(queue)
			for {
				b := make([]byte, 32<<10)
				n, err := server.Read(b)
				if n > 0 {
					queue <- chunk{time.Now().Add(delay), b[:n]}
				}
				if err != nil {
					return
				}
			}
		}()
		for c := range queue {
			time.Sleep(time.Until(c.due))
			if _, err := client.Write(c.data); err != nil {
				return
			}
		}
	})
	return ln.Addr().(*net.TCPAddr).Port
}

// liveServer is a miux process.
type liveServer struct {
	miux, config string
	ports        []int
	cmd          *exec.Cmd
	out          bytes.Buffer
}

func (s *liveServer) start(t *testing.T) {
	t.Helper()
	s.cmd = exec.Command(s.miux, s.config)
	s.cmd.Stdout, s.cmd.Stderr = &s.out, &s.out
	if err := s.cmd.Start(); err != nil {
		t.Fatal(err)
	}
	testWait(t, "the server to listen", func() bool {
		for _, port := range s.ports {
			conn, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", port))
			if err != nil {
				return false
			}
			conn.Close()
		}
		return true
	})
	// A REALITY inbound holds back whoever connects while it is still probing
	// its dest, for five seconds: let that settle.
	time.Sleep(300 * time.Millisecond)
}

func (s *liveServer) stop() {
	if s.cmd != nil {
		_ = s.cmd.Process.Kill()
		_ = s.cmd.Wait()
		s.cmd = nil
	}
}

// liveStart runs miux with inbounds (JSON) listening on ports.
func liveStart(t *testing.T, miux string, ports []int, inbounds ...string) *liveServer {
	t.Helper()
	s := &liveServer{miux: miux, ports: ports, config: filepath.Join(t.TempDir(), "server.json")}
	config := fmt.Sprintf(`{"log":{"loglevel":"warning","access":"none"},"inbounds":[%s],"outbounds":[{"protocol":"freedom"}]}`, strings.Join(inbounds, ","))
	if err := os.WriteFile(s.config, []byte(config), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		s.stop()
		if t.Failed() {
			t.Logf("server output:\n%s", s.out.String())
		}
	})
	s.start(t)
	return s
}

// liveBlindDialer hides the socket, so the liveness peek sees nothing and a dead
// lane is only found out by the stream using it.
type liveBlindDialer struct{}

func (liveBlindDialer) DialContext(ctx context.Context, network string, destination M.Socksaddr) (net.Conn, error) {
	conn, err := N.SystemDialer.DialContext(ctx, network, destination)
	if err != nil {
		return nil, err
	}
	return struct{ net.Conn }{conn}, nil
}

func (liveBlindDialer) ListenPacket(ctx context.Context, destination M.Socksaddr) (net.PacketConn, error) {
	return N.SystemDialer.ListenPacket(ctx, destination)
}

func liveRandom(n int) []byte {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return b
}

func liveDial(t *testing.T, c *Client, destination M.Socksaddr) *Stream {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	conn, err := c.CreateProxy(ctx, destination)
	if err != nil {
		t.Fatalf("CreateProxy %s: %v", destination, err)
	}
	t.Cleanup(func() { conn.Close() })
	return conn.(*Stream)
}

func liveEchoOnce(conn net.Conn, payload []byte) error {
	go func() { _, _ = conn.Write(payload) }()
	got := make([]byte, len(payload))
	if _, err := io.ReadFull(conn, got); err != nil {
		return fmt.Errorf("echo of %d bytes: %w", len(payload), err)
	}
	if !bytes.Equal(got, payload) {
		return fmt.Errorf("echo of %d bytes came back corrupted", len(payload))
	}
	return nil
}

// liveEnd expects the downlink to be at its end, and closes the stream: the lane
// goes back to the pool.
func liveEnd(s *Stream) error {
	if n, err := s.Read(make([]byte, 16)); n != 0 || err != io.EOF {
		return fmt.Errorf("expected the end of the stream: %d %v", n, err)
	}
	return s.Close()
}

// livePlain runs one stream to an echo-N target: the payload both ways at once,
// then the target ends the downlink and Close ends the uplink.
func livePlain(c *Client, destination M.Socksaddr, payload []byte) (*lane, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	conn, err := c.CreateProxy(ctx, destination)
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	s := conn.(*Stream)
	_ = s.SetDeadline(time.Now().Add(60 * time.Second))
	go func() {
		if _, err := s.Write(binary.BigEndian.AppendUint32(nil, uint32(len(payload)))); err == nil {
			_, _ = s.Write(payload)
		}
	}()
	got := make([]byte, len(payload))
	if _, err = io.ReadFull(s, got); err != nil {
		return nil, fmt.Errorf("echo of %d bytes: %w", len(payload), err)
	}
	if !bytes.Equal(got, payload) {
		return nil, fmt.Errorf("echo of %d bytes came back corrupted", len(payload))
	}
	return s.lane(), liveEnd(s)
}

// liveInner runs one stream to the TLS 1.3 echo with a real handshake inside: its
// integrity check is the referee, a raw segment a byte off fails it. Then the
// inner connection is shut down properly, which ends both directions.
func liveInner(c *Client, destination M.Socksaddr, payload []byte) (*Stream, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	conn, err := c.CreateProxy(ctx, destination)
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	s := conn.(*Stream)
	_ = s.SetDeadline(time.Now().Add(60 * time.Second))
	tc := stdtls.Client(s, &stdtls.Config{InsecureSkipVerify: true, MinVersion: stdtls.VersionTLS13})
	if err = tc.Handshake(); err != nil {
		return nil, fmt.Errorf("inner TLS handshake: %w", err)
	}
	if err = liveEchoOnce(tc, payload); err != nil {
		return nil, err
	}
	// close_notify: the echo closes in return
	if err = tc.CloseWrite(); err != nil {
		return nil, err
	}
	if n, err := tc.Read(make([]byte, 16)); n != 0 || err != io.EOF {
		return nil, fmt.Errorf("expected the end of the inner connection: %d %v", n, err)
	}
	return s, liveEnd(s)
}

func TestLive(t *testing.T) {
	miux := os.Getenv("MIU_LIVE_MIUX")
	if miux == "" {
		t.Skip("MIU_LIVE_MIUX is not set")
	}

	certPEM, keyPEM, pair := liveCert(t)
	innerLn, err := stdtls.Listen("tcp", "127.0.0.1:0", &stdtls.Config{Certificates: []stdtls.Certificate{pair}, MinVersion: stdtls.VersionTLS13})
	if err != nil {
		t.Fatal(err)
	}
	listen := func() net.Listener {
		ln, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		return ln
	}
	floodLn, err := stdtls.Listen("tcp", "127.0.0.1:0", &stdtls.Config{Certificates: []stdtls.Certificate{pair}, MinVersion: stdtls.VersionTLS13})
	if err != nil {
		t.Fatal(err)
	}
	innerDst := liveServe(t, innerLn, liveEcho)
	innerFloodDst := liveServe(t, floodLn, liveFlood)
	floodDst := liveServe(t, listen(), liveFlood)
	echoDst := liveServe(t, listen(), liveEcho)
	echoNDst := liveServe(t, listen(), liveEchoN)
	udpDst := liveUDPEcho(t)
	blob := liveRandom(16 << 20)

	realityKey, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	realityConfig := &tlsC.RealityConfig{PublicKey: realityKey.PublicKey()}
	copy(realityConfig.ShortID[:], []byte{0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef})

	// one server, three inbounds: TLS, REALITY, and TLS dropping idle lanes after a second
	tlsPort, realityPort, impatientPort := liveFreePort(t), liveFreePort(t), liveFreePort(t)
	tlsSettings := fmt.Sprintf(`{"security":"tls","tlsSettings":{"certificates":[{"certificate":%s,"key":%s}]}}`,
		livePEMLines(certPEM), livePEMLines(keyPEM))
	tlsInbound := func(port int, settings string) string {
		return fmt.Sprintf(`{"listen":"127.0.0.1","port":%d,"protocol":"miu","settings":{"users":[{"psk":"%s","email":"u@test"}]%s},"streamSettings":%s}`,
			port, testPSK, settings, tlsSettings)
	}
	realityInbound := fmt.Sprintf(`{"listen":"127.0.0.1","port":%d,"protocol":"miu","settings":{"users":[{"psk":"%s","email":"r@test"}]},
		"streamSettings":{"security":"reality","realitySettings":{
		"dest":"127.0.0.1:%d","serverNames":["localhost"],"privateKey":"%s","shortIds":["0123456789abcdef"]}}}`,
		realityPort, testPSK, innerDst.Port, base64.RawURLEncoding.EncodeToString(realityKey.Bytes()))
	liveStart(t, miux, []int{tlsPort, realityPort, impatientPort},
		tlsInbound(tlsPort, ""), realityInbound, tlsInbound(impatientPort, `,"idleTimeout":1`))

	newClient := func(t *testing.T, port int, tlsConfig vmess.TLSConfig, config ClientConfig) (*Client, *testEvents) {
		t.Helper()
		tlsConfig.Host = "localhost"
		// the surrounding spaces must not end up in the token
		config.PSK = " " + testPSK + "\n"
		config.Server = M.ParseSocksaddrHostPort("127.0.0.1", uint16(port))
		config.TLSConfig = &tlsConfig
		if config.Dialer == nil {
			config.Dialer = N.SystemDialer
		}
		c, err := NewClient(context.Background(), config)
		if err != nil {
			t.Fatal(err)
		}
		events := &testEvents{m: map[string]int{}}
		c.observer = events.add
		t.Cleanup(func() { c.Close() })
		return c, events
	}
	// burst runs n streams at once.
	burst := func(t *testing.T, n int, run func(i int) error) {
		t.Helper()
		var wg sync.WaitGroup
		for i := 0; i < n; i++ {
			wg.Add(1)
			go func(i int) {
				defer wg.Done()
				if err := run(i); err != nil {
					t.Error(err)
				}
			}(i)
		}
		wg.Wait()
	}

	outers := []struct {
		name      string
		port      int
		tlsConfig vmess.TLSConfig
	}{
		{"tls", tlsPort, vmess.TLSConfig{SkipCertVerify: true}},
		{"utls", tlsPort, vmess.TLSConfig{SkipCertVerify: true, ClientFingerprint: "chrome"}},
		{"reality", realityPort, vmess.TLSConfig{ClientFingerprint: "chrome", Reality: realityConfig}},
	}
	for _, o := range outers {
		o := o
		t.Run(o.name, func(t *testing.T) {
			t.Parallel()

			// The inner data is not TLS: all of it stays inside the outer TLS.
			t.Run("plain", func(t *testing.T) {
				c, events := newClient(t, o.port, o.tlsConfig, ClientConfig{})
				c.minIdle = 0 // every dial counts here
				first, err := livePlain(c, echoNDst, []byte("hello miu"))
				if err != nil {
					t.Fatal(err)
				}
				if !first.canRaw {
					t.Fatalf("no way into the outer connection: %T", first.conn)
				}
				// megabytes both ways at once, then one stream after the other:
				// all of them on the one lane
				for i, payload := range [][]byte{blob, liveRandom(1000), liveRandom(1001), liveRandom(70000), {1}} {
					l, err := livePlain(c, echoNDst, payload)
					if err != nil {
						t.Fatal(err)
					}
					if l != first {
						t.Fatalf("stream %d did not reuse the lane", i)
					}
				}
				if events.count("lane:dial") != 1 || events.count("lane:reuse") != 5 {
					t.Fatalf("one stream at a time: dials=%d reuses=%d", events.count("lane:dial"), events.count("lane:reuse"))
				}

				// a burst dials what it needs, the streams after it reuse that
				burst(t, 8, func(i int) error {
					_, err := livePlain(c, echoNDst, liveRandom(64<<10+i))
					return err
				})
				dials, idle := events.count("lane:dial"), len(c.idleLanes())
				if dials < 2 || dials > 8 || idle != dials {
					t.Fatalf("after a burst of 8: dials=%d idle=%d", dials, idle)
				}
				burst(t, idle, func(i int) error {
					_, err := livePlain(c, echoNDst, liveRandom(3000+i))
					return err
				})
				for i := 0; i < 6; i++ {
					if _, err := livePlain(c, echoNDst, liveRandom(1000+i)); err != nil {
						t.Fatal(err)
					}
				}
				if events.count("lane:dial") != dials || len(c.idleLanes()) != idle {
					t.Fatalf("lanes dialed with idle ones at hand: dials=%d idle=%d", events.count("lane:dial")-dials, len(c.idleLanes()))
				}

				// half close through the real server: the uplink ends first, the
				// downlink follows when the server gives up on the target
				s := liveDial(t, c, echoDst)
				if err := liveEchoOnce(s, []byte("half close")); err != nil {
					t.Fatal(err)
				}
				start := time.Now()
				testFinish(t, s)
				t.Logf("END answered after %v", time.Since(start).Round(time.Millisecond))
				if len(c.idleLanes()) != idle {
					t.Fatal("the lane did not go back after a half close")
				}

				if events.count("raw:out") != 0 || events.count("raw:in") != 0 || events.count("replay") != 0 {
					t.Fatalf("inner data that is not TLS left the outer TLS: out=%d in=%d, replays=%d",
						events.count("raw:out"), events.count("raw:in"), events.count("replay"))
				}
			})

			// A real TLS 1.3 handshake inside: once it is through, both directions
			// go as raw segments.
			t.Run("inner", func(t *testing.T) {
				c, events := newClient(t, o.port, o.tlsConfig, ClientConfig{})
				c.minIdle = 0
				first, err := liveInner(c, innerDst, blob[:5<<20])
				if err != nil {
					t.Fatal(err)
				}
				out, in := events.count("raw:out"), events.count("raw:in")
				if !first.wentRaw() || out == 0 || in == 0 {
					t.Fatalf("inner TLS 1.3 data did not go as raw segments: out=%d in=%d", out, in)
				}
				t.Logf("5 MiB echoed in %d raw segments out, %d in", out, in)
				// stream after stream on the same outer connection: in and out
				// of raw segments again and again
				for i, n := range []int{1, 100, 16 << 10, 1 << 20, 3} {
					s, err := liveInner(c, innerDst, blob[i:i+n])
					if err != nil {
						t.Fatalf("stream %d: %v", i, err)
					}
					if s.lane() != first.lane() || !s.wentRaw() {
						t.Fatalf("stream %d: not on the same lane, or not raw", i)
					}
				}
				if events.count("lane:dial") != 1 {
					t.Fatalf("dials=%d", events.count("lane:dial"))
				}
				burst(t, 8, func(i int) error {
					_, err := liveInner(c, innerDst, liveRandom(256<<10+i))
					return err
				})
				// plain streams and inner TLS ones taking turns on the lanes
				for i := 0; i < 4; i++ {
					if _, err := livePlain(c, echoNDst, liveRandom(5000+i)); err != nil {
						t.Fatal(err)
					}
					if _, err := liveInner(c, innerDst, liveRandom(5000+i)); err != nil {
						t.Fatal(err)
					}
				}
				if events.count("replay") != 0 {
					t.Fatalf("replays=%d", events.count("replay"))
				}
			})

			t.Run("udp", func(t *testing.T) {
				c, events := newClient(t, o.port, o.tlsConfig, ClientConfig{})
				s := liveDial(t, c, uot.RequestDestination(uot.Version))
				packet := uot.NewLazyConn(s, uot.Request{Destination: udpDst})
				b := make([]byte, 2048)
				for i := 0; i < 5; i++ {
					msg := []byte(fmt.Sprintf("udp packet %d %s", i, strings.Repeat("x", 500+i)))
					if _, err := packet.WriteTo(msg, udpDst.UDPAddr()); err != nil {
						t.Fatal(err)
					}
					_ = s.SetReadDeadline(time.Now().Add(10 * time.Second))
					n, from, err := packet.ReadFrom(b)
					if err != nil || !bytes.Equal(b[:n], msg) {
						t.Fatalf("udp echo %d: %q %v", i, b[:n], err)
					}
					if from.String() != udpDst.String() {
						t.Fatalf("udp echo %d came from %s", i, from)
					}
				}
				if events.count("raw:out") != 0 || events.count("raw:in") != 0 {
					t.Fatal("UDP went as raw segments")
				}
			})

			// Idle lanes are kept for a while and no longer, Close takes them all.
			t.Run("pool", func(t *testing.T) {
				c, events := newClient(t, o.port, o.tlsConfig, ClientConfig{IdleSessionTimeout: 1500 * time.Millisecond})
				c.warmIdle = c.laneIdle // the two tiers have a test of their own
				// two streams in a row: lanes are prewarmed while the second one runs
				for i := 0; i < 2; i++ {
					if _, err := livePlain(c, echoNDst, []byte("warm up")); err != nil {
						t.Fatal(err)
					}
				}
				settled := func() []idleLane {
					var idle []idleLane
					testWait(t, "the prewarmed lanes", func() bool {
						c.mu.Lock()
						defer c.mu.Unlock()
						idle = append([]idleLane(nil), c.idle...)
						return c.pending == 0 && len(idle) >= defaultMinIdle
					})
					return idle
				}
				idle := settled()
				warm := map[*lane]bool{}
				for _, it := range idle {
					warm[it.l] = !it.l.used
				}
				if len(idle) != 1+defaultMinIdle || len(warm) != len(idle) || events.count("lane:dial") != len(idle) {
					t.Fatalf("idle=%d dials=%d", len(idle), events.count("lane:dial"))
				}
				// of the two lanes on top one at least is prewarmed: it carries a
				// stream with nothing read from it before
				held := liveDial(t, c, echoDst)
				l, err := livePlain(c, echoNDst, liveRandom(4000))
				if err != nil {
					t.Fatal(err)
				}
				if err = liveEchoOnce(held, liveRandom(4000)); err != nil {
					t.Fatal(err)
				}
				if !warm[l] && !warm[held.lane()] {
					t.Fatal("no stream ran on a prewarmed lane")
				}
				held.Close()

				// nobody uses them: closed when their time is up
				idle = settled()
				testWait(t, "the idle lanes to expire", func() bool { return len(c.idleLanes()) == 0 })
				for _, it := range idle {
					if !it.l.closed.Load() {
						t.Fatal("an expired lane should be closed")
					}
					raw := it.l.raw
					testWait(t, "the connection of an expired lane to be closed", func() bool {
						_ = raw.SetReadDeadline(time.Now().Add(20 * time.Millisecond))
						_, err := raw.Read(make([]byte, 64))
						return err != nil && !isTimeout(err)
					})
				}

				// Close closes what is in the pool
				dials := events.count("lane:dial")
				for i := 0; i < 2; i++ {
					if _, err := livePlain(c, echoNDst, []byte("again")); err != nil {
						t.Fatal(err)
					}
				}
				idle = settled()
				if events.count("lane:dial") != dials+len(idle) {
					t.Fatalf("idle=%d dials=%d", len(idle), events.count("lane:dial")-dials)
				}
				busy := liveDial(t, c, echoDst)
				c.Close()
				if len(c.idleLanes()) != 0 {
					t.Fatal("idle lanes after Close")
				}
				for _, it := range idle {
					if it.l != busy.lane() && !it.l.closed.Load() {
						t.Fatal("Close should close the idle lanes")
					}
				}
				// the lane of a stream under way is closed when the stream is
				busy.Close()
				testWait(t, "the lane of the last stream to be closed", func() bool { return busy.lane().closed.Load() })
			})

			// Streams the app walks away from: the server is told with RESET and
			// the lane carries the next stream, nothing is dialed for it.
			t.Run("abort", func(t *testing.T) {
				c, events := newClient(t, o.port, o.tlsConfig, ClientConfig{})
				c.minIdle = 0
				first, err := livePlain(c, echoNDst, []byte("the one lane"))
				if err != nil {
					t.Fatal(err)
				}
				// back waits for the lane to be idle again.
				back := func(what string) {
					t.Helper()
					testWait(t, "the lane to go back after "+what, func() bool { return len(c.idleLanes()) == 1 })
					if c.idleLanes()[0] != first || first.closed.Load() {
						t.Fatalf("after %s: another lane in the pool", what)
					}
				}
				aborts := 0
				abort := func(s *Stream, what string) {
					t.Helper()
					s.Close()
					aborts++
					back(what)
				}
				const rounds = 6

				// a download left half way, megabytes still coming: inner data
				// plain, then inner TLS 1.3 with the downlink in raw segments
				for i := 0; i < rounds; i++ {
					s := liveDial(t, c, floodDst)
					_ = s.SetDeadline(time.Now().Add(30 * time.Second))
					if err := liveFlooded(s, 2<<20); err != nil {
						t.Fatalf("round %d: %v", i, err)
					}
					abort(s, "a plain download")
				}
				if _, err := livePlain(c, echoNDst, liveRandom(100000)); err != nil {
					t.Fatal(err)
				}
				for i := 0; i < rounds; i++ {
					s := liveDial(t, c, innerFloodDst)
					_ = s.SetDeadline(time.Now().Add(30 * time.Second))
					tc := stdtls.Client(s, &stdtls.Config{InsecureSkipVerify: true, MinVersion: stdtls.VersionTLS13})
					if err := liveFlooded(tc, 2<<20); err != nil {
						t.Fatalf("round %d: %v", i, err)
					}
					abort(s, "a download through inner TLS")
				}
				if events.count("raw:in") == 0 {
					t.Fatal("the inner TLS 1.3 download did not come in raw segments")
				}
				if _, err := liveInner(c, innerDst, liveRandom(100000)); err != nil {
					t.Fatal(err)
				}

				// a probe: a request, the head of the answer, gone
				for i := 0; i < rounds; i++ {
					s := liveDial(t, c, floodDst)
					_ = s.SetDeadline(time.Now().Add(30 * time.Second))
					if _, err := s.Write([]byte("HEAD / HTTP/1.1\r\n\r\n")); err != nil {
						t.Fatal(err)
					}
					if err := liveFlooded(s, 200); err != nil {
						t.Fatalf("round %d: %v", i, err)
					}
					abort(s, "a probe")

					s = liveDial(t, c, echoDst)
					_ = s.SetDeadline(time.Now().Add(30 * time.Second))
					if err := liveEchoOnce(s, []byte("ping")); err != nil {
						t.Fatalf("round %d: %v", i, err)
					}
					abort(s, "an exchange with both directions open")
				}

				// the app half closes, and then leaves before the server is done
				start := time.Now()
				for i := 0; i < rounds; i++ {
					s := liveDial(t, c, echoDst)
					_ = s.SetDeadline(time.Now().Add(30 * time.Second))
					if err := liveEchoOnce(s, []byte("ping")); err != nil {
						t.Fatalf("round %d: %v", i, err)
					}
					if err := s.CloseWrite(); err != nil {
						t.Fatal(err)
					}
					abort(s, "END and RESET")
				}
				t.Logf("%d streams ended with END and RESET in %v", rounds, time.Since(start).Round(time.Millisecond))

				// a reader waiting when the stream is closed
				for i := 0; i < rounds; i++ {
					s := liveDial(t, c, echoDst)
					if err := liveEchoOnce(s, []byte("ping")); err != nil {
						t.Fatalf("round %d: %v", i, err)
					}
					reader := make(chan error, 1)
					go func() {
						_, err := s.Read(make([]byte, 16))
						reader <- err
					}()
					time.Sleep(10 * time.Millisecond)
					s.Close()
					if err := <-reader; err != io.ErrClosedPipe {
						t.Fatalf("read on a closed stream: %v", err)
					}
					aborts++
					back("a close with a reader waiting")
				}

				// closed before anything was sent
				for i := 0; i < rounds; i++ {
					s := liveDial(t, c, echoDst)
					s.timer.Stop()
					s.Close()
					back("a stream never opened")
				}

				// UDP sessions come and go
				for i := 0; i < rounds; i++ {
					s := liveDial(t, c, uot.RequestDestination(uot.Version))
					packet := uot.NewLazyConn(s, uot.Request{Destination: udpDst})
					b := make([]byte, 2048)
					for j := 0; j < 2; j++ {
						msg := []byte(fmt.Sprintf("udp session %d packet %d", i, j))
						if _, err := packet.WriteTo(msg, udpDst.UDPAddr()); err != nil {
							t.Fatal(err)
						}
						_ = s.SetReadDeadline(time.Now().Add(10 * time.Second))
						if n, _, err := packet.ReadFrom(b); err != nil || !bytes.Equal(b[:n], msg) {
							t.Fatalf("udp session %d: %q %v", i, b[:n], err)
						}
					}
					packet.Close()
					aborts++
					back("a UDP session")
				}

				// and the lane is still good for everything
				if l, err := livePlain(c, echoNDst, blob[:3<<20]); err != nil || l != first {
					t.Fatalf("after all the aborts: %v", err)
				}
				if s, err := liveInner(c, innerDst, blob[:3<<20]); err != nil || s.lane() != first {
					t.Fatalf("after all the aborts: %v", err)
				}
				t.Logf("%d aborted streams: dials=%d reuses=%d resets=%d", aborts+rounds, events.count("lane:dial"), events.count("lane:reuse"), events.count("reset"))
				if events.count("lane:dial") != 1 || events.count("reset") != aborts || events.count("replay") != 0 {
					t.Fatalf("aborted streams are burning lanes: dials=%d resets=%d of %d replays=%d",
						events.count("lane:dial"), events.count("reset"), aborts, events.count("replay"))
				}
			})
		})
	}

	// The server closes lanes it finds idle for a second, while this end would
	// keep them for 30: the next stream must not see any of that.
	t.Run("impatient", func(t *testing.T) {
		t.Parallel()
		for _, blind := range []bool{false, true} {
			config := ClientConfig{}
			if blind {
				config.Dialer = liveBlindDialer{}
			}
			c, events := newClient(t, impatientPort, vmess.TLSConfig{SkipCertVerify: true}, config)
			c.minIdle = 0
			for i := 0; i < 3; i++ {
				l, err := livePlain(c, echoNDst, liveRandom(2000))
				if err != nil {
					t.Fatalf("blind=%v, stream %d: %v", blind, i, err)
				}
				if l.peerIdle.Load() != 1 || c.ttl(l, 0) != warmLaneIdle {
					t.Fatalf("idle=%d ttl=%v", l.peerIdle.Load(), c.ttl(l, 0))
				}
				time.Sleep(2 * time.Second)
			}
			// seen by the peek and dialed anew, or else found out and replayed
			dials, replays := events.count("lane:dial"), events.count("replay")
			t.Logf("blind=%v: dials=%d reuses=%d replays=%d", blind, dials, events.count("lane:reuse"), replays)
			if blind && replays != 2 || !blind && peekWorks && replays != 0 || dials != 3 {
				t.Fatalf("blind=%v: dials=%d replays=%d", blind, dials, replays)
			}
		}
	})

	// The server goes away and comes back with lanes in the pool.
	t.Run("restart", func(t *testing.T) {
		t.Parallel()
		port := liveFreePort(t)
		server := liveStart(t, miux, []int{port}, tlsInbound(port, ""))
		seeing, _ := newClient(t, port, vmess.TLSConfig{SkipCertVerify: true}, ClientConfig{})
		blind, blindEvents := newClient(t, port, vmess.TLSConfig{SkipCertVerify: true}, ClientConfig{Dialer: liveBlindDialer{}})
		for _, c := range []*Client{seeing, blind} {
			c := c
			c.minIdle = 0
			burst(t, 3, func(i int) error {
				_, err := liveInner(c, innerDst, liveRandom(10000+i))
				return err
			})
			if len(c.idleLanes()) < 2 {
				t.Fatalf("%d idle lanes", len(c.idleLanes()))
			}
		}
		server.stop()
		server.start(t)
		for _, c := range []*Client{seeing, blind} {
			for i := 0; i < 4; i++ {
				if _, err := liveInner(c, innerDst, liveRandom(10000+i)); err != nil {
					t.Fatalf("stream %d after the restart: %v", i, err)
				}
				if _, err := livePlain(c, echoNDst, liveRandom(10000+i)); err != nil {
					t.Fatalf("stream %d after the restart: %v", i, err)
				}
			}
		}
		t.Logf("blind: %d replays", blindEvents.count("replay"))
		if blindEvents.count("replay") == 0 {
			t.Fatal("dead lanes nobody could see, yet no replay")
		}
	})

	// With the way back delayed: a stream on a warm lane starts without waiting
	// for anything, a cold one pays for the outer handshake.
	t.Run("delay", func(t *testing.T) {
		t.Parallel()
		const delay = 200 * time.Millisecond
		for _, o := range outers {
			var port int
			if o.name == "reality" {
				port = liveDelay(t, fmt.Sprintf("127.0.0.1:%d", realityPort), delay)
			} else {
				port = liveDelay(t, fmt.Sprintf("127.0.0.1:%d", tlsPort), delay)
			}
			c, _ := newClient(t, port, o.tlsConfig, ClientConfig{})
			c.minIdle = 0
			timed := func() (open, first time.Duration) {
				start := time.Now()
				s := liveDial(t, c, echoNDst)
				open = time.Since(start)
				if _, err := s.Write([]byte{0, 0, 0, 4, 'p', 'i', 'n', 'g'}); err != nil {
					t.Fatal(err)
				}
				got := make([]byte, 4)
				if _, err := io.ReadFull(s, got); err != nil || string(got) != "ping" {
					t.Fatalf("echo: %q %v", got, err)
				}
				first = time.Since(start)
				if err := liveEnd(s); err != nil {
					t.Fatal(err)
				}
				return
			}
			coldOpen, coldFirst := timed()
			warmOpen, warmFirst := timed()
			t.Logf("%s, way back delayed by %v: cold lane open %v, first byte %v; warm lane open %v, first byte %v", o.name, delay,
				coldOpen.Round(time.Millisecond), coldFirst.Round(time.Millisecond), warmOpen.Round(100*time.Microsecond), warmFirst.Round(time.Millisecond))
			if coldOpen < delay || coldFirst < 2*delay {
				t.Fatalf("%s: a cold lane without the handshake round trip?", o.name)
			}
			// no round trip to open, and one to the first byte
			if warmOpen > delay/4 || warmFirst < delay || warmFirst > 2*delay-delay/4 {
				t.Fatalf("%s: a stream on a warm lane should not wait for the server: open %v, first byte %v", o.name, warmOpen, warmFirst)
			}
		}
	})
}
