package dev.fluse.runtime

import dev.fluse.protocol.FLUSE_PROTOCOL_VERSION
import java.security.SecureRandom
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNull

internal class FluseConnectUriTest {
    private val appInfo =
        FluseAppInfo(
            projectId = "0123456789abcdef",
            flutterRevision = "00b0c91f2a3b4c5d",
            dartVersion = "3.5.0",
            appVersion = "fedcba9876543210",
        )

    /**
     * テスト用のトークン。
     *
     * **リテラルで書かない。** ダミーであっても、資格情報の形をした
     * 文字列がリポジトリに残ると本物と見分けが付かない。
     */
    private val token: String =
        ByteArray(16).also { SecureRandom().nextBytes(it) }
            .joinToString("") { "%02x".format(it) }

    private val valid =
        "fluse://connect?v=1&h=192.168.0.10&p=8180" +
            "&pid=0123456789abcdef&t=$token&rev=00b0c91f"

    private fun accepted(raw: String): FluseConnectRequest {
        val result = FluseConnectUri.parse(raw)
        assertIs<FluseConnectResult.Accepted>(result, "解けませんでした: $result")
        return result.request
    }

    private fun rejected(raw: String): FluseConnectError {
        val result = FluseConnectUri.parse(raw)
        assertIs<FluseConnectResult.Rejected>(result, "解けてしまいました")
        return result.error
    }

    // ------------------------------------------------------------------ parse

    @Test
    fun `設計の QR を解く`() {
        val request = accepted(valid)

        assertEquals(FLUSE_PROTOCOL_VERSION, request.protocolVersion)
        assertEquals("192.168.0.10", request.host)
        assertEquals(8180, request.port)
        assertEquals("0123456789abcdef", request.projectId)
        assertEquals(token, request.pairingToken)
        assertEquals("00b0c91f", request.revision)
        assertEquals(FluseEndpoint("192.168.0.10", 8180), request.endpoint())
    }

    @Test
    fun `別のアプリの QR は fluse ではないと分かる`() {
        // 「読み取れません」ではなく「これは fluse の QR ではない」と出したい。
        assertEquals(FluseConnectError.NOT_FLUSE, rejected("https://example.com/"))
        assertEquals(FluseConnectError.NOT_FLUSE, rejected("fluse://other?v=1"))
    }

    @Test
    fun `必要な値が欠けていたら受け付けない`() {
        assertEquals(FluseConnectError.MALFORMED, rejected(valid.replace("&t=$token", "")))
        assertEquals(FluseConnectError.MALFORMED, rejected(valid.replace("&h=192.168.0.10", "")))
        assertEquals(FluseConnectError.MALFORMED, rejected(valid.replace("&rev=00b0c91f", "")))
    }

    @Test
    fun `ポートが数でなければ受け付けない`() {
        assertEquals(FluseConnectError.MALFORMED, rejected(valid.replace("p=8180", "p=abc")))
    }

    @Test
    fun `ポートが範囲の外なら受け付けない`() {
        // 0 や 70000 で繋ぎに行っても、その場で分かる形にしておく。
        assertEquals(FluseConnectError.MALFORMED, rejected(valid.replace("p=8180", "p=0")))
        assertEquals(FluseConnectError.MALFORMED, rejected(valid.replace("p=8180", "p=70000")))
    }

    @Test
    fun `前後の空白は落とす`() {
        // QR リーダによっては改行が混ざる。
        assertEquals("192.168.0.10", accepted("  $valid\n").host)
    }

    @Test
    fun `percent encode を戻す`() {
        val request = accepted(valid.replace("t=$token", "t=a%2Bb%2Fc"))

        assertEquals("a+b/c", request.pairingToken)
    }

    @Test
    fun `同じキーが二度あっても後から上書きされない`() {
        // 細工した QR で繋ぎ先だけを差し替えられないようにする。
        val request = accepted("$valid&h=10.0.0.1")

        assertEquals("192.168.0.10", request.host)
    }

    @Test
    fun `トークンは toString に出さない`() {
        // 例外文やログに混ざると漏れる。
        val request = accepted(valid)

        assertEquals(false, request.toString().contains(token), request.toString())
    }

    // ----------------------------------------------------------------- verify

    @Test
    fun `噛み合えば通す`() {
        assertNull(FluseConnectUri.verify(accepted(valid), appInfo))
    }

    @Test
    fun `別プロジェクトの QR はその場で分かる`() {
        // 繋ぎに行ってサーバに断られるまで待たせない。
        val other = accepted(valid.replace("pid=0123456789abcdef", "pid=ffffffffffffffff"))

        assertEquals(FluseConnectError.PROJECT_MISMATCH, FluseConnectUri.verify(other, appInfo))
    }

    @Test
    fun `Flutter の版が違えばその場で分かる`() {
        val other = accepted(valid.replace("rev=00b0c91f", "rev=deadbeef"))

        assertEquals(FluseConnectError.REVISION_MISMATCH, FluseConnectUri.verify(other, appInfo))
    }

    @Test
    fun `プロトコルの版が違えばその場で分かる`() {
        val other = accepted(valid.replace("v=1", "v=99"))

        assertEquals(FluseConnectError.PROTOCOL_MISMATCH, FluseConnectUri.verify(other, appInfo))
    }

    @Test
    fun `rev は先頭8桁だけを見る`() {
        // QR に載るのは先頭8桁（設計 §4.2(a)）。全桁と比べると必ず外れる。
        assertNull(FluseConnectUri.verify(accepted(valid), appInfo))
    }

    // ------------------------------------------------------------------ 手入力

    @Test
    fun `手入力からも同じ形に均す`() {
        val result =
            FluseConnectUri.fromManualInput(
                host = " 192.168.0.10 ",
                port = " 8180 ",
                token = " $token ",
                appInfo = appInfo,
            )

        assertIs<FluseConnectResult.Accepted>(result)
        assertEquals("192.168.0.10", result.request.host)
        assertEquals(8180, result.request.port)
        assertEquals(token, result.request.pairingToken)
        // QR に無い値はこの端末の素性で埋める。突き合わせはサーバが行う。
        assertEquals(appInfo.projectId, result.request.projectId)
        assertEquals("00b0c91f", result.request.revision)
    }

    @Test
    fun `手入力が空なら受け付けない`() {
        val result =
            FluseConnectUri.fromManualInput(
                host = "",
                port = "8180",
                token = token,
                appInfo = appInfo,
            )

        assertIs<FluseConnectResult.Rejected>(result)
        assertEquals(FluseConnectError.MALFORMED, result.error)
    }

    @Test
    fun `空白だけの値は受け付けない`() {
        // `h=%20` は decode 後も空でない文字列になり、そのまま繋ぎ先へ渡る。
        assertEquals(FluseConnectError.MALFORMED, rejected(valid.replace("h=192.168.0.10", "h=%20")))
        assertEquals(FluseConnectError.MALFORMED, rejected(valid.replace("t=$token", "t=%20")))
    }

    @Test
    fun `壊れたエスケープは受け付けない`() {
        // 直して通すと、読み取ったものと繋ぎに行く先が食い違う。
        assertEquals(FluseConnectError.MALFORMED, rejected(valid.replace("t=$token", "t=%A")))
        assertEquals(FluseConnectError.MALFORMED, rejected(valid.replace("t=$token", "t=%ZZ")))
        assertEquals(FluseConnectError.MALFORMED, rejected(valid.replace("t=$token", "t=abc%")))
    }

    @Test
    fun `手入力のポートが数でなければ受け付けない`() {
        val result =
            FluseConnectUri.fromManualInput(
                host = "192.168.0.10",
                port = "八一八〇",
                token = token,
                appInfo = appInfo,
            )

        assertIs<FluseConnectResult.Rejected>(result)
        assertEquals(FluseConnectError.MALFORMED, result.error)
    }
}
