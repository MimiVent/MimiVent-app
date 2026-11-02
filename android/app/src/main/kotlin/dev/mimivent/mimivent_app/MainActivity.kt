package dev.mimivent.mimivent_app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.location.LocationManager
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val handler = Handler(Looper.getMainLooper())
    private var scanReceiver: BroadcastReceiver? = null
    private var scanResult: MethodChannel.Result? = null
    private var scanTimeout: Runnable? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val credentials = WifiCredentialStorage(applicationContext)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mimivent/wifi_credentials")
            .setMethodCallHandler { call, result ->
                credentials.handle(call.method, call.argument<String>("value"), result)
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mimivent/wifi_scan")
            .setMethodCallHandler { call, result ->
                if (call.method == "scan") scan(result) else result.notImplemented()
            }
    }

    private fun scan(result: MethodChannel.Result) {
        if (scanResult != null) {
            result.error("BUSY", "正在搜索 WiFi，请稍候", null)
            return
        }
        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        val location = getSystemService(Context.LOCATION_SERVICE) as LocationManager
        if (!wifi.isWifiEnabled) {
            result.error("WIFI_DISABLED", "请先打开手机 WiFi，再搜索网络；也可以手动输入 SSID", null)
            return
        }
        if (!location.isProviderEnabled(LocationManager.GPS_PROVIDER) &&
            !location.isProviderEnabled(LocationManager.NETWORK_PROVIDER)) {
            result.error("LOCATION_DISABLED", "搜索 WiFi 需要打开系统定位；也可以手动输入 SSID", null)
            return
        }
        scanResult = result
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                finishScan(wifi, !intent.getBooleanExtra(WifiManager.EXTRA_RESULTS_UPDATED, false))
            }
        }
        scanReceiver = receiver
        try {
            val filter = IntentFilter(WifiManager.SCAN_RESULTS_AVAILABLE_ACTION)
            if (Build.VERSION.SDK_INT >= 33) {
                registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
            } else {
                registerReceiver(receiver, filter)
            }
            // 系统限流时使用最近结果，并让界面明确标记为缓存。
            if (!wifi.startScan()) {
                finishScan(wifi, true)
            } else {
                val timeout = Runnable { finishScan(wifi, true) }
                scanTimeout = timeout
                handler.postDelayed(timeout, 12000)
            }
        } catch (error: Exception) {
            clearScan()?.error("SCAN_FAILED", "搜索 WiFi 失败，请检查定位权限或手动输入 SSID", null)
        }
    }

    private fun finishScan(wifi: WifiManager, cached: Boolean) {
        if (scanResult == null) return
        try {
            val nowUs = android.os.SystemClock.elapsedRealtimeNanos() / 1000
            val networks = wifi.scanResults
                .filter { it.frequency in 2400..2500 && it.SSID.isNotEmpty() }
                .groupBy { it.SSID }
                .map { (_, items) ->
                    // 同名网络优先选择本设备可用的 PSK 接入点。
                    val supported = items.filter { it.capabilities.contains("PSK") }
                    (supported.ifEmpty { items }).maxByOrNull { it.level }!!
                }
                .sortedByDescending { it.level }
                .map { item -> mapOf(
                    "ssid" to item.SSID,
                    "rssi" to item.level,
                    "supported" to item.capabilities.contains("PSK"),
                    "ageSeconds" to ((nowUs - item.timestamp).coerceAtLeast(0) / 1000000)
                ) }
            clearScan()?.success(mapOf("cached" to cached, "networks" to networks))
        } catch (error: Exception) {
            clearScan()?.error("SCAN_FAILED", "无法读取 WiFi 列表，请检查定位权限或手动输入 SSID", null)
        }
    }

    private fun clearScan(): MethodChannel.Result? {
        scanTimeout?.let { handler.removeCallbacks(it) }
        scanTimeout = null
        scanReceiver?.let { try { unregisterReceiver(it) } catch (_: Exception) {} }
        scanReceiver = null
        val result = scanResult
        scanResult = null
        return result
    }

    override fun onDestroy() {
        clearScan()?.error("CANCELLED", "页面已关闭，请重新搜索", null)
        super.onDestroy()
    }
}
