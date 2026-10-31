package com.appshub.bettbox.meowx

import android.app.Activity
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * MeowX：小组件与 Dart 侧的通道「meowx/widget」，只挂在 App 界面的引擎上（`MainActivity`）。
 * - Dart → 原生：`update`（写入小组件数据并重画）、`consumePendingMode`（取走小组件上点的、App 没开时没法立刻切的模式）。
 * - 原生 → Dart：`setMode`（App 界面在时，小组件上点模式直接切，不打开 App）。
 * 挂上 / 卸下时都重画一次小组件：模式分段的点击动作随之在「广播进本进程」与「打开 App」之间换。
 */
class MeowXWidgetPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    companion object {
        @Volatile
        private var channel: MethodChannel? = null
        private val mainHandler = Handler(Looper.getMainLooper())

        val isAttached: Boolean get() = channel != null

        /** 小组件上点了模式：分段先挪过去；App 界面在就交给它切，不在就记下来打开 App。 */
        fun requestMode(context: Context, mode: String) {
            MeowXWidgetStore.setMode(context, mode)
            MeowXWidgets.refreshAll(context)
            val ch = channel
            if (ch != null) {
                mainHandler.post { runCatching { ch.invokeMethod("setMode", mode) } }
            } else {
                MeowXWidgetStore.setPendingMode(context, mode)
                runCatching {
                    context.packageManager.getLaunchIntentForPackage(context.packageName)
                        ?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        ?.let(context::startActivity)
                }
            }
        }
    }

    private var context: Context? = null
    private var own: MethodChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        own = MethodChannel(binding.binaryMessenger, "meowx/widget").also {
            it.setMethodCallHandler(this)
            channel = it
        }
        MeowXWidgets.refreshAll(binding.applicationContext)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        own?.setMethodCallHandler(null)
        if (channel === own) channel = null
        own = null
        context = null
        MeowXWidgets.refreshAll(binding.applicationContext)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val ctx = context ?: return result.success(null)
        when (call.method) {
            "update" -> {
                (call.arguments as? Map<*, *>)?.let { MeowXWidgetStore.save(ctx, it) }
                MeowXWidgets.refreshAll(ctx)
                result.success(null)
            }
            "consumePendingMode" -> result.success(MeowXWidgetStore.consumePendingMode(ctx))
            else -> result.notImplemented()
        }
    }
}

/**
 * MeowX：App 界面不在时，小组件上的模式分段点到这里——记下要切的模式、打开 App，自己马上结束（不显示任何界面）。
 * 用 Activity 而不是广播里 startActivity：安卓 10 起广播里拉起界面会被后台启动限制拦下，小组件直接打开 Activity 不受限。
 */
class MeowXWidgetModeActivity : Activity() {
    companion object {
        private const val EXTRA_MODE = "mode"

        fun pendingIntent(context: Context, mode: String, code: Int): PendingIntent {
            val intent = Intent(context, MeowXWidgetModeActivity::class.java)
                .putExtra(EXTRA_MODE, mode)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION)
            return PendingIntent.getActivity(context, code, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        intent.getStringExtra(EXTRA_MODE)?.let { mode ->
            MeowXWidgetStore.setMode(this, mode)
            MeowXWidgetStore.setPendingMode(this, mode)
            MeowXWidgets.refreshAll(this)
        }
        packageManager.getLaunchIntentForPackage(packageName)?.let { startActivity(it) }
        finish()
        @Suppress("DEPRECATION")
        overridePendingTransition(0, 0)
    }
}
