// Snell v6 client.
//
// Ported from github.com/sagernet/sing-snell (snellv6/mode.go, client.go and
// packet.go, plus the request and reply encoding of the module root),
// Copyright (C) 2022 by nekohasekai <contact-sagernet@sekai.icu>, licensed
// under the GNU General Public License v3.0 or later.

package snell

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"sync"

	"github.com/metacubex/mihomo/transport/shadowsocks/shadowaead"
	"github.com/metacubex/mihomo/transport/socks5"
)

// V6Mode selects the record format of a Snell v6 connection. Both peers must
// be configured with the same mode.
type V6Mode int

const (
	// V6ModeDefault is the shaped mode: record sizes, padding and filler
	// bytes follow a profile derived from the PSK.
	V6ModeDefault V6Mode = iota
	// V6ModeUnshaped encrypts records without any shaping.
	V6ModeUnshaped
	// V6ModeUnsafeRaw frames records without encryption.
	V6ModeUnsafeRaw
)

// ParseV6Mode parses the value of the "mode" proxy option. An empty name
// selects the default mode.
func ParseV6Mode(name string) (V6Mode, error) {
	switch name {
	case "", "default":
		return V6ModeDefault, nil
	case "unshaped":
		return V6ModeUnshaped, nil
	case "unsafe-raw":
		return V6ModeUnsafeRaw, nil
	default:
		return 0, fmt.Errorf("snell: unknown v6 mode: %s", name)
	}
}

func (m V6Mode) String() string {
	switch m {
	case V6ModeDefault:
		return "default"
	case V6ModeUnshaped:
		return "unshaped"
	case V6ModeUnsafeRaw:
		return "unsafe-raw"
	default:
		return "unknown"
	}
}

// V6Option configures a V6Client.
type V6Option struct {
	PSK  []byte
	Mode V6Mode
	// Reuse keeps finished connections in a pool for later requests.
	Reuse bool
	// Dial opens a new connection to the server. It is required when Reuse
	// is set and unused otherwise.
	Dial func(ctx context.Context) (net.Conn, error)
}

// V6Client creates Snell v6 connections. It is safe for concurrent use.
type V6Client struct {
	psk     []byte
	mode    V6Mode
	profile *v6Profile
	reuse   bool
	dial    func(ctx context.Context) (net.Conn, error)
	pool    v6Pool
}

func NewV6Client(option V6Option) (*V6Client, error) {
	if len(option.PSK) == 0 {
		return nil, errors.New("snell: missing pre-shared key")
	}
	switch option.Mode {
	case V6ModeDefault, V6ModeUnshaped, V6ModeUnsafeRaw:
	default:
		return nil, fmt.Errorf("snell: unknown v6 mode: %d", int(option.Mode))
	}
	if option.Reuse && option.Dial == nil {
		return nil, errors.New("snell: missing dialer")
	}
	client := &V6Client{
		psk:   option.PSK,
		mode:  option.Mode,
		reuse: option.Reuse,
		dial:  option.Dial,
	}
	if option.Mode == V6ModeDefault {
		client.profile = newV6Profile(option.PSK)
	}
	if option.Reuse {
		client.pool.init()
	}
	return client, nil
}

// Close closes the pooled connections. Connections that are in use are not
// affected, but they are no longer returned to the pool.
func (c *V6Client) Close() error {
	return c.pool.close()
}

func (c *V6Client) newRecordIO(conn net.Conn) (*v6RecordReader, v6RecordWriter, error) {
	writer, err := newV6RecordWriter(conn, c.mode, c.psk, c.profile)
	if err != nil {
		return nil, nil, err
	}
	return newV6RecordReader(conn, c.mode, c.psk, c.profile), writer, nil
}

// v6AppendRequest appends a request to b. The client identifier is always
// empty. TCP requests use the reusable connect command whether or not the
// client pools connections; the server answers every stream with a zero chunk
// either way.
func v6AppendRequest(b []byte, command byte, host string, port uint16) ([]byte, error) {
	b = append(b, Version, command, 0)
	if command == CommandConnectV2 {
		// The target is a host string even for literal IP addresses.
		if len(host) > 255 {
			return nil, fmt.Errorf("snell: host too long: %s", host)
		}
		b = append(b, byte(len(host)))
		b = append(b, host...)
		b = binary.BigEndian.AppendUint16(b, port)
	}
	return b, nil
}

// v6ParseReply checks the reply opcode that starts the first record of a
// response and returns the stream data following it in the same record.
func v6ParseReply(record []byte) ([]byte, error) {
	if len(record) == 0 {
		return nil, io.ErrUnexpectedEOF
	}
	switch record[0] {
	case CommandTunnel:
		return record[1:], nil
	case CommandError:
		// error code, message length, message
		if len(record) < 3 || len(record) < 3+int(record[2]) {
			return nil, io.ErrUnexpectedEOF
		}
		message := record[3 : 3+int(record[2])]
		// An error reply must be exactly the code, the length and the message.
		if len(record) != 3+len(message) {
			return nil, errors.New("snell: server error reply has trailing data")
		}
		return nil, fmt.Errorf("server reported code: %d, message: %s", record[1], string(message))
	default:
		return nil, fmt.Errorf("snell: unexpected reply opcode: %d", record[0])
	}
}

// v6ReadReply reads the first record of a response.
func v6ReadReply(reader *v6RecordReader) error {
	record, err := reader.readRecord()
	if err != nil {
		if err == shadowaead.ErrZeroChunk {
			err = io.EOF
		}
		return err
	}
	rest, err := v6ParseReply(record)
	if err != nil {
		return err
	}
	reader.setCache(rest)
	return nil
}

// StreamConn starts a TCP request to host:port on conn, which is used for
// this request only, and returns the proxied connection. The request is
// written before StreamConn returns; the reply is read by the first Read.
func (c *V6Client) StreamConn(conn net.Conn, host string, port uint16) (net.Conn, error) {
	request, err := v6AppendRequest(nil, CommandConnectV2, host, port)
	if err != nil {
		return nil, err
	}
	reader, writer, err := c.newRecordIO(conn)
	if err != nil {
		return nil, err
	}
	if _, err = writer.Write(request); err != nil {
		return nil, err
	}
	return &v6Conn{Conn: conn, reader: reader, writer: writer}, nil
}

// v6Conn is a TCP stream on a connection that is not reused.
type v6Conn struct {
	net.Conn
	reader *v6RecordReader
	writer v6RecordWriter

	replyRead bool
	readEOF   bool

	closeWriteOnce sync.Once
	closeWriteErr  error
}

func (c *v6Conn) Read(p []byte) (int, error) {
	if c.readEOF {
		return 0, io.EOF
	}
	if !c.replyRead {
		if err := v6ReadReply(c.reader); err != nil {
			return 0, err
		}
		c.replyRead = true
	}
	n, err := c.reader.Read(p)
	if err == shadowaead.ErrZeroChunk {
		c.readEOF = true
		err = io.EOF
	}
	return n, err
}

func (c *v6Conn) Write(p []byte) (int, error) {
	return c.writer.Write(p)
}

// CloseWrite tells the server that no more data follows. The other direction
// stays open.
func (c *v6Conn) CloseWrite() error {
	c.closeWriteOnce.Do(func() {
		c.closeWriteErr = c.writer.writeZeroChunk()
	})
	return c.closeWriteErr
}

// StreamPacketConn starts a UDP tunnel on conn. It writes the request and
// waits for the reply: the server rejects a tunnel request that shares a
// record with the first datagram, and datagrams must not be sent before the
// tunnel is confirmed.
func (c *V6Client) StreamPacketConn(conn net.Conn) (*V6PacketConn, error) {
	request, err := v6AppendRequest(nil, CommandUDP, "", 0)
	if err != nil {
		return nil, err
	}
	reader, writer, err := c.newRecordIO(conn)
	if err != nil {
		return nil, err
	}
	if _, err = writer.Write(request); err != nil {
		return nil, err
	}
	if err = v6ReadReply(reader); err != nil {
		return nil, err
	}
	return &V6PacketConn{Conn: conn, reader: reader, writer: writer}, nil
}

// V6PacketConn is a UDP tunnel. Every datagram travels in one record:
//
//	client to server: 0x01 | address | payload
//	    address: length, host, port          for a domain name
//	             0x00, 0x04 or 0x06, IP, port for an IP address
//	server to client: 0x04 or 0x06 | IP | port | payload
//
// The embedded connection is only there for Close, the addresses and the
// deadlines; its Read and Write must not be used.
type V6PacketConn struct {
	net.Conn
	reader *v6RecordReader
	writer v6RecordWriter

	readAccess  sync.Mutex
	writeAccess sync.Mutex
}

// WritePacketFrame writes b as exactly one record.
func (pc *V6PacketConn) WritePacketFrame(b []byte) (int, error) {
	if err := pc.writer.writePacket(b); err != nil {
		return 0, err
	}
	return len(b), nil
}

func (pc *V6PacketConn) WriteTo(b []byte, addr net.Addr) (int, error) {
	socks5Addr := socks5.ParseAddrToSocksAddr(addr)
	headerLen := UdpRequestHeaderLength(socks5Addr)
	if headerLen > maxLength {
		return 0, errors.New("snell UDP address invalid")
	}
	if headerLen+len(b) > v6MaxPayload {
		return 0, errV6PayloadTooLarge
	}

	pc.writeAccess.Lock()
	defer pc.writeAccess.Unlock()
	return writePacket(pc, socks5Addr, b)
}

func (pc *V6PacketConn) ReadFrom(b []byte) (int, net.Addr, error) {
	pc.readAccess.Lock()
	defer pc.readAccess.Unlock()

	record, err := pc.reader.nextRecord()
	if err != nil {
		if err == shadowaead.ErrZeroChunk {
			err = io.EOF
		}
		return 0, nil, err
	}
	if len(record) == 0 {
		return 0, nil, errors.New("insufficient UDP length")
	}
	var ipLen int
	switch record[0] {
	case 0x04:
		ipLen = net.IPv4len
	case 0x06:
		ipLen = net.IPv6len
	default:
		return 0, nil, errors.New("ip version invalid")
	}
	if len(record) < 1+ipLen+2 {
		return 0, nil, errors.New("insufficient UDP length")
	}
	// The record buffer is reused by the next read, so the address is copied.
	addr := &net.UDPAddr{
		IP:   append(net.IP(nil), record[1:1+ipLen]...),
		Port: int(binary.BigEndian.Uint16(record[1+ipLen:])),
	}
	n := copy(b, record[1+ipLen+2:])
	return n, addr, nil
}
