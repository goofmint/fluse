import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'fingerprint_exception.dart';
import 'flutter_sdk.dart';
import 'project_info.dart';

/// APK を作り直す必要があるかを判じる指紋（設計 §2.2.2 / 要件16）。
///
/// **Dart のソースは対象にしない。** そこは増分コンパイルとホットリロードで
/// 賄える。ここが見るのは「作り直さないと反映されないもの」——ネイティブの
/// 構成、プラグイン、asset の宣言、ビルドフラグ——だけ。
///
/// 取りこぼすと、直したはずの変更が反映されない理由が分からなくなる。
/// 逆に広く取りすぎると、触るたびに APK ビルドが走って待たされる。
final class Fingerprint {
  const Fingerprint({
    required this.entries,
    this.nativeStamp,
    this.schemaVersion = currentSchemaVersion,
  });

  /// このファイル形式の版。
  ///
  /// 将来キーを増やしたときに、古い `fingerprint.json` を「読めない」と
  /// 判定できるようにするため。
  static const int currentSchemaVersion = 1;

  /// 論理名 -> sha256（設計 §2.2.2 の指紋テーブル）。
  final Map<String, String> entries;

  /// `android.native` の一次判定に使う合成ハッシュ。
  ///
  /// パス・mtime・サイズだけから作る。これが前回と一致すれば、中身を
  /// 読み直さずに前回の内容ハッシュを使い回せる（設計 §8.2-7）。
  final String? nativeStamp;

  /// 読み込んだ形式の版。
  final int schemaVersion;

  // ------------------------------------------------------------------ キー

  static const String keyFlutterRevision = 'flutter.revision';
  static const String keyPubspecLock = 'pubspec.lock';
  static const String keyPubspecAssets = 'pubspec.assets';
  static const String keyPlugins = 'plugins';
  static const String keyAndroidManifest = 'android.manifest';
  static const String keyAndroidGradle = 'android.gradle';
  static const String keyAndroidNative = 'android.native';
  static const String keyBuildFlags = 'build.flags';

  /// 指紋が見る対象。並びは設計 §2.2.2 の表と揃える。
  static const List<String> keys = <String>[
    keyFlutterRevision,
    keyPubspecLock,
    keyPubspecAssets,
    keyPlugins,
    keyAndroidManifest,
    keyAndroidGradle,
    keyAndroidNative,
    keyBuildFlags,
  ];

  /// 対象が1つも無いことを表す値。
  ///
  /// **空文字にしない。** 「まだ計算していない」と「対象が無い」を
  /// 見分けられなくなる。
  static final String empty = _hash('');

  /// どの階層にあっても中身を見ないディレクトリ。
  ///
  /// **Gradle の生成物を入れてはいけない。** `build/` にはマージ済みの
  /// `AndroidManifest.xml` が置かれ、ビルドのたびに指紋が変わる。
  /// `fluse_server` の `ChangeClassifier` と揃えてある。
  static const Set<String> ignoredDirs = <String>{
    'build',
    '.gradle',
    '.cxx',
    '.dart_tool',
    '.flutter_preview',
    '.git',
    '.idea',
  };

  // ---------------------------------------------------------------- 計算

  /// [project] の今の指紋を作る。
  ///
  /// [buildFlags] は `frontend_server` に渡すフラグ集合。**ここでは
  /// 組み立てない。** 真実の出どころは `build_meta.json`（設計 §10-1）で、
  /// それを読むのは呼び出し側の役目。
  ///
  /// [previous] を渡すと `android.native` の内容ハッシュを省ける場合がある。
  static Future<Fingerprint> compute(
    ProjectInfo project,
    FlutterSdk sdk, {
    required List<String> buildFlags,
    Fingerprint? previous,
  }) async {
    final String root = project.root;
    final _NativeDigest native = await _computeNative(root, previous);

    return Fingerprint(
      entries: Map<String, String>.unmodifiable(<String, String>{
        keyFlutterRevision: _hash(sdk.revision),
        keyPubspecLock: await _hashRequiredFile(p.join(root, 'pubspec.lock')),
        keyPubspecAssets: _hashAssets(p.join(root, 'pubspec.yaml')),
        keyPlugins: _hashPlugins(p.join(root, '.flutter-plugins-dependencies')),
        keyAndroidManifest: await _hashFiles(_androidManifests(root), root),
        keyAndroidGradle: await _hashFiles(_gradleFiles(root), root),
        keyAndroidNative: native.content,
        // **並べ替えない。** `-D` は同じキーが複数あれば後勝ちで、
        // 順序が変われば結果も変わりうる（`BuildMeta.dartDefines` と同じ）。
        keyBuildFlags: _hash(buildFlags.join(' ')),
      }),
      nativeStamp: native.stamp,
    );
  }

  // ------------------------------------------------------------------ 差分

  /// 値が違うキー名。
  ///
  /// **値そのものは返さない。** 呼び出し側がそのまま表示するため、
  /// パスや中身が混ざらないようにキー名だけに絞る。
  List<String> diff(Fingerprint other) {
    final Set<String> names = <String>{...entries.keys, ...other.entries.keys};
    final List<String> changed = <String>[
      for (final String name in names)
        if (entries[name] != other.entries[name]) name,
    ];
    // 並びを決めておく。表示とテストの両方で揺れないように。
    changed.sort();
    return List<String>.unmodifiable(changed);
  }

  /// 作り直さずに使えるか。
  bool isCompatibleWith(Fingerprint other) => diff(other).isEmpty;

  // ---------------------------------------------------------------- 永続化

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': schemaVersion,
    'entries': entries,
    if (nativeStamp != null) 'nativeStamp': nativeStamp,
  };

  static Fingerprint fromJson(Map<String, Object?> json) {
    final Object? version = json['schemaVersion'];
    if (version == null) {
      throw const FingerprintException('schemaVersion がありません');
    }
    if (version is! int) {
      throw const FingerprintException('schemaVersion が整数ではありません');
    }
    if (version < 1) {
      throw FingerprintException('schemaVersion が不正です: $version');
    }
    if (version > currentSchemaVersion) {
      // **読めないものを読めたことにしない。** 知らないキーを見落として
      // 「差分なし」と判じると、古い APK のまま動き続ける。
      throw FingerprintException(
        'この fluse では読めない schemaVersion です: $version'
        '（対応は $currentSchemaVersion まで）',
      );
    }

    final Object? rawEntries = json['entries'];
    if (rawEntries is! Map) {
      throw const FingerprintException('entries がオブジェクトではありません');
    }
    final Map<String, String> entries = <String, String>{};
    for (final MapEntry<Object?, Object?> entry in rawEntries.entries) {
      final Object? key = entry.key;
      final Object? value = entry.value;
      if (key is! String || value is! String) {
        throw const FingerprintException('entries に文字列以外が入っています');
      }
      entries[key] = value;
    }

    final Object? stamp = json['nativeStamp'];
    if (stamp != null && stamp is! String) {
      throw const FingerprintException('nativeStamp が文字列ではありません');
    }

    return Fingerprint(
      entries: Map<String, String>.unmodifiable(entries),
      nativeStamp: stamp is String ? stamp : null,
      schemaVersion: version,
    );
  }

  /// [file] へ書く。親ディレクトリが無ければ作る。
  Future<void> writeTo(File file) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(toJson())}\n',
    );
  }

  /// [file] から読む。
  static Future<Fingerprint> readFrom(File file) async {
    if (!file.existsSync()) {
      throw FingerprintException(
        '指紋がまだありません。`fluse init` で Preview App を作ってください',
        path: file.path,
      );
    }

    final Object? document;
    try {
      document = jsonDecode(await file.readAsString());
    } on FormatException catch (error) {
      throw FingerprintException(
        'JSON として読めません: ${error.message}',
        path: file.path,
      );
    }
    if (document is! Map<String, Object?>) {
      throw FingerprintException('JSON のオブジェクトではありません', path: file.path);
    }

    try {
      return fromJson(document);
    } on FingerprintException catch (error) {
      // 元の理由を保ったまま、どのファイルの話かを足す。
      throw FingerprintException(error.message, path: file.path);
    }
  }

  // ------------------------------------------------------------ 個々のキー

  /// `flutter:` の `assets:` / `fonts:` だけを対象にする。
  ///
  /// **`pubspec.yaml` 全体をハッシュしない。** 説明文や依存の版を書き換える
  /// たびに APK ビルドが走ることになる。作り直しが要るのは、APK へ焼き込む
  /// 宣言が変わった時だけ。
  static String _hashAssets(String pubspecPath) {
    final File file = File(pubspecPath);
    if (!file.existsSync()) {
      // Flutter プロジェクトに必ずある。無いのは異常。
      throw FingerprintException('指紋の対象が見つかりません', path: pubspecPath);
    }

    final Object? document;
    try {
      document = loadYaml(file.readAsStringSync());
    } on YamlException catch (error) {
      throw FingerprintException(
        'pubspec.yaml を YAML として読めません: ${error.message}',
        path: pubspecPath,
      );
    }
    if (document is! Map) {
      return empty;
    }
    final Object? flutter = document['flutter'];
    if (flutter is! Map) {
      return empty;
    }

    return _hash(
      _canonical(<String, Object?>{
        'assets': _plain(flutter['assets']),
        'fonts': _plain(flutter['fonts']),
      }),
    );
  }

  /// `.flutter-plugins-dependencies` を正規化してからハッシュする。
  ///
  /// **そのままハッシュしない。** この生成物には `date_created` が入る。
  /// `flutter pub get` を打ち直しただけで指紋が変わり、毎回 APK を
  /// 作り直すことになる。
  static String _hashPlugins(String path) {
    final File file = File(path);
    if (!file.existsSync()) {
      return empty;
    }

    final Object? document;
    try {
      document = jsonDecode(file.readAsStringSync());
    } on FormatException catch (error) {
      throw FingerprintException(
        '.flutter-plugins-dependencies を JSON として読めません: ${error.message}',
        path: path,
      );
    }
    if (document is! Map<String, Object?>) {
      return empty;
    }

    // 見るのは plugins と dependencyGraph だけ。生成時刻は落とす。
    return _hash(
      _canonical(<String, Object?>{
        'plugins': document['plugins'],
        'dependencyGraph': document['dependencyGraph'],
      }),
    );
  }

  static List<File> _androidManifests(String root) {
    final Directory src = Directory(p.join(root, 'android', 'app', 'src'));
    if (!src.existsSync()) {
      return const <File>[];
    }
    return <File>[
      for (final FileSystemEntity entity in _walk(src))
        if (entity is File && p.basename(entity.path) == 'AndroidManifest.xml')
          entity,
    ];
  }

  static List<File> _gradleFiles(String root) {
    final Directory android = Directory(p.join(root, 'android'));
    if (!android.existsSync()) {
      return const <File>[];
    }
    return <File>[
      for (final FileSystemEntity entity in _walk(android))
        if (entity is File && _isGradleFile(p.basename(entity.path))) entity,
    ];
  }

  static bool _isGradleFile(String name) =>
      name.endsWith('.gradle') ||
      name.endsWith('.gradle.kts') ||
      name == 'gradle.properties' ||
      name == 'gradle-wrapper.properties';

  /// `android.native` を二段構えで求める。
  static Future<_NativeDigest> _computeNative(
    String root,
    Fingerprint? previous,
  ) async {
    const List<String> targets = <String>['java', 'kotlin', 'jni', 'res'];
    final List<File> files = <File>[];
    for (final String name in targets) {
      final Directory dir = Directory(
        p.join(root, 'android', 'app', 'src', 'main', name),
      );
      if (!dir.existsSync()) {
        continue;
      }
      for (final FileSystemEntity entity in _walk(dir)) {
        if (entity is File) {
          files.add(entity);
        }
      }
    }
    files.sort((File a, File b) => a.path.compareTo(b.path));

    // 一次判定。中身を読まずに済ませられるか見る。
    final StringBuffer stampSource = StringBuffer();
    for (final File file in files) {
      final FileStat stat = file.statSync();
      stampSource
        ..write(_relative(file.path, root))
        ..write(' ')
        ..write(stat.modified.microsecondsSinceEpoch)
        ..write(' ')
        ..write(stat.size)
        ..write('\n');
    }
    final String stamp = _hash(stampSource.toString());

    final String? reused = previous?.entries[keyAndroidNative];
    if (reused != null && previous?.nativeStamp == stamp) {
      // 触られていない。**中身は読まない。** res/ は数千ファイルになり、
      // 毎回読むと起動のたびに待たされる（設計 §8.2-7）。
      return _NativeDigest(content: reused, stamp: stamp);
    }

    return _NativeDigest(content: await _hashFiles(files, root), stamp: stamp);
  }

  // ------------------------------------------------------------------ 道具

  /// 生成物を避けながら辿る。
  static Iterable<FileSystemEntity> _walk(Directory root) sync* {
    final List<Directory> pending = <Directory>[root];
    while (pending.isNotEmpty) {
      final Directory current = pending.removeLast();
      final List<FileSystemEntity> children;
      try {
        children = current.listSync(followLinks: false);
      } on FileSystemException catch (error) {
        // **黙って飛ばさない。** その配下の変更が指紋に入らなくなり、
        // 直したのに反映されない理由が分からなくなる。
        throw FingerprintException(
          'ディレクトリを辿れません: ${error.message}',
          path: current.path,
        );
      }
      for (final FileSystemEntity entity in children) {
        if (entity is Directory) {
          if (ignoredDirs.contains(p.basename(entity.path))) {
            continue;
          }
          pending.add(entity);
        } else if (entity is File) {
          yield entity;
        }
      }
    }
  }

  /// 相対パス順に並べ、パスと中身の両方を混ぜてハッシュする。
  ///
  /// **中身だけでは足りない。** ファイル名を変えただけの変更を取りこぼす。
  static Future<String> _hashFiles(List<File> files, String root) async {
    if (files.isEmpty) {
      return empty;
    }
    final List<File> sorted = List<File>.of(files)
      ..sort((File a, File b) => a.path.compareTo(b.path));

    final StringBuffer buffer = StringBuffer();
    for (final File file in sorted) {
      final Digest content = sha256.convert(await file.readAsBytes());
      buffer
        ..write(_relative(file.path, root))
        ..write(' ')
        ..write(content)
        ..write('\n');
    }
    return _hash(buffer.toString());
  }

  /// 区切りを `/` に揃えた相対パス。
  ///
  /// **OS の区切りをそのまま混ぜない。** Windows と macOS で同じ
  /// プロジェクトの指紋が変わってしまう。
  static String _relative(String path, String root) =>
      p.split(p.relative(path, from: root)).join('/');

  static String _hash(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  /// キーを並べ替えて、書き順に左右されない文字列にする。
  static String _canonical(Object? node) {
    if (node is Map) {
      final List<String> keys = node.keys.map((Object? key) => '$key').toList()
        ..sort();
      return '{${keys.map((String key) => '${jsonEncode(key)}:${_canonical(node[key])}').join(',')}}';
    }
    if (node is List) {
      return '[${node.map(_canonical).join(',')}]';
    }
    return jsonEncode(node);
  }

  /// YAML のノードを素の Dart の値に落とす。
  static Object? _plain(Object? node) {
    if (node is YamlMap) {
      return <String, Object?>{
        for (final MapEntry<Object?, Object?> entry in node.entries)
          '${entry.key}': _plain(entry.value),
      };
    }
    if (node is YamlList) {
      return node.map(_plain).toList();
    }
    return node;
  }

  /// 必ずあるはずのファイルをハッシュする。
  ///
  /// **無ければ [empty] に倒さない。** 「対象が1つも無い」と同じ値になり、
  /// 欠けていること自体に気づけないまま指紋が成立してしまう。
  static Future<String> _hashRequiredFile(String path) async {
    final File file = File(path);
    if (!file.existsSync()) {
      throw FingerprintException('指紋の対象が見つかりません', path: path);
    }
    return sha256.convert(await file.readAsBytes()).toString();
  }

  @override
  String toString() => 'Fingerprint(${entries.length}キー)';
}

/// `android.native` の計算結果。
final class _NativeDigest {
  const _NativeDigest({required this.content, required this.stamp});

  /// 中身から作った正準の値。
  final String content;

  /// パス・mtime・サイズから作った一次判定用の値。
  final String stamp;
}
