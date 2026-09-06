import 'dart:io';

import 'package:fluse_builder/fluse_builder.dart';
import 'package:fluse_cli/fluse_cli.dart';
import 'package:fluse_server/fluse_server.dart';

/// `fluse` の入口。
///
/// **ここでは何も決めない。** 解析と振り分けは [FluseCommandRunner]、
/// 実際の処理は各コマンドが持つ。具体的なコマンドは Task 5.8 以降で足す。
Future<void> main(List<String> arguments) async {
  final FluseCommandRunner runner = FluseCommandRunner(version: fluseVersion);

  final bool verbose =
      arguments.contains('--verbose') || arguments.contains('-v');

  final int code;
  try {
    code = await runner.run(
      arguments,
      contextFor: (FluseCommand command) => buildContext(verbose: verbose),
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
Future<FluseContext> buildContext({required bool verbose}) async {
  final Directory projectRoot = Directory.current;
  return FluseContext.of(
    projectRoot: projectRoot,
    config: FluseConfig.resolve(projectRoot: projectRoot),
    sdk: await FlutterSdk.resolve(),
    // **ファイルには常に残す。** 後から「あのとき何が起きたか」を追う
    // のがログの主目的で、コンソールへの表示は副次的（設計 §5.2）。
    logger: openProjectLogger(projectRoot: projectRoot.path, verbose: verbose),
  );
}
