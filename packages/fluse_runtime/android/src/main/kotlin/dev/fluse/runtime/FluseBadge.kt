package dev.fluse.runtime

import android.app.Activity
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.view.View
import android.widget.TextView
import dev.fluse.protocol.FluseMessage

/**
 * 画面隅の接続バッジ（設計 §2.2.5）。
 *
 * 繋がっているのかどうかが分からないまま「反映されない」と悩む時間を
 * 無くすために出す。押すとペアリング画面に戻る。
 */
internal class FluseBadge(
    main: java.util.concurrent.Executor = MainThreadExecutor,
) : FluseConnectionListener {
    private val layer =
        FluseWindowLayer("バッジ", FluseWindowLayer.BADGE_GRAVITY, false, ::createView, main).also {
            it.render = ::renderInto
        }

    /** 今の見え方。テストと診断のために読めるようにしてある。 */
    @Volatile
    var state = FluseBadgeState.CONNECTING
        private set

    /** 出し始める。接続の前から出す。繋がらないことも状態のうち。 */
    fun start() {
        FluseForeground.addWatcher(layer)
        layer.show()
    }

    override fun onConnected(sessionId: String) = moveTo(FluseBadgeState.CONNECTED)

    override fun onDisconnected() = moveTo(FluseBadgeState.DISCONNECTED)

    override fun onNeedsPairing(reason: String) = moveTo(FluseBadgeState.NEEDS_PAIRING)

    override fun onRejected(
        code: String,
        message: String,
    ) = moveTo(FluseBadgeState.REJECTED)

    override fun onMessage(message: FluseMessage) = Unit

    private fun moveTo(next: FluseBadgeState) {
        if (state == next) {
            return
        }
        state = next
        layer.update()
    }

    // ---------------------------------------------------------------- View

    private fun createView(activity: Activity): View =
        TextView(activity).apply {
            id = LABEL_ID
            setTextColor(Color.WHITE)
            textSize = TEXT_SIZE
            setPadding(PADDING_H, PADDING_V, PADDING_H, PADDING_V)
            background =
                GradientDrawable().apply {
                    cornerRadius = CORNER_RADIUS
                    // `state` は Drawable 側にもある。外の状態を指す。
                    setColor(colorOf(this@FluseBadge.state))
                }
            setOnClickListener {
                // 押したら繋ぎ直す道へ。**接続は切らない。** 繋がっている
                // のに触ってしまった時に、そこで止まってしまう。
                activity.startActivity(FluseConnectActivity.intentFor(activity))
            }
        }

    private fun renderInto(view: View) {
        val label = view.findViewById<TextView>(LABEL_ID) ?: return
        val current = state
        label.text = view.context.getString(textOf(current))
        (label.background as? GradientDrawable)?.setColor(colorOf(current))
    }

    private companion object {
        const val LABEL_ID = 0x0F150E03
        const val TEXT_SIZE = 10f
        const val PADDING_H = 24
        const val PADDING_V = 12
        const val CORNER_RADIUS = 24f

        /** 色だけで判じさせない。文言も併せて出す。 */
        fun colorOf(state: FluseBadgeState): Int =
            when (state) {
                FluseBadgeState.CONNECTED -> 0xCC1B5E20.toInt()
                FluseBadgeState.CONNECTING -> 0xCC424242.toInt()
                FluseBadgeState.DISCONNECTED -> 0xCCE65100.toInt()
                FluseBadgeState.NEEDS_PAIRING -> 0xCC0D47A1.toInt()
                FluseBadgeState.REJECTED -> 0xCCB00020.toInt()
            }

        fun textOf(state: FluseBadgeState): Int =
            when (state) {
                FluseBadgeState.CONNECTED -> R.string.fluse_badge_connected
                FluseBadgeState.CONNECTING -> R.string.fluse_badge_connecting
                FluseBadgeState.DISCONNECTED -> R.string.fluse_badge_disconnected
                FluseBadgeState.NEEDS_PAIRING -> R.string.fluse_badge_pairing
                FluseBadgeState.REJECTED -> R.string.fluse_badge_rejected
            }
    }
}
