package dev.fluse.runtime

import dev.fluse.protocol.AcceptMessage
import dev.fluse.protocol.FluseMessage
import dev.fluse.protocol.HelloMessage
import dev.fluse.protocol.RejectCode
import dev.fluse.protocol.RejectMessage
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import okhttp3.OkHttpClient
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.json.JSONObject

/**
 * 実際に WebSocket を張って確かめる（Issue #23 の完了条件）。
 *
 * [FluseConnectionTest] が状態機械を、こちらが OkHttp との繋ぎ込みを見る。
 * 差し替えたソケットだけで通しても、実装が実ソケットで動く保証にはならない。
 */
internal class FluseConnectionServerTest {
    /** 実際に待つのはここだけ。CI の遅さで落ちない程度に取る。 */
    private val timeoutSeconds = 10L
    private val timeoutMs = timeoutSeconds * 1_000

    private val appInfo =
        FluseAppInfo(
            projectId = "0123456789abcdef",
            flutterRevision = "00b0c91f",
            dartVersion = "3.5.0",
            appVersion = "fedcba9876543210",
        )
    private val device = FluseDeviceInfo(deviceId = "a1b2c3d4e5f60718", deviceName = "Google Pixel 8")

    private lateinit var server: MockWebServer
    private lateinit var client: OkHttpClient
    private lateinit var store: FluseStore
    private lateinit var scheduler: RecordingScheduler
    private lateinit var listener: RecordingListener
    private lateinit var connection: FluseConnection
    private val peers = mutableListOf<ServerSide>()

    @BeforeTest
    fun setUp() {
        server = MockWebServer()
        server.start()
        client = OkHttpFluseSocketFactory.defaultClient()
        store = FluseStore(MemoryBacking())
        scheduler = RecordingScheduler()
        listener = RecordingListener()
        connection =
            FluseConnection(
                store = store,
                device = device,
                appInfo = appInfo,
                socketFactory = OkHttpFluseSocketFactory(client),
                scheduler = scheduler,
            )
        connection.addListener(listener)
    }

    @AfterTest
    fun tearDown() {
        // **先に端末側を閉じる。** 繋いだままだと MockWebServer の
        // shutdown が待たされて「Gave up waiting for queue to shut down」で
        // 落ちる。
        connection.stop()
        peers.forEach { it.closeQuietly() }
        client.dispatcher.executorService.shutdown()
        client.connectionPool.evictAll()
        server.shutdown()
    }

    private fun endpoint() = FluseEndpoint(server.hostName, server.port)

    @Test
    fun `繋いで hello を送り accept を受け取る`() {
        val peer = ServerSide()
        server.enqueue(MockResponse().withWebSocketUpgrade(peer))

        connection.connect(endpoint(), pairingToken = "pairing-value")

        val hello = peer.take() as HelloMessage
        assertEquals(appInfo.projectId, hello.projectId)
        assertEquals("pairing-value", hello.pairingToken)

        peer.send(AcceptMessage("s-1", 5_000, issuedDeviceToken = "issued-value"))

        assertTrue(await { listener.connected.isNotEmpty() }, "accept が届きませんでした")
        assertEquals("issued-value", store.deviceToken)
        assertEquals(listOf("s-1"), listener.connected)
    }

    @Test
    fun `reject を受け取ったら繋ぎ直さない`() {
        val peer = ServerSide()
        server.enqueue(MockResponse().withWebSocketUpgrade(peer))

        connection.connect(endpoint(), pairingToken = "pairing-value")
        peer.take()
        peer.send(RejectMessage.of(RejectCode.TOO_MANY_DEVICES, "1台だけです"))

        assertTrue(await { listener.rejected.isNotEmpty() }, "reject が届きませんでした")
        assertEquals(listOf("TOO_MANY_DEVICES"), listener.rejected)
        assertEquals(emptyList(), scheduler.delays)
    }

    @Test
    fun `切られたら待ってから繋ぎ直す`() {
        val first = ServerSide()
        val second = ServerSide()
        server.enqueue(MockResponse().withWebSocketUpgrade(first))
        server.enqueue(MockResponse().withWebSocketUpgrade(second))

        connection.connect(endpoint())
        first.take()
        first.close()

        assertTrue(scheduler.awaitScheduled(1, timeoutMs), "繋ぎ直しが予約されませんでした")
        assertEquals(listOf(1_000L), scheduler.delays)

        // 待ち終わったことにして繋ぎ直す。実時間は待たない。
        scheduler.runNext()

        assertTrue(second.take() is HelloMessage, "繋ぎ直しで hello が届きませんでした")
    }

    /** [check] が真になるまで待つ。ならなければ false。 */
    private fun await(check: () -> Boolean): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (check()) return true
            Thread.sleep(10)
        }
        return check()
    }

    /** 端末から届いた制御メッセージを溜め、こちらからも送れるサーバ側。 */
    private inner class ServerSide : WebSocketListener() {
        init {
            peers.add(this)
        }

        private val received = LinkedBlockingQueue<FluseMessage>()
        private val opened = CountDownLatch(1)

        @Volatile
        private var socket: WebSocket? = null

        override fun onOpen(
            webSocket: WebSocket,
            response: Response,
        ) {
            socket = webSocket
            opened.countDown()
        }

        override fun onMessage(
            webSocket: WebSocket,
            text: String,
        ) {
            received.add(FluseMessage.fromJson(JSONObject(text)))
        }

        /**
         * 応じて閉じる。
         *
         * **返さないと片側だけ開いたまま残る。** その状態で
         * MockWebServer を止めると shutdown が待たされて落ちる。
         */
        override fun onClosing(
            webSocket: WebSocket,
            code: Int,
            reason: String,
        ) {
            webSocket.close(code, null)
        }

        /** 次に届いた制御メッセージ。来なければ落とす。 */
        fun take(): FluseMessage =
            requireNotNull(received.poll(timeoutSeconds, TimeUnit.SECONDS)) {
                "制御メッセージが届きませんでした"
            }

        fun send(message: FluseMessage) {
            requireNotNull(awaitSocket()).send(message.toJson().toString())
        }

        /** サーバ側から切る。端末は切断として扱う。 */
        fun close() {
            requireNotNull(awaitSocket()).close(NORMAL_CLOSURE, "テスト")
        }

        /** 後始末。開いていなければ何もしない。 */
        fun closeQuietly() {
            socket?.close(NORMAL_CLOSURE, null)
        }

        private fun awaitSocket(): WebSocket? {
            require(opened.await(timeoutSeconds, TimeUnit.SECONDS)) { "接続されませんでした" }
            return socket
        }
    }

    private companion object {
        const val NORMAL_CLOSURE = 1000
    }
}
