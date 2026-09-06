package dev.fluse.protocol

/** トンネルフレームの種別（設計 §2.2.1）。 */
enum class TunnelOpcode(val value: Int) {
    /** 新しいストリームを開く。 */
    OPEN(0x01),

    /** データ本体。 */
    DATA(0x02),

    /** ストリームを閉じる。 */
    CLOSE(0x03),

    ;

    /** Dart 側の enum 名と揃えたワイヤ表現（ゴールデンの `opcode`）。 */
    val wireName: String get() = name.lowercase()

    companion object {
        fun tryParse(value: Int): TunnelOpcode? = entries.firstOrNull { it.value == value }

        fun tryParseName(name: String): TunnelOpcode? =
            entries.firstOrNull { it.wireName == name }
    }
}

/**
 * WebSocket の binary frame に載せる TCP トンネルのフレーム（設計 §2.2.1）。
 *
 * ```text
 * byte0      : opcode  0x01=open, 0x02=data, 0x03=close
 * byte1..4   : streamId (uint32 big-endian)
 * byte5..    : payload (data時のみ)
 * ```
 *
 * **VM Service のプロトコルは一切解釈しない**（設計 §10-3）。
 *
 * Dart 側の `TunnelFrame` と完全に同じ表現でなければならない。
 * 検証は `packages/fluse_protocol/test/fixtures/wire_golden.json` を
 * 両実装が読むことで担保する。
 */
class TunnelFrame(
    val opcode: TunnelOpcode,
    /** ストリームの識別子。uint32 なので Kotlin では [Long] で持つ。 */
    val streamId: Long,
    /** 本体。`data` 以外では空。 */
    val payload: ByteArray = EMPTY,
) {
    companion object {
        private val EMPTY = ByteArray(0)

        /** ヘッダの長さ（opcode 1バイト + streamId 4バイト）。 */
        const val HEADER_LENGTH = 5

        /** `streamId` の最大値。uint32 なので 0xFFFFFFFF。 */
        const val MAX_STREAM_ID = 0xFFFFFFFFL

        /**
         * 1フレームに載せられる payload の上限（1 MiB）。
         *
         * 送信側はこれを超える前に分割する責務がある。
         */
        const val MAX_PAYLOAD_LENGTH = 1024 * 1024

        /** ストリームを開くフレーム。 */
        fun open(streamId: Long): TunnelFrame = TunnelFrame(TunnelOpcode.OPEN, streamId)

        /** データを運ぶフレーム。 */
        fun data(streamId: Long, payload: ByteArray): TunnelFrame =
            TunnelFrame(TunnelOpcode.DATA, streamId, payload)

        /** ストリームを閉じるフレーム。 */
        fun close(streamId: Long): TunnelFrame = TunnelFrame(TunnelOpcode.CLOSE, streamId)

        fun decode(bytes: ByteArray): TunnelFrame {
            if (bytes.size < HEADER_LENGTH) {
                throw FluseProtocolException(
                    "トンネルフレームが短すぎます: ${bytes.size} バイト（最低 $HEADER_LENGTH バイト必要）",
                )
            }

            val opcode = TunnelOpcode.tryParse(bytes[0].toInt() and 0xFF)
                ?: throw FluseProtocolException(
                    "未知の opcode: 0x%02x".format(bytes[0].toInt() and 0xFF),
                )

            val payloadLength = bytes.size - HEADER_LENGTH
            if (payloadLength > MAX_PAYLOAD_LENGTH) {
                // コピーする前に弾く。長さを信じて確保すると、壊れた相手に
                // メモリを一気に取らせられる。
                throw FluseProtocolException(
                    "payload が上限を超えています: $payloadLength バイト（上限 $MAX_PAYLOAD_LENGTH）",
                )
            }

            // Kotlin の Byte は符号付き。マスクせずに組み立てると
            // streamId が負になり、別のストリームを指す。
            val streamId =
                ((bytes[1].toLong() and 0xFF) shl 24) or
                    ((bytes[2].toLong() and 0xFF) shl 16) or
                    ((bytes[3].toLong() and 0xFF) shl 8) or
                    (bytes[4].toLong() and 0xFF)

            val payload =
                if (payloadLength == 0) EMPTY else bytes.copyOfRange(HEADER_LENGTH, bytes.size)

            if (opcode != TunnelOpcode.DATA && payload.isNotEmpty()) {
                throw FluseProtocolException(
                    "${opcode.wireName} フレームに payload が付いています（${payload.size} バイト）",
                )
            }

            return TunnelFrame(opcode, streamId, payload)
        }
    }

    fun encode(): ByteArray {
        if (streamId < 0 || streamId > MAX_STREAM_ID) {
            throw FluseProtocolException("streamId が uint32 の範囲外です: $streamId")
        }
        if (opcode != TunnelOpcode.DATA && payload.isNotEmpty()) {
            // open / close に本体を載せると、受け側の解釈が opcode と食い違う。
            throw FluseProtocolException(
                "${opcode.wireName} フレームに payload は載せられません（${payload.size} バイト）",
            )
        }
        if (payload.size > MAX_PAYLOAD_LENGTH) {
            throw FluseProtocolException(
                "payload が上限を超えています: ${payload.size} バイト" +
                    "（上限 $MAX_PAYLOAD_LENGTH）。送信側で分割してください",
            )
        }

        val bytes = ByteArray(HEADER_LENGTH + payload.size)
        bytes[0] = opcode.value.toByte()
        // big-endian。バイト順を取り違えると streamId が別のストリームを指す。
        bytes[1] = ((streamId shr 24) and 0xFF).toByte()
        bytes[2] = ((streamId shr 16) and 0xFF).toByte()
        bytes[3] = ((streamId shr 8) and 0xFF).toByte()
        bytes[4] = (streamId and 0xFF).toByte()
        payload.copyInto(bytes, HEADER_LENGTH)
        return bytes
    }

    override fun toString(): String =
        "TunnelFrame(${opcode.wireName}, stream: $streamId, ${payload.size}バイト)"
}
