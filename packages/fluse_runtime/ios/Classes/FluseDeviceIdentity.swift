import Foundation
import CryptoKit
#if canImport(UIKit)
import UIKit
#endif

/**
 * 端末を見分けるための値（設計 §2.2.1 の `hello`）。
 *
 * 移植元: `packages/fluse_runtime/android/src/main/kotlin/dev/fluse/runtime/DeviceIdentity.kt`
 * （`hashAndroidId` / `deviceId` 部分、25-74行目）。
 *
 * **UIKit に触る部分と、触らない計算とを分けてある。** Kotlin 版の
 * コメントと同じ意図で、計算側だけなら Android のランタイム
 * （この場合 UIKit）が無い環境からも確かめられる。このパッケージは
 * `Package.swift` が `.iOS(.v13)` と `.macOS(.v11)` の両方を対象にしており
 * `swift test` は macOS 上で走るため、`UIDevice` に触る箇所は
 * `#if canImport(UIKit)` で隔離する（既存の前例: `FluseRuntimePlugin.swift`
 * の `#if canImport(Flutter)`）。ハッシュ計算そのもの（`hashVendorId` /
 * `deviceId(vendorId:fallback:)`）は platform 非依存にしてあり、macOS でも
 * そのままテストできる。
 *
 * **Android の `ANDROID_ID` とは取得元も性質も異なる。** Android は
 * `Settings.Secure.ANDROID_ID`（端末とアプリ署名の組で決まり、
 * アプリをアンインストールしても値は変わらない）を使うが、iOS の
 * パブリック API には対応する値が無い。代わりに
 * `UIDevice.identifierForVendor`（同じベンダーの全アプリを端末から
 * 削除すると変わりうる／条件によっては `nil` にもなりうる）を使う。
 * 「同じ端末なら同じ値」という性質は同じだが、値が変わりうるタイミングが
 * Android と異なる。元の値をそのまま送らずハッシュにする理由は
 * Android 版と同じ（サーバへ送る必要があるのは「同じ端末かどうか」だけ）。
 *
 * **`deviceName` は移植しない。** Kotlin 版は `Build.MANUFACTURER` +
 * `Build.MODEL` を組み合わせるが、iOS には対応する「メーカー名」の概念が
 * 無く、`UIDevice.current.name`（iOS 16 以降は既定でエンタイトルメントが
 * 無いと汎用値しか返らない）や `.model`（"iPhone" のような汎用名で、
 * 具体的な機種名は返らない）のどちらを使うかは UI 上の見せ方の判断を
 * 要する。`FluseDeviceInfo` の組み立て自体が別チケット
 * （`FluseConnection.swift` のコメント参照）の対象であり、この Issue の
 * 要求（端末識別の計算そのもの）にも含まれないため、ここでは扱わない。
 */
public enum FluseDeviceIdentity {
    /// `deviceId` の文字数。sha256 の先頭を16進で取る。
    public static let deviceIdLength = 16

    /// `identifierForVendor` をそのままは使わない。
    ///
    /// サーバへ送る必要があるのは「同じ端末かどうか」だけなので、
    /// ハッシュにして元の値を渡さない（Kotlin 版の `hashAndroidId` と
    /// 同じ理由）。
    public static func hashVendorId(_ vendorId: String) -> String {
        let digest = SHA256.hash(data: Data(vendorId.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(deviceIdLength))
    }

    /**
     * この端末の `deviceId`。ランタイム（UIKit）に触らないので単体で
     * 確かめられる。
     *
     * **`vendorId` が取れないときに固定値へ落としてはいけない。** 取れない
     * 端末どうしがサーバから見て1台に見え、片方の登録がもう片方を
     * 上書きする（Kotlin 版の `deviceId(context, store)` と同じ理由）。
     * 取れなければ [fallback] が返す、端末ごとの代替 ID を使う
     * （呼び出し側は通常 `FluseKeychainStore.fallbackDeviceId()` を渡す）。
     */
    public static func deviceId(vendorId: String?, fallback: () -> String) -> String {
        guard let vendorId = vendorId, !vendorId.isEmpty else {
            return fallback()
        }
        return hashVendorId(vendorId)
    }

    #if canImport(UIKit)
    /// `identifierForVendor` を取り出すだけの層。UIKit に触る唯一の箇所。
    ///
    /// **`nil` になりうる。** シミュレータや、端末が初回ロック解除前の
    /// 場合など（Android の `ANDROID_ID` が空文字を返す状況に相当）。
    public static func currentVendorId() -> String? {
        UIDevice.current.identifierForVendor?.uuidString
    }

    /// この端末の `deviceId`（実行環境から直接取る版）。
    public static func deviceId(store: FluseKeychainStore) -> String {
        deviceId(vendorId: currentVendorId(), fallback: { store.fallbackDeviceId() })
    }
    #endif
}
