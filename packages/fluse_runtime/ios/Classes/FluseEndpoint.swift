import Foundation

/// 繋ぎ先。
///
/// 移植元: `packages/fluse_runtime/android/src/main/kotlin/dev/fluse/runtime/FluseAppInfo.kt`
/// （`FluseEndpoint` 部分、78-84行目）。
public struct FluseEndpoint: Equatable {
    public let host: String
    public let port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    /// WebSocket の URL（設計 §4.2(b) の `/ws`）。
    public func webSocketUrl() -> String {
        "ws://\(host):\(port)/ws"
    }
}
