import 'dart:io';

import 'package:fluse_builder/fluse_builder.dart';
import 'package:fluse_server/fluse_server.dart';
import 'package:path/path.dart' as p;

import 'fluse_config.dart';

/// 全てのコマンドが共有するもの（設計 §4.1）。
///
/// **ここを唯一の差し込み口にする。** 外部プロセスもログも、コマンドが
/// 個別に作ると、テストで差し替える場所が散らばる。
final class FluseContext {
  const FluseContext({
    required this.projectRoot,
    required this.previewDir,
    required this.config,
    required this.sdk,
    required this.logger,
    this.processManager = const LocalProcessManager(),
  });

  /// 作業場所の名前（設計 §9.2）。
  static const String previewDirName = '.flutter_preview';

  /// 解析済みのプロジェクトルート。
  final Directory projectRoot;

  /// `.flutter_preview/`。生成物と資格情報の置き場。
  final Directory previewDir;

  /// 畳んだ設定。
  final FluseConfig config;

  /// 解決済みの Flutter SDK。
  final FlutterSdk sdk;

  /// 構造化ログ。**print を使わない。**
  final FluseLogger logger;

  /// 外部プロセスの実行。テストから差し替える。
  final ProcessManager processManager;

  /// [projectRoot] から組み立てる。
  static FluseContext of({
    required Directory projectRoot,
    required FluseConfig config,
    required FlutterSdk sdk,
    required FluseLogger logger,
    ProcessManager processManager = const LocalProcessManager(),
  }) => FluseContext(
    projectRoot: projectRoot,
    previewDir: Directory(p.join(projectRoot.path, previewDirName)),
    config: config,
    sdk: sdk,
    logger: logger,
    processManager: processManager,
  );

  @override
  String toString() => 'FluseContext(${projectRoot.path})';
}
