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

extension FluseBackoffTests {
    /// 極端な上限でも落ちないこと。
    ///
    /// Kotlin の Long 乗算は溢れても一周するだけだが、Swift の Int 乗算は
    /// トラップする。同じ式のまま移すと、ここだけ挙動が「落ちる」に化ける。
    func testDoesNotTrapOnHugeBounds() {
        let backoff = FluseBackoff(initialMs: Int.max, maxMs: Int.max)

        XCTAssertEqual(backoff.next(), Int.max)
        XCTAssertEqual(backoff.next(), Int.max)
    }

    /// 上限に届く手前までは倍で伸びること（正常な入力での結果は不変）。
    func testDoublesUntilBound() {
        let backoff = FluseBackoff()

        XCTAssertEqual(backoff.next(), 1000)
        XCTAssertEqual(backoff.next(), 2000)
        XCTAssertEqual(backoff.next(), 4000)
        XCTAssertEqual(backoff.next(), 8000)
        XCTAssertEqual(backoff.next(), 16000)
        XCTAssertEqual(backoff.next(), 30000)
        XCTAssertEqual(backoff.next(), 30000)
    }
}
