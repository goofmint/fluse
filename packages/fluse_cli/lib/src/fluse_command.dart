import 'package:args/args.dart';

import 'fluse_context.dart';

/// `fluse` のサブコマンド1つ（設計 §4.1）。
///
/// **`package:args` の `Command` は使わない。** あちらは実行の入口も
/// 抱えるため、`FluseContext` を渡す口が無い。解析だけを借りる。
abstract interface class FluseCommand {
  /// `fluse <name>` の名前。
  String get name;

  /// 一覧に出す1行説明。
  String get description;

  /// このコマンドが取るオプション。
  ArgParser get argParser;

  /// 実行する。返す値がプロセスの終了コードになる。
  Future<int> run(ArgResults args, FluseContext context);
}
