import Foundation

/// カメラの権限状態を、`AVFoundation` の型を持ち込まずに表したもの。
///
/// **`AVAuthorizationStatus` をそのまま使わない。** macOS の
/// `swift test` からもこの判断を確かめたいため、UI 層
/// （`#if canImport(UIKit)` の中）で `AVAuthorizationStatus` から
/// 変換してから渡す。
public enum FluseCameraAuthorization: Equatable {
    /// 許可済み。
    case authorized
    /// まだ尋ねていない。これから尋ねられる。
    case notDetermined
    /// 拒否された、または端末の制限で使えない。
    case denied
}

/// 次に取るべき行動。
public enum FluseCameraDecision: Equatable {
    /// そのままカメラを起動する。
    case startCamera
    /// 権限を尋ねる。
    case requestPermission
    /// 手入力へ回す（ハードウェアが無い、または拒否された）。
    case useManualInput
}

/**
 * カメラを使えるかどうかの判断だけを切り出したもの（UI 非依存）。
 *
 * 移植元: `FluseConnectActivity.kt` の `hasCamera()` /
 * `requestCamera`（`registerForActivityResult`）に相当する新規実装。
 * Android 版はハードウェアの有無（`PackageManager.FEATURE_CAMERA_ANY`）と
 * 権限の可否を別々に見ているが、iOS 側はシミュレータに背面カメラの
 * ハードウェアが無いことが多く、この2つを一体で判断しても実害が無いため
 * まとめてある。
 */
public enum FluseCameraPermission {
    /**
     * ハードウェアの有無と権限状態から、次に取る行動を決める。
     *
     * **ハードウェアが無ければ権限の状態を見ずに手入力へ回す。**
     * シミュレータではそもそも尋ねる意味が無い（Android 版がエミュレータで
     * 最初から手入力を出すのと同じ判断）。
     */
    public static func decide(
        hasCameraHardware: Bool,
        authorization: FluseCameraAuthorization
    ) -> FluseCameraDecision {
        guard hasCameraHardware else { return .useManualInput }
        switch authorization {
        case .authorized: return .startCamera
        case .notDetermined: return .requestPermission
        case .denied: return .useManualInput
        }
    }
}
