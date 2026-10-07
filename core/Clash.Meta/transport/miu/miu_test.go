package miu

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"testing"
	"time"

	"github.com/metacubex/mihomo/common/pool"
	"github.com/metacubex/mihomo/transport/anytls/util"
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
	psk := []byte("0123456789abcdef0123456789abcdef")
	ekm := bytes.Repeat([]byte{7}, ekmLen)

	// ver=1: 0x01 | HMAC(psk, ekm || 0x01) | padlen | padding
	head := buildAuthHeader(psk, ekm, 30)
	m := hmac.New(sha256.New, psk)
	m.Write(ekm)
	m.Write([]byte{roleClient})
	if len(head) != 1+32+2+30 || head[0] != authVersionEKM || !bytes.Equal(head[1:33], m.Sum(nil)) ||
		binary.BigEndian.Uint16(head[33:]) != 30 {
		t.Fatalf("ver=1 header: %x", head)
	}

	// ver=2: 0x02 | ts | nonce | HMAC(psk, ts || nonce || 0x01) | padlen
	head = buildAuthHeader(psk, nil, 0)
	if len(head) != 1+8+16+32+2 || head[0] != authVersionNonce {
		t.Fatalf("ver=2 header: %x", head)
	}
	m = hmac.New(sha256.New, psk)
	m.Write(head[1:25])
	m.Write([]byte{roleClient})
	if !bytes.Equal(head[25:57], m.Sum(nil)) {
		t.Fatal("ver=2 tag mismatch")
	}
	if ts := int64(binary.BigEndian.Uint64(head[1:9])); time.Now().Unix()-ts > 5 {
		t.Fatalf("ver=2 timestamp: %d", ts)
	}
}

func TestVerifyServerTag(t *testing.T) {
	psk := []byte("0123456789abcdef")
	ekm := bytes.Repeat([]byte{9}, ekmLen)
	good := hex.EncodeToString(authTagEKM(psk, ekm, roleServer))
	if err := verifyServerTag(util.StringMap{"srv": good}, psk, ekm); err != nil {
		t.Fatal(err)
	}
	// the client tag is not a valid server tag
	bad := hex.EncodeToString(authTagEKM(psk, ekm, roleClient))
	if err := verifyServerTag(util.StringMap{"srv": bad}, psk, ekm); err == nil {
		t.Fatal("wrong tag accepted")
	}
	// nothing to check without an exporter
	if err := verifyServerTag(util.StringMap{"srv": bad}, psk, nil); err != nil {
		t.Fatal(err)
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
	r := recvWindow{initial: 100}
	if r.consume(49) != 0 || r.consume(1) != 50 || r.consume(10) != 0 {
		t.Fatal("credit is returned once half of the window is consumed")
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
