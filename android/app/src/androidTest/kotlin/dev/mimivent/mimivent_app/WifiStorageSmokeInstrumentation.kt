package dev.mimivent.mimivent_app

import android.app.Activity
import android.app.Instrumentation
import android.os.Bundle
import android.util.AtomicFile
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.KeyStore
import java.util.UUID

/** 独立测试别名/文件；不接触用户的真实绑定、网络或统计。无需解锁手机 UI。 */
class WifiStorageSmokeInstrumentation : Instrumentation() {
    override fun onCreate(arguments: Bundle?) { super.onCreate(arguments); start() }
    class Result : MethodChannel.Result {
        var value: Any? = null
        var error: String? = null
        override fun success(result: Any?) { value = result }
        override fun error(code: String, message: String?, details: Any?) { error = code }
        override fun notImplemented() { error = "NOT_IMPLEMENTED" }
    }
    override fun onStart() {
        val id = UUID.randomUUID().toString()
        val name = "wifi-bindings-smoke-$id.enc"
        val alias = "mimivent.wifi.smoke.$id"
        val file = AtomicFile(File(targetContext.noBackupFilesDir, name))
        val keys = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        var stage = "empty-read"
        try {
            // 保持 Activity 使用的单参数 JVM 构造签名，防止增量构建后的 ABI 不匹配。
            WifiCredentialStorage::class.java.getConstructor(android.content.Context::class.java)
            val store = WifiCredentialStorage(targetContext, name, alias)
            var result = Result(); store.handle("read", null, result)
            check(result.error == null && result.value == "[]" && !keys.containsAlias(alias))
            val text = "[{\"test\":\"private-test-value-not-a-real-credential\"}]"
            stage = "encrypt"
            result = Result(); store.handle("write", text, result); check(result.error == null)
            val first = file.readFully()
            check(!String(first, Charsets.UTF_8).contains(text))
            stage = "fresh-instance-decrypt"
            result = Result(); WifiCredentialStorage(targetContext, name, alias).handle("read", null, result)
            check(result.error == null && result.value == text)
            stage = "unique-iv"
            result = Result(); store.handle("write", text, result); check(result.error == null)
            val valid = file.readFully(); check(!first.contentEquals(valid))
            stage = "backup-recovery"
            File(file.baseFile.path + ".bak").writeBytes(valid); check(file.baseFile.delete())
            result = Result(); store.handle("read", null, result)
            check(result.error == null && result.value == text)
            stage = "tamper-preserved"
            val damaged = valid.copyOf(); damaged[damaged.lastIndex] = (damaged.last().toInt() xor 1).toByte()
            file.baseFile.writeBytes(damaged)
            result = Result(); store.handle("read", null, result)
            check(result.error == "SECURE_STORAGE_UNAVAILABLE" && file.baseFile.readBytes().contentEquals(damaged))
            stage = "reset-confirmation"
            result = Result(); store.handle("clear", null, result)
            check(result.error == "CONFIRMATION_REQUIRED" && file.baseFile.exists() && keys.containsAlias(alias))
            stage = "confirmed-reset"
            result = Result(); store.handle("clear", "REMOVE_LOCAL_WIFI_BINDINGS", result)
            check(result.error == null && !file.baseFile.exists() && !keys.containsAlias(alias))
            result = Result(); store.handle("read", null, result)
            check(result.error == null && result.value == "[]")
            finish(Activity.RESULT_OK, Bundle().apply { putString("stream", "WiFi Keystore: 8 checks passed\n") })
        } catch (_: Throwable) {
            finish(Activity.RESULT_CANCELED, Bundle().apply { putString("stream", "WiFi Keystore failed at $stage\n") })
        } finally {
            file.delete()
            if (keys.containsAlias(alias)) keys.deleteEntry(alias)
        }
    }
}
