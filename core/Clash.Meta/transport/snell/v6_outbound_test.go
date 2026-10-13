package snell_test

import (
	"bytes"
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"os"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/metacubex/mihomo/adapter"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/transport/snell"

	"github.com/metacubex/sing/common"
	"github.com/metacubex/sing/common/network"
)

// countingDialer dials directly and counts the connections to the server.
type countingDialer struct {
	dials atomic.Int32
}

func (d *countingDialer) DialContext(ctx context.Context, network, address string) (net.Conn, error) {
	d.dials.Add(1)
	var dialer net.Dialer
	return dialer.DialContext(ctx, network, address)
}

func (d *countingDialer) ListenPacket(context.Context, string, string, netip.AddrPort) (net.PacketConn, error) {
	return nil, errors.New("not supported")
}

// newSnellProxy builds the outbound the way a configuration file does.
func newSnellProxy(t testing.TB, address string, psk string, extra map[string]any) (C.Proxy, *countingDialer, error) {
	host, port, err := net.SplitHostPort(address)
	if err != nil {
		t.Fatal(err)
	}
	portNumber, err := strconv.Atoi(port)
	if err != nil {
		t.Fatal(err)
	}
	mapping := map[string]any{
		"name":   "snell-test",
		"type":   "snell",
		"server": host,
		"port":   portNumber,
		"psk":    psk,
	}
	for key, value := range extra {
		mapping[key] = value
	}
	dialer := new(countingDialer)
	proxy, err := adapter.ParseProxy(mapping, adapter.WithDialerForAPI(dialer))
	if err != nil {
		return nil, nil, err
	}
	t.Cleanup(func() {
		_ = proxy.Close()
	})
	return proxy, dialer, nil
}

func TestSnellV6OutboundOptions(t *testing.T) {
	const address = "127.0.0.1:1"
	for _, mode := range []any{nil, "", "default", "unshaped", "unsafe-raw"} {
		extra := map[string]any{"version": 6, "udp": true, "reuse": true}
		if mode != nil {
			extra["mode"] = mode
		}
		proxy, _, err := newSnellProxy(t, address, "psk", extra)
		if err != nil {
			t.Fatalf("mode %v: %v", mode, err)
		}
		if !proxy.SupportUDP() {
			t.Fatalf("mode %v: version 6 must support UDP", mode)
		}
	}
	proxy, _, err := newSnellProxy(t, address, "psk", map[string]any{"version": 6})
	if err != nil {
		t.Fatal(err)
	}
	if proxy.SupportUDP() {
		t.Fatal("UDP must stay off unless it is enabled")
	}
	// Version 6 has no obfs layer: obfs-opts is ignored, whatever it holds.
	for name, opts := range map[string]map[string]any{
		"empty":      {},
		"mode":       {"mode": "http"},
		"host":       {"host": "bing.com"},
		"shadow-tls": {"mode": "shadow-tls", "password": "x"},
	} {
		if _, _, err = newSnellProxy(t, address, "psk", map[string]any{"version": 6, "obfs-opts": opts}); err != nil {
			t.Fatalf("obfs-opts (%s) on version 6 must be ignored, got %v", name, err)
		}
	}

	for name, c := range map[string]struct {
		extra map[string]any
		want  string
	}{
		"unknown mode":       {map[string]any{"version": 6, "mode": "shaped"}, "unknown v6 mode"},
		"mode is exact":      {map[string]any{"version": 6, "mode": "Unshaped"}, "unknown v6 mode"},
		"unknown version":    {map[string]any{"version": 7}, "snell version error"},
		"version 7 and mode": {map[string]any{"version": 7, "mode": "default"}, "snell version error"},
	} {
		if _, _, err := newSnellProxy(t, address, "psk", c.extra); err == nil || !strings.Contains(err.Error(), c.want) {
			t.Fatalf("%s: got %v, want an error about %q", name, err, c.want)
		}
	}
	if _, _, err := newSnellProxy(t, address, "", map[string]any{"version": 6}); err == nil {
		t.Fatal("version 6 without a psk must be rejected")
	}

	// Earlier versions are unchanged: they accept obfs-opts and do not look at mode.
	for _, extra := range []map[string]any{
		{"version": 4, "mode": "shaped"},
		{"version": 5, "mode": "unshaped", "reuse": true, "udp": true},
		{"version": 4, "obfs-opts": map[string]any{"mode": "http", "host": "bing.com"}},
		{"version": 3, "udp": true},
		{"version": 2},
		{},
	} {
		if _, _, err := newSnellProxy(t, address, "psk", extra); err != nil {
			t.Fatalf("%v: %v", extra, err)
		}
	}
	if _, _, err := newSnellProxy(t, address, "psk", map[string]any{"version": 1, "udp": true}); err == nil {
		t.Fatal("version 1 with UDP must still be rejected")
	}
}

func closeWrite(t testing.TB, conn net.Conn) {
	// The lookup the relay uses to half-close a connection.
	writeCloser, ok := common.Cast[network.WriteCloser](conn)
	if !ok {
		t.Fatal("the connection does not expose CloseWrite")
	}
	if err := writeCloser.CloseWrite(); err != nil {
		t.Fatal(err)
	}
}

// TestSnellV6Outbound drives the outbound against the in-process peer: TCP
// with and without reuse, and UDP, in every mode.
func TestSnellV6Outbound(t *testing.T) {
	for _, mode := range []string{"default", "unshaped", "unsafe-raw"} {
		mode := mode
		t.Run(mode, func(t *testing.T) {
			address, psk, connections := snell.StartV6TestServer(t, mode)
			ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
			defer cancel()

			request := func(proxy C.Proxy, index int) {
				conn, err := proxy.DialContext(ctx, &C.Metadata{NetWork: C.TCP, Host: "echo", DstPort: 80})
				if err != nil {
					t.Fatal(err)
				}
				defer conn.Close()
				payload := bytes.Repeat([]byte{byte('a' + index)}, 20000+index*7000)
				go conn.Write(payload)
				got := make([]byte, len(payload))
				if _, err := io.ReadFull(conn, got); err != nil || !bytes.Equal(got, payload) {
					t.Fatalf("request %d: echo mismatch, %v", index, err)
				}
				closeWrite(t, conn)
				if n, err := conn.Read(got); n != 0 || err != io.EOF {
					t.Fatalf("request %d: expected EOF, got %d bytes, %v", index, n, err)
				}
			}

			const requests = 5
			proxy, dialer, err := newSnellProxy(t, address, psk, map[string]any{"version": 6, "mode": mode})
			if err != nil {
				t.Fatal(err)
			}
			for index := 0; index < requests; index++ {
				request(proxy, index)
			}
			if dialer.dials.Load() != requests {
				t.Fatalf("without reuse: %d dials for %d requests", dialer.dials.Load(), requests)
			}
			withoutReuse := connections()

			proxy, dialer, err = newSnellProxy(t, address, psk, map[string]any{"version": 6, "mode": mode, "reuse": true, "udp": true})
			if err != nil {
				t.Fatal(err)
			}
			for index := 0; index < requests; index++ {
				request(proxy, index)
			}
			if dialer.dials.Load() != 1 || connections()-withoutReuse != 1 {
				t.Fatalf("with reuse: %d dials and %d server connections for %d requests, want 1",
					dialer.dials.Load(), connections()-withoutReuse, requests)
			}

			// A download that the client reads to the end and then closes.
			conn, err := proxy.DialContext(ctx, &C.Metadata{NetWork: C.TCP, Host: "source", DstPort: 2048})
			if err != nil {
				t.Fatal(err)
			}
			got, err := io.ReadAll(conn)
			if err != nil || !bytes.Equal(got, snell.V6TestPattern(2048*1024)) {
				t.Fatalf("download: %d bytes, %v", len(got), err)
			}
			_ = conn.Close()
			request(proxy, 0)
			if dialer.dials.Load() != 1 {
				t.Fatalf("with reuse: %d dials after the download, want 1", dialer.dials.Load())
			}

			// UDP uses a connection of its own.
			target := netip.MustParseAddrPort("192.0.2.7:5353")
			pc, err := proxy.ListenPacketContext(ctx, &C.Metadata{NetWork: C.UDP, DstIP: target.Addr(), DstPort: target.Port()})
			if err != nil {
				t.Fatal(err)
			}
			defer pc.Close()
			buf := make([]byte, 65536)
			for _, size := range []int{1, 1200, 9000} {
				payload := bytes.Repeat([]byte{byte(size)}, size)
				if _, err := pc.WriteTo(payload, net.UDPAddrFromAddrPort(target)); err != nil {
					t.Fatal(err)
				}
				_ = pc.SetReadDeadline(time.Now().Add(10 * time.Second))
				n, from, err := pc.ReadFrom(buf)
				if err != nil || !bytes.Equal(buf[:n], payload) || from.String() != target.String() {
					t.Fatalf("datagram of %d bytes: got %d bytes from %v, %v", size, n, from, err)
				}
			}
			if dialer.dials.Load() != 2 {
				t.Fatalf("%d dials after the UDP tunnel, want 2", dialer.dials.Load())
			}
		})
	}
}

// Live interoperability test against a real server. It is skipped unless
// SNELL_LIVE names the server host, for example:
//
//	SNELL_LIVE=127.0.0.1 go test ./transport/snell/ -run TestSnellLive -v
//
// The server is expected to listen on one port per case and to be able to
// reach the targets below. Everything has a default and can be overridden:
//
//	SNELL_LIVE_PSK        pre-shared key (snell-lab-psk-0123456789abcdef)
//	SNELL_LIVE_V6_PORTS   ports of the v6 default, unshaped and unsafe-raw
//	                      servers (24805,24806,24807); 0 skips a mode
//	SNELL_LIVE_V4_PORT    port of a v4 server, regression (24801); 0 skips
//	SNELL_LIVE_V5_PORT    port of a v5 server, regression (24804); 0 skips
//	SNELL_LIVE_HTTP       HTTP target (127.0.0.1:28180): GET /hello answers
//	                      "snell-lab-ok\n", GET /blob answers 8 MiB made of one
//	                      repeated 1 MiB block, POST answers the number of
//	                      bytes it received
//	SNELL_LIVE_UDP        UDP echo target (127.0.0.1:28153)
//	SNELL_LIVE_REUSE      "require" fails the test when sequential requests
//	                      with reuse do not share one server connection. By
//	                      default the number of connections is only logged,
//	                      because a server may close the connection after
//	                      every request, which rules reuse out.
func TestSnellLive(t *testing.T) {
	host := os.Getenv("SNELL_LIVE")
	if host == "" {
		t.Skip("set SNELL_LIVE=<server host> to run the live test")
	}
	env := func(key, fallback string) string {
		if value := os.Getenv(key); value != "" {
			return value
		}
		return fallback
	}
	psk := env("SNELL_LIVE_PSK", "snell-lab-psk-0123456789abcdef")
	httpTarget := env("SNELL_LIVE_HTTP", "127.0.0.1:28180")
	udpTarget := netip.MustParseAddrPort(env("SNELL_LIVE_UDP", "127.0.0.1:28153"))
	requireReuse := os.Getenv("SNELL_LIVE_REUSE") == "require"
	v6Ports := strings.Split(env("SNELL_LIVE_V6_PORTS", "24805,24806,24807"), ",")
	if len(v6Ports) != 3 {
		t.Fatal("SNELL_LIVE_V6_PORTS needs three ports: default, unshaped, unsafe-raw")
	}

	type liveCase struct {
		name    string
		port    string
		options map[string]any
	}
	cases := []liveCase{
		{"v6-default", v6Ports[0], map[string]any{"version": 6, "mode": "default"}},
		{"v6-unshaped", v6Ports[1], map[string]any{"version": 6, "mode": "unshaped"}},
		{"v6-unsafe-raw", v6Ports[2], map[string]any{"version": 6, "mode": "unsafe-raw"}},
		{"v4", env("SNELL_LIVE_V4_PORT", "24801"), map[string]any{"version": 4}},
		{"v5", env("SNELL_LIVE_V5_PORT", "24804"), map[string]any{"version": 5}},
	}
	for _, c := range cases {
		c := c
		t.Run(c.name, func(t *testing.T) {
			if strings.TrimSpace(c.port) == "0" {
				t.Skip("no port configured")
			}
			address := net.JoinHostPort(host, strings.TrimSpace(c.port))
			proxyWith := func(extra map[string]any) (C.Proxy, *countingDialer) {
				options := map[string]any{}
				for key, value := range c.options {
					options[key] = value
				}
				for key, value := range extra {
					options[key] = value
				}
				proxy, dialer, err := newSnellProxy(t, address, psk, options)
				if err != nil {
					t.Fatal(err)
				}
				return proxy, dialer
			}
			// Every HTTP request opens a proxied connection of its own unless
			// keepAlive is set, so the dial counter shows what the outbound
			// does with the server connections.
			clientFor := func(proxy C.Proxy, keepAlive bool) *http.Client {
				transport := &http.Transport{
					DisableKeepAlives: !keepAlive,
					DialContext: func(ctx context.Context, _ string, target string) (net.Conn, error) {
						metadata := &C.Metadata{NetWork: C.TCP}
						if err := metadata.SetRemoteAddress(target); err != nil {
							return nil, err
						}
						return proxy.DialContext(ctx, metadata)
					},
				}
				t.Cleanup(transport.CloseIdleConnections)
				return &http.Client{Transport: transport, Timeout: 60 * time.Second}
			}
			get := func(client *http.Client, path string) []byte {
				t.Helper()
				response, err := client.Get("http://" + httpTarget + path)
				if err != nil {
					t.Fatalf("GET %s: %v", path, err)
				}
				defer response.Body.Close()
				body, err := io.ReadAll(response.Body)
				if err != nil {
					t.Fatalf("GET %s: read body: %v", path, err)
				}
				if response.StatusCode != http.StatusOK {
					t.Fatalf("GET %s: status %d", path, response.StatusCode)
				}
				if response.ContentLength != int64(len(body)) {
					t.Fatalf("GET %s: content length %d, got %d bytes", path, response.ContentLength, len(body))
				}
				return body
			}

			proxy, dialer := proxyWith(nil)
			client := clientFor(proxy, false)

			if body := get(client, "/hello"); string(body) != "snell-lab-ok\n" {
				t.Fatalf("GET /hello: %q", body)
			}
			t.Logf("GET /hello ok")

			const blockSize = 1 << 20
			started := time.Now()
			blob := get(client, "/blob")
			if len(blob) != 8*blockSize {
				t.Fatalf("GET /blob: %d bytes, want %d", len(blob), 8*blockSize)
			}
			for block := 1; block < 8; block++ {
				if !bytes.Equal(blob[:blockSize], blob[block*blockSize:(block+1)*blockSize]) {
					t.Fatalf("GET /blob: block %d is damaged", block)
				}
			}
			t.Logf("GET /blob ok: %d bytes, content length and all 8 blocks match, %v", len(blob), time.Since(started).Round(time.Millisecond))

			upload := make([]byte, 3*blockSize+12345)
			if _, err := rand.Read(upload); err != nil {
				t.Fatal(err)
			}
			started = time.Now()
			response, err := client.Post("http://"+httpTarget+"/upload", "application/octet-stream", bytes.NewReader(upload))
			if err != nil {
				t.Fatalf("POST /upload: %v", err)
			}
			body, err := io.ReadAll(response.Body)
			_ = response.Body.Close()
			if err != nil || string(body) != strconv.Itoa(len(upload)) {
				t.Fatalf("POST /upload: server counted %q, sent %d, %v", body, len(upload), err)
			}
			t.Logf("POST /upload ok: %d bytes, %v", len(upload), time.Since(started).Round(time.Millisecond))
			if dialer.dials.Load() != 3 {
				t.Fatalf("without reuse: %d dials for 3 requests", dialer.dials.Load())
			}

			// Sequential requests with reuse. The HTTP client closes a
			// connection as soon as it has the whole body, which is before
			// the server's zero chunk arrives; the server connection can be
			// taken again once it did, hence the pause between the requests.
			const requests = 6
			const settle = 200 * time.Millisecond
			proxy, dialer = proxyWith(map[string]any{"reuse": true})
			client = clientFor(proxy, false)
			for index := 0; index < requests; index++ {
				path := "/hello"
				if index == requests/2 {
					path = "/blob"
				}
				if body := get(client, path); path == "/hello" && string(body) != "snell-lab-ok\n" {
					t.Fatalf("request %d with reuse: %q", index, body)
				}
				time.Sleep(settle)
			}
			sequential := dialer.dials.Load()

			// A keep-alive connection that the client closes while a read is
			// pending, followed by one more request.
			client = clientFor(proxy, true)
			get(client, "/hello")
			client.CloseIdleConnections()
			time.Sleep(settle)
			get(clientFor(proxy, false), "/hello")
			afterClientClose := dialer.dials.Load() - sequential

			reused := sequential == 1 && afterClientClose == 0
			t.Logf("reuse: %d sequential requests used %d server connection(s); a client-closed keep-alive connection and the request after it used %d more; reused=%v",
				requests, sequential, afterClientClose, reused)
			if requireReuse && !reused {
				t.Fatalf("the server connection was not reused")
			}

			// UDP.
			proxy, dialer = proxyWith(map[string]any{"udp": true})
			if !proxy.SupportUDP() {
				t.Fatal("UDP is not supported")
			}
			ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
			defer cancel()
			pc, err := proxy.ListenPacketContext(ctx, &C.Metadata{NetWork: C.UDP, DstIP: udpTarget.Addr(), DstPort: udpTarget.Port()})
			if err != nil {
				t.Fatalf("UDP tunnel: %v", err)
			}
			defer pc.Close()
			buf := make([]byte, 65536)
			var sizes []string
			for _, size := range []int{1, 1200, 8000} {
				payload := make([]byte, size)
				if _, err := rand.Read(payload); err != nil {
					t.Fatal(err)
				}
				if _, err := pc.WriteTo(payload, net.UDPAddrFromAddrPort(udpTarget)); err != nil {
					t.Fatalf("UDP write of %d bytes: %v", size, err)
				}
				_ = pc.SetReadDeadline(time.Now().Add(10 * time.Second))
				n, from, err := pc.ReadFrom(buf)
				if err != nil {
					t.Fatalf("UDP read of %d bytes: %v", size, err)
				}
				if !bytes.Equal(buf[:n], payload) {
					t.Fatalf("UDP echo of %d bytes came back as %d bytes", size, n)
				}
				if from.String() != udpTarget.String() {
					t.Fatalf("UDP echo from %v, want %v", from, udpTarget)
				}
				sizes = append(sizes, strconv.Itoa(size))
			}
			t.Logf("UDP echo ok: datagrams of %s bytes via %s", strings.Join(sizes, ", "), fmt.Sprint(udpTarget))
			if dialer.dials.Load() != 1 {
				t.Fatalf("UDP tunnel: %d dials, want 1", dialer.dials.Load())
			}
		})
	}
}
