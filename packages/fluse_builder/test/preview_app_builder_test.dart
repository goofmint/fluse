import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:fluse_builder/fluse_builder.dart';
import 'package:path/path.dart' as p;
import 'package:process/process.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;

  /// テスト用の値。
  ///
  /// **リテラルで書かない。** ダミーであっても、資格情報の形をした
  /// 文字列がリポジトリに残ると本物と見分けが付かない。
  late String storePassword;
  late String keyPassword;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('fluse_builder_');
    storePassword = _secret();
    keyPassword = _secret();
  });

  tearDown(() {
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  /// `flutter build --verbose` が出す起動コマンドを模した1行。
  const String verboseLine =
      '[   +4 ms] executing: /opt/flutter/bin/cache/dart-sdk/bin/dartaotruntime '
      '/opt/flutter/bin/cache/artifacts/engine/darwin-arm64/'
      'frontend_server_aot.dart.snapshot --sdk-root /opt/flutter/x/ '
      '--incremental --target=flutter --track-widget-creation '
      '-DFLUTTER_VERSION=3.41.9 -Ddart.vm.product=false';

  ProjectInfo projectInfo() => ProjectInfo(
    root: temp.path,
    packageName: 'counter_app',
    applicationId: 'com.example.counter_app',
    defaultTarget: 'lib/main.dart',
  );

  KeystoreInfo keystoreInfo({String? keystorePath}) => KeystoreInfo(
    file: File(
      keystorePath ?? p.join(temp.path, 'keystore', 'fluse-debug.keystore'),
    ),
    alias: 'fluse-debug',
    storePassword: storePassword,
    keyPassword: keyPassword,
  );

  File entrypointFile() =>
      File(p.join(temp.path, '.flutter_preview', 'fluse_main.dart'));

  FlutterSdk sdk() => const FlutterSdk(
    root: '/opt/flutter',
    version: '3.41.9',
    revision: 'aaaaaaaa',
    dartVersion: '3.11.5',
    engineDirectoryName: 'darwin-arm64',
    isWindows: false,
  );

  /// `flutter build apk` が APK を置いたことにする。
  void createApk() {
    final File apk = File(
      p.join(temp.path, p.joinAll(PreviewAppBuilder.flutterApkPath)),
    );
    apk.parent.createSync(recursive: true);
    apk.writeAsStringSync('偽の APK');
  }

  Future<BuildResult> runBuild({
    required _Recorder recorder,
    String? applicationIdSuffix,
    BuildProgress? onProgress,
    Duration timeout = PreviewAppBuilder.defaultTimeout,
  }) =>
      PreviewAppBuilder(
        sdk: sdk(),
        processManager: recorder,
        timeout: timeout,
        onProgress: onProgress,
      ).build(
        project: projectInfo(),
        entrypoint: entrypointFile(),
        keystore: keystoreInfo(),
        applicationIdSuffix: applicationIdSuffix,
      );

  group('flutter の呼び方', () {
    test('CLI として呼ぶ', () async {
      // flutter_tools へ path 依存を張ると SDK の版に追従できなくなる。
      final _Recorder recorder = _Recorder(stdout: verboseLine)
        ..onStart = createApk;

      await runBuild(recorder: recorder);

      expect(recorder.command.first, '/opt/flutter/bin/flutter');
      expect(recorder.command, containsAllInOrder(<String>['build', 'apk']));
    });

    test('debug で verbose を付ける', () async {
      // verbose を外すと frontend_server のフラグを読み取れない。
      final _Recorder recorder = _Recorder(stdout: verboseLine)
        ..onStart = createApk;

      await runBuild(recorder: recorder);

      expect(recorder.command, contains('--debug'));
      expect(recorder.command, contains('--verbose'));
    });

    test('生成したエントリポイントを指す', () async {
      final _Recorder recorder = _Recorder(stdout: verboseLine)
        ..onStart = createApk;

      await runBuild(recorder: recorder);

      final int at = recorder.command.indexOf('--target');
      expect(at, greaterThan(0));
      expect(recorder.command[at + 1], entrypointFile().path);
    });

    test('filesystem-root は渡さない', () async {
      // package: URI で参照するため、multi-root と混ぜてはいけない。
      final _Recorder recorder = _Recorder(stdout: verboseLine)
        ..onStart = createApk;

      await runBuild(recorder: recorder);

      expect(recorder.command, isNot(contains('--filesystem-root')));
      expect(recorder.command, isNot(contains('--filesystem-scheme')));
    });

    test('プロジェクトルートで走らせる', () async {
      final _Recorder recorder = _Recorder(stdout: verboseLine)
        ..onStart = createApk;

      await runBuild(recorder: recorder);

      expect(recorder.workingDirectory, temp.path);
    });
  });

  group('applicationIdSuffix', () {
    test('頼まれても黙って無視しない', () async {
      // **flutter に applicationId を変える口が無い。** 無視すると、
      // 衝突を避けるために別 ID を頼んだのに同じ ID の APK が出来上がる。
      final _Recorder recorder = _Recorder(stdout: verboseLine)
        ..onStart = createApk;

      await expectLater(
        runBuild(recorder: recorder, applicationIdSuffix: '.preview'),
        throwsA(isA<PreviewAppBuildException>()),
      );
    });

    test('存在しないオプションを渡さない', () async {
      // flutter build apk に --application-id-suffix は無い。渡すと
      // 引数の解析で落ちる。
      final _Recorder recorder = _Recorder(stdout: verboseLine)
        ..onStart = createApk;

      await runBuild(recorder: recorder);

      expect(
        recorder.command.where(
          (String a) => a.contains('application-id-suffix'),
        ),
        isEmpty,
      );
    });

    test('計算した実効 ID は使える', () {
      // Task 5.6 が入れる／消すの判断に使う。
      expect(
        PreviewAppBuilder.effectiveApplicationId('com.example.app', '.preview'),
        'com.example.app.preview',
      );
    });

    test('指定が無ければ渡さない', () async {
      final _Recorder recorder = _Recorder(stdout: verboseLine)
        ..onStart = createApk;

      final BuildResult result = await runBuild(recorder: recorder);

      expect(
        recorder.command.where((String a) => a.startsWith('--application-id')),
        isEmpty,
      );
      expect(result.applicationId, 'com.example.counter_app');
    });

    test('空文字は指定なしと同じ', () {
      expect(
        PreviewAppBuilder.effectiveApplicationId('com.example.app', ''),
        'com.example.app',
      );
    });
  });

  group('署名の渡し方', () {
    test('Gradle のプロパティで渡す', () async {
      // key.properties を置くと利用者の Gradle を書き換えることになる。
      final _Recorder recorder = _Recorder(stdout: verboseLine)
        ..onStart = createApk;

      await runBuild(recorder: recorder);

      final String opts = recorder.environment!['GRADLE_OPTS']!;
      expect(opts, contains(PreviewAppBuilder.signingStoreFileProperty));
      expect(opts, contains(PreviewAppBuilder.signingStorePasswordProperty));
      expect(opts, contains(PreviewAppBuilder.signingKeyAliasProperty));
      expect(opts, contains(PreviewAppBuilder.signingKeyPasswordProperty));
    });

    test('android の中に何も置かない', () async {
      // 置くと android.gradle の指紋が動き、毎回作り直すことになる。
      final _Recorder recorder = _Recorder(stdout: verboseLine)
        ..onStart = createApk;

      await runBuild(recorder: recorder);

      expect(Directory(p.join(temp.path, 'android')).existsSync(), isFalse);
    });

    test('既にある GRADLE_OPTS を消さない', () {
      // 利用者がメモリ設定などを入れていることがある。
      final Map<String, String> environment =
          PreviewAppBuilder.signingEnvironment(
            keystore: keystoreInfo(),
            parent: <String, String>{'GRADLE_OPTS': '-Xmx4g'},
          );

      expect(environment['GRADLE_OPTS'], startsWith('-Xmx4g '));
      expect(
        environment['GRADLE_OPTS'],
        contains(PreviewAppBuilder.signingStoreFileProperty),
      );
    });

    test('他の環境変数を落とさない', () {
      // JAVA_HOME が消えると Gradle が動かない。
      final Map<String, String> environment =
          PreviewAppBuilder.signingEnvironment(
            keystore: keystoreInfo(),
            parent: <String, String>{'JAVA_HOME': '/opt/jdk'},
          );

      expect(environment['JAVA_HOME'], '/opt/jdk');
    });

    test('空白を含むパスでも1つの引数として渡る', () {
      // GRADLE_OPTS は Unix では xargs に、Windows ではコマンドラインへ
      // そのまま展開される。裸で置くとそこで割れて JVM が起動しない。
      final Map<String, String> environment =
          PreviewAppBuilder.signingEnvironment(
            keystore: keystoreInfo(
              keystorePath: '/Users/My Name/app/fluse-debug.keystore',
            ),
            parent: <String, String>{},
          );

      expect(
        environment['GRADLE_OPTS'],
        contains('="/Users/My Name/app/fluse-debug.keystore"'),
      );
    });

    test('keystore は絶対パスで渡す', () {
      // Gradle の作業ディレクトリは android/ になる。相対では届かない。
      final Map<String, String> environment =
          PreviewAppBuilder.signingEnvironment(
            keystore: keystoreInfo(),
            parent: <String, String>{},
          );

      expect(
        environment['GRADLE_OPTS'],
        contains(keystoreInfo().file.absolute.path),
      );
    });
  });

  group('パスワードを漏らさない', () {
    test('失敗の文言に載せない', () async {
      final _Recorder recorder = _Recorder(
        exitCode: 1,
        stdout:
            '-Dorg.gradle.project.'
            '${PreviewAppBuilder.signingStorePasswordProperty}'
            '="$storePassword"',
      );

      final Object error = await runBuild(recorder: recorder).then<Object>(
        (BuildResult _) => throw StateError('失敗するはず'),
        onError: (Object error) => error,
      );

      expect(error.toString().contains(storePassword), isFalse);
      expect(error.toString(), contains(PreviewAppBuilder.maskSuffixSample));
    });

    test('進み具合の通知にも載せない', () async {
      final List<String> lines = <String>[];
      final _Recorder recorder = _Recorder(
        stdout:
            '-Dorg.gradle.project.'
            '${PreviewAppBuilder.signingKeyPasswordProperty}="$keyPassword"\n'
            '$verboseLine',
      )..onStart = createApk;

      await runBuild(recorder: recorder, onProgress: lines.add);

      expect(lines.join('\n').contains(keyPassword), isFalse);
      expect(lines, isNotEmpty);
    });

    test('伏せるのは知っている秘密だけ', () {
      // 別名やパスまで伏せると、何が起きたか追えなくなる。
      final String masked = PreviewAppBuilder.maskSecrets(
        '-Dorg.gradle.project.${PreviewAppBuilder.signingKeyAliasProperty}'
        '="fluse-debug"',
        PreviewAppBuilder.secretsOf(keystoreInfo()),
      );

      expect(masked, contains('fluse-debug'));
    });

    test('空白を含むパスワードでも取りこぼさない', () {
      // 「= の後ろから空白まで」で探すと、後半が残る。
      const String withSpace = 'pass word with spaces';
      final String masked = PreviewAppBuilder.maskSecrets(
        'GRADLE_OPTS=...="$withSpace" のあと',
        <String>[withSpace],
      );

      expect(masked.contains(withSpace), isFalse);
    });

    test('書き方が変わっても値そのものを探す', () {
      // Gradle が別の形で書き戻すことがある。
      final String masked = PreviewAppBuilder.maskSecrets(
        'Gradle は $storePassword を受け取りました',
        PreviewAppBuilder.secretsOf(keystoreInfo()),
      );

      expect(masked.contains(storePassword), isFalse);
    });
  });

  group('build_meta', () {
    test('verbose からフラグを取り出して残す', () async {
      // 1つでも違うと reloadSources が静かに失敗する（設計 §10-1）。
      final _Recorder recorder = _Recorder(stdout: verboseLine)
        ..onStart = createApk;

      final BuildResult result = await runBuild(recorder: recorder);

      expect(result.buildMeta.trackWidgetCreation, isTrue);
      expect(result.buildMeta.dartDefines, contains('FLUTTER_VERSION=3.41.9'));

      final File written = File(
        p.join(
          temp.path,
          '.flutter_preview',
          PreviewAppBuilder.cacheDirName,
          PreviewAppBuilder.buildMetaName,
        ),
      );
      expect(written.existsSync(), isTrue);
      final Object? json = jsonDecode(written.readAsStringSync());
      expect((json! as Map<String, Object?>)['trackWidgetCreation'], isTrue);
    });

    test('読み取れなければ弾く', () async {
      // 推測で埋めると、画面が変わらない理由が分からなくなる。
      final _Recorder recorder = _Recorder(stdout: 'ビルドしました')
        ..onStart = createApk;

      await expectLater(
        runBuild(recorder: recorder),
        throwsA(isA<PreviewAppBuildException>()),
      );
    });
  });

  group('成果物', () {
    test('preview.apk へ置く', () async {
      final _Recorder recorder = _Recorder(stdout: verboseLine)
        ..onStart = createApk;

      final BuildResult result = await runBuild(recorder: recorder);

      expect(
        p.relative(result.apk.path, from: temp.path),
        p.join('.flutter_preview', 'build', 'preview.apk'),
      );
      expect(result.apk.existsSync(), isTrue);
    });

    test('作られていなければ弾く', () async {
      final _Recorder recorder = _Recorder(stdout: verboseLine);

      await expectLater(
        runBuild(recorder: recorder),
        throwsA(isA<PreviewAppBuildException>()),
      );
    });
  });

  group('失敗', () {
    test('終了コードが非ゼロなら弾く', () async {
      final _Recorder recorder = _Recorder(
        exitCode: 1,
        stdout: 'Gradle task assembleDebug failed',
      );

      await expectLater(
        runBuild(recorder: recorder),
        throwsA(
          isA<PreviewAppBuildException>().having(
            (PreviewAppBuildException e) => e.toString(),
            'toString',
            allOf(contains('assembleDebug'), contains('doctor')),
          ),
        ),
      );
    });

    test('起動できなければ弾く', () async {
      await expectLater(
        runBuild(recorder: _Recorder(failToStart: true)),
        throwsA(isA<PreviewAppBuildException>()),
      );
    });

    test('終わらなければ待ち続けない', () async {
      // Gradle のデーモンが固まると、待っていることにも気づけない。
      final _Recorder recorder = _Recorder(neverExits: true);

      await expectLater(
        runBuild(recorder: recorder, timeout: const Duration(milliseconds: 50)),
        throwsA(isA<PreviewAppBuildException>()),
      );
      expect(recorder.killed, isTrue);
    });
  });
}

/// `flutter` の代わりに答える [ProcessManager]。
final class _Recorder implements ProcessManager {
  _Recorder({
    this.exitCode = 0,
    this.stdout = '',
    this.failToStart = false,
    this.neverExits = false,
  });

  final int exitCode;
  final String stdout;
  final bool failToStart;
  final bool neverExits;

  /// 起動された時に呼ぶ。APK を置いたことにするために使う。
  void Function()? onStart;

  late List<String> command;
  String? workingDirectory;
  Map<String, String>? environment;
  bool killed = false;

  @override
  Future<Process> start(
    List<Object> command, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) async {
    if (failToStart) {
      throw ProcessException('flutter', const <String>[], '見つかりません');
    }
    this.command = command.map((Object e) => '$e').toList();
    this.workingDirectory = workingDirectory;
    this.environment = environment;
    onStart?.call();
    return _Process(stdout: stdout, exitCode: exitCode, neverExits: neverExits)
      ..onKill = () => killed = true;
  }

  @override
  bool canRun(Object? executable, {String? workingDirectory}) => !failToStart;

  @override
  Future<ProcessResult> run(
    List<Object> command, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    Encoding? stdoutEncoding = systemEncoding,
    Encoding? stderrEncoding = systemEncoding,
  }) => throw UnsupportedError('run は使わない');

  @override
  ProcessResult runSync(
    List<Object> command, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    Encoding? stdoutEncoding = systemEncoding,
    Encoding? stderrEncoding = systemEncoding,
  }) => throw UnsupportedError('runSync は使わない');

  @override
  bool killPid(int pid, [ProcessSignal signal = ProcessSignal.sigterm]) => true;
}

final class _Process implements Process {
  _Process({
    required String stdout,
    required int exitCode,
    required bool neverExits,
  }) : _stdout = stdout,
       _exit = neverExits
           ? Completer<int>()
           : (Completer<int>()..complete(exitCode));

  final String _stdout;
  final Completer<int> _exit;

  void Function()? onKill;

  @override
  Stream<List<int>> get stdout => Stream<List<int>>.value(utf8.encode(_stdout));

  @override
  Stream<List<int>> get stderr => const Stream<List<int>>.empty();

  @override
  IOSink get stdin => throw UnsupportedError('stdin は使わない');

  @override
  Future<int> get exitCode => _exit.future;

  @override
  int get pid => 4242;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    onKill?.call();
    if (!_exit.isCompleted) {
      _exit.complete(-1);
    }
    return true;
  }
}

/// テスト用の秘密。リテラルで書かず、実行のたびに作る。
String _secret() {
  final Random random = Random.secure();
  final List<int> bytes = List<int>.generate(
    16,
    (int _) => random.nextInt(256),
  );
  return base64Url.encode(bytes).replaceAll('=', '');
}
