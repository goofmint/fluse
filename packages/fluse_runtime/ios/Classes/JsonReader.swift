import Foundation

/// JSON から型付きの値を取り出す小道具。
///
/// 「無い」と「型が違う」を別のメッセージで報告する。片方に丸めると、
/// 壊れたメッセージの原因が追えなくなる。Dart / Kotlin 側の `JsonReader`
/// と同じ規則。
///
/// **Kotlin の `org.json` 相当を `JSONSerialization` に置き換えた簡略版。**
/// 受け付ける入力・拒否する入力の範囲は変えていない
/// （`packages/fluse_runtime/android/src/wire/kotlin/dev/fluse/protocol/JsonReader.kt` を参照）。
struct JsonReader {
    private let json: [String: Any]

    init(_ json: [String: Any]) {
        self.json = json
    }

    /// JSON が正確に表せる整数の上限（2^53 - 1）。
    ///
    /// Dart の `double` / Kotlin の `org.json` の数値表現に揃えてある。
    static let maxSafeInteger: Int64 = 9_007_199_254_740_991

    /// 同じく下限。
    static let minSafeInteger: Int64 = -9_007_199_254_740_991

    /// キーが存在し、かつ JSON の null でもないか。
    private func has(_ field: String) -> Bool {
        guard let value = json[field] else { return false }
        return !(value is NSNull)
    }

    func requireString(_ type: String, _ field: String) throws -> String {
        guard has(field) else {
            throw FluseProtocolException.missingField(type, field)
        }
        let value = json[field] as Any
        // NSNumber は `as? String` に失敗するので、真偽値・数値の混入は
        // ここで自然に弾ける。
        guard let string = value as? String else {
            throw FluseProtocolException.wrongType(type, field, "文字列", value)
        }
        return string
    }

    /// 省略可能な文字列。キーが無い場合と null の場合はどちらも nil。
    func optionalString(_ type: String, _ field: String) throws -> String? {
        guard has(field) else { return nil }
        return try requireString(type, field)
    }

    /// 必須の整数。
    ///
    /// `JSONSerialization` は小数点も指数表記も持たない数値を
    /// `NSNumber`（内部表現は `long long`）として返し、`1.0` や `1e3` の
    /// ような表記は `double` として返す。**どちらの経路で来ても**、整数として
    /// 正確に表せて安全整数の範囲に収まる場合だけ受け入れる。
    /// Dart / Kotlin 側と同じ判定基準（設計上の「JSON が正確に表せる整数」）。
    func requireInt(_ type: String, _ field: String) throws -> Int64 {
        guard has(field) else {
            throw FluseProtocolException.missingField(type, field)
        }
        let value = json[field] as Any

        guard let number = value as? NSNumber, !isBoolean(number) else {
            throw FluseProtocolException.wrongType(type, field, "整数", value)
        }

        if isIntegerEncoded(number) {
            return try requireSafeRange(type, field, number.int64Value, raw: value)
        }

        // 小数点や指数表記を経由して届いた場合は double として渡ってくる。
        let doubleValue = number.doubleValue
        guard doubleValue.isFinite, doubleValue == doubleValue.rounded() else {
            throw FluseProtocolException.wrongType(type, field, "整数", value)
        }
        guard
            doubleValue >= Double(Self.minSafeInteger),
            doubleValue <= Double(Self.maxSafeInteger)
        else {
            throw FluseProtocolException.wrongType(
                type, field, "JSON が正確に表せる整数", value
            )
        }
        return Int64(doubleValue)
    }

    /// 省略可能な整数。キーが無い場合と null の場合はどちらも nil。
    func optionalInt(_ type: String, _ field: String) throws -> Int64? {
        guard has(field) else { return nil }
        return try requireInt(type, field)
    }

    /// 必須の配列。
    func requireArray(_ type: String, _ field: String) throws -> [Any] {
        guard has(field) else {
            throw FluseProtocolException.missingField(type, field)
        }
        let value = json[field] as Any
        guard let array = value as? [Any] else {
            throw FluseProtocolException.wrongType(type, field, "配列", value)
        }
        return array
    }

    /// 配列の要素をオブジェクトとして取り出す。
    static func requireObject(_ type: String, _ field: String, _ value: Any?) throws -> [String: Any] {
        guard let object = value as? [String: Any] else {
            throw FluseProtocolException.wrongType(type, field, "オブジェクト", value)
        }
        return object
    }

    private func requireSafeRange(_ type: String, _ field: String, _ value: Int64, raw: Any) throws -> Int64 {
        guard value >= Self.minSafeInteger, value <= Self.maxSafeInteger else {
            throw FluseProtocolException.wrongType(
                type, field, "JSON が正確に表せる整数", raw
            )
        }
        return value
    }

    private func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// 小数点・指数表記を経由せずに届いた数値か。
    ///
    /// `JSONSerialization` は整数リテラルを `long long`（objCType `"q"` 等）
    /// として、小数を `double`（objCType `"d"`）として返す。ここを見て
    /// 経路を判定する。
    private func isIntegerEncoded(_ number: NSNumber) -> Bool {
        let objCType = String(cString: number.objCType)
        return objCType != "d" && objCType != "f"
    }
}
