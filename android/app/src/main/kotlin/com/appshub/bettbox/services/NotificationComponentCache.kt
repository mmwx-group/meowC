package com.appshub.bettbox.services

import android.content.ComponentName
import android.content.pm.PackageManager

object NotificationComponentCache {

    @Volatile
    private var cached: ComponentName? = null

    fun get(
        packageManager: PackageManager,
        defaultComponent: ComponentName,
        lightComponent: ComponentName,
        darkComponent: ComponentName,
    ): ComponentName {
        cached?.let { return it }

        synchronized(this) {
            cached?.let { return it }
            val result = resolve(packageManager, defaultComponent, lightComponent, darkComponent)
            cached = result
            return result
        }
    }

    fun invalidate() {
        cached = null
    }

    private fun resolve(
        packageManager: PackageManager,
        defaultComponent: ComponentName,
        lightComponent: ComponentName,
        darkComponent: ComponentName,
    ): ComponentName {
        val darkState = runCatching {
            packageManager.getComponentEnabledSetting(darkComponent)
        }.getOrDefault(PackageManager.COMPONENT_ENABLED_STATE_DEFAULT)

        val lightState = runCatching {
            packageManager.getComponentEnabledSetting(lightComponent)
        }.getOrDefault(PackageManager.COMPONENT_ENABLED_STATE_DEFAULT)

        // MeowX：换成 M 猫脸图标时 MainActivity 是停用的，通知要点开开着的那个 alias
        val mAlias = listOf("com.appshub.bettbox.MainActivityMDark", "com.appshub.bettbox.MainActivityMLight")
            .map { ComponentName(defaultComponent.packageName, it) }
            .firstOrNull {
                runCatching { packageManager.getComponentEnabledSetting(it) }
                    .getOrNull() == PackageManager.COMPONENT_ENABLED_STATE_ENABLED
            }

        return when {
            darkState == PackageManager.COMPONENT_ENABLED_STATE_ENABLED -> darkComponent
            lightState == PackageManager.COMPONENT_ENABLED_STATE_ENABLED -> lightComponent
            mAlias != null -> mAlias
            else -> defaultComponent
        }
    }
}
