import 'dart:convert';
import 'dart:io';

import 'package:fluse_builder/fluse_builder.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('fluse_fingerprint_');
    _createProject(temp);
  });

  tearDown(() {
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  const List<String> flags = <String>['--track-widget-creation', '-Dfoo=1'];

  Future<Fingerprint> compute({
    String revision = 'aaaaaaaa',
    List<String> buildFlags = flags,
    Fingerprint? previous,
  }) async {
    final ProjectInfo project = await const ProjectAnalyzer().analyze(temp);
    return Fingerprint.compute(
      project,
      _sdk(revision),
      buildFlags: buildFlags,
      previous: previous,
    );
  }

  group('指紋テーブル', () {
    test('設計の8キーを揃える', () async {
      final Fingerprint print = await compute();

      expect(print.entries.keys.toSet(), Fingerprint.keys.toSet());
    });

    test('何も変えなければ差分は出ない', () async {
      final Fingerprint before = await compute();
      final Fingerprint after = await compute();

      expect(before.diff(after), isEmpty);
      expect(before.isCompatibleWith(after), isTrue);
    });

    // 1つ変えたら、そのキーだけが差分になること（完了条件）。
    final List<({String key, String note, void Function(Directory) change})>
    cases = <({String key, String note, void Function(Directory) change})>[
      (
        key: Fingerprint.keyPubspecLock,
        note: '依存の版が動いた',
        change: (Directory root) => _write(root, 'pubspec.lock', '# 版が変わった\n'),
      ),
      (
        key: Fingerprint.keyPubspecAssets,
        note: 'asset の宣言が増えた',
        change: (Directory root) => _write(root, 'pubspec.yaml', '''
name: counter_app
description: テスト用
flutter:
  uses-material-design: true
  assets:
    - assets/logo.png
'''),
      ),
      (
        key: Fingerprint.keyPlugins,
        note: 'プラグインが増えた',
        change: (Directory root) => _write(
          root,
          '.flutter-plugins-dependencies',
          jsonEncode(<String, Object?>{
            'plugins': <String, Object?>{
              'android': <Object?>[
                <String, Object?>{'name': 'added', 'path': '/pub/added/'},
              ],
            },
            'date_created': '2026-01-01',
          }),
        ),
      ),
      (
        key: Fingerprint.keyAndroidManifest,
        note: '権限が増えた',
        change: (Directory root) => _write(
          root,
          p.join('android', 'app', 'src', 'main', 'AndroidManifest.xml'),
          '<manifest><uses-permission android:name="CAMERA" /></manifest>\n',
        ),
      ),
      (
        key: Fingerprint.keyAndroidGradle,
        note: 'Gradle の設定が変わった',
        change: (Directory root) => _write(
          root,
          p.join('android', 'gradle.properties'),
          'org.gradle.jvmargs=-Xmx4g\n',
        ),
      ),
      (
        key: Fingerprint.keyAndroidNative,
        note: 'ネイティブのコードが変わった',
        change: (Directory root) => _write(
          root,
          p.join('android', 'app', 'src', 'main', 'kotlin', 'Main.kt'),
          'class Main { fun run() {} }\n',
        ),
      ),
    ];

    for (final ({String key, String note, void Function(Directory) change})
        entry
        in cases) {
      test('${entry.key} だけが差分になる（${entry.note}）', () async {
        final Fingerprint before = await compute();

        entry.change(temp);

        expect((await compute()).diff(before), <String>[entry.key]);
      });
    }

    test('${Fingerprint.keyFlutterRevision} だけが差分になる（SDK を入れ替えた）', () async {
      final Fingerprint before = await compute();

      expect((await compute(revision: 'bbbbbbbb')).diff(before), <String>[
        Fingerprint.keyFlutterRevision,
      ]);
    });

    test('${Fingerprint.keyBuildFlags} だけが差分になる（フラグが変わった）', () async {
      // 1つでも違うと reloadSources が静かに失敗する（設計 §10-1）。
      final Fingerprint before = await compute();

      final Fingerprint after = await compute(
        buildFlags: <String>['--track-widget-creation'],
      );

      expect(after.diff(before), <String>[Fingerprint.keyBuildFlags]);
    });

    test('フラグの並びが変われば差分になる', () async {
      // `-D` は後勝ちで解決されるため、順序で結果が変わりうる。
      final Fingerprint before = await compute(
        buildFlags: <String>['-Da=1', '-Da=2'],
      );

      final Fingerprint after = await compute(
        buildFlags: <String>['-Da=2', '-Da=1'],
      );

      expect(after.diff(before), <String>[Fingerprint.keyBuildFlags]);
    });
  });

  group('拾わないもの', () {
    test('Dart のソースは見ない', () async {
      // そこは増分コンパイルとホットリロードで賄える。
      final Fingerprint before = await compute();

      _write(temp, p.join('lib', 'main.dart'), 'void main() {}\n');

      expect((await compute()).diff(before), isEmpty);
    });

    test('pubspec.yaml の説明を変えても差分にならない', () async {
      // 作り直しが要るのは、APK へ焼き込む宣言が変わった時だけ。
      final Fingerprint before = await compute();

      _write(temp, 'pubspec.yaml', '''
name: counter_app
description: 説明だけを書き換えた
flutter:
  uses-material-design: true
''');

      expect((await compute()).diff(before), isEmpty);
    });

    test('.flutter-plugins-dependencies の生成時刻は見ない', () async {
      // pub get を打ち直しただけで APK を作り直すことになる。
      final Fingerprint before = await compute();

      _write(
        temp,
        '.flutter-plugins-dependencies',
        jsonEncode(<String, Object?>{
          'plugins': <String, Object?>{'android': <Object?>[]},
          'date_created': '2099-12-31 23:59:59.000',
        }),
      );

      expect((await compute()).diff(before), isEmpty);
    });

    test('Gradle が build/ に吐いたものは見ない', () async {
      // マージ済みの AndroidManifest.xml が置かれる。名前だけで拾うと
      // ビルドのたびに指紋が変わる。
      final Fingerprint before = await compute();

      _write(
        temp,
        p.join('android', 'app', 'build', 'merged', 'AndroidManifest.xml'),
        '<manifest />\n',
      );
      _write(temp, p.join('android', '.gradle', 'cache.gradle'), 'x\n');

      expect((await compute()).diff(before), isEmpty);
    });
  });

  group('android.native の一次判定', () {
    test('触られていなければ中身を読み直さない', () async {
      // res/ は数千ファイルになる。毎回読むと起動のたびに待たされる。
      final Fingerprint before = await compute();

      final Fingerprint after = await compute(previous: before);

      expect(after.nativeStamp, before.nativeStamp);
      expect(
        after.entries[Fingerprint.keyAndroidNative],
        before.entries[Fingerprint.keyAndroidNative],
      );
    });

    test('中身が変われば前回を使い回さない', () async {
      final Fingerprint before = await compute();

      _write(
        temp,
        p.join('android', 'app', 'src', 'main', 'kotlin', 'Main.kt'),
        'class Main { fun changed() {} }\n',
      );
      final Fingerprint after = await compute(previous: before);

      expect(after.diff(before), <String>[Fingerprint.keyAndroidNative]);
      expect(after.nativeStamp, isNot(before.nativeStamp));
    });

    test('名前を変えただけでも差分になる', () async {
      // 中身だけを見ていると取りこぼす。
      final Fingerprint before = await compute();

      File(
        p.join(temp.path, 'android', 'app', 'src', 'main', 'kotlin', 'Main.kt'),
      ).renameSync(
        p.join(
          temp.path,
          'android',
          'app',
          'src',
          'main',
          'kotlin',
          'Renamed.kt',
        ),
      );

      expect((await compute()).diff(before), <String>[
        Fingerprint.keyAndroidNative,
      ]);
    });
  });

  group('保存と読込', () {
    test('書いて読み直しても同じ', () async {
      final Fingerprint before = await compute();
      final File file = File(
        p.join(temp.path, '.flutter_preview', 'cache', 'fingerprint.json'),
      );

      await before.writeTo(file);
      final Fingerprint restored = await Fingerprint.readFrom(file);

      expect(restored.diff(before), isEmpty);
      expect(restored.nativeStamp, before.nativeStamp);
      expect(restored.schemaVersion, Fingerprint.currentSchemaVersion);
    });

    test('読み直した指紋でも一次判定が効く', () async {
      // 保存した合成ハッシュを次回の省略に使う。
      final Fingerprint before = await compute();
      final File file = File(p.join(temp.path, 'cache', 'fingerprint.json'));
      await before.writeTo(file);

      final Fingerprint after = await compute(
        previous: await Fingerprint.readFrom(file),
      );

      expect(after.nativeStamp, before.nativeStamp);
    });

    test('まだ無ければ次にすることを示す', () async {
      final File file = File(p.join(temp.path, 'missing.json'));

      await expectLater(
        Fingerprint.readFrom(file),
        throwsA(
          isA<FingerprintException>().having(
            (FingerprintException e) => e.toString(),
            'toString',
            allOf(contains('fluse init'), contains('missing.json')),
          ),
        ),
      );
    });

    test('壊れた JSON はファイル名を添えて弾く', () async {
      final File file = File(p.join(temp.path, 'broken.json'))
        ..writeAsStringSync('{ これは JSON ではない');

      await expectLater(
        Fingerprint.readFrom(file),
        throwsA(
          isA<FingerprintException>().having(
            (FingerprintException e) => e.path,
            'path',
            file.path,
          ),
        ),
      );
    });

    test('知らない schemaVersion は読めたことにしない', () async {
      // 見落としたキーがあるまま「差分なし」と判じると、古い APK のまま
      // 動き続ける。
      final File file = File(p.join(temp.path, 'future.json'))
        ..writeAsStringSync(
          jsonEncode(<String, Object?>{
            'schemaVersion': Fingerprint.currentSchemaVersion + 1,
            'entries': <String, Object?>{},
          }),
        );

      await expectLater(
        Fingerprint.readFrom(file),
        throwsA(isA<FingerprintException>()),
      );
    });

    test('schemaVersion の型と範囲を見る', () {
      expect(
        () => Fingerprint.fromJson(<String, Object?>{
          'entries': <String, Object?>{},
        }),
        throwsA(isA<FingerprintException>()),
      );
      expect(
        () => Fingerprint.fromJson(<String, Object?>{
          'schemaVersion': '1',
          'entries': <String, Object?>{},
        }),
        throwsA(isA<FingerprintException>()),
      );
      expect(
        () => Fingerprint.fromJson(<String, Object?>{
          'schemaVersion': 0,
          'entries': <String, Object?>{},
        }),
        throwsA(isA<FingerprintException>()),
      );
    });

    test('entries に文字列以外があれば弾く', () {
      expect(
        () => Fingerprint.fromJson(<String, Object?>{
          'schemaVersion': 1,
          'entries': <String, Object?>{'plugins': 42},
        }),
        throwsA(isA<FingerprintException>()),
      );
    });
  });

  group('差分の見せ方', () {
    test('キー名だけを返す', () async {
      // 値やパスが混ざると、そのまま表示した時に漏れる。
      final Fingerprint before = await compute();
      _write(temp, 'pubspec.lock', '# 変えた\n');

      final List<String> changed = (await compute()).diff(before);

      expect(changed, <String>[Fingerprint.keyPubspecLock]);
      expect(changed.single.contains(temp.path), isFalse);
    });

    test('片方にしか無いキーも差分に出す', () {
      const Fingerprint a = Fingerprint(entries: <String, String>{'x': '1'});
      const Fingerprint b = Fingerprint(entries: <String, String>{});

      expect(a.diff(b), <String>['x']);
      expect(b.diff(a), <String>['x']);
    });

    test('差分の並びは決まっている', () {
      const Fingerprint a = Fingerprint(
        entries: <String, String>{'b': '1', 'a': '1', 'c': '1'},
      );
      const Fingerprint b = Fingerprint(entries: <String, String>{});

      expect(a.diff(b), <String>['a', 'b', 'c']);
    });
  });
}

/// 最小の Flutter プロジェクトを組み立てる。
void _createProject(Directory root) {
  _write(root, 'pubspec.yaml', '''
name: counter_app
description: テスト用
flutter:
  uses-material-design: true
''');
  _write(root, 'pubspec.lock', '# 空\n');
  _write(root, p.join('lib', 'main.dart'), 'void main() {}\n');
  _write(root, p.join('android', 'app', 'build.gradle.kts'), '''
android {
    namespace = "com.example.counter_app"
    defaultConfig {
        applicationId = "com.example.counter_app"
    }
}
''');
  _write(
    root,
    p.join('android', 'gradle.properties'),
    'org.gradle.jvmargs=-Xmx2g\n',
  );
  _write(
    root,
    p.join('android', 'app', 'src', 'main', 'AndroidManifest.xml'),
    '<manifest />\n',
  );
  _write(
    root,
    p.join('android', 'app', 'src', 'main', 'kotlin', 'Main.kt'),
    'class Main\n',
  );
  _write(
    root,
    p.join('android', 'app', 'src', 'main', 'res', 'values', 'strings.xml'),
    '<resources />\n',
  );
  _write(
    root,
    '.flutter-plugins-dependencies',
    jsonEncode(<String, Object?>{
      'plugins': <String, Object?>{'android': <Object?>[]},
      'date_created': '2026-01-01 00:00:00.000',
    }),
  );
}

void _write(Directory root, String relative, String contents) {
  final File file = File(p.join(root.path, relative));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(contents);
}

/// 指紋は `revision` しか見ない。実 SDK を解決せずに組み立てる。
FlutterSdk _sdk(String revision) => FlutterSdk(
  root: '/opt/flutter',
  version: '3.41.9',
  revision: revision,
  dartVersion: '3.11.5',
  engineDirectoryName: 'darwin-arm64',
  isWindows: false,
);
