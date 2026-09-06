package dev.fluse.runtime

/**
 * 再接続の待ち時間（設計 §2.2.5）。
 *
 * `1s → 2s → 4s → … → 30s` と伸ばし、30s で頭打ちにする。**すぐに繋ぎ
 * 直し続けてはいけない。** サーバを落としたまま端末を放置すると、
 * 秒間何十回もの接続でバッテリを削り、サーバ復帰時には溜まった接続が
 * 一斉に来る。
 *
 * Android に触らないので単体で確かめられる。
 */
class FluseBackoff(
    private val initialMs: Long = DEFAULT_INITIAL_MS,
    private val maxMs: Long = DEFAULT_MAX_MS,
) {
    companion object {
        const val DEFAULT_INITIAL_MS = 1_000L
        const val DEFAULT_MAX_MS = 30_000L
    }

    private var currentMs = 0L

    /** 次に待つミリ秒。 */
    fun next(): Long {
        currentMs =
            if (currentMs == 0L) {
                initialMs
            } else {
                (currentMs * 2).coerceAtMost(maxMs)
            }
        return currentMs
    }

    /** 繋がったら呼ぶ。次の切断で最初の待ち時間から始める。 */
    fun reset() {
        currentMs = 0L
    }
}
