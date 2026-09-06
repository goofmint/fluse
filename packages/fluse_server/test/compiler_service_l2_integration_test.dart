// **リテラルでなければならない。** `package:test` はこの注釈を実行前に
// 文字面から読むため、定数名を書くと "Expected a Duration" で読み込みに
// 失敗する。実 frontend_server を起動して Flutter のプロジェクトを読むので
// 10分取る。
@Timeout(Duration(minutes: 10))
library;

import 'dart:io';

import 'package:fluse_builder/fluse_builder.dart';
import 'package:fluse_server/fluse_server.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 実 `frontend_server` に対する L2 統合テスト（設計 §7.2、Task 6.1）。
///
/// 偽の `frontend_server` では、こちらの思い込みを検証しているだけになる。
/// **本物を起動して確かめる。** 見るのは3つ。
///
/// 1. compile → recompile で差分 dill が出ること
/// 2. 構文エラーの `errorCount` と診断の中身
/// 3. `accept` / `reject` の後の状態遷移
///
/// **3 で分かったこと。** `reject` は「次回また送る」を意味しない。
/// 差分に何が載るかは `recompile` の invalidate に入れたファイルで決まり、
/// `reject` はそのファイルの内容を最後に `accept` した状態へ戻すだけ。
/// つまり reload に失敗した変更は、呼び出し側が覚えておいて次回の
/// invalidate に入れ直さないと端末へ届かない（`HotReloadOrchestrator`
/// がその持ち越しを行う）。設計 §10-2 の「reject を送る」は必要では
/// あるが、それだけでは足りない。
///
/// dill の中身はバイト単位では比べない。同じ入力から同じバイト列が出る
/// ことはどこにも保証されていない。**目印を1つ埋めて、その目印が差分に
/// 入ったかを見る。** ただし `const` は参照側へ畳み込まれるため、目印は
/// 関数の中に置く。
///
/// Flutter SDK か `examples/counter_app` の依存解決が無い環境では
/// スキップする（CI では `l2-integration` ジョブが依存を解決して走らせる）。
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

  /// 差分に載っているファイル名。
  List<String> namesOf(CompileOutput output) =>
      output.sources.map((Uri u) => p.basename(u.path)).toList();

  /// 起動して初回コンパイルまで済ませる。
  Future<CompilerService> started(FlutterSdk sdk) async {
    copySampleApp();
    final CompilerService compiler = buildService(sdk);
    service = compiler;
    await compiler.start();
    return compiler;
  }

  test('compile → recompile で差分 dill が出る', () async {
    final FlutterSdk? resolved = ensurePrerequisites();
    if (resolved == null) {
      return;
    }
    final CompilerService compiler = await started(resolved);

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
    expect(namesOf(first), contains('main.dart'));
    compiler.accept();

    final File mainFile = File(p.join(projectRoot, 'lib', 'main.dart'));
    mainFile.writeAsStringSync(
      "${mainFile.readAsStringSync()}\nString fluseChanged() => '$_markerB';\n",
    );
    final CompileOutput second = await compiler.recompile(mainUri(), <Uri>[
      mainUri(),
    ]);

    expect(
      second.errorCount,
      0,
      reason: second.diagnostics.map((DiagnosticEntry d) => d.raw).join('\n'),
    );
    expect(second.incrementalDill?.existsSync(), isTrue);
    // **中身が入っていることまで見る。** 空の dill を送っても端末は
    // 何も変わらず、失敗として表に出ない。
    expect(second.incrementalDill?.lengthSync(), greaterThan(0));
    expect(dillHas(second, _markerB), isTrue);
    compiler.accept();
  });

  test('構文エラーは errorCount と診断で分かる', () async {
    final FlutterSdk? resolved = ensurePrerequisites();
    if (resolved == null) {
      return;
    }
    final CompilerService compiler = await started(resolved);

    await compiler.compile(mainUri());
    compiler.accept();

    final File mainFile = File(p.join(projectRoot, 'lib', 'main.dart'));
    // セミコロンを落とすのではなく、確実にパースエラーになる行を足す。
    mainFile.writeAsStringSync(
      '${mainFile.readAsStringSync()}\nint broken = ;\n',
    );

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

    // **accept も reject も送らない。** エラーのまま次へ進む経路は
    // 設計 §10-2 の通り、コンパイルが通ってから決める。
  });

  test('構文エラーから直せばエラーが消える', () async {
    final FlutterSdk? resolved = ensurePrerequisites();
    if (resolved == null) {
      return;
    }
    final CompilerService compiler = await started(resolved);

    await compiler.compile(mainUri());
    compiler.accept();

    final File mainFile = File(p.join(projectRoot, 'lib', 'main.dart'));
    final String original = mainFile.readAsStringSync();
    mainFile.writeAsStringSync('$original\nint broken = ;\n');
    final CompileOutput broken = await compiler.recompile(mainUri(), <Uri>[
      mainUri(),
    ]);
    expect(broken.hasErrors, isTrue);
    await compiler.reject();

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

  test('reject した差分は、もう一度 invalidate すれば届く', () async {
    final FlutterSdk? resolved = ensurePrerequisites();
    if (resolved == null) {
      return;
    }
    final CompilerService compiler = await started(resolved);
    final _TwoFiles files = _TwoFiles.create(projectRoot);

    await compiler.compile(mainUri());
    compiler.accept();

    // extra.dart だけを変えて差分を作り、reload が失敗した体で reject する。
    files.writeExtra(_markerA);
    final CompileOutput rejected = await compiler.recompile(mainUri(), <Uri>[
      files.extraUri,
    ]);
    expect(dillHas(rejected, _markerA), isTrue);
    await compiler.reject();

    // **ここが肝心。** reject しただけでは戻ってこない。次の recompile で
    // 同じファイルを invalidate に入れて初めて、差分が再び載る。
    final CompileOutput again = await compiler.recompile(mainUri(), <Uri>[
      files.extraUri,
    ]);

    expect(again.errorCount, 0);
    expect(
      dillHas(again, _markerA),
      isTrue,
      reason: 'reject した変更は、もう一度 invalidate すれば差分に載るはず',
    );
    compiler.accept();
  });

  test('reject しても invalidate を落とすと差分から消える', () async {
    final FlutterSdk? resolved = ensurePrerequisites();
    if (resolved == null) {
      return;
    }
    final CompilerService compiler = await started(resolved);
    final _TwoFiles files = _TwoFiles.create(projectRoot);

    await compiler.compile(mainUri());
    compiler.accept();

    files.writeExtra(_markerA);
    final CompileOutput rejected = await compiler.recompile(mainUri(), <Uri>[
      files.extraUri,
    ]);
    expect(dillHas(rejected, _markerA), isTrue);
    await compiler.reject();

    // 別のファイルだけを変えて送る。**呼び出し側が覚えていないと、
    // 先の変更は端末に届かないまま消える。**
    files.appendMain(_markerB);
    final CompileOutput next = await compiler.recompile(mainUri(), <Uri>[
      mainUri(),
    ]);

    expect(dillHas(next, _markerB), isTrue);
    expect(
      dillHas(next, _markerA),
      isFalse,
      reason:
          'reject は「次回また送る」を意味しない。差分に何が載るかは '
          'invalidate に入れたファイルで決まる。'
          'この性質に合わせて HotReloadOrchestrator が持ち越す',
    );
    compiler.accept();
  });

  test('accept 済みの変更は次の差分に載らない', () async {
    final FlutterSdk? resolved = ensurePrerequisites();
    if (resolved == null) {
      return;
    }
    final CompilerService compiler = await started(resolved);
    final _TwoFiles files = _TwoFiles.create(projectRoot);

    await compiler.compile(mainUri());
    compiler.accept();

    files.writeExtra(_markerA);
    final CompileOutput accepted = await compiler.recompile(mainUri(), <Uri>[
      files.extraUri,
    ]);
    expect(dillHas(accepted, _markerA), isTrue);
    compiler.accept();

    files.appendMain(_markerB);
    final CompileOutput next = await compiler.recompile(mainUri(), <Uri>[
      mainUri(),
    ]);

    expect(dillHas(next, _markerB), isTrue);
    expect(dillHas(next, _markerA), isFalse, reason: '受理済みの差分は再送されない');
    compiler.accept();
  });
}

/// 差分 dill の中に [marker] が入っているか。
///
/// **バイト単位で前回と比べない。** 同じ入力から同じバイト列が出ることは
/// どこにも保証されていない。文字列定数は kernel の文字列表にそのまま
/// 載るので、目印を1つ埋めておけば「その変更が差分に入ったか」を直接
/// 確かめられる。
bool dillHas(CompileOutput output, String marker) {
  final File? dill = output.incrementalDill;
  if (dill == null) {
    return false;
  }
  // 文字列表は UTF-8。ASCII の目印しか探さないので、この読み方で足りる。
  return String.fromCharCodes(dill.readAsBytesSync()).contains(marker);
}

const String _markerA = 'fluse-l2-marker-a';
const String _markerB = 'fluse-l2-marker-b';

/// `main.dart` と、そこから読む `extra.dart`。
///
/// **2つ要る。** 1ファイルだと「invalidate したから載った」のか
/// 「reject したから戻ってきた」のかを見分けられない。
final class _TwoFiles {
  _TwoFiles._(this.main, this.extra);

  final File main;
  final File extra;

  Uri get extraUri => Uri.file(extra.path);

  static _TwoFiles create(String projectRoot) {
    final File main = File(p.join(projectRoot, 'lib', 'main.dart'));
    final File extra = File(p.join(projectRoot, 'lib', 'extra.dart'));
    // **定数にしない。** const は参照側の library へ畳み込まれるため、
    // extra.dart が差分に載っていなくても目印が main.dart 側に現れる。
    extra.writeAsStringSync("String fluseExtra() => 'extra-0';\n");
    main.writeAsStringSync(
      "import 'extra.dart';\n"
      '${main.readAsStringSync()}\n'
      'String fluseUseExtra() => fluseExtra();\n',
    );
    return _TwoFiles._(main, extra);
  }

  void writeExtra(String marker) =>
      extra.writeAsStringSync("String fluseExtra() => '$marker';\n");

  void appendMain(String marker) => main.writeAsStringSync(
    "${main.readAsStringSync()}\nString fluseOther() => '$marker';\n",
  );
}
