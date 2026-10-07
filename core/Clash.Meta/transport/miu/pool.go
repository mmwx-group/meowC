package miu

import (
	"context"
	"fmt"
	"io"
	"math"
	"sync"
	"sync/atomic"
	"time"

	"github.com/metacubex/mihomo/transport/anytls/skiplist"
	"github.com/metacubex/mihomo/transport/anytls/util"
)

// sessionPool keeps idle MUX sessions for reuse, same policy as the AnyTLS client.
type sessionPool struct {
	die       context.Context
	dieCancel context.CancelFunc

	newSession func(ctx context.Context) (*Session, error)

	sessionCounter atomic.Uint64

	idleSession     *skiplist.SkipList[uint64, *Session]
	idleSessionLock sync.Mutex

	sessions     map[uint64]*Session
	sessionsLock sync.Mutex

	idleSessionTimeout time.Duration
	minIdleSession     int
}

func newSessionPool(ctx context.Context, newSession func(ctx context.Context) (*Session, error), idleSessionCheckInterval, idleSessionTimeout time.Duration, minIdleSession int) *sessionPool {
	p := &sessionPool{
		sessions:           make(map[uint64]*Session),
		newSession:         newSession,
		idleSessionTimeout: idleSessionTimeout,
		minIdleSession:     minIdleSession,
	}
	if idleSessionCheckInterval <= time.Second*5 {
		idleSessionCheckInterval = time.Second * 30
	}
	if p.idleSessionTimeout <= time.Second*5 {
		p.idleSessionTimeout = time.Second * 30
	}
	p.die, p.dieCancel = context.WithCancel(ctx)
	p.idleSession = skiplist.NewSkipList[uint64, *Session]()
	util.StartRoutine(p.die, idleSessionCheckInterval, p.idleCleanup)
	return p
}

func (p *sessionPool) CreateStream(ctx context.Context) (*Stream, error) {
	select {
	case <-p.die.Done():
		return nil, io.ErrClosedPipe
	default:
	}

	var err error
	session := p.getIdleSession()
	if session == nil {
		session, err = p.createSession(ctx)
	}
	if session == nil {
		return nil, fmt.Errorf("failed to create session: %w", err)
	}
	stream, err := session.OpenStream()
	if err != nil {
		session.Close()
		return nil, fmt.Errorf("failed to create stream: %w", err)
	}

	stream.dieHook = func() {
		// If Session is not closed, put this Stream to pool
		if !session.IsClosed() {
			select {
			case <-p.die.Done():
				// Now client has been closed
				session.Close()
			default:
				p.idleSessionLock.Lock()
				session.idleSince = time.Now()
				p.idleSession.Insert(math.MaxUint64-session.seq, session)
				p.idleSessionLock.Unlock()
			}
		}
	}

	return stream, nil
}

func (p *sessionPool) getIdleSession() (idle *Session) {
	p.idleSessionLock.Lock()
	if !p.idleSession.IsEmpty() {
		it := p.idleSession.Iterate()
		idle = it.Value()
		p.idleSession.Remove(it.Key())
	}
	p.idleSessionLock.Unlock()
	return
}

func (p *sessionPool) createSession(ctx context.Context) (*Session, error) {
	session, err := p.newSession(ctx)
	if err != nil {
		return nil, err
	}

	session.seq = p.sessionCounter.Add(1)
	session.dieHook = func() {
		p.idleSessionLock.Lock()
		p.idleSession.Remove(math.MaxUint64 - session.seq)
		p.idleSessionLock.Unlock()

		p.sessionsLock.Lock()
		delete(p.sessions, session.seq)
		p.sessionsLock.Unlock()
	}

	p.sessionsLock.Lock()
	p.sessions[session.seq] = session
	p.sessionsLock.Unlock()

	session.Run()
	return session, nil
}

func (p *sessionPool) Close() error {
	p.dieCancel()

	p.sessionsLock.Lock()
	sessionToClose := make([]*Session, 0, len(p.sessions))
	for _, session := range p.sessions {
		sessionToClose = append(sessionToClose, session)
	}
	p.sessions = make(map[uint64]*Session)
	p.sessionsLock.Unlock()

	for _, session := range sessionToClose {
		session.Close()
	}

	return nil
}

func (p *sessionPool) idleCleanup() {
	expTime := time.Now().Add(-p.idleSessionTimeout)
	activeCount := 0
	sessionToClose := make([]*Session, 0, p.idleSession.Len())

	p.idleSessionLock.Lock()
	it := p.idleSession.Iterate()
	for it.IsNotEnd() {
		session := it.Value()
		key := it.Key()
		it.MoveToNext()

		if !session.idleSince.Before(expTime) {
			activeCount++
			continue
		}

		if activeCount < p.minIdleSession {
			session.idleSince = time.Now()
			activeCount++
			continue
		}

		sessionToClose = append(sessionToClose, session)
		p.idleSession.Remove(key)
	}
	p.idleSessionLock.Unlock()

	for _, session := range sessionToClose {
		session.Close()
	}
}
