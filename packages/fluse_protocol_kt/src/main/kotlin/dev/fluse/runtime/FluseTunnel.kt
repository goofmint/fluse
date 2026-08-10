package dev.fluse.runtime

import dev.fluse.protocol.FluseProtocolException
import dev.fluse.protocol.TunnelFrame
import dev.fluse.protocol.TunnelOpcode
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * 端末側のトンネル終端（設計 §2.2.3(e)）。
 *
 * サーバ側 `TunnelEndpoint`（Dart）の**鏡像**。あちらは localhost に TCP を
 * 待ち受けて、来た接続を `open` として送り出す。こちらは `open` を受け取って
 * 端末の `127.0.0.1:<vmServicePort>` へ**自分から接続する**。
 *
 * Android の Dart VM Service は端末の `127.0.0.1` にしかバインドされず、
 * LAN から直接は届かない。WebSocket の中を生 TCP で運ぶことで越える。
 *
 * **プロトコルは一切解釈しない**（設計 §10-3）。VM Service は JSON-RPC over
 * WebSocket と DevFS の HTTP PUT を同じポートで受けるため、片方だけ対応した
 * 「賢いプロキシ」は必ず破綻する。ここはバイト列を運ぶだけ。
 *
 * バックプレッシャ（high/low watermark）とロガーは本クラスの範囲外。
 * 後から足せるよう、送信は [send]、破棄は [closeStream] に集約してある。
 */
class FluseTunnel(
    /** 端末上の VM Service のポート。 */
    val vmServicePort: Int,
    private val channel: TunnelChannel,
    parentScope: CoroutineScope,
) {
    companion object {
        /** VM Service は端末のループバックにしか居ない。 */
        const val LOOPBACK = "127.0.0.1"

        /**
         * 接続の待ち時間。
         *
         * 相手はループバックなので、繋がるか即座に拒否されるかのどちらか。
         * それでも上限を置く。**無制限にすると受信ループが止まり、
         * 他のストリームまで巻き添えになる。**
         */
        const val CONNECT_TIMEOUT_MS = 5_000

        /**
         * TCP から一度に読む量。
         *
         * [TunnelFrame.MAX_PAYLOAD_LENGTH] 以下にしておくことで、
         * 読んだ塊がそのまま 1 フレームに収まる。プロトコル層は自動では
         * 割らず、超えたら例外にする約束なので、ここで守る。
         */
        const val READ_BUFFER_LENGTH = 64 * 1024

        /**
         * 1ストリームあたりの送信待ち行列。
         *
         * これを超えると受信ループが待たされる。**捨てるよりは待たせる。**
         * 落としたバイトは相手には届いたように見え、VM Service の
         * ストリームが黙って壊れる。本来のバックプレッシャは後のタスク。
         */
        const val OUTBOUND_CAPACITY = 64
    }

    init {
        require(READ_BUFFER_LENGTH <= TunnelFrame.MAX_PAYLOAD_LENGTH) {
            "READ_BUFFER_LENGTH が 1 フレームの上限を超えています"
        }
    }

    /**
     * 自分の子だけを畳むための Job。
     *
     * 呼び出し元から受け取った scope をそのまま cancel すると、
     * 呼び出し元の他の仕事まで巻き添えにする。
     */
    private val job = SupervisorJob(parentScope.coroutineContext[Job])

    private val scope =
        CoroutineScope(parentScope.coroutineContext + job + Dispatchers.IO)

    private val streams = HashMap<Long, TunnelStream>()
    private val streamsMutex = Mutex()

    /** フレームは丸ごと・順番どおりに送る。割り込まれると相手が復号できない。 */
    private val sendMutex = Mutex()

    private val closing = AtomicBoolean(false)
    private val terminated = CompletableDeferred<Unit>()

    private var receiveJob: Job? = null

    /** 受信が失敗した理由。[close] が [done] をこれで終わらせる。 */
    @Volatile
    private var terminationError: Throwable? = null

    /** 中継中のストリーム数。 */
    suspend fun activeStreams(): Int = streamsMutex.withLock { streams.size }

    /**
     * トンネルが終わったら完了する。
     *
     * チャネルが閉じた・受信でエラーが出た場合もここで分かる。
     * **呼び出し元はこれを監視すること。** 監視しないと、中継が
     * 止まっていることに気づけない。
     */
    val done: CompletableDeferred<Unit> get() = terminated

    /** 受信ループを開始する。2度目以降は何もしない。 */
    fun start() {
        if (receiveJob != null) {
            return
        }
        receiveJob = scope.launch {
            try {
                channel.incoming.collect { bytes -> handleIncomingFrame(bytes) }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                terminationError = TunnelException("トンネルの受信が失敗しました", e)
            }
            // 正常終了・異常終了どちらでも中継は続けられない。
            close()
        }
    }

    /** 全ストリームを閉じ、[done] を完了させる。二重に呼んでも安全。 */
    suspend fun close() {
        if (!closing.compareAndSet(false, true)) {
            return
        }

        // 自分の scope の中から呼ばれることがある（受信ループの終了時）。
        // 後始末の途中で cancel されないようにしてから畳む。
        withContext(NonCancellable) {
            val snapshot = streamsMutex.withLock {
                streams.values.toList().also { streams.clear() }
            }
            for (stream in snapshot) {
                stream.dispose()
            }

            val error = terminationError
            if (error != null) {
                terminated.completeExceptionally(error)
            } else {
                terminated.complete(Unit)
            }
        }

        // 最後に畳む。ここより前に置くと、この関数自身が途中で止まる。
        job.cancel()
    }

    // ------------------------------------------------------- WebSocket -> TCP

    private suspend fun handleIncomingFrame(bytes: ByteArray) {
        val frame = try {
            TunnelFrame.decode(bytes)
        } catch (_: FluseProtocolException) {
            // 壊れたフレームはどのストリームのものかも分からない。
            // ループは続ける。1 フレームの破損で中継全体を落とさない。
            return
        }

        when (frame.opcode) {
            TunnelOpcode.OPEN -> openStream(frame.streamId)
            TunnelOpcode.DATA -> writeToStream(frame)
            // 相手へ close を送り返さない。応酬が終わらなくなる。
            TunnelOpcode.CLOSE -> closeStream(frame.streamId, notifyPeer = false)
        }
    }

    /**
     * VM Service へ自分から繋ぐ。
     *
     * 接続はこの受信ループの中で待つ。別の coroutine に逃がすと、
     * 直後に届いた同じ streamId の `data` が登録前に来て、開いたばかりの
     * ストリームを「未知」として閉じてしまう。
     */
    private suspend fun openStream(streamId: Long) {
        val duplicated = streamsMutex.withLock { streams.containsKey(streamId) }
        if (duplicated) {
            // 相手の採番が壊れている。開き直すと既存の中継が黙って壊れる。
            send(TunnelFrame.close(streamId))
            return
        }

        val socket = try {
            withContext(Dispatchers.IO) {
                Socket().apply {
                    connect(InetSocketAddress(LOOPBACK, vmServicePort), CONNECT_TIMEOUT_MS)
                }
            }
        } catch (_: IOException) {
            // VM Service がまだ立っていない / 落ちた。開けないことを伝える。
            send(TunnelFrame.close(streamId))
            return
        }

        val stream = TunnelStream(streamId, socket)
        val registered = streamsMutex.withLock {
            if (closing.get()) {
                false
            } else {
                streams[streamId] = stream
                true
            }
        }
        if (!registered) {
            // close と競合した。登録簿に残さないので、ここで畳む。
            stream.dispose()
            return
        }

        stream.readerJob = scope.launch { forwardToTunnel(stream) }
        stream.writerJob = scope.launch { drainOutbound(stream) }
    }

    private suspend fun writeToStream(frame: TunnelFrame) {
        val stream = streamsMutex.withLock { streams[frame.streamId] }
        if (stream == null) {
            // 既に閉じたストリーム宛。相手がまだ知らないだけなので伝える。
            send(TunnelFrame.close(frame.streamId))
            return
        }

        if (!stream.enqueue(frame.payload)) {
            closeStream(frame.streamId, notifyPeer = true)
        }
    }

    /** 受け取ったバイト列をソケットへ書く。ストリームごとに1本だけ走る。 */
    private suspend fun drainOutbound(stream: TunnelStream) {
        try {
            val output = stream.socket.getOutputStream()
            for (payload in stream.outbound) {
                withContext(Dispatchers.IO) {
                    output.write(payload)
                    output.flush()
                }
            }
        } catch (e: CancellationException) {
            throw e
        } catch (_: IOException) {
            closeStream(stream.streamId, notifyPeer = true)
        }
    }

    // ------------------------------------------------------- TCP -> WebSocket

    /**
     * ソケットから読んだバイト列をフレームに割って送る。
     *
     * 分割は中継側の責務。プロトコル層は自動では割らない。
     */
    private suspend fun forwardToTunnel(stream: TunnelStream) {
        val buffer = ByteArray(READ_BUFFER_LENGTH)
        try {
            val input = stream.socket.getInputStream()
            while (true) {
                val read = withContext(Dispatchers.IO) { input.read(buffer) }
                if (read < 0) {
                    // EOF。VM Service 側が閉じた。
                    break
                }
                if (read == 0) {
                    continue
                }
                send(TunnelFrame.data(stream.streamId, buffer.copyOf(read)))
            }
        } catch (e: CancellationException) {
            throw e
        } catch (_: IOException) {
            // 破棄でソケットを閉じた場合もここに来る。closeStream は
            // 登録簿から消えていれば何もしないので、二重には送らない。
        }

        closeStream(stream.streamId, notifyPeer = true)
    }

    // ------------------------------------------------------------- ライフサイクル

    /**
     * フレームを1つ送る。**送信はすべてここを通る。**
     *
     * 送れなかったフレームは失われる。相手は届いたと思って待ち続けるので、
     * 該当ストリームを畳む。close フレームも同じチャネルを通るため、
     * こちらからは送らない。
     */
    private suspend fun send(frame: TunnelFrame) {
        val bytes = try {
            frame.encode()
        } catch (e: FluseProtocolException) {
            // 自分で作ったフレームが符号化できないのは実装の誤り。
            throw TunnelException("フレームを符号化できません", e)
        }

        try {
            sendMutex.withLock { channel.send(bytes) }
        } catch (e: CancellationException) {
            throw e
        } catch (_: Throwable) {
            closeStream(frame.streamId, notifyPeer = false)
        }
    }

    private suspend fun closeStream(streamId: Long, notifyPeer: Boolean) {
        val stream = streamsMutex.withLock { streams.remove(streamId) } ?: return

        if (notifyPeer && !closing.get()) {
            send(TunnelFrame.close(streamId))
        }
        stream.dispose()
    }

    /** 中継中の1ストリーム。 */
    private class TunnelStream(val streamId: Long, val socket: Socket) {
        /**
         * WebSocket から届いたバイト列の行き先。
         *
         * 受信ループから直接 `write` すると、詰まった1本が全ストリームを
         * 止める。ソケットごとに1本の書き手を立てて順序も守る。
         */
        val outbound = Channel<ByteArray>(capacity = OUTBOUND_CAPACITY)

        var readerJob: Job? = null
        var writerJob: Job? = null

        private val disposed = AtomicBoolean(false)

        /** 書き込み待ちに積む。積めなければ false。 */
        suspend fun enqueue(payload: ByteArray): Boolean =
            try {
                outbound.send(payload)
                true
            } catch (_: Throwable) {
                false
            }

        suspend fun dispose() {
            if (!disposed.compareAndSet(false, true)) {
                return
            }

            outbound.close()

            // **ソケットを先に閉じる。** ブロッキングの read / write に
            // 入った coroutine は cancel では起きない。閉じて例外を
            // 起こして初めて抜ける。
            withContext(NonCancellable + Dispatchers.IO) {
                try {
                    socket.close()
                } catch (_: IOException) {
                    // すでに切れている場合は何もしなくてよい。
                }
            }

            // join しない。自分の coroutine から呼ばれることがある。
            readerJob?.cancel()
            writerJob?.cancel()
        }
    }
}
