import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'asset_cache.dart';
import 'asset_manifest_parser.dart';
import 'dev_fs_client.dart';
import 'fluse_logger.dart';
import 'hot_reload_orchestrator.dart';

/// 1回の同期で送るもの・消すもの。
final class AssetSyncResult {
  const AssetSyncResult({required this.changed, required this.removed});

  /// 追加・変更された asset。そのまま
  /// [HotReloadOrchestrator.reload] の `changedAssets` に渡せる。
  final List<ChangedAsset> changed;

  /// 宣言から消えた asset の archivePath。
  ///
  /// **DevFS 上のファイルは消せない。** DevFS に削除の API が無いため、
  /// マニフェストから外して参照されないようにするのが実質的な削除になる。
  final List<String> removed;

  bool get isEmpty => changed.isEmpty && removed.isEmpty;

  @override
  String toString() =>
      'AssetSyncResult(changed: ${changed.length}, removed: ${removed.length})';
}

/// asset を集めて差分だけを DevFS 用に組み立てる（設計 §2.2.3(b) / §8.2-6）。
///
/// **毎回全部は送らない。** 中規模アプリの asset は数十MBになり、
/// 1ファイル変えるたびに送り直すと反映が秒単位で遅れる。
/// `archivePath -> (size, mtime, sha256)` を覚えておき、変わった分だけ送る。
final class AssetBundleService {
  AssetBundleService({
    required String projectRoot,
    String? cachePath,
    FluseLogger? logger,
  }) : projectRoot = p.normalize(p.absolute(projectRoot)),
       _cacheFile = File(
         cachePath ??
             p.join(
               p.normalize(p.absolute(projectRoot)),
               '.flutter_preview',
               'cache',
               'assets.json',
             ),
       ),
       _logger = logger;

  /// DevFS 上で asset が置かれる場所。
  ///
  /// flutter_tools と同じ配置。ここを変えると端末側が見つけられない。
  static const String devFsAssetRoot = 'build/flutter_assets';

  /// 論理 asset とバリアントの対応表。
  static const String assetManifestName = 'AssetManifest.json';

  /// フォントの一覧。
  static const String fontManifestName = 'FontManifest.json';

  /// 解像度バリアントのディレクトリ名（`2.0x` など）。
  static final RegExp _variantDir = RegExp(r'^\d+(\.\d+)?x$');

  /// プロジェクトの絶対パス。
  final String projectRoot;

  final File _cacheFile;
  final FluseLogger? _logger;

  /// キャッシュの保存先。
  File get cacheFile => _cacheFile;

  /// `pubspec.yaml` を読み直して差分を組み立てる。
  ///
  /// 実行のたびにキャッシュを書き戻す。**書けなければ例外にする。**
  /// 黙って続けると、次回に同じ差分をもう一度送ることになる。
  AssetSyncResult sync() {
    final AssetDeclarations declarations = _readDeclarations();
    final _Bundle bundle = _resolve(declarations);
    final AssetCache previous = AssetCache.readFrom(_cacheFile);

    final List<ChangedAsset> changed = <ChangedAsset>[];
    final Map<String, AssetCacheEntry> next = <String, AssetCacheEntry>{};

    for (final _ResolvedAsset asset in bundle.assets) {
      final FileStat stat = asset.file.statSync();
      final int mtime = stat.modified.millisecondsSinceEpoch;
      final AssetCacheEntry? cached = previous[asset.archivePath];

      // size と mtime が両方一致していれば読み直さない（設計 §8.2-7）。
      // 数十MBの asset を毎回ハッシュすると、変更が無くても遅くなる。
      if (cached != null &&
          cached.sizeBytes == stat.size &&
          cached.mtimeMillis == mtime) {
        next[asset.archivePath] = cached;
        continue;
      }

      final List<int> bytes = asset.file.readAsBytesSync();
      final String digest = sha256.convert(bytes).toString();
      next[asset.archivePath] = AssetCacheEntry(
        archivePath: asset.archivePath,
        sizeBytes: bytes.length,
        mtimeMillis: mtime,
        sha256: digest,
      );

      if (cached != null && cached.sha256 == digest) {
        // 触っただけで中身は同じ。保存し直しただけの場合に起こる。
        continue;
      }
      changed.add(
        ChangedAsset(
          deviceUri: _deviceUri(asset.archivePath),
          content: DevFSContent(bytes),
          archivePath: asset.archivePath,
        ),
      );
    }

    // マニフェストも asset の1つとして同じ流れに乗せる。宣言が変われば
    // 中身が変わるので、内容ハッシュで送るかどうかを決める。
    for (final MapEntry<String, String> manifest in <String, String>{
      assetManifestName: _buildAssetManifest(bundle),
      fontManifestName: _buildFontManifest(declarations),
    }.entries) {
      final List<int> bytes = utf8.encode(manifest.value);
      final String digest = sha256.convert(bytes).toString();
      final AssetCacheEntry? cached = previous[manifest.key];
      next[manifest.key] = AssetCacheEntry(
        archivePath: manifest.key,
        // マニフェストは実ファイルではないので mtime を持たない。
        // 判定は常に内容ハッシュで行う。
        sizeBytes: bytes.length,
        mtimeMillis: 0,
        sha256: digest,
      );
      if (cached?.sha256 == digest) {
        continue;
      }
      changed.add(
        ChangedAsset(
          deviceUri: _deviceUri(manifest.key),
          content: DevFSContent(bytes),
          archivePath: manifest.key,
        ),
      );
    }

    final List<String> removed = <String>[
      for (final String archivePath in previous.archivePaths)
        if (!next.containsKey(archivePath)) archivePath,
    ]..sort();

    AssetCache(next).writeTo(_cacheFile);

    _logger?.debug(
      'asset の差分を作りました',
      fields: <String, Object?>{
        'changed': changed.length,
        'removed': removed.length,
        'total': next.length,
      },
    );
    return AssetSyncResult(changed: changed, removed: removed);
  }

  // ------------------------------------------------------------- 宣言の解決

  AssetDeclarations _readDeclarations() {
    final File pubspec = File(p.join(projectRoot, 'pubspec.yaml'));
    if (!pubspec.existsSync()) {
      throw AssetManifestException('${pubspec.path} がありません');
    }
    return AssetManifestParser.parse(pubspec.readAsStringSync());
  }

  /// 宣言を実ファイルへ展開する。
  _Bundle _resolve(AssetDeclarations declarations) {
    // 同じファイルが複数の宣言から来ることがある。archivePath で束ねる。
    final Map<String, _ResolvedAsset> resolved = <String, _ResolvedAsset>{};
    // 論理 asset -> バリアントの archivePath。AssetManifest.json の元。
    final Map<String, Set<String>> variants = <String, Set<String>>{};

    void addFile(File file, {String? logicalKey}) {
      final String archivePath = _archivePath(file.path);
      resolved[archivePath] = _ResolvedAsset(
        archivePath: archivePath,
        file: file,
      );
      if (logicalKey != null) {
        (variants[logicalKey] ??= <String>{}).add(archivePath);
      }
    }

    for (final String declaration in declarations.assets) {
      if (declaration.endsWith('/')) {
        _resolveDirectory(declaration, addFile, variants);
        continue;
      }

      final File file = File(p.join(projectRoot, declaration));
      if (!file.existsSync()) {
        // 宣言と実体の食い違いは利用者の誤りだが、ここで落とすと
        // 1ファイルの打ち間違いで起動できなくなる。記録して続ける。
        _logger?.warn(
          '宣言された asset がありません',
          fields: <String, Object?>{'asset': declaration},
        );
        continue;
      }

      final String logicalKey = _archivePath(file.path);
      addFile(file, logicalKey: logicalKey);
      for (final File variant in _variantsOf(file)) {
        addFile(variant, logicalKey: logicalKey);
      }
    }

    for (final FontFamily family in declarations.fonts) {
      for (final FontAsset font in family.fonts) {
        final File file = File(p.join(projectRoot, font.asset));
        if (!file.existsSync()) {
          _logger?.warn(
            '宣言されたフォントがありません',
            fields: <String, Object?>{'asset': font.asset},
          );
          continue;
        }
        // フォントは AssetManifest.json に載らない。FontManifest.json が
        // 参照するので、バリアントの束ねも要らない。
        addFile(file);
      }
    }

    return _Bundle(
      assets: resolved.values.toList()
        ..sort(
          (_ResolvedAsset a, _ResolvedAsset b) =>
              a.archivePath.compareTo(b.archivePath),
        ),
      variants: variants,
    );
  }

  /// ディレクトリ宣言を展開する。
  ///
  /// **直下のファイルだけ。** Flutter は再帰しない。再帰させると、
  /// `assets/` の下に置いた作業用ディレクトリまで APK に入ってしまう。
  /// ただし解像度バリアント（`2.0x/`）だけは例外で、基底に紐付ける。
  void _resolveDirectory(
    String declaration,
    void Function(File file, {String? logicalKey}) addFile,
    Map<String, Set<String>> variants,
  ) {
    final Directory directory = Directory(p.join(projectRoot, declaration));
    if (!directory.existsSync()) {
      _logger?.warn(
        '宣言された asset ディレクトリがありません',
        fields: <String, Object?>{'asset': declaration},
      );
      return;
    }

    for (final FileSystemEntity entity in directory.listSync()) {
      if (entity is! File) {
        continue;
      }
      final String logicalKey = _archivePath(entity.path);
      addFile(entity, logicalKey: logicalKey);
      for (final File variant in _variantsOf(entity)) {
        addFile(variant, logicalKey: logicalKey);
      }
    }
  }

  /// [base] の解像度バリアント（`<dir>/2.0x/<name>`）を集める。
  List<File> _variantsOf(File base) {
    final Directory parent = base.parent;
    if (!parent.existsSync()) {
      return const <File>[];
    }

    final String name = p.basename(base.path);
    final List<File> found = <File>[];
    for (final FileSystemEntity entity in parent.listSync()) {
      if (entity is! Directory) {
        continue;
      }
      if (!_variantDir.hasMatch(p.basename(entity.path))) {
        continue;
      }
      final File candidate = File(p.join(entity.path, name));
      if (candidate.existsSync()) {
        found.add(candidate);
      }
    }
    return found;
  }

  // --------------------------------------------------------- マニフェスト

  /// 論理 asset からバリアント一覧への対応表。
  ///
  /// 端末側はこれを見て、画面の解像度に合うファイルを選ぶ。
  /// **基底自身も一覧に含める**（1.0x として扱われる）。
  String _buildAssetManifest(_Bundle bundle) {
    final Map<String, List<String>> manifest = <String, List<String>>{
      for (final MapEntry<String, Set<String>> entry in bundle.variants.entries)
        entry.key: entry.value.toList()..sort(),
    };
    // キーの順を安定させる。順序が揺れると、中身が同じでもハッシュが
    // 変わって毎回転送されてしまう。
    final List<String> keys = manifest.keys.toList()..sort();
    return jsonEncode(<String, Object?>{
      for (final String key in keys) key: manifest[key],
    });
  }

  String _buildFontManifest(AssetDeclarations declarations) =>
      jsonEncode(<Object?>[
        for (final FontFamily family in declarations.fonts) family.toJson(),
      ]);

  // --------------------------------------------------------------- パス計算

  /// プロジェクトルートからの POSIX 相対パス。
  String _archivePath(String path) =>
      p.relative(p.normalize(path), from: projectRoot).replaceAll(r'\', '/');

  /// DevFS 上の書き込み先。
  Uri _deviceUri(String archivePath) =>
      Uri.parse('$devFsAssetRoot/$archivePath');
}

/// 解決済みの asset 1件。
final class _ResolvedAsset {
  const _ResolvedAsset({required this.archivePath, required this.file});

  final String archivePath;
  final File file;
}

/// 解決結果。
final class _Bundle {
  const _Bundle({required this.assets, required this.variants});

  final List<_ResolvedAsset> assets;

  /// 論理 asset -> バリアントの archivePath。
  final Map<String, Set<String>> variants;
}
