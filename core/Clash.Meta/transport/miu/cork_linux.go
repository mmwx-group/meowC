package miu

import (
	"net"
	"syscall"
)

// setCork corks or uncorks the sending side of conn (TCP_CORK): what is written
// while corked does not leave in small packets of its own, it goes out together
// once uncorked. A connection without a socket to reach is left alone.
func setCork(conn net.Conn, on bool) {
	sc, ok := conn.(syscall.Conn)
	if !ok {
		return
	}
	rc, err := sc.SyscallConn()
	if err != nil {
		return
	}
	v := 0
	if on {
		v = 1
	}
	_ = rc.Control(func(fd uintptr) {
		_ = syscall.SetsockoptInt(int(fd), syscall.IPPROTO_TCP, syscall.TCP_CORK, v)
	})
}
