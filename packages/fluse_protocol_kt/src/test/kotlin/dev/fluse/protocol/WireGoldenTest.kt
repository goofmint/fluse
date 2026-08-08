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

    /** org.json の `similar` は JSONObject / JSONArray にしか無いので補う。 */
    private fun Any?.similarTo(other: Any?): Boolean = when {
        this is JSONObject && other is JSONObject -> similar(other)
        this is JSONArray && other is JSONArray -> similar(other)
        else -> this == other
    }

    /** `messages` から名前で1件引く。 */
    private fun sample(name: String): JSONObject {
        val array: JSONArray = golden.getJSONArray("messages")
        for (i in 0 until array.length()) {
            val entry = array.getJSONObject(i)
            if (entry.getString("name") == name) return entry.getJSONObject("json")
        }
        error("ゴールデンに $name がありません")
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
            val encoded = message.toJson()

            // **値は出さない。** helloWithTokens のようにトークンを持つ
            // 標本があり、失敗時に JSON 全体を出すとログへ流れる。
            // 食い違ったキー名だけ挙げれば原因は追える。
            assertTrue(
                json.similar(encoded),
                "$name の往復が一致しません。食い違うキー: ${
                    (json.keySet() + encoded.keySet())
                        .filter { !json.opt(it).similarTo(encoded.opt(it)) }
                        .sorted()
                }",
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
        // 標本はゴールデン側に置き、Dart 側も同じ入力で検証する。
        val reject = FluseMessage.fromJson(sample("rejectUnknownCode")) as RejectMessage

        assertNull(reject.knownCode)
        assertEquals("将来の理由", reject.message)
    }

    @Test
    fun `トークンは toString に出ない`() {
        val json = sample("helloWithTokens")
        val hello = FluseMessage.fromJson(json)

        // 失敗メッセージに toString() を渡さない。渡すと、漏れている
        // ことを報告するためにトークンをもう一度ログへ出すことになる。
        for (field in listOf("pairingToken", "deviceToken")) {
            assertTrue(
                !hello.toString().contains(json.getString(field)),
                "$field が toString() に出ています",
            )
        }
    }
}
