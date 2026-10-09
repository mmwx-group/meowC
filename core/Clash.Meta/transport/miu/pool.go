package miu

import (
	"context"
	"io"
	"time"
)

const (
	// How long an idle lane stays in the pool. The warmLanes put back last stay
	// for warmLaneIdle: two taps are often more than half a minute apart, and with
	// the pool empty the next one pays for a handshake again, while an idle lane
	// sends no heartbeat and costs next to nothing. The others go after
	// defaultLaneIdle. Neither is longer than what the server announced minus a
	// margin.
	defaultLaneIdle = 30 * time.Second
	warmLaneIdle    = 120 * time.Second
	warmLanes       = 4
	laneIdleMargin  = 5 * time.Second
	// idle lanes beyond this many: the oldest is closed
	maxIdleLanes = 32
	// Idle lanes are only topped up to minIdle when two streams were opened
	// within this long: the odd background connection is not worth more handshakes.
	laneBurstWindow = 10 * time.Second
	defaultMinIdle  = 2
	// for the dials that are not made for a request: prewarming, replaying
	dialTimeout = 10 * time.Second
)

type idleLane struct {
	l     *lane
	since time.Time
}

// ttl is how long l may stay idle as the idle lane number rank, 0 being the one
// put back last.
func (c *Client) ttl(l *lane, rank int) time.Duration {
	ttl := c.laneIdle
	if rank < warmLanes && ttl < c.warmIdle {
		ttl = c.warmIdle
	}
	if peer := time.Duration(l.peerIdle.Load()) * time.Second; peer > 2*laneIdleMargin && peer-laneIdleMargin < ttl {
		ttl = peer - laneIdleMargin
	}
	return ttl
}

// takeIdle returns the idle lane put back last that is still alive, nil when
// there is none.
func (c *Client) takeIdle(now time.Time) *lane {
	for {
		c.mu.Lock()
		n := len(c.idle)
		if n == 0 {
			c.mu.Unlock()
			return nil
		}
		it := c.idle[n-1]
		c.idle[n-1] = idleLane{}
		c.idle = c.idle[:n-1]
		c.mu.Unlock()

		// a look without taking data: the server may have closed it meanwhile.
		// Data waiting on a lane that carried a stream is the server closing it.
		alive, pending := connAlive(it.l.raw)
		if now.Sub(it.since) < c.ttl(it.l, 0) && alive && !(pending && it.l.used) {
			it.l.pooled = true
			return it.l
		}
		it.l.close()
	}
}

// get returns a lane for a new stream: an idle one, or else a new one. Streams
// coming in a burst have more lanes prewarmed in the background.
func (c *Client) get(ctx context.Context) (*lane, error) {
	now := time.Now()
	l := c.takeIdle(now)

	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		if l != nil {
			l.close()
		}
		return nil, io.ErrClosedPipe
	}
	burst := !c.lastOpen.IsZero() && now.Sub(c.lastOpen) <= laneBurstWindow
	c.lastOpen = now
	warm := 0
	if burst {
		if warm = c.minIdle - len(c.idle) - c.pending; warm < 0 {
			warm = 0
		}
		c.pending += warm
	}
	c.mu.Unlock()
	for i := 0; i < warm; i++ {
		go c.prewarm()
	}

	if l != nil {
		c.observe("lane:reuse")
		return l, nil
	}
	return c.dial(ctx)
}

// prewarm dials a lane for the pool. It outlives the request that triggered it,
// so it does not run on the context of that request.
func (c *Client) prewarm() {
	ctx, cancel := context.WithTimeout(c.ctx, dialTimeout)
	l, err := c.dial(ctx)
	cancel()
	c.mu.Lock()
	c.pending--
	c.mu.Unlock()
	if err == nil {
		c.put(l)
	}
}

// put hands an idle lane to the pool.
func (c *Client) put(l *lane) {
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		l.close()
		return
	}
	var oldest *lane
	if len(c.idle) >= maxIdleLanes {
		oldest = c.idle[0].l
		c.idle = append(c.idle[:0], c.idle[1:]...)
	}
	c.idle = append(c.idle, idleLane{l: l, since: time.Now()})
	// a lane more on top may have cut the time of one further down
	c.arm()
	c.mu.Unlock()
	if oldest != nil {
		oldest.close()
	}
}

// arm sets the sweeper to when the first idle lane runs out of time. mu must be held.
func (c *Client) arm() {
	if c.sweeper != nil {
		c.sweeper.Stop()
		c.sweeper = nil
	}
	if len(c.idle) == 0 {
		return
	}
	now := time.Now()
	var next time.Duration
	for i, it := range c.idle {
		if left := c.ttl(it.l, len(c.idle)-1-i) - now.Sub(it.since); i == 0 || left < next {
			next = left
		}
	}
	if next < 0 {
		next = 0
	}
	c.sweeper = time.AfterFunc(next, c.sweep)
}

// sweep closes the lanes that sat idle for too long and comes back for the rest.
func (c *Client) sweep() {
	now := time.Now()
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return
	}
	var stale []*lane
	keep := c.idle[:0]
	for i, it := range c.idle {
		if now.Sub(it.since) < c.ttl(it.l, len(c.idle)-1-i) {
			keep = append(keep, it)
		} else {
			stale = append(stale, it.l)
		}
	}
	for i := len(keep); i < len(c.idle); i++ {
		c.idle[i] = idleLane{}
	}
	c.idle = keep
	c.arm()
	c.mu.Unlock()
	for _, l := range stale {
		l.close()
	}
}
