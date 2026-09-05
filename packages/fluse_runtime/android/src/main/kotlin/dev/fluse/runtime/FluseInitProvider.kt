package dev.fluse.runtime

import android.app.Activity
import android.app.Application
import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.os.Bundle
import android.util.Log
import java.util.concurrent.atomic.AtomicBoolean

/**
 * プロセス起動時に自分から動き出すための入口（設計 §2.2.5）。
 *
 * **データは何も持たない。** `ContentProvider` を使うのは、
 * 利用者のマニフェストに手を入れずに初期化の機会を得るため。
 * Application クラスの差し替えを求めると、既に独自の Application を
 * 持つアプリで衝突する。
 *
 * `ContentProvider.onCreate` は `Application.onCreate` より前に呼ばれる。
 * Flutter エンジンが立つより早く、確実に一度だけ通る。
 */
class FluseInitProvider : ContentProvider() {
    companion object {
        private const val TAG = FluseRuntimePlugin.TAG

        /**
         * 直近に作られた lifecycle の監視役。
         *
         * Task 4.3 以降が実処理を差し込むための入口。
         */
        @Volatile
        var lifecycle: FluseActivityLifecycle? = null
            private set
    }

    override fun onCreate(): Boolean {
        val application = context?.applicationContext as? Application
        if (application == null) {
            // 起動のごく初期に context が無いことがある。ここで落とすと
            // アプリ自体が起動しない。プレビューを諦める方がまし。
            Log.w(TAG, "Application を取得できませんでした。自動初期化を行いません")
            return true
        }

        val callbacks = FluseActivityLifecycle(application)
        application.registerActivityLifecycleCallbacks(callbacks)
        lifecycle = callbacks
        Log.i(TAG, "自動初期化しました")
        return true
    }

    // --- ContentProvider としては何も提供しない。 ---

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor? = null

    override fun getType(uri: Uri): String? = null

    override fun insert(
        uri: Uri,
        values: ContentValues?,
    ): Uri? = null

    override fun delete(
        uri: Uri,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int = 0

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int = 0
}

/**
 * 最初の Activity が前に出た時に一度だけ分岐する。
 *
 * `onCreate` ではなく `onResume` を使う。ペアリング画面を出すには
 * 前面にいる Activity が要る。作られただけの Activity から起動すると、
 * 端末によっては表示されない。
 */
class FluseActivityLifecycle internal constructor(
    private val application: Application,
    private val storeFactory: (Context) -> FluseStore = FluseStore::open,
    private val handlerFactory: (Activity) -> StartupHandler = ::LoggingStartupHandler,
) : Application.ActivityLifecycleCallbacks {
    private val started = AtomicBoolean(false)

    /** 分岐を済ませたか。テストと診断のために公開する。 */
    val hasStarted: Boolean get() = started.get()

    override fun onActivityResumed(activity: Activity) {
        // **一度だけ。** 画面を行き来するたびに繋ぎ直すと、その都度
        // セッションが張り替わってリロードの途中経過が失われる。
        if (!started.compareAndSet(false, true)) {
            return
        }

        val store =
            try {
                storeFactory(application)
            } catch (e: Exception) {
                // 暗号ストアが開けない端末がありうる。プレビューは
                // 諦めるが、アプリは動かす。
                Log.w(TAG, "設定を読めませんでした: $e")
                return
            }

        val handler = handlerFactory(activity)
        when (FluseStartup.resolve(store.hasDeviceToken(), store.hasLastServer())) {
            StartupPath.RECONNECT -> {
                val host = store.lastHost
                val port = store.lastPort
                if (host == null) {
                    // hasLastServer() が true ならここには来ない。
                    handler.pair()
                    return
                }
                handler.reconnect(host, port)
            }

            StartupPath.PAIR -> handler.pair()
        }
    }

    override fun onActivityCreated(
        activity: Activity,
        savedInstanceState: Bundle?,
    ) = Unit

    override fun onActivityStarted(activity: Activity) = Unit

    override fun onActivityPaused(activity: Activity) = Unit

    override fun onActivityStopped(activity: Activity) = Unit

    override fun onActivitySaveInstanceState(
        activity: Activity,
        outState: Bundle,
    ) = Unit

    override fun onActivityDestroyed(activity: Activity) = Unit

    private companion object {
        const val TAG = FluseRuntimePlugin.TAG
    }
}

/**
 * 分岐したことを記録するだけの仮実装。
 *
 * 実処理は Task 4.3（`FluseConnection`）と Task 4.4
 * （`FluseConnectActivity`）で入れ替える。
 */
internal class LoggingStartupHandler(
    @Suppress("UNUSED_PARAMETER") activity: Activity,
) : StartupHandler {
    override fun reconnect(
        host: String,
        port: Int,
    ) {
        Log.i(FluseRuntimePlugin.TAG, "前回のサーバへ繋ぎ直します: $host:$port（Task 4.3 で実装）")
    }

    override fun pair() {
        Log.i(FluseRuntimePlugin.TAG, "ペアリングが必要です（Task 4.4 で実装）")
    }
}
