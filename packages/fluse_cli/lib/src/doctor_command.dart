import 'dart:io';

import 'package:args/args.dart';
import 'package:fluse_builder/fluse_builder.dart';
import 'package:fluse_protocol/fluse_protocol.dart';
import 'package:fluse_server/fluse_server.dart';
import 'package:path/path.dart' as p;

import 'devices_command.dart';
import 'fluse_command.dart';
import 'fluse_context.dart';
import 'fluse_target_platform.dart';

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
  /// [probePort] はポートを掴めるかを確かめる。塞がっていれば投げる。
  /// [isWindows] を省くと動いている OS を見る。**どれもテストから
  /// 差し替える。** 実際に塞がった環境を作らずに検査を確かめられる。
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
      checks.add(_checkSdk(context));
      // **プラットフォームで分岐する。** iOS を選んでいる利用者に
      // `adb` が無いと言っても意味が無い（Issue #104）。
      switch (context.config.platform) {
        case FluseTargetPlatform.android:
          checks
            ..add(
              _checkExecutable(context, 'adb', 'Android SDK の platform-tools'),
            )
            ..add(_checkExecutable(context, 'keytool', 'JDK'));
        case FluseTargetPlatform.ios:
          checks
            ..add(await _checkXcode(context))
            ..add(await _checkDevicectl(context))
            ..add(_checkIosDir(context))
            ..add(_checkDevelopmentTeam(context))
            ..addAll(_checkInfoPlist(context))
            ..add(_checkExecutable(context, 'pod', 'CocoaPods'));
      }
      checks.add(await _checkPort(context));
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

  // -------------------------------------------------------------------- iOS

  /// `xcode-select -p` が指す先が Command Line Tools のままでないか。
  ///
  /// **Xcode.app が入っていても、これが切り替わっていない状態は普通に
  /// 起きる。** その時は `xcodebuild` や `xcrun` が Xcode 本体の道具を
  /// 見つけられず、実機ビルドが理由不明のまま失敗する。
  Future<DoctorCheck> _checkXcode(FluseContext context) async {
    const String label = 'Xcode';
    final ProcessResult result;
    try {
      result = await context.processManager.run(<String>['xcode-select', '-p']);
    } on ProcessException catch (error) {
      return DoctorCheck.failed(label, detail: '確かめられません: ${error.message}');
    }
    if (result.exitCode != 0) {
      return DoctorCheck.failed(
        label,
        detail:
            '見つかりません。App Store から Xcode を入れてください: '
            '${_trimmed(result.stderr) ?? result.stderr}',
      );
    }
    final String path = '${result.stdout}'.trim();
    if (path.contains('CommandLineTools')) {
      return DoctorCheck.failed(
        label,
        detail:
            'コマンドラインツール（$path）を指しています。Xcode 本体に切り替えてください: '
            '`sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer`',
      );
    }
    return DoctorCheck.ok(label, detail: path);
  }

  /// `xcrun devicectl` が使えるか。実機の一覧・インストールに使う（Issue #99）。
  Future<DoctorCheck> _checkDevicectl(FluseContext context) async {
    const String label = 'xcrun devicectl';
    final ProcessResult result;
    try {
      result = await context.processManager.run(<String>[
        'xcrun',
        '--find',
        'devicectl',
      ]);
    } on ProcessException catch (error) {
      return DoctorCheck.failed(label, detail: '確かめられません: ${error.message}');
    }
    if (result.exitCode != 0) {
      return DoctorCheck.failed(label, detail: '見つかりません。Xcode 15 以降が必要です');
    }
    return DoctorCheck.ok(label);
  }

  /// `ios/` があるか。`flutter create` を Android だけで済ませたまま
  /// `--platform ios` を選んでいる場合に起きる。
  DoctorCheck _checkIosDir(FluseContext context) {
    const String label = 'ios/';
    final Directory dir = Directory(p.join(context.projectRoot.path, 'ios'));
    if (!dir.existsSync()) {
      return const DoctorCheck.failed(
        label,
        detail: 'ありません。`flutter create --platforms=ios .` を実行してください',
      );
    }
    return const DoctorCheck.ok(label);
  }

  /// 署名チームを解決できるか（Issue #104）。
  ///
  /// 実機ビルドは `DEVELOPMENT_TEAM` が無いと Xcode の automatic signing に
  /// 入れず、`No signing certificate` で落ちる。**シミュレータだけなら
  /// 要らない**ので、失敗の文面でその区別を伝える。
  ///
  /// **`xcodebuild -showBuildSettings` は動かさない。** Gradle を動かさない
  /// のと同じ方針で、`project.pbxproj` をテキストとして読む。数秒かかる
  /// コマンドを doctor の中で待たせない。
  DoctorCheck _checkDevelopmentTeam(FluseContext context) {
    const String label = 'DEVELOPMENT_TEAM';
    final File project = File(
      p.join(
        context.projectRoot.path,
        'ios',
        'Runner.xcodeproj',
        'project.pbxproj',
      ),
    );

    if (!project.existsSync()) {
      return const DoctorCheck.failed(
        label,
        detail:
            'ios/Runner.xcodeproj/project.pbxproj がありません。'
            '`flutter create --platforms=ios .` を実行してください',
      );
    }

    final String contents;
    try {
      contents = project.readAsStringSync();
    } on Object catch (error) {
      return DoctorCheck.failed(
        label,
        detail: 'ios/Runner.xcodeproj/project.pbxproj を読めません: $error',
      );
    }

    final String? team = _developmentTeam(contents);
    if (team == null) {
      return const DoctorCheck.failed(
        label,
        detail:
            '解決できません。実機ビルドには署名チームが要ります。'
            'Xcode で Runner > Signing & Capabilities > Team を選んでください'
            '（シミュレータだけなら不要です）',
      );
    }
    return DoctorCheck.ok(label, detail: team);
  }

  /// `project.pbxproj` から `DEVELOPMENT_TEAM` の値を拾う。
  ///
  /// 構成ごとに複数書かれることがある。**空文字は「未設定」として
  /// 扱う。** Xcode は Team を外したときに `DEVELOPMENT_TEAM = "";` を
  /// 残すため、キーがあることだけでは解決できたことにならない。
  static String? _developmentTeam(String contents) {
    final RegExp pattern = RegExp(r'DEVELOPMENT_TEAM\s*=\s*"?([^";\n]*)"?\s*;');
    for (final RegExpMatch match in pattern.allMatches(contents)) {
      final String value = (match.group(1) ?? '').trim();
      if (value.isNotEmpty) {
        return value;
      }
    }
    return null;
  }

  static const String _localNetworkUsageKey = 'NSLocalNetworkUsageDescription';
  static const String _localNetworkingKey = 'NSAllowsLocalNetworking';
  static const String _appTransportSecurityKey = 'NSAppTransportSecurity';

  /// `ios/Runner/Info.plist` の2キーを見る。Android の `INTERNET` 権限と
  /// `usesCleartextTraffic`（設計 §10-4）の iOS 版に当たる。
  ///
  /// **`plutil` は使わない。** Gradle や xcodebuild を動かさないのと
  /// 同じ方針で、テキストとして読む。
  List<DoctorCheck> _checkInfoPlist(FluseContext context) {
    const String usageLabel = 'Info.plist: $_localNetworkUsageKey';
    const String allowsLabel = 'Info.plist: $_localNetworkingKey';
    final File plist = File(
      p.join(context.projectRoot.path, 'ios', 'Runner', 'Info.plist'),
    );

    if (!plist.existsSync()) {
      const String detail =
          'ios/Runner/Info.plist がありません。これが無いと LAN の WebSocket に繋がりません';
      return const <DoctorCheck>[
        DoctorCheck.failed(usageLabel, detail: detail),
        DoctorCheck.failed(allowsLabel, detail: detail),
      ];
    }

    final String contents;
    try {
      contents = plist.readAsStringSync();
    } on Object catch (error) {
      // **読めないことを他の検査の巻き添えにしない。** ここで投げると
      // run() の外側の catch に届き、CocoaPods・ポート・.flutter_preview の
      // 検査ごと打ち切られる。この2件の失敗として返す。
      final String detail = 'ios/Runner/Info.plist を読めません: $error';
      return <DoctorCheck>[
        DoctorCheck.failed(usageLabel, detail: detail),
        DoctorCheck.failed(allowsLabel, detail: detail),
      ];
    }

    final DoctorCheck usageCheck =
        contents.contains('<key>$_localNetworkUsageKey</key>')
        ? const DoctorCheck.ok(usageLabel)
        : const DoctorCheck.failed(
            usageLabel,
            detail: 'ありません。これが無いと LAN の WebSocket に繋がりません',
          );

    final DoctorCheck allowsCheck = _hasLocalNetworkingException(contents)
        ? const DoctorCheck.ok(allowsLabel)
        : const DoctorCheck.failed(
            allowsLabel,
            detail:
                '$_appTransportSecurityKey 配下にありません。'
                'これが無いと LAN の WebSocket に繋がりません',
          );

    return <DoctorCheck>[usageCheck, allowsCheck];
  }

  /// `NSAppTransportSecurity` 配下に `NSAllowsLocalNetworking` が
  /// `true` で入っているかを、素朴な文字列探索で見る。
  ///
  /// **探索範囲は ATS の `<dict>` の中だけ。** root 直下に置かれた
  /// `NSAllowsLocalNetworking` は ATS の設定として効かないため、
  /// それを成功と判定してはいけない。
  static bool _hasLocalNetworkingException(String contents) {
    final String? body = _appTransportSecurityBody(contents);
    if (body == null) {
      return false;
    }
    const String key = '<key>$_localNetworkingKey</key>';
    final int keyIndex = body.indexOf(key);
    if (keyIndex == -1) {
      return false;
    }
    final String after = body.substring(keyIndex + key.length).trimLeft();
    return after.startsWith('<true/>') || after.startsWith('<true></true>');
  }

  /// `NSAppTransportSecurity` に対応する `<dict>` の中身を切り出す。
  ///
  /// 入れ子の `<dict>` を数えて対応する `</dict>` を見つける。キーが
  /// 無い・値が辞書でない・閉じていない、のいずれでも null を返す。
  static String? _appTransportSecurityBody(String contents) {
    const String open = '<dict>';
    const String close = '</dict>';
    final int atsIndex = contents.indexOf(
      '<key>$_appTransportSecurityKey</key>',
    );
    if (atsIndex == -1) {
      return null;
    }

    final String rest = contents
        .substring(atsIndex + '<key>$_appTransportSecurityKey</key>'.length)
        .trimLeft();
    // 空の辞書。中身が無いので探すまでもない。
    if (rest.startsWith('<dict/>')) {
      return '';
    }
    if (!rest.startsWith(open)) {
      // 値が辞書でない。ATS の設定として壊れている。
      return null;
    }

    int depth = 1;
    int cursor = open.length;
    while (true) {
      final int nextOpen = rest.indexOf(open, cursor);
      final int nextClose = rest.indexOf(close, cursor);
      if (nextClose == -1) {
        // 閉じていない。
        return null;
      }
      if (nextOpen != -1 && nextOpen < nextClose) {
        depth++;
        cursor = nextOpen + open.length;
        continue;
      }
      depth--;
      if (depth == 0) {
        return rest.substring(open.length, nextClose);
      }
      cursor = nextClose + close.length;
    }
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

  /// `stderr` が空でない `String` ならそのまま、それ以外は null。
  static String? _trimmed(Object? stderr) {
    if (stderr is! String) {
      return null;
    }
    final String trimmed = stderr.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
