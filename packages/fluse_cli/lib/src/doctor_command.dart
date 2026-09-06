import 'dart:io';

import 'package:args/args.dart';
import 'package:fluse_builder/fluse_builder.dart';
import 'package:fluse_protocol/fluse_protocol.dart';
import 'package:fluse_server/fluse_server.dart';
import 'package:path/path.dart' as p;

import 'devices_command.dart';
import 'fluse_command.dart';
import 'fluse_context.dart';

/// 検査1件の結果。
final class DoctorCheck {
  const DoctorCheck.ok(this.name, {this.detail}) : isOk = true;

  const DoctorCheck.failed(this.name, {required String this.detail})
    : isOk = false;

  /// 検査の名前。
  final String name;

  /// 通ったか。
  final bool isOk;

  /// 補足。通った時は版などを、落ちた時は何が足りないかを持つ。
  final String? detail;

  @override
  String toString() =>
      '${isOk ? '✓' : '✗'} $name${detail == null ? '' : ': $detail'}';
}

/// `fluse doctor`（設計 §2.2.4）。
///
/// **1つ落ちても止めない。** adb が無いから keystore を見ない、では
/// 直しては再実行を繰り返すことになる。全部見てから並べる。
final class DoctorCommand implements FluseCommand {
  DoctorCommand({
    this.onOutput = print,
    this.probePort = _bindAndClose,
    bool? isWindows,
  }) : _isWindows = isWindows,
       argParser = ArgParser() {
    argParser.addFlag('help', abbr: 'h', negatable: false, help: '使い方を表示します。');
  }

  /// 利用者への表示。
  final void Function(String line) onOutput;

  /// ポートが空いているかを確かめる。塞がっていれば投げる。
  final Future<void> Function(int port) probePort;

  final bool? _isWindows;

  bool get _windows => _isWindows ?? Platform.isWindows;

  /// 持ち主だけが読み書きできる状態（`0600`）。
  static const int privateMode = 0x180;

  /// パーミッションのビット。
  static const int permissionMask = 0x1FF;

  @override
  String get name => 'doctor';

  @override
  String get description => '足りないものと壊れているものを調べます。';

  @override
  final ArgParser argParser;

  @override
  Future<int> run(ArgResults args, FluseContext context) async {
    final List<DoctorCheck> checks = <DoctorCheck>[];
    try {
      checks
        ..add(_checkSdk(context))
        ..add(_checkExecutable(context, 'adb', 'Android SDK の platform-tools'))
        ..add(_checkExecutable(context, 'keytool', 'JDK'))
        ..add(await _checkPort(context));
      checks.addAll(await _checkPreviewDir(context));
    } on Object catch (error) {
      // 検査そのものが落ちた。**「異常なし」で終わらせない。**
      context.logger.error('$error');
      onOutput('$error');
      return 1;
    }

    return _report(context, checks);
  }

  // ------------------------------------------------------------------ SDK

  DoctorCheck _checkSdk(FluseContext context) {
    final FlutterSdk? sdk = context.sdkOrNull;
    if (sdk == null) {
      // 解決は入口で済んでいる。**ここで解決し直さない。**
      // `flutter --version` は数分掛かることがあり、二度走らせる意味が無い。
      return DoctorCheck.failed(
        'Flutter SDK',
        detail:
            '${FluseErrorCode.sdkNotFound.wireValue}\n'
            '    ${_indent('${context.sdkError}')}',
      );
    }
    return DoctorCheck.ok(
      'Flutter SDK',
      detail: '${sdk.version} (${sdk.revision}) ${sdk.root}',
    );
  }

  // ---------------------------------------------------------------- 実行ファイル

  DoctorCheck _checkExecutable(
    FluseContext context,
    String executable,
    String where,
  ) {
    final bool available;
    try {
      available = context.processManager.canRun(executable);
    } on Object catch (error) {
      return DoctorCheck.failed(executable, detail: '確かめられません: $error');
    }
    return available
        ? DoctorCheck.ok(executable)
        : DoctorCheck.failed(
            executable,
            detail: '見つかりません。$where を入れて PATH を通してください',
          );
  }

  // ---------------------------------------------------------------- ポート

  Future<DoctorCheck> _checkPort(FluseContext context) async {
    final int port = context.config.port;
    try {
      await probePort(port);
    } on SocketException catch (error) {
      // Dart は「使用中」だけを表す型を持たない。**握り潰さない。**
      // 塞がっているのか他の理由なのかは、詳細をそのまま出して伝える。
      return DoctorCheck.failed(
        'ポート $port',
        detail:
            '待ち受けられません: ${error.osError?.message ?? error.message}。'
            '`fluse start --port <n>` か fluse.yaml の port で変えられます',
      );
    }
    return DoctorCheck.ok('ポート $port');
  }

  /// **どのアドレスで待ち受けるかは、ここでは決まっていない。**
  /// `fluse start` は LAN の私設 IPv4 を選ぶが、その選択は起動時に
  /// 行われる。ここでは `0.0.0.0` で掴めるかだけを見る。特定の
  /// アドレスだけを他が掴んでいる場合、OS によっては見逃す。
  static Future<void> _bindAndClose(int port) async {
    final ServerSocket socket = await ServerSocket.bind(
      InternetAddress.anyIPv4,
      port,
    );
    // **すぐ閉じる。** 調べるだけのコマンドが掴んだままだと、
    // 直後の `fluse start` が同じポートを取れない。
    await socket.close();
  }

  // ------------------------------------------------------- .flutter_preview

  Future<List<DoctorCheck>> _checkPreviewDir(FluseContext context) async {
    final String previewName = FluseContext.previewDirName;
    if (!context.previewDir.existsSync()) {
      return <DoctorCheck>[
        DoctorCheck.failed(previewName, detail: 'ありません。`fluse init` を実行してください'),
      ];
    }

    return <DoctorCheck>[
      await _checkFingerprint(context),
      _checkBuildMeta(context),
      _checkApk(context),
      ..._checkKeystore(context),
      _checkDevices(context),
    ];
  }

  Future<DoctorCheck> _checkFingerprint(FluseContext context) async {
    const String label = 'cache/fingerprint.json';
    final File file = _cacheFile(context, 'fingerprint.json');
    if (!file.existsSync()) {
      return const DoctorCheck.failed(
        label,
        detail: 'ありません。`fluse rebuild --force` で作り直してください',
      );
    }
    try {
      await Fingerprint.readFrom(file);
    } on FingerprintException catch (error) {
      return DoctorCheck.failed(label, detail: '読めません: ${error.message}');
    }
    return const DoctorCheck.ok(label);
  }

  DoctorCheck _checkBuildMeta(FluseContext context) {
    const String label = 'cache/build_meta.json';
    final File file = _cacheFile(context, PreviewAppBuilder.buildMetaName);
    if (!file.existsSync()) {
      return const DoctorCheck.failed(
        label,
        detail: 'ありません。`fluse rebuild --force` で作り直してください',
      );
    }
    try {
      BuildMeta.readFrom(file);
    } on BuildMetaException catch (error) {
      return DoctorCheck.failed(label, detail: '読めません: ${error.message}');
    }
    return const DoctorCheck.ok(label);
  }

  DoctorCheck _checkApk(FluseContext context) {
    const String label = 'build/preview.apk';
    final File apk = File(
      p.join(
        context.previewDir.path,
        PreviewAppBuilder.outputDirName,
        PreviewAppBuilder.outputApkName,
      ),
    );
    return apk.existsSync()
        ? const DoctorCheck.ok(label)
        : const DoctorCheck.failed(
            label,
            detail: 'ありません。`fluse init` を実行してください',
          );
  }

  /// 署名鍵を見る。
  ///
  /// **`KeystoreManager.ensure` は呼ばない。** あれは無ければ作る。
  /// 調べるだけのコマンドが鍵を作ると、`doctor` を走らせただけで
  /// 端末に入っている Preview App と署名が食い違う余地が生まれる。
  List<DoctorCheck> _checkKeystore(FluseContext context) {
    const String label = 'keystore';
    final Directory dir = Directory(
      p.join(context.previewDir.path, KeystoreManager.directoryName),
    );
    final File keystore = File(
      p.join(dir.path, KeystoreManager.keystoreFileName),
    );
    final File passwords = File(
      p.join(dir.path, KeystoreManager.passwordFileName),
    );

    if (!keystore.existsSync() && !passwords.existsSync()) {
      return const <DoctorCheck>[
        DoctorCheck.failed(label, detail: 'ありません。`fluse init` を実行してください'),
      ];
    }
    if (!keystore.existsSync() || !passwords.existsSync()) {
      // **片方だけを直せる形にしない。** 鍵とパスワードは対で意味を持つ。
      return <DoctorCheck>[
        DoctorCheck.failed(
          label,
          detail:
              '${keystore.existsSync() ? KeystoreManager.passwordFileName : KeystoreManager.keystoreFileName}'
              ' がありません。${dir.path} を消して `fluse init` をやり直すと作り直せます'
              '（端末の Preview App は入れ直しになります）',
        ),
      ];
    }

    return <DoctorCheck>[
      const DoctorCheck.ok(label),
      _checkPrivateMode(
        passwords,
        'keystore/${KeystoreManager.passwordFileName}',
      ),
    ];
  }

  /// 持ち主だけが読める状態か（設計 §9.2）。
  DoctorCheck _checkPrivateMode(File file, String label) {
    if (_windows) {
      // POSIX のパーミッションが無い。見ても意味が無い。
      return DoctorCheck.ok(label, detail: 'Windows では確かめません');
    }
    final int mode = file.statSync().mode & permissionMask;
    if (mode != privateMode) {
      return DoctorCheck.failed(
        label,
        detail:
            '誰でも読めます（${mode.toRadixString(8).padLeft(3, '0')}）。'
            '`chmod 600 ${file.path}` で絞ってください',
      );
    }
    return DoctorCheck.ok(label);
  }

  DoctorCheck _checkDevices(FluseContext context) {
    const String label = 'devices.json';
    final File file = File(
      p.join(context.previewDir.path, DevicesCommand.devicesFileName),
    );
    if (!file.existsSync()) {
      // 無いのは正常。ペアリング前は誰とも繋いでいない。
      return const DoctorCheck.ok(label, detail: 'まだペアリングしていません');
    }
    final int count;
    try {
      count = DeviceStore.readFrom(file).length;
    } on DeviceStoreException catch (error) {
      return DoctorCheck.failed(label, detail: '読めません: ${error.message}');
    }
    return DoctorCheck.ok(label, detail: '$count 台');
  }

  // ------------------------------------------------------------------ 表示

  int _report(FluseContext context, List<DoctorCheck> checks) {
    onOutput('');
    for (final DoctorCheck check in checks) {
      onOutput('  $check');
    }

    final List<DoctorCheck> failures = checks
        .where((DoctorCheck check) => !check.isOk)
        .toList();
    onOutput('');
    if (failures.isEmpty) {
      onOutput('問題はありません。');
      context.logger.info('doctor', fields: <String, Object?>{'failures': 0});
      return 0;
    }

    onOutput('${failures.length} 件の問題があります。');
    context.logger.warn(
      'doctor',
      fields: <String, Object?>{
        'failures': failures.map((DoctorCheck c) => c.name).toList(),
      },
    );
    return 1;
  }

  // ------------------------------------------------------------------ 道具

  static File _cacheFile(FluseContext context, String name) => File(
    p.join(context.previewDir.path, PreviewAppBuilder.cacheDirName, name),
  );

  /// 複数行の詳細を桁下げして読めるようにする。
  static String _indent(String text) => text.replaceAll('\n', '\n    ');
}
