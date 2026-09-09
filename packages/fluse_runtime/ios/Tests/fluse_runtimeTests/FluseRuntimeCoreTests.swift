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
}
