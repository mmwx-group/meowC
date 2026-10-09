package outbound

import (
	"bufio"
	"context"
	"crypto/ecdh"
	"crypto/rand"
	"encoding/base64"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	C "github.com/metacubex/mihomo/constant"
)

// MeowX: AnyTLS over REALITY (reality-opts). Upstream mihomo has no REALITY for AnyTLS.

func testRealityPublicKey(t *testing.T) string {
	key, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return base64.RawURLEncoding.EncodeToString(key.PublicKey().Bytes())
}

func TestNewAnyTLSReality(t *testing.T) {
	option := AnyTLSOption{
		Name:              "test",
		Server:            "1.2.3.4",
		Port:              443,
		Password:          "test",
		SNI:               "www.example.com",
		ClientFingerprint: "chrome",
		RealityOpts:       RealityOptions{PublicKey: testRealityPublicKey(t), ShortID: "0123456789abcdef"},
	}
	if _, err := NewAnyTLS(option); err != nil {
		t.Fatalf("anytls with reality-opts: %v", err)
	}

	invalid := option
	invalid.RealityOpts.PublicKey = "not-a-key"
	if _, err := NewAnyTLS(invalid); err == nil {
		t.Fatal("an invalid REALITY public key must be rejected")
	}

	exclusive := option
	exclusive.ShadowTLSOpts = ShadowTLSOptions{Password: "test", Version: 3}
	if _, err := NewAnyTLS(exclusive); err == nil || !strings.Contains(err.Error(), "mutually exclusive") {
		t.Fatalf("REALITY together with ShadowTLS must be rejected, got %v", err)
	}
}

// Live check against a real AnyTLS + REALITY inbound. Skipped unless ANYTLS_REALITY_LIVE=host:port is set, with
// ANYTLS_REALITY_PASSWORD / ANYTLS_REALITY_PBK / ANYTLS_REALITY_SID / ANYTLS_REALITY_SNI describing the inbound.
func TestAnyTLSRealityLive(t *testing.T) {
	addr := os.Getenv("ANYTLS_REALITY_LIVE")
	if addr == "" {
		t.Skip("ANYTLS_REALITY_LIVE not set")
	}
	host, portText, err := net.SplitHostPort(addr)
	if err != nil {
		t.Fatal(err)
	}
	port, _ := strconv.Atoi(portText)
	outbound, err := NewAnyTLS(AnyTLSOption{
		Name:              "live",
		Server:            host,
		Port:              port,
		Password:          os.Getenv("ANYTLS_REALITY_PASSWORD"),
		SNI:               os.Getenv("ANYTLS_REALITY_SNI"),
		ClientFingerprint: "chrome",
		RealityOpts:       RealityOptions{PublicKey: os.Getenv("ANYTLS_REALITY_PBK"), ShortID: os.Getenv("ANYTLS_REALITY_SID")},
	})
	if err != nil {
		t.Fatal(err)
	}
	defer outbound.Close()

	get := func() {
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		conn, err := outbound.DialContext(ctx, &C.Metadata{NetWork: C.TCP, Host: "cp.cloudflare.com", DstPort: 80})
		if err != nil {
			t.Fatalf("dial: %v", err)
		}
		defer conn.Close()
		_ = conn.SetDeadline(time.Now().Add(15 * time.Second))
		if _, err = conn.Write([]byte("GET /generate_204 HTTP/1.1\r\nHost: cp.cloudflare.com\r\nConnection: close\r\n\r\n")); err != nil {
			t.Fatalf("write: %v", err)
		}
		resp, err := http.ReadResponse(bufio.NewReader(conn), nil)
		if err != nil {
			t.Fatalf("read: %v", err)
		}
		_ = resp.Body.Close()
		if resp.StatusCode != http.StatusNoContent {
			t.Fatalf("status %d, want 204", resp.StatusCode)
		}
	}
	// Twice: the second request rides the session the first one left idle.
	get()
	get()
}
