package miu

import (
	"bytes"
	"encoding/binary"
	"net"
	"reflect"
	"strconv"
	"strings"
	"sync/atomic"
	"unsafe"

	tlsC "github.com/metacubex/mihomo/component/tls"
	"github.com/metacubex/mihomo/transport/anytls/padding"
	"github.com/metacubex/mihomo/transport/anytls/util"

	"github.com/metacubex/tls"
)

// lane is one TCP connection + the outer TLS + one authentication. It carries one
// stream at a time and goes back to the pool when that stream ended.
//
// Two things alternate on it: frames inside outer TLS records, and behind a RAW
// frame a raw segment written to the TCP connection as is. Reads and writes each
// come from one goroutine at a time, the stream sees to that.
type lane struct {
	c    *Client
	conn net.Conn // the outer TLS connection: frames
	raw  net.Conn // the connection below it: raw segments, and the liveness peek

	// buffers inside conn, see tlsBuffers
	in  *bytes.Reader
	rin *bytes.Buffer

	// canRaw: this end can take and send raw segments (the outer layer is a TLS
	// connection we can reach into). peerRaw: the server announced it takes them.
	canRaw  bool
	peerRaw atomic.Bool
	// seconds the server keeps an idle lane, from ServerSettings
	peerIdle atomic.Int64

	// taken out of the pool, so it may have died there unnoticed
	pooled bool
	// It carried a stream: ServerSettings is read and nothing may arrive while
	// it is idle. A prewarmed lane still has ServerSettings on its way in.
	used   bool
	closed atomic.Bool
}

// tlsBuffers reaches into the outer TLS connection the way XTLS-Vision does
// (reflect + unsafe): input holds what is decrypted and not read yet, rawInput
// what came off the socket and is not parsed yet, raw is the connection below.
// Standard TLS is a *tls.Conn, uTLS and REALITY are a *tlsC.UConn.
func tlsBuffers(conn net.Conn) (raw net.Conn, input *bytes.Reader, rawInput *bytes.Buffer, ok bool) {
	var t reflect.Type
	var p unsafe.Pointer
	switch c := conn.(type) {
	case *tls.Conn:
		raw, t, p = c.NetConn(), reflect.TypeOf(c).Elem(), unsafe.Pointer(c)
	case *tlsC.Conn:
		raw, t, p = c.NetConn(), reflect.TypeOf(c).Elem(), unsafe.Pointer(c)
	case *tlsC.UConn:
		raw, t, p = c.NetConn(), reflect.TypeOf(c.Conn).Elem(), unsafe.Pointer(c.Conn)
	default:
		return nil, nil, nil, false
	}
	i, ok1 := t.FieldByName("input")
	r, ok2 := t.FieldByName("rawInput")
	if raw == nil || p == nil || !ok1 || !ok2 ||
		i.Type != reflect.TypeOf(bytes.Reader{}) || r.Type != reflect.TypeOf(bytes.Buffer{}) {
		return nil, nil, nil, false
	}
	return raw, (*bytes.Reader)(unsafe.Add(p, i.Offset)), (*bytes.Buffer)(unsafe.Add(p, r.Offset)), true
}

func newLane(c *Client, conn net.Conn) *lane {
	l := &lane{c: c, conn: conn, raw: conn}
	if raw, in, rin, ok := tlsBuffers(conn); ok {
		l.raw, l.in, l.rin, l.canRaw = raw, in, rin, true
	}
	return l
}

func (l *lane) close() {
	if l.closed.CompareAndSwap(false, true) {
		_ = l.conn.Close()
	}
}

// settings is the payload of the Settings frame.
func (l *lane) settings(paddingMd5 string) []byte {
	raw := "0"
	if l.canRaw {
		raw = "1"
	}
	return []byte("v=2\nraw=" + raw + "\npadding-md5=" + paddingMd5)
}

// control handles the frames that belong to no stream. They may show up anywhere.
func (l *lane) control(typ byte, payload []byte) error {
	switch typ {
	case frPad:
	case frServerSettings:
		m := util.StringMapFromBytes(payload)
		l.peerRaw.Store(strings.TrimSpace(m["raw"]) == "1")
		if idle, err := strconv.ParseInt(strings.TrimSpace(m["idle"]), 10, 64); err == nil && idle > 0 {
			l.peerIdle.Store(idle)
		}
	case frUpdatePadding:
		padding.UpdatePaddingScheme(payload, &l.c.padding)
	default:
		return protoError("unexpected frame type " + strconv.Itoa(int(typ)))
	}
	return nil
}

// ---- read ----
//
// Frames are read on demand and never ahead: entering and leaving a raw segment
// needs the read position to line up with the TLS records, a buffered reader
// would swallow the raw bytes behind a RAW frame as if they were TLS plaintext.

// readMore fills b from the outer TLS connection, *n bytes of it are there
// already. It can be resumed after a timeout.
func (l *lane) readMore(b []byte, n *int) error {
	for *n < len(b) {
		k, err := l.conn.Read(b[*n:])
		*n += k
		if err != nil && *n < len(b) {
			return err
		}
	}
	return nil
}

// readRawLen finishes the body (u32) of a RAW frame, head holds the frame header
// and *n counts the bytes read so far.
//
// RAW is the last frame of its record and raw bytes follow. Once a record is
// read empty, Read of the TLS connection peeks at the first byte of rawInput and
// parses an alert record if it is 0x15 (all of metacubex/tls, utls and so REALITY
// do), but here that byte is raw data and may be anything. So the last byte does
// not go through Read: the first three do, which leaves one in input and no peek,
// and that one is taken out of input directly.
func (l *lane) readRawLen(head *[frameHead + 4]byte, n *int) (int64, error) {
	if !l.canRaw {
		return 0, protoError("unexpected RAW frame")
	}
	if err := l.readMore(head[:frameHead+3], n); err != nil {
		return 0, err
	}
	b, err := l.in.ReadByte()
	if err != nil || l.in.Len() != 0 {
		return 0, protoError("RAW frame is not the last frame of its record")
	}
	head[frameHead+3] = b
	return int64(binary.BigEndian.Uint32(head[frameHead:])), nil
}

// readRaw reads from the current raw segment, p must not be longer than what is
// left of it: first what the TLS connection already took off the socket, then
// the socket itself. Nothing is read beyond the segment, so nothing has to be
// handed back to the TLS connection.
func (l *lane) readRaw(p []byte) (int, error) {
	if l.rin.Len() > 0 {
		return l.rin.Read(p)
	}
	return l.raw.Read(p)
}

// ---- write ----

func (l *lane) write(p []byte) error {
	_, err := l.conn.Write(p)
	return err
}

// writePacket sends one packet, a run of frames. Within the stop of the padding
// scheme it is cut into TLS records of the prescribed sizes and filled up with
// PAD frames, otherwise it goes out in one write. A cut may fall inside a frame,
// the peer parses frames from the byte stream.
func (l *lane) writePacket(pkt uint32, p []byte) error {
	var sizes []int
	if scheme := l.c.padding.Load(); pkt < scheme.Stop {
		sizes = scheme.GenerateRecordPayloadSizes(pkt)
	}
	for _, size := range sizes {
		if size == padding.CheckMark {
			if len(p) == 0 {
				break
			}
			continue
		}
		if size <= frameHead || size >= 8192 {
			break // a broken scheme: the rest goes out unshaped
		}
		switch {
		case len(p) > size:
			if err := l.write(p[:size]); err != nil {
				return err
			}
			p = p[size:]
		case len(p) > 0:
			if pad := size - len(p) - frameHead; pad > 0 {
				p = appendPad(p, pad)
			}
			if err := l.write(p); err != nil {
				return err
			}
			p = nil
		default:
			if err := l.write(appendPad(nil, size)); err != nil {
				return err
			}
		}
	}
	if len(p) > 0 {
		return l.write(p)
	}
	return nil
}

// writePacketEnd sends a packet and, with end set, the END frame after it. END is
// never shaped and is the last byte of its direction: a PAD after it would reach
// the peer when the lane is already back in its pool, where pending data means
// the lane is being closed.
func (l *lane) writePacketEnd(pkt uint32, p []byte, end bool) error {
	if len(p) > 0 {
		if err := l.writePacket(pkt, p); err != nil {
			return err
		}
	}
	if !end {
		return nil
	}
	return l.write(appendFrame(nil, frEnd, nil))
}

// writeRaw sends p as raw segments: a record holding nothing but the RAW frame,
// then the bytes straight to the connection below the outer TLS. The connection
// is corked in between where that is possible, so that the few bytes of that
// record do not travel in a packet of their own.
func (l *lane) writeRaw(p []byte) error {
	for len(p) > 0 {
		seg := p
		if len(seg) > maxSeg {
			seg = seg[:maxSeg]
		}
		var head [frameHead + 4]byte
		head[0], head[2] = frRaw, 4
		binary.BigEndian.PutUint32(head[frameHead:], uint32(len(seg)))
		setCork(l.raw, true)
		err := l.write(head[:])
		if err == nil {
			_, err = l.raw.Write(seg)
		}
		setCork(l.raw, false)
		if err != nil {
			return err
		}
		l.c.observe("raw:out")
		p = p[len(seg):]
	}
	return nil
}

// ---- inner TLS ----

// recScan follows the TLS record boundaries of the inner data in one direction:
// a ServerHello tells whether the inner connection is TLS 1.3, and once it is, an
// application_data record header at a boundary means everything behind may go out
// raw. That is the condition XTLS-Vision switches to direct copy on, but tracked
// over the byte stream instead of requiring a read to line up with a record.
type recScan struct {
	tls13 *atomic.Bool // of the stream, both directions share it
	hdr   []byte
	need  int
	sh    []byte
	inSH  bool
	seen  int
	dead  bool
}

// feed takes the next bytes of the direction and reports whether what follows
// them may go out raw.
func (s *recScan) feed(b []byte) bool {
	if s.dead {
		return false
	}
	if s.seen += len(b); s.seen > sniffLimit {
		s.dead = true
		return false
	}
	for len(b) > 0 {
		if s.need > 0 {
			k := s.need
			if k > len(b) {
				k = len(b)
			}
			if s.inSH {
				s.sh = append(s.sh, b[:k]...)
			}
			s.need -= k
			b = b[k:]
			if s.need == 0 && s.inSH {
				s.inSH = false
				if isTLS13ServerHello(s.sh) {
					s.tls13.Store(true)
				}
				s.sh = nil
			}
			continue
		}
		k := 5 - len(s.hdr)
		if k > len(b) {
			k = len(b)
		}
		s.hdr = append(s.hdr, b[:k]...)
		b = b[k:]
		if len(s.hdr) < 5 {
			break
		}
		typ := s.hdr[0]
		if s.hdr[1] != 3 || typ < 0x14 || typ > 0x17 {
			s.dead = true // not TLS
			return false
		}
		if typ == 0x17 && s.tls13.Load() {
			return true
		}
		s.need = int(s.hdr[3])<<8 | int(s.hdr[4])
		s.inSH = typ == 0x16 && !s.tls13.Load()
		s.hdr = s.hdr[:0]
	}
	return false
}

// isTLS13ServerHello reports whether the handshake message is a ServerHello whose
// supported_versions extension selects 0x0304.
func isTLS13ServerHello(b []byte) bool {
	if len(b) < 4+2+32+1 || b[0] != 2 {
		return false
	}
	p := b[4+2+32:]
	sid := int(p[0])
	if len(p) < 1+sid+3+2 {
		return false
	}
	p = p[1+sid+3:]
	n := int(p[0])<<8 | int(p[1])
	if p = p[2:]; n < len(p) {
		p = p[:n]
	}
	for len(p) >= 4 {
		typ := int(p[0])<<8 | int(p[1])
		l := int(p[2])<<8 | int(p[3])
		if len(p) < 4+l {
			return false
		}
		if typ == 0x002b && l == 2 && p[4] == 3 && p[5] == 4 {
			return true
		}
		p = p[4+l:]
	}
	return false
}
