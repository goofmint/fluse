package dev.fluse.runtime

import android.app.Application
import android.util.Log
import dev.fluse.protocol.AcceptMessage
import dev.fluse.protocol.CloseMessage
import dev.fluse.protocol.FLUSE_PROTOCOL_VERSION
import dev.fluse.protocol.FluseMessage
import dev.fluse.protocol.HelloMessage
import dev.fluse.protocol.PingMessage
import dev.fluse.protocol.RejectCode
import dev.fluse.protocol.RejectMessage
import dev.fluse.protocol.VmServiceReadyMessage
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import org.json.JSONObject

/** 待ってから実行する。テストでは時間を進めずに動かす。 */
internal fun interface RetryScheduler {
    fun schedule(
        delayMs: Long,
        action: () -> Unit,
    )
}

/** 接続の行方を受け取る側。表示（Task 4.5）と画面遷移（Task 4.4）が使う。 */
interface FluseConnectionListener {
    /** 受理された。 */
    fun onConnected(sessionId: String)

    /**
     * 断られた。**再試行しない。**
     *
     * どの理由も繋ぎ直しでは解けない（設計 §5.1）。
     */
    fun onRejected(
        code: String,
        message: String,
    )

    /** ペアリングからやり直す必要がある。 */
    fun onNeedsPairing(reason: String)

    /** 切れた。再接続は [FluseConnection] が自分で行う。 */
    fun onDisconnected()

    /**
     * 端末の設定で `ws://` が塞がれている（設計 §10-4）。
     *
     * 既定では何もしない。気にする側だけが受ければよい。
     */
    fun onCleartextBlocked(
        host: String,
        message: String,
    ) = Unit

    /** 受理後に届いた制御メッセージ。`reload` などは後続タスクが使う。 */
    fun onMessage(message: FluseMessage)
}

/**
 * サーバとの唯一の接続（設計 §2.2.5）。
 *
 * **Application スコープに置く。** Hot Restart は Dart isolate だけを
 * 作り直し、Android のプロセスは生きたままなので、接続を張り直さずに
 * 済ませられる（設計 §10-6）。Activity に持たせると画面が畳まれるたびに
 * セッションが切れ、リロードの途中経過が消える。
 */
class FluseConnection internal constructor(
    private val store: FluseStore,
    private val device: FluseDeviceInfo,
    private val appInfo: FluseAppInfo,
    private val socketFactory: FluseSocketFactory = OkHttpFluseSocketFactory(),
    private val scheduler: RetryScheduler = DefaultScheduler,
    private val backoff: FluseBackoff = FluseBackoff(),
) {
    companion object {
        private const val TAG = FluseRuntimePlugin.TAG

        /**
         * Application スコープの唯一のインスタンス。
         *
         * `FluseInitProvider.lifecycle` と同じ持ち方に揃えてある。
         */
        @Volatile
        var instance: FluseConnection? = null
            private set

        /**
         * 作るか、既にあればそれを返す。
         *
         * **作り直さない。** Hot Restart のたびに新しくすると、生きている
         * 接続を捨てて張り直すことになる。
         */
        fun getOrCreate(
            application: Application,
            store: FluseStore,
        ): FluseConnection {
            instance?.let { return it }
            synchronized(this) {
                instance?.let { return it }
                val created =
                    FluseConnection(
                        store = store,
                        device = FluseDeviceInfo.of(application, store),
                        appInfo = FluseAppInfo.load(application),
                    )
                instance = created
                return created
            }
        }

        /** テストのために差し替える。 */
        internal fun install(connection: FluseConnection?) {
            instance = connection
        }

        /** 起動時に一度使うだけなので単一スレッドで足りる。 */
        private val DefaultScheduler =
            object : RetryScheduler {
                private val executor: ScheduledExecutorService =
                    Executors.newSingleThreadScheduledExecutor { runnable ->
                        Thread(runnable, "fluse-reconnect").apply { isDaemon = true }
                    }

                override fun schedule(
                    delayMs: Long,
                    action: () -> Unit,
                ) {
                    executor.schedule(action, delayMs, TimeUnit.MILLISECONDS)
                }
            }
    }

    private val lock = Any()

    /** 繋ぎ先。[connect] が決める。 */
    private var endpoint: FluseEndpoint? = null

    /**
     * 初回ペアリングのトークン。
     *
     * **`deviceToken` と同時には送れない。** サーバは両方載った `hello` を
     * 誤りとして断る（`session_manager.authenticate`）。
     */
    private var pairingToken: String? = null

    private var socket: FluseSocket? = null

    /**
     * 今の接続の世代。
     *
     * **予約した再接続は取り消せない。** [connect] や [stop] で状況が
     * 変わった後に古い予約が動くと、生きているソケットを置き換えて
     * 二重のセッションになる。世代を見て、古い分は捨てる。
     *
     * 遅れて届くコールバックにも同じ番号を持たせてある。閉じた直後の
     * 通知が新しい接続の状態を消してしまうのを防ぐため。
     */
    private var generation = 0L

    /** 止めたら再接続しない。[connect] を呼び直すまで動かない。 */
    private var stopped = true

    /** `accept` を受け取った後だけ true。 */
    private var sessionId: String? = null

    /** `accept` が指定した heartbeat の間隔。診断のために持つ。 */
    var heartbeatIntervalMs: Long = 0
        private set

    /**
     * Dart から受け取った VM Service の URI。
     *
     * **接続前に届くことがある。** `flusePreviewMain` はアプリの起動と
     * 並行に走るため、`accept` より先に来る。受理できるまで持っておく。
     */
    private var pendingVmServiceUri: String? = null

    /** 今のセッションで送り終えた URI。同じ値なら送り直さない。 */
    private var sentVmServiceUri: String? = null

    /**
     * 出来事を受け取る面々。
     *
     * **1つに絞れない。** ペアリング画面・エラーオーバーレイ・バッジが
     * 同時に見ている。1枠にすると、後から入った側が前の側を追い出す。
     */
    private val listeners = java.util.concurrent.CopyOnWriteArraySet<FluseConnectionListener>()

    fun addListener(listener: FluseConnectionListener) {
        listeners.add(listener)
    }

    fun removeListener(listener: FluseConnectionListener) {
        listeners.remove(listener)
    }

    private fun notifyListeners(action: (FluseConnectionListener) -> Unit) {
        listeners.forEach(action)
    }

    /** 受理済みか。 */
    val isAuthenticated: Boolean get() = synchronized(lock) { sessionId != null }

    /**
     * 繋ぎに行く。
     *
     * [pairingToken] は QR から来た初回だけ渡す。2回目以降は保存済みの
     * `deviceToken` を使う。
     */
    fun connect(
        endpoint: FluseEndpoint,
        pairingToken: String? = null,
    ) {
        // **繋ぎに行く前に確かめる。** 塞がれていると OkHttp が平文を
        // 拒んで例外になるだけで、理由が出ない。バックオフで延々と
        // 繋ぎ直すことにもなる。
        if (!FluseCleartext.isPermitted(endpoint.host)) {
            val message = FluseCleartext.blockedMessage(endpoint.host)
            // **今の接続も予約も畳む。** ここで戻るだけだと、繋ぎ直しを
            // 待っている予約が古い繋ぎ先で動き出す。繋ぎ先を変えたのに
            // 前の相手へ繋ぎに行くことになる。
            synchronized(lock) {
                stopped = true
                generation++
                closeSocketLocked("平文が塞がれています")
            }
            Log.e(TAG, message)
            notifyListeners { it.onCleartextBlocked(endpoint.host, message) }
            return
        }

        val target =
            synchronized(lock) {
                closeSocketLocked("繋ぎ直します")
                this.endpoint = endpoint
                this.pairingToken = pairingToken
                stopped = false
                backoff.reset()
                // 進めた後の番号で開く。前置でないと1つ前の世代を渡してしまう。
                ++generation
            }
        openSocket(target)
    }

    /** 止める。以後は再接続しない。 */
    fun stop() {
        synchronized(lock) {
            stopped = true
            // 世代を進めて、予約済みの再接続と遅れて届く通知を無効にする。
            generation++
            closeSocketLocked("終了します")
        }
    }

    /**
     * VM Service が立ち上がったことを伝える（設計 §2.2.5）。
     *
     * **同じ URI で何度呼ばれても一度しか送らない。** Hot Restart のたびに
     * Dart 側の `main()` が作り直され、同じ URI が再送されるため。
     */
    fun vmServiceReady(uri: String) {
        val toSend =
            synchronized(lock) {
                pendingVmServiceUri = uri
                if (sessionId == null || uri == sentVmServiceUri) {
                    null
                } else {
                    sentVmServiceUri = uri
                    uri
                }
            }
        if (toSend == null) {
            return
        }
        Log.i(TAG, "VM Service を伝えます: ${FluseRuntimePlugin.maskAuthCode(toSend)}")
        send(VmServiceReadyMessage(toSend))
    }

    // ------------------------------------------------------------ 送受信

    private fun send(message: FluseMessage) {
        val current = synchronized(lock) { socket } ?: return
        current.sendText(message.toJson().toString())
    }

    private fun openSocket(forGeneration: Long) {
        val target =
            synchronized(lock) {
                if (stopped || generation != forGeneration) null else endpoint
            } ?: return

        val events = Events(forGeneration)
        val created = socketFactory.open(target.webSocketUrl(), events)
        synchronized(lock) {
            if (stopped || generation != forGeneration) {
                created.close("終了します")
                return
            }
            socket = created
        }

        // **繋がった通知は `socket` を入れる前に来ることがある。**
        // 先に来ていたら、ここで hello を送る。取りこぼすと名乗らないまま
        // 待ち続け、サーバから見れば無言の接続になる。
        events.attach()
    }

    private fun closeSocketLocked(reason: String) {
        socket?.close(reason)
        socket = null
        sessionId = null
        sentVmServiceUri = null
    }

    private fun sendHello() {
        val hello =
            synchronized(lock) {
                val pairing = pairingToken
                HelloMessage(
                    protocolVersion = FLUSE_PROTOCOL_VERSION.toLong(),
                    projectId = appInfo.projectId,
                    flutterRevision = appInfo.flutterRevision,
                    dartVersion = appInfo.dartVersion,
                    appVersion = appInfo.appVersion,
                    deviceId = device.deviceId,
                    deviceName = device.deviceName,
                    // 片方だけ載せる。両方載せるとサーバが誤りとして断る。
                    pairingToken = pairing,
                    deviceToken = if (pairing == null) store.deviceToken else null,
                )
            }
        send(hello)
    }

    private fun handleText(text: String) {
        val message =
            try {
                FluseMessage.fromJson(JSONObject(text))
            } catch (e: Exception) {
                // 読めないメッセージで接続ごと落とさない。次が読めるかもしれない。
                Log.w(TAG, "制御メッセージを解釈できません: $e")
                return
            }

        when (message) {
            is AcceptMessage -> handleAccept(message)
            is RejectMessage -> handleReject(message)
            // 受け取った値をそのまま返す。作り直すとサーバが RTT を測れない。
            is PingMessage -> send(message.toPong())
            is CloseMessage -> handleClose(message)
            else -> {
                if (!isAuthenticated) {
                    Log.w(TAG, "受理前の制御メッセージを無視しました: ${message.type}")
                    return
                }
                notifyListeners { it.onMessage(message) }
            }
        }
    }

    private fun handleAccept(accept: AcceptMessage) {
        val resend =
            synchronized(lock) {
                sessionId = accept.sessionId
                heartbeatIntervalMs = accept.heartbeatIntervalMs
                backoff.reset()

                // 発行されたら保存する。次回は QR を出さずに繋げる。
                accept.issuedDeviceToken?.let { store.deviceToken = it }

                // 繋ぎ直した先は前のセッションを知らない。送り直す。
                sentVmServiceUri = null
                pendingVmServiceUri
            }

        // 次に繋ぐときのために覚えておく。
        synchronized(lock) {
            endpoint?.let {
                store.lastHost = it.host
                store.lastPort = it.port
            }
            // 使い切った。以後は deviceToken で繋ぐ。
            pairingToken = null
        }

        Log.i(TAG, "接続しました: ${accept.sessionId}")
        notifyListeners { it.onConnected(accept.sessionId) }
        resend?.let { vmServiceReady(it) }
    }

    private fun handleReject(reject: RejectMessage) {
        // **繋ぎ直しでは解けない。** どの理由も端末かサーバの構成違いで、
        // 待って再送しても同じ答えが返る（設計 §5.1）。
        synchronized(lock) {
            stopped = true
            // 遅れて届く通知で再接続が動き出さないようにする。
            generation++
            closeSocketLocked("断られました")
        }
        Log.w(TAG, "接続を断られました: ${reject.code}")

        if (reject.knownCode == RejectCode.AUTH_FAILED) {
            // 持っているトークンでは通らない。残すと次回も同じ所で止まる。
            store.deviceToken = null
            notifyListeners { it.onNeedsPairing(reject.message) }
            return
        }
        notifyListeners { it.onRejected(reject.code, reject.message) }
    }

    private fun handleClose(close: CloseMessage) {
        Log.i(TAG, "サーバから切断されました: ${close.code}")
        // **ソケットも閉じる。** 残すと OkHttp 側の通知が後から来て、
        // 切断処理とバックオフが二重に走る。
        val current =
            synchronized(lock) {
                socket?.close("サーバが切断しました")
                generation
            }
        // 正常終了でも繋ぎ直す。サーバが再起動しただけかもしれない。
        onDisconnected(current)
    }

    private fun onDisconnected(forGeneration: Long) {
        val delayMs =
            synchronized(lock) {
                // **古い接続の通知では何も消さない。** 閉じた直後の通知は
                // 新しいソケットが入った後に届くことがあり、そこで消すと
                // 生きている接続の状態が失われる。
                if (generation != forGeneration) {
                    return
                }
                socket = null
                sessionId = null
                sentVmServiceUri = null
                if (stopped) null else backoff.next()
            }
        notifyListeners { it.onDisconnected() }
        if (delayMs == null) {
            return
        }
        Log.i(TAG, "${delayMs}ms 後に繋ぎ直します")
        scheduler.schedule(delayMs) { openSocket(forGeneration) }
    }

    /**
     * 1本のソケットから来る出来事。
     *
     * 開いた世代を持たせてある。後から届いた古い世代の通知は捨てる。
     */
    private inner class Events(
        private val forGeneration: Long,
    ) : FluseSocketEvents {
        private val gate = Any()
        private var opened = false
        private var attached = false

        /** [openSocket] が `socket` を入れ終えたら呼ぶ。 */
        fun attach() {
            val ready =
                synchronized(gate) {
                    attached = true
                    opened
                }
            if (ready) {
                sendHello()
            }
        }

        override fun onOpen() {
            val ready =
                synchronized(gate) {
                    opened = true
                    attached
                }
            if (ready) {
                sendHello()
            }
        }

        override fun onText(text: String) {
            if (isStale()) return
            handleText(text)
        }

        override fun onBinary(frame: ByteArray) {
            // トンネルは Task 4.3 の範囲外。受理前に binary が来ることは
            // 無いはずなので、黙って捨てずに気づける形で残す。
            Log.w(TAG, "トンネルの受け手がまだありません（${frame.size}バイトを捨てました）")
        }

        override fun onClosed(reason: String) = onDisconnected(forGeneration)

        override fun onFailure(error: Throwable) {
            if (isStale()) return
            Log.w(TAG, "接続が切れました: $error")
            onDisconnected(forGeneration)
        }

        private fun isStale(): Boolean = synchronized(lock) { generation != forGeneration }
    }
}
