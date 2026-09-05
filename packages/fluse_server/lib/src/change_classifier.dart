/// 変更ファイルの分類（設計 §2.2.2 / §3.2）。
///
/// 反映の仕方が3通りあるので、まず何が変わったかを見分ける。
library;

import 'package:path/path.dart' as p;

/// 変更の種類。
enum ChangeKind {
  /// `lib/` 配下の Dart。増分コンパイルの対象。
  dartSource,

  /// `pubspec.yaml` の `flutter:` で宣言された asset。DevFS へ転送する。
  asset,

  /// 変わると APK を作り直すしかないもの（設計 §2.2.2 の指紋対象）。
  fingerprintTarget,

  /// どれでもない。無視する。
  ignored,
}

/// debounce で畳んだ1回分の変更。
final class ChangeSet {
  ChangeSet({
    required Set<String> dartSources,
    required Set<String> assets,
    required Set<String> fingerprintTargets,
  }) : dartSources = Set<String>.unmodifiable(dartSources),
       assets = Set<String>.unmodifiable(assets),
       fingerprintTargets = Set<String>.unmodifiable(fingerprintTargets);

  /// 変更された Dart ソースの絶対パス。
  final Set<String> dartSources;

  /// 変更された asset の絶対パス。
  final Set<String> assets;

  /// 変更された指紋対象の絶対パス。
  ///
  /// **1つでもあれば APK の作り直しが要る。** 増分コンパイルでは埋められない
  /// 差分なので、Watch を止めて `fluse rebuild` に誘導する（設計 §3.2）。
  final Set<String> fingerprintTargets;

  /// 反映すべき変更があるか。
  bool get isEmpty =>
      dartSources.isEmpty && assets.isEmpty && fingerprintTargets.isEmpty;

  /// 指紋対象が含まれるか。
  bool get requiresRebuild => fingerprintTargets.isNotEmpty;

  @override
  String toString() =>
      'ChangeSet(dart: ${dartSources.length}, asset: ${assets.length}, '
      'fingerprint: ${fingerprintTargets.length})';
}

/// パスを [ChangeKind] に振り分ける。
///
/// 判定はプロジェクトルートからの相対パスで行う。絶対パスのまま比べると、
/// シンボリックリンク経由やケース差のあるファイルシステムで取りこぼす。
final class ChangeClassifier {
  ChangeClassifier({
    required String projectRoot,
    Set<String> assetPaths = const <String>{},
  }) : projectRoot = p.normalize(p.absolute(projectRoot)),
       // **末尾の `/` を残す。** normalize は落としてしまうが、Flutter の
       // 宣言ではディレクトリかどうかの唯一の手がかりになっている。
       _assetPaths = assetPaths.map((String path) {
         final String posix = _toPosix(path);
         final String normalized = p.posix.normalize(posix);
         return posix.endsWith('/') ? '$normalized/' : normalized;
       }).toSet();

  /// プロジェクトの絶対パス。
  final String projectRoot;

  /// `pubspec.yaml` の `flutter:` で宣言された asset。
  ///
  /// ディレクトリ宣言（末尾 `/`）は配下すべてを含む。Flutter の宣言規則に
  /// 合わせてある。
  final Set<String> _assetPaths;

  /// 指紋対象になる固定ファイル（設計 §2.2.2）。
  static const Set<String> fingerprintFiles = <String>{
    'pubspec.lock',
    // asset / fonts の宣言そのものが変わると APK の同梱物が変わる。
    'pubspec.yaml',
    '.flutter-plugins-dependencies',
  };

  /// 指紋対象になる `android/` 配下のファイル名。
  static const Set<String> fingerprintAndroidFileNames = <String>{
    'AndroidManifest.xml',
    'gradle.properties',
    'gradle-wrapper.properties',
  };

  /// `android/app/src/main/` 配下で指紋対象になるディレクトリ。
  static const Set<String> fingerprintNativeDirs = <String>{
    'java',
    'kotlin',
    'jni',
    'res',
  };

  /// プロジェクト直下にあれば中身を見ないディレクトリ。
  ///
  /// ツールの出力先。ここを見ると自分の書き込みで変更を検出し続ける。
  static const Set<String> generatedRootDirs = <String>{
    'build',
    '.dart_tool',
    '.flutter_preview',
    '.git',
    '.idea',
  };

  /// どの階層にあっても中身を見ないディレクトリ。
  ///
  /// Gradle はモジュールごとに `build/` を作り、その中に**マージ済みの
  /// `AndroidManifest.xml`** を生成する。名前だけで指紋対象と判定すると、
  /// ビルドのたびに監視が止まる。
  static const Set<String> generatedAndroidDirs = <String>{
    'build',
    '.gradle',
    '.cxx',
  };

  /// [path] の種類を返す。相対パスはプロジェクトルート基準で解決する。
  ChangeKind classify(String path) {
    // `p.absolute(a, b)` は「b を基準に a を解く」ではなく **結合** なので
    // ここでは使えない。第2引数が絶対パスだと結果がそれに置き換わる。
    final String absolute = p.normalize(
      p.isAbsolute(path) ? path : p.join(projectRoot, path),
    );
    if (!p.isWithin(projectRoot, absolute)) {
      // プロジェクトの外は見ない。監視の網から漏れたイベントが来ても
      // 誤って rebuild を要求しないため。
      return ChangeKind.ignored;
    }

    final String relative = _toPosix(p.relative(absolute, from: projectRoot));

    if (_isGenerated(relative)) {
      return ChangeKind.ignored;
    }

    if (_isFingerprintTarget(relative)) {
      // **asset より先に見る。** pubspec.yaml は両方に当たるが、
      // 宣言が変われば APK を作り直すしかない。
      return ChangeKind.fingerprintTarget;
    }
    if (_isDartSource(relative)) {
      return ChangeKind.dartSource;
    }
    if (_isAsset(relative)) {
      return ChangeKind.asset;
    }
    return ChangeKind.ignored;
  }

  /// ツールが作ったファイルか。
  ///
  /// **指紋の判定より先に落とす。** そうしないと、Gradle が生成した
  /// `android/app/build/.../AndroidManifest.xml` を指紋対象と見なして
  /// 監視が止まる。`build/` と `.dart_tool/` を監視から外した意図と
  /// 同じことを、分類の側でも守る必要がある。
  bool _isGenerated(String relative) {
    final List<String> segments = relative.split('/');
    if (segments.isEmpty) {
      return false;
    }
    if (generatedRootDirs.contains(segments.first)) {
      return true;
    }
    // Gradle はモジュールごとに build/ を持つ。深さは決め打ちできない。
    // lib/build/ のような利用者のディレクトリまで巻き込まないよう、
    // android/ の中だけを対象にする。
    if (segments.first == 'android') {
      for (final String segment in segments.skip(1)) {
        if (generatedAndroidDirs.contains(segment)) {
          return true;
        }
      }
    }
    return false;
  }

  bool _isDartSource(String relative) =>
      relative.endsWith('.dart') && p.posix.isWithin('lib', relative);

  bool _isAsset(String relative) {
    for (final String declared in _assetPaths) {
      if (declared.endsWith('/')) {
        // ディレクトリ宣言は配下すべて。
        if (p.posix.isWithin(declared, relative)) {
          return true;
        }
        continue;
      }
      if (declared == relative) {
        return true;
      }
      // 解像度別バリアント（assets/2.0x/logo.png）も同じ asset の一部。
      // 宣言に無くても Flutter は同梱するので、ここでも拾う。
      if (p.posix.basename(declared) == p.posix.basename(relative) &&
          p.posix.isWithin(p.posix.dirname(declared), relative)) {
        return true;
      }
    }
    return false;
  }

  bool _isFingerprintTarget(String relative) {
    if (fingerprintFiles.contains(relative)) {
      return true;
    }
    if (!p.posix.isWithin('android', relative)) {
      return false;
    }

    final String name = p.posix.basename(relative);
    if (fingerprintAndroidFileNames.contains(name)) {
      return true;
    }
    if (name.endsWith('.gradle') || name.endsWith('.gradle.kts')) {
      return true;
    }

    // android/app/src/main/{java,kotlin,jni,res}/**
    const String nativeRoot = 'android/app/src/main';
    if (p.posix.isWithin(nativeRoot, relative)) {
      final List<String> rest = p.posix
          .relative(relative, from: nativeRoot)
          .split('/');
      if (rest.isNotEmpty && fingerprintNativeDirs.contains(rest.first)) {
        return true;
      }
    }
    return false;
  }
}

/// Windows の区切りも `/` に揃える。判定を1通りに保つため。
String _toPosix(String path) => path.replaceAll(r'\', '/');
