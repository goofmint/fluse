import Foundation

/// ワイヤに載せるコンパイル診断1件（設計 §2.2.1 の `CompileErrorMessage`）。
///
/// Dart / Kotlin 側の `DiagnosticEntry` と同じ形。
public struct DiagnosticEntry: Equatable {
    public let severity: DiagnosticSeverity
    public let message: String

    /// 対象ファイル。位置を持たない診断では nil。
    public let file: String?
    public let line: Int64?
    public let col: Int64?

    public init(
        severity: DiagnosticSeverity,
        message: String,
        file: String? = nil,
        line: Int64? = nil,
        col: Int64? = nil
    ) {
        self.severity = severity
        self.message = message
        self.file = file
        self.line = line
        self.col = col
    }

    /// `file:line:col` 形式。エディタから開けるようにするための表現。
    public var location: String? {
        guard let file = file else { return nil }
        guard let line = line else { return file }
        guard let col = col else { return "\(file):\(line)" }
        return "\(file):\(line):\(col)"
    }

    public func toJson() -> [String: Any] {
        var json: [String: Any] = [
            "severity": severity.wireValue,
            "message": message,
        ]
        if let file = file { json["file"] = file }
        if let line = line { json["line"] = line }
        if let col = col { json["col"] = col }
        return json
    }

    static let type = "DiagnosticEntry"

    public static func fromJson(_ json: [String: Any]) throws -> DiagnosticEntry {
        let reader = JsonReader(json)
        let rawSeverity = try reader.requireString(type, "severity")
        guard let severity = DiagnosticSeverity.tryParse(rawSeverity) else {
            // 深刻度が分からないとオーバーレイの出し分けができない。
            // 黙って error に丸めると、警告で赤画面になる。
            //
            // **受け取った値そのものは載せない。** severity は相手が
            // 自由に入れられるフィールドで、例外文はログに出る。
            throw FluseProtocolException("\(type): 未知の severity")
        }

        return DiagnosticEntry(
            severity: severity,
            message: try reader.requireString(type, "message"),
            file: try reader.optionalString(type, "file"),
            line: try reader.optionalInt(type, "line"),
            col: try reader.optionalInt(type, "col")
        )
    }
}

extension DiagnosticEntry: CustomStringConvertible {
    public var description: String {
        guard let location = location else { return message }
        return "\(location): \(message)"
    }
}
