package dev.fluse.protocol

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import org.json.JSONArray
import org.json.JSONObject

/**
 * Dart 実装と Kotlin 実装が**同じファイル**を読んで検証する。
 *
 * どちらか片方だけを直しても、もう片方のテストが落ちる。ワイヤ表現が
 * ずれたまま気づかない事態を防ぐための唯一の共有仕様。
 */
class WireGoldenTest {
    private val golden: JSONObject by lazy {
        val file = File("../fluse_protocol/test/fixtures/wire_golden.json")
        check(file.exists()) { "ゴールデンが見つかりません: ${file.absolutePath}" }
        JSONObject(file.readText())
    }

    private fun hexToBytes(hex: String): ByteArray =
        ByteArray(hex.length / 2) { i ->
            hex.substring(i * 2, i * 2 + 2).toInt(16).toByte()
        }

    private fun bytesToHex(bytes: ByteArray): String =
        bytes.joinToString("") { "%02x".format(it.toInt() and 0xFF) }

    private fun each(key: String, body: (JSONObject) -> Unit) {
        val array: JSONArray = golden.getJSONArray(key)
        for (i in 0 until array.length()) {
            body(array.getJSONObject(i))
        }
    }

    @Test
    fun `protocolVersion がゴールデンと一致する`() {
        assertEquals(golden.getInt("protocolVersion"), FLUSE_PROTOCOL_VERSION)
    }

    @Test
    fun `encode がゴールデンのバイト列と一致する`() {
        each("tunnelFrames") { frame ->
            val name = frame.getString("name")
            val opcode = assertNotNull(
                TunnelOpcode.tryParseName(frame.getString("opcode")),
                "$name の opcode が不明です",
            )
            val built = TunnelFrame(
                opcode = opcode,
                streamId = frame.getLong("streamId"),
                payload = hexToBytes(frame.getString("payloadHex")),
            )

            assertEquals(
                frame.getString("bytesHex"),
                bytesToHex(built.encode()),
                "$name の符号化が違います",
            )
        }
    }

    @Test
    fun `decode がゴールデンのバイト列を復元する`() {
        each("tunnelFrames") { frame ->
            val name = frame.getString("name")
            val decoded = TunnelFrame.decode(hexToBytes(frame.getString("bytesHex")))

            assertEquals(frame.getString("opcode"), decoded.opcode.wireName, name)
            assertEquals(frame.getLong("streamId"), decoded.streamId, name)
            assertEquals(frame.getString("payloadHex"), bytesToHex(decoded.payload), name)
        }
    }

    @Test
    fun `不正なバイト列はゴールデンの通り拒否する`() {
        each("invalidTunnelFrames") { frame ->
            assertFailsWith<FluseProtocolException>(
                "${frame.getString("name")} が拒否されていません",
            ) {
                TunnelFrame.decode(hexToBytes(frame.getString("bytesHex")))
            }
        }
    }

    @Test
    fun `fromJson から toJson が完全に一致する`() {
        each("messages") { sample ->
            val name = sample.getString("name")
            val json = sample.getJSONObject("json")

            val message = FluseMessage.fromJson(json)

            assertTrue(
                json.similar(message.toJson()),
                "$name の往復が一致しません: 期待 $json 実際 ${message.toJson()}",
            )
        }
    }

    @Test
    fun `全メッセージ型がゴールデンに含まれている`() {
        val covered = mutableSetOf<String>()
        each("messages") { sample -> covered.add(sample.getJSONObject("json").getString("type")) }

        assertEquals(
            setOf(
                "hello", "vmServiceReady", "ready", "log", "error",
                "accept", "reject", "reload", "compileError", "compileOk",
                "ping", "pong", "close",
            ),
            covered,
        )
    }

    @Test
    fun `不正なメッセージはゴールデンの通り拒否する`() {
        each("invalidMessages") { sample ->
            assertFailsWith<FluseProtocolException>(
                "${sample.getString("name")} が拒否されていません",
            ) {
                FluseMessage.fromJson(sample.getJSONObject("json"))
            }
        }
    }

    @Test
    fun `未知のコードでも解析は成功する`() {
        // 新しいサーバのコードを古いアプリが受け取っても、文言は表示できる。
        val reject = FluseMessage.fromJson(
            JSONObject()
                .put("type", "reject")
                .put("code", "FUTURE_REASON")
                .put("message", "将来の理由"),
        ) as RejectMessage

        assertNull(reject.knownCode)
        assertEquals("将来の理由", reject.message)
    }

    @Test
    fun `トークンは toString に出ない`() {
        val hello = FluseMessage.fromJson(
            golden.getJSONArray("messages").let { array ->
                (0 until array.length())
                    .map { array.getJSONObject(it) }
                    .first { it.getString("name") == "helloWithTokens" }
                    .getJSONObject("json")
            },
        )

        assertTrue(!hello.toString().contains("0123456789"), hello.toString())
    }
}
