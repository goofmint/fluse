package dev.fluse.protocol

/** `reject` の理由（設計 §2.2.1 / §5.1）。 */
enum class RejectCode(val wireValue: String) {
    AUTH_FAILED("AUTH_FAILED"),
    PROJECT_MISMATCH("PROJECT_MISMATCH"),
    REVISION_MISMATCH("REVISION_MISMATCH"),
    PROTOCOL_MISMATCH("PROTOCOL_MISMATCH"),
    APP_OUTDATED("APP_OUTDATED"),

    /** Phase1 は1台のみ。2台目は受け付けない（設計 §10-10）。 */
    TOO_MANY_DEVICES("TOO_MANY_DEVICES"),

    ;

    companion object {
        /**
         * 既知の値なら対応する定数、そうでなければ null。
         *
         * **未知の値でも解析は失敗させない。** 新しいサーバが増やしたコードを
         * 古いアプリが受け取ったときに、理由の文言すら表示できなくなるのを避ける。
         */
        fun tryParse(value: String): RejectCode? =
            entries.firstOrNull { it.wireValue == value }
    }
}

/** `close` の理由（設計 §2.2.1）。 */
enum class CloseCode(val wireValue: String) {
    SHUTDOWN("SHUTDOWN"),
    SESSION_REPLACED("SESSION_REPLACED"),
    CLIENT_EXIT("CLIENT_EXIT"),

    ;

    companion object {
        fun tryParse(value: String): CloseCode? =
            entries.firstOrNull { it.wireValue == value }
    }
}

/** `error` の分類（設計 §5.1）。 */
enum class FluseErrorCode(val wireValue: String) {
    SDK_NOT_FOUND("SDK_NOT_FOUND"),
    PROJECT_NOT_FLUTTER("PROJECT_NOT_FLUTTER"),
    NO_DEVICE("NO_DEVICE"),
    INSTALL_SIGNATURE_CONFLICT("INSTALL_SIGNATURE_CONFLICT"),
    PROTOCOL_MISMATCH("PROTOCOL_MISMATCH"),
    PROJECT_MISMATCH("PROJECT_MISMATCH"),
    REVISION_MISMATCH("REVISION_MISMATCH"),
    APP_OUTDATED("APP_OUTDATED"),
    COMPILE_ERROR("COMPILE_ERROR"),
    RELOAD_REJECTED("RELOAD_REJECTED"),
    TUNNEL_LOST("TUNNEL_LOST"),
    AUTH_FAILED("AUTH_FAILED"),

    ;

    companion object {
        fun tryParse(value: String): FluseErrorCode? =
            entries.firstOrNull { it.wireValue == value }
    }
}

/** `log` の深刻度（設計 §2.2.1）。 */
enum class LogLevel(val wireValue: String) {
    DEBUG("debug"),
    INFO("info"),
    WARN("warn"),
    ERROR("error"),

    ;

    companion object {
        fun tryParse(value: String): LogLevel? =
            entries.firstOrNull { it.wireValue == value }
    }
}

/** 診断の深刻度。 */
enum class DiagnosticSeverity(val wireValue: String) {
    ERROR("error"),
    WARNING("warning"),
    INFO("info"),
    CONTEXT("context"),

    ;

    companion object {
        fun tryParse(value: String): DiagnosticSeverity? =
            entries.firstOrNull { it.wireValue == value }
    }
}
