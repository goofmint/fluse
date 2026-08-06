import 'dart:io';

import 'compile_output.dart';
import 'dev_fs_client.dart';
import 'fluse_logger.dart';
import 'reload_contracts.dart';
import 'vm_service_client.dart';

/// 1サイクルの結果。
enum HotReloadStatus {
  /// 反映まで通った。
  success,

  /// コンパイルエラーで中断した。`accept` も `reject` も送っていない。
  compileError,

  /// `reloadSources` が受理しなかった。`reject` を送って中断した。
  reloadFailure,
}

/// 転送して evict する asset 1件。
///
/// DevFS 上のパス解決は呼び出し側（Task 3.4 の `AssetBundleService`）の
/// 責務。ここでは解決済みのものを受け取る。
final class ChangedAsset {
  const ChangedAsset({
    required this.deviceUri,
    required this.content,
    required this.archivePath,
  });

  /// DevFS 上の書き込み先。
  final Uri deviceUri;

  final DevFSContent content;

  /// `ext.flutter.evict` に渡すパス。`assets/images/logo.png` の形。
  final String archivePath;
}

/// [HotReloadOrchestrator.reload] の結果。
final class HotReloadResult {
  const HotReloadResult({
    required this.status,
    required this.summary,
    required this.timings,
    this.diagnostics = const <DiagnosticEntry>[],
    this.notices = const <String>[],
  });

  final HotReloadStatus status;

  /// CLI に出す1行サマリ。
  final String summary;

  /// 各段の所要時間（ミリ秒）。段の名前は [HotReloadOrchestrator] の
  /// `stage*` 定数と対応する。
  final Map<String, int> timings;

  /// コンパイル診断。[HotReloadStatus.compileError] のときに入る。
  final List<DiagnosticEntry> diagnostics;

  /// VM が返した補足。[HotReloadStatus.reloadFailure] のときに入る。
  final List<String> notices;

  bool get isSuccess => status == HotReloadStatus.success;

  /// 全段の合計時間。
  int get totalMs => timings.values.fold(0, (int sum, int ms) => sum + ms);

  @override
  String toString() => 'HotReloadResult($status, ${totalMs}ms): $summary';
}

/// 反映の1サイクル（設計 §2.2.3(d)）。
///
/// **`accept` と `reject` の使い分けがこのクラスの核心**（設計 §10-2）。
///
/// | 経路 | 送るもの |
/// |---|---|
/// | コンパイルエラー | **どちらも送らない**。次回の recompile が同じ差分を再送する |
/// | reload 失敗 | **必ず `reject`**。送らないと差分が「送信済み」のまま残る |
/// | 成功 | `accept` |
///
/// reload 失敗時に `accept` を送ると `frontend_server` が「送信済み」と
/// 誤認し、以降そのファイルの差分が二度と送られなくなる。再現性が低く
/// デバッグが極めて困難な不具合になる。
final class HotReloadOrchestrator {
  HotReloadOrchestrator({
    required CompilerContract compiler,
    required DevFSWriterContract devFS,
    required VmServiceContract vmService,
    required this.mainUri,
    required this.dillDeviceUri,
    required this.rootLibUri,
    FluseLogger? logger,
  }) : _compiler = compiler,
       _devFS = devFS,
       _vmService = vmService,
       _logger = logger;

  /// 段の名前。[HotReloadResult.timings] のキー。
  static const String stageRecompile = 'recompile';
  static const String stageDevFsWrite = 'devfsWrite';
  static const String stageReload = 'reloadSources';
  static const String stageEvict = 'evict';
  static const String stageReassemble = 'reassemble';

  /// コンパイル対象のエントリポイント。
  final Uri mainUri;

  /// 差分 dill を DevFS のどこに置くか。
  final Uri dillDeviceUri;

  /// `reloadSources` に渡す `rootLibUri`。DevFS 上の `fluse_main.dart`。
  final String rootLibUri;

  final CompilerContract _compiler;
  final DevFSWriterContract _devFS;
  final VmServiceContract _vmService;
  final FluseLogger? _logger;

  /// 一度特定した isolate は使い回す。毎回 `getVM` を投げると遅い。
  String? _isolateId;

  /// キャッシュ済みの isolate を捨てる。
  ///
  /// Hot Restart の後など、isolate が作り直された場合に呼ぶ。
  void invalidateIsolate() => _isolateId = null;

  /// 1サイクル回す。
  Future<HotReloadResult> reload({
    required List<Uri> invalidated,
    List<ChangedAsset> changedAssets = const <ChangedAsset>[],
  }) async {
    final Map<String, int> timings = <String, int>{};

    // --- 1. 差分コンパイル -------------------------------------------------
    final CompileOutput compiled = await _measure(
      stageRecompile,
      timings,
      () => _compiler.recompile(mainUri, invalidated),
    );

    if (compiled.hasErrors) {
      // accept も reject も送らない。差分は未確定のまま残り、
      // 次回の recompile が同じ内容を再送する。
      _logger?.warn(
        'コンパイルエラーのため中断しました',
        fields: <String, Object?>{
          'errorCount': compiled.errorCount,
          ...timings,
        },
      );
      return HotReloadResult(
        status: HotReloadStatus.compileError,
        summary: compiled.summary,
        timings: timings,
        diagnostics: compiled.diagnostics,
      );
    }

    // --- 2. DevFS へ転送 ---------------------------------------------------
    final File? dill = compiled.incrementalDill;
    if (dill == null) {
      // 差分が無い応答。転送するものが無いので反映もしない。
      _logger?.debug('差分 dill が無いため転送をスキップしました');
      return HotReloadResult(
        status: HotReloadStatus.success,
        summary: '変更はありません',
        timings: timings,
      );
    }

    await _measure(stageDevFsWrite, timings, () async {
      await _devFS.writeAll(<Uri, DevFSContent>{
        dillDeviceUri: DevFSContent.fromFile(dill),
        for (final ChangedAsset asset in changedAssets)
          asset.deviceUri: asset.content,
      });
    });

    // --- 3. reloadSources --------------------------------------------------
    final String isolateId = _isolateId ??= await _vmService
        .findMainIsolateId();

    final ReloadResult reloaded = await _measure(
      stageReload,
      timings,
      () => _vmService.reloadSources(isolateId, rootLibUri: rootLibUri),
    );

    if (!reloaded.success) {
      // 必ず reject する。送らないと差分が「送信済み」のまま残り、
      // 次回の recompile に含まれなくなる。
      await _compiler.reject();
      _logger?.warn(
        'reloadSources が受理されませんでした',
        fields: <String, Object?>{'notices': reloaded.notices, ...timings},
      );
      return HotReloadResult(
        status: HotReloadStatus.reloadFailure,
        summary: 'リロードが受理されませんでした',
        timings: timings,
        notices: reloaded.notices,
      );
    }

    _compiler.accept();

    // --- 4. asset の evict -------------------------------------------------
    if (changedAssets.isNotEmpty) {
      await _measure(stageEvict, timings, () async {
        for (final ChangedAsset asset in changedAssets) {
          await _vmService.evict(isolateId, asset.archivePath);
        }
      });
    }

    // --- 5. reassemble -----------------------------------------------------
    await _measure(
      stageReassemble,
      timings,
      () => _vmService.reassemble(isolateId),
    );

    final HotReloadResult result = HotReloadResult(
      status: HotReloadStatus.success,
      summary: '反映しました',
      timings: timings,
    );

    _logger?.info(
      'ホットリロードが完了しました',
      fields: <String, Object?>{
        'files': invalidated.length,
        'assets': changedAssets.length,
        'totalMs': result.totalMs,
        ...timings,
      },
    );
    return result;
  }

  /// [action] の所要時間を [timings] に記録する。
  ///
  /// 例外が出た場合も記録する。どの段で落ちたかが分からないと
  /// 原因の切り分けができない。
  Future<T> _measure<T>(
    String stage,
    Map<String, int> timings,
    Future<T> Function() action,
  ) async {
    final Stopwatch stopwatch = Stopwatch()..start();
    try {
      return await action();
    } finally {
      stopwatch.stop();
      timings[stage] = stopwatch.elapsedMilliseconds;
    }
  }
}
