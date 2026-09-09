#if canImport(UIKit)
import UIKit

/**
 * ペアリング画面（`FluseConnectViewController`）を乗せる専用ウィンドウ。
 *
 * 移植元: `FluseConnectActivity.kt` の `intentFor` に相当する新規実装。
 * Android は別 Activity を起動するだけで済むが、iOS 側にはプラグインから
 * 開ける「別画面」の概念が無い。ホストアプリの `rootViewController` を
 * 掴んで一時的にモーダルを乗せる方法もあるが、起動の最初期
 * （`register(with:)` の直後）は既にホストアプリの画面が前に出ている
 * 保証が無く、`rootViewController` を横取りするとホストアプリの画面遷移と
 * 衝突しうる。**独自の `UIWindow` を通常より高い `windowLevel` で前面に
 * 出す**ことで、ホストアプリの画面階層に触れずに済ませる。
 */
final class FluseConnectPresentation {
    /// **型に持たせる。** ローカル変数のままだと ARC に解放され、
    /// 画面がすぐ消える（`FluseConnection.instance` と同じ理由でシングルトン）。
    static let shared = FluseConnectPresentation()

    private var window: UIWindow?

    private init() {}

    /// ペアリング画面を出す。
    ///
    /// **既に出ていれば何もしない。** 起動フックは一度しか呼ばない想定
    /// だが、二重に開いてカメラを取り合う事態を避ける。
    func present(store: FluseConnectionStore, device: FluseDeviceInfo, appInfo: FluseAppInfo) {
        guard window == nil else { return }

        let viewController = FluseConnectViewController(
            appInfo: appInfo,
            device: device,
            store: store
        ) { [weak self] in
            self?.dismiss()
        }

        let newWindow: UIWindow
        if let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
            newWindow = UIWindow(windowScene: scene)
        } else {
            // **前面の scene が見つからないことがある。** 起動のごく初期は
            // scene がまだ前面に出ていない場合がある。`UIWindow(frame:)` は
            // scene に紐付かない分だけ非推奨だが、表示自体はできる
            // （ペアリングという一度きりの導線でここまで気にする必要は無い）。
            newWindow = UIWindow(frame: UIScreen.main.bounds)
        }
        newWindow.windowLevel = .alert + 1
        newWindow.rootViewController = viewController
        newWindow.makeKeyAndVisible()
        window = newWindow
    }

    private func dismiss() {
        window?.isHidden = true
        window = nil
    }
}
#endif
