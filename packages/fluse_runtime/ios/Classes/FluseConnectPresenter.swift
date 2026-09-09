import Foundation

/// ペアリング画面（Task 9.5 / Issue #93）に出す文言。
///
/// 移植元: `packages/fluse_runtime/android/src/main/res/values/fluse_strings.xml`
/// （Android は文字列リソースだが、iOS 側にはリソース機構が無いため、
/// 判断ロジックと同じ場所に定数として持つ）。
///
/// **文言そのものは Android 版とできるだけ揃える。** 同じ状況で違う説明が
/// 出ると、Android/iOS で挙動が違うように見えてしまう。
public enum FluseConnectStrings {
    public static let scanHint = "サーバの画面に出ている QR を読み取ってください"
    public static let manualSwitchTitle = "QR を使わずに入力する"
    public static let manualHint = "サーバの案内ページに出ている値を入力してください"
    public static let hostPlaceholder = "ホスト（例: 192.168.0.10）"
    public static let portPlaceholder = "ポート（例: 8180）"
    public static let tokenPlaceholder = "トークン"
    public static let connectButtonTitle = "接続する"

    public static let errorNotFluse = "fluse の QR ではありません"
    public static let errorMalformed = "QR の内容を読み取れませんでした"
    public static let errorProtocol = "サーバとアプリのバージョンが違います。fluse を揃えてください"
    public static let errorProject = "別プロジェクトの Preview App です"
    public static let errorRevision = "ビルドに使った Flutter が違います。作り直してください"
    public static let errorAuth = "認証できませんでした。QR を取り直してください"
    public static let errorTooManyDevices = "すでに別の端末が繋がっています"
    public static let errorNoCamera = "カメラを使えません。手で入力してください"
    public static let errorConnect = "サーバに繋がりませんでした。ホストとポートを確認してください"
    public static let errorAppInfo = "Preview App の情報を読めませんでした"

    /// QR / 手入力の検証で弾かれた理由の文言。
    public static func message(for error: FluseConnectError) -> String {
        switch error {
        case .notFluse: return errorNotFluse
        case .malformed: return errorMalformed
        case .protocolMismatch: return errorProtocol
        case .projectMismatch: return errorProject
        case .revisionMismatch: return errorRevision
        }
    }

    /// `reject` の理由コードの文言。
    ///
    /// **未知のコードでも黙らない。** 新しいサーバが増やしたコードを
    /// 古いアプリが受け取っても、理由の文言だけは出す
    /// （Android 版の `messageFor(RejectCode?)` と同じ判断）。
    public static func message(forRejectCode code: RejectCode?) -> String {
        switch code {
        case .authFailed: return errorAuth
        case .projectMismatch: return errorProject
        case .revisionMismatch: return errorRevision
        case .protocolMismatch: return errorProtocol
        case .appOutdated: return errorRevision
        case .tooManyDevices: return errorTooManyDevices
        case nil: return errorMalformed
        }
    }
}

/// ペアリング画面が UI 層へ返す指示。
///
/// **UI（`UIViewController` / `AVCaptureSession`）はこの列挙を受け取って
/// 実行するだけにする。** 「いつ・どの文言を・どちらの面に出すか」という
/// 判断は `FluseConnectPresenter` 側に閉じ込め、UI 層はここに判断を持たない。
public enum FluseConnectAction: Equatable {
    /// スキャン面の案内文を更新する。
    case showScanMessage(String)
    /// 手入力面の案内文を更新する。
    case showManualMessage(String)
    /// 手入力面へ切り替え、案内文を出す。
    case switchToManual(message: String)
    /// 接続を開始する。呼び出し側が `FluseConnection.getOrCreate(...).connect(...)` を呼ぶ。
    case beginConnect(FluseConnectRequest)
    /// 読み取りを再開する（受け入れられなかった時。カメラが止まっていても無害）。
    case resumeScanning
    /// 画面を閉じる（受理された）。
    case finish
}

/**
 * ペアリング画面の判断だけを切り出したもの（UI 非依存）。
 *
 * 移植元: `FluseConnectActivity.kt`（に相当する新規実装。Kotlin 版は
 * `connecting` / `established` フラグと画面遷移を Activity 自身に持たせて
 * いるが、iOS 側ではその判断だけをここへ切り出し、`UIViewController` は
 * 本クラスが返す `FluseConnectAction` を実行するだけの薄い層にする
 * （`swift test` は macOS で走り `UIKit` / `AVFoundation` に触れないため、
 * ここを split しないと一切テストできなくなる）。
 *
 * **カメラ面か手入力面かは呼び出し側の見た目ではなく、ここが持つ
 * `isManualActive` で決める。** Android 版の `showError()` が
 * `manualPane.visibility` を見て振り先を決めるのと同じ判断で、
 * 「QR から接続を始めた後に『手入力に切り替え』を押した」ような
 * 途中の切り替えでも、失敗メッセージは今見えている面に出る。
 */
public final class FluseConnectPresenter {
    private let appInfo: FluseAppInfo

    /// 繋ぎに行っている間は次の読み取り・送信を受け付けない。
    private var connecting = false

    /// `accept` まで届いたか。届く前の切断だけを失敗として扱う。
    private var established = false

    /// 今、手入力面が見えているか。
    private var isManualActive = false

    public init(appInfo: FluseAppInfo) {
        self.appInfo = appInfo
    }

    /// テストのために公開する。UI 層はこれを見て分岐しない
    /// （分岐は `FluseConnectAction` の形で返す）。
    public var isConnecting: Bool { connecting }
    public var isEstablished: Bool { established }
    public var isManualPaneActive: Bool { isManualActive }

    // ------------------------------------------------------------ カメラ

    /// カメラが使えない（ハードウェアが無い、または権限を拒否された）。
    ///
    /// **行き止まりにしない。** 手入力面へ必ず案内する。
    public func cameraUnavailable() -> [FluseConnectAction] {
        isManualActive = true
        return [.switchToManual(message: FluseConnectStrings.errorNoCamera)]
    }

    /// 利用者が「QR を使わずに入力する」を押した。
    public func switchToManualRequested() -> [FluseConnectAction] {
        isManualActive = true
        return [.switchToManual(message: FluseConnectStrings.manualHint)]
    }

    // ------------------------------------------------------------ 入力

    /// QR から読み取った文字列。
    ///
    /// **`connecting` 中は無視する。** 二重送信を防ぐ。受け入れられなければ
    /// 読み取りを再開できるよう `resumeScanning` を添える。
    public func scanned(_ text: String) -> [FluseConnectAction] {
        guard !connecting else { return [] }
        switch FluseConnectUri.parse(text) {
        case let .rejected(error):
            return [.showScanMessage(FluseConnectStrings.message(for: error)), .resumeScanning]
        case let .accepted(request):
            return proceed(with: request)
        }
    }

    /// 手入力3項目（ホスト・ポート・トークン）の送信。
    public func manualSubmitted(host: String, port: String, token: String) -> [FluseConnectAction] {
        guard !connecting else { return [] }
        let result = FluseConnectUri.fromManualInput(host: host, port: port, token: token, appInfo: appInfo)
        switch result {
        case let .rejected(error):
            return [.showManualMessage(FluseConnectStrings.message(for: error))]
        case let .accepted(request):
            return proceed(with: request)
        }
    }

    /// 解けた `FluseConnectRequest` を、繋ぎに行く前にもう一度確かめる。
    ///
    /// **サーバ側の検証を省いた訳ではない。** ここで弾いても往復が
    /// 1回省けるだけで、権威は依然としてサーバの `hello` / `reject`。
    private func proceed(with request: FluseConnectRequest) -> [FluseConnectAction] {
        if let error = FluseConnectUri.verify(request, appInfo: appInfo) {
            let message = FluseConnectStrings.message(for: error)
            if isManualActive {
                return [.showManualMessage(message)]
            }
            return [.showScanMessage(message), .resumeScanning]
        }
        connecting = true
        return [.beginConnect(request)]
    }

    // ------------------------------------------------- FluseConnectionListener 相当

    /// 受理された。
    public func connected(sessionId: String) -> [FluseConnectAction] {
        established = true
        return [.finish]
    }

    /// 断られた。**再試行しない。**（`FluseConnection` 側も繋ぎ直さない）
    public func rejected(code: String, message: String) -> [FluseConnectAction] {
        failed(message: FluseConnectStrings.message(forRejectCode: RejectCode.tryParse(code)))
    }

    /// ペアリングからやり直す必要がある（`deviceToken` が通らなかった）。
    public func needsPairing(reason: String) -> [FluseConnectAction] {
        failed(message: FluseConnectStrings.errorAuth)
    }

    /// ATS に `ws://` が塞がれている。
    ///
    /// **そのまま出す。** `FluseATSCheck` が作る文言には直し方まで
    /// 書いてあるので、ここで丸めると意味が無くなる。
    public func cleartextBlocked(message: String) -> [FluseConnectAction] {
        failed(message: message)
    }

    /// 切れた。
    ///
    /// **受理される前の切断だけ失敗として扱う。** 受理後の切断は
    /// `FluseConnection` が自分で繋ぎ直すので、この画面は既に閉じている
    /// はずであり、ここには来ない想定だが、来ても何もしない。
    public func disconnected() -> [FluseConnectAction] {
        guard !established else { return [] }
        return failed(message: FluseConnectStrings.errorConnect)
    }

    /// `connect()` の呼び出し自体が失敗した（例外を投げた）。
    public func connectFailedToStart() -> [FluseConnectAction] {
        failed(message: FluseConnectStrings.errorConnect)
    }

    /// 繋がらなかった。もう一度やり直せる状態に戻す。
    private func failed(message: String) -> [FluseConnectAction] {
        connecting = false
        let messageAction: FluseConnectAction = isManualActive
            ? .showManualMessage(message)
            : .showScanMessage(message)
        return [messageAction, .resumeScanning]
    }
}
