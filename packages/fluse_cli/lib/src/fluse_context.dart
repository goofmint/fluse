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
    required FlutterSdk sdk,
    required this.logger,
    this.processManager = const LocalProcessManager(),
  }) : _sdk = sdk,
       _sdkError = null;

  /// SDK を解決できなかった時の入れ物。
  ///
  /// **`doctor` のためだけにある。** 環境を調べるコマンドが、環境が
  /// 整っていないという理由で動かないのでは意味がない。他のコマンドは
  /// [sdk] を読んだ時点で [sdkError] が投げられ、これまでと同じ形で
  /// 失敗する。
  const FluseContext.sdkUnavailable({
    required this.projectRoot,
    required this.previewDir,
    required this.config,
    required Object sdkError,
    required this.logger,
    this.processManager = const LocalProcessManager(),
  }) : _sdk = null,
       _sdkError = sdkError;

  /// 作業場所の名前（設計 §9.2）。
  static const String previewDirName = '.flutter_preview';

  /// 解析済みのプロジェクトルート。
  final Directory projectRoot;

  /// `.flutter_preview/`。生成物と資格情報の置き場。
  final Directory previewDir;

  /// 畳んだ設定。
  final FluseConfig config;

  final FlutterSdk? _sdk;

  final Object? _sdkError;

  /// 解決済みの Flutter SDK。
  ///
  /// **解決できていなければ投げる。** 代わりに使える SDK は無い。ここで
  /// 別のものを返すと、指定した版でビルドされない理由に辿り着けなくなる。
  FlutterSdk get sdk {
    final FlutterSdk? resolved = _sdk;
    if (resolved == null) {
      throw _sdkError!;
    }
    return resolved;
  }

  /// 解決できていれば SDK、できていなければ null。**`doctor` 用。**
  FlutterSdk? get sdkOrNull => _sdk;

  /// 解決に失敗した理由。成功していれば null。
  Object? get sdkError => _sdkError;

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

  /// SDK を解決できなかった場合に組み立てる。
  static FluseContext withoutSdk({
    required Directory projectRoot,
    required FluseConfig config,
    required Object sdkError,
    required FluseLogger logger,
    ProcessManager processManager = const LocalProcessManager(),
  }) => FluseContext.sdkUnavailable(
    projectRoot: projectRoot,
    previewDir: Directory(p.join(projectRoot.path, previewDirName)),
    config: config,
    sdkError: sdkError,
    logger: logger,
    processManager: processManager,
  );

  @override
  String toString() => 'FluseContext(${projectRoot.path})';
}
