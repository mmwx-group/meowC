package miu

import (
	"io"
	"sync"
)

// Per-stream flow control:
//   - the sender holds the window announced by the peer as credit, every n bytes of
//     data costs n, and it waits when the credit runs out;
//   - the receiver counts what the application has consumed and returns it with
//     cmdWindow once it reaches half of the initial window.
//
// There is no connection level window, congestion control is left to TCP. This only
// makes sure a slow stream cannot stall the other streams of the same session.

const (
	defaultRecvWindow = 2 << 20 // 2 MiB
	minRecvWindow     = 64 << 10
	maxRecvWindow     = 64 << 20

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

// recvWindow tracks the bytes consumed locally but not yet returned to the peer.
type recvWindow struct {
	mu       sync.Mutex
	initial  int64
	consumed int64
}

// consume records n bytes, it returns the increment to send with cmdWindow
// once the threshold is reached, 0 otherwise.
func (w *recvWindow) consume(n int64) uint32 {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.consumed += n
	if w.consumed*2 < w.initial {
		return 0
	}
	n = w.consumed
	w.consumed = 0
	return uint32(n)
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
