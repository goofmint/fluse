package dev.fluse.runtime

import dev.fluse.protocol.CompileErrorMessage
import dev.fluse.protocol.CompileOkMessage
import dev.fluse.protocol.DiagnosticEntry
import dev.fluse.protocol.DiagnosticSeverity
import dev.fluse.protocol.ReadyMessage
import dev.fluse.protocol.ReloadMessage
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue

internal class FluseOverlayStateTest {
    private fun entry(
        severity: DiagnosticSeverity = DiagnosticSeverity.ERROR,
        message: String = "型が合いません",
        file: String? = "lib/main.dart",
        line: Long? = 42,
        col: Long? = 7,
    ) = DiagnosticEntry(severity, message, file, line, col)

    private fun shown(vararg entries: DiagnosticEntry): FluseOverlayContent {
        val command = FluseOverlayState.of(CompileErrorMessage("1件のエラー", entries.toList()))
        assertIs<FluseOverlayCommand.Show>(command)
        return command.content
    }

    @Test
    fun `compileError で赤画面を出す`() {
        val content = shown(entry())

        assertEquals("1件のエラー", content.summary)
        assertEquals(1, content.lines.size)
    }

    @Test
    fun `どこを直すかが行の先頭に来る`() {
        // 場所が分からないと、赤画面はただ視界を塞ぐだけになる。
        val line = shown(entry()).lines.single()

        assertTrue(line.contains("lib/main.dart:42:7"), line)
        assertTrue(line.contains("型が合いません"), line)
    }

    @Test
    fun `場所が無い診断も落とさない`() {
        // file が無いだけで表示ごと消えると、原因を追えなくなる。
        val line = shown(entry(file = null)).lines.single()

        assertTrue(line.contains(FluseOverlayState.NO_LOCATION), line)
        assertTrue(line.contains("型が合いません"), line)
    }

    @Test
    fun `行と列が欠けても出せるところまで出す`() {
        assertTrue(shown(entry(col = null)).lines.single().contains("lib/main.dart:42"))
        assertTrue(shown(entry(line = null)).lines.single().contains("lib/main.dart"))
    }

    @Test
    fun `深刻度は目印で見分ける`() {
        // 赤地の上では色を変えても見分けが付かない。
        assertEquals("✗", FluseOverlayState.markOf(DiagnosticSeverity.ERROR))
        assertEquals("△", FluseOverlayState.markOf(DiagnosticSeverity.WARNING))
        assertEquals("・", FluseOverlayState.markOf(DiagnosticSeverity.INFO))
    }

    @Test
    fun `診断が複数あれば全部並べる`() {
        val content = shown(entry(), entry(message = "未定義の名前", line = 99))

        assertEquals(2, content.lines.size)
        assertTrue(content.lines[1].contains("未定義の名前"))
    }

    @Test
    fun `診断が空でも summary は出す`() {
        // 何も出ないと「反映されていないだけ」と区別が付かない。
        val content = shown()

        assertEquals("1件のエラー", content.summary)
        assertEquals(emptyList(), content.lines)
    }

    @Test
    fun `ホスト側の絶対パスをそのまま出さない`() {
        // 端末の画面に開発者の名前や置き場所まで映る。狭い画面では肝心の
        // ファイル名が押し出される。
        val line = shown(entry(file = "/Users/someone/work/app/lib/ui/home.dart")).lines.single()

        assertTrue(line.contains("lib/ui/home.dart"), line)
        assertTrue(line.contains(FluseOverlayState.ELLIPSIS), line)
        assertTrue(!line.contains("/Users/someone"), line)
        // どこを直すかは残す。
        assertTrue(line.contains(":42:7"), line)
    }

    @Test
    fun `file スキームを外す`() {
        val line = shown(entry(file = "file:///Users/someone/app/lib/main.dart")).lines.single()

        assertTrue(!line.contains("file://"), line)
    }

    @Test
    fun `短いパスはそのまま出す`() {
        assertEquals("lib/main.dart", FluseOverlayState.shorten("lib/main.dart"))
        assertEquals("a/b/c.dart", FluseOverlayState.shorten("/a/b/c.dart"))
    }

    @Test
    fun `compileOk で自動的に消す`() {
        // 利用者に閉じさせない。直ったのに赤いままだと直った事に気づけない。
        assertEquals(FluseOverlayCommand.Hide, FluseOverlayState.of(CompileOkMessage()))
    }

    @Test
    fun `関係の無いメッセージでは何も変えない`() {
        // reload のたびに消えると、直す前にエラーが読めなくなる。
        assertEquals(FluseOverlayCommand.Ignore, FluseOverlayState.of(ReloadMessage()))
        assertEquals(FluseOverlayCommand.Ignore, FluseOverlayState.of(ReadyMessage()))
    }
}

/**
 * バッジが接続の出来事をどう読むか。
 *
 * View は JVM 単体テストで動かせないため、貼り付け先の無い状態で
 * [FluseBadge] を直に動かし、状態の移り変わりだけを見る。
 */
internal class FluseBadgeStateTest {
    /** すぐ実行する。メインスレッドの Looper が無いテストで使う。 */
    private val now = java.util.concurrent.Executor { it.run() }

    private fun badge() = FluseBadge(main = now)

    @Test
    fun `繋がる前は接続中`() {
        // 何も出さないと「繋がっていない」ことに気づけない。
        assertEquals(FluseBadgeState.CONNECTING, badge().state)
    }

    @Test
    fun `accept で接続済みになる`() {
        val badge = badge()

        badge.onConnected("s-1")

        assertEquals(FluseBadgeState.CONNECTED, badge.state)
    }

    @Test
    fun `切れたら切断に戻る`() {
        val badge = badge()
        badge.onConnected("s-1")

        badge.onDisconnected()

        assertEquals(FluseBadgeState.DISCONNECTED, badge.state)
    }

    @Test
    fun `繋ぎ直せば接続済みに戻る`() {
        val badge = badge()
        badge.onConnected("s-1")
        badge.onDisconnected()

        badge.onConnected("s-2")

        assertEquals(FluseBadgeState.CONNECTED, badge.state)
    }

    @Test
    fun `断られたら接続不可になる`() {
        // 繋ぎ直しでは解けない。押してペアリングし直す道を示す。
        val badge = badge()

        badge.onRejected("TOO_MANY_DEVICES", "1台だけです")

        assertEquals(FluseBadgeState.REJECTED, badge.state)
    }

    @Test
    fun `認証に落ちたら要ペアリング`() {
        val badge = badge()

        badge.onNeedsPairing("認証できません")

        assertEquals(FluseBadgeState.NEEDS_PAIRING, badge.state)
    }

    @Test
    fun `制御メッセージでは変わらない`() {
        // reload や compileError はバッジの話ではない。
        val badge = badge()
        badge.onConnected("s-1")

        badge.onMessage(ReloadMessage())

        assertEquals(FluseBadgeState.CONNECTED, badge.state)
    }
}

/**
 * 赤画面が中身を持ち替えるところ。
 *
 * 貼り付け先の無い状態で [FluseErrorOverlay] を直に動かす。
 */
internal class FluseErrorOverlayTest {
    private val now = java.util.concurrent.Executor { it.run() }

    @Test
    fun `compileError で中身を持つ`() {
        val overlay = FluseErrorOverlay(main = now)

        overlay.onMessage(
            CompileErrorMessage(
                "1件のエラー",
                listOf(DiagnosticEntry(DiagnosticSeverity.ERROR, "型が合いません", "lib/main.dart", 42, 7)),
            ),
        )

        assertEquals("1件のエラー", overlay.content?.summary)
    }

    @Test
    fun `compileOk で中身を捨てる`() {
        val overlay = FluseErrorOverlay(main = now)
        overlay.onMessage(CompileErrorMessage("1件のエラー", emptyList()))

        overlay.onMessage(CompileOkMessage())

        assertEquals(null, overlay.content)
    }

    @Test
    fun `切れても消さない`() {
        // サーバが落ちた時に赤画面まで消えると、直前に何が起きていたのかが
        // 分からなくなる。
        val overlay = FluseErrorOverlay(main = now)
        overlay.onMessage(CompileErrorMessage("1件のエラー", emptyList()))

        overlay.onDisconnected()

        assertEquals("1件のエラー", overlay.content?.summary)
    }

    @Test
    fun `reload では消さない`() {
        // 直す前にエラーが読めなくなる。
        val overlay = FluseErrorOverlay(main = now)
        overlay.onMessage(CompileErrorMessage("1件のエラー", emptyList()))

        overlay.onMessage(ReloadMessage())

        assertEquals("1件のエラー", overlay.content?.summary)
    }
}
