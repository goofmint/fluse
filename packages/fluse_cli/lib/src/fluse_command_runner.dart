import 'dart:io';

import 'package:args/args.dart';

import 'fluse_command.dart';
import 'fluse_context.dart';

/// サブコマンドを振り分ける（設計 §2.2.4）。
///
/// **実行までは持たない。** どのコマンドを呼ぶかまでを決め、
/// `FluseContext` の組み立ては呼び出し側に委ねる。SDK の解決や設定の
/// 読み込みは失敗しうる処理で、その扱い方はコマンドごとに違う。
final class FluseCommandRunner {
  FluseCommandRunner({
    required this.version,
    List<FluseCommand> commands = const <FluseCommand>[],
  }) {
    _parser = buildRootParser();
    for (final FluseCommand command in commands) {
      register(command);
    }
  }

  /// 使い方が違う時の終了コード。
  ///
  /// `sysexits.h` の `EX_USAGE`。**1 と分けておく。** 呼び出し側の
  /// スクリプトが「使い方の誤り」と「実行時の失敗」を見分けられる。
  static const int usageExitCode = 64;

  /// 実行時に失敗した時の終了コード。
  static const int failureExitCode = 1;

  /// `fluse --version` で出す版。
  final String version;

  late final ArgParser _parser;

  final Map<String, FluseCommand> _commands = <String, FluseCommand>{};

  /// 登録済みのコマンド。
  Iterable<FluseCommand> get commands => _commands.values;

  ArgParser get parser => _parser;

  /// 全コマンドに共通のオプション（設計 §2.2.4）。
  static ArgParser buildRootParser() => ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false, help: '使い方を表示します。')
    ..addFlag('version', negatable: false, help: 'fluse の版を表示します。')
    ..addFlag(
      'verbose',
      abbr: 'v',
      negatable: false,
      help: '詳しいログをコンソールにも出します。',
    )
    ..addOption(
      'flutter-sdk',
      help: 'Flutter SDK の場所。省略すると FLUSE_FLUTTER_SDK と PATH を見ます。',
      valueHelp: 'path',
    );

  void register(FluseCommand command) {
    _commands[command.name] = command;
    _parser.addCommand(command.name, command.argParser);
  }

  /// [arguments] を解析して振り分ける。
  ///
  /// [contextFor] は選ばれたコマンドに渡す [FluseContext] を作る。
  /// **ここでは作らない。** SDK の解決も設定の読み込みも失敗しうるうえ、
  /// `doctor` のように失敗しても続けたいコマンドがある。
  ///
  /// [contextFor] には共通のオプション（[FluseGlobalOptions]）も渡す。
  /// **捨ててはいけない。** `--flutter-sdk` を解析だけして使わないと、
  /// 指定した SDK ではない方でビルドしてしまう。
  Future<int> run(
    List<String> arguments, {
    required Future<FluseContext> Function(
      FluseCommand command,
      FluseGlobalOptions options,
    )
    contextFor,
    void Function(String line) onOutput = print,
    void Function(String line) onError = _printError,
  }) async {
    final ArgResults results;
    try {
      results = _parser.parse(arguments);
    } on ArgParserException catch (error) {
      // **使い方を添える。** 何が違うのかだけでは直せない。
      onError(error.message);
      onError('');
      onError(usage());
      return usageExitCode;
    }

    if (results['version'] == true) {
      onOutput('fluse $version');
      return 0;
    }

    final ArgResults? sub = results.command;
    if (sub == null) {
      // 引数なしと `--help` は求められた表示。標準出力へ出して 0。
      if (arguments.isEmpty || results['help'] == true) {
        onOutput(usage());
        return 0;
      }
      // それ以外は使い方の誤り。**標準出力へ混ぜない。**
      onError('コマンドを指定してください');
      onError('');
      onError(usage());
      return usageExitCode;
    }

    final FluseCommand? command = _commands[sub.name];
    if (command == null) {
      // `addCommand` した名前しか来ないはずだが、取り違えを黙らせない。
      onError('知らないコマンドです: ${sub.name}');
      return usageExitCode;
    }

    // コマンド側が `help` を持たないこともある。無い名前を引くと投げる。
    if (sub.options.contains('help') && sub['help'] == true) {
      onOutput(usageOf(command));
      return 0;
    }

    return command.run(
      sub,
      await contextFor(command, FluseGlobalOptions.from(results)),
    );
  }

  /// 全体の使い方。
  String usage() {
    final StringBuffer buffer = StringBuffer()
      ..writeln('fluse $version')
      ..writeln()
      ..writeln('使い方: fluse <コマンド> [オプション]')
      ..writeln()
      ..writeln('コマンド:');
    for (final FluseCommand command in _commands.values) {
      buffer.writeln('  ${command.name.padRight(10)}${command.description}');
    }
    buffer
      ..writeln()
      ..writeln('共通のオプション:')
      ..writeln(_parser.usage);
    return buffer.toString();
  }

  /// 1つのコマンドの使い方。
  String usageOf(FluseCommand command) =>
      '''
fluse ${command.name} — ${command.description}

${command.argParser.usage}''';

  /// **標準出力へ混ぜない。** 失敗の知らせをパイプの先へ流すと、
  /// 出力を機械で読んでいる側が壊れる。
  static void _printError(String line) => stderr.writeln(line);
}

/// 全コマンドに共通のオプション（設計 §2.2.4）。
///
/// **解析しただけで終わらせない。** `--flutter-sdk` を受け取っておきながら
/// 使わないと、指定した SDK ではない方でビルドすることになる。
final class FluseGlobalOptions {
  const FluseGlobalOptions({this.flutterSdk, this.verbose = false});

  /// `--flutter-sdk`。指定が無ければ null。
  final String? flutterSdk;

  /// `--verbose`。
  final bool verbose;

  /// ルートの解析結果から取り出す。
  static FluseGlobalOptions from(ArgResults results) {
    final Object? sdk = results['flutter-sdk'];
    return FluseGlobalOptions(
      flutterSdk: sdk is String && sdk.isNotEmpty ? sdk : null,
      verbose: results['verbose'] == true,
    );
  }

  @override
  String toString() =>
      'FluseGlobalOptions(flutterSdk: $flutterSdk, verbose: $verbose)';
}
