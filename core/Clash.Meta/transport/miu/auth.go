package miu

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"errors"
)

// Auth header, sent right after the outer TLS handshake and before the first frame.
//
//	token(32) | padlen(u16) | padding        token = sha256(psk string)
//
// The token is one fixed value per user, the server looks it up in a table. It only
// ever appears inside the outer TLS / REALITY session.
const (
	authTokenLen = sha256.Size

	pskMinLen = 16
)

// authToken hashes the configured PSK string as is (trimmed, not base64 decoded):
// both ends must hold the very same string.
func authToken(psk string) [authTokenLen]byte {
	return sha256.Sum256([]byte(psk))
}

// decodePSK returns the key bytes of the PSK, they seed the Vision padding. It
// accepts standard / URL-safe base64 (padded or not), otherwise the raw string is
// used as is. Must stay in sync with the server, both sides derive the same key
// bytes from the configured string.
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

// buildAuthHeader builds the client auth header including the zero padding.
func buildAuthHeader(token [authTokenLen]byte, paddingLen int) []byte {
	head := make([]byte, 0, authTokenLen+2+paddingLen)
	head = append(head, token[:]...)
	head = binary.BigEndian.AppendUint16(head, uint16(paddingLen))
	return append(head, make([]byte, paddingLen)...)
}
