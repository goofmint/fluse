import Foundation

/// 最初の画面で選ぶ道（設計 §2.2.5 の起動シーケンス）。
///
/// 移植元: `packages/fluse_runtime/android/src/main/kotlin/dev/fluse/runtime/FluseStartup.kt`
public enum StartupPath: Equatable {
    /// `deviceToken` があり、前回の接続先も分かる。まずそこへ繋ぎ直す。
    case reconnect

    /// ペアリングが要る。QR の読み取り画面を出す。
    case pair
}

/**
 * 起動時の分岐。
 *
 * Android のランタイムに触らない判定だけを切り出してある。
 * ここが間違うと「毎回 QR を求められる」か「繋がらないまま黙る」の
 * どちらかになるので、単体で確かめられる形にしておく。
 *
 * **`StartupHandler` 相当は移植しない。** Android 版は
 * `FluseConnection` / `FluseConnectActivity` への配線口を示すだけの
 * インターフェースで、iOS 側の対応する画面遷移がまだ無い
 * （Task 4.3 / 4.4 に相当するものが iOS 側にできてから配線する）。
 */
public enum FluseStartup {
    /**
     * `hasDeviceToken` と `hasLastServer` から進む道を決める。
     *
     * **トークンだけでは足りない。** 接続先が分からなければ繋ぎようが
     * ないので、QR から取り直す。トークン自体は残しておき、同じサーバに
     * 再会したときに再ペアリングを省ける。
     */
    public static func resolve(hasDeviceToken: Bool, hasLastServer: Bool) -> StartupPath {
        if hasDeviceToken && hasLastServer {
            return .reconnect
        }
        return .pair
    }
}
