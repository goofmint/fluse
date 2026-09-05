import 'package:fluse_server/fluse_server.dart';
import 'package:test/test.dart';

void main() {
  const String root = '/proj';

  ChangeClassifier build({Set<String> assets = const <String>{}}) =>
      ChangeClassifier(projectRoot: root, assetPaths: assets);

  group('Dart ソース', () {
    test('lib 配下の .dart は dartSource', () {
      final ChangeClassifier c = build();

      expect(c.classify('$root/lib/main.dart'), ChangeKind.dartSource);
      expect(c.classify('$root/lib/src/nested/a.dart'), ChangeKind.dartSource);
    });

    test('lib の外の .dart は対象外', () {
      // test/ や tool/ の変更で端末に配る意味は無い。
      final ChangeClassifier c = build();

      expect(c.classify('$root/test/a_test.dart'), ChangeKind.ignored);
      expect(c.classify('$root/tool/gen.dart'), ChangeKind.ignored);
    });

    test('lib 配下でも .dart 以外は対象外', () {
      expect(build().classify('$root/lib/note.md'), ChangeKind.ignored);
    });
  });

  group('asset', () {
    test('宣言されたファイルは asset', () {
      final ChangeClassifier c = build(
        assets: <String>{'assets/images/logo.png'},
      );

      expect(c.classify('$root/assets/images/logo.png'), ChangeKind.asset);
    });

    test('宣言されていないファイルは対象外', () {
      final ChangeClassifier c = build(
        assets: <String>{'assets/images/logo.png'},
      );

      expect(c.classify('$root/assets/images/other.png'), ChangeKind.ignored);
    });

    test('ディレクトリ宣言は配下すべてを含む', () {
      final ChangeClassifier c = build(assets: <String>{'assets/images/'});

      expect(c.classify('$root/assets/images/a.png'), ChangeKind.asset);
      expect(c.classify('$root/assets/images/deep/b.png'), ChangeKind.asset);
    });

    test('解像度別バリアントも asset として拾う', () {
      // Flutter は assets/2.0x/logo.png を宣言なしで同梱する。
      final ChangeClassifier c = build(
        assets: <String>{'assets/images/logo.png'},
      );

      expect(c.classify('$root/assets/images/2.0x/logo.png'), ChangeKind.asset);
    });
  });

  group('指紋対象', () {
    test('ルート直下の固定ファイル', () {
      final ChangeClassifier c = build();

      for (final String file in <String>[
        'pubspec.lock',
        'pubspec.yaml',
        '.flutter-plugins-dependencies',
      ]) {
        expect(
          c.classify('$root/$file'),
          ChangeKind.fingerprintTarget,
          reason: file,
        );
      }
    });

    test('AndroidManifest.xml', () {
      final ChangeClassifier c = build();

      expect(
        c.classify('$root/android/app/src/main/AndroidManifest.xml'),
        ChangeKind.fingerprintTarget,
      );
      expect(
        c.classify('$root/android/app/src/debug/AndroidManifest.xml'),
        ChangeKind.fingerprintTarget,
      );
    });

    test('gradle 系', () {
      final ChangeClassifier c = build();

      for (final String file in <String>[
        'android/build.gradle',
        'android/app/build.gradle.kts',
        'android/gradle.properties',
        'android/gradle/wrapper/gradle-wrapper.properties',
      ]) {
        expect(
          c.classify('$root/$file'),
          ChangeKind.fingerprintTarget,
          reason: file,
        );
      }
    });

    test('native ソース', () {
      final ChangeClassifier c = build();

      for (final String file in <String>[
        'android/app/src/main/kotlin/Main.kt',
        'android/app/src/main/java/Legacy.java',
        'android/app/src/main/jni/native.cpp',
        'android/app/src/main/res/values/strings.xml',
      ]) {
        expect(
          c.classify('$root/$file'),
          ChangeKind.fingerprintTarget,
          reason: file,
        );
      }
    });

    test('android 配下でも対象外のものはある', () {
      final ChangeClassifier c = build();

      expect(c.classify('$root/android/app/README.md'), ChangeKind.ignored);
      // main 配下でも java/kotlin/jni/res 以外は指紋に入らない。
      expect(
        c.classify('$root/android/app/src/main/assets/x.txt'),
        ChangeKind.ignored,
      );
    });

    test('pubspec.yaml は asset 宣言元でも指紋対象を優先する', () {
      // 宣言が変われば APK の同梱物が変わる。増分では埋められない。
      final ChangeClassifier c = build(assets: <String>{'pubspec.yaml'});

      expect(c.classify('$root/pubspec.yaml'), ChangeKind.fingerprintTarget);
    });
  });

  test('プロジェクトの外は対象外', () {
    // 監視の網から漏れたイベントで誤って rebuild を要求しないため。
    expect(build().classify('/other/lib/main.dart'), ChangeKind.ignored);
  });
}
