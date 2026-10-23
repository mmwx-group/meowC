//go:build android && cgo

package main

import "C"
import (
	"github.com/metacubex/mihomo/component/iface"
	"github.com/metacubex/mihomo/component/netreset"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/log"
)

// MeowX：Android 的默认物理网络换了（Wi-Fi ↔ 移动数据、换了一个 Wi-Fi）。由 VPN 服务里跟踪
// 「最佳非 VPN 网络」的回调去抖后调（BettboxVpnService / UnderlyingNetworkTracker），不经 Flutter。
// Android 的 TUN 不开 mihomo 的网卡监听（AutoDetectInterface 关着），以前换网时内核什么都不知道：
// 旧网络上建的出站连接、DNS 连接、连接池里的空闲连接全是死的，要么挂到超时、要么被拿来复用，
// 表现为「用几个小时后没网、关掉重开才好」（三星 One UI 用户实报）。这里把它们一次清掉：
// 网卡缓存、DNS 上游连接与缓存、统计表里的全部连接、各协议的空闲连接池（netreset 钩子），再重测自动组。
func handleNetworkChanged() {
	if tunHandler.Load() == nil {
		return
	}
	log.Infoln("[APP] underlying network changed, resetting connections")
	iface.FlushCache()
	resolver.ResetConnection()
	dns.FlushCacheWithDefaultResolver()
	closeConnections()
	netreset.Run()
	scheduleGroupRecheck()
}

//export networkChanged
func networkChanged() {
	go handleNetworkChanged()
}
