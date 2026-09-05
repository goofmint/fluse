package dev.fluse.runtime

/**
 * 最初の Activity で選ぶ道（設計 §2.2.5 の起動シーケンス）。
 */
enum class StartupPath {
    /** `deviceToken` があり、前回の接続先も分かる。まずそこへ繋ぎ直す。 */
    RECONNECT,

    /** ペアリングが要る。QR の読み取り画面を出す。 */
    PAIR,
}

/**
 * 起動時の分岐。
 *
 * Android のランタイムに触らない判定だけを切り出してある。
 * ここが間違うと「毎回 QR を求められる」か「繋がらないまま黙る」の
 * どちらかになるので、単体で確かめられる形にしておく。
 */
object FluseStartup {
    /**
     * [hasDeviceToken] と [hasLastServer] から進む道を決める。
     *
     * **トークンだけでは足りない。** 接続先が分からなければ繋ぎようが
     * ないので、QR から取り直す。トークン自体は残しておき、同じサーバに
     * 再会したときに再ペアリングを省ける。
     */
    fun resolve(
        hasDeviceToken: Boolean,
        hasLastServer: Boolean,
    ): StartupPath =
        if (hasDeviceToken && hasLastServer) {
            StartupPath.RECONNECT
        } else {
            StartupPath.PAIR
        }
}

/**
 * 分岐した先の処理。
 *
 * 実体は Task 4.3（`FluseConnection`）と Task 4.4
 * （`FluseConnectActivity`）で入る。ここでは差し込み口だけを決めておく。
 */
interface StartupHandler {
    /** 前回のサーバへ繋ぎ直す。 */
    fun reconnect(
        host: String,
        port: Int,
    )

    /** ペアリング画面を出す。 */
    fun pair()
}
