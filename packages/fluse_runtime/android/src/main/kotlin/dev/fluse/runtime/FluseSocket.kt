package dev.fluse.runtime

import java.util.concurrent.atomic.AtomicBoolean
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString

/**
 * WebSocket の出来事を受け取る側。
 *
 * OkHttp のコールバックをそのまま外へ出さないための一枚。テストでは
 * 実ソケットを立てずにここへ流し込める。
 */
internal interface FluseSocketEvents {
    fun onOpen()

    /** 制御メッセージ（設計 §2.2.1 の text frame）。 */
    fun onText(text: String)

    /** トンネル（binary frame）。 */
    fun onBinary(frame: ByteArray)

    /** 閉じた。理由は表示とログのためだけに使う。 */
    fun onClosed(reason: String)

    fun onFailure(error: Throwable)
}

/** 張った WebSocket。 */
internal interface FluseSocket {
    /** 制御メッセージを送る。閉じていれば false。 */
    fun sendText(text: String): Boolean

    /** 閉じる。以後 [FluseSocketEvents] は呼ばれない。 */
    fun close(reason: String)
}

/** URL と受け手からソケットを作る。テストで差し替える。 */
internal fun interface FluseSocketFactory {
    fun open(
        url: String,
        events: FluseSocketEvents,
    ): FluseSocket
}

/**
 * OkHttp で張る実装。
 *
 * **`java.net.http` は使えない。** Android のクラスライブラリに無い。
 */
internal class OkHttpFluseSocketFactory(
    private val client: OkHttpClient = defaultClient(),
) : FluseSocketFactory {
    companion object {
        /**
         * 既定のクライアント。
         *
         * **ping は送らせない。** 生存確認は制御メッセージの
         * `ping`/`pong`（設計 §2.2.1）でサーバが握っており、WebSocket
         * 層でも打つと二重になる。
         */
        fun defaultClient(): OkHttpClient =
            OkHttpClient.Builder()
                // **`java.time.Duration` の引数は使えない。** minSdk 21 では
                // API 26 の型に触れず、desugaring 無しでは実行時に落ちる。
                .pingInterval(0, java.util.concurrent.TimeUnit.MILLISECONDS)
                .build()
    }

    override fun open(
        url: String,
        events: FluseSocketEvents,
    ): FluseSocket {
        val request = Request.Builder().url(url).build()
        val listener = Adapter(events)
        val socket = client.newWebSocket(request, listener)
        return Handle(socket, listener)
    }

    /** OkHttp のコールバックを [FluseSocketEvents] に写す。 */
    private class Adapter(
        private val events: FluseSocketEvents,
    ) : WebSocketListener() {
        /**
         * 切断を伝えるのは一度だけ。
         *
         * **判定と代入を分けてはいけない。** `close()` と OkHttp の
         * コールバックは別のスレッドから同時に来る。読んでから書くまでの
         * 間に割り込まれると、閉じた後の `onFailure` が切断として通り、
         * 止めたはずの再接続がもう一度動き出す。
         */
        private val detachedFlag = AtomicBoolean(false)

        /** まだ伝えていなければ true を返し、以後は false。 */
        fun detach(): Boolean = detachedFlag.compareAndSet(false, true)

        val detached: Boolean get() = detachedFlag.get()

        override fun onOpen(
            webSocket: WebSocket,
            response: Response,
        ) {
            if (detached) return
            events.onOpen()
        }

        override fun onMessage(
            webSocket: WebSocket,
            text: String,
        ) {
            if (detached) return
            events.onText(text)
        }

        override fun onMessage(
            webSocket: WebSocket,
            bytes: ByteString,
        ) {
            if (detached) return
            events.onBinary(bytes.toByteArray())
        }

        override fun onClosing(
            webSocket: WebSocket,
            code: Int,
            reason: String,
        ) {
            // 応答して閉じないと相手が待ち続ける。
            webSocket.close(code, null)
            if (!detach()) return
            events.onClosed(reason)
        }

        override fun onFailure(
            webSocket: WebSocket,
            t: Throwable,
            response: Response?,
        ) {
            if (!detach()) return
            events.onFailure(t)
        }
    }

    private class Handle(
        private val socket: WebSocket,
        private val adapter: Adapter,
    ) : FluseSocket {
        override fun sendText(text: String): Boolean = socket.send(text)

        override fun close(reason: String) {
            adapter.detach()
            // 1000 は正常終了。異常は WebSocket の close フレームに委ねる
            // （設計 §2.2.1 の CloseMessage の注記）。
            socket.close(NORMAL_CLOSURE, reason)
        }

        private companion object {
            const val NORMAL_CLOSURE = 1000
        }
    }
}
