package dev.fluse.runtime

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

internal class FluseCleartextTest {
    private val host = "192.168.0.10"

    private fun permitted(
        sdkInt: Int,
        all: Boolean = true,
        perHost: Boolean = true,
    ): Boolean = FluseCleartext.isPermitted(sdkInt, host, { all }, { perHost })

    @Test
    fun `古い端末では尋ねずに通す`() {
        // NetworkSecurityPolicy が無い。呼ぶと落ちる。
        var asked = false
        val mark = { asked = true }

        val result =
            FluseCleartext.isPermitted(
                FluseCleartext.MIN_POLICY_SDK - 1,
                host,
                {
                    mark()
                    false
                },
                {
                    mark()
                    false
                },
            )

        assertTrue(result)
        assertFalse(asked, "古い端末で端末に尋ねてはいけない")
    }

    @Test
    fun `API 23 は端末全体の可否で判じる`() {
        // ホスト別には答えられないが、usesCleartextTraffic は効く。
        // 素通りさせると塞がれていることに気づけない。
        assertTrue(permitted(FluseCleartext.MIN_POLICY_SDK, all = true))
        assertFalse(permitted(FluseCleartext.MIN_POLICY_SDK, all = false))
    }

    @Test
    fun `API 23 ではホスト別には尋ねない`() {
        var askedHost = false

        FluseCleartext.isPermitted(FluseCleartext.MIN_POLICY_SDK, host, { true }, {
            askedHost = true
            true
        })

        assertFalse(askedHost, "API 23 にホスト別の判定は無い")
    }

    @Test
    fun `API 24 以降は端末の答えに従う`() {
        assertTrue(permitted(FluseCleartext.MIN_PER_HOST_SDK, perHost = true))
        assertFalse(permitted(FluseCleartext.MIN_PER_HOST_SDK, perHost = false))
    }

    @Test
    fun `尋ねるのは繋ぎ先のホスト`() {
        // 端末全体ではなく、これから繋ぐ相手で判定する。独自の
        // networkSecurityConfig が開発サーバだけを許していることがある。
        var asked: String? = null

        FluseCleartext.isPermitted(FluseCleartext.MIN_PER_HOST_SDK, host, { false }, {
            asked = it
            true
        })

        assertEquals(host, asked)
    }

    @Test
    fun `文言に繋ぎ先が入る`() {
        assertTrue(FluseCleartext.blockedMessage(host).contains(host))
    }

    @Test
    fun `文言に直し方が入る`() {
        // 「拒否されました」だけでは、自分のアプリの設定が原因だと気づけない。
        val message = FluseCleartext.blockedMessage(host)

        assertTrue(message.contains("networkSecurityConfig"), message)
        assertTrue(message.contains("cleartextTrafficPermitted"), message)
    }
}
