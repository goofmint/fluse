package dev.fluse.runtime

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

internal class FluseAppInfoTest {
    private val full =
        """
        {
          "projectId": "0123456789abcdef",
          "flutterRevision": "00b0c91f",
          "dartVersion": "3.5.0",
          "appVersion": "fedcba9876543210"
        }
        """.trimIndent()

    @Test
    fun `assets の JSON から素性を読む`() {
        val info = FluseAppInfo.parse(full)

        assertEquals("0123456789abcdef", info.projectId)
        assertEquals("00b0c91f", info.flutterRevision)
        assertEquals("3.5.0", info.dartVersion)
        assertEquals("fedcba9876543210", info.appVersion)
    }

    @Test
    fun `欠けていたら落とす`() {
        // **既定値で埋めない。** 別プロジェクトのサーバに繋がったり、
        // 古い APK が受理されたりする形で表面化して切り分けが難しい。
        val missing = full.replace("\"projectId\": \"0123456789abcdef\",", "")

        val error = assertFailsWith<IllegalArgumentException> { FluseAppInfo.parse(missing) }

        assertEquals(true, error.message?.contains("projectId"), error.message)
    }

    @Test
    fun `空文字も欠けている扱い`() {
        val empty = full.replace("0123456789abcdef", "")

        assertFailsWith<IllegalArgumentException> { FluseAppInfo.parse(empty) }
    }

    @Test
    fun `WebSocket の URL は設計の経路に合わせる`() {
        assertEquals("ws://192.168.1.2:8180/ws", FluseEndpoint("192.168.1.2", 8180).webSocketUrl())
    }
}
