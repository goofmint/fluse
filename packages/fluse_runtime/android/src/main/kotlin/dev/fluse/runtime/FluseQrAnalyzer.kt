package dev.fluse.runtime

import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.MultiFormatReader
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.common.HybridBinarizer
import java.util.EnumMap
import java.util.concurrent.atomic.AtomicBoolean

/**
 * カメラの絵から QR を読む。
 *
 * `zxing-android-embedded` は使わない。minSdk を引き上げるうえ、画面まで
 * 持ち込むことになる。要るのはデコードだけ。
 */
internal class FluseQrAnalyzer(
    private val onDecoded: (String) -> Unit,
) : ImageAnalysis.Analyzer {
    private val reader =
        MultiFormatReader().apply {
            // QR だけに絞る。他の形式まで試すと1コマあたりが重くなる。
            val hints = EnumMap<DecodeHintType, Any>(DecodeHintType::class.java)
            hints[DecodeHintType.POSSIBLE_FORMATS] = listOf(com.google.zxing.BarcodeFormat.QR_CODE)
            setHints(hints)
        }

    /** 一度読めたら止める。同じ QR で何度も繋ぎに行かせない。 */
    private val done = AtomicBoolean(false)

    override fun analyze(image: ImageProxy) {
        try {
            if (done.get()) {
                return
            }
            val text = decode(image) ?: return
            if (done.compareAndSet(false, true)) {
                onDecoded(text)
            }
        } finally {
            // **必ず閉じる。** 閉じ忘れると次のコマが来ず、画面が止まる。
            image.close()
        }
    }

    private fun decode(image: ImageProxy): String? {
        val luminance = luminanceOf(image) ?: return null
        val source =
            PlanarYUVLuminanceSource(
                luminance,
                image.width,
                image.height,
                0,
                0,
                image.width,
                image.height,
                false,
            )
        return try {
            reader.decodeWithState(BinaryBitmap(HybridBinarizer(source)))?.text
        } catch (e: Exception) {
            // 写っていないコマの方が多い。見つからないのは普通のこと。
            null
        } finally {
            reader.reset()
        }
    }

    /**
     * Y 平面（輝度）を隙間なく詰め直す。
     *
     * **`rowStride` は `width` と一致するとは限らない。** 端末によっては
     * 行の末尾に詰め物が入る。そのまま渡すと絵が斜めにずれて読めない。
     */
    private fun luminanceOf(image: ImageProxy): ByteArray? {
        val plane = image.planes.firstOrNull() ?: return null
        val buffer = plane.buffer
        buffer.rewind()

        val width = image.width
        val height = image.height
        val rowStride = plane.rowStride
        val pixelStride = plane.pixelStride

        if (rowStride == width && pixelStride == 1) {
            val dense = ByteArray(buffer.remaining())
            buffer.get(dense)
            return dense
        }

        val dense = ByteArray(width * height)
        val row = ByteArray(rowStride)
        for (y in 0 until height) {
            val available = minOf(rowStride, buffer.remaining())
            if (available <= 0) {
                return null
            }
            buffer.get(row, 0, available)
            if (pixelStride == 1) {
                System.arraycopy(row, 0, dense, y * width, minOf(width, available))
            } else {
                for (x in 0 until width) {
                    val at = x * pixelStride
                    if (at >= available) break
                    dense[y * width + x] = row[at]
                }
            }
        }
        return dense
    }
}
