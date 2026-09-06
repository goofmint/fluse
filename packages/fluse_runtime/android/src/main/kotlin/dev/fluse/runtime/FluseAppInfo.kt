package dev.fluse.runtime

import android.content.Context
import org.json.JSONObject

/**
 * Preview App に焼き込まれた素性（設計 §2.2.1 の `hello`）。
 *
 * **端末側では決められない。** `projectId` はプロジェクトの絶対パスから、
 * `appVersion` はビルド時の指紋から作られる（設計 §4.2(a) / §2.2.2）。
 * どちらもビルドした側だけが知っている値なので、APK の assets に置いて
 * 持ち込む。生成は Task 5.3 / 5.5 の担当。
 */
data class FluseAppInfo(
    val projectId: String,
    val flutterRevision: String,
    val dartVersion: String,
    val appVersion: String,
) {
    companion object {
        /** ビルド時に書き込まれる場所。生成側と揃えること。 */
        const val ASSET_PATH = "fluse/app_info.json"

        /**
         * assets から読む。
         *
         * **無ければ落とす。** 既定値で埋めると、別プロジェクトのサーバに
         * 繋がったり、古い APK が新しいサーバに受理されたりする。どちらも
         * 「なぜか動かない」形で表面化して切り分けが難しい。
         */
        fun load(context: Context): FluseAppInfo {
            val text = context.assets.open(ASSET_PATH).use { it.readBytes().toString(Charsets.UTF_8) }
            return parse(text)
        }

        /** JSON から組み立てる。ランタイムに触らないので単体で確かめられる。 */
        fun parse(text: String): FluseAppInfo {
            val json = JSONObject(text)
            return FluseAppInfo(
                projectId = require(json, "projectId"),
                flutterRevision = require(json, "flutterRevision"),
                dartVersion = require(json, "dartVersion"),
                appVersion = require(json, "appVersion"),
            )
        }

        private fun require(
            json: JSONObject,
            key: String,
        ): String {
            val value = json.optString(key)
            if (value.isEmpty()) {
                throw IllegalArgumentException("$ASSET_PATH に $key がありません")
            }
            return value
        }
    }
}

/** この端末の名乗り。 */
data class FluseDeviceInfo(
    val deviceId: String,
    val deviceName: String,
) {
    companion object {
        fun of(
            context: Context,
            store: FluseStore,
        ): FluseDeviceInfo =
            FluseDeviceInfo(
                deviceId = DeviceIdentity.deviceId(context, store),
                deviceName = DeviceIdentity.deviceName(),
            )
    }
}

/** 繋ぎ先。 */
data class FluseEndpoint(
    val host: String,
    val port: Int,
) {
    /** WebSocket の URL（設計 §4.2(b) の `/ws`）。 */
    fun webSocketUrl(): String = "ws://$host:$port/ws"
}
