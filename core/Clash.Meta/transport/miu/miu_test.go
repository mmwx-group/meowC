package miu

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"os"
	"sync/atomic"
	"testing"
	"time"

	"github.com/metacubex/mihomo/common/pool"

	M "github.com/metacubex/sing/common/metadata"
)

func TestDecodePSK(t *testing.T) {
	raw := bytes.Repeat([]byte{0xfb, 0xef}, 16) // encodes to + / in std and - _ in url alphabet
	for _, enc := range []*base64.Encoding{base64.StdEncoding, base64.RawStdEncoding, base64.URLEncoding, base64.RawURLEncoding} {
		got, err := decodePSK(enc.EncodeToString(raw))
		if err != nil || !bytes.Equal(got, raw) {
			t.Fatalf("base64 psk: %x %v", got, err)
		}
	}
	// not base64: used as is
	if got, err := decodePSK("plain text psk !!"); err != nil || string(got) != "plain text psk !!" {
		t.Fatalf("raw psk: %q %v", got, err)
	}
	for _, bad := range []string{"", "short"} {
		if _, err := decodePSK(bad); err == nil {
			t.Fatalf("%q should be rejected", bad)
		}
	}
}

func TestAuthHeader(t *testing.T) {
	// token(32) | padlen(u16) | padding, token = sha256 of the PSK string itself
	const psk = "c2VjcmV0LXNlY3JldC1zZWNyZXQtc2VjcmV0LTEyMzQ="
	want := sha256.Sum256([]byte(psk))
	head := buildAuthHeader(authToken(psk), 30)
	if len(head) != 32+2+30 || !bytes.Equal(head[:32], want[:]) || binary.BigEndian.Uint16(head[32:]) != 30 ||
		!bytes.Equal(head[34:], make([]byte, 30)) {
		t.Fatalf("header: %x", head)
	}
	if head = buildAuthHeader(authToken(psk), 0); len(head) != 32+2 || binary.BigEndian.Uint16(head[32:]) != 0 {
		t.Fatalf("header without padding: %x", head)
	}

	// the client trims the configured string, hashes it undecoded for the token
	// and seeds Vision with the decoded key bytes
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	c, err := NewClient(ctx, ClientConfig{PSK: " " + psk + "\n"})
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	if c.token != want {
		t.Fatalf("token: %x", c.token)
	}
	key, _ := base64.StdEncoding.DecodeString(psk)
	seed := sha256.Sum256(key)
	if !bytes.Equal(c.visionSeed.Bytes(), seed[:16]) {
		t.Fatalf("vision seed: %x", c.visionSeed.Bytes())
	}
	if head = c.authHeader(); !bytes.Equal(head[:32], want[:]) || len(head) != 34+int(binary.BigEndian.Uint16(head[32:])) {
		t.Fatalf("client header: %x", head)
	}
}

func TestSendWindow(t *testing.T) {
	w := newSendWindow(10)
	if n, err := w.acquire(4); err != nil || n != 4 {
		t.Fatal(n, err)
	}
	// less credit than asked: take what is there instead of waiting
	if n, err := w.acquire(100); err != nil || n != 6 {
		t.Fatal(n, err)
	}
	done := make(chan int64, 1)
	go func() {
		n, _ := w.acquire(5)
		done <- n
	}()
	select {
	case <-done:
		t.Fatal("acquire should block without credit")
	case <-time.After(50 * time.Millisecond):
	}
	w.add(3)
	if n := <-done; n != 3 {
		t.Fatal(n)
	}
	w.close()
	if _, err := w.acquire(1); err != io.ErrClosedPipe {
		t.Fatal(err)
	}
}

func TestRecvWindow(t *testing.T) {
	now := time.Now()
	r := newRecvWindow(100, 100)
	if r.consume(49, now, 0) != 0 || r.consume(1, now, 0) != 50 || r.consume(10, now, 0) != 0 {
		t.Fatal("credit is returned once half of the window is consumed")
	}
}

// Two returns less than 2 x rtt apart = the peer is stalled by the window: it is
// doubled and the extra credit goes out with the return, up to the limit.
func TestRecvWindowAutoGrow(t *testing.T) {
	const rtt = 100 * time.Millisecond
	t0 := time.Now()
	r := newRecvWindow(100, 350)
	// nothing to compare the first return with: no growth
	if got := r.consume(50, t0, rtt); got != 50 {
		t.Fatalf("first return: %d", got)
	}
	// half a window again 50ms later: grows to 200, returns 50 + 100
	if got := r.consume(50, t0.Add(50*time.Millisecond), rtt); got != 150 {
		t.Fatalf("grow: %d", got)
	}
	// half a window is 100 now; far apart (held back by the network): no growth
	if got := r.consume(60, t0.Add(time.Second), rtt); got != 0 {
		t.Fatalf("below half: %d", got)
	}
	if got := r.consume(40, t0.Add(2*time.Second), rtt); got != 100 {
		t.Fatalf("slow return: %d", got)
	}
	// fast once more: only up to the limit of 350, 150 extra
	if got := r.consume(100, t0.Add(2*time.Second+10*time.Millisecond), rtt); got != 250 {
		t.Fatalf("grow to limit: %d", got)
	}
	// nothing extra once at the limit
	if got := r.consume(175, t0.Add(2*time.Second+20*time.Millisecond), rtt); got != 175 {
		t.Fatalf("at limit: %d", got)
	}
	// never grows without a measured rtt
	s := newRecvWindow(100, 350)
	s.consume(50, t0, 0)
	if got := s.consume(50, t0.Add(time.Millisecond), 0); got != 50 {
		t.Fatalf("no rtt: %d", got)
	}
	// a configured window above the limit is left alone
	if w := newRecvWindow(maxRecvWindow, autoRecvWindowMax); w.limit != maxRecvWindow {
		t.Fatalf("limit below the initial window: %d", w.limit)
	}
}

type closeRecorder struct {
	net.Conn
	closed atomic.Bool
}

func (c *closeRecorder) Close() error {
	c.closed.Store(true)
	return nil
}

func TestVisionSpares(t *testing.T) {
	var p visionSpares
	t0 := time.Now()
	// a single dial, and one long after the previous, is not a burst
	if n := p.demand(t0); n != 0 {
		t.Fatalf("first dial: %d", n)
	}
	t1 := t0.Add(visionBurstWindow + time.Second)
	if n := p.demand(t1); n != 0 {
		t.Fatalf("dial after the burst window: %d", n)
	}
	// the next one within the window fills the pool, what is being dialed counts
	t2 := t1.Add(visionBurstWindow)
	if n := p.demand(t2); n != visionSpareMax {
		t.Fatalf("burst: %d", n)
	}
	if n := p.demand(t2); n != 0 {
		t.Fatalf("pending dials are counted: %d", n)
	}
	// a failed dial is made up for by the next demand
	p.settle(nil)
	if n := p.demand(t2); n != 1 {
		t.Fatalf("after a failed dial: %d", n)
	}
	a, b := new(closeRecorder), new(closeRecorder)
	p.settle(a)
	p.settle(b)
	if n := p.demand(t2); n != 0 || len(p.ready) != visionSpareMax || p.pending != 0 {
		t.Fatalf("full pool: demand=%d ready=%d pending=%d", n, len(p.ready), p.pending)
	}

	// the newest spare goes first, taking it disarms its expiry
	spareB := p.ready[1]
	if got := p.take(); got != net.Conn(b) {
		t.Fatal("take should return the newest spare")
	}
	p.expire(spareB)
	if b.closed.Load() {
		t.Fatal("a spare in use must not be closed by its expiry")
	}
	if n := p.demand(t2); n != 1 {
		t.Fatalf("after take: %d", n)
	}
	// expiry closes the spare and drops it from the pool
	p.expire(p.ready[0])
	if !a.closed.Load() || p.take() != nil {
		t.Fatal("an expired spare should be closed and gone")
	}

	// close drops what is ready and whatever is still coming in
	c, d := new(closeRecorder), new(closeRecorder)
	p.settle(c)
	p.close()
	p.settle(d)
	if !c.closed.Load() || !d.closed.Load() || p.take() != nil {
		t.Fatal("close should close the spares")
	}
}

func TestUseVision(t *testing.T) {
	c := &Client{vision: true}
	if !c.useVision(M.ParseSocksaddrHostPort("example.com", 443)) {
		t.Fatal("port 443 should use Vision")
	}
	for _, port := range []uint16{80, 8443, 22} {
		if c.useVision(M.ParseSocksaddrHostPort("example.com", port)) {
			t.Fatalf("port %d should stay in MUX", port)
		}
	}
	c.visionRefused.Store(true)
	if c.useVision(M.ParseSocksaddrHostPort("example.com", 443)) {
		t.Fatal("a server refusing Vision only gets MUX streams")
	}
	c = &Client{}
	if c.useVision(M.ParseSocksaddrHostPort("example.com", 443)) {
		t.Fatal("Vision is off")
	}
}

func TestRecvQueue(t *testing.T) {
	push := func(q *recvQueue, s string) {
		b := pool.Get(len(s))
		copy(b, s)
		q.push(b)
	}
	q := newRecvQueue()
	push(q, "hello ")
	push(q, "world")
	q.close(io.EOF, false) // remote FIN: buffered data stays readable

	got, err := io.ReadAll(readerFunc(q.read))
	if err != nil || string(got) != "hello world" {
		t.Fatalf("%q %v", got, err)
	}
	if _, err = q.read(make([]byte, 1)); err != io.EOF {
		t.Fatal(err)
	}

	q = newRecvQueue()
	q.deadline.Set(time.Now().Add(20 * time.Millisecond))
	if _, err = q.read(make([]byte, 1)); !errors.Is(err, os.ErrDeadlineExceeded) {
		t.Fatal(err)
	}

	q = newRecvQueue()
	push(q, "dropped")
	q.close(io.ErrClosedPipe, true) // local close: buffered data is discarded
	if _, err = q.read(make([]byte, 8)); err != io.ErrClosedPipe {
		t.Fatal(err)
	}
}

type readerFunc func([]byte) (int, error)

func (f readerFunc) Read(p []byte) (int, error) { return f(p) }
