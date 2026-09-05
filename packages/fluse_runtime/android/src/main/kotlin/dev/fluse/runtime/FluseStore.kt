package dev.fluse.runtime

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

/**
 * 端末側に残す設定（設計 §2.2.5 / §6.1）。
 *
 * **`deviceToken` は永続の資格情報**で、盗まれれば以後のセッションにも
 * 繋がれる。平文の SharedPreferences には置かず、
 * `EncryptedSharedPreferences` を使う。
 *
 * ここに置くのは3つだけ。
 * - `deviceToken`: 2回目以降の接続に使う。QR の再スキャンを不要にする。
 * - `lastHost` / `lastPort`: 前回繋がったサーバ。まずここへ試す。
 */
class FluseStore internal constructor(
    private val preferences: SharedPreferences,
) {
    companion object {
        /** 保存先のファイル名。 */
        const val FILE_NAME = "fluse_store"

        private const val KEY_DEVICE_TOKEN = "deviceToken"
        private const val KEY_LAST_HOST = "lastHost"
        private const val KEY_LAST_PORT = "lastPort"

        /** ポート未設定を表す値。 */
        const val NO_PORT = -1

        /**
         * 端末の暗号化ストアを開く。
         *
         * 鍵は Android Keystore に置かれ、アプリの外からは取り出せない。
         */
        fun open(context: Context): FluseStore {
            val masterKey =
                MasterKey.Builder(context)
                    .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                    .build()
            val preferences =
                EncryptedSharedPreferences.create(
                    context,
                    FILE_NAME,
                    masterKey,
                    EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                    EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
                )
            return FluseStore(preferences)
        }
    }

    /** ペアリング済みなら値が入る。無ければ null。 */
    var deviceToken: String?
        get() = preferences.getString(KEY_DEVICE_TOKEN, null)
        set(value) {
            preferences.edit().apply {
                if (value.isNullOrEmpty()) {
                    remove(KEY_DEVICE_TOKEN)
                } else {
                    putString(KEY_DEVICE_TOKEN, value)
                }
            }.apply()
        }

    /** 前回繋がったサーバのホスト。 */
    var lastHost: String?
        get() = preferences.getString(KEY_LAST_HOST, null)
        set(value) {
            preferences.edit().apply {
                if (value.isNullOrEmpty()) remove(KEY_LAST_HOST) else putString(KEY_LAST_HOST, value)
            }.apply()
        }

    /** 前回繋がったサーバのポート。未設定は [NO_PORT]。 */
    var lastPort: Int
        get() = preferences.getInt(KEY_LAST_PORT, NO_PORT)
        set(value) {
            preferences.edit().putInt(KEY_LAST_PORT, value).apply()
        }

    /** ペアリング済みか。 */
    fun hasDeviceToken(): Boolean = !deviceToken.isNullOrEmpty()

    /** 前回の接続先が分かるか。 */
    fun hasLastServer(): Boolean = !lastHost.isNullOrEmpty() && lastPort != NO_PORT

    /** 登録を消す。ペアリングからやり直す時に使う。 */
    fun clear() {
        preferences.edit().clear().apply()
    }

    /** **トークンは含めない。** 例外文やログに混ざると漏れる。 */
    override fun toString(): String = "FluseStore(paired=${hasDeviceToken()})"
}
