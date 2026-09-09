import XCTest

@testable import fluse_runtime

/// `FluseConnectUri` が Kotlin 側と同じ入力に同じ結果を返すかを見る。
///
/// 移植元: `packages/fluse_runtime/android/src/test/kotlin/dev/fluse/runtime/FluseConnectUriTest.kt`
/// ケースは減らさず、同じ入力・同じ期待値で移植する。
final class FluseConnectUriTests: XCTestCase {
    private let appInfo = FluseAppInfo(
        projectId: "0123456789abcdef",
        flutterRevision: "00b0c91f2a3b4c5d",
        dartVersion: "3.5.0",
        appVersion: "fedcba9876543210"
    )

    /// テスト用のトークン。
    ///
    /// **リテラルで書かない。** ダミーであっても、資格情報の形をした
    /// 文字列がリポジトリに残ると本物と見分けが付かない。
    private let token: String = (0..<16)
        .map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }
        .joined()

    private var valid: String {
        "fluse://connect?v=1&h=192.168.0.10&p=8180" +
            "&pid=0123456789abcdef&t=\(token)&rev=00b0c91f"
    }

    private func accepted(_ raw: String, file: StaticString = #filePath, line: UInt = #line) -> FluseConnectRequest {
        let result = FluseConnectUri.parse(raw)
        guard case let .accepted(request) = result else {
            XCTFail("解けませんでした: \(result)", file: file, line: line)
            return FluseConnectRequest(protocolVersion: 0, host: "", port: 0, projectId: "", pairingToken: "", revision: "")
        }
        return request
    }

    private func rejected(_ raw: String, file: StaticString = #filePath, line: UInt = #line) -> FluseConnectError {
        let result = FluseConnectUri.parse(raw)
        guard case let .rejected(error) = result else {
            XCTFail("解けてしまいました", file: file, line: line)
            return .malformed
        }
        return error
    }

    // ------------------------------------------------------------------ parse

    func testParsesTheDesignQr() {
        let request = accepted(valid)

        XCTAssertEqual(fluseProtocolVersion, request.protocolVersion)
        XCTAssertEqual("192.168.0.10", request.host)
        XCTAssertEqual(8180, request.port)
        XCTAssertEqual("0123456789abcdef", request.projectId)
        XCTAssertEqual(token, request.pairingToken)
        XCTAssertEqual("00b0c91f", request.revision)
        XCTAssertEqual(FluseEndpoint(host: "192.168.0.10", port: 8180), request.endpoint())
    }

    func testRecognizesNonFluseQrAsNotFluse() {
        // 「読み取れません」ではなく「これは fluse の QR ではない」と出したい。
        XCTAssertEqual(FluseConnectError.notFluse, rejected("https://example.com/"))
        XCTAssertEqual(FluseConnectError.notFluse, rejected("fluse://other?v=1"))
    }

    func testRejectsWhenRequiredValueIsMissing() {
        XCTAssertEqual(FluseConnectError.malformed, rejected(valid.replacingOccurrences(of: "&t=\(token)", with: "")))
        XCTAssertEqual(FluseConnectError.malformed, rejected(valid.replacingOccurrences(of: "&h=192.168.0.10", with: "")))
        XCTAssertEqual(FluseConnectError.malformed, rejected(valid.replacingOccurrences(of: "&rev=00b0c91f", with: "")))
    }

    func testRejectsWhenPortIsNotANumber() {
        XCTAssertEqual(FluseConnectError.malformed, rejected(valid.replacingOccurrences(of: "p=8180", with: "p=abc")))
    }

    func testRejectsWhenPortIsOutOfRange() {
        // 0 や 70000 で繋ぎに行っても、その場で分かる形にしておく。
        XCTAssertEqual(FluseConnectError.malformed, rejected(valid.replacingOccurrences(of: "p=8180", with: "p=0")))
        XCTAssertEqual(FluseConnectError.malformed, rejected(valid.replacingOccurrences(of: "p=8180", with: "p=70000")))
    }

    func testTrimsSurroundingWhitespace() {
        // QR リーダによっては改行が混ざる。
        XCTAssertEqual("192.168.0.10", accepted("  \(valid)\n").host)
    }

    func testDecodesPercentEncoding() {
        let request = accepted(valid.replacingOccurrences(of: "t=\(token)", with: "t=a%2Bb%2Fc"))

        XCTAssertEqual("a+b/c", request.pairingToken)
    }

    func testDoesNotLetLaterDuplicateKeyOverride() {
        // 細工した QR で繋ぎ先だけを差し替えられないようにする。
        let request = accepted("\(valid)&h=10.0.0.1")

        XCTAssertEqual("192.168.0.10", request.host)
    }

    func testDoesNotIncludeTokenInDescription() {
        // 例外文やログに混ざると漏れる。
        let request = accepted(valid)

        XCTAssertFalse(request.description.contains(token), request.description)
    }

    // ----------------------------------------------------------------- verify

    func testVerifyPassesWhenEverythingMatches() {
        XCTAssertNil(FluseConnectUri.verify(accepted(valid), appInfo: appInfo))
    }

    func testDetectsProjectMismatchImmediately() {
        // 繋ぎに行ってサーバに断られるまで待たせない。
        let other = accepted(valid.replacingOccurrences(of: "pid=0123456789abcdef", with: "pid=ffffffffffffffff"))

        XCTAssertEqual(FluseConnectError.projectMismatch, FluseConnectUri.verify(other, appInfo: appInfo))
    }

    func testDetectsRevisionMismatchImmediately() {
        let other = accepted(valid.replacingOccurrences(of: "rev=00b0c91f", with: "rev=deadbeef"))

        XCTAssertEqual(FluseConnectError.revisionMismatch, FluseConnectUri.verify(other, appInfo: appInfo))
    }

    func testDetectsProtocolMismatchImmediately() {
        let other = accepted(valid.replacingOccurrences(of: "v=1", with: "v=99"))

        XCTAssertEqual(FluseConnectError.protocolMismatch, FluseConnectUri.verify(other, appInfo: appInfo))
    }

    func testRevOnlyComparesFirstEightCharacters() {
        // QR に載るのは先頭8桁（設計 §4.2(a)）。全桁と比べると必ず外れる。
        XCTAssertNil(FluseConnectUri.verify(accepted(valid), appInfo: appInfo))
    }

    // ------------------------------------------------------------------ 手入力

    func testManualInputNormalizesTheSameWay() {
        let result = FluseConnectUri.fromManualInput(
            host: " 192.168.0.10 ",
            port: " 8180 ",
            token: " \(token) ",
            appInfo: appInfo
        )

        guard case let .accepted(request) = result else {
            return XCTFail("解けませんでした: \(result)")
        }
        XCTAssertEqual("192.168.0.10", request.host)
        XCTAssertEqual(8180, request.port)
        XCTAssertEqual(token, request.pairingToken)
        // QR に無い値はこの端末の素性で埋める。突き合わせはサーバが行う。
        XCTAssertEqual(appInfo.projectId, request.projectId)
        XCTAssertEqual("00b0c91f", request.revision)
    }

    func testRejectsEmptyManualInput() {
        let result = FluseConnectUri.fromManualInput(
            host: "",
            port: "8180",
            token: token,
            appInfo: appInfo
        )

        guard case let .rejected(error) = result else {
            return XCTFail("解けてしまいました")
        }
        XCTAssertEqual(FluseConnectError.malformed, error)
    }

    func testRejectsBlankOnlyValues() {
        // `h=%20` は decode 後も空でない文字列になり、そのまま繋ぎ先へ渡る。
        XCTAssertEqual(FluseConnectError.malformed, rejected(valid.replacingOccurrences(of: "h=192.168.0.10", with: "h=%20")))
        XCTAssertEqual(FluseConnectError.malformed, rejected(valid.replacingOccurrences(of: "t=\(token)", with: "t=%20")))
    }

    func testRejectsBrokenEscapes() {
        // 直して通すと、読み取ったものと繋ぎに行く先が食い違う。
        XCTAssertEqual(FluseConnectError.malformed, rejected(valid.replacingOccurrences(of: "t=\(token)", with: "t=%A")))
        XCTAssertEqual(FluseConnectError.malformed, rejected(valid.replacingOccurrences(of: "t=\(token)", with: "t=%ZZ")))
        XCTAssertEqual(FluseConnectError.malformed, rejected(valid.replacingOccurrences(of: "t=\(token)", with: "t=abc%")))
    }

    func testRejectsManualInputWhenPortIsNotANumber() {
        let result = FluseConnectUri.fromManualInput(
            host: "192.168.0.10",
            port: "八一八〇",
            token: token,
            appInfo: appInfo
        )

        guard case let .rejected(error) = result else {
            return XCTFail("解けてしまいました")
        }
        XCTAssertEqual(FluseConnectError.malformed, error)
    }
}
