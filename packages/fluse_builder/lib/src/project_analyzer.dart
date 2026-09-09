import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'plugin_ref.dart';
import 'project_info.dart';
import 'project_not_flutter_exception.dart';
import 'project_platform.dart';

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
  ///
  /// [platform] は読む識別子を選ぶ。**既定は [ProjectPlatform.android] で、
  /// 従来どおり `applicationId` だけを読む。** `ProjectPlatform.ios` を
  /// 渡すと `bundleId` だけを読み、`applicationId` は null のままになる。
  /// 一方の platform を読んでいる間、もう一方は解析しない。
  ///
  /// `android/` と `ios/` の**両方が無い**場合だけ、ここで
  /// [ProjectAnalysisException] を投げる。**要求した platform のディレクトリ
  /// だけが無く、もう一方は存在する場合はここでは弾かない。** その場合でも、
  /// 要求された platform の識別子は結局読めないので、この後
  /// `_readApplicationId` / `_readBundleId` がそれぞれの言葉で
  /// [ProjectAnalysisException] を投げる（例: android/ が無く ios/ だけの
  /// プロジェクトで `platform: ProjectPlatform.android` を指定した場合）。
  Future<ProjectInfo> analyze(
    Directory projectRoot, {
    ProjectPlatform platform = ProjectPlatform.android,
  }) async {
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

    final Directory androidDir = Directory(p.join(root, 'android'));
    final Directory iosDir = Directory(p.join(root, 'ios'));

    // **両方無いときだけ、ここでまとめて弾く。** 個別の識別子が読めない
    // 場合は、この後の platform 別の reader が自分の言葉で例外を投げる。
    // ここで見るのは「そもそもどちらの対象も無い」プロジェクトだけ。
    if (!androidDir.existsSync() && !iosDir.existsSync()) {
      throw ProjectAnalysisException(
        'android/app/build.gradle(.kts) も '
        'ios/Runner.xcodeproj/project.pbxproj も見当たりません'
        '（android/ も ios/ もありません）',
        path: p.join(androidDir.path, 'app', 'build.gradle.kts'),
      );
    }

    String? applicationId;
    String? bundleId;
    switch (platform) {
      case ProjectPlatform.android:
        applicationId = _readApplicationId(root);
      case ProjectPlatform.ios:
        bundleId = _readBundleId(root);
    }

    return ProjectInfo(
      root: root,
      packageName: packageName,
      applicationId: applicationId,
      bundleId: bundleId,
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

  // ------------------------------------------------------------- bundleId

  /// `project.pbxproj` の `PRODUCT_BUNDLE_IDENTIFIER = <value>;` を書いた行。
  /// 値は引用符で囲まれることも、囲まれないこともある。
  static final RegExp _bundleIdPattern = RegExp(
    r'''PRODUCT_BUNDLE_IDENTIFIER\s*=\s*"?([^;"]+)"?\s*;''',
  );

  /// `Info.plist` の `CFBundleIdentifier` エントリ。
  static final RegExp _cfBundleIdentifierPattern = RegExp(
    r'''<key>\s*CFBundleIdentifier\s*</key>\s*<string>([^<]+)</string>''',
  );

  /// 変数参照を含むかどうか。
  ///
  /// `project.pbxproj` は Debug / Release / Profile の3つの構成を持つのが
  /// 普通で、`Info.plist` の既定値もビルド設定側の値をこの記法で参照する。
  /// 具体値の行が見つかるまで、この形は読み飛ばす。
  ///
  /// **前方一致・後方一致では足りない。** テストターゲットの既定値は
  /// `$(PRODUCT_BUNDLE_IDENTIFIER).RunnerTests` のように参照の後ろに
  /// 文字が続く。`)` で終わらないからと具体値に数えると、この値が
  /// bundleId になってしまう。
  static bool _isVariableReference(String value) => value.contains(r'$(');

  /// 一致した中から、変数参照でない最初の値を返す。
  static String? _firstConcreteValue(Iterable<RegExpMatch> matches) {
    for (final RegExpMatch match in matches) {
      final String value = match.group(1)!.trim();
      if (!_isVariableReference(value)) {
        return value;
      }
    }
    return null;
  }

  /// `project.pbxproj` の1つのオブジェクト宣言（`<ID> = {`）。
  ///
  /// コメントを落とした後の形を見る。ID は 24 桁の16進。
  static final RegExp _objectHeadPattern = RegExp(
    r'([0-9A-Fa-f]{24})\s*=\s*\{',
  );

  /// `buildConfigurationList = <ID>;`
  static final RegExp _configurationListPattern = RegExp(
    r'buildConfigurationList\s*=\s*([0-9A-Fa-f]{24})\s*;',
  );

  /// `buildConfigurations = ( <ID>, <ID>, );`
  static final RegExp _buildConfigurationsPattern = RegExp(
    r'buildConfigurations\s*=\s*\(([^)]*)\)',
  );

  /// `name = Runner;` / `name = "Runner";`
  static final RegExp _runnerNamePattern = RegExp(r'name\s*=\s*"?Runner"?\s*;');

  /// Runner ターゲットの構成だけから bundle identifier を読む。
  ///
  /// **ファイル全体の最初の具体値では駄目。** App Extension や
  /// Watch App を足したプロジェクトでは、Runner より前に別ターゲットの
  /// 具体値が現れる。それを掴むと、別アプリの ID で署名や配布を
  /// しようとして落ちる。
  ///
  /// Runner の `PBXNativeTarget` を見つけられない場合（`PBXNativeTarget`
  /// を持たない最小の pbxproj など）に限り、従来どおりファイル全体を
  /// 走査する。**その場合も変数参照は読み飛ばす。**
  static String? _runnerBundleId(String source) {
    final Map<String, String> objects = _pbxObjects(source);

    String? runner;
    for (final String body in objects.values) {
      if (body.contains('isa = PBXNativeTarget;') &&
          _runnerNamePattern.hasMatch(body)) {
        runner = body;
        break;
      }
    }
    if (runner == null) {
      return _firstConcreteValue(_bundleIdPattern.allMatches(source));
    }

    final RegExpMatch? listMatch = _configurationListPattern.firstMatch(runner);
    final String? listBody = listMatch == null
        ? null
        : objects[listMatch.group(1)!];
    if (listBody == null) {
      return null;
    }

    final RegExpMatch? idsMatch = _buildConfigurationsPattern.firstMatch(
      listBody,
    );
    if (idsMatch == null) {
      return null;
    }

    for (final String id in RegExp(
      r'[0-9A-Fa-f]{24}',
    ).allMatches(idsMatch.group(1)!).map((RegExpMatch m) => m.group(0)!)) {
      final String? body = objects[id];
      if (body == null) {
        continue;
      }
      final String? value = _firstConcreteValue(
        _bundleIdPattern.allMatches(body),
      );
      if (value != null) {
        return value;
      }
    }
    return null;
  }

  /// `<ID> = { ... };` を ID から中身へ引ける形にする。
  ///
  /// 入れ子の `{}` を数えて対応する `}` までを1つの塊として取る。
  static Map<String, String> _pbxObjects(String source) {
    final Map<String, String> objects = <String, String>{};
    for (final RegExpMatch match in _objectHeadPattern.allMatches(source)) {
      final String? body = _balancedBlock(source, match.end - 1);
      if (body != null) {
        objects[match.group(1)!] = body;
      }
    }
    return objects;
  }

  /// [open] の位置にある `{` に対応する `}` までの中身を返す。
  static String? _balancedBlock(String source, int open) {
    int depth = 0;
    for (int i = open; i < source.length; i++) {
      final String ch = source[i];
      if (ch == '{') {
        depth++;
      } else if (ch == '}') {
        depth--;
        if (depth == 0) {
          return source.substring(open + 1, i);
        }
      }
    }
    return null;
  }

  /// `ios/Runner.xcodeproj/project.pbxproj` または `ios/Runner/Info.plist`
  /// から bundle identifier を取り出す。
  ///
  /// **xcodebuild は動かさない。** `_readApplicationId` が Gradle を
  /// 動かさないのと同じ理由で、評価には Xcode の環境が要り、数十秒かかる
  /// うえ環境の差で落ちる。読み取るのは1つの文字列だけなので見合わない。
  static String _readBundleId(String projectRoot) {
    final String pbxprojPath = p.join(
      projectRoot,
      'ios',
      'Runner.xcodeproj',
      'project.pbxproj',
    );
    final File pbxproj = File(pbxprojPath);
    if (pbxproj.existsSync()) {
      // コメントに書かれた例を拾わないよう、先に落とす。
      final String source = pbxproj.readAsStringSync().replaceAll(
        _commentPattern,
        '',
      );
      final String? bundleId = _runnerBundleId(source);
      if (bundleId != null) {
        return bundleId;
      }
    }

    // **`project.pbxproj` に具体値が無ければ `Info.plist` を見る。**
    // 既定のテンプレートは `Info.plist` 側で `$(PRODUCT_BUNDLE_IDENTIFIER)`
    // を参照するだけだが、`Info.plist` を直接書き換えているプロジェクトも
    // ある。
    final String infoPlistPath = p.join(
      projectRoot,
      'ios',
      'Runner',
      'Info.plist',
    );
    final File infoPlist = File(infoPlistPath);
    if (infoPlist.existsSync()) {
      final String source = infoPlist.readAsStringSync();
      final String? bundleId = _firstConcreteValue(
        _cfBundleIdentifierPattern.allMatches(source),
      );
      if (bundleId != null) {
        return bundleId;
      }
    }

    throw ProjectAnalysisException(
      'PRODUCT_BUNDLE_IDENTIFIER も CFBundleIdentifier も見つかりません',
      path: infoPlist.existsSync() ? infoPlistPath : pbxprojPath,
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
