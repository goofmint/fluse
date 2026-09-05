import 'dart:convert';
import 'dart:io';

import 'package:fluse_server/fluse_server.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late File file;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('fluse_asset_cache_');
    file = File(p.join(temp.path, '.flutter_preview', 'cache', 'assets.json'));
  });

  tearDown(() => temp.deleteSync(recursive: true));

  AssetCacheEntry entry(String path, String digest) => AssetCacheEntry(
    archivePath: path,
    sizeBytes: 12,
    mtimeMillis: 1700000000000,
    sha256: digest,
  );

  test('ファイルが無ければ空として開ける', () {
    // 初回同期の前に無いのは正常。落とすと最初の start が必ず失敗する。
    final AssetCache cache = AssetCache.readFrom(file);

    expect(cache.length, 0);
    expect(cache['assets/logo.png'], isNull);
  });

  test('書いて読み直すと同じ内容になる', () {
    AssetCache(<String, AssetCacheEntry>{
      'assets/logo.png': entry('assets/logo.png', 'aaaa'),
      'AssetManifest.json': entry('AssetManifest.json', 'bbbb'),
    }).writeTo(file);

    final AssetCache reopened = AssetCache.readFrom(file);

    expect(reopened.length, 2);
    expect(reopened['assets/logo.png']?.sha256, 'aaaa');
    expect(reopened['assets/logo.png']?.sizeBytes, 12);
    expect(reopened['assets/logo.png']?.mtimeMillis, 1700000000000);
  });

  test('親ディレクトリが無くても書ける', () {
    expect(file.parent.existsSync(), isFalse);

    AssetCache(<String, AssetCacheEntry>{'a': entry('a', 'x')}).writeTo(file);

    expect(file.existsSync(), isTrue);
  });

  test('一時ファイルを残さない', () {
    AssetCache(<String, AssetCacheEntry>{'a': entry('a', 'x')}).writeTo(file);

    expect(File('${file.path}.tmp').existsSync(), isFalse);
  });

  group('壊れた assets.json', () {
    void write(Object? content) {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(content is String ? content : jsonEncode(content));
    }

    test('JSON として読めなければ失敗する', () {
      // 黙って空にすると全件転送になり、原因が分からないまま遅くなる。
      write('{ぐちゃ');

      expect(
        () => AssetCache.readFrom(file),
        throwsA(isA<AssetCacheException>()),
      );
    });

    test('JSON オブジェクトでなければ失敗する', () {
      write(<Object?>[]);

      expect(
        () => AssetCache.readFrom(file),
        throwsA(isA<AssetCacheException>()),
      );
    });

    test('schemaVersion が無ければ失敗する', () {
      write(<String, Object?>{'assets': <String, Object?>{}});

      expect(
        () => AssetCache.readFrom(file),
        throwsA(isA<AssetCacheException>()),
      );
    });

    test('未対応の新しい schemaVersion は拒否する', () {
      write(<String, Object?>{
        'schemaVersion': AssetCache.currentSchemaVersion + 1,
        'assets': <String, Object?>{},
      });

      expect(
        () => AssetCache.readFrom(file),
        throwsA(
          isA<AssetCacheException>().having(
            (AssetCacheException e) => e.message,
            'message',
            contains('未対応'),
          ),
        ),
      );
    });

    test('sha256 が欠けていれば失敗する', () {
      write(<String, Object?>{
        'schemaVersion': AssetCache.currentSchemaVersion,
        'assets': <String, Object?>{
          'a': <String, Object?>{'sizeBytes': 1, 'mtimeMillis': 2},
        },
      });

      expect(
        () => AssetCache.readFrom(file),
        throwsA(isA<AssetCacheException>()),
      );
    });
  });
}
