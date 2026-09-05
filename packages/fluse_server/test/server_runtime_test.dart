@Timeout(Duration(seconds: 60))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:async/async.dart';
import 'package:fluse_protocol/fluse_protocol.dart'
    hide DiagnosticEntry, DiagnosticSeverity;
import 'package:fluse_server/fluse_server.dart';
import 'package:fluse_server/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:watcher/watcher.dart' as w;

/// 呼ばれた順を1本に記録する。解放順の検証に使う。
final class CallLog {
  final List<String> calls = <String>[];

  void add(String call) => calls.add(call);

  int countOf(String call) => calls.where((String c) => c == call).length;
}

final class FakeDeviceStore implements DeviceStoreContract {
  final Map<String, DeviceRecord> records = <String, DeviceRecord>{};

  @override
  DeviceRecord? lookup(String deviceId) => records[deviceId];

  @override
  void upsert(DeviceRecord record) => records[record.deviceId] = record;

  @override
  void remove(String deviceId) => records.remove(deviceId);
}

final class FakeWatchTarget implements WatchTarget {
  FakeWatchTarget(this.path);

  @override
  final String path;

  final StreamController<w.WatchEvent> _controller =
      StreamController<w.WatchEvent>.broadcast();

  @override
  Stream<w.WatchEvent> get events => _controller.stream;

  @override
  Future<void> get ready => Future<void>.value();

  void emit(String path) =>
      _controller.add(w.WatchEvent(w.ChangeType.MODIFY, path));

  Future<void> dispose() => _controller.close();
}

final class FakeCompiler implements ServerCompilerContract {
  FakeCompiler(this._log, {required this.dill});

  final CallLog _log;
  final File dill;

  /// 次の recompile が返す結果。差し替えて失敗を作る。
  CompileOutput? nextRecompile;

  @override
  bool get needsConfirmation => false;

  @override
  Future<CompileOutput> compile(Uri mainUri) async {
    _log.add('compiler.compile');
    return CompileOutput(
      incrementalDill: dill,
      errorCount: 0,
      diagnostics: const <DiagnosticEntry>[],
      sources: <Uri>[mainUri],
    );
  }

  @override
  Future<CompileOutput> recompile(Uri mainUri, List<Uri> invalidated) async {
    _log.add('compiler.recompile');
    return nextRecompile ??
        CompileOutput(
          incrementalDill: dill,
          errorCount: 0,
          diagnostics: const <DiagnosticEntry>[],
          sources: invalidated,
        );
  }

  @override
  void accept() => _log.add('compiler.accept');

  @override
  Future<CompileOutput?> reject() async {
    _log.add('compiler.reject');
    return null;
  }

  @override
  Future<void> shutdown() async => _log.add('compiler.shutdown');
}

final class FakeTunnel implements TunnelContract {
  FakeTunnel(this._log);

  final CallLog _log;
  final Completer<void> _done = Completer<void>();

  /// bind が投げる例外。接続シーケンスの失敗を作る。
  Object? bindError;

  @override
  Future<Uri> bind(String remoteVmServiceUri) async {
    _log.add('tunnel.bind');
    final Object? error = bindError;
    if (error != null) {
      throw error;
    }
    return Uri.parse('http://127.0.0.1:1234/authcode/');
  }

  @override
  Future<void> close() async {
    _log.add('tunnel.close');
    if (!_done.isCompleted) {
      _done.complete();
    }
  }

  @override
  Future<void> get done => _done.future;
}

final class FakeVmService implements SessionVmServiceContract {
  FakeVmService(this._log);

  final CallLog _log;

  /// reloadSources が返す結果。
  bool reloadSucceeds = true;

  @override
  Uri get httpAddress => Uri.parse('http://127.0.0.1:1234/authcode/');

  @override
  Future<Uri> createDevFS(String fsName) async {
    _log.add('vm.createDevFS');
    return Uri.parse('file:///devfs/$fsName/');
  }

  @override
  Future<void> deleteDevFS(String fsName) async => _log.add('vm.deleteDevFS');

  @override
  Future<String> findMainIsolateId() async => 'isolate-1';

  @override
  Future<ReloadResult> reloadSources(
    String isolateId, {
    String? rootLibUri,
    String? packagesUri,
  }) async {
    _log.add('vm.reloadSources');
    return ReloadResult(
      success: reloadSucceeds,
      notices: reloadSucceeds ? const <String>[] : <String>['壊れています'],
    );
  }

  @override
  Future<void> evict(String isolateId, String assetPath) async =>
      _log.add('vm.evict');

  @override
  Future<void> reassemble(String isolateId) async => _log.add('vm.reassemble');

  @override
  Future<List<({String viewId, String? isolateId})>> listViews() async =>
      <({String viewId, String? isolateId})>[
        (viewId: 'view-1', isolateId: 'isolate-1'),
      ];

  @override
  Future<void> setAssetDirectory({
    required String viewId,
    required String? isolateId,
    required Uri assetsDirectory,
  }) async => _log.add('vm.setAssetDirectory');

  @override
  Future<void> dispose() async => _log.add('vm.dispose');
}

final class FakeDevFS implements DevFSContract {
  FakeDevFS(this._log);

  final CallLog _log;

  @override
  String? fsName;

  @override
  Uri? baseUri;

  /// 転送されたエントリ。
  final List<Map<Uri, DevFSContent>> writes = <Map<Uri, DevFSContent>>[];

  @override
  Future<Uri> create(String name) async {
    _log.add('devfs.create');
    fsName = name;
    baseUri = Uri.parse('file:///devfs/$name/');
    return baseUri!;
  }

  @override
  Future<void> destroy() async {
    _log.add('devfs.destroy');
    fsName = null;
    baseUri = null;
  }

  @override
  void close() => _log.add('devfs.close');

  @override
  Future<void> writeAll(Map<Uri, DevFSContent> entries) async {
    _log.add('devfs.writeAll');
    writes.add(entries);
  }
}

void main() {
  const String projectId = 'counter_app-0123456789abcdef';
  const String flutterRevision = '42d3d75a56';
  const String appVersion = 'fingerprint-aaaa';

  late Directory temp;
  late String root;
  late CallLog log;
  late MemoryLogSink sink;
  late FluseLogger logger;
  late SessionManager sessions;
  late FakeCompiler compiler;
  late FakeTunnel tunnel;
  late FakeVmService vmService;
  late FakeDevFS devFS;
  late FileWatcher fileWatcher;
  final List<FakeWatchTarget> targets = <FakeWatchTarget>[];
  ServerRuntime? runtime;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('fluse_runtime_');
    root = temp.path;
    Directory(p.join(root, 'lib')).createSync(recursive: true);
    File(p.join(root, 'pubspec.yaml')).writeAsStringSync('name: sample\n');
    File(p.join(root, 'out.dill')).writeAsStringSync('dill');

    log = CallLog();
    sink = MemoryLogSink();
    logger = FluseLogger(
      sinks: <FluseLogSink>[sink],
      minimumLevel: FluseLogLevel.debug,
    );
    sessions = SessionManager(
      expectedProjectId: projectId,
      expectedFlutterRevision: flutterRevision,
      expectedAppVersion: appVersion,
      deviceStore: FakeDeviceStore(),
      logger: logger,
      // heartbeat で切られないよう長めに。
      heartbeatIntervalMs: 60000,
    );
    compiler = FakeCompiler(log, dill: File(p.join(root, 'out.dill')));
    tunnel = FakeTunnel(log);
    vmService = FakeVmService(log);
    devFS = FakeDevFS(log);
    targets.clear();

    fileWatcher = FileWatcher(
      projectRoot: root,
      debounce: const Duration(milliseconds: 10),
      logger: logger,
      watcherFactory: (String path) {
        final FakeWatchTarget target = FakeWatchTarget(path);
        targets.add(target);
        return target;
      },
    );
  });

  tearDown(() async {
    await runtime?.close();
    runtime = null;
    for (final FakeWatchTarget target in targets) {
      await target.dispose();
    }
    temp.deleteSync(recursive: true);
  });

  Future<Uri> startRuntime() async {
    final ServerRuntime created = ServerRuntime(
      wsServerFactory: (ServerRuntime r) => WsServer(
        sessionManager: sessions,
        host: '127.0.0.1',
        port: 0,
        logger: logger,
        onAuthenticated: r.onAuthenticated,
        onMessage: r.onMessage,
        onDisconnected: r.onDisconnected,
      ),
      compiler: compiler,
      fileWatcher: fileWatcher,
      assets: AssetBundleService(projectRoot: root, logger: logger),
      mainUri: Uri.file(p.join(root, 'lib', 'main.dart')),
      dillDeviceUri: Uri.parse('lib/main.dart.dill'),
      rootLibUri: 'lib/main.dart',
      logger: logger,
      tunnelFactory: (TunnelChannel channel, FluseLogger? _) => tunnel,
      vmServiceConnector: (Uri uri, FluseLogger? _) async => vmService,
      devFsFactory: (SessionVmServiceContract vm, FluseLogger? _) => devFS,
    );
    runtime = created;
    return created.start();
  }

  Map<String, Object?> helloJson({String? pairingToken, String? deviceToken}) =>
      HelloMessage(
        protocolVersion: fluseProtocolVersion,
        projectId: projectId,
        flutterRevision: flutterRevision,
        dartVersion: '3.11.5',
        appVersion: appVersion,
        deviceId: 'device-1',
        deviceName: 'Pixel 8',
        pairingToken: pairingToken,
        deviceToken: deviceToken,
      ).toJson();

  Future<FluseMessage> nextMessage(StreamQueue<dynamic> queue) async {
    while (true) {
      final dynamic frame = await queue.next;
      if (frame is String) {
        return FluseMessage.fromJson(jsonDecode(frame) as Map<String, Object?>);
      }
    }
  }

  /// 接続して hello → accept → vmServiceReady → ready まで進める。
  Future<({WebSocket socket, StreamQueue<dynamic> queue})> connectAndReady(
    Uri base,
  ) async {
    final PairingToken token = sessions.issuePairingToken();
    final WebSocket socket = await WebSocket.connect(
      'ws://${base.host}:${base.port}/ws',
    );
    final StreamQueue<dynamic> queue = StreamQueue<dynamic>(socket);

    socket.add(jsonEncode(helloJson(pairingToken: token.value)));
    expect(await nextMessage(queue), isA<AcceptMessage>());

    socket.add(
      jsonEncode(
        const VmServiceReadyMessage(
          vmServiceUri: 'http://127.0.0.1:9999/devauth/',
        ).toJson(),
      ),
    );
    expect(await nextMessage(queue), isA<ReadyMessage>());

    return (socket: socket, queue: queue);
  }

  /// debounce の窓が閉じるまで待つ。
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 120));

  test('接続 → reload → 切断 → 再接続 が一通り通る（完了条件）', () async {
    final Uri base = await startRuntime();

    // --- 接続と初回同期 -------------------------------------------------
    final ({WebSocket socket, StreamQueue<dynamic> queue}) first =
        await connectAndReady(base);

    expect(
      log.calls,
      containsAllInOrder(<String>[
        'tunnel.bind',
        'devfs.create',
        'compiler.compile',
        'devfs.writeAll',
        'vm.reloadSources',
        'compiler.accept',
        'vm.setAssetDirectory',
        'vm.reassemble',
      ]),
      reason: '設計 §3.1 の順で初回同期が走る',
    );
    expect(runtime!.activeDevFsName, ServerRuntime.defaultDevFsName);

    // --- 変更を反映 -----------------------------------------------------
    for (final FakeWatchTarget target in targets) {
      target.emit(p.join(root, 'lib', 'main.dart'));
    }
    await settle();

    expect(await nextMessage(first.queue), isA<CompileOkMessage>());
    expect(log.countOf('compiler.recompile'), 1);

    // --- 切断 -----------------------------------------------------------
    await first.queue.cancel(immediate: true);
    await first.socket.close();
    while (runtime!.hasSession) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    expect(
      log.calls,
      containsAllInOrder(<String>[
        'devfs.destroy',
        'vm.dispose',
        'tunnel.close',
      ]),
      reason: 'DevFS を先に消さないと deleteDevFS が届かない',
    );
    // frontend_server を落とすと増分の状態が消え、再接続が数十秒かかる。
    expect(log.countOf('compiler.shutdown'), 0);

    // --- 再接続 ---------------------------------------------------------
    final ({WebSocket socket, StreamQueue<dynamic> queue}) second =
        await connectAndReady(base);
    addTearDown(() async {
      await second.queue.cancel(immediate: true);
      await second.socket.close();
    });

    expect(log.countOf('devfs.create'), 2, reason: 'DevFS を作り直す');
    expect(log.countOf('compiler.compile'), 2, reason: '初回同期をやり直す');
    expect(runtime!.activeDevFsName, ServerRuntime.defaultDevFsName);
  });

  test('コンパイルエラーは compileError として届き、監視は続く', () async {
    final Uri base = await startRuntime();
    final ({WebSocket socket, StreamQueue<dynamic> queue}) client =
        await connectAndReady(base);
    addTearDown(() async {
      await client.queue.cancel(immediate: true);
      await client.socket.close();
    });

    compiler.nextRecompile = CompileOutput(
      incrementalDill: null,
      errorCount: 1,
      diagnostics: <DiagnosticEntry>[
        const DiagnosticEntry(
          severity: DiagnosticSeverity.error,
          message: '足りません',
          raw: 'lib/main.dart:3:5: Error: 足りません',
          file: 'lib/main.dart',
          line: 3,
          column: 5,
        ),
      ],
      sources: const <Uri>[],
    );
    for (final FakeWatchTarget target in targets) {
      target.emit(p.join(root, 'lib', 'main.dart'));
    }
    await settle();

    final FluseMessage message = await nextMessage(client.queue);
    expect(message, isA<CompileErrorMessage>());
    final CompileErrorMessage error = message as CompileErrorMessage;
    expect(error.diagnostics.single.message, '足りません');
    expect(error.diagnostics.single.line, 3);
    // Watch は止めない（設計 §5.1）。
    expect(runtime!.hasSession, isTrue);
  });

  test('reloadSources の失敗は reloadRejected として届く', () async {
    final Uri base = await startRuntime();
    final ({WebSocket socket, StreamQueue<dynamic> queue}) client =
        await connectAndReady(base);
    addTearDown(() async {
      await client.queue.cancel(immediate: true);
      await client.socket.close();
    });

    vmService.reloadSucceeds = false;
    for (final FakeWatchTarget target in targets) {
      target.emit(p.join(root, 'lib', 'main.dart'));
    }
    await settle();

    final FluseMessage message = await nextMessage(client.queue);
    expect(message, isA<ErrorMessage>());
    expect(
      (message as ErrorMessage).code,
      FluseErrorCode.reloadRejected.wireValue,
    );
    // 失敗時に accept すると以降の全リロードが壊れる（設計 §10-2）。
    expect(log.countOf('compiler.accept'), 1, reason: '初回同期の1回だけ');
    expect(log.countOf('compiler.reject'), 1);
  });

  test('指紋対象の変更は APP_OUTDATED として届く', () async {
    final Uri base = await startRuntime();
    final ({WebSocket socket, StreamQueue<dynamic> queue}) client =
        await connectAndReady(base);
    addTearDown(() async {
      await client.queue.cancel(immediate: true);
      await client.socket.close();
    });

    for (final FakeWatchTarget target in targets) {
      target.emit(p.join(root, 'pubspec.yaml'));
    }
    await settle();

    final FluseMessage message = await nextMessage(client.queue);
    expect(message, isA<ErrorMessage>());
    expect(
      (message as ErrorMessage).code,
      FluseErrorCode.appOutdated.wireValue,
    );
  });

  test('接続シーケンスが失敗したらエラーを返して資源を畳む', () async {
    final Uri base = await startRuntime();
    tunnel.bindError = StateError('トンネルを張れません');

    final PairingToken token = sessions.issuePairingToken();
    final WebSocket socket = await WebSocket.connect(
      'ws://${base.host}:${base.port}/ws',
    );
    final StreamQueue<dynamic> queue = StreamQueue<dynamic>(socket);
    addTearDown(() async {
      await queue.cancel(immediate: true);
      await socket.close();
    });

    socket.add(jsonEncode(helloJson(pairingToken: token.value)));
    await nextMessage(queue);
    socket.add(
      jsonEncode(
        const VmServiceReadyMessage(
          vmServiceUri: 'http://127.0.0.1:9999/devauth/',
        ).toJson(),
      ),
    );

    final FluseMessage message = await nextMessage(queue);
    expect(message, isA<ErrorMessage>());
    expect((message as ErrorMessage).code, FluseErrorCode.tunnelLost.wireValue);
    expect(runtime!.hasSession, isFalse);
    // 途中まで作った資源を残さない。
    expect(log.countOf('devfs.create'), 0);
  });

  test('セッションが無い間の変更は反映しない', () async {
    await startRuntime();

    for (final FakeWatchTarget target in targets) {
      target.emit(p.join(root, 'lib', 'main.dart'));
    }
    await settle();

    expect(log.countOf('compiler.recompile'), 0);
  });

  test('close で CompilerService も落とす', () async {
    await startRuntime();

    await runtime!.close();

    expect(log.countOf('compiler.shutdown'), 1);
    expect(fileWatcher.isWatching, isFalse);
  });
}
