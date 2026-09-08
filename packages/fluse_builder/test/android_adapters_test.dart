import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fluse_builder/fluse_builder.dart';
import 'package:path/path.dart' as p;
import 'package:process/process.dart';
import 'package:test/test.dart';

/// [FluseDevice] を Android 以外から渡された体で使う最小のフェイク。
/// `AndroidDeviceInstaller` が `AndroidDevice` 以外を弾くことを確かめる。
final class _FakeIosDevice implements FluseDevice {
  const _FakeIosDevice();

  @override
  String get id => 'sim-ios-1234';

  @override
  String get name => 'iPhone 15 シミュレータ';

  @override
  bool get isSimulator => true;
}

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('fluse_android_adapters_');
  });

  tearDown(() {
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  group('AndroidPreviewAppBuilder', () {
    ProjectInfo projectInfo() => ProjectInfo(
      root: temp.path,
      packageName: 'counter_app',
      applicationId: 'com.example.counter_app',
      defaultTarget: 'lib/main.dart',
    );

    File entrypointFile() =>
        File(p.join(temp.path, '.flutter_preview', 'fluse_main.dart'));

    KeystoreInfo keystoreInfo() => KeystoreInfo(
      file: File(p.join(temp.path, 'keystore', 'fluse-debug.keystore')),
      alias: 'fluse-debug',
      storePassword: 'store-pass',
      keyPassword: 'key-pass',
    );

    const FlutterSdk sdk = FlutterSdk(
      root: '/opt/flutter',
      version: '3.41.9',
      revision: 'aaaaaaaa',
      dartVersion: '3.11.5',
      engineDirectoryName: 'darwin-arm64',
      isWindows: false,
    );

    test('keystore が null なら明確なエラーを投げ、委譲もしない', () async {
      final _NeverStart neverStart = _NeverStart();
      final AndroidPreviewAppBuilder builder = AndroidPreviewAppBuilder(
        PreviewAppBuilder(sdk: sdk, processManager: neverStart),
      );

      await expectLater(
        builder.build(project: projectInfo(), entrypoint: entrypointFile()),
        throwsA(
          isA<ArgumentError>().having(
            (ArgumentError e) => '$e',
            'message',
            contains('keystore'),
          ),
        ),
      );
      // **黙って落ちない上に、委譲もしていない。** flutter を起動していない
      // ことで確かめる。
      expect(neverStart.started, isFalse);
    });

    test('keystore があれば PreviewAppBuilder.build にそのまま委譲する', () async {
      final _FlutterRecorder recorder = _FlutterRecorder(stdout: _verboseLine)
        ..onStart = () => _writeFakeApk(temp);
      final AndroidPreviewAppBuilder builder = AndroidPreviewAppBuilder(
        PreviewAppBuilder(sdk: sdk, processManager: recorder),
      );

      final BuildResult result = await builder.build(
        project: projectInfo(),
        entrypoint: entrypointFile(),
        keystore: keystoreInfo(),
      );

      // 実際に `flutter build apk` を呼んでいる（委譲された証拠）。
      expect(recorder.command, isNotNull);
      expect(recorder.command, containsAllInOrder(<String>['build', 'apk']));
      expect(result.applicationId, 'com.example.counter_app');
      expect(result.artifact, isA<File>());
    });
  });

  group('AndroidDeviceInstaller', () {
    const AndroidDevice device = AndroidDevice(
      serial: 'RF8N70XXXXX',
      model: 'Pixel 8',
    );
    const String applicationId = 'com.example.counter_app';

    test('listDevices は DeviceInstaller の一覧をそのまま返す（変換不要）', () async {
      final _Adb adb = _Adb(
        stdout: '''
List of devices attached
RF8N70XXXXX            device product:a54x model:Pixel_8 transport_id:1
''',
      );
      final AndroidDeviceInstaller installer = AndroidDeviceInstaller(
        DeviceInstaller(processManager: adb),
      );

      final List<FluseDevice> devices = await installer.listDevices();

      expect(devices, hasLength(1));
      expect(devices.single, isA<AndroidDevice>());
      expect(devices.single.id, 'RF8N70XXXXX');
    });

    test('device が AndroidDevice でなければ、何が起きたか分かるエラーを投げる', () async {
      final _Adb adb = _Adb(stdout: 'Success');
      final AndroidDeviceInstaller installer = AndroidDeviceInstaller(
        DeviceInstaller(processManager: adb),
      );

      await expectLater(
        installer.install(
          device: const _FakeIosDevice(),
          artifact: File(p.join(temp.path, 'preview.apk')),
          applicationId: applicationId,
          projectRoot: temp,
        ),
        throwsA(
          isA<ArgumentError>().having(
            (ArgumentError e) => '$e',
            'message',
            allOf(contains('AndroidDevice'), contains('_FakeIosDevice')),
          ),
        ),
      );
      // 素の `as` キャスト例外ではなく、adb も叩いていない。
      expect(adb.commands, isEmpty);
    });

    test('artifact が File でなければ、何が起きたか分かるエラーを投げる', () async {
      final _Adb adb = _Adb(stdout: 'Success');
      final AndroidDeviceInstaller installer = AndroidDeviceInstaller(
        DeviceInstaller(processManager: adb),
      );
      final Directory notAFile = Directory(p.join(temp.path, 'not_a_file'))
        ..createSync();

      await expectLater(
        installer.install(
          device: device,
          artifact: notAFile,
          applicationId: applicationId,
          projectRoot: temp,
        ),
        throwsA(
          isA<ArgumentError>().having(
            (ArgumentError e) => '$e',
            'message',
            allOf(contains('File'), contains('Directory')),
          ),
        ),
      );
      expect(adb.commands, isEmpty);
    });

    test('AndroidDevice と File なら DeviceInstaller.install に委譲する', () async {
      final File apk = File(p.join(temp.path, 'preview.apk'))
        ..writeAsStringSync('偽の APK');
      final _Adb adb = _Adb(stdout: 'Success');
      final AndroidDeviceInstaller installer = AndroidDeviceInstaller(
        DeviceInstaller(processManager: adb),
      );

      final InstallOutcome outcome = await installer.install(
        device: device,
        artifact: apk,
        applicationId: applicationId,
        projectRoot: temp,
      );

      expect(outcome, isA<Installed>());
      expect((outcome as Installed).device.id, device.id);
      expect(adb.commands.single, <String>[
        'adb',
        '-s',
        device.serial,
        'install',
        '-r',
        apk.path,
      ]);
    });
  });
}

/// `flutter build --verbose` が出す起動コマンドを模した1行
/// （`preview_app_builder_test.dart` と同じ体裁）。
const String _verboseLine =
    '[   +4 ms] executing: /opt/flutter/bin/cache/dart-sdk/bin/dartaotruntime '
    '/opt/flutter/bin/cache/artifacts/engine/darwin-arm64/'
    'frontend_server_aot.dart.snapshot --sdk-root /opt/flutter/x/ '
    '--incremental --target=flutter --track-widget-creation '
    '-DFLUTTER_VERSION=3.41.9 -Ddart.vm.product=false';

/// `flutter build apk` が APK を置いたことにする。
void _writeFakeApk(Directory root) {
  final File apk = File(
    p.join(root.path, p.joinAll(PreviewAppBuilder.flutterApkPath)),
  );
  apk.parent.createSync(recursive: true);
  apk.writeAsStringSync('偽の APK');
}

/// 呼ばれたら失敗させる [ProcessManager]。
///
/// 「委譲していない」ことを、起動されなかったことで確かめるために使う。
final class _NeverStart implements ProcessManager {
  bool started = false;

  @override
  bool canRun(Object? executable, {String? workingDirectory}) => true;

  @override
  Future<Process> start(
    List<Object> command, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) async {
    started = true;
    throw StateError('呼ばれないはずの start が呼ばれた: $command');
  }

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

/// `flutter` の代わりに答える [ProcessManager]（`preview_app_builder_test.dart`
/// の `_Recorder` の縮小版）。
final class _FlutterRecorder implements ProcessManager {
  _FlutterRecorder({this.stdout = ''});

  final String stdout;

  void Function()? onStart;

  List<String>? command;

  @override
  Future<Process> start(
    List<Object> command, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) async {
    this.command = command.map((Object e) => '$e').toList();
    onStart?.call();
    return _FakeProcess(stdout: stdout);
  }

  @override
  bool canRun(Object? executable, {String? workingDirectory}) => true;

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

/// `adb` の代わりに答える [ProcessManager]（`device_installer_test.dart` の
/// `_Adb` の縮小版。署名衝突などは扱わない）。
final class _Adb implements ProcessManager {
  _Adb({this.stdout = ''});

  final String stdout;

  final List<List<String>> commands = <List<String>>[];

  @override
  bool canRun(Object? executable, {String? workingDirectory}) => true;

  @override
  Future<Process> start(
    List<Object> command, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) async {
    final List<String> args = command.map((Object e) => '$e').toList();
    commands.add(args);
    return _FakeProcess(stdout: stdout);
  }

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

final class _FakeProcess implements Process {
  _FakeProcess({required String stdout, String stderr = '', int exitCode = 0})
    : _stdout = stdout,
      _stderr = stderr,
      _exitCode = exitCode;

  final String _stdout;
  final String _stderr;
  final int _exitCode;

  @override
  Stream<List<int>> get stdout => Stream<List<int>>.value(utf8.encode(_stdout));

  @override
  Stream<List<int>> get stderr => Stream<List<int>>.value(utf8.encode(_stderr));

  @override
  IOSink get stdin => throw UnsupportedError('stdin は使わない');

  @override
  Future<int> get exitCode async => _exitCode;

  @override
  int get pid => 4242;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;
}
