import XCTest

@testable import fluse_runtime

/// 移植元: `packages/fluse_runtime/android/src/test/kotlin/dev/fluse/runtime/FluseStartupTest.kt`
final class FluseStartupTests: XCTestCase {
    func testReconnectsWhenTokenAndServerArePresent() {
        XCTAssertEqual(
            StartupPath.reconnect,
            FluseStartup.resolve(hasDeviceToken: true, hasLastServer: true)
        )
    }

    func testPairsWhenTokenIsMissing() {
        XCTAssertEqual(
            StartupPath.pair,
            FluseStartup.resolve(hasDeviceToken: false, hasLastServer: true)
        )
    }

    func testPairsWhenServerIsUnknown() {
        // トークンだけでは繋ぎようが無い。QR から取り直す。
        XCTAssertEqual(
            StartupPath.pair,
            FluseStartup.resolve(hasDeviceToken: true, hasLastServer: false)
        )
    }

    func testPairsWhenNeitherIsPresent() {
        XCTAssertEqual(
            StartupPath.pair,
            FluseStartup.resolve(hasDeviceToken: false, hasLastServer: false)
        )
    }
}
