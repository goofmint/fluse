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
 * View は JVM 単体テストで動かせないので、状態の移り変わりだけを見る。
 */
internal class FluseBadgeStateTest {
    /** 出来事を受けた後の状態を返す。 */
    private fun after(vararg events: (FluseConnectionListener) -> Unit): FluseBadgeState {
        val recorder = StateRecorder()
        events.forEach { it(recorder) }
        return recorder.state
    }

    private class StateRecorder : FluseConnectionListener {
        var state = FluseBadgeState.CONNECTING

        override fun onConnected(sessionId: String) {
            state = FluseBadgeState.CONNECTED
        }

        override fun onDisconnected() {
            state = FluseBadgeState.DISCONNECTED
        }

        override fun onNeedsPairing(reason: String) {
            state = FluseBadgeState.NEEDS_PAIRING
        }

        override fun onRejected(
            code: String,
            message: String,
        ) {
            state = FluseBadgeState.REJECTED
        }

        override fun onMessage(message: dev.fluse.protocol.FluseMessage) = Unit
    }

    @Test
    fun `繋がる前は接続中`() {
        // 何も出さないと「繋がっていない」ことに気づけない。
        assertEquals(FluseBadgeState.CONNECTING, after())
    }

    @Test
    fun `accept で接続済みになる`() {
        assertEquals(FluseBadgeState.CONNECTED, after({ it.onConnected("s-1") }))
    }

    @Test
    fun `切れたら切断に戻る`() {
        assertEquals(
            FluseBadgeState.DISCONNECTED,
            after({ it.onConnected("s-1") }, { it.onDisconnected() }),
        )
    }

    @Test
    fun `繋ぎ直せば接続済みに戻る`() {
        assertEquals(
            FluseBadgeState.CONNECTED,
            after({ it.onConnected("s-1") }, { it.onDisconnected() }, { it.onConnected("s-2") }),
        )
    }

    @Test
    fun `断られたら接続不可のまま`() {
        // 繋ぎ直しでは解けない。押してペアリングし直す道を示す。
        assertEquals(
            FluseBadgeState.REJECTED,
            after({ it.onRejected("TOO_MANY_DEVICES", "1台だけです") }),
        )
    }

    @Test
    fun `認証に落ちたら要ペアリング`() {
        assertEquals(
            FluseBadgeState.NEEDS_PAIRING,
            after({ it.onNeedsPairing("認証できません") }),
        )
    }
}
