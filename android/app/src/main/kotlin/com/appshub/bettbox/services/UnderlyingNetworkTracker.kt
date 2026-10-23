package com.appshub.bettbox.services

import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.appshub.bettbox.core.Core

/**
 * MeowX：跟踪 VPN 底下「最佳的非 VPN 网络」（即系统实际在用的物理网络），只在 VPN 开着时运行。
 *
 * - 每次它变了就 [VpnService.setUnderlyingNetworks]，系统据此判断 VPN 的计费 / 连通状态，
 *   被 protect 的出站 socket 也跟着走对的网络。
 * - 换成另一个网络（Wi-Fi ↔ 移动数据、换了一个 Wi-Fi，或断网后接上了别的网络）时去抖 1 秒，
 *   让内核清掉旧网络上建的连接、DNS 连接与空闲连接池（[Core.onUnderlyingNetworkChanged]）。
 *   以前只有系统 DNS 字符串变了才通知内核，三星常让 Wi-Fi 与移动数据同时在线，来回切时这个字符串往往不变，
 *   内核什么都不知道，死连接越积越多（One UI 用户实报「用几个小时后没网，关掉重开才好」）。
 * - 不依赖 Flutter 引擎：界面没开、只有服务在跑时照样生效。
 *
 * API 31+ 用 registerBestMatchingNetworkCallback，28–30 用 requestNetwork（只匹配、不额外拉起网络），
 * 更早的用 registerDefaultNetworkCallback（minSdk 是 26）。
 */
class UnderlyingNetworkTracker(private val service: VpnService) {
    companion object {
        private const val TAG = "UnderlyingNetwork"
        private const val RESET_DEBOUNCE_MS = 1000L
    }

    private val connectivity = service.getSystemService(ConnectivityManager::class.java)
    private val handler = Handler(Looper.getMainLooper())

    // 只在主线程上读写（回调都投到 handler 上）
    private var current: Network? = null
    private var lastSeen: Network? = null
    private var registered = false

    private val reset = Runnable {
        Log.i(TAG, "underlying network switched, resetting core connections")
        Core.onUnderlyingNetworkChanged()
    }

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            handler.post { onNetwork(network) }
        }

        override fun onLost(network: Network) {
            handler.post {
                if (network == current) {
                    current = null
                    runCatching { service.setUnderlyingNetworks(null) }
                }
            }
        }
    }

    private fun onNetwork(network: Network) {
        if (network == current) return
        current = network
        runCatching { service.setUnderlyingNetworks(arrayOf(network)) }
            .onFailure { Log.w(TAG, "setUnderlyingNetworks failed: ${it.message}") }
        val previous = lastSeen
        lastSeen = network
        // 第一次拿到网络（VPN 刚建好）不重置：内核刚起来，连接都是在这个网络上建的
        if (previous != null && previous != network) {
            handler.removeCallbacks(reset)
            handler.postDelayed(reset, RESET_DEBOUNCE_MS)
        }
    }

    fun start() {
        handler.post {
            if (registered || connectivity == null) return@post
            val request = NetworkRequest.Builder()
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED)
                .build()
            runCatching {
                when {
                    Build.VERSION.SDK_INT >= Build.VERSION_CODES.S ->
                        connectivity.registerBestMatchingNetworkCallback(request, callback, handler)
                    Build.VERSION.SDK_INT >= Build.VERSION_CODES.P ->
                        connectivity.requestNetwork(request, callback, handler)
                    else ->
                        connectivity.registerDefaultNetworkCallback(callback, handler)
                }
                registered = true
            }.onFailure { Log.e(TAG, "register network callback failed: ${it.message}") }
        }
    }

    fun stop() {
        handler.post {
            handler.removeCallbacks(reset)
            if (registered) {
                runCatching { connectivity?.unregisterNetworkCallback(callback) }
                registered = false
            }
            current = null
            lastSeen = null
        }
    }
}
