package dev.fluse.runtime

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

internal class FluseCleartextTest {
    private val host = "192.168.0.10"

    @Test
    fun `古い端末では尋ねずに通す`() {
        // NetworkSecurityPolicy にホスト別の判定が無い。呼ぶと落ちる。
        var asked = false

        val permitted =
            FluseCleartext.isPermitted(FluseCleartext.MIN_POLICY_SDK - 1, host) {
                asked = true
                false
            }

        assertTrue(permitted)
        assertFalse(asked, "古い端末で端末に尋ねてはいけない")
    }

    @Test
    fun `新しい端末では端末の答えに従う`() {
        assertTrue(FluseCleartext.isPermitted(FluseCleartext.MIN_POLICY_SDK, host) { true })
        assertFalse(FluseCleartext.isPermitted(FluseCleartext.MIN_POLICY_SDK, host) { false })
    }

    @Test
    fun `尋ねるのは繋ぎ先のホスト`() {
        // 端末全体ではなく、これから繋ぐ相手で判定する。独自の
        // networkSecurityConfig が開発サーバだけを許していることがある。
        var asked: String? = null

        FluseCleartext.isPermitted(FluseCleartext.MIN_POLICY_SDK, host) {
            asked = it
            true
        }

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
