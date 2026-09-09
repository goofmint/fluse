import XCTest

@testable import fluse_runtime

/// `FluseConnection` が `FluseATSCheck` をどう配線しているかを見る。
///
/// Task 9.7（Issue #95）: `FluseConnectionListener.onCleartextBlocked` は
/// Task 9.3 の時点では形だけあってどこからも呼ばれていなかった
/// （`FluseConnection.swift` の当時のコメント参照）。ここでは
///   1. `connect()` からの事前判定（Info.plist の宣言が無ければ、接続は
///      続けつつ早めに知らせる）
///   2. `Events.onFailure` からの受動判定（`URLError` -1022 のときだけ
///      特別に知らせ、それ以外の失敗は通常の切断処理のまま）
/// の2つの配線を確かめる。状態機械そのもの（`hello` の組み立てや
/// バックオフ）は `FluseConnectionTests.swift` の対象であり、ここでは
/// 重複させない。
///
/// 対応する Kotlin テストは無い（`FluseCleartext` の呼び出し元である
/// Android の `FluseConnection.kt` は本 Issue の対象外）。この配線は
/// iOS 側でのみ追加した振る舞いのため。
final class FluseATSCheckWiringTests: XCTestCase {
    private let appInfo = FluseAppInfo(
        projectId: "0123456789abcdef",
        flutterRevision: "00b0c91f",
        dartVersion: "3.5.0",
        appVersion: "fedcba9876543210"
    )
    private let device = FluseDeviceInfo(deviceId: "a1b2c3d4e5f60718", deviceName: "Google Pixel 8")
    private let endpoint = FluseEndpoint(host: "192.168.1.2", port: 8180)

    private struct Fixture {
        let sockets: FakeSocketFactory
        let scheduler: RecordingScheduler
        let connection: FluseConnection
        let listener: RecordingListener
    }

    private func fixture(atsAllowed: Bool) -> Fixture {
        let store = MemoryConnectionStore()
        let sockets = FakeSocketFactory()
        let scheduler = RecordingScheduler()
        let connection = FluseConnection(
            store: store,
            device: device,
            appInfo: appInfo,
            socketFactory: sockets,
            scheduler: scheduler,
            atsLocalNetworkingAllowed: { atsAllowed }
        )
        let listener = RecordingListener()
        connection.addListener(listener)
        return Fixture(sockets: sockets, scheduler: scheduler, connection: connection, listener: listener)
    }

    // ------------------------------------------------------------ 事前判定

    func testNotifiesCleartextBlockedWhenNotDeclared() {
        let f = fixture(atsAllowed: false)

        f.connection.connect(endpoint: endpoint)

        XCTAssertEqual(1, f.listener.cleartextBlocked.count)
        XCTAssertEqual(endpoint.host, f.listener.cleartextBlocked[0].host)
        XCTAssertTrue(f.listener.cleartextBlocked[0].message.contains(endpoint.host))
    }

    func testStillAttemptsToConnectWhenNotDeclared() {
        // **宣言が無いだけで接続自体は諦めない。** 独自の ATS 例外設定次第
        // では実際には通ることがあるため（`FluseConnection.connect` の
        // コメント参照）。
        let f = fixture(atsAllowed: false)

        f.connection.connect(endpoint: endpoint)

        XCTAssertEqual(1, f.sockets.opened.count)
    }

    func testDoesNotNotifyWhenDeclared() {
        let f = fixture(atsAllowed: true)

        f.connection.connect(endpoint: endpoint)

        XCTAssertTrue(f.listener.cleartextBlocked.isEmpty)
    }

    // ------------------------------------------------------------ 受動判定

    func testNotifiesCleartextBlockedOnAtsUrlError() {
        let f = fixture(atsAllowed: true)
        f.connection.connect(endpoint: endpoint)
        f.sockets.latest.open()

        f.sockets.latest.fail(NSError(domain: NSURLErrorDomain, code: -1022, userInfo: nil))

        XCTAssertEqual(1, f.listener.cleartextBlocked.count)
        XCTAssertEqual(endpoint.host, f.listener.cleartextBlocked[0].host)
    }

    func testStillRunsNormalDisconnectHandlingOnAtsFailure() {
        // ATS 由来でも、バックオフ再接続の経路自体は変えない
        // （`FluseConnection.handleATSFailure` のコメント参照）。
        let f = fixture(atsAllowed: true)
        f.connection.connect(endpoint: endpoint)
        f.sockets.latest.open()

        f.sockets.latest.fail(NSError(domain: NSURLErrorDomain, code: -1022, userInfo: nil))

        XCTAssertEqual(1, f.listener.disconnected)
        XCTAssertEqual(1, f.scheduler.delays.count)
    }

    func testDoesNotNotifyCleartextBlockedOnUnrelatedFailure() {
        let f = fixture(atsAllowed: true)
        f.connection.connect(endpoint: endpoint)
        f.sockets.latest.open()

        f.sockets.latest.fail()

        XCTAssertTrue(f.listener.cleartextBlocked.isEmpty)
        XCTAssertEqual(1, f.listener.disconnected)
    }

    func testDoesNotNotifyCleartextBlockedOnUnrelatedUrlErrorCode() {
        let f = fixture(atsAllowed: true)
        f.connection.connect(endpoint: endpoint)
        f.sockets.latest.open()

        // -1004 は「サーバに繋がらない」。ATS の話ではない。
        f.sockets.latest.fail(NSError(domain: NSURLErrorDomain, code: -1004, userInfo: nil))

        XCTAssertTrue(f.listener.cleartextBlocked.isEmpty)
    }
}
