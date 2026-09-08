import Foundation

/// サーバとランタイムが交わす制御メッセージ（設計 §2.2.1）。
///
/// **Dart / Kotlin 側の `FluseMessage` と同じワイヤ表現でなければならない。**
/// 検証は `packages/fluse_protocol/test/fixtures/wire_golden.json` を
/// 三実装が読むことで担保する。ここを変えたら他の2つも必ず追従させること。
public protocol FluseMessage {
    /// JSON の `type` フィールドに載る値。
    var type: String { get }

    func toJson() -> [String: Any]
}

/// `FluseMessage.fromJson` 相当の入口。
///
/// Kotlin / Dart は sealed class の companion / static メソッドとして
/// 持たせているが、Swift の `protocol` は static ディスパッチ用の
/// ファクトリを直接持てないため、専用の名前空間に切り出す。
public enum FluseMessageDecoder {
    /// `type` を見て対応するメッセージに振り分ける。
    ///
    /// 未知の `type` は明示的に失敗させる。黙って無視すると、
    /// 送った側は届いたと思い込んだまま応答を待ち続ける。
    public static func fromJson(_ json: [String: Any]) throws -> FluseMessage {
        guard let rawType = json["type"], !(rawType is NSNull) else {
            throw FluseProtocolException("メッセージに type がありません")
        }
        guard let rawTypeString = rawType as? String else {
            throw FluseProtocolException.wrongType("FluseMessage", "type", "文字列", rawType)
        }

        switch rawTypeString {
        case HelloMessage.messageType:
            return try HelloMessage.fromJson(json)
        case VmServiceReadyMessage.messageType:
            return try VmServiceReadyMessage.fromJson(json)
        case ReadyMessage.messageType:
            return ReadyMessage()
        case LogMessage.messageType:
            return try LogMessage.fromJson(json)
        case ErrorMessage.messageType:
            return try ErrorMessage.fromJson(json)
        case AcceptMessage.messageType:
            return try AcceptMessage.fromJson(json)
        case RejectMessage.messageType:
            return try RejectMessage.fromJson(json)
        case ReloadMessage.messageType:
            return ReloadMessage()
        case CompileErrorMessage.messageType:
            return try CompileErrorMessage.fromJson(json)
        case CompileOkMessage.messageType:
            return CompileOkMessage()
        case PingMessage.messageType:
            return try PingMessage.fromJson(json)
        case PongMessage.messageType:
            return try PongMessage.fromJson(json)
        case CloseMessage.messageType:
            return try CloseMessage.fromJson(json)
        default:
            throw FluseProtocolException("未知の type: \(rawTypeString)")
        }
    }
}

// --------------------------------------------------------- Client -> Server

/// 接続時の名乗り（type: `hello`）。
public struct HelloMessage: FluseMessage, Equatable {
    public static let messageType = "hello"

    public let protocolVersion: Int64
    /// `pubspec.yaml` の name + プロジェクト絶対パスの sha256 先頭16桁（設計 §4.2(a)）。
    public let projectId: String
    public let flutterRevision: String
    public let dartVersion: String
    /// init 時に埋め込まれたビルドID。
    public let appVersion: String
    /// ANDROID_ID / iOS 側の端末識別子由来のハッシュ。
    public let deviceId: String
    public let deviceName: String
    /// 初回ペアリング時のみ。
    public let pairingToken: String?
    /// ペアリング済みの場合。
    public let deviceToken: String?

    public init(
        protocolVersion: Int64,
        projectId: String,
        flutterRevision: String,
        dartVersion: String,
        appVersion: String,
        deviceId: String,
        deviceName: String,
        pairingToken: String? = nil,
        deviceToken: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.projectId = projectId
        self.flutterRevision = flutterRevision
        self.dartVersion = dartVersion
        self.appVersion = appVersion
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.pairingToken = pairingToken
        self.deviceToken = deviceToken
    }

    public var type: String { Self.messageType }

    public func toJson() -> [String: Any] {
        var json: [String: Any] = [
            "type": type,
            "protocolVersion": protocolVersion,
            "projectId": projectId,
            "flutterRevision": flutterRevision,
            "dartVersion": dartVersion,
            "appVersion": appVersion,
            "deviceId": deviceId,
            "deviceName": deviceName,
        ]
        if let pairingToken = pairingToken { json["pairingToken"] = pairingToken }
        if let deviceToken = deviceToken { json["deviceToken"] = deviceToken }
        return json
    }

    public static func fromJson(_ json: [String: Any]) throws -> HelloMessage {
        let r = JsonReader(json)
        return HelloMessage(
            protocolVersion: try r.requireInt(messageType, "protocolVersion"),
            projectId: try r.requireString(messageType, "projectId"),
            flutterRevision: try r.requireString(messageType, "flutterRevision"),
            dartVersion: try r.requireString(messageType, "dartVersion"),
            appVersion: try r.requireString(messageType, "appVersion"),
            deviceId: try r.requireString(messageType, "deviceId"),
            deviceName: try r.requireString(messageType, "deviceName"),
            pairingToken: try r.optionalString(messageType, "pairingToken"),
            deviceToken: try r.optionalString(messageType, "deviceToken")
        )
    }
}

extension HelloMessage: CustomStringConvertible {
    /// **トークンは含めない。** ログや例外文に混ざると漏れる。
    public var description: String {
        "HelloMessage(v\(protocolVersion), project: \(projectId), device: \(deviceName))"
    }
}

/// VM Service が立ち上がったことの通知（type: `vmServiceReady`）。
public struct VmServiceReadyMessage: FluseMessage, Equatable {
    public static let messageType = "vmServiceReady"

    /// `http://127.0.0.1:PORT/AUTHCODE/` 形式。
    ///
    /// **パスセグメントの認証コードが資格情報**なので、ログに出す際は
    /// 必ずマスクすること。
    public let vmServiceUri: String

    public init(vmServiceUri: String) {
        self.vmServiceUri = vmServiceUri
    }

    public var type: String { Self.messageType }

    public func toJson() -> [String: Any] {
        ["type": type, "vmServiceUri": vmServiceUri]
    }

    public static func fromJson(_ json: [String: Any]) throws -> VmServiceReadyMessage {
        VmServiceReadyMessage(
            vmServiceUri: try JsonReader(json).requireString(messageType, "vmServiceUri")
        )
    }
}

extension VmServiceReadyMessage: CustomStringConvertible {
    /// URI は載せない。パスセグメントが認証コードそのものであるため。
    public var description: String { "VmServiceReadyMessage(...)" }
}

/// 準備完了（type: `ready`）。
public struct ReadyMessage: FluseMessage, Equatable {
    public static let messageType = "ready"

    public init() {}

    public var type: String { Self.messageType }

    public func toJson() -> [String: Any] { ["type": type] }
}

extension ReadyMessage: CustomStringConvertible {
    public var description: String { "ReadyMessage()" }
}

/// 端末からのログ（type: `log`）。
public struct LogMessage: FluseMessage, Equatable {
    public static let messageType = "log"

    public let level: String
    public let message: String

    public init(level: String, message: String) {
        self.level = level
        self.message = message
    }

    /// 既知の値なら対応する定数、そうでなければ nil。
    public var knownLevel: LogLevel? { LogLevel.tryParse(level) }

    public var type: String { Self.messageType }

    public func toJson() -> [String: Any] {
        ["type": type, "level": level, "message": message]
    }

    public static func fromJson(_ json: [String: Any]) throws -> LogMessage {
        let r = JsonReader(json)
        return LogMessage(
            level: try r.requireString(messageType, "level"),
            message: try r.requireString(messageType, "message")
        )
    }
}

extension LogMessage: CustomStringConvertible {
    public var description: String { "LogMessage(\(level))" }
}

/// 端末からのエラー通知（type: `error`）。
public struct ErrorMessage: FluseMessage, Equatable {
    public static let messageType = "error"

    public let code: String
    public let message: String
    public let detail: String?

    public init(code: String, message: String, detail: String? = nil) {
        self.code = code
        self.message = message
        self.detail = detail
    }

    public var knownCode: FluseErrorCode? { FluseErrorCode.tryParse(code) }

    public var type: String { Self.messageType }

    public func toJson() -> [String: Any] {
        var json: [String: Any] = ["type": type, "code": code, "message": message]
        if let detail = detail { json["detail"] = detail }
        return json
    }

    public static func fromJson(_ json: [String: Any]) throws -> ErrorMessage {
        let r = JsonReader(json)
        return ErrorMessage(
            code: try r.requireString(messageType, "code"),
            message: try r.requireString(messageType, "message"),
            detail: try r.optionalString(messageType, "detail")
        )
    }
}

extension ErrorMessage: CustomStringConvertible {
    public var description: String { "ErrorMessage(\(code))" }
}

// --------------------------------------------------------- Server -> Client

/// 接続を受理した（type: `accept`）。
public struct AcceptMessage: FluseMessage, Equatable {
    public static let messageType = "accept"

    public let sessionId: String
    public let heartbeatIntervalMs: Int64
    public let issuedDeviceToken: String?

    public init(sessionId: String, heartbeatIntervalMs: Int64, issuedDeviceToken: String? = nil) {
        self.sessionId = sessionId
        self.heartbeatIntervalMs = heartbeatIntervalMs
        self.issuedDeviceToken = issuedDeviceToken
    }

    public var type: String { Self.messageType }

    public func toJson() -> [String: Any] {
        var json: [String: Any] = [
            "type": type,
            "sessionId": sessionId,
            "heartbeatIntervalMs": heartbeatIntervalMs,
        ]
        if let issuedDeviceToken = issuedDeviceToken {
            json["issuedDeviceToken"] = issuedDeviceToken
        }
        return json
    }

    public static func fromJson(_ json: [String: Any]) throws -> AcceptMessage {
        let r = JsonReader(json)
        return AcceptMessage(
            sessionId: try r.requireString(messageType, "sessionId"),
            heartbeatIntervalMs: try r.requireInt(messageType, "heartbeatIntervalMs"),
            issuedDeviceToken: try r.optionalString(messageType, "issuedDeviceToken")
        )
    }
}

extension AcceptMessage: CustomStringConvertible {
    /// 発行トークンは載せない。
    public var description: String { "AcceptMessage(\(sessionId))" }
}

/// 接続を拒否した（type: `reject`）。
public struct RejectMessage: FluseMessage, Equatable {
    public static let messageType = "reject"

    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public static func of(_ code: RejectCode, _ message: String) -> RejectMessage {
        RejectMessage(code: code.wireValue, message: message)
    }

    public var knownCode: RejectCode? { RejectCode.tryParse(code) }

    public var type: String { Self.messageType }

    public func toJson() -> [String: Any] {
        ["type": type, "code": code, "message": message]
    }

    public static func fromJson(_ json: [String: Any]) throws -> RejectMessage {
        let r = JsonReader(json)
        return RejectMessage(
            code: try r.requireString(messageType, "code"),
            message: try r.requireString(messageType, "message")
        )
    }
}

extension RejectMessage: CustomStringConvertible {
    public var description: String { "RejectMessage(\(code))" }
}

/// リロードの進捗通知（type: `reload`）。
public struct ReloadMessage: FluseMessage, Equatable {
    public static let messageType = "reload"

    public init() {}

    public var type: String { Self.messageType }

    public func toJson() -> [String: Any] { ["type": type] }
}

extension ReloadMessage: CustomStringConvertible {
    public var description: String { "ReloadMessage()" }
}

/// コンパイルエラー（type: `compileError`）。
public struct CompileErrorMessage: FluseMessage, Equatable {
    public static let messageType = "compileError"

    public let summary: String
    public let diagnostics: [DiagnosticEntry]

    public init(summary: String, diagnostics: [DiagnosticEntry]) {
        self.summary = summary
        self.diagnostics = diagnostics
    }

    public var type: String { Self.messageType }

    public func toJson() -> [String: Any] {
        [
            "type": type,
            "summary": summary,
            "diagnostics": diagnostics.map { $0.toJson() },
        ]
    }

    public static func fromJson(_ json: [String: Any]) throws -> CompileErrorMessage {
        let r = JsonReader(json)
        let array = try r.requireArray(messageType, "diagnostics")
        let entries = try array.map { element -> DiagnosticEntry in
            let object = try JsonReader.requireObject(messageType, "diagnostics", element)
            return try DiagnosticEntry.fromJson(object)
        }
        return CompileErrorMessage(
            summary: try r.requireString(messageType, "summary"),
            diagnostics: entries
        )
    }
}

extension CompileErrorMessage: CustomStringConvertible {
    public var description: String { "CompileErrorMessage(\(diagnostics.count)件)" }
}

/// コンパイルが通った（type: `compileOk`）。オーバーレイの解除に使う。
public struct CompileOkMessage: FluseMessage, Equatable {
    public static let messageType = "compileOk"

    public init() {}

    public var type: String { Self.messageType }

    public func toJson() -> [String: Any] { ["type": type] }
}

extension CompileOkMessage: CustomStringConvertible {
    public var description: String { "CompileOkMessage()" }
}

// -------------------------------------------------------------------- 双方向

/// 疎通確認（type: `ping`）。
public struct PingMessage: FluseMessage, Equatable {
    public static let messageType = "ping"

    /// 対応する `pong` と突き合わせる。
    public let seq: Int64
    /// 送信側の時刻。RTT 計測に使う。
    public let timestampMs: Int64

    public init(seq: Int64, timestampMs: Int64) {
        self.seq = seq
        self.timestampMs = timestampMs
    }

    public var type: String { Self.messageType }

    public func toJson() -> [String: Any] {
        ["type": type, "seq": seq, "timestampMs": timestampMs]
    }

    public static func fromJson(_ json: [String: Any]) throws -> PingMessage {
        let r = JsonReader(json)
        return PingMessage(
            seq: try r.requireInt(messageType, "seq"),
            timestampMs: try r.requireInt(messageType, "timestampMs")
        )
    }

    /// この ping に対応する pong を作る。
    ///
    /// **受け取った値をそのまま返す。** 受信側で時刻を作り直すと RTT が測れない。
    public func toPong() -> PongMessage {
        PongMessage(seq: seq, timestampMs: timestampMs)
    }
}

extension PingMessage: CustomStringConvertible {
    public var description: String { "PingMessage(\(seq))" }
}

/// 疎通確認への応答（type: `pong`）。
public struct PongMessage: FluseMessage, Equatable {
    public static let messageType = "pong"

    public let seq: Int64
    public let timestampMs: Int64

    public init(seq: Int64, timestampMs: Int64) {
        self.seq = seq
        self.timestampMs = timestampMs
    }

    public var type: String { Self.messageType }

    public func toJson() -> [String: Any] {
        ["type": type, "seq": seq, "timestampMs": timestampMs]
    }

    public static func fromJson(_ json: [String: Any]) throws -> PongMessage {
        let r = JsonReader(json)
        return PongMessage(
            seq: try r.requireInt(messageType, "seq"),
            timestampMs: try r.requireInt(messageType, "timestampMs")
        )
    }
}

extension PongMessage: CustomStringConvertible {
    public var description: String { "PongMessage(\(seq))" }
}

/// 正常終了の通知（type: `close`）。
///
/// 異常終了は WebSocket の close フレームに委ねる。
public struct CloseMessage: FluseMessage, Equatable {
    public static let messageType = "close"

    /// 終了理由。既知の値は [CloseCode] を参照。
    public let code: String
    public let message: String?

    public init(code: String, message: String? = nil) {
        self.code = code
        self.message = message
    }

    public static func of(_ code: CloseCode, message: String? = nil) -> CloseMessage {
        CloseMessage(code: code.wireValue, message: message)
    }

    public var knownCode: CloseCode? { CloseCode.tryParse(code) }

    public var type: String { Self.messageType }

    public func toJson() -> [String: Any] {
        var json: [String: Any] = ["type": type, "code": code]
        if let message = message { json["message"] = message }
        return json
    }

    public static func fromJson(_ json: [String: Any]) throws -> CloseMessage {
        let r = JsonReader(json)
        return CloseMessage(
            code: try r.requireString(messageType, "code"),
            message: try r.optionalString(messageType, "message")
        )
    }
}

extension CloseMessage: CustomStringConvertible {
    public var description: String { "CloseMessage(\(code))" }
}
