import 'dart:convert';
import 'dart:io';

import 'package:fluse_builder/fluse_builder.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('fluse_project_analyzer_');
  });

  tearDown(() {
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  /// ファイルを1つ置く。途中のディレクトリも作る。
  void write(String relative, String contents) {
    final File file = File(p.join(temp.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(contents);
  }

  /// 最小の Flutter プロジェクトを組み立てる。
  void createFlutterProject({
    String name = 'counter_app',
    String applicationId = 'com.example.counter_app',
    bool kotlinDsl = true,
  }) {
    write('pubspec.yaml', '''
name: $name
description: テスト用
environment:
  sdk: ^3.9.0

dependencies:
  flutter:
    sdk: flutter

flutter:
  uses-material-design: true
''');

    final String gradle = kotlinDsl
        ? '''
android {
    namespace = "$applicationId"
    defaultConfig {
        applicationId = "$applicationId"
        minSdk = 21
    }
}
'''
        : '''
android {
    defaultConfig {
        applicationId "$applicationId"
        minSdkVersion 21
    }
}
''';
    write(
      p.join('android', 'app', kotlinDsl ? 'build.gradle.kts' : 'build.gradle'),
      gradle,
    );
  }

  /// `flutter pub get` が置く生成物を模す。
  void createPluginsFile(Map<String, Object?> document) {
    write('.flutter-plugins-dependencies', jsonEncode(document));
  }

  Future<ProjectInfo> analyze() => const ProjectAnalyzer().analyze(temp);

  group('Flutter プロジェクト', () {
    test('pubspec と build.gradle.kts から素性を読む', () async {
      createFlutterProject();

      final ProjectInfo info = await analyze();

      expect(info.packageName, 'counter_app');
      expect(info.applicationId, 'com.example.counter_app');
      expect(info.defaultTarget, 'lib/main.dart');
      expect(info.root, temp.absolute.path);
    });

    test('Groovy の build.gradle からも読む', () async {
      // 引数を括弧なしで並べる記法。古いプロジェクトはこちら。
      createFlutterProject(kotlinDsl: false);

      final ProjectInfo info = await analyze();

      expect(info.applicationId, 'com.example.counter_app');
    });

    test('.kts と .gradle が両方あれば .kts を採る', () async {
      // 移行途中のプロジェクトで両方残ることがある。Gradle も .kts を見る。
      createFlutterProject();
      write(p.join('android', 'app', 'build.gradle'), '''
android {
    defaultConfig {
        applicationId "com.example.old"
    }
}
''');

      final ProjectInfo info = await analyze();

      expect(info.applicationId, 'com.example.counter_app');
    });

    test('applicationId が無ければ namespace を使う', () async {
      // AGP は applicationId を省くと namespace をそのまま使う。
      createFlutterProject();
      write(p.join('android', 'app', 'build.gradle.kts'), '''
android {
    namespace = "com.example.from_namespace"
    defaultConfig {
        minSdk = 21
    }
}
''');

      final ProjectInfo info = await analyze();

      expect(info.applicationId, 'com.example.from_namespace');
    });

    test('コメントに書かれた applicationId は拾わない', () async {
      createFlutterProject();
      write(p.join('android', 'app', 'build.gradle.kts'), '''
android {
    namespace = "com.example.real"
    defaultConfig {
        // applicationId = "com.example.commented"
        /* applicationId = "com.example.blocked" */
        applicationId = "com.example.real"
    }
}
''');

      final ProjectInfo info = await analyze();

      expect(info.applicationId, 'com.example.real');
    });
  });

  group('プラグイン', () {
    test('生成物が無ければ空', () async {
      // clone 直後には無い。ここで落とすと理由が伝わりにくい。
      createFlutterProject();

      final ProjectInfo info = await analyze();

      expect(info.plugins, isEmpty);
    });

    test('プラットフォームごとに読む', () async {
      createFlutterProject();
      createPluginsFile(<String, Object?>{
        'plugins': <String, Object?>{
          'android': <Object?>[
            <String, Object?>{
              'name': 'path_provider_android',
              'path': '/pub/path_provider_android/',
              'native_build': true,
              'dependencies': <Object?>['jni'],
              'dev_dependency': false,
            },
            <String, Object?>{
              'name': 'fluse_runtime',
              'path': '/repo/packages/fluse_runtime/',
              'native_build': true,
              'dependencies': <Object?>[],
              'dev_dependency': true,
            },
          ],
          'ios': <Object?>[
            <String, Object?>{
              'name': 'path_provider_foundation',
              'path': '/pub/path_provider_foundation/',
              'native_build': true,
              'dependencies': <Object?>[],
              'dev_dependency': false,
            },
          ],
        },
      });

      final ProjectInfo info = await analyze();

      expect(info.plugins.length, 3);
      final PluginRef first = info.plugins.firstWhere(
        (PluginRef ref) => ref.name == 'path_provider_android',
      );
      expect(first.platform, 'android');
      expect(first.path, '/pub/path_provider_android/');
      expect(first.dependencies, <String>['jni']);
      expect(first.isDevDependency, isFalse);
      expect(first.hasNativeBuild, isTrue);
    });

    test('dev_dependency を見分ける', () async {
      // release には含まれない。fluse_runtime 自身がこれに当たる。
      createFlutterProject();
      createPluginsFile(<String, Object?>{
        'plugins': <String, Object?>{
          'android': <Object?>[
            <String, Object?>{
              'name': 'fluse_runtime',
              'path': '/repo/packages/fluse_runtime/',
              'dev_dependency': true,
            },
          ],
        },
      });

      final ProjectInfo info = await analyze();

      expect(info.plugins.single.isDevDependency, isTrue);
    });

    test('古い生成物で欠けている項目は既定へ倒す', () async {
      // dev_dependency / native_build は後から入った。落とすと Flutter を
      // 上げるまで解析できなくなる。
      createFlutterProject();
      createPluginsFile(<String, Object?>{
        'plugins': <String, Object?>{
          'android': <Object?>[
            <String, Object?>{'name': 'old_plugin', 'path': '/pub/old_plugin/'},
          ],
        },
      });

      final ProjectInfo info = await analyze();

      expect(info.plugins.single.isDevDependency, isFalse);
      expect(info.plugins.single.hasNativeBuild, isTrue);
      expect(info.plugins.single.dependencies, isEmpty);
    });

    test('plugins が無い生成物でも落ちない', () async {
      createFlutterProject();
      createPluginsFile(<String, Object?>{'version': 2});

      expect((await analyze()).plugins, isEmpty);
    });

    test('壊れた JSON は理由を添えて弾く', () async {
      createFlutterProject();
      write('.flutter-plugins-dependencies', '{ これは JSON ではない');

      await expectLater(
        analyze(),
        throwsA(
          isA<ProjectAnalysisException>().having(
            (ProjectAnalysisException e) => e.toString(),
            'toString',
            contains('.flutter-plugins-dependencies'),
          ),
        ),
      );
    });
  });

  group('Flutter プロジェクトでない', () {
    test('flutter: が無ければ弾く', () async {
      // 判定基準はここだけ（設計 §5.1）。
      write('pubspec.yaml', '''
name: plain_dart
environment:
  sdk: ^3.9.0
''');

      await expectLater(
        analyze(),
        throwsA(
          isA<ProjectNotFlutterException>().having(
            (ProjectNotFlutterException e) => e.toString(),
            'toString',
            allOf(contains('flutter:'), contains('pubspec.yaml')),
          ),
        ),
      );
    });

    test('android ディレクトリの有無では判じない', () async {
      // まだ flutter create していないプロジェクトを取り違えない。
      write('pubspec.yaml', '''
name: plain_dart
environment:
  sdk: ^3.9.0
''');
      Directory(
        p.join(temp.path, 'android', 'app'),
      ).createSync(recursive: true);

      await expectLater(analyze(), throwsA(isA<ProjectNotFlutterException>()));
    });

    test('pubspec.yaml が無ければ弾く', () async {
      await expectLater(
        analyze(),
        throwsA(
          isA<ProjectNotFlutterException>().having(
            (ProjectNotFlutterException e) => e.reason,
            'reason',
            contains('pubspec.yaml がありません'),
          ),
        ),
      );
    });
  });

  group('壊れた宣言', () {
    test('name が無ければ弾く', () async {
      write('pubspec.yaml', '''
description: name がない
flutter:
  uses-material-design: true
''');

      await expectLater(analyze(), throwsA(isA<ProjectAnalysisException>()));
    });

    test('build.gradle が無ければ弾く', () async {
      // applicationId を既定値に倒すと、別のアプリを上書きしかねない。
      write('pubspec.yaml', '''
name: counter_app
flutter:
  uses-material-design: true
''');

      await expectLater(
        analyze(),
        throwsA(
          isA<ProjectAnalysisException>().having(
            (ProjectAnalysisException e) => e.toString(),
            'toString',
            contains('build.gradle'),
          ),
        ),
      );
    });

    test('applicationId も namespace も無ければ弾く', () async {
      createFlutterProject();
      write(p.join('android', 'app', 'build.gradle.kts'), '''
android {
    defaultConfig {
        minSdk = 21
    }
}
''');

      await expectLater(analyze(), throwsA(isA<ProjectAnalysisException>()));
    });
  });
}
