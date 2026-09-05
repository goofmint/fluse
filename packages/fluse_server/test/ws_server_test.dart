@Timeout(Duration(seconds: 60))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:async/async.dart';
import 'package:fluse_protocol/fluse_protocol.dart';
import 'package:fluse_server/fluse_server.dart';
import 'package:fluse_server/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// `devices.json` を触らずに登録状態だけを持つ [DeviceStoreContract]。
final class FakeDeviceStore implements DeviceStoreContract {
  final Map<String, DeviceRecord> records = <String, DeviceRecord>{};

  @override
  DeviceRecord? lookup(String deviceId) => records[deviceId];

  @override
  void upsert(DeviceRecord record) => records[record.deviceId] = record;

  @override
  void remove(String deviceId) => records.remove(deviceId);
}

void main() {
  const String projectId = 'counter_app-0123456789abcdef';
  const String flutterRevision = '42d3d75a56';
  const String appVersion = 'fingerprint-aaaa';

  late FakeDeviceStore store;
  late MemoryLogSink sink;
  late FluseLogger logger;
  late SessionManager sessions;
  WsServer? server;
  Directory? temp;

  setUp(() {
    store = FakeDeviceStore();
    sink = MemoryLogSink();
    logger = FluseLogger(
      sinks: <FluseLogSink>[sink],
      minimumLevel: FluseLogLevel.debug,
    );
    sessions = SessionManager(
      expectedProjectId: projectId,
      expectedFlutterRevision: flutterRevision,
      expectedAppVersion: appVersion,
      deviceStore: store,
      logger: logger,
      // テストを実時間で待たないよう、heartbeat を短くする。
      heartbeatIntervalMs: 40,
    );
  });

  tearDown(() async {
    await server?.close();
    server = null;
    temp?.deleteSync(recursive: true);
    temp = null;
  });

  /// loopback に立てて基底 URI を返す。
  Future<Uri> serve({
    bool serveApk = true,
    String? apkPath,
    String host = '127.0.0.1',
    int missedPongLimit = WsServer.defaultMissedPongLimit,
  }) async {
    final WsServer created = WsServer(
      sessionManager: sessions,
      host: host,
      port: 0,
      serveApk: serveApk,
      apkPath: apkPath,
      missedPongLimit: missedPongLimit,
      logger: logger,
    );
    server = created;
    return created.start();
  }

  Map<String, Object?> helloJson({
    int protocolVersion = fluseProtocolVersion,
    String id = projectId,
    String? pairingToken,
    String? deviceToken,
    String deviceId = 'device-1',
  }) => HelloMessage(
    protocolVersion: protocolVersion,
    projectId: id,
    flutterRevision: flutterRevision,
    dartVersion: '3.11.5',
    appVersion: appVersion,
    deviceId: deviceId,
    deviceName: 'Pixel 8',
    pairingToken: pairingToken,
    deviceToken: deviceToken,
  ).toJson();

  Future<WebSocket> connect(Uri base) =>
      WebSocket.connect('ws://${base.host}:${base.port}/ws');

  /// 次に届く制御メッセージを取り出す。binary frame は読み飛ばす。
  Future<FluseMessage> nextMessage(StreamQueue<dynamic> queue) async {
    while (true) {
      final dynamic frame = await queue.next;
      if (frame is String) {
        return FluseMessage.fromJson(jsonDecode(frame) as Map<String, Object?>);
      }
    }
  }

  group('HTTP エンドポイント', () {
    test('/health は 200 と JSON を返す', () async {
      final Uri base = await serve();

      final HttpClientResponse response = await _get(base.resolve('/health'));

      expect(response.statusCode, 200);
      final Object? body = jsonDecode(await _text(response));
      expect(body, isA<Map<String, Object?>>());
      expect((body! as Map<String, Object?>)['status'], 'ok');
    });

    test('/apk はトークンが一致すれば APK を返す', () async {
      temp = Directory.systemTemp.createTempSync('fluse_ws_');
      final File apk = File(p.join(temp!.path, 'preview.apk'))
        ..writeAsBytesSync(<int>[1, 2, 3, 4]);
      final Uri base = await serve(apkPath: apk.path);
      final PairingToken token = sessions.issuePairingToken();

      final HttpClientResponse response = await _get(
        base.resolve('/apk?t=${Uri.encodeQueryComponent(token.value)}'),
      );

      expect(response.statusCode, 200);
      expect(response.headers.contentType?.toString(), WsServer.apkContentType);
    });

    test('/apk はトークンが違えば 404', () async {
      temp = Directory.systemTemp.createTempSync('fluse_ws_');
      final File apk = File(p.join(temp!.path, 'preview.apk'))
        ..writeAsBytesSync(<int>[1, 2, 3, 4]);
      final Uri base = await serve(apkPath: apk.path);
      sessions.issuePairingToken();

      // 403 にするとファイルの存在を教えることになる（設計 §4.2(b)）。
      expect((await _get(base.resolve('/apk?t=にせもの'))).statusCode, 404);
      expect((await _get(base.resolve('/apk'))).statusCode, 404);
    });

    test('serveApk が false なら 404', () async {
      temp = Directory.systemTemp.createTempSync('fluse_ws_');
      final File apk = File(p.join(temp!.path, 'preview.apk'))
        ..writeAsBytesSync(<int>[1, 2, 3, 4]);
      final Uri base = await serve(serveApk: false, apkPath: apk.path);
      final PairingToken token = sessions.issuePairingToken();

      final HttpClientResponse response = await _get(
        base.resolve('/apk?t=${Uri.encodeQueryComponent(token.value)}'),
      );

      expect(response.statusCode, 404);
    });

    test('/ は手入力用のトークンと APK リンクを出す', () async {
      temp = Directory.systemTemp.createTempSync('fluse_ws_');
      final File apk = File(p.join(temp!.path, 'preview.apk'))
        ..writeAsBytesSync(<int>[1, 2, 3, 4]);
      final Uri base = await serve(apkPath: apk.path);
      final PairingToken token = sessions.issuePairingToken();

      final String html = await _text(await _get(base.resolve('/')));

      expect(html, contains(token.value));
      expect(html, contains('/apk?t='));
    });

    test('/ はトークン未発行でも説明を出す', () async {
      final Uri base = await serve();

      final String html = await _text(await _get(base.resolve('/')));

      expect(html, contains('fluse start'));
    });

    test('知らないパスは 404', () async {
      final Uri base = await serve();

      expect((await _get(base.resolve('/nope'))).statusCode, 404);
    });
  });

  group('バインド', () {
    test('0.0.0.0 を指定したら警告する', () async {
      await serve(host: '0.0.0.0');

      expect(sink.lines.where((String l) => l.contains('第三者')), isNotEmpty);
    });

    test('プライベート IP の指定では警告しない', () async {
      await serve(host: '127.0.0.1');

      expect(sink.lines.where((String l) => l.contains('第三者')), isEmpty);
    });
  });

  group('認証', () {
    test('正しい pairingToken なら accept を返す', () async {
      final Uri base = await serve();
      final PairingToken token = sessions.issuePairingToken();
      final WebSocket socket = await connect(base);
      final StreamQueue<dynamic> queue = StreamQueue<dynamic>(socket);
      addTearDown(() async {
        await queue.cancel(immediate: true);
        await socket.close();
      });

      socket.add(jsonEncode(helloJson(pairingToken: token.value)));

      final FluseMessage message = await nextMessage(queue);
      expect(message, isA<AcceptMessage>());
      expect((message as AcceptMessage).issuedDeviceToken, isNotNull);
    });

    test('トークンが違えば reject を送って閉じる', () async {
      final Uri base = await serve();
      sessions.issuePairingToken();
      final WebSocket socket = await connect(base);
      final StreamQueue<dynamic> queue = StreamQueue<dynamic>(socket);

      socket.add(jsonEncode(helloJson(pairingToken: 'にせもの')));

      final FluseMessage message = await nextMessage(queue);
      expect(message, isA<RejectMessage>());
      expect((message as RejectMessage).knownCode, RejectCode.authFailed);
      // reject を先に送ってから切る。順序が逆だと理由が届かない。
      await queue.rest.drain<void>();
    });

    test('切断で endSession を呼び、次の端末が繋がる', () async {
      final Uri base = await serve();
      final PairingToken first = sessions.issuePairingToken();
      final WebSocket socket = await connect(base);
      final StreamQueue<dynamic> queue = StreamQueue<dynamic>(socket);
      socket.add(jsonEncode(helloJson(pairingToken: first.value)));
      await nextMessage(queue);

      await queue.cancel(immediate: true);
      await socket.close();
      // 解放されるまで待つ。
      while (sessions.activeDeviceId != null) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      final PairingToken second = sessions.issuePairingToken();
      final WebSocket other = await connect(base);
      final StreamQueue<dynamic> otherQueue = StreamQueue<dynamic>(other);
      addTearDown(() async {
        await otherQueue.cancel(immediate: true);
        await other.close();
      });

      other.add(
        jsonEncode(helloJson(pairingToken: second.value, deviceId: 'device-2')),
      );

      expect(await nextMessage(otherQueue), isA<AcceptMessage>());
    });
  });

  group('未認証のトンネルフレーム', () {
    test('binary frame を受け取ったら即切断する（完了条件）', () async {
      final Uri base = await serve();
      sessions.issuePairingToken();
      final WebSocket socket = await connect(base);

      // 設計 §6.1。認証前のトンネルフレームは事故ではなく攻撃を疑う。
      socket.add(TunnelFrame.open(1).encode());

      // 応答は返らず、接続が閉じる。
      await socket.drain<void>();
      expect(socket.closeCode, isNotNull);
      expect(sink.lines.where((String l) => l.contains('未認証')), isNotEmpty);
    });

    test('認証後の binary frame は incoming に流れる', () async {
      FluseConnection? authenticated;
      final WsServer created = WsServer(
        sessionManager: sessions,
        host: '127.0.0.1',
        port: 0,
        logger: logger,
        onAuthenticated: (FluseConnection c) => authenticated = c,
      );
      server = created;
      final Uri base = await created.start();
      final PairingToken token = sessions.issuePairingToken();

      final WebSocket socket = await connect(base);
      final StreamQueue<dynamic> queue = StreamQueue<dynamic>(socket);
      addTearDown(() async {
        await queue.cancel(immediate: true);
        await socket.close();
      });
      socket.add(jsonEncode(helloJson(pairingToken: token.value)));
      await nextMessage(queue);

      expect(authenticated, isNotNull);
      final Future<List<int>> received = authenticated!.incoming.first;
      socket.add(TunnelFrame.open(7).encode());

      expect(TunnelFrame.decode(await received).streamId, 7);
    });
  });

  group('heartbeat', () {
    test('pong を返さなければタイムアウトで切断する（完了条件）', () async {
      final Uri base = await serve(missedPongLimit: 2);
      final PairingToken token = sessions.issuePairingToken();
      final WebSocket socket = await connect(base);

      socket.add(jsonEncode(helloJson(pairingToken: token.value)));

      // pong を返さずに読み捨てる。ping が 2 回続けて未応答になれば切れる。
      await socket.drain<void>();
      expect(socket.closeCode, isNotNull);
      expect(
        sink.lines.where((String l) => l.contains('heartbeat')),
        isNotEmpty,
      );
    });

    test('pong を返し続ければ切れない', () async {
      final Uri base = await serve(missedPongLimit: 2);
      final PairingToken token = sessions.issuePairingToken();
      final WebSocket socket = await connect(base);
      addTearDown(() => socket.close());

      int pongs = 0;
      socket.listen((dynamic frame) {
        if (frame is! String) {
          return;
        }
        final FluseMessage message = FluseMessage.fromJson(
          jsonDecode(frame) as Map<String, Object?>,
        );
        if (message is PingMessage) {
          pongs++;
          socket.add(jsonEncode(message.toPong().toJson()));
        }
      });
      socket.add(jsonEncode(helloJson(pairingToken: token.value)));

      // heartbeat 40ms なので、この間に何度も往復する。
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(pongs, greaterThan(2));
      expect(socket.closeCode, isNull);
    });

    test('端末からの ping には pong を返す', () async {
      final Uri base = await serve();
      final WebSocket socket = await connect(base);
      final StreamQueue<dynamic> queue = StreamQueue<dynamic>(socket);
      addTearDown(() async {
        await queue.cancel(immediate: true);
        await socket.close();
      });

      socket.add(
        jsonEncode(const PingMessage(seq: 42, timestampMs: 1000).toJson()),
      );

      final FluseMessage message = await nextMessage(queue);
      expect(message, isA<PongMessage>());
      expect((message as PongMessage).seq, 42);
      // 受け取った値をそのまま返す。作り直すと RTT が測れない。
      expect(message.timestampMs, 1000);
    });
  });

  group('壊れた制御メッセージ', () {
    test('JSON でなければ無視して接続を保つ', () async {
      final Uri base = await serve();
      final WebSocket socket = await connect(base);
      final StreamQueue<dynamic> queue = StreamQueue<dynamic>(socket);
      addTearDown(() async {
        await queue.cancel(immediate: true);
        await socket.close();
      });

      socket.add('{ぐちゃぐちゃ');
      // 1つ壊れただけで切ると、些細な取りこぼしで再接続の嵐になる。
      socket.add(
        jsonEncode(const PingMessage(seq: 1, timestampMs: 1).toJson()),
      );

      expect(await nextMessage(queue), isA<PongMessage>());
    });

    test('未知の type は無視する', () async {
      final Uri base = await serve();
      final WebSocket socket = await connect(base);
      final StreamQueue<dynamic> queue = StreamQueue<dynamic>(socket);
      addTearDown(() async {
        await queue.cancel(immediate: true);
        await socket.close();
      });

      socket.add(jsonEncode(<String, Object?>{'type': 'なにこれ'}));
      socket.add(
        jsonEncode(const PingMessage(seq: 1, timestampMs: 1).toJson()),
      );

      expect(await nextMessage(queue), isA<PongMessage>());
    });
  });
}

Future<HttpClientResponse> _get(Uri uri) async {
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest request = await client.getUrl(uri);
    return await request.close();
  } finally {
    client.close();
  }
}

Future<String> _text(HttpClientResponse response) =>
    response.transform(utf8.decoder).join();
