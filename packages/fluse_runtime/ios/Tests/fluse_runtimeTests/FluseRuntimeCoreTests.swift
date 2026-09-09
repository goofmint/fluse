import XCTest

@testable import fluse_runtime

/// 認証コードのマスクと、最新 URI の冪等な保持だけを見る。
///
/// `MethodChannel` の配線は Flutter エンジンが要るので、ここでは扱わない
/// （Kotlin 側の `FluseRuntimePluginTest` と同じ方針）。
final class FluseRuntimeCoreTests: XCTestCase {
    /// 認証コードらしい文字列を組み立てる。
    ///
    /// **直書きしない。** ダミーでも接続トークンの literal は置かない規約
    /// （設計 §6.1）。パスセグメントそのものが資格情報なので、形だけ
    /// 本物に似せて実行時に作る。
    private func authCode(_ length: Int = 12) -> String {
        (0..<length)
            .map { index -> String in
                let scalar = UnicodeScalar(UInt8(97 + index % 26))
                return String(Character(scalar))
            }
            .joined()
    }

    func testMasksAuthCode() {
        let code = authCode()

        let masked = FluseRuntimeCore.maskAuthCode("http://127.0.0.1:45123/\(code)/")

        XCTAssertFalse(masked.contains(code), "認証コードが残っている: \(masked)")
        XCTAssertTrue(masked.hasPrefix("http://127.0.0.1:45123/"), masked)
        XCTAssertTrue(masked.contains("***"), masked)
    }

    func testKeepsOnlyFirstFourCharacters() {
        let code = authCode(10)

        let masked = FluseRuntimeCore.maskAuthCode("http://127.0.0.1:1/\(code)/")

        XCTAssertEqual(masked, "http://127.0.0.1:1/\(code.prefix(4))***/")
    }

    func testShortPathIsNotTreatedAsAuthCode() {
        // /health のような普通のパスを巻き込まない。
        let uri = "http://127.0.0.1:1/health"

        XCTAssertEqual(FluseRuntimeCore.maskAuthCode(uri), uri)
    }

    func testReturnsAsIsWhenNoPath() {
        let uri = "http://127.0.0.1:1"

        XCTAssertEqual(FluseRuntimeCore.maskAuthCode(uri), uri)
    }

    func testReturnsAsIsWhenNotAUri() {
        XCTAssertEqual(FluseRuntimeCore.maskAuthCode("なにか"), "なにか")
    }

    func testMasksOnlyTheFirstSegment() {
        // 認証コードは先頭の1セグメント。後続まで潰すと形が変わる。
        let code = authCode(10)

        let masked = FluseRuntimeCore.maskAuthCode("ws://127.0.0.1:1/\(code)/ws")

        XCTAssertEqual(masked, "ws://127.0.0.1:1/\(code.prefix(4))***/ws")
    }

    func testStoringTheSameUriTwiceIsIdempotent() {
        let code = authCode()
        let uri = "http://127.0.0.1:1/\(code)/"

        FluseRuntimeCore.handleVmServiceReady(uri)
        XCTAssertEqual(FluseRuntimeCore.latestVmServiceUri, uri)

        // Hot Restart のたびに同じ URI が再送される。上書きしても
        // 同じ値のままであること（例外や状態の乱れが起きない）。
        FluseRuntimeCore.handleVmServiceReady(uri)
        XCTAssertEqual(FluseRuntimeCore.latestVmServiceUri, uri)
    }

    func testStoresTheLatestUri() {
        let first = "http://127.0.0.1:1/\(authCode())/"
        let second = "http://127.0.0.1:2/\(authCode())/"

        FluseRuntimeCore.handleVmServiceReady(first)
        FluseRuntimeCore.handleVmServiceReady(second)

        XCTAssertEqual(FluseRuntimeCore.latestVmServiceUri, second)
    }

    /// マスクの強さが実装言語で変わらないこと。
    ///
    /// サーバ側の `maskToken` は Dart の `substring`（UTF-16 単位）で
    /// 切る。Swift の `prefix` は書記素単位なので、そのまま書くと
    /// `😀abcde` で Swift だけ1文字多く残ってしまう。
    func testMaskSecretCountsUtf16UnitsLikeDart() {
        // 😀 は UTF-16 で2単位。先頭4単位は "😀ab"。
        XCTAssertEqual("😀ab***", FluseRuntimeCore.maskSecret("😀abcde"))
    }

    /// 短い値は丸ごと隠す（4文字を残すと元の値がそのまま残るため）。
    func testMaskSecretHidesShortValuesEntirely() {
        XCTAssertEqual("***", FluseRuntimeCore.maskSecret("abcd"))
        XCTAssertEqual("abcd***", FluseRuntimeCore.maskSecret("abcde"))
    }

    // ------------------------------------------------------ FluseConnection への転送

    /// Task 9.5（Issue #93）で解消した TODO: `FluseConnection` が用意された
    /// （Task 9.3）以上、受け取った URI はその場で転送されること。
    ///
    /// `FluseConnection.instance` はプロセス全体で共有される静的な状態
    /// なので、他のテストへ漏れないよう必ず `install(nil)` で後始末する
    /// （`FluseConnectionTests.swift` / `FluseATSCheckWiringTests.swift` は
    /// この静的インスタンスを使わないため、通常は競合しないが念のため）。
    func testForwardsToTheInstalledConnectionWhenAlreadyAuthenticated() {
        let store = MemoryConnectionStore()
        let sockets = FakeSocketFactory()
        let device = FluseDeviceInfo(deviceId: "a1b2c3d4e5f60718", deviceName: "iPhone")
        let appInfo = FluseAppInfo(
            projectId: "0123456789abcdef",
            flutterRevision: "00b0c91f",
            dartVersion: "3.5.0",
            appVersion: "fedcba9876543210"
        )
        let connection = FluseConnection(
            store: store,
            device: device,
            appInfo: appInfo,
            socketFactory: sockets,
            scheduler: RecordingScheduler()
        )
        FluseConnection.install(connection)
        defer { FluseConnection.install(nil) }

        connection.connect(endpoint: FluseEndpoint(host: "127.0.0.1", port: 1), pairingToken: "pairing-value")
        sockets.latest.open()
        sockets.latest.receive(AcceptMessage(sessionId: "s-1", heartbeatIntervalMs: 1_000))

        let code = authCode()
        let uri = "http://127.0.0.1:1/\(code)/"
        FluseRuntimeCore.handleVmServiceReady(uri)

        let sent: VmServiceReadyMessage = sockets.latest.sentAs(1)
        XCTAssertEqual(uri, sent.vmServiceUri)
    }

    /// 接続が無い間に届いた URI は、型に持たせた `latestVmServiceUri` に
    /// 残るだけで例外にはならない（`FluseConnection.instance` が `nil` の
    /// ときに転送先を強制的に必要としないこと）。
    func testDoesNotThrowWhenNoConnectionIsInstalled() {
        FluseConnection.install(nil)
        let code = authCode()
        let uri = "http://127.0.0.1:1/\(code)/"

        FluseRuntimeCore.handleVmServiceReady(uri)

        XCTAssertEqual(FluseRuntimeCore.latestVmServiceUri, uri)
    }
}
