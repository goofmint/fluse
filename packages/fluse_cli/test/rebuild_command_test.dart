import 'dart:io';

import 'package:fluse_builder/fluse_builder.dart';
import 'package:fluse_cli/fluse_cli.dart';
import 'package:fluse_server/fluse_server.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'steps.dart';

void main() {
  late Directory temp;
  late Steps steps;
  late List<String> output;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('fluse_rebuild_');
    steps = Steps(temp);
    output = <String>[];
    createProject(temp);
    // **`init` を通してから始める。** 指紋も keystore も APK も、
    // 前回のビルドが残した物を見て判断するコマンドのため。
    expect(await _runInit(temp, steps), 0);
    steps.order.clear();
  });

  tearDown(() {
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  FluseContext context() => FluseContext.of(
    projectRoot: temp,
    config: const FluseConfig(),
    sdk: _sdk,
    logger: FluseLogger(sinks: const <FluseLogSink>[]),
    processManager: steps,
  );

  Future<int> runRebuild({List<String> arguments = const <String>[]}) {
    final RebuildCommand command = RebuildCommand(
      keystoreManager: KeystoreManager(processManager: steps, isWindows: false),
      builderFactory: (FluseContext c) =>
          PreviewAppBuilder(sdk: c.sdk, processManager: steps),
      installerFactory: (FluseContext c) => DeviceInstaller(
        processManager: steps,
        onMessage: (String _) {},
        readLine: () => '3',
      ),
      onOutput: output.add,
    );
    return command.run(command.argParser.parse(arguments), context());
  }

  group('指紋', () {
    test('変わっていなければ作り直さない', () async {
      expect(await runRebuild(), 0);

      expect(steps.ran('build apk'), isFalse);
      expect(steps.ran('install'), isFalse);
      expect(output.join('\n'), contains('変わっていません'));
    });

    test('変われば作り直して入れ直す', () async {
      _touchManifest(temp);

      expect(await runRebuild(), 0);

      expect(steps.ran('build apk'), isTrue);
      expect(steps.ran('install'), isTrue);
      // 何が変わったかはキー名だけ。値にはパスが混ざる。
      expect(output.join('\n'), contains('android.manifest'));
    });

    test('--force なら変わっていなくても作り直す', () async {
      expect(await runRebuild(arguments: <String>['--force']), 0);

      expect(steps.ran('build apk'), isTrue);
      expect(steps.ran('install'), isTrue);
    });

    test('指紋を読めなければ「差分なし」にしない', () async {
      File(
        p.join(temp.path, '.flutter_preview', 'cache', 'fingerprint.json'),
      ).writeAsStringSync('{壊れている');

      expect(await runRebuild(), 1);

      expect(steps.ran('build apk'), isFalse);
      expect(output.join('\n'), contains('fingerprint.json'));
    });

    test('作り直したら指紋を更新する', () async {
      final File file = File(
        p.join(temp.path, '.flutter_preview', 'cache', 'fingerprint.json'),
      );
      final String before = file.readAsStringSync();

      _touchManifest(temp);
      expect(await runRebuild(), 0);

      expect(file.readAsStringSync(), isNot(before));
      // 続けて呼べば差分なしになる。
      steps.order.clear();
      expect(await runRebuild(), 0);
      expect(steps.ran('build apk'), isFalse);
    });

    test('ビルドに失敗したら指紋を残さない', () async {
      final File file = File(
        p.join(temp.path, '.flutter_preview', 'cache', 'fingerprint.json'),
      );
      final String before = file.readAsStringSync();

      _touchManifest(temp);
      steps.buildExitCode = 1;

      expect(await runRebuild(), 1);
      expect(file.readAsStringSync(), before);
    });
  });

  group('端末', () {
    test('複数あって --device が無ければ入れない', () async {
      steps.devices = <String>['AAA', 'BBB'];

      expect(await runRebuild(arguments: <String>['--force']), 1);

      expect(steps.ran('build apk'), isTrue);
      expect(steps.ran('install'), isFalse);
      expect(output.join('\n'), contains('--device'));
    });

    test('--device で選べる', () async {
      steps.devices = <String>['AAA', 'BBB'];

      expect(
        await runRebuild(arguments: <String>['--force', '--device', 'BBB']),
        0,
      );

      expect(steps.installedTo, 'BBB');
    });

    test('繋がっていなければ APK の場所を伝える', () async {
      steps.devices = <String>[];

      expect(await runRebuild(arguments: <String>['--force']), 1);

      expect(output.join('\n'), contains('preview.apk'));
    });
  });
}

const FlutterSdk _sdk = FlutterSdk(
  root: '/opt/flutter',
  version: '3.41.9',
  revision: 'aaaaaaaa',
  dartVersion: '3.11.5',
  engineDirectoryName: 'darwin-arm64',
  isWindows: false,
);

/// 指紋が動くように書き換える。
///
/// **Dart のソースでは動かない。** 差分は hot reload が運ぶもので、
/// 作り直す必要のあるものだけが指紋に入る（設計 §10-1）。
void _touchManifest(Directory root) => File(
  p.join(root.path, 'android', 'app', 'src', 'main', 'AndroidManifest.xml'),
).writeAsStringSync('<manifest><!-- 変えた --></manifest>\n');

Future<int> _runInit(Directory root, Steps steps) {
  final InitCommand init = InitCommand(
    keystoreManager: KeystoreManager(processManager: steps, isWindows: false),
    pubGetRunnerFactory: (FluseContext c) =>
        PubGetRunner(sdk: c.sdk, processManager: steps),
    builderFactory: (FluseContext c) =>
        PreviewAppBuilder(sdk: c.sdk, processManager: steps),
    installerFactory: (FluseContext c) => DeviceInstaller(
      processManager: steps,
      onMessage: (String _) {},
      readLine: () => '3',
    ),
  );
  return init.run(
    init.argParser.parse(const <String>[]),
    FluseContext.of(
      projectRoot: root,
      config: const FluseConfig(),
      sdk: _sdk,
      logger: FluseLogger(sinks: const <FluseLogSink>[]),
      processManager: steps,
    ),
  );
}
