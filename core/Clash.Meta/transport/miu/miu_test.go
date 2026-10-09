package miu

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"os"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/metacubex/mihomo/transport/anytls/padding"
	"github.com/metacubex/mihomo/transport/vmess"

	M "github.com/metacubex/sing/common/metadata"
	"github.com/metacubex/tls"
)

const testPSK = "c2VjcmV0LXNlY3JldC1zZWNyZXQtc2VjcmV0LTEyMzQ="

// whether connAlive can look at a socket on this platform
const peekWorks = runtime.GOOS != "windows"

var (
	echoDst    = M.ParseSocksaddrHostPort("echo.test", 7)
	discardDst = M.ParseSocksaddrHostPort("discard.test", 9)
	floodDst   = M.ParseSocksaddrHostPort("flood.test", 19)
	holdDst    = M.ParseSocksaddrHostPort("hold.test", 1)
	muteDst    = M.ParseSocksaddrHostPort("mute.test", 1)
)

// testServer speaks just enough of the server side over plain TCP (no raw
// segments): auth, Settings, then stream after stream. A stream to echoDst gets
// its uplink back, one to discardDst gets nothing, both end when the uplink ends.
// Data "bye" ends the downlink right away, data "slow" comes back byte by byte.
// The other streams outlast their uplink and take a RESET to end: one to floodDst
// gets data without end, one to holdDst nothing. One to muteDst does not even
// answer the RESET.
type testServer struct {
	t      *testing.T
	ln     net.Listener
	scheme string // sent as UpdatePaddingScheme when set
	idle   string // idle= of ServerSettings

	live   atomic.Int32 // connections open
	opens  atomic.Int32 // streams opened
	resets atomic.Int32 // RESET frames received

	mu       sync.Mutex
	conns    []net.Conn
	settings []string
}

func newTestServer(t *testing.T) *testServer {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	s := &testServer{t: t, ln: ln, idle: "60"}
	t.Cleanup(func() {
		ln.Close()
		s.closeConns()
	})
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			s.mu.Lock()
			s.conns = append(s.conns, conn)
			s.mu.Unlock()
			s.live.Add(1)
			go func() {
				defer s.live.Add(-1)
				defer conn.Close()
				s.serve(conn)
			}()
		}
	}()
	return s
}

// closeConns closes every connection accepted so far.
func (s *testServer) closeConns() {
	s.mu.Lock()
	conns := s.conns
	s.conns = nil
	s.mu.Unlock()
	for _, conn := range conns {
		conn.Close()
	}
}

func readTestFrame(conn net.Conn) (typ byte, payload []byte, err error) {
	var head [frameHead]byte
	if _, err = io.ReadFull(conn, head[:]); err != nil {
		return
	}
	payload = make([]byte, int(head[1])<<8|int(head[2]))
	_, err = io.ReadFull(conn, payload)
	return head[0], payload, err
}

func (s *testServer) serve(conn net.Conn) {
	var head [authTokenLen + 2]byte
	if _, err := io.ReadFull(conn, head[:]); err != nil {
		return
	}
	if token := authToken(testPSK); !bytes.Equal(head[:authTokenLen], token[:]) {
		return
	}
	if _, err := io.CopyN(io.Discard, conn, int64(binary.BigEndian.Uint16(head[authTokenLen:]))); err != nil {
		return
	}
	for {
		typ, payload, err := readTestFrame(conn)
		if err != nil {
			return
		}
		switch typ {
		case frPad:
		case frSettings:
			s.mu.Lock()
			s.settings = append(s.settings, string(payload))
			s.mu.Unlock()
			reply := appendFrame(nil, frServerSettings, []byte("v=2\nraw=0\nidle="+s.idle))
			if s.scheme != "" {
				reply = appendFrame(reply, frUpdatePadding, []byte(s.scheme))
			}
			if _, err = conn.Write(reply); err != nil {
				return
			}
		case frOpen:
			s.opens.Add(1)
			mode := string(payload[2 : len(payload)-len(".test")-2])
			if !s.stream(conn, mode) {
				return
			}
		case frReset:
			// for a stream that ended meanwhile
			s.resets.Add(1)
		default:
			s.t.Errorf("frame type %d between streams", typ)
			return
		}
	}
}

// stream runs one stream, false when the connection is gone.
func (s *testServer) stream(conn net.Conn, mode string) bool {
	var wmu sync.Mutex
	write := func(b []byte) error {
		wmu.Lock()
		defer wmu.Unlock()
		_, err := conn.Write(b)
		return err
	}
	// the flood, until stopped
	stop, stopped := make(chan struct{}), make(chan struct{})
	go func() {
		defer close(stopped)
		chunk := appendFrame(nil, frData, bytes.Repeat([]byte{0x5a}, 1000))
		for mode == "flood" {
			select {
			case <-stop:
				return
			default:
			}
			if write(chunk) != nil {
				return
			}
		}
	}()
	ended, upEnded := false, false
	end := func() error {
		close(stop)
		<-stopped
		if ended {
			return nil
		}
		return write(appendFrame(nil, frEnd, nil))
	}
	for {
		typ, payload, err := readTestFrame(conn)
		if err != nil {
			close(stop)
			return false
		}
		switch typ {
		case frPad:
		case frData:
			switch {
			case upEnded:
				s.t.Errorf("data behind END")
				return false
			case ended || mode != "echo":
			case string(payload) == "bye":
				ended = true
				err = write(appendFrame(appendFrame(nil, frData, payload), frEnd, nil))
			case string(payload) == "slow":
				for _, b := range appendFrame(nil, frData, payload) {
					time.Sleep(20 * time.Millisecond)
					if err = write([]byte{b}); err != nil {
						break
					}
				}
			default:
				err = write(appendFrame(nil, frData, payload))
			}
			if err != nil {
				close(stop)
				return false
			}
		case frEnd:
			upEnded = true
			if mode == "echo" || mode == "discard" {
				return end() == nil
			}
		case frReset:
			s.resets.Add(1)
			if mode != "mute" {
				return end() == nil
			}
		default:
			s.t.Errorf("frame type %d inside a stream", typ)
			close(stop)
			return false
		}
	}
}

// testEvents counts what the client reports to its observer.
type testEvents struct {
	mu sync.Mutex
	m  map[string]int
}

func (e *testEvents) add(event string) {
	e.mu.Lock()
	e.m[event]++
	e.mu.Unlock()
}

func (e *testEvents) count(event string) int {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.m[event]
}

// newTestClient returns a client of s that does not prewarm, wrap is put around
// each connection it dials.
func newTestClient(t *testing.T, s *testServer, wrap func(net.Conn) net.Conn) (*Client, *testEvents) {
	t.Helper()
	c, err := NewClient(context.Background(), ClientConfig{PSK: testPSK})
	if err != nil {
		t.Fatal(err)
	}
	events := &testEvents{m: map[string]int{}}
	c.observer = events.add
	c.minIdle = 0
	c.connect = func(ctx context.Context) (net.Conn, error) {
		conn, err := (&net.Dialer{}).DialContext(ctx, "tcp", s.ln.Addr().String())
		if err == nil && wrap != nil {
			conn = wrap(conn)
		}
		return conn, err
	}
	t.Cleanup(func() { c.Close() })
	return c, events
}

func testOpen(t *testing.T, c *Client, destination M.Socksaddr) *Stream {
	t.Helper()
	conn, err := c.CreateProxy(context.Background(), destination)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	return conn.(*Stream)
}

func testEcho(t *testing.T, conn net.Conn, payload []byte) {
	t.Helper()
	go func() { _, _ = conn.Write(payload) }()
	got := make([]byte, len(payload))
	_ = conn.SetReadDeadline(time.Now().Add(10 * time.Second))
	if _, err := io.ReadFull(conn, got); err != nil {
		t.Fatalf("echo of %d bytes: %v", len(payload), err)
	}
	if !bytes.Equal(got, payload) {
		t.Fatalf("echo of %d bytes came back corrupted", len(payload))
	}
	_ = conn.SetReadDeadline(time.Time{})
}

// testFinish ends the uplink and expects the downlink to end in return.
func testFinish(t *testing.T, s *Stream) {
	t.Helper()
	if err := s.CloseWrite(); err != nil {
		t.Fatal(err)
	}
	_ = s.SetReadDeadline(time.Now().Add(10 * time.Second))
	if n, err := s.Read(make([]byte, 16)); n != 0 || err != io.EOF {
		t.Fatalf("after END: %d %v", n, err)
	}
}

func testWait(t *testing.T, what string, cond func() bool) {
	t.Helper()
	for deadline := time.Now().Add(10 * time.Second); !cond(); time.Sleep(5 * time.Millisecond) {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
	}
}

// lane returns the lane the stream is on.
func (s *Stream) lane() *lane {
	s.smu.Lock()
	defer s.smu.Unlock()
	return s.l
}

// wentRaw tells whether the uplink switched to raw segments.
func (s *Stream) wentRaw() bool {
	s.wmu.Lock()
	defer s.wmu.Unlock()
	return s.raw
}

// kept returns what the stream holds for a replay, nil when it holds nothing.
func (s *Stream) kept() []byte {
	s.wmu.Lock()
	defer s.wmu.Unlock()
	if !s.keep {
		return nil
	}
	return append([]byte{}, s.sent...)
}

func (c *Client) idleLanes() []*lane {
	c.mu.Lock()
	defer c.mu.Unlock()
	lanes := make([]*lane, 0, len(c.idle))
	for _, it := range c.idle {
		lanes = append(lanes, it.l)
	}
	return lanes
}

// opaqueConn hides the socket, the liveness peek cannot see through it.
type opaqueConn struct {
	net.Conn
	failWrite atomic.Bool
	writes    atomic.Int32
}

func (c *opaqueConn) Write(b []byte) (int, error) {
	if c.failWrite.Load() {
		return 0, errors.New("broken")
	}
	c.writes.Add(1)
	return c.Conn.Write(b)
}

func TestPSK(t *testing.T) {
	for _, bad := range []string{"", "  ", "short"} {
		if _, err := NewClient(context.Background(), ClientConfig{PSK: bad}); err == nil {
			t.Fatalf("%q should be rejected", bad)
		}
	}
	// the configured string is trimmed and hashed as it is, not base64 decoded
	c, err := NewClient(context.Background(), ClientConfig{PSK: " " + testPSK + "\n"})
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	if c.token != sha256.Sum256([]byte(testPSK)) {
		t.Fatalf("token: %x", c.token)
	}
}

// token(32) | padlen(u16) | padding, then the Settings frame, all in one write
func TestHello(t *testing.T) {
	c, err := NewClient(context.Background(), ClientConfig{PSK: testPSK})
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	a, b := net.Pipe()
	defer a.Close()
	defer b.Close()

	token := sha256.Sum256([]byte(testPSK))
	md5 := padding.NewPaddingFactory(padding.DefaultPaddingScheme).Md5
	want := append(token[:], 0, 30)
	want = append(want, make([]byte, 30)...)
	settings := "v=2\nraw=0\npadding-md5=" + md5
	want = append(want, frSettings, 0, byte(len(settings)))
	want = append(want, settings...)
	if got := c.hello(newLane(c, a)); !bytes.Equal(got, want) {
		t.Fatalf("hello:\n%x\nwant\n%x", got, want)
	}

	// entry 0 of the scheme is the padding length
	padding.UpdatePaddingScheme([]byte("stop=2\n0=7-7\n1=50-60"), &c.padding)
	got := c.hello(newLane(c, a))
	if binary.BigEndian.Uint16(got[32:]) != 7 || got[34+7] != frSettings {
		t.Fatalf("hello with a 7 byte padding: %x", got)
	}
	// and 30 without one
	padding.UpdatePaddingScheme([]byte("stop=2\n1=50-60"), &c.padding)
	if got = c.hello(newLane(c, a)); binary.BigEndian.Uint16(got[32:]) != 30 {
		t.Fatalf("hello without entry 0: %x", got)
	}
}

func TestFrames(t *testing.T) {
	if got := appendFrame([]byte{0xaa}, frOpen, []byte{1, 2, 3}); !bytes.Equal(got, []byte{0xaa, 4, 0, 3, 1, 2, 3}) {
		t.Fatalf("frame: %x", got)
	}
	if got := appendFrame(nil, frEnd, nil); !bytes.Equal(got, []byte{7, 0, 0}) {
		t.Fatalf("END: %x", got)
	}
	if got := appendPad(nil, 2); !bytes.Equal(got, []byte{0, 0, 2, 0, 0}) {
		t.Fatalf("PAD: %x", got)
	}
	// data is cut into frames that fit a TLS record
	data := bytes.Repeat([]byte{9}, 2*maxData+5)
	b := appendData(nil, data)
	var sizes []int
	var joined []byte
	for len(b) > 0 {
		n := int(b[1])<<8 | int(b[2])
		if b[0] != frData {
			t.Fatalf("frame type %d", b[0])
		}
		sizes = append(sizes, n)
		joined = append(joined, b[frameHead:frameHead+n]...)
		b = b[frameHead+n:]
	}
	if len(sizes) != 3 || sizes[0] != maxData || sizes[1] != maxData || sizes[2] != 5 || !bytes.Equal(joined, data) {
		t.Fatalf("DATA frames: %v", sizes)
	}
	if len(appendData(nil, nil)) != 0 {
		t.Fatal("no data, no frame")
	}

	// the RAW frame as it goes out, alone in its write
	c, _ := NewClient(context.Background(), ClientConfig{PSK: testPSK})
	defer c.Close()
	x, y := net.Pipe()
	defer x.Close()
	defer y.Close()
	l := newLane(c, x)
	if l.canRaw {
		t.Fatal("a plain connection cannot carry raw segments")
	}
	go func() { _ = l.writeRaw([]byte("0123456789")) }()
	got := make([]byte, 64)
	if n, _ := y.Read(got); !bytes.Equal(got[:n], []byte{frRaw, 0, 4, 0, 0, 0, 10}) {
		t.Fatalf("RAW frame: %x", got[:n])
	}
	if n, _ := y.Read(got); string(got[:n]) != "0123456789" {
		t.Fatalf("raw segment: %q", got[:n])
	}
}

// Tracking the record boundaries of the inner handshake: after a TLS 1.3
// ServerHello, an application_data record header at a boundary is where raw
// segments may start, however the data is cut. A stream that is not TLS, or is
// TLS 1.2, never gets there.
func TestRecScan(t *testing.T) {
	rec := func(typ byte, body []byte) []byte {
		return append([]byte{typ, 3, 3, byte(len(body) >> 8), byte(len(body))}, body...)
	}
	serverHello := func(tls13 bool) []byte {
		b := []byte{2, 0, 0, 0, 3, 3}
		b = append(b, make([]byte, 32)...)    // random
		b = append(b, 0)                      // session id
		b = append(b, 0x13, 0x01, 0)          // cipher, compression
		ext := []byte{0, 0x33, 0, 2, 0, 0x1d} // some other extension
		if tls13 {
			ext = append(ext, 0, 0x2b, 0, 2, 3, 4)
		}
		return append(append(b, byte(len(ext)>>8), byte(len(ext))), ext...)
	}
	down13 := bytes.Join([][]byte{rec(0x16, serverHello(true)), rec(0x14, []byte{1}), rec(0x17, make([]byte, 100))}, nil)

	for _, chunk := range []int{1, 3, 7, 64, len(down13)} {
		var tls13 atomic.Bool
		s := &recScan{tls13: &tls13}
		sw, at := false, 0
		for i := 0; i < len(down13) && !sw; i += chunk {
			end := i + chunk
			if end > len(down13) {
				end = len(down13)
			}
			sw, at = s.feed(down13[i:end]), end
		}
		// the chunk completing the 5 byte header of the application_data record
		if want := len(down13) - 100; !sw || at < want || at >= want+chunk {
			t.Fatalf("chunk %d: switch=%v at %d, want within [%d,%d)", chunk, sw, at, want, want+chunk)
		}
		if !tls13.Load() {
			t.Fatalf("chunk %d: TLS 1.3 not recognised", chunk)
		}
		// asked again, the answer stays
		if !s.feed([]byte{1}) {
			t.Fatalf("chunk %d: the switch did not stick", chunk)
		}
	}

	// the uplink learns about 1.3 from the other direction: no switch on
	// ClientHello and CCS, one on Finished (application_data)
	var tls13 atomic.Bool
	up := &recScan{tls13: &tls13}
	if up.feed(rec(0x16, []byte{1, 0, 0, 0})) {
		t.Fatal("switched on ClientHello")
	}
	tls13.Store(true)
	if up.feed(rec(0x14, []byte{1})) || !up.feed(rec(0x17, make([]byte, 40))) {
		t.Fatal("the uplink should switch at the first application_data record once TLS 1.3 is known")
	}

	var tls12 atomic.Bool
	s12 := &recScan{tls13: &tls12}
	if s12.feed(bytes.Join([][]byte{rec(0x16, serverHello(false)), rec(0x14, []byte{1}), rec(0x17, make([]byte, 100))}, nil)) || tls12.Load() {
		t.Fatal("switched on a TLS 1.2 handshake")
	}
	var no atomic.Bool
	plain := &recScan{tls13: &no}
	if plain.feed([]byte("GET / HTTP/1.1\r\n\r\n")) || !plain.dead {
		t.Fatal("plaintext HTTP should be given up on")
	}
	// a handshake that does not get there within the limit is given up on too
	long := &recScan{tls13: &no}
	for i := 0; i <= sniffLimit/1000; i++ {
		if long.feed(rec(0x16, make([]byte, 995))) {
			t.Fatal("switched without a ServerHello")
		}
	}
	if !long.dead {
		t.Fatal("still looking past the limit")
	}
}

// Shaping: with the default scheme packet 1 is filled up to one record of 100 to
// 400 bytes, packet 2 is cut into several, each within its range. Without the
// PAD frames the frames are the original ones. A packet past stop goes out whole.
func TestWritePacketShaping(t *testing.T) {
	c, err := NewClient(context.Background(), ClientConfig{PSK: testPSK})
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	a, peer := net.Pipe()
	defer a.Close()
	defer peer.Close()
	l := newLane(c, a)

	read := func(pkt uint32, p []byte) [][]byte {
		var writes [][]byte
		done := make(chan struct{})
		go func() {
			defer close(done)
			_ = l.writePacket(pkt, p)
			_ = l.write([]byte{0xff}) // sentinel: the packet is through
		}()
		for {
			b := make([]byte, 70000)
			n, err := peer.Read(b)
			if err != nil {
				t.Fatal(err)
			}
			if n == 1 && b[0] == 0xff {
				<-done
				return writes
			}
			writes = append(writes, b[:n])
		}
	}
	strip := func(writes [][]byte) []byte {
		all := bytes.Join(writes, nil)
		var out []byte
		for len(all) > 0 {
			n := int(all[1])<<8 | int(all[2])
			if all[0] != frPad {
				out = append(out, all[:frameHead+n]...)
			}
			all = all[frameHead+n:]
		}
		return out
	}

	open := appendFrame(appendFrame(nil, frOpen, []byte{1, 127, 0, 0, 1, 1, 187}), frData, bytes.Repeat([]byte{7}, 20))
	w := read(1, append([]byte(nil), open...))
	if len(w) != 1 || len(w[0]) < 100 || len(w[0]) >= 400 {
		t.Fatalf("packet 1: %d writes, first %d bytes", len(w), len(w[0]))
	}
	if !bytes.Equal(strip(w), open) {
		t.Fatal("packet 1: frames changed")
	}

	data := appendFrame(nil, frData, bytes.Repeat([]byte{9}, 3000))
	w = read(2, append([]byte(nil), data...))
	if len(w) < 3 || len(w[0]) < 400 || len(w[0]) >= 500 {
		t.Fatalf("packet 2: %d writes, first %d bytes", len(w), len(w[0]))
	}
	// the ones in between are 500 to 1000, what is left when the scheme is
	// through follows in one piece of any length
	for _, x := range w[1 : len(w)-1] {
		if len(x) < 500 || len(x) >= 1000 {
			t.Fatalf("packet 2: a record of %d bytes", len(x))
		}
	}
	if !bytes.Equal(strip(w), data) {
		t.Fatal("packet 2: frames changed")
	}

	// END as packet 3 (9-9,500-1000): filled up to 9 bytes, a record of padding behind
	end := appendFrame(nil, frEnd, nil)
	w = read(3, append([]byte(nil), end...))
	if len(w) != 2 || len(w[0]) != 9 || w[1][0] != frPad || !bytes.Equal(strip(w), end) {
		t.Fatalf("packet 3: %d writes, first %d bytes", len(w), len(w[0]))
	}

	if w = read(c.padding.Load().Stop, append([]byte(nil), data...)); len(w) != 1 || !bytes.Equal(w[0], data) {
		t.Fatalf("a packet past stop was shaped: %d writes", len(w))
	}
}

// OPEN leaves in one packet with the first bytes of the app, or alone when there
// are none in time.
func TestOpenPacket(t *testing.T) {
	s := newTestServer(t)
	var conns []*opaqueConn
	c, _ := newTestClient(t, s, func(conn net.Conn) net.Conn {
		oc := &opaqueConn{Conn: conn}
		conns = append(conns, oc)
		return oc
	})

	first := testOpen(t, c, echoDst)
	if _, err := first.Write([]byte("hello")); err != nil {
		t.Fatal(err)
	}
	// the hello, then packet 1: OPEN and DATA in a single record
	if n := conns[0].writes.Load(); n != 2 {
		t.Fatalf("%d writes for the hello and the first packet", n)
	}
	time.Sleep(3 * firstPayloadWait)
	if n := conns[0].writes.Load(); n != 2 {
		t.Fatalf("OPEN went out twice: %d writes", n)
	}
	got := make([]byte, 16)
	if n, err := first.Read(got); err != nil || string(got[:n]) != "hello" {
		t.Fatalf("echo: %q %v", got[:n], err)
	}

	second := testOpen(t, c, echoDst)
	testWait(t, "OPEN to go out alone", func() bool { return s.opens.Load() == 2 })
	if n := conns[1].writes.Load(); n != 2 {
		t.Fatalf("%d writes for the hello and a lone OPEN", n)
	}
	testEcho(t, second, []byte("late"))
}

func TestStream(t *testing.T) {
	s := newTestServer(t)
	c, events := newTestClient(t, s, nil)

	// small, large, one byte at a time
	first := testOpen(t, c, echoDst)
	testEcho(t, first, []byte("hello miu"))
	big := make([]byte, 3<<20)
	for i := range big {
		big[i] = byte(i * 7)
	}
	testEcho(t, first, big)
	for i := 0; i < 20; i++ {
		testEcho(t, first, []byte{byte(i)})
	}
	if first.wentRaw() || events.count("raw:in") != 0 {
		t.Fatal("raw segments on a plain connection")
	}
	lane := first.lane()

	// half close: the uplink ends, the server ends the downlink, the lane is idle
	testFinish(t, first)
	if idle := c.idleLanes(); len(idle) != 1 || idle[0] != lane {
		t.Fatalf("%d idle lanes after the stream ended", len(idle))
	}
	if _, err := first.Write([]byte("x")); err != io.ErrClosedPipe {
		t.Fatalf("write after END: %v", err)
	}
	if n, err := first.Read(make([]byte, 1)); n != 0 || err != io.EOF {
		t.Fatalf("read after END: %d %v", n, err)
	}
	// closing a stream that ran to its end leaves the lane alone
	first.Close()
	_ = first.SetDeadline(time.Now())

	// the next streams run on that very lane, one after the other
	for i := 0; i < 5; i++ {
		next := testOpen(t, c, echoDst)
		if next.lane() != lane || !lane.pooled {
			t.Fatal("the idle lane was not reused")
		}
		testEcho(t, next, []byte("again"))
		testFinish(t, next)
	}
	if events.count("lane:dial") != 1 || events.count("lane:reuse") != 5 || s.live.Load() != 1 {
		t.Fatalf("dials=%d reuses=%d connections=%d", events.count("lane:dial"), events.count("lane:reuse"), s.live.Load())
	}

	// the server ends the downlink first: Close sends the END that is missing
	bye := testOpen(t, c, echoDst)
	if _, err := bye.Write([]byte("bye")); err != nil {
		t.Fatal(err)
	}
	if got, err := io.ReadAll(bye); err != nil || string(got) != "bye" {
		t.Fatalf("until END: %q %v", got, err)
	}
	if len(c.idleLanes()) != 0 {
		t.Fatal("the lane went back with the uplink still open")
	}
	bye.Close()
	testWait(t, "the lane to go back", func() bool { return len(c.idleLanes()) == 1 })
	if c.idleLanes()[0] != lane || events.count("reset") != 0 || s.resets.Load() != 0 {
		t.Fatal("Close after the downlink ended should end the uplink and hand the lane back")
	}
	testEcho(t, testOpen(t, c, echoDst), []byte("after bye"))

	// two streams at once need two lanes
	other := testOpen(t, c, echoDst)
	testEcho(t, other, []byte("second lane"))
	if events.count("lane:dial") != 2 {
		t.Fatalf("dials=%d", events.count("lane:dial"))
	}
}

// Close on a stream that did not run to its end: the server is told with RESET,
// the rest of the downlink is dropped up to its END, and the lane carries the
// next stream.
func TestStreamAbort(t *testing.T) {
	s := newTestServer(t)
	c, events := newTestClient(t, s, nil)
	// back waits for the lane to be idle again and runs a stream on it: whatever
	// the aborted one left behind would show there.
	back := func(l *lane) {
		t.Helper()
		testWait(t, "the lane to go back", func() bool { return len(c.idleLanes()) == 1 })
		next := testOpen(t, c, echoDst)
		if next.lane() != l || l.closed.Load() {
			t.Fatal("the lane of the aborted stream was not reused")
		}
		testEcho(t, next, []byte("the stream after"))
		testFinish(t, next)
	}

	// before OPEN went out: nothing is sent, the lane goes back as it came
	stream := testOpen(t, c, echoDst)
	stream.timer.Stop()
	l := stream.lane()
	stream.Close()
	if idle := c.idleLanes(); len(idle) != 1 || idle[0] != l || l.used {
		t.Fatal("a lane nothing was sent on should go straight back")
	}
	// the same with a reader waiting already
	stream = testOpen(t, c, echoDst)
	stream.timer.Stop()
	reader := make(chan error, 1)
	go func() {
		_, err := stream.Read(make([]byte, 16))
		reader <- err
	}()
	time.Sleep(20 * time.Millisecond)
	stream.Close()
	if err := <-reader; err != io.ErrClosedPipe {
		t.Fatalf("read on a closed stream: %v", err)
	}
	back(l)
	if s.opens.Load() != 1 || s.resets.Load() != 0 || events.count("reset") != 0 || events.count("lane:dial") != 1 {
		t.Fatalf("opens=%d resets=%d dials=%d", s.opens.Load(), s.resets.Load(), events.count("lane:dial"))
	}

	// in the middle of a download: RESET in place of END, megabytes on their way
	// are dropped
	for i := 0; i < 3; i++ {
		stream = testOpen(t, c, floodDst)
		_ = stream.SetReadDeadline(time.Now().Add(10 * time.Second))
		if _, err := io.ReadFull(stream, make([]byte, 300<<10)); err != nil {
			t.Fatal(err)
		}
		stream.Close()
		back(l)
		if s.resets.Load() != int32(i+1) || events.count("reset") != i+1 {
			t.Fatalf("round %d: resets=%d", i, s.resets.Load())
		}
	}

	// nothing read at all, a reader and Close at the same time: the reader
	// returns at once and does not get in the way of the draining
	stream = testOpen(t, c, floodDst)
	if _, err := stream.Write([]byte("x")); err != nil {
		t.Fatal(err)
	}
	go func() {
		b := make([]byte, 1000)
		for {
			if _, err := stream.Read(b); err != nil {
				reader <- err
				return
			}
		}
	}()
	time.Sleep(20 * time.Millisecond)
	stream.Close()
	if err := <-reader; err != io.ErrClosedPipe {
		t.Fatalf("read on a closed stream: %v", err)
	}
	back(l)

	// the uplink ended, then the app left altogether: RESET behind END
	stream = testOpen(t, c, holdDst)
	if _, err := stream.Write([]byte("x")); err != nil {
		t.Fatal(err)
	}
	if err := stream.CloseWrite(); err != nil {
		t.Fatal(err)
	}
	go func() {
		_, err := stream.Read(make([]byte, 16))
		reader <- err
	}()
	time.Sleep(20 * time.Millisecond)
	resets := s.resets.Load()
	start := time.Now()
	stream.Close()
	if err := <-reader; err != io.ErrClosedPipe || time.Since(start) > time.Second {
		t.Fatalf("read on a closed stream: %v after %v", err, time.Since(start))
	}
	// and whatever is called from here on returns right away
	if _, err := stream.Write([]byte("x")); err != io.ErrClosedPipe {
		t.Fatalf("write on a closed stream: %v", err)
	}
	if _, err := stream.Read(make([]byte, 1)); err != io.ErrClosedPipe {
		t.Fatalf("read on a closed stream: %v", err)
	}
	if err := stream.CloseWrite(); err != io.ErrClosedPipe {
		t.Fatalf("CloseWrite on a closed stream: %v", err)
	}
	_ = stream.SetDeadline(time.Now().Add(-time.Hour)) // must not reach the lane
	back(l)
	if s.resets.Load() != resets+1 {
		t.Fatalf("resets=%d", s.resets.Load()-resets)
	}

	// END and RESET, and the server was done already: the RESET is for nobody
	stream = testOpen(t, c, echoDst)
	testEcho(t, stream, []byte("hello"))
	if err := stream.CloseWrite(); err != nil {
		t.Fatal(err)
	}
	stream.Close()
	back(l)

	if events.count("lane:dial") != 1 || events.count("replay") != 0 || s.live.Load() != 1 {
		t.Fatalf("dials=%d replays=%d connections=%d", events.count("lane:dial"), events.count("replay"), s.live.Load())
	}
}

// The END of the server does not come: the lane is given up when the time is up.
// Calls on the stream do not wait for that.
func TestStreamAbortTimeout(t *testing.T) {
	s := newTestServer(t)
	c, events := newTestClient(t, s, nil)
	c.drain = 300 * time.Millisecond

	stream := testOpen(t, c, muteDst)
	if _, err := stream.Write([]byte("x")); err != nil {
		t.Fatal(err)
	}
	reader := make(chan error, 1)
	go func() {
		_, err := stream.Read(make([]byte, 16))
		reader <- err
	}()
	time.Sleep(20 * time.Millisecond)
	start := time.Now()
	stream.Close()
	if err := <-reader; err != io.ErrClosedPipe {
		t.Fatalf("read on a closed stream: %v", err)
	}
	if _, err := stream.Read(make([]byte, 1)); err != io.ErrClosedPipe {
		t.Fatalf("read on a closed stream: %v", err)
	}
	if _, err := stream.Write([]byte("x")); err != io.ErrClosedPipe {
		t.Fatalf("write on a closed stream: %v", err)
	}
	if d := time.Since(start); d > c.drain/2 {
		t.Fatalf("calls on a closed stream took %v", d)
	}
	l := stream.lane()
	if l.closed.Load() {
		t.Fatal("the lane was closed without waiting for END")
	}
	testWait(t, "the lane to be given up", func() bool { return l.closed.Load() })
	if d := time.Since(start); d < c.drain || d > 10*c.drain {
		t.Fatalf("the lane was given up after %v", d)
	}
	testWait(t, "the connection to close", func() bool { return s.live.Load() == 0 })
	if len(c.idleLanes()) != 0 || s.resets.Load() != 1 || events.count("reset") != 1 {
		t.Fatalf("idle=%d resets=%d", len(c.idleLanes()), s.resets.Load())
	}

	// a write under way cannot be cut short without leaving the lane out of
	// step: that lane goes with the stream
	stream = testOpen(t, c, echoDst)
	testEcho(t, stream, []byte("hello"))
	stream.wmu.Lock()
	stream.Close()
	stream.wmu.Unlock()
	if !stream.lane().closed.Load() || s.resets.Load() != 1 {
		t.Fatal("Close in the middle of a write should close the lane")
	}

	// the lane died under the stream: nothing to keep
	stream = testOpen(t, c, holdDst)
	if _, err := stream.Write([]byte("x")); err != nil {
		t.Fatal(err)
	}
	testWait(t, "the stream to be opened", func() bool { return s.opens.Load() == 3 })
	s.closeConns()
	stream.Close()
	l = stream.lane()
	testWait(t, "the dead lane to be closed", func() bool { return l.closed.Load() })
	if len(c.idleLanes()) != 0 {
		t.Fatal("a dead lane in the pool")
	}
}

// A deadline interrupts a read without losing the place in the frame.
func TestStreamDeadline(t *testing.T) {
	s := newTestServer(t)
	c, _ := newTestClient(t, s, nil)
	stream := testOpen(t, c, echoDst)
	testEcho(t, stream, []byte("hello"))

	_ = stream.SetReadDeadline(time.Now().Add(30 * time.Millisecond))
	if _, err := stream.Read(make([]byte, 16)); !errors.Is(err, os.ErrDeadlineExceeded) {
		t.Fatalf("read past the deadline: %v", err)
	}
	// the frame comes in byte by byte, 20ms apart: time out in the middle of
	// its header, then again and again
	if _, err := stream.Write([]byte("slow")); err != nil {
		t.Fatal(err)
	}
	var got []byte
	timeouts := 0
	for len(got) < 4 {
		_ = stream.SetReadDeadline(time.Now().Add(30 * time.Millisecond))
		b := make([]byte, 16)
		n, err := stream.Read(b)
		got = append(got, b[:n]...)
		if err != nil {
			if !errors.Is(err, os.ErrDeadlineExceeded) {
				t.Fatal(err)
			}
			timeouts++
		}
	}
	if string(got) != "slow" || timeouts == 0 {
		t.Fatalf("%q after %d timeouts", got, timeouts)
	}
	_ = stream.SetReadDeadline(time.Time{})
	testEcho(t, stream, []byte("still in step"))

	// the deadlines do not stick to the lane
	_ = stream.SetDeadline(time.Now().Add(time.Hour))
	testFinish(t, stream)
	_ = stream.SetDeadline(time.Now().Add(-time.Second))
	next := testOpen(t, c, echoDst)
	if next.lane() != stream.lane() {
		t.Fatal("the idle lane was not reused")
	}
	testEcho(t, next, []byte("no deadline left over"))
}

func TestConnAlive(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	conn, err := net.Dial("tcp", ln.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	peer, err := ln.Accept()
	if err != nil {
		t.Fatal(err)
	}
	defer peer.Close()

	if alive, pending := connAlive(&opaqueConn{Conn: conn}); !alive || pending {
		t.Fatal("a connection that cannot be looked at counts as alive")
	}
	if alive, pending := connAlive(conn); !alive || pending {
		t.Fatalf("idle connection: alive=%v pending=%v", alive, pending)
	}
	if !peekWorks {
		return
	}
	if _, err = peer.Write([]byte("x")); err != nil {
		t.Fatal(err)
	}
	testWait(t, "the data to arrive", func() bool {
		_, pending := connAlive(conn)
		return pending
	})
	// looking does not take the data
	b := make([]byte, 4)
	if alive, _ := connAlive(conn); !alive {
		t.Fatal("data waiting, yet not alive")
	}
	if n, _ := conn.Read(b); string(b[:n]) != "x" {
		t.Fatalf("the peek took the data: %q", b[:n])
	}
	peer.Close()
	testWait(t, "the close to arrive", func() bool {
		alive, _ := connAlive(conn)
		return !alive
	})
}

// The pool: last in first out, a limit, a time to live, a look before use.
func TestPool(t *testing.T) {
	s := newTestServer(t)
	s.idle = "20"
	c, events := newTestClient(t, s, nil)

	// what the server announced, minus the margin, bounds the time to live
	stream := testOpen(t, c, echoDst)
	testEcho(t, stream, []byte("x"))
	testFinish(t, stream)
	l := stream.lane()
	if l.peerIdle.Load() != 20 || c.ttl(l, 0) != 15*time.Second || c.ttl(l, warmLanes) != 15*time.Second {
		t.Fatalf("idle=%d ttl=%v", l.peerIdle.Load(), c.ttl(l, 0))
	}
	// the four put back last stay for longer than the rest
	for peer, want := range map[int64][2]time.Duration{
		8:   {warmLaneIdle, defaultLaneIdle}, // too short to take a margin off
		60:  {55 * time.Second, defaultLaneIdle},
		180: {warmLaneIdle, defaultLaneIdle},
	} {
		l.peerIdle.Store(peer)
		if c.ttl(l, 0) != want[0] || c.ttl(l, warmLanes-1) != want[0] || c.ttl(l, warmLanes) != want[1] {
			t.Fatalf("idle=%d: ttl %v, %v", peer, c.ttl(l, 0), c.ttl(l, warmLanes))
		}
	}
	// a configured time for the rest that is longer than that holds for all
	c.laneIdle = 10 * time.Minute
	l.peerIdle.Store(180)
	if c.ttl(l, 0) != 175*time.Second || c.ttl(l, warmLanes) != 175*time.Second {
		t.Fatalf("ttl %v, %v", c.ttl(l, 0), c.ttl(l, warmLanes))
	}
	c.laneIdle = defaultLaneIdle

	// last in, first out
	a, b := testOpen(t, c, echoDst), testOpen(t, c, echoDst)
	testEcho(t, a, []byte("a"))
	testEcho(t, b, []byte("b"))
	testFinish(t, b)
	testFinish(t, a)
	if got := testOpen(t, c, discardDst); got.lane() != a.lane() {
		t.Fatal("the lane put back last should be taken first")
	}
	if got := testOpen(t, c, discardDst); got.lane() != b.lane() {
		t.Fatal("then the one before")
	}

	// the server closed an idle lane: seen before use, the stream gets a new one
	if !peekWorks {
		return
	}
	stream = testOpen(t, c, echoDst)
	testEcho(t, stream, []byte("x"))
	testFinish(t, stream)
	s.closeConns()
	testWait(t, "the close to arrive", func() bool {
		alive, _ := connAlive(stream.lane().raw)
		return !alive
	})
	dials := events.count("lane:dial")
	stream = testOpen(t, c, echoDst)
	testEcho(t, stream, []byte("on a new lane"))
	if events.count("lane:dial") != dials+1 || events.count("replay") != 0 {
		t.Fatalf("dials=%d replays=%d", events.count("lane:dial")-dials, events.count("replay"))
	}
	testFinish(t, stream)

	// data on an idle lane that carried a stream is the server closing it
	s.mu.Lock()
	_, _ = s.conns[len(s.conns)-1].Write(appendPad(nil, 4))
	s.mu.Unlock()
	testWait(t, "the data to arrive", func() bool {
		_, pending := connAlive(stream.lane().raw)
		return pending
	})
	if got := testOpen(t, c, echoDst); got.lane() == stream.lane() || !stream.lane().closed.Load() {
		t.Fatal("a lane with data waiting should be dropped")
	}
}

func TestPoolLimit(t *testing.T) {
	s := newTestServer(t)
	c, _ := newTestClient(t, s, nil)
	var lanes []*lane
	for i := 0; i < maxIdleLanes+2; i++ {
		l, err := c.dial(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		lanes = append(lanes, l)
		c.put(l)
	}
	idle := c.idleLanes()
	if len(idle) != maxIdleLanes || idle[0] != lanes[2] || idle[maxIdleLanes-1] != lanes[maxIdleLanes+1] {
		t.Fatalf("%d idle lanes", len(idle))
	}
	if !lanes[0].closed.Load() || !lanes[1].closed.Load() || lanes[2].closed.Load() {
		t.Fatal("the oldest lanes should be closed")
	}
	// a prewarmed lane has ServerSettings waiting: that is no reason to drop it
	testWait(t, "ServerSettings", func() bool {
		_, pending := connAlive(lanes[maxIdleLanes+1].raw)
		return pending || !peekWorks
	})
	stream := testOpen(t, c, echoDst)
	if stream.lane() != lanes[maxIdleLanes+1] {
		t.Fatal("the newest lane should be taken")
	}
	testEcho(t, stream, []byte("x"))

	// Close closes what is in the pool, and whatever is put back later
	c.Close()
	if len(c.idleLanes()) != 0 {
		t.Fatal("idle lanes after Close")
	}
	for _, l := range lanes[2 : maxIdleLanes+1] {
		if !l.closed.Load() {
			t.Fatal("Close should close the idle lanes")
		}
	}
	testFinish(t, stream)
	if !stream.lane().closed.Load() || len(c.idleLanes()) != 0 {
		t.Fatal("a lane handed back after Close should be closed")
	}
	testWait(t, "the connections to close", func() bool { return s.live.Load() == 0 })
	if _, err := c.CreateProxy(context.Background(), echoDst); err != io.ErrClosedPipe {
		t.Fatalf("CreateProxy after Close: %v", err)
	}
}

func TestPoolExpiry(t *testing.T) {
	s := newTestServer(t)
	c, events := newTestClient(t, s, nil)
	c.laneIdle, c.warmIdle = 150*time.Millisecond, 150*time.Millisecond

	a, b := testOpen(t, c, echoDst), testOpen(t, c, echoDst)
	testEcho(t, a, []byte("a"))
	testEcho(t, b, []byte("b"))
	testFinish(t, a)
	time.Sleep(80 * time.Millisecond)
	testFinish(t, b)
	// each one goes when its own time is up
	testWait(t, "the first lane to expire", func() bool { return len(c.idleLanes()) == 1 && a.lane().closed.Load() })
	if b.lane().closed.Load() {
		t.Fatal("the lane idle for longer should expire first")
	}
	testWait(t, "the second lane to expire", func() bool { return len(c.idleLanes()) == 0 })
	testWait(t, "the connections to close", func() bool { return s.live.Load() == 0 })
	c.mu.Lock()
	sweeper := c.sweeper
	c.mu.Unlock()
	if sweeper != nil {
		t.Fatal("nothing left to sweep, yet a timer is set")
	}

	// a lane past its time that is still in the pool is not handed out either
	stream := testOpen(t, c, echoDst)
	testEcho(t, stream, []byte("x"))
	testFinish(t, stream)
	c.mu.Lock()
	c.idle[0].since = time.Now().Add(-time.Second)
	c.mu.Unlock()
	dials := events.count("lane:dial")
	if got := testOpen(t, c, echoDst); got.lane() == stream.lane() || events.count("lane:dial") != dials+1 {
		t.Fatal("an expired lane was handed out")
	}
}

// Two tiers: the lanes put back last are kept for long, the ones below them go
// early. A lane moves down as others are put on top of it.
func TestPoolTiers(t *testing.T) {
	s := newTestServer(t)
	c, _ := newTestClient(t, s, nil)
	c.laneIdle, c.warmIdle = 150*time.Millisecond, 600*time.Millisecond

	var lanes []*lane
	start := time.Now()
	for i := 0; i < warmLanes+2; i++ {
		l, err := c.dial(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		lanes = append(lanes, l)
		c.put(l)
	}
	testWait(t, "the lanes below the top ones to expire", func() bool { return len(c.idleLanes()) == warmLanes })
	if d := time.Since(start); d < c.laneIdle || d > c.warmIdle {
		t.Fatalf("expired after %v", d)
	}
	testWait(t, "the expired lanes to be closed", func() bool { return lanes[0].closed.Load() && lanes[1].closed.Load() })
	if lanes[2].closed.Load() {
		t.Fatal("the oldest lanes should go first")
	}
	// one more on top: the one at the bottom of the top ones is among the rest
	// now, and its time there is up already
	l, err := c.dial(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	c.put(l)
	testWait(t, "the lane pushed down to expire", func() bool { return lanes[2].closed.Load() })
	if d := time.Since(start); d > c.warmIdle {
		t.Fatalf("a lane pushed down was only closed after %v", d)
	}
	if idle := c.idleLanes(); len(idle) != warmLanes || idle[0] != lanes[3] {
		t.Fatalf("%d idle lanes", len(idle))
	}
	// taking from the top moves the others up, they stay for long again
	if got := testOpen(t, c, echoDst); got.lane() != l {
		t.Fatal("the lane put back last should be taken first")
	}
	testWait(t, "the top lanes to expire", func() bool { return len(c.idleLanes()) == 0 })
	if d := time.Since(start); d < c.warmIdle {
		t.Fatalf("the top lanes expired after %v", d)
	}
	testWait(t, "the expired lanes to be closed", func() bool {
		for _, l := range lanes {
			if !l.closed.Load() {
				return false
			}
		}
		return true
	})
}

// Streams coming in a burst have idle lanes prewarmed, on a context of their own.
func TestPrewarm(t *testing.T) {
	s := newTestServer(t)
	c, events := newTestClient(t, s, nil)
	c.minIdle = defaultMinIdle

	ctx, cancel := context.WithCancel(context.Background())
	first, err := c.CreateProxy(ctx, echoDst)
	if err != nil {
		t.Fatal(err)
	}
	defer first.Close()
	time.Sleep(50 * time.Millisecond)
	if events.count("lane:dial") != 1 || len(c.idleLanes()) != 0 {
		t.Fatal("a single stream should not prewarm anything")
	}
	second, err := c.CreateProxy(ctx, echoDst)
	cancel() // the request is over before the prewarm dials are
	if err != nil {
		t.Fatal(err)
	}
	defer second.Close()
	testWait(t, "the prewarmed lanes", func() bool { return len(c.idleLanes()) == defaultMinIdle })
	if events.count("lane:dial") != 2+defaultMinIdle {
		t.Fatalf("dials=%d", events.count("lane:dial"))
	}
	// taking one has it replaced, the pool is not filled beyond minIdle
	warm := c.idleLanes()
	third := testOpen(t, c, echoDst)
	if third.lane() != warm[1] {
		t.Fatal("the stream should run on a prewarmed lane")
	}
	testEcho(t, third, []byte("warm"))
	testWait(t, "the pool to be topped up", func() bool { return len(c.idleLanes()) == defaultMinIdle })
	time.Sleep(50 * time.Millisecond)
	if n := events.count("lane:dial"); n != 3+defaultMinIdle || len(c.idleLanes()) != defaultMinIdle {
		t.Fatalf("dials=%d idle=%d", n, len(c.idleLanes()))
	}
}

// A lane from the pool that turns out to be dead before the server answered
// anything: the stream sends what it sent so far again on a new one.
func TestReplay(t *testing.T) {
	s := newTestServer(t)
	var mu sync.Mutex
	var conns []*opaqueConn
	c, events := newTestClient(t, s, func(conn net.Conn) net.Conn {
		oc := &opaqueConn{Conn: conn}
		mu.Lock()
		conns = append(conns, oc)
		mu.Unlock()
		return oc
	})
	last := func() *opaqueConn {
		mu.Lock()
		defer mu.Unlock()
		return conns[len(conns)-1]
	}
	// idle leaves a used lane in the pool
	idle := func() {
		t.Helper()
		stream := testOpen(t, c, echoDst)
		testEcho(t, stream, []byte("x"))
		testFinish(t, stream)
		if len(c.idleLanes()) != 1 {
			t.Fatal("no idle lane")
		}
	}
	// kill has the server close its connections, unseen by the peek
	kill := func() {
		t.Helper()
		s.closeConns()
		testWait(t, "the connections to close", func() bool { return s.live.Load() == 0 })
	}

	// the first write fails
	idle()
	last().failWrite.Store(true)
	stream := testOpen(t, c, echoDst)
	if stream.kept() == nil {
		t.Fatal("a stream on a lane from the pool should keep what it sends")
	}
	testEcho(t, stream, []byte("first write failed"))
	if events.count("replay") != 1 || stream.kept() != nil {
		t.Fatalf("replays=%d", events.count("replay"))
	}
	testFinish(t, stream)

	// the writes go through, the lane is found dead when reading
	kill()
	stream = testOpen(t, c, echoDst)
	if _, err := stream.Write([]byte("found dead ")); err != nil {
		t.Fatal(err)
	}
	go func() { _, _ = stream.Write([]byte("when reading")) }()
	found := make([]byte, 23)
	_ = stream.SetReadDeadline(time.Now().Add(10 * time.Second))
	if _, err := io.ReadFull(stream, found); err != nil || string(found) != "found dead when reading" {
		t.Fatalf("echo after a replay: %q %v", found, err)
	}
	if events.count("replay") != 2 {
		t.Fatalf("replays=%d", events.count("replay"))
	}
	testFinish(t, stream)

	// a reader already waiting, nothing written yet: only OPEN is sent again
	kill()
	stream = testOpen(t, c, echoDst)
	got := make(chan []byte, 1)
	go func() {
		b := make([]byte, 16)
		n, _ := stream.Read(b)
		got <- b[:n]
	}()
	testWait(t, "the replay", func() bool { return events.count("replay") == 3 })
	if _, err := stream.Write([]byte("after")); err != nil {
		t.Fatal(err)
	}
	if b := <-got; string(b) != "after" {
		t.Fatalf("echo after a replay: %q", b)
	}
	testFinish(t, stream)

	// the uplink ended before the lane was found dead: END is sent again as well
	kill()
	stream = testOpen(t, c, echoDst)
	if _, err := stream.Write([]byte("bye")); err != nil {
		t.Fatal(err)
	}
	if err := stream.CloseWrite(); err != nil {
		t.Fatal(err)
	}
	if b, err := io.ReadAll(stream); err != nil || string(b) != "bye" {
		t.Fatalf("until END: %q %v", b, err)
	}
	if events.count("replay") != 4 || len(c.idleLanes()) != 1 {
		t.Fatalf("replays=%d idle=%d", events.count("replay"), len(c.idleLanes()))
	}

	// once the server answered there is no going back
	stream = testOpen(t, c, echoDst)
	testEcho(t, stream, []byte("answered"))
	kill()
	_ = stream.SetReadDeadline(time.Now().Add(10 * time.Second))
	if _, err := stream.Read(make([]byte, 16)); err == nil || err == io.EOF || isTimeout(err) {
		t.Fatalf("read on a lane that died in mid-stream: %v", err)
	}
	if _, err := stream.Read(make([]byte, 16)); err == nil || err == io.EOF {
		t.Fatalf("and again: %v", err)
	}
	stream.Close()

	// more sent than is kept: no replay either
	idle()
	stream = testOpen(t, c, discardDst)
	if _, err := stream.Write(make([]byte, replayLimit)); err != nil || len(stream.kept()) != replayLimit {
		t.Fatalf("up to the limit everything is kept: %v", err)
	}
	if _, err := stream.Write([]byte("x")); err != nil || stream.kept() != nil {
		t.Fatalf("past the limit nothing is: %v", err)
	}
	kill()
	_ = stream.SetReadDeadline(time.Now().Add(10 * time.Second))
	if _, err := stream.Read(make([]byte, 16)); err == nil || err == io.EOF || isTimeout(err) {
		t.Fatalf("read on a dead lane past the limit: %v", err)
	}
	stream.Close()

	// a newly dialed lane has no excuse: its failure is reported
	stream = testOpen(t, c, echoDst)
	if stream.kept() != nil {
		t.Fatal("a new lane counts as pooled")
	}
	testWait(t, "the connection", func() bool { return s.live.Load() == 1 })
	kill()
	_ = stream.SetReadDeadline(time.Now().Add(10 * time.Second))
	if _, err := stream.Read(make([]byte, 16)); err == nil || err == io.EOF || isTimeout(err) {
		t.Fatalf("read on a new lane that died: %v", err)
	}
	if events.count("replay") != 4 {
		t.Fatalf("replays=%d", events.count("replay"))
	}
}

// The server hands out its padding scheme, the next lanes announce and use it.
func TestUpdatePaddingScheme(t *testing.T) {
	s := newTestServer(t)
	s.scheme = "stop=3\n0=11-11\n1=64-64\n2=64-64"
	c, _ := newTestClient(t, s, nil)
	testEcho(t, testOpen(t, c, echoDst), []byte("x"))
	scheme := c.padding.Load()
	if string(scheme.RawScheme) != s.scheme || authPadding(scheme) != 11 {
		t.Fatalf("scheme: %q", scheme.RawScheme)
	}
	testEcho(t, testOpen(t, c, echoDst), []byte("y"))
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.settings) != 2 || !strings.HasPrefix(s.settings[0], "v=2\nraw=0\npadding-md5=") ||
		!strings.HasSuffix(s.settings[1], "padding-md5="+scheme.Md5) || s.settings[0] == s.settings[1] {
		t.Fatalf("settings: %q", s.settings)
	}
}

// A frame the client has no business receiving ends the stream with an error,
// not a replay.
func TestProtocolError(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			// RAW on a connection that cannot carry raw segments
			_, _ = conn.Write([]byte{frRaw, 0, 4, 0, 0, 0, 1, 'x'})
		}
	}()
	c, err := NewClient(context.Background(), ClientConfig{PSK: testPSK})
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	c.connect = func(ctx context.Context) (net.Conn, error) {
		return net.Dial("tcp", ln.Addr().String())
	}
	l, err := c.dial(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	c.put(l)
	stream := testOpen(t, c, echoDst)
	if stream.kept() == nil {
		t.Fatal("expected a lane from the pool")
	}
	var proto protoError
	if _, err = stream.Read(make([]byte, 16)); !errors.As(err, &proto) {
		t.Fatalf("RAW on a plain connection: %v", err)
	}
}

// corkConn holds back what is written while corked and lets it go in one write:
// the reader then finds all of it in a single read off the socket.
type corkConn struct {
	net.Conn
	mu     sync.Mutex
	corked bool
	held   []byte
}

func (c *corkConn) Write(b []byte) (int, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.corked {
		c.held = append(c.held, b...)
		return len(b), nil
	}
	return c.Conn.Write(b)
}

func (c *corkConn) cork() {
	c.mu.Lock()
	c.corked = true
	c.mu.Unlock()
}

func (c *corkConn) uncork() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.corked = false
	held := c.held
	c.held = nil
	_, err := c.Conn.Write(held)
	return err
}

// Raw segments in and out of a real outer TLS connection, standard and uTLS
// (REALITY is a uTLS connection as well). The server side is a lane too, on a
// *tls.Conn, so both directions go through the same code.
func TestRawSegments(t *testing.T) {
	certPEM, keyPEM, _ := liveCert(t)
	pair, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		t.Fatal(err)
	}
	rec := func(typ byte, body []byte) []byte {
		return append([]byte{typ, 3, 3, byte(len(body) >> 8), byte(len(body))}, body...)
	}
	// a TLS 1.3 ServerHello, as far as recScan is concerned
	serverHello := append([]byte{2, 0, 0, 0, 3, 3}, make([]byte, 32)...)
	serverHello = append(serverHello, 0, 0x13, 0x01, 0, 0, 6, 0, 0x2b, 0, 2, 3, 4)
	// raw bytes that look like the start of an alert record: read through the TLS
	// connection they would be taken for one
	alert := []byte{0x15, 3, 3, 0, 2, 1, 0}
	big := make([]byte, 300<<10)
	for i := range big {
		big[i] = byte(i*31 + i>>8)
	}
	big[0] = 0x15

	for _, fingerprint := range []string{"", "chrome"} {
		fingerprint := fingerprint
		name := "tls"
		if fingerprint != "" {
			name = "utls"
		}
		t.Run(name, func(t *testing.T) {
			ln, err := net.Listen("tcp", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			defer ln.Close()
			c, err := NewClient(context.Background(), ClientConfig{PSK: testPSK})
			if err != nil {
				t.Fatal(err)
			}
			defer c.Close()
			events := &testEvents{m: map[string]int{}}
			c.observer = events.add
			c.minIdle = 0
			c.connect = func(ctx context.Context) (net.Conn, error) {
				conn, err := net.Dial("tcp", ln.Addr().String())
				if err != nil {
					return nil, err
				}
				return vmess.StreamTLSConn(ctx, conn, &vmess.TLSConfig{Host: "localhost", SkipCertVerify: true, ClientFingerprint: fingerprint})
			}

			// the server: past the handshake its steps are driven from here, one
			// at a time
			wires := make(chan *corkConn, 1)
			go func() {
				accepted, err := ln.Accept()
				if err != nil {
					close(wires)
					return
				}
				_ = accepted.SetDeadline(time.Now().Add(30 * time.Second))
				wires <- &corkConn{Conn: accepted}
			}()
			var wire *corkConn
			var serverConn *tls.Conn
			handshake := make(chan error, 1)
			go func() {
				if wire = <-wires; wire == nil {
					handshake <- io.ErrClosedPipe
					return
				}
				serverConn = tls.Server(wire, &tls.Config{Certificates: []tls.Certificate{pair}})
				handshake <- serverConn.Handshake()
			}()
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			conn, err := c.CreateProxy(ctx, echoDst)
			if err != nil {
				t.Fatal(err)
			}
			defer conn.Close()
			stream := conn.(*Stream)
			if !stream.lane().canRaw {
				t.Fatalf("no way into %T", stream.lane().conn)
			}
			if err = <-handshake; err != nil {
				t.Fatal(err)
			}
			defer wire.Close()
			// a client of its own, for the padding scheme a lane looks up there
			sc, err := NewClient(context.Background(), ClientConfig{PSK: testPSK})
			if err != nil {
				t.Fatal(err)
			}
			defer sc.Close()
			server := newLane(sc, serverConn)
			if !server.canRaw {
				t.Fatal("no way into the server connection")
			}
			// next returns the next frame the client sent, PAD left out, for RAW
			// the raw segment behind it
			next := func() (byte, []byte) {
				t.Helper()
				for {
					var head [frameHead + 4]byte
					n := 0
					if err := server.readMore(head[:frameHead], &n); err != nil {
						t.Fatal(err)
					}
					size := int(head[1])<<8 | int(head[2])
					if head[0] == frRaw {
						left, err := server.readRawLen(&head, &n)
						if err != nil {
							t.Fatal(err)
						}
						seg := make([]byte, left)
						for got := 0; got < len(seg); {
							k, err := server.readRaw(seg[got:])
							if err != nil {
								t.Fatal(err)
							}
							got += k
						}
						return frRaw, seg
					}
					payload := make([]byte, size)
					n = 0
					if err := server.readMore(payload, &n); err != nil {
						t.Fatal(err)
					}
					if head[0] != frPad {
						return head[0], payload
					}
				}
			}
			expect := func(typ byte, payload []byte) {
				t.Helper()
				if gotTyp, got := next(); gotTyp != typ || !bytes.Equal(got, payload) {
					t.Fatalf("frame type %d with %d bytes, want type %d with %d bytes", gotTyp, len(got), typ, len(payload))
				}
			}
			send := func(b []byte) {
				t.Helper()
				if err := server.write(b); err != nil {
					t.Fatal(err)
				}
			}
			// read reads exactly n bytes from the stream, in pieces of at most piece
			read := func(n, piece int) []byte {
				t.Helper()
				got := make([]byte, 0, n)
				b := make([]byte, piece)
				_ = stream.SetReadDeadline(time.Now().Add(10 * time.Second))
				for len(got) < n {
					k := n - len(got)
					if k > piece {
						k = piece
					}
					k, err := stream.Read(b[:k])
					if err != nil {
						t.Fatalf("after %d of %d bytes: %v", len(got), n, err)
					}
					got = append(got, b[:k]...)
				}
				return got
			}

			// the hello, then OPEN alone
			hello := make([]byte, authTokenLen+2+defaultAuthPadding)
			n := 0
			if err = server.readMore(hello, &n); err != nil {
				t.Fatal(err)
			}
			if typ, payload := next(); typ != frSettings || !strings.HasPrefix(string(payload), "v=2\nraw=1\n") {
				t.Fatalf("settings: %d %q", typ, payload)
			}
			send(appendFrame(nil, frServerSettings, []byte("v=2\nraw=1\nidle=60")))
			expect(frOpen, stream.dest)

			// The inner handshake: ClientHello up, ServerHello down, and with the
			// client's Finished the uplink may go raw.
			clientHello := rec(0x16, []byte{1, 0, 0, 0})
			if _, err = stream.Write(clientHello); err != nil {
				t.Fatal(err)
			}
			expect(frData, clientHello)
			if stream.wentRaw() {
				t.Fatal("raw before the ServerHello")
			}
			flight := rec(0x16, serverHello)
			send(appendFrame(nil, frData, flight))
			if got := read(len(flight), 7); !bytes.Equal(got, flight) {
				t.Fatal("ServerHello came back changed")
			}
			finished := append(rec(0x14, []byte{1}), rec(0x17, make([]byte, 40))...)
			if _, err = stream.Write(finished); err != nil {
				t.Fatal(err)
			}
			// the batch holding the record header still goes as DATA
			expect(frData, finished)
			if !stream.wentRaw() {
				t.Fatal("not raw after the handshake")
			}

			// uplink: a small batch is not worth a raw segment, it goes as DATA
			if _, err = stream.Write(alert); err != nil {
				t.Fatal(err)
			}
			expect(frData, alert)
			if _, err = stream.Write(big[:rawMin-1]); err != nil {
				t.Fatal(err)
			}
			expect(frData, big[:rawMin-1])
			// raw segments, starting like an alert record: one of the least size,
			// one larger than a single segment may be
			if _, err = stream.Write(big[:rawMin]); err != nil {
				t.Fatal(err)
			}
			expect(frRaw, big[:rawMin])
			huge := make([]byte, maxSeg+rawMin)
			copy(huge, big)
			go func() { _, _ = stream.Write(huge) }()
			expect(frRaw, huge[:maxSeg])
			expect(frRaw, huge[maxSeg:])

			// downlink, all of it arriving in one piece: DATA, a raw segment
			// starting like an alert record, DATA again
			wire.cork()
			send(appendFrame(nil, frData, []byte("abc")))
			if err = server.writeRaw(alert); err != nil {
				t.Fatal(err)
			}
			send(appendFrame(nil, frData, []byte("def")))
			if err = wire.uncork(); err != nil {
				t.Fatal(err)
			}
			want := append(append([]byte("abc"), alert...), "def"...)
			if got := read(len(want), 2); !bytes.Equal(got, want) {
				t.Fatalf("got %x, want %x", got, want)
			}
			// an empty one, then one arriving in pieces with frames right behind
			wire.cork()
			if err = server.writeRaw(nil); err != nil {
				t.Fatal(err)
			}
			send([]byte{frRaw, 0, 4, 0, 0, 0, 0})
			send(appendPad(nil, 5))
			if err = wire.uncork(); err != nil {
				t.Fatal(err)
			}
			go func() {
				_ = server.writeRaw(big)
				_ = server.write(appendFrame(appendFrame(nil, frData, []byte("tail")), frEnd, nil))
			}()
			if got := read(len(big), 4000); !bytes.Equal(got, big) {
				t.Fatal("raw segment came back changed")
			}
			if got := read(4, 16); string(got) != "tail" {
				t.Fatalf("after the raw segment: %q", got)
			}
			if k, err := stream.Read(make([]byte, 1)); k != 0 || err != io.EOF {
				t.Fatalf("END: %d %v", k, err)
			}
			if events.count("raw:in") != 3 || events.count("raw:out") != 3 {
				t.Fatalf("raw segments: in=%d out=%d", events.count("raw:in"), events.count("raw:out"))
			}

			// END behind raw segments, and the lane carries the next stream: back
			// in TLS records, and no longer raw
			l := stream.lane()
			stream.Close()
			expect(frEnd, nil)
			testWait(t, "the lane to go back", func() bool { return len(c.idleLanes()) == 1 })
			if c.idleLanes()[0] != l {
				t.Fatal("the lane did not go back")
			}
			second := testOpen(t, c, discardDst)
			if second.lane() != l {
				t.Fatal("the lane was not reused")
			}
			if _, err = second.Write([]byte("plain")); err != nil {
				t.Fatal(err)
			}
			expect(frOpen, second.dest)
			expect(frData, []byte("plain"))
			send(appendFrame(nil, frData, []byte("text")))
			stream = second
			if got := read(4, 16); string(got) != "text" || second.wentRaw() {
				t.Fatalf("second stream: %q", got)
			}
		})
	}
}
