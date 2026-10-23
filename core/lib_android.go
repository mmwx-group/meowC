//go:build android && cgo

package main

import "C"
import (
	"context"
	bridge "core/dart-bridge"
	"core/platform"
	"core/state"
	t "core/tun"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/component/process"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/listener/sing_tun"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
	"golang.org/x/sync/semaphore"
	"net"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unsafe"
)

type TunHandler struct {
	listener *sing_tun.Listener
	callback unsafe.Pointer

	limit *semaphore.Weighted
}

func (t *TunHandler) close() {
	_ = t.limit.Acquire(context.TODO(), 4)
	defer t.limit.Release(4)
	removeTunHook()
	if t.listener != nil {
		_ = t.listener.Close()
	}

	if t.callback != nil {
		releaseObject(t.callback)
	}
	t.callback = nil
	t.listener = nil
}

func (t *TunHandler) handleProtect(fd int) {
	_ = t.limit.Acquire(context.Background(), 1)
	defer t.limit.Release(1)

	cb := t.callback
	if cb == nil {
		return
	}

	Protect(cb, fd)
}

func (t *TunHandler) handleResolveProcess(source, target net.Addr) string {
	_ = t.limit.Acquire(context.Background(), 1)
	defer t.limit.Release(1)

	if t.listener == nil {
		return ""
	}
	var protocol int
	uid := -1
	switch source.Network() {
	case "udp", "udp4", "udp6":
		protocol = syscall.IPPROTO_UDP
	case "tcp", "tcp4", "tcp6":
		protocol = syscall.IPPROTO_TCP
	}
	if version < 29 {
		uid = platform.QuerySocketUidFromProcFs(source, target)
	}
	return ResolveProcess(t.callback, protocol, source.String(), target.String(), uid)
}

var (
	tunLock    sync.Mutex
	runTime    *time.Time
	errBlocked = errors.New("blocked")
	tunHandler atomic.Pointer[TunHandler]
)

func init() {
	dialer.DefaultSocketHook = func(network, address string, conn syscall.RawConn) error {
		if platform.ShouldBlockConnection() {
			return errBlocked
		}
		handler := tunHandler.Load()
		if handler != nil {
			return conn.Control(func(fd uintptr) {
				handler.handleProtect(int(fd))
			})
		}
		return nil
	}
}

func handleStopTun() {
	tunLock.Lock()
	defer tunLock.Unlock()
	runTime = nil
	handler := tunHandler.Swap(nil)
	if handler != nil {
		handler.close()
	}
}

func handleStartTun(fd int, callback unsafe.Pointer) {
	handleStopTun()
	tunLock.Lock()
	defer tunLock.Unlock()
	now := time.Now()
	runTime = &now
	if fd != 0 {
		if currentConfig == nil {
			log.Warnln("[APP] handleStartTun called before setupConfig")
			handleStopTun()
			return
		}
		handler := &TunHandler{
			callback: callback,
			limit:    semaphore.NewWeighted(4),
		}
		tunHandler.Store(handler)
		initTunHook()
		tunListener, _ := t.Start(fd, currentConfig.General.Tun.Device, currentConfig.General.Tun.Stack, currentConfig.General.Tun.DisableICMPForwarding, uint32(currentConfig.General.Tun.MTU), currentConfig.General.IPv6)
		if tunListener != nil {
			log.Infoln("TUN address: %v", tunListener.Address())
			handler.listener = tunListener
			scheduleGroupRecheck()
		} else {
			removeTunHook()
			tunHandler.Store(nil)
		}
	}
}

// MeowX：TUN 建好、socket protect 就位后，重测一遍自动组（fallback / url-test / load-balance）里被判失效的节点。
// mihomo 在加载配置时立即发起首轮健康检查（不受 lazy 影响，失败一次即判死、不重试）。自动连接 / 磁贴 / 开机，或打开
// App 后马上连接这类 setupConfig 紧接着建 VPN 的路径里，这轮检查的 socket 还没 protect（tunHandler 在上面才设置），
// VPN 一生效就被改道进 TUN；期间还会多次 ResetConnection 打断在途的 DoH 解析。被误判失效的节点（fallback 里常是
// 排第一、握手最慢的 vless / REALITY）要等 interval（默认 300s）才重测，这段时间 fallback 一直停在后面的节点。
//   - 延后 6s：让那一轮未 protect 的探测（每个最多 5s）全部结束，免得旧的失败结果晚到、覆盖新结果。
//   - 只测当前失效的、每个「节点 × 测速地址」只测一次：存活状态挂在共享的节点对象上、以最后写入为准，
//     整组重跑会让同一节点被多个组并发探测，偶发的一次超时（总是最后结束）反而把好节点判死。
var groupRecheckGen atomic.Uint64

func scheduleGroupRecheck() {
	gen := groupRecheckGen.Add(1)
	time.AfterFunc(6*time.Second, func() {
		// 期间又重启了 TUN（会重新排一次）或已经停了：这次作废
		if groupRecheckGen.Load() != gen || tunHandler.Load() == nil {
			return
		}
		type target struct {
			proxy constant.Proxy
			url   string
		}
		var targets []target
		seen := make(map[string]struct{})
		for _, group := range tunnel.Proxies() {
			switch group.Type() {
			case constant.Fallback, constant.URLTest, constant.LoadBalance:
			default:
				continue
			}
			members, ok := group.Adapter().(interface{ Proxies() []constant.Proxy })
			if !ok {
				continue
			}
			// 组的测速地址没有导出，从它的 JSON 里取（fallback 判断存活看的就是这个地址）
			var info struct {
				TestURL string `json:"testUrl"`
			}
			if raw, err := group.MarshalJSON(); err != nil || json.Unmarshal(raw, &info) != nil {
				continue
			}
			url := strings.TrimSpace(info.TestURL)
			if url == "" {
				continue
			}
			for _, member := range members.Proxies() {
				if member.AliveForTestUrl(url) {
					continue
				}
				key := member.Name() + "\x00" + url
				if _, dup := seen[key]; dup {
					continue
				}
				seen[key] = struct{}{}
				targets = append(targets, target{member, url})
			}
		}
		if len(targets) == 0 {
			return
		}
		log.Infoln("[APP] recheck %d proxies marked dead before TUN was up", len(targets))
		sem := semaphore.NewWeighted(8)
		for _, t := range targets {
			go func(t target) {
				if sem.Acquire(context.Background(), 1) != nil {
					return
				}
				defer sem.Release(1)
				ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
				defer cancel()
				_, _ = t.proxy.URLTest(ctx, t.url, nil) // 结果经 UrlTestHook 推给 App，fallback 下次选路即生效
			}(t)
		}
	})
}

func handleGetRunTime() string {
	if runTime == nil {
		return ""
	}
	return strconv.FormatInt(runTime.UnixMilli(), 10)
}

func initTunHook() {
	process.DefaultPackageNameResolver = func(metadata *constant.Metadata) (string, error) {
		src, dst := metadata.RawSrcAddr, metadata.RawDstAddr
		if src == nil || dst == nil {
			return "", process.ErrInvalidNetwork
		}
		handler := tunHandler.Load()
		if handler == nil {
			return "", errors.New("tun is closed")
		}
		return handler.handleResolveProcess(src, dst), nil
	}
}

func removeTunHook() {
	process.DefaultPackageNameResolver = nil
}

func handleGetAndroidVpnOptions() string {
	tunLock.Lock()
	defer tunLock.Unlock()
	if currentConfig == nil {
		log.Warnln("[APP] handleGetAndroidVpnOptions called before setupConfig")
		return ""
	}
	ipv6Address := ""
	if currentConfig.General.IPv6 {
		ipv6Address = state.DefaultIpv6Address
	}
	options := state.AndroidVpnOptions{
		Enable:                state.CurrentState.VpnProps.Enable,
		Port:                  currentConfig.General.MixedPort,
		Ipv4Address:           state.DefaultIpv4Address,
		Ipv6Address:           ipv6Address,
		AccessControl:         state.CurrentState.VpnProps.AccessControl,
		SystemProxy:           state.CurrentState.VpnProps.SystemProxy,
		AllowBypass:           state.CurrentState.VpnProps.AllowBypass,
		RouteAddress:          currentConfig.General.Tun.RouteAddress,
		RouteMode:             state.CurrentState.VpnProps.RouteMode,
		BypassDomain:          state.CurrentState.BypassDomain,
		DnsServerAddress:      state.GetDnsServerAddress(),
		DozeSuspend:           state.CurrentState.VpnProps.DozeSuspend,
		DisableIcmpForwarding: currentConfig.General.Tun.DisableICMPForwarding,
		Mtu:                   uint32(currentConfig.General.Tun.MTU),
	}
	data, err := json.Marshal(options)
	if err != nil {
		fmt.Println("Error:", err)
		return ""
	}
	return string(data)
}

func handleUpdateDns(value string) {
	go func() {
		log.Infoln("[DNS] updateDns %s", value)
		dns.UpdateSystemDNS(strings.Split(value, ","))
		dns.FlushCacheWithDefaultResolver()
	}()
}

func handleGetCurrentProfileName() string {
	if state.CurrentState == nil {
		return ""
	}
	return state.CurrentState.CurrentProfileName
}

func nextHandle(action *Action, result ActionResult) bool {
	switch action.Method {
	case getAndroidVpnOptionsMethod:
		result.success(handleGetAndroidVpnOptions())
		return true
	case updateDnsMethod:
		data := action.Data.(string)
		handleUpdateDns(data)
		result.success(true)
		return true
	case getRunTimeMethod:
		result.success(handleGetRunTime())
		return true
	case getCurrentProfileNameMethod:
		result.success(handleGetCurrentProfileName())
		return true
	}
	return false
}

//export quickStart
func quickStart(initParamsChar *C.char, paramsChar *C.char, stateParamsChar *C.char, port C.longlong) {
	i := int64(port)
	paramsString := C.GoString(initParamsChar)
	bytes := []byte(C.GoString(paramsChar))
	stateParams := C.GoString(stateParamsChar)
	go func() {
		res := handleInitClash(paramsString)
		if res == false {
			bridge.SendToPort(i, "init error")
			return // 上游 Bettbox 60c9862e：初始化失败后不再接着套配置
		}
		handleSetState(stateParams)
		bridge.SendToPort(i, handleSetupConfig(bytes))
	}()
}

//export startTUN
func startTUN(fd C.int, callback unsafe.Pointer) bool {
	handleStartTun(int(fd), callback)
	return true
}

//export getRunTime
func getRunTime() *C.char {
	return C.CString(handleGetRunTime())
}

//export stopTun
func stopTun() {
	handleStopTun()
}

//export getCurrentProfileName
func getCurrentProfileName() *C.char {
	return C.CString(handleGetCurrentProfileName())
}

//export getAndroidVpnOptions
func getAndroidVpnOptions() *C.char {
	return C.CString(handleGetAndroidVpnOptions())
}

//export setState
func setState(s *C.char) {
	paramsString := C.GoString(s)
	handleSetState(paramsString)
}

//export updateDns
func updateDns(s *C.char) {
	dnsList := C.GoString(s)
	handleUpdateDns(dnsList)
}
