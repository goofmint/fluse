/// トンネルが使う WebSocket の binary チャネル。
///
/// **WebSocket そのものは所有しない。** 同じ接続の text frame を制御
/// メッセージが使うため、ソケットの持ち主は `WsServer`（Task 3.2）で
/// あり、トンネルは binary frame の出入り口だけを借りる。
abstract interface class TunnelChannel {
  /// 端末から届いた binary frame。
  Stream<List<int>> get incoming;

  /// binary frame を1つ送る。
  ///
  /// **返る [Future] は「送り出しが済んだ」ことを表す。** これが完了する
  /// までを「送信キューに載っている」とみなしてバックプレッシャを判断する
  /// ので、実装は書き込みが片付いてから完了させること。
  Future<void> send(List<int> frame);
}
