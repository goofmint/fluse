package dev.fluse.runtime

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * 認証コードのマスクだけを見る。
 *
 * MethodChannel の配線は Flutter エンジンが要るので、ここでは扱わない。
 * **logcat は Dart 側の redact を通らない**ため、マスクの正しさは
 * 単体で押さえておく必要がある。
 */
internal class FluseRuntimePluginTest {
    @Test
    fun `認証コードを伏せる`() {
        val masked = FluseRuntimePlugin.maskAuthCode("http://127.0.0.1:45123/aBcDeFgHiJkL=/")

        assertFalse(masked.contains("aBcDeFgHiJkL"), "認証コードが残っている: $masked")
        assertTrue(masked.startsWith("http://127.0.0.1:45123/"), masked)
        assertTrue(masked.contains("***"), masked)
    }

    @Test
    fun `先頭4文字だけ残す`() {
        val masked = FluseRuntimePlugin.maskAuthCode("http://127.0.0.1:1/abcdefghij/")

        assertEquals("http://127.0.0.1:1/abcd***/", masked)
    }

    @Test
    fun `短いパスは認証コードとみなさない`() {
        // /health のような普通のパスを巻き込まない。
        val uri = "http://127.0.0.1:1/health"

        assertEquals(uri, FluseRuntimePlugin.maskAuthCode(uri))
    }

    @Test
    fun `パスが無ければそのまま返す`() {
        val uri = "http://127.0.0.1:1"

        assertEquals(uri, FluseRuntimePlugin.maskAuthCode(uri))
    }

    @Test
    fun `URI でなければそのまま返す`() {
        assertEquals("なにか", FluseRuntimePlugin.maskAuthCode("なにか"))
    }

    @Test
    fun `伏せるのは最初の1セグメントだけ`() {
        // 認証コードは先頭の1セグメント。後続まで潰すと形が変わる。
        val masked = FluseRuntimePlugin.maskAuthCode("ws://127.0.0.1:1/abcdefghij/ws")

        assertEquals("ws://127.0.0.1:1/abcd***/ws", masked)
    }
}
