package miu

import (
	"bytes"
	"crypto/md5"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"runtime/debug"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/metacubex/mihomo/common/pool"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/transport/anytls/padding"
	"github.com/metacubex/mihomo/transport/anytls/util"
)

// Session is a client side MUX session, derived from the AnyTLS one with the
// Miu settings negotiation and per-stream flow control added.
type Session struct {
	conn     net.Conn
	connLock sync.Mutex

	streams    map[uint32]*Stream
	streamId   atomic.Uint32
	streamLock sync.RWMutex

	dieOnce sync.Once
	die     chan struct{}
	dieHook func()

	synDone     func()
	synDoneLock sync.Mutex

	// pool
	seq       uint64
	idleSince time.Time
	padding   *atomic.Pointer[padding.PaddingFactory]

	peerVersion atomic.Uint32

	sendPadding    bool
	buffering      bool
	buffer         []byte
	pktCounter     atomic.Uint32
	clientMetadata string

	// miu
	psk        []byte
	ekm        []byte // exporter of the outer TLS session, nil when unavailable
	recvWindow int64  // announced to the server, per stream
	// guarded by streamLock: the window announced by the server
	sendWindowInit int64
	windowsApplied bool
}

func newSession(conn net.Conn, _padding *atomic.Pointer[padding.PaddingFactory], clientMetadata string, psk, ekm []byte, recvWindow int64) *Session {
	s := &Session{
		conn:           conn,
		sendPadding:    true,
		padding:        _padding,
		clientMetadata: clientMetadata,
		psk:            psk,
		ekm:            ekm,
		recvWindow:     recvWindow,
	}
	s.die = make(chan struct{})
	s.streams = make(map[uint32]*Stream)
	return s
}

func clientSettings(clientMetadata, paddingMd5 string, recvWindow int64) []byte {
	settings := util.StringMap{
		"v":           "2",
		"padding-md5": paddingMd5,
		"miu":         "1",
		"win":         strconv.FormatInt(recvWindow, 10),
	}
	if clientMetadata != "" {
		settings["client"] = clientMetadata
	}
	return settings.ToBytes()
}

func (s *Session) Run() {
	f := newFrame(cmdSettings, 0)
	f.data = clientSettings(s.clientMetadata, s.padding.Load().Md5, s.recvWindow)
	s.buffering = true
	s.writeControlFrame(f)

	go s.recvLoop()
}

// IsClosed does a safe check to see if we have shutdown
func (s *Session) IsClosed() bool {
	select {
	case <-s.die:
		return true
	default:
		return false
	}
}

// Close is used to close the session and all streams.
func (s *Session) Close() error {
	var once bool
	s.dieOnce.Do(func() {
		_ = s.conn.SetDeadline(time.Now())
		close(s.die)
		once = true
	})
	if once {
		if s.dieHook != nil {
			s.dieHook()
			s.dieHook = nil
		}
		s.streamLock.Lock()
		streams := s.streams
		s.streams = make(map[uint32]*Stream)
		s.streamLock.Unlock()
		for _, stream := range streams {
			stream.closeLocally(io.ErrClosedPipe)
		}
		return s.conn.Close()
	} else {
		return io.ErrClosedPipe
	}
}

// OpenStream is used to create a new stream
func (s *Session) OpenStream() (*Stream, error) {
	if s.IsClosed() {
		return nil, io.ErrClosedPipe
	}

	sid := s.streamId.Add(1)
	stream := newStream(sid, s)

	if sid >= 2 && s.peerVersion.Load() >= 2 {
		s.synDoneLock.Lock()
		if s.synDone != nil {
			s.synDone()
		}
		s.synDone = util.NewDeadlineWatcher(time.Second*3, func() {
			s.Close()
		})
		s.synDoneLock.Unlock()
	}

	if _, err := s.writeControlFrame(newFrame(cmdSYN, sid)); err != nil {
		return nil, err
	}

	s.buffering = false // proxy Write it's SocksAddr to flush the buffer

	s.streamLock.Lock()
	defer s.streamLock.Unlock()
	select {
	case <-s.die:
		return nil, io.ErrClosedPipe
	default:
		// Either the stream is in the map before ServerSettings arrives and gets its
		// credit there, or windowsApplied is already set and it is topped up here.
		if s.windowsApplied {
			stream.send.add(s.sendWindowInit - minRecvWindow)
		}
		s.streams[sid] = stream
		return stream, nil
	}
}

func (s *Session) getStream(sid uint32) *Stream {
	s.streamLock.RLock()
	stream := s.streams[sid]
	s.streamLock.RUnlock()
	return stream
}

// readBody reads a frame body into a pooled buffer, the caller must pool.Put it.
func (s *Session) readBody(length uint16) ([]byte, error) {
	buffer := pool.Get(int(length))
	if _, err := io.ReadFull(s.conn, buffer); err != nil {
		_ = pool.Put(buffer)
		return nil, err
	}
	return buffer, nil
}

func (s *Session) recvLoop() error {
	defer func() {
		if r := recover(); r != nil {
			log.Errorln("[BUG] %v %s", r, string(debug.Stack()))
		}
	}()
	defer s.Close()

	var hdr rawHeader

	for {
		if s.IsClosed() {
			return io.ErrClosedPipe
		}
		// read header first
		if _, err := io.ReadFull(s.conn, hdr[:]); err != nil {
			return err
		}
		sid := hdr.StreamID()
		length := hdr.Length()
		switch hdr.Cmd() {
		case cmdPSH:
			if length == 0 {
				continue
			}
			buffer, err := s.readBody(length)
			if err != nil {
				return err
			}
			if stream := s.getStream(sid); stream != nil {
				stream.recvQ.push(buffer)
			} else {
				_ = pool.Put(buffer)
			}
		case cmdSYNACK:
			s.synDoneLock.Lock()
			if s.synDone != nil {
				s.synDone()
				s.synDone = nil
			}
			s.synDoneLock.Unlock()
			if length == 0 {
				continue
			}
			buffer, err := s.readBody(length)
			if err != nil {
				return err
			}
			// report error
			if stream := s.getStream(sid); stream != nil {
				stream.closeWithError(fmt.Errorf("remote: %s", string(buffer)))
			}
			_ = pool.Put(buffer)
		case cmdFIN:
			s.streamLock.Lock()
			stream, ok := s.streams[sid]
			delete(s.streams, sid)
			s.streamLock.Unlock()
			if ok {
				stream.closeLocally(io.EOF)
			}
		case cmdWindow:
			if length != 4 {
				return errors.New("miu: bad WINDOW frame")
			}
			var d [4]byte
			if _, err := io.ReadFull(s.conn, d[:]); err != nil {
				return err
			}
			if stream := s.getStream(sid); stream != nil {
				stream.send.add(int64(binary.BigEndian.Uint32(d[:])))
			}
		case cmdAlert:
			if length == 0 {
				continue
			}
			buffer, err := s.readBody(length)
			if err != nil {
				return err
			}
			log.Warnln("[Miu] alert from server: %s", string(buffer))
			_ = pool.Put(buffer)
			return nil
		case cmdUpdatePaddingScheme:
			if length == 0 {
				continue
			}
			// `rawScheme` Do not use buffer to prevent subsequent misuse
			rawScheme := make([]byte, int(length))
			if _, err := io.ReadFull(s.conn, rawScheme); err != nil {
				return err
			}
			if padding.UpdatePaddingScheme(rawScheme, s.padding) {
				log.Debugln("[Miu] update padding succeed %x", md5.Sum(rawScheme))
			} else {
				log.Warnln("[Miu] update padding failed %x", md5.Sum(rawScheme))
			}
		case cmdHeartRequest:
			if _, err := s.writeControlFrame(newFrame(cmdHeartResponse, sid)); err != nil {
				return err
			}
		case cmdServerSettings:
			if length == 0 {
				continue
			}
			buffer, err := s.readBody(length)
			if err != nil {
				return err
			}
			err = s.handleServerSettings(util.StringMapFromBytes(buffer))
			_ = pool.Put(buffer)
			if err != nil {
				log.Warnln("[Miu] %v", err)
				return err
			}
		default: // cmdWaste, cmdHeartResponse and anything unknown: skip the body
			if length > 0 {
				if _, err := io.CopyN(io.Discard, s.conn, int64(length)); err != nil {
					return err
				}
			}
		}
	}
}

// verifyServerTag checks the "srv" value of ServerSettings: HMAC-SHA256(psk, EKM || 0x02).
// It proves the peer holds the PSK and sees the same TLS session as we do.
func verifyServerTag(m util.StringMap, psk, ekm []byte) error {
	srv, ok := m["srv"]
	if !ok || len(ekm) != ekmLen {
		return nil
	}
	got, err := hex.DecodeString(strings.TrimSpace(srv))
	if err != nil || !bytes.Equal(got, authTagEKM(psk, ekm, roleServer)) {
		return errors.New("miu: server auth tag mismatch")
	}
	return nil
}

func (s *Session) handleServerSettings(m util.StringMap) error {
	if v, err := strconv.Atoi(m["v"]); err == nil {
		s.peerVersion.Store(uint32(v))
	}
	win := unlimitedCredit
	if m["miu"] == "1" {
		win = defaultRecvWindow
		if w, err := strconv.ParseInt(m["win"], 10, 64); err == nil {
			win = clampWindow(w)
		}
		if err := verifyServerTag(m, s.psk, s.ekm); err != nil {
			return err
		}
	}
	// Streams opened before ServerSettings only had a conservative credit.
	s.streamLock.Lock()
	if !s.windowsApplied {
		s.sendWindowInit = win
		s.windowsApplied = true
		for _, stream := range s.streams {
			stream.send.add(win - minRecvWindow)
		}
	}
	s.streamLock.Unlock()
	return nil
}

func (s *Session) streamClosed(sid uint32) error {
	if s.IsClosed() {
		return io.ErrClosedPipe
	}
	_, err := s.writeControlFrame(newFrame(cmdFIN, sid))
	s.streamLock.Lock()
	delete(s.streams, sid)
	s.streamLock.Unlock()
	return err
}

func (s *Session) writeWindow(sid uint32, increment uint32) error {
	if s.IsClosed() {
		return io.ErrClosedPipe
	}
	f := newFrame(cmdWindow, sid)
	f.data = binary.BigEndian.AppendUint32(nil, increment)
	_, err := s.writeControlFrame(f)
	return err
}

func (s *Session) writeDataFrame(sid uint32, data []byte) (int, error) {
	f := newFrame(cmdPSH, sid)
	f.data = data
	buffer := f.appendTo(pool.Get(len(data) + headerOverHeadSize)[:0])
	_, err := s.writeConn(buffer)
	_ = pool.Put(buffer)
	if err != nil {
		return 0, err
	}
	return len(data), nil
}

func (s *Session) writeControlFrame(frame frame) (int, error) {
	buffer := frame.appendTo(pool.Get(len(frame.data) + headerOverHeadSize)[:0])

	s.conn.SetWriteDeadline(time.Now().Add(time.Second * 5))

	_, err := s.writeConn(buffer)
	_ = pool.Put(buffer)
	if err != nil {
		s.Close()
		return 0, err
	}

	s.conn.SetWriteDeadline(time.Time{})

	return len(frame.data), nil
}

func (s *Session) writeConn(b []byte) (n int, err error) {
	s.connLock.Lock()
	defer s.connLock.Unlock()

	if s.buffering {
		s.buffer = append(s.buffer, b...)
		return len(b), nil
	} else if len(s.buffer) > 0 {
		b = append(s.buffer, b...)
		s.buffer = nil
	}

	// calulate & send padding
	if s.sendPadding {
		pkt := s.pktCounter.Add(1)
		paddingF := s.padding.Load()
		if pkt < paddingF.Stop {
			pktSizes := paddingF.GenerateRecordPayloadSizes(pkt)
			for _, l := range pktSizes {
				remainPayloadLen := len(b)
				if l == padding.CheckMark {
					if remainPayloadLen == 0 {
						break
					} else {
						continue
					}
				}
				if remainPayloadLen > l { // this packet is all payload
					_, err = s.conn.Write(b[:l])
					if err != nil {
						return 0, err
					}
					n += l
					b = b[l:]
				} else if remainPayloadLen > 0 { // this packet contains padding and the last part of payload
					paddingLen := l - remainPayloadLen - headerOverHeadSize
					if paddingLen > 0 {
						padding := make([]byte, headerOverHeadSize+paddingLen)
						padding[0] = cmdWaste
						binary.BigEndian.PutUint32(padding[1:5], 0)
						binary.BigEndian.PutUint16(padding[5:7], uint16(paddingLen))
						b = append(b, padding...)
					}
					_, err = s.conn.Write(b)
					if err != nil {
						return 0, err
					}
					n += remainPayloadLen
					b = nil
				} else { // this packet is all padding
					padding := make([]byte, headerOverHeadSize+l)
					padding[0] = cmdWaste
					binary.BigEndian.PutUint32(padding[1:5], 0)
					binary.BigEndian.PutUint16(padding[5:7], uint16(l))
					_, err = s.conn.Write(padding)
					if err != nil {
						return 0, err
					}
					b = nil
				}
			}
			// maybe still remain payload to write
			if len(b) == 0 {
				return
			} else {
				n2, err := s.conn.Write(b)
				return n + n2, err
			}
		} else {
			s.sendPadding = false
		}
	}

	return s.conn.Write(b)
}
