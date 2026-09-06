package dev.fluse.runtime

import dev.fluse.protocol.AcceptMessage
import dev.fluse.protocol.FLUSE_PROTOCOL_VERSION
import dev.fluse.protocol.FluseMessage
import dev.fluse.protocol.HelloMessage
import dev.fluse.protocol.PingMessage
import dev.fluse.protocol.PongMessage
import dev.fluse.protocol.RejectCode
import dev.fluse.protocol.RejectMessage
import dev.fluse.protocol.VmServiceReadyMessage
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import org.json.JSONObject

internal class FluseConnectionTest {
    private val appInfo =
        FluseAppInfo(
            projectId = "0123456789abcdef",
            flutterRevision = "00b0c91f",
            dartVersion = "3.5.0",
            appVersion = "fedcba9876543210",
        )
    private val device = FluseDeviceInfo(deviceId = "a1b2c3d4e5f60718", deviceName = "Google Pixel 8")
    private val endpoint = FluseEndpoint(host = "192.168.1.2", port = 8180)

    private fun fixture(): Fixture {
        val store = FluseStore(MemoryBacking())
        val sockets = FakeSocketFactory()
        val scheduler = RecordingScheduler()
        val connection =
            FluseConnection(
                store = store,
                device = device,
                appInfo = appInfo,
                socketFactory = sockets,
                scheduler = scheduler,
            )
        val listener = RecordingListener()
        connection.listener = listener
        return Fixture(store, sockets, scheduler, connection, listener)
    }

    private class Fixture(
        val store: FluseStore,
        val sockets: FakeSocketFactory,
        val scheduler: RecordingScheduler,
        val connection: FluseConnection,
        val listener: RecordingListener,
    )

    // ------------------------------------------------------------------ hello

    @Test
    fun `繋がったら hello を送る`() {
        val f = fixture()

        f.connection.connect(endpoint, pairingToken = "pairing-value")
        f.sockets.latest.open()

        val hello = f.sockets.latest.sentAs<HelloMessage>(0)
        assertEquals(FLUSE_PROTOCOL_VERSION.toLong(), hello.protocolVersion)
        assertEquals(appInfo.projectId, hello.projectId)
        assertEquals(appInfo.appVersion, hello.appVersion)
        assertEquals(device.deviceId, hello.deviceId)
        assertEquals(device.deviceName, hello.deviceName)
        assertEquals("ws://192.168.1.2:8180/ws", f.sockets.latest.url)
    }

    @Test
    fun `pairingToken と deviceToken は同時に送らない`() {
        // サーバは両方載った hello を誤りとして断る（session_manager）。
        val f = fixture()
        f.store.deviceToken = "stored-value"

        f.connection.connect(endpoint, pairingToken = "pairing-value")
        f.sockets.latest.open()

        val hello = f.sockets.latest.sentAs<HelloMessage>(0)
        assertEquals("pairing-value", hello.pairingToken)
        assertNull(hello.deviceToken)
    }

    @Test
    fun `ペアリング済みなら deviceToken で名乗る`() {
        val f = fixture()
        f.store.deviceToken = "stored-value"

        f.connection.connect(endpoint)
        f.sockets.latest.open()

        val hello = f.sockets.latest.sentAs<HelloMessage>(0)
        assertEquals("stored-value", hello.deviceToken)
        assertNull(hello.pairingToken)
    }

    // ----------------------------------------------------------------- accept

    @Test
    fun `accept で発行されたトークンを保存する`() {
        // 保存しないと次回も QR を出すことになる。
        val f = fixture()
        f.connection.connect(endpoint, pairingToken = "pairing-value")
        f.sockets.latest.open()

        f.sockets.latest.receive(AcceptMessage("s-1", 5_000, issuedDeviceToken = "issued-value"))

        assertEquals("issued-value", f.store.deviceToken)
        assertTrue(f.connection.isAuthenticated)
        assertEquals(listOf("s-1"), f.listener.connected)
    }

    @Test
    fun `accept で接続先を覚える`() {
        // 次の起動で QR を出さずに繋ぎ直すために要る。
        val f = fixture()
        f.connection.connect(endpoint, pairingToken = "pairing-value")
        f.sockets.latest.open()

        f.sockets.latest.receive(AcceptMessage("s-1", 5_000))

        assertEquals("192.168.1.2", f.store.lastHost)
        assertEquals(8180, f.store.lastPort)
        assertEquals(5_000, f.connection.heartbeatIntervalMs)
    }

    // ----------------------------------------------------------------- reject

    @Test
    fun `TOO_MANY_DEVICES は再試行しない`() {
        // 待って送り直しても同じ答えが返る。バッテリを削るだけ。
        val f = fixture()
        f.connection.connect(endpoint, pairingToken = "pairing-value")
        f.sockets.latest.open()

        f.sockets.latest.receive(RejectMessage.of(RejectCode.TOO_MANY_DEVICES, "1台だけです"))

        assertTrue(f.sockets.latest.closed)
        assertEquals(emptyList(), f.scheduler.delays)
        assertEquals(listOf("TOO_MANY_DEVICES"), f.listener.rejected)
    }

    @Test
    fun `AUTH_FAILED はトークンを捨ててペアリングへ戻す`() {
        // 通らないトークンを残すと、次の起動も同じ所で止まる。
        val f = fixture()
        f.store.deviceToken = "stale-value"
        f.connection.connect(endpoint)
        f.sockets.latest.open()

        f.sockets.latest.receive(RejectMessage.of(RejectCode.AUTH_FAILED, "認証できません"))

        assertFalse(f.store.hasDeviceToken())
        assertEquals(listOf("認証できません"), f.listener.needsPairing)
        assertEquals(emptyList(), f.scheduler.delays)
    }

    // -------------------------------------------------------------- heartbeat

    @Test
    fun `ping には seq と時刻をそのまま返す`() {
        // 作り直すとサーバが RTT を測れない。
        val f = fixture()
        f.connection.connect(endpoint, pairingToken = "pairing-value")
        f.sockets.latest.open()
        f.sockets.latest.receive(AcceptMessage("s-1", 5_000))

        f.sockets.latest.receive(PingMessage(seq = 7, timestampMs = 1_700_000_000_000))

        val pong = f.sockets.latest.sentAs<PongMessage>(f.sockets.latest.sent.lastIndex)
        assertEquals(7, pong.seq)
        assertEquals(1_700_000_000_000, pong.timestampMs)
    }

    // ------------------------------------------------------------------ 再接続

    @Test
    fun `切れたら1秒2秒4秒と待って繋ぎ直す`() {
        val f = fixture()
        f.connection.connect(endpoint)

        repeat(3) {
            f.sockets.latest.fail()
            f.scheduler.runNext()
        }

        assertEquals(listOf(1_000L, 2_000L, 4_000L), f.scheduler.delays)
        // 1回目の接続 + 3回の繋ぎ直し。
        assertEquals(4, f.sockets.opened.size)
    }

    @Test
    fun `繋がった後の切断は1秒から数え直す`() {
        val f = fixture()
        f.connection.connect(endpoint)
        f.sockets.latest.fail()
        f.scheduler.runNext()
        f.sockets.latest.open()
        f.sockets.latest.receive(AcceptMessage("s-1", 5_000))

        f.sockets.latest.fail()

        assertEquals(listOf(1_000L, 1_000L), f.scheduler.delays)
        assertEquals(2, f.listener.disconnected)
    }

    @Test
    fun `stop したら繋ぎ直さない`() {
        val f = fixture()
        f.connection.connect(endpoint)

        f.connection.stop()
        f.sockets.latest.fail()

        assertEquals(emptyList(), f.scheduler.delays)
    }

    // --------------------------------------------------------- vmServiceReady

    @Test
    fun `同じ URI は一度しか送らない`() {
        // Hot Restart のたびに Dart 側の main() が同じ URI を送ってくる。
        val f = fixture()
        f.connection.connect(endpoint)
        f.sockets.latest.open()
        f.sockets.latest.receive(AcceptMessage("s-1", 5_000))

        f.connection.vmServiceReady("http://127.0.0.1:1234/abcdefgh/")
        f.connection.vmServiceReady("http://127.0.0.1:1234/abcdefgh/")

        assertEquals(1, f.sockets.latest.countOf<VmServiceReadyMessage>())
    }

    @Test
    fun `URI が変われば送り直す`() {
        val f = fixture()
        f.connection.connect(endpoint)
        f.sockets.latest.open()
        f.sockets.latest.receive(AcceptMessage("s-1", 5_000))

        f.connection.vmServiceReady("http://127.0.0.1:1234/abcdefgh/")
        f.connection.vmServiceReady("http://127.0.0.1:5678/ijklmnop/")

        assertEquals(2, f.sockets.latest.countOf<VmServiceReadyMessage>())
    }

    @Test
    fun `受理前に届いた URI は受理後に送る`() {
        // flusePreviewMain はアプリの起動と並行に走り、accept より先に来る。
        val f = fixture()
        f.connection.connect(endpoint)
        f.sockets.latest.open()

        f.connection.vmServiceReady("http://127.0.0.1:1234/abcdefgh/")
        assertEquals(0, f.sockets.latest.countOf<VmServiceReadyMessage>())

        f.sockets.latest.receive(AcceptMessage("s-1", 5_000))

        assertEquals(1, f.sockets.latest.countOf<VmServiceReadyMessage>())
    }

    @Test
    fun `繋ぎ直した先には同じ URI でも送る`() {
        // 新しいセッションは前のセッションが何を受け取ったか知らない。
        val f = fixture()
        f.connection.connect(endpoint)
        f.sockets.latest.open()
        f.sockets.latest.receive(AcceptMessage("s-1", 5_000))
        f.connection.vmServiceReady("http://127.0.0.1:1234/abcdefgh/")

        f.sockets.latest.fail()
        f.scheduler.runNext()
        f.sockets.latest.open()
        f.sockets.latest.receive(AcceptMessage("s-2", 5_000))

        assertEquals(1, f.sockets.latest.countOf<VmServiceReadyMessage>())
    }
}

// ------------------------------------------------------------------ テスト用

/** 実ソケットを立てずに出来事を流し込む。 */
internal class FakeSocketFactory : FluseSocketFactory {
    val opened = mutableListOf<FakeSocket>()

    val latest: FakeSocket get() = opened.last()

    override fun open(
        url: String,
        events: FluseSocketEvents,
    ): FluseSocket {
        val socket = FakeSocket(url, events)
        opened.add(socket)
        return socket
    }
}

internal class FakeSocket(
    val url: String,
    private val events: FluseSocketEvents,
) : FluseSocket {
    val sent = mutableListOf<String>()
    var closed = false
        private set

    override fun sendText(text: String): Boolean {
        sent.add(text)
        return true
    }

    override fun close(reason: String) {
        closed = true
    }

    fun open() = events.onOpen()

    fun receive(message: FluseMessage) = events.onText(message.toJson().toString())

    fun fail() = events.onFailure(IllegalStateException("切れました"))

    /** [index] 番目に送った制御メッセージ。 */
    inline fun <reified T : FluseMessage> sentAs(index: Int): T =
        FluseMessage.fromJson(JSONObject(sent[index])) as T

    /** 送った中で [T] が何件あるか。 */
    inline fun <reified T : FluseMessage> countOf(): Int =
        sent.count { FluseMessage.fromJson(JSONObject(it)) is T }
}

/**
 * 起きた出来事を溜める。
 *
 * **実ソケットのテストからは別スレッドで呼ばれる。** 同期しないと、
 * 溜めた側と読む側で見え方がずれる。
 */
internal class RecordingListener : FluseConnectionListener {
    private val lock = Any()
    private val connectedList = mutableListOf<String>()
    private val rejectedList = mutableListOf<String>()
    private val needsPairingList = mutableListOf<String>()
    private val messageList = mutableListOf<FluseMessage>()
    private var disconnectedCount = 0

    val connected: List<String> get() = synchronized(lock) { connectedList.toList() }
    val rejected: List<String> get() = synchronized(lock) { rejectedList.toList() }
    val needsPairing: List<String> get() = synchronized(lock) { needsPairingList.toList() }
    val messages: List<FluseMessage> get() = synchronized(lock) { messageList.toList() }
    val disconnected: Int get() = synchronized(lock) { disconnectedCount }

    override fun onConnected(sessionId: String) {
        synchronized(lock) { connectedList.add(sessionId) }
    }

    override fun onRejected(
        code: String,
        message: String,
    ) {
        synchronized(lock) { rejectedList.add(code) }
    }

    override fun onNeedsPairing(reason: String) {
        synchronized(lock) { needsPairingList.add(reason) }
    }

    override fun onDisconnected() {
        synchronized(lock) { disconnectedCount++ }
    }

    override fun onMessage(message: FluseMessage) {
        synchronized(lock) { messageList.add(message) }
    }
}

/**
 * 待たずに、待ち時間だけ記録する。
 *
 * 実ソケットのテストでは OkHttp のスレッドから予約が入るため、
 * [awaitScheduled] で予約されるまで待てるようにしてある。
 */
internal class RecordingScheduler : RetryScheduler {
    private val lock = Object()
    private val recorded = mutableListOf<Long>()
    private val actions = ArrayDeque<() -> Unit>()

    val delays: List<Long> get() = synchronized(lock) { recorded.toList() }

    override fun schedule(
        delayMs: Long,
        action: () -> Unit,
    ) {
        synchronized(lock) {
            recorded.add(delayMs)
            actions.addLast(action)
            lock.notifyAll()
        }
    }

    /** [count] 件の予約が入るまで待つ。入らなければ false。 */
    fun awaitScheduled(
        count: Int,
        timeoutMs: Long,
    ): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        synchronized(lock) {
            while (recorded.size < count) {
                val remaining = deadline - System.currentTimeMillis()
                if (remaining <= 0) return false
                lock.wait(remaining)
            }
            return true
        }
    }

    /** 予約された処理を1つ実行する。 */
    fun runNext() {
        val action = synchronized(lock) { actions.removeFirst() }
        action()
    }
}
