package dev.fluse.runtime

import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/**
 * 端末側ランタイムの入口（設計 §2.2.5）。
 *
 * 今は Dart 側から VM Service の URI を受け取るだけ。WebSocket 接続・
 * トンネル・エラーオーバーレイは Task 4.2 以降で足す。
 */
class FluseRuntimePlugin :
    FlutterPlugin,
    MethodCallHandler {
    companion object {
        /** Dart 側と揃える。片方だけ変えると通知が届かなくなる。 */
        const val CHANNEL_NAME = "dev.fluse/runtime"

        /** VM Service が立ち上がったことの通知。 */
        const val METHOD_VM_SERVICE_READY = "vmServiceReady"

        /** logcat のタグ。 */
        const val TAG = "fluse"

        /**
         * マスク後に残す先頭の文字数。
         *
         * Dart 側の `maskToken` と揃える（設計 §6.1）。
         */
        private const val MASK_PREFIX_LENGTH = 4

        /**
         * 認証コードとみなす最短の長さ。
         *
         * `/health` のような普通のパスを巻き込まないための足切り。
         * Dart 側の `_maskUriAuthCode` と同じ値。
         */
        private const val MIN_AUTH_CODE_LENGTH = 8

        /**
         * VM Service の URI から認証コードを伏せる。
         *
         * **logcat は Dart 側の redact を通らない。** VM Service の URI は
         * `http://127.0.0.1:<port>/<authCode>/` の形で、**パスセグメント
         * そのものが認証情報**になっている。これを掴んだ相手は DevFS への
         * 書き込みも reloadSources の実行もできる。端末のログは adb で
         * 誰でも読めるため、ここで必ず伏せる。
         */
        fun maskAuthCode(uri: String): String {
            val schemeEnd = uri.indexOf("://")
            if (schemeEnd < 0) {
                return uri
            }
            val pathStart = uri.indexOf('/', schemeEnd + 3)
            if (pathStart < 0) {
                // パスが無い。認証コードも無い。
                return uri
            }

            val prefix = uri.substring(0, pathStart)
            val path = uri.substring(pathStart)
            val segments = path.split('/')

            var replaced = false
            val masked =
                segments.map { segment ->
                    if (!replaced && segment.length >= MIN_AUTH_CODE_LENGTH) {
                        replaced = true
                        mask(segment)
                    } else {
                        segment
                    }
                }
            return prefix + masked.joinToString("/")
        }

        private fun mask(value: String): String =
            if (value.length < MASK_PREFIX_LENGTH + 1) {
                "***"
            } else {
                value.take(MASK_PREFIX_LENGTH) + "***"
            }
    }

    private var channel: MethodChannel? = null

    /** 受け取った VM Service の URI。Task 4.3 の接続処理が使う。 */
    @Volatile
    var vmServiceUri: String? = null
        private set

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val created = MethodChannel(binding.binaryMessenger, CHANNEL_NAME)
        created.setMethodCallHandler(this)
        channel = created
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    override fun onMethodCall(
        call: MethodCall,
        result: Result,
    ) {
        when (call.method) {
            METHOD_VM_SERVICE_READY -> handleVmServiceReady(call, result)
            else -> result.notImplemented()
        }
    }

    private fun handleVmServiceReady(
        call: MethodCall,
        result: Result,
    ) {
        val uri = call.arguments as? String
        if (uri.isNullOrEmpty()) {
            // 引数が無いのは Dart 側の実装誤り。黙って成功にすると
            // 「繋がらない理由が分からない」状態になる。
            result.error("INVALID_ARGUMENT", "vmServiceUri が文字列ではありません", null)
            return
        }

        // **Hot Restart のたびに同じ URI が再送される。** Dart 側の
        // main() が作り直されるため。上書きで冪等に受ける。
        vmServiceUri = uri
        Log.i(TAG, "VM Service を受け取りました: ${maskAuthCode(uri)}")
        result.success(null)
    }
}
