package dev.fluse.runtime

import kotlinx.coroutines.flow.Flow

/**
 * トンネルが使う WebSocket の binary チャネル。
 *
 * **WebSocket そのものは所有しない。** 同じ接続の text frame を制御
 * メッセージが使うため、ソケットの持ち主は `FluseConnection` であり、
 * トンネルは binary frame の出入り口だけを借りる。
 *
 * サーバ側 `packages/fluse_server/lib/src/tunnel_channel.dart` の鏡像。
 * 責務の分け方を両側で揃えておかないと、片方だけ WebSocket を閉じて
 * もう片方が生き残る、という切り分けの難しい状態になる。
 */
interface TunnelChannel {
    /**
     * サーバから届いた binary frame。
     *
     * 1要素が 1 フレーム。フローが正常終了すれば相手が閉じたこと、
     * 例外で終われば受信が壊れたことを表す。[FluseTunnel] はどちらの
     * 場合もトンネル全体を畳む。
     */
    val incoming: Flow<ByteArray>

    /**
     * binary frame を1つ送る。
     *
     * **この関数の復帰は「送り出しが済んだ」ことを表す。** 実装は
     * 書き込みが片付いてから戻ること。呼び出し側はこれを直列化の
     * 手がかりにしている。
     */
    suspend fun send(frame: ByteArray)
}
