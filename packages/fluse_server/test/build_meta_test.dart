import 'dart:convert';
import 'dart:io';

import 'package:fluse_server/fluse_server.dart';
import 'package:test/test.dart';

/// Flutter 3.41.9 の `flutter build apk --debug --verbose` から採った実物。
///
/// `examples/counter_app` に対する出力の抜粋。ハードコードされた期待値では
/// なく**実際に SDK が渡していたフラグ**なので、SDK 更新でこの前提が
/// 崩れたらテストが落ちる。
final File _fixture = File('test/fixtures/flutter_build_verbose_excerpt.log');

void main() {
  late Directory temp;

  setUp(
    () => temp = Directory.systemTemp.createTempSync('fluse_build_meta_test.'),
  );
  tearDown(() => temp.deleteSync(recursive: true));

  group('BuildMetaParser（実出力）', () {
    late BuildMeta parsed;

    setUp(() => parsed = BuildMetaParser.parse(_fixture.readAsStringSync()));

    test('--track-widget-creation と --enable-asserts を拾う', () {
      expect(parsed.trackWidgetCreation, isTrue);
      expect(parsed.enableAsserts, isTrue);
    });

    test('SDK が自動で入れる -D を全て拾う', () {
      // ここが本タスクの肝。これらは fluse 側で予測できないため、
      // ハードコードせず実出力から取る必要がある。
      expect(
        parsed.dartDefines,
        containsAll(<String>[
          'FLUTTER_VERSION=3.41.9',
          'FLUTTER_CHANNEL=stable',
          'FLUTTER_GIT_URL=https://github.com/flutter/flutter.git',
          'FLUTTER_DART_VERSION=3.11.5',
          'dart.vm.profile=false',
          'dart.vm.product=false',
        ]),
      );
    });

    test('値が空の -D も落とさない', () {
      // `-DFLUTTER_APP_FLAVOR=` は値が空。落とすと不一致になる。
      expect(parsed.dartDefines, contains('FLUTTER_APP_FLAVOR='));
    });

    test('-D の順序を保つ', () {
      // frontend_server は同じキーが複数あると後勝ちで解決する。
      final int version = parsed.dartDefines.indexOf('FLUTTER_VERSION=3.41.9');
      final int channel = parsed.dartDefines.indexOf('FLUTTER_CHANNEL=stable');

      expect(version, greaterThanOrEqualTo(0));
      expect(channel, greaterThan(version));
    });

    test('-D 以外のフラグは dartDefines に混ざらない', () {
      expect(parsed.dartDefines, isNot(anyElement(startsWith('-'))));
    });
  });

  group('BuildMetaParser（合成入力）', () {
    String command({
      bool trackWidgetCreation = true,
      bool enableAsserts = true,
      List<String> defines = const <String>[],
    }) =>
        '[        ] [   +4 ms] /sdk/bin/dartaotruntime '
        '/sdk/bin/snapshots/frontend_server_aot.dart.snapshot '
        '--sdk-root /sdk/flutter_patched_sdk/ --target=flutter '
        '${defines.map((String d) => '-D$d').join(' ')} '
        '${enableAsserts ? '--enable-asserts' : ''} '
        '${trackWidgetCreation ? '--track-widget-creation' : ''} '
        '--verbosity=error package:counter_app/main.dart';

    test('タイミング接頭辞を剥がす', () {
      expect(
        BuildMetaParser.stripTimingPrefix('[        ] [ +317 ms] hello'),
        'hello',
      );
      expect(BuildMetaParser.stripTimingPrefix('hello'), 'hello');
    });

    test('フラグが無ければ false になる', () {
      final BuildMeta meta = BuildMetaParser.parse(
        command(trackWidgetCreation: false, enableAsserts: false),
      );

      expect(meta.trackWidgetCreation, isFalse);
      expect(meta.enableAsserts, isFalse);
    });

    test('複数回の起動があれば最後のものを使う', () {
      // program と plugin registrant で2回走ることがある。
      final String output = <String>[
        command(defines: <String>['A=1']),
        command(defines: <String>['B=2']),
      ].join('\n');

      expect(BuildMetaParser.parse(output).dartDefines, <String>['B=2']);
    });

    test('frontend_server の行が無ければ例外にする', () {
      // 黙って既定値を返すと、フラグ不一致のまま起動してしまう。
      expect(
        () => BuildMetaParser.parse('Building...\nDone.'),
        throwsA(
          isA<BuildMetaException>().having(
            (BuildMetaException e) => e.toString(),
            'message',
            contains('--verbose'),
          ),
        ),
      );
    });

    test('--target=flutter を伴わない言及行は拾わない', () {
      expect(
        () => BuildMetaParser.parse(
          '[  ] frontend_server_aot.dart.snapshot について',
        ),
        throwsA(isA<BuildMetaException>()),
      );
    });
  });

  group('tokenize', () {
    test('空白で割る', () {
      expect(BuildMetaParser.tokenize('a b  c'), <String>['a', 'b', 'c']);
    });

    test('引用符で囲まれた空白は割らない', () {
      // パスに空白を含む環境で壊れないこと。
      expect(
        BuildMetaParser.tokenize('--packages "/My Apps/a.json" -DX=1'),
        <String>['--packages', '/My Apps/a.json', '-DX=1'],
      );
    });

    test('シングルクォートも扱う', () {
      expect(BuildMetaParser.tokenize("-DMSG='hello world'"), <String>[
        '-DMSG=hello world',
      ]);
    });

    test('空文字の引数を落とさない', () {
      expect(BuildMetaParser.tokenize('-DX="" -DY=1'), <String>[
        '-DX=',
        '-DY=1',
      ]);
    });

    test('引用符が閉じていなければ例外にする', () {
      // 途中で切れたログを黙って通すと、値の欠けた dartDefines を
      // 記録してしまい、以後ずっと不一致で止まる。
      expect(
        () => BuildMetaParser.tokenize('--packages "/My Apps/a.json'),
        throwsA(
          isA<BuildMetaException>().having(
            (BuildMetaException e) => e.toString(),
            'message',
            contains('閉じていません'),
          ),
        ),
      );
    });
  });

  group('BuildMeta の入出力', () {
    const BuildMeta meta = BuildMeta(
      trackWidgetCreation: true,
      enableAsserts: true,
      dartDefines: <String>['A=1', 'B='],
    );

    test('往復できる', () {
      final BuildMeta restored = BuildMeta.fromJson(meta.toJson());

      expect(restored.dartDefines, meta.dartDefines);
      expect(restored.trackWidgetCreation, meta.trackWidgetCreation);
      expect(restored.enableAsserts, meta.enableAsserts);
      expect(restored.schemaVersion, BuildMeta.currentSchemaVersion);
      expect(restored.differencesFrom(meta), isEmpty);
    });

    test('ファイルに書いて読める', () {
      final File file = File('${temp.path}/cache/build_meta.json');

      meta.writeTo(file);

      expect(file.existsSync(), isTrue);
      final BuildMeta loaded = BuildMeta.readFrom(file);
      expect(loaded.trackWidgetCreation, isTrue);
      expect(loaded.dartDefines, <String>['A=1', 'B=']);
    });

    test('ファイルが無ければ init を案内する', () {
      expect(
        () => BuildMeta.readFrom(File('${temp.path}/missing.json')),
        throwsA(
          isA<BuildMetaException>().having(
            (BuildMetaException e) => e.toString(),
            'message',
            contains('fluse init'),
          ),
        ),
      );
    });

    test('壊れた JSON はパスを添えて失敗する', () {
      final File file = File('${temp.path}/build_meta.json')
        ..writeAsStringSync('{ これは JSON ではない');

      expect(
        () => BuildMeta.readFrom(file),
        throwsA(
          isA<BuildMetaException>().having(
            (BuildMetaException e) => e.toString(),
            'message',
            contains(file.path),
          ),
        ),
      );
    });

    test('schemaVersion の型が違えば「無い」と区別して報告する', () {
      final File file = File('${temp.path}/build_meta.json')
        ..writeAsStringSync(
          jsonEncode(<String, Object?>{
            ...meta.toJson(),
            'schemaVersion': 'いち',
          }),
        );

      expect(
        () => BuildMeta.readFrom(file),
        throwsA(
          isA<BuildMetaException>().having(
            (BuildMetaException e) => e.toString(),
            'message',
            contains('整数ではありません'),
          ),
        ),
      );
    });

    test('schemaVersion が 0 以下なら不正として扱う', () {
      final File file = File('${temp.path}/build_meta.json')
        ..writeAsStringSync(
          jsonEncode(<String, Object?>{...meta.toJson(), 'schemaVersion': 0}),
        );

      expect(
        () => BuildMeta.readFrom(file),
        throwsA(
          isA<BuildMetaException>().having(
            (BuildMetaException e) => e.toString(),
            'message',
            contains('不正'),
          ),
        ),
      );
    });

    test('キーが欠けていれば失敗する', () {
      final File file = File('${temp.path}/build_meta.json')
        ..writeAsStringSync(
          jsonEncode(<String, Object?>{
            'schemaVersion': 1,
            'dartDefines': <String>[],
          }),
        );

      expect(
        () => BuildMeta.readFrom(file),
        throwsA(
          isA<BuildMetaException>().having(
            (BuildMetaException e) => e.toString(),
            'message',
            contains('trackWidgetCreation'),
          ),
        ),
      );
    });

    test('未対応の schemaVersion は更新を案内する', () {
      final File file = File('${temp.path}/build_meta.json')
        ..writeAsStringSync(
          jsonEncode(<String, Object?>{
            ...meta.toJson(),
            'schemaVersion': BuildMeta.currentSchemaVersion + 1,
          }),
        );

      expect(
        () => BuildMeta.readFrom(file),
        throwsA(
          isA<BuildMetaException>().having(
            (BuildMetaException e) => e.toString(),
            'message',
            contains('rebuild'),
          ),
        ),
      );
    });
  });

  group('differencesFrom', () {
    const BuildMeta recorded = BuildMeta(
      trackWidgetCreation: true,
      enableAsserts: true,
      dartDefines: <String>['A=1', 'B=2'],
    );

    test('一致していれば空', () {
      expect(recorded.differencesFrom(recorded), isEmpty);
    });

    test('track-widget-creation の差を両方の値付きで報告する', () {
      const BuildMeta other = BuildMeta(
        trackWidgetCreation: false,
        enableAsserts: true,
        dartDefines: <String>['A=1', 'B=2'],
      );

      expect(
        recorded.differencesFrom(other).single,
        allOf(
          contains('--track-widget-creation'),
          contains('記録=true'),
          contains('現在=false'),
        ),
      );
    });

    test('-D が1つ足りなければ差として出る', () {
      const BuildMeta other = BuildMeta(
        trackWidgetCreation: true,
        enableAsserts: true,
        dartDefines: <String>['A=1'],
      );

      expect(recorded.differencesFrom(other).single, contains('-D'));
    });

    test('-D の順序が違えば差として出る', () {
      // 後勝ちで解決されるため、順序が変われば結果も変わりうる。
      const BuildMeta other = BuildMeta(
        trackWidgetCreation: true,
        enableAsserts: true,
        dartDefines: <String>['B=2', 'A=1'],
      );

      expect(recorded.differencesFrom(other), hasLength(1));
    });

    test('-D の値をマスクする', () {
      // -D には API キーが入りうる。エラーメッセージは端末にもログにも
      // 出るため、値をそのまま載せない。
      const BuildMeta withSecret = BuildMeta(
        trackWidgetCreation: true,
        enableAsserts: true,
        dartDefines: <String>['API_KEY=sk-live-abcdefghijklmnop'],
      );
      const BuildMeta other = BuildMeta(
        trackWidgetCreation: true,
        enableAsserts: true,
        dartDefines: <String>[],
      );

      final String difference = withSecret.differencesFrom(other).single;

      expect(difference, isNot(contains('abcdefghijklmnop')));
      expect(difference, contains('API_KEY='));
      expect(difference, contains('***'));
    });

    test('値が空の -D はマスクせず空のまま示す', () {
      // マスクすると「空である」という情報が失われる。
      expect(
        BuildMeta.maskDefine('FLUTTER_APP_FLAVOR='),
        'FLUTTER_APP_FLAVOR=',
      );
    });

    test('= を含まない -D はそのまま', () {
      expect(BuildMeta.maskDefine('FLAG'), 'FLAG');
    });

    test('複数の差を全て報告する', () {
      const BuildMeta other = BuildMeta(
        trackWidgetCreation: false,
        enableAsserts: false,
        dartDefines: <String>[],
      );

      expect(recorded.differencesFrom(other), hasLength(3));
    });
  });
}
