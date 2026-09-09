import Foundation

/**
 * ATS（App Transport Security）が `ws://` を張れる設定になっているか
 * （設計 §10-4）。
 *
 * 移植元: `packages/fluse_runtime/android/src/main/kotlin/dev/fluse/runtime/FluseCleartext.kt`
 *
 * **Android と判定の形が根本的に違う。** Android は `NetworkSecurityPolicy`
 * で「今、この host へ `ws://` を張れるか」を実行時に問い合わせられる
 * （`isCleartextTrafficPermitted(host)`）。iOS の ATS には対応する
 * 事前問い合わせ API が無いため、次の2つを組み合わせて判定するしかない:
 *
 *   1. **事前判定（宣言を見る）**: Info.plist に
 *      `NSAppTransportSecurity` → `NSAllowsLocalNetworking` が無ければ、
 *      ローカルネットワークへの `ws://` は ATS に塞がれる。これは
 *      Android の「宣言の有無ではなく実際に通るかどうかを見る」という
 *      方針とは違う（宣言そのものを見ている）。iOS にはホスト単位の
 *      例外設定（`NSExceptionDomains`）はあるが、開発サーバは起動ごとに
 *      IP が変わりうるため、ホスト単位の宣言では判定しきれない。よって
 *      ここでは「ローカルネットワーク全体を許しているか」という、より粗い
 *      宣言の有無だけを見る。
 *   2. **受動判定（実際に繋いで見る）**: 実際に接続を試み、`URLError` の
 *      コードが `-1022`
 *      （`NSURLErrorAppTransportSecurityRequiresSecureConnection`）なら、
 *      それが「ATS が拒んだ」という動かぬ証拠になる。Android の
 *      `askHost` に一番近いのはこちら（実際に起きた結果を見ている）。
 *
 * どちらか一方だけでは断定できないため両方を用意し、呼び出し側
 * （`FluseConnection`）が使う: `connect()` の時点では 1 を先に見て早めに
 * 知らせ、接続が実際に失敗したときは 2 で確信を持って知らせる。
 */
public enum FluseATSCheck {
    private static let transportSecurityKey = "NSAppTransportSecurity"
    private static let allowsLocalNetworkingKey = "NSAllowsLocalNetworking"

    /// `URLError.Code.appTransportSecurityRequiresSecureConnection` の
    /// 生の値。列挙子の存在に依存せず数値で比較する
    /// （Foundation のバージョン差でケース名が変わっても揺れない）。
    static let atsErrorCode = -1022

    /// ATS がローカルネットワークへの平文接続を事前に許しているか
    /// （実行中のアプリの Info.plist を見る版）。
    public static func isLocalNetworkingAllowed(bundle: Bundle = .main) -> Bool {
        isLocalNetworkingAllowed(infoDictionary: bundle.infoDictionary)
    }

    /**
     * 判定そのもの。`Bundle` に触らないので単体で確かめられる。
     *
     * **プレビューは `ws://` を使うため、これが無いと繋がらない**
     * （設計 §10-4）。Info.plist に次が無ければ ATS が塞ぐ:
     * ```xml
     * <key>NSAppTransportSecurity</key>
     * <dict>
     *   <key>NSAllowsLocalNetworking</key>
     *   <true/>
     * </dict>
     * ```
     */
    static func isLocalNetworkingAllowed(infoDictionary: [String: Any]?) -> Bool {
        guard let ats = infoDictionary?[transportSecurityKey] as? [String: Any] else {
            return false
        }
        return (ats[allowsLocalNetworkingKey] as? Bool) ?? false
    }

    /**
     * 塞がれている時に出す文言。
     *
     * **何をすればよいかまで書く。** 「ATS に拒否されました」だけでは、
     * 自分のアプリの Info.plist が原因だと気づけない
     * （Kotlin 版の `blockedMessage` と同じ判断）。
     */
    public static func blockedMessage(host: String) -> String {
        """
        \(host) への平文接続が ATS（App Transport Security）に拒否されています。プレビューは ws:// を使うため繋がりません（設計 §10-4）。
        Info.plist の NSAppTransportSecurity に次を足してください:
          <key>NSAppTransportSecurity</key>
          <dict>
            <key>NSAllowsLocalNetworking</key>
            <true/>
          </dict>
        """
    }

    /**
     * ソケットの失敗が ATS による拒否かどうか（受動判定）。
     *
     * `URLSessionTaskDelegate` から渡ってくる `Error` は `URLError` として
     * 橋渡しされる（`FluseSocket.swift` の `Adapter` を参照。エラーを
     * 元の型のまま `onFailure` に渡している）。`NSError` としての比較に
     * 倒しているのは、`URLError.Code` に対応するケースが無いバージョンの
     * Foundation でもビルドが通るようにするため。
     */
    public static func isATSFailure(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == atsErrorCode
    }
}
