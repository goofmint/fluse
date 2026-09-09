import XCTest

@testable import fluse_runtime

/// 移植元: `packages/fluse_runtime/android/src/test/kotlin/dev/fluse/runtime/FluseBackoffTest.kt`
final class FluseBackoffTests: XCTestCase {
    func testDoublesFromOneSecondAndCapsAtThirtySeconds() {
        // すぐに繋ぎ直し続けるとバッテリを削り、サーバ復帰時に接続が殺到する。
        let backoff = FluseBackoff()

        let waits = (1...8).map { _ in backoff.next() }

        XCTAssertEqual(
            [1_000, 2_000, 4_000, 8_000, 16_000, 30_000, 30_000, 30_000],
            waits
        )
    }

    func testResetsToInitialWaitWhenConnected() {
        // 一度繋がった後の切断は、たいてい一時的なもの。30秒待たせない。
        let backoff = FluseBackoff()
        for _ in 0..<5 { _ = backoff.next() }

        backoff.reset()

        XCTAssertEqual(1_000, backoff.next())
    }
}
