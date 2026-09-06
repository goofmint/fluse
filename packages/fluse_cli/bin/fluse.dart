import 'dart:io';

import 'package:fluse_builder/fluse_builder.dart';
import 'package:fluse_cli/fluse_cli.dart';
import 'package:fluse_server/fluse_server.dart';

/// `fluse` の入口。
///
/// **ここでは何も決めない。** 解析と振り分けは [FluseCommandRunner]、
/// 実際の処理は各コマンドが持つ。rebuild / doctor / devices は Task 5.10。
Future<void> main(List<String> arguments) async {
  final FluseCommandRunner runner = FluseCommandRunner(
    version: fluseVersion,
    commands: <FluseCommand>[InitCommand(), StartCommand()],
  );

  final int code;
  try {
    code = await runner.run(
      arguments,
      contextFor: (FluseCommand command, FluseGlobalOptions options) =>
          buildContext(options),
    );
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
Future<FluseContext> buildContext(FluseGlobalOptions options) async {
  final Directory projectRoot = Directory.current;
  return FluseContext.of(
    projectRoot: projectRoot,
    config: FluseConfig.resolve(projectRoot: projectRoot),
    // **指定された場所を使う。** 受け取っておきながら PATH の SDK で
    // ビルドすると、版が違う理由に辿り着けない。
    sdk: await FlutterSdk.resolve(explicitRoot: options.flutterSdk),
    // **ファイルには常に残す。** 後から「あのとき何が起きたか」を追う
    // のがログの主目的で、コンソールへの表示は副次的（設計 §5.2）。
    logger: openProjectLogger(
      projectRoot: projectRoot.path,
      verbose: options.verbose,
    ),
  );
}
