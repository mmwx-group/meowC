package com.appshub.bettbox.plugins

import android.annotation.SuppressLint
import android.net.Network
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.security.cert.X509Certificate
import javax.net.ssl.HostnameVerifier
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager

/**
 * MeowX：拉订阅「直连」那一路在 VPN 底下的物理网络上发（连 DNS 一起，见 [Network.openConnection]），不进自己的 VPN。
 *
 * App 自己也在 VPN 里：Dart 的「直连」其实被 VPN 收进内核、按规则走代理节点。节点全连不上时（例如账号的节点全是
 * 只认白名单 IP 的服务器，关掉「白名单节点经喵窝连线」后）主控也跟着连不上，再打开开关也拉不回喵窝版节点，只能先断开 VPN。
 */
internal object DirectFetch {
    private const val MAX_REDIRECTS = 5

    /** 和 Dart 那边「直连」的老行为一致：接受任何证书（全局 HttpOverrides 一律放行） */
    private val trustAll: SSLContext by lazy {
        @SuppressLint("CustomX509TrustManager", "TrustAllX509TrustManager")
        val tm = object : X509TrustManager {
            override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) {}
            override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {}
            override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
        }
        SSLContext.getInstance("TLS").apply { init(null, arrayOf<TrustManager>(tm), null) }
    }

    /** GET [url]；返回 status / url（跳转后的）/ headers（键小写）/ body。连接层失败抛 IOException。 */
    fun get(
        network: Network,
        url: String,
        headers: Map<String, String>,
        connectTimeoutMs: Int,
        readTimeoutMs: Int,
        insecure: Boolean,
    ): Map<String, Any> {
        var target = URL(url)
        var sendHeaders = headers
        repeat(MAX_REDIRECTS + 1) {
            val conn = network.openConnection(target) as HttpURLConnection
            try {
                conn.instanceFollowRedirects = false
                conn.connectTimeout = connectTimeoutMs
                conn.readTimeout = readTimeoutMs
                conn.useCaches = false
                if (insecure && conn is HttpsURLConnection) {
                    conn.sslSocketFactory = trustAll.socketFactory
                    conn.hostnameVerifier = HostnameVerifier { _, _ -> true }
                }
                sendHeaders.forEach { (k, v) -> conn.setRequestProperty(k, v) }
                val status = conn.responseCode
                val location = conn.getHeaderField("Location")
                if (status in 300..399 && location != null) {
                    val next = URL(target, location)
                    // 跳到别的主机时不带订阅地址里的账号密码
                    if (next.host != target.host) sendHeaders = sendHeaders.filterKeys { !it.equals("Authorization", true) }
                    target = next
                    return@repeat
                }
                val stream = if (status >= 400) conn.errorStream else conn.inputStream
                val body = stream?.use { it.readBytes() } ?: ByteArray(0)
                val outHeaders = HashMap<String, List<String>>()
                for ((k, v) in conn.headerFields) {
                    if (k != null) outHeaders[k.lowercase()] = v
                }
                return mapOf("status" to status, "url" to target.toString(), "headers" to outHeaders, "body" to body)
            } finally {
                conn.disconnect()
            }
        }
        throw IOException("too many redirects")
    }
}
