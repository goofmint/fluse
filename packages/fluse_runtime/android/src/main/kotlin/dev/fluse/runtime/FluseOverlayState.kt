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

    /** 画面に残すパスの深さ。 */
    const val PATH_SEGMENTS = 3

    /** 端を落としたことを示す印。 */
    const val ELLIPSIS = "…/"

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
        val place = placeOf(entry) ?: NO_LOCATION
        return "${markOf(entry.severity)} $place: ${entry.message}"
    }

    /** `file:line:col`。ファイルは短くしてから組み立てる。 */
    fun placeOf(entry: DiagnosticEntry): String? {
        val file = entry.file ?: return null
        val shortened = shorten(file)
        val line = entry.line ?: return shortened
        val col = entry.col ?: return "$shortened:$line"
        return "$shortened:$line:$col"
    }

    /**
     * 画面に出すパスを短くする。
     *
     * `frontend_server` はホスト側の絶対パスをそのまま返す
     * （`/Users/<名前>/work/app/lib/main.dart`）。**そのまま出さない。**
     * 端末の画面に開発者の名前や置き場所まで映るうえ、狭い画面では肝心の
     * ファイル名が押し出される。
     *
     * どこを直すかが分かればよいので、末尾の [PATH_SEGMENTS] 段だけ残す。
     */
    fun shorten(file: String): String {
        val path = file.substringAfter("file://")
        val segments = path.split('/').filter { it.isNotEmpty() }
        if (segments.size <= PATH_SEGMENTS) {
            return segments.joinToString("/")
        }
        return ELLIPSIS + segments.takeLast(PATH_SEGMENTS).joinToString("/")
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
