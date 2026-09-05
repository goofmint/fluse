package dev.fluse.runtime

import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import java.security.SecureRandom

/**
 * 値の置き場。
 *
 * 暗号化できる端末とできない端末で実体を差し替えるために挟む。
 */
internal interface FluseBacking {
    fun getString(key: String): String?

    fun putString(
        key: String,
        value: String?,
    )

    fun getInt(
        key: String,
        fallback: Int,
    ): Int

    fun putInt(
        key: String,
        value: Int,
    )

    fun clear()

    /** ディスクに残るか。残らないなら再起動で消える。 */
    val isPersistent: Boolean
}

/** `EncryptedSharedPreferences` に置く。 */
internal class PreferencesBacking(
    private val preferences: SharedPreferences,
) : FluseBacking {
    override val isPersistent: Boolean = true

    override fun getString(key: String): String? = preferences.getString(key, null)

    override fun putString(
        key: String,
        value: String?,
    ) {
        preferences.edit().apply {
            if (value.isNullOrEmpty()) remove(key) else putString(key, value)
        }.apply()
    }

    override fun getInt(
        key: String,
        fallback: Int,
    ): Int = preferences.getInt(key, fallback)

    override fun putInt(
        key: String,
        value: Int,
    ) {
        preferences.edit().putInt(key, value).apply()
    }

    override fun clear() {
        preferences.edit().clear().apply()
    }
}

/**
 * メモリにだけ置く。**プロセスが終われば消える。**
 *
 * 暗号化できない端末（API 22 以下）で使う。毎回ペアリングが要るように
 * なるが、資格情報を平文で残すよりはよい。
 */
internal class MemoryBacking : FluseBacking {
    override val isPersistent: Boolean = false

    private val values = HashMap<String, Any?>()

    override fun getString(key: String): String? = values[key] as? String

    override fun putString(
        key: String,
        value: String?,
    ) {
        if (value.isNullOrEmpty()) values.remove(key) else values[key] = value
    }

    override fun getInt(
        key: String,
        fallback: Int,
    ): Int = values[key] as? Int ?: fallback

    override fun putInt(
        key: String,
        value: Int,
    ) {
        values[key] = value
    }

    override fun clear() = values.clear()
}

/**
 * 端末側に残す設定（設計 §2.2.5 / §6.1）。
 *
 * **`deviceToken` は永続の資格情報**で、盗まれれば以後のセッションにも
 * 繋がれる。平文の `SharedPreferences` には置かず
 * `EncryptedSharedPreferences` を使う。
 */
class FluseStore internal constructor(
    private val backing: FluseBacking,
) {
    companion object {
        /** 保存先のファイル名。 */
        const val FILE_NAME = "fluse_store"

        /**
         * 暗号化ストアが実際に鍵で守られる最低の API レベル。
         *
         * **API 22 以下では守られない。** `MasterKey` は Android Keystore
         * を使わずに作られ、Tink の `AndroidKeysetManager` は
         * `masterAead` が null のまま `CleartextKeysetHandle.write` で
         * **鍵セットを平文の SharedPreferences に書く**。値だけ暗号化されて
         * いても、その鍵が隣に平置きされていては意味がない。
         */
        const val MIN_ENCRYPTED_SDK = Build.VERSION_CODES.M

        private const val KEY_DEVICE_TOKEN = "deviceToken"
        private const val KEY_LAST_HOST = "lastHost"
        private const val KEY_LAST_PORT = "lastPort"
        private const val KEY_DEVICE_ID = "deviceId"

        /** ポート未設定を表す値。 */
        const val NO_PORT = -1

        /** 代替 deviceId の元にする乱数のバイト数。 */
        private const val FALLBACK_ID_BYTES = 16

        /**
         * 端末のストアを開く。
         *
         * 暗号化できる端末（API 23 以上）ではディスクに残す。それ以外は
         * メモリだけに置き、再起動で消えるようにする。**平文で残すより
         * 毎回ペアリングさせる方がよい。**
         */
        fun open(context: Context): FluseStore {
            if (Build.VERSION.SDK_INT < MIN_ENCRYPTED_SDK) {
                Log.w(
                    FluseRuntimePlugin.TAG,
                    "この端末では設定を暗号化して保存できません（API ${Build.VERSION.SDK_INT}）。" +
                        "起動のたびにペアリングが必要になります",
                )
                return FluseStore(MemoryBacking())
            }

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
            return FluseStore(PreferencesBacking(preferences))
        }

        /** 予測されにくい代替 ID を作る。 */
        internal fun generateFallbackDeviceId(random: SecureRandom = SecureRandom()): String {
            val bytes = ByteArray(FALLBACK_ID_BYTES)
            random.nextBytes(bytes)
            return bytes.joinToString("") { "%02x".format(it) }
                .take(DeviceIdentity.DEVICE_ID_LENGTH)
        }
    }

    /** ディスクに残るか。残らない端末では毎回ペアリングが要る。 */
    val isPersistent: Boolean get() = backing.isPersistent

    /** ペアリング済みなら値が入る。無ければ null。 */
    var deviceToken: String?
        get() = backing.getString(KEY_DEVICE_TOKEN)
        set(value) = backing.putString(KEY_DEVICE_TOKEN, value)

    /** 前回繋がったサーバのホスト。 */
    var lastHost: String?
        get() = backing.getString(KEY_LAST_HOST)
        set(value) = backing.putString(KEY_LAST_HOST, value)

    /** 前回繋がったサーバのポート。未設定は [NO_PORT]。 */
    var lastPort: Int
        get() = backing.getInt(KEY_LAST_PORT, NO_PORT)
        set(value) = backing.putInt(KEY_LAST_PORT, value)

    /**
     * ANDROID_ID が取れない端末のための代替 ID。
     *
     * **端末ごとに違う値でなければならない。** 取れない端末で同じ値に
     * 落とすと、別々の端末がサーバから見て1台に見え、片方の登録が
     * もう片方を上書きする。
     */
    fun fallbackDeviceId(): String {
        val existing = backing.getString(KEY_DEVICE_ID)
        if (!existing.isNullOrEmpty()) {
            return existing
        }
        val generated = generateFallbackDeviceId()
        backing.putString(KEY_DEVICE_ID, generated)
        return generated
    }

    /** ペアリング済みか。 */
    fun hasDeviceToken(): Boolean = !deviceToken.isNullOrEmpty()

    /** 前回の接続先が分かるか。 */
    fun hasLastServer(): Boolean = !lastHost.isNullOrEmpty() && lastPort != NO_PORT

    /** 登録を消す。ペアリングからやり直す時に使う。 */
    fun clear() = backing.clear()

    /** **トークンは含めない。** 例外文やログに混ざると漏れる。 */
    override fun toString(): String =
        "FluseStore(paired=${hasDeviceToken()}, persistent=$isPersistent)"
}
