import Foundation

/// トンネルの中継に失敗したときに投げる。
///
/// 移植元: `packages/fluse_runtime/android/src/wire/kotlin/dev/fluse/runtime/TunnelException.kt`
///
/// サーバ側 `TunnelException`（Dart, `packages/fluse_server/lib/src/tunnel_endpoint.dart`）の鏡像。
///
/// **VM Service の URI やトークンは載せない。** この文言はログに出る。
public struct TunnelException: Error, CustomStringConvertible, Equatable {
    public let message: String

    /// 元になった例外。無い場合は nil。
    ///
    /// Kotlin 版は `Throwable?` を持つが、`Throwable` は `Equatable` ではない
    /// ため、そのままでは `TunnelException` 自体が `Equatable` にできない。
    /// `NSError` に正規化して比較可能にする（比較はテストの利便性のためで、
    /// ワイヤ表現や制御ロジックには関与しない）。
    public let cause: NSError?

    /// [cause] は元の失敗。握り潰さずに繋いでおくと、TCP 側の
    /// エラーなのかフレームの解釈失敗なのかが後から辿れる。
    public init(_ message: String, cause: Error? = nil) {
        self.message = message
        self.cause = cause.map { $0 as NSError }
    }

    /// ログと例外表示に出る文字列。[cause] があれば併記する。
    public var description: String {
        if let cause = cause {
            return "トンネル: \(message) (\(cause))"
        }
        return "トンネル: \(message)"
    }
}
