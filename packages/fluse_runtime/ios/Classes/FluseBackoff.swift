import Foundation

/**
 * 再接続の待ち時間（設計 §2.2.5）。
 *
 * `1s → 2s → 4s → … → 30s` と伸ばし、30s で頭打ちにする。**すぐに繋ぎ
 * 直し続けてはいけない。** サーバを落としたまま端末を放置すると、
 * 秒間何十回もの接続でバッテリを削り、サーバ復帰時には溜まった接続が
 * 一斉に来る。
 *
 * Android に触らないので単体で確かめられる。
 *
 * 移植元: `packages/fluse_runtime/android/src/main/kotlin/dev/fluse/runtime/FluseBackoff.kt`
 * Kotlin 側はミリ秒を `Long` で持つが、Swift では十分な範囲の `Int`
 * （64bit プラットフォームで `Int64` 相当）を使う。
 */
public final class FluseBackoff {
    public static let defaultInitialMs = 1_000
    public static let defaultMaxMs = 30_000

    private let initialMs: Int
    private let maxMs: Int
    private var currentMs = 0

    public init(initialMs: Int = FluseBackoff.defaultInitialMs, maxMs: Int = FluseBackoff.defaultMaxMs) {
        self.initialMs = initialMs
        self.maxMs = maxMs
    }

    /// 次に待つミリ秒。
    public func next() -> Int {
        if currentMs == 0 {
            currentMs = initialMs
        } else {
            currentMs = min(currentMs * 2, maxMs)
        }
        return currentMs
    }

    /// 繋がったら呼ぶ。次の切断で最初の待ち時間から始める。
    public func reset() {
        currentMs = 0
    }
}
