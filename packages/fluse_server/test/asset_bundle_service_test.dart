import 'dart:convert';
import 'dart:io';

import 'package:fluse_server/fluse_server.dart';
import 'package:fluse_server/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late Directory outside;
  late String root;
  late MemoryLogSink sink;
  late FluseLogger logger;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('fluse_assets_');
    // プロジェクト外に置くファイルの行き先。固定名を使うと、並列実行の
    // テスト同士が同じファイルを取り合う。
    outside = Directory.systemTemp.createTempSync('fluse_outside_');
    root = temp.path;
    sink = MemoryLogSink();
    logger = FluseLogger(
      sinks: <FluseLogSink>[sink],
      minimumLevel: FluseLogLevel.debug,
    );
  });

  tearDown(() {
    temp.deleteSync(recursive: true);
    outside.deleteSync(recursive: true);
  });

  void writePubspec(String flutterSection) {
    File(p.join(root, 'pubspec.yaml')).writeAsStringSync('''
name: sample
flutter:
$flutterSection
''');
  }

  File writeFile(String relative, String content) {
    final File file = File(p.join(root, relative))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(content);
    return file;
  }

  AssetBundleService build() =>
      AssetBundleService(projectRoot: root, logger: logger);

  /// 変更として列挙された archivePath。マニフェストは除く。
  Set<String> changedAssets(AssetSyncResult result) => result.changed
      .map((ChangedAsset a) => a.archivePath)
      .where(
        (String path) =>
            path != AssetBundleService.assetManifestName &&
            path != AssetBundleService.fontManifestName,
      )
      .toSet();

  ChangedAsset manifest(AssetSyncResult result, String name) =>
      result.changed.firstWhere((ChangedAsset a) => a.archivePath == name);

  group('差分列挙', () {
    test('初回はすべて追加になる', () {
      writePubspec('  assets:\n    - assets/logo.png\n');
      writeFile('assets/logo.png', 'v1');

      final AssetSyncResult result = build().sync();

      expect(changedAssets(result), <String>{'assets/logo.png'});
      expect(result.removed, isEmpty);
    });

    test('変更が無ければ2回目は空になる', () {
      writePubspec('  assets:\n    - assets/logo.png\n');
      writeFile('assets/logo.png', 'v1');
      final AssetBundleService service = build();
      service.sync();

      final AssetSyncResult second = service.sync();

      expect(changedAssets(second), isEmpty);
      expect(second.changed, isEmpty, reason: 'マニフェストも変わらない');
      expect(second.removed, isEmpty);
    });

    test('内容を変えると変更として出る', () {
      writePubspec('  assets:\n    - assets/logo.png\n');
      final File asset = writeFile('assets/logo.png', 'v1');
      final AssetBundleService service = build();
      service.sync();

      // mtime の解像度が粗い環境でも size が変わるので確実に検出される。
      asset.writeAsStringSync('v2-changed');

      expect(changedAssets(service.sync()), <String>{'assets/logo.png'});
    });

    test('asset を足すと追加として出る', () {
      writePubspec('  assets:\n    - assets/a.png\n');
      writeFile('assets/a.png', 'a');
      final AssetBundleService service = build();
      service.sync();

      writePubspec('  assets:\n    - assets/a.png\n    - assets/b.png\n');
      writeFile('assets/b.png', 'b');

      expect(changedAssets(service.sync()), <String>{'assets/b.png'});
    });

    test('宣言から外すと削除として出る', () {
      writePubspec('  assets:\n    - assets/a.png\n    - assets/b.png\n');
      writeFile('assets/a.png', 'a');
      writeFile('assets/b.png', 'b');
      final AssetBundleService service = build();
      service.sync();

      writePubspec('  assets:\n    - assets/a.png\n');

      final AssetSyncResult result = service.sync();
      expect(result.removed, <String>['assets/b.png']);
      expect(changedAssets(result), isEmpty);
    });

    test('触っただけで中身が同じなら送らない', () {
      // 保存し直しただけで数十MBを送り直すのは無駄。
      writePubspec('  assets:\n    - assets/logo.png\n');
      final File asset = writeFile('assets/logo.png', 'same');
      final AssetBundleService service = build();
      service.sync();

      asset.setLastModifiedSync(
        DateTime.now().add(const Duration(seconds: 10)),
      );

      expect(changedAssets(service.sync()), isEmpty);
    });

    test('宣言された asset が無くても止まらない', () {
      // 1ファイルの打ち間違いで起動できなくなるのは困る。
      writePubspec('  assets:\n    - assets/missing.png\n');

      final AssetSyncResult result = build().sync();

      expect(changedAssets(result), isEmpty);
      expect(sink.lines.where((String l) => l.contains('ありません')), isNotEmpty);
    });
  });

  group('ディレクトリ宣言', () {
    test('直下のファイルを含める', () {
      writePubspec('  assets:\n    - assets/icons/\n');
      writeFile('assets/icons/a.png', 'a');
      writeFile('assets/icons/b.png', 'b');

      expect(changedAssets(build().sync()), <String>{
        'assets/icons/a.png',
        'assets/icons/b.png',
      });
    });

    test('サブディレクトリは再帰しない', () {
      // Flutter は再帰しない。させると作業用ディレクトリまで APK に入る。
      writePubspec('  assets:\n    - assets/icons/\n');
      writeFile('assets/icons/a.png', 'a');
      writeFile('assets/icons/nested/b.png', 'b');

      expect(changedAssets(build().sync()), <String>{'assets/icons/a.png'});
    });

    test('ディレクトリが無くても止まらない', () {
      writePubspec('  assets:\n    - assets/missing/\n');

      expect(changedAssets(build().sync()), isEmpty);
    });
  });

  group('解像度バリアント', () {
    test('2.0x / 3.0x を基底に紐付けて含める', () {
      writePubspec('  assets:\n    - assets/logo.png\n');
      writeFile('assets/logo.png', '1x');
      writeFile('assets/2.0x/logo.png', '2x');
      writeFile('assets/3.0x/logo.png', '3x');

      final AssetSyncResult result = build().sync();

      expect(changedAssets(result), <String>{
        'assets/logo.png',
        'assets/2.0x/logo.png',
        'assets/3.0x/logo.png',
      });

      final Object? decoded = jsonDecode(
        utf8.decode(
          manifest(result, AssetBundleService.assetManifestName).content.bytes,
        ),
      );
      expect((decoded! as Map<String, Object?>)['assets/logo.png'], <String>[
        'assets/2.0x/logo.png',
        'assets/3.0x/logo.png',
        'assets/logo.png',
      ]);
    });

    test('バリアントらしくないディレクトリは拾わない', () {
      writePubspec('  assets:\n    - assets/logo.png\n');
      writeFile('assets/logo.png', '1x');
      writeFile('assets/backup/logo.png', 'old');

      expect(changedAssets(build().sync()), <String>{'assets/logo.png'});
    });
  });

  group('マニフェスト', () {
    test('初回は両方とも送られる', () {
      writePubspec('  assets:\n    - assets/logo.png\n');
      writeFile('assets/logo.png', 'v1');

      final AssetSyncResult result = build().sync();

      expect(
        result.changed.map((ChangedAsset a) => a.archivePath),
        containsAll(<String>[
          AssetBundleService.assetManifestName,
          AssetBundleService.fontManifestName,
        ]),
      );
    });

    test('宣言が変わればマニフェストも送り直す', () {
      writePubspec('  assets:\n    - assets/a.png\n');
      writeFile('assets/a.png', 'a');
      final AssetBundleService service = build();
      service.sync();

      writePubspec('  assets:\n    - assets/a.png\n    - assets/b.png\n');
      writeFile('assets/b.png', 'b');

      expect(
        service.sync().changed.map((ChangedAsset a) => a.archivePath),
        contains(AssetBundleService.assetManifestName),
      );
    });

    test('削除でもマニフェストを送り直す', () {
      // 参照が残ると端末側が無いファイルを探しに行く。
      writePubspec('  assets:\n    - assets/a.png\n    - assets/b.png\n');
      writeFile('assets/a.png', 'a');
      writeFile('assets/b.png', 'b');
      final AssetBundleService service = build();
      service.sync();

      writePubspec('  assets:\n    - assets/a.png\n');

      expect(
        service.sync().changed.map((ChangedAsset a) => a.archivePath),
        contains(AssetBundleService.assetManifestName),
      );
    });

    test('FontManifest.json は宣言をそのまま写す', () {
      writePubspec('''
  fonts:
    - family: Inconsolata
      fonts:
        - asset: assets/fonts/Inconsolata-Regular.ttf
        - asset: assets/fonts/Inconsolata-Bold.ttf
          weight: 700
''');
      writeFile('assets/fonts/Inconsolata-Regular.ttf', 'r');
      writeFile('assets/fonts/Inconsolata-Bold.ttf', 'b');

      final AssetSyncResult result = build().sync();

      final Object? decoded = jsonDecode(
        utf8.decode(
          manifest(result, AssetBundleService.fontManifestName).content.bytes,
        ),
      );
      expect(decoded, <Object?>[
        <String, Object?>{
          'family': 'Inconsolata',
          'fonts': <Object?>[
            <String, Object?>{'asset': 'assets/fonts/Inconsolata-Regular.ttf'},
            <String, Object?>{
              'asset': 'assets/fonts/Inconsolata-Bold.ttf',
              'weight': 700,
            },
          ],
        },
      ]);
    });

    test('フォントの実体も転送対象になる', () {
      writePubspec('''
  fonts:
    - family: X
      fonts:
        - asset: assets/fonts/X.ttf
''');
      writeFile('assets/fonts/X.ttf', 'font');

      expect(changedAssets(build().sync()), <String>{'assets/fonts/X.ttf'});
    });
  });

  group('DevFS への写像', () {
    test('build/flutter_assets 配下に置く', () {
      writePubspec('  assets:\n    - assets/logo.png\n');
      writeFile('assets/logo.png', 'v1');

      final ChangedAsset asset = build().sync().changed.firstWhere(
        (ChangedAsset a) => a.archivePath == 'assets/logo.png',
      );

      expect('${asset.deviceUri}', 'build/flutter_assets/assets/logo.png');
      // evict にはアーカイブ上のパスを渡す（設計 §2.2.3(d)）。
      expect(asset.archivePath, 'assets/logo.png');
    });

    test('URI で意味を持つ文字を符号化する', () {
      // Uri.parse だと # が fragment、? が query になり、端末側が
      // ファイルを見つけられない。
      writePubspec('  assets:\n    - "assets/a#1 b.png"\n');
      writeFile('assets/a#1 b.png', 'v1');

      final ChangedAsset asset = build().sync().changed.firstWhere(
        (ChangedAsset a) => a.archivePath == 'assets/a#1 b.png',
      );

      expect(asset.deviceUri.pathSegments, <String>[
        'build',
        'flutter_assets',
        'assets',
        'a#1 b.png',
      ]);
      expect('${asset.deviceUri}', isNot(contains('#1')));
    });
  });

  group('プロジェクト外への脱出', () {
    /// プロジェクト外に置いた秘密のファイル。
    File writeOutside(String name) =>
        File(p.join(outside.path, name))..writeAsStringSync('secret');

    test('.. を含む宣言は無視する', () {
      // 鍵ファイルのような無関係なファイルが DevFS 経由で端末へ渡る。
      final File secret = writeOutside('id_rsa');
      writePubspec('  assets:\n    - ${p.relative(secret.path, from: root)}\n');

      final AssetSyncResult result = build().sync();

      expect(changedAssets(result), isEmpty);
      expect(
        sink.lines.where((String l) => l.contains('プロジェクトの外')),
        isNotEmpty,
      );
    });

    test('絶対パスの宣言は無視する', () {
      final File secret = writeOutside('absolute.txt');
      writePubspec('  assets:\n    - ${secret.path}\n');

      expect(changedAssets(build().sync()), isEmpty);
    });

    test('フォント宣言でも脱出できない', () {
      final File secret = writeOutside('outside.ttf');
      writePubspec(
        '  fonts:\n'
        '    - family: X\n'
        '      fonts:\n'
        '        - asset: ${p.relative(secret.path, from: root)}\n',
      );

      expect(changedAssets(build().sync()), isEmpty);
    });

    test('シンボリックリンクでも脱出できない', () {
      // 文字列の判定だけでは通ってしまう。`../` を含まないまま外を読む。
      final File secret = writeOutside('linked.txt');
      Directory(p.join(root, 'assets')).createSync(recursive: true);
      Link(p.join(root, 'assets', 'linked.txt')).createSync(secret.path);
      writePubspec('  assets:\n    - assets/linked.txt\n');

      expect(changedAssets(build().sync()), isEmpty);
    });

    test('ディレクトリ宣言の中のリンクも弾く', () {
      final File secret = writeOutside('in_dir.txt');
      Directory(p.join(root, 'assets')).createSync(recursive: true);
      writeFile('assets/ok.png', 'ok');
      Link(p.join(root, 'assets', 'in_dir.txt')).createSync(secret.path);
      writePubspec('  assets:\n    - assets/\n');

      expect(changedAssets(build().sync()), <String>{'assets/ok.png'});
    });
  });

  group('キャッシュ', () {
    test('.flutter_preview/cache/assets.json に保存する', () {
      writePubspec('  assets:\n    - assets/logo.png\n');
      writeFile('assets/logo.png', 'v1');

      final AssetBundleService service = build();
      service.sync();

      expect(service.cacheFile.existsSync(), isTrue);
      expect(
        p.relative(service.cacheFile.path, from: root),
        p.join('.flutter_preview', 'cache', 'assets.json'),
      );
      expect(
        AssetCache.readFrom(service.cacheFile)['assets/logo.png'],
        isNotNull,
      );
    });

    test('pubspec.yaml が無ければ失敗する', () {
      expect(build().sync, throwsA(isA<AssetManifestException>()));
    });
  });
}
