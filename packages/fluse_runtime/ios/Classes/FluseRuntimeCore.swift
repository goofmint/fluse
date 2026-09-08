import Foundation
import os.log

/// 端末側ランタイムの入口が扱うロジック本体（設計 §2.2.5）。
///
/// **Flutter への依存を持たない。** `FlutterPlugin` を実装する
/// `FluseRuntimePlugin`（`FluseRuntimePlugin.swift`）から呼ばれるが、
/// ロジックだけをここへ切り出すことで、Flutter フレームワークが無い
/// 環境（SwiftPM の `swift test`）からも検証できる。Xcode プロジェクトを
/// 作らずに CI で回すのが狙い。
///
/// 移植元: `packages/fluse_runtime/android/src/main/kotlin/dev/fluse/runtime/FluseRuntimePlugin.kt`
/// （特に29-37行目の `latestVmServiceUri` と、`maskAuthCode` まわり）。
public enum FluseRuntimeCore {
    /// Dart 側と揃える。片方だけ変えると通知が届かなくなる。
    public static let channelName = "dev.fluse/runtime"

    /// VM Service が立ち上がったことの通知。
    public static let methodVmServiceReady = "vmServiceReady"

    /// os_log のカテゴリ。Android の logcat タグ `"fluse"` に揃える。
    static let log = OSLog(subsystem: "dev.fluse.runtime", category: "fluse")

    /// マスク後に残す先頭の文字数。
    ///
    /// Dart 側の `maskToken`（`packages/fluse_server/lib/src/redact.dart`）と揃える（設計 §6.1）。
    private static let maskPrefixLength = 4

    /// 認証コードとみなす最短の長さ。
    ///
    /// `/health` のような普通のパスを巻き込まないための足切り。
    /// Dart 側の `_maskUriAuthCode` と同じ値。
    private static let minAuthCodeLength = 8

    private static let lock = NSLock()

    /// 最後に受け取った VM Service の URI。
    ///
    /// **接続より先に届く。** アプリの起動と並行に走る経路があるため、
    /// トンネル相当のものがまだ無い時点で来ることがある（トンネルへの
    /// 転送は Issue #91）。インスタンスではなく型に持たせることで、
    /// 後から作られる接続へも渡せるようにする。
    ///
    /// MethodChannel の呼び出しはメインスレッドで届くのが通常だが、
    /// 読み出し側が別スレッドから参照する可能性を考えてロックで守る。
    private static var storedVmServiceUri: String?

    public static var latestVmServiceUri: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedVmServiceUri
    }

    /// VM Service の URI を受け取る。
    ///
    /// **Hot Restart のたびに同じ URI が再送される。** Dart 側の `main()` が
    /// 作り直されるため。上書きで冪等に受ける（同じ値の再送では状態が
    /// 変わらない）。
    public static func handleVmServiceReady(_ uri: String) {
        lock.lock()
        storedVmServiceUri = uri
        lock.unlock()

        // logcat は Dart 側の redact を通らないため、ここで必ず伏せる。
        os_log("VM Service を受け取りました: %{public}@", log: log, type: .info, maskAuthCode(uri))

        // TODO(Issue #91): iOS 側の接続（Android の `FluseConnection` 相当）が
        // できたら、ここから転送する。現時点ではまだ無いため、最新の URI を
        // 保持するところまでが本タスクの範囲。
    }

    /// VM Service の URI から認証コードを伏せる。
    ///
    /// **logcat（os_log）は Dart 側の redact を通らない。** VM Service の URI は
    /// `http://127.0.0.1:<port>/<authCode>/` の形で、**パスセグメント
    /// そのものが認証情報**になっている。これを掴んだ相手は DevFS への
    /// 書き込みも reloadSources の実行もできる。端末のログは Console.app
    /// 等で誰でも読めるため、ここで必ず伏せる。
    ///
    /// Kotlin 側の `FluseRuntimePlugin.maskAuthCode` と同じ規則
    /// （Dart 側の `redact.dart` の `_maskUriAuthCode` を単一 URI 向けに
    /// 簡略化したもの）。
    public static func maskAuthCode(_ uri: String) -> String {
        guard let schemeRange = uri.range(of: "://") else {
            return uri
        }
        guard let pathStart = uri[schemeRange.upperBound...].firstIndex(of: "/") else {
            // パスが無い。認証コードも無い。
            return uri
        }

        let prefix = String(uri[uri.startIndex..<pathStart])
        let path = uri[pathStart...]
        var segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)

        var replaced = false
        for index in segments.indices {
            if !replaced, segments[index].count >= minAuthCodeLength {
                segments[index] = mask(segments[index])
                replaced = true
            }
        }

        return prefix + segments.joined(separator: "/")
    }

    private static func mask(_ value: String) -> String {
        if value.count < maskPrefixLength + 1 {
            return "***"
        }
        return String(value.prefix(maskPrefixLength)) + "***"
    }
}
