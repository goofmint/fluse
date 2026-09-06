/// プロジェクトが使うプラグイン1件（設計 §2.2.2）。
///
/// 出どころは `flutter pub get` が置く `.flutter-plugins-dependencies`。
/// **自分で pubspec を辿って組み立てない。** 推移的な依存や
/// プラットフォーム別の有無まで解くことになり、Flutter 本体の解決結果と
/// ずれる余地ができる。
final class PluginRef {
  const PluginRef({
    required this.name,
    required this.path,
    required this.platform,
    this.dependencies = const <String>[],
    this.isDevDependency = false,
    this.hasNativeBuild = true,
  });

  /// パッケージ名。例: `path_provider_android`
  final String name;

  /// 展開先の絶対パス。pub のキャッシュや相対パス依存の解決済みの場所。
  final String path;

  /// どのプラットフォーム向けか。例: `android`
  final String platform;

  /// このプラグインが依存する他のプラグイン。
  final List<String> dependencies;

  /// `dev_dependencies` 経由で入っているか。
  ///
  /// **release ビルドには含まれない。** `fluse_runtime` 自身がこれに当たる
  /// （設計 §10-4）。
  final bool isDevDependency;

  /// ネイティブのビルドを持つか。
  ///
  /// 持たないプラグインは Dart だけで完結し、APK を作り直さなくても
  /// 差し替えられる（Task 5.2 の指紋が使う）。
  final bool hasNativeBuild;

  @override
  String toString() => 'PluginRef($name, $platform)';
}
