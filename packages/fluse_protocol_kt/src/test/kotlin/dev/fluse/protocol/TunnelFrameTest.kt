package dev.fluse.protocol

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull

class TunnelFrameTest {
    @Test
    fun `data フレームが往復する`() {
        val frame = TunnelFrame.data(42, byteArrayOf(1, 2, 3, 0xFF.toByte()))

        val restored = TunnelFrame.decode(frame.encode())

        assertEquals(TunnelOpcode.DATA, restored.opcode)
        assertEquals(42L, restored.streamId)
        assertContentEquals(byteArrayOf(1, 2, 3, 0xFF.toByte()), restored.payload)
    }

    @Test
    fun `streamId は符号なしで扱う`() {
        // Kotlin の Byte は符号付き。マスクを忘れると負になる。
        val restored = TunnelFrame.decode(TunnelFrame.open(TunnelFrame.MAX_STREAM_ID).encode())

        assertEquals(0xFFFFFFFFL, restored.streamId)
        assertEquals(true, restored.streamId > 0)
    }

    @Test
    fun `最上位ビットのみの streamId`() {
        assertEquals(
            0x80000000L,
            TunnelFrame.decode(TunnelFrame.open(0x80000000L).encode()).streamId,
        )
    }

    @Test
    fun `payload 0バイトの data フレーム`() {
        val restored = TunnelFrame.decode(TunnelFrame.data(7, ByteArray(0)).encode())

        assertEquals(TunnelOpcode.DATA, restored.opcode)
        assertEquals(0, restored.payload.size)
    }

    @Test
    fun `5バイト未満は失敗する`() {
        for (length in 0 until TunnelFrame.HEADER_LENGTH) {
            assertFailsWith<FluseProtocolException>("$length バイト") {
                TunnelFrame.decode(ByteArray(length) { 0x02 })
            }
        }
    }

    @Test
    fun `未知の opcode は失敗する`() {
        val error = assertFailsWith<FluseProtocolException> {
            TunnelFrame.decode(byteArrayOf(0x09, 0, 0, 0, 1))
        }

        assertEquals(true, error.message?.contains("0x09"))
    }

    @Test
    fun `open に payload が付いていれば失敗する`() {
        assertFailsWith<FluseProtocolException> {
            TunnelFrame.decode(byteArrayOf(0x01, 0, 0, 0, 1, 0xFF.toByte()))
        }
        assertFailsWith<FluseProtocolException> {
            TunnelFrame(TunnelOpcode.CLOSE, 1, byteArrayOf(1)).encode()
        }
    }

    @Test
    fun `範囲外の streamId は失敗する`() {
        assertFailsWith<FluseProtocolException> {
            TunnelFrame.open(TunnelFrame.MAX_STREAM_ID + 1).encode()
        }
        assertFailsWith<FluseProtocolException> { TunnelFrame.open(-1).encode() }
    }

    @Test
    fun `上限を超える payload は失敗する`() {
        assertFailsWith<FluseProtocolException> {
            TunnelFrame.data(1, ByteArray(TunnelFrame.MAX_PAYLOAD_LENGTH + 1)).encode()
        }
        assertFailsWith<FluseProtocolException> {
            TunnelFrame.decode(
                ByteArray(TunnelFrame.HEADER_LENGTH + TunnelFrame.MAX_PAYLOAD_LENGTH + 1).also {
                    it[0] = 0x02
                },
            )
        }
    }

    @Test
    fun `上限ちょうどは通る`() {
        val payload = ByteArray(TunnelFrame.MAX_PAYLOAD_LENGTH) { 0x41 }

        assertEquals(
            TunnelFrame.MAX_PAYLOAD_LENGTH,
            TunnelFrame.decode(TunnelFrame.data(1, payload).encode()).payload.size,
        )
    }

    @Test
    fun `未知の opcode 値は null になる`() {
        assertNull(TunnelOpcode.tryParse(0x00))
        assertNull(TunnelOpcode.tryParse(0xFF))
    }
}
