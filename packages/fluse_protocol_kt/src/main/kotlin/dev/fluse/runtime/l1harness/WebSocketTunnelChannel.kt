package dev.fluse.runtime.l1harness

import dev.fluse.runtime.TunnelChannel
import java.net.http.WebSocket
import java.nio.ByteBuffer
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CompletionStage
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.future.await
import kotlinx.coroutines.future.future
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * 実 WebSocket を [TunnelChannel] に見せる実装。**L1統合テスト専用**（Task 2.5）。
 *
 * 本番の端末側 WebSocket は `FluseConnection` が所有する。ここは
 * `TunnelEndpoint`(Dart) ⇄ [dev.fluse.runtime.FluseTunnel] を
 * **実 WebSocket 越しに**繋いで検証するためだけに存在する。
 *
 * **このパッケージを Android プラグインへ移してはいけない。**
 * `java.net.http` は Android のクラスライブラリに無く、移すと実行時に落ちる。
 */
class WebSocketTunnelChannel(
    private val scope: CoroutineScope,
) : TunnelChannel, WebSocket.Listener {

    /**
     * 受信フレームの受け渡し口。
     *
     * 容量は 1 に留める。溜め込むと WebSocket の受信が青天井に先行し、
     * バックプレッシャが効かなくなる。[onBinary] が返す [CompletionStage] を
     * 送信完了まで未完了に保つことで、下流が詰まれば受信も止まる。
     */
    private val frames = Channel<ByteArray>(capacity = 1)

    /**
     * 分割配信された binary メッセージの組み立て先。
     *
     * `onBinary` は 1 メッセージを複数回に分けて渡してくることがある。
     * 途中の塊をそのまま流すと [dev.fluse.protocol.TunnelFrame.decode] が
     * 壊れたフレームとして捨て、中継が黙って壊れる。
     *
     * WebSocket の受信は 1 スレッドから順に呼ばれる契約なので、
     * ここに同期は要らない。
     */
    private var partial: ByteArray? = null

    /** WebSocket は前の送信が完了するまで次を出せない。順序も保つ必要がある。 */
    private val sendMutex = Mutex()

    /** [attach] が埋める。接続前に [send] は呼べない。 */
    @Volatile
    private var socket: WebSocket? = null

    override val incoming: Flow<ByteArray> = frames.receiveAsFlow()

    /** 接続が確立した WebSocket を結びつける。 */
    fun attach(webSocket: WebSocket) {
        socket = webSocket
    }

    override suspend fun send(frame: ByteArray) {
        val webSocket = socket ?: error("WebSocket が未接続です")
        // sendBinary の CompletableFuture が完了するまで戻らない。
        // 先に戻ると「送り出しが済んだ」という TunnelChannel の約束が崩れ、
        // バックプレッシャの計上が実際より軽く見える。
        sendMutex.withLock {
            webSocket.sendBinary(ByteBuffer.wrap(frame), true).await()
        }
    }

    // ------------------------------------------------------ WebSocket.Listener

    override fun onOpen(webSocket: WebSocket) {
        // 既定実装と違い自分で要求する。オーバーライドすると自動では要求されない。
        webSocket.request(1)
    }

    override fun onBinary(
        webSocket: WebSocket,
        data: ByteBuffer,
        last: Boolean,
    ): CompletionStage<*> {
        // data は返す CompletionStage が完了するまでしか有効でない。先に写す。
        val chunk = ByteArray(data.remaining())
        data.get(chunk)

        val message = when (val head = partial) {
            null -> chunk
            else -> head + chunk
        }
        if (!last) {
            partial = message
            webSocket.request(1)
            return CompletableFuture.completedFuture(null)
        }
        partial = null

        // 下流が受け取るまで完了させない。これが受信側のバックプレッシャ。
        return scope.future {
            frames.send(message)
            webSocket.request(1)
        }
    }

    override fun onClose(
        webSocket: WebSocket,
        statusCode: Int,
        reason: String,
    ): CompletionStage<*>? {
        // 正常終了。FluseTunnel は incoming の完了を「相手が閉じた」と読む。
        frames.close()
        return null
    }

    override fun onError(webSocket: WebSocket, error: Throwable) {
        // 握り潰すと中継が死んだことに誰も気づけない。
        frames.close(error)
    }
}
