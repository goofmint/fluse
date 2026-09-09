import XCTest

@testable import fluse_runtime

/// `FluseConnection` の状態機械を、実ソケットを立てずに確かめる。
///
/// 移植元: `packages/fluse_runtime/android/src/test/kotlin/dev/fluse/runtime/FluseConnectionTest.kt`
/// ケースは減らさず、同じ入力・同じ期待値で移植する。
///
/// 実ソケット越しの確認は `FluseConnectionServerTests`、`URLSessionFluseSocketFactory`
/// 自体の確認は `FluseSocketTests`（いずれも同ディレクトリ）を見ること。
final class FluseConnectionTests: XCTestCase {
    private let appInfo = FluseAppInfo(
        projectId: "0123456789abcdef",
        flutterRevision: "00b0c91f",
        dartVersion: "3.5.0",
        appVersion: "fedcba9876543210"
    )
    private let device = FluseDeviceInfo(deviceId: "a1b2c3d4e5f60718", deviceName: "Google Pixel 8")
    private let endpoint = FluseEndpoint(host: "192.168.1.2", port: 8180)

    private struct Fixture {
        let store: MemoryConnectionStore
        let sockets: FakeSocketFactory
        let scheduler: RecordingScheduler
        let connection: FluseConnection
        let listener: RecordingListener
    }

    private func fixture() -> Fixture {
        let store = MemoryConnectionStore()
        let sockets = FakeSocketFactory()
        let scheduler = RecordingScheduler()
        let connection = FluseConnection(
            store: store,
            device: device,
            appInfo: appInfo,
            socketFactory: sockets,
            scheduler: scheduler
        )
        let listener = RecordingListener()
        connection.addListener(listener)
        return Fixture(store: store, sockets: sockets, scheduler: scheduler, connection: connection, listener: listener)
    }

    // ------------------------------------------------------------------ hello

    func testSendsHelloWhenConnected() {
        let f = fixture()

        f.connection.connect(endpoint: endpoint, pairingToken: "pairing-value")
        f.sockets.latest.open()

        let hello: HelloMessage = f.sockets.latest.sentAs(0)
        XCTAssertEqual(Int64(fluseProtocolVersion), hello.protocolVersion)
        XCTAssertEqual(appInfo.projectId, hello.projectId)
        XCTAssertEqual(appInfo.appVersion, hello.appVersion)
        XCTAssertEqual(device.deviceId, hello.deviceId)
        XCTAssertEqual(device.deviceName, hello.deviceName)
        XCTAssertEqual("ws://192.168.1.2:8180/ws", f.sockets.latest.url)
    }

    func testDoesNotSendPairingTokenAndDeviceTokenTogether() {
        // サーバは両方載った hello を誤りとして断る（session_manager）。
        let f = fixture()
        f.store.deviceToken = "stored-value"

        f.connection.connect(endpoint: endpoint, pairingToken: "pairing-value")
        f.sockets.latest.open()

        let hello: HelloMessage = f.sockets.latest.sentAs(0)
        XCTAssertEqual("pairing-value", hello.pairingToken)
        XCTAssertNil(hello.deviceToken)
    }

    func testUsesDeviceTokenWhenAlreadyPaired() {
        let f = fixture()
        f.store.deviceToken = "stored-value"

        f.connection.connect(endpoint: endpoint)
        f.sockets.latest.open()

        let hello: HelloMessage = f.sockets.latest.sentAs(0)
        XCTAssertEqual("stored-value", hello.deviceToken)
        XCTAssertNil(hello.pairingToken)
    }

    // ----------------------------------------------------------------- accept

    func testSavesIssuedTokenOnAccept() {
        // 保存しないと次回も QR を出すことになる。
        let f = fixture()
        f.connection.connect(endpoint: endpoint, pairingToken: "pairing-value")
        f.sockets.latest.open()

        f.sockets.latest.receive(AcceptMessage(sessionId: "s-1", heartbeatIntervalMs: 5_000, issuedDeviceToken: "issued-value"))

        XCTAssertEqual("issued-value", f.store.deviceToken)
        XCTAssertTrue(f.connection.isAuthenticated)
        XCTAssertEqual(["s-1"], f.listener.connected)
    }

    func testRemembersEndpointOnAccept() {
        // 次の起動で QR を出さずに繋ぎ直すために要る。
        let f = fixture()
        f.connection.connect(endpoint: endpoint, pairingToken: "pairing-value")
        f.sockets.latest.open()

        f.sockets.latest.receive(AcceptMessage(sessionId: "s-1", heartbeatIntervalMs: 5_000))

        XCTAssertEqual("192.168.1.2", f.store.lastHost)
        XCTAssertEqual(8180, f.store.lastPort)
        XCTAssertEqual(5_000, f.connection.heartbeatIntervalMs)
    }

    // ----------------------------------------------------------------- reject

    func testTooManyDevicesDoesNotRetry() {
        // 待って送り直しても同じ答えが返る。バッテリを削るだけ。
        let f = fixture()
        f.connection.connect(endpoint: endpoint, pairingToken: "pairing-value")
        f.sockets.latest.open()

        f.sockets.latest.receive(RejectMessage.of(.tooManyDevices, "1台だけです"))

        XCTAssertTrue(f.sockets.latest.closed)
        XCTAssertEqual([], f.scheduler.delays)
        XCTAssertEqual(["TOO_MANY_DEVICES"], f.listener.rejected)
    }

    func testAuthFailedDiscardsTokenAndReturnsToPairing() {
        // 通らないトークンを残すと、次の起動も同じ所で止まる。
        let f = fixture()
        f.store.deviceToken = "stale-value"
        f.connection.connect(endpoint: endpoint)
        f.sockets.latest.open()

        f.sockets.latest.receive(RejectMessage.of(.authFailed, "認証できません"))

        XCTAssertNil(f.store.deviceToken)
        XCTAssertEqual(["認証できません"], f.listener.needsPairing)
        XCTAssertEqual([], f.scheduler.delays)
    }

    // -------------------------------------------------------------- heartbeat

    func testPingIsAnsweredWithSameSeqAndTimestamp() {
        // 作り直すとサーバが RTT を測れない。
        let f = fixture()
        f.connection.connect(endpoint: endpoint, pairingToken: "pairing-value")
        f.sockets.latest.open()
        f.sockets.latest.receive(AcceptMessage(sessionId: "s-1", heartbeatIntervalMs: 5_000))

        f.sockets.latest.receive(PingMessage(seq: 7, timestampMs: 1_700_000_000_000))

        let pong: PongMessage = f.sockets.latest.sentAs(f.sockets.latest.sent.count - 1)
        XCTAssertEqual(7, pong.seq)
        XCTAssertEqual(1_700_000_000_000, pong.timestampMs)
    }

    // ------------------------------------------------------------------ 再接続

    func testReconnectsWithOneTwoFourSecondBackoff() {
        let f = fixture()
        f.connection.connect(endpoint: endpoint)

        for _ in 0..<3 {
            f.sockets.latest.fail()
            f.scheduler.runNext()
        }

        XCTAssertEqual([1_000, 2_000, 4_000], f.scheduler.delays)
        // 1回目の接続 + 3回の繋ぎ直し。
        XCTAssertEqual(4, f.sockets.opened.count)
    }

    func testDisconnectAfterConnectedRestartsBackoffFromOneSecond() {
        let f = fixture()
        f.connection.connect(endpoint: endpoint)
        f.sockets.latest.fail()
        f.scheduler.runNext()
        f.sockets.latest.open()
        f.sockets.latest.receive(AcceptMessage(sessionId: "s-1", heartbeatIntervalMs: 5_000))

        f.sockets.latest.fail()

        XCTAssertEqual([1_000, 1_000], f.scheduler.delays)
        XCTAssertEqual(2, f.listener.disconnected)
    }

    func testStopPreventsReconnect() {
        let f = fixture()
        f.connection.connect(endpoint: endpoint)

        f.connection.stop()
        f.sockets.latest.fail()

        XCTAssertEqual([], f.scheduler.delays)
    }

    func testIgnoresOldSocketFailureAfterReconnecting() {
        // 閉じた直後の通知は、新しいソケットが入った後に届くことがある。
        // そこで状態を消すと、生きている接続が失われる。
        let f = fixture()
        f.connection.connect(endpoint: endpoint)
        let old = f.sockets.latest

        f.connection.connect(endpoint: endpoint)
        old.fail()

        XCTAssertEqual([], f.scheduler.delays)
        XCTAssertEqual(0, f.listener.disconnected)
    }

    func testOldScheduledRetryDoesNotReopenAfterReconnecting() {
        // 取り消せない予約が後から動くと、生きているソケットを置き換えて
        // 二重のセッションになる。
        let f = fixture()
        f.connection.connect(endpoint: endpoint)
        f.sockets.latest.fail()
        XCTAssertEqual([1_000], f.scheduler.delays)

        f.connection.connect(endpoint: endpoint)
        let beforeRetry = f.sockets.opened.count
        f.scheduler.runNext()

        XCTAssertEqual(beforeRetry, f.sockets.opened.count)
    }

    func testClosingMessageAlsoClosesSocket() {
        // 残すと URLSession 側の通知が後から来て、切断処理が二重に走る。
        let f = fixture()
        f.connection.connect(endpoint: endpoint)
        f.sockets.latest.open()
        f.sockets.latest.receive(AcceptMessage(sessionId: "s-1", heartbeatIntervalMs: 5_000))
        let current = f.sockets.latest

        current.receive(CloseMessage.of(.shutdown))

        XCTAssertTrue(current.closed)
        XCTAssertEqual([1_000], f.scheduler.delays)
    }

    func testSendsHelloEvenWhenOpenArrivesFirst() {
        // `URLSession` はコールバックを登録した後にソケットを返すとは限らない。
        // onOpen が先に走ると、取りこぼして名乗らないまま待ち続ける。
        let f = fixture()
        f.sockets.openImmediately = true

        f.connection.connect(endpoint: endpoint)

        XCTAssertEqual(1, f.sockets.latest.countOf(HelloMessage.self))
    }

    // --------------------------------------------------------- vmServiceReady

    func testSameUriIsSentOnlyOnce() {
        // Hot Restart のたびに Dart 側の main() が同じ URI を送ってくる。
        let f = fixture()
        f.connection.connect(endpoint: endpoint)
        f.sockets.latest.open()
        f.sockets.latest.receive(AcceptMessage(sessionId: "s-1", heartbeatIntervalMs: 5_000))

        f.connection.vmServiceReady("http://127.0.0.1:1234/abcdefgh/")
        f.connection.vmServiceReady("http://127.0.0.1:1234/abcdefgh/")

        XCTAssertEqual(1, f.sockets.latest.countOf(VmServiceReadyMessage.self))
    }

    func testResendsWhenUriChanges() {
        let f = fixture()
        f.connection.connect(endpoint: endpoint)
        f.sockets.latest.open()
        f.sockets.latest.receive(AcceptMessage(sessionId: "s-1", heartbeatIntervalMs: 5_000))

        f.connection.vmServiceReady("http://127.0.0.1:1234/abcdefgh/")
        f.connection.vmServiceReady("http://127.0.0.1:5678/ijklmnop/")

        XCTAssertEqual(2, f.sockets.latest.countOf(VmServiceReadyMessage.self))
    }

    func testUriReceivedBeforeAcceptIsSentAfterAccept() {
        // flusePreviewMain はアプリの起動と並行に走り、accept より先に来る。
        let f = fixture()
        f.connection.connect(endpoint: endpoint)
        f.sockets.latest.open()

        f.connection.vmServiceReady("http://127.0.0.1:1234/abcdefgh/")
        XCTAssertEqual(0, f.sockets.latest.countOf(VmServiceReadyMessage.self))

        f.sockets.latest.receive(AcceptMessage(sessionId: "s-1", heartbeatIntervalMs: 5_000))

        XCTAssertEqual(1, f.sockets.latest.countOf(VmServiceReadyMessage.self))
    }

    func testSendsSameUriAgainAfterReconnecting() {
        // 新しいセッションは前のセッションが何を受け取ったか知らない。
        let f = fixture()
        f.connection.connect(endpoint: endpoint)
        f.sockets.latest.open()
        f.sockets.latest.receive(AcceptMessage(sessionId: "s-1", heartbeatIntervalMs: 5_000))
        f.connection.vmServiceReady("http://127.0.0.1:1234/abcdefgh/")

        f.sockets.latest.fail()
        f.scheduler.runNext()
        f.sockets.latest.open()
        f.sockets.latest.receive(AcceptMessage(sessionId: "s-2", heartbeatIntervalMs: 5_000))

        XCTAssertEqual(1, f.sockets.latest.countOf(VmServiceReadyMessage.self))
    }

    // ------------------------------------------------------------- listeners
    //
    // Kotlin 版は `CopyOnWriteArraySet` に委ねているため専用のテストが無いが、
    // Swift 版はここを配列 + NSLock で手書きしている。重複防止・除去・
    // 通知中の増減が本当に安全かはライブラリ任せにできないので、ここで確かめる。

    func testAddListenerIgnoresDuplicateSameInstance() {
        let f = fixture()
        let extra = RecordingListener()
        f.connection.addListener(extra)
        f.connection.addListener(extra)

        f.connection.connect(endpoint: endpoint)
        f.sockets.latest.open()
        f.sockets.latest.receive(AcceptMessage(sessionId: "s-1", heartbeatIntervalMs: 5_000))

        // 2回登録しても、1回の accept で1回しか通知されない。
        XCTAssertEqual(["s-1"], extra.connected)
    }

    func testRemoveListenerStopsNotifications() {
        let f = fixture()
        let extra = RecordingListener()
        f.connection.addListener(extra)
        f.connection.removeListener(extra)

        f.connection.connect(endpoint: endpoint)
        f.sockets.latest.open()
        f.sockets.latest.receive(AcceptMessage(sessionId: "s-1", heartbeatIntervalMs: 5_000))

        XCTAssertEqual([], extra.connected)
        // 除去した後も、他のリスナーへの通知は続く。
        XCTAssertEqual(["s-1"], f.listener.connected)
    }

    func testListenerChangesDuringNotificationDoNotCrash() {
        // 通知はスナップショットを取ってから回すため、通知中に増減しても
        // その場で取りこぼしたり例外になったりしない（設計どおりの前提を確認する）。
        let f = fixture()
        let late = RecordingListener()
        let mutating = MutatingListener(connection: f.connection, toAdd: late)
        f.connection.addListener(mutating)

        f.connection.connect(endpoint: endpoint)
        f.sockets.latest.open()
        f.sockets.latest.receive(AcceptMessage(sessionId: "s-1", heartbeatIntervalMs: 5_000))

        // 通知の最中に追加したリスナーは、その場の accept 通知は受け取れない
        // （スナップショットを取った後に足したため）。次の出来事からは届く。
        XCTAssertEqual([], late.connected)
        f.connection.stop()
        f.connection.connect(endpoint: endpoint)
        f.sockets.latest.open()
        f.sockets.latest.receive(AcceptMessage(sessionId: "s-2", heartbeatIntervalMs: 5_000))
        XCTAssertEqual(["s-2"], late.connected)
    }

    func testListenerCanRemoveItselfDuringNotificationWithoutCrashing() {
        // 通知中に自分自身を外す実装（画面が閉じる際にありがち）は、
        // スナップショットを取っていない実装だと `ConcurrentModificationException`
        // 相当のクラッシュになる。ここでは起きないことと、以後は通知が
        // 届かなくなることの両方を確かめる。
        let f = fixture()
        let selfRemoving = SelfRemovingListener(connection: f.connection)
        f.connection.addListener(selfRemoving)

        f.connection.connect(endpoint: endpoint)
        f.sockets.latest.open()
        f.sockets.latest.receive(AcceptMessage(sessionId: "s-1", heartbeatIntervalMs: 5_000))

        XCTAssertEqual(["s-1"], selfRemoving.connected)

        f.connection.stop()
        f.connection.connect(endpoint: endpoint)
        f.sockets.latest.open()
        f.sockets.latest.receive(AcceptMessage(sessionId: "s-2", heartbeatIntervalMs: 5_000))

        // 1回目の通知の最中に自分を外しているので、2回目は届かない。
        XCTAssertEqual(["s-1"], selfRemoving.connected)
    }
}

// ------------------------------------------------------------------ テスト用

/// 実ソケットを立てずに出来事を流し込む。
///
/// 移植元: `FluseConnectionTest.kt` の `FakeSocketFactory`。
final class FakeSocketFactory: FluseSocketFactory {
    private(set) var opened: [FakeSocket] = []

    /// `URLSession` のように、ソケットを返す前に onOpen を走らせる。
    var openImmediately = false

    var latest: FakeSocket { opened[opened.count - 1] }

    func open(url: String, events: FluseSocketEvents) -> FluseSocket {
        let socket = FakeSocket(url: url, events: events)
        opened.append(socket)
        if openImmediately {
            socket.open()
        }
        return socket
    }
}

final class FakeSocket: FluseSocket {
    let url: String

    /// **強く持つ。** `FluseConnection.openSocket` はローカル変数として
    /// `Events` を作って渡してくるだけなので、ここで保持しないと呼び出しが
    /// 終わった時点で解放され、以後 `open()`/`receive()`/`fail()` が
    /// 何も届けられなくなる（`URLSessionFluseSocketFactory` では
    /// `Adapter` がこの役目を果たす）。
    private let events: FluseSocketEvents

    private(set) var sent: [String] = []
    private(set) var closed = false

    init(url: String, events: FluseSocketEvents) {
        self.url = url
        self.events = events
    }

    func sendText(_ text: String) -> Bool {
        sent.append(text)
        return true
    }

    func sendBinary(_ frame: Data) -> Bool {
        false
    }

    func close(reason: String) {
        closed = true
    }

    func open() { events.onOpen() }

    func receive(_ message: FluseMessage) {
        let data = try! JSONSerialization.data(withJSONObject: message.toJson())
        events.onText(String(data: data, encoding: .utf8)!)
    }

    func fail() {
        events.onFailure(FakeSocketFailure())
    }

    /// [index] 番目に送った制御メッセージ。
    func sentAs<T: FluseMessage>(_ index: Int) -> T {
        let data = sent[index].data(using: .utf8)!
        let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        return try! FluseMessageDecoder.fromJson(json) as! T
    }

    /// 送った中で `T` が何件あるか。
    func countOf<T: FluseMessage>(_ type: T.Type) -> Int {
        sent.filter { text in
            guard
                let data = text.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let message = try? FluseMessageDecoder.fromJson(json)
            else { return false }
            return message is T
        }.count
    }
}

private struct FakeSocketFailure: Error, CustomStringConvertible {
    var description: String { "切れました" }
}

/// 起きた出来事を溜める。
///
/// 移植元: `FluseConnectionTest.kt` の `RecordingListener`。Kotlin 版のコメントに
/// あるとおり実ソケットのテストからは別スレッドで呼ばれうるため、ロックはここでも残す。
final class RecordingListener: FluseConnectionListener {
    private let lock = NSLock()
    private var connectedList: [String] = []
    private var rejectedList: [String] = []
    private var needsPairingList: [String] = []
    private var messageList: [FluseMessage] = []
    private var disconnectedCount = 0

    var connected: [String] {
        lock.lock(); defer { lock.unlock() }
        return connectedList
    }

    var rejected: [String] {
        lock.lock(); defer { lock.unlock() }
        return rejectedList
    }

    var needsPairing: [String] {
        lock.lock(); defer { lock.unlock() }
        return needsPairingList
    }

    var messages: [FluseMessage] {
        lock.lock(); defer { lock.unlock() }
        return messageList
    }

    var disconnected: Int {
        lock.lock(); defer { lock.unlock() }
        return disconnectedCount
    }

    func onConnected(sessionId: String) {
        lock.lock(); connectedList.append(sessionId); lock.unlock()
    }

    func onRejected(code: String, message: String) {
        lock.lock(); rejectedList.append(code); lock.unlock()
    }

    func onNeedsPairing(reason: String) {
        lock.lock(); needsPairingList.append(reason); lock.unlock()
    }

    func onDisconnected() {
        lock.lock(); disconnectedCount += 1; lock.unlock()
    }

    func onMessage(_ message: FluseMessage) {
        lock.lock(); messageList.append(message); lock.unlock()
    }
}

/// 通知の最中に `addListener` を呼んでみるための道具。
///
/// `notifyListeners` がスナップショットを取ってから回している前提を、
/// 「通知中に足しても例外にならず、その場の通知には乗らない」という
/// 観測可能な形で確かめる。
private final class MutatingListener: FluseConnectionListener {
    private weak var connection: FluseConnection?
    private let toAdd: FluseConnectionListener

    init(connection: FluseConnection, toAdd: FluseConnectionListener) {
        self.connection = connection
        self.toAdd = toAdd
    }

    func onConnected(sessionId: String) {
        connection?.addListener(toAdd)
    }

    func onRejected(code: String, message: String) {}
    func onNeedsPairing(reason: String) {}
    func onDisconnected() {}
    func onMessage(_ message: FluseMessage) {}
}

/// 自分自身を、通知されている最中に `removeListener` してみるための道具。
private final class SelfRemovingListener: FluseConnectionListener {
    private weak var connection: FluseConnection?
    private(set) var connected: [String] = []

    init(connection: FluseConnection) {
        self.connection = connection
    }

    func onConnected(sessionId: String) {
        connected.append(sessionId)
        connection?.removeListener(self)
    }

    func onRejected(code: String, message: String) {}
    func onNeedsPairing(reason: String) {}
    func onDisconnected() {}
    func onMessage(_ message: FluseMessage) {}
}

/// 待たずに、待ち時間だけ記録する。
///
/// 移植元: `FluseConnectionTest.kt` の `RecordingScheduler`。
final class RecordingScheduler: RetryScheduler {
    private let lock = NSLock()
    private var recorded: [Int] = []
    private var actions: [() -> Void] = []

    var delays: [Int] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func schedule(delayMs: Int, action: @escaping () -> Void) {
        lock.lock()
        recorded.append(delayMs)
        actions.append(action)
        lock.unlock()
    }

    /// 予約された処理を1つ実行する。
    func runNext() {
        lock.lock()
        let action = actions.removeFirst()
        lock.unlock()
        action()
    }
}

/// `FluseConnectionStore` の in-memory フェイク。
final class MemoryConnectionStore: FluseConnectionStore {
    var deviceToken: String?
    var lastHost: String?
    var lastPort: Int?
}
