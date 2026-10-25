package com.nickp.komga_reader

import android.content.ClipData
import android.content.ClipboardManager
import android.content.ContentValues
import android.content.Intent
import android.content.res.Configuration
import android.database.ContentObserver
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.Settings
import android.view.OrientationEventListener
import android.view.Surface
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

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
        resumed = true
        updateListening()
    }

    override fun onPause() {
        resumed = false
        updateListening()
        super.onPause()
    }

    // ---- Auto rotation, the app's own (lib/rotation.dart, user 2026-10-24: "the app should handle the rotation so
    // it's not turning every time the tablet turns"): the tablet's tilt and its auto-rotate setting are read here and
    // sent to the app, which decides when to turn. Only while the app asks for it and is in front.
    private var rotationChannel: MethodChannel? = null
    private var followWanted = false
    private var resumed = false
    private var tiltListener: OrientationEventListener? = null
    private var autoRotateObserver: ContentObserver? = null
    private var lastTilt = Int.MIN_VALUE

    private fun systemAutoRotate() =
        Settings.System.getInt(contentResolver, Settings.System.ACCELEROMETER_ROTATION, 0) == 1

    private fun updateListening() {
        val on = followWanted && resumed
        if (on && tiltListener == null) {
            val observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
                override fun onChange(selfChange: Boolean) {
                    rotationChannel?.invokeMethod("systemAutoRotate", systemAutoRotate())
                }
            }
            contentResolver.registerContentObserver(
                Settings.System.getUriFor(Settings.System.ACCELEROMETER_ROTATION), false, observer)
            autoRotateObserver = observer
            val listener = object : OrientationEventListener(this) {
                override fun onOrientationChanged(angle: Int) {
                    val way = tiltWay(angle)
                    // only a change worth telling (the sensor reports several times a second)
                    if (way == lastTilt || (way >= 0 && lastTilt >= 0 && Math.abs(way - lastTilt) in 1..2)) return
                    lastTilt = way
                    rotationChannel?.invokeMethod("tilt", way)
                }
            }
            if (listener.canDetectOrientation()) listener.enable()
            tiltListener = listener
            lastTilt = Int.MIN_VALUE
            // (back in front: the setting may have changed meanwhile)
            rotationChannel?.invokeMethod("systemAutoRotate", systemAutoRotate())
        } else if (!on && tiltListener != null) {
            tiltListener?.disable()
            tiltListener = null
            autoRotateObserver?.let { contentResolver.unregisterContentObserver(it) }
            autoRotateObserver = null
        }
    }

    /// The display rotation now (Surface.ROTATION_*), and whether the device's natural orientation is portrait.
    private fun rotationNow(): Pair<Int, Boolean> {
        @Suppress("DEPRECATION")
        val rotation = if (Build.VERSION.SDK_INT >= 30) display?.rotation ?: Surface.ROTATION_0
            else windowManager.defaultDisplay.rotation
        val portraitNow = resources.configuration.orientation == Configuration.ORIENTATION_PORTRAIT
        val upright = rotation == Surface.ROTATION_0 || rotation == Surface.ROTATION_180
        return Pair(rotation, upright == portraitNow)
    }

    /// The sensor's angle (0 = the device upright as it naturally is, 90 = its left side up...) as the way up it
    /// leans to, in degrees: 0 portrait, 90 landscape, 180 portrait upside down, 270 landscape the other way (as
    /// currentWayUp names them); -1 lying flat.
    private fun tiltWay(angle: Int): Int {
        if (angle == OrientationEventListener.ORIENTATION_UNKNOWN) return -1
        val rotation = (360 - angle) % 360 // the display rotation that would keep it upright
        return (rotation + if (rotationNow().second) 0 else 90) % 360
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
        rotationChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "komga_reader/rotation").also {
            it.setMethodCallHandler { call, result ->
                when (call.method) {
                    // the app's Auto: tilt readings wanted (true) or not; answers the tablet's auto-rotate setting
                    "follow" -> {
                        followWanted = call.arguments == true
                        updateListening()
                        result.success(systemAutoRotate())
                    }
                    else -> result.notImplemented()
                }
            }
        }
        // Local libraries (experimental/sources, lib/local/android_files.dart): "All files access", so the folders
        // on the tablet read as plain paths. Android 11+: the special permission, granted on its Settings page; before
        // that, the storage permission asked for in place.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "komga_reader/files").setMethodCallHandler { call, result ->
            when (call.method) {
                "hasAllFiles" -> result.success(
                    if (Build.VERSION.SDK_INT >= 30) Environment.isExternalStorageManager()
                    else checkSelfPermission(android.Manifest.permission.READ_EXTERNAL_STORAGE) ==
                        android.content.pm.PackageManager.PERMISSION_GRANTED)
                "askAllFiles" -> {
                    if (Build.VERSION.SDK_INT >= 30) {
                        try {
                            startActivity(Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                                Uri.parse("package:$packageName")))
                        } catch (_: Exception) {
                            startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
                        }
                    } else {
                        requestPermissions(arrayOf(android.Manifest.permission.READ_EXTERNAL_STORAGE), 41)
                    }
                    result.success(null)
                }
                // where the tablet's own storage starts (/storage/emulated/0): for the folder field's hint
                "storageRoot" -> result.success(Environment.getExternalStorageDirectory().absolutePath)
                else -> result.notImplemented()
            }
        }
        // Keep the screen on while the reader is open (lib/screen.dart). The flag only lives as long as the window,
        // so nothing is left behind if the app is closed while reading.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "komga_reader/screen").setMethodCallHandler { call, result ->
            when (call.method) {
                // Which way up the screen is now, for the readers' rotation lock (lib/screen.dart OrientationLock): a
                // lock starts the way the tablet is held. The display's rotation counts from the device's natural
                // orientation, so that is worked out first (portrait now at 0 or 180 degrees = a natural portrait).
                "currentWayUp" -> {
                    val (rotation, naturalPortrait) = rotationNow()
                    result.success(if (naturalPortrait) when (rotation) {
                        Surface.ROTATION_0 -> "portrait"
                        Surface.ROTATION_90 -> "landscape"
                        Surface.ROTATION_180 -> "reversePortrait"
                        else -> "reverseLandscape"
                    } else when (rotation) {
                        Surface.ROTATION_0 -> "landscape"
                        Surface.ROTATION_90 -> "reversePortrait"
                        Surface.ROTATION_180 -> "reverseLandscape"
                        else -> "portrait"
                    })
                }
                "keepOn" -> {
                    if (call.arguments == true) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                    result.success(null)
                }
                // The reader's brightness (lib/screen.dart): only this app's window, so leaving the app restores the
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
                // Installed version for About (versionName + build number from pubspec's version).
                "appVersion" -> {
                    val info = packageManager.getPackageInfo(packageName, 0)
                    val code = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode else @Suppress("DEPRECATION") info.versionCode.toLong()
                    result.success(mapOf("name" to info.versionName, "code" to code))
                }
                // Open a web link (About's credits) in the tablet's browser.
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
                // What the app is connected through, for Downloads' "Wi-Fi only": "wifi" (Wi-Fi or a cable),
                // "cellular", "none", or "other" (VPN over something unknown, Bluetooth...).
                "network" -> {
                    val cm = getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager
                    val caps = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        cm.getNetworkCapabilities(cm.activeNetwork)
                    } else {
                        null
                    }
                    result.success(when {
                        caps == null -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) "none" else "wifi"
                        caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
                            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "wifi"
                        caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
                        else -> "other"
                    })
                }
                // Save page (the reader): into the Pictures/BeDeReader album - the gallery shows it; no permission
                // asked (Android 10+). Older Android: the app's own Pictures folder. Returns where, for the message.
                "savePicture" -> {
                    try {
                        val bytes = call.argument<ByteArray>("bytes")!!
                        val name = call.argument<String>("name")!!
                        val mime = call.argument<String>("mime")!!
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                            val values = ContentValues().apply {
                                put(MediaStore.Images.Media.DISPLAY_NAME, name)
                                put(MediaStore.Images.Media.MIME_TYPE, mime)
                                put(MediaStore.Images.Media.RELATIVE_PATH, "${Environment.DIRECTORY_PICTURES}/BeDeReader")
                                put(MediaStore.Images.Media.IS_PENDING, 1)
                            }
                            val uri = contentResolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)!!
                            try {
                                contentResolver.openOutputStream(uri)!!.use { it.write(bytes) }
                                values.clear()
                                values.put(MediaStore.Images.Media.IS_PENDING, 0)
                                contentResolver.update(uri, values, null, null)
                            } catch (e: Exception) {
                                // the half-made entry this call just added goes (it lingered hidden ~7 days - code
                                // review 2026-10-05, #21); the error is reported below
                                contentResolver.delete(uri, null, null)
                                throw e
                            }
                            result.success("Pictures/BeDeReader/$name")
                        } else {
                            val dir = File(getExternalFilesDir(Environment.DIRECTORY_PICTURES), "BeDeReader")
                            dir.mkdirs()
                            val file = File(dir, name)
                            file.writeBytes(bytes)
                            result.success(file.absolutePath)
                        }
                    } catch (e: Exception) {
                        result.error("save", e.message, null)
                    }
                }
                // Copy page (the reader): the picture on the clipboard, shared from the app's cache through its file
                // provider (the app pasting into is let read it).
                "copyPicture" -> {
                    try {
                        val dir = File(cacheDir, "shared")
                        dir.mkdirs()
                        dir.listFiles()?.forEach { it.delete() } // only the last page copied is kept
                        val file = File(dir, call.argument<String>("name")!!)
                        file.writeBytes(call.argument<ByteArray>("bytes")!!)
                        val uri = FileProvider.getUriForFile(this, "$packageName.files", file)
                        val clipboard = getSystemService(CLIPBOARD_SERVICE) as ClipboardManager
                        clipboard.setPrimaryClip(ClipData.newUri(contentResolver, file.name, uri))
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("copy", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
