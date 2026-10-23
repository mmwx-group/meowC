package tun

import (
	"context"

	"net"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/metacubex/sing/common/logger"
)

// meowC: acceptLoop must survive transient Accept errors (e.g. EMFILE) and stop only when the listener is closed.
type flakyListener struct {
	calls atomic.Int32
	fails int32
}

func (l *flakyListener) Accept() (net.Conn, error) {
	n := l.calls.Add(1)
	if n <= l.fails {
		return nil, &net.OpError{Op: "accept", Net: "tcp", Err: syscall.EMFILE}
	}
	return nil, &net.OpError{Op: "accept", Net: "tcp", Err: net.ErrClosed}
}
func (l *flakyListener) Close() error   { return nil }
func (l *flakyListener) Addr() net.Addr { return &net.TCPAddr{} }

func TestAcceptLoopSurvivesTransientErrors(t *testing.T) {
	s := &System{ctx: context.Background(), logger: logger.NOP()}
	l := &flakyListener{fails: 3}
	done := make(chan struct{})
	go func() { s.acceptLoop(l, nil); close(done) }()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("acceptLoop did not return after the listener was closed")
	}
	if got := l.calls.Load(); got != 4 {
		t.Fatalf("Accept called %d times, want 4 (3 transient errors, then closed)", got)
	}
}

func TestAcceptLoopStopsOnContextCancel(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	s := &System{ctx: ctx, logger: logger.NOP()}
	l := &flakyListener{fails: 1 << 30}
	done := make(chan struct{})
	go func() { s.acceptLoop(l, nil); close(done) }()
	time.Sleep(50 * time.Millisecond)
	cancel()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("acceptLoop kept running after the context was cancelled")
	}

}
