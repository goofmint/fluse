#if canImport(Flutter)
import Flutter
import Foundation

/// 端末側ランタイムの入口（設計 §2.2.5）。
///
/// Dart 側から VM Service の URI を受け取り、状態は [FluseRuntimeCore] へ
/// 渡す。実際のロジックはそちらに切り出してあり、ここは
/// `MethodChannel` の配線だけを担う。トンネルとエラーオーバーレイは
/// 後続タスクで足す（Issue #91 以降）。
///
/// 移植元: `packages/fluse_runtime/android/src/main/kotlin/dev/fluse/runtime/FluseRuntimePlugin.kt`。
public final class FluseRuntimePlugin: NSObject, FlutterPlugin {
    private var channel: FlutterMethodChannel?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: FluseRuntimeCore.channelName,
            binaryMessenger: registrar.messenger()
        )
        let instance = FluseRuntimePlugin()
        instance.channel = channel
        registrar.addMethodCallDelegate(instance, channel: channel)

        // **起動フック（設計 §2.2.5 / Task 9.5・Issue #93）。** iOS に
        // `ContentProvider` は無いが、この `register(with:)` がエンジン
        // 初期化時に必ず一度呼ばれるので、`FluseInitProvider.kt` 相当の
        // 入口として使う。保存済みトークンがあれば再接続、無ければ
        // ペアリング画面を出す（`FluseStartupCoordinator` 側の判断）。
        // `canImport(Flutter)` が真の実行環境（CocoaPods 経由の iOS
        // ビルド）では常に UIKit も使えるはずだが、呼び出し先が触る
        // `UIKit` / `AVFoundation` を型として持ち出さないよう、ここでも
        // 同じガードを重ねておく。
        #if canImport(UIKit)
        FluseStartupCoordinator.start()
        #endif
    }

    public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
        channel = nil
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case FluseRuntimeCore.methodVmServiceReady:
            handleVmServiceReady(call: call, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func handleVmServiceReady(call: FlutterMethodCall, result: @escaping FlutterResult) {
        // 引数の誤りは Dart 側の実装誤り。黙って成功にすると
        // 「繋がらない理由が分からない」状態になる。
        // **「型が違う」と「空だった」を混ぜない。** 同じ文面にすると
        // 原因を取り違えたまま Dart 側を探すことになる。
        guard let uri = call.arguments as? String else {
            result(
                FlutterError(
                    code: "INVALID_ARGUMENT",
                    message: "vmServiceUri が文字列ではありません",
                    details: nil
                )
            )
            return
        }
        guard !uri.isEmpty else {
            result(
                FlutterError(
                    code: "INVALID_ARGUMENT",
                    message: "vmServiceUri が空文字です",
                    details: nil
                )
            )
            return
        }

        // 最新の URI を保持する。Hot Restart のたびに同じ URI が再送
        // されるが、上書きなので冪等に扱える。マスクしたログの出力も
        // ここで行う（[FluseRuntimeCore] を参照）。
        FluseRuntimeCore.handleVmServiceReady(uri)
        result(nil)
    }
}
#endif
