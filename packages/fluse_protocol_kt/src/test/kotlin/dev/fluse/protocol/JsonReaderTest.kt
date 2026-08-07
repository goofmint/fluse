package dev.fluse.protocol

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import org.json.JSONObject

/** Dart 側の `JsonReader` と同じ判定になっていることを確かめる。 */
class JsonReaderTest {
    private fun ping(seq: Any?): JSONObject =
        JSONObject().put("type", "ping").put("seq", seq).put("timestampMs", 1)

    @Test
    fun `整数として表せる double は受け入れる`() {
        val message = FluseMessage.fromJson(ping(7.0)) as PingMessage

        assertEquals(7L, message.seq)
    }

    @Test
    fun `小数は受け入れない`() {
        assertFailsWith<FluseProtocolException> { FluseMessage.fromJson(ping(7.5)) }
    }

    @Test
    fun `安全範囲外は拒否する`() {
        assertFailsWith<FluseProtocolException> { FluseMessage.fromJson(ping(1e30)) }
        assertFailsWith<FluseProtocolException> {
            FluseMessage.fromJson(ping(9007199254740992L))
        }
    }

    @Test
    fun `安全範囲の境界は受け入れる`() {
        val message = FluseMessage.fromJson(
            JSONObject()
                .put("type", "ping")
                .put("seq", 9007199254740991L)
                .put("timestampMs", -9007199254740991L),
        ) as PingMessage

        assertEquals(9007199254740991L, message.seq)
        assertEquals(-9007199254740991L, message.timestampMs)
    }

    @Test
    fun `キー有りで null の任意フィールドは省略と同じ扱い`() {
        // Dart 側が null を明示送信しても失敗しないこと。
        val close = FluseMessage.fromJson(
            JSONObject().put("type", "close").put("code", "SHUTDOWN").put("message", JSONObject.NULL),
        ) as CloseMessage

        assertNull(close.message)
    }

    @Test
    fun `型が違えば「無い」と区別して失敗する`() {
        val error = assertFailsWith<FluseProtocolException> {
            FluseMessage.fromJson(ping("いち"))
        }

        assertEquals(true, error.message?.contains("整数"))
    }

    @Test
    fun `例外メッセージに値が載らない`() {
        val error = assertFailsWith<FluseProtocolException> {
            FluseMessage.fromJson(
                JSONObject()
                    .put("type", "hello")
                    .put("protocolVersion", 1)
                    .put("projectId", "p")
                    .put("flutterRevision", "r")
                    .put("dartVersion", "d")
                    .put("appVersion", "a")
                    .put("deviceId", "i")
                    .put("deviceName", "n")
                    .put("pairingToken", 12345),
            )
        }

        assertEquals(true, error.message?.contains("pairingToken"))
        assertEquals(false, error.message?.contains("12345"))
    }

    @Test
    fun `protocolVersion の互換判定は厳密一致`() {
        assertEquals(true, isCompatibleProtocolVersion(FLUSE_PROTOCOL_VERSION))
        assertEquals(false, isCompatibleProtocolVersion(FLUSE_PROTOCOL_VERSION + 1))
    }
}
