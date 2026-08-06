import 'dart:async';
import 'dart:io';

import 'package:fluse_protocol/fluse_protocol.dart';

import 'fluse_logger.dart';
import 'tunnel_channel.dart';

/// トンネルの中継に失敗したときに投げる。
final class TunnelException implements Exception {
  /// [message] に失敗の内容、[cause] に元の例外を渡す。
  const TunnelException(this.message, {this.cause});

  /// 失敗の内容。
  final String message;

  /// 元になった例外。無い場合は null。
  final Object? cause;

  @override
  String toString() =>
      cause == null ? 'トンネル: $message' : 'トンネル: $message ($cause)';
}

/// `ServerSocket` を作る関数。テストから差し替えるために切り出す。
typedef ServerSocketFactory = Future<ServerSocket> Function();

/// サーバ側のトンネル終端（設計 §2.2.3(e)）。
///
/// localhost に TCP を待ち受け、来た接続を WebSocket の binary frame として
/// 端末へ運ぶ。端末側（`FluseTunnel`）が本物の VM Service へ繋ぐ。
///
/// **プロトコルは一切解釈しない**（設計 §10-3）。VM Service は JSON-RPC
/// over WebSocket と DevFS の HTTP PUT を同じポートで受けるため、片方だけ
/// 対応した「賢いプロキシ」は必ず破綻する。ここはバイト列を運ぶだけ。
final class TunnelEndpoint {
  TunnelEndpoint({
    required TunnelChannel channel,
    FluseLogger? logger,
    ServerSocketFactory? serverSocketFactory,
    this.highWaterMark = defaultHighWaterMark,
    this.lowWaterMark = defaultLowWaterMark,
  }) : _channel = channel,
       _logger = logger,
       _serverSocketFactory =
           serverSocketFactory ??
           (() => ServerSocket.bind(InternetAddress.loopbackIPv4, 0)) {
    if (lowWaterMark >= highWaterMark) {
      throw ArgumentError.value(
        lowWaterMark,
        'lowWaterMark',
        'highWaterMark ($highWaterMark) より小さくしてください',
      );
    }
  }

  /// 送信キューがこれを超えたら TCP の読み取りを止める（設計 §8.2-5）。
  static const int defaultHighWaterMark = 4 * 1024 * 1024;

  /// ここまで減ったら読み取りを再開する。
  ///
  /// 高水位と同じ値にすると、境界で pause と resume を往復して
  /// かえって遅くなる。ヒステリシスを持たせる。
  static const int defaultLowWaterMark = 1 * 1024 * 1024;

  /// 送信キューがこの量を超えたら TCP の読み取りを止める。
  final int highWaterMark;

  /// 送信キューがこの量まで減ったら TCP の読み取りを再開する。
  final int lowWaterMark;

  final TunnelChannel _channel;
  final FluseLogger? _logger;
  final ServerSocketFactory _serverSocketFactory;

  ServerSocket? _server;
  StreamSubscription<Socket>? _acceptSubscription;
  StreamSubscription<List<int>>? _incomingSubscription;

  final Map<int, _TunnelStream> _streams = <int, _TunnelStream>{};

  /// 次に採番する streamId。
  int _nextStreamId = 1;

  /// 送り出しが済んでいないバイト数。
  int _pendingBytes = 0;

  bool _closed = false;

  /// バックプレッシャで読み取りを止めているか。
  ///
  /// 実際の購読状態と揃える必要がある。閾値から都度計算すると、
  /// 中間帯（低水位 < 現在 <= 高水位）で「止めているのに false」になる。
  bool _backpressured = false;

  Completer<void>? _terminated;

  /// 受信が失敗した理由。[close] が [done] をこれで終わらせる。
  Object? _terminationError;
  StackTrace? _terminationTrace;

  /// 中継中のストリーム数。
  int get activeStreams => _streams.length;

  /// 送信待ちのバイト数。
  int get pendingBytes => _pendingBytes;

  /// バックプレッシャで TCP の読み取りを止めているか。
  bool get isPaused => _backpressured;

  /// トンネルが終わったら完了する。
  ///
  /// チャネルが閉じた・受信でエラーが出た場合もここで分かる。**呼び出し
  /// 元はこれを監視すること。** 監視しないと、中継が止まっているのに
  /// TCP 待ち受けだけ生きている状態に気づけない。
  /// [bind] 前は完了済みの [Future] を返す。
  Future<void> get done => _terminated?.future ?? Future<void>.value();

  /// localhost に待ち受けを立て、VM Service として振る舞う URI を返す。
  ///
  /// [remoteVmServiceUri] は端末側の
  /// `http://127.0.0.1:<devicePort>/<authCode>/`。返す URI は
  /// **同じ authCode を保ったまま**ローカルのポートを指す。認証コードは
  /// VM Service のパスそのものなので、書き換えると通らなくなる。
  Future<Uri> bind(String remoteVmServiceUri) async {
    if (_closed) {
      // close 後に bind できてしまうと、_closed が true のままなので
      // close フレームが送られず、中継が片方向だけ壊れる。
      throw const TunnelException('すでに close 済みです');
    }
    if (_server != null) {
      throw const TunnelException('すでに bind 済みです');
    }

    final Uri remote = Uri.parse(remoteVmServiceUri);
    final List<String> segments = remote.pathSegments
        .where((String s) => s.isNotEmpty)
        .toList();
    if (segments.isEmpty) {
      throw TunnelException(
        'VM Service の URI に認証コードがありません: ${remote.replace(path: '')}',
      );
    }

    // パスセグメントがそのまま資格情報。以降のログから消す。
    for (final String segment in segments) {
      _logger?.addSecret(segment);
    }

    final ServerSocket server = await _serverSocketFactory();
    _server = server;
    _acceptSubscription = server.listen(
      _acceptConnection,
      onError: (Object error) => _logger?.warn('TCP の待ち受けでエラーが発生しました: $error'),
    );

    final Completer<void> terminated = Completer<void>();
    _terminated = terminated;
    _incomingSubscription = _channel.incoming.listen(
      _handleIncomingFrame,
      onError: (Object error, StackTrace stackTrace) {
        // 記録だけして続けると、中継が死んだことに誰も気づけない。
        _logger?.warn('トンネルの受信でエラーが発生しました: $error');
        _terminationError = TunnelException('トンネルの受信が失敗しました', cause: error);
        _terminationTrace = stackTrace;
        unawaited(close());
      },
      // done は close() が後始末を終えてから完了させる。ここで先に
      // 完了させると、待っている側が「閉じ終わった」と誤解する。
      onDone: () => unawaited(close()),
    );

    final Uri local = Uri(
      scheme: 'http',
      host: server.address.address,
      port: server.port,
      pathSegments: <String>[...segments, ''],
    );
    _logger?.debug(
      'トンネルを開きました',
      fields: <String, Object?>{'localPort': server.port},
    );
    return local;
  }

  /// 待ち受けと全ストリームを閉じる。二重に呼んでも安全。
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;

    await _acceptSubscription?.cancel();
    _acceptSubscription = null;
    await _incomingSubscription?.cancel();
    _incomingSubscription = null;
    await _server?.close();
    _server = null;

    // 反復中に _streams が変わるのでコピーしてから回す。
    for (final _TunnelStream stream in _streams.values.toList()) {
      await stream.dispose();
    }
    _streams.clear();
    _pendingBytes = 0;
    _backpressured = false;

    final Completer<void>? terminated = _terminated;
    if (terminated != null && !terminated.isCompleted) {
      final Object? error = _terminationError;
      if (error != null) {
        terminated.completeError(
          error,
          _terminationTrace ?? StackTrace.current,
        );
      } else {
        terminated.complete();
      }
    }
  }

  // ------------------------------------------------------- TCP -> WebSocket

  void _acceptConnection(Socket socket) {
    final int streamId = _allocateStreamId();
    final _TunnelStream stream = _TunnelStream(
      streamId: streamId,
      socket: socket,
    );
    _streams[streamId] = stream;

    _logger?.debug(
      'トンネルのストリームを開きました',
      fields: <String, Object?>{'streamId': streamId},
    );

    _send(TunnelFrame.open(streamId));

    stream.subscription = socket.listen(
      (List<int> data) => _forwardToTunnel(stream, data),
      onError: (Object error) {
        _logger?.debug(
          'TCP でエラーが発生しました',
          fields: <String, Object?>{'streamId': streamId, 'error': '$error'},
        );
        unawaited(_closeStream(streamId, notifyPeer: true));
      },
      onDone: () => unawaited(_closeStream(streamId, notifyPeer: true)),
    );

    // 既に高水位を超えている最中に来た接続も止める。忘れると新しい
    // 接続だけ全速で読み続けてしまう。
    if (_backpressured) {
      stream.pause();
    }
  }

  /// TCP から読んだバイト列をフレームに割って送る。
  ///
  /// **1フレームの上限を超える分は自分で分割する。** プロトコル層は
  /// 自動では割らず、超えたら例外にする約束になっている。
  void _forwardToTunnel(_TunnelStream stream, List<int> data) {
    for (int offset = 0; offset < data.length;) {
      final int end = offset + TunnelFrame.maxPayloadLength < data.length
          ? offset + TunnelFrame.maxPayloadLength
          : data.length;
      _send(TunnelFrame.data(stream.streamId, data.sublist(offset, end)));
      offset = end;
    }
    _applyBackpressure();
  }

  void _send(TunnelFrame frame) {
    final List<int> bytes;
    try {
      bytes = frame.encode();
    } on FluseProtocolException catch (error) {
      // 自分で作ったフレームが符号化できないのは実装の誤り。
      // 黙って捨てると、相手は届いたと思って待ち続ける。
      throw TunnelException('フレームを符号化できません', cause: error);
    }

    _pendingBytes += bytes.length;
    unawaited(
      _channel
          .send(bytes)
          .catchError((Object error) {
            _logger?.warn('トンネルへの送信に失敗しました: $error');
            // 送れなかったフレームは失われる。対向は届いたと思って
            // 待ち続けるので、該当ストリームを畳む。close フレームも
            // 同じチャネルを通るため、こちらからは送らない。
            unawaited(_closeStream(frame.streamId, notifyPeer: false));
          })
          .whenComplete(() {
            _pendingBytes -= bytes.length;
            _applyBackpressure();
          }),
    );
  }

  /// 送信キューの量に応じて TCP の読み取りを止める / 再開する。
  void _applyBackpressure() {
    if (_pendingBytes > highWaterMark) {
      _backpressured = true;
      for (final _TunnelStream stream in _streams.values) {
        stream.pause();
      }
      return;
    }
    if (_pendingBytes <= lowWaterMark) {
      _backpressured = false;
      for (final _TunnelStream stream in _streams.values) {
        stream.resume();
      }
    }
  }

  // ------------------------------------------------------- WebSocket -> TCP

  void _handleIncomingFrame(List<int> bytes) {
    final TunnelFrame frame;
    try {
      frame = TunnelFrame.decode(bytes);
    } on FluseProtocolException catch (error) {
      // 壊れたフレームは握り潰さない。どのストリームのものかも
      // 分からないので、ここでは記録に留める。
      _logger?.warn(
        'トンネルのフレームを解釈できません',
        fields: <String, Object?>{'error': '$error'},
      );
      return;
    }

    switch (frame.opcode) {
      case TunnelOpcode.data:
        _writeToSocket(frame);
      case TunnelOpcode.close:
        unawaited(_closeStream(frame.streamId, notifyPeer: false));
      case TunnelOpcode.open:
        // サーバ側の待ち受けはローカル TCP 起点なので、対向からの open に
        // 対応する接続先が無い。開けないことを伝えて畳む。
        _logger?.warn(
          '対向からの open は受け付けられません',
          fields: <String, Object?>{'streamId': frame.streamId},
        );
        _send(TunnelFrame.close(frame.streamId));
    }
  }

  void _writeToSocket(TunnelFrame frame) {
    final _TunnelStream? stream = _streams[frame.streamId];
    if (stream == null) {
      // 既に閉じたストリーム宛。相手がまだ知らないだけなので、
      // 閉じたことを伝える。
      _send(TunnelFrame.close(frame.streamId));
      return;
    }

    try {
      stream.socket.add(frame.payload);
    } on Object catch (error) {
      _logger?.debug(
        'TCP への書き込みに失敗しました',
        fields: <String, Object?>{
          'streamId': frame.streamId,
          'error': '$error',
        },
      );
      unawaited(_closeStream(frame.streamId, notifyPeer: true));
    }
  }

  // ------------------------------------------------------------- ライフサイクル

  Future<void> _closeStream(int streamId, {required bool notifyPeer}) async {
    final _TunnelStream? stream = _streams.remove(streamId);
    if (stream == null) {
      return;
    }

    if (notifyPeer && !_closed) {
      _send(TunnelFrame.close(streamId));
    }

    _logger?.debug(
      'トンネルのストリームを閉じました',
      fields: <String, Object?>{'streamId': streamId},
    );
    await stream.dispose();
  }

  /// uint32 を一周したら 1 に戻す。
  ///
  /// 実際に一周するのは現実的でないが、負数や範囲外の streamId を
  /// 作らないようにしておく。
  int _allocateStreamId() {
    final int id = _nextStreamId;
    _nextStreamId = id >= TunnelFrame.maxStreamId ? 1 : id + 1;
    return id;
  }
}

/// 中継中の1ストリーム。
final class _TunnelStream {
  _TunnelStream({required this.streamId, required this.socket});

  final int streamId;
  final Socket socket;
  StreamSubscription<List<int>>? subscription;

  bool _paused = false;
  bool _disposed = false;

  void pause() {
    if (_paused || _disposed) {
      return;
    }
    _paused = true;
    subscription?.pause();
  }

  void resume() {
    if (!_paused || _disposed) {
      return;
    }
    _paused = false;
    subscription?.resume();
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;

    // pause 中の購読を cancel すると解放されないことがあるので先に戻す。
    if (_paused) {
      _paused = false;
      subscription?.resume();
    }
    await subscription?.cancel();
    subscription = null;

    try {
      await socket.close();
    } on Object {
      // すでに切れている場合は何もしなくてよい。
    }
    socket.destroy();
  }
}
