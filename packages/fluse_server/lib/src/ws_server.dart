import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fluse_protocol/fluse_protocol.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'auth_crypto.dart';
import 'bind_address.dart';
import 'fluse_logger.dart';
import 'session_manager.dart';
import 'tunnel_channel.dart';

/// 端末との唯一の入口（設計 §2.2.3 / §4.2(b)）。
///
/// 1つのポートで案内ページ・APK 配信・疎通確認・WebSocket を捌く。
/// WebSocket の中では **text frame が制御メッセージ、binary frame が
/// TCP トンネル**という2つの流れが同居する（設計 §2.2.1）。
///
/// **WebSocket はここが所有する。** `TunnelEndpoint` には
/// [TunnelChannel] だけを渡す。所有権を分けないと、片方が閉じた時に
/// もう片方が生き残る切り分けの難しい状態になる。
final class WsServer {
  WsServer({
    required SessionManager sessionManager,
    this.host,
    this.port = defaultPort,
    this.serveApk = true,
    this.apkPath,
    this.missedPongLimit = defaultMissedPongLimit,
    FluseLogger? logger,
    Future<List<InternetAddress>> Function()? addresses,
    void Function(FluseConnection connection)? onAuthenticated,
    void Function(FluseConnection connection, FluseMessage message)? onMessage,
    void Function(FluseConnection connection)? onDisconnected,
  }) : _sessions = sessionManager,
       _logger = logger,
       _addresses = addresses,
       _onAuthenticated = onAuthenticated,
       _onMessage = onMessage,
       _onDisconnected = onDisconnected;

  /// 既定のポート（設計 §1.1）。
  static const int defaultPort = 8180;

  /// pong が続けて返らないときに切るまでの回数。
  ///
  /// 1回で切ると、たまたま重なった GC やアプリの一時停止で落ちる。
  static const int defaultMissedPongLimit = 2;

  /// APK の Content-Type。これ以外だと Android がインストーラを開かない。
  static const String apkContentType =
      'application/vnd.android.package-archive';

  /// 待ち受けるアドレス。null なら プライベート IPv4 を自動で選ぶ。
  final String? host;

  final int port;

  /// `/apk` で Preview App を配信するか。
  final bool serveApk;

  /// 配信する APK の場所。null なら配信しない。
  final String? apkPath;

  /// pong の未応答をこの回数だけ許す。
  final int missedPongLimit;

  final SessionManager _sessions;
  final FluseLogger? _logger;
  final Future<List<InternetAddress>> Function()? _addresses;
  final void Function(FluseConnection connection)? _onAuthenticated;
  final void Function(FluseConnection connection, FluseMessage message)?
  _onMessage;
  final void Function(FluseConnection connection)? _onDisconnected;

  HttpServer? _server;
  final Set<FluseConnection> _connections = <FluseConnection>{};

  /// 実際に待ち受けているアドレス。[start] 前は null。
  InternetAddress? get address => _server?.address;

  /// 実際に待ち受けているポート。[start] 前は null。
  ///
  /// [port] に 0 を渡した場合、ここで実際の値が分かる。
  int? get boundPort => _server?.port;

  /// 端末に見せる基底 URI。[start] 前は null。
  Uri? get baseUri {
    final HttpServer? server = _server;
    if (server == null) {
      return null;
    }
    return Uri(scheme: 'http', host: server.address.address, port: server.port);
  }

  /// 接続中の端末。
  Iterable<FluseConnection> get connections => _connections;

  /// 待ち受けを開始する。
  Future<Uri> start() async {
    if (_server != null) {
      throw StateError('すでに start 済みです');
    }

    final InternetAddress bind = await resolveBindAddress(
      host: host,
      addresses: _addresses,
    );

    if (isAnyHost(bind.address)) {
      // 黙って開けない。平文でソースが流れる以上、届く範囲が唯一の境界。
      _logger?.warn(
        '全てのネットワークインタフェースで待ち受けます。'
        'LAN 上の第三者がソースを取得できます（設計 §6.1）',
        fields: <String, Object?>{'host': bind.address},
      );
    }

    final HttpServer server = await shelf_io.serve(_handler, bind, port);
    _server = server;

    final Uri uri = baseUri!;
    _logger?.info(
      'サーバを開始しました',
      fields: <String, Object?>{'url': uri.toString()},
    );
    return uri;
  }

  /// 待ち受けと全接続を閉じる。二重に呼んでも安全。
  Future<void> close() async {
    final HttpServer? server = _server;
    _server = null;

    // 反復中に集合が変わるのでコピーしてから回す。
    for (final FluseConnection connection in _connections.toList()) {
      try {
        await connection.close(CloseCode.shutdown, 'サーバを終了します');
      } on Object catch (error) {
        // 1本の失敗で残りの後始末を止めない。閉じ損ねた接続と
        // 待ち受けが生き残る方が困る。
        _logger?.warn('接続の切断に失敗しました: $error');
      }
    }
    _connections.clear();

    await server?.close(force: true);
  }

  // ------------------------------------------------------------ HTTP

  Handler get _handler => (Request request) {
    return switch ('/${request.url.path}') {
      '/ws' => _webSocketHandler(request),
      '/health' => _health(),
      '/apk' => _apk(request),
      '/' => _indexPage(),
      _ => Response.notFound('not found'),
    };
  };

  Response _health() => Response.ok(
    jsonEncode(<String, Object?>{
      'status': 'ok',
      'protocolVersion': fluseProtocolVersion,
      'connectedDevices': _connections.length,
    }),
    headers: <String, String>{'content-type': 'application/json'},
  );

  /// `/apk?t=<pairingToken>`。
  ///
  /// **不一致は 404**（設計 §4.2(b)）。403 にすると「ファイルはある」と
  /// 教えることになる。
  Response _apk(Request request) {
    if (!serveApk) {
      return Response.notFound('not found');
    }

    final String? token = request.url.queryParameters['t'];
    final PairingToken? issued = _sessions.pairingToken;
    if (token == null ||
        issued == null ||
        !constantTimeEquals(issued.value, token)) {
      _logger?.warn('APK の配信を拒否しました（トークン不一致）');
      return Response.notFound('not found');
    }

    final String? path = apkPath;
    if (path == null) {
      return Response.notFound('not found');
    }
    final File apk = File(path);
    if (!apk.existsSync()) {
      _logger?.warn('APK がありません', fields: <String, Object?>{'path': path});
      return Response.notFound('not found');
    }

    return Response.ok(
      apk.openRead(),
      headers: <String, String>{
        'content-type': apkContentType,
        'content-length': '${apk.lengthSync()}',
        'content-disposition': 'attachment; filename="preview.apk"',
      },
    );
  }

  /// インストール案内ページ。
  ///
  /// QR を読めない端末のための手入力導線（設計 §2.2.3）。
  Response _indexPage() {
    final PairingToken? issued = _sessions.pairingToken;
    final bool downloadable =
        serveApk && apkPath != null && File(apkPath!).existsSync();

    final StringBuffer body = StringBuffer()
      ..writeln('<!doctype html>')
      ..writeln('<html lang="ja"><head>')
      ..writeln('<meta charset="utf-8">')
      ..writeln(
        '<meta name="viewport" content="width=device-width,'
        ' initial-scale=1">',
      )
      ..writeln('<title>fluse — Preview App のインストール</title>')
      ..writeln(
        '<style>'
        'body{font-family:system-ui,sans-serif;margin:2rem auto;'
        'max-width:32rem;padding:0 1rem;line-height:1.7}'
        'code{background:#f2f2f2;padding:.2em .4em;border-radius:.2em;'
        'word-break:break-all}'
        '.token{font-size:1.1rem;display:block;padding:.8em;'
        'background:#f2f2f2;border-radius:.4em;word-break:break-all}'
        '.btn{display:inline-block;padding:.7em 1.4em;background:#0b57d0;'
        'color:#fff;text-decoration:none;border-radius:.4em}'
        '</style>',
      )
      ..writeln('</head><body>')
      ..writeln('<h1>fluse Preview App</h1>');

    if (issued == null) {
      // start していない間に開かれることがある。無言の空白より説明を出す。
      body.writeln(
        '<p>ペアリングトークンがまだ発行されていません。'
        '<code>fluse start</code> を実行してください。</p>',
      );
    } else {
      if (downloadable) {
        body
          ..writeln('<h2>1. インストール</h2>')
          ..writeln(
            '<p><a class="btn" href="/apk?t='
            '${Uri.encodeQueryComponent(issued.value)}">'
            'Preview App をダウンロード</a></p>',
          )
          ..writeln('<h2>2. 接続</h2>');
      } else {
        body.writeln('<h2>接続</h2>');
      }
      body
        ..writeln(
          '<p>QR を読めない場合は、アプリの手入力欄に'
          '次のトークンを貼り付けてください。</p>',
        )
        ..writeln('<code class="token">${_escapeHtml(issued.value)}</code>')
        ..writeln(
          '<p>このトークンは1回限りで、'
          '${issued.expiresAt.toLocal()} に失効します。</p>',
        );
    }

    body.writeln('</body></html>');
    return Response.ok(
      body.toString(),
      headers: <String, String>{'content-type': 'text/html; charset=utf-8'},
    );
  }

  // ------------------------------------------------------------ WebSocket

  FutureOr<Response> _webSocketHandler(Request request) =>
      webSocketHandler((WebSocketChannel channel, String? _) {
        final FluseConnection connection = FluseConnection._(
          channel: channel,
          sessions: _sessions,
          logger: _logger,
          missedPongLimit: missedPongLimit,
          onAuthenticated: _onAuthenticated,
          onMessage: _onMessage,
          onDisconnected: _onDisconnected,
        );
        _connections.add(connection);
        unawaited(
          connection.done.whenComplete(() {
            _connections.remove(connection);
          }),
        );
      })(request);
}

/// 端末1台分の WebSocket 接続。
///
/// 制御メッセージ（text）とトンネル（binary）が同じソケットに同居する。
/// トンネル側には [TunnelChannel] としてだけ見せる。
final class FluseConnection implements TunnelChannel {
  FluseConnection._({
    required WebSocketChannel channel,
    required SessionManager sessions,
    required int missedPongLimit,
    FluseLogger? logger,
    void Function(FluseConnection connection)? onAuthenticated,
    void Function(FluseConnection connection, FluseMessage message)? onMessage,
    void Function(FluseConnection connection)? onDisconnected,
  }) : _channel = channel,
       _sessions = sessions,
       _missedPongLimit = missedPongLimit,
       _logger = logger,
       _onAuthenticated = onAuthenticated,
       _onMessage = onMessage,
       _onDisconnected = onDisconnected {
    _subscription = _channel.stream.listen(
      _handleFrame,
      onError: (Object error) {
        _logger?.warn('WebSocket でエラーが発生しました: $error');
        _teardownQuietly();
      },
      onDone: _teardownQuietly,
    );
  }

  final WebSocketChannel _channel;
  final SessionManager _sessions;
  final int _missedPongLimit;
  final FluseLogger? _logger;
  final void Function(FluseConnection connection)? _onAuthenticated;
  final void Function(FluseConnection connection, FluseMessage message)?
  _onMessage;
  final void Function(FluseConnection connection)? _onDisconnected;

  late final StreamSubscription<dynamic> _subscription;

  final StreamController<List<int>> _tunnelIn =
      StreamController<List<int>>.broadcast();
  final Completer<void> _done = Completer<void>();

  String? _sessionId;
  Timer? _heartbeat;
  int _pingSeq = 0;

  /// 送ったが pong が返っていない ping の数。
  int _missedPongs = 0;

  bool _closed = false;

  /// 認証が済んでいるか。
  bool get isAuthenticated => _sessionId != null;

  /// 認証済みのセッション ID。未認証なら null。
  String? get sessionId => _sessionId;

  /// 接続が終わったら完了する。
  Future<void> get done => _done.future;

  /// 未応答の ping の数。テストと診断のために公開する。
  int get missedPongs => _missedPongs;

  @override
  Stream<List<int>> get incoming => _tunnelIn.stream;

  @override
  Future<void> send(List<int> frame) async {
    // 閉じた sink への add は StateError になる。トンネルの送信は
    // 接続断と競合するので、ここで見ないと切断のたびに例外が漏れる。
    if (_closed) {
      return;
    }
    _channel.sink.add(frame);
  }

  /// 制御メッセージを1つ送る。
  void sendMessage(FluseMessage message) {
    if (_closed) {
      return;
    }
    _channel.sink.add(jsonEncode(message.toJson()));
  }

  /// `close` を送ってから閉じる。
  Future<void> close(CloseCode code, String reason) async {
    if (!_closed) {
      sendMessage(CloseMessage.of(code, message: reason));
    }
    await _teardown();
  }

  // --------------------------------------------------------------- 受信

  void _handleFrame(dynamic frame) {
    if (frame is String) {
      _handleControl(frame);
      return;
    }
    if (frame is List<int>) {
      _handleTunnel(frame);
      return;
    }
    _logger?.warn('未知の frame 種別を受け取りました: ${frame.runtimeType}');
  }

  void _handleTunnel(List<int> frame) {
    if (!isAuthenticated) {
      // 設計 §6.1。認証前のトンネルフレームは事故ではなく攻撃を疑う。
      // 応答を返さず即切る。
      _logger?.warn('未認証の接続からトンネルフレームを受け取りました。切断します');
      _teardownQuietly();
      return;
    }
    if (!_tunnelIn.isClosed) {
      _tunnelIn.add(frame);
    }
  }

  void _handleControl(String text) {
    final FluseMessage message;
    try {
      final Object? decoded = jsonDecode(text);
      if (decoded is! Map<String, Object?>) {
        throw const FluseProtocolException('制御メッセージが JSON オブジェクトではありません');
      }
      message = FluseMessage.fromJson(decoded);
    } on FluseProtocolException catch (error) {
      _logger?.warn('制御メッセージを解釈できません: ${error.message}');
      return;
    } on FormatException catch (error) {
      _logger?.warn('制御メッセージを JSON として読めません: ${error.message}');
      return;
    }

    switch (message) {
      case HelloMessage():
        _handleHello(message);
      case PongMessage():
        _handlePong(message);
      case PingMessage():
        // 端末からの ping にも応じる。片方向だけだと端末側が
        // 生存確認できない。
        sendMessage(message.toPong());
      case CloseMessage():
        _teardownQuietly();
      default:
        if (!isAuthenticated) {
          // hello より前に来る制御メッセージは受け付けない。
          _logger?.warn(
            '認証前の制御メッセージを無視しました',
            fields: <String, Object?>{'type': message.type},
          );
          return;
        }
        _onMessage?.call(this, message);
    }
  }

  void _handleHello(HelloMessage hello) {
    if (isAuthenticated) {
      _logger?.warn('認証済みの接続で hello を受け取りました。無視します');
      return;
    }

    final AuthResult result = _sessions.authenticate(hello);
    switch (result) {
      case AuthRejected(:final RejectMessage reject):
        sendMessage(reject);
        // reject を送ってから切る。先に切ると理由が端末に届かない。
        _teardownQuietly();
      case AuthAccepted(:final AcceptMessage accept):
        _sessionId = accept.sessionId;
        sendMessage(accept);
        _startHeartbeat(accept.heartbeatIntervalMs);
        _onAuthenticated?.call(this);
    }
  }

  // ------------------------------------------------------------ heartbeat

  void _startHeartbeat(int intervalMs) {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(Duration(milliseconds: intervalMs), (Timer _) {
      if (_missedPongs >= _missedPongLimit) {
        // 応答が続けて無い。回線が死んでいるのに接続だけ生きていると、
        // 1台制限に引っかかって次の接続も入れない。
        _logger?.warn(
          'heartbeat がタイムアウトしました。切断します',
          fields: <String, Object?>{'missedPongs': _missedPongs},
        );
        _teardownQuietly();
        return;
      }

      _missedPongs++;
      _pingSeq++;
      sendMessage(
        PingMessage(
          seq: _pingSeq,
          timestampMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    });
  }

  void _handlePong(PongMessage pong) {
    if (pong.seq != _pingSeq) {
      // 古い pong。数え直すと、遅れて届いた1つで生存扱いになってしまう。
      _logger?.debug(
        '想定外の seq の pong を無視しました',
        fields: <String, Object?>{'expected': _pingSeq, 'received': pong.seq},
      );
      return;
    }
    _missedPongs = 0;
  }

  // --------------------------------------------------------------- 後始末

  Future<void> _teardown() async {
    if (_closed) {
      return;
    }
    _closed = true;

    _heartbeat?.cancel();
    _heartbeat = null;

    // **忘れると次の端末が永久に繋がらない。** 1台制限の状態が残る。
    if (isAuthenticated) {
      _sessions.endSession();
    }
    _sessionId = null;

    // 接続に紐づく資源（DevFS / トンネル / VM Service）の解放を促す。
    // `_closed` を先に立てているので、ここは1回しか通らない。
    try {
      _onDisconnected?.call(this);
    } on Object catch (error) {
      // 通知先の失敗で自分の後始末を止めない。
      _logger?.warn('切断の通知に失敗しました: $error');
    }

    // **1つ失敗しても残りは閉じる。** 途中で抜けると購読やストリームが
    // 生き残り、done も完了しないので WsServer の集合に接続が残り続ける。
    Object? failure;
    StackTrace? trace;
    Future<void> attempt(Future<void> Function() action) async {
      try {
        await action();
      } on Object catch (error, stackTrace) {
        // 最初の失敗だけを覚える。後続は原因の派生であることが多い。
        failure ??= error;
        trace ??= stackTrace;
      }
    }

    await attempt(_subscription.cancel);
    await attempt(_tunnelIn.close);
    await attempt(_channel.sink.close);

    if (!_done.isCompleted) {
      _done.complete();
    }

    // 全て閉じ終えてから呼び出し元へ返す。close() を待っている側は
    // 後始末が失敗したことを知る必要がある。
    if (failure != null) {
      Error.throwWithStackTrace(failure!, trace ?? StackTrace.current);
    }
  }

  /// 後始末して、失敗はログに留める。
  ///
  /// イベント経由（onDone / onError / タイムアウト）の切断は待つ相手が
  /// 居ない。そこから例外を投げると未処理の非同期エラーになる。
  void _teardownQuietly() {
    unawaited(
      _teardown().catchError((Object error) {
        _logger?.warn('接続の後始末に失敗しました: $error');
      }),
    );
  }
}

/// HTML に埋める前に最低限の文字を落とす。
String _escapeHtml(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');
