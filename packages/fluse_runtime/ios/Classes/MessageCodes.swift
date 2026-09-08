import Foundation

/// `reject` の理由（設計 §2.2.1 / §5.1）。
public enum RejectCode: String {
    case authFailed = "AUTH_FAILED"
    case projectMismatch = "PROJECT_MISMATCH"
    case revisionMismatch = "REVISION_MISMATCH"
    case protocolMismatch = "PROTOCOL_MISMATCH"
    case appOutdated = "APP_OUTDATED"

    /// Phase1 は1台のみ。2台目は受け付けない（設計 §10-10）。
    case tooManyDevices = "TOO_MANY_DEVICES"

    /// JSON に載る文字列。
    public var wireValue: String { rawValue }

    /// 既知の値なら対応する定数、そうでなければ nil。
    ///
    /// **未知の値でも解析は失敗させない。** 新しいサーバが増やしたコードを
    /// 古いアプリが受け取ったときに、理由の文言すら表示できなくなるのを避ける。
    public static func tryParse(_ value: String) -> RejectCode? {
        RejectCode(rawValue: value)
    }
}

/// `close` の理由（設計 §2.2.1）。
public enum CloseCode: String {
    case shutdown = "SHUTDOWN"
    case sessionReplaced = "SESSION_REPLACED"
    case clientExit = "CLIENT_EXIT"

    public var wireValue: String { rawValue }

    public static func tryParse(_ value: String) -> CloseCode? {
        CloseCode(rawValue: value)
    }
}

/// `error` の分類（設計 §5.1）。
public enum FluseErrorCode: String {
    case sdkNotFound = "SDK_NOT_FOUND"
    case projectNotFlutter = "PROJECT_NOT_FLUTTER"
    case noDevice = "NO_DEVICE"
    case installSignatureConflict = "INSTALL_SIGNATURE_CONFLICT"
    case protocolMismatch = "PROTOCOL_MISMATCH"
    case projectMismatch = "PROJECT_MISMATCH"
    case revisionMismatch = "REVISION_MISMATCH"
    case appOutdated = "APP_OUTDATED"
    case compileError = "COMPILE_ERROR"
    case reloadRejected = "RELOAD_REJECTED"
    case tunnelLost = "TUNNEL_LOST"
    case authFailed = "AUTH_FAILED"

    public var wireValue: String { rawValue }

    public static func tryParse(_ value: String) -> FluseErrorCode? {
        FluseErrorCode(rawValue: value)
    }
}

/// `log` の深刻度（設計 §2.2.1）。
public enum LogLevel: String {
    case debug
    case info
    case warn
    case error

    public var wireValue: String { rawValue }

    public static func tryParse(_ value: String) -> LogLevel? {
        LogLevel(rawValue: value)
    }
}

/// 診断の深刻度。
public enum DiagnosticSeverity: String {
    case error
    case warning
    case info
    case context

    public var wireValue: String { rawValue }

    public static func tryParse(_ value: String) -> DiagnosticSeverity? {
        DiagnosticSeverity(rawValue: value)
    }
}
