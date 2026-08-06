@Timeout(Duration(minutes: 10))
library;

import 'dart:io';

import 'package:fluse_builder/fluse_builder.dart';
import 'package:fluse_server/fluse_server.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 実 `frontend_server` に対する統合テスト（Task 1.2 の完了条件）。
///
/// `examples/counter_app` を compile し、意図的な構文エラーを入れて
/// recompile したときに `errorCount` と診断内容が期待通りになることを見る。
///
/// Flutter SDK か `examples/counter_app` の依存解決が無い環境では
/// スキップする。
void main() {
  late Directory temp;
  late String projectRoot;
  CompilerService? service;
  FlutterSdk? sdk;
  SdkNotFoundException? sdkError;

  /// リポジトリ内の `examples/counter_app`。
  ///
  /// テストは `packages/fluse_server` を作業ディレクトリとして走る。
  final String sampleApp = p.normalize(
    p.join(Directory.current.path, '..', '..', 'examples', 'counter_app'),
  );

  /// `examples/counter_app` の解決済み依存をそのまま使える形で複製する。
  ///
  /// `package_config.json` 内の自パッケージは `rootUri: "../"`（`.dart_tool`
  /// からの相対）で、他パッケージは pub キャッシュへの絶対 URI なので、
  /// `lib` / `pubspec.yaml` / `.dart_tool/package_config.json` を写すだけで
  /// そのまま解決できる。**元のプロジェクトには一切書き込まない。**
  void copySampleApp() {
    Directory(p.join(projectRoot, '.dart_tool')).createSync(recursive: true);
    File(
      p.join(sampleApp, '.dart_tool', 'package_config.json'),
    ).copySync(p.join(projectRoot, '.dart_tool', 'package_config.json'));
    File(
      p.join(sampleApp, 'pubspec.yaml'),
    ).copySync(p.join(projectRoot, 'pubspec.yaml'));

    final Directory libSource = Directory(p.join(sampleApp, 'lib'));
    for (final FileSystemEntity entity in libSource.listSync(recursive: true)) {
      if (entity is! File) {
        continue;
      }
      final String relative = p.relative(entity.path, from: sampleApp);
      final File destination = File(p.join(projectRoot, relative))
        ..parent.createSync(recursive: true);
      entity.copySync(destination.path);
    }
  }

  setUpAll(() async {
    try {
      sdk = await FlutterSdk.resolve();
    } on SdkNotFoundException catch (error) {
      // setUpAll ではスキップできないため、各テストで判定する。
      sdkError = error;
    }
  });

  setUp(() {
    service = null;
    temp = Directory.systemTemp.createTempSync('fluse_compile_integration.');
    projectRoot = p.join(temp.path, 'counter_app');
    Directory(projectRoot).createSync(recursive: true);
  });

  tearDown(() async {
    try {
      // shutdown が失敗しても一時ディレクトリは必ず消す。
      // dill を含むので放置すると数十MB残る。
      await service?.shutdown();
    } finally {
      temp.deleteSync(recursive: true);
    }
  });

  /// 前提が揃っていなければスキップする。揃っていれば解決済みの SDK。
  FlutterSdk? ensurePrerequisites() {
    final SdkNotFoundException? error = sdkError;
    if (error != null) {
      markTestSkipped('Flutter SDK を解決できないためスキップ: ${error.reason}');
      return null;
    }
    if (!File(
      p.join(sampleApp, '.dart_tool', 'package_config.json'),
    ).existsSync()) {
      markTestSkipped(
        'examples/counter_app の依存が未解決のためスキップ'
        '（flutter pub get を実行してください）',
      );
      return null;
    }
    return sdk;
  }

  Uri mainUri() => Uri.file(p.join(projectRoot, 'lib', 'main.dart'));

  CompilerService buildService(FlutterSdk sdk) => CompilerService(
    dartAotRuntime: sdk.dartAotRuntime,
    frontendServerSnapshot: sdk.frontendServerSnapshot,
    patchedSdkRoot: sdk.patchedSdkRoot,
    projectRoot: projectRoot,
    outputDill: p.join(temp.path, 'cache', 'app.dill'),
    packagesPath: p.join(projectRoot, '.dart_tool', 'package_config.json'),
  );

  test('counter_app を compile → 構文エラーで recompile → 復旧できる', () async {
    final FlutterSdk? resolved = ensurePrerequisites();
    if (resolved == null) {
      return;
    }

    copySampleApp();
    final CompilerService compiler = buildService(resolved);
    service = compiler;
    await compiler.start();

    // --- 1. 初回コンパイルはエラー0で dill が出る -------------------------
    final CompileOutput first = await compiler.compile(mainUri());

    expect(
      first.errorCount,
      0,
      reason:
          '素の counter_app はエラー無しでコンパイルできるはず:\n'
          '${first.diagnostics.map((DiagnosticEntry d) => d.raw).join('\n')}',
    );
    expect(first.incrementalDill, isNotNull);
    expect(first.incrementalDill?.existsSync(), isTrue);
    expect(
      first.sources.map((Uri u) => u.toString()),
      contains(contains('main.dart')),
    );
    compiler.accept();

    // --- 2. 構文エラーを入れて recompile ---------------------------------
    final File mainFile = File(p.join(projectRoot, 'lib', 'main.dart'));
    final String original = mainFile.readAsStringSync();
    // セミコロンを落とすのではなく、確実にパースエラーになる行を足す。
    mainFile.writeAsStringSync('$original\nint broken = ;\n');

    final CompileOutput broken = await compiler.recompile(mainUri(), <Uri>[
      mainUri(),
    ]);

    expect(broken.errorCount, greaterThan(0));
    expect(broken.hasErrors, isTrue);
    expect(broken.diagnostics, isNotEmpty);
    expect(
      broken.diagnostics.map((DiagnosticEntry d) => d.file),
      anyElement(contains('main.dart')),
      reason: '診断が main.dart を指しているはず',
    );
    expect(
      broken.diagnostics.map((DiagnosticEntry d) => d.severity),
      contains(DiagnosticSeverity.error),
    );
    expect(
      broken.diagnostics
          .where((DiagnosticEntry d) => d.severity == DiagnosticSeverity.error)
          .map((DiagnosticEntry d) => d.line),
      everyElement(isNotNull),
      reason: 'エラー診断は行番号を持つはず',
    );

    // reload は失敗した扱いにする。accept を送ると差分が二度と来なくなる。
    await compiler.reject();

    // --- 3. 直してから recompile するとエラーが消える ---------------------
    mainFile.writeAsStringSync(original);
    final CompileOutput recovered = await compiler.recompile(mainUri(), <Uri>[
      mainUri(),
    ]);

    expect(
      recovered.errorCount,
      0,
      reason:
          '構文エラーを戻したのでエラーは消えるはず:\n'
          '${recovered.diagnostics.map((DiagnosticEntry d) => d.raw).join('\n')}',
    );
    expect(recovered.incrementalDill?.existsSync(), isTrue);
    compiler.accept();
  });
}
