package miu

import (
	"io"
	"sync"
	"time"
)

// Per-stream flow control:
//   - the sender holds the window announced by the peer as credit, every n bytes of
//     data costs n, and it waits when the credit runs out;
//   - the receiver counts what the application has consumed and returns it with
//     cmdWindow once it reaches half of the window, and grows the window on the way
//     when the sender turns out to be stalled by it.
//
// There is no connection level window, congestion control is left to TCP. This only
// makes sure a slow stream cannot stall the other streams of the same session.

const (
	defaultRecvWindow = 2 << 20 // 2 MiB
	minRecvWindow     = 64 << 10
	maxRecvWindow     = 64 << 20

	// upper bound of the receive window auto-growth, see recvWindow.consume
	autoRecvWindowMax = 16 << 20

	// credit for a peer that did not announce miu=1
	unlimitedCredit = int64(1) << 62
)

type sendWindow struct {
	mu     sync.Mutex
	cond   *sync.Cond
	credit int64
	closed bool
}

func newSendWindow(initial int64) *sendWindow {
	w := &sendWindow{credit: initial}
	w.cond = sync.NewCond(&w.mu)
	return w
}

// acquire waits until some credit is available and takes up to max bytes of it.
// Taking what is there instead of waiting for the full amount matters: the peer
// only returns credit after consuming half a window, so with a window smaller
// than two frames a sender insisting on a whole frame would wait forever.
func (w *sendWindow) acquire(max int64) (int64, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	for !w.closed && w.credit <= 0 {
		w.cond.Wait()
	}
	if w.closed {
		return 0, io.ErrClosedPipe
	}
	if max > w.credit {
		max = w.credit
	}
	w.credit -= max
	return max, nil
}

func (w *sendWindow) add(n int64) {
	w.mu.Lock()
	w.credit += n
	w.mu.Unlock()
	w.cond.Broadcast()
}

func (w *sendWindow) close() {
	w.mu.Lock()
	w.closed = true
	w.mu.Unlock()
	w.cond.Broadcast()
}

// recvWindow tracks the bytes consumed locally but not yet returned to the peer,
// and grows the window when the peer is stalled by it.
type recvWindow struct {
	mu       sync.Mutex
	size     int64 // current window
	limit    int64 // upper bound of the auto-growth, the initial window = never grow
	consumed int64
	last     time.Time // when credit was last returned
}

func newRecvWindow(initial, limit int64) *recvWindow {
	if limit < initial {
		limit = initial
	}
	return &recvWindow{size: initial, limit: limit}
}

// consume records n bytes, it returns the increment to send with cmdWindow
// once half of the window is consumed, 0 otherwise.
//
// A sender stalled by the window runs at about window / rtt, so half a window is
// consumed every rtt / 2 or so; one held back by the network or by the application
// is slower than that. Two returns less than 2 x rtt apart therefore mean the window
// is too small: it is doubled and the extra credit goes out with this return (the
// credit of the sender is not capped, a return may exceed what was consumed).
// Without a measured rtt (rtt <= 0) the window never grows.
func (w *recvWindow) consume(n int64, now time.Time, rtt time.Duration) uint32 {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.consumed += n
	if w.consumed*2 < w.size {
		return 0
	}
	give := w.consumed
	w.consumed = 0
	if rtt > 0 && w.size < w.limit && !w.last.IsZero() && now.Sub(w.last) < 2*rtt {
		grow := w.size
		if grow > w.limit-w.size {
			grow = w.limit - w.size
		}
		w.size += grow
		give += grow
	}
	w.last = now
	return uint32(give)
}

func clampWindow(n int64) int64 {
	switch {
	case n <= 0:
		return defaultRecvWindow
	case n < minRecvWindow:
		return minRecvWindow
	case n > maxRecvWindow:
		return maxRecvWindow
	}
	return n
}
