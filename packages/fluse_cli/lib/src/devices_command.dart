import 'dart:io';

import 'package:args/args.dart';
import 'package:fluse_builder/fluse_builder.dart';
import 'package:fluse_server/fluse_server.dart';
import 'package:path/path.dart' as p;

import 'fluse_command.dart';
import 'fluse_context.dart';

/// `fluse devices`（設計 §2.2.4）。
///
/// 「繋がっている端末」と「ペアリング済みの端末」は別のものを指す。
/// **一緒に並べない。** USB で繋がっていてもペアリングしていない端末や、
/// ペアリング済みでも今は手元に無い端末がある。
final class DevicesCommand implements FluseCommand {
  DevicesCommand({
    this.installerFactory = _defaultInstaller,
    this.onOutput = print,
  }) : argParser = ArgParser() {
    argParser.addFlag('help', abbr: 'h', negatable: false, help: '使い方を表示します。');
  }

  /// テストから差し替えるための作り手。
  final DeviceInstaller Function(FluseContext context) installerFactory;

  /// 利用者への表示。
  final void Function(String line) onOutput;

  /// ペアリング済み端末の置き場。
  static const String devicesFileName = 'devices.json';

  @override
  String get name => 'devices';

  @override
  String get description => '繋がっている端末とペアリング済みの端末を並べます。';

  @override
  final ArgParser argParser;

  @override
  Future<int> run(ArgResults args, FluseContext context) async {
    try {
      await _showConnected(context);
      _showPaired(context);
      return 0;
    } on Object catch (error) {
      context.logger.error('$error');
      onOutput('$error');
      return 1;
    }
  }

  // -------------------------------------------------------------- 繋がっている

  Future<void> _showConnected(FluseContext context) async {
    onOutput('繋がっている端末:');

    final List<AndroidDevice> devices;
    try {
      devices = await installerFactory(context).listDevices();
    } on DeviceInstallException catch (error) {
      // **ここで止めない。** adb が無くても、ペアリング済みの一覧は
      // `devices.json` から出せる。両方見せてこそ食い違いに気づける。
      context.logger.warn('$error');
      onOutput('  取得できません: $error');
      onOutput('');
      return;
    }

    if (devices.isEmpty) {
      onOutput('  ありません');
    } else {
      for (final AndroidDevice device in devices) {
        onOutput('  ${device.label}');
      }
    }
    context.logger.info(
      '繋がっている端末',
      fields: <String, Object?>{'count': devices.length},
    );
    onOutput('');
  }

  // ------------------------------------------------------------ ペアリング済み

  void _showPaired(FluseContext context) {
    onOutput('ペアリング済みの端末:');

    // 無いのは失敗ではない。`fluse start` の前は誰とも繋いでいない。
    final DeviceStore store = DeviceStore.readFrom(
      File(p.join(context.previewDir.path, devicesFileName)),
    );

    if (store.length == 0) {
      onOutput('  ありません');
      return;
    }

    for (final DeviceRecord record in store.records) {
      // **deviceToken は出さない。** 画面に出れば端末の成り済ましが
      // できてしまう（設計 §6.1）。
      onOutput(
        '  ${record.deviceName}  ${record.deviceId}  '
        '${record.issuedAt.toUtc().toIso8601String()}',
      );
    }
    context.logger.info(
      'ペアリング済みの端末',
      fields: <String, Object?>{'count': store.length},
    );
  }

  static DeviceInstaller _defaultInstaller(FluseContext context) =>
      DeviceInstaller(
        processManager: context.processManager,
        onMessage: (String line) => context.logger.info(line),
      );
}
