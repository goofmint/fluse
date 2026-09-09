import Foundation

/// 赤画面に出す中身。
///
/// 移植元: `packages/fluse_runtime/android/src/main/kotlin/dev/fluse/runtime/FluseOverlayState.kt`
public struct FluseOverlayContent: Equatable {
    public let summary: String
    public let lines: [String]

    public init(summary: String, lines: [String]) {
        self.summary = summary
        self.lines = lines
    }
}

/// 受け取ったメッセージから決まる、赤画面への指示。
public enum FluseOverlayCommand: Equatable {
    case show(FluseOverlayContent)

    /// 直ったので消す。
    case hide

    /// この画面には関係の無いメッセージ。
    case ignore
}

/**
 * 何を出すかを決める（設計 §5.2）。
 *
 * Android のランタイムに触らない。**View と分けておく。** 赤画面は
 * 「Dart が起動しない時に出るもの」で、動かして確かめるのが最も難しい
 * 部類に入る。判断だけでも単体で確かめられるようにしておく。
 */
public enum FluseOverlayState {
    /// 診断が無い時に出す文言の代わり。
    public static let noLocation = "場所不明"

    /// 画面に残すパスの深さ。
    public static let pathSegments = 3

    /// 端を落としたことを示す印。
    public static let ellipsis = "…/"

    public static func of(_ message: FluseMessage) -> FluseOverlayCommand {
        if let compileError = message as? CompileErrorMessage {
            return .show(
                FluseOverlayContent(
                    summary: compileError.summary,
                    lines: compileError.diagnostics.map(lineOf)
                )
            )
        }
        if message is CompileOkMessage {
            return .hide
        }
        return .ignore
    }

    /**
     * 1件を1行にする。
     *
     * `file:line:col` を頭に置く（設計 §5.2）。どこを直せばよいかが
     * 分からないと、赤画面はただ視界を塞ぐだけになる。
     */
    public static func lineOf(_ entry: DiagnosticEntry) -> String {
        let place = placeOf(entry) ?? noLocation
        return "\(markOf(entry.severity)) \(place): \(entry.message)"
    }

    /// `file:line:col`。ファイルは短くしてから組み立てる。
    public static func placeOf(_ entry: DiagnosticEntry) -> String? {
        guard let file = entry.file else { return nil }
        let shortened = shorten(file)
        guard let line = entry.line else { return shortened }
        guard let col = entry.col else { return "\(shortened):\(line)" }
        return "\(shortened):\(line):\(col)"
    }

    /**
     * 画面に出すパスを短くする。
     *
     * `frontend_server` はホスト側の絶対パスをそのまま返す
     * （`/Users/<名前>/work/app/lib/main.dart`）。**そのまま出さない。**
     * 端末の画面に開発者の名前や置き場所まで映るうえ、狭い画面では肝心の
     * ファイル名が押し出される。
     *
     * どこを直すかが分かればよいので、末尾の `pathSegments` 段だけ残す。
     */
    public static func shorten(_ file: String) -> String {
        // **`\\` も区切りとして扱う。** frontend_server は動かした側の
        // パスをそのまま返すため、Windows なら `C:\Users\...` の形で来る。
        // `/` だけを見ていると丸ごと素通りする。
        let path = removeFileScheme(file).replacingOccurrences(of: "\\", with: "/")
        let segments = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if segments.count <= pathSegments {
            return segments.joined(separator: "/")
        }
        return ellipsis + segments.suffix(pathSegments).joined(separator: "/")
    }

    /// 深刻度の目印。色を分けると赤画面の上で見分けが付かない。
    public static func markOf(_ severity: DiagnosticSeverity) -> String {
        switch severity {
        case .error: return "✗"
        case .warning: return "△"
        case .info: return "・"
        case .context: return " "
        }
    }

    /// `file://` を先頭の1回だけ取り除く。見つからなければそのまま返す
    /// （Kotlin の `substringAfter("file://")` に相当）。
    private static func removeFileScheme(_ file: String) -> String {
        guard let range = file.range(of: "file://") else { return file }
        return String(file[range.upperBound...])
    }
}

/// バッジに出す接続の様子。
///
/// 移植元: `packages/fluse_runtime/android/src/main/kotlin/dev/fluse/runtime/FluseOverlayState.kt`
/// （`FluseBadgeState`、同ファイルに同居）。
///
/// **`FluseSurfaces` / `FluseErrorOverlay` / `FluseBadge` は移植しない。**
/// これらは Android の `View`（`WindowManager` に載せるオーバーレイと
/// バッジ）へ直接描画する実装で、iOS 側に対応する画面がまだ無い
/// （Issue #94 の範囲）。ここに移す `FluseOverlayState` /
/// `FluseBadgeState` はその判断だけを切り出した部分であり、View を
/// 持たないぶん先行して移植できる。
public enum FluseBadgeState: Equatable {
    /// 繋ぎに行っている最中。
    case connecting

    case connected

    /// 切れた。接続側が繋ぎ直している。
    case disconnected

    /// QR の読み直しが要る。
    case needsPairing

    /// 断られた。繋ぎ直しでは解けない。
    case rejected

    /// 繋ぎに行く前の状態。
    ///
    /// **移植元は `FluseBadge.state` の初期値として持っている**
    /// （`var state = FluseBadgeState.CONNECTING`）。バッジ本体は
    /// 移植しないが、「何も出さないと繋がっていないことに気づけない」
    /// という判断はここに残しておく。
    ///
    /// 状態の遷移そのもの（`onConnected` → `.connected` など）は
    /// 関数として切り出していない。移植元では条件分岐の無い一対一の
    /// 代入で、Kotlin 側に対応する純関数が無いため、ここで作ると
    /// iOS 側のバッジ実装（Issue #94）の形を先取りすることになる。
    public static let initial = FluseBadgeState.connecting
}
