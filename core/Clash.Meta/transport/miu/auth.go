package miu

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"net"
	"reflect"
	"time"

	tlsC "github.com/metacubex/mihomo/component/tls"

	utls "github.com/metacubex/utls"
)

// Auth header, sent right after the outer TLS handshake and before the first frame.
// The identity is the key: there is no user id, the server trial-verifies the tag
// against each user's PSK.
//
//	ver=1 (exporter bound)  0x01 | tag(32) | padlen(u16) | padding
//	      tag = HMAC-SHA256(psk, EKM || role), EKM = TLS-Exporter("miu/1/auth", "", 32)
//	ver=2 (no exporter)     0x02 | ts(u64 BE, unix seconds) | nonce(16) | tag(32) | padlen(u16) | padding
//	      tag = HMAC-SHA256(psk, ts || nonce || role)
const (
	authVersionEKM   = 1
	authVersionNonce = 2

	roleClient = 0x01
	roleServer = 0x02

	ekmLabel = "miu/1/auth"
	ekmLen   = 32

	pskMinLen = 16
)

// decodePSK accepts standard / URL-safe base64 (padded or not), otherwise the raw
// string is used as is. Must stay in sync with the server, both sides derive the
// same key bytes from the configured string.
func decodePSK(s string) ([]byte, error) {
	if s == "" {
		return nil, errors.New("miu: psk is required")
	}
	for _, enc := range []*base64.Encoding{base64.StdEncoding, base64.RawStdEncoding, base64.URLEncoding, base64.RawURLEncoding} {
		if b, err := enc.DecodeString(s); err == nil && len(b) >= pskMinLen {
			return b, nil
		}
	}
	if len(s) >= pskMinLen {
		return []byte(s), nil
	}
	return nil, errors.New("miu: psk too short (need at least 16 bytes)")
}

// allowExporter makes a uTLS connection willing to export keying material.
//
// uTLS browser fingerprints carry renegotiation_info and set config.Renegotiation,
// and ConnectionState refuses to export keying material whenever that is not
// RenegotiateNever. TLS 1.3 has no renegotiation at all, so after a finished
// TLS 1.3 handshake clearing the flag only affects that check. config is an
// unexported field, reached the same way Vision reaches the record buffers.
func allowExporter(conn net.Conn) {
	uc, ok := conn.(*tlsC.UConn)
	if !ok || uc.Conn == nil {
		return
	}
	if state := uc.ConnectionState(); !state.HandshakeComplete || state.Version != tlsC.VersionTLS13 {
		return
	}
	f := reflect.ValueOf(uc.Conn).Elem().FieldByName("config")
	if !f.IsValid() || f.Kind() != reflect.Pointer || f.IsNil() {
		return
	}
	(*utls.Config)(f.UnsafePointer()).Renegotiation = utls.RenegotiateNever
}

// exportKeyingMaterial returns the exporter value of the outer TLS session,
// or nil when the transport cannot provide one.
func exportKeyingMaterial(conn net.Conn) []byte {
	allowExporter(conn)
	state := tlsC.GetTLSConnectionState(conn)
	if !state.HandshakeComplete {
		return nil
	}
	ekm, err := state.ExportKeyingMaterial(ekmLabel, nil, ekmLen)
	if err != nil || len(ekm) != ekmLen {
		return nil
	}
	return ekm
}

func authTagEKM(psk, ekm []byte, role byte) []byte {
	m := hmac.New(sha256.New, psk)
	m.Write(ekm)
	m.Write([]byte{role})
	return m.Sum(nil)
}

func authTagNonce(psk []byte, ts uint64, nonce []byte, role byte) []byte {
	m := hmac.New(sha256.New, psk)
	var t [8]byte
	binary.BigEndian.PutUint64(t[:], ts)
	m.Write(t[:])
	m.Write(nonce)
	m.Write([]byte{role})
	return m.Sum(nil)
}

// buildAuthHeader builds the client auth header including the zero padding.
// ver=1 is used when ekm is available, ver=2 otherwise.
func buildAuthHeader(psk, ekm []byte, paddingLen int) []byte {
	head := make([]byte, 0, 1+8+16+32+2+paddingLen)
	if len(ekm) == ekmLen {
		head = append(head, authVersionEKM)
		head = append(head, authTagEKM(psk, ekm, roleClient)...)
	} else {
		var nonce [16]byte
		_, _ = rand.Read(nonce[:])
		ts := uint64(time.Now().Unix())
		head = append(head, authVersionNonce)
		head = binary.BigEndian.AppendUint64(head, ts)
		head = append(head, nonce[:]...)
		head = append(head, authTagNonce(psk, ts, nonce[:], roleClient)...)
	}
	head = binary.BigEndian.AppendUint16(head, uint16(paddingLen))
	return append(head, make([]byte, paddingLen)...)
}
