package com.appshub.bettbox.meowx

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.View
import android.widget.RemoteViews
import com.appshub.bettbox.BettboxApplication
import com.appshub.bettbox.GlobalState
import com.appshub.bettbox.R
import com.appshub.bettbox.RunState

/**
 * MeowX：桌面小组件（与 iOS 的 `Widget/StatusWidgetView.swift` 同一套设计）。
 *
 * 订阅名 / 已连接 + 运行时长 / 电源钮 / 本次流量 + 订阅用量 / 出站模式分段，小（2×2）中（4×2）两个尺寸。
 * 不显示网速：桌面上的数字不会每秒刷新，网速只会是旧数；本次流量是累计量，旧一点也不会错。
 *
 * 数据来源：连没连看原生的 [GlobalState.currentRunState]（App 没开、VPN 从磁贴 / 小组件起的时候也准）；
 * 订阅名、用量、模式、本次流量、运行时长起点由 Dart 侧（`lib/meowx/state/home_widget.dart`）经 [MeowXWidgetPlugin] 写进来，
 * 存在 SharedPreferences「meowx_widget」里，进程重启后照样画得出来。
 */
object MeowXWidgets {
    const val ACTION_TOGGLE = "com.miaomiaowux.widget.TOGGLE"
    const val ACTION_MODE = "com.miaomiaowux.widget.MODE"
    const val EXTRA_MODE = "mode"

    private val mainHandler = Handler(Looper.getMainLooper())

    /** 重画所有已放在桌面上的 MeowX 小组件。任意线程可调。 */
    fun refreshAll(context: Context = BettboxApplication.getAppContext()) {
        val app = context.applicationContext
        mainHandler.post {
            runCatching {
                val manager = AppWidgetManager.getInstance(app)
                for ((cls, small) in listOf(MeowXWidgetSmall::class.java to true, MeowXWidgetMedium::class.java to false)) {
                    val ids = manager.getAppWidgetIds(ComponentName(app, cls))
                    if (ids.isNotEmpty()) manager.updateAppWidget(ids, render(app, small))
                }
            }.onFailure { android.util.Log.e("MeowXWidget", "refresh failed: ${it.message}") }
        }
    }

    /** 隧道起停：连上时记一个运行时长起点（Dart 侧随后会写准确的），断开时清掉起点与本次流量。 */
    fun onRunState(state: RunState) {
        val context = runCatching { BettboxApplication.getAppContext() }.getOrNull() ?: return
        when (state) {
            RunState.START -> MeowXWidgetStore.markStarted(context)
            RunState.STOP -> MeowXWidgetStore.markStopped(context)
            RunState.PENDING -> {}
        }
        refreshAll(context)
    }

    fun render(context: Context, small: Boolean): RemoteViews {
        val s = MeowXWidgetStore.load(context)
        val connected = GlobalState.currentRunState == RunState.START
        val views = RemoteViews(context.packageName, if (small) R.layout.meowx_widget_small else R.layout.meowx_widget_medium)
        // 颜色一律按资源上色：安卓 12 起交给桌面在每次画的时候按当时的浅 / 深色取值（setColor），系统切深浅色时
        // 小组件跟着变；以前在这里取成具体色值，切了深浅色背景变了、字色还停在旧的（浅底上浅字看不见）。12 以下只能取死值。
        fun paint(id: Int, method: String, colorRes: Int) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) views.setColor(id, method, colorRes)
            else views.setInt(id, method, context.getColor(colorRes))
        }

        // 卡底与状态行：已连接樱粉、未连接中性色，同首页连接主卡
        views.setInt(R.id.meowx_w_root, "setBackgroundResource", if (connected) R.drawable.meowx_w_bg_on else R.drawable.meowx_w_bg_off)
        val secondaryOnBackground = if (connected) R.color.meowx_w_t2 else R.color.meowx_w_idle_text
        val tone = if (connected) R.color.meowx_w_good else secondaryOnBackground
        paint(R.id.meowx_w_dot, "setColorFilter", tone)
        paint(R.id.meowx_w_status, "setTextColor", tone)
        val state = if (connected) "保护中" else "未保护"
        views.setTextViewText(R.id.meowx_w_status, s.subName ?: if (small) state else "${modeName(s.mode)}模式 · $state")
        views.setTextViewText(R.id.meowx_w_title, if (connected) "已连接" else "未连接")

        if (!small) {
            if (connected && s.since > 0) {
                // 时长由系统自己走字，不需要为它刷新
                val base = SystemClock.elapsedRealtime() - (System.currentTimeMillis() - s.since).coerceAtLeast(0)
                views.setChronometer(R.id.meowx_w_uptime, base, "已运行 %s", true)
                views.setViewVisibility(R.id.meowx_w_uptime, View.VISIBLE)
                views.setViewVisibility(R.id.meowx_w_hint, View.GONE)
            } else {
                views.setChronometer(R.id.meowx_w_uptime, SystemClock.elapsedRealtime(), null, false)
                views.setViewVisibility(R.id.meowx_w_uptime, View.GONE)
                views.setViewVisibility(R.id.meowx_w_hint, if (connected) View.GONE else View.VISIBLE)
            }
            paint(R.id.meowx_w_uptime, "setTextColor", secondaryOnBackground)
            paint(R.id.meowx_w_hint, "setTextColor", secondaryOnBackground)
        }

        // 电源钮
        views.setInt(R.id.meowx_w_power, "setBackgroundResource", if (connected) R.drawable.meowx_w_power_on else R.drawable.meowx_w_power_off)
        paint(R.id.meowx_w_power_icon, "setColorFilter", if (connected) R.color.meowx_w_on_power_on else R.color.meowx_w_on_strong)
        views.setOnClickPendingIntent(R.id.meowx_w_power, broadcast(context, small, ACTION_TOGGLE, null, 1))

        // 本次流量：未连接一律 0、次要色
        val valueColor = if (connected) R.color.meowx_w_ink else R.color.meowx_w_t2
        views.setTextViewText(R.id.meowx_w_down, bytes(if (connected) s.sessionDown else 0))
        views.setTextViewText(R.id.meowx_w_up, bytes(if (connected) s.sessionUp else 0))
        paint(R.id.meowx_w_down, "setTextColor", valueColor)
        paint(R.id.meowx_w_up, "setTextColor", valueColor)
        paint(R.id.meowx_w_down_arrow, "setTextColor", if (connected) R.color.meowx_w_vio else R.color.meowx_w_t2)
        paint(R.id.meowx_w_up_arrow, "setTextColor", if (connected) R.color.meowx_w_rose else R.color.meowx_w_t2)

        // 订阅用量：中号文字 + 细条，小号一个环；没有总量的环不画
        val fraction = if (s.used != null && s.total != null && s.total > 0) (s.used.toDouble() / s.total).coerceIn(0.0, 1.0) else null
        if (small) {
            if (fraction != null) {
                val percent = (fraction * 100).toInt()
                views.setViewVisibility(R.id.meowx_w_ring_box, View.VISIBLE)
                views.setProgressBar(R.id.meowx_w_ring, 100, percent.coerceAtLeast(2), false)
                views.setTextViewText(R.id.meowx_w_ring_text, "$percent%")
            } else {
                views.setViewVisibility(R.id.meowx_w_ring_box, View.GONE)
            }
        } else {
            val text = usageText(s.used, s.total)
            if (text != null) {
                views.setViewVisibility(R.id.meowx_w_usage_box, View.VISIBLE)
                views.setViewVisibility(R.id.meowx_w_no_sub, View.GONE)
                views.setTextViewText(R.id.meowx_w_usage_text, text)
                views.setViewVisibility(R.id.meowx_w_usage_bar, if (fraction != null) View.VISIBLE else View.GONE)
                if (fraction != null) views.setProgressBar(R.id.meowx_w_usage_bar, 1000, (fraction * 1000).toInt().coerceAtLeast(10), false)
            } else {
                views.setViewVisibility(R.id.meowx_w_usage_box, View.GONE)
                views.setViewVisibility(R.id.meowx_w_no_sub, if (s.subName == null) View.VISIBLE else View.GONE)
            }
        }

        // 出站模式分段：App 界面在时直接切（广播进本进程，不打开 App）；不在时打开 App 由它切
        listOf("rule" to R.id.meowx_w_mode_rule, "global" to R.id.meowx_w_mode_global, "direct" to R.id.meowx_w_mode_direct)
            .forEachIndexed { index, (mode, id) ->
                val on = s.mode == mode
                views.setInt(id, "setBackgroundResource", if (on) R.drawable.meowx_w_seg_on else 0)
                paint(id, "setTextColor", if (on) R.color.meowx_w_on_strong else R.color.meowx_w_ink)
                val intent = if (MeowXWidgetPlugin.isAttached) {
                    broadcast(context, small, ACTION_MODE, mode, 10 + index)
                } else {
                    MeowXWidgetModeActivity.pendingIntent(context, mode, (if (small) 20 else 30) + index)
                }
                views.setOnClickPendingIntent(id, intent)
            }

        // 点别处打开 App
        context.packageManager.getLaunchIntentForPackage(context.packageName)?.let { launch ->
            val open = PendingIntent.getActivity(
                context, if (small) 2 else 3, launch, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            views.setOnClickPendingIntent(R.id.meowx_w_root, open)
        }
        return views
    }

    /** 按钮动作发给不导出的 [MeowXWidgetActionReceiver]：小组件的 Provider 必须导出（系统要给它发 APPWIDGET_UPDATE），
     *  别的 App 能往它发广播，开关 VPN / 切模式不能挂在它上面。PendingIntent 以本 App 身份发出，进得了不导出的接收器。 */
    private fun broadcast(context: Context, small: Boolean, action: String, mode: String?, code: Int): PendingIntent {
        val intent = Intent(context, MeowXWidgetActionReceiver::class.java).setAction(action)
        if (mode != null) intent.putExtra(EXTRA_MODE, mode)
        return PendingIntent.getBroadcast(
            context, code + if (small) 100 else 200, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    fun modeName(mode: String) = when (mode) {
        "global" -> "全局"
        "direct" -> "直连"
        else -> "规则"
    }

    /** 本次流量："820 KB" / "35.2 MB" / "1.2 GB"：KB 起步，100 以下留一位小数（去掉多余的 .0）。同 iOS。 */
    fun bytes(value: Long): String {
        val units = listOf("KB", "MB", "GB", "TB")
        var v = value.coerceAtLeast(0) / 1024.0
        var index = 0
        while (v >= 1000 && index < units.size - 1) {
            v /= 1024
            index += 1
        }
        return trim(String.format(java.util.Locale.US, if (v >= 100) "%.0f" else "%.1f", v)) + " " + units[index]
    }

    /** "128.4 / 500 GB"：两个数用同一个单位（按总量定）；只有已用量时单独显示。同 iOS。 */
    fun usageText(used: Long?, total: Long?): String? {
        if (used == null) return null
        if (total == null || total <= 0) {
            val unit = unit(used)
            return "${amount(used, unit.second)} ${unit.first}"
        }
        val unit = unit(total)
        return "${amount(used, unit.second)} / ${amount(total, unit.second)} ${unit.first}"
    }

    private fun unit(bytes: Long): Pair<String, Double> {
        val gb = 1024.0 * 1024 * 1024
        return when {
            bytes >= 1024 * gb -> "TB" to 1024 * gb
            bytes >= gb -> "GB" to gb
            else -> "MB" to 1024.0 * 1024
        }
    }

    private fun amount(bytes: Long, size: Double): String {
        val v = bytes.coerceAtLeast(0) / size
        return trim(String.format(java.util.Locale.US, if (v >= 1000) "%.0f" else "%.1f", v))
    }

    private fun trim(text: String) = if (text.endsWith(".0")) text.dropLast(2) else text
}

/** 小组件的数据（SharedPreferences「meowx_widget」）。 */
object MeowXWidgetStore {
    private const val PREFS = "meowx_widget"

    data class State(
        val subName: String?,
        val mode: String,
        val used: Long?,
        val total: Long?,
        val sessionUp: Long,
        val sessionDown: Long,
        /** 运行时长起点（墙上时钟毫秒），0 = 不知道 */
        val since: Long,
    )

    private fun prefs(context: Context) = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun load(context: Context): State {
        val p = prefs(context)
        return State(
            subName = p.getString("subName", null),
            mode = p.getString("mode", "rule") ?: "rule",
            used = p.getLong("used", -1).takeIf { it >= 0 },
            total = p.getLong("total", -1).takeIf { it >= 0 },
            sessionUp = p.getLong("sessionUp", 0),
            sessionDown = p.getLong("sessionDown", 0),
            since = p.getLong("since", 0),
        )
    }

    /** Dart 侧写来的一份（键见 `HomeWidgetData.toMap`）。 */
    fun save(context: Context, map: Map<*, *>) {
        fun long(key: String) = (map[key] as? Number)?.toLong()
        prefs(context).edit().apply {
            val name = map["subName"] as? String
            if (name.isNullOrEmpty()) remove("subName") else putString("subName", name)
            putString("mode", map["mode"] as? String ?: "rule")
            putLong("used", long("used") ?: -1)
            putLong("total", long("total") ?: -1)
            putLong("sessionUp", long("sessionUp") ?: 0)
            putLong("sessionDown", long("sessionDown") ?: 0)
            long("since")?.let { putLong("since", it) }
        }.apply()
    }

    fun setMode(context: Context, mode: String) {
        prefs(context).edit().putString("mode", mode).apply()
    }

    fun markStarted(context: Context) {
        val p = prefs(context)
        if (p.getLong("since", 0) == 0L) p.edit().putLong("since", System.currentTimeMillis()).apply()
    }

    fun markStopped(context: Context) {
        prefs(context).edit().putLong("since", 0).putLong("sessionUp", 0).putLong("sessionDown", 0).apply()
    }

    fun setPendingMode(context: Context, mode: String) {
        prefs(context).edit().putString("pendingMode", mode).apply()
    }

    /** 小组件上点的、还没交给 App 的模式；取走即清。 */
    fun consumePendingMode(context: Context): String? {
        val p = prefs(context)
        val mode = p.getString("pendingMode", null) ?: return null
        p.edit().remove("pendingMode").apply()
        return mode
    }
}

abstract class MeowXWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        MeowXWidgets.refreshAll(context)
    }
}

/** 小组件上的按钮（不导出，见 [MeowXWidgets] 里 broadcast 的说明）。 */
class MeowXWidgetActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            MeowXWidgets.ACTION_TOGGLE -> GlobalState.handleToggle()   // 同快捷磁贴：App 没开时起后台引擎
            MeowXWidgets.ACTION_MODE -> intent.getStringExtra(MeowXWidgets.EXTRA_MODE)?.let { MeowXWidgetPlugin.requestMode(context, it) }
        }
    }
}

class MeowXWidgetSmall : MeowXWidgetProvider()

class MeowXWidgetMedium : MeowXWidgetProvider()
