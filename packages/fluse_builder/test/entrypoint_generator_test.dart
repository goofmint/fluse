import 'dart:io';

import 'package:fluse_builder/fluse_builder.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('fluse_entrypoint_');
  });

  tearDown(() {
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  void write(String relative, String contents) {
    final File file = File(p.join(temp.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(contents);
  }

  String read(String relative) =>
      File(p.join(temp.path, relative)).readAsStringSync();

  bool exists(String relative) =>
      File(p.join(temp.path, relative)).existsSync();

  /// コメントと並びを持つ、ありふれた pubspec。
  const String pubspecWithComments = '''
name: counter_app
description: "カウンタの例"

# SDK の範囲。上げる時は CI も一緒に確認すること。
environment:
  sdk: ^3.9.0

dependencies:
  flutter:
    sdk: flutter

  # 保存先の解決に使う。
  path_provider: ^2.1.5

dev_dependencies:
  flutter_test:
    sdk: flutter

  # lint の設定は analysis_options.yaml にある。
  flutter_lints: ^6.0.0

flutter:
  uses-material-design: true
''';

  void createProject({String pubspec = pubspecWithComments}) {
    write('pubspec.yaml', pubspec);
    write(p.join('lib', 'main.dart'), 'void main() {}\n');
    write(p.join('android', 'app', 'build.gradle.kts'), '''
android {
    namespace = "com.example.counter_app"
    defaultConfig {
        applicationId = "com.example.counter_app"
    }
}
''');
  }

  Future<EntrypointResult> generate({
    String userTarget = 'lib/main.dart',
  }) async {
    final ProjectInfo project = await const ProjectAnalyzer().analyze(temp);
    return const EntrypointGenerator().generate(
      project: project,
      userTarget: userTarget,
    );
  }

  group('import 先の解決', () {
    const String root = '/work/app';

    String resolve(String userTarget) => EntrypointGenerator.resolveTargetUri(
      root: root,
      packageName: 'counter_app',
      userTarget: userTarget,
    );

    test('lib 配下は package: で指す', () {
      expect(resolve('lib/main.dart'), 'package:counter_app/main.dart');
    });

    test('lib の入れ子も package: で指す', () {
      expect(resolve('lib/src/app.dart'), 'package:counter_app/src/app.dart');
    });

    test('絶対パスでも lib 配下なら package: で指す', () {
      expect(resolve('$root/lib/main.dart'), 'package:counter_app/main.dart');
    });

    test('lib の外は file: で指す', () {
      // main.dart を bin/ や tool/ に置く構成がある。ここで弾くと
      // そのプロジェクトが使えない。
      expect(resolve('bin/app.dart'), 'file:///work/app/bin/app.dart');
    });

    test('プロジェクトの外も file: で指す', () {
      expect(resolve('../shared/main.dart'), 'file:///work/shared/main.dart');
    });

    test('lib で始まるだけの別ディレクトリは package: にしない', () {
      // `library/` を `lib/` の中と取り違えると、存在しない package: URI に
      // なって「なぜか解決できない」状態になる。
      expect(
        resolve('library/main.dart'),
        'file:///work/app/library/main.dart',
      );
    });

    test('空の指定は弾く', () {
      expect(() => resolve(''), throwsA(isA<EntrypointGeneratorException>()));
    });
  });

  group('生成する中身', () {
    test('利用者の main を包むだけ', () async {
      createProject();

      final EntrypointResult result = await generate();

      final String source = result.entrypoint.readAsStringSync();
      expect(
        source,
        contains("import 'package:fluse_runtime/fluse_runtime.dart';"),
      );
      expect(
        source,
        contains("import 'package:counter_app/main.dart' as app;"),
      );
      expect(source, contains('flusePreviewMain(app.main)'));
    });

    test('手で編集しないよう先頭に書く', () async {
      // 直しても次の生成で消える。気づけないと戸惑わせる。
      createProject();

      final EntrypointResult result = await generate();

      expect(result.entrypoint.readAsStringSync(), contains('手で編集しないでください'));
    });

    test('.flutter_preview の下に置く', () async {
      createProject();

      final EntrypointResult result = await generate();

      expect(
        p.relative(result.entrypoint.path, from: temp.path),
        p.join('.flutter_preview', 'fluse_main.dart'),
      );
    });
  });

  group('pubspec.yaml への追記', () {
    test('dev_dependencies に1行だけ足す', () async {
      createProject();

      await generate();

      final Object? document = loadYaml(read('pubspec.yaml'));
      expect(document, isA<Map<Object?, Object?>>());
      final Object? dev =
          (document as Map<Object?, Object?>)['dev_dependencies'];
      expect(dev, isA<Map<Object?, Object?>>());
      expect(
        (dev as Map<Object?, Object?>)['fluse_runtime'],
        EntrypointGenerator.defaultConstraint,
      );
    });

    test('コメントを消さない（完了条件）', () async {
      // YAML 全体を組み直すと利用者の書いたものが失われる（設計 §10-8）。
      createProject();

      await generate();

      final String after = read('pubspec.yaml');
      expect(after, contains('# SDK の範囲。上げる時は CI も一緒に確認すること。'));
      expect(after, contains('# 保存先の解決に使う。'));
      expect(after, contains('# lint の設定は analysis_options.yaml にある。'));
    });

    test('もとの並びと書き方を保つ', () async {
      createProject();

      await generate();

      final String after = read('pubspec.yaml');
      expect(after, contains('description: "カウンタの例"'));
      // 触っていない行はそのまま残る。
      expect(after, contains('  path_provider: ^2.1.5'));
      expect(
        after.indexOf('dependencies:'),
        lessThan(after.indexOf('dev_dependencies:')),
      );
    });

    test('触ったのは1行だけ', () async {
      createProject();
      final List<String> before = read('pubspec.yaml').split('\n');

      await generate();

      final List<String> after = read('pubspec.yaml').split('\n');
      final Set<String> added = after.toSet().difference(before.toSet());
      expect(added.where((String line) => line.trim().isNotEmpty).length, 1);
    });

    test('既にあれば触らない', () async {
      // 版を固定している利用者の意図を上書きしない。
      createProject(
        pubspec: pubspecWithComments.replaceFirst(
          'dev_dependencies:\n',
          'dev_dependencies:\n  fluse_runtime: ^9.9.9\n',
        ),
      );
      final String before = read('pubspec.yaml');

      final EntrypointResult result = await generate();

      expect(result.addedDependency, isFalse);
      expect(read('pubspec.yaml'), before);
    });

    test('dev_dependencies が無ければ作る', () async {
      createProject(
        pubspec: '''
name: counter_app
environment:
  sdk: ^3.9.0

flutter:
  uses-material-design: true
''',
      );

      await generate();

      final Object? document = loadYaml(read('pubspec.yaml'));
      final Object? dev =
          (document! as Map<Object?, Object?>)['dev_dependencies'];
      expect((dev! as Map<Object?, Object?>)['fluse_runtime'], isNotNull);
      // フロースタイル（`{a: b}`）だと pubspec の見た目から浮く。
      expect(read('pubspec.yaml'), isNot(contains('{fluse_runtime')));
    });

    test('壊れた YAML なら書き換える前に弾く', () async {
      // 書き換えてから落ちると、利用者の pubspec が半端な状態で残る。
      createProject();
      write('pubspec.yaml', 'name: counter_app\ndependencies: [壊れている\n');

      await expectLater(
        const EntrypointGenerator().generate(
          project: ProjectInfo(
            root: temp.path,
            packageName: 'counter_app',
            applicationId: 'com.example.counter_app',
            defaultTarget: 'lib/main.dart',
          ),
          userTarget: 'lib/main.dart',
        ),
        throwsA(isA<EntrypointGeneratorException>()),
      );
    });

    test('pubspec.yaml が無ければ弾く', () async {
      await expectLater(
        const EntrypointGenerator().generate(
          project: ProjectInfo(
            root: temp.path,
            packageName: 'counter_app',
            applicationId: 'com.example.counter_app',
            defaultTarget: 'lib/main.dart',
          ),
          userTarget: 'lib/main.dart',
        ),
        throwsA(
          isA<EntrypointGeneratorException>().having(
            (EntrypointGeneratorException e) => e.path,
            'path',
            contains('pubspec.yaml'),
          ),
        ),
      );
    });
  });

  group('.gitignore への追記', () {
    test('無ければ作って足す', () async {
      // secret と keystore/ が入る。取り込まれると資格情報が残る。
      createProject();

      final EntrypointResult result = await generate();

      expect(result.addedGitignore, isTrue);
      expect(read('.gitignore'), contains('.flutter_preview/'));
    });

    test('既存の中身を残す', () async {
      createProject();
      write('.gitignore', '# 生成物\nbuild/\n.dart_tool/\n');

      await generate();

      final String after = read('.gitignore');
      expect(after, contains('build/'));
      expect(after, contains('.dart_tool/'));
      expect(after, contains('.flutter_preview/'));
    });

    test('改行で終わっていなくても行を潰さない', () async {
      createProject();
      write('.gitignore', 'build/');

      await generate();

      expect(read('.gitignore'), contains('\nbuild/\n'.substring(1)));
      expect(read('.gitignore').split('\n'), contains('build/'));
    });

    test('書き方が違っても既にあれば足さない', () async {
      // 取りこぼすと二重に書き足すことになる。
      for (final String line in <String>[
        '.flutter_preview/',
        '.flutter_preview',
        '/.flutter_preview/',
        '  .flutter_preview/  ',
      ]) {
        createProject();
        write('.gitignore', '$line\n');

        final EntrypointResult result = await generate();

        expect(result.addedGitignore, isFalse, reason: line);
      }
    });

    test('打ち消してあれば足す', () async {
      // `!` は無視の解除。無視されていないので足す必要がある。
      createProject();
      write('.gitignore', '!.flutter_preview/\n');

      final EntrypointResult result = await generate();

      expect(result.addedGitignore, isTrue);
    });
  });

  group('二度実行しても同じ（完了条件）', () {
    test('差分が出ない', () async {
      createProject();
      write('.gitignore', 'build/\n');

      await generate();
      final String pubspec = read('pubspec.yaml');
      final String gitignore = read('.gitignore');
      final String entrypoint = read(
        p.join('.flutter_preview', 'fluse_main.dart'),
      );

      final EntrypointResult second = await generate();

      expect(read('pubspec.yaml'), pubspec);
      expect(read('.gitignore'), gitignore);
      expect(read(p.join('.flutter_preview', 'fluse_main.dart')), entrypoint);
      expect(second.isUnchanged, isTrue);
    });

    test('3回目も同じ', () async {
      createProject();

      await generate();
      await generate();
      final String pubspec = read('pubspec.yaml');

      await generate();

      expect(read('pubspec.yaml'), pubspec);
      // `.flutter_preview/` が2度書かれていないこと。
      expect('.flutter_preview/'.allMatches(read('.gitignore')).length, 1);
    });

    test('生成物を消しても作り直す', () async {
      createProject();
      await generate();
      File(
        p.join(temp.path, '.flutter_preview', 'fluse_main.dart'),
      ).deleteSync();

      await generate();

      expect(exists(p.join('.flutter_preview', 'fluse_main.dart')), isTrue);
    });
  });
}
