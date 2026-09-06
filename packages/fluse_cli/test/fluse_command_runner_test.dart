import 'dart:io';

import 'package:args/args.dart';
import 'package:fluse_builder/fluse_builder.dart';
import 'package:fluse_cli/fluse_cli.dart';
import 'package:fluse_server/fluse_server.dart';
import 'package:test/test.dart';

void main() {
  late List<String> output;
  late List<String> errors;

  setUp(() {
    output = <String>[];
    errors = <String>[];
  });

  FluseContext context() => FluseContext.of(
    projectRoot: Directory.current,
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
  );

  /// 最後に渡された共通のオプション。
  FluseGlobalOptions? seen;

  Future<int> run(FluseCommandRunner runner, List<String> arguments) =>
      runner.run(
        arguments,
        contextFor: (FluseCommand _, FluseGlobalOptions options) async {
          seen = options;
          return context();
        },
        onOutput: output.add,
        onError: errors.add,
      );

  FluseCommandRunner runnerWith(List<FluseCommand> commands) =>
      FluseCommandRunner(version: '0.1.0', commands: commands);

  group('振り分け', () {
    test('登録したコマンドを呼ぶ', () async {
      final _Recording command = _Recording();

      final int code = await run(runnerWith(<FluseCommand>[command]), <String>[
        'demo',
      ]);

      expect(code, 0);
      expect(command.calls, 1);
    });

    test('コマンドの終了コードをそのまま返す', () async {
      // 呼び出し側のスクリプトが失敗を見分けられるようにする。
      final _Recording command = _Recording(exitCode: 3);

      expect(
        await run(runnerWith(<FluseCommand>[command]), <String>['demo']),
        3,
      );
    });

    test('コマンド固有のオプションを渡す', () async {
      final _Recording command = _Recording();

      await run(runnerWith(<FluseCommand>[command]), <String>[
        'demo',
        '--target',
        'lib/other.dart',
      ]);

      expect(command.lastArgs?['target'], 'lib/other.dart');
    });

    test('--flutter-sdk を文脈の組み立てまで渡す', () async {
      // 受け取っておきながら PATH の SDK でビルドすると、版が違う理由に
      // 辿り着けない。
      await run(runnerWith(<FluseCommand>[_Recording()]), <String>[
        '--flutter-sdk',
        '/opt/other-flutter',
        'demo',
      ]);

      expect(seen?.flutterSdk, '/opt/other-flutter');
    });

    test('--verbose も渡す', () async {
      await run(runnerWith(<FluseCommand>[_Recording()]), <String>[
        '--verbose',
        'demo',
      ]);

      expect(seen?.verbose, isTrue);
    });

    test('指定が無ければ null', () async {
      await run(runnerWith(<FluseCommand>[_Recording()]), <String>['demo']);

      expect(seen?.flutterSdk, isNull);
      expect(seen?.verbose, isFalse);
    });

    test('文脈はコマンドが決まってから作る', () async {
      // SDK の解決も設定の読み込みも失敗しうる。使わないなら触らない。
      final FluseCommandRunner runner = runnerWith(<FluseCommand>[]);
      bool built = false;

      await runner.run(
        <String>['--version'],
        contextFor: (FluseCommand _, FluseGlobalOptions _) async {
          built = true;
          return context();
        },
        onOutput: output.add,
        onError: errors.add,
      );

      expect(built, isFalse);
    });
  });

  group('使い方', () {
    test('引数なしなら使い方を出して 0', () async {
      final int code = await run(
        runnerWith(<FluseCommand>[_Recording()]),
        <String>[],
      );

      expect(code, 0);
      expect(output.join('\n'), contains('使い方: fluse'));
      expect(output.join('\n'), contains('demo'));
    });

    test('--help でも使い方', () async {
      expect(await run(runnerWith(<FluseCommand>[]), <String>['--help']), 0);
      expect(output.join('\n'), contains('使い方: fluse'));
    });

    test('--version で版を出す', () async {
      expect(await run(runnerWith(<FluseCommand>[]), <String>['--version']), 0);
      expect(output.join('\n'), contains('fluse 0.1.0'));
    });

    test('コマンドの --help はそのコマンドの使い方', () async {
      final int code = await run(
        runnerWith(<FluseCommand>[_Recording()]),
        <String>['demo', '--help'],
      );

      expect(code, 0);
      expect(output.join('\n'), contains('fluse demo'));
      expect(output.join('\n'), contains('--target'));
    });
  });

  group('使い方の誤り', () {
    test('知らないオプションは 64 で終わる', () async {
      // 実行時の失敗（1）と分けておくと、スクリプトが見分けられる。
      final int code = await run(runnerWith(<FluseCommand>[]), <String>[
        '--unknown-option',
      ]);

      expect(code, FluseCommandRunner.usageExitCode);
    });

    test('何が違うかと使い方の両方を出す', () async {
      // 何が違うかだけでは直せない。
      await run(runnerWith(<FluseCommand>[_Recording()]), <String>[
        '--unknown-option',
      ]);

      final String text = errors.join('\n');
      expect(text, contains('unknown-option'));
      expect(text, contains('使い方: fluse'));
    });

    test('知らないコマンドは 64 で終わる', () async {
      expect(
        await run(runnerWith(<FluseCommand>[]), <String>['ない']),
        FluseCommandRunner.usageExitCode,
      );
    });

    test('失敗の知らせを標準出力へ混ぜない', () async {
      // パイプの先で出力を機械で読んでいる側が壊れる。
      await run(runnerWith(<FluseCommand>[]), <String>['--unknown-option']);

      expect(output, isEmpty);
      expect(errors, isNotEmpty);
    });

    test('help を持たないコマンドでも落ちない', () async {
      // `--help` を定義していないコマンドがある。
      final _Recording bare = _Recording(withHelp: false);

      expect(await run(runnerWith(<FluseCommand>[bare]), <String>['demo']), 0);
    });
  });
}

/// 呼ばれたことを覚えるだけのコマンド。
final class _Recording implements FluseCommand {
  _Recording({this.exitCode = 0, bool withHelp = true})
    : argParser = ArgParser() {
    argParser.addOption('target', help: '対象のエントリポイント。');
    if (withHelp) {
      argParser.addFlag('help', abbr: 'h', negatable: false);
    }
  }

  final int exitCode;

  int calls = 0;
  ArgResults? lastArgs;

  @override
  String get name => 'demo';

  @override
  String get description => '試すためのコマンド。';

  @override
  final ArgParser argParser;

  @override
  Future<int> run(ArgResults args, FluseContext context) async {
    calls++;
    lastArgs = args;
    return exitCode;
  }
}
