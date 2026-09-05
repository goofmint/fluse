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

  /// recompile をここで止める。直列化の検証に使う。
  Completer<void>? gate;

  /// 次の recompile で例外を投げる。キューが止まらないことの検証に使う。
  bool throwOnNextRecompile = false;

  /// 同時に走っている recompile の数。直列化が守られていれば常に1以下。
  int inFlight = 0;
  int maxInFlight = 0;

  /// recompile が呼ばれるたびに完了する。
  final List<Completer<void>> _recompileWaiters = <Completer<void>>[];

  /// 次の recompile 開始を待つ。
  Future<void> nextRecompileStart() {
    final Completer<void> waiter = Completer<void>();
    _recompileWaiters.add(waiter);
    return waiter.future;
  }

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
    inFlight++;
    maxInFlight = inFlight > maxInFlight ? inFlight : maxInFlight;
    for (final Completer<void> waiter in _recompileWaiters.toList()) {
      if (!waiter.isCompleted) {
        waiter.complete();
      }
    }
    _recompileWaiters.clear();
    try {
      await gate?.future;
      if (throwOnNextRecompile) {
        throwOnNextRecompile = false;
        throw StateError('コンパイラが落ちました');
      }
    } finally {
      inFlight--;
    }
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

  /// close が呼ばれたら完了する。解放を待つのに使う。
  final Completer<void> closed = Completer<void>();

  @override
  Future<Uri> bind(String remoteVmServiceUri) async {
    _log.add('tunnel.bind');
    final Object? error = bindError;
    if (error != null) {
      throw error;
    }
    // フェイクは認証コードを見ない。実物の形に寄せる必要も無いので
    // 資格情報らしい文字列は置かない。
    return Uri.parse('http://127.0.0.1:1234/');
  }

  @override
  Future<void> close() async {
    _log.add('tunnel.close');
    if (!_done.isCompleted) {
      _done.complete();
    }
    if (!closed.isCompleted) {
      closed.complete();
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

  /// dispose が呼ばれたら完了する。
  final Completer<void> disposed = Completer<void>();

  @override
  Uri get httpAddress => Uri.parse('http://127.0.0.1:1234/');

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
  Future<void> dispose() async {
    _log.add('vm.dispose');
    if (!disposed.isCompleted) {
      disposed.complete();
    }
  }
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

  /// destroy が呼ばれたら完了する。
  final Completer<void> destroyed = Completer<void>();

  @override
  Future<void> destroy() async {
    _log.add('devfs.destroy');
    fsName = null;
    baseUri = null;
    if (!destroyed.isCompleted) {
      destroyed.complete();
    }
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
  late FileWatcher fileWatcher;

  /// 次に作るトンネルの bind を失敗させる。
  bool bindShouldFail = false;

  /// 接続ごとに作られたフェイク。再接続で作り直されることを見る。
  final List<FakeTunnel> tunnels = <FakeTunnel>[];
  final List<FakeVmService> vmServices = <FakeVmService>[];
  final List<FakeDevFS> devFSs = <FakeDevFS>[];
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
    bindShouldFail = false;
    tunnels.clear();
    vmServices.clear();
    devFSs.clear();
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
      // 接続ごとに作り直す。使い回すと、解放済みの資源を再接続でも
      // 掴んでしまい「作り直している」ことを検証できない。
      tunnelFactory: (TunnelChannel channel, FluseLogger? _) {
        final FakeTunnel created = FakeTunnel(log);
        if (bindShouldFail) {
          created.bindError = StateError('トンネルを張れません');
        }
        tunnels.add(created);
        return created;
      },
      vmServiceConnector: (Uri uri, FluseLogger? _) async {
        final FakeVmService created = FakeVmService(log);
        vmServices.add(created);
        return created;
      },
      devFsFactory: (SessionVmServiceContract vm, FluseLogger? _) {
        final FakeDevFS created = FakeDevFS(log);
        devFSs.add(created);
        return created;
      },
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
        // フェイクは URI の中身を見ない。資格情報らしい文字列は置かない。
        const VmServiceReadyMessage(
          vmServiceUri: 'http://127.0.0.1:9999/',
        ).toJson(),
      ),
    );
    expect(await nextMessage(queue), isA<ReadyMessage>());

    return (socket: socket, queue: queue);
  }

  /// 監視対象へ変更を流す。
  void emitChange(String relative) {
    for (final FakeWatchTarget target in targets) {
      target.emit(p.join(root, relative));
    }
  }

  /// 変更を流し、reload が実際に始まるまで待つ。
  ///
  /// **実時間で待たない。** 遅い CI では debounce の窓が閉じる前に
  /// 戻ってしまい、たまに落ちるテストになる。
  Future<void> emitAndAwaitReload(String relative) async {
    final Future<void> started = compiler.nextRecompileStart();
    emitChange(relative);
    await started;
  }

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
    await emitAndAwaitReload(p.join('lib', 'main.dart'));

    expect(await nextMessage(first.queue), isA<CompileOkMessage>());
    expect(log.countOf('compiler.recompile'), 1);

    // --- 切断 -----------------------------------------------------------
    final FakeTunnel firstTunnel = tunnels.single;
    final FakeVmService firstVmService = vmServices.single;
    final FakeDevFS firstDevFS = devFSs.single;

    await first.queue.cancel(immediate: true);
    await first.socket.close();
    // ポーリングで待たない。解放そのものの完了を待つ。
    await Future.wait(<Future<void>>[
      firstDevFS.destroyed.future,
      firstVmService.disposed.future,
      firstTunnel.closed.future,
    ]).timeout(const Duration(seconds: 10));

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
    // 解放済みの資源を掴み直していないこと。
    expect(tunnels, hasLength(2));
    expect(devFSs, hasLength(2));
    expect(identical(tunnels.first, tunnels.last), isFalse);
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
    await emitAndAwaitReload(p.join('lib', 'main.dart'));

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

    vmServices.single.reloadSucceeds = false;
    await emitAndAwaitReload(p.join('lib', 'main.dart'));

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

    // 指紋対象は recompile を通らないので、届いたメッセージで待つ。
    emitChange('pubspec.yaml');

    final FluseMessage message = await nextMessage(client.queue);
    expect(message, isA<ErrorMessage>());
    expect(
      (message as ErrorMessage).code,
      FluseErrorCode.appOutdated.wireValue,
    );
  });

  test('接続シーケンスが失敗したらエラーを返して資源を畳む', () async {
    final Uri base = await startRuntime();
    // 最初に作られるトンネルで失敗させる。
    bindShouldFail = true;

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
        // フェイクは URI の中身を見ない。資格情報らしい文字列は置かない。
        const VmServiceReadyMessage(
          vmServiceUri: 'http://127.0.0.1:9999/',
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

  test('vmServiceReady が連続で来てもセッションは1つだけ', () async {
    // _session への代入までに await が3つ挟まる。入口で止めないと
    // 両方が通り抜け、先に作った資源が参照を失ったまま残る。
    final Uri base = await startRuntime();
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
    expect(await nextMessage(queue), isA<AcceptMessage>());

    final String ready = jsonEncode(
      const VmServiceReadyMessage(
        vmServiceUri: 'http://127.0.0.1:9999/',
      ).toJson(),
    );
    socket
      ..add(ready)
      ..add(ready);

    expect(await nextMessage(queue), isA<ReadyMessage>());
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(tunnels, hasLength(1));
    expect(devFSs, hasLength(1));
    expect(log.countOf('devfs.create'), 1);
  });

  test('セッションが無い間の変更は反映しない', () async {
    await startRuntime();

    emitChange(p.join('lib', 'main.dart'));
    // 反映されないことの確認なので、ここは窓が閉じるまで待つしかない。
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(log.countOf('compiler.recompile'), 0);
  });

  test('反映中に来た変更は待たされ、recompile は重ならない', () async {
    // frontend_server は accept / reject の応答待ちを1つしか持てない。
    // 重ねると差分の状態が壊れ、以降の全リロードが失敗する（設計 §10-2）。
    final Uri base = await startRuntime();
    final ({WebSocket socket, StreamQueue<dynamic> queue}) client =
        await connectAndReady(base);
    addTearDown(() async {
      await client.queue.cancel(immediate: true);
      await client.socket.close();
    });

    final Completer<void> gate = Completer<void>();
    compiler.gate = gate;
    await emitAndAwaitReload(p.join('lib', 'a.dart'));

    // 1本目が止まっている間に2本目を流す。
    final Future<void> second = compiler.nextRecompileStart();
    emitChange(p.join('lib', 'b.dart'));
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(log.countOf('compiler.recompile'), 1, reason: 'まだ2本目は始まらない');

    compiler.gate = null;
    gate.complete();
    await second.timeout(const Duration(seconds: 10));

    expect(compiler.maxInFlight, 1);
    expect(log.countOf('compiler.recompile'), 2);
  });

  test('反映が失敗してもキューは止まらない', () async {
    // エラー完了の Future に then を繋いでも走らない。以後ファイルを
    // 変えてもリロードが二度と起きなくなる。
    final Uri base = await startRuntime();
    final ({WebSocket socket, StreamQueue<dynamic> queue}) client =
        await connectAndReady(base);
    addTearDown(() async {
      await client.queue.cancel(immediate: true);
      await client.socket.close();
    });

    compiler.throwOnNextRecompile = true;
    await emitAndAwaitReload(p.join('lib', 'a.dart'));
    expect(await nextMessage(client.queue), isA<ErrorMessage>());

    await emitAndAwaitReload(p.join('lib', 'b.dart'));

    expect(await nextMessage(client.queue), isA<CompileOkMessage>());
    expect(log.countOf('compiler.recompile'), 2);
  });

  test('close で CompilerService も落とす', () async {
    await startRuntime();

    await runtime!.close();

    expect(log.countOf('compiler.shutdown'), 1);
    expect(fileWatcher.isWatching, isFalse);
  });
}
