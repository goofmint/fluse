package dev.fluse.runtime

import kotlin.test.Test
import kotlin.test.assertEquals

internal class FluseBackoffTest {
    @Test
    fun `1秒から倍にして30秒で止まる`() {
        // すぐに繋ぎ直し続けるとバッテリを削り、サーバ復帰時に接続が殺到する。
        val backoff = FluseBackoff()

        val waits = (1..8).map { backoff.next() }

        assertEquals(
            listOf(1_000L, 2_000L, 4_000L, 8_000L, 16_000L, 30_000L, 30_000L, 30_000L),
            waits,
        )
    }

    @Test
    fun `繋がったら最初の待ち時間に戻る`() {
        // 一度繋がった後の切断は、たいてい一時的なもの。30秒待たせない。
        val backoff = FluseBackoff()
        repeat(5) { backoff.next() }

        backoff.reset()

        assertEquals(1_000L, backoff.next())
    }
}
