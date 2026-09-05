import 'dart:convert';
import 'dart:io';

/// `assets.json` の読み書きに失敗したときに投げる。
final class AssetCacheException implements Exception {
  const AssetCacheException(this.message);

  final String message;

  @override
  String toString() => 'asset_cache: $message';
}

/// 前回同期した asset 1件の指紋。
final class AssetCacheEntry {
  const AssetCacheEntry({
    required this.archivePath,
    required this.sizeBytes,
    required this.mtimeMillis,
    required this.sha256,
  });

  /// `assets/images/logo.png` の形。DevFS 上のパスの元になる。
  final String archivePath;

  final int sizeBytes;

  /// 最終更新時刻（エポックミリ秒）。
  ///
  /// size と併せて**内容ハッシュを省くための一次判定**に使う
  /// （設計 §8.2-7）。一致しても内容が同じとは限らないが、
  /// 変わっていれば確実に読み直す必要がある。
  final int mtimeMillis;

  /// 内容の sha256（16進）。差分判定の最終的な根拠。
  final String sha256;

  Map<String, Object?> toJson() => <String, Object?>{
    'sizeBytes': sizeBytes,
    'mtimeMillis': mtimeMillis,
    'sha256': sha256,
  };

  static AssetCacheEntry fromJson(String archivePath, Object? json) {
    if (json is! Map<String, Object?>) {
      throw AssetCacheException('$archivePath の記録が JSON オブジェクトではありません');
    }

    final Object? size = json['sizeBytes'];
    if (size is! int) {
      throw AssetCacheException('$archivePath の sizeBytes が整数ではありません');
    }
    final Object? mtime = json['mtimeMillis'];
    if (mtime is! int) {
      throw AssetCacheException('$archivePath の mtimeMillis が整数ではありません');
    }
    final Object? digest = json['sha256'];
    if (digest is! String || digest.isEmpty) {
      throw AssetCacheException('$archivePath の sha256 が文字列ではありません');
    }

    return AssetCacheEntry(
      archivePath: archivePath,
      sizeBytes: size,
      mtimeMillis: mtime,
      sha256: digest,
    );
  }

  @override
  String toString() => 'AssetCacheEntry($archivePath, $sizeBytes bytes)';
}

/// 前回同期した asset の一覧（設計 §8.2-6）。
///
/// `.flutter_preview/cache/assets.json` に持つ。毎回全部を送らずに
/// 済ませるための記録なので、**壊れていたら空として扱わない**。
/// 黙って空にすると全件転送になり、原因が分からないまま遅くなる。
final class AssetCache {
  AssetCache(Map<String, AssetCacheEntry> entries)
    : _entries = Map<String, AssetCacheEntry>.of(entries);

  /// 空のキャッシュ。
  AssetCache.empty() : _entries = <String, AssetCacheEntry>{};

  /// このファイル形式の版。
  static const int currentSchemaVersion = 1;

  final Map<String, AssetCacheEntry> _entries;

  /// 記録されている archivePath。
  Iterable<String> get archivePaths => _entries.keys;

  int get length => _entries.length;

  AssetCacheEntry? operator [](String archivePath) => _entries[archivePath];

  /// [file] から読む。**存在しなければ空として扱う。**
  ///
  /// 初回同期の前にファイルが無いのは正常。ここで失敗させると
  /// 最初の `fluse start` が必ず落ちる。
  static AssetCache readFrom(File file) {
    if (!file.existsSync()) {
      return AssetCache.empty();
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(file.readAsStringSync());
    } on FormatException catch (error) {
      throw AssetCacheException(
        '${file.path} を JSON として読めません: ${error.message}',
      );
    }

    if (decoded is! Map<String, Object?>) {
      throw AssetCacheException('${file.path} が JSON オブジェクトではありません');
    }

    final Object? version = decoded['schemaVersion'];
    if (version is! int) {
      throw AssetCacheException('${file.path} の schemaVersion が整数ではありません');
    }
    if (version > currentSchemaVersion) {
      throw AssetCacheException(
        '${file.path} の schemaVersion $version は未対応です'
        '（対応は $currentSchemaVersion まで）',
      );
    }

    final Object? assets = decoded['assets'];
    if (assets is! Map<String, Object?>) {
      throw AssetCacheException('${file.path} の assets が JSON オブジェクトではありません');
    }

    return AssetCache(<String, AssetCacheEntry>{
      for (final MapEntry<String, Object?> entry in assets.entries)
        entry.key: AssetCacheEntry.fromJson(entry.key, entry.value),
    });
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': currentSchemaVersion,
    'assets': <String, Object?>{
      for (final MapEntry<String, AssetCacheEntry> entry in _entries.entries)
        entry.key: entry.value.toJson(),
    },
  };

  /// [file] へ書き出す。
  ///
  /// **一時ファイルへ書いてから差し替える。** 途中で落ちると半端な JSON が
  /// 残り、次回の起動が読めずに失敗する。
  void writeTo(File file) {
    file.parent.createSync(recursive: true);

    final File staging = File('${file.path}.tmp');
    try {
      staging.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(toJson()),
      );
      staging.renameSync(file.path);
    } on Object {
      if (staging.existsSync()) {
        staging.deleteSync();
      }
      rethrow;
    }
  }
}
