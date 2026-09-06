package dev.fluse.runtime

import android.app.Activity
import android.graphics.PixelFormat
import android.util.Log
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager

/**
 * 前面の Activity に View を重ねる。
 *
 * **`TYPE_APPLICATION_OVERLAY` は使わない。** `SYSTEM_ALERT_WINDOW` の
 * 許可を求めることになり、利用者のマニフェストに手を入れずに済ませる、
 * という前提（設計 §2.2.5）が崩れる。Activity のウィンドウトークンを
 * 借りたサブウィンドウなら、追加の許可は要らない。
 *
 * 前面が入れ替わったら追いかける。画面を移っただけでエラーが消えると、
 * 何が起きたのか分からなくなる。
 */
internal class FluseWindowLayer(
    private val name: String,
    private val gravity: Int,
    private val fullscreen: Boolean,
    private val create: (Activity) -> View,
) : FluseForeground.Watcher {
    private var attachedTo: Activity? = null
    private var view: View? = null

    /** 出すべき状態か。前面が入れ替わった時に、これを見て貼り直す。 */
    private var wanted = false

    /** 貼り直した View に中身を書き戻すための手。 */
    var render: ((View) -> Unit)? = null

    fun show() {
        wanted = true
        FluseForeground.activity?.let { attach(it) }
    }

    fun hide() {
        wanted = false
        detach()
    }

    /** 出したまま中身だけ書き換える。 */
    fun update() {
        view?.let { target -> render?.invoke(target) }
    }

    override fun onForeground(activity: Activity) {
        if (!wanted) {
            return
        }
        if (attachedTo === activity) {
            return
        }
        detach()
        attach(activity)
    }

    override fun onBackground() = detach()

    private fun attach(activity: Activity) {
        if (attachedTo != null) {
            return
        }
        // View は必ずメインスレッドで触る。制御メッセージは別スレッドで届く。
        activity.runOnUiThread {
            if (attachedTo != null || !wanted) {
                return@runOnUiThread
            }
            val created =
                try {
                    create(activity)
                } catch (e: Exception) {
                    Log.w(FluseRuntimePlugin.TAG, "$name を組み立てられませんでした: $e")
                    return@runOnUiThread
                }
            render?.invoke(created)

            if (addToWindow(activity, created) || addToContent(activity, created)) {
                attachedTo = activity
                view = created
            }
        }
    }

    private fun addToWindow(
        activity: Activity,
        target: View,
    ): Boolean {
        val token = activity.window?.decorView?.windowToken ?: return false
        val size =
            if (fullscreen) {
                WindowManager.LayoutParams.MATCH_PARENT
            } else {
                WindowManager.LayoutParams.WRAP_CONTENT
            }
        val params =
            WindowManager.LayoutParams(
                size,
                size,
                // Activity のトークンを持つサブウィンドウ。許可は要らない。
                WindowManager.LayoutParams.TYPE_APPLICATION_PANEL,
                // 全面の時だけ操作を受け止める。バッジは背後を触れるままにする。
                if (fullscreen) {
                    0
                } else {
                    WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL
                },
                PixelFormat.TRANSLUCENT,
            ).apply {
                this.token = token
                this.gravity = this@FluseWindowLayer.gravity
            }
        return try {
            activity.windowManager.addView(target, params)
            true
        } catch (e: Exception) {
            Log.w(FluseRuntimePlugin.TAG, "$name をウィンドウへ足せませんでした: $e")
            false
        }
    }

    /** ウィンドウへ足せない端末のための逃げ道。 */
    private fun addToContent(
        activity: Activity,
        target: View,
    ): Boolean =
        try {
            val size =
                if (fullscreen) {
                    ViewGroup.LayoutParams.MATCH_PARENT
                } else {
                    ViewGroup.LayoutParams.WRAP_CONTENT
                }
            activity.addContentView(target, ViewGroup.LayoutParams(size, size))
            true
        } catch (e: Exception) {
            Log.w(FluseRuntimePlugin.TAG, "$name を画面へ足せませんでした: $e")
            false
        }

    private fun detach() {
        val activity = attachedTo ?: return
        val target = view ?: return
        attachedTo = null
        view = null
        activity.runOnUiThread {
            try {
                if (target.parent === activity.window?.decorView?.parent ||
                    target.windowToken != null
                ) {
                    activity.windowManager.removeViewImmediate(target)
                }
            } catch (e: Exception) {
                // addContentView で足した場合はここに来る。親から外す。
                (target.parent as? ViewGroup)?.removeView(target)
            }
        }
    }

    companion object {
        /** バッジを置く隅。右下は Flutter の debug バナーと重ならない。 */
        const val BADGE_GRAVITY = Gravity.BOTTOM or Gravity.END
    }
}
