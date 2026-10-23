// Snell v6 connection reuse.
//
// Ported from github.com/sagernet/sing-snell (snellv6/reuse.go, client side,
// and internal/reuse/reuse.go), Copyright (C) 2022 by nekohasekai
// <contact-sagernet@sekai.icu>, licensed under the GNU General Public License
// v3.0 or later.
//
// A v6 connection carries one request at a time. Each side ends its half of a
// request with a zero chunk; once both zero chunks have passed, the next
// request may start on the same connection. A session is one such connection
// together with its record state, which lives across requests.
//
// Unlike the reference, a session is only reused after the server's zero
// chunk was actually received. A server that ends a request by closing the
// connection is therefore never taken for a reusable one.

package snell

import (
	"context"
	"errors"
	"io"
	"net"
	"sync"
	"sync/atomic"
	"time"

	N "github.com/metacubex/mihomo/common/net"
	"github.com/metacubex/mihomo/transport/shadowsocks/shadowaead"
)

const (
	v6PoolSize = 10
	// v6PoolMaxAge is how long a session may stay in the pool. The reference
	// keeps sessions for 180 seconds and drops them when the network
	// interface changes; there is no such signal here, so the age of the pool
	// of the earlier versions is used and a session that died unnoticed is
	// not handed out for long.
	v6PoolMaxAge        = 15 * time.Second
	v6PoolTimerInterval = 5 * time.Second
	// v6WaitingDiscardLimit is how much server data is discarded while waiting
	// for the server's zero chunk after the client closed its request.
	v6WaitingDiscardLimit = 0x80001
)

const (
	// v6StateReady: idle in the pool, may be taken for a request.
	v6StateReady uint32 = iota
	// v6StateActive: carrying a request.
	v6StateActive
	// v6StateWaiting: the client finished, the server's zero chunk is pending.
	v6StateWaiting
	// v6StateClosed: the connection is closed.
	v6StateClosed
)

type v6PoolEntry struct {
	session *v6Session
	time    time.Time
}

type v6Pool struct {
	access  sync.Mutex
	closed  bool
	entries []*v6PoolEntry
	stop    chan struct{}
	ticking bool
	drainWg sync.WaitGroup
}

func (p *v6Pool) init() {
	p.access.Lock()
	if p.stop == nil {
		p.stop = make(chan struct{})
	}
	p.access.Unlock()
}

func (p *v6Pool) isClosed() bool {
	p.access.Lock()
	closed := p.closed
	p.access.Unlock()
	return closed
}

// sweepLocked drops closed entries and returns the sessions that outlived the
// maximum age; the caller closes them after releasing the lock. With take set
// it also removes and returns the oldest ready session, marked active.
func (p *v6Pool) sweepLocked(now time.Time, take bool) (taken *v6Session, expired []*v6Session) {
	kept := p.entries[:0]
	for _, entry := range p.entries {
		state := entry.session.state.Load()
		if state == v6StateClosed {
			continue
		}
		if now.Sub(entry.time) > v6PoolMaxAge {
			expired = append(expired, entry.session)
			continue
		}
		if take && taken == nil && state == v6StateReady && entry.session.state.CompareAndSwap(v6StateReady, v6StateActive) {
			taken = entry.session
			continue
		}
		kept = append(kept, entry)
	}
	for index := len(kept); index < len(p.entries); index++ {
		p.entries[index] = nil
	}
	p.entries = kept
	return
}

func (p *v6Pool) take() (session *v6Session, found bool, closed bool) {
	p.access.Lock()
	closed = p.closed
	var expired []*v6Session
	if !closed {
		session, expired = p.sweepLocked(time.Now(), true)
		found = session != nil
	}
	p.access.Unlock()
	for _, expiredSession := range expired {
		_ = expiredSession.Close()
	}
	return
}

// moveToPool stores a session that is ready or waiting. It reports whether the
// session was stored; a session that was not stored is closed.
func (p *v6Pool) moveToPool(session *v6Session, state uint32, drain bool) bool {
	p.access.Lock()
	closed := p.closed
	var expired []*v6Session
	now := time.Now()
	if !closed {
		_, expired = p.sweepLocked(now, false)
	}
	var added bool
	if !closed && p.stop != nil && len(p.entries) < v6PoolSize {
		p.entries = append(p.entries, &v6PoolEntry{session: session, time: now})
		if state == v6StateWaiting && drain {
			p.drainWg.Add(1)
		}
		added = true
		if !p.ticking {
			p.ticking = true
			go p.expireLoop()
		}
	}
	p.access.Unlock()
	for _, expiredSession := range expired {
		_ = expiredSession.Close()
	}
	if !added {
		_ = session.Close()
	}
	return added
}

// expireLoop runs while the pool holds sessions and stops once it is empty.
func (p *v6Pool) expireLoop() {
	ticker := time.NewTicker(v6PoolTimerInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			p.access.Lock()
			if p.closed {
				p.ticking = false
				p.access.Unlock()
				return
			}
			_, expired := p.sweepLocked(time.Now(), false)
			empty := len(p.entries) == 0
			if empty {
				p.ticking = false
			}
			p.access.Unlock()
			for _, expiredSession := range expired {
				_ = expiredSession.Close()
			}
			if empty {
				return
			}
		case <-p.stop:
			return
		}
	}
}

// closeIdle (meowC) closes the pooled sessions but keeps the pool open for new ones.
func (p *v6Pool) closeIdle() {
	p.access.Lock()
	entries := p.entries
	p.entries = nil
	p.access.Unlock()
	for _, entry := range entries {
		_ = entry.session.Close()
	}
}

func (p *v6Pool) drainDone() {
	p.drainWg.Done()
}

func (p *v6Pool) close() error {
	p.access.Lock()
	if p.closed {
		p.access.Unlock()
		return nil
	}
	p.closed = true
	entries := p.entries
	p.entries = nil
	if p.stop != nil {
		close(p.stop)
	}
	p.access.Unlock()
	var closeErr error
	for _, entry := range entries {
		if err := entry.session.Close(); err != nil && closeErr == nil {
			closeErr = err
		}
	}
	p.drainWg.Wait()
	return closeErr
}

// v6Session is a server connection that carries one request after another.
type v6Session struct {
	net.Conn
	client *V6Client
	state  atomic.Uint32
	reader *v6RecordReader
	writer v6RecordWriter
}

func (s *v6Session) release(reusable bool) {
	if !reusable {
		_ = s.Close()
		return
	}
	if !s.state.CompareAndSwap(v6StateActive, v6StateReady) {
		if s.state.Load() != v6StateClosed {
			_ = s.Close()
		}
		return
	}
	s.client.pool.moveToPool(s, v6StateReady, false)
}

func (s *v6Session) Close() error {
	if s.state.Swap(v6StateClosed) == v6StateClosed {
		return nil
	}
	return s.Conn.Close()
}

// startDrain parks the session in the pool and reads on until the server's
// zero chunk arrives. No other goroutine may be reading the session.
func (s *v6Session) startDrain() {
	if !s.state.CompareAndSwap(v6StateActive, v6StateWaiting) {
		if s.state.Load() != v6StateClosed {
			_ = s.Close()
		}
		return
	}
	if !s.client.pool.moveToPool(s, v6StateWaiting, true) {
		return
	}
	go s.drain()
}

func (s *v6Session) drain() {
	defer s.client.pool.drainDone()
	var discarded int
	for {
		record, err := s.reader.nextRecord()
		if err == shadowaead.ErrZeroChunk {
			s.state.CompareAndSwap(v6StateWaiting, v6StateReady)
			return
		}
		if err != nil {
			_ = s.Close()
			return
		}
		discarded += len(record)
		if discarded >= v6WaitingDiscardLimit {
			_ = s.Close()
			return
		}
	}
}

// session returns an active session: a pooled one if there is any, otherwise
// one on a new connection.
func (c *V6Client) session(ctx context.Context) (*v6Session, error) {
	session, found, closed := c.pool.take()
	if closed {
		return nil, net.ErrClosed
	}
	if found {
		return session, nil
	}
	conn, err := c.dial(ctx)
	if err != nil {
		return nil, err
	}
	if c.pool.isClosed() {
		_ = conn.Close()
		return nil, net.ErrClosed
	}
	reader, writer, err := c.newRecordIO(conn)
	if err != nil {
		_ = conn.Close()
		return nil, err
	}
	session = &v6Session{Conn: conn, client: c, reader: reader, writer: writer}
	session.state.Store(v6StateActive)
	return session, nil
}

// DialContext starts a TCP request to host:port on a pooled connection, or on
// a new one when the pool has none. It needs a client created with Reuse.
// Closing the returned connection gives the server connection back to the
// pool when the request ended cleanly.
func (c *V6Client) DialContext(ctx context.Context, host string, port uint16) (conn net.Conn, err error) {
	if !c.reuse {
		return nil, errors.New("snell: connection reuse is disabled")
	}
	request, err := v6AppendRequest(nil, CommandConnectV2, host, port)
	if err != nil {
		return nil, err
	}
	session, err := c.session(ctx)
	if err != nil {
		return nil, err
	}
	// Registered first so that it runs after the context guard below has
	// settled the final error.
	defer func() {
		if err != nil {
			conn = nil
			_ = session.Close()
		}
	}()
	if ctx.Done() != nil {
		done := N.SetupContextForConn(ctx, session.Conn)
		defer done(&err)
	}
	if _, err = session.writer.Write(request); err != nil {
		return nil, err
	}
	return &v6ReuseConn{Conn: session.Conn, session: session}, nil
}

// v6ReuseConn is one request on a session.
type v6ReuseConn struct {
	net.Conn
	session *v6Session

	writeAccess sync.Mutex
	writeClosed bool

	closeWriteOnce  sync.Once
	closeWriteErr   error
	closeOnce       sync.Once
	closeErr        error
	replyRead       atomic.Bool
	closed          atomic.Bool
	readActionCount atomic.Int32
	readClosed      atomic.Bool
}

func (c *v6ReuseConn) Read(p []byte) (int, error) {
	if c.closed.Load() {
		return 0, net.ErrClosed
	}
	c.readActionCount.Add(1)
	defer c.readActionCount.Add(-1)
	if c.closed.Load() {
		return 0, net.ErrClosed
	}
	// What follows the server's zero chunk belongs to the next request.
	if c.readClosed.Load() {
		return 0, io.EOF
	}
	if !c.replyRead.Load() {
		if err := v6ReadReply(c.session.reader); err != nil {
			return 0, err
		}
		c.replyRead.Store(true)
	}
	var discarded int
	for {
		n, err := c.session.reader.Read(p)
		if c.closed.Load() {
			// Close found this read in flight and left the wait for the
			// server's zero chunk to it; whatever arrives is discarded.
			discarded += n
			if err == shadowaead.ErrZeroChunk {
				c.readClosed.Store(true)
				c.session.state.CompareAndSwap(v6StateWaiting, v6StateReady)
				return 0, io.EOF
			}
			if err != nil {
				_ = c.session.Close()
				return 0, err
			}
			if discarded >= v6WaitingDiscardLimit {
				_ = c.session.Close()
				return 0, errors.New("snell: read too much data after client EOF")
			}
			continue
		}
		if err == shadowaead.ErrZeroChunk {
			c.readClosed.Store(true)
			err = io.EOF
		}
		return n, err
	}
}

func (c *v6ReuseConn) Write(p []byte) (int, error) {
	// A record written after the zero chunk would be taken for the start of
	// the next request on this session.
	c.writeAccess.Lock()
	defer c.writeAccess.Unlock()
	if c.writeClosed {
		return 0, net.ErrClosed
	}
	return c.session.writer.Write(p)
}

// CloseWrite ends the client half of the request.
func (c *v6ReuseConn) CloseWrite() error {
	c.closeWriteOnce.Do(func() {
		c.writeAccess.Lock()
		c.writeClosed = true
		c.writeAccess.Unlock()
		c.closeWriteErr = c.session.writer.writeZeroChunk()
	})
	return c.closeWriteErr
}

// The deadlines belong to the server connection, which the next request
// inherits, so a request that is closed must not touch them any more.

func (c *v6ReuseConn) SetDeadline(t time.Time) error {
	if c.closed.Load() {
		return net.ErrClosed
	}
	return c.Conn.SetDeadline(t)
}

func (c *v6ReuseConn) SetReadDeadline(t time.Time) error {
	if c.closed.Load() {
		return net.ErrClosed
	}
	return c.Conn.SetReadDeadline(t)
}

func (c *v6ReuseConn) SetWriteDeadline(t time.Time) error {
	if c.closed.Load() {
		return net.ErrClosed
	}
	return c.Conn.SetWriteDeadline(t)
}

// Close ends the request. The session goes back to the pool when the server
// replied and the stream state is intact; it is closed otherwise.
func (c *v6ReuseConn) Close() error {
	c.closeOnce.Do(func() {
		c.closed.Store(true)
		if !c.replyRead.Load() || c.session.reader.dead() {
			c.session.release(false)
			return
		}
		c.closeErr = c.CloseWrite()
		if c.closeErr != nil {
			c.session.release(false)
			return
		}
		_ = c.session.Conn.SetReadDeadline(time.Time{})
		_ = c.session.Conn.SetWriteDeadline(time.Time{})
		if c.readClosed.Load() {
			c.session.release(true)
			return
		}
		// The server has not finished yet. A read that is in flight keeps
		// going and discards what it gets; without one, a drain is started.
		if c.readActionCount.Load() > 0 {
			if !c.session.state.CompareAndSwap(v6StateActive, v6StateWaiting) {
				if c.session.state.Load() != v6StateClosed {
					_ = c.session.Close()
				}
				return
			}
			poolState := v6StateWaiting
			if c.readClosed.Load() {
				c.session.state.CompareAndSwap(v6StateWaiting, v6StateReady)
				poolState = v6StateReady
			}
			c.session.client.pool.moveToPool(c.session, poolState, false)
			return
		}
		c.session.startDrain()
	})
	return c.closeErr
}
