//go:build !unix

package miu

import "net"

// connAlive cannot look at a connection without taking data off it here, every
// idle lane counts as alive: a dead one is found out by the stream that gets it,
// which then replays on a new lane.
func connAlive(net.Conn) (alive, pending bool) { return true, false }
