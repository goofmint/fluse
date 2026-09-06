import 'dart:io';

import 'package:args/args.dart';
import 'package:fluse_builder/fluse_builder.dart';
import 'package:fluse_protocol/fluse_protocol.dart';
import 'package:path/path.dart' as p;

import 'fluse_command.dart';
import 'fluse_context.dart';

/// `fluse rebuild`（設計 §2.2.4）。
///
/// 指紋が動いた時だけ作り直す。**毎回作り直さない。** `flutter build apk`
/// は分単位で掛かるため、変わっていない時にも走らせると `fluse start` の
/// 手前で毎回待たされる。
///
/// ```
/// 解析 → 指紋の突き合わせ → エントリポイント → 署名鍵 → ビルド → 導入
/// ```
final class RebuildCommand implements FluseCommand {
  /// 外に触るものは全て差し替えられるようにする。[builderFactory] は
  /// `flutter build apk`、[installerFactory] は adb、[onOutput] は表示先。
  RebuildCommand({
    this.analyzer = const ProjectAnalyzer(),
    this.entrypointGenerator = const EntrypointGenerator(),
    this.keystoreManager = const KeystoreManager(),
    this.builderFactory = _defaultBuilder,
    this.installerFactory = _defaultInstaller,
    this.onOutput = print,
  }) : argParser = ArgParser() {
    argParser
      ..addOption(
        'target',
        help: '包む対象のエントリポイント。省略すると fluse.yaml か lib/main.dart。',
        valueHelp: 'path',
      )
      ..addOption(
        'device',
        abbr: 'd',
        help: '入れる端末。省略すると1台だけの時はそれを使います。',
        valueHelp: 'serial',
      )
      ..addFlag('force', abbr: 'f', negatable: false, help: '指紋が同じでも作り直します。')
      ..addFlag('help', abbr: 'h', negatable: false, help: '使い方を表示します。');
  }

  final ProjectAnalyzer analyzer;
  final EntrypointGenerator entrypointGenerator;
  final KeystoreManager keystoreManager;

  /// テストから差し替えるための作り手。
  final PreviewAppBuilder Function(FluseContext context) builderFactory;
  final DeviceInstaller Function(FluseContext context) installerFactory;

  /// 利用者への表示。**変わったものの一覧は画面に出す。**
  final void Function(String line) onOutput;

  @override
  String get name => 'rebuild';

  @override
  String get description => '指紋が動いていれば Preview App を作り直します。';

  @override
  final ArgParser argParser;

  @override
  Future<int> run(ArgResults args, FluseContext context) async {
    // **その場の指定が勝つ。** `fluse.yaml` は「いつもそうしたい」を書く場所
    // （設計 §9.2）。ここで書き戻しはしない。今回だけの指定を残すと、
    // 次の `fluse start` が知らないうちに別の対象を見ることになる。
    final String target = _stringOf(args, 'target') ?? context.config.target;
    final String? deviceSerial = _stringOf(args, 'device');
    final bool force = args.options.contains('force') && args['force'] == true;

    try {
      return await _run(
        context: context,
        target: target,
        deviceSerial: deviceSerial,
        force: force,
      );
    } on Object catch (error) {
      context.logger.error('$error');
      onOutput('$error');
      // 環境側で止まっていることがある。次に何を見ればよいかを添える。
      onOutput('環境の確認は `fluse doctor`。');
      return 1;
    }
  }

  Future<int> _run({
    required FluseContext context,
    required String target,
    required String? deviceSerial,
    required bool force,
  }) async {
    final ProjectInfo project = await analyzer.analyze(context.projectRoot);

    final List<String> changed = await _changes(context, project);
    if (changed.isEmpty && !force) {
      onOutput('変わっていません。作り直す必要はありません。');
      onOutput('作り直したい場合は `fluse rebuild --force`。');
      return 0;
    }

    if (changed.isNotEmpty) {
      // 何が変わったかはキー名だけ出す。値にはパスが混ざる。
      onOutput('');
      onOutput('変わったもの:');
      for (final String key in changed) {
        onOutput('  $key');
      }
      onOutput('');
      context.logger.warn(
        'APP_OUTDATED',
        fields: <String, Object?>{'changed': changed},
      );
    }

    final EntrypointResult entrypoint = await entrypointGenerator.generate(
      project: project,
      userTarget: target,
    );
    final KeystoreInfo keystore = await keystoreManager.ensure(
      context.previewDir,
    );

    context.logger.info('Preview App を作ります');
    final BuildResult build = await builderFactory(context).build(
      project: project,
      entrypoint: entrypoint.entrypoint,
      keystore: keystore,
      applicationIdSuffix: context.config.applicationIdSuffix,
    );

    // **ビルドしてから残す。** 失敗したビルドの指紋を残すと、次回に
    // 「変わっていない」と判じて作り直さなくなる。
    await _saveFingerprint(context, project, build);

    return _install(context: context, build: build, deviceSerial: deviceSerial);
  }

  // ------------------------------------------------------------------ 指紋

  /// 前回のビルドから変わったものの一覧。
  ///
  /// **読めないことを「差分なし」と読み替えない。** 記録が壊れている時に
  /// 何もしないと、古い APK のまま動き続ける。
  Future<List<String>> _changes(
    FluseContext context,
    ProjectInfo project,
  ) async {
    final Fingerprint saved = await Fingerprint.readFrom(
      _cacheFile(context, fingerprintName),
    );
    final BuildMeta meta = BuildMeta.readFrom(
      _cacheFile(context, PreviewAppBuilder.buildMetaName),
    );

    final Fingerprint current = await Fingerprint.compute(
      project,
      context.sdk,
      // 前回と同じフラグで比べる。フラグを変えれば指紋も動く（設計 §10-1）。
      buildFlags: <String>[
        if (meta.trackWidgetCreation) '--track-widget-creation',
        if (meta.enableAsserts) '--enable-asserts',
        for (final String define in meta.dartDefines) '-D$define',
      ],
      previous: saved,
    );
    return current.diff(saved);
  }

  Future<void> _saveFingerprint(
    FluseContext context,
    ProjectInfo project,
    BuildResult build,
  ) async {
    final Fingerprint fingerprint = await Fingerprint.compute(
      project,
      context.sdk,
      // 実際に使われたフラグをそのまま指紋に入れる（設計 §10-1）。
      buildFlags: <String>[
        if (build.buildMeta.trackWidgetCreation) '--track-widget-creation',
        if (build.buildMeta.enableAsserts) '--enable-asserts',
        for (final String define in build.buildMeta.dartDefines) '-D$define',
      ],
    );
    await fingerprint.writeTo(_cacheFile(context, fingerprintName));
  }

  // ------------------------------------------------------------------ 導入

  Future<int> _install({
    required FluseContext context,
    required BuildResult build,
    required String? deviceSerial,
  }) async {
    final DeviceInstaller installer = installerFactory(context);
    final List<AndroidDevice> devices = await installer.listDevices();

    if (devices.isEmpty) {
      // **黙って終わらない。** APK は出来ているので、手で入れる道を示す。
      context.logger.warn(
        '繋がっている端末がありません',
        fields: <String, Object?>{'apk': build.apk.path},
      );
      onOutput('繋がっている端末がありません。出来上がった APK: ${build.apk.path}');
      return 1;
    }

    final AndroidDevice? device = _pick(devices, deviceSerial);
    if (device == null) {
      // **勝手に選ばない。** 別の端末を書き換えることになる。
      final String message = deviceSerial == null
          ? '端末が複数あります。--device で選んでください'
          : '指定された端末が見つかりません: $deviceSerial';
      context.logger.error(
        message,
        fields: <String, Object?>{
          'devices': devices.map((AndroidDevice d) => d.label).toList(),
        },
      );
      onOutput(message);
      return 1;
    }

    final InstallOutcome outcome = await installer.install(
      device: device,
      apk: build.apk,
      applicationId: build.applicationId,
      projectRoot: context.projectRoot,
    );

    switch (outcome) {
      case Installed(:final AndroidDevice device):
        context.logger.info(
          '入りました',
          fields: <String, Object?>{
            'device': device.label,
            'applicationId': build.applicationId,
          },
        );
        onOutput('入りました: ${device.label}');
        return 0;

      case NeedsRebuild(:final String applicationIdSuffix):
        // 別 ID でのビルドは `PreviewAppBuilder` がまだ持っていない。
        context.logger.warn(
          'fluse.yaml に applicationIdSuffix を書きました: $applicationIdSuffix。'
          '別 ID でのビルドは未対応です',
        );
        onOutput('fluse.yaml に applicationIdSuffix を書きました。別 ID でのビルドは未対応です');
        return 1;

      case Aborted():
        context.logger.info('中止しました');
        onOutput('中止しました');
        return 1;
    }
  }

  /// 入れる端末を決める。決められなければ null。
  static AndroidDevice? _pick(List<AndroidDevice> devices, String? serial) {
    if (serial != null) {
      for (final AndroidDevice device in devices) {
        if (device.serial == serial) {
          return device;
        }
      }
      return null;
    }
    return devices.length == 1 ? devices.first : null;
  }

  // ------------------------------------------------------------------ 道具

  /// 指紋の置き場。`init` / `start` と同じ場所を見る。
  static const String fingerprintName = 'fingerprint.json';

  static File _cacheFile(FluseContext context, String name) => File(
    p.join(context.previewDir.path, PreviewAppBuilder.cacheDirName, name),
  );

  static String? _stringOf(ArgResults args, String name) {
    if (!args.options.contains(name)) {
      return null;
    }
    final Object? value = args[name];
    return value is String && value.isNotEmpty ? value : null;
  }

  static PreviewAppBuilder _defaultBuilder(FluseContext context) =>
      PreviewAppBuilder(
        sdk: context.sdk,
        processManager: context.processManager,
        onProgress: (String line) => context.logger.debug(line),
      );

  static DeviceInstaller _defaultInstaller(FluseContext context) =>
      DeviceInstaller(
        processManager: context.processManager,
        onMessage: (String line) => context.logger.info(line),
      );
}
