import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fluse_builder/fluse_builder.dart';
import 'package:process/process.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('fluse_pub_get_');
  });

  tearDown(() {
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  const FlutterSdk sdk = FlutterSdk(
    root: '/opt/flutter',
    version: '3.41.9',
    revision: 'aaaaaaaa',
    dartVersion: '3.11.5',
    engineDirectoryName: 'darwin-arm64',
    isWindows: false,
  );

  test('プロジェクトルートで flutter pub get を回す', () async {
    final _Fake fake = _Fake(stdout: 'Got dependencies!');

    await PubGetRunner(sdk: sdk, processManager: fake).run(temp);

    expect(fake.command, <String>['/opt/flutter/bin/flutter', 'pub', 'get']);
    expect(fake.workingDirectory, temp.path);
  });

  test('進み具合を1行ずつ伝える', () async {
    final List<String> lines = <String>[];
    final _Fake fake = _Fake(stdout: 'Resolving dependencies...\nGot it!');

    await PubGetRunner(
      sdk: sdk,
      processManager: fake,
      onProgress: lines.add,
    ).run(temp);

    expect(lines, <String>['Resolving dependencies...', 'Got it!']);
  });

  test('失敗したら理由を添えて弾く', () async {
    // 黙って進むと、ランタイムが入らないまま APK が出来上がる。
    final _Fake fake = _Fake(
      exitCode: 66,
      stdout: 'Because counter_app depends on ...',
    );

    await expectLater(
      PubGetRunner(sdk: sdk, processManager: fake).run(temp),
      throwsA(
        isA<PubGetException>().having(
          (PubGetException e) => e.toString(),
          'toString',
          allOf(contains('66'), contains('depends on')),
        ),
      ),
    );
  });

  test('起動できなければ弾く', () async {
    await expectLater(
      PubGetRunner(
        sdk: sdk,
        processManager: _Fake(failToStart: true),
      ).run(temp),
      throwsA(isA<PubGetException>()),
    );
  });

  test('終わらなければ待ち続けない', () async {
    // 取りに行く先が黙ると気づけない。
    final _Fake fake = _Fake(neverExits: true);

    await expectLater(
      PubGetRunner(
        sdk: sdk,
        processManager: fake,
        timeout: const Duration(milliseconds: 50),
      ).run(temp),
      throwsA(isA<PubGetException>()),
    );
    expect(fake.killed, isTrue);
  });
}

final class _Fake implements ProcessManager {
  _Fake({
    this.exitCode = 0,
    this.stdout = '',
    this.failToStart = false,
    this.neverExits = false,
  });

  final int exitCode;
  final String stdout;
  final bool failToStart;
  final bool neverExits;

  late List<String> command;
  String? workingDirectory;
  bool killed = false;

  @override
  Future<Process> start(
    List<Object> command, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) async {
    if (failToStart) {
      throw ProcessException('flutter', const <String>[], '見つかりません');
    }
    this.command = command.map((Object e) => '$e').toList();
    this.workingDirectory = workingDirectory;
    return _Process(stdout: stdout, exitCode: exitCode, neverExits: neverExits)
      ..onKill = () => killed = true;
  }

  @override
  bool canRun(Object? executable, {String? workingDirectory}) => !failToStart;

  @override
  Future<ProcessResult> run(
    List<Object> command, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    Encoding? stdoutEncoding = systemEncoding,
    Encoding? stderrEncoding = systemEncoding,
  }) => throw UnsupportedError('run は使わない');

  @override
  ProcessResult runSync(
    List<Object> command, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    Encoding? stdoutEncoding = systemEncoding,
    Encoding? stderrEncoding = systemEncoding,
  }) => throw UnsupportedError('runSync は使わない');

  @override
  bool killPid(int pid, [ProcessSignal signal = ProcessSignal.sigterm]) => true;
}

final class _Process implements Process {
  _Process({
    required String stdout,
    required int exitCode,
    required bool neverExits,
  }) : _stdout = stdout,
       _exit = neverExits
           ? Completer<int>()
           : (Completer<int>()..complete(exitCode));

  final String _stdout;
  final Completer<int> _exit;

  void Function()? onKill;

  @override
  Stream<List<int>> get stdout => Stream<List<int>>.value(utf8.encode(_stdout));

  @override
  Stream<List<int>> get stderr => const Stream<List<int>>.empty();

  @override
  IOSink get stdin => throw UnsupportedError('stdin は使わない');

  @override
  Future<int> get exitCode => _exit.future;

  @override
  int get pid => 4242;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    onKill?.call();
    if (!_exit.isCompleted) {
      _exit.complete(-1);
    }
    return true;
  }
}
