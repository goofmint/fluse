package dev.fluse.protocol

import org.json.JSONArray
import org.json.JSONObject

/**
 * サーバとランタイムが交わす制御メッセージ（設計 §2.2.1）。
 *
 * **Dart 側の `FluseMessage` と同じワイヤ表現でなければならない。**
 * 検証は `packages/fluse_protocol/test/fixtures/wire_golden.json` を
 * 両実装が読むことで担保する。ここを変えたら Dart 側も必ず追従させること。
 */
sealed class FluseMessage {
    /** JSON の `type` フィールドに載る値。 */
    abstract val type: String

    abstract fun toJson(): JSONObject

    companion object {
        /**
         * `type` を見て対応するメッセージに振り分ける。
         *
         * 未知の `type` は明示的に失敗させる。黙って無視すると、
         * 送った側は届いたと思い込んだまま応答を待ち続ける。
         */
        fun fromJson(json: JSONObject): FluseMessage {
            if (!json.has("type") || json.isNull("type")) {
                throw FluseProtocolException("メッセージに type がありません")
            }
            val rawType = json.get("type")
            if (rawType !is String) {
                throw FluseProtocolException.wrongType("FluseMessage", "type", "文字列", rawType)
            }

            return when (rawType) {
                HelloMessage.TYPE -> HelloMessage.fromJson(json)
                VmServiceReadyMessage.TYPE -> VmServiceReadyMessage.fromJson(json)
                ReadyMessage.TYPE -> ReadyMessage()
                LogMessage.TYPE -> LogMessage.fromJson(json)
                ErrorMessage.TYPE -> ErrorMessage.fromJson(json)
                AcceptMessage.TYPE -> AcceptMessage.fromJson(json)
                RejectMessage.TYPE -> RejectMessage.fromJson(json)
                ReloadMessage.TYPE -> ReloadMessage()
                CompileErrorMessage.TYPE -> CompileErrorMessage.fromJson(json)
                CompileOkMessage.TYPE -> CompileOkMessage()
                PingMessage.TYPE -> PingMessage.fromJson(json)
                PongMessage.TYPE -> PongMessage.fromJson(json)
                CloseMessage.TYPE -> CloseMessage.fromJson(json)
                else -> throw FluseProtocolException("未知の type: $rawType")
            }
        }
    }
}

// --------------------------------------------------------- Client -> Server

/** 接続時の名乗り（type: `hello`）。 */
class HelloMessage(
    val protocolVersion: Long,
    val projectId: String,
    val flutterRevision: String,
    val dartVersion: String,
    val appVersion: String,
    val deviceId: String,
    val deviceName: String,
    val pairingToken: String? = null,
    val deviceToken: String? = null,
) : FluseMessage() {
    companion object {
        const val TYPE = "hello"

        fun fromJson(json: JSONObject): HelloMessage {
            val r = JsonReader(json)
            return HelloMessage(
                protocolVersion = r.requireInt(TYPE, "protocolVersion"),
                projectId = r.requireString(TYPE, "projectId"),
                flutterRevision = r.requireString(TYPE, "flutterRevision"),
                dartVersion = r.requireString(TYPE, "dartVersion"),
                appVersion = r.requireString(TYPE, "appVersion"),
                deviceId = r.requireString(TYPE, "deviceId"),
                deviceName = r.requireString(TYPE, "deviceName"),
                pairingToken = r.optionalString(TYPE, "pairingToken"),
                deviceToken = r.optionalString(TYPE, "deviceToken"),
            )
        }
    }

    override val type: String get() = TYPE

    override fun toJson(): JSONObject {
        val json = JSONObject()
        json.put("type", type)
        json.put("protocolVersion", protocolVersion)
        json.put("projectId", projectId)
        json.put("flutterRevision", flutterRevision)
        json.put("dartVersion", dartVersion)
        json.put("appVersion", appVersion)
        json.put("deviceId", deviceId)
        json.put("deviceName", deviceName)
        pairingToken?.let { json.put("pairingToken", it) }
        deviceToken?.let { json.put("deviceToken", it) }
        return json
    }

    /** **トークンは含めない。** ログや例外文に混ざると漏れる。 */
    override fun toString(): String =
        "HelloMessage(v$protocolVersion, project: $projectId, device: $deviceName)"
}

/** VM Service が立ち上がったことの通知（type: `vmServiceReady`）。 */
class VmServiceReadyMessage(val vmServiceUri: String) : FluseMessage() {
    companion object {
        const val TYPE = "vmServiceReady"

        fun fromJson(json: JSONObject): VmServiceReadyMessage =
            VmServiceReadyMessage(JsonReader(json).requireString(TYPE, "vmServiceUri"))
    }

    override val type: String get() = TYPE

    override fun toJson(): JSONObject =
        JSONObject().put("type", type).put("vmServiceUri", vmServiceUri)

    /** URI は載せない。パスセグメントが認証コードそのものであるため。 */
    override fun toString(): String = "VmServiceReadyMessage(...)"
}

/** 準備完了（type: `ready`）。 */
class ReadyMessage : FluseMessage() {
    companion object {
        const val TYPE = "ready"
    }

    override val type: String get() = TYPE

    override fun toJson(): JSONObject = JSONObject().put("type", type)

    override fun toString(): String = "ReadyMessage()"
}

/** 端末からのログ（type: `log`）。 */
class LogMessage(val level: String, val message: String) : FluseMessage() {
    companion object {
        const val TYPE = "log"

        fun fromJson(json: JSONObject): LogMessage {
            val r = JsonReader(json)
            return LogMessage(
                level = r.requireString(TYPE, "level"),
                message = r.requireString(TYPE, "message"),
            )
        }
    }

    /** 既知の値なら対応する定数、そうでなければ null。 */
    val knownLevel: LogLevel? get() = LogLevel.tryParse(level)

    override val type: String get() = TYPE

    override fun toJson(): JSONObject =
        JSONObject().put("type", type).put("level", level).put("message", message)

    override fun toString(): String = "LogMessage($level)"
}

/** 端末からのエラー通知（type: `error`）。 */
class ErrorMessage(
    val code: String,
    val message: String,
    val detail: String? = null,
) : FluseMessage() {
    companion object {
        const val TYPE = "error"

        fun fromJson(json: JSONObject): ErrorMessage {
            val r = JsonReader(json)
            return ErrorMessage(
                code = r.requireString(TYPE, "code"),
                message = r.requireString(TYPE, "message"),
                detail = r.optionalString(TYPE, "detail"),
            )
        }
    }

    val knownCode: FluseErrorCode? get() = FluseErrorCode.tryParse(code)

    override val type: String get() = TYPE

    override fun toJson(): JSONObject {
        val json = JSONObject().put("type", type).put("code", code).put("message", message)
        detail?.let { json.put("detail", it) }
        return json
    }

    override fun toString(): String = "ErrorMessage($code)"
}

// --------------------------------------------------------- Server -> Client

/** 接続を受理した（type: `accept`）。 */
class AcceptMessage(
    val sessionId: String,
    val heartbeatIntervalMs: Long,
    val issuedDeviceToken: String? = null,
) : FluseMessage() {
    companion object {
        const val TYPE = "accept"

        fun fromJson(json: JSONObject): AcceptMessage {
            val r = JsonReader(json)
            return AcceptMessage(
                sessionId = r.requireString(TYPE, "sessionId"),
                heartbeatIntervalMs = r.requireInt(TYPE, "heartbeatIntervalMs"),
                issuedDeviceToken = r.optionalString(TYPE, "issuedDeviceToken"),
            )
        }
    }

    override val type: String get() = TYPE

    override fun toJson(): JSONObject {
        val json = JSONObject()
            .put("type", type)
            .put("sessionId", sessionId)
            .put("heartbeatIntervalMs", heartbeatIntervalMs)
        issuedDeviceToken?.let { json.put("issuedDeviceToken", it) }
        return json
    }

    /** 発行トークンは載せない。 */
    override fun toString(): String = "AcceptMessage($sessionId)"
}

/** 接続を拒否した（type: `reject`）。 */
class RejectMessage(val code: String, val message: String) : FluseMessage() {
    companion object {
        const val TYPE = "reject"

        fun of(code: RejectCode, message: String): RejectMessage =
            RejectMessage(code.wireValue, message)

        fun fromJson(json: JSONObject): RejectMessage {
            val r = JsonReader(json)
            return RejectMessage(
                code = r.requireString(TYPE, "code"),
                message = r.requireString(TYPE, "message"),
            )
        }
    }

    val knownCode: RejectCode? get() = RejectCode.tryParse(code)

    override val type: String get() = TYPE

    override fun toJson(): JSONObject =
        JSONObject().put("type", type).put("code", code).put("message", message)

    override fun toString(): String = "RejectMessage($code)"
}

/** リロードの進捗通知（type: `reload`）。 */
class ReloadMessage : FluseMessage() {
    companion object {
        const val TYPE = "reload"
    }

    override val type: String get() = TYPE

    override fun toJson(): JSONObject = JSONObject().put("type", type)

    override fun toString(): String = "ReloadMessage()"
}

/** コンパイルエラー（type: `compileError`）。 */
class CompileErrorMessage(
    val summary: String,
    val diagnostics: List<DiagnosticEntry>,
) : FluseMessage() {
    companion object {
        const val TYPE = "compileError"

        fun fromJson(json: JSONObject): CompileErrorMessage {
            val r = JsonReader(json)
            val array = r.requireArray(TYPE, "diagnostics")
            val entries = ArrayList<DiagnosticEntry>(array.length())
            for (i in 0 until array.length()) {
                val element = array.get(i)
                if (element !is JSONObject) {
                    throw FluseProtocolException.wrongType(
                        TYPE, "diagnostics", "オブジェクト", element,
                    )
                }
                entries.add(DiagnosticEntry.fromJson(element))
            }
            return CompileErrorMessage(r.requireString(TYPE, "summary"), entries)
        }
    }

    override val type: String get() = TYPE

    override fun toJson(): JSONObject {
        val array = JSONArray()
        diagnostics.forEach { array.put(it.toJson()) }
        return JSONObject().put("type", type).put("summary", summary).put("diagnostics", array)
    }

    override fun toString(): String = "CompileErrorMessage(${diagnostics.size}件)"
}

/** コンパイルが通った（type: `compileOk`）。オーバーレイの解除に使う。 */
class CompileOkMessage : FluseMessage() {
    companion object {
        const val TYPE = "compileOk"
    }

    override val type: String get() = TYPE

    override fun toJson(): JSONObject = JSONObject().put("type", type)

    override fun toString(): String = "CompileOkMessage()"
}

// -------------------------------------------------------------------- 双方向

/** 疎通確認（type: `ping`）。 */
class PingMessage(val seq: Long, val timestampMs: Long) : FluseMessage() {
    companion object {
        const val TYPE = "ping"

        fun fromJson(json: JSONObject): PingMessage {
            val r = JsonReader(json)
            return PingMessage(r.requireInt(TYPE, "seq"), r.requireInt(TYPE, "timestampMs"))
        }
    }

    override val type: String get() = TYPE

    override fun toJson(): JSONObject =
        JSONObject().put("type", type).put("seq", seq).put("timestampMs", timestampMs)

    /**
     * この ping に対応する pong を作る。
     *
     * **受け取った値をそのまま返す。** 受信側で時刻を作り直すと RTT が測れない。
     */
    fun toPong(): PongMessage = PongMessage(seq, timestampMs)

    override fun toString(): String = "PingMessage($seq)"
}

/** 疎通確認への応答（type: `pong`）。 */
class PongMessage(val seq: Long, val timestampMs: Long) : FluseMessage() {
    companion object {
        const val TYPE = "pong"

        fun fromJson(json: JSONObject): PongMessage {
            val r = JsonReader(json)
            return PongMessage(r.requireInt(TYPE, "seq"), r.requireInt(TYPE, "timestampMs"))
        }
    }

    override val type: String get() = TYPE

    override fun toJson(): JSONObject =
        JSONObject().put("type", type).put("seq", seq).put("timestampMs", timestampMs)

    override fun toString(): String = "PongMessage($seq)"
}

/**
 * 正常終了の通知（type: `close`）。
 *
 * 異常終了は WebSocket の close フレームに委ねる。
 */
class CloseMessage(val code: String, val message: String? = null) : FluseMessage() {
    companion object {
        const val TYPE = "close"

        fun of(code: CloseCode, message: String? = null): CloseMessage =
            CloseMessage(code.wireValue, message)

        fun fromJson(json: JSONObject): CloseMessage {
            val r = JsonReader(json)
            return CloseMessage(
                code = r.requireString(TYPE, "code"),
                message = r.optionalString(TYPE, "message"),
            )
        }
    }

    val knownCode: CloseCode? get() = CloseCode.tryParse(code)

    override val type: String get() = TYPE

    override fun toJson(): JSONObject {
        val json = JSONObject().put("type", type).put("code", code)
        message?.let { json.put("message", it) }
        return json
    }

    override fun toString(): String = "CloseMessage($code)"
}
