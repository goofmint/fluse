package dev.fluse.runtime

import android.app.Activity
import android.graphics.Color
import android.view.Gravity
import android.view.View
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import dev.fluse.protocol.FluseMessage

/**
 * コンパイルエラーの赤画面（設計 §5.2）。
 *
 * **Dart に依存しない。** コンパイルが通らなければ Dart isolate は
 * 起動せず、Flutter 側からは何も描けない。エラーを出せないまま白い画面が
 * 残るのが一番困るので、Android の View で直に重ねる。
 */
internal class FluseErrorOverlay(
    private val layerFactory: (String, Int, Boolean, (Activity) -> View) -> FluseWindowLayer =
        ::FluseWindowLayer,
) : FluseConnectionListener {
    private val layer =
        layerFactory("エラー表示", Gravity.CENTER, true, ::createView).also {
            it.render = ::renderInto
        }

    /** 今出している中身。前面が入れ替わった時に書き戻す。 */
    @Volatile
    private var content: FluseOverlayContent? = null

    /** 前面の入れ替わりを追い始める。 */
    fun start() {
        FluseForeground.addWatcher(layer)
    }

    override fun onMessage(message: FluseMessage) {
        when (val command = FluseOverlayState.of(message)) {
            is FluseOverlayCommand.Show -> {
                content = command.content
                layer.show()
                layer.update()
            }

            FluseOverlayCommand.Hide -> {
                // compileOk で自動的に消す。利用者に閉じさせない。
                content = null
                layer.hide()
            }

            FluseOverlayCommand.Ignore -> Unit
        }
    }

    /**
     * 切れても消さない。
     *
     * サーバが落ちた時に赤画面まで消えると、直前に何が起きていたのかが
     * 分からなくなる。次の `compileOk` まで出したままにする。
     */
    override fun onDisconnected() = Unit

    override fun onConnected(sessionId: String) = Unit

    override fun onRejected(
        code: String,
        message: String,
    ) = Unit

    override fun onNeedsPairing(reason: String) = Unit

    // ---------------------------------------------------------------- View

    private fun createView(activity: Activity): View {
        val root =
            LinearLayout(activity).apply {
                orientation = LinearLayout.VERTICAL
                setBackgroundColor(BACKGROUND)
                // **背後へ通さない。** 触れてしまうと、壊れたままの画面を
                // 操作できてしまい、何が起きているのか分からなくなる。
                isClickable = true
                isFocusable = true
                setPadding(PADDING, PADDING, PADDING, PADDING)
            }

        root.addView(
            TextView(activity).apply {
                id = SUMMARY_ID
                setTextColor(Color.WHITE)
                textSize = SUMMARY_SIZE
                setPadding(0, 0, 0, PADDING)
            },
        )

        val scroll = ScrollView(activity)
        scroll.addView(
            TextView(activity).apply {
                id = DETAIL_ID
                setTextColor(Color.WHITE)
                textSize = DETAIL_SIZE
                // 等幅にすると file:line:col が縦に揃って読みやすい。
                typeface = android.graphics.Typeface.MONOSPACE
            },
        )
        root.addView(scroll)
        return root
    }

    private fun renderInto(view: View) {
        val shown = content ?: return
        view.findViewById<TextView>(SUMMARY_ID)?.text = shown.summary
        view.findViewById<TextView>(DETAIL_ID)?.text = shown.lines.joinToString("\n\n")
    }

    private companion object {
        /** 赤。利用者のアプリのテーマに関係なく同じ見た目にする。 */
        const val BACKGROUND = 0xFFB00020.toInt()
        const val PADDING = 48
        const val SUMMARY_SIZE = 18f
        const val DETAIL_SIZE = 12f

        // View を組み立てで作るため、id はここで決める。R には無い。
        const val SUMMARY_ID = 0x0F150E01
        const val DETAIL_ID = 0x0F150E02
    }
}
