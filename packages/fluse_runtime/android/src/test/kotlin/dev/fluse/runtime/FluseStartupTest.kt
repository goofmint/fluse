package dev.fluse.runtime

import kotlin.test.Test
import kotlin.test.assertEquals

internal class FluseStartupTest {
    @Test
    fun `トークンと接続先が揃っていれば繋ぎ直す`() {
        assertEquals(
            StartupPath.RECONNECT,
            FluseStartup.resolve(hasDeviceToken = true, hasLastServer = true),
        )
    }

    @Test
    fun `トークンが無ければペアリング`() {
        assertEquals(
            StartupPath.PAIR,
            FluseStartup.resolve(hasDeviceToken = false, hasLastServer = true),
        )
    }

    @Test
    fun `接続先が分からなければペアリング`() {
        // トークンだけでは繋ぎようが無い。QR から取り直す。
        assertEquals(
            StartupPath.PAIR,
            FluseStartup.resolve(hasDeviceToken = true, hasLastServer = false),
        )
    }

    @Test
    fun `どちらも無ければペアリング`() {
        assertEquals(
            StartupPath.PAIR,
            FluseStartup.resolve(hasDeviceToken = false, hasLastServer = false),
        )
    }
}
