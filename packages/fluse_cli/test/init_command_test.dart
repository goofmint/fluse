import 'dart:async';
import 'dart:io';

import 'package:fluse_builder/fluse_builder.dart';
import 'package:fluse_cli/fluse_cli.dart';
import 'package:fluse_server/fluse_server.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import 'steps.dart';

void main() {
  late Directory temp;
  late Steps steps;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('fluse_init_');
    steps = Steps(temp);
    createProject(temp);
  });

  tearDown(() {
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  FluseContext context() => FluseContext.of(
    projectRoot: temp,
    config: const FluseConfig(),
    sdk: const FlutterSdk(
      root: '/opt/flutter',
      version: '3.41.9',
      revision: 'aaaaaaaa',
      dartVersion: '3.11.5',
      engineDirectoryName: 'darwin-arm64',
      isWindows: false,
    ),
    logger: FluseLogger(sinks: const <FluseLogSink>[]),
    processManager: steps,
  );

  InitCommand command() => InitCommand(
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

  Future<int> runInit({List<String> arguments = const <String>[]}) {
    final InitCommand init = command();
    return init.run(init.argParser.parse(arguments), context());
  }

  group('一連の流れ', () {
    test('端末まで入って 0 で終わる（完了条件）', () async {
      expect(await runInit(), 0);

      // 6段すべてを通っていること。
      expect(steps.ran('pub get'), isTrue);
      expect(steps.ran('keytool'), isTrue);
      expect(steps.ran('build apk'), isTrue);
      expect(steps.ran('install'), isTrue);
    });

    test('生成物を残す', () async {
      await runInit();

      expect(
        File(
          p.join(temp.path, '.flutter_preview', 'fluse_main.dart'),
        ).existsSync(),
        isTrue,
      );
      expect(
        File(
          p.join(temp.path, '.flutter_preview', 'build', 'preview.apk'),
        ).existsSync(),
        isTrue,
      );
      expect(
        File(
          p.join(temp.path, '.flutter_preview', 'cache', 'build_meta.json'),
        ).existsSync(),
        isTrue,
      );
      expect(
        File(
          p.join(temp.path, '.flutter_preview', 'cache', 'fingerprint.json'),
        ).existsSync(),
        isTrue,
      );
    });

    test('指紋にビルドで使ったフラグを入れる', () async {
      // 1つでも違うと reloadSources が静かに失敗する（設計 §10-1）。
      await runInit();

      final Fingerprint fingerprint = await Fingerprint.readFrom(
        File(
          p.join(temp.path, '.flutter_preview', 'cache', 'fingerprint.json'),
        ),
      );
      expect(fingerprint.entries.keys.toSet(), Fingerprint.keys.toSet());
    });

    test('fluse.yaml に決まった値を残す', () async {
      await runInit(arguments: <String>['--target', 'lib/other.dart']);

      final Object? config = loadYaml(
        File(p.join(temp.path, 'fluse.yaml')).readAsStringSync(),
      );
      expect((config! as Map<Object?, Object?>)['target'], 'lib/other.dart');
    });

    test('pub get はエントリポイントを作った後に回す', () async {
      // 先に回すと、足した fluse_runtime が
      // .flutter-plugins-dependencies に載らない。
      await runInit();

      final int generated = steps.order.indexOf('entrypoint');
      final int pubGet = steps.order.indexOf('pub get');
      expect(generated, greaterThanOrEqualTo(0));
      expect(pubGet, greaterThan(generated));
    });
  });

  group('引数', () {
    test('--target が fluse.yaml より優先される', () async {
      File(
        p.join(temp.path, 'fluse.yaml'),
      ).writeAsStringSync('target: lib/from_file.dart\n');

      await runInit(arguments: <String>['--target', 'lib/from_arg.dart']);

      final String source = File(
        p.join(temp.path, '.flutter_preview', 'fluse_main.dart'),
      ).readAsStringSync();
      expect(source, contains('from_arg.dart'));
    });

    test('--device で端末を選ぶ', () async {
      steps.devices = <String>['AAA', 'BBB'];

      expect(await runInit(arguments: <String>['--device', 'BBB']), 0);
      expect(steps.installedTo, 'BBB');
    });

    test('端末が複数で --device が無ければ選ばない', () async {
      // 勝手に選ぶと、別の端末を書き換えることになる。
      steps.devices = <String>['AAA', 'BBB'];

      expect(await runInit(), 1);
      expect(steps.installedTo, isNull);
    });

    test('知らない端末を指定したら弾く', () async {
      steps.devices = <String>['AAA'];

      expect(await runInit(arguments: <String>['--device', 'ZZZ']), 1);
      expect(steps.installedTo, isNull);
    });
  });

  group('失敗', () {
    test('Flutter プロジェクトでなければ 1 で終わる', () async {
      File(p.join(temp.path, 'pubspec.yaml')).writeAsStringSync('name: x\n');

      expect(await runInit(), 1);
      // 先の段まで進まない。
      expect(steps.ran('build apk'), isFalse);
    });

    test('pub get が失敗したらビルドへ進まない', () async {
      steps.pubGetExitCode = 1;

      expect(await runInit(), 1);
      expect(steps.ran('build apk'), isFalse);
    });

    test('ビルドが失敗したら指紋を残さない', () async {
      // 失敗したビルドの指紋を残すと、次回に「変わっていない」と判じて
      // 作り直さなくなる。
      steps.buildExitCode = 1;

      expect(await runInit(), 1);
      expect(
        File(
          p.join(temp.path, '.flutter_preview', 'cache', 'fingerprint.json'),
        ).existsSync(),
        isFalse,
      );
    });

    test('端末が無ければ APK の場所を示して 1', () async {
      // APK は出来ている。手で入れる道がある。
      steps.devices = <String>[];

      expect(await runInit(), 1);
      expect(
        File(
          p.join(temp.path, '.flutter_preview', 'build', 'preview.apk'),
        ).existsSync(),
        isTrue,
      );
    });

    test('署名がぶつかって中止したら 1', () async {
      steps.conflict = true;

      expect(await runInit(), 1);
    });
  });
}

/// 最小の Flutter プロジェクト。
