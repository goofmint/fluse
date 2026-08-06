import 'package:fluse_server/fluse_server.dart';
import 'package:fluse_server/testing.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart' as vm;

/// 応答を差し替えられる最小の [vm.VmService]。
final class _StubVmService implements vm.VmService {
  /// 呼ばれた RPC の記録。`method isolateId args` の形。
  final List<String> calls = <String>[];

  /// `callServiceExtension` の応答。
  Map<String, Object?> extensionResponse = <String, Object?>{'type': 'Success'};

  /// `callServiceExtension` を失敗させる場合の例外。
  Object? extensionError;

  /// `getVM` が返す isolate。
  List<vm.IsolateRef> isolates = <vm.IsolateRef>[];

  /// `reloadSources` の応答。
  Map<String, Object?> reloadResponse = <String, Object?>{
    'type': 'ReloadReport',
    'success': true,
  };

  Object? reloadError;

  @override
  Future<vm.Response> callServiceExtension(
    String method, {
    String? isolateId,
    Map<String, dynamic>? args,
  }) async {
    calls.add('$method|$isolateId|$args');
    final Object? error = extensionError;
    if (error != null) {
      throw error;
    }
    return vm.Response.parse(extensionResponse)!;
  }

  @override
  Future<vm.VM> getVM() async {
    calls.add('getVM||');
    return vm.VM.parse(<String, Object?>{
      'type': 'VM',
      'isolates': <Object?>[
        for (final vm.IsolateRef ref in isolates) ref.toJson(),
      ],
    })!;
  }

  @override
  Future<vm.ReloadReport> reloadSources(
    String isolateId, {
    bool? force,
    bool? pause,
    String? rootLibUri,
    String? packagesUri,
  }) async {
    calls.add('reloadSources|$isolateId|$rootLibUri');
    final Object? error = reloadError;
    if (error != null) {
      throw error;
    }
    return vm.ReloadReport.parse(reloadResponse)!;
  }

  @override
  Future<void> dispose() async => calls.add('dispose||');

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} は未実装です');
}

vm.IsolateRef _isolate(String id, String name) =>
    vm.IsolateRef(id: id, name: name, number: id, isSystemIsolate: false);

void main() {
  late _StubVmService stub;
  late VmServiceClient client;
  late MemoryLogSink sink;

  setUp(() {
    stub = _StubVmService();
    sink = MemoryLogSink();
    client = VmServiceClient(
      stub,
      httpAddress: Uri.parse('http://127.0.0.1:43219/xY7Kq2Lm9Ab=/'),
      logger: FluseLogger(
        sinks: <FluseLogSink>[sink],
        minimumLevel: FluseLogLevel.debug,
      ),
    );
  });

  group('findMainIsolateId', () {
    test('main という名前の isolate を優先する', () async {
      stub.isolates = <vm.IsolateRef>[
        _isolate('isolates/1', 'worker'),
        _isolate('isolates/2', 'main'),
      ];

      expect(await client.findMainIsolateId(), 'isolates/2');
    });

    test('main が無ければ先頭を採る', () async {
      // VM は起動順に並べるので先頭がルート isolate。
      stub.isolates = <vm.IsolateRef>[
        _isolate('isolates/1', 'foo'),
        _isolate('isolates/2', 'bar'),
      ];

      expect(await client.findMainIsolateId(), 'isolates/1');
    });

    test('isolate が無ければ理由付きで失敗する', () async {
      stub.isolates = <vm.IsolateRef>[];

      await expectLater(
        client.findMainIsolateId(),
        throwsA(
          isA<VmServiceException>().having(
            (VmServiceException e) => e.toString(),
            'message',
            contains('起動していない'),
          ),
        ),
      );
    });
  });

  group('createDevFS / deleteDevFS', () {
    test('_createDevFS を呼び uri を返す', () async {
      stub.extensionResponse = <String, Object?>{
        'type': 'FileSystem',
        'uri': 'file:///devfs/fluse/',
      };

      expect(
        await client.createDevFS('fluse'),
        Uri.parse('file:///devfs/fluse/'),
      );
      expect(stub.calls.single, contains('_createDevFS'));
      expect(stub.calls.single, contains('fluse'));
    });

    test('uri が無い応答は失敗させる', () async {
      // ここで黙って null を返すと、後段の PUT 先が決まらないまま進む。
      stub.extensionResponse = <String, Object?>{'type': 'Success'};

      await expectLater(
        client.createDevFS('fluse'),
        throwsA(isA<VmServiceException>()),
      );
    });

    test('RPC が失敗したら VmServiceException に変換する', () async {
      stub.extensionError = StateError('rpc failed');

      await expectLater(
        client.createDevFS('fluse'),
        throwsA(
          isA<VmServiceException>().having(
            (VmServiceException e) => e.cause,
            'cause',
            isA<StateError>(),
          ),
        ),
      );
    });

    test('_deleteDevFS を呼ぶ', () async {
      await client.deleteDevFS('fluse');

      expect(stub.calls.single, contains('_deleteDevFS'));
    });
  });

  group('reloadSources', () {
    test('success を返す', () async {
      stub.reloadResponse = <String, Object?>{
        'type': 'ReloadReport',
        'success': true,
      };

      final ReloadResult result = await client.reloadSources(
        'isolates/1',
        rootLibUri: 'lib/main.dart.dill',
      );

      expect(result.success, isTrue);
      expect(stub.calls.single, contains('lib/main.dart.dill'));
    });

    test('失敗時は notices を取り出す', () async {
      // 失敗理由を表示できないと、利用者は何が起きたか分からない。
      stub.reloadResponse = <String, Object?>{
        'type': 'ReloadReport',
        'success': false,
        'notices': <Object?>[
          <String, Object?>{'message': 'const class を変更しました'},
        ],
      };

      final ReloadResult result = await client.reloadSources('isolates/1');

      expect(result.success, isFalse);
      expect(result.notices, <String>['const class を変更しました']);
    });

    test('success が無ければ false として扱う', () async {
      // 不明を成功にすると、失敗したまま accept を送ってしまう。
      stub.reloadResponse = <String, Object?>{'type': 'ReloadReport'};

      expect((await client.reloadSources('isolates/1')).success, isFalse);
    });

    test('notices の形が想定外でも壊れない', () async {
      stub.reloadResponse = <String, Object?>{
        'type': 'ReloadReport',
        'success': false,
        'notices': 'これは List ではない',
      };

      expect((await client.reloadSources('isolates/1')).notices, isEmpty);
    });

    test('RPC の失敗は VmServiceException になる', () async {
      stub.reloadError = StateError('boom');

      await expectLater(
        client.reloadSources('isolates/1'),
        throwsA(isA<VmServiceException>()),
      );
    });
  });

  group('reassemble / evict', () {
    test('ext.flutter.reassemble を isolate 指定で呼ぶ', () async {
      await client.reassemble('isolates/1');

      expect(
        stub.calls.single,
        startsWith('ext.flutter.reassemble|isolates/1'),
      );
    });

    test('ext.flutter.evict は value に asset パスを載せる', () async {
      await client.evict('isolates/1', 'assets/images/logo.png');

      expect(stub.calls.single, contains('ext.flutter.evict'));
      expect(stub.calls.single, contains('assets/images/logo.png'));
    });

    test('evict の失敗は対象を含めて失敗させる', () async {
      stub.extensionError = StateError('nope');

      await expectLater(
        client.evict('isolates/1', 'assets/a.png'),
        throwsA(
          isA<VmServiceException>().having(
            (VmServiceException e) => e.toString(),
            'message',
            contains('assets/a.png'),
          ),
        ),
      );
    });
  });

  test('ログに VM Service の認証コードが平文で残らない', () async {
    stub.isolates = <vm.IsolateRef>[_isolate('isolates/1', 'main')];
    await client.findMainIsolateId();

    expect(sink.lines, isNotEmpty);
    expect(sink.lines.join('\n'), isNot(contains('xY7Kq2Lm9Ab')));
  });

  test('dispose は接続を閉じる', () async {
    await client.dispose();

    expect(stub.calls, contains('dispose||'));
  });
}
