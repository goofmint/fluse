import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'plugin_ref.dart';
import 'project_info.dart';
import 'project_not_flutter_exception.dart';

/// ユーザープロジェクトを読み取る（設計 §2.2.2）。
///
/// **プロジェクトを作り替えない。** `fluse` の前提は「そのままの構成を
/// debug で組み立てる」こと。ここは既にある宣言を読むだけで、書き戻しは
/// しない。
final class ProjectAnalyzer {
  const ProjectAnalyzer();

  /// 既定のエントリポイント。
  static const String defaultTarget = 'lib/main.dart';

  /// `flutter pub get` が置く、プラグイン解決の結果。
  static const String pluginsFileName = '.flutter-plugins-dependencies';

  /// [projectRoot] を解析する。
  ///
  /// Flutter プロジェクトでなければ [ProjectNotFlutterException]、
  /// 読めるが中身が足りなければ [ProjectAnalysisException] を投げる。
  Future<ProjectInfo> analyze(Directory projectRoot) async {
    final String root = projectRoot.absolute.path;
    final String pubspecPath = p.join(root, 'pubspec.yaml');
    final File pubspec = File(pubspecPath);

    if (!pubspec.existsSync()) {
      throw ProjectNotFlutterException.pubspecMissing(
        projectRoot: root,
        pubspecPath: pubspecPath,
      );
    }

    final String packageName = _parsePubspec(
      await pubspec.readAsString(),
      projectRoot: root,
      pubspecPath: pubspecPath,
    );

    return ProjectInfo(
      root: root,
      packageName: packageName,
      applicationId: _readApplicationId(root),
      defaultTarget: defaultTarget,
      plugins: _readPlugins(root),
    );
  }

  // -------------------------------------------------------------- pubspec

  /// `name` を返す。`flutter:` が無ければ Flutter プロジェクトではない。
  static String _parsePubspec(
    String contents, {
    required String projectRoot,
    required String pubspecPath,
  }) {
    final Object? document;
    try {
      document = loadYaml(contents);
    } on YamlException catch (error) {
      throw ProjectAnalysisException(
        'pubspec.yaml を YAML として読めません: ${error.message}',
        path: pubspecPath,
      );
    }

    if (document is! Map) {
      throw ProjectAnalysisException(
        'pubspec.yaml が YAML のマップではありません',
        path: pubspecPath,
      );
    }

    // **`flutter:` の有無だけで判じる（設計 §5.1）。** `android/` を見ると、
    // まだ `flutter create` していないプロジェクトを取り違える。
    if (!document.containsKey('flutter')) {
      throw ProjectNotFlutterException.notFlutter(
        projectRoot: projectRoot,
        pubspecPath: pubspecPath,
      );
    }

    final Object? name = document['name'];
    if (name is! String || name.isEmpty) {
      throw ProjectAnalysisException(
        'pubspec.yaml の name が文字列ではありません',
        path: pubspecPath,
      );
    }
    return name;
  }

  // --------------------------------------------------------- applicationId

  /// `applicationId` を書いた行。Kotlin と Groovy のどちらの記法も拾う。
  ///
  /// Kotlin: `applicationId = "com.example.app"`
  /// Groovy: `applicationId "com.example.app"`
  static final RegExp _applicationIdPattern = RegExp(
    r'''^\s*applicationId\s*=?\s*["']([^"']+)["']''',
    multiLine: true,
  );

  /// `namespace` を書いた行。
  static final RegExp _namespacePattern = RegExp(
    r'''^\s*namespace\s*=?\s*["']([^"']+)["']''',
    multiLine: true,
  );

  /// コメント行。`//` と `/* */` の両方を落とす。
  static final RegExp _commentPattern = RegExp(
    r'/\*.*?\*/|//[^\n]*',
    dotAll: true,
  );

  /// `android/app/build.gradle(.kts)` から `applicationId` を取り出す。
  ///
  /// **Gradle は動かさない。** 評価には Android SDK と依存解決が要り、
  /// 数十秒かかるうえ、環境の差で落ちる。読み取るのは1つの文字列だけなので
  /// 見合わない。
  static String _readApplicationId(String projectRoot) {
    final List<String> candidates = <String>[
      p.join(projectRoot, 'android', 'app', 'build.gradle.kts'),
      p.join(projectRoot, 'android', 'app', 'build.gradle'),
    ];

    for (final String path in candidates) {
      final File file = File(path);
      if (!file.existsSync()) {
        continue;
      }
      // コメントに書かれた例を拾わないよう、先に落とす。
      final String source = file.readAsStringSync().replaceAll(
        _commentPattern,
        '',
      );

      final String? applicationId = _applicationIdPattern
          .firstMatch(source)
          ?.group(1);
      if (applicationId != null) {
        return applicationId;
      }

      // **`applicationId` は省ける。** 省いた場合、AGP は `namespace` を
      // そのまま使う。ここで諦めると、その構成のプロジェクトが扱えない。
      final String? namespace = _namespacePattern.firstMatch(source)?.group(1);
      if (namespace != null) {
        return namespace;
      }

      throw ProjectAnalysisException(
        'applicationId も namespace も見つかりません',
        path: path,
      );
    }

    throw ProjectAnalysisException(
      'android/app/build.gradle(.kts) がありません',
      path: candidates.first,
    );
  }

  // --------------------------------------------------------------- plugins

  /// `.flutter-plugins-dependencies` からプラグイン一覧を組み立てる。
  ///
  /// **無ければ空で返す。** これは `flutter pub get` の生成物で、
  /// clone 直後には無い。ここで落とすと、解析より先に pub get を
  /// 求めることになり、エラーの理由が伝わりにくくなる。
  static List<PluginRef> _readPlugins(String projectRoot) {
    final String path = p.join(projectRoot, pluginsFileName);
    final File file = File(path);
    if (!file.existsSync()) {
      return const <PluginRef>[];
    }

    final Object? document;
    try {
      document = jsonDecode(file.readAsStringSync());
    } on FormatException catch (error) {
      throw ProjectAnalysisException(
        '$pluginsFileName を JSON として読めません: ${error.message}',
        path: path,
      );
    }

    if (document is! Map<String, Object?>) {
      throw ProjectAnalysisException(
        '$pluginsFileName が JSON のオブジェクトではありません',
        path: path,
      );
    }

    final Object? plugins = document['plugins'];
    if (plugins == null) {
      return const <PluginRef>[];
    }
    if (plugins is! Map<String, Object?>) {
      throw ProjectAnalysisException(
        '$pluginsFileName の plugins がオブジェクトではありません',
        path: path,
      );
    }

    final List<PluginRef> result = <PluginRef>[];
    for (final MapEntry<String, Object?> entry in plugins.entries) {
      final Object? list = entry.value;
      if (list is! List) {
        throw ProjectAnalysisException(
          '$pluginsFileName の plugins.${entry.key} が配列ではありません',
          path: path,
        );
      }
      for (final Object? element in list) {
        result.add(_parsePlugin(element, platform: entry.key, path: path));
      }
    }
    return List<PluginRef>.unmodifiable(result);
  }

  static PluginRef _parsePlugin(
    Object? element, {
    required String platform,
    required String path,
  }) {
    if (element is! Map<String, Object?>) {
      throw ProjectAnalysisException(
        '$pluginsFileName の plugins.$platform にオブジェクト以外が入っています',
        path: path,
      );
    }

    final Object? name = element['name'];
    if (name is! String || name.isEmpty) {
      throw ProjectAnalysisException(
        '$pluginsFileName の plugins.$platform に name がありません',
        path: path,
      );
    }
    final Object? pluginPath = element['path'];
    if (pluginPath is! String || pluginPath.isEmpty) {
      throw ProjectAnalysisException(
        '$pluginsFileName の $name に path がありません',
        path: path,
      );
    }

    return PluginRef(
      name: name,
      path: pluginPath,
      platform: platform,
      dependencies: _parseDependencies(
        element['dependencies'],
        name: name,
        path: path,
      ),
      // 無ければ false / true に倒す。**この2つは古い生成物には無い。**
      // 落とすと、Flutter を上げるまで解析できなくなる。
      isDevDependency: element['dev_dependency'] == true,
      hasNativeBuild: element['native_build'] != false,
    );
  }

  static List<String> _parseDependencies(
    Object? node, {
    required String name,
    required String path,
  }) {
    if (node == null) {
      return const <String>[];
    }
    if (node is! List) {
      throw ProjectAnalysisException(
        '$pluginsFileName の $name の dependencies が配列ではありません',
        path: path,
      );
    }
    final List<String> result = <String>[];
    for (final Object? element in node) {
      if (element is! String) {
        throw ProjectAnalysisException(
          '$pluginsFileName の $name の dependencies に文字列以外が入っています',
          path: path,
        );
      }
      result.add(element);
    }
    return List<String>.unmodifiable(result);
  }
}
