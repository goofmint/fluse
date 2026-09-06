package dev.fluse.runtime

/**
 * 画面に重ねるもの（設計 §5.2 / §2.2.5）のまとめ役。
 *
 * **接続より先に立てる。** 繋がらなかったことも、コンパイルが通らな
 * かったことも、出せなければ利用者には「何も起きない」としか見えない。
 * 接続が出来上がってから [listenTo] で繋ぎ込む。
 */
internal object FluseSurfaces {
    private val overlay = FluseErrorOverlay()
    private val badge = FluseBadge()

    @Volatile
    private var started = false

    /** 前面の Activity を追い始める。 */
    fun start() {
        if (started) {
            return
        }
        started = true
        overlay.start()
        badge.start()
    }

    /**
     * 接続の出来事を受け取り始める。
     *
     * **接続を作った場所すべてから呼ぶ。** 再接続の道とペアリングの道で
     * 入口が2つあり、片方だけに置くともう片方から入った時に赤画面も
     * バッジも動かない。二度呼んでも増えない。
     */
    fun listenTo(connection: FluseConnection) {
        start()
        connection.addListener(overlay)
        connection.addListener(badge)
    }
}
