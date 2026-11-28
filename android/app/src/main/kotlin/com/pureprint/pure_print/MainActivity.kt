package com.pureprint.pure_print

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.Uri
import android.net.wifi.WifiManager
import android.provider.OpenableColumns
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.util.UUID

/**
 * 两个职责:
 *  1) 手机同时开着移动数据时,Android 会把默认路由指向蜂窝网络,导致发往局域网
 *     打印机(192.168.1.x)的连接报 "No route to host"。这里把进程绑定到 WiFi。
 *  2) 接收微信/系统「分享到」与「用其他应用打开」的文件,复制到 App 私有缓存后
 *     通过 MethodChannel 交给 Flutter 侧进入打印流程。
 *     只读 content:// 临时授权,不申请外部存储权限,文件不上传、不落公共目录。
 */
class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "pure_print/share"
        private const val UPDATE_CHANNEL = "pure_print/update"
        private const val SCAN_CHANNEL = "pure_print/scan"
    }

    private var wifiNetwork: Network? = null
    private var channel: MethodChannel? = null
    private var pendingShare: List<String> = emptyList()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        bindToWifi()
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialShare" -> result.success(pendingShare)
                "clearInitialShare" -> {
                    pendingShare = emptyList()
                    result.success(null)
                }
                "getWifiInfo" -> result.success(wifiInfo())
                else -> result.notImplemented()
            }
        }
        // 应用内更新:读版本、提供下载缓存目录、调起系统安装器
        val updateChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, UPDATE_CHANNEL)
        updateChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getAppVersion" -> try {
                    result.success(packageManager.getPackageInfo(packageName, 0).versionName ?: "")
                } catch (e: Exception) {
                    result.error("VERSION_FAILED", e.message, null)
                }
                "getCacheDir" -> result.success(cacheDir.absolutePath)
                "installApk" -> installApk(call.argument<String>("path"), result)
                else -> result.notImplemented()
            }
        }
        // 扫描:eSCL 结果的私有缓存目录 + FileProvider 分享
        val scanChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SCAN_CHANNEL)
        scanChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getScanDir" -> result.success(
                    File(cacheDir, "scans").apply { mkdirs() }.absolutePath
                )
                "shareFile" -> shareFile(
                    call.argument<String>("path"),
                    call.argument<String>("mime"),
                    result
                )
                else -> result.notImplemented()
            }
        }
        // 冷启动分享:Intent 在 Flutter 引擎创建前就已存在
        pendingShare = extractSharedFiles(intent)
    }

    /** 通过 FileProvider 把扫描件交给系统分享面板(不申请外部存储权限) */
    private fun shareFile(path: String?, mime: String?, result: MethodChannel.Result) {
        if (path.isNullOrEmpty()) {
            result.error("INVALID_PATH", "未找到扫描件路径", null)
            return
        }
        try {
            val file = File(path)
            if (!file.exists()) {
                result.error("NOT_FOUND", "扫描件不存在", null)
                return
            }
            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
            val intent = Intent(Intent.ACTION_SEND).apply {
                type = mime ?: "image/jpeg"
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            val chooser = Intent.createChooser(intent, "分享扫描件").apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            if (chooser.resolveActivity(packageManager) == null) {
                result.error("NO_SHARE_TARGET", "系统未提供分享目标", null)
                return
            }
            startActivity(chooser)
            result.success(true)
        } catch (e: Exception) {
            result.error("SHARE_FAILED", e.message, null)
        }
    }

    /** 通过 FileProvider 授权 content:// URI,调起系统安装器完成更新 */
    private fun installApk(path: String?, result: MethodChannel.Result) {
        if (path.isNullOrEmpty()) {
            result.error("INVALID_PATH", "未找到安装包路径", null)
            return
        }
        try {
            val apk = File(path)
            if (!apk.exists()) {
                result.error("NOT_FOUND", "安装包不存在", null)
                return
            }
            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", apk)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            if (intent.resolveActivity(packageManager) == null) {
                result.error("NO_INSTALLER", "系统未提供安装器", null)
                return
            }
            startActivity(intent)
            result.success(true)
        } catch (e: Exception) {
            result.error("INSTALL_FAILED", e.message, null)
        }
    }

    /** singleTop 热启动:应用已在后台,再次被分享唤起 */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val files = extractSharedFiles(intent)
        if (files.isNotEmpty()) channel?.invokeMethod("onSharedFiles", files)
    }

    // ---------------- WiFi 绑定 ----------------
    private fun bindToWifi() {
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

        cm.allNetworks.firstOrNull { n ->
            cm.getNetworkCapabilities(n)
                ?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
        }?.let { n ->
            wifiNetwork = n
            cm.bindProcessToNetwork(n)
        }

        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .build()
        cm.registerNetworkCallback(request, object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                wifiNetwork = network
                cm.bindProcessToNetwork(network)
            }

            override fun onLost(network: Network) {
                if (wifiNetwork == network) wifiNetwork = null
            }
        })
    }

    @SuppressLint("MissingPermission")
    private fun wifiInfo(): Map<String, Any> {
        var ssid = ""
        try {
            val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            ssid = wm?.connectionInfo?.ssid?.trim('"') ?: ""
        } catch (_: Exception) {
        }
        // Android 8+ 无位置权限时会返回占位值,此时不显示 SSID
        if (ssid == "<unknown ssid>" || ssid == "0x") ssid = ""
        return mapOf("bound" to (wifiNetwork != null), "ssid" to ssid)
    }

    // ---------------- 分享文件导入 ----------------
    @Suppress("DEPRECATION")
    private fun extractSharedFiles(src: Intent?): List<String> {
        val i = src ?: return emptyList()
        val uris = mutableListOf<Uri>()
        when (i.action) {
            Intent.ACTION_SEND -> i.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris.add(it) }
            Intent.ACTION_SEND_MULTIPLE -> i.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
                ?.let { uris.addAll(it) }
            Intent.ACTION_VIEW -> i.data?.let { uris.add(it) }
        }
        // 少数应用把本地路径放在 EXTRA_TEXT 里
        if (uris.isEmpty() && i.action == Intent.ACTION_SEND) {
            i.getStringExtra(Intent.EXTRA_TEXT)?.let { text ->
                if (text.startsWith("/")) uris.add(Uri.fromFile(File(text)))
            }
        }
        return uris.mapNotNull(::copyToCache)
    }

    /** content:// 只在本次授权窗口内可读,必须先复制一份到自己的缓存目录 */
    private fun copyToCache(uri: Uri): String? {
        return try {
            val mime = try {
                contentResolver.getType(uri) ?: ""
            } catch (_: Exception) {
                ""
            }
            var name = displayName(uri)
            if (!name.contains('.')) name += extForMime(mime)
            val safe = name.replace(Regex("[^A-Za-z0-9._\\-\\u4e00-\\u9fff]"), "_")
            val dir = File(cacheDir, "shared").apply { mkdirs() }
            val out = File(dir, "${UUID.randomUUID().toString().take(8)}_$safe")

            val input = if (uri.scheme == "file") {
                FileInputStream(File(uri.path ?: return null))
            } else {
                contentResolver.openInputStream(uri) ?: return null
            }
            input.use { src -> out.outputStream().use { dst -> src.copyTo(dst, 8192) } }
            if (out.length() == 0L) {
                out.delete()
                return null
            }
            out.absolutePath
        } catch (_: Exception) {
            null
        }
    }

    private fun displayName(uri: Uri): String {
        if (uri.scheme == "content") {
            try {
                contentResolver.query(uri, null, null, null, null)?.use { c ->
                    val idx = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (idx >= 0 && c.moveToFirst()) {
                        val n = c.getString(idx)
                        if (!n.isNullOrEmpty()) return n
                    }
                }
            } catch (_: Exception) {
            }
        }
        return uri.lastPathSegment?.takeIf { it.isNotEmpty() } ?: "shared_file"
    }

    private fun extForMime(mime: String): String = when {
        mime.contains("pdf") -> ".pdf"
        mime.startsWith("image/png") -> ".png"
        mime.startsWith("image/") -> ".jpg"
        mime.contains("wordprocessingml") -> ".docx"
        mime.contains("spreadsheetml") -> ".xlsx"
        mime == "application/msword" -> ".doc"
        mime.contains("excel") || mime.contains("ms-excel") -> ".xls"
        else -> ""
    }
}
