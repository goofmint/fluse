import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:fluse_builder/fluse_builder.dart';
import 'package:fluse_protocol/fluse_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// [FluseDevice] を実装できることを確かめるための最小のフェイク。
final class _FakeDevice implements FluseDevice {
  const _FakeDevice({
    required this.id,
    required this.name,
    required this.isSimulator,
  });

  @override
  final String id;

  @override
  final String name;

  @override
  final bool isSimulator;
}

/// [PreviewAppBuilderContract] を実装できることを確かめるための
/// フェイク。`keystore` が nullable のまま実装できることが要点。
final class _FakePreviewAppBuilder implements PreviewAppBuilderContract {
  _FakePreviewAppBuilder({required this.artifact});

  final File artifact;

  KeystoreInfo? lastKeystore;

  @override
  Future<BuildResult> build({
    required ProjectInfo project,
    required File entrypoint,
    KeystoreInfo? keystore,
    String? applicationIdSuffix,
  }) async {
    lastKeystore = keystore;
    return BuildResult(
      apk: artifact,
      applicationId: '${project.applicationId}${applicationIdSuffix ?? ''}',
      buildMeta: const BuildMeta(
        trackWidgetCreation: true,
        enableAsserts: true,
        dartDefines: <String>[],
      ),
    );
  }
}

/// [DeviceInstallerContract] を実装できることを確かめるためのフェイク。
final class _FakeDeviceInstaller implements DeviceInstallerContract {
  _FakeDeviceInstaller(this.devices);

  final List<FluseDevice> devices;

  FluseDevice? lastDevice;
  FileSystemEntity? lastArtifact;

  @override
  Future<List<FluseDevice>> listDevices() async => devices;

  @override
  Future<InstallOutcome> install({
    required FluseDevice device,
    required FileSystemEntity artifact,
    required String applicationId,
    required Directory projectRoot,
  }) async {
    lastDevice = device;
    lastArtifact = artifact;
    return Installed(
      device: const AndroidDevice(serial: 'stub', model: 'stub'),
      reinstalled: false,
    );
  }
}

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('fluse_builder_contracts_');
  });

  tearDown(() {
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  ProjectInfo projectInfo() => ProjectInfo(
    root: temp.path,
    packageName: 'counter_app',
    applicationId: 'com.example.counter_app',
    defaultTarget: 'lib/main.dart',
  );

  test('FluseDevice はゲッターだけの最小実装で満たせる', () {
    const FluseDevice device = _FakeDevice(
      id: 'RF8N70XXXXX',
      name: 'Pixel 8',
      isSimulator: false,
    );

    expect(device.id, 'RF8N70XXXXX');
    expect(device.name, 'Pixel 8');
    expect(device.isSimulator, isFalse);
  });

  test('PreviewAppBuilderContract.build は keystore なしで呼び出せる（iOS 相当）', () async {
    final File apk = File(p.join(temp.path, 'preview.apk'));
    final _FakePreviewAppBuilder builder = _FakePreviewAppBuilder(
      artifact: apk,
    );

    final BuildResult result = await builder.build(
      project: projectInfo(),
      entrypoint: File(p.join(temp.path, 'fluse_main.dart')),
    );

    expect(builder.lastKeystore, isNull);
    expect(result.applicationId, 'com.example.counter_app');
    expect(result.artifact, same(apk));
  });

  test(
    'PreviewAppBuilderContract.build は keystore ありでも呼び出せる（Android 相当）',
    () async {
      final File apk = File(p.join(temp.path, 'preview.apk'));
      final _FakePreviewAppBuilder builder = _FakePreviewAppBuilder(
        artifact: apk,
      );
      final KeystoreInfo keystore = KeystoreInfo(
        file: File(p.join(temp.path, 'keystore', 'fluse-debug.keystore')),
        alias: 'fluse-debug',
        storePassword: _secret(),
        keyPassword: _secret(),
      );

      await builder.build(
        project: projectInfo(),
        entrypoint: File(p.join(temp.path, 'fluse_main.dart')),
        keystore: keystore,
      );

      expect(builder.lastKeystore, same(keystore));
    },
  );

  test('DeviceInstallerContract は FluseDevice と artifact を受け渡せる', () async {
    const FluseDevice device = _FakeDevice(
      id: 'sim-1234',
      name: 'iPhone 15 シミュレータ',
      isSimulator: true,
    );
    final File artifact = File(p.join(temp.path, 'preview.apk'));
    final _FakeDeviceInstaller installer = _FakeDeviceInstaller(<FluseDevice>[
      device,
    ]);

    final List<FluseDevice> devices = await installer.listDevices();
    expect(devices, <FluseDevice>[device]);

    final InstallOutcome outcome = await installer.install(
      device: device,
      artifact: artifact,
      applicationId: 'com.example.counter_app',
      projectRoot: temp,
    );

    expect(installer.lastDevice, same(device));
    expect(installer.lastArtifact, same(artifact));
    expect(outcome, isA<Installed>());
  });

  test('BuildResult.artifact は既存の apk を返す（Android 経路の互換）', () {
    final File apk = File(p.join(temp.path, 'preview.apk'));
    final BuildResult result = BuildResult(
      apk: apk,
      applicationId: 'com.example.counter_app',
      buildMeta: const BuildMeta(
        trackWidgetCreation: true,
        enableAsserts: true,
        dartDefines: <String>[],
      ),
    );

    expect(result.artifact, same(apk));
    expect(result.artifact, isA<File>());
  });
}

/// テスト用の使い捨てパスワード。
///
/// リテラルを置くと（ダミーでも）secret のハードコーディングになるため、
/// preview_app_builder_test.dart と同じく実行時に生成する。
String _secret() {
  final Random random = Random.secure();
  final List<int> bytes = List<int>.generate(
    16,
    (int _) => random.nextInt(256),
  );
  return base64Url.encode(bytes).replaceAll('=', '');
}
