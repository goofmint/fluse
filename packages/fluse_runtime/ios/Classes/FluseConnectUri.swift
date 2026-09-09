import Foundation

/// QR に載る繋ぎ先（設計 §4.2(a)）。
///
/// ```
/// fluse://connect?v=1&h=192.168.0.10&p=8180&pid=<projectId>&t=<pairingToken>&rev=00b0c91f
/// ```
///
/// 移植元: `packages/fluse_runtime/android/src/main/kotlin/dev/fluse/runtime/FluseConnectUri.kt`
///
/// Android 版は「`android.net.Uri` を使うと単体テストに実機が要るため
/// 自前で解く」という理由で手書きしている。iOS 側でも同じ理由で
/// **`URLComponents` は使わない。** クエリ解析とパーセントデコードは
/// Kotlin と挙動を合わせるため、同じ手書きロジックを移植する。
public struct FluseConnectRequest: Equatable {
    public let protocolVersion: Int
    public let host: String
    public let port: Int
    public let projectId: String
    public let pairingToken: String
    /// Flutter revision の先頭8桁。
    public let revision: String

    public init(
        protocolVersion: Int,
        host: String,
        port: Int,
        projectId: String,
        pairingToken: String,
        revision: String
    ) {
        self.protocolVersion = protocolVersion
        self.host = host
        self.port = port
        self.projectId = projectId
        self.pairingToken = pairingToken
        self.revision = revision
    }

    public func endpoint() -> FluseEndpoint {
        FluseEndpoint(host: host, port: port)
    }
}

extension FluseConnectRequest: CustomStringConvertible {
    /// **トークンは含めない。** ログや例外文に混ざると漏れる。
    public var description: String {
        "FluseConnectRequest(\(host):\(port), project: \(projectId))"
    }
}

/// 読み取った QR を受け入れられない理由。
public enum FluseConnectError: Equatable {
    /// `fluse://connect` ではない。別のアプリの QR を読んだ。
    case notFluse

    /// 必要な値が足りない、または形が違う。
    case malformed

    /// サーバとアプリでプロトコルの版が違う。
    case protocolMismatch

    /// 別プロジェクトの Preview App。
    case projectMismatch

    /// ビルドに使った Flutter が違う。
    case revisionMismatch
}

/// 解いた結果。
public enum FluseConnectResult: Equatable {
    case accepted(FluseConnectRequest)
    case rejected(FluseConnectError)
}

/**
 * QR と手入力を同じ形に均す。
 *
 * **ここで弾いてもサーバ側の検証は省かない。** こちらは「読んだ瞬間に
 * 理由が分かる」ためのもので、権威はあくまでサーバの `hello` / `reject`
 * （設計 §3.1）。端末側の値は利用者が手で書き換えられる。
 */
public enum FluseConnectUri {
    public static let scheme = "fluse"
    public static let host = "connect"

    /// `rev` に載るのは先頭8桁（設計 §4.2(a)）。
    public static let revisionLength = 8

    private static let prefix = "\(scheme)://\(host)"

    /// 読んだ文字列を解く。中身の突き合わせは `verify` が行う。
    public static func parse(_ raw: String) -> FluseConnectResult {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("\(prefix)?") else {
            return .rejected(.notFluse)
        }

        let queryString = String(text.dropFirst(prefix.count + 1))
        guard let query = decodeQuery(queryString) else {
            return .rejected(.malformed)
        }
        let version = query["v"].flatMap { Int($0) }
        let rawHost = query["h"]
        let port = query["p"].flatMap { Int($0) }
        let projectId = query["pid"]
        let token = query["t"]
        let revision = query["rev"]

        // **空白だけの値も受け付けない。** `h=%20` は decode 後に空でない
        // 文字列になり、そのまま繋ぎ先として渡ってしまう。
        guard
            let version = version,
            let rawHost = rawHost, !isBlank(rawHost),
            let port = port,
            let projectId = projectId, !isBlank(projectId),
            let token = token, !isBlank(token),
            let revision = revision, !isBlank(revision)
        else {
            return .rejected(.malformed)
        }
        guard (1...65535).contains(port) else {
            return .rejected(.malformed)
        }

        return .accepted(
            FluseConnectRequest(
                protocolVersion: version,
                host: rawHost,
                port: port,
                projectId: projectId,
                pairingToken: token,
                revision: revision
            )
        )
    }

    /**
     * この端末に入っている Preview App と噛み合うか見る。
     *
     * 噛み合わないまま繋ぎに行っても、サーバが `reject` を返すだけ。
     * 往復を省いて、その場で理由を出す。
     */
    public static func verify(_ request: FluseConnectRequest, appInfo: FluseAppInfo) -> FluseConnectError? {
        if request.protocolVersion != fluseProtocolVersion {
            return .protocolMismatch
        }
        if request.projectId != appInfo.projectId {
            return .projectMismatch
        }
        if request.revision != String(appInfo.flutterRevision.prefix(revisionLength)) {
            return .revisionMismatch
        }
        return nil
    }

    /**
     * 手入力から組み立てる（設計 §4.2(b) の `GET /` が値の出どころ）。
     *
     * カメラの無い端末とエミュレータのための道。案内ページに出ている
     * ホスト・ポート・トークンを写してもらう。
     *
     * `pid` と `rev` は QR にしか無いので、この端末の値で埋める。
     * **突き合わせを緩めているわけではない。** サーバは `hello` の中身を
     * 見て、違えば断る。
     */
    public static func fromManualInput(
        host: String,
        port: String,
        token: String,
        appInfo: FluseAppInfo
    ) -> FluseConnectResult {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedPort = Int(port.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !trimmedHost.isEmpty, !trimmedToken.isEmpty, let parsedPort = parsedPort else {
            return .rejected(.malformed)
        }
        guard (1...65535).contains(parsedPort) else {
            return .rejected(.malformed)
        }

        return .accepted(
            FluseConnectRequest(
                protocolVersion: fluseProtocolVersion,
                host: trimmedHost,
                port: parsedPort,
                projectId: appInfo.projectId,
                pairingToken: trimmedToken,
                revision: String(appInfo.flutterRevision.prefix(revisionLength))
            )
        )
    }

    /// 空、または空白のみか。Kotlin の `isNullOrBlank()` に相当。
    private static func isBlank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /**
     * クエリを解く。
     *
     * `pairingToken` は base64url（設計 §4.2(a)）で、`%` は現れない。
     * ただし将来の値のために percent-decode は通しておく。
     */
    private static func decodeQuery(_ query: String) -> [String: String]? {
        var result: [String: String] = [:]
        // Kotlin の `split('&')` は空要素を落とさないため、ここでも
        // `omittingEmptySubsequences: false` で揃える。
        for pair in query.split(separator: "&", omittingEmptySubsequences: false) {
            if pair.isEmpty { continue }
            guard let equalsIndex = pair.firstIndex(of: "=") else { continue }
            if equalsIndex == pair.startIndex { continue }
            let key = String(pair[pair.startIndex..<equalsIndex])
            // 同じキーが2度出たら最初を採る。後から上書きさせない。
            if result[key] != nil { continue }
            let rawValue = String(pair[pair.index(after: equalsIndex)...])
            // **壊れたエスケープは通さない。** 直せば別の値になってしまい、
            // 読み取ったものと繋ぎに行く先が食い違う。
            guard let decoded = percentDecode(rawValue) else { return nil }
            result[key] = decoded
        }
        return result
    }

    /// 壊れていれば nil。`%A` のような中途半端なエスケープを直さない。
    ///
    /// UTF-16 のコード単位ごとに Kotlin と同じ手順で処理する。文字単位
    /// （`Character`）で処理すると、サロゲートペアの扱いが Kotlin の
    /// `Char` 単位の走査とずれる恐れがあるため。
    private static func percentDecode(_ value: String) -> String? {
        if !value.contains("%") {
            return value
        }
        let units = Array(value.utf16)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(units.count)
        var i = 0
        let percent = UInt16(UnicodeScalar("%").value)
        while i < units.count {
            let unit = units[i]
            if unit != percent {
                bytes.append(UInt8(truncatingIfNeeded: unit))
                i += 1
                continue
            }
            if i + 2 >= units.count {
                return nil
            }
            guard
                let hexString = String(utf16CodeUnits: [units[i + 1], units[i + 2]], count: 2) as String?,
                let hexValue = Int(hexString, radix: 16),
                (0...255).contains(hexValue)
            else {
                return nil
            }
            bytes.append(UInt8(hexValue))
            i += 3
        }
        // Kotlin の `ByteArray.toString(Charsets.UTF_8.name())` は不正な
        // バイト列でも例外を出さず置換文字で埋める。`String(decoding:as:)`
        // も同じ挙動（decode に失敗しても nil を返さない）なのでこちらを使う。
        return String(decoding: bytes, as: UTF8.self)
    }
}
