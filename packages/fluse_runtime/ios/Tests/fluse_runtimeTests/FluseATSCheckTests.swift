import XCTest

@testable import fluse_runtime

/// `FluseATSCheck` の2つの判定（事前判定・受動判定）を見る。
///
/// 移植元: `packages/fluse_runtime/android/src/test/kotlin/dev/fluse/runtime/FluseCleartextTest.kt`
///
/// **1対1では移植できない。** Kotlin 版のケースの大半
/// （`古い端末では尋ねずに通す` / `API 23 は端末全体の可否で判じる` /
/// `API 23 ではホスト別には尋ねない` / `API 24 以降は端末の答えに従う`）は
/// `NetworkSecurityPolicy` の SDK バージョン別の問い合わせ API が前提で、
/// iOS の ATS には SDK レベルによる分岐も、ホスト単位の実行時問い合わせ
/// API も存在しない（`FluseATSCheck.swift` のヘッダ参照）。そのため
/// ここでは Kotlin 版と同じ「何を確かめたいか」（宣言が無ければ塞がれる・
/// 文言に繋ぎ先と直し方が入る）を、iOS の実際の判定手段
/// （Info.plist の宣言 / `URLError` -1022）に合わせて書き直している。
final class FluseATSCheckTests: XCTestCase {
    private let host = "192.168.0.10"

    // ------------------------------------------------------ 事前判定（宣言）

    func testAllowedWhenDeclaredTrue() {
        let info: [String: Any] = [
            "NSAppTransportSecurity": ["NSAllowsLocalNetworking": true],
        ]

        XCTAssertTrue(FluseATSCheck.isLocalNetworkingAllowed(infoDictionary: info))
    }

    func testBlockedWhenDeclaredFalse() {
        // 明示的に false を書いている場合も塞がれている扱いにする。
        let info: [String: Any] = [
            "NSAppTransportSecurity": ["NSAllowsLocalNetworking": false],
        ]

        XCTAssertFalse(FluseATSCheck.isLocalNetworkingAllowed(infoDictionary: info))
    }

    func testBlockedWhenKeyMissingEntirely() {
        // Info.plist に NSAppTransportSecurity 自体が無い（既定の ATS）。
        XCTAssertFalse(FluseATSCheck.isLocalNetworkingAllowed(infoDictionary: [:]))
    }

    func testBlockedWhenInfoDictionaryIsNil() {
        // Bundle からの読み出しに失敗した場合の値。
        XCTAssertFalse(FluseATSCheck.isLocalNetworkingAllowed(infoDictionary: nil))
    }

    func testBlockedWhenTransportSecurityDictHasOtherKeysOnly() {
        // NSAllowsLocalNetworking 以外の ATS 例外だけが書かれている場合。
        let info: [String: Any] = [
            "NSAppTransportSecurity": ["NSAllowsArbitraryLoads": true],
        ]

        XCTAssertFalse(FluseATSCheck.isLocalNetworkingAllowed(infoDictionary: info))
    }

    // -------------------------------------------------------------- 文言

    func testMessageContainsHost() {
        XCTAssertTrue(FluseATSCheck.blockedMessage(host: host).contains(host))
    }

    func testMessageContainsHowToFix() {
        // 「拒否されました」だけでは、自分のアプリの Info.plist が原因だと気づけない。
        let message = FluseATSCheck.blockedMessage(host: host)

        XCTAssertTrue(message.contains("Info.plist"), message)
        XCTAssertTrue(message.contains("NSAllowsLocalNetworking"), message)
    }

    // --------------------------------------------------------- 受動判定

    func testDetectsAppTransportSecurityErrorCode() {
        let error = NSError(domain: NSURLErrorDomain, code: -1022, userInfo: nil)

        XCTAssertTrue(FluseATSCheck.isATSFailure(error))
    }

    func testDoesNotFlagUnrelatedUrlErrors() {
        // 例えば「サーバに繋がらない」（-1004）は ATS の話ではない。
        let error = NSError(domain: NSURLErrorDomain, code: -1004, userInfo: nil)

        XCTAssertFalse(FluseATSCheck.isATSFailure(error))
    }

    func testDoesNotFlagSameCodeFromOtherDomain() {
        // コード番号がたまたま一致しても、ATS のドメインでなければ違う話。
        let error = NSError(domain: "dev.fluse.runtime.other", code: -1022, userInfo: nil)

        XCTAssertFalse(FluseATSCheck.isATSFailure(error))
    }
}
