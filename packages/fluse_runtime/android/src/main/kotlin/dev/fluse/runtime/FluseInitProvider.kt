package dev.fluse.runtime

import android.app.Activity
import android.app.Application
import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.pm.ApplicationInfo
import android.database.Cursor
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.util.concurrent.Executor
import java.util.concurrent.Executors
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

        // **release ビルドでは何もしない。** dev_dependency のプラグインは
        // debug にしか入らない想定だが、マニフェストに載る Provider は
        // 構成次第で release にも残りうる。VM Service が無い以上プレビュー
        // は成立しないので、lifecycle も掴まない。
        if (!isDebuggable(application)) {
            return true
        }

        val callbacks = FluseActivityLifecycle(application)
        application.registerActivityLifecycleCallbacks(callbacks)
        lifecycle = callbacks
        Log.i(TAG, "自動初期化しました")
        return true
    }

    /** デバッグ可能なビルドか。 */
    private fun isDebuggable(application: Application): Boolean =
        (application.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0

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
    private val handlerFactory: (Activity, FluseStore) -> StartupHandler = ::ConnectingStartupHandler,
    private val background: Executor = defaultBackground,
    private val main: Executor = MainThreadExecutor,
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

        // **メインスレッドで開かない。** Android Keystore と
        // EncryptedSharedPreferences の初期化は初回に時間がかかる。
        // ここで待つと最初の画面がその分だけ遅れる。
        background.execute {
            val decision =
                try {
                    val store = storeFactory(application)
                    Decision(
                        store = store,
                        path = FluseStartup.resolve(store.hasDeviceToken(), store.hasLastServer()),
                        host = store.lastHost,
                        port = store.lastPort,
                    )
                } catch (e: Exception) {
                    // 暗号ストアが開けない端末がありうる。プレビューは
                    // 諦めるが、アプリは動かす。
                    //
                    // **やり直せるようにしておく。** started を立てたまま
                    // 戻ると、次に画面が前に出ても分岐に入れなくなる。
                    Log.w(TAG, "設定を読めませんでした: $e")
                    started.set(false)
                    null
                } ?: return@execute

            main.execute {
                // 読んでいる間に画面が畳まれていることがある。
                // 消えた Activity から画面を出そうとしても届かない。
                if (activity.isFinishing) {
                    return@execute
                }

                val handler = handlerFactory(activity, decision.store)
                when (decision.path) {
                    StartupPath.RECONNECT -> {
                        val host = decision.host
                        if (host == null) {
                            // hasLastServer() が true ならここには来ない。
                            handler.pair()
                            return@execute
                        }
                        handler.reconnect(host, decision.port)
                    }

                    StartupPath.PAIR -> handler.pair()
                }
            }
        }
    }

    /** 背景で決めた行き先。 */
    private data class Decision(
        val store: FluseStore,
        val path: StartupPath,
        val host: String?,
        val port: Int,
    )

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

        /**
         * 暗号ストアを開くための1本。
         *
         * 起動時に一度使うだけなので、単一スレッドで足りる。
         */
        val defaultBackground: Executor =
            Executors.newSingleThreadExecutor { runnable ->
                Thread(runnable, "fluse-init").apply { isDaemon = true }
            }
    }
}

/** メインスレッドへ戻すための [Executor]。 */
internal object MainThreadExecutor : Executor {
    private val handler = Handler(Looper.getMainLooper())

    override fun execute(command: Runnable) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            command.run()
            return
        }
        handler.post(command)
    }
}

/**
 * 分岐した先を [FluseConnection] に繋ぐ。
 *
 * ペアリング画面（`FluseConnectActivity`）は Task 4.4。ここでは
 * 差し込み口だけを残す。
 */
internal class ConnectingStartupHandler(
    private val activity: Activity,
    private val store: FluseStore,
) : StartupHandler {
    override fun reconnect(
        host: String,
        port: Int,
    ) {
        val connection =
            try {
                FluseConnection.getOrCreate(activity.application, store)
            } catch (e: Exception) {
                // **握り潰さない。** assets の素性が無ければ `hello` を
                // 組み立てられず、プレビューは成立しない。ただしアプリ自体は
                // 動かす。fluse は dev_dependency であって本体ではない。
                Log.e(FluseRuntimePlugin.TAG, "接続の準備ができませんでした: $e")
                return
            }
        // **接続より先に届いた分を渡す。** 渡さないと、受理できたのに
        // 送るものが無い状態になり、初回の vmServiceReady が落ちる。
        FluseRuntimePlugin.latestVmServiceUri?.let { connection.vmServiceReady(it) }
        connection.connect(FluseEndpoint(host, port))
    }

    override fun pair() {
        Log.i(FluseRuntimePlugin.TAG, "ペアリング画面を出します")
        activity.startActivity(FluseConnectActivity.intentFor(activity))
    }
}
