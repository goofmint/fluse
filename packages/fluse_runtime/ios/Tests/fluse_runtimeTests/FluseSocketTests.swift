import XCTest

@testable import fluse_runtime

/**
 * `URLSessionFluseSocketFactory`（`FluseSocket.swift`）自身の配線を確かめる。
 *
 * **Kotlin 側に対応するテストは無い。** Kotlin 版はソケット層を素の OkHttp に
 * 委ねており、その正しさはライブラリの責任範囲になる。Swift 版は
 * `URLSessionWebSocketDelegate` / `URLSessionTaskDelegate` の2系統の
 * コールバックから1本の `FluseSocketEvents` を組み立て直す薄い層
 * （`Adapter`）を自前で書いており、ここが壊れると『閉じたはずのソケットの
 * 通知が二重に届く』『受信が2本同時に飛ぶ』といった Kotlin 版には無い
 * 事故が起こりうる。ここではその配線だけを、実際の `URLSessionWebSocketTask`
 * とローカルサーバ（`LocalWebSocketTestServer`）を使って確かめる。
 *
 * `FluseConnection` を経由しない、`FluseSocket` 単体のテスト。
 * `FluseConnection` 込みの確認は `FluseConnectionServerTests` を見ること。
 */
final class FluseSocketTests: XCTestCase {
    private let timeout: TimeInterval = 10

    private var server: LocalWebSocketTestServer!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let server = LocalWebSocketTestServer()
        try server.start()
        self.server = server
    }

    override func tearDown() {
        server.stop()
        super.tearDown()
    }

    private func open(_ events: FluseSocketEvents) -> FluseSocket {
        URLSessionFluseSocketFactory().open(url: server.url, events: events)
    }

    func testOnOpenFiresAfterRealHandshake() {
        let recorder = RecordingSocketEvents()
        _ = open(recorder)

        XCTAssertTrue(recorder.waitForOpen(timeout: timeout), "onOpen が呼ばれませんでした")
    }

    func testSendTextReachesTheServerAsIs() {
        let recorder = RecordingSocketEvents()
        let socket = open(recorder)
        guard let peer = server.peer(timeout: timeout) else {
            return XCTFail("端末が繋いできませんでした")
        }

        XCTAssertTrue(socket.sendText(HelloMessageFixture.json))
        guard let received = peer.take(timeout: timeout) as? HelloMessage else {
            return XCTFail("サーバに届きませんでした")
        }
        XCTAssertEqual("0123456789abcdef", received.projectId)
    }

    func testReceiveLoopStaysSingleForBackToBackMessages() {
        // 受信を2本同時に飛ばすと `URLSessionWebSocketTask` は片方を
        // 取りこぼしうる（`Adapter.startReceiving` のコメント参照）。
        // 連続して送っても順番どおり全部届くことで、1本に保たれていることを見る。
        let recorder = RecordingSocketEvents()
        _ = open(recorder)
        guard let peer = server.peer(timeout: timeout) else {
            return XCTFail("端末が繋いできませんでした")
        }
        XCTAssertTrue(recorder.waitForOpen(timeout: timeout))

        for index in 0..<20 {
            peer.send(LogMessage(level: "info", message: "m\(index)"))
        }

        XCTAssertTrue(recorder.waitForTextCount(20, timeout: timeout), "受け取った件数: \(recorder.texts.count)")
        let messages = recorder.texts.compactMap { text -> LogMessage? in
            guard
                let data = text.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let message = try? FluseMessageDecoder.fromJson(json) as? LogMessage
            else { return nil }
            return message
        }
        XCTAssertEqual((0..<20).map { "m\($0)" }, messages.map(\.message), "順序が崩れているか、取りこぼしています")
    }

    func testCloseCalledByUsSuppressesLaterClosedAndFailureCallbacks() {
        // `close(reason:)` は `Adapter.detach()` を `task.cancel` より **前に**
        // 実行してから閉じにいく（`FluseSocket.swift` の `Handle.close`
        // 参照）。よって、この経路では `onClosed`/`onFailure` は一度も
        // 呼ばれないはず（指摘4対応：「高々1回」ではなく「ちょうど0回」を
        // 検証する）。
        let recorder = RecordingSocketEvents()
        let socket = open(recorder)
        guard let peer = server.peer(timeout: timeout) else {
            return XCTFail("端末が繋いできませんでした")
        }
        XCTAssertTrue(recorder.waitForOpen(timeout: timeout))

        // 「呼ばれない」ことを確かめるテストなので、届かないことを見届けるだけの
        // 猶予を実際に待つ。ここは `sleep` ではなく「起こらないはずのことが
        // 起きていないか」を一定時間観測する待ち（`XCTWaiter` の逆待ち相当）。
        //
        // **`close()`/`cancel()` より前に設定する。** 後に置くと、設定する
        // 前に非同期コールバックが飛んだ場合にそれを取りこぼしてしまう
        // （指摘4対応）。
        let unexpected = XCTestExpectation(description: "unexpected closed/failure callback")
        unexpected.isInverted = true
        recorder.onExtraTerminalCallback = { unexpected.fulfill() }

        socket.close(reason: "テスト")
        // サーバ側からも重ねて閉じにいく。detach 済みなら、これで増えない。
        peer.closeGracefully()
        peer.cancel()

        wait(for: [unexpected], timeout: 0.5)

        XCTAssertEqual(0, recorder.closedCount + recorder.failureCount)
    }

    func testServerSideDisconnectFiresExactlyOneTerminalCallback() {
        // `task.receive` の失敗と `didCloseWith` はどちらも独立した経路から
        // 非同期に届き、レースする。`detach()` の早い者勝ちで、
        // どちらか一方だけが `FluseConnection` に伝わることを確かめる
        // （両方伝わると `onDisconnected` が二重に呼ばれ、バックオフが
        // 余計に進んでしまう）。
        let recorder = RecordingSocketEvents()
        _ = open(recorder)
        guard let peer = server.peer(timeout: timeout) else {
            return XCTFail("端末が繋いできませんでした")
        }
        XCTAssertTrue(recorder.waitForOpen(timeout: timeout))

        peer.closeGracefully()

        XCTAssertTrue(recorder.waitForTerminal(timeout: timeout), "onClosed も onFailure も呼ばれませんでした")
        // レース次第でどちらが呼ばれるかは決まらないが、合計はちょうど1回。
        XCTAssertEqual(1, recorder.closedCount + recorder.failureCount)
    }
}

// ------------------------------------------------------------------ テスト用

/// `FluseSocketEvents` の呼ばれ方をそのまま記録する。
///
/// `FluseConnection` を経由しないため、`FluseConnectionTests` の
/// `RecordingListener` とは別に、生のコールバック回数を数えられる形にしてある。
private final class RecordingSocketEvents: FluseSocketEvents {
    private let lock = NSLock()
    private var openedFlag = false
    private var textList: [String] = []
    private var closedCountValue = 0
    private var failureCountValue = 0
    private var onExtraTerminalCallbackValue: (() -> Void)?

    var closedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return closedCountValue
    }

    var failureCount: Int {
        lock.lock(); defer { lock.unlock() }
        return failureCountValue
    }

    /// 2回目以降の `onClosed`/`onFailure`（本来起きてはいけない）を知らせる。
    ///
    /// **カウンタと同じ `NSLock` で保護する。** `onClosed`/`onFailure` は
    /// ロックを解放した後にこのプロパティを読み出し、テストスレッドは
    /// 任意のタイミングでこれを書き込む。無防備な `var` のままだと
    /// データ競合になる（指摘4対応）。
    var onExtraTerminalCallback: (() -> Void)? {
        get {
            lock.lock(); defer { lock.unlock() }
            return onExtraTerminalCallbackValue
        }
        set {
            lock.lock(); defer { lock.unlock() }
            onExtraTerminalCallbackValue = newValue
        }
    }

    var texts: [String] {
        lock.lock(); defer { lock.unlock() }
        return textList
    }

    func onOpen() {
        lock.lock(); openedFlag = true; lock.unlock()
    }

    func onText(_ text: String) {
        lock.lock(); textList.append(text); lock.unlock()
    }

    func onBinary(_ frame: Data) {}

    func onClosed(_ reason: String) {
        lock.lock()
        closedCountValue += 1
        let isExtra = closedCountValue + failureCountValue > 1
        // **コールバックはロック内で取得し、ロックの外で実行する。** 握った
        // まま呼ぶと、コールバック側（`XCTestExpectation.fulfill()` など）が
        // 何らかの経路でこのロックを取ろうとした場合にデッドロックしうる
        // （指摘4対応）。
        let callback = onExtraTerminalCallbackValue
        lock.unlock()
        if isExtra { callback?() }
    }

    func onFailure(_ error: Error) {
        lock.lock()
        failureCountValue += 1
        let isExtra = closedCountValue + failureCountValue > 1
        let callback = onExtraTerminalCallbackValue
        lock.unlock()
        if isExtra { callback?() }
    }

    func waitForOpen(timeout: TimeInterval) -> Bool {
        pollUntil(timeout: timeout) {
            self.lock.lock(); defer { self.lock.unlock() }
            return self.openedFlag
        }
    }

    func waitForTextCount(_ count: Int, timeout: TimeInterval) -> Bool {
        pollUntil(timeout: timeout) {
            self.lock.lock(); defer { self.lock.unlock() }
            return self.textList.count >= count
        }
    }

    func waitForTerminal(timeout: TimeInterval) -> Bool {
        pollUntil(timeout: timeout) {
            self.lock.lock(); defer { self.lock.unlock() }
            return self.closedCountValue + self.failureCountValue >= 1
        }
    }

    private func pollUntil(timeout: TimeInterval, check: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if check() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return check()
    }
}

/// リテラルの JSON を直書きしない代わりに、実物の `HelloMessage` から作る。
private enum HelloMessageFixture {
    static var json: String {
        let message = HelloMessage(
            protocolVersion: Int64(fluseProtocolVersion),
            projectId: "0123456789abcdef",
            flutterRevision: "00b0c91f",
            dartVersion: "3.5.0",
            appVersion: "fedcba9876543210",
            deviceId: "a1b2c3d4e5f60718",
            deviceName: "Google Pixel 8"
        )
        let data = try! JSONSerialization.data(withJSONObject: message.toJson())
        return String(data: data, encoding: .utf8)!
    }
}
