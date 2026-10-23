package keepalive

import (
	"net"
	"runtime"
	"time"

	"github.com/metacubex/mihomo/common/atomic"
)

var (
	keepAliveIdle     = atomic.NewInt64(0)
	keepAliveInterval = atomic.NewInt64(0)
	disableKeepAlive  = atomic.NewBool(false)
)

func SetKeepAliveIdle(t time.Duration) {
	keepAliveIdle.Store(int64(t))
}

func SetKeepAliveInterval(t time.Duration) {
	keepAliveInterval.Store(int64(t))
}

// meowC: upstream forces keep-alive off on Android (battery). Without it, connections that died
// on a network change / NAT timeout are only noticed after the write timeout (or never when idle),
// so stale sockets pile up — part of the "works for hours, then no network until reconnect" reports
// on Samsung phones. Keep it on, but never probe more often than this on Android.
const androidKeepAliveFloor = 60 * time.Second

func androidFloor(d time.Duration) time.Duration {
	if runtime.GOOS == "android" && d < androidKeepAliveFloor {
		return androidKeepAliveFloor
	}
	return d
}

func KeepAliveIdle() time.Duration {
	return androidFloor(time.Duration(keepAliveIdle.Load()))
}

func KeepAliveInterval() time.Duration {
	return androidFloor(time.Duration(keepAliveInterval.Load()))
}

func SetDisableKeepAlive(disable bool) {
	setDisableKeepAlive(disable)
}

func setDisableKeepAlive(disable bool) {
	disableKeepAlive.Store(disable)
}

func DisableKeepAlive() bool {
	return disableKeepAlive.Load()
}

func SetNetDialer(dialer *net.Dialer) {
	setNetDialer(dialer)
}

func SetNetListenConfig(lc *net.ListenConfig) {
	setNetListenConfig(lc)
}

func TCPKeepAlive(c net.Conn) {
	if tcp, ok := c.(TCPConn); ok && tcp != nil {
		tcpKeepAlive(tcp)
	}
}
