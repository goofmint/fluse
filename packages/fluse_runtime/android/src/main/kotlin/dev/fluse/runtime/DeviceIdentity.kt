package dev.fluse.runtime

import android.content.Context
import android.os.Build
import android.provider.Settings
import java.security.MessageDigest

/**
 * 端末を見分けるための値（設計 §2.2.1 の `hello`）。
 *
 * Android のランタイムに触る部分と、触らない計算とを分けてある。
 * 計算側だけなら JVM の単体テストで確かめられる。
 */
object DeviceIdentity {
    /** `deviceId` の文字数。sha256 の先頭を16進で取る。 */
    const val DEVICE_ID_LENGTH = 16

    /**
     * ANDROID_ID をそのままは使わない。
     *
     * ANDROID_ID は端末とアプリ署名の組で決まる識別子で、他のアプリとの
     * 突き合わせに使える。サーバへ送る必要があるのは「同じ端末かどうか」
     * だけなので、ハッシュにして元の値を渡さない。
     */
    fun hashAndroidId(androidId: String): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(androidId.toByteArray())
        return digest.joinToString("") { byte -> "%02x".format(byte) }
            .take(DEVICE_ID_LENGTH)
    }

    /**
     * 表示用の端末名。
     *
     * `Build.MODEL` だけだと "SM-G991B" のような型番になり、利用者が
     * 自分の端末か判断しにくい。メーカー名を前に付ける。
     */
    fun deviceName(
        manufacturer: String,
        model: String,
    ): String {
        val trimmedManufacturer = manufacturer.trim()
        val trimmedModel = model.trim()
        return when {
            trimmedManufacturer.isEmpty() -> trimmedModel
            trimmedModel.isEmpty() -> trimmedManufacturer
            // Pixel のように model がメーカー名で始まる場合は重ねない。
            trimmedModel.startsWith(trimmedManufacturer, ignoreCase = true) -> trimmedModel
            else -> "$trimmedManufacturer $trimmedModel"
        }
    }

    /** この端末の `deviceId`。 */
    @Suppress("HardwareIds")
    fun deviceId(context: Context): String {
        val androidId =
            Settings.Secure.getString(
                context.contentResolver,
                Settings.Secure.ANDROID_ID,
            ).orEmpty()
        return hashAndroidId(androidId)
    }

    /** この端末の表示名。 */
    fun deviceName(): String = deviceName(Build.MANUFACTURER, Build.MODEL)
}
