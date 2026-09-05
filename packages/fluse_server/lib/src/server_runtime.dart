import 'dart:async';
import 'dart:io';

// DiagnosticEntry / DiagnosticSeverity はサーバ内部にも同名の型がある。
// 設計どおり別物（あちらは frontend_server の生の出力を持つ内部表現）
// なので、内部の型を素で使い、ワイヤ用は wire. で呼び分ける。
import 'package:fluse_protocol/fluse_protocol.dart'
    hide DiagnosticEntry, DiagnosticSeverity;
import 'package:fluse_protocol/fluse_protocol.dart'
    as wire
    show DiagnosticEntry, DiagnosticSeverity;

import 'asset_bundle_service.dart';
import 'change_classifier.dart';
import 'compile_output.dart';
import 'dev_fs_client.dart';
import 'file_watcher.dart';
import 'fluse_logger.dart';
import 'hot_reload_orchestrator.dart';
import 'reload_contracts.dart';
import 'server_contracts.dart';
import 'tunnel_channel.dart';
import 'tunnel_endpoint.dart';
import 'vm_service_client.dart';
import 'ws_server.dart';

/// [TunnelEndpoint] を作る。テストから差し替えるために切り出す。
typedef TunnelEndpointFactory =
    TunnelContract Function(TunnelChannel channel, FluseLogger? logger);

/// ローカルの VM Service URI に繋ぐ。
typedef VmServiceConnector =
    Future<SessionVmServiceContract> Function(Uri httpUri, FluseLogger? logger);

/// [DevFSClient] を作る。
typedef DevFSClientFactory =
    DevFSContract Function(
      SessionVmServiceContract vmService,
      FluseLogger? logger,
    );

/// 反映経路の統合（設計 §3.1 / §3.2）。
///
/// 部品はそれぞれ単体で完結しているが、**寿命が2種類ある**。
///
/// - 接続をまたいで生きるもの: `CompilerService`（`frontend_server` の
///   プロセスと増分コンパイルの状態）と `FileWatcher`
/// - 接続ごとに作り直すもの: トンネル・VM Service 接続・DevFS
///
/// 混ぜると、再接続のたびに全部を作り直して初回コンパイルからやり直す
/// （数十秒かかる）か、逆に死んだ接続の DevFS を掴んだままになる。
/// ここで線を引く。
final class ServerRuntime {
  ServerRuntime({
    required WsServer Function(ServerRuntime runtime) wsServerFactory,
    required ServerCompilerContract compiler,
    required FileWatcher fileWatcher,
    required AssetBundleService assets,
    required this.mainUri,
    required this.dillDeviceUri,
    required this.rootLibUri,
    this.devFsName = defaultDevFsName,
    FluseLogger? logger,
    TunnelEndpointFactory? tunnelFactory,
    VmServiceConnector? vmServiceConnector,
    DevFSClientFactory? devFsFactory,
  }) : _compiler = compiler,
       _fileWatcher = fileWatcher,
       _assets = assets,
       _logger = logger,
       _tunnelFactory =
           tunnelFactory ??
           ((TunnelChannel channel, FluseLogger? logger) =>
               TunnelEndpoint(channel: channel, logger: logger)),
       _vmServiceConnector =
           vmServiceConnector ??
           ((Uri httpUri, FluseLogger? logger) =>
               VmServiceClient.connect(httpUri, logger: logger)),
       _devFsFactory =
           devFsFactory ??
           ((SessionVmServiceContract vmService, FluseLogger? logger) =>
               DevFSClient(
                 vmService: vmService as VmServiceClient,
                 logger: logger,
               )) {
    _wsServer = wsServerFactory(this);
  }

  /// DevFS の名前。flutter_tools と衝突しないよう独自の名前を使う。
  static const String defaultDevFsName = 'fluse';

  /// コンパイル対象のエントリポイント。
  final Uri mainUri;

  /// 差分 dill を DevFS のどこに置くか。
  final Uri dillDeviceUri;

  /// `reloadSources` に渡す `rootLibUri`。
  final String rootLibUri;

  /// 作る DevFS の名前。
  final String devFsName;

  final ServerCompilerContract _compiler;
  final FileWatcher _fileWatcher;
  final AssetBundleService _assets;
  final FluseLogger? _logger;
  final TunnelEndpointFactory _tunnelFactory;
  final VmServiceConnector _vmServiceConnector;
  final DevFSClientFactory _devFsFactory;

  late final WsServer _wsServer;

  /// 今つながっている端末のセッション。空いていれば null。
  ///
  /// Phase1 は1台のみ（設計 §10-10）なので1つで足りる。
  _Session? _session;

  StreamSubscription<ChangeSet>? _changesSubscription;
  StreamSubscription<ChangeSet>? _outdatedSubscription;

  /// 変更の反映を直列化する。
  ///
  /// **前の反映が終わる前に次を始めない。** `frontend_server` は
  /// accept / reject の応答待ちを1つしか持てず、重ねると差分の状態が
  /// 壊れて以降のリロードが全部失敗する（設計 §10-2）。
  Future<void> _reloadQueue = Future<void>.value();

  bool _started = false;
  bool _closed = false;

  /// 待ち受けているサーバ。
  WsServer get wsServer => _wsServer;

  /// 反映中のセッションがあるか。
  bool get hasSession => _session != null;

  /// 現在のセッションの DevFS 名。無ければ null。テストと診断のため。
  String? get activeDevFsName => _session?.devFS.fsName;

  /// 待ち受けとファイル監視を始める。
  Future<Uri> start() async {
    if (_started) {
      throw StateError('すでに start 済みです');
    }
    _started = true;

    await _fileWatcher.start();
    _changesSubscription = _fileWatcher.changes.listen(_onChanges);
    _outdatedSubscription = _fileWatcher.outdated.listen(_onOutdated);

    return _wsServer.start();
  }

  /// 全部畳む。二重に呼んでも安全。
  ///
  /// [CompilerService] もここで落とす。セッション単位の解放
  /// （[_releaseSession]）とは寿命が違う。
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;

    await _changesSubscription?.cancel();
    await _outdatedSubscription?.cancel();
    await _fileWatcher.close();
    await _wsServer.close();
    await _releaseSession();
    await _compiler.shutdown();
  }

  // ------------------------------------------------------------ WebSocket

  /// 認証が通った。まだ VM Service は立っていない。
  void onAuthenticated(FluseConnection connection) {
    _logger?.info('端末が接続しました');
  }

  /// 制御メッセージを受け取った。
  void onMessage(FluseConnection connection, FluseMessage message) {
    switch (message) {
      case VmServiceReadyMessage(:final String vmServiceUri):
        // 端末で VM Service が立った。ここから §3.1 の後半に入る。
        unawaited(_openSession(connection, vmServiceUri));
      default:
        _logger?.debug(
          '扱わない制御メッセージを受け取りました',
          fields: <String, Object?>{'type': message.type},
        );
    }
  }

  /// 切断された。接続に紐づく資源だけを解放する。
  void onDisconnected(FluseConnection connection) {
    if (_session?.connection != connection) {
      // 認証前に切れた接続など。掴んでいる資源が無い。
      return;
    }
    // 切断は同期のコールバックで来る。解放は待たずに走らせる。
    unawaited(_releaseSession());
  }

  // --------------------------------------------------------- 接続シーケンス

  /// 設計 §3.1 の後半。トンネルを張って初回同期まで進め、`ready` を返す。
  Future<void> _openSession(
    FluseConnection connection,
    String vmServiceUri,
  ) async {
    if (_session != null) {
      // 同じ端末が vmServiceReady を2度送ってきた。作り直すと
      // 前のトンネルと DevFS が宙に浮く。
      _logger?.warn('すでにセッションが確立しています。vmServiceReady を無視します');
      return;
    }

    TunnelContract? tunnel;
    SessionVmServiceContract? vmService;
    DevFSContract? devFS;
    try {
      tunnel = _tunnelFactory(connection, _logger);
      final Uri localUri = await tunnel.bind(vmServiceUri);

      vmService = await _vmServiceConnector(localUri, _logger);
      devFS = _devFsFactory(vmService, _logger);
      await devFS.create(devFsName);

      final HotReloadOrchestrator orchestrator = HotReloadOrchestrator(
        mainUri: mainUri,
        dillDeviceUri: dillDeviceUri,
        rootLibUri: rootLibUri,
        compiler: _compiler,
        devFS: devFS,
        vmService: vmService,
        logger: _logger,
      );

      _session = _Session(
        connection: connection,
        tunnel: tunnel,
        vmService: vmService,
        devFS: devFS,
        orchestrator: orchestrator,
      );

      await _initialSync(_session!);
      connection.sendMessage(const ReadyMessage());
      _logger?.info('初回同期が完了しました');
    } on Object catch (error, stackTrace) {
      _logger?.error(
        '接続シーケンスに失敗しました',
        fields: <String, Object?>{'error': '$error'},
      );
      connection.sendMessage(
        ErrorMessage(
          code: FluseErrorCode.tunnelLost.wireValue,
          message: '端末との接続を確立できませんでした',
          detail: '$error',
        ),
      );

      // 途中まで作った資源を残さない。_session に入る前に失敗した場合も
      // あるので、ローカル変数から畳む。
      if (_session != null) {
        await _releaseSession();
      } else {
        await _releaseParts(tunnel: tunnel, vmService: vmService, devFS: devFS);
      }
      _logger?.debug('$stackTrace');
    }
  }

  /// 端末に今のソースと asset を丸ごと入れる。
  ///
  /// **必ず1回は通す。** APK に同梱された kernel_blob.bin は init 時点の
  /// 内容で、start までの変更を含まない（Task 1.6 のスパイク結論）。
  Future<void> _initialSync(_Session session) async {
    final CompileOutput compiled = await _compiler.compile(mainUri);
    if (compiled.hasErrors) {
      throw StateError('初回コンパイルに失敗しました: ${compiled.summary}');
    }
    final File? dill = compiled.incrementalDill;
    if (dill == null) {
      // エラーが無いのに出力が無いのは frontend_server 側の異常。
      // 転送するものが無いまま reloadSources を投げても意味が無い。
      throw StateError('初回コンパイルの出力がありません');
    }

    final AssetSyncResult syncResult = _assets.sync();
    await session.devFS.writeAll(<Uri, DevFSContent>{
      dillDeviceUri: DevFSContent.fromFile(dill),
      for (final ChangedAsset asset in syncResult.changed)
        asset.deviceUri: asset.content,
    });

    final String isolateId = await session.vmService.findMainIsolateId();
    final ReloadResult result = await session.vmService.reloadSources(
      isolateId,
      rootLibUri: rootLibUri,
    );
    if (!result.success) {
      // ここで accept すると frontend_server の状態が実機とずれ、
      // 以降の全リロードが壊れる（設計 §10-2）。
      await _compiler.reject();
      throw StateError(
        '初回の reloadSources が失敗しました: ${result.notices.join(', ')}',
      );
    }
    _compiler.accept();

    await _registerAssetDirectory(session);
    await session.vmService.reassemble(isolateId);
  }

  /// asset の置き場所を端末へ教える。
  ///
  /// これを飛ばすと、転送した asset を端末が探しに行かない。
  Future<void> _registerAssetDirectory(_Session session) async {
    final Uri? base = session.devFS.baseUri;
    if (base == null) {
      return;
    }
    final Uri assetsDirectory = base.resolve(
      '${AssetBundleService.devFsAssetRoot}/',
    );

    for (final ({String viewId, String? isolateId}) view
        in await session.vmService.listViews()) {
      await session.vmService.setAssetDirectory(
        viewId: view.viewId,
        isolateId: view.isolateId,
        assetsDirectory: assetsDirectory,
      );
    }
  }

  // --------------------------------------------------------------- 変更反映

  void _onChanges(ChangeSet changes) {
    final _Session? session = _session;
    if (session == null) {
      // 端末が繋がっていない間の変更は捨てる。次の接続で初回同期が
      // 走り、その時点の内容が丸ごと入る。
      _logger?.debug('セッションが無いため変更を保留しません');
      return;
    }

    // 前の反映が終わってから次を始める。重ねると差分の状態が壊れる。
    _reloadQueue = _reloadQueue.then((void _) => _reload(session, changes));
  }

  Future<void> _reload(_Session session, ChangeSet changes) async {
    if (_session != session) {
      // 反映を待っている間に切断された。
      return;
    }

    List<ChangedAsset> changedAssets = const <ChangedAsset>[];
    if (changes.assets.isNotEmpty) {
      changedAssets = _assets.sync().changed;
    }

    final HotReloadResult result = await session.orchestrator.reload(
      invalidated: <Uri>[
        for (final String path in changes.dartSources) Uri.file(path),
      ],
      changedAssets: changedAssets,
    );

    switch (result.status) {
      case HotReloadStatus.success:
        session.connection.sendMessage(const CompileOkMessage());
      case HotReloadStatus.compileError:
        // 画面に赤く出す。Watch は続ける（設計 §5.1）。
        session.connection.sendMessage(
          CompileErrorMessage(
            summary: result.summary,
            diagnostics: result.diagnostics.map(_toWire).toList(),
          ),
        );
      case HotReloadStatus.reloadFailure:
        session.connection.sendMessage(
          ErrorMessage(
            code: FluseErrorCode.reloadRejected.wireValue,
            message: result.summary,
          ),
        );
    }
  }

  void _onOutdated(ChangeSet changes) {
    // 指紋が変わった。増分では埋められないので作り直してもらう。
    // FileWatcher は既に監視を止めている。
    _logger?.warn('Preview App が古くなりました。fluse rebuild が必要です');
    _session?.connection.sendMessage(
      ErrorMessage(
        code: FluseErrorCode.appOutdated.wireValue,
        message: 'Preview App が古くなりました。fluse rebuild を実行してください',
        detail: changes.fingerprintTargets.join(', '),
      ),
    );
  }

  // --------------------------------------------------------------- 後始末

  /// 接続に紐づく資源だけを解放する。
  ///
  /// **`CompilerService` は落とさない。** `frontend_server` を落とすと
  /// 増分コンパイルの状態が消え、再接続後の初回コンパイルが数十秒かかる。
  Future<void> _releaseSession() async {
    final _Session? session = _session;
    if (session == null) {
      return;
    }
    _session = null;

    await _releaseParts(
      tunnel: session.tunnel,
      vmService: session.vmService,
      devFS: session.devFS,
    );
    _logger?.info('セッションを解放しました');
  }

  /// 資源を安全な順で畳む。
  ///
  /// **DevFS を先に消す。** トンネルを先に切ると deleteDevFS が届かず、
  /// 端末側に DevFS が残ったまま次の接続で同じ名前を作れなくなる。
  Future<void> _releaseParts({
    required TunnelContract? tunnel,
    required SessionVmServiceContract? vmService,
    required DevFSContract? devFS,
  }) async {
    if (devFS != null) {
      await _ignoreFailure('DevFS の削除', devFS.destroy);
      devFS.close();
    }
    if (vmService != null) {
      await _ignoreFailure('VM Service の切断', vmService.dispose);
    }
    if (tunnel != null) {
      await _ignoreFailure('トンネルの終了', tunnel.close);
    }
  }

  /// 後始末の失敗で残りを止めない。
  ///
  /// 相手が既に居ない場合、DevFS の削除も VM Service の切断も失敗する。
  /// そこで止めるとトンネルが閉じられずに残る。
  Future<void> _ignoreFailure(
    String what,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } on Object catch (error) {
      _logger?.warn('$what に失敗しました: $error');
    }
  }
}

/// サーバ内部の診断をワイヤ表現へ写す。
///
/// `raw`（`frontend_server` の生の行）は載せない。CLI に原文を出すための
/// もので、端末には要らない。
wire.DiagnosticEntry _toWire(DiagnosticEntry entry) => wire.DiagnosticEntry(
  severity:
      wire.DiagnosticSeverity.tryParse(entry.severity.name) ??
      wire.DiagnosticSeverity.error,
  message: entry.message,
  file: entry.file,
  line: entry.line,
  col: entry.column,
);

/// 接続1本分の資源。
final class _Session {
  const _Session({
    required this.connection,
    required this.tunnel,
    required this.vmService,
    required this.devFS,
    required this.orchestrator,
  });

  final FluseConnection connection;
  final TunnelContract tunnel;
  final SessionVmServiceContract vmService;
  final DevFSContract devFS;
  final HotReloadOrchestrator orchestrator;
}
