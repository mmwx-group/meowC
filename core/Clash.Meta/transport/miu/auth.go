package miu

import (
	"crypto/sha256"
	"errors"

	"github.com/metacubex/mihomo/transport/anytls/padding"
)

// Auth header, the first bytes the client sends once the outer handshake is done.
//
//	token(32) | padlen(u16) | padding        token = sha256(psk string)
//
// The token is one fixed value per user, the server looks it up in a table. It only
// ever appears inside the outer TLS / REALITY session.
const (
	authTokenLen = sha256.Size

	pskMinLen = 16

	// padlen when entry 0 of the padding scheme is unusable
	defaultAuthPadding = 30
)

// authToken hashes the configured PSK string as is (trimmed, not base64 decoded):
// both ends must hold the very same string.
func authToken(psk string) [authTokenLen]byte {
	return sha256.Sum256([]byte(psk))
}

// checkPSK applies the rule of the server: base64 of at least 16 bytes, or else
// a raw string that long. Either way that is a string of 16 characters or more.
func checkPSK(s string) error {
	if s == "" {
		return errors.New("miu: psk is required")
	}
	if len(s) < pskMinLen {
		return errors.New("miu: psk too short (need at least 16 bytes)")
	}
	return nil
}

// authPadding is the padding length of the auth header, entry 0 of the scheme.
func authPadding(scheme *padding.PaddingFactory) int {
	if sizes := scheme.GenerateRecordPayloadSizes(0); len(sizes) > 0 && sizes[0] != padding.CheckMark {
		return int(uint16(sizes[0]))
	}
	return defaultAuthPadding
}

// appendAuthHeader appends the auth header including its zero padding.
func appendAuthHeader(b []byte, token [authTokenLen]byte, paddingLen int) []byte {
	b = append(b, token[:]...)
	b = append(b, byte(paddingLen>>8), byte(paddingLen))
	return append(b, make([]byte, paddingLen)...)
}
