package snell

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"testing/iotest"
	"time"

	"github.com/metacubex/mihomo/transport/shadowsocks/shadowaead"
)

var v6TestModes = []V6Mode{V6ModeDefault, V6ModeUnshaped, V6ModeUnsafeRaw}

const v6TestPSK = "snell-v6-unit-test-psk"

func v6TestProfile(mode V6Mode, psk []byte) *v6Profile {
	if mode == V6ModeDefault {
		return newV6Profile(psk)
	}
	return nil
}

func v6TestPattern(n int, seed int) []byte {
	b := make([]byte, n)
	for i := range b {
		b[i] = byte(i*131 + seed)
	}
	return b
}

// v6TestServer is an in-process peer that follows the reference server: it
// answers one request after another on the same connection, ends its half of
// every stream with a zero chunk and waits for the client's zero chunk before
// it reads the next request. The target host selects the behaviour.
type v6TestServer struct {
	t        testing.TB
	listener net.Listener
	mode     V6Mode
	psk      []byte
	profile  *v6Profile
	conns    atomic.Int32
	requests atomic.Int32
	wg       sync.WaitGroup
}

func newV6TestServer(t testing.TB, mode V6Mode) *v6TestServer {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	s := &v6TestServer{t: t, listener: listener, mode: mode, psk: []byte(v6TestPSK)}
	s.profile = v6TestProfile(mode, s.psk)
	s.wg.Add(1)
	go func() {
		defer s.wg.Done()
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			s.conns.Add(1)
			s.wg.Add(1)
			go func() {
				defer s.wg.Done()
				defer conn.Close()
				s.serve(conn)
			}()
		}
	}()
	t.Cleanup(func() {
		_ = listener.Close()
	})
	return s
}

func (s *v6TestServer) serve(conn net.Conn) {
	_ = conn.SetDeadline(time.Now().Add(30 * time.Second))
	reader := newV6RecordReader(conn, s.mode, s.psk, s.profile)
	writer, err := newV6RecordWriter(conn, s.mode, s.psk, s.profile)
	if err != nil {
		return
	}
	for {
		record, err := reader.readRecord()
		if err != nil {
			return
		}
		if len(record) < 3 || record[0] != Version {
			return
		}
		command := record[1]
		rest := record[3+int(record[2]):]
		s.requests.Add(1)
		switch command {
		case CommandUDP:
			// A datagram must not share the record with the tunnel request.
			if len(rest) != 0 {
				return
			}
			s.serveUDP(reader, writer)
			return
		case CommandConnectV2:
			hostLen := int(rest[0])
			host := string(rest[1 : 1+hostLen])
			port := int(binary.BigEndian.Uint16(rest[1+hostLen:]))
			reader.setCache(rest[1+hostLen+2:])
			if !s.serveStream(reader, writer, host, port) {
				return
			}
		default:
			return
		}
	}
}

// awaitClientEOF discards client data up to the client's zero chunk.
func (s *v6TestServer) awaitClientEOF(reader *v6RecordReader) bool {
	for {
		_, err := reader.nextRecord()
		if err == shadowaead.ErrZeroChunk {
			return true
		}
		if err != nil {
			return false
		}
	}
}

// serveStream reports whether the connection may carry another request.
func (s *v6TestServer) serveStream(reader *v6RecordReader, writer v6RecordWriter, host string, port int) bool {
	reply := []byte{CommandTunnel}
	switch host {
	case "echo", "echo-coalesced":
		// "echo" sends the reply in a record of its own, "echo-coalesced"
		// puts it in front of the first data like the reference server does.
		pending := reply
		if host == "echo" {
			if _, err := writer.Write(reply); err != nil {
				return false
			}
			pending = nil
		}
		buf := make([]byte, 32*1024)
		for {
			n, err := reader.Read(buf)
			if err == shadowaead.ErrZeroChunk {
				if len(pending) > 0 {
					if _, err := writer.Write(pending); err != nil {
						return false
					}
				}
				return writer.writeZeroChunk() == nil
			}
			if err != nil {
				return false
			}
			if _, err := writer.Write(append(pending, buf[:n]...)); err != nil {
				return false
			}
			pending = nil
		}
	case "source":
		// Sends port KiB of patterned data.
		if _, err := writer.Write(append(reply, v6TestPattern(port*1024, 7)...)); err != nil {
			return false
		}
		if writer.writeZeroChunk() != nil {
			return false
		}
		return s.awaitClientEOF(reader)
	case "sink":
		// Counts the client data and answers with the count.
		total := 0
		for {
			record, err := reader.nextRecord()
			if err == shadowaead.ErrZeroChunk {
				break
			}
			if err != nil {
				return false
			}
			total += len(record)
		}
		if _, err := writer.Write(append(reply, strconv.Itoa(total)...)); err != nil {
			return false
		}
		return writer.writeZeroChunk() == nil
	case "refuse":
		message := "Remote EOF"
		_, _ = writer.Write(append([]byte{CommandError, 0x65, byte(len(message))}, message...))
		return false
	case "hangup":
		// Closes the connection instead of sending a zero chunk.
		_, _ = writer.Write(append(reply, "bye"...))
		return false
	case "linger", "flood":
		// Keeps sending after the client finished: port bytes for "linger",
		// more than the discard limit for "flood".
		if _, err := writer.Write(append(reply, "hello"...)); err != nil {
			return false
		}
		if !s.awaitClientEOF(reader) {
			return false
		}
		tail := port
		if host == "flood" {
			tail = v6WaitingDiscardLimit + 4096
		}
		if _, err := writer.Write(v6TestPattern(tail, 3)); err != nil {
			return false
		}
		return writer.writeZeroChunk() == nil
	case "silent":
		// Never replies.
		s.awaitClientEOF(reader)
		return false
	default:
		return false
	}
}

type v6TestFrameWriter struct {
	writer v6RecordWriter
}

func (w v6TestFrameWriter) Write(b []byte) (int, error) {
	return w.WritePacketFrame(b)
}

func (w v6TestFrameWriter) WritePacketFrame(b []byte) (int, error) {
	return len(b), w.writer.writePacket(b)
}

// serveUDP echoes every datagram with its target as the source. A domain
// target is answered from 127.0.0.1 with the host name put before the payload.
func (s *v6TestServer) serveUDP(reader *v6RecordReader, writer v6RecordWriter) {
	if _, err := writer.Write([]byte{CommandTunnel}); err != nil {
		return
	}
	for {
		record, err := reader.nextRecord()
		if err != nil {
			return
		}
		request, err := ParseUDPRequest(record)
		if err != nil {
			return
		}
		source := &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: int(request.Port)}
		payload := request.Payload
		if request.Host != "" {
			payload = append([]byte(request.Host+"|"), payload...)
		} else {
			source.IP = request.Ip.AsSlice()
		}
		if _, err := WritePacketResponse(v6TestFrameWriter{writer}, source, payload); err != nil {
			return
		}
	}
}

func (s *v6TestServer) dial(ctx context.Context) (net.Conn, error) {
	var dialer net.Dialer
	return dialer.DialContext(ctx, "tcp", s.listener.Addr().String())
}

// client returns a client for the server and the counter of its dials.
func (s *v6TestServer) client(reuse bool) (*V6Client, *atomic.Int32) {
	dials := new(atomic.Int32)
	client, err := NewV6Client(V6Option{
		PSK:   s.psk,
		Mode:  s.mode,
		Reuse: reuse,
		Dial: func(ctx context.Context) (net.Conn, error) {
			dials.Add(1)
			return s.dial(ctx)
		},
	})
	if err != nil {
		s.t.Fatal(err)
	}
	s.t.Cleanup(func() {
		_ = client.Close()
	})
	return client, dials
}

// stream opens a request on a connection of its own.
func (s *v6TestServer) stream(client *V6Client, host string, port uint16) net.Conn {
	raw, err := s.dial(context.Background())
	if err != nil {
		s.t.Fatal(err)
	}
	_ = raw.SetDeadline(time.Now().Add(30 * time.Second))
	conn, err := client.StreamConn(raw, host, port)
	if err != nil {
		s.t.Fatal(err)
	}
	s.t.Cleanup(func() {
		_ = conn.Close()
	})
	return conn
}

func v6TestCloseWrite(t testing.TB, conn net.Conn) {
	if err := conn.(interface{ CloseWrite() error }).CloseWrite(); err != nil {
		t.Fatal(err)
	}
}

// v6TestEcho writes payload, half-closes and expects the echo followed by EOF.
func v6TestEcho(t testing.TB, conn net.Conn, payload []byte) {
	writeErr := make(chan error, 1)
	go func() {
		_, err := conn.Write(payload)
		writeErr <- err
	}()
	got := make([]byte, len(payload))
	if _, err := io.ReadFull(conn, got); err != nil {
		t.Fatalf("read echo: %v", err)
	}
	if !bytes.Equal(got, payload) {
		t.Fatal("echo mismatch")
	}
	if err := <-writeErr; err != nil {
		t.Fatalf("write: %v", err)
	}
	v6TestCloseWrite(t, conn)
	if n, err := conn.Read(make([]byte, 16)); n != 0 || err != io.EOF {
		t.Fatalf("expected EOF after half-close, got %d bytes, %v", n, err)
	}
	// EOF is sticky: what follows belongs to the next request.
	if n, err := conn.Read(make([]byte, 16)); n != 0 || err != io.EOF {
		t.Fatalf("expected EOF again, got %d bytes, %v", n, err)
	}
}

func v6TestEventually(t testing.TB, what string, condition func() bool) {
	deadline := time.Now().Add(10 * time.Second)
	for !condition() {
		if time.Now().After(deadline) {
			t.Fatalf("timeout waiting for %s", what)
		}
		time.Sleep(2 * time.Millisecond)
	}
}

func (p *v6Pool) testStates() []uint32 {
	p.access.Lock()
	defer p.access.Unlock()
	states := make([]uint32, 0, len(p.entries))
	for _, entry := range p.entries {
		states = append(states, entry.session.state.Load())
	}
	return states
}

func v6TestPoolReady(t testing.TB, client *V6Client, want int) {
	v6TestEventually(t, fmt.Sprintf("%d ready session(s)", want), func() bool {
		ready := 0
		for _, state := range client.pool.testStates() {
			if state == v6StateReady {
				ready++
			}
		}
		return ready == want
	})
}

func v6TestForModes(t *testing.T, run func(t *testing.T, mode V6Mode)) {
	for _, mode := range v6TestModes {
		mode := mode
		t.Run(mode.String(), func(t *testing.T) {
			run(t, mode)
		})
	}
}

func TestSnellV6ParseMode(t *testing.T) {
	for name, want := range map[string]V6Mode{
		"":           V6ModeDefault,
		"default":    V6ModeDefault,
		"unshaped":   V6ModeUnshaped,
		"unsafe-raw": V6ModeUnsafeRaw,
	} {
		got, err := ParseV6Mode(name)
		if err != nil || got != want {
			t.Fatalf("mode %q: got %v, %v", name, got, err)
		}
		if name != "" && got.String() != name {
			t.Fatalf("mode %q prints as %q", name, got.String())
		}
	}
	for _, name := range []string{"shaped", "Default", "raw", "unsafe_raw", " default"} {
		if _, err := ParseV6Mode(name); err == nil {
			t.Fatalf("mode %q should be rejected", name)
		}
	}
	if _, err := NewV6Client(V6Option{PSK: []byte("psk"), Mode: V6Mode(7)}); err == nil {
		t.Fatal("invalid mode value should be rejected")
	}
	if _, err := NewV6Client(V6Option{Mode: V6ModeDefault}); err == nil {
		t.Fatal("missing psk should be rejected")
	}
	if _, err := NewV6Client(V6Option{PSK: []byte("psk"), Reuse: true}); err == nil {
		t.Fatal("reuse without a dialer should be rejected")
	}
}

func TestSnellV6Request(t *testing.T) {
	request, err := v6AppendRequest(nil, CommandConnectV2, "example.com", 443)
	if err != nil {
		t.Fatal(err)
	}
	want := append([]byte{Version, CommandConnectV2, 0, 11}, "example.com"...)
	want = append(want, 0x01, 0xbb)
	if !bytes.Equal(request, want) {
		t.Fatalf("unexpected connect request: %x", request)
	}
	request, err = v6AppendRequest(nil, CommandUDP, "", 0)
	if err != nil || !bytes.Equal(request, []byte{Version, CommandUDP, 0}) {
		t.Fatalf("unexpected udp request: %x, %v", request, err)
	}
	if _, err = v6AppendRequest(nil, CommandConnectV2, strings.Repeat("a", 256), 1); err == nil {
		t.Fatal("over-long host should be rejected")
	}
}

func TestSnellV6ParseReply(t *testing.T) {
	rest, err := v6ParseReply([]byte{CommandTunnel, 'a', 'b'})
	if err != nil || string(rest) != "ab" {
		t.Fatalf("tunnel reply: %q, %v", rest, err)
	}
	rest, err = v6ParseReply([]byte{CommandTunnel})
	if err != nil || len(rest) != 0 {
		t.Fatalf("bare tunnel reply: %q, %v", rest, err)
	}
	_, err = v6ParseReply(append([]byte{CommandError, 0x65, 10}, "Remote EOF"...))
	if err == nil || !strings.Contains(err.Error(), "code: 101") || !strings.Contains(err.Error(), "Remote EOF") {
		t.Fatalf("error reply: %v", err)
	}
	for _, record := range [][]byte{
		{},
		{CommandError},
		{CommandError, 1, 5, 'x'},
		{CommandError, 1, 1, 'x', 'y'},
		{CommandPong},
		{9},
	} {
		if _, err = v6ParseReply(record); err == nil {
			t.Fatalf("reply %x should be rejected", record)
		}
	}
}

// TestSnellV6RecordRoundTrip sends stream data of awkward sizes, packets and
// zero chunks through a writer and reads them back, with reads that return
// one byte at a time as well.
func TestSnellV6RecordRoundTrip(t *testing.T) {
	v6TestForModes(t, func(t *testing.T, mode V6Mode) {
		psk := []byte(v6TestPSK)
		profile := v6TestProfile(mode, psk)
		limit := 1460
		if profile != nil {
			limit = profile.firstRecordCap
		}
		sizes := []int{1, 2, limit - 1, limit, limit + 1, 1460, 16383, 16384, 65535, 65536, 65537, 150000}
		packets := []int{1, 1200, 65535}

		var wire bytes.Buffer
		writer, err := newV6RecordWriter(&wire, mode, psk, profile)
		if err != nil {
			t.Fatal(err)
		}
		var streamData []byte
		for index, size := range sizes {
			chunk := v6TestPattern(size, index)
			streamData = append(streamData, chunk...)
			if n, err := writer.Write(chunk); err != nil || n != size {
				t.Fatalf("write %d bytes: %d, %v", size, n, err)
			}
		}
		if err := writer.writeZeroChunk(); err != nil {
			t.Fatal(err)
		}
		for index, size := range packets {
			if err := writer.writePacket(v6TestPattern(size, 100+index)); err != nil {
				t.Fatal(err)
			}
		}
		before := wire.Len()
		if err := writer.writePacket(nil); err != nil || wire.Len() != before {
			t.Fatalf("an empty packet must not be sent: %v", err)
		}
		if err := writer.writePacket(make([]byte, v6MaxPayload+1)); err != errV6PayloadTooLarge || wire.Len() != before {
			t.Fatalf("an oversized packet must be rejected: %v", err)
		}
		if n, err := writer.Write(nil); n != 0 || err != nil || wire.Len() != before {
			t.Fatalf("an empty write must not be sent: %d, %v", n, err)
		}
		if err := writer.writeZeroChunk(); err != nil {
			t.Fatal(err)
		}
		if _, err := writer.Write([]byte("next request")); err != nil {
			t.Fatal(err)
		}

		for _, oneByte := range []bool{false, true} {
			var source io.Reader = bytes.NewReader(wire.Bytes())
			if oneByte {
				source = iotest.OneByteReader(source)
			}
			reader := newV6RecordReader(source, mode, psk, profile)

			got := make([]byte, 0, len(streamData))
			buf := make([]byte, 4099)
			for {
				n, err := reader.Read(buf)
				got = append(got, buf[:n]...)
				if err == shadowaead.ErrZeroChunk {
					break
				}
				if err != nil {
					t.Fatalf("read stream: %v", err)
				}
			}
			if !bytes.Equal(got, streamData) {
				t.Fatalf("stream mismatch: got %d bytes, want %d", len(got), len(streamData))
			}
			for index, size := range packets {
				record, err := reader.nextRecord()
				if err != nil {
					t.Fatalf("read packet: %v", err)
				}
				if !bytes.Equal(record, v6TestPattern(size, 100+index)) {
					t.Fatalf("packet %d is not delivered as one record: got %d bytes", size, len(record))
				}
			}
			if _, err := reader.nextRecord(); err != shadowaead.ErrZeroChunk {
				t.Fatalf("expected the second zero chunk, got %v", err)
			}
			// A partial Read leaves the rest of the record for nextRecord.
			if n, err := reader.Read(buf[:4]); n != 4 || err != nil || string(buf[:4]) != "next" {
				t.Fatalf("partial read: %q, %v", buf[:n], err)
			}
			if record, err := reader.nextRecord(); err != nil || string(record) != " request" {
				t.Fatalf("rest of the record: %q, %v", record, err)
			}
			// The connection ends between two records.
			if _, err := reader.nextRecord(); err != io.EOF {
				t.Fatalf("expected EOF at the end of the connection, got %v", err)
			}
			if !reader.dead() {
				t.Fatal("the reader must be dead after the connection ended")
			}
		}
	})
}

// TestSnellV6RecordSizes checks how the writers cut stream data into records.
func TestSnellV6RecordSizes(t *testing.T) {
	v6TestForModes(t, func(t *testing.T, mode V6Mode) {
		psk := []byte(v6TestPSK)
		profile := v6TestProfile(mode, psk)
		var wire bytes.Buffer
		writer, err := newV6RecordWriter(&wire, mode, psk, profile)
		if err != nil {
			t.Fatal(err)
		}
		const total = 300000
		if _, err := writer.Write(v6TestPattern(total, 1)); err != nil {
			t.Fatal(err)
		}
		reader := newV6RecordReader(&wire, mode, psk, profile)
		var sizes []int
		sum := 0
		for sum < total {
			record, err := reader.readRecord()
			if err != nil {
				t.Fatal(err)
			}
			sizes = append(sizes, len(record))
			sum += len(record)
		}
		if mode != V6ModeDefault {
			// Records of the non-default modes are filled to the 16-bit limit.
			want := []int{v6MaxPayload, v6MaxPayload, v6MaxPayload, v6MaxPayload, total - 4*v6MaxPayload}
			if fmt.Sprint(sizes) != fmt.Sprint(want) {
				t.Fatalf("record sizes %v, want %v", sizes, want)
			}
			return
		}
		// The default mode starts below the first-record cap and never
		// exceeds the profile's largest chunk.
		if sizes[0] > profile.firstRecordCap {
			t.Fatalf("first record carries %d bytes, cap is %d", sizes[0], profile.firstRecordCap)
		}
		for _, size := range sizes {
			if size > profile.chunkMax {
				t.Fatalf("record carries %d bytes, chunk max is %d", size, profile.chunkMax)
			}
		}
	})
}

func TestSnellV6ReaderRejectsDamagedRecords(t *testing.T) {
	psk := []byte(v6TestPSK)
	record := func(mode V6Mode) []byte {
		var wire bytes.Buffer
		writer, err := newV6RecordWriter(&wire, mode, psk, v6TestProfile(mode, psk))
		if err != nil {
			t.Fatal(err)
		}
		if _, err := writer.Write(v6TestPattern(200, 1)); err != nil {
			t.Fatal(err)
		}
		return wire.Bytes()
	}
	read := func(mode V6Mode, wire []byte) (*v6RecordReader, error) {
		reader := newV6RecordReader(bytes.NewReader(wire), mode, psk, v6TestProfile(mode, psk))
		_, err := reader.readRecord()
		return reader, err
	}

	for _, mode := range []V6Mode{V6ModeDefault, V6ModeUnshaped} {
		wire := record(mode)
		// Every byte is covered: the salt block decides the key, the prefix
		// and the padding are authenticated, the rest is ciphertext.
		for _, position := range []int{0, len(wire) / 3, len(wire) / 2, len(wire) - 1} {
			damaged := append([]byte(nil), wire...)
			damaged[position] ^= 0x01
			reader, err := read(mode, damaged)
			if err == nil {
				// In the default mode a byte of the salt block that holds
				// no salt is plain filler; nothing else may be ignored.
				if mode == V6ModeDefault && position < v6TestProfile(mode, psk).saltBlockLen {
					continue
				}
				t.Fatalf("%s: damage at %d was not detected", mode, position)
			}
			if !reader.dead() {
				t.Fatalf("%s: the reader must be dead after a damaged record", mode)
			}
			if _, again := reader.readRecord(); again != err {
				t.Fatalf("%s: a dead reader must keep its error, got %v", mode, again)
			}
		}
		if _, err := read(mode, wire[:len(wire)-1]); err != io.ErrUnexpectedEOF {
			t.Fatalf("%s: a truncated record must be reported, got %v", mode, err)
		}
		wrong := newV6RecordReader(bytes.NewReader(wire), mode, []byte("another psk"), v6TestProfile(mode, []byte("another psk")))
		if _, err := wrong.readRecord(); err == nil {
			t.Fatalf("%s: a record of another key was accepted", mode)
		}
	}

	wire := record(V6ModeUnsafeRaw)
	for _, c := range []struct {
		position int
		value    byte
		want     error
	}{
		{0, 0x05, errV6BadVersion},
		{1, 0x01, errV6ReservedNonZero},
		{2, 0x01, errV6ReservedNonZero},
		{4, 0x01, errV6RecordPadding},
	} {
		damaged := append([]byte(nil), wire...)
		damaged[c.position] = c.value
		if _, err := read(V6ModeUnsafeRaw, damaged); err != c.want {
			t.Fatalf("raw header byte %d: got %v, want %v", c.position, err, c.want)
		}
	}
	if _, err := read(V6ModeUnsafeRaw, wire[:len(wire)-1]); err != io.ErrUnexpectedEOF {
		t.Fatalf("a truncated raw record must be reported, got %v", err)
	}
}

// TestSnellV6ReaderDeadline: a deadline that expires between two records can
// be retried, one that expires inside a record cannot.
func TestSnellV6ReaderDeadline(t *testing.T) {
	v6TestForModes(t, func(t *testing.T, mode V6Mode) {
		psk := []byte(v6TestPSK)
		profile := v6TestProfile(mode, psk)
		var wire bytes.Buffer
		writer, err := newV6RecordWriter(&wire, mode, psk, profile)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := writer.Write([]byte("first")); err != nil {
			t.Fatal(err)
		}
		first := append([]byte(nil), wire.Bytes()...)
		wire.Reset()
		if _, err := writer.Write([]byte("second")); err != nil {
			t.Fatal(err)
		}
		second := append([]byte(nil), wire.Bytes()...)

		local, remote := net.Pipe()
		defer local.Close()
		defer remote.Close()
		reader := newV6RecordReader(local, mode, psk, profile)

		_ = local.SetReadDeadline(time.Now().Add(20 * time.Millisecond))
		if _, err := reader.readRecord(); !v6IsTimeout(err) {
			t.Fatalf("expected a timeout before the first record, got %v", err)
		}
		if reader.dead() {
			t.Fatal("a timeout between records must not kill the reader")
		}

		_ = local.SetReadDeadline(time.Time{})
		go remote.Write(first)
		if record, err := reader.readRecord(); err != nil || string(record) != "first" {
			t.Fatalf("read after a timeout: %q, %v", record, err)
		}

		_ = local.SetReadDeadline(time.Now().Add(20 * time.Millisecond))
		if _, err := reader.readRecord(); !v6IsTimeout(err) || reader.dead() {
			t.Fatalf("expected a retryable timeout between records, got %v", err)
		}

		// Only the first bytes of the second record arrive in time.
		go remote.Write(second[:3])
		_ = local.SetReadDeadline(time.Now().Add(50 * time.Millisecond))
		_, err = reader.readRecord()
		if !v6IsTimeout(err) {
			t.Fatalf("expected a timeout inside the record, got %v", err)
		}
		if !reader.dead() {
			t.Fatal("a timeout inside a record must kill the reader")
		}
		_ = local.SetReadDeadline(time.Time{})
		if _, again := reader.readRecord(); again != err {
			t.Fatalf("a dead reader must keep its error, got %v", again)
		}
	})
}

func TestSnellV6StreamConn(t *testing.T) {
	v6TestForModes(t, func(t *testing.T, mode V6Mode) {
		server := newV6TestServer(t, mode)
		client, _ := server.client(false)

		for _, host := range []string{"echo", "echo-coalesced"} {
			v6TestEcho(t, server.stream(client, host, 80), v6TestPattern(100000, 1))
			// A stream without any client data.
			v6TestEcho(t, server.stream(client, host, 80), nil)
		}

		// Download.
		conn := server.stream(client, "source", 3000)
		got, err := io.ReadAll(conn)
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(got, v6TestPattern(3000*1024, 7)) {
			t.Fatalf("download mismatch: got %d bytes", len(got))
		}

		// Upload, then the answer after the half-close.
		conn = server.stream(client, "sink", 80)
		if _, err := conn.Write(v6TestPattern(2500000, 9)); err != nil {
			t.Fatal(err)
		}
		v6TestCloseWrite(t, conn)
		got, err = io.ReadAll(conn)
		if err != nil || string(got) != "2500000" {
			t.Fatalf("upload answer %q, %v", got, err)
		}

		// A server that closes the connection instead of sending a zero chunk.
		conn = server.stream(client, "hangup", 80)
		got, err = io.ReadAll(conn)
		if err != nil || string(got) != "bye" {
			t.Fatalf("hangup: %q, %v", got, err)
		}

		conn = server.stream(client, "refuse", 80)
		_, err = conn.Read(make([]byte, 16))
		if err == nil || !strings.Contains(err.Error(), "Remote EOF") {
			t.Fatalf("expected the server error, got %v", err)
		}
	})
}

// v6TestReuseEcho runs one echo request on a pooled connection.
func v6TestReuseEcho(t testing.TB, client *V6Client, host string, payload []byte) {
	conn, err := client.DialContext(context.Background(), host, 80)
	if err != nil {
		t.Fatal(err)
	}
	v6TestEcho(t, conn, payload)
	if err := conn.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestSnellV6Reuse(t *testing.T) {
	v6TestForModes(t, func(t *testing.T, mode V6Mode) {
		server := newV6TestServer(t, mode)
		client, dials := server.client(true)

		const requests = 6
		for index := 0; index < requests; index++ {
			host := "echo"
			if index%2 == 1 {
				host = "echo-coalesced"
			}
			v6TestReuseEcho(t, client, host, v6TestPattern(1000+index*30000, index))
			// Both zero chunks have passed, so Close pools the session at once.
			if states := client.pool.testStates(); len(states) != 1 || states[0] != v6StateReady {
				t.Fatalf("request %d: pool states %v", index, states)
			}
		}
		if dials.Load() != 1 || server.conns.Load() != 1 {
			t.Fatalf("%d requests used %d dials and %d server connections, want 1", requests, dials.Load(), server.conns.Load())
		}
		if server.requests.Load() != requests {
			t.Fatalf("the server saw %d requests, want %d", server.requests.Load(), requests)
		}

		// Two requests at the same time need two connections; both are kept.
		first, err := client.DialContext(context.Background(), "echo", 80)
		if err != nil {
			t.Fatal(err)
		}
		second, err := client.DialContext(context.Background(), "echo", 80)
		if err != nil {
			t.Fatal(err)
		}
		v6TestEcho(t, first, []byte("first"))
		v6TestEcho(t, second, []byte("second"))
		_ = first.Close()
		_ = second.Close()
		if dials.Load() != 2 {
			t.Fatalf("expected one more dial, got %d", dials.Load())
		}
		v6TestPoolReady(t, client, 2)
		v6TestReuseEcho(t, client, "echo", []byte("again"))
		if dials.Load() != 2 {
			t.Fatalf("pooled sessions were not used, %d dials", dials.Load())
		}

		// Closing the client closes the pool.
		if err := client.Close(); err != nil {
			t.Fatal(err)
		}
		if _, err := client.DialContext(context.Background(), "echo", 80); !errors.Is(err, net.ErrClosed) {
			t.Fatalf("dial on a closed client: %v", err)
		}
	})
}

// TestSnellV6ReuseClientClosesFirst covers both ways of closing a request
// before the server finished: without a pending read a drain is started, with
// one the pending read waits for the server's zero chunk.
func TestSnellV6ReuseClientClosesFirst(t *testing.T) {
	v6TestForModes(t, func(t *testing.T, mode V6Mode) {
		server := newV6TestServer(t, mode)
		client, dials := server.client(true)
		hello := make([]byte, 5)

		conn, err := client.DialContext(context.Background(), "linger", 20000)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := io.ReadFull(conn, hello); err != nil || string(hello) != "hello" {
			t.Fatalf("read: %q, %v", hello, err)
		}
		if err := conn.Close(); err != nil {
			t.Fatal(err)
		}
		if _, err := conn.Read(hello); !errors.Is(err, net.ErrClosed) {
			t.Fatalf("read on a closed request: %v", err)
		}
		if _, err := conn.Write(hello); !errors.Is(err, net.ErrClosed) {
			t.Fatalf("write on a closed request: %v", err)
		}
		// A late deadline must not reach the session, which is still
		// waiting for the server and is about to serve the next request.
		if err := conn.SetReadDeadline(time.Now()); !errors.Is(err, net.ErrClosed) {
			t.Fatalf("deadline on a closed request: %v", err)
		}
		v6TestPoolReady(t, client, 1)

		conn, err = client.DialContext(context.Background(), "linger", 20000)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := io.ReadFull(conn, hello); err != nil || string(hello) != "hello" {
			t.Fatalf("read: %q, %v", hello, err)
		}
		pending := make(chan error, 1)
		go func() {
			n, err := conn.Read(make([]byte, 64))
			if n != 0 {
				err = fmt.Errorf("the pending read returned %d bytes, %v", n, err)
			}
			pending <- err
		}()
		v6TestEventually(t, "the pending read", func() bool {
			return conn.(*v6ReuseConn).readActionCount.Load() == 1
		})
		// Give the read the few instructions it needs to block in the socket.
		time.Sleep(20 * time.Millisecond)
		if err := conn.Close(); err != nil {
			t.Fatal(err)
		}
		if err := <-pending; err != io.EOF {
			t.Fatalf("the pending read must end with EOF, got %v", err)
		}
		v6TestPoolReady(t, client, 1)

		v6TestReuseEcho(t, client, "echo", []byte("after"))
		if dials.Load() != 1 || server.conns.Load() != 1 {
			t.Fatalf("expected a single connection, got %d dials", dials.Load())
		}
	})
}

// TestSnellV6ReuseRequiresZeroChunk: sessions whose request did not end with
// the server's zero chunk are closed, and the next request gets a new one.
func TestSnellV6ReuseRequiresZeroChunk(t *testing.T) {
	v6TestForModes(t, func(t *testing.T, mode V6Mode) {
		server := newV6TestServer(t, mode)
		client, dials := server.client(true)
		expectDials := func(what string, want int32) {
			t.Helper()
			if states := client.pool.testStates(); len(states) != 0 {
				// A closed session may linger until the next sweep.
				for _, state := range states {
					if state != v6StateClosed {
						t.Fatalf("%s: pool states %v", what, states)
					}
				}
			}
			if dials.Load() != want {
				t.Fatalf("%s: %d dials, want %d", what, dials.Load(), want)
			}
		}

		// The server closes the connection like a server without reuse does.
		for index := 0; index < 3; index++ {
			conn, err := client.DialContext(context.Background(), "hangup", 80)
			if err != nil {
				t.Fatal(err)
			}
			got, err := io.ReadAll(conn)
			if err != nil || string(got) != "bye" {
				t.Fatalf("hangup: %q, %v", got, err)
			}
			_ = conn.Close()
		}
		expectDials("hangup", 3)

		// The server reports an error.
		conn, err := client.DialContext(context.Background(), "refuse", 80)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := conn.Read(make([]byte, 16)); err == nil || !strings.Contains(err.Error(), "Remote EOF") {
			t.Fatalf("expected the server error, got %v", err)
		}
		_ = conn.Close()
		expectDials("refuse", 4)

		// The request is closed before the reply was read.
		conn, err = client.DialContext(context.Background(), "silent", 80)
		if err != nil {
			t.Fatal(err)
		}
		_ = conn.Close()
		expectDials("close before reply", 5)

		// The server sends more than the discard limit after the client finished.
		conn, err = client.DialContext(context.Background(), "flood", 80)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := io.ReadFull(conn, make([]byte, 5)); err != nil {
			t.Fatal(err)
		}
		session := conn.(*v6ReuseConn).session
		_ = conn.Close()
		v6TestEventually(t, "the flooded session to close", func() bool {
			return session.state.Load() == v6StateClosed
		})
		expectDials("flood", 6)

		// A deadline that expires inside a record leaves the stream unusable.
		conn, err = client.DialContext(context.Background(), "linger", 80)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := io.ReadFull(conn, make([]byte, 5)); err != nil {
			t.Fatal(err)
		}
		conn.(*v6ReuseConn).session.reader.failed.Store(true)
		_ = conn.Close()
		expectDials("dead reader", 7)

		v6TestReuseEcho(t, client, "echo", []byte("still works"))
		if dials.Load() != 8 {
			t.Fatalf("expected a new connection after the failures, got %d dials", dials.Load())
		}
	})
}

func TestSnellV6ReuseDialContextCanceled(t *testing.T) {
	server := newV6TestServer(t, V6ModeDefault)
	client, _ := server.client(true)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := client.DialContext(ctx, "echo", 80); err == nil {
		t.Fatal("a canceled context must fail the dial")
	}
	if states := client.pool.testStates(); len(states) != 0 {
		t.Fatalf("pool states %v", states)
	}
	if _, err := client.DialContext(context.Background(), strings.Repeat("a", 256), 80); err == nil {
		t.Fatal("over-long host should be rejected")
	}
}

func TestSnellV6ReusePoolSize(t *testing.T) {
	server := newV6TestServer(t, V6ModeUnshaped)
	client, dials := server.client(true)
	const parallel = v6PoolSize + 3
	conns := make([]net.Conn, parallel)
	for index := range conns {
		conn, err := client.DialContext(context.Background(), "echo", 80)
		if err != nil {
			t.Fatal(err)
		}
		conns[index] = conn
	}
	for _, conn := range conns {
		v6TestEcho(t, conn, []byte("x"))
		_ = conn.Close()
	}
	if dials.Load() != parallel {
		t.Fatalf("%d dials, want %d", dials.Load(), parallel)
	}
	if states := client.pool.testStates(); len(states) != v6PoolSize {
		t.Fatalf("the pool holds %d sessions, want %d", len(states), v6PoolSize)
	}
}

func TestSnellV6ReusePoolExpiry(t *testing.T) {
	server := newV6TestServer(t, V6ModeDefault)
	client, dials := server.client(true)
	v6TestReuseEcho(t, client, "echo", []byte("first"))

	client.pool.access.Lock()
	if len(client.pool.entries) != 1 {
		client.pool.access.Unlock()
		t.Fatalf("the pool holds %d sessions, want 1", len(client.pool.entries))
	}
	entry := client.pool.entries[0]
	entry.time = time.Now().Add(-v6PoolMaxAge - time.Second)
	client.pool.access.Unlock()

	v6TestReuseEcho(t, client, "echo", []byte("second"))
	if dials.Load() != 2 {
		t.Fatalf("an expired session was used: %d dials", dials.Load())
	}
	if entry.session.state.Load() != v6StateClosed {
		t.Fatal("the expired session must be closed")
	}
	v6TestReuseEcho(t, client, "echo", []byte("third"))
	if dials.Load() != 2 {
		t.Fatalf("the fresh session was not reused: %d dials", dials.Load())
	}
}

func TestSnellV6ReuseConcurrent(t *testing.T) {
	v6TestForModes(t, func(t *testing.T, mode V6Mode) {
		server := newV6TestServer(t, mode)
		client, dials := server.client(true)
		const workers, rounds = 8, 12
		var wg sync.WaitGroup
		failures := make(chan error, workers)
		for worker := 0; worker < workers; worker++ {
			wg.Add(1)
			go func(worker int) {
				defer wg.Done()
				for round := 0; round < rounds; round++ {
					conn, err := client.DialContext(context.Background(), "echo", 80)
					if err != nil {
						failures <- err
						return
					}
					payload := v6TestPattern(5000+worker*777+round*313, worker*rounds+round)
					go conn.Write(payload)
					got := make([]byte, len(payload))
					if _, err := io.ReadFull(conn, got); err != nil || !bytes.Equal(got, payload) {
						failures <- fmt.Errorf("worker %d round %d: echo mismatch, %v", worker, round, err)
						return
					}
					// Alternate between a clean end and closing first.
					if round%2 == 0 {
						_ = conn.(*v6ReuseConn).CloseWrite()
						_, _ = io.Copy(io.Discard, conn)
					}
					_ = conn.Close()
				}
			}(worker)
		}
		wg.Wait()
		close(failures)
		for err := range failures {
			t.Fatal(err)
		}
		// How many requests find a ready session depends on timing; a clean
		// end pools the session at once, so some always do.
		if dials.Load() >= workers*rounds {
			t.Fatalf("%d dials for %d requests: sessions are not reused", dials.Load(), workers*rounds)
		}
		t.Logf("%d requests on %d connections", workers*rounds, dials.Load())
	})
}

type v6TestAddr string

func (a v6TestAddr) Network() string { return "udp" }
func (a v6TestAddr) String() string  { return string(a) }

func TestSnellV6PacketConn(t *testing.T) {
	v6TestForModes(t, func(t *testing.T, mode V6Mode) {
		server := newV6TestServer(t, mode)
		client, _ := server.client(false)
		raw, err := server.dial(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		defer raw.Close()
		_ = raw.SetDeadline(time.Now().Add(30 * time.Second))
		pc, err := client.StreamPacketConn(raw)
		if err != nil {
			t.Fatal(err)
		}
		if PacketConn(pc) != net.PacketConn(pc) {
			t.Fatal("PacketConn must return a v6 tunnel as it is")
		}

		buf := make([]byte, 65536)
		for index, target := range []net.Addr{
			&net.UDPAddr{IP: net.IPv4(192, 0, 2, 7), Port: 53},
			&net.UDPAddr{IP: net.ParseIP("2001:db8::7"), Port: 5353},
			v6TestAddr("example.com:443"),
		} {
			for _, size := range []int{1, 1200, 9000, 60000} {
				payload := v6TestPattern(size, index*10+size)
				if n, err := pc.WriteTo(payload, target); err != nil || n != size {
					t.Fatalf("write %d bytes to %v: %d, %v", size, target, n, err)
				}
				n, from, err := pc.ReadFrom(buf)
				if err != nil {
					t.Fatalf("read from %v: %v", target, err)
				}
				want := payload
				wantFrom := target.String()
				if _, isDomain := target.(v6TestAddr); isDomain {
					want = append([]byte("example.com|"), payload...)
					wantFrom = "127.0.0.1:443"
				}
				if from.String() != wantFrom {
					t.Fatalf("datagram from %v, want %v", from, wantFrom)
				}
				if !bytes.Equal(buf[:n], want) {
					t.Fatalf("datagram of %d bytes to %v came back as %d bytes", size, target, n)
				}
			}
		}

		// Datagrams are not merged, and a short buffer truncates one datagram.
		target := &net.UDPAddr{IP: net.IPv4(192, 0, 2, 9), Port: 9}
		for _, text := range []string{"one", "two", "three"} {
			if _, err := pc.WriteTo([]byte(text), target); err != nil {
				t.Fatal(err)
			}
		}
		for _, text := range []string{"one", "tw", "three"} {
			n, _, err := pc.ReadFrom(buf[:len(text)])
			if err != nil || string(buf[:n]) != text {
				t.Fatalf("datagram %q, %v, want %q", buf[:n], err, text)
			}
		}

		// The largest datagram fills the record; one more byte is rejected.
		headerLen := 1 + 2 + net.IPv4len + 2
		if _, err := pc.WriteTo(make([]byte, v6MaxPayload-headerLen+1), target); err != errV6PayloadTooLarge {
			t.Fatalf("oversized datagram: %v", err)
		}
		if n, err := pc.WriteTo(make([]byte, v6MaxPayload-headerLen), target); err != nil || n != v6MaxPayload-headerLen {
			t.Fatalf("largest datagram: %d, %v", n, err)
		}
		// Its echo is two bytes shorter in the header, so it fits as well.
		if n, _, err := pc.ReadFrom(buf); err != nil || n != v6MaxPayload-headerLen {
			t.Fatalf("largest datagram echo: %d, %v", n, err)
		}
	})
}

func TestSnellV6PacketConnReplyError(t *testing.T) {
	psk := []byte(v6TestPSK)
	local, remote := net.Pipe()
	defer local.Close()
	defer remote.Close()
	go func() {
		reader := newV6RecordReader(remote, V6ModeUnshaped, psk, nil)
		writer, _ := newV6RecordWriter(remote, V6ModeUnshaped, psk, nil)
		if record, err := reader.readRecord(); err != nil || !bytes.Equal(record, []byte{Version, CommandUDP, 0}) {
			_ = remote.Close()
			return
		}
		message := "udp disabled"
		_, _ = writer.Write(append([]byte{CommandError, 1, byte(len(message))}, message...))
	}()
	client, err := NewV6Client(V6Option{PSK: psk, Mode: V6ModeUnshaped})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := client.StreamPacketConn(local); err == nil || !strings.Contains(err.Error(), "udp disabled") {
		t.Fatalf("expected the server error, got %v", err)
	}
}

// StartV6TestServer starts the in-process peer for the tests of the external
// test package, which drive it through the outbound. It returns the server
// address, the pre-shared key and a counter of accepted connections.
func StartV6TestServer(t testing.TB, mode string) (address string, psk string, connections func() int) {
	parsed, err := ParseV6Mode(mode)
	if err != nil {
		t.Fatal(err)
	}
	server := newV6TestServer(t, parsed)
	return server.listener.Addr().String(), v6TestPSK, func() int {
		return int(server.conns.Load())
	}
}

// V6TestPattern is the data the "source" target of the in-process peer sends.
func V6TestPattern(n int) []byte {
	return v6TestPattern(n, 7)
}
