import Foundation

/// トンネルが使う WebSocket の binary チャネル。
///
/// 移植元: `packages/fluse_runtime/android/src/wire/kotlin/dev/fluse/runtime/TunnelChannel.kt`
///
/// **WebSocket そのものは所有しない。** 同じ接続の text frame を制御
/// メッセージが使うため、ソケットの持ち主は `FluseConnection` であり、
/// トンネルは binary frame の出入り口だけを借りる。
///
/// サーバ側 `packages/fluse_server/lib/src/tunnel_channel.dart` の鏡像。
/// 責務の分け方を両側で揃えておかないと、片方だけ WebSocket を閉じて
/// もう片方が生き残る、という切り分けの難しい状態になる。
///
/// **本番の `FluseConnection` / `FluseSocket` への配線はこのタスクの範囲外**
/// （Kotlin 側も同様）。この protocol 越しに差し込むところまでが範囲。
///
/// **並行処理モデルについて**: この protocol と `FluseTunnel` だけ Swift
/// Concurrency（`async`/`await`, `AsyncThrowingStream`）で書く。理由は
/// `FluseTunnel.swift` のヘッダコメントを参照。
@available(iOS 13.0, macOS 11.0, *)
public protocol TunnelChannel: AnyObject {
    /// サーバから届いた binary frame。
    ///
    /// 1要素が1フレーム。ストリームが正常終了すれば相手が閉じたこと、
    /// エラーで終われば受信が壊れたことを表す。`FluseTunnel` はどちらの
    /// 場合もトンネル全体を畳む。
    ///
    /// Kotlin 版の `Flow<ByteArray>` に相当する。`Flow` は「値を要求される
    /// たびに供給する」cold stream だが `AsyncThrowingStream` は基本的に
    /// hot（生成時から供給側が動く）という違いがある。ただし `FluseTunnel`
    /// はこのストリームを一度しか iterate しない（`start()` が1回だけ
    /// `for try await` で回す）ため、この違いが実際の挙動に影響することはない。
    var incoming: AsyncThrowingStream<[UInt8], Error> { get }

    /// binary frame を1つ送る。
    ///
    /// **この関数の復帰は「送り出しが済んだ」ことを表す。** 実装は
    /// 書き込みが片付いてから戻ること。呼び出し側はこれを直列化の
    /// 手がかりにしている。
    func send(_ frame: [UInt8]) async throws
}
