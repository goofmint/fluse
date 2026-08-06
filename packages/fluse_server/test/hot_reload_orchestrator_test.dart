import 'dart:io';

import 'package:fluse_server/fluse_server.dart';
import 'package:fluse_server/testing.dart';
import 'package:test/test.dart';

/// `accept` / `reject` のどちらが呼ばれたかを記録するフェイク。
///
/// **このタスクで最も守りたいのはここの呼び分け**（設計 §10-2）なので、
/// 呼び出し順まで残す。
final class _FakeCompiler implements CompilerContract {
  _FakeCompiler(this.output);

  CompileOutput output;

  /// `recompile` に渡された引数。
  final List<(Uri, List<Uri>)> recompileCalls = <(Uri, List<Uri>)>[];

  /// `accept` / `reject` の呼び出し順。
  final List<String> confirmations = <String>[];

  @override
  bool needsConfirmation = false;

  @override
  Future<CompileOutput> recompile(Uri mainUri, List<Uri> invalidated) async {
    recompileCalls.add((mainUri, invalidated));
    needsConfirmation = true;
    return output;
  }

  @override
  void accept() {
    confirmations.add('accept');
    needsConfirmation = false;
  }

  /// `reject` を失敗させたい場合に設定する。
  Object? rejectError;

  @override
  Future<CompileOutput?> reject() async {
    confirmations.add('reject');
    needsConfirmation = false;
    final Object? failure = rejectError;
    if (failure != null) {
      throw failure;
    }
    return null;
  }
}

final class _FakeDevFS implements DevFSWriterContract {
  final List<Map<Uri, DevFSContent>> writes = <Map<Uri, DevFSContent>>[];

  /// 転送を失敗させたい場合に設定する。
  Object? error;

  @override
  Future<void> writeAll(Map<Uri, DevFSContent> entries) async {
    final Object? failure = error;
    if (failure != null) {
      throw failure;
    }
    writes.add(entries);
  }
}

final class _FakeVmService implements VmServiceContract {
  /// `reloadSources` が返す結果。失敗経路のテストで差し替える。
  ReloadResult reloadResult = const ReloadResult(success: true);

  int findIsolateCalls = 0;
  final List<String> evicted = <String>[];
  int reassembleCalls = 0;
  final List<String> calls = <String>[];

  /// `findMainIsolateId` を失敗させたい場合に設定する。
  Object? findIsolateError;

  /// `reloadSources` を失敗させたい場合に設定する。
  Object? reloadError;

  @override
  Future<String> findMainIsolateId() async {
    findIsolateCalls++;
    final Object? failure = findIsolateError;
    if (failure != null) {
      throw failure;
    }
    return 'isolates/1';
  }

  @override
  Future<ReloadResult> reloadSources(
    String isolateId, {
    String? rootLibUri,
    String? packagesUri,
  }) async {
    calls.add('reloadSources:$rootLibUri');
    final Object? failure = reloadError;
    if (failure != null) {
      throw failure;
    }
    return reloadResult;
  }

  @override
  Future<void> evict(String isolateId, String assetPath) async {
    calls.add('evict:$assetPath');
    evicted.add(assetPath);
  }

  @override
  Future<void> reassemble(String isolateId) async {
    calls.add('reassemble');
    reassembleCalls++;
  }
}

void main() {
  late Directory temp;
  late File dill;
  late _FakeCompiler compiler;
  late _FakeDevFS devFS;
  late _FakeVmService vmService;
  late MemoryLogSink sink;

  final Uri mainUri = Uri.parse('org-dartlang-root:///lib/main.dart');
  final Uri dillDeviceUri = Uri.parse('lib/main.dart.incremental.dill');
  const String rootLibUri =
      'org-dartlang-root:///.flutter_preview/fluse_main.dart';

  CompileOutput successOutput() => CompileOutput(
    errorCount: 0,
    diagnostics: const <DiagnosticEntry>[],
    sources: <Uri>[mainUri],
    incrementalDill: dill,
  );

  CompileOutput errorOutput() => CompileOutput(
    errorCount: 2,
    diagnostics: const <DiagnosticEntry>[
      DiagnosticEntry(
        severity: DiagnosticSeverity.error,
        message: "Expected ';'",
        raw: "lib/main.dart:3:1: Error: Expected ';'",
        file: 'lib/main.dart',
        line: 3,
        column: 1,
      ),
    ],
    sources: <Uri>[mainUri],
    incrementalDill: dill,
  );

  HotReloadOrchestrator buildOrchestrator() => HotReloadOrchestrator(
    compiler: compiler,
    devFS: devFS,
    vmService: vmService,
    mainUri: mainUri,
    dillDeviceUri: dillDeviceUri,
    rootLibUri: rootLibUri,
    logger: FluseLogger(
      sinks: <FluseLogSink>[sink],
      minimumLevel: FluseLogLevel.debug,
    ),
  );

  ChangedAsset asset(String path) => ChangedAsset(
    deviceUri: Uri.parse('build/flutter_assets/$path'),
    content: DevFSContent.fromString('bytes of $path'),
    archivePath: path,
  );

  setUp(() {
    temp = Directory.systemTemp.createTempSync('fluse_orchestrator_test.');
    dill = File('${temp.path}/app.dill')..writeAsBytesSync(<int>[1, 2, 3]);
    compiler = _FakeCompiler(successOutput());
    devFS = _FakeDevFS();
    vmService = _FakeVmService();
    sink = MemoryLogSink();
  });

  tearDown(() => temp.deleteSync(recursive: true));

  group('成功経路', () {
    test('accept → evict → reassemble の順に進む', () async {
      final HotReloadOrchestrator orchestrator = buildOrchestrator();

      final HotReloadResult result = await orchestrator.reload(
        invalidated: <Uri>[mainUri],
        changedAssets: <ChangedAsset>[asset('assets/images/logo.png')],
      );

      expect(result.status, HotReloadStatus.success);
      expect(result.isSuccess, isTrue);
      expect(compiler.confirmations, <String>['accept']);
      expect(vmService.calls, <String>[
        'reloadSources:$rootLibUri',
        'evict:assets/images/logo.png',
        'reassemble',
      ]);
    });

    test('差分 dill と asset を1回の writeAll でまとめて送る', () async {
      final HotReloadOrchestrator orchestrator = buildOrchestrator();

      await orchestrator.reload(
        invalidated: <Uri>[mainUri],
        changedAssets: <ChangedAsset>[
          asset('assets/a.png'),
          asset('assets/b.png'),
        ],
      );

      expect(devFS.writes, hasLength(1));
      expect(devFS.writes.single.keys, <Uri>[
        dillDeviceUri,
        Uri.parse('build/flutter_assets/assets/a.png'),
        Uri.parse('build/flutter_assets/assets/b.png'),
      ]);
    });

    test('asset が無ければ evict しない', () async {
      final HotReloadOrchestrator orchestrator = buildOrchestrator();

      await orchestrator.reload(invalidated: <Uri>[mainUri]);

      expect(vmService.evicted, isEmpty);
      expect(vmService.reassembleCalls, 1);
    });

    test('isolate は一度だけ特定して使い回す', () async {
      final HotReloadOrchestrator orchestrator = buildOrchestrator();

      final HotReloadResult first = await orchestrator.reload(
        invalidated: <Uri>[mainUri],
      );
      final HotReloadResult second = await orchestrator.reload(
        invalidated: <Uri>[mainUri],
      );

      expect(vmService.findIsolateCalls, 1);
      // 2回目はキャッシュヒットなので段として記録しない。毎回0msの段が
      // 並ぶとログのノイズになる。
      expect(
        first.timings.keys,
        contains(HotReloadOrchestrator.stageResolveIsolate),
      );
      expect(
        second.timings.keys,
        isNot(contains(HotReloadOrchestrator.stageResolveIsolate)),
      );
    });

    test('invalidateIsolate で再取得する', () async {
      // Hot Restart 後は isolate が作り直される。
      final HotReloadOrchestrator orchestrator = buildOrchestrator();

      await orchestrator.reload(invalidated: <Uri>[mainUri]);
      orchestrator.invalidateIsolate();
      await orchestrator.reload(invalidated: <Uri>[mainUri]);

      expect(vmService.findIsolateCalls, 2);
    });

    test('差分 dill が無ければ転送も反映もしない', () async {
      compiler.output = const CompileOutput(
        errorCount: 0,
        diagnostics: <DiagnosticEntry>[],
        sources: <Uri>[],
      );
      final HotReloadOrchestrator orchestrator = buildOrchestrator();

      final HotReloadResult result = await orchestrator.reload(
        invalidated: <Uri>[mainUri],
      );

      expect(result.status, HotReloadStatus.success);
      expect(devFS.writes, isEmpty);
      expect(vmService.calls, isEmpty);
      // 適用していないので reject。確認を未解決のまま残すと、この差分が
      // 次回の recompile に含まれなくなる。
      expect(compiler.confirmations, <String>['reject']);
      expect(compiler.needsConfirmation, isFalse);
    });
  });

  group('コンパイルエラー経路', () {
    test('accept も reject も送らない', () async {
      // 送ってしまうと差分の状態が壊れる（設計 §10-2）。
      compiler.output = errorOutput();
      final HotReloadOrchestrator orchestrator = buildOrchestrator();

      final HotReloadResult result = await orchestrator.reload(
        invalidated: <Uri>[mainUri],
      );

      expect(result.status, HotReloadStatus.compileError);
      expect(compiler.confirmations, isEmpty);
    });

    test('DevFS 転送も reloadSources もしない', () async {
      compiler.output = errorOutput();
      final HotReloadOrchestrator orchestrator = buildOrchestrator();

      await orchestrator.reload(invalidated: <Uri>[mainUri]);

      expect(devFS.writes, isEmpty);
      expect(vmService.calls, isEmpty);
      expect(vmService.findIsolateCalls, 0);
    });

    test('診断を結果に含める', () async {
      compiler.output = errorOutput();
      final HotReloadOrchestrator orchestrator = buildOrchestrator();

      final HotReloadResult result = await orchestrator.reload(
        invalidated: <Uri>[mainUri],
      );

      expect(result.diagnostics, hasLength(1));
      expect(result.diagnostics.single.line, 3);
      expect(result.summary, contains('2'));
    });

    test('確認待ちのまま残る', () async {
      // 次回の recompile が同じ差分を再送できる状態。
      compiler.output = errorOutput();
      final HotReloadOrchestrator orchestrator = buildOrchestrator();

      await orchestrator.reload(invalidated: <Uri>[mainUri]);

      expect(compiler.needsConfirmation, isTrue);
    });
  });

  group('reload 失敗経路', () {
    setUp(() {
      vmService.reloadResult = const ReloadResult(
        success: false,
        notices: <String>['const class を変更しました'],
      );
    });

    test('必ず reject を送る', () async {
      // accept を送ると、以降そのファイルの差分が二度と送られなくなる。
      final HotReloadOrchestrator orchestrator = buildOrchestrator();

      final HotReloadResult result = await orchestrator.reload(
        invalidated: <Uri>[mainUri],
      );

      expect(result.status, HotReloadStatus.reloadFailure);
      expect(compiler.confirmations, <String>['reject']);
      expect(compiler.confirmations, isNot(contains('accept')));
    });

    test('notices を結果に含める', () async {
      final HotReloadOrchestrator orchestrator = buildOrchestrator();

      final HotReloadResult result = await orchestrator.reload(
        invalidated: <Uri>[mainUri],
      );

      expect(result.notices, <String>['const class を変更しました']);
    });

    test('evict も reassemble もしない', () async {
      final HotReloadOrchestrator orchestrator = buildOrchestrator();

      await orchestrator.reload(
        invalidated: <Uri>[mainUri],
        changedAssets: <ChangedAsset>[asset('assets/a.png')],
      );

      expect(vmService.evicted, isEmpty);
      expect(vmService.reassembleCalls, 0);
    });
  });

  group('accept 前の例外', () {
    test('DevFS 転送が失敗したら reject してから投げ直す', () async {
      // 部分的に転送された状態で反映すると、端末側の kernel と食い違う。
      // 確認を未解決のまま抜けると、この差分が次回に含まれなくなる。
      devFS.error = const DevFSException('転送に失敗しました');
      final HotReloadOrchestrator orchestrator = buildOrchestrator();

      await expectLater(
        orchestrator.reload(invalidated: <Uri>[mainUri]),
        throwsA(isA<DevFSException>()),
      );
      expect(vmService.calls, isEmpty);
      expect(compiler.confirmations, <String>['reject']);
      expect(compiler.needsConfirmation, isFalse);
    });

    test('isolate の特定が失敗したら reject してから投げ直す', () async {
      vmService.findIsolateError = const VmServiceException('isolate なし');
      final HotReloadOrchestrator orchestrator = buildOrchestrator();

      await expectLater(
        orchestrator.reload(invalidated: <Uri>[mainUri]),
        throwsA(isA<VmServiceException>()),
      );
      expect(compiler.confirmations, <String>['reject']);
      // 失敗した段が isolate 解決だと分かること。
      expect(
        sink.lines.join('\n'),
        contains(HotReloadOrchestrator.stageResolveIsolate),
      );
    });

    test('reject の失敗で元の例外を隠さない', () async {
      // 後始末の失敗を投げると、本当の原因が呼び出し元に届かなくなる。
      devFS.error = const DevFSException('本当の原因');
      compiler.rejectError = StateError('後始末の失敗');
      final HotReloadOrchestrator orchestrator = buildOrchestrator();

      await expectLater(
        orchestrator.reload(invalidated: <Uri>[mainUri]),
        throwsA(
          isA<DevFSException>().having(
            (DevFSException e) => e.message,
            'message',
            '本当の原因',
          ),
        ),
      );
      expect(sink.lines.join('\n'), contains('cleanupError'));
    });

    test('reloadSources が例外を投げたら reject してから投げ直す', () async {
      vmService.reloadError = const VmServiceException('rpc 失敗');
      final HotReloadOrchestrator orchestrator = buildOrchestrator();

      await expectLater(
        orchestrator.reload(invalidated: <Uri>[mainUri]),
        throwsA(isA<VmServiceException>()),
      );
      expect(compiler.confirmations, <String>['reject']);
      expect(compiler.needsConfirmation, isFalse);
    });

    test('失敗した段と計測値をログに残す', () async {
      // どの段で落ちたか分からないと原因の切り分けができない。
      devFS.error = const DevFSException('boom');
      final HotReloadOrchestrator orchestrator = buildOrchestrator();

      await expectLater(
        orchestrator.reload(invalidated: <Uri>[mainUri]),
        throwsA(isA<DevFSException>()),
      );

      final String logged = sink.lines.join('\n');
      expect(logged, contains('failedStage'));
      expect(logged, contains(HotReloadOrchestrator.stageDevFsWrite));
      expect(logged, contains(HotReloadOrchestrator.stageRecompile));
    });
  });

  group('所要時間の計測', () {
    test('各段の時間を結果に含める', () async {
      final HotReloadOrchestrator orchestrator = buildOrchestrator();

      final HotReloadResult result = await orchestrator.reload(
        invalidated: <Uri>[mainUri],
        changedAssets: <ChangedAsset>[asset('assets/a.png')],
      );

      expect(
        result.timings.keys,
        containsAll(<String>[
          HotReloadOrchestrator.stageRecompile,
          HotReloadOrchestrator.stageDevFsWrite,
          HotReloadOrchestrator.stageReload,
          HotReloadOrchestrator.stageEvict,
          HotReloadOrchestrator.stageReassemble,
        ]),
      );
      expect(result.timings.values, everyElement(greaterThanOrEqualTo(0)));
      expect(result.totalMs, greaterThanOrEqualTo(0));
    });

    test('中断した場合はそこまでの段だけ記録する', () async {
      compiler.output = errorOutput();
      final HotReloadOrchestrator orchestrator = buildOrchestrator();

      final HotReloadResult result = await orchestrator.reload(
        invalidated: <Uri>[mainUri],
      );

      expect(result.timings.keys, <String>[
        HotReloadOrchestrator.stageRecompile,
      ]);
    });

    test('ログに elapsedMs を構造化フィールドで残す', () async {
      final HotReloadOrchestrator orchestrator = buildOrchestrator();

      await orchestrator.reload(invalidated: <Uri>[mainUri]);

      expect(
        sink.lines.join('\n'),
        contains(HotReloadOrchestrator.stageReassemble),
      );
      expect(sink.lines.join('\n'), contains('totalMs'));
    });
  });

  test('recompile に mainUri と invalidated をそのまま渡す', () async {
    final HotReloadOrchestrator orchestrator = buildOrchestrator();
    final List<Uri> invalidated = <Uri>[
      mainUri,
      Uri.parse('org-dartlang-root:///lib/widget.dart'),
    ];

    await orchestrator.reload(invalidated: invalidated);

    expect(compiler.recompileCalls.single.$1, mainUri);
    expect(compiler.recompileCalls.single.$2, invalidated);
  });
}
