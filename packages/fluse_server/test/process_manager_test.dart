import 'dart:convert';
import 'dart:io';

import 'package:fluse_server/fluse_server.dart';
import 'package:fluse_server/testing.dart';
import 'package:test/test.dart';

void main() {
  late FakeProcessManager manager;

  setUp(() => manager = FakeProcessManager());

  group('run / runSync', () {
    test('登録したコマンドの結果を返す', () async {
      manager.registerRun(<String>[
        'adb',
        'devices',
        '-l',
      ], ProcessResult(1, 0, 'List of devices attached\n', ''));

      final ProcessResult result = await manager.run(<String>[
        'adb',
        'devices',
        '-l',
      ]);

      expect(result.exitCode, 0);
      expect(result.stdout, contains('List of devices'));
    });

    test('runSync でも同じ登録が使える', () {
      manager.registerRun(<String>[
        'keytool',
        '-genkeypair',
      ], ProcessResult(1, 0, '', ''));

      expect(manager.runSync(<String>['keytool', '-genkeypair']).exitCode, 0);
    });

    test('非ゼロ終了も表現できる', () async {
      manager.registerRun(<String>[
        'adb',
        'install',
        '-r',
        'app.apk',
      ], ProcessResult(1, 1, '', 'INSTALL_FAILED_UPDATE_INCOMPATIBLE'));

      final ProcessResult result = await manager.run(<String>[
        'adb',
        'install',
        '-r',
        'app.apk',
      ]);

      expect(result.exitCode, 1);
      expect(result.stderr, contains('INSTALL_FAILED_UPDATE_INCOMPATIBLE'));
    });

    test('引数が1つでも違えば別コマンド扱いになる', () async {
      manager.registerRun(<String>[
        'adb',
        'devices',
      ], ProcessResult(1, 0, '', ''));

      await expectLater(
        manager.run(<String>['adb', 'devices', '-l']),
        throwsA(isA<UnregisteredProcessException>()),
      );
    });

    test('未登録コマンドは例外になり、登録済み一覧が読める', () async {
      manager.registerRun(<String>[
        'adb',
        'devices',
      ], ProcessResult(1, 0, '', ''));

      await expectLater(
        manager.run(<String>['flutter', 'build', 'apk']),
        throwsA(
          isA<UnregisteredProcessException>()
              .having(
                (UnregisteredProcessException e) => e.command,
                'command',
                <String>['flutter', 'build', 'apk'],
              )
              .having(
                (UnregisteredProcessException e) => e.toString(),
                'message',
                allOf(contains('flutter build apk'), contains('adb devices')),
              ),
        ),
      );
    });

    test('実行されたコマンドが記録される', () async {
      manager
        ..registerRun(<String>['adb', 'devices'], ProcessResult(1, 0, '', ''))
        ..registerRun(<String>['adb', 'forward'], ProcessResult(1, 0, '', ''));

      await manager.run(<String>['adb', 'devices']);
      await manager.run(<String>['adb', 'forward']);

      expect(manager.invocations, <List<String>>[
        <String>['adb', 'devices'],
        <String>['adb', 'forward'],
      ]);
    });

    test('コマンドは文字列以外も受け付ける', () async {
      // package:process の API は List<Object> を取る。
      manager.registerRun(<Object>[
        'adb',
        'forward',
        'tcp:8181',
      ], ProcessResult(1, 0, 'ok', ''));

      final ProcessResult result = await manager.run(<Object>[
        'adb',
        'forward',
        Uri.parse('tcp:8181'),
      ]);

      expect(result.stdout, 'ok');
    });
  });

  group('start（長寿命プロセス）', () {
    test('stdout をテストから流せる', () async {
      final FakeProcess fake = manager.registerStart(<String>[
        'dartaotruntime',
        'frontend_server_aot.dart.snapshot',
      ]);

      final Process process = await manager.start(<String>[
        'dartaotruntime',
        'frontend_server_aot.dart.snapshot',
      ]);
      final Future<List<String>> lines = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .toList();

      fake
        ..emitStdout('result abc123\n')
        ..emitStdout('abc123 /tmp/app.dill 0\n');
      await fake.complete(0);

      expect(await lines, <String>['result abc123', 'abc123 /tmp/app.dill 0']);
      expect(await process.exitCode, 0);
    });

    test('stderr も流せる', () async {
      final FakeProcess fake = manager.registerStart(<String>[
        'flutter',
        'attach',
      ]);
      final Process process = await manager.start(<String>[
        'flutter',
        'attach',
      ]);
      final Future<String> errors = process.stderr
          .transform(utf8.decoder)
          .join();

      fake.emitStderr('boom');
      await fake.complete(1);

      expect(await errors, 'boom');
      expect(await process.exitCode, 1);
    });

    test('プロセスに書いた stdin を読み取れる', () async {
      final FakeProcess fake = manager.registerStart(<String>[
        'frontend_server',
      ]);
      final Process process = await manager.start(<String>['frontend_server']);

      process.stdin.write('compile org-dartlang-root:///lib/main.dart\n');
      await process.stdin.flush();

      expect(fake.stdinText, 'compile org-dartlang-root:///lib/main.dart\n');
    });

    test('kill するとシグナルが記録され終了する', () async {
      final FakeProcess fake = manager.registerStart(<String>[
        'frontend_server',
      ]);
      final Process process = await manager.start(<String>['frontend_server']);

      expect(process.kill(), isTrue);

      expect(fake.signals, <ProcessSignal>[ProcessSignal.sigterm]);
      expect(await process.exitCode, FakeProcess.killedExitCode);
    });

    test('未登録の start は例外になる', () async {
      await expectLater(
        manager.start(<String>['frontend_server']),
        throwsA(isA<UnregisteredProcessException>()),
      );
    });

    test('processFactory を渡すと呼び出しごとに別プロセスを返せる', () async {
      // 再起動を伴うテスト（frontend_server の再生成など）で使う。
      final List<FakeProcess> created = <FakeProcess>[];
      manager.registerStart(
        <String>['frontend_server'],
        processFactory: () {
          final FakeProcess p = FakeProcess();
          created.add(p);
          return p;
        },
      );

      await manager.start(<String>['frontend_server']);
      await manager.start(<String>['frontend_server']);

      expect(created, hasLength(2));
      expect(identical(created[0], created[1]), isFalse);
    });
  });

  group('canRun / killPid', () {
    test('登録した実行ファイルだけ true', () {
      manager.registerExecutable('adb');

      expect(manager.canRun('adb'), isTrue);
      expect(manager.canRun('keytool'), isFalse);
    });

    test('registerRun / registerStart は実行ファイルも登録する', () {
      manager
        ..registerRun(<String>['keytool', '-list'], ProcessResult(1, 0, '', ''))
        ..registerStart(<String>['frontend_server']);

      expect(manager.canRun('keytool'), isTrue);
      expect(manager.canRun('frontend_server'), isTrue);
    });

    test('killPid は記録される', () {
      expect(manager.killPid(1234), isTrue);
      expect(manager.killedPids, <(int, ProcessSignal)>[
        (1234, ProcessSignal.sigterm),
      ]);
    });
  });

  test('LocalProcessManager は ProcessManager として使える', () {
    // 本番実装が抽象を満たすことは、この代入が型検査を通ることで保証される。
    // 振る舞いは canRun で確認する。実際のプロセスは起動しない。
    const ProcessManager production = LocalProcessManager();
    expect(production.canRun('fluse-no-such-executable-12345'), isFalse);
  });
}
