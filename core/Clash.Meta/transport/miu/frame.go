// Package miu implements the client side of the Miu protocol.
//
// Miu keeps the AnyTLS v2 wire format as its baseline (frames 0-10) and adds:
//   - a per-user PSK auth header bound to the outer TLS session via the TLS exporter,
//     so nothing fixed per user ever appears on the wire;
//   - per-stream flow control (cmdWindow);
//   - DIRECT: a dedicated connection that hands over to XTLS-Vision after SYNACK,
//     letting the server splice inner TLS 1.3 traffic.
//
// The extensions are only used after both sides announced "miu=1" in their settings.
package miu

import (
	"encoding/binary"
)

const ( // cmds 0-10 are identical to AnyTLS
	cmdWaste               = 0  // paddings
	cmdSYN                 = 1  // stream open
	cmdPSH                 = 2  // data push
	cmdFIN                 = 3  // stream close, a.k.a EOF mark
	cmdSettings            = 4  // settings (client send to server)
	cmdAlert               = 5  // alert
	cmdUpdatePaddingScheme = 6  // update padding scheme
	cmdSYNACK              = 7  // server reports that the stream has been opened
	cmdHeartRequest        = 8  // keep alive command
	cmdHeartResponse       = 9  // keep alive command
	cmdServerSettings      = 10 // settings (server send to client)

	// Miu extensions
	cmdWindow    = 11 // flow control: u32 BE, bytes the receiver has freed
	cmdSYNDirect = 13 // like SYN, and promises this connection only carries this stream
)

const (
	headerOverHeadSize = 1 + 4 + 2

	// maxFrameDataLen is the maximum payload bytes per data frame, the wire
	// format encodes payload length as a uint16.
	maxFrameDataLen = 0xFFFF
)

// frame defines a packet from or to be multiplexed into a single connection
type frame struct {
	cmd  byte   // 1
	sid  uint32 // 4
	data []byte // 2 + len(data)
}

func newFrame(cmd byte, sid uint32) frame {
	return frame{cmd: cmd, sid: sid}
}

func (f frame) appendTo(b []byte) []byte {
	b = append(b, f.cmd)
	b = binary.BigEndian.AppendUint32(b, f.sid)
	b = binary.BigEndian.AppendUint16(b, uint16(len(f.data)))
	return append(b, f.data...)
}

type rawHeader [headerOverHeadSize]byte

func (h rawHeader) Cmd() byte {
	return h[0]
}

func (h rawHeader) StreamID() uint32 {
	return binary.BigEndian.Uint32(h[1:])
}

func (h rawHeader) Length() uint16 {
	return binary.BigEndian.Uint16(h[5:])
}
