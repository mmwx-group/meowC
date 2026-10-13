// Snell v6 record layer.
//
// Ported from github.com/sagernet/sing-snell (snellv6/record.go, shaped.go
// and handshake.go), Copyright (C) 2022 by nekohasekai
// <contact-sagernet@sekai.icu>, licensed under the GNU General Public License
// v3.0 or later. The buffer and vectorised-write plumbing of the original is
// replaced with plain io.Reader / io.Writer code; the bytes on the wire are
// unchanged.
//
// Record layout per mode ("header" is version 0x04, two reserved zero bytes,
// padding length and payload length, both big endian):
//
//	unsafe-raw: header(7) | payload
//	unshaped:   [salt(16), first record only] | sealed header(23) | sealed payload(n+16)
//	default:    [salt block, first record only] | prefix | sealed header(23, AAD = prefix)
//	            | padding | sealed payload(n+16, AAD = padding)
//
// In the default mode the padding and the sealed payload are mixed after
// sealing, and every length is taken from the profile derived from the PSK.
// A record whose payload length is zero ends the logical stream in that
// direction; the connection itself stays usable for the next request.

package snell

import (
	"crypto/cipher"
	"crypto/rand"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"sync"
	"sync/atomic"
	"time"

	"github.com/metacubex/mihomo/transport/shadowsocks/shadowaead"
)

const (
	v6HeaderVersion   = 0x04
	v6HeaderPlainLen  = 7
	v6TagLen          = 16
	v6HeaderCipherLen = v6HeaderPlainLen + v6TagLen
	v6SaltLen         = 16
	v6NonceLen        = 12

	// v6MaxPayload is the largest payload of one record. Unlike v4 the whole
	// 16-bit length field is usable.
	v6MaxPayload = 0xffff

	// v6ScratchKeep bounds the scratch buffer a writer keeps between calls.
	v6ScratchKeep = 128 * 1024
)

var (
	errV6BadVersion      = errors.New("snell: bad header version")
	errV6ReservedNonZero = errors.New("snell: reserved header octet is non-zero")
	errV6RecordPadding   = errors.New("snell: unexpected padding in non-default record")
	errV6PayloadTooLarge = errors.New("snell: payload length exceeds maximum")
)

func v6PutHeader(header []byte, paddingLen int, payloadLen int) {
	header[0] = v6HeaderVersion
	header[1] = 0
	header[2] = 0
	binary.BigEndian.PutUint16(header[3:5], uint16(paddingLen))
	binary.BigEndian.PutUint16(header[5:7], uint16(payloadLen))
}

func v6ParseHeader(header []byte) (paddingLen int, payloadLen int, err error) {
	if header[0] != v6HeaderVersion {
		return 0, 0, errV6BadVersion
	}
	if header[1] != 0 || header[2] != 0 {
		return 0, 0, errV6ReservedNonZero
	}
	return int(binary.BigEndian.Uint16(header[3:5])), int(binary.BigEndian.Uint16(header[5:7])), nil
}

// v6Extend grows b by n bytes and returns the grown slice and the new region.
func v6Extend(b []byte, n int) ([]byte, []byte) {
	length := len(b)
	if cap(b)-length < n {
		grown := make([]byte, length, length+n+length/2)
		copy(grown, b)
		b = grown
	}
	b = b[:length+n]
	return b, b[length:]
}

// v6Scratch returns a slice of length n backed by *buf, reallocating it when
// it is too small.
func v6Scratch(buf *[]byte, n int) []byte {
	if cap(*buf) < n {
		*buf = make([]byte, n)
	}
	return (*buf)[:n]
}

func v6IsTimeout(err error) bool {
	var netErr net.Error
	return errors.As(err, &netErr) && netErr.Timeout()
}

// v6RecordWriter is the sending half of a v6 connection.
type v6RecordWriter interface {
	// Write sends p as stream data, split into as many records as the mode requires.
	io.Writer
	// writePacket sends payload as exactly one record. An empty payload is not sent.
	writePacket(payload []byte) error
	// writeZeroChunk sends the end-of-stream record.
	writeZeroChunk() error
}

func newV6RecordWriter(upstream io.Writer, mode V6Mode, psk []byte, profile *v6Profile) (v6RecordWriter, error) {
	if mode == V6ModeUnsafeRaw {
		return &v6RawWriter{upstream: upstream}, nil
	}
	var salt [v6SaltLen]byte
	if _, err := io.ReadFull(rand.Reader, salt[:]); err != nil {
		return nil, err
	}
	return newV6RecordWriterWithSalt(upstream, mode, psk, profile, salt)
}

func newV6RecordWriterWithSalt(upstream io.Writer, mode V6Mode, psk []byte, profile *v6Profile, salt [v6SaltLen]byte) (v6RecordWriter, error) {
	switch mode {
	case V6ModeUnsafeRaw:
		return &v6RawWriter{upstream: upstream}, nil
	case V6ModeUnshaped:
		aead, err := v4AEAD(psk, salt[:])
		if err != nil {
			return nil, err
		}
		return &v6UnshapedWriter{upstream: upstream, aead: aead, salt: salt}, nil
	case V6ModeDefault:
		aead, err := v4AEAD(psk, salt[:])
		if err != nil {
			return nil, err
		}
		return &v6ShapedWriter{upstream: upstream, profile: profile, aead: aead, salt: salt}, nil
	default:
		return nil, fmt.Errorf("snell: unknown v6 mode: %d", int(mode))
	}
}

// v6ShapedWriter writes default-mode records.
type v6ShapedWriter struct {
	upstream      io.Writer
	profile       *v6Profile
	aead          cipher.AEAD
	salt          [v6SaltLen]byte
	nonce         [v6NonceLen]byte
	seq           uint32
	saltSent      bool
	chunkSize     int
	lastWriteUnix int64
	access        sync.Mutex
	scratch       []byte
}

// appendRecord appends one sealed record carrying payload to out. An empty
// payload produces the zero chunk.
func (w *v6ShapedWriter) appendRecord(out []byte, payload []byte) []byte {
	prefixLen := w.profile.recordPrefixLen(w.seq)
	saltBlockLen := 0
	saltPrefixLen := 0
	if !w.saltSent {
		saltBlockLen = w.profile.saltBlockLen
		saltPrefixLen = saltBlockLen - v6SaltLen
	}
	paddingLen := w.profile.paddingLen(w.seq, len(payload), prefixLen, saltPrefixLen, saltBlockLen)
	payloadCipherLen := 0
	if len(payload) > 0 {
		payloadCipherLen = len(payload) + v6TagLen
	}
	out, record := v6Extend(out, saltBlockLen+prefixLen+v6HeaderCipherLen+paddingLen+payloadCipherLen)

	if saltBlockLen > 0 {
		block := record[:saltBlockLen]
		// The salt block is filled with shaped padding at the sentinel
		// sequence 0xffffffff before the salt positions are overwritten.
		w.profile.fillPadding(0xffffffff, block)
		w.profile.writeSaltBlock(w.salt[:], block)
		w.saltSent = true
		record = record[saltBlockLen:]
	}
	prefix := record[:prefixLen]
	w.profile.fillPadding(w.seq, prefix)

	header := record[prefixLen : prefixLen+v6HeaderCipherLen]
	v6PutHeader(header, paddingLen, len(payload))
	w.aead.Seal(header[:0], w.nonce[:], header[:v6HeaderPlainLen], prefix)
	incrementV4Nonce(w.nonce[:])

	padding := record[prefixLen+v6HeaderCipherLen : prefixLen+v6HeaderCipherLen+paddingLen]
	w.profile.fillPadding(w.seq, padding)
	if len(payload) > 0 {
		region := record[prefixLen+v6HeaderCipherLen+paddingLen:]
		copy(region, payload)
		w.aead.Seal(region[:0], w.nonce[:], region[:len(payload)], padding)
		incrementV4Nonce(w.nonce[:])
		w.profile.mixPaddingPayload(w.seq, padding, region)
	}
	w.seq++
	return out
}

// payloadLimitFor returns the payload limit of the next record and advances
// the dynamic chunk state. The idle reset is second-granular.
func (w *v6ShapedWriter) payloadLimitFor(now time.Time) int {
	nowUnix := now.Unix()
	if w.lastWriteUnix == 0 || nowUnix-w.lastWriteUnix > int64(w.profile.idleResetSec) {
		w.chunkSize = w.profile.chunkInitial
	}
	if w.chunkSize == 0 {
		w.chunkSize = w.profile.chunkInitial
	}
	payloadLimit := w.profile.chunkPayloadLimit(w.seq, w.chunkSize)
	if w.seq == 0 {
		payloadLimit = v6Min(payloadLimit, w.profile.firstRecordCap)
	}
	w.chunkSize = w.profile.nextChunkSize(w.chunkSize)
	w.lastWriteUnix = nowUnix
	return v6Max(1, v6Min(payloadLimit, v6MaxPayload))
}

func (w *v6ShapedWriter) flush(out []byte) error {
	_, err := w.upstream.Write(out)
	if cap(out) <= v6ScratchKeep {
		w.scratch = out[:0]
	} else {
		w.scratch = nil
	}
	return err
}

// Write splits p by the dynamic chunk limit and sends all resulting records
// with a single write to the underlying connection.
func (w *v6ShapedWriter) Write(p []byte) (int, error) {
	w.access.Lock()
	defer w.access.Unlock()
	if len(p) == 0 {
		return 0, nil
	}
	now := time.Now()
	total := len(p)
	out := w.scratch[:0]
	for len(p) > 0 {
		payloadLimit := w.payloadLimitFor(now)
		recordLen := v6Min(len(p), payloadLimit)
		out = w.appendRecord(out, p[:recordLen])
		p = p[recordLen:]
	}
	if err := w.flush(out); err != nil {
		return 0, err
	}
	return total, nil
}

// writePacket still advances the dynamic chunk state, but emits the whole
// datagram as one record regardless of the current stream chunk limit.
func (w *v6ShapedWriter) writePacket(payload []byte) error {
	if len(payload) == 0 {
		return nil
	}
	if len(payload) > v6MaxPayload {
		return errV6PayloadTooLarge
	}
	w.access.Lock()
	defer w.access.Unlock()
	w.payloadLimitFor(time.Now())
	return w.flush(w.appendRecord(w.scratch[:0], payload))
}

func (w *v6ShapedWriter) writeZeroChunk() error {
	w.access.Lock()
	defer w.access.Unlock()
	w.payloadLimitFor(time.Now())
	return w.flush(w.appendRecord(w.scratch[:0], nil))
}

// v6UnshapedWriter writes unshaped-mode records: the salt in clear once, then
// sealed headers and payloads without padding.
type v6UnshapedWriter struct {
	upstream io.Writer
	aead     cipher.AEAD
	salt     [v6SaltLen]byte
	nonce    [v6NonceLen]byte
	saltSent bool
	access   sync.Mutex
	scratch  []byte
}

func (w *v6UnshapedWriter) appendRecord(out []byte, payload []byte) []byte {
	if !w.saltSent {
		out = append(out, w.salt[:]...)
		w.saltSent = true
	}
	payloadCipherLen := 0
	if len(payload) > 0 {
		payloadCipherLen = len(payload) + v6TagLen
	}
	out, record := v6Extend(out, v6HeaderCipherLen+payloadCipherLen)
	header := record[:v6HeaderCipherLen]
	v6PutHeader(header, 0, len(payload))
	w.aead.Seal(header[:0], w.nonce[:], header[:v6HeaderPlainLen], nil)
	incrementV4Nonce(w.nonce[:])
	if len(payload) > 0 {
		region := record[v6HeaderCipherLen:]
		copy(region, payload)
		w.aead.Seal(region[:0], w.nonce[:], region[:len(payload)], nil)
		incrementV4Nonce(w.nonce[:])
	}
	return out
}

func (w *v6UnshapedWriter) flush(out []byte) error {
	_, err := w.upstream.Write(out)
	if cap(out) <= v6ScratchKeep {
		w.scratch = out[:0]
	} else {
		w.scratch = nil
	}
	return err
}

// Write splits p into 0xffff-byte records. The first payload of a connection
// goes out together with the salt in a single write; later records are
// written one by one.
func (w *v6UnshapedWriter) Write(p []byte) (int, error) {
	w.access.Lock()
	defer w.access.Unlock()
	first := !w.saltSent
	written := 0
	pending := 0
	out := w.scratch[:0]
	for len(p) > 0 {
		recordLen := v6Min(len(p), v6MaxPayload)
		out = w.appendRecord(out, p[:recordLen])
		p = p[recordLen:]
		pending += recordLen
		if first && len(p) > 0 {
			continue
		}
		if err := w.flush(out); err != nil {
			return written, err
		}
		written += pending
		pending = 0
		out = w.scratch[:0]
	}
	return written, nil
}

func (w *v6UnshapedWriter) writePacket(payload []byte) error {
	if len(payload) == 0 {
		return nil
	}
	if len(payload) > v6MaxPayload {
		return errV6PayloadTooLarge
	}
	w.access.Lock()
	defer w.access.Unlock()
	return w.flush(w.appendRecord(w.scratch[:0], payload))
}

func (w *v6UnshapedWriter) writeZeroChunk() error {
	w.access.Lock()
	defer w.access.Unlock()
	return w.flush(w.appendRecord(w.scratch[:0], nil))
}

// v6RawWriter writes unsafe-raw records: a clear header and the clear payload.
type v6RawWriter struct {
	upstream io.Writer
	access   sync.Mutex
	scratch  []byte
}

func (w *v6RawWriter) writeRecord(payload []byte) error {
	out, record := v6Extend(w.scratch[:0], v6HeaderPlainLen+len(payload))
	v6PutHeader(record[:v6HeaderPlainLen], 0, len(payload))
	copy(record[v6HeaderPlainLen:], payload)
	_, err := w.upstream.Write(out)
	if cap(out) <= v6ScratchKeep {
		w.scratch = out[:0]
	} else {
		w.scratch = nil
	}
	return err
}

func (w *v6RawWriter) Write(p []byte) (int, error) {
	w.access.Lock()
	defer w.access.Unlock()
	written := 0
	for len(p) > 0 {
		recordLen := v6Min(len(p), v6MaxPayload)
		if err := w.writeRecord(p[:recordLen]); err != nil {
			return written, err
		}
		p = p[recordLen:]
		written += recordLen
	}
	return written, nil
}

func (w *v6RawWriter) writePacket(payload []byte) error {
	if len(payload) == 0 {
		return nil
	}
	if len(payload) > v6MaxPayload {
		return errV6PayloadTooLarge
	}
	w.access.Lock()
	defer w.access.Unlock()
	return w.writeRecord(payload)
}

func (w *v6RawWriter) writeZeroChunk() error {
	w.access.Lock()
	defer w.access.Unlock()
	return w.writeRecord(nil)
}

// v6RecordReader is the receiving half of a v6 connection.
//
// readRecord reports the end-of-stream record as shadowaead.ErrZeroChunk, the
// same sentinel the v4 reader uses, so that callers can tell it apart from
// io.EOF, which here always means that the underlying connection ended
// between two records. The distinction decides whether a connection may be
// reused.
//
// A read that fails without consuming any byte of a record because of a
// deadline leaves the reader intact and may be retried. Every other failure
// is permanent: bytes of the stream are lost or the connection is gone.
//
// The returned payload aliases an internal buffer and is only valid until the
// next call. The reader is not safe for concurrent use; dead may be called
// from any goroutine.
type v6RecordReader struct {
	upstream io.Reader
	mode     V6Mode
	psk      []byte
	profile  *v6Profile

	aead  cipher.AEAD
	nonce [v6NonceLen]byte
	seq   uint32

	cache   []byte
	head    []byte
	padding []byte
	body    []byte

	consumed bool
	failed   atomic.Bool
	err      error
}

func newV6RecordReader(upstream io.Reader, mode V6Mode, psk []byte, profile *v6Profile) *v6RecordReader {
	return &v6RecordReader{upstream: upstream, mode: mode, psk: psk, profile: profile}
}

// dead reports whether the reader failed permanently.
func (r *v6RecordReader) dead() bool {
	return r.failed.Load()
}

func (r *v6RecordReader) readFull(p []byte) error {
	n, err := io.ReadFull(r.upstream, p)
	if n > 0 {
		r.consumed = true
	}
	return err
}

// readRecord reads the next record from the connection, bypassing the cache.
func (r *v6RecordReader) readRecord() ([]byte, error) {
	if r.failed.Load() {
		return nil, r.err
	}
	r.consumed = false
	var (
		payload []byte
		err     error
	)
	switch r.mode {
	case V6ModeUnsafeRaw:
		payload, err = r.readRaw()
	case V6ModeUnshaped:
		payload, err = r.readUnshaped()
	default:
		payload, err = r.readShaped()
	}
	if err != nil && err != shadowaead.ErrZeroChunk {
		if r.consumed || !v6IsTimeout(err) {
			if r.consumed && err == io.EOF {
				err = io.ErrUnexpectedEOF
			}
			r.err = err
			r.failed.Store(true)
		}
		return nil, err
	}
	return payload, err
}

// nextRecord returns the unread part of the current record if there is one,
// otherwise the next record.
func (r *v6RecordReader) nextRecord() ([]byte, error) {
	if len(r.cache) > 0 {
		record := r.cache
		r.cache = nil
		return record, nil
	}
	return r.readRecord()
}

func (r *v6RecordReader) setCache(cache []byte) {
	r.cache = cache
}

// Read reads stream data across record boundaries.
func (r *v6RecordReader) Read(p []byte) (int, error) {
	for len(r.cache) == 0 {
		record, err := r.readRecord()
		if err != nil {
			return 0, err
		}
		r.cache = record
	}
	n := copy(p, r.cache)
	r.cache = r.cache[n:]
	return n, nil
}

func (r *v6RecordReader) readShaped() ([]byte, error) {
	if r.aead == nil {
		block := v6Scratch(&r.padding, r.profile.saltBlockLen)
		if err := r.readFull(block); err != nil {
			return nil, err
		}
		salt := r.profile.extractSalt(block)
		aead, err := v4AEAD(r.psk, salt[:])
		if err != nil {
			return nil, err
		}
		r.aead = aead
		// The salt block is complete and its result is kept, so a deadline
		// that expires before the first header arrives stays retryable.
		r.consumed = false
	}

	prefixLen := r.profile.recordPrefixLen(r.seq)
	head := v6Scratch(&r.head, prefixLen+v6HeaderCipherLen)
	if err := r.readFull(head); err != nil {
		return nil, err
	}
	prefix := head[:prefixLen]
	headerCipher := head[prefixLen:]
	if _, err := r.aead.Open(headerCipher[:0], r.nonce[:], headerCipher, prefix); err != nil {
		return nil, fmt.Errorf("snell: open shaped header: %w", err)
	}
	incrementV4Nonce(r.nonce[:])
	if headerCipher[0] != v6HeaderVersion {
		return nil, errV6BadVersion
	}
	// The default-mode reader ignores the two reserved header bytes.
	paddingLen := int(binary.BigEndian.Uint16(headerCipher[3:5]))
	payloadLen := int(binary.BigEndian.Uint16(headerCipher[5:7]))
	seq := r.seq
	r.seq++

	if payloadLen == 0 {
		if paddingLen > 0 {
			if err := r.readFull(v6Scratch(&r.padding, paddingLen)); err != nil {
				return nil, err
			}
		}
		return nil, shadowaead.ErrZeroChunk
	}

	var padding []byte
	if paddingLen > 0 {
		padding = v6Scratch(&r.padding, paddingLen)
		if err := r.readFull(padding); err != nil {
			return nil, err
		}
	}
	body := v6Scratch(&r.body, payloadLen+v6TagLen)
	if err := r.readFull(body); err != nil {
		return nil, err
	}
	r.profile.mixPaddingPayload(seq, padding, body)
	if _, err := r.aead.Open(body[:0], r.nonce[:], body, padding); err != nil {
		return nil, fmt.Errorf("snell: open shaped payload: %w", err)
	}
	incrementV4Nonce(r.nonce[:])
	return body[:payloadLen], nil
}

func (r *v6RecordReader) readUnshaped() ([]byte, error) {
	if r.aead == nil {
		salt := v6Scratch(&r.head, v6SaltLen)
		if err := r.readFull(salt); err != nil {
			return nil, err
		}
		aead, err := v4AEAD(r.psk, salt)
		if err != nil {
			return nil, err
		}
		r.aead = aead
		r.consumed = false
	}

	header := v6Scratch(&r.head, v6HeaderCipherLen)
	if err := r.readFull(header); err != nil {
		return nil, err
	}
	if _, err := r.aead.Open(header[:0], r.nonce[:], header, nil); err != nil {
		return nil, fmt.Errorf("snell: open record header: %w", err)
	}
	incrementV4Nonce(r.nonce[:])
	paddingLen, payloadLen, err := v6ParseHeader(header[:v6HeaderPlainLen])
	if err != nil {
		return nil, err
	}
	// Records of the non-default modes must not carry padding.
	if paddingLen != 0 {
		return nil, errV6RecordPadding
	}
	if payloadLen == 0 {
		return nil, shadowaead.ErrZeroChunk
	}
	body := v6Scratch(&r.body, payloadLen+v6TagLen)
	if err := r.readFull(body); err != nil {
		return nil, err
	}
	if _, err := r.aead.Open(body[:0], r.nonce[:], body, nil); err != nil {
		return nil, fmt.Errorf("snell: open record payload: %w", err)
	}
	incrementV4Nonce(r.nonce[:])
	return body[:payloadLen], nil
}

func (r *v6RecordReader) readRaw() ([]byte, error) {
	header := v6Scratch(&r.head, v6HeaderPlainLen)
	if err := r.readFull(header); err != nil {
		return nil, err
	}
	paddingLen, payloadLen, err := v6ParseHeader(header)
	if err != nil {
		return nil, err
	}
	if paddingLen != 0 {
		return nil, errV6RecordPadding
	}
	if payloadLen == 0 {
		return nil, shadowaead.ErrZeroChunk
	}
	body := v6Scratch(&r.body, payloadLen)
	if err := r.readFull(body); err != nil {
		return nil, err
	}
	return body, nil
}
