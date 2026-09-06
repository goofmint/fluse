import 'dart:io';

import 'package:fluse_builder/fluse_builder.dart';
import 'package:fluse_cli/fluse_cli.dart';
import 'package:fluse_server/fluse_server.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'steps.dart';

void main() {
  late Directory temp;
  late Steps steps;
  late List<String> output;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('fluse_devices_');
    steps = Steps(temp);
    output = <String>[];
  });

  tearDown(() {
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  FluseContext context() => FluseContext.of(
    projectRoot: temp,
    config: const FluseConfig(),
    sdk: _sdk,
    logger: FluseLogger(sinks: const <FluseLogSink>[]),
    processManager: steps,
  );

  /// ペアリング済みの端末を1台書いておく。
  void pair({String token = 'とても秘密なトークン'}) {
    final DeviceStore store = DeviceStore.readFrom(
      File(p.join(temp.path, '.flutter_preview', 'devices.json')),
    );
    store.upsert(
      DeviceRecord(
        deviceId: 'device-1',
        deviceToken: token,
        deviceName: 'たろうの端末',
        issuedAt: DateTime.utc(2026, 9, 6, 12),
      ),
    );
  }

  Future<int> runDevices() {
    final DevicesCommand command = DevicesCommand(
      installerFactory: (FluseContext c) =>
          DeviceInstaller(processManager: steps, onMessage: (String _) {}),
      onOutput: output.add,
    );
    return command.run(command.argParser.parse(const <String>[]), context());
  }

  test('繋がっている端末とペアリング済みの端末を並べる', () async {
    steps.devices = <String>['AAA'];
    pair();

    expect(await runDevices(), 0);

    final String text = output.join('\n');
    expect(text, contains('Pixel 8 (AAA)'));
    expect(text, contains('たろうの端末'));
    expect(text, contains('device-1'));
  });

  test('deviceToken は出さない', () async {
    pair(token: 'ひみつ-トークン-xyz');

    expect(await runDevices(), 0);

    expect(output.join('\n'), isNot(contains('ひみつ-トークン-xyz')));
  });

  test('devices.json が無くても失敗しない', () async {
    steps.devices = <String>['AAA'];

    expect(await runDevices(), 0);

    expect(output.join('\n'), contains('ペアリング済みの端末'));
  });

  test('adb が無くてもペアリング済みは出す', () async {
    pair();

    steps.adbAvailable = false;

    expect(await runDevices(), 0);

    final String text = output.join('\n');
    expect(text, contains('adb が見つかりません'));
    expect(text, contains('たろうの端末'));
  });

  test('devices.json が壊れていれば知らせる', () async {
    final File file = File(
      p.join(temp.path, '.flutter_preview', 'devices.json'),
    );
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('{壊れている');

    expect(await runDevices(), 1);

    expect(output.join('\n'), contains('devices.json'));
  });
}

const FlutterSdk _sdk = FlutterSdk(
  root: '/opt/flutter',
  version: '3.41.9',
  revision: 'aaaaaaaa',
  dartVersion: '3.11.5',
  engineDirectoryName: 'darwin-arm64',
  isWindows: false,
);
