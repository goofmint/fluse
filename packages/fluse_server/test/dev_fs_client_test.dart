import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fluse_server/fluse_server.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart' as vm;

/// DevFS の PUT を受ける最小のダミーサーバ。
///
/// 実接続数を測るために、応答を保留できるようにしてある。
final class _DummyDevFsServer {
  _DummyDevFsServer(this._server) {
    unawaited(_serve());
  }

  static Future<_DummyDevFsServer> start() async =>
      _DummyDevFsServer(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;

  /// 受け取ったリクエストの記録。
  final List<_ReceivedRequest> received = <_ReceivedRequest>[];

  /// 同時に処理中だったリクエスト数の最大値。
  int maxConcurrent = 0;
  int _current = 0;

  /// 応答を返す前に待つ時間。並列度の計測に使う。
  Duration holdFor = Duration.zero;

  /// 何回目までのリクエストを失敗させるか。リトライの検証に使う。
  int failFirst = 0;
  int _handled = 0;

  Uri get uri => Uri.parse('http://${_server.address.host}:${_server.port}/');

  Future<void> close() => _server.close(force: true);

  Future<void> _serve() async {
    await for (final HttpRequest request in _server) {
      unawaited(_handle(request));
    }
  }

  Future<void> _handle(HttpRequest request) async {
    _current++;
    maxConcurrent = maxConcurrent > _current ? maxConcurrent : _current;

    final List<int> body = <int>[];
    await for (final List<int> chunk in request) {
      body.addAll(chunk);
    }

    received.add(
      _ReceivedRequest(
        method: request.method,
        headers: <String, List<String>>{
          for (final String name in _headerNames(request.headers))
            name: request.headers[name] ?? <String>[],
        },
        body: body,
      ),
    );

    if (holdFor > Duration.zero) {
      await Future<void>.delayed(holdFor);
    }

    _handled++;
    request.response.statusCode = _handled <= failFirst
        ? HttpStatus.internalServerError
        : HttpStatus.ok;

    _current--;
    await request.response.close();
  }

  static List<String> _headerNames(HttpHeaders headers) {
    final List<String> names = <String>[];
    headers.forEach((String name, _) => names.add(name));
    return names;
  }
}

final class _ReceivedRequest {
  const _ReceivedRequest({
    required this.method,
    required this.headers,
    required this.body,
  });

  final String method;
  final Map<String, List<String>> headers;
  final List<int> body;

  /// ヘッダを1つ取り出す。無ければテストを止める。
  ///
  /// `!` で潰すと「ヘッダが無い」ことが null エラーとして出てしまい、
  /// 失敗の理由が読めなくなる。
  String requireHeader(String name) {
    final String? value = headers[name.toLowerCase()]?.firstOrNull;
    if (value == null) {
      throw StateError('ヘッダ $name がリクエストにありません: ${headers.keys.toList()}');
    }
    return value;
  }

  /// ヘッダの有無だけを見る。
  String? optionalHeader(String name) =>
      headers[name.toLowerCase()]?.firstOrNull;
}

/// `_createDevFS` / `_deleteDevFS` にだけ答える最小の [vm.VmService]。
final class _FakeVmService implements vm.VmService {
  final List<String> calls = <String>[];

  @override
  Future<vm.Response> callServiceExtension(
    String method, {
    String? isolateId,
    Map<String, dynamic>? args,
  }) async {
    calls.add('$method ${args?['fsName']}');
    return vm.Response.parse(<String, Object?>{
      'type': 'FileSystem',
      'uri': 'file:///devfs/${args?['fsName']}/',
    })!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} は未実装です');
}

void main() {
  late _DummyDevFsServer server;
  DevFSClient? client;
  late _FakeVmService fakeVm;

  /// マップからヘッダを取り出す。無ければテストを止める。
  String requireEntry(Map<String, String> headers, String name) {
    final String? value = headers[name];
    if (value == null) {
      throw StateError('$name が生成されていません: ${headers.keys.toList()}');
    }
    return value;
  }

  Future<DevFSClient> buildClient({
    int maxInFlight = DevFSClient.defaultMaxInFlight,
    Duration uploadTimeout = DevFSClient.defaultUploadTimeout,
    int maxRetries = DevFSClient.defaultMaxRetries,
    Duration retryDelay = Duration.zero,
  }) async {
    final DevFSClient built = DevFSClient(
      vmService: VmServiceClient(fakeVm, httpAddress: server.uri),
      maxInFlight: maxInFlight,
      uploadTimeout: uploadTimeout,
      maxRetries: maxRetries,
      retryDelay: retryDelay,
    );
    await built.create('fluse');
    return built;
  }

  setUp(() async {
    fakeVm = _FakeVmService();
    server = await _DummyDevFsServer.start();
  });

  tearDown(() async {
    // 純粋ロジックのテストは client を作らないので nullable にしている。
    client?.close();
    client = null;
    await server.close();
  });

  group('ヘッダの生成', () {
    test('dev_fs_name と base64 の dev_fs_uri_b64 を付ける', () {
      final Map<String, String> headers = DevFSClient.buildHeaders(
        fsName: 'fluse',
        deviceUri: Uri.parse('lib/main.dart.incremental.dill'),
      );

      expect(headers['dev_fs_name'], 'fluse');
      expect(
        utf8.decode(base64.decode(requireEntry(headers, 'dev_fs_uri_b64'))),
        'lib/main.dart.incremental.dill',
      );
    });

    test('非 ASCII のパスはパーセントエンコードされた URI が入る', () {
      // 生の URI をヘッダに入れると非 ASCII で壊れるため base64 にしている。
      // 中身は Uri.toString() の結果、つまりパーセントエンコード済みの形。
      // flutter_tools も `base64.encode(utf8.encode('$deviceUri'))` で
      // 同じものを送っている（devfs.dart:334）。
      final Map<String, String> headers = DevFSClient.buildHeaders(
        fsName: 'fluse',
        deviceUri: Uri.parse('assets/画像.png'),
      );

      final String decoded = utf8.decode(
        base64.decode(requireEntry(headers, 'dev_fs_uri_b64')),
      );
      expect(decoded, 'assets/%E7%94%BB%E5%83%8F.png');
      expect(Uri.decodeFull(decoded), 'assets/画像.png');
    });
  });

  group('gzip 圧縮', () {
    test('gzip として展開できる', () {
      final List<int> original = utf8.encode('hello devfs' * 100);

      expect(gzip.decode(DevFSClient.compress(original)), original);
    });

    test('gzip のマジックナンバーで始まる', () {
      final List<int> compressed = DevFSClient.compress(<int>[1, 2, 3]);

      expect(compressed.take(2), <int>[0x1f, 0x8b]);
    });
  });

  group('create / destroy', () {
    test('createDevFS を呼びベース URI を返す', () async {
      final DevFSClient built = await buildClient();
      client = built;

      expect(built.fsName, 'fluse');
      expect(built.baseUri, Uri.parse('file:///devfs/fluse/'));
      expect(fakeVm.calls, contains('_createDevFS fluse'));
    });

    test('二重の create は拒否する', () async {
      final DevFSClient built = await buildClient();
      client = built;

      await expectLater(
        built.create('another'),
        throwsA(isA<DevFSException>()),
      );
    });

    test('destroy は deleteDevFS を呼び、二重呼び出しでも安全', () async {
      final DevFSClient built = await buildClient();
      client = built;

      await built.destroy();
      await built.destroy();

      expect(
        fakeVm.calls.where((String c) => c.startsWith('_deleteDevFS')),
        hasLength(1),
      );
      expect(built.fsName, isNull);
    });

    test('create 前の writeAll は明確に失敗する', () async {
      final DevFSClient built = DevFSClient(
        vmService: VmServiceClient(fakeVm, httpAddress: server.uri),
      );
      client = built;

      await expectLater(
        built.writeAll(<Uri, DevFSContent>{
          Uri.parse('a.dill'): DevFSContent.fromString('x'),
        }),
        throwsA(isA<DevFSException>()),
      );
    });
  });

  group('PUT の内容', () {
    test('PUT で gzip したボディとヘッダを送る', () async {
      final DevFSClient built = await buildClient();
      client = built;

      await built.writeAll(<Uri, DevFSContent>{
        Uri.parse('lib/main.dart.dill'): DevFSContent.fromString('kernel'),
      });

      expect(server.received, hasLength(1));
      final _ReceivedRequest request = server.received.single;
      expect(request.method, 'PUT');
      expect(request.requireHeader('dev_fs_name'), 'fluse');
      expect(
        utf8.decode(base64.decode(request.requireHeader('dev_fs_uri_b64'))),
        'lib/main.dart.dill',
      );
      expect(utf8.decode(gzip.decode(request.body)), 'kernel');
    });

    test('Accept-Encoding を送らない', () async {
      // 付いていると応答が圧縮され、dart-lang/sdk#43525 を踏みやすくなる。
      final DevFSClient built = await buildClient();
      client = built;

      await built.writeAll(<Uri, DevFSContent>{
        Uri.parse('a.dill'): DevFSContent.fromString('x'),
      });

      expect(server.received.single.optionalHeader('accept-encoding'), isNull);
    });

    test('空の entries では何も送らない', () async {
      final DevFSClient built = await buildClient();
      client = built;

      await built.writeAll(<Uri, DevFSContent>{});

      expect(server.received, isEmpty);
    });

    test('全件を送る', () async {
      final DevFSClient built = await buildClient();
      client = built;

      await built.writeAll(<Uri, DevFSContent>{
        for (int i = 0; i < 7; i++)
          Uri.parse('file$i.dill'): DevFSContent.fromString('body$i'),
      });

      expect(server.received, hasLength(7));
    });
  });

  group('同時実行', () {
    test('3並列を超えない', () async {
      // 応答を保留して、実際に何本同時に走ったかを測る。
      server.holdFor = const Duration(milliseconds: 80);
      final DevFSClient built = await buildClient();
      client = built;

      await built.writeAll(<Uri, DevFSContent>{
        for (int i = 0; i < 9; i++)
          Uri.parse('file$i.dill'): DevFSContent.fromString('body$i'),
      });

      expect(server.received, hasLength(9));
      expect(server.maxConcurrent, lessThanOrEqualTo(3));
    });

    test('3並列に達する', () async {
      // 上限が効いているだけでなく、直列にもなっていないこと。
      server.holdFor = const Duration(milliseconds: 80);
      final DevFSClient built = await buildClient();
      client = built;

      await built.writeAll(<Uri, DevFSContent>{
        for (int i = 0; i < 6; i++)
          Uri.parse('file$i.dill'): DevFSContent.fromString('body$i'),
      });

      expect(server.maxConcurrent, 3);
    });

    test('maxInFlight を下げれば並列度も下がる', () async {
      server.holdFor = const Duration(milliseconds: 50);
      final DevFSClient built = await buildClient(maxInFlight: 1);
      client = built;

      await built.writeAll(<Uri, DevFSContent>{
        for (int i = 0; i < 4; i++)
          Uri.parse('file$i.dill'): DevFSContent.fromString('body$i'),
      });

      expect(server.maxConcurrent, 1);
    });
  });

  group('リトライ', () {
    test('失敗しても再試行して成功する', () async {
      server.failFirst = 2;
      final DevFSClient built = await buildClient();
      client = built;

      await built.writeAll(<Uri, DevFSContent>{
        Uri.parse('a.dill'): DevFSContent.fromString('x'),
      });

      // 最初の2回は 500、3回目で成功。
      expect(server.received, hasLength(3));
    });

    test('リトライ回数を超えたら DevFSException になる', () async {
      server.failFirst = 100;
      final DevFSClient built = await buildClient(maxRetries: 2);
      client = built;

      await expectLater(
        built.writeAll(<Uri, DevFSContent>{
          Uri.parse('a.dill'): DevFSContent.fromString('x'),
        }),
        throwsA(
          isA<DevFSException>().having(
            (DevFSException e) => e.toString(),
            'message',
            contains('a.dill'),
          ),
        ),
      );
      // 初回 + リトライ2回。
      expect(server.received, hasLength(3));
    });

    test('応答が返らなければタイムアウトして再試行する', () async {
      server
        ..holdFor = const Duration(milliseconds: 300)
        ..failFirst = 0;
      final DevFSClient built = await buildClient(
        uploadTimeout: const Duration(milliseconds: 30),
        maxRetries: 1,
      );
      client = built;

      await expectLater(
        built.writeAll(<Uri, DevFSContent>{
          Uri.parse('a.dill'): DevFSContent.fromString('x'),
        }),
        throwsA(isA<DevFSException>()),
      );
    });
  });

  group('VmServiceClient.webSocketUriFor', () {
    test('HTTP ルートから ws の URI を作る', () {
      // 認証コードは実行時に組み立てる。固定の値を書くと、実在の資格情報と
      // 区別できない形でリポジトリに残る。
      final String authCode = 'auth${DateTime.now().microsecondsSinceEpoch}';

      expect(
        VmServiceClient.webSocketUriFor(
          Uri.parse('http://127.0.0.1:43219/$authCode/'),
        ).toString(),
        'ws://127.0.0.1:43219/$authCode/ws',
      );
    });

    test('https は wss になる', () {
      expect(
        VmServiceClient.webSocketUriFor(
          Uri.parse('https://example.com/auth/'),
        ).scheme,
        'wss',
      );
    });

    test('パスが無くても ws を足す', () {
      expect(
        VmServiceClient.webSocketUriFor(
          Uri.parse('http://127.0.0.1:8181'),
        ).path,
        '/ws',
      );
    });
  });
}
