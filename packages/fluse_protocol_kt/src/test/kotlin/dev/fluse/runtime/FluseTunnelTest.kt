package dev.fluse.runtime

import dev.fluse.protocol.TunnelFrame
import dev.fluse.protocol.TunnelOpcode
import java.io.Closeable
import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeout

/**
 * TCP 側は**実ソケットを使う**。サーバ側 `tunnel_endpoint_test.dart` と
 * 同じ方針で、フェイクにするのは WebSocket チャネルだけにする。
 * ブロッキング I/O の畳み方こそがこのクラスの難所なので、そこを
 * 偽物に置き換えるとテストの意味が無くなる。
 */
class FluseTunnelTest {
    /** WebSocket の代わり。注入したフレームを流し、送られたフレームを溜める。 */
    private class FakeChannel : TunnelChannel {
        private val inbound = Channel<ByteArray>(capacity = Channel.UNLIMITED)
        private val sent = Channel<TunnelFrame>(capacity = Channel.UNLIMITED)

        /** 送信を失敗させる。中継が畳まれることを確かめるために使う。 */
        @Volatile
        var failSend: Boolean = false

        override val incoming: Flow<ByteArray> get() = inbound.receiveAsFlow()

        override suspend fun send(frame: ByteArray) {
            if (failSend) {
                throw IOException("送信できません")
            }
            sent.send(TunnelFrame.decode(frame))
        }

        /** サーバから届いたことにする。 */
        suspend fun inject(frame: TunnelFrame) {
            inbound.send(frame.encode())
        }

        /** サーバが切断したことにする。 */
        fun closeIncoming() {
            inbound.close()
        }

        /** 次に送られたフレームを取り出す。 */
        suspend fun next(): TunnelFrame = sent.receive()

        /** streamId ごとの受信済みバイト列。 */
        private val pending = HashMap<Long, ArrayDeque<Byte>>()
        private val drainMutex = Mutex()

        /**
         * 指定 streamId の `data` を集めて連結する。
         *
         * **他ストリームのフレームは捨てずに溜める。** 捨てると、
         * 複数ストリームを順に検証したときに後のストリームの分が
         * 消えて、テストだけが落ちる。
         *
         * 分割は中継側の都合なので、フレーム数ではなく**再結合した
         * バイト列**で判定する。
         */
        suspend fun collectData(streamId: Long, expectedLength: Int): ByteArray =
            drainMutex.withLock {
                while ((pending[streamId]?.size ?: 0) < expectedLength) {
                    val frame = sent.receive()
                    if (frame.opcode != TunnelOpcode.DATA) {
                        if (frame.streamId == streamId) {
                            error("$streamId が ${frame.opcode.wireName} で終わりました")
                        }
                        continue
                    }
                    pending.getOrPut(frame.streamId) { ArrayDeque() }
                        .addAll(frame.payload.asList())
                }

                val buffer = pending.getValue(streamId)
                ByteArray(expectedLength) { buffer.removeFirst() }
            }

        /** 溜まっているフレームを覗く。無ければ null。 */
        fun poll(): TunnelFrame? = sent.tryReceive().getOrNull()
    }

    /** 受け取ったバイト列をそのまま返すだけの TCP サーバ。 */
    private class EchoServer : Closeable {
        private val server = ServerSocket(0, 50, InetAddress.getByName(FluseTunnel.LOOPBACK))
        private val accepted = java.util.Collections.synchronizedList(ArrayList<Socket>())

        val port: Int get() = server.localPort

        /** 受け付けた接続の数。 */
        val connectionCount: Int get() = accepted.size

        private val thread = Thread {
            while (!server.isClosed) {
                val socket = try {
                    server.accept()
                } catch (_: IOException) {
                    return@Thread
                }
                accepted.add(socket)
                Thread { echo(socket) }.apply { isDaemon = true }.start()
            }
        }.apply { isDaemon = true }

        init {
            thread.start()
        }

        private fun echo(socket: Socket) {
            try {
                val input = socket.getInputStream()
                val output = socket.getOutputStream()
                val buffer = ByteArray(16 * 1024)
                while (true) {
                    val read = input.read(buffer)
                    if (read < 0) {
                        break
                    }
                    output.write(buffer, 0, read)
                    output.flush()
                }
            } catch (_: IOException) {
                // 相手が閉じただけ。
            } finally {
                try {
                    socket.close()
                } catch (_: IOException) {
                    // すでに閉じている。
                }
            }
        }

        /** 受け付けた接続がすべて閉じているか。 */
        fun allClosed(): Boolean = synchronized(accepted) { accepted.all { it.isClosed || !it.isConnected } }

        override fun close() {
            server.close()
            synchronized(accepted) {
                accepted.forEach { runCatching { it.close() } }
            }
        }
    }

    /** ばらけた内容にする。全部同じ値だと分割の取り違えに気づけない。 */
    private fun payload(length: Int): ByteArray =
        ByteArray(length) { i -> ((i * 31 + 7) and 0xFF).toByte() }

    private fun withTunnel(
        port: Int,
        channel: FakeChannel,
        body: suspend CoroutineScope.(FluseTunnel) -> Unit,
    ) = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val tunnel = FluseTunnel(vmServicePort = port, channel = channel, parentScope = scope)
        try {
            tunnel.start()
            withTimeout(30_000) { body(tunnel) }
        } finally {
            tunnel.close()
            scope.cancel()
        }
    }

    @Test
    fun `open で VM Service へ接続する`() {
        EchoServer().use { echo ->
            val channel = FakeChannel()
            withTunnel(echo.port, channel) { tunnel ->
                channel.inject(TunnelFrame.open(1))

                // 接続できたことは、往復が成立することで確かめる。
                channel.inject(TunnelFrame.data(1, payload(8)))
                assertContentEquals(payload(8), channel.collectData(1, 8))

                assertEquals(1, tunnel.activeStreams())
                assertEquals(1, echo.connectionCount)
            }
        }
    }

    @Test
    fun `data が往復する`() {
        EchoServer().use { echo ->
            val channel = FakeChannel()
            withTunnel(echo.port, channel) {
                channel.inject(TunnelFrame.open(7))

                val sent = payload(3000)
                channel.inject(TunnelFrame.data(7, sent))

                assertContentEquals(sent, channel.collectData(7, sent.size))
            }
        }
    }

    @Test
    fun `1MiB を超える転送は分割され再結合で一致する`() {
        EchoServer().use { echo ->
            val channel = FakeChannel()
            withTunnel(echo.port, channel) {
                channel.inject(TunnelFrame.open(1))

                // 1 フレームの上限を明確に超える量を、上限以下ずつ流し込む。
                val total = 3 * TunnelFrame.MAX_PAYLOAD_LENGTH + 12345
                val sent = payload(total)
                var offset = 0
                while (offset < total) {
                    val end = minOf(offset + TunnelFrame.MAX_PAYLOAD_LENGTH, total)
                    channel.inject(TunnelFrame.data(1, sent.copyOfRange(offset, end)))
                    offset = end
                }

                assertContentEquals(sent, channel.collectData(1, total))
            }
        }
    }

    @Test
    fun `複数ストリームが独立に往復する`() {
        EchoServer().use { echo ->
            val channel = FakeChannel()
            withTunnel(echo.port, channel) { tunnel ->
                val ids = listOf(1L, 2L, 3L)
                for (id in ids) {
                    channel.inject(TunnelFrame.open(id))
                }
                // ストリームごとに違う内容を流し、取り違えを検出する。
                val payloads = ids.associateWith { payload(1000 + it.toInt()) }
                for (id in ids) {
                    channel.inject(TunnelFrame.data(id, payloads.getValue(id)))
                }

                for (id in ids) {
                    assertContentEquals(
                        payloads.getValue(id),
                        channel.collectData(id, payloads.getValue(id).size),
                        "streamId=$id",
                    )
                }
                assertEquals(3, tunnel.activeStreams())
            }
        }
    }

    @Test
    fun `close を受けたらソケットを閉じ close を返さない`() {
        EchoServer().use { echo ->
            val channel = FakeChannel()
            withTunnel(echo.port, channel) { tunnel ->
                channel.inject(TunnelFrame.open(1))
                channel.inject(TunnelFrame.data(1, payload(4)))
                channel.collectData(1, 4)

                channel.inject(TunnelFrame.close(1))

                // 登録簿から消えるまで待つ。
                while (tunnel.activeStreams() != 0) {
                    kotlinx.coroutines.yield()
                }

                // **close は送り返さない。** 応酬が終わらなくなる。
                assertEquals(null, channel.poll())
            }
        }
    }

    @Test
    fun `未知の streamId への data には close を返す`() {
        EchoServer().use { echo ->
            val channel = FakeChannel()
            withTunnel(echo.port, channel) {
                channel.inject(TunnelFrame.data(99, payload(4)))

                val frame = channel.next()
                assertEquals(TunnelOpcode.CLOSE, frame.opcode)
                assertEquals(99L, frame.streamId)
            }
        }
    }

    @Test
    fun `接続できなければ close を返す`() {
        // 誰も待ち受けていないポートを用意する。
        val deadPort = ServerSocket(0, 1, InetAddress.getByName(FluseTunnel.LOOPBACK))
            .use { it.localPort }

        val channel = FakeChannel()
        withTunnel(deadPort, channel) { tunnel ->
            channel.inject(TunnelFrame.open(5))

            val frame = channel.next()
            assertEquals(TunnelOpcode.CLOSE, frame.opcode)
            assertEquals(5L, frame.streamId)
            // 開けなかったストリームを登録簿に残さない。
            assertEquals(0, tunnel.activeStreams())
        }
    }

    @Test
    fun `TCP が切れたら close を送る`() {
        EchoServer().use { echo ->
            val channel = FakeChannel()
            withTunnel(echo.port, channel) { tunnel ->
                channel.inject(TunnelFrame.open(1))
                channel.inject(TunnelFrame.data(1, payload(4)))
                channel.collectData(1, 4)

                // VM Service 側が落ちた状況を作る。
                echo.close()

                var frame = channel.next()
                while (frame.opcode != TunnelOpcode.CLOSE) {
                    frame = channel.next()
                }
                assertEquals(1L, frame.streamId)
                assertEquals(0, tunnel.activeStreams())
            }
        }
    }

    @Test
    fun `チャネルが閉じたら全ストリームを解放して done が完了する`() {
        EchoServer().use { echo ->
            val channel = FakeChannel()
            withTunnel(echo.port, channel) { tunnel ->
                channel.inject(TunnelFrame.open(1))
                channel.inject(TunnelFrame.data(1, payload(4)))
                channel.collectData(1, 4)

                channel.closeIncoming()

                tunnel.done.await()
                assertEquals(0, tunnel.activeStreams())
                assertTrue(echo.allClosed(), "ソケットが解放されていません")
            }
        }
    }

    @Test
    fun `送信に失敗したらストリームを畳む`() {
        EchoServer().use { echo ->
            val channel = FakeChannel()
            withTunnel(echo.port, channel) { tunnel ->
                channel.inject(TunnelFrame.open(1))
                channel.inject(TunnelFrame.data(1, payload(4)))
                channel.collectData(1, 4)

                channel.failSend = true
                // エコーが返ってくると送信が失敗し、そのストリームが畳まれる。
                channel.inject(TunnelFrame.data(1, payload(4)))

                while (tunnel.activeStreams() != 0) {
                    kotlinx.coroutines.yield()
                }

                // 送信が壊れているチャネルへ close を流そうとしていない。
                channel.failSend = false
                assertEquals(null, channel.poll())
            }
        }
    }
}
