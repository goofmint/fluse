import 'dart:convert';
import 'dart:io';

import 'mask.dart';

/// `build_meta.json` の読み書きや解析に失敗したときに投げる。
final class BuildMetaException implements Exception {
  const BuildMetaException(this.message);

  final String message;

  @override
  String toString() => 'build_meta: $message';
}

/// `fluse init` の APK ビルドで実際に使われた `frontend_server` のフラグ
/// （設計 §10-1）。
///
/// **`fluse start` の増分コンパイルは、ここに記録されたフラグを完全に
/// 再現しなければならない。** `--track-widget-creation` / `-D` /
/// `--enable-asserts` が1つでも違うと `reloadSources` が**静かに失敗**する。
/// 画面が更新されないだけでエラーも出ないため、原因の特定が極めて難しい。
///
/// フラグはハードコードせず `flutter build --verbose` の出力から抽出する。
/// Flutter SDK のバージョンで既定のフラグが変わっても追従できるようにする。
final class BuildMeta {
  const BuildMeta({
    required this.trackWidgetCreation,
    required this.enableAsserts,
    required this.dartDefines,
    this.schemaVersion = currentSchemaVersion,
  });

  /// このファイル形式の版。
  ///
  /// 将来フラグを増やしたときに、古い `build_meta.json` を「読めない」と
  /// 判定できるようにするため。
  static const int currentSchemaVersion = 1;

  /// `--track-widget-creation` が渡されたか。
  final bool trackWidgetCreation;

  /// `--enable-asserts` が渡されたか。
  final bool enableAsserts;

  /// `-D<key>=<value>` の値（`key=value` の形）。
  ///
  /// **順序も含めて比較する。** `frontend_server` は同じキーが複数ある
  /// 場合に後勝ちで解決するため、順序が変われば結果も変わりうる。
  final List<String> dartDefines;

  /// 読み込んだ `build_meta.json` の形式版。既定は [currentSchemaVersion]。
  final int schemaVersion;

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': schemaVersion,
    'trackWidgetCreation': trackWidgetCreation,
    'enableAsserts': enableAsserts,
    'dartDefines': dartDefines,
  };

  static BuildMeta fromJson(Map<String, Object?> json) {
    final Object? version = json['schemaVersion'];
    if (version == null) {
      throw const BuildMetaException('schemaVersion がありません');
    }
    if (version is! int) {
      // 「無い」と「型が違う」を区別する。壊れた build_meta.json の
      // 原因を特定できるようにするため。
      throw BuildMetaException('schemaVersion が整数ではありません: $version');
    }
    if (version < 1) {
      throw BuildMetaException('schemaVersion $version は不正です');
    }
    if (version > currentSchemaVersion) {
      throw BuildMetaException(
        'schemaVersion $version は未対応です（対応は $currentSchemaVersion まで）。'
        'fluse を更新するか `fluse rebuild --force` をしてください',
      );
    }

    final Object? defines = json['dartDefines'];
    if (defines == null) {
      throw const BuildMetaException('dartDefines がありません');
    }
    if (defines is! List) {
      throw BuildMetaException('dartDefines が配列ではありません: $defines');
    }

    return BuildMeta(
      schemaVersion: version,
      trackWidgetCreation: _requireBool(json, 'trackWidgetCreation'),
      enableAsserts: _requireBool(json, 'enableAsserts'),
      dartDefines: <String>[
        for (final Object? define in defines)
          if (define is String)
            define
          else
            throw BuildMetaException('dartDefines に文字列でない値があります: $define'),
      ],
    );
  }

  /// [file] へ書き出す。親ディレクトリが無ければ作る。
  void writeTo(File file) {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(toJson()),
    );
  }

  /// [file] から読み込む。
  ///
  /// 存在しない場合も不正な場合も、何をすればよいかを添えて失敗させる。
  /// ここで黙って既定値に落とすと、フラグ不一致のまま起動して
  /// 「リロードしても画面が変わらない」状態になる。
  static BuildMeta readFrom(File file) {
    if (!file.existsSync()) {
      throw BuildMetaException('${file.path} がありません。`fluse init` を実行してください');
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(file.readAsStringSync());
    } on FormatException catch (error) {
      throw BuildMetaException(
        '${file.path} を JSON として読めません: ${error.message}',
      );
    }

    if (decoded is! Map<String, Object?>) {
      throw BuildMetaException('${file.path} が JSON オブジェクトではありません');
    }

    try {
      return fromJson(decoded);
    } on BuildMetaException catch (error) {
      throw BuildMetaException('${file.path}: ${error.message}');
    }
  }

  /// [other] と食い違うフラグの説明を返す。一致していれば空。
  List<String> differencesFrom(BuildMeta other) => <String>[
    if (trackWidgetCreation != other.trackWidgetCreation)
      '--track-widget-creation: 記録=$trackWidgetCreation, '
          '現在=${other.trackWidgetCreation}',
    if (enableAsserts != other.enableAsserts)
      '--enable-asserts: 記録=$enableAsserts, 現在=${other.enableAsserts}',
    if (!_sameDefines(dartDefines, other.dartDefines))
      '-D: 記録=${maskDefines(dartDefines)}, 現在=${maskDefines(other.dartDefines)}',
  ];

  /// `-D` の値をマスクした表示用の文字列を返す。
  ///
  /// `-D` には API キーやトークンが入りうる。不一致のエラーメッセージは
  /// 端末にもログにも出るため、値をそのまま載せない。キー名と「変わった
  /// こと」が分かれば利用者は対処できる。
  static List<String> maskDefines(List<String> defines) => <String>[
    for (final String define in defines) maskDefine(define),
  ];

  /// `KEY=value` の値部分だけをマスクする。
  ///
  /// 値が空のもの（`FLUTTER_APP_FLAVOR=`）は空のままにする。マスクすると
  /// 「空である」という情報が失われ、差分の読み取りが難しくなる。
  static String maskDefine(String define) {
    final int separator = define.indexOf('=');
    if (separator < 0) {
      return define;
    }
    final String key = define.substring(0, separator);
    final String value = define.substring(separator + 1);
    return value.isEmpty ? '$key=' : '$key=${maskToken(value)}';
  }

  static bool _sameDefines(List<String> a, List<String> b) {
    if (a.length != b.length) {
      return false;
    }
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }

  static bool _requireBool(Map<String, Object?> json, String key) {
    final Object? value = json[key];
    if (value == null) {
      throw BuildMetaException('$key がありません');
    }
    if (value is! bool) {
      throw BuildMetaException('$key が真偽値ではありません: $value');
    }
    return value;
  }

  @override
  String toString() =>
      'BuildMeta(trackWidgetCreation: $trackWidgetCreation, '
      'enableAsserts: $enableAsserts, dartDefines: $dartDefines)';
}
