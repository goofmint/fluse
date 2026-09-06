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
import 'dart:async';
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
      '--vm-service <URI> --project <パス> [--scheme package|filesystem] '
      '[--cycles <n>] [--warmup <n>] [--report <パス>]',
    );
    return 64;
  }

  // 設計 §2.2.3(a) は --filesystem-scheme を使う前提だが、
  // flutter build apk が生成する kernel は package: URI を使っている。
  // どちらで通るかをこのスパイクで確かめるため切り替えられるようにする。
  final bool useFilesystemScheme = options['scheme'] != 'package';

  // 何回回すか。**既定は1回。** これまでの使い方（1回だけ回して
  // 反映されるかを見る）を変えない。
  final int cycles = _positiveInt(options['cycles'], 'cycles', 1);
  // 捨てる回数。初回は VM のキャッシュが冷えていて他より遅い。
  final int warmup = _positiveInt(options['warmup'], 'warmup', 0);

  // `--asset` はプロジェクト配下に限る。絶対パスや `..` をそのまま
  // 受け取ると、プロジェクト外のファイルを端末へ送れてしまう。
  final String? assetPath = _validateAssetPath(options['asset'], projectRoot);

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

  CompilerService? compiler;
  DevFSClient? devFS;
  int exitCode;
  Object? failure;
  StackTrace? failureTrace;

  try {
    exitCode = await _run(
      vmService: vmService,
      sdk: sdk,
      logger: logger,
      projectRoot: projectRoot,
      cache: cache,
      useFilesystemScheme: useFilesystemScheme,
      assetPath: assetPath,
      onCompiler: (CompilerService c) => compiler = c,
      onDevFS: (DevFSClient d) => devFS = d,
      cycles: cycles,
      warmup: warmup,
      reportPath: options['report'],
    );
  } on Object catch (error, stackTrace) {
    exitCode = 70;
    failure = error;
    failureTrace = stackTrace;
  }

  // 例外経路でも必ず解放する。DevFS を残すと端末側にゴミが溜まり、
  // frontend_server を残すとプロセスが居座る。1つが失敗しても残りは続ける。
  final List<String> cleanupErrors = <String>[
    ...await _release('DevFS の削除', () => devFS?.destroy()),
    ...await _release('HTTP 接続の解放', () async => devFS?.close()),
    ...await _release('frontend_server の停止', () => compiler?.shutdown()),
    ...await _release('VM Service の切断', vmService.dispose),
  ];

  if (failure != null) {
    // 本来の失敗を優先して見せる。後始末の失敗で原因を隠さない。
    for (final String error in cleanupErrors) {
      stderr.writeln('  $error');
    }
    Error.throwWithStackTrace(failure, failureTrace ?? StackTrace.current);
  }

  if (cleanupErrors.isNotEmpty) {
    // 後始末に失敗したまま成功を返すと、端末に DevFS が残ったことに
    // 気づけない。成功していても非ゼロで返す。
    for (final String error in cleanupErrors) {
      stderr.writeln('  $error');
    }
    return exitCode == 0 ? 70 : exitCode;
  }

  return exitCode;
}

/// 本体。解放は呼び出し元の finally が受け持つ。
Future<int> _run({
  required VmServiceClient vmService,
  required FlutterSdk sdk,
  required FluseLogger logger,
  required String projectRoot,
  required Directory cache,
  required bool useFilesystemScheme,
  required String? assetPath,
  required void Function(CompilerService) onCompiler,
  required void Function(DevFSClient) onDevFS,
  required int cycles,
  required int warmup,
  required String? reportPath,
}) async {
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
  onCompiler(compiler);
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
    return 1;
  }

  final File? compiledDill = first.incrementalDill;
  if (compiledDill == null) {
    // エラーが無いのに出力が無いのは応答が壊れている。黙って先へ進むと
    // 「転送するものが無いのに成功」に見えてしまう。
    stderr.writeln('  コンパイルは成功したが dill が出力されていません');
    return 1;
  }
  stdout.writeln('== DevFS を作成 ==');
  final DevFSClient devFS = DevFSClient(vmService: vmService, logger: logger);
  onDevFS(devFS);
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
  final File fullDill = compiledDill;
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
    return 1;
  }
  compiler.accept();

  // 変更 asset。`--asset <プロジェクト相対パス>` で指定する。
  // DevFS 上の置き場所は flutter_tools と同じ `build/flutter_assets/` 配下、
  // evict に渡すのは asset マニフェスト上のパス（`assets/...`）。
  const String assetSubdir = 'build/flutter_assets';
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
    final List<({String viewId, String? isolateId})> views = await vmService
        .listViews();
    if (views.isEmpty) {
      // View が無いと asset ディレクトリを登録できない。そのまま進むと
      // 「成功したのに画像だけ古いまま」という分かりにくい結果になる。
      stderr.writeln('  Flutter View が1つも見つかりません。asset は反映できません');
      return 1;
    }
    for (final ({String viewId, String? isolateId}) view in views) {
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
  final TimingReport report = TimingReport();
  final File mainFile = File(p.join(projectRoot, 'lib', 'main.dart'));
  HotReloadResult? last;

  // **1回では測れない。** 初回は VM 側のキャッシュが冷えていて他より
  // 遅く、1回だけ見ると実態より悪い数字になる。捨てる回数を分けて数える。
  for (int i = 0; i < warmup + cycles; i++) {
    final bool measured = i >= warmup;
    if (i > 0) {
      // **毎回中身を変える。** 同じ内容だと差分が空になり、
      // 「速い」のではなく「何もしていない」時間を測ることになる。
      mainFile.writeAsStringSync(
        '${mainFile.readAsStringSync()}\n// fluse spike $i\n',
      );
    }

    final Stopwatch cycle = Stopwatch()..start();
    final HotReloadResult result = await orchestrator.reload(
      invalidated: <Uri>[mainUri],
      // asset は初回だけ送る。毎回同じ内容を送っても差分にならない。
      changedAssets: i == 0 ? changedAssets : const <ChangedAsset>[],
    );
    cycle.stop();
    last = result;

    stdout.writeln(
      '  [${i + 1}/${warmup + cycles}]'
      '${measured ? '' : '（捨てる）'} '
      'status=${result.status} timings=${result.timings} '
      'total=${cycle.elapsedMilliseconds}ms',
    );
    for (final String notice in result.notices) {
      stdout.writeln('  notice: $notice');
    }
    for (final DiagnosticEntry d in result.diagnostics) {
      stdout.writeln('  ${d.raw}');
    }
    if (!result.isSuccess) {
      // **測り続けない。** 失敗したサイクルの時間には意味が無い。
      return 1;
    }
    if (measured) {
      report.add(result.timings);
    }
  }

  if (report.cycles > 0) {
    stdout.writeln();
    stdout.writeln(report.render());
    if (reportPath != null) {
      File(reportPath).writeAsStringSync('${report.toJsonString()}\n');
      stdout.writeln('  レポート: $reportPath');
    }
  }

  return last != null && last.isSuccess ? 0 : 1;
}

/// `--asset` をプロジェクト配下の相対パスに限定する。
///
/// 絶対パスや `..` をそのまま受け取ると、プロジェクト外のファイルを
/// 端末へ送れてしまう。
String? _validateAssetPath(String? assetPath, String projectRoot) {
  if (assetPath == null) {
    return null;
  }
  if (p.isAbsolute(assetPath)) {
    throw ArgumentError.value(assetPath, '--asset', 'プロジェクト相対で指定してください');
  }

  final String candidate = p.normalize(p.join(projectRoot, assetPath));
  final File file = File(candidate);
  if (!file.existsSync()) {
    throw ArgumentError.value(assetPath, '--asset', 'ファイルがありません: $candidate');
  }

  // **シンボリックリンクを解決してから包含関係を見る。** パス文字列だけの
  // 判定では、プロジェクト内に置かれた外部を指すリンクを通してしまう。
  final String resolvedRoot = Directory(projectRoot).resolveSymbolicLinksSync();
  final String resolvedFile = file.resolveSymbolicLinksSync();
  if (!p.isWithin(resolvedRoot, resolvedFile)) {
    throw ArgumentError.value(
      assetPath,
      '--asset',
      'プロジェクト外は指定できません: $resolvedFile',
    );
  }

  // 呼び出し側は `File(p.join(projectRoot, assetPath))` で開くので、
  // 元の projectRoot からの相対で返す。
  return p.relative(candidate, from: projectRoot);
}

/// 0 以上の整数として読む。読めなければ投げる。
///
/// **黙って既定値へ倒さない。** `--cycles abc` を1回として扱うと、
/// 20回測ったつもりの数字が1回分になる。
int _positiveInt(String? raw, String name, int fallback) {
  if (raw == null) {
    return fallback;
  }
  final int? parsed = int.tryParse(raw);
  if (parsed == null || parsed < 0) {
    throw ArgumentError.value(raw, '--$name', '0 以上の整数で指定してください');
  }
  return parsed;
}

/// 解放処理を、失敗しても他の解放を止めないように包む。
Future<List<String>> _release(
  String what,
  FutureOr<void> Function() action,
) async {
  try {
    await action();
    return const <String>[];
  } on Object catch (error) {
    return <String>['$what に失敗しました: $error'];
  }
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
