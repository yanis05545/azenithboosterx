package com.azettech.azenithboosterx

import android.content.Context
import android.webkit.JavascriptInterface
import android.webkit.WebView

/**
 * Dipanggil dari JavaScript di webroot/index.html lewat:
 *   AzenithApp.runScript("core.sh", "status")
 *   AzenithApp.runCommand("getprop ro.product.model")
 * Dulu WebUI modul memanggil binary lewat shell sysfs milik root manager;
 * sekarang app ini yang menjadi "root manager"-nya.
 */
class WebAppInterface(private val context: Context, private val webView: WebView) {

    @JavascriptInterface
    fun isRooted(): Boolean = RootShell.isRootAvailable()

    @JavascriptInterface
    fun runCommand(command: String): String = RootShell.run(command)

    @JavascriptInterface
    fun redeployScripts(): String = RootShell.deployScripts(context)
}
