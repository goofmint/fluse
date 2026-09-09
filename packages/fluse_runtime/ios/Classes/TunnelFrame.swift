import Foundation

/// トンネルフレームの種別（設計 §2.2.1）。
public enum TunnelOpcode: UInt8 {
    /// 新しいストリームを開く。
    case open = 0x01

    /// データ本体。
    case data = 0x02

    /// ストリームを閉じる。
    case close = 0x03

    /// Dart 側の enum 名と揃えたワイヤ表現（ゴールデンの `opcode`）。
    public var wireName: String {
        switch self {
        case .open: return "open"
        case .data: return "data"
        case .close: return "close"
        }
    }

    public static func tryParse(_ value: UInt8) -> TunnelOpcode? {
        TunnelOpcode(rawValue: value)
    }

    public static func tryParseName(_ name: String) -> TunnelOpcode? {
        switch name {
        case "open": return .open
        case "data": return .data
        case "close": return .close
        default: return nil
        }
    }
}

/// WebSocket の binary frame に載せる TCP トンネルのフレーム（設計 §2.2.1）。
///
/// ```text
/// byte0      : opcode  0x01=open, 0x02=data, 0x03=close
/// byte1..4   : streamId (uint32 big-endian)
/// byte5..    : payload (data時のみ)
/// ```
///
/// **VM Service のプロトコルは一切解釈しない**（設計 §10-3）。
///
/// Dart / Kotlin 側の `TunnelFrame` と完全に同じ表現でなければならない。
/// 検証は `packages/fluse_protocol/test/fixtures/wire_golden.json` を
/// 三実装が読むことで担保する。
///
/// **`streamId` を `UInt32` で持つ。** Kotlin は符号付き `Long` で持ち
/// 範囲外を実行時に弾いているが、Swift では `UInt32` という型そのものが
/// uint32 の範囲を保証するため、同じ検査を型で肩代わりできる
/// （受け付ける・拒否する範囲は変わらない）。
public struct TunnelFrame: Equatable {
    public let opcode: TunnelOpcode

    /// ストリームの識別子。
    public let streamId: UInt32

    /// 本体。`data` 以外では空。
    public let payload: [UInt8]

    /// ヘッダの長さ（opcode 1バイト + streamId 4バイト）。
    public static let headerLength = 5

    /// `streamId` の最大値。uint32 なので 0xFFFFFFFF。
    public static let maxStreamId: UInt32 = 0xFFFF_FFFF

    /// 1フレームに載せられる payload の上限（1 MiB）。
    ///
    /// 送信側はこれを超える前に分割する責務がある。
    public static let maxPayloadLength = 1024 * 1024

    public init(opcode: TunnelOpcode, streamId: UInt32, payload: [UInt8] = []) {
        self.opcode = opcode
        self.streamId = streamId
        self.payload = payload
    }

    /// ストリームを開くフレーム。
    public static func open(streamId: UInt32) -> TunnelFrame {
        TunnelFrame(opcode: .open, streamId: streamId)
    }

    /// データを運ぶフレーム。
    public static func data(streamId: UInt32, payload: [UInt8]) -> TunnelFrame {
        TunnelFrame(opcode: .data, streamId: streamId, payload: payload)
    }

    /// ストリームを閉じるフレーム。
    public static func close(streamId: UInt32) -> TunnelFrame {
        TunnelFrame(opcode: .close, streamId: streamId)
    }

    public static func decode(_ bytes: [UInt8]) throws -> TunnelFrame {
        if bytes.count < headerLength {
            throw FluseProtocolException(
                "トンネルフレームが短すぎます: \(bytes.count) バイト（最低 \(headerLength) バイト必要）"
            )
        }

        guard let opcode = TunnelOpcode.tryParse(bytes[0]) else {
            throw FluseProtocolException(
                String(format: "未知の opcode: 0x%02x", bytes[0])
            )
        }

        let payloadLength = bytes.count - headerLength
        if payloadLength > maxPayloadLength {
            // コピーする前に弾く。長さを信じて確保すると、壊れた相手に
            // メモリを一気に取らせられる。
            throw FluseProtocolException(
                "payload が上限を超えています: \(payloadLength) バイト（上限 \(maxPayloadLength)）"
            )
        }

        let streamId =
            (UInt32(bytes[1]) << 24) | (UInt32(bytes[2]) << 16)
                | (UInt32(bytes[3]) << 8) | UInt32(bytes[4])

        let payload = payloadLength == 0 ? [] : Array(bytes[headerLength...])

        if opcode != .data, !payload.isEmpty {
            throw FluseProtocolException(
                "\(opcode.wireName) フレームに payload が付いています（\(payload.count) バイト）"
            )
        }

        return TunnelFrame(opcode: opcode, streamId: streamId, payload: payload)
    }

    public func encode() throws -> [UInt8] {
        if opcode != .data, !payload.isEmpty {
            // open / close に本体を載せると、受け側の解釈が opcode と食い違う。
            throw FluseProtocolException(
                "\(opcode.wireName) フレームに payload は載せられません（\(payload.count) バイト）"
            )
        }
        if payload.count > TunnelFrame.maxPayloadLength {
            throw FluseProtocolException(
                "payload が上限を超えています: \(payload.count) バイト"
                    + "（上限 \(TunnelFrame.maxPayloadLength)）。送信側で分割してください"
            )
        }

        var bytes = [UInt8](repeating: 0, count: TunnelFrame.headerLength + payload.count)
        bytes[0] = opcode.rawValue
        // big-endian。バイト順を取り違えると streamId が別のストリームを指す。
        bytes[1] = UInt8((streamId >> 24) & 0xFF)
        bytes[2] = UInt8((streamId >> 16) & 0xFF)
        bytes[3] = UInt8((streamId >> 8) & 0xFF)
        bytes[4] = UInt8(streamId & 0xFF)
        for (index, byte) in payload.enumerated() {
            bytes[TunnelFrame.headerLength + index] = byte
        }
        return bytes
    }
}

extension TunnelFrame: CustomStringConvertible {
    public var description: String {
        "TunnelFrame(\(opcode.wireName), stream: \(streamId), \(payload.count)バイト)"
    }
}
