import 'dart:io';

import 'package:args/args.dart';
import 'package:fluse_builder/fluse_builder.dart';
import 'package:path/path.dart' as p;

import 'fluse_command.dart';
import 'fluse_config.dart';
import 'fluse_context.dart';

/// `fluse init`（設計 §2.2.4）。
///
/// これまでの部品を1本に繋ぐ。**どの段で止まったかが分かるようにする。**
/// 6段あり、どれも失敗しうる。「動かない」だけでは手の打ちようがない。
///
/// ```
/// 解析 → エントリポイント生成 → pub get → keystore → ビルド → 導入
/// ```
final class InitCommand implements FluseCommand {
  InitCommand({
    this.analyzer = const ProjectAnalyzer(),
    this.entrypointGenerator = const EntrypointGenerator(),
    this.keystoreManager = const KeystoreManager(),
    this.pubGetRunnerFactory = _defaultPubGet,
    this.builderFactory = _defaultBuilder,
    this.installerFactory = _defaultInstaller,
  }) : argParser = ArgParser() {
    argParser
      ..addOption(
        'target',
        help: '包む対象のエントリポイント。省略すると fluse.yaml か lib/main.dart。',
        valueHelp: 'path',
      )
      ..addOption(
        'application-id-suffix',
        help: '既に入っているアプリと分けたい時に付けます（設計 §5.3）。',
        valueHelp: 'suffix',
      )
      ..addOption(
        'device',
        abbr: 'd',
        help: '入れる端末。省略すると1台だけの時はそれを使います。',
        valueHelp: 'serial',
      )
      ..addFlag('help', abbr: 'h', negatable: false, help: '使い方を表示します。');
  }

  final ProjectAnalyzer analyzer;
  final EntrypointGenerator entrypointGenerator;
  final KeystoreManager keystoreManager;

  /// テストから差し替えるための作り手。
  final PubGetRunner Function(FluseContext context) pubGetRunnerFactory;
  final PreviewAppBuilder Function(FluseContext context) builderFactory;
  final DeviceInstaller Function(FluseContext context) installerFactory;

  @override
  String get name => 'init';

  @override
  String get description => 'Preview App を作って端末へ入れます。';

  @override
  final ArgParser argParser;

  @override
  Future<int> run(ArgResults args, FluseContext context) async {
    // **コマンドの引数が最優先。** `fluse.yaml` は「いつもそうしたい」を
    // 書く場所で、その場の指定はこちらが勝つ（設計 §9.2）。
    final String target = _stringOf(args, 'target') ?? context.config.target;
    final String? suffix =
        _stringOf(args, 'application-id-suffix') ??
        context.config.applicationIdSuffix;
    final String? deviceSerial = _stringOf(args, 'device');

    try {
      return await _run(
        context: context,
        target: target,
        suffix: suffix,
        deviceSerial: deviceSerial,
      );
    } on Object catch (error) {
      // **握り潰さない。** どの段で止まったかは各例外が持っている。
      context.logger.error('$error');
      return 1;
    }
  }

  Future<int> _run({
    required FluseContext context,
    required String target,
    required String? suffix,
    required String? deviceSerial,
  }) async {
    _step(context, 1, 'プロジェクトを読みます');
    final ProjectInfo project = await analyzer.analyze(context.projectRoot);
    context.logger.info(
      'プロジェクト',
      fields: <String, Object?>{
        'packageName': project.packageName,
        'applicationId': project.applicationId,
        'plugins': project.plugins.length,
      },
    );

    _step(context, 2, 'エントリポイントを用意します');
    final EntrypointResult entrypoint = await entrypointGenerator.generate(
      project: project,
      userTarget: target,
    );

    // **足したら解決し直す。** `fluse_runtime` を pubspec に足しても、
    // `pub get` を通さなければ `.flutter-plugins-dependencies` に載らず、
    // Preview App にランタイムが入らない。
    _step(context, 3, '依存を解決します');
    await pubGetRunnerFactory(context).run(context.projectRoot);

    // pub get で入れ替わっているので読み直す。
    final ProjectInfo resolved = await analyzer.analyze(context.projectRoot);

    _step(context, 4, '署名鍵を用意します');
    final KeystoreInfo keystore = await keystoreManager.ensure(
      context.previewDir,
    );

    _step(context, 5, 'Preview App を作ります');
    final BuildResult build = await builderFactory(context).build(
      project: resolved,
      entrypoint: entrypoint.entrypoint,
      keystore: keystore,
      applicationIdSuffix: suffix,
    );

    // **ビルドしてから残す。** 失敗したビルドの指紋を残すと、次回に
    // 「変わっていない」と判じて作り直さなくなる。
    await _saveFingerprint(context, resolved, build);
    await _saveConfig(context, target: target, suffix: suffix);

    _step(context, 6, '端末へ入れます');
    return _install(context: context, build: build, deviceSerial: deviceSerial);
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
      context.logger.info(
        'USB で繋いでから `fluse init` をやり直すか、'
        '出来上がった APK を手で入れてください',
      );
      return 1;
    }

    final AndroidDevice? device = _pick(devices, deviceSerial);
    if (device == null) {
      // **勝手に選ばない。** 別の端末を書き換えることになる。
      context.logger.error(
        deviceSerial == null
            ? '端末が複数あります。--device で選んでください'
            : '指定された端末が見つかりません: $deviceSerial',
        fields: <String, Object?>{
          'devices': devices.map((AndroidDevice d) => d.label).toList(),
        },
      );
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
        return 0;

      case NeedsRebuild(:final String applicationIdSuffix):
        // **ここでは作り直さない。** 別 ID でのビルドは `PreviewAppBuilder`
        // がまだ持っていない（Task 5.5 の保留、Task 5.10 で決める）。
        context.logger.warn(
          'fluse.yaml に applicationIdSuffix を書きました: $applicationIdSuffix。'
          '別 ID でのビルドは未対応です',
        );
        return 1;

      case Aborted():
        // 中止は選んだ結果。失敗として扱うが、何も壊していない。
        context.logger.info('中止しました');
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

  // ------------------------------------------------------------------ 保存

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
    await fingerprint.writeTo(
      File(p.join(context.previewDir.path, 'cache', 'fingerprint.json')),
    );
  }

  Future<void> _saveConfig(
    FluseContext context, {
    required String target,
    required String? suffix,
  }) async {
    final FluseConfig config = FluseConfig(
      port: context.config.port,
      target: target,
      applicationIdSuffix: suffix,
      dartDefines: context.config.dartDefines,
      serveApk: context.config.serveApk,
    );
    await config.writeTo(
      File(p.join(context.projectRoot.path, FluseConfig.fileName)),
    );
  }

  // ------------------------------------------------------------------ 道具

  void _step(FluseContext context, int index, String what) =>
      context.logger.info('[$index/$totalSteps] $what');

  /// 段の数。表示にしか使わない。
  static const int totalSteps = 6;

  static String? _stringOf(ArgResults args, String name) {
    if (!args.options.contains(name)) {
      return null;
    }
    final Object? value = args[name];
    return value is String && value.isNotEmpty ? value : null;
  }

  static PubGetRunner _defaultPubGet(FluseContext context) => PubGetRunner(
    sdk: context.sdk,
    processManager: context.processManager,
    onProgress: (String line) => context.logger.debug(line),
  );

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
