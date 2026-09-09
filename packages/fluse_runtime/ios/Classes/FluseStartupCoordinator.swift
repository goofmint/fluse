#if canImport(UIKit)
import Foundation
import UIKit
import os.log

/**
 * 起動時にどちらの道を通るかを決めて、実際に動かす（設計 §2.2.5）。
 *
 * 移植元: `packages/fluse_runtime/android/src/main/kotlin/dev/fluse/runtime/FluseInitProvider.kt`
 * の `FluseActivityLifecycle.onActivityResumed` + `ConnectingStartupHandler`
 * に相当する新規実装。
 *
 * **`ContentProvider` に相当するものは使わない。** iOS には対応する
 * 「マニフェストに書くだけで起動時に呼ばれる」仕組みが無いが、
 * Flutter プラグインの `register(with:)` がエンジン初期化時に必ず一度
 * 呼ばれるため、`FluseRuntimePlugin.register(with:)` からここを呼ぶ方が
 * `FluseInitProvider.kt`（275行、`ContentProvider` の空実装や
 * `ActivityLifecycleCallbacks` の配線が大半）より素直に書ける。
 *
 * Android 版は「最初の Activity が前面に出た時」まで待つ
 * （`onActivityResumed`）が、iOS 側には「エンジンが起動した」という
 * 一度きりの節目（`register(with:)`）しか無く、かつペアリング画面は
 * 専用の `UIWindow` を自分で作る（`FluseConnectPresentation`）ため、
 * ホストアプリの `UIViewController` が前面に出るのを待つ必要が無い。
 */
enum FluseStartupCoordinator {
    private static let lock = NSLock()
    private static var started = false

    /// `register(with:)` から一度だけ呼ぶ。
    ///
    /// **二度目以降は何もしない。** Android 版の `AtomicBoolean` と同じ
    /// 役割。Hot Restart のたびに `register(with:)` が呼ばれ直しても、
    /// 生きている接続やペアリング画面を張り直さない。
    static func start() {
        #if DEBUG
        // **release ビルドでは何もしない。** `fluse_runtime` は
        // `dev_dependency` としてしか使わない想定だが、ビルド構成次第では
        // release にもプラグインが残りうる（Android 版の `isDebuggable`
        // チェックと同じ「念のため」の判断）。VM Service が無い release
        // ビルドではプレビューは成立しないので、ここで諦めてよい。
        lock.lock()
        guard !started else {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()

        // **メインスレッドで待たない。** Keychain の初期化（`probe` の
        // 読み書き）はエンジン起動直後の初回だけ時間がかかることがあり、
        // ここで待つとアプリの起動そのものが遅れる
        // （`FluseActivityLifecycle.onActivityResumed` の `background.execute` と同じ判断）。
        DispatchQueue.global(qos: .userInitiated).async {
            resolveAndStart()
        }
        #endif
    }

    private static func resolveAndStart() {
        let appInfo: FluseAppInfo
        do {
            appInfo = try FluseAppInfo.load()
        } catch {
            // **既定値では埋めない。** 読めなければ `hello` を組み立てられず、
            // どのサーバへ繋いでも断られる。プレビューは諦めるが、アプリ
            // 自体は動かす（fluse は dev_dependency であって本体ではない。
            // `ConnectingStartupHandler.reconnect` の catch と同じ判断）。
            os_log(
                "Preview App の情報を読めませんでした: %{public}@",
                log: FluseRuntimeCore.log,
                type: .error,
                String(describing: error)
            )
            return
        }

        let store = FluseKeychainStore.open()
        let path = FluseStartup.resolve(
            hasDeviceToken: store.hasDeviceToken(),
            hasLastServer: store.hasLastServer()
        )

        // `UIDevice` に触るのはここから先だけ。メインスレッドへ戻す。
        DispatchQueue.main.async {
            let device = FluseDeviceInfo(
                deviceId: FluseDeviceIdentity.deviceId(store: store),
                deviceName: UIDevice.current.name
            )
            switch path {
            case .reconnect:
                reconnect(store: store, device: device, appInfo: appInfo)
            case .pair:
                FluseConnectPresentation.shared.present(store: store, device: device, appInfo: appInfo)
            }
        }
    }

    /// 保存済みトークンで無画面接続する。
    private static func reconnect(
        store: FluseConnectionStore,
        device: FluseDeviceInfo,
        appInfo: FluseAppInfo
    ) {
        guard let host = store.lastHost, let port = store.lastPort else {
            // `hasLastServer()` が true ならここには来ない契約
            // （`FluseKeychainStore.hasLastServer()` 参照）。来てしまったら
            // 黙って諦めず、唯一残っている代替手段（ペアリング画面）へ回す。
            os_log(
                "再接続先の情報が壊れています。ペアリング画面を出します",
                log: FluseRuntimeCore.log,
                type: .error
            )
            FluseConnectPresentation.shared.present(store: store, device: device, appInfo: appInfo)
            return
        }

        let connection = FluseConnection.getOrCreate(store: store, device: device, appInfo: appInfo)
        // **接続より先に届いた分を渡す。** `flusePreviewMain` はアプリの
        // 起動と並行に走るため、この接続が受理できる前に VM Service の
        // URI が届いていることがある。
        if let pending = FluseRuntimeCore.latestVmServiceUri {
            connection.vmServiceReady(pending)
        }
        // 再接続では `pairingToken` を渡さない。保存済みの `deviceToken` を使う。
        connection.connect(endpoint: FluseEndpoint(host: host, port: port))
    }
}
#endif
