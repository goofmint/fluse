package dev.fluse.runtime

import android.os.Build
import android.security.NetworkSecurityPolicy

/**
 * `ws://` を張れる端末設定になっているか（設計 §10-4）。
 *
 * **`usesCleartextTraffic` はライブラリからは押し通せない。**
 * マニフェストの優先順位は利用者のアプリが上で、アプリが
 * `networkSecurityConfig` を持てばそちらが勝つ。`tools:replace` を書いても
 * 覆らない。
 *
 * その状態で繋ぎに行くと、OkHttp が平文を拒んで例外になる。理由を出さないと
 * 「繋がらない」としか見えず、原因に辿り着けない。
 *
 * **宣言の有無ではなく、実際に通るかどうかを見る。** 独自の
 * `networkSecurityConfig` を持っていても、開発サーバへの平文を許して
 * いれば繋がる。宣言だけを見て断ると誤って止めることになる。
 */
object FluseCleartext {
    /**
     * `NetworkSecurityPolicy` にホスト別の判定が入った版。
     *
     * これ未満の端末では `ws://` は素通りする（API 28 で既定が変わる前）。
     */
    const val MIN_POLICY_SDK = Build.VERSION_CODES.N

    /** 端末の設定を見て、[host] へ平文で繋げるか。 */
    fun isPermitted(host: String): Boolean = isPermitted(Build.VERSION.SDK_INT, host, ::askPolicy)

    /**
     * 判定そのもの。Android のランタイムに触らないので単体で確かめられる。
     *
     * [ask] は端末に尋ねる手。古い端末では呼ばない。
     */
    fun isPermitted(
        sdkInt: Int,
        host: String,
        ask: (String) -> Boolean,
    ): Boolean {
        if (sdkInt < MIN_POLICY_SDK) {
            // 尋ねる先が無い。この頃の端末は平文を止めない。
            return true
        }
        return ask(host)
    }

    /**
     * 塞がれている時に出す文言。
     *
     * **何をすればよいかまで書く。** 「平文が拒否されました」だけでは、
     * 自分のアプリの設定が原因だと気づけない。
     */
    fun blockedMessage(host: String): String =
        buildString {
            append("$host への平文接続がアプリの設定で拒否されています。")
            append("プレビューは ws:// を使うため繋がりません（設計 §10-4）。\n")
            append("アプリが独自の networkSecurityConfig を持っている場合、")
            append("fluse が debug マニフェストで入れる usesCleartextTraffic は上書きされます。\n")
            append("debug 用の network_security_config.xml に次を足してください:\n")
            append("  <domain-config cleartextTrafficPermitted=\"true\">\n")
            append("    <domain includeSubdomains=\"true\">$host</domain>\n")
            append("  </domain-config>")
        }

    private fun askPolicy(host: String): Boolean =
        NetworkSecurityPolicy.getInstance().isCleartextTrafficPermitted(host)
}
