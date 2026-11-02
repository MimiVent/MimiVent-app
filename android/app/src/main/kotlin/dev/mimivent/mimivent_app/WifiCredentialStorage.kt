package dev.mimivent.mimivent_app

import android.content.Context
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** 凭据仅存为 Keystore 加密密文，且放在系统不备份目录。 */
class WifiCredentialStorage @JvmOverloads constructor(context: Context,
    fileName: String = "wifi-bindings-v1.enc",
    private val alias: String = "mimivent.wifi.bindings.v1") {
    private val file = AtomicFile(File(context.noBackupFilesDir, fileName))
    fun handle(method: String, value: String?, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < 23) {
            result.error("SECURE_STORAGE_UNSUPPORTED", "WiFi 安全绑定需要 Android 6.0 或以上，蓝牙控制不受影响", null)
            return
        }
        try {
            val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            when (method) {
                "read" -> {
                    val backup = File(file.baseFile.path + ".bak")
                    if (!file.baseFile.exists() && !backup.exists()) { result.success("[]"); return }
                    require((if (backup.exists()) backup else file.baseFile).length() in 28..65536)
                    val key = store.getKey(alias, null) as? SecretKey ?: error("key unavailable")
                    val bytes = file.readFully()
                    val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                    cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
                    result.success(String(cipher.doFinal(bytes.copyOfRange(12, bytes.size)), Charsets.UTF_8))
                }
                "write" -> {
                    require(value != null && value.toByteArray(Charsets.UTF_8).size <= 32768)
                    val key = (store.getKey(alias, null) as? SecretKey) ?: KeyGenerator.getInstance("AES", "AndroidKeyStore").apply {
                        init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                            .setKeySize(256).build())
                    }.generateKey()
                    val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                    cipher.init(Cipher.ENCRYPT_MODE, key)
                    require(cipher.iv.size == 12)
                    val bytes = cipher.iv + cipher.doFinal(value.toByteArray(Charsets.UTF_8))
                    val stream = file.startWrite()
                    try { stream.write(bytes); file.finishWrite(stream) }
                    catch (error: Exception) { file.failWrite(stream); throw error }
                    result.success(null)
                }
                "clear" -> {
                    if (value != "REMOVE_LOCAL_WIFI_BINDINGS") {
                        result.error("CONFIRMATION_REQUIRED", "请先确认移除全部本机 WiFi 记录", null)
                        return
                    }
                    file.delete()
                    if (store.containsAlias(alias)) store.deleteEntry(alias)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (_: Exception) {
            // 不将凭据、密文或底层异常直接写入日志/界面。
            result.error("SECURE_STORAGE_UNAVAILABLE", "安全凭据存储暂不可用，请重试或检查系统 Keystore", null)
        }
    }
}
