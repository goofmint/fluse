/// L1統合テスト（Task 2.5）の補助。**テスト専用**で、本番コードからは使わない。
///
/// 実 WebSocket と、VM Service に見立てたダミー TCP エコーサーバを用意する。
library;

import 'dart:async';
import 'dart:io';

import 'package:fluse_server/fluse_server.dart';

/// `dart:io` の [WebSocket] を [TunnelChannel] に見せる実装。
///
/// 本番では `WsServer`（Task 3.2）が同じ WebSocket の text frame も扱う。
/// ここは binary frame だけを見る L1 検証用の最小実装。
final class WebSocketTunnelChannel implements TunnelChannel {
  WebSocketTunnelChannel(this._socket);

  final WebSocket _socket;

  @override
  Stream<List<int>> get incoming =>
      _socket.where((Object? event) => event is List<int>).cast<List<int>>();

  /// 直前の送信。[send] を直列化して順序を保つために持つ。
  Future<void> _tail = Future<void>.value();

  @override
  Future<void> send(List<int> frame) {
    // `add` は送信キューへ積むだけで、書き終わりが分からない。
    // **待たずに返すと**「送り出しが済んだ」という TunnelChannel の約束が
    // 崩れ、バックプレッシャの計上が実際より軽く見える。
    // `addStream` は書き終わってから完了するので、こちらを使う。
    //
    // `addStream` は多重に呼べない。前の完了に繋いで直列化する。
    final Future<void> result = _tail.then(
      (void _) => _socket.addStream(Stream<List<int>>.value(frame)),
    );
    // 失敗しても後続を止めない。止めると以降の送信が全部道連れになる。
    _tail = result.catchError((Object _) {});
    return result;
  }
}

/// 受け取ったバイトをそのまま返すだけの TCP サーバ。
///
/// 端末上の VM Service の代わり。`FluseTunnel` はここへ接続する。
/// 4本同時接続（DevFS の HTTP PUT 最大3並列 + VM Service の WebSocket 1本）
/// を扱えることが実運用条件に相当する。
final class EchoServer {
  EchoServer._(this._server) {
    _subscription = _server.listen(_accept);
  }

  /// `127.0.0.1` の空きポートで待ち受ける。
  static Future<EchoServer> bind() async {
    final ServerSocket server = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    return EchoServer._(server);
  }

  final ServerSocket _server;
  late final StreamSubscription<Socket> _subscription;
  final List<Socket> _clients = <Socket>[];

  /// 待ち受けているポート。ハーネスの `vmServicePort` に渡す。
  int get port => _server.port;

  void _accept(Socket socket) {
    _clients.add(socket);
    // addStream は相手が閉じるまで流し続ける。エコーはこれで十分。
    unawaited(
      socket.addStream(socket).catchError((Object _) {}).whenComplete(() async {
        _clients.remove(socket);
        await socket.close().catchError((Object _) {});
      }),
    );
  }

  Future<void> close() async {
    await _subscription.cancel();
    await _server.close();
    for (final Socket socket in _clients.toList()) {
      socket.destroy();
    }
    _clients.clear();
  }
}
