import XCTest

@testable import fluse_runtime

/**
 * 実際に WebSocket を張って `FluseConnection` を確かめる（Issue #91 / Task 9.3）。
 *
 * `FluseConnectionTests` が状態機械を、こちらが `URLSessionFluseSocketFactory`
 * との繋ぎ込みを見る。差し替えたソケットだけで通しても、実装が実ソケットで
 * 動く保証にはならない。
 *
 * 移植元: `packages/fluse_runtime/android/src/test/kotlin/dev/fluse/runtime/FluseConnectionServerTest.kt`
 * サーバ役は Kotlin の `MockWebServer`（OkHttp 付属）の代わりに、
 * `Network.framework` で組んだ `LocalWebSocketTestServer` を使う
 * （`LocalWebSocketTestServer.swift` のヘッダ参照）。
 *
 * **`sleep` は使わない。** 到着待ちはすべてポーリング＋タイムアウト
 * （`ServerPeer.take` / `LocalWebSocketTestServer.peer`）で行う。
 */
final class FluseConnectionServerTests: XCTestCase {
    /// 実際に待つのはここだけ。CI の遅さで落ちない程度に取る。
    private let timeout: TimeInterval = 10

    private let appInfo = FluseAppInfo(
        projectId: "0123456789abcdef",
        flutterRevision: "00b0c91f",
        dartVersion: "3.5.0",
        appVersion: "fedcba9876543210"
    )
    private let device = FluseDeviceInfo(deviceId: "a1b2c3d4e5f60718", deviceName: "Google Pixel 8")

    private var server: LocalWebSocketTestServer!
    private var store: MemoryConnectionStore!
    private var scheduler: RecordingScheduler!
    private var listener: RecordingListener!
    private var connection: FluseConnection!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let server = LocalWebSocketTestServer()
        // **`start()` を呼ぶ前にプロパティへ保持する。** `start()` は
        // `NWListener` を作った後で `startTimedOut` を投げうる（リスナー自体は
        // 生きたまま失敗する）。先に代入しておけば、途中で投げても
        // `tearDown()` の `server.stop()` でそのリスナーを後始末できる
        // （指摘3対応）。
        self.server = server
        try server.start()

        store = MemoryConnectionStore()
        scheduler = RecordingScheduler()
        listener = RecordingListener()
        connection = FluseConnection(
            store: store,
            device: device,
            appInfo: appInfo,
            socketFactory: URLSessionFluseSocketFactory(),
            scheduler: scheduler
        )
        connection.addListener(listener)
    }

    override func tearDown() {
        // **先に端末側を止める。** 繋いだままサーバを畳むと、次のテストの
        // ポートに影響しうる後始末待ちが残る（Kotlin 版の tearDown と同じ配慮）。
        //
        // **nil 安全にする。** `setUpWithError` が `server.start()` で
        // 例外を投げた場合、`connection` はまだ作られておらず nil のまま
        // （`server` は上で先に代入済み）。ここで force unwrap すると本来の
        // セットアップエラーがクラッシュに隠れてしまうため、オプショナル
        // チェーンで安全に呼ぶ（指摘3対応）。
        connection?.stop()
        server?.stop()
        super.tearDown()
    }

    private func endpoint() -> FluseEndpoint {
        FluseEndpoint(host: "127.0.0.1", port: Int(server.port))
    }

    func testConnectsSendsHelloAndReceivesAccept() {
        connection.connect(endpoint: endpoint(), pairingToken: "pairing-value")

        guard let peer = server.peer(timeout: timeout) else {
            return XCTFail("端末が繋いできませんでした")
        }
        guard let hello = peer.take(timeout: timeout) as? HelloMessage else {
            return XCTFail("hello が届きませんでした")
        }
        XCTAssertEqual(appInfo.projectId, hello.projectId)
        XCTAssertEqual("pairing-value", hello.pairingToken)

        peer.send(AcceptMessage(sessionId: "s-1", heartbeatIntervalMs: 5_000, issuedDeviceToken: "issued-value"))

        XCTAssertTrue(waitUntil(timeout: timeout) { !self.listener.connected.isEmpty }, "accept が届きませんでした")
        XCTAssertEqual("issued-value", store.deviceToken)
        XCTAssertEqual(["s-1"], listener.connected)
    }

    func testRejectDoesNotRetry() {
        connection.connect(endpoint: endpoint(), pairingToken: "pairing-value")

        guard let peer = server.peer(timeout: timeout) else {
            return XCTFail("端末が繋いできませんでした")
        }
        _ = peer.take(timeout: timeout)
        peer.send(RejectMessage.of(.tooManyDevices, "1台だけです"))

        XCTAssertTrue(waitUntil(timeout: timeout) { !self.listener.rejected.isEmpty }, "reject が届きませんでした")
        XCTAssertEqual(["TOO_MANY_DEVICES"], listener.rejected)
        XCTAssertEqual([], scheduler.delays)
    }

    func testDisconnectedThenReconnectsAfterWaiting() {
        connection.connect(endpoint: endpoint())

        guard let first = server.peer(timeout: timeout) else {
            return XCTFail("端末が繋いできませんでした")
        }
        _ = first.take(timeout: timeout)
        first.closeGracefully()

        XCTAssertTrue(awaitScheduled(count: 1, timeout: timeout), "繋ぎ直しが予約されませんでした")
        XCTAssertEqual([1_000], scheduler.delays)

        // 待ち終わったことにして繋ぎ直す。実時間は待たない。
        scheduler.runNext()

        guard let second = server.peer(1, timeout: timeout) else {
            return XCTFail("繋ぎ直しの接続が来ませんでした")
        }
        XCTAssertTrue(second.take(timeout: timeout) is HelloMessage, "繋ぎ直しで hello が届きませんでした")
    }

    // ------------------------------------------------------------------ 待ち

    /// [check] が真になるまで待つ。ならなければ false。
    private func waitUntil(timeout: TimeInterval, check: @escaping () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if check() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return check()
    }

    private func awaitScheduled(count: Int, timeout: TimeInterval) -> Bool {
        waitUntil(timeout: timeout) { self.scheduler.delays.count >= count }
    }
}
