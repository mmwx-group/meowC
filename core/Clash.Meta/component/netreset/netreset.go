// Package netreset (meowC) collects hooks that drop pooled / idle connections when the device's
// underlying network changes. Android's TUN runs without mihomo's interface monitor
// (AutoDetectInterface is off), so nothing else tells connection pools that the network they were
// dialed on is gone; pooled connections from the old network then fail or hang when reused.
package netreset

import "sync"

var (
	mu    sync.Mutex
	next  uint64
	hooks = map[uint64]func(){}
)

// Register adds fn and returns a function that removes it again.
func Register(fn func()) (unregister func()) {
	mu.Lock()
	next++
	id := next
	hooks[id] = fn
	mu.Unlock()
	return func() {
		mu.Lock()
		delete(hooks, id)
		mu.Unlock()
	}
}

// Run calls every registered hook.
func Run() {
	mu.Lock()
	fns := make([]func(), 0, len(hooks))
	for _, fn := range hooks {
		fns = append(fns, fn)
	}
	mu.Unlock()
	for _, fn := range fns {
		fn()
	}
}
