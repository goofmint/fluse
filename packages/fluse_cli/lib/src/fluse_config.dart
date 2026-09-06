import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

import 'fluse_config_exception.dart';

/// `fluse.yaml` の中身（設計 §9.2）。
///
/// **決め方には順序がある。** CLI引数 > 環境変数 > `fluse.yaml` > 既定値。
/// 一時的に上書きしたい時（`--port 9000`）と、いつもそうしたい時
/// （`fluse.yaml`）を分けられるようにするため。
final class FluseConfig {
  const FluseConfig({
    this.version = currentVersion,
    this.port = defaultPort,
    this.target = defaultTarget,
    this.applicationIdSuffix,
    this.dartDefines = const <String>[],
    this.serveApk = defaultServeApk,
  });

  /// ファイル名。
  static const String fileName = 'fluse.yaml';

  /// このスキーマの版。
  static const int currentVersion = 1;

  /// 既定のポート（設計 §1.1）。
  static const int defaultPort = 8180;

  /// 既定のエントリポイント。
  static const String defaultTarget = 'lib/main.dart';

  /// APK を配るか。
  static const bool defaultServeApk = true;

  /// ポートの下限。
  static const int minPort = 0;

  /// ポートの上限。
  static const int maxPort = 65535;

  /// ポートを差し替える環境変数（設計 §9.2）。
  static const String portVariable = 'FLUSE_PORT';

  /// 読み込んだスキーマの版。
  final int version;

  /// 待ち受けるポート。
  final int port;

  /// 包む対象のエントリポイント。
  final String target;

  /// 署名がぶつかった時に付ける接尾辞（設計 §5.3）。無ければ null。
  final String? applicationIdSuffix;

  /// `-D<key>=<value>` に渡す値。
  ///
  /// **順序も含めて意味がある。** 同じキーが複数あれば後勝ちで解決される。
  final List<String> dartDefines;

  /// `/apk` で Preview App を配るか。
  final bool serveApk;

  // ---------------------------------------------------------------- 読み込み

  /// [projectRoot] の `fluse.yaml` を読む。無ければ既定値。
  ///
  /// **無いことは失敗ではない。** `fluse init` の前は存在しない。
  static FluseConfig readFrom(Directory projectRoot) {
    final String path = p.join(projectRoot.path, fileName);
    final File file = File(path);
    if (!file.existsSync()) {
      return const FluseConfig();
    }
    return fromYaml(file.readAsStringSync(), path: path);
  }

  /// YAML から組み立てる。
  ///
  /// **キーの欠落と型の食い違いを分けて扱う。** 書いていないものは既定値で
  /// よいが、書いてあるのに読めないのは書き手の意図が通っていない。
  static FluseConfig fromYaml(String contents, {String? path}) {
    final Object? document;
    try {
      document = loadYaml(contents);
    } on YamlException catch (error) {
      throw FluseConfigException(
        '$fileName を YAML として読めません: ${error.message}',
        path: path,
      );
    }

    if (document == null) {
      // 空のファイル。書いていないのと同じ。
      return const FluseConfig();
    }
    if (document is! Map) {
      throw FluseConfigException('$fileName が YAML のマップではありません', path: path);
    }

    final int version =
        _optionalInt(document, 'version', path) ?? currentVersion;
    if (version < 1 || version > currentVersion) {
      // **読めないものを読めたことにしない。** 知らないキーを見落として
      // 動くと、書いた設定が効かない理由が分からなくなる。
      throw FluseConfigException(
        'version $version は未対応です（対応は $currentVersion まで）。fluse を更新してください',
        path: path,
      );
    }

    return FluseConfig(
      version: version,
      port: switch (_optionalInt(document, 'port', path)) {
        final int value => validatePort(value, 'port', path: path),
        null => defaultPort,
      },
      target: _optionalString(document, 'target', path) ?? defaultTarget,
      applicationIdSuffix: _optionalString(
        document,
        'applicationIdSuffix',
        path,
      ),
      dartDefines: _optionalStringList(document, 'dartDefines', path),
      serveApk: _optionalBool(document, 'serveApk', path) ?? defaultServeApk,
    );
  }

  // ---------------------------------------------------------------- 優先順位

  /// 決め方の順序に従って1つに畳む。
  ///
  /// [argument] は CLI 引数（無ければ null）、[environment] は環境変数。
  /// **空文字は「指定なし」として扱う。** `FLUSE_PORT=` を「0番ポート」と
  /// 読むと、意図しない場所で待ち受けることになる。
  static T resolveValue<T>({
    T? argument,
    T? environment,
    T? file,
    required T fallback,
  }) => argument ?? environment ?? file ?? fallback;

  /// 全体を1つに畳む。
  static FluseConfig resolve({
    required Directory projectRoot,
    int? portArgument,
    String? targetArgument,
    String? applicationIdSuffixArgument,
    List<String>? dartDefinesArgument,
    bool? serveApkArgument,
    Map<String, String>? environment,
  }) {
    final FluseConfig file = readFrom(projectRoot);
    final Map<String, String> env = environment ?? Platform.environment;

    return FluseConfig(
      version: file.version,
      port: resolveValue<int>(
        argument: portArgument == null
            ? null
            : validatePort(portArgument, '--port'),
        environment: portFromEnvironment(env),
        file: file.port,
        fallback: defaultPort,
      ),
      target: resolveValue<String>(
        argument: targetArgument,
        file: file.target,
        fallback: defaultTarget,
      ),
      // **null が既定値。** 「指定なし」と「null を指定」を分けられないが、
      // 接尾辞に意味のある null は無いので困らない。
      applicationIdSuffix:
          applicationIdSuffixArgument ?? file.applicationIdSuffix,
      dartDefines: dartDefinesArgument ?? file.dartDefines,
      serveApk: resolveValue<bool>(
        argument: serveApkArgument,
        file: file.serveApk,
        fallback: defaultServeApk,
      ),
    );
  }

  /// 環境変数から読むポート。指定が無ければ null。
  static int? portFromEnvironment(Map<String, String> environment) {
    final String? raw = environment[portVariable];
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    final int? parsed = int.tryParse(raw.trim());
    if (parsed == null) {
      // **黙って既定値へ倒さない。** 指定したのに効かない理由が分からない。
      throw FluseConfigException('$portVariable が正しくありません: $raw');
    }
    return validatePort(parsed, portVariable);
  }

  /// ポートの範囲を見る。
  ///
  /// **どの経路から来ても同じ所で見る。** 片方だけ見ていると、
  /// `fluse.yaml` に書いた 70000 が bind の失敗として表面化し、
  /// 設定の誤りだと気づけない。
  static int validatePort(int value, String source, {String? path}) {
    if (value < minPort || value > maxPort) {
      throw FluseConfigException(
        '$source が正しくありません: $value（$minPort〜$maxPort）',
        path: path,
      );
    }
    return value;
  }

  // ---------------------------------------------------------------- 書き込み

  /// `fluse.yaml` に書く。
  ///
  /// **他のキーとコメントを残す。** 既にある内容を組み直すと、利用者が
  /// 書いたものが失われる（設計 §10-8）。無ければ全項目を並べて作る。
  Future<void> writeTo(File file) async {
    final YamlEditor editor;
    if (file.existsSync()) {
      editor = YamlEditor(await file.readAsString());
      final YamlNode root = editor.parseAt(
        <Object>[],
        orElse: () => wrapAsYamlNode(null),
      );
      if (root.value != null && root is! YamlMap) {
        throw FluseConfigException(
          '$fileName が YAML のマップではありません',
          path: file.path,
        );
      }
      if (root.value == null) {
        editor.update(<Object>[], wrapAsYamlNode(<String, Object?>{}));
      }
      editor
        ..update(<Object>['version'], version)
        ..update(<Object>['port'], port)
        ..update(<Object>['target'], target)
        ..update(<Object>['applicationIdSuffix'], applicationIdSuffix)
        ..update(<Object>['dartDefines'], dartDefines)
        ..update(<Object>['serveApk'], serveApk);
    } else {
      editor = YamlEditor(_template());
    }

    await file.parent.create(recursive: true);

    // 別の場所へ書いてから置き換える。途中で落ちても半端な内容が残らない。
    final File temporary = File('${file.path}.tmp');
    try {
      await temporary.writeAsString(editor.toString());
      await temporary.rename(file.path);
    } on Object {
      if (temporary.existsSync()) {
        temporary.deleteSync();
      }
      rethrow;
    }
  }

  /// 新しく作る時の中身（設計 §9.2 の並び）。
  String _template() {
    final StringBuffer buffer = StringBuffer()
      ..writeln('# fluse の設定。CLI 引数と環境変数が優先されます。')
      ..writeln('version: $version')
      ..writeln()
      ..writeln('# 待ち受けるポート。$portVariable で一時的に変えられます。')
      ..writeln('port: $port')
      ..writeln()
      ..writeln('# 包む対象のエントリポイント。')
      ..writeln('target: $target')
      ..writeln()
      ..writeln('# 署名がぶつかった時に付ける接尾辞（設計 §5.3）。')
      ..writeln('applicationIdSuffix: ${applicationIdSuffix ?? 'null'}')
      ..writeln()
      ..writeln('# -D で渡す値。順序も含めて意味があります。')
      ..writeln('dartDefines:');
    if (dartDefines.isEmpty) {
      // 空リストを `[]` で書く。項目が無いことを見て分かるようにする。
      buffer
        ..write('  ')
        ..writeln('[]');
    } else {
      for (final String define in dartDefines) {
        buffer.writeln('  - $define');
      }
    }
    buffer
      ..writeln()
      ..writeln('# 案内ページから APK を配るか。')
      ..writeln('serveApk: $serveApk');
    return buffer.toString();
  }

  // ------------------------------------------------------------------ 道具

  static String? _optionalString(
    Map<Object?, Object?> map,
    String key,
    String? path,
  ) {
    final Object? value = map[key];
    if (value == null) {
      return null;
    }
    if (value is! String) {
      throw FluseConfigException('$key が文字列ではありません', path: path);
    }
    return value.isEmpty ? null : value;
  }

  static int? _optionalInt(
    Map<Object?, Object?> map,
    String key,
    String? path,
  ) {
    final Object? value = map[key];
    if (value == null) {
      return null;
    }
    if (value is! int) {
      throw FluseConfigException('$key が整数ではありません', path: path);
    }
    return value;
  }

  static bool? _optionalBool(
    Map<Object?, Object?> map,
    String key,
    String? path,
  ) {
    final Object? value = map[key];
    if (value == null) {
      return null;
    }
    if (value is! bool) {
      throw FluseConfigException('$key が真偽値ではありません', path: path);
    }
    return value;
  }

  static List<String> _optionalStringList(
    Map<Object?, Object?> map,
    String key,
    String? path,
  ) {
    final Object? value = map[key];
    if (value == null) {
      return const <String>[];
    }
    if (value is! List) {
      throw FluseConfigException('$key が配列ではありません', path: path);
    }
    return List<String>.unmodifiable(<String>[
      for (final Object? element in value)
        if (element is String)
          element
        else
          throw FluseConfigException('$key に文字列でない値があります', path: path),
    ]);
  }

  @override
  String toString() =>
      'FluseConfig(port: $port, target: $target, '
      'applicationIdSuffix: $applicationIdSuffix, '
      'dartDefines: ${dartDefines.length}件, serveApk: $serveApk)';
}
