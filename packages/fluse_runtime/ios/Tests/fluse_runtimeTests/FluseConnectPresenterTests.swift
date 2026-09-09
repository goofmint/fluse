import XCTest

@testable import fluse_runtime

/// `FluseConnectPresenter` の判断だけを、`UIKit` / `AVFoundation` に触れずに確かめる。
///
/// 対応する Kotlin テストは無い（`FluseConnectActivity.kt` は Android の
/// `ComponentActivity` に判断を持たせたままで、iOS 側でだけ切り出した層）。
final class FluseConnectPresenterTests: XCTestCase {
    private let appInfo = FluseAppInfo(
        projectId: "0123456789abcdef",
        flutterRevision: "00b0c91f2a3b4c5d",
        dartVersion: "3.5.0",
        appVersion: "fedcba9876543210"
    )

    /// テスト用のトークン。リテラルで書かない（`FluseConnectUriTests` と同じ規約）。
    private var token: String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    private func validQr(token: String) -> String {
        "fluse://connect?v=1&h=192.168.0.10&p=8180" +
            "&pid=0123456789abcdef&t=\(token)&rev=00b0c91f"
    }

    private func makePresenter() -> FluseConnectPresenter {
        FluseConnectPresenter(appInfo: appInfo)
    }

    // ---------------------------------------------------------------- カメラ

    func testCameraUnavailableSwitchesToManualAndShowsNoCameraMessage() {
        let presenter = makePresenter()

        let actions = presenter.cameraUnavailable()

        XCTAssertEqual([.switchToManual(message: FluseConnectStrings.errorNoCamera)], actions)
        XCTAssertTrue(presenter.isManualPaneActive)
    }

    func testSwitchToManualRequestedShowsManualHint() {
        let presenter = makePresenter()

        let actions = presenter.switchToManualRequested()

        XCTAssertEqual([.switchToManual(message: FluseConnectStrings.manualHint)], actions)
        XCTAssertTrue(presenter.isManualPaneActive)
    }

    // ------------------------------------------------------------------ QR

    func testScannedValidQrBeginsConnectAndMarksConnecting() {
        let presenter = makePresenter()
        let t = token
        let qr = validQr(token: t)

        let actions = presenter.scanned(qr)

        guard case let .accepted(request) = FluseConnectUri.parse(qr) else {
            return XCTFail("テスト用の QR 自体が解けなかった")
        }
        XCTAssertEqual([.beginConnect(request)], actions)
        XCTAssertTrue(presenter.isConnecting)
    }

    func testScannedInvalidQrShowsScanMessageAndResumes() {
        let presenter = makePresenter()

        let actions = presenter.scanned("https://example.com/")

        XCTAssertEqual(
            [.showScanMessage(FluseConnectStrings.errorNotFluse), .resumeScanning],
            actions
        )
        XCTAssertFalse(presenter.isConnecting)
    }

    func testScannedIsIgnoredWhileConnecting() {
        let presenter = makePresenter()
        _ = presenter.scanned(validQr(token: token))
        XCTAssertTrue(presenter.isConnecting)

        // 繋ぎに行っている間に別の QR が写り込んでも、二重に扱わない。
        let actions = presenter.scanned(validQr(token: token))

        XCTAssertEqual([], actions)
    }

    func testScannedQrThatFailsVerifyShowsScanMessageAndResumes() {
        // pid が異なる = projectMismatch。parse は通るが verify で弾かれる。
        let presenter = makePresenter()
        let qr = validQr(token: token).replacingOccurrences(
            of: "pid=0123456789abcdef",
            with: "pid=ffffffffffffffff"
        )

        let actions = presenter.scanned(qr)

        XCTAssertEqual(
            [.showScanMessage(FluseConnectStrings.errorProject), .resumeScanning],
            actions
        )
        XCTAssertFalse(presenter.isConnecting)
    }

    // -------------------------------------------------------------- 手入力

    func testManualSubmittedValidInputBeginsConnect() {
        let presenter = makePresenter()
        _ = presenter.cameraUnavailable()
        let t = token

        let actions = presenter.manualSubmitted(host: "192.168.0.10", port: "8180", token: t)

        guard actions.count == 1, case let .beginConnect(request) = actions[0] else {
            return XCTFail("beginConnect が返らなかった: \(actions)")
        }
        XCTAssertEqual("192.168.0.10", request.host)
        XCTAssertEqual(8180, request.port)
        XCTAssertEqual(t, request.pairingToken)
        XCTAssertTrue(presenter.isConnecting)
    }

    func testManualSubmittedInvalidInputShowsManualMessageOnly() {
        let presenter = makePresenter()
        _ = presenter.cameraUnavailable()

        // ポートが数字ではない。
        let actions = presenter.manualSubmitted(host: "192.168.0.10", port: "abc", token: token)

        XCTAssertEqual([.showManualMessage(FluseConnectStrings.errorMalformed)], actions)
        XCTAssertFalse(presenter.isConnecting)
    }

    func testManualSubmittedIsIgnoredWhileConnecting() {
        let presenter = makePresenter()
        _ = presenter.cameraUnavailable()
        _ = presenter.manualSubmitted(host: "192.168.0.10", port: "8180", token: token)
        XCTAssertTrue(presenter.isConnecting)

        let actions = presenter.manualSubmitted(host: "192.168.0.10", port: "8180", token: token)

        XCTAssertEqual([], actions)
    }

    // ------------------------------------------------------- 接続結果（成功）

    func testConnectedFinishesAndMarksEstablished() {
        let presenter = makePresenter()
        _ = presenter.scanned(validQr(token: token))

        let actions = presenter.connected(sessionId: "s-1")

        XCTAssertEqual([.finish], actions)
        XCTAssertTrue(presenter.isEstablished)
    }

    // ------------------------------------------------------- 接続結果（失敗）

    func testRejectedShowsScanMessageWhenScanPaneIsActiveAndResumesScanning() {
        let presenter = makePresenter()
        _ = presenter.scanned(validQr(token: token))

        let actions = presenter.rejected(code: "TOO_MANY_DEVICES", message: "too many")

        XCTAssertEqual(
            [.showScanMessage(FluseConnectStrings.errorTooManyDevices), .resumeScanning],
            actions
        )
        XCTAssertFalse(presenter.isConnecting)
    }

    func testRejectedShowsManualMessageWhenManualPaneIsActive() {
        let presenter = makePresenter()
        _ = presenter.cameraUnavailable()
        _ = presenter.manualSubmitted(host: "192.168.0.10", port: "8180", token: token)

        let actions = presenter.rejected(code: "PROJECT_MISMATCH", message: "mismatch")

        XCTAssertEqual(
            [.showManualMessage(FluseConnectStrings.errorProject), .resumeScanning],
            actions
        )
    }

    func testRejectedWithUnknownCodeStillShowsAMessage() {
        // 未知のコードでも黙らない。
        let presenter = makePresenter()
        _ = presenter.scanned(validQr(token: token))

        let actions = presenter.rejected(code: "SOMETHING_NEW", message: "?")

        XCTAssertEqual(
            [.showScanMessage(FluseConnectStrings.errorMalformed), .resumeScanning],
            actions
        )
    }

    func testNeedsPairingShowsAuthErrorAndResetsConnecting() {
        let presenter = makePresenter()
        _ = presenter.scanned(validQr(token: token))

        let actions = presenter.needsPairing(reason: "auth failed")

        XCTAssertEqual(
            [.showScanMessage(FluseConnectStrings.errorAuth), .resumeScanning],
            actions
        )
        XCTAssertFalse(presenter.isConnecting)
    }

    /// 実際に塞がれたと分かった時は失敗として扱う（文言はそのまま出す）。
    func testConfirmedCleartextBlockedIsTreatedAsFailure() {
        let presenter = makePresenter()
        _ = presenter.scanned(validQr(token: token))

        let actions = presenter.cleartextBlocked(
            message: "ATS の設定を直してください",
            certainty: .confirmed
        )

        XCTAssertEqual(
            [.showScanMessage("ATS の設定を直してください"), .resumeScanning],
            actions
        )
        XCTAssertFalse(presenter.isConnecting)
    }

    /// **事前通知では接続中の状態を解除しない。**
    ///
    /// 事前判定の時点では接続はまだ走っている。ここで失敗として扱うと
    /// 再スキャンが効くようになり、1本目の裏で2本目の connect() を
    /// 始められてしまう。
    func testSuspectedCleartextBlockedKeepsConnecting() {
        let presenter = makePresenter()
        _ = presenter.scanned(validQr(token: token))

        let actions = presenter.cleartextBlocked(
            message: "塞がれている可能性があります",
            certainty: .suspected
        )

        XCTAssertEqual([.showScanMessage("塞がれている可能性があります")], actions)
        // 再スキャンを促していないこと。
        XCTAssertFalse(actions.contains(.resumeScanning))
        XCTAssertTrue(presenter.isConnecting)
    }

    func testDisconnectedBeforeEstablishedIsTreatedAsFailure() {
        let presenter = makePresenter()
        _ = presenter.scanned(validQr(token: token))

        let actions = presenter.disconnected()

        XCTAssertEqual(
            [.showScanMessage(FluseConnectStrings.errorConnect), .resumeScanning],
            actions
        )
        XCTAssertFalse(presenter.isConnecting)
    }

    func testDisconnectedAfterEstablishedDoesNothing() {
        let presenter = makePresenter()
        _ = presenter.scanned(validQr(token: token))
        _ = presenter.connected(sessionId: "s-1")

        let actions = presenter.disconnected()

        XCTAssertEqual([], actions)
    }

    func testConnectFailedToStartShowsConnectError() {
        let presenter = makePresenter()
        _ = presenter.scanned(validQr(token: token))

        let actions = presenter.connectFailedToStart()

        XCTAssertEqual(
            [.showScanMessage(FluseConnectStrings.errorConnect), .resumeScanning],
            actions
        )
        XCTAssertFalse(presenter.isConnecting)
    }

    /// 失敗メッセージの振り先は、要求を出した時点の面ではなく、
    /// 「今見えている面」で決まる（Android 版の `showError()` と同じ判断）。
    func testFailureMessageRoutingFollowsTheCurrentlyActivePaneNotTheRequestSource() {
        let presenter = makePresenter()
        _ = presenter.scanned(validQr(token: token))
        // 接続を待っている間に手入力へ切り替えた。
        _ = presenter.switchToManualRequested()

        let actions = presenter.rejected(code: "AUTH_FAILED", message: "auth failed")

        XCTAssertEqual(
            [.showManualMessage(FluseConnectStrings.errorAuth), .resumeScanning],
            actions
        )
    }
}
