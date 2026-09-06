import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:fluse_builder/fluse_builder.dart';
import 'package:fluse_server/fluse_server.dart';
import 'package:path/path.dart' as p;

import 'connect_uri.dart';
import 'console_qr.dart';
import 'fluse_command.dart';
import 'fluse_config.dart';
import 'fluse_context.dart';

/// 起動して待ち受けるまでの一式。テストから差し替える。
typedef ServerFactory = Future<StartedServer> Function(StartRequest request);

/// 立ち上がったサーバ。
final class StartedServer {
  const StartedServer({
    required this.uri,
    required this.pairingToken,
    required this.close,
  });

  /// 実際に待ち受けている場所。
  final Uri uri;

  /// 手入力用の合言葉（設計 §4.2(b)）。
  final String pairingToken;

  /// 畳む。
  final Future<void> Function() close;
}

/// サーバを立てるのに要るもの。
final class StartRequest {
  const StartRequest({
    required this.context,
    required this.project,
    required this.projectId,
    required this.appVersion,
    required this.host,
    required this.port,
    required this.target,
  });

  final FluseContext context;
  final ProjectInfo project;
  final String projectId;
  final String appVersion;
  final String host;
  final int port;
  final String target;
}

/// `fluse start`（設計 §2.2.4）。
///
/// QR を出して端末を待ち、繋がったら差分を送り続ける。
final class StartCommand implements FluseCommand {
  StartCommand({
    this.analyzer = const ProjectAnalyzer(),
    this.serverFactory = defaultServerFactory,
    this.onOutput = print,
    this.addresses,
    this.readLine = _readStdin,
  }) : argParser = ArgParser() {
    argParser
      ..addOption('port', help: '待ち受けるポート。', valueHelp: 'n')
      ..addOption(
        'host',
        help: '待ち受けるアドレス。省略すると LAN の私設 IPv4 を選びます。',
        valueHelp: 'ip',
      )
      ..addOption('target', help: '包む対象のエントリポイント。', valueHelp: 'path')
      ..addFlag('help', abbr: 'h', negatable: false, help: '使い方を表示します。');
  }

  final ProjectAnalyzer analyzer;
  final ServerFactory serverFactory;

  /// 利用者への表示。**QR はログではなく画面に出す。**
  final void Function(String line) onOutput;

  /// 候補アドレスの取得。テストから差し替える。
  final Future<List<InternetAddress>> Function()? addresses;

  final String? Function() readLine;

  static String? _readStdin() => stdin.readLineSync();

  @override
  String get name => 'start';

  @override
  String get description => 'Preview Server を立てて端末を待ちます。';

  @override
  final ArgParser argParser;

  @override
  Future<int> run(ArgResults args, FluseContext context) async {
    try {
      return await _run(args, context);
    } on Object catch (error) {
      context.logger.error('$error');
      onOutput('$error');
      return 1;
    }
  }

  Future<int> _run(ArgResults args, FluseContext context) async {
    final FluseConfig config = FluseConfig.resolve(
      projectRoot: context.projectRoot,
      portArgument: _intOf(args, 'port'),
      targetArgument: _stringOf(args, 'target'),
    );

    final ProjectInfo project = await analyzer.analyze(context.projectRoot);

    // **繋ぐ前に確かめる。** 古い APK のまま繋ぐと、差分を送っても
    // 反映されない理由が分からなくなる（設計 §5.1 の APP_OUTDATED）。
    final Fingerprint? current = await _checkFingerprint(context, project);
    if (current == null) {
      return 1;
    }

    final String? host = await _resolveHost(
      context,
      explicit: _stringOf(args, 'host'),
    );
    if (host == null) {
      return 1;
    }

    final StartedServer server = await serverFactory(
      StartRequest(
        context: context,
        project: project,
        projectId: ProjectIdentity.projectIdOf(project),
        appVersion: ProjectIdentity.appVersionOf(current),
        host: host,
        port: config.port,
        target: config.target,
      ),
    );

    // **合言葉をログの伏せ字に登録する。** 以後どの経路から出ても
    // 平文にならない（設計 §6.1）。
    context.logger.addSecret(server.pairingToken);

    _showConnectionInfo(
      context: context,
      server: server,
      projectId: ProjectIdentity.projectIdOf(project),
      host: host,
    );

    await _waitForKeys(server, context);
    return 0;
  }

  // ------------------------------------------------------------------ 指紋

  /// 今の指紋を返す。食い違っていれば null。
  Future<Fingerprint?> _checkFingerprint(
    FluseContext context,
    ProjectInfo project,
  ) async {
    final File file = File(
      p.join(context.previewDir.path, 'cache', 'fingerprint.json'),
    );
    final File metaFile = File(
      p.join(context.previewDir.path, 'cache', 'build_meta.json'),
    );

    // **読めないことを「差分なし」と読み替えない。** 古い APK のまま
    // 動き続けることになる。
    final Fingerprint saved = await Fingerprint.readFrom(file);
    final BuildMeta meta = BuildMeta.readFrom(metaFile);

    final Fingerprint current = await Fingerprint.compute(
      project,
      context.sdk,
      buildFlags: <String>[
        if (meta.trackWidgetCreation) '--track-widget-creation',
        if (meta.enableAsserts) '--enable-asserts',
        for (final String define in meta.dartDefines) '-D$define',
      ],
      previous: saved,
    );

    final List<String> changed = current.diff(saved);
    if (changed.isEmpty) {
      return current;
    }

    // 何が変わったかはキー名だけ出す。値にはパスが混ざる。
    onOutput('');
    onOutput('✗ APP_OUTDATED: 端末の Preview App が古くなっています');
    onOutput('');
    onOutput('  変わったもの:');
    for (final String key in changed) {
      onOutput('    $key');
    }
    onOutput('');
    onOutput('  `fluse rebuild` で作り直してください。');
    context.logger.warn(
      'APP_OUTDATED',
      fields: <String, Object?>{'changed': changed},
    );
    return null;
  }

  // ------------------------------------------------------------ アドレス

  /// 待ち受けるアドレスを決める。決められなければ null。
  Future<String?> _resolveHost(FluseContext context, {String? explicit}) async {
    if (explicit != null) {
      // **明示指定は尊重する。** `0.0.0.0` も含む。判断は利用者のもの。
      return explicit;
    }

    final List<InternetAddress> candidates = await listPrivateIPv4(
      addresses: addresses,
    );
    if (candidates.isEmpty) {
      onOutput('端末から届くアドレスが見つかりません。');
      onOutput('Wi-Fi に繋がっているか確認するか、`--host <IP>` で指定してください。');
      return null;
    }
    if (candidates.length == 1) {
      return candidates.first.address;
    }

    // **勝手に選ばない。** 複数の NIC がある機では、端末から届かない側を
    // 選ぶと「QR は出るのに繋がらない」状態になる。
    onOutput('');
    onOutput('どのアドレスで待ち受けますか？');
    for (int i = 0; i < candidates.length; i++) {
      onOutput('  ${i + 1}) ${candidates[i].address}');
    }
    while (true) {
      onOutput('番号を入力してください [1-${candidates.length}]: ');
      final String? answer = readLine()?.trim();
      if (answer == null) {
        // 入力が閉じた。決めずに止める。
        onOutput('選ばれませんでした。`--host <IP>` で指定してください。');
        return null;
      }
      final int? index = int.tryParse(answer);
      if (index != null && index >= 1 && index <= candidates.length) {
        return candidates[index - 1].address;
      }
      onOutput('1 から ${candidates.length} で答えてください');
    }
  }

  // ------------------------------------------------------------------ 表示

  void _showConnectionInfo({
    required FluseContext context,
    required StartedServer server,
    required String projectId,
    required String host,
  }) {
    final String uri = ConnectUri.build(
      lanHost: host,
      port: server.uri.port,
      projectId: projectId,
      pairingToken: server.pairingToken,
      flutterRevision: context.sdk.revision,
    );

    onOutput('');
    onOutput(
      'fluse  •  Flutter ${context.sdk.version} '
      '(${ConnectUri.shortRevision(context.sdk.revision)})',
    );
    onOutput('');
    onOutput('  QRコードをPreview Appでスキャンしてください');
    onOutput('');
    onOutput(ConsoleQr.render(uri));
    onOutput('  http://$host:${server.uri.port}');
    // **合言葉を平文で出す。** QR を読めない端末のための手入力導線
    // （設計 §2.2.3 / §4.2(b)）。画面には出すが、ログには残さない。
    onOutput('  手で入れる場合のトークン: ${server.pairingToken}');
    onOutput('  端末が見つからない場合は  fluse start --host <IP>');
    onOutput('');
    onOutput('  r: 手動リロード  q: 終了');
  }

  // ------------------------------------------------------------ キー入力

  Future<void> _waitForKeys(StartedServer server, FluseContext context) async {
    while (true) {
      final String? key = readLine()?.trim().toLowerCase();
      if (key == null || key == 'q') {
        // **必ず畳む。** 掴んだままだと次の `fluse start` がポートを
        // 取れない。
        await server.close();
        return;
      }
      if (key == 'r') {
        // 手動リロードの実体は Task 5.10。ここでは受け口だけ。
        context.logger.info('手動リロードを受け付けました');
        onOutput('  リロードを要求しました');
      }
    }
  }

  // ------------------------------------------------------------------ 道具

  static int? _intOf(ArgResults args, String name) {
    final String? raw = _stringOf(args, name);
    if (raw == null) {
      return null;
    }
    final int? parsed = int.tryParse(raw);
    if (parsed == null) {
      throw FormatException('--$name が整数ではありません: $raw');
    }
    return parsed;
  }

  static String? _stringOf(ArgResults args, String name) {
    if (!args.options.contains(name)) {
      return null;
    }
    final Object? value = args[name];
    return value is String && value.isNotEmpty ? value : null;
  }

  /// 本番の配線。
  static Future<StartedServer> defaultServerFactory(
    StartRequest request,
  ) async {
    final FluseContext context = request.context;
    final String previewPath = context.previewDir.path;

    final SessionManager sessions = SessionManager(
      expectedProjectId: request.projectId,
      expectedFlutterRevision: context.sdk.revision,
      expectedAppVersion: request.appVersion,
      deviceStore: DeviceStore.readFrom(
        File(p.join(previewPath, 'devices.json')),
      ),
      logger: context.logger,
    );

    final BuildMeta meta = BuildMeta.readFrom(
      File(p.join(previewPath, 'cache', 'build_meta.json')),
    );

    // **記録されたフラグをそのまま再現する。** 1つでも違うと
    // reloadSources が静かに失敗する（設計 §10-1）。
    final CompilerService compiler = CompilerService(
      dartAotRuntime: context.sdk.dartAotRuntime,
      frontendServerSnapshot: context.sdk.frontendServerSnapshot,
      patchedSdkRoot: context.sdk.patchedSdkRoot,
      projectRoot: context.projectRoot.path,
      outputDill: p.join(previewPath, 'cache', 'app.dill'),
      packagesPath: p.join(
        context.projectRoot.path,
        '.dart_tool',
        'package_config.json',
      ),
      trackWidgetCreation: meta.trackWidgetCreation,
      enableAsserts: meta.enableAsserts,
      dartDefines: meta.dartDefines,
      buildMetaPath: p.join(previewPath, 'cache', 'build_meta.json'),
      processManager: context.processManager,
      logger: context.logger,
    );

    final PairingToken token = sessions.issuePairingToken();

    late final ServerRuntime runtime;
    runtime = ServerRuntime(
      wsServerFactory: (ServerRuntime self) => WsServer(
        sessionManager: sessions,
        host: request.host,
        port: request.port,
        serveApk: context.config.serveApk,
        apkPath: p.join(previewPath, 'build', 'preview.apk'),
        logger: context.logger,
        onAuthenticated: self.onAuthenticated,
        onMessage: self.onMessage,
        onDisconnected: self.onDisconnected,
      ),
      compiler: compiler,
      fileWatcher: FileWatcher(
        projectRoot: context.projectRoot.path,
        logger: context.logger,
      ),
      assets: AssetBundleService(
        projectRoot: context.projectRoot.path,
        logger: context.logger,
      ),
      mainUri: Uri.file(p.join(previewPath, 'fluse_main.dart')),
      dillDeviceUri: Uri.parse('lib/main.dart.dill'),
      rootLibUri: request.target,
      logger: context.logger,
    );

    final Uri uri = await runtime.start();
    return StartedServer(
      uri: uri,
      pairingToken: token.value,
      close: runtime.close,
    );
  }
}
