package dev.fluse.runtime

import android.app.Activity
import android.app.Application
import android.os.Bundle
import java.lang.ref.WeakReference
import java.util.concurrent.CopyOnWriteArraySet

/**
 * 今どの Activity が前に出ているかを追う。
 *
 * **オーバーレイとバッジは Dart に依存できない。** コンパイルエラーで
 * Dart isolate が起動しない状態でも出す必要がある（設計 §5.2）。
 * Flutter の側から画面を借りられないので、Android の Activity を直に掴む。
 *
 * `FluseActivityLifecycle`（起動時の一度きりの分岐）とは分けてある。
 * あちらは一度で終わる判定、こちらはアプリが動いている間ずっと続く。
 */
internal object FluseForeground : Application.ActivityLifecycleCallbacks {
    /** **強参照で持たない。** 掴んだままだと Activity が解放されない。 */
    private var current: WeakReference<Activity>? = null

    private val watchers = CopyOnWriteArraySet<Watcher>()

    /** 前に出ている Activity。無ければ null。 */
    val activity: Activity? get() = current?.get()

    /** 前面が入れ替わったことを知りたい側。 */
    interface Watcher {
        fun onForeground(activity: Activity)

        fun onBackground()
    }

    fun addWatcher(watcher: Watcher) {
        watchers.add(watcher)
        activity?.let { watcher.onForeground(it) }
    }

    fun removeWatcher(watcher: Watcher) {
        watchers.remove(watcher)
    }

    override fun onActivityResumed(activity: Activity) {
        // **ペアリング画面には重ねない。** QR を隠してしまうと、
        // エラーを直すために繋ぎ直すこともできなくなる。
        if (activity is FluseConnectActivity) {
            clear()
            return
        }
        current = WeakReference(activity)
        watchers.forEach { it.onForeground(activity) }
    }

    override fun onActivityPaused(activity: Activity) {
        if (current?.get() === activity) {
            clear()
        }
    }

    override fun onActivityDestroyed(activity: Activity) {
        if (current?.get() === activity) {
            clear()
        }
    }

    private fun clear() {
        current = null
        watchers.forEach { it.onBackground() }
    }

    override fun onActivityCreated(
        activity: Activity,
        savedInstanceState: Bundle?,
    ) = Unit

    override fun onActivityStarted(activity: Activity) = Unit

    override fun onActivityStopped(activity: Activity) = Unit

    override fun onActivitySaveInstanceState(
        activity: Activity,
        outState: Bundle,
    ) = Unit
}
