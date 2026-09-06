package dev.fluse.runtime

import dev.fluse.protocol.CompileErrorMessage
import dev.fluse.protocol.CompileOkMessage
import dev.fluse.protocol.DiagnosticEntry
import dev.fluse.protocol.DiagnosticSeverity
import dev.fluse.protocol.FluseMessage

/** 赤画面に出す中身。 */
data class FluseOverlayContent(
    val summary: String,
    val lines: List<String>,
)

/** 受け取ったメッセージから決まる、赤画面への指示。 */
sealed class FluseOverlayCommand {
    data class Show(val content: FluseOverlayContent) : FluseOverlayCommand()

    /** 直ったので消す。 */
    object Hide : FluseOverlayCommand()

    /** この画面には関係の無いメッセージ。 */
    object Ignore : FluseOverlayCommand()
}

/**
 * 何を出すかを決める（設計 §5.2）。
 *
 * Android のランタイムに触らない。**View と分けておく。** 赤画面は
 * 「Dart が起動しない時に出るもの」で、動かして確かめるのが最も難しい
 * 部類に入る。判断だけでも単体で確かめられるようにしておく。
 */
object FluseOverlayState {
    /** 診断が無い時に出す文言の代わり。 */
    const val NO_LOCATION = "場所不明"

    fun of(message: FluseMessage): FluseOverlayCommand =
        when (message) {
            is CompileErrorMessage ->
                FluseOverlayCommand.Show(
                    FluseOverlayContent(
                        summary = message.summary,
                        lines = message.diagnostics.map(::lineOf),
                    ),
                )

            is CompileOkMessage -> FluseOverlayCommand.Hide
            else -> FluseOverlayCommand.Ignore
        }

    /**
     * 1件を1行にする。
     *
     * `file:line:col` を頭に置く（設計 §5.2）。どこを直せばよいかが
     * 分からないと、赤画面はただ視界を塞ぐだけになる。
     */
    fun lineOf(entry: DiagnosticEntry): String {
        val place = entry.location ?: NO_LOCATION
        return "${markOf(entry.severity)} $place: ${entry.message}"
    }

    /** 深刻度の目印。色を分けると赤画面の上で見分けが付かない。 */
    fun markOf(severity: DiagnosticSeverity): String =
        when (severity) {
            DiagnosticSeverity.ERROR -> "✗"
            DiagnosticSeverity.WARNING -> "△"
            DiagnosticSeverity.INFO -> "・"
            DiagnosticSeverity.CONTEXT -> " "
        }
}

/** バッジに出す接続の様子。 */
enum class FluseBadgeState {
    /** 繋ぎに行っている最中。 */
    CONNECTING,

    CONNECTED,

    /** 切れた。[FluseConnection] が繋ぎ直している。 */
    DISCONNECTED,

    /** QR の読み直しが要る。 */
    NEEDS_PAIRING,

    /** 断られた。繋ぎ直しでは解けない。 */
    REJECTED,
}
