package miu

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"time"

	"github.com/metacubex/mihomo/transport/anytls/padding"
	"github.com/metacubex/mihomo/transport/anytls/util"
	"github.com/metacubex/mihomo/transport/vless/vision"

	M "github.com/metacubex/sing/common/metadata"
)

// Vision: one connection, one stream. After SYNACK both ends drop the Miu framing
// and hand the connection over to XTLS-Vision, inner TLS 1.3 traffic then leaves
// the outer TLS and the server can splice it. Only the handshake is done here,
// the switching itself is the stock Vision implementation.

const visionStreamID = 1

var errVisionRefused = errors.New("miu: server did not grant Vision")

func readFrame(conn net.Conn) (cmd byte, sid uint32, data []byte, err error) {
	var hdr rawHeader
	if _, err = io.ReadFull(conn, hdr[:]); err != nil {
		return
	}
	if n := hdr.Length(); n > 0 {
		data = make([]byte, n)
		if _, err = io.ReadFull(conn, data); err != nil {
			return
		}
	}
	return hdr.Cmd(), hdr.StreamID(), data, nil
}

func (c *Client) dialVision(ctx context.Context, destination M.Socksaddr) (_ net.Conn, err error) {
	addr, err := destinationBytes(destination)
	if err != nil {
		return nil, err
	}
	conn, ekm, err := c.connect(ctx)
	if err != nil {
		return nil, err
	}
	defer func() {
		if err != nil {
			conn.Close()
		}
	}()
	if ekm == nil {
		// Vision needs the outer TLS session anyway
		return nil, errors.New("miu: Vision requires TLS or REALITY")
	}

	deadline := time.Now().Add(10 * time.Second)
	if d, ok := ctx.Deadline(); ok && d.Before(deadline) {
		deadline = d
	}
	_ = conn.SetDeadline(deadline)

	f := newFrame(cmdSettings, 0)
	f.data = clientSettings(c.clientMetadata, c.padding.Load().Md5, c.recvWindow)
	if _, err = conn.Write(f.appendTo(nil)); err != nil {
		return nil, err
	}

	// wait for ServerSettings: does the server speak miu, is it the right server, does it grant Vision
	for granted := false; !granted; {
		cmd, _, data, err := readFrame(conn)
		if err != nil {
			return nil, fmt.Errorf("miu: read ServerSettings: %w", err)
		}
		switch cmd {
		case cmdServerSettings:
			m := util.StringMapFromBytes(data)
			if m["miu"] != "1" || m["vision"] != "1" {
				return nil, errVisionRefused
			}
			if err = verifyServerTag(m, c.psk, ekm); err != nil {
				return nil, err
			}
			granted = true
		case cmdUpdatePaddingScheme:
			padding.UpdatePaddingScheme(data, &c.padding)
		case cmdAlert:
			return nil, fmt.Errorf("miu: alert from server: %s", string(data))
		}
	}

	open := newFrame(cmdSYNVision, visionStreamID).appendTo(nil)
	psh := newFrame(cmdPSH, visionStreamID)
	psh.data = addr
	if _, err = conn.Write(psh.appendTo(open)); err != nil {
		return nil, err
	}

	for acked := false; !acked; {
		cmd, sid, data, err := readFrame(conn)
		if err != nil {
			return nil, fmt.Errorf("miu: read SYNACK: %w", err)
		}
		switch cmd {
		case cmdSYNACK:
			if sid != visionStreamID {
				continue
			}
			if len(data) > 0 {
				return nil, fmt.Errorf("remote: %s", string(data))
			}
			acked = true
		case cmdAlert:
			return nil, fmt.Errorf("miu: alert from server: %s", string(data))
		}
	}

	_ = conn.SetDeadline(time.Time{})
	return vision.NewConn(conn, conn, c.visionSeed)
}
