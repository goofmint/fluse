// **リテラルでなければならない。** `package:test` はこの注釈を実行前に
// 文字面から読むため、定数名を書くと "Expected a Duration" で読み込みに
// 失敗する。ネイティブ側（CMake / clang）のビルドから始まるので長く取る。
@Timeout(Duration(minutes: 30))
library;

import 'dart:io';

import 'package:fluse_builder/fluse_builder.dart';
import 'package:fluse_server/fluse_server.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'l3_flutter_run_harness.dart';

/// 実 Flutter プロセスに対する L3 統合テスト（設計 §7.2、Task 6.2）。
///
/// **Android を介さずに反映経路を通す。** 実機が要らないので CI で回せる。
/// デスクトップの Flutter も端末と同じ VM Service を持つため、
/// DevFS → `reloadSources` → `evict` → `reassemble` の経路は共通。
///
/// 見るのは2つ。
///
/// 1. Dart を変えて反映が通ること（`reloadSources` → `reassemble`）
/// 2. asset を変えて反映が通ること（`evict` → `reassemble`）
///
/// **画面の見た目までは見ない。** ピクセルの検証は CI で安定しない。
/// ここで確かめたいのは経路が繋がっていることで、それは各段が例外を
/// 出さずに完走し、`timings` に段が残ることで分かる。
///
/// 走るのは Linux のみ。macOS で試したい場合は `FLUSE_L3_DEVICE=macos` を
/// 指定する。**既定で macOS でも走らせない。** 手元で `dart test` を
/// 流すたびにデスクトップアプリの窓が開くのは、意図しない副作用になる。
void main() {
  /// `flutter run -d <device>`。空なら Linux 以外では走らせない。
  final String device =
      Platform.environment['FLUSE_L3_DEVICE'] ??
      (Platform.isLinux ? 'linux' : '');

  /// リポジトリ内の `examples/counter_app`。
  ///
  /// テストは `packages/fluse_server` を作業ディレクトリとして走る。
  final String sampleApp = p.normalize(
    p.join(Directory.current.path, '..', '..', 'examples', 'counter_app'),
  );

  /// DevFS 上の dill の名前。flutter_tools と同じ約束。
  const String dillName = 'main.dart.incremental.dill';

  /// 変更を起こす asset。`pubspec.yaml` で宣言済みのものを使う。
  const String assetPath = 'assets/images/fluse_logo.png';

  late Directory temp;
  late String projectRoot;

  String? skipReason;
  FlutterSdk? sdk;
  FlutterRunHarness? harness;
  VmServiceClient? vmService;
  CompilerService? compiler;
  DevFSClient? devFS;
  HotReloadOrchestrator? orchestrator;
  String? isolateId;

  /// `examples/counter_app` を丸ごと写す。**元は触らない。**
  ///
  /// `package_config.json` の自パッケージは `.dart_tool` からの相対なので、
  /// 写した先でもそのまま解決できる。
  void copySampleApp() {
    for (final String name in <String>['pubspec.yaml', 'pubspec.lock']) {
      File(p.join(sampleApp, name)).copySync(p.join(projectRoot, name));
    }
    for (final String dir in <String>['lib', 'assets', 'linux']) {
      _copyTree(Directory(p.join(sampleApp, dir)), projectRoot, sampleApp);
    }
    // **pubspec より後に写す。** 先に写すと mtime が古く見え、
    // `flutter run` が pub get をやり直す。
    Directory(p.join(projectRoot, '.dart_tool')).createSync(recursive: true);
    File(
      p.join(sampleApp, '.dart_tool', 'package_config.json'),
    ).copySync(p.join(projectRoot, '.dart_tool', 'package_config.json'));
  }

  setUpAll(() async {
    if (device.isEmpty) {
      skipReason =
          'デスクトップのターゲットが無いためスキップ'
          '（Linux で走ります。macOS では FLUSE_L3_DEVICE=macos）';
      return;
    }
    try {
      sdk = await FlutterSdk.resolve();
    } on SdkNotFoundException catch (error) {
      skipReason = 'Flutter SDK を解決できないためスキップ: ${error.reason}';
      return;
    }
    if (!File(
      p.join(sampleApp, '.dart_tool', 'package_config.json'),
    ).existsSync()) {
      skipReason =
          'examples/counter_app の依存が未解決のためスキップ'
          '（flutter pub get を実行してください）';
      return;
    }
    if (!Directory(p.join(sampleApp, 'linux')).existsSync()) {
      skipReason = 'examples/counter_app に linux/ が無いためスキップ';
      return;
    }

    temp = Directory.systemTemp.createTempSync('fluse_l3.');
    projectRoot = p.join(temp.path, 'counter_app');
    Directory(projectRoot).createSync(recursive: true);
    copySampleApp();

    final FlutterSdk resolved = sdk!;
    harness = await FlutterRunHarness.start(
      flutterExecutable: resolved.flutterExecutable,
      workingDirectory: projectRoot,
      device: device,
    );

    final VmServiceClient connected = await VmServiceClient.connect(
      harness!.vmServiceUri,
    );
    vmService = connected;
    isolateId = await connected.findMainIsolateId();

    // **`package:` で組む。** `flutter run` が作る kernel のライブラリ URI が
    // `package:` 形式なので、こちらも合わせないと差分が当たらない。
    final CompilerService started = CompilerService(
      dartAotRuntime: resolved.dartAotRuntime,
      frontendServerSnapshot: resolved.frontendServerSnapshot,
      patchedSdkRoot: resolved.patchedSdkRoot,
      projectRoot: projectRoot,
      outputDill: p.join(projectRoot, '.flutter_preview', 'cache', 'app.dill'),
      packagesPath: p.join(projectRoot, '.dart_tool', 'package_config.json'),
      fileSystemScheme: '',
    );
    compiler = started;
    await started.start();

    final CompileOutput first = await started.compile(_mainUri);
    expect(
      first.errorCount,
      0,
      reason: first.diagnostics.map((DiagnosticEntry d) => d.raw).join('\n'),
    );
    final File? fullDill = first.incrementalDill;
    expect(fullDill, isNotNull, reason: 'コンパイルは通ったのに dill が無い');

    final DevFSClient fs = DevFSClient(vmService: connected);
    devFS = fs;
    final Uri devFsBase = await fs.create('fluse-l3');

    // **初回は完全な dill を送る。** アプリが動かしている kernel は
    // こちらの frontend_server が持つ状態と無関係で、差分だけでは
    // 文脈を組み立てられない（`Error while starting Kernel isolate task`）。
    await fs.writeAll(<Uri, DevFSContent>{
      Uri.parse(dillName): DevFSContent.fromFile(fullDill!),
    });
    final String rootLibUri = devFsBase.resolve(dillName).toString();
    final ReloadResult primed = await connected.reloadSources(
      isolateId!,
      rootLibUri: rootLibUri,
    );
    expect(
      primed.success,
      isTrue,
      reason: '初回同期に失敗しました: ${primed.notices.join(', ')}',
    );
    started.accept();

    // **asset は登録の前に置く。** 実体が無いと
    // `Could not update asset directory.` で失敗する。
    final AssetSyncResult initial = AssetBundleService(
      projectRoot: projectRoot,
    ).sync();
    await fs.writeAll(<Uri, DevFSContent>{
      for (final ChangedAsset asset in initial.changed)
        asset.deviceUri: asset.content,
    });
    final List<({String viewId, String? isolateId})> views = await connected
        .listViews();
    expect(views, isNotEmpty, reason: 'Flutter View が1つも無い');
    for (final ({String viewId, String? isolateId}) view in views) {
      await connected.setAssetDirectory(
        viewId: view.viewId,
        isolateId: view.isolateId,
        assetsDirectory: devFsBase.resolve(
          '${AssetBundleService.devFsAssetRoot}/',
        ),
      );
    }

    orchestrator = HotReloadOrchestrator(
      compiler: started,
      devFS: fs,
      vmService: connected,
      mainUri: _mainUri,
      dillDeviceUri: Uri.parse(dillName),
      rootLibUri: rootLibUri,
    );
  });

  tearDownAll(() async {
    // 1つ失敗しても残りは続ける。DevFS を残すとアプリ側にゴミが溜まり、
    // frontend_server と flutter run を残すとプロセスが居座る。
    await _quietly(() => devFS?.destroy());
    await _quietly(() async => devFS?.close());
    await _quietly(() => compiler?.shutdown());
    await _quietly(() async => vmService?.dispose());
    await _quietly(() => harness?.stop());
    if (skipReason == null && temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  /// 前提が揃っていなければスキップする。
  HotReloadOrchestrator? ensureReady() {
    final String? reason = skipReason;
    if (reason != null) {
      markTestSkipped(reason);
      return null;
    }
    return orchestrator;
  }

  test('Dart の変更が反映まで通る', () async {
    final HotReloadOrchestrator? reload = ensureReady();
    if (reload == null) {
      return;
    }

    final File mainFile = File(p.join(projectRoot, 'lib', 'main.dart'));
    mainFile.writeAsStringSync(
      "${mainFile.readAsStringSync()}\nString fluseL3Changed() => 'l3';\n",
    );

    final HotReloadResult result = await reload.reload(
      invalidated: <Uri>[_mainUri],
    );

    expect(
      result.status,
      HotReloadStatus.success,
      reason: '${result.summary} ${result.notices.join(', ')}',
    );
    expect(result.timings.keys, contains(HotReloadOrchestrator.stageRecompile));
    expect(
      result.timings.keys,
      contains(HotReloadOrchestrator.stageDevFsWrite),
    );
    expect(result.timings.keys, contains(HotReloadOrchestrator.stageReload));
    expect(
      result.timings.keys,
      contains(HotReloadOrchestrator.stageReassemble),
    );
    expect(reload.unapplied, isEmpty, reason: '入ったなら持ち越しは残らない');
  });

  test('asset の変更が evict まで通る', () async {
    final HotReloadOrchestrator? reload = ensureReady();
    if (reload == null) {
      return;
    }

    // 中身を入れ替える。**サイズも変える。** 同じ大きさのまま書くと、
    // 差分の判定が mtime だけに頼る形になる。
    final File asset = File(p.join(projectRoot, assetPath));
    asset.writeAsBytesSync(<int>[...asset.readAsBytesSync(), 0, 1, 2, 3]);

    final AssetSyncResult synced = AssetBundleService(
      projectRoot: projectRoot,
    ).sync();
    expect(
      synced.changed.map((ChangedAsset a) => a.archivePath),
      contains(assetPath),
      reason: '書き換えた asset が差分に出るはず',
    );

    final HotReloadResult result = await reload.reload(
      invalidated: <Uri>[_mainUri],
      changedAssets: synced.changed,
    );

    expect(
      result.status,
      HotReloadStatus.success,
      reason: '${result.summary} ${result.notices.join(', ')}',
    );
    expect(result.timings.keys, contains(HotReloadOrchestrator.stageEvict));
    expect(
      result.timings.keys,
      contains(HotReloadOrchestrator.stageReassemble),
    );
  });
}

/// コンパイル対象。`flutter run` が作る kernel と同じ形にする。
final Uri _mainUri = Uri.parse('package:counter_app/main.dart');

/// [from] の下を [root] からの相対を保って [destination] へ写す。
void _copyTree(Directory from, String destination, String root) {
  if (!from.existsSync()) {
    return;
  }
  for (final FileSystemEntity entity in from.listSync(recursive: true)) {
    if (entity is! File) {
      continue;
    }
    final String relative = p.relative(entity.path, from: root);
    final File target = File(p.join(destination, relative))
      ..parent.createSync(recursive: true);
    entity.copySync(target.path);
  }
}

/// 後始末を、失敗しても次を止めないように包む。
Future<void> _quietly(Future<void>? Function() action) async {
  try {
    await action();
  } on Object catch (error) {
    printOnFailure('後始末に失敗しました: $error');
  }
}
