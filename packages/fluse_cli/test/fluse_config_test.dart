import 'dart:io';

import 'package:fluse_cli/fluse_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('fluse_config_');
  });

  tearDown(() {
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  void writeConfig(String contents) {
    File(p.join(temp.path, FluseConfig.fileName)).writeAsStringSync(contents);
  }

  group('fluse.yaml の読み取り', () {
    test('設計 §9.2 のスキーマを読む', () {
      writeConfig('''
version: 1
port: 9000
target: lib/other.dart
applicationIdSuffix: .preview
dartDefines:
  - FOO=1
  - BAR=2
serveApk: false
''');

      final FluseConfig config = FluseConfig.readFrom(temp);

      expect(config.version, 1);
      expect(config.port, 9000);
      expect(config.target, 'lib/other.dart');
      expect(config.applicationIdSuffix, '.preview');
      expect(config.dartDefines, <String>['FOO=1', 'BAR=2']);
      expect(config.serveApk, isFalse);
    });

    test('無ければ既定値', () {
      // `fluse init` の前は存在しない。失敗ではない。
      final FluseConfig config = FluseConfig.readFrom(temp);

      expect(config.port, FluseConfig.defaultPort);
      expect(config.target, FluseConfig.defaultTarget);
      expect(config.applicationIdSuffix, isNull);
      expect(config.dartDefines, isEmpty);
      expect(config.serveApk, isTrue);
    });

    test('空のファイルも既定値', () {
      writeConfig('');

      expect(FluseConfig.readFrom(temp).port, FluseConfig.defaultPort);
    });

    test('書いていないキーは既定値', () {
      writeConfig('port: 9000\n');

      final FluseConfig config = FluseConfig.readFrom(temp);

      expect(config.port, 9000);
      expect(config.target, FluseConfig.defaultTarget);
    });

    test('applicationIdSuffix: null を読める', () {
      // 設計 §9.2 の既定の書き方。
      writeConfig('applicationIdSuffix: null\n');

      expect(FluseConfig.readFrom(temp).applicationIdSuffix, isNull);
    });

    test('型が違えば黙って倒さない', () {
      // 書いてあるのに読めないのは、書き手の意図が通っていない。
      writeConfig('port: "9000"\n');

      expect(
        () => FluseConfig.readFrom(temp),
        throwsA(
          isA<FluseConfigException>().having(
            (FluseConfigException e) => e.toString(),
            'toString',
            allOf(contains('port'), contains(FluseConfig.fileName)),
          ),
        ),
      );
    });

    test('dartDefines に文字列以外があれば弾く', () {
      writeConfig('dartDefines:\n  - FOO=1\n  - 42\n');

      expect(
        () => FluseConfig.readFrom(temp),
        throwsA(isA<FluseConfigException>()),
      );
    });

    test('壊れた YAML は理由を添えて弾く', () {
      writeConfig('port: [壊れている\n');

      expect(
        () => FluseConfig.readFrom(temp),
        throwsA(isA<FluseConfigException>()),
      );
    });

    test('知らない version は読めたことにしない', () {
      // 見落としたキーがあるまま動くと、書いた設定が効かない理由が
      // 分からなくなる。
      writeConfig('version: ${FluseConfig.currentVersion + 1}\n');

      expect(
        () => FluseConfig.readFrom(temp),
        throwsA(
          isA<FluseConfigException>().having(
            (FluseConfigException e) => e.toString(),
            'toString',
            contains('fluse を更新'),
          ),
        ),
      );
    });
  });

  group('優先順位（完了条件）', () {
    // CLI引数 > 環境変数 > fluse.yaml > 既定値
    const int fromArgument = 1111;
    const int fromEnvironment = 2222;
    const int fromFile = 3333;

    FluseConfig resolve({
      int? argument,
      String? environment,
      bool withFile = false,
    }) {
      if (withFile) {
        writeConfig('port: $fromFile\n');
      }
      final Map<String, String> env = <String, String>{};
      if (environment != null) {
        env[FluseConfig.portVariable] = environment;
      }
      return FluseConfig.resolve(
        projectRoot: temp,
        portArgument: argument,
        environment: env,
      );
    }

    test('4つ揃えば CLI 引数', () {
      expect(
        resolve(
          argument: fromArgument,
          environment: '$fromEnvironment',
          withFile: true,
        ).port,
        fromArgument,
      );
    });

    test('引数が無ければ環境変数', () {
      expect(
        resolve(environment: '$fromEnvironment', withFile: true).port,
        fromEnvironment,
      );
    });

    test('環境変数も無ければ fluse.yaml', () {
      expect(resolve(withFile: true).port, fromFile);
    });

    test('どれも無ければ既定値', () {
      expect(resolve().port, FluseConfig.defaultPort);
    });

    test('引数と環境変数だけなら引数', () {
      expect(
        resolve(argument: fromArgument, environment: '$fromEnvironment').port,
        fromArgument,
      );
    });

    test('引数とファイルだけなら引数', () {
      expect(
        resolve(argument: fromArgument, withFile: true).port,
        fromArgument,
      );
    });

    test('環境変数とファイルだけなら環境変数', () {
      expect(
        resolve(environment: '$fromEnvironment', withFile: true).port,
        fromEnvironment,
      );
    });

    test('引数だけなら引数', () {
      expect(resolve(argument: fromArgument).port, fromArgument);
    });

    test('環境変数だけなら環境変数', () {
      expect(resolve(environment: '$fromEnvironment').port, fromEnvironment);
    });

    test('ファイルだけならファイル', () {
      expect(resolve(withFile: true).port, fromFile);
    });

    test('空の環境変数は指定なし', () {
      // `FLUSE_PORT=` を 0番ポートと読むと、意図しない場所で待ち受ける。
      expect(resolve(environment: '', withFile: true).port, fromFile);
      expect(resolve(environment: '   ', withFile: true).port, fromFile);
    });

    test('読めない環境変数は黙って倒さない', () {
      // 指定したのに効かない理由が分からなくなる。
      expect(
        () => resolve(environment: 'にせん'),
        throwsA(
          isA<FluseConfigException>().having(
            (FluseConfigException e) => e.toString(),
            'toString',
            contains(FluseConfig.portVariable),
          ),
        ),
      );
    });

    test('範囲の外の環境変数も弾く', () {
      expect(
        () => resolve(environment: '70000'),
        throwsA(
          isA<FluseConfigException>().having(
            (FluseConfigException e) => e.toString(),
            'toString',
            contains(FluseConfig.portVariable),
          ),
        ),
      );
    });

    test('fluse.yaml のポートも範囲を見る', () {
      // 片方だけ見ていると、bind の失敗として表面化して原因が分からない。
      writeConfig('port: 70000\n');

      expect(
        () => FluseConfig.readFrom(temp),
        throwsA(
          isA<FluseConfigException>().having(
            (FluseConfigException e) => e.toString(),
            'toString',
            contains('port'),
          ),
        ),
      );
    });

    test('引数のポートも範囲を見る', () {
      expect(
        () => resolve(argument: 70000),
        throwsA(isA<FluseConfigException>()),
      );
      expect(() => resolve(argument: -1), throwsA(isA<FluseConfigException>()));
    });

    test('失敗の文言に次の手を書く', () {
      // 何が違うかだけでは直せない。
      expect(
        () => resolve(environment: '70000'),
        throwsA(
          isA<FluseConfigException>().having(
            (FluseConfigException e) => e.toString(),
            'toString',
            allOf(contains(FluseConfig.fileName), contains('doctor')),
          ),
        ),
      );
    });

    test('target と serveApk も同じ順序で決まる', () {
      writeConfig('target: lib/from_file.dart\nserveApk: false\n');

      expect(
        FluseConfig.resolve(
          projectRoot: temp,
          environment: const <String, String>{},
        ).target,
        'lib/from_file.dart',
      );
      expect(
        FluseConfig.resolve(
          projectRoot: temp,
          targetArgument: 'lib/from_arg.dart',
          environment: const <String, String>{},
        ).target,
        'lib/from_arg.dart',
      );
      expect(
        FluseConfig.resolve(
          projectRoot: temp,
          serveApkArgument: true,
          environment: const <String, String>{},
        ).serveApk,
        isTrue,
      );
    });
  });

  group('書き込み', () {
    test('無ければ全項目を並べて作る', () async {
      final File file = File(p.join(temp.path, FluseConfig.fileName));

      await const FluseConfig().writeTo(file);

      final Object? document = loadYaml(file.readAsStringSync());
      final Map<Object?, Object?> map = document! as Map<Object?, Object?>;
      expect(map['version'], FluseConfig.currentVersion);
      expect(map['port'], FluseConfig.defaultPort);
      expect(map['target'], FluseConfig.defaultTarget);
      expect(map['applicationIdSuffix'], isNull);
      expect(map['dartDefines'], isEmpty);
      expect(map['serveApk'], isTrue);
    });

    test('書いたものを読み直せる', () async {
      final File file = File(p.join(temp.path, FluseConfig.fileName));

      await const FluseConfig(
        port: 9000,
        target: 'lib/other.dart',
        applicationIdSuffix: '.preview',
        dartDefines: <String>['FOO=1'],
        serveApk: false,
      ).writeTo(file);

      final FluseConfig read = FluseConfig.readFrom(temp);
      expect(read.port, 9000);
      expect(read.target, 'lib/other.dart');
      expect(read.applicationIdSuffix, '.preview');
      expect(read.dartDefines, <String>['FOO=1']);
      expect(read.serveApk, isFalse);
    });

    test('既にある内容とコメントを残す', () async {
      // 利用者が書いたものを組み直しで失わない（設計 §10-8）。
      writeConfig('''
# 開発チームで共有している設定。
port: 9000

# ここは触らないこと。
customKey: 残す
''');
      final File file = File(p.join(temp.path, FluseConfig.fileName));

      await const FluseConfig(port: 9500).writeTo(file);

      final String after = file.readAsStringSync();
      expect(after, contains('# 開発チームで共有している設定。'));
      expect(after, contains('# ここは触らないこと。'));
      expect(after, contains('customKey: 残す'));
      expect(FluseConfig.readFrom(temp).port, 9500);
    });

    test('一時ファイルを残さない', () async {
      final File file = File(p.join(temp.path, FluseConfig.fileName));

      await const FluseConfig().writeTo(file);

      expect(File('${file.path}.tmp').existsSync(), isFalse);
    });

    test('二度書いても壊れない', () async {
      final File file = File(p.join(temp.path, FluseConfig.fileName));

      await const FluseConfig(port: 9000).writeTo(file);
      await const FluseConfig(port: 9000).writeTo(file);

      expect(FluseConfig.readFrom(temp).port, 9000);
    });
  });
}
