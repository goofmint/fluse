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
        // `close(reason:)` は `detach()` を自分で先に呼んでから閉じにいく
        // （`FluseSocket.swift` の `Handle.close` 参照）。以後サーバ側で何が
        // 起きても、`onClosed`/`onFailure` は二度と呼ばれないはず。
        let recorder = RecordingSocketEvents()
        let socket = open(recorder)
        guard let peer = server.peer(timeout: timeout) else {
            return XCTFail("端末が繋いできませんでした")
        }
        XCTAssertTrue(recorder.waitForOpen(timeout: timeout))

        socket.close(reason: "テスト")
        // サーバ側からも重ねて閉じにいく。detach 済みなら、これで増えない。
        peer.closeGracefully()
        peer.cancel()

        // 「呼ばれない」ことを確かめるテストなので、届かないことを見届けるだけの
        // 猶予を実際に待つ。ここは `sleep` ではなく「起こらないはずのことが
        // 起きていないか」を一定時間観測する待ち（`XCTWaiter` の逆待ち相当）。
        let unexpected = XCTestExpectation(description: "unexpected closed/failure callback")
        unexpected.isInverted = true
        recorder.onExtraTerminalCallback = { unexpected.fulfill() }
        wait(for: [unexpected], timeout: 0.5)

        XCTAssertLessThanOrEqual(recorder.closedCount + recorder.failureCount, 1)
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
    private(set) var closedCount = 0
    private(set) var failureCount = 0

    /// 2回目以降の `onClosed`/`onFailure`（本来起きてはいけない）を知らせる。
    var onExtraTerminalCallback: (() -> Void)?

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
        closedCount += 1
        let isExtra = closedCount + failureCount > 1
        lock.unlock()
        if isExtra { onExtraTerminalCallback?() }
    }

    func onFailure(_ error: Error) {
        lock.lock()
        failureCount += 1
        let isExtra = closedCount + failureCount > 1
        lock.unlock()
        if isExtra { onExtraTerminalCallback?() }
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
            return self.closedCount + self.failureCount >= 1
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
