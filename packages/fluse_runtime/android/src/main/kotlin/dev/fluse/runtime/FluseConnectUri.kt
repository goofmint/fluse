package dev.fluse.runtime

import dev.fluse.protocol.FLUSE_PROTOCOL_VERSION

/**
 * QR に載る繋ぎ先（設計 §4.2(a)）。
 *
 * ```
 * fluse://connect?v=1&h=192.168.0.10&p=8180&pid=<projectId>&t=<pairingToken>&rev=00b0c91f
 * ```
 *
 * Android のランタイムに触らない。`android.net.Uri` を使うと単体テストで
 * 実機が要るため、自前で解く。
 */
data class FluseConnectRequest(
    val protocolVersion: Int,
    val host: String,
    val port: Int,
    val projectId: String,
    val pairingToken: String,
    /** Flutter revision の先頭8桁。 */
    val revision: String,
) {
    fun endpoint(): FluseEndpoint = FluseEndpoint(host, port)

    /** **トークンは含めない。** ログや例外文に混ざると漏れる。 */
    override fun toString(): String = "FluseConnectRequest($host:$port, project: $projectId)"
}

/** 読み取った QR を受け入れられない理由。 */
enum class FluseConnectError {
    /** `fluse://connect` ではない。別のアプリの QR を読んだ。 */
    NOT_FLUSE,

    /** 必要な値が足りない、または形が違う。 */
    MALFORMED,

    /** サーバとアプリでプロトコルの版が違う。 */
    PROTOCOL_MISMATCH,

    /** 別プロジェクトの Preview App。 */
    PROJECT_MISMATCH,

    /** ビルドに使った Flutter が違う。 */
    REVISION_MISMATCH,
}

/** 解いた結果。 */
sealed class FluseConnectResult {
    data class Accepted(val request: FluseConnectRequest) : FluseConnectResult()

    data class Rejected(val error: FluseConnectError) : FluseConnectResult()
}

/**
 * QR と手入力を同じ形に均す。
 *
 * **ここで弾いてもサーバ側の検証は省かない。** こちらは「読んだ瞬間に
 * 理由が分かる」ためのもので、権威はあくまでサーバの `hello` / `reject`
 * （設計 §3.1）。端末側の値は利用者が手で書き換えられる。
 */
object FluseConnectUri {
    const val SCHEME = "fluse"
    const val HOST = "connect"

    /** `rev` に載るのは先頭8桁（設計 §4.2(a)）。 */
    const val REVISION_LENGTH = 8

    private const val PREFIX = "$SCHEME://$HOST"

    /** 読んだ文字列を解く。中身の突き合わせは [verify] が行う。 */
    fun parse(raw: String): FluseConnectResult {
        val text = raw.trim()
        if (!text.startsWith("$PREFIX?")) {
            return FluseConnectResult.Rejected(FluseConnectError.NOT_FLUSE)
        }

        val query = decodeQuery(text.substringAfter('?'))
        val version = query["v"]?.toIntOrNull()
        val host = query["h"]
        val port = query["p"]?.toIntOrNull()
        val projectId = query["pid"]
        val token = query["t"]
        val revision = query["rev"]

        if (version == null ||
            host.isNullOrEmpty() ||
            port == null ||
            projectId.isNullOrEmpty() ||
            token.isNullOrEmpty() ||
            revision.isNullOrEmpty()
        ) {
            return FluseConnectResult.Rejected(FluseConnectError.MALFORMED)
        }
        if (port !in 1..65535) {
            return FluseConnectResult.Rejected(FluseConnectError.MALFORMED)
        }

        return FluseConnectResult.Accepted(
            FluseConnectRequest(
                protocolVersion = version,
                host = host,
                port = port,
                projectId = projectId,
                pairingToken = token,
                revision = revision,
            ),
        )
    }

    /**
     * この端末に入っている Preview App と噛み合うか見る。
     *
     * 噛み合わないまま繋ぎに行っても、サーバが `reject` を返すだけ。
     * 往復を省いて、その場で理由を出す。
     */
    fun verify(
        request: FluseConnectRequest,
        appInfo: FluseAppInfo,
    ): FluseConnectError? {
        if (request.protocolVersion != FLUSE_PROTOCOL_VERSION) {
            return FluseConnectError.PROTOCOL_MISMATCH
        }
        if (request.projectId != appInfo.projectId) {
            return FluseConnectError.PROJECT_MISMATCH
        }
        if (request.revision != appInfo.flutterRevision.take(REVISION_LENGTH)) {
            return FluseConnectError.REVISION_MISMATCH
        }
        return null
    }

    /**
     * 手入力から組み立てる（設計 §4.2(b) の `GET /` が値の出どころ）。
     *
     * カメラの無い端末とエミュレータのための道。案内ページに出ている
     * ホスト・ポート・トークンを写してもらう。
     *
     * `pid` と `rev` は QR にしか無いので、この端末の値で埋める。
     * **突き合わせを緩めているわけではない。** サーバは `hello` の中身を
     * 見て、違えば断る。
     */
    fun fromManualInput(
        host: String,
        port: String,
        token: String,
        appInfo: FluseAppInfo,
    ): FluseConnectResult {
        val trimmedHost = host.trim()
        val trimmedToken = token.trim()
        val parsedPort = port.trim().toIntOrNull()
        if (trimmedHost.isEmpty() || trimmedToken.isEmpty() || parsedPort == null) {
            return FluseConnectResult.Rejected(FluseConnectError.MALFORMED)
        }
        if (parsedPort !in 1..65535) {
            return FluseConnectResult.Rejected(FluseConnectError.MALFORMED)
        }

        return FluseConnectResult.Accepted(
            FluseConnectRequest(
                protocolVersion = FLUSE_PROTOCOL_VERSION,
                host = trimmedHost,
                port = parsedPort,
                projectId = appInfo.projectId,
                pairingToken = trimmedToken,
                revision = appInfo.flutterRevision.take(REVISION_LENGTH),
            ),
        )
    }

    /**
     * クエリを解く。
     *
     * `pairingToken` は base64url（設計 §4.2(a)）で、`%` は現れない。
     * ただし将来の値のために percent-decode は通しておく。
     */
    private fun decodeQuery(query: String): Map<String, String> {
        val result = HashMap<String, String>()
        for (pair in query.split('&')) {
            if (pair.isEmpty()) continue
            val separator = pair.indexOf('=')
            if (separator <= 0) continue
            val key = pair.substring(0, separator)
            // 同じキーが2度出たら最初を採る。後から上書きさせない。
            if (result.containsKey(key)) continue
            result[key] = percentDecode(pair.substring(separator + 1))
        }
        return result
    }

    private fun percentDecode(value: String): String {
        if (!value.contains('%')) {
            return value
        }
        val bytes = java.io.ByteArrayOutputStream(value.length)
        var i = 0
        while (i < value.length) {
            val c = value[i]
            if (c == '%' && i + 2 < value.length) {
                val hex = value.substring(i + 1, i + 3).toIntOrNull(16)
                if (hex != null) {
                    bytes.write(hex)
                    i += 3
                    continue
                }
            }
            bytes.write(c.code)
            i++
        }
        return bytes.toString(Charsets.UTF_8.name())
    }
}
