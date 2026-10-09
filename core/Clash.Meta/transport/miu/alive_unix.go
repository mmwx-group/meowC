//go:build unix

package miu

import (
	"net"
	"syscall"
)

// connAlive looks at an idle connection without taking any data off it: alive is
// false once the peer closed it (EOF or an error), pending tells that data is
// waiting to be read. A connection that cannot be looked at counts as alive.
func connAlive(c net.Conn) (alive, pending bool) {
	sc, ok := c.(syscall.Conn)
	if !ok {
		return true, false
	}
	rc, err := sc.SyscallConn()
	if err != nil {
		return true, false
	}
	alive = true
	_ = rc.Read(func(fd uintptr) bool {
		var b [1]byte
		n, _, e := syscall.Recvfrom(int(fd), b[:], syscall.MSG_PEEK|syscall.MSG_DONTWAIT)
		switch {
		case e == syscall.EAGAIN || e == syscall.EWOULDBLOCK || e == syscall.EINTR:
		case e != nil || n == 0:
			alive = false
		default:
			pending = true
		}
		return true
	})
	return
}
