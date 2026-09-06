import 'dart:io';

import 'package:fluse_builder/fluse_builder.dart';
import 'package:fluse_cli/fluse_cli.dart';
import 'package:fluse_server/fluse_server.dart';

/// `fluse` の入口。
///
/// **ここでは何も決めない。** 解析と振り分けは [FluseCommandRunner]、
/// 実際の処理は各コマンドが持つ。
Future<void> main(List<String> arguments) async {
  final FluseCommandRunner runner = FluseCommandRunner(
    version: fluseVersion,
    commands: <FluseCommand>[
      InitCommand(),
      StartCommand(),
      RebuildCommand(),
      DoctorCommand(),
      DevicesCommand(),
    ],
  );

  final int code;
  try {
    code = await runner.run(arguments, contextFor: buildContext);
  } on Object catch (error) {
    // **握り潰さない。** 何が起きたか分からないまま 0 で終わらせない。
    stderr.writeln('$error');
    exit(FluseCommandRunner.failureExitCode);
  }
  exit(code);
}

/// この版。`--version` に出す。
const String fluseVersion = '0.1.0';

/// コマンドに渡すものを揃える。
///
/// SDK の解決も設定の読み込みも失敗しうる。**コマンドが決まってから**
/// 行うことで、`--version` や `--help` が環境に左右されないようにする。
Future<FluseContext> buildContext(
  FluseCommand command,
  FluseGlobalOptions options,
) async {
  final Directory projectRoot = Directory.current;
  final FluseConfig config = FluseConfig.resolve(projectRoot: projectRoot);
  // **ファイルには常に残す。** 後から「あのとき何が起きたか」を追う
  // のがログの主目的で、コンソールへの表示は副次的（設計 §5.2）。
  final FluseLogger logger = openProjectLogger(
    projectRoot: projectRoot.path,
    verbose: options.verbose,
  );

  final FlutterSdk sdk;
  try {
    // **指定された場所を使う。** 受け取っておきながら PATH の SDK で
    // ビルドすると、版が違う理由に辿り着けない。
    sdk = await FlutterSdk.resolve(explicitRoot: options.flutterSdk);
  } on SdkNotFoundException catch (error) {
    // **`doctor` だけは続ける。** 環境を調べに来た人に「環境が整って
    // いないので調べられません」と返すのでは、何を直せばよいか分からない。
    // 他のコマンドはこれまで通り、SDK を使う所で同じ例外が出る。
    if (command is! DoctorCommand) {
      rethrow;
    }
    return FluseContext.withoutSdk(
      projectRoot: projectRoot,
      config: config,
      sdkError: error,
      logger: logger,
    );
  }

  return FluseContext.of(
    projectRoot: projectRoot,
    config: config,
    sdk: sdk,
    logger: logger,
  );
}
