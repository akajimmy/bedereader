package com.nickp.komga_reader

import android.content.Intent
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    // Android 8+ outlines the focused view once a key is pressed; here that's the whole Flutter view, which showed as a
    // permanent yellow frame round the screen after the first remote press. The app draws its own focus outlines.
    // Switched off in three places because a single pass missed cases: after Back to the launcher and relaunching
    // (a fresh activity), the view that took focus was not the one the resume pass had already handled.
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // whichever view gains focus, at any time
            window.decorView.viewTreeObserver.addOnGlobalFocusChangeListener { _, focused ->
                focused?.defaultFocusHighlightEnabled = false
            }
        }
    }

    override fun onResume() {
        super.onResume()
        window.decorView.post { noFocusHighlight(window.decorView) }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) noFocusHighlight(window.decorView)
    }

    private fun noFocusHighlight(v: View) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        v.defaultFocusHighlightEnabled = false
        if (v is ViewGroup) {
            for (i in 0 until v.childCount) noFocusHighlight(v.getChildAt(i))
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Keep the screen on while the reader is open (lib/screen.dart). The flag only lives as long as the window,
        // so nothing is left behind if the app is closed while reading.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "komga_reader/screen").setMethodCallHandler { call, result ->
            when (call.method) {
                "keepOn" -> {
                    if (call.arguments == true) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                    result.success(null)
                }
                // App-wide brightness (lib/screen.dart): only this app's window, so leaving the app restores the
                // tablet's own level. -1 = follow the system.
                "brightness" -> {
                    val v = (call.arguments as Number).toFloat()
                    val lp = window.attributes
                    lp.screenBrightness = if (v < 0f) WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE else v.coerceIn(0.01f, 1f)
                    window.attributes = lp
                    result.success(null)
                }
                // What the screen is at right now (0..1), so switching "Automatic" off doesn't jump.
                "getBrightness" -> {
                    val own = window.attributes.screenBrightness
                    if (own >= 0f) {
                        result.success(own.toDouble())
                    } else {
                        val sys = Settings.System.getInt(contentResolver, Settings.System.SCREEN_BRIGHTNESS, 128)
                        result.success((sys / 255.0).coerceIn(0.0, 1.0))
                    }
                }
                // Installed version for the Info screen (versionName + build number from pubspec's version).
                "appVersion" -> {
                    val info = packageManager.getPackageInfo(packageName, 0)
                    val code = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode else @Suppress("DEPRECATION") info.versionCode.toLong()
                    result.success(mapOf("name" to info.versionName, "code" to code))
                }
                // Open a web link (Info screen credits) in the tablet's browser.
                "openUrl" -> {
                    try {
                        startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(call.arguments as String)))
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                // App-private storage for downloaded books (removed with the app; no permissions needed).
                "storageDir" -> result.success(filesDir.absolutePath)
                // Battery level (0..100) and whether it's charging, for the reader's clock (no permission needed).
                "battery" -> {
                    val bm = getSystemService(BATTERY_SERVICE) as BatteryManager
                    val level = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
                    val charging = Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && bm.isCharging
                    result.success(if (level in 0..100) mapOf("level" to level, "charging" to charging) else null)
                }
                else -> result.notImplemented()
            }
        }
    }
}
