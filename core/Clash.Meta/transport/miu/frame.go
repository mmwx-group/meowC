// Package miu implements the client side of the Miu protocol, second version: a
// pool of lanes with pass-through.
//
//   - A lane is one TCP connection + the outer TLS / REALITY + one authentication.
//     It carries one stream at a time and goes back to the pool when that stream
//     ended, so a stream on a warm lane starts without a handshake or a round
//     trip. Nothing is multiplexed: no flow control windows, no stream holding
//     back another, backpressure is left to TCP.
//   - Inner data that already is TLS 1.3 ciphertext is not encrypted a second
//     time: a RAW frame announces a byte count and the bytes follow as they are
//     on the TCP connection.
//   - The first packets of every stream are shaped by the padding scheme, UDP
//     rides a stream as UoT.
//
// The wire format is PROTOCOL.md of the miu repository. The first version (the
// AnyTLS frame format with MUX and the Vision handover) is kept at the tag miu-v1.
package miu

// Frames, all of them inside outer TLS records:
//
//	type(1) | len(u16) | payload
const (
	frPad            = 0 // padding, dropped
	frSettings       = 1 // client to server, text
	frServerSettings = 2 // server to client, text
	frUpdatePadding  = 3 // server to client, padding scheme text
	frOpen           = 4 // client to server, the destination as socksaddr
	frData           = 5 // data, encrypted by the outer TLS only
	frRaw            = 6 // u32 BE = N: N bytes follow on the TCP connection outside the outer TLS. Last frame of its record
	frEnd            = 7 // this direction is done
	frReset          = 8 // client to server: the stream is aborted, the uplink is done, stop the downlink and send END

	frameHead = 3
	// a DATA frame with its header fits one TLS record
	maxData = 16000
	// upper bound of one raw segment
	maxSeg = 1 << 20
	// Past the inner handshake a batch smaller than this still goes as DATA: the
	// RAW frame takes a record of its own, for little data that doubles the
	// packets and the encryption saved is not worth it.
	rawMin = 4096
	// how far into a direction the inner TLS handshake is looked for, a stream
	// without one by then stays in DATA frames
	sniffLimit = 64 << 10
)

func appendFrame(b []byte, typ byte, payload []byte) []byte {
	b = append(b, typ, byte(len(payload)>>8), byte(len(payload)))
	return append(b, payload...)
}

// appendData appends p as DATA frames.
func appendData(b []byte, p []byte) []byte {
	for len(p) > 0 {
		k := len(p)
		if k > maxData {
			k = maxData
		}
		b = appendFrame(b, frData, p[:k])
		p = p[k:]
	}
	return b
}

// appendPad appends a PAD frame with n bytes of payload.
func appendPad(b []byte, n int) []byte {
	b = append(b, frPad, byte(n>>8), byte(n))
	return append(b, make([]byte, n)...)
}

// protoError is a violation of the wire format by the server, as opposed to a
// lane that just died.
type protoError string

func (e protoError) Error() string {
	return "miu: " + string(e)
}
