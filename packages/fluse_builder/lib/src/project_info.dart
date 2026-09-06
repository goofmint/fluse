import 'plugin_ref.dart';

/// 解析したユーザープロジェクト（設計 §2.2.2）。
///
/// `fluse` はプロジェクトを新規生成せず、**そのままの構成を debug で
/// 組み立てる**。そのために、既にある設定を読み取って把握しておく。
///
/// 指紋（`Fingerprint`）は Task 5.2 で足す。ここには持たせない。
/// 計算には Flutter SDK が要り、解析だけで済む場面まで SDK の解決を
/// 巻き込むことになる。
final class ProjectInfo {
  const ProjectInfo({
    required this.root,
    required this.packageName,
    required this.applicationId,
    required this.defaultTarget,
    this.plugins = const <PluginRef>[],
  });

  /// プロジェクトルートの絶対パス。
  final String root;

  /// `pubspec.yaml` の `name`。生成するエントリポイントの import に使う。
  final String packageName;

  /// `android/app/build.gradle(.kts)` の `applicationId`。
  ///
  /// 端末に入る際の同一性はこれで決まる。既に入っている本番の debug ビルドと
  /// ぶつかると `INSTALL_FAILED_UPDATE_INCOMPATIBLE` になる（設計 §5.3）。
  final String applicationId;

  /// 既定のエントリポイント。`lib/main.dart`。
  final String defaultTarget;

  /// 使っているプラグイン。
  final List<PluginRef> plugins;

  @override
  String toString() => 'ProjectInfo($packageName, $applicationId)';
}
