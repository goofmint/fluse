// Task 1.6 のスパイク（GO/NO-GO ゲート）。
//
// トンネル・WebSocket・Runtime を一切使わず、`adb forward` で VM Service に
// 直結して「反映経路が成立するか」だけを確かめる。
//
// 使い方:
//   1. examples/counter_app をビルドして端末にインストール・起動する
//   2. logcat から VM Service の URI を取る
//   3. adb forward tcp:0 tcp:<端末側ポート>
//   4. dart run tool/spike_hot_reload.dart \
//        --vm-service http://127.0.0.1:<ホスト側ポート>/<認証コード>/ \
//        --project <counter_app のパス>
//
// 反映が確認できたら GO、できなければ設計に戻る。
import 'dart:io';

import 'package:fluse_builder/fluse_builder.dart';
import 'package:fluse_server/fluse_server.dart';
import 'package:path/path.dart' as p;

Future<int> main(List<String> args) async {
  final Map<String, String> options = _parseArgs(args);
  final String? vmServiceUri = options['vm-service'];
  final String? projectRoot = options['project'];

  if (vmServiceUri == null || projectRoot == null) {
    stderr.writeln(
      '使い方: dart run tool/spike_hot_reload.dart '
      '--vm-service <URI> --project <パス> [--scheme package|filesystem]',
    );
    return 64;
  }

  // 設計 §2.2.3(a) は --filesystem-scheme を使う前提だが、
  // flutter build apk が生成する kernel は package: URI を使っている。
  // どちらで通るかをこのスパイクで確かめるため切り替えられるようにする。
  final bool useFilesystemScheme = options['scheme'] != 'package';

  final Directory cache = Directory(p.join(projectRoot, '.flutter_preview'))
    ..createSync(recursive: true);

  final FluseLogger logger = FluseLogger(
    sinks: <FluseLogSink>[const StdoutLogSink()],
    minimumLevel: FluseLogLevel.debug,
  );

  stdout.writeln('== Flutter SDK を解決 ==');
  final FlutterSdk sdk = await FlutterSdk.resolve();
  stdout.writeln('  ${sdk.version} (${sdk.revision})');

  stdout.writeln('== VM Service に接続 ==');
  final VmServiceClient vmService = await VmServiceClient.connect(
    Uri.parse(vmServiceUri),
    logger: logger,
  );
  final String isolateId = await vmService.findMainIsolateId();
  stdout.writeln('  isolate: $isolateId');

  stdout.writeln('== frontend_server を起動 ==');
  final CompilerService compiler = CompilerService(
    dartAotRuntime: sdk.dartAotRuntime,
    frontendServerSnapshot: sdk.frontendServerSnapshot,
    patchedSdkRoot: sdk.patchedSdkRoot,
    projectRoot: projectRoot,
    outputDill: p.join(cache.path, 'cache', 'app.dill'),
    packagesPath: p.join(projectRoot, '.dart_tool', 'package_config.json'),
    dartDefines: _buildDefines(sdk),
    fileSystemScheme: useFilesystemScheme
        ? CompilerService.defaultFileSystemScheme
        : '',
    logger: logger,
  );
  await compiler.start();

  final Uri mainUri = useFilesystemScheme
      ? Uri.file(p.join(projectRoot, 'lib', 'main.dart'))
      : Uri.parse('package:counter_app/main.dart');

  stdout.writeln('== 初回コンパイル ==');
  final Stopwatch firstCompile = Stopwatch()..start();
  final CompileOutput first = await compiler.compile(mainUri);
  firstCompile.stop();
  stdout.writeln(
    '  errorCount=${first.errorCount} '
    'sources=${first.sources.length} ${firstCompile.elapsedMilliseconds}ms',
  );
  if (first.hasErrors) {
    for (final DiagnosticEntry d in first.diagnostics) {
      stderr.writeln('  ${d.raw}');
    }
    await compiler.shutdown();
    return 1;
  }
  stdout.writeln('== DevFS を作成 ==');
  final DevFSClient devFS = DevFSClient(vmService: vmService, logger: logger);
  final Uri devFsBase = await devFS.create('fluse-spike');
  stdout.writeln('  $devFsBase');

  // flutter_tools と同じ約束。dill は DevFS 直下に置き、reloadSources には
  // **その DevFS 上の絶対 URI**を渡す（run_hot.dart:1297, 1371）。
  // エントリポイントの URI ではない。
  const String dillName = 'main.dart.incremental.dill';
  final String rootLibUri = devFsBase.resolve(dillName).toString();
  stdout.writeln('  rootLibUri=$rootLibUri');

  // --- 初回同期 ---------------------------------------------------------
  // **初回は完全な dill を送る必要がある。**
  // 端末で動いているのは APK に同梱された kernel_blob.bin であり、
  // こちらの frontend_server セッションが持つ「直前の状態」とは無関係。
  // 差分だけを送っても VM は文脈を組み立てられず、
  // `Error while starting Kernel isolate task` で拒否される。
  stdout.writeln('== 初回同期（完全な dill を転送）==');
  final File fullDill = first.incrementalDill!;
  final Stopwatch priming = Stopwatch()..start();
  await devFS.writeAll(<Uri, DevFSContent>{
    Uri.parse(dillName): DevFSContent.fromFile(fullDill),
  });
  final ReloadResult primed = await vmService.reloadSources(
    isolateId,
    rootLibUri: rootLibUri,
  );
  priming.stop();
  stdout.writeln(
    '  success=${primed.success} '
    '${fullDill.lengthSync()}バイト ${priming.elapsedMilliseconds}ms',
  );
  if (!primed.success) {
    for (final String notice in primed.notices) {
      stderr.writeln('  notice: $notice');
    }
    await compiler.shutdown();
    return 1;
  }
  compiler.accept();

  // 変更 asset。`--asset <プロジェクト相対パス>` で指定する。
  // DevFS 上の置き場所は flutter_tools と同じ `build/flutter_assets/` 配下、
  // evict に渡すのは asset マニフェスト上のパス（`assets/...`）。
  const String assetSubdir = 'build/flutter_assets';
  final String? assetPath = options['asset'];
  final List<ChangedAsset> changedAssets = <ChangedAsset>[
    if (assetPath != null)
      ChangedAsset(
        deviceUri: Uri.parse('$assetSubdir/$assetPath'),
        content: DevFSContent.fromFile(File(p.join(projectRoot, assetPath))),
        archivePath: assetPath,
      ),
  ];

  // **asset を反映させるにはエンジンに DevFS 上の asset ディレクトリを
  // 教える必要がある。** これをしないと Dart は反映されるのに画像だけが
  // 古いまま、という分かりにくい状態になる（実測で確認）。
  //
  // **順序が重要**: ディレクトリの実体が DevFS 上に無いと
  // `setAssetBundlePath` は `Could not update asset directory.` で失敗する。
  // 先に1つ書き込んでからエンジンに教える。
  if (changedAssets.isNotEmpty) {
    stdout.writeln('== asset ディレクトリを用意して登録 ==');
    await devFS.writeAll(<Uri, DevFSContent>{
      for (final ChangedAsset asset in changedAssets)
        asset.deviceUri: asset.content,
    });
    for (final ({String viewId, String? isolateId}) view
        in await vmService.listViews()) {
      await vmService.setAssetDirectory(
        viewId: view.viewId,
        isolateId: view.isolateId,
        assetsDirectory: devFsBase.resolve('$assetSubdir/'),
      );
    }
  }

  await vmService.reassemble(isolateId);

  final HotReloadOrchestrator orchestrator = HotReloadOrchestrator(
    compiler: compiler,
    devFS: devFS,
    vmService: vmService,
    mainUri: mainUri,
    dillDeviceUri: Uri.parse(dillName),
    rootLibUri: rootLibUri,
    logger: logger,
  );

  stdout.writeln('== 差分サイクルを回す ==');
  final Stopwatch cycle = Stopwatch()..start();
  final HotReloadResult result = await orchestrator.reload(
    invalidated: <Uri>[mainUri],
    changedAssets: changedAssets,
  );
  cycle.stop();

  stdout.writeln('  status=${result.status}');
  stdout.writeln('  timings=${result.timings}');
  stdout.writeln('  total=${cycle.elapsedMilliseconds}ms');
  for (final String notice in result.notices) {
    stdout.writeln('  notice: $notice');
  }
  for (final DiagnosticEntry d in result.diagnostics) {
    stdout.writeln('  ${d.raw}');
  }

  await devFS.destroy();
  devFS.close();
  await compiler.shutdown();
  await vmService.dispose();

  return result.isSuccess ? 0 : 1;
}

/// `flutter build apk --debug` が渡していた `-D` を再現する。
///
/// 本来は `build_meta.json` から読む（Task 1.5）。スパイクでは
/// SDK の値から組み立てる。
List<String> _buildDefines(FlutterSdk sdk) => <String>[
  'FLUTTER_VERSION=${sdk.version}',
  'FLUTTER_CHANNEL=stable',
  'FLUTTER_GIT_URL=https://github.com/flutter/flutter.git',
  'FLUTTER_FRAMEWORK_REVISION=${sdk.revision.substring(0, 10)}',
  'FLUTTER_DART_VERSION=${sdk.dartVersion}',
  'FLUTTER_APP_FLAVOR=',
  'dart.vm.profile=false',
  'dart.vm.product=false',
];

Map<String, String> _parseArgs(List<String> args) {
  final Map<String, String> options = <String, String>{};
  for (int i = 0; i < args.length - 1; i++) {
    if (args[i].startsWith('--')) {
      options[args[i].substring(2)] = args[i + 1];
    }
  }
  return options;
}
