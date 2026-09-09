import XCTest

@testable import fluse_runtime

/// `FluseAppInfo.load(bundle:)` の失敗経路だけを確かめる。
///
/// **成功経路（実際に `fluse/app_info.json` を読めること）はここでは
/// 確かめられない。** `swift test` の `Bundle.main` はテストランナーの
/// バンドルであり、このリソースを持たない。実機・シミュレータでの確認が
/// 必要な部分として報告する。
final class FluseAppInfoLoadTests: XCTestCase {
    func testThrowsWhenResourceIsMissingFromTheBundle() {
        // このテストバンドルには `fluse/app_info.json` が無い。
        // **既定値へは倒さない。** 読めなければ明確に投げること自体を確かめる。
        XCTAssertThrowsError(try FluseAppInfo.load(bundle: Bundle(for: FluseAppInfoLoadTests.self)))
    }

    func testThrowsWhenResourceIsMissingFromTheMainBundle() {
        XCTAssertThrowsError(try FluseAppInfo.load())
    }
}
