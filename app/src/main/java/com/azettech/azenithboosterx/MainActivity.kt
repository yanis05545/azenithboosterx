package com.azettech.azenithboosterx

import android.annotation.SuppressLint
import android.os.Bundle
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class MainActivity : AppCompatActivity() {

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        val webView = findViewById<WebView>(R.id.webview)
        webView.settings.javaScriptEnabled = true
        webView.settings.domStorageEnabled = true
        webView.webViewClient = WebViewClient()
        webView.addJavascriptInterface(WebAppInterface(this, webView), "AzenithApp")

        // Minta akses root + deploy script di background supaya UI tidak freeze.
        CoroutineScope(Dispatchers.Main).launch {
            val granted = withContext(Dispatchers.IO) { RootShell.isRootAvailable() }
            if (!granted) {
                Toast.makeText(this@MainActivity, R.string.no_root, Toast.LENGTH_LONG).show()
            } else {
                withContext(Dispatchers.IO) { RootShell.deployScripts(this@MainActivity) }
            }
            // UI lama (webroot/index.html) tetap dipakai, sekarang disajikan dari assets app.
            webView.loadUrl("file:///android_asset/webroot/index.html")
        }
    }
}
