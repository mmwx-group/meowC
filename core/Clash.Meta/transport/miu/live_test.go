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
	"github.com/metacubex/mihomo/transport/vless/vision"
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

const livePSK = "c2VjcmV0LXNlY3JldC1zZWNyZXQtc2VjcmV0LTEyMzQ="

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

// liveEcho serves echo on ln and returns its port.
func liveEcho(t *testing.T, ln net.Listener) uint16 {
	t.Helper()
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go func() { defer conn.Close(); _, _ = io.Copy(conn, conn) }()
		}
	}()
	return uint16(ln.Addr().(*net.TCPAddr).Port)
}

// liveBulk serves one-way downloads of blob, the request is a mode byte ('D') and
// a length: it sends that much of blob.
func liveBulk(t *testing.T, blob []byte) uint16 {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				var head [5]byte
				if _, err := io.ReadFull(conn, head[:]); err != nil {
					return
				}
				n := int(binary.BigEndian.Uint32(head[1:]))
				if head[0] == 'D' {
					_, _ = conn.Write(blob[:n])
				}
				// leave closing to the client
				_, _ = io.Copy(io.Discard, conn)
			}()
		}
	}()
	return uint16(ln.Addr().(*net.TCPAddr).Port)
}

func liveBulkRequest(mode byte, n int) []byte {
	return binary.BigEndian.AppendUint32([]byte{mode}, uint32(n))
}

func liveDownload(t *testing.T, conn net.Conn, blob []byte) {
	t.Helper()
	if _, err := conn.Write(liveBulkRequest('D', len(blob))); err != nil {
		t.Fatal(err)
	}
	got := make([]byte, len(blob))
	_ = conn.SetReadDeadline(time.Now().Add(30 * time.Second))
	if _, err := io.ReadFull(conn, got); err != nil {
		t.Fatalf("download of %d bytes: %v", len(blob), err)
	}
	if !bytes.Equal(got, blob) {
		t.Fatalf("download of %d bytes came back corrupted", len(blob))
	}
}

// liveDelay forwards to target and holds back the way from the server to the
// client by delay, it returns the port to connect to.
func liveDelay(t *testing.T, target string, delay time.Duration) int {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	type chunk struct {
		due  time.Time
		data []byte
	}
	go func() {
		for {
			client, err := ln.Accept()
			if err != nil {
				return
			}
			go func() {
				defer client.Close()
				server, err := net.Dial("tcp", target)
				if err != nil {
					return
				}
				defer server.Close()
				go func() { _, _ = io.Copy(server, client) }()
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
			}()
		}
	}()
	return ln.Addr().(*net.TCPAddr).Port
}

func liveUDPEcho(t *testing.T) uint16 {
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
	return uint16(pc.LocalAddr().(*net.UDPAddr).Port)
}

func liveEchoOnce(conn net.Conn, payload []byte) error {
	go func() { _, _ = conn.Write(payload) }()
	got := make([]byte, len(payload))
	_ = conn.SetReadDeadline(time.Now().Add(30 * time.Second))
	if _, err := io.ReadFull(conn, got); err != nil {
		return fmt.Errorf("echo of %d bytes: %w", len(payload), err)
	}
	if !bytes.Equal(got, payload) {
		return fmt.Errorf("echo of %d bytes came back corrupted", len(payload))
	}
	return conn.SetReadDeadline(time.Time{})
}

func liveRoundTrip(t *testing.T, conn net.Conn, payload []byte) {
	t.Helper()
	if err := liveEchoOnce(conn, payload); err != nil {
		t.Fatal(err)
	}
}

// liveInnerTLS runs a real TLS 1.3 handshake through conn: its integrity check
// is the referee, Vision dropping or mangling a single byte fails it.
func liveInnerTLS(conn net.Conn) (*stdtls.Conn, error) {
	tc := stdtls.Client(conn, &stdtls.Config{InsecureSkipVerify: true, MinVersion: stdtls.VersionTLS13})
	_ = conn.SetDeadline(time.Now().Add(15 * time.Second))
	if err := tc.Handshake(); err != nil {
		return nil, fmt.Errorf("inner TLS handshake: %w", err)
	}
	return tc, conn.SetDeadline(time.Time{})
}

func liveTLSRoundTrip(t *testing.T, conn net.Conn, payload []byte) {
	t.Helper()
	tc, err := liveInnerTLS(conn)
	if err != nil {
		t.Fatal(err)
	}
	liveRoundTrip(t, tc, payload)
}

func liveRandom(n int) []byte {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return b
}

func liveWait(t *testing.T, timeout time.Duration, what string, cond func() bool) {
	t.Helper()
	for deadline := time.Now().Add(timeout); !cond(); time.Sleep(20 * time.Millisecond) {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
	}
}

func (p *visionSpares) snapshot() (ready []net.Conn, pending int) {
	p.mu.Lock()
	defer p.mu.Unlock()
	for _, sp := range p.ready {
		ready = append(ready, sp.conn)
	}
	return ready, p.pending
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
	plainLn, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	// the inner TLS echo stands in for port 443
	oldPort := visionPort
	visionPort = liveEcho(t, innerLn)
	t.Cleanup(func() { visionPort = oldPort })
	visionDst := M.ParseSocksaddrHostPort("127.0.0.1", visionPort)
	plainDst := M.ParseSocksaddrHostPort("127.0.0.1", liveEcho(t, plainLn))
	blob := liveRandom(16 << 20)
	bulkDst := M.ParseSocksaddrHostPort("127.0.0.1", liveBulk(t, blob))
	udpDst := M.ParseSocksaddrHostPort("127.0.0.1", liveUDPEcho(t))

	realityKey, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	realityConfig := &tlsC.RealityConfig{PublicKey: realityKey.PublicKey()}
	copy(realityConfig.ShortID[:], []byte{0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef})

	// one server, three inbounds: TLS with Vision, REALITY with Vision, TLS without
	tlsPort, realityPort, muxPort := liveFreePort(t), liveFreePort(t), liveFreePort(t)
	tlsSettings := fmt.Sprintf(`{"security":"tls","tlsSettings":{"certificates":[{"certificate":%s,"key":%s}]}}`,
		livePEMLines(certPEM), livePEMLines(keyPEM))
	config := fmt.Sprintf(`{
	  "inbounds":[
	    {"listen":"127.0.0.1","port":%d,"protocol":"miu",
	     "settings":{"users":[{"psk":"%s","email":"tls@test"}],"vision":true},"streamSettings":%s},
	    {"listen":"127.0.0.1","port":%d,"protocol":"miu",
	     "settings":{"users":[{"psk":"%s","email":"reality@test"}],"vision":true},
	     "streamSettings":{"security":"reality","realitySettings":{
	       "dest":"127.0.0.1:%d","serverNames":["localhost"],"privateKey":"%s","shortIds":["0123456789abcdef"]}}},
	    {"listen":"127.0.0.1","port":%d,"protocol":"miu",
	     "settings":{"users":[{"psk":"%s","email":"mux@test"}]},"streamSettings":%s}],
	  "outbounds":[{"protocol":"freedom"}]
	}`, tlsPort, livePSK, tlsSettings,
		realityPort, livePSK, visionPort, base64.RawURLEncoding.EncodeToString(realityKey.Bytes()),
		muxPort, livePSK, tlsSettings)
	configPath := filepath.Join(t.TempDir(), "server.json")
	if err = os.WriteFile(configPath, []byte(config), 0o600); err != nil {
		t.Fatal(err)
	}
	server := exec.Command(miux, configPath)
	server.Stderr = os.Stderr
	if err = server.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = server.Process.Kill()
		_ = server.Wait()
	})
	liveWait(t, 10*time.Second, "the server to listen", func() bool {
		conn, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", muxPort))
		if err != nil {
			return false
		}
		conn.Close()
		return true
	})

	newClient := func(t *testing.T, port int, tlsConfig vmess.TLSConfig, recvWindow int) *Client {
		t.Helper()
		tlsConfig.Host = "localhost"
		// the surrounding spaces must not end up in the token
		c, err := NewClient(context.Background(), ClientConfig{
			PSK:        " " + livePSK + "\n",
			Vision:     true,
			RecvWindow: recvWindow,
			Server:     M.ParseSocksaddrHostPort("127.0.0.1", uint16(port)),
			Dialer:     N.SystemDialer,
			TLSConfig:  &tlsConfig,
		})
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { c.Close() })
		return c
	}
	dial := func(t *testing.T, c *Client, destination M.Socksaddr) net.Conn {
		t.Helper()
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		conn, err := c.CreateProxy(ctx, destination)
		if err != nil {
			t.Fatalf("CreateProxy %s: %v", destination, err)
		}
		t.Cleanup(func() { conn.Close() })
		return conn
	}
	// outer returns the connection a Vision stream runs on.
	outer := func(t *testing.T, conn net.Conn) net.Conn {
		t.Helper()
		vc, ok := conn.(*vision.Conn)
		if !ok {
			t.Fatalf("expected a Vision connection, got %T", conn)
		}
		return vc.Conn.(*visionConn).Conn
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
			c := newClient(t, o.port, o.tlsConfig, 0)

			// the first stream does not know the server yet: it waits for ServerSettings
			first := dial(t, c, visionDst)
			outer(t, first)
			if !c.visionConfirmed.Load() {
				t.Fatal("the first Vision stream should confirm the server")
			}
			liveTLSRoundTrip(t, first, []byte("hello-vision"))

			// the second one goes out in one flight, megabytes through the direct path
			if ready, pending := c.spares.snapshot(); len(ready) != 0 || pending != 0 {
				t.Fatalf("no spares expected after a single dial: ready=%d pending=%d", len(ready), pending)
			}
			second := dial(t, c, visionDst)
			outer(t, second)
			liveTLSRoundTrip(t, second, liveRandom(4<<20))

			// two streams in a row: the pool fills up and the third one takes a spare
			var spares []net.Conn
			liveWait(t, 10*time.Second, "the spare connections", func() bool {
				spares, _ = c.spares.snapshot()
				return len(spares) == visionSpareMax
			})
			third := dial(t, c, visionDst)
			if conn := outer(t, third); conn != spares[0] && conn != spares[1] {
				t.Fatal("the third Vision stream should run on a spare connection")
			}
			liveTLSRoundTrip(t, third, []byte("via-spare"))

			// a burst: whoever finds no spare dials as usual, all of them must work
			var burst sync.WaitGroup
			for i := 0; i < 8; i++ {
				burst.Add(1)
				go func() {
					defer burst.Done()
					conn, err := c.CreateProxy(context.Background(), visionDst)
					if err != nil {
						t.Error(err)
						return
					}
					defer conn.Close()
					tc, err := liveInnerTLS(conn)
					if err == nil {
						err = liveEchoOnce(tc, liveRandom(64<<10))
					}
					if err != nil {
						t.Error(err)
					}
				}()
			}
			burst.Wait()

			// any other port and all of UDP stay in MUX
			plain := dial(t, c, plainDst)
			stream, ok := plain.(*Stream)
			if !ok {
				t.Fatalf("expected a MUX stream, got %T", plain)
			}
			liveRoundTrip(t, plain, liveRandom(64<<10))
			if stream.sess.rtt.Load() <= 0 {
				t.Fatal("no round trip time measured from ServerSettings")
			}
			// megabytes both ways at once: the upload waits for the download
			liveRoundTrip(t, dial(t, c, plainDst), blob)
			udp, err := c.CreateStream(context.Background(), uot.RequestDestination(2))
			if err != nil {
				t.Fatal(err)
			}
			defer udp.Close()
			packet := uot.NewLazyConn(udp, uot.Request{Destination: udpDst})
			if _, err = packet.WriteTo([]byte("hello-udp"), udpDst.UDPAddr()); err != nil {
				t.Fatal(err)
			}
			b := make([]byte, 64)
			_ = udp.SetReadDeadline(time.Now().Add(10 * time.Second))
			if n, _, err := packet.ReadFrom(b); err != nil || string(b[:n]) != "hello-udp" {
				t.Fatalf("udp echo: %q %v", b[:n], err)
			}

			// spares nobody uses are closed after the TTL
			liveWait(t, 10*time.Second, "the spares dialed by the burst", func() bool {
				ready, pending := c.spares.snapshot()
				spares = ready
				return len(ready) > 0 && pending == 0
			})
			liveWait(t, visionSpareTTL+5*time.Second, "the spares to expire", func() bool {
				ready, _ := c.spares.snapshot()
				return len(ready) == 0
			})
			_ = spares[0].SetReadDeadline(time.Now().Add(time.Second))
			if _, err = spares[0].Read(b); err == nil || os.IsTimeout(err) {
				t.Fatalf("an expired spare should be closed: %v", err)
			}

			// Close takes the spares along
			dial(t, c, visionDst)
			dial(t, c, visionDst)
			liveWait(t, 10*time.Second, "the spare connections", func() bool {
				spares, _ = c.spares.snapshot()
				return len(spares) == visionSpareMax
			})
			c.Close()
			if ready, _ := c.spares.snapshot(); len(ready) != 0 {
				t.Fatal("Close should drop the spares")
			}
			_ = spares[0].SetReadDeadline(time.Now().Add(time.Second))
			if _, err = spares[0].Read(b); err == nil || os.IsTimeout(err) {
				t.Fatalf("Close should close the spares: %v", err)
			}
		})
	}

	// A window far too small for a path with a real round trip time: it has to grow,
	// and the server has to take returns larger than what was consumed.
	t.Run("window", func(t *testing.T) {
		t.Parallel()
		const delay = 50 * time.Millisecond
		port := liveDelay(t, fmt.Sprintf("127.0.0.1:%d", tlsPort), delay)
		c := newClient(t, port, vmess.TLSConfig{SkipCertVerify: true}, minRecvWindow)
		stream := dial(t, c, bulkDst).(*Stream)
		start := time.Now()
		liveDownload(t, stream, blob)
		stream.recvWin.mu.Lock()
		size := stream.recvWin.size
		stream.recvWin.mu.Unlock()
		rtt := time.Duration(stream.sess.rtt.Load())
		t.Logf("%d bytes in %v, rtt %v, receive window %d -> %d", len(blob), time.Since(start).Round(time.Millisecond), rtt.Round(time.Millisecond), minRecvWindow, size)
		if rtt < delay || rtt > 4*delay {
			t.Fatalf("round trip time on a path delayed by %v: %v", delay, rtt)
		}
		if size <= minRecvWindow || size > autoRecvWindowMax {
			t.Fatalf("receive window after %d bytes: %d", len(blob), size)
		}
	})

	// the server does not grant Vision: found out by the first stream, MUX from then on
	t.Run("refused", func(t *testing.T) {
		t.Parallel()
		c := newClient(t, muxPort, vmess.TLSConfig{SkipCertVerify: true}, 0)
		for i := 0; i < 2; i++ {
			conn := dial(t, c, visionDst)
			if _, ok := conn.(*Stream); !ok {
				t.Fatalf("expected the MUX fallback, got %T", conn)
			}
			liveTLSRoundTrip(t, conn, liveRandom(1<<20))
		}
		if !c.visionRefused.Load() || c.visionConfirmed.Load() {
			t.Fatal("the refusal should be remembered")
		}
	})

	// the server turned Vision off after granting it: the stream sent blindly fails,
	// the next ones use MUX
	t.Run("revoked", func(t *testing.T) {
		t.Parallel()
		c := newClient(t, muxPort, vmess.TLSConfig{SkipCertVerify: true}, 0)
		c.visionConfirmed.Store(true)
		conn := dial(t, c, visionDst)
		outer(t, conn)
		_, _ = conn.Write([]byte("lost"))
		_ = conn.SetReadDeadline(time.Now().Add(10 * time.Second))
		if _, err := conn.Read(make([]byte, 16)); err == nil || os.IsTimeout(err) {
			t.Fatalf("the blind Vision stream should fail: %v", err)
		}
		if !c.visionRefused.Load() || c.visionConfirmed.Load() {
			t.Fatal("the refusal should be remembered")
		}
		conn = dial(t, c, visionDst)
		if _, ok := conn.(*Stream); !ok {
			t.Fatalf("expected the MUX fallback, got %T", conn)
		}
		liveTLSRoundTrip(t, conn, []byte("after-revoke"))
	})
}
