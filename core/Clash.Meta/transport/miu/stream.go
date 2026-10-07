package miu

import (
	"io"
	"net"
	"os"
	"sync"
	"sync/atomic"
	"time"

	"github.com/metacubex/mihomo/common/pool"
	"github.com/metacubex/mihomo/transport/anytls/pipe"
)

// recvQueue buffers the data frames of one stream. The peer never has more than the
// announced window in flight, so pushing never blocks the session's receive loop and
// a slow reader cannot hold back the other streams.
type recvQueue struct {
	mu       sync.Mutex
	pending  [][]byte
	cur      []byte // unread part of curOrig
	curOrig  []byte // pooled buffer cur points into
	err      error  // returned once everything buffered has been read
	notify   chan struct{}
	deadline pipe.PipeDeadline
}

func newRecvQueue() *recvQueue {
	return &recvQueue{
		notify:   make(chan struct{}, 1),
		deadline: pipe.MakePipeDeadline(),
	}
}

func (q *recvQueue) wake() {
	select {
	case q.notify <- struct{}{}:
	default:
	}
}

// push takes ownership of b, which must come from pool.Get.
func (q *recvQueue) push(b []byte) {
	q.mu.Lock()
	if q.err != nil {
		q.mu.Unlock()
		_ = pool.Put(b)
		return
	}
	q.pending = append(q.pending, b)
	q.mu.Unlock()
	q.wake()
}

// close stops the queue. With drop the buffered data is discarded, otherwise the
// reader still gets it before seeing err.
func (q *recvQueue) close(err error, drop bool) {
	q.mu.Lock()
	if q.err == nil {
		q.err = err
	}
	if drop {
		if q.curOrig != nil {
			_ = pool.Put(q.curOrig)
		}
		for _, b := range q.pending {
			_ = pool.Put(b)
		}
		q.cur, q.curOrig, q.pending = nil, nil, nil
	}
	q.mu.Unlock()
	q.wake()
}

func (q *recvQueue) read(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	for {
		q.mu.Lock()
		for len(q.cur) == 0 && len(q.pending) > 0 {
			if q.curOrig != nil {
				_ = pool.Put(q.curOrig)
			}
			q.curOrig = q.pending[0]
			q.cur = q.curOrig
			q.pending[0] = nil
			q.pending = q.pending[1:]
		}
		if len(q.cur) > 0 {
			n := copy(p, q.cur)
			q.cur = q.cur[n:]
			q.mu.Unlock()
			return n, nil
		}
		err := q.err
		q.mu.Unlock()
		if err != nil {
			q.wake() // keep later readers from waiting
			return 0, err
		}
		select {
		case <-q.notify:
		case <-q.deadline.Wait():
			return 0, os.ErrDeadlineExceeded
		}
	}
}

// Stream implements net.Conn
type Stream struct {
	id uint32

	sess *Session

	recvQ   *recvQueue
	recvWin recvWindow
	send    *sendWindow

	writeDeadline pipe.PipeDeadline

	dieOnce sync.Once
	dieHook func()
	dieErr  error // written once before dead is set
	dead    atomic.Bool
}

// newStream initiates a Stream struct
func newStream(id uint32, sess *Session) *Stream {
	s := new(Stream)
	s.id = id
	s.sess = sess
	s.recvQ = newRecvQueue()
	s.recvWin.initial = sess.recvWindow
	// only a conservative credit until ServerSettings arrives
	s.send = newSendWindow(minRecvWindow)
	s.writeDeadline = pipe.MakePipeDeadline()
	return s
}

// Read implements net.Conn
func (s *Stream) Read(b []byte) (n int, err error) {
	n, err = s.recvQ.read(b)
	if n > 0 && !s.dead.Load() {
		if inc := s.recvWin.consume(int64(n)); inc > 0 {
			_ = s.sess.writeWindow(s.id, inc)
		}
	}
	return
}

// Write implements net.Conn
func (s *Stream) Write(b []byte) (n int, err error) {
	for len(b) > 0 {
		select {
		case <-s.writeDeadline.Wait():
			return n, os.ErrDeadlineExceeded
		default:
		}
		if s.dead.Load() {
			return n, s.dieErr
		}
		want := len(b)
		if want > maxFrameDataLen {
			want = maxFrameDataLen
		}
		granted, err := s.send.acquire(int64(want))
		if err != nil {
			return n, err
		}
		chunk := b[:granted]
		if _, err = s.sess.writeDataFrame(s.id, chunk); err != nil {
			return n, err
		}
		n += len(chunk)
		b = b[len(chunk):]
	}
	return n, nil
}

// writeDestination sends the first PSH of the stream, it is not subject to flow control.
func (s *Stream) writeDestination(b []byte) error {
	_, err := s.sess.writeDataFrame(s.id, b)
	return err
}

// Close implements net.Conn
func (s *Stream) Close() error {
	var once bool
	s.dieOnce.Do(func() {
		s.dieErr = io.ErrClosedPipe
		s.dead.Store(true)
		s.recvQ.close(io.ErrClosedPipe, true)
		s.send.close()
		once = true
	})
	if once {
		err := s.sess.streamClosed(s.id)
		if s.dieHook != nil {
			s.dieHook()
			s.dieHook = nil
		}
		return err
	}
	return s.dieErr
}

// closeLocally only closes Stream and don't notify remote peer, what is already
// buffered stays readable before readErr shows up.
func (s *Stream) closeLocally(readErr error) {
	var once bool
	s.dieOnce.Do(func() {
		s.dieErr = net.ErrClosed
		s.dead.Store(true)
		s.recvQ.close(readErr, false)
		s.send.close()
		once = true
	})
	if once {
		if s.dieHook != nil {
			s.dieHook()
			s.dieHook = nil
		}
	}
}

// closeWithError closes Stream with a reason reported by the remote peer.
func (s *Stream) closeWithError(err error) {
	var once bool
	s.dieOnce.Do(func() {
		s.dieErr = err
		s.dead.Store(true)
		s.recvQ.close(err, true)
		s.send.close()
		once = true
	})
	if once {
		_ = s.sess.streamClosed(s.id)
		if s.dieHook != nil {
			s.dieHook()
			s.dieHook = nil
		}
	}
}

func (s *Stream) SetReadDeadline(t time.Time) error {
	s.recvQ.deadline.Set(t)
	return nil
}

func (s *Stream) SetWriteDeadline(t time.Time) error {
	s.writeDeadline.Set(t)
	return nil
}

func (s *Stream) SetDeadline(t time.Time) error {
	s.SetWriteDeadline(t)
	return s.SetReadDeadline(t)
}

// LocalAddr satisfies net.Conn interface
func (s *Stream) LocalAddr() net.Addr {
	return s.sess.conn.LocalAddr()
}

// RemoteAddr satisfies net.Conn interface
func (s *Stream) RemoteAddr() net.Addr {
	return s.sess.conn.RemoteAddr()
}
