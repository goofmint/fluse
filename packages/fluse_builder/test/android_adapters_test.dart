import 'dart:convert';
import 'dart:io';

import 'package:fluse_builder/fluse_builder.dart';
import 'package:path/path.dart' as p;
import 'package:process/process.dart';
import 'package:test/test.dart';

/// [AndroidDeviceInstaller] の外にある `FluseDevice` 実装を模す。
///
/// iOS 側の実装（Issue #99）が来る前段として、「よそで作った FluseDevice」
/// を弾けることを確かめるためだけに使う最小のフェイク。
final class _OtherDevice implements FluseDevice {
  const _OtherDevice();

  @override
  String get id => 'sim-0000';

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

    test('keystore が無ければ ArgumentError を投げる（黙って既定値へ倒さない）', () async {
      const FlutterSdk sdk = FlutterSdk(
        root: '/opt/flutter',
        version: '3.41.9',
        revision: 'aaaaaaaa',
        dartVersion: '3.11.5',
        engineDirectoryName: 'darwin-arm64',
        isWindows: false,
      );
      final AndroidPreviewAppBuilder adapter = AndroidPreviewAppBuilder(
        PreviewAppBuilder(
          sdk: sdk,
          processManager: const LocalProcessManager(),
        ),
      );

      // Android のビルドには keystore が要るという理由が読み取れれば十分。
      // `flutter build apk` が実際に走らないよう、失敗するより先に
      // ArgumentError で止まることを確かめる。
      expect(
        () => adapter.build(
          project: projectInfo(),
          entrypoint: File(p.join(temp.path, 'fluse_main.dart')),
        ),
        throwsArgumentError,
      );
    });
  });

  group('AndroidDeviceInstaller', () {
    const AndroidDevice device = AndroidDevice(
      serial: 'RF8N70XXXXX',
      model: 'Pixel 8',
    );

    test('listDevices は serial/label を id/name に写す', () async {
      final AndroidDeviceInstaller adapter = AndroidDeviceInstaller(
        DeviceInstaller(
          processManager: _FakeAdb(devices: <AndroidDevice>[device]),
        ),
      );

      final List<FluseDevice> devices = await adapter.listDevices();

      expect(devices, hasLength(1));
      expect(devices.single.id, device.serial);
      expect(devices.single.name, device.label);
      // adb には実機/エミュレータを区別する情報が無いため常に false。
      expect(devices.single.isSimulator, isFalse);
    });

    test('よその FluseDevice を install に渡すと ArgumentError', () async {
      final AndroidDeviceInstaller adapter = AndroidDeviceInstaller(
        DeviceInstaller(
          processManager: _FakeAdb(devices: <AndroidDevice>[device]),
        ),
      );
      final File apk = File(p.join(temp.path, 'preview.apk'))
        ..writeAsStringSync('偽の APK');

      expect(
        () => adapter.install(
          device: const _OtherDevice(),
          artifact: apk,
          applicationId: 'com.example.counter_app',
          projectRoot: temp,
        ),
        throwsArgumentError,
      );
    });

    test('File 以外の artifact を渡すと ArgumentError', () async {
      final AndroidDeviceInstaller adapter = AndroidDeviceInstaller(
        DeviceInstaller(
          processManager: _FakeAdb(devices: <AndroidDevice>[device]),
        ),
      );
      final List<FluseDevice> devices = await adapter.listDevices();

      expect(
        () => adapter.install(
          device: devices.single,
          artifact: temp,
          applicationId: 'com.example.counter_app',
          projectRoot: temp,
        ),
        throwsArgumentError,
      );
    });

    test(
      'InstallOutcome は変換せずそのまま返す（Installed.device は AndroidDevice）',
      () async {
        final AndroidDeviceInstaller adapter = AndroidDeviceInstaller(
          DeviceInstaller(
            processManager: _FakeAdb(devices: <AndroidDevice>[device]),
          ),
        );
        final List<FluseDevice> devices = await adapter.listDevices();
        final File apk = File(p.join(temp.path, 'preview.apk'))
          ..writeAsStringSync('偽の APK');

        final InstallOutcome outcome = await adapter.install(
          device: devices.single,
          artifact: apk,
          applicationId: 'com.example.counter_app',
          projectRoot: temp,
        );

        expect(outcome, isA<Installed>());
        final Installed installed = outcome as Installed;
        expect(installed.device, isA<AndroidDevice>());
        expect(installed.device.label, device.label);
      },
    );
  });
}

/// `adb` を模した最小の [ProcessManager]。
///
/// `DeviceInstaller` 自体は変えられないので、その入出力（`adb devices -l`
/// / `adb -s ... install`）だけを差し替える。`device_installer_test.dart`
/// にある `_Adb` / `_Process` と同じ最小構成にしている。
final class _FakeAdb implements ProcessManager {
  _FakeAdb({required this.devices});

  final List<AndroidDevice> devices;

  @override
  bool canRun(Object? executable, {String? workingDirectory}) => true;

  @override
  bool killPid(int pid, [ProcessSignal signal = ProcessSignal.sigterm]) => true;

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
  Future<Process> start(
    List<Object> command, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) async {
    final List<String> args = command.map((Object e) => '$e').toList();
    if (args.length >= 2 && args[1] == 'devices') {
      final StringBuffer buffer = StringBuffer('List of devices attached\n');
      for (final AndroidDevice device in devices) {
        buffer.writeln(
          '${device.serial} device model:${device.model.replaceAll(' ', '_')}',
        );
      }
      return _FakeProcess(stdout: buffer.toString(), exitCode: 0);
    }
    // `install` / `uninstall` はどちらも成功として返す。
    return _FakeProcess(stdout: 'Success\n', exitCode: 0);
  }
}

/// 即座に終わる偽の [Process]。
final class _FakeProcess implements Process {
  _FakeProcess({
    required String stdout,
    required int exitCode,
    String stderr = '',
  }) : _stdout = stdout,
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
