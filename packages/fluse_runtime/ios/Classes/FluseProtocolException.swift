import Foundation

/// ワイヤ表現を解釈できなかったときに投げる。
///
/// **トークンなどの値は載せない。** このメッセージはログにも出るため、
/// `pairingToken` や `deviceToken` が混ざると漏れる。
/// 何のフィールドが、どう期待と違ったかだけを書く。
///
/// Kotlin 側の `FluseProtocolException`（`packages/fluse_runtime/android/src/wire/kotlin/dev/fluse/protocol/FluseProtocolException.kt`）
/// と役割・文言の作り方を揃えてある。
public struct FluseProtocolException: Error, CustomStringConvertible, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    /// 欠けているフィールドについての定型。
    public static func missingField(_ type: String, _ field: String) -> FluseProtocolException {
        FluseProtocolException("\(type): \(field) がありません")
    }

    /// 型が違うフィールドについての定型。
    ///
    /// 値そのものは載せず、実際の型だけを示す。
    public static func wrongType(
        _ type: String,
        _ field: String,
        _ expected: String,
        _ actual: Any?
    ) -> FluseProtocolException {
        FluseProtocolException(
            "\(type): \(field) が \(expected) ではありません（実際は \(Self.typeName(of: actual))）"
        )
    }

    public var description: String { "fluse_protocol: \(message)" }

    /// デバッグ表示用の型名。ワイヤ表現には関与しない。
    private static func typeName(of value: Any?) -> String {
        guard let value = value, !(value is NSNull) else {
            return "null"
        }
        if let number = value as? NSNumber {
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? "Bool" : "Number"
        }
        if value is String { return "String" }
        if value is [Any] { return "Array" }
        if value is [String: Any] { return "Object" }
        return String(describing: type(of: value))
    }
}
