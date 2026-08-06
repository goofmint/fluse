import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:fluse_server/fluse_server.dart';
import 'package:fluse_server/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late String projectRoot;
  late String outputDill;
  late FakeProcessManager processManager;
  late CompilerService service;
  late FakeProcess process;

  /// 境界キーを固定して、テストが応答を組み立てられるようにする。
  final Random fixedRandom = Random(1234);

  CompilerService buildService({
    bool trackWidgetCreation = true,
    bool enableAsserts = true,
    List<String> dartDefines = const <String>[],
  }) => CompilerService(
    dartAotRuntime: '/sdk/bin/dartaotruntime',
    frontendServerSnapshot: '/sdk/frontend_server_aot.dart.snapshot',
    patchedSdkRoot: '/sdk/flutter_patched_sdk',
    projectRoot: projectRoot,
    outputDill: outputDill,
    packagesPath: p.join(projectRoot, '.dart_tool', 'package_config.json'),
    trackWidgetCreation: trackWidgetCreation,
    enableAsserts: enableAsserts,
    dartDefines: dartDefines,
    processManager: processManager,
    random: fixedRandom,
  );

  /// `start()` まで済ませ、stdin に届いた内容を読めるようにする。
  Future<void> startService() async {
    process = processManager.registerStart(service.commandLine);
    await service.start();
  }

  /// テスト対象が stdin に書いた内容を取り出す。
  Future<List<String>> sentLines() async {
    await process.flushStdin();
    return process.stdinText
        .split('\n')
        .where((String l) => l.isNotEmpty)
        .toList();
  }

  /// `frontend_server` の応答を流す。境界キーは stdin から読み取る。
  Future<void> respond({
    required String outputPath,
    int errorCount = 0,
    List<String> diagnostics = const <String>[],
    List<String> sources = const <String>[],
  }) async {
    // compile は応答側が任意のキーを選べる。recompile は要求で送った
    // キーを使うが、応答の解析は `result <key>` 行に従うので同じでよい。
    const String key = 'response-key';
    process.emitStdout('result $key\n');
    for (final String line in diagnostics) {
      process.emitStdout('$line\n');
    }
    process.emitStdout('$key\n');
    for (final String source in sources) {
      process.emitStdout('+$source\n');
    }
    process.emitStdout('$key $outputPath $errorCount\n');
  }

  setUp(() {
    temp = Directory.systemTemp.createTempSync('fluse_compiler_test.');
    projectRoot = p.join(temp.path, 'project');
    Directory(projectRoot).createSync(recursive: true);
    outputDill = p.join(temp.path, 'cache', 'app.dill');
    processManager = FakeProcessManager();
    service = buildService();
  });

  tearDown(() => temp.deleteSync(recursive: true));

  group('起動コマンド', () {
    test('設計 §2.2.3(a) の全フラグを含む', () {
      final List<String> command = service.commandLine;

      expect(command.first, '/sdk/bin/dartaotruntime');
      expect(command[1], '/sdk/frontend_server_aot.dart.snapshot');
      expect(command, containsAllInOrder(<String>['--sdk-root']));
      expect(command, contains('--incremental'));
      expect(command, contains('--target=flutter'));
      expect(command, contains('--experimental-emit-debug-metadata'));
      expect(
        command,
        containsAllInOrder(<String>['--output-dill', outputDill]),
      );
      expect(command, contains('--track-widget-creation'));
      expect(
        command,
        containsAllInOrder(<String>['--filesystem-root', projectRoot]),
      );
      expect(
        command,
        containsAllInOrder(<String>[
          '--filesystem-scheme',
          'org-dartlang-root',
        ]),
      );
      expect(
        command,
        containsAllInOrder(<String>['--initialize-from-dill', outputDill]),
      );
      expect(command, contains('--enable-asserts'));
      expect(command, contains('--verbosity=error'));
    });

    test('--sdk-root は末尾に区切りが付く', () {
      final int index = service.commandLine.indexOf('--sdk-root');
      expect(service.commandLine[index + 1], endsWith(p.separator));
    });

    test('trackWidgetCreation / enableAsserts を落とせる', () {
      // APK ビルド側と揃える必要があるため、両方向に設定できること。
      final CompilerService plain = buildService(
        trackWidgetCreation: false,
        enableAsserts: false,
      );

      expect(plain.commandLine, isNot(contains('--track-widget-creation')));
      expect(plain.commandLine, isNot(contains('--enable-asserts')));
    });

    test('dartDefines を -D で渡す', () {
      final CompilerService withDefines = buildService(
        dartDefines: <String>['FOO=1', 'BAR=baz'],
      );

      expect(withDefines.commandLine, contains('-DFOO=1'));
      expect(withDefines.commandLine, contains('-DBAR=baz'));
    });
  });

  group('start / shutdown', () {
    test('起動すると出力先の親ディレクトリを作る', () async {
      await startService();

      expect(Directory(p.dirname(outputDill)).existsSync(), isTrue);
      expect(service.isRunning, isTrue);
    });

    test('二重起動は拒否する', () async {
      await startService();

      await expectLater(service.start(), throwsA(isA<CompilerException>()));
    });

    test('start 前の compile は明確に失敗する', () async {
      await expectLater(
        service.compile(Uri.file(p.join(projectRoot, 'lib', 'main.dart'))),
        throwsA(
          isA<CompilerException>().having(
            (CompilerException e) => e.toString(),
            'message',
            contains('start()'),
          ),
        ),
      );
    });

    test('shutdown は quit を送ってプロセスを落とす', () async {
      await startService();
      await service.shutdown();

      expect(await sentLines(), contains('quit'));
      expect(process.signals, isNotEmpty);
      expect(service.isRunning, isFalse);
    });
  });

  group('compile', () {
    test('compile <uri> を送り、結果を組み立てる', () async {
      await startService();

      final Future<CompileOutput> pending = service.compile(
        Uri.file(p.join(projectRoot, 'lib', 'main.dart')),
      );
      await pumpEventQueue();
      await respond(
        outputPath: outputDill,
        sources: <String>['org-dartlang-root:///lib/main.dart'],
      );

      final CompileOutput output = await pending;
      expect(await sentLines(), <String>[
        'compile org-dartlang-root:///lib/main.dart',
      ]);
      expect(output.errorCount, 0);
      expect(output.hasErrors, isFalse);
      expect(output.incrementalDill?.path, outputDill);
      expect(output.sources, hasLength(1));
    });

    test('エラーがあれば errorCount と診断を返す', () async {
      await startService();

      final Future<CompileOutput> pending = service.compile(
        Uri.file(p.join(projectRoot, 'lib', 'main.dart')),
      );
      await pumpEventQueue();
      await respond(
        outputPath: outputDill,
        errorCount: 2,
        diagnostics: <String>[
          "org-dartlang-root:///lib/main.dart:3:1: Error: Expected ';'",
        ],
      );

      final CompileOutput output = await pending;
      expect(output.errorCount, 2);
      expect(output.hasErrors, isTrue);
      expect(output.diagnostics.single.line, 3);
      expect(output.summary, contains('2'));
    });

    test('プロジェクト外のファイルは拒否する', () async {
      await startService();

      await expectLater(
        service.compile(Uri.file(p.join(temp.path, 'outside.dart'))),
        throwsA(
          isA<CompilerException>().having(
            (CompilerException e) => e.toString(),
            'message',
            contains('プロジェクト外'),
          ),
        ),
      );
    });

    test('package: URI はそのまま送る', () async {
      await startService();

      final Future<CompileOutput> pending = service.compile(
        Uri.parse('package:counter_app/main.dart'),
      );
      await pumpEventQueue();
      await respond(outputPath: outputDill);
      await pending;

      expect(await sentLines(), <String>[
        'compile package:counter_app/main.dart',
      ]);
    });
  });

  group('recompile', () {
    test('境界キーで挟んだ差分リストを送る', () async {
      await startService();

      final Future<CompileOutput> pending = service
          .recompile(Uri.file(p.join(projectRoot, 'lib', 'main.dart')), <Uri>[
            Uri.file(p.join(projectRoot, 'lib', 'main.dart')),
            Uri.file(p.join(projectRoot, 'lib', 'widget.dart')),
          ]);
      await pumpEventQueue();
      await respond(outputPath: outputDill);
      await pending;

      final List<String> lines = await sentLines();
      expect(
        lines.first,
        startsWith('recompile org-dartlang-root:///lib/main.dart '),
      );
      final String boundaryKey = lines.first.split(' ').last;
      expect(lines, <String>[
        'recompile org-dartlang-root:///lib/main.dart $boundaryKey',
        'org-dartlang-root:///lib/main.dart',
        'org-dartlang-root:///lib/widget.dart',
        boundaryKey,
      ]);
    });

    test('差分が空でも境界キーで閉じる', () async {
      await startService();

      final Future<CompileOutput> pending = service.recompile(
        Uri.file(p.join(projectRoot, 'lib', 'main.dart')),
        <Uri>[],
      );
      await pumpEventQueue();
      await respond(outputPath: outputDill);
      await pending;

      final List<String> lines = await sentLines();
      expect(lines, hasLength(2));
      expect(lines.last, lines.first.split(' ').last);
    });

    test('境界キーは呼び出しごとに変わる', () async {
      await startService();

      final List<String> keys = <String>[];
      for (int i = 0; i < 2; i++) {
        final Future<CompileOutput> pending = service.recompile(
          Uri.file(p.join(projectRoot, 'lib', 'main.dart')),
          <Uri>[],
        );
        await pumpEventQueue();
        await respond(outputPath: outputDill);
        await pending;
        service.accept();
      }

      for (final String line in await sentLines()) {
        if (line.startsWith('recompile ')) {
          keys.add(line.split(' ').last);
        }
      }
      expect(keys, hasLength(2));
      expect(keys.first, isNot(keys.last));
    });
  });

  group('accept / reject', () {
    test('compile 後は accept が必要', () async {
      await startService();

      expect(service.needsConfirmation, isFalse);

      final Future<CompileOutput> pending = service.compile(
        Uri.file(p.join(projectRoot, 'lib', 'main.dart')),
      );
      await pumpEventQueue();
      await respond(outputPath: outputDill);
      await pending;

      expect(service.needsConfirmation, isTrue);
      service.accept();
      expect(service.needsConfirmation, isFalse);
      expect(await sentLines(), contains('accept'));
    });

    test('確認が不要な状態で accept を呼んでも送らない', () async {
      await startService();

      service.accept();

      expect(await sentLines(), isEmpty);
    });

    test('reject は応答を1つ受け取る', () async {
      await startService();

      final Future<CompileOutput> compiling = service.compile(
        Uri.file(p.join(projectRoot, 'lib', 'main.dart')),
      );
      await pumpEventQueue();
      await respond(outputPath: outputDill);
      await compiling;

      final Future<CompileOutput?> rejecting = service.reject();
      await pumpEventQueue();
      // reject の応答は依存ソースを列挙しない。
      process.emitStdout('result rk\n');
      process.emitStdout('rk\n');

      expect(await rejecting, isNotNull);
      expect(service.needsConfirmation, isFalse);
      expect(await sentLines(), contains('reject'));
    });

    test('確認が不要な状態の reject は何もせず null を返す', () async {
      await startService();

      expect(await service.reject(), isNull);
      expect(await sentLines(), isEmpty);
    });
  });

  group('直列化と異常系', () {
    test('同時に投げた compile が混ざらない', () async {
      await startService();

      final Future<CompileOutput> first = service.compile(
        Uri.file(p.join(projectRoot, 'lib', 'a.dart')),
      );
      final Future<CompileOutput> second = service.compile(
        Uri.file(p.join(projectRoot, 'lib', 'b.dart')),
      );

      await pumpEventQueue();
      await respond(outputPath: '/tmp/first.dill');
      expect((await first).incrementalDill?.path, '/tmp/first.dill');

      await pumpEventQueue();
      await respond(outputPath: '/tmp/second.dill');
      expect((await second).incrementalDill?.path, '/tmp/second.dill');

      // 2つ目の要求は1つ目の応答が返るまで送られない。
      expect(await sentLines(), <String>[
        'compile org-dartlang-root:///lib/a.dart',
        'compile org-dartlang-root:///lib/b.dart',
      ]);
    });

    test('応答前にプロセスが落ちたら待っている側を失敗させる', () async {
      await startService();

      final Future<CompileOutput> pending = service.compile(
        Uri.file(p.join(projectRoot, 'lib', 'main.dart')),
      );
      await pumpEventQueue();
      await process.complete(70);

      await expectLater(
        pending,
        throwsA(
          isA<CompilerException>().having(
            (CompilerException e) => e.toString(),
            'message',
            contains('70'),
          ),
        ),
      );
      expect(service.isRunning, isFalse);
    });

    test('応答が来なければタイムアウトする', () async {
      await startService();

      await expectLater(
        service.compile(
          Uri.file(p.join(projectRoot, 'lib', 'main.dart')),
          timeout: const Duration(milliseconds: 20),
        ),
        throwsA(
          isA<CompilerException>().having(
            (CompilerException e) => e.toString(),
            'message',
            contains('応答がありません'),
          ),
        ),
      );
    });

    test('タイムアウト後も次の要求を受け付ける', () async {
      await startService();

      await expectLater(
        service.compile(
          Uri.file(p.join(projectRoot, 'lib', 'a.dart')),
          timeout: const Duration(milliseconds: 20),
        ),
        throwsA(isA<CompilerException>()),
      );

      final Future<CompileOutput> pending = service.compile(
        Uri.file(p.join(projectRoot, 'lib', 'b.dart')),
      );
      await pumpEventQueue();
      await respond(outputPath: outputDill);

      expect((await pending).errorCount, 0);
    });
  });
}
