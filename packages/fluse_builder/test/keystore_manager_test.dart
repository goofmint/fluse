import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:fluse_builder/fluse_builder.dart';
import 'package:path/path.dart' as p;
import 'package:process/process.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late Directory previewDir;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('fluse_keystore_');
    previewDir = Directory(p.join(temp.path, '.flutter_preview'));
  });

  tearDown(() {
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  String keystorePath() => p.join(
    previewDir.path,
    KeystoreManager.directoryName,
    KeystoreManager.keystoreFileName,
  );

  String passwordPath() => p.join(
    previewDir.path,
    KeystoreManager.directoryName,
    KeystoreManager.passwordFileName,
  );

  /// `keytool` が実際にファイルを作ったことにする。
  _Recorder fake({
    int keytoolExitCode = 0,
    String keytoolStderr = '',
    int chmodExitCode = 0,
    bool createsKeystore = true,
  }) => _Recorder(
    keytoolExitCode: keytoolExitCode,
    keytoolStderr: keytoolStderr,
    chmodExitCode: chmodExitCode,
    createsKeystore: createsKeystore,
  );

  group('生成', () {
    test('keytool を呼んで keystore を作る', () async {
      final _Recorder manager = fake();

      final KeystoreInfo info = await KeystoreManager(
        processManager: manager,
        isWindows: false,
      ).ensure(previewDir);

      expect(info.file.path, keystorePath());
      expect(info.file.existsSync(), isTrue);
      expect(info.alias, KeystoreManager.alias);
    });

    test('debug 用と分かる引数で呼ぶ', () async {
      final _Recorder manager = fake();

      await KeystoreManager(
        processManager: manager,
        isWindows: false,
      ).ensure(previewDir);

      final List<String> command = manager.executed.firstWhere(
        (List<String> c) => c.first == 'keytool',
      );
      expect(command, contains('-genkeypair'));
      expect(command, contains('-storetype'));
      expect(command, contains('PKCS12'));
      expect(command, contains(KeystoreManager.distinguishedName));
      // 期限が切れると、その鍵で署名した APK は端末が受け付けない。
      expect(command, contains('${KeystoreManager.validityDays}'));
    });

    test('パスワードを keystore.json に残す', () async {
      final KeystoreInfo info = await KeystoreManager(
        processManager: fake(),
        isWindows: false,
      ).ensure(previewDir);

      final Object? document = jsonDecode(
        File(passwordPath()).readAsStringSync(),
      );
      expect(document, isA<Map<String, Object?>>());
      final Map<String, Object?> json = document! as Map<String, Object?>;
      expect(json['storePassword'], info.storePassword);
      expect(json['keyPassword'], info.keyPassword);
      expect(json['alias'], KeystoreManager.alias);
      expect(json['schemaVersion'], KeystoreManager.currentSchemaVersion);
    });

    test('パスワードは毎回違う', () async {
      final String first = KeystoreManager.generatePassword();
      final String second = KeystoreManager.generatePassword();

      expect(first, isNot(second));
      expect(first.length, greaterThanOrEqualTo(32));
    });

    test('パスワードに = は入らない', () {
      // keytool の引数に載る。余計な記号を避ける。
      final String password = KeystoreManager.generatePassword(
        random: Random(1234),
      );

      expect(password.contains('='), isFalse);
    });
  });

  group('パーミッション', () {
    test('keystore.json を 600 にする（完了条件）', () async {
      // パスワードが平文で入る。他の利用者から読めてはいけない。
      final _Recorder manager = fake();

      await KeystoreManager(
        processManager: manager,
        isWindows: false,
      ).ensure(previewDir);

      final List<String> command = manager.executed.firstWhere(
        (List<String> c) => c.first == 'chmod',
      );
      expect(command[1], '600');
    });

    test('置き換える前に絞る', () async {
      // 置き換えてから絞ると、その間だけ誰でも読める。
      final _Recorder manager = fake();

      await KeystoreManager(
        processManager: manager,
        isWindows: false,
      ).ensure(previewDir);

      final List<String> command = manager.executed.firstWhere(
        (List<String> c) => c.first == 'chmod',
      );
      expect(command[2], endsWith('.tmp'));
    });

    test('絞れなければ弾く', () async {
      // 黙って続けると、読めるままパスワードが残る。
      await expectLater(
        KeystoreManager(
          processManager: fake(chmodExitCode: 1),
          isWindows: false,
        ).ensure(previewDir),
        throwsA(isA<KeystoreException>()),
      );
    });

    test('絞れなければ一時ファイルも残さない', () async {
      // 絞れなかった一時ファイルにもパスワードがそのまま入っている。
      await expectLater(
        KeystoreManager(
          processManager: fake(chmodExitCode: 1),
          isWindows: false,
        ).ensure(previewDir),
        throwsA(isA<KeystoreException>()),
      );

      expect(File('${passwordPath()}.tmp').existsSync(), isFalse);
    });

    test('絞れなかった時に JDK の確認を促さない', () async {
      // 無関係な場所を探させることになる。
      final KeystoreException error =
          await KeystoreManager(
                processManager: fake(chmodExitCode: 1),
                isWindows: false,
              )
              .ensure(previewDir)
              .then<KeystoreException>(
                (KeystoreInfo _) => throw StateError('失敗するはず'),
                onError: (Object error) => error as KeystoreException,
              );

      expect(error.toString().contains('JAVA_HOME'), isFalse);
      expect(error.toString(), contains('600'));
    });

    test('Windows では chmod を呼ばない', () async {
      // POSIX のパーミッションが無い。
      final _Recorder manager = fake();

      await KeystoreManager(
        processManager: manager,
        isWindows: true,
      ).ensure(previewDir);

      expect(
        manager.executed.where((List<String> c) => c.first == 'chmod'),
        isEmpty,
      );
    });
  }, testOn: '!windows');

  group('実ファイルのパーミッション', () {
    test('生成後の keystore.json は持ち主だけが読める（完了条件）', () async {
      await KeystoreManager(
        processManager: fake(),
        isWindows: false,
      ).ensure(previewDir);

      final int mode = File(passwordPath()).statSync().mode;
      expect(mode & 0x1FF, 0x180, reason: '600 でない: ${mode.toRadixString(8)}');
    });
  }, testOn: '!windows');

  group('作り直さない', () {
    test('2回目は keytool を呼ばない', () async {
      // 作り直すと署名が変わり、端末の Preview App を上書きできなくなる。
      final _Recorder first = fake();
      final KeystoreInfo before = await KeystoreManager(
        processManager: first,
        isWindows: false,
      ).ensure(previewDir);

      final _Recorder second = fake();
      final KeystoreInfo after = await KeystoreManager(
        processManager: second,
        isWindows: false,
      ).ensure(previewDir);

      expect(second.executed, isEmpty);
      expect(after.storePassword, before.storePassword);
      expect(after.alias, before.alias);
    });

    test('keystore.json だけ残っていれば作り直す', () async {
      // 片方だけあっても開けない。
      final _Recorder manager = fake();
      await KeystoreManager(
        processManager: manager,
        isWindows: false,
      ).ensure(previewDir);
      File(keystorePath()).deleteSync();

      final _Recorder again = fake();
      await KeystoreManager(
        processManager: again,
        isWindows: false,
      ).ensure(previewDir);

      expect(
        again.executed.where((List<String> c) => c.first == 'keytool'),
        isNotEmpty,
      );
    });

    test('keystore だけ残っていれば作り直す', () async {
      final _Recorder manager = fake();
      await KeystoreManager(
        processManager: manager,
        isWindows: false,
      ).ensure(previewDir);
      File(passwordPath()).deleteSync();

      final _Recorder again = fake();
      await KeystoreManager(
        processManager: again,
        isWindows: false,
      ).ensure(previewDir);

      // **呼ぶ前に消す。** 残したままだと「別名が既にある」と言われて
      // 失敗する。
      expect(
        again.executed.where((List<String> c) => c.first == 'keytool'),
        isNotEmpty,
      );
      expect(again.keystoreExistedAtKeytool, <bool>[false]);
    });
  });

  group('失敗', () {
    test('keytool が無ければ次にすることを示す', () async {
      final _Recorder manager = _Recorder(keytoolAvailable: false);

      await expectLater(
        KeystoreManager(
          processManager: manager,
          isWindows: false,
        ).ensure(previewDir),
        throwsA(
          isA<KeystoreException>().having(
            (KeystoreException e) => e.toString(),
            'toString',
            allOf(contains('JDK'), contains('JAVA_HOME'), contains('doctor')),
          ),
        ),
      );
    });

    test('keytool が無ければディレクトリも作らない', () async {
      // 作る前に確かめる。途中まで作ると次回に中途半端なものを使い回す。
      final _Recorder manager = _Recorder(keytoolAvailable: false);

      await expectLater(
        KeystoreManager(
          processManager: manager,
          isWindows: false,
        ).ensure(previewDir),
        throwsA(isA<KeystoreException>()),
      );

      expect(previewDir.existsSync(), isFalse);
    });

    test('keytool が失敗したら理由を添える', () async {
      await expectLater(
        KeystoreManager(
          processManager: fake(
            keytoolExitCode: 1,
            keytoolStderr: 'keytool error: 何かがおかしい',
          ),
          isWindows: false,
        ).ensure(previewDir),
        throwsA(
          isA<KeystoreException>().having(
            (KeystoreException e) => e.toString(),
            'toString',
            contains('何かがおかしい'),
          ),
        ),
      );
    });

    test('失敗の文言にパスワードを載せない', () async {
      // -storepass がそのまま出ると漏れる。
      final KeystoreException error =
          await KeystoreManager(
                processManager: fake(
                  keytoolExitCode: 1,
                  keytoolStderr: 'だめでした',
                ),
                isWindows: false,
              )
              .ensure(previewDir)
              .then<KeystoreException>(
                (KeystoreInfo _) => throw StateError('失敗するはず'),
                onError: (Object error) => error as KeystoreException,
              );

      expect(error.toString().contains('-storepass'), isFalse);
    });

    test('作ったはずのものが無ければ弾く', () async {
      await expectLater(
        KeystoreManager(
          processManager: fake(createsKeystore: false),
          isWindows: false,
        ).ensure(previewDir),
        throwsA(isA<KeystoreException>()),
      );
    });

    test('壊れた keystore.json は弾く', () async {
      await KeystoreManager(
        processManager: fake(),
        isWindows: false,
      ).ensure(previewDir);
      File(passwordPath()).writeAsStringSync('{ これは JSON ではない');

      await expectLater(
        KeystoreManager(
          processManager: fake(),
          isWindows: false,
        ).ensure(previewDir),
        throwsA(isA<KeystoreException>()),
      );
    });

    test('知らない schemaVersion は読めたことにしない', () async {
      await KeystoreManager(
        processManager: fake(),
        isWindows: false,
      ).ensure(previewDir);
      File(passwordPath()).writeAsStringSync(
        jsonEncode(<String, Object?>{
          'schemaVersion': KeystoreManager.currentSchemaVersion + 1,
          'alias': 'x',
          'storePassword': 'y',
          'keyPassword': 'z',
        }),
      );

      await expectLater(
        KeystoreManager(
          processManager: fake(),
          isWindows: false,
        ).ensure(previewDir),
        throwsA(isA<KeystoreException>()),
      );
    });
  });

  group('漏らさない', () {
    test('KeystoreInfo の toString にパスワードを含めない', () async {
      final KeystoreInfo info = await KeystoreManager(
        processManager: fake(),
        isWindows: false,
      ).ensure(previewDir);

      expect(info.toString().contains(info.storePassword), isFalse);
    });
  });
}

/// 実行されたコマンドを覚える [ProcessManager]。
///
/// `keytool` の引数にはその場で作ったパスワードが載るため、事前に完全一致で
/// 登録する方式（`FakeProcessManager`）は使えない。
final class _Recorder implements ProcessManager {
  _Recorder({
    this.keytoolExitCode = 0,
    this.keytoolStderr = '',
    this.chmodExitCode = 0,
    this.createsKeystore = true,
    this.keytoolAvailable = true,
  });

  final int keytoolExitCode;
  final String keytoolStderr;
  final int chmodExitCode;
  final bool createsKeystore;
  final bool keytoolAvailable;

  /// 実行されたコマンド。
  final List<List<String>> executed = <List<String>>[];

  /// `keytool` を呼んだ時点で keystore が残っていたか。
  ///
  /// 残したまま呼ぶと「別名が既にある」と言われて失敗する。実装が先に
  /// 消していることを、ここで確かめられるようにする。
  final List<bool> keystoreExistedAtKeytool = <bool>[];

  @override
  bool canRun(Object? executable, {String? workingDirectory}) =>
      executable != 'keytool' || keytoolAvailable;

  @override
  Future<ProcessResult> run(
    List<Object> command, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    Encoding? stdoutEncoding = systemEncoding,
    Encoding? stderrEncoding = systemEncoding,
  }) async => runSync(command);

  @override
  ProcessResult runSync(
    List<Object> command, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    Encoding? stdoutEncoding = systemEncoding,
    Encoding? stderrEncoding = systemEncoding,
  }) {
    final List<String> args = command.map((Object e) => '$e').toList();
    executed.add(args);

    if (args.first == 'keytool') {
      final File file = File(args[args.indexOf('-keystore') + 1]);
      keystoreExistedAtKeytool.add(file.existsSync());
      if (createsKeystore && keytoolExitCode == 0) {
        file.parent.createSync(recursive: true);
        file.writeAsStringSync('偽の keystore');
      }
      return ProcessResult(1, keytoolExitCode, '', keytoolStderr);
    }
    if (args.first == 'chmod') {
      if (chmodExitCode != 0) {
        return ProcessResult(2, chmodExitCode, '', 'chmod に失敗しました');
      }
      // **本当に絞る。** 記録するだけだと、実装が chmod を呼ばなくなっても
      // テストが通ってしまう。
      final ProcessResult applied = Process.runSync('chmod', args.sublist(1));
      return ProcessResult(2, applied.exitCode, '', '${applied.stderr}');
    }
    return ProcessResult(3, 0, '', '');
  }

  @override
  Future<Process> start(
    List<Object> command, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) => throw UnsupportedError('start は使わない');

  @override
  bool killPid(int pid, [ProcessSignal signal = ProcessSignal.sigterm]) => true;
}
