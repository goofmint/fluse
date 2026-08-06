import 'dart:async';

import 'package:vm_service/vm_service.dart' as vm;
import 'package:vm_service/vm_service_io.dart' as vm_io;

import 'fluse_logger.dart';
import 'reload_contracts.dart';

/// VM Service とのやり取りに失敗したときに投げる。
final class VmServiceException implements Exception {
  const VmServiceException(this.message, {this.cause});

  final String message;

  /// 元になった例外。原因を追えるように保持する。
  final Object? cause;

  @override
  String toString() =>
      cause == null ? 'VM Service: $message' : 'VM Service: $message ($cause)';
}

/// `reloadSources` の結果。
///
/// `vm_service` の [vm.ReloadReport] は動的な JSON をそのまま持つので、
/// 使う値だけを型付きで取り出す。
final class ReloadResult {
  const ReloadResult({required this.success, this.notices = const <String>[]});

  /// リロードが受理されたか。
  ///
  /// **false のときに `CompilerService.accept()` を呼んではいけない**
  /// （設計 §10-2）。
  final bool success;

  /// VM が返した補足メッセージ。失敗理由の表示に使う。
  final List<String> notices;

  @override
  String toString() => 'ReloadResult(success: $success, notices: $notices)';
}

/// VM Service への接点を一本化するクライアント（設計 §2.2.3(c)）。
///
/// DevFS の作成・削除もここを通す。`vm_service` パッケージに触れる場所を
/// 1つに絞ることで、バージョン追従の影響範囲を閉じ込める。
final class VmServiceClient implements VmServiceContract {
  VmServiceClient(
    this._service, {
    required this.httpAddress,
    FluseLogger? logger,
  }) : _logger = logger;

  /// VM Service の HTTP ルート。`http://127.0.0.1:<port>/<authCode>/` の形。
  ///
  /// DevFS への PUT はここへ送る。**パスセグメントの認証コードが
  /// そのまま資格情報**なので、ログに出す際は必ずマスクする。
  final Uri httpAddress;

  final vm.VmService _service;
  final FluseLogger? _logger;

  /// 生の [vm.VmService]。ここに無いRPCが必要になった場合の逃げ道。
  vm.VmService get service => _service;

  /// HTTP ルートから WebSocket の URI を作る。
  ///
  /// flutter_tools と同じ規則（`vmservice.dart:400`）。
  /// `http://host:port/auth/` → `ws://host:port/auth/ws`
  static Uri webSocketUriFor(Uri httpUri) {
    final List<String> segments =
        httpUri.pathSegments.where((String s) => s.isNotEmpty).toList()
          ..add('ws');
    return httpUri.replace(
      scheme: httpUri.scheme == 'https' ? 'wss' : 'ws',
      pathSegments: segments,
    );
  }

  /// VM Service に接続する。
  ///
  /// [httpUri] は `VmServiceReadyMessage.vmServiceUri` で受け取る
  /// HTTP ルート（設計 §2.2.1）。
  static Future<VmServiceClient> connect(
    Uri httpUri, {
    FluseLogger? logger,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    // URI のパスに認証コードが入っている。以降のログから確実に消すため、
    // 接続前に秘匿対象へ登録する。
    for (final String segment in httpUri.pathSegments) {
      if (segment.isNotEmpty) {
        logger?.addSecret(segment);
      }
    }

    final Uri wsUri = webSocketUriFor(httpUri);
    logger?.debug(
      'VM Service に接続します',
      fields: <String, Object?>{'uri': '$wsUri'},
    );

    final vm.VmService service;
    try {
      service = await vm_io
          .vmServiceConnectUri(wsUri.toString())
          .timeout(timeout);
    } on TimeoutException {
      throw VmServiceException('$timeout 以内に接続できませんでした');
    } on Object catch (error) {
      throw VmServiceException('接続に失敗しました', cause: error);
    }

    return VmServiceClient(service, httpAddress: httpUri, logger: logger);
  }

  /// Flutter アプリのメイン isolate を特定する。
  ///
  /// 通常は1つだけだが、`dart:isolate` を使うアプリでは複数ありうる。
  /// **`main` という名前を優先し、無ければ先頭を採る**。VM は起動順に
  /// isolate を並べるので、先頭がルート isolate になる。
  @override
  Future<String> findMainIsolateId() async {
    final vm.VM machine;
    try {
      machine = await _service.getVM();
    } on Object catch (error) {
      throw VmServiceException('getVM に失敗しました', cause: error);
    }

    final List<vm.IsolateRef> isolates = machine.isolates ?? <vm.IsolateRef>[];
    if (isolates.isEmpty) {
      throw const VmServiceException(
        'isolate が1つも見つかりません。アプリがまだ起動していない可能性があります',
      );
    }

    final vm.IsolateRef selected = isolates.firstWhere(
      (vm.IsolateRef ref) => ref.name == 'main',
      orElse: () => isolates.first,
    );

    final String? id = selected.id;
    if (id == null) {
      throw const VmServiceException('isolate に id がありません');
    }

    _logger?.debug(
      'メイン isolate を特定しました',
      fields: <String, Object?>{'isolateId': id, 'name': selected.name},
    );
    return id;
  }

  /// DevFS を作る。返るのは DevFS のベース URI。
  Future<Uri> createDevFS(String fsName) async {
    final vm.Response response;
    try {
      response = await _service.callServiceExtension(
        '_createDevFS',
        args: <String, Object?>{'fsName': fsName},
      );
    } on Object catch (error) {
      throw VmServiceException('DevFS "$fsName" を作成できません', cause: error);
    }

    final Object? uri = response.json?['uri'];
    if (uri is! String) {
      throw VmServiceException(
        'DevFS "$fsName" の作成応答に uri がありません',
        cause: response.json,
      );
    }

    _logger?.debug(
      'DevFS を作成しました',
      fields: <String, Object?>{'fsName': fsName, 'uri': uri},
    );
    return Uri.parse(uri);
  }

  /// DevFS を消す。
  Future<void> deleteDevFS(String fsName) async {
    try {
      await _service.callServiceExtension(
        '_deleteDevFS',
        args: <String, Object?>{'fsName': fsName},
      );
    } on Object catch (error) {
      throw VmServiceException('DevFS "$fsName" を削除できません', cause: error);
    }
    _logger?.debug(
      'DevFS を削除しました',
      fields: <String, Object?>{'fsName': fsName},
    );
  }

  /// 差分を反映する。
  ///
  /// [rootLibUri] には DevFS 上の差分 dill を指す URI を渡す。
  @override
  Future<ReloadResult> reloadSources(
    String isolateId, {
    String? rootLibUri,
    String? packagesUri,
  }) async {
    final vm.ReloadReport report;
    try {
      report = await _service.reloadSources(
        isolateId,
        rootLibUri: rootLibUri,
        packagesUri: packagesUri,
      );
    } on Object catch (error) {
      throw VmServiceException('reloadSources に失敗しました', cause: error);
    }

    // `report.success` は見ない。vm_service が `json['success'] ?? false`
    // で埋めてしまうため（vm_service.dart:7426）、応答に success が無い
    // ケースと「失敗した」ケースを区別できない。生の JSON を見る。
    final Map<String, Object?>? json = report.json;
    final Object? rawSuccess = json?['success'];
    if (rawSuccess is! bool) {
      // 不明を false に落とすと「失敗したのか応答が壊れているのか」が
      // 区別できない。どちらも先へ進めてはいけないので明示的に落とす。
      throw VmServiceException(
        'reloadSources の応答に success がありません',
        cause: json,
      );
    }
    final bool success = rawSuccess;
    final List<String> notices = _extractNotices(json);

    _logger?.debug(
      'reloadSources の結果',
      fields: <String, Object?>{'success': success, 'notices': notices},
    );
    return ReloadResult(success: success, notices: notices);
  }

  /// ウィジェットツリーを作り直す。リロード後の画面反映に必要。
  @override
  Future<void> reassemble(String isolateId) async {
    try {
      await _service.callServiceExtension(
        'ext.flutter.reassemble',
        isolateId: isolateId,
      );
    } on Object catch (error) {
      throw VmServiceException('reassemble に失敗しました', cause: error);
    }
    _logger?.debug('reassemble しました');
  }

  /// 画像キャッシュから [assetPath] を追い出す。
  ///
  /// asset を差し替えたときに呼ばないと、古い画像が表示され続ける。
  @override
  Future<void> evict(String isolateId, String assetPath) async {
    try {
      await _service.callServiceExtension(
        'ext.flutter.evict',
        isolateId: isolateId,
        args: <String, Object?>{'value': assetPath},
      );
    } on Object catch (error) {
      throw VmServiceException('evict に失敗しました: $assetPath', cause: error);
    }
    _logger?.debug(
      'asset を evict しました',
      fields: <String, Object?>{'asset': assetPath},
    );
  }

  /// 接続を閉じる。
  Future<void> dispose() async {
    await _service.dispose();
  }

  /// `ReloadReport` の JSON から補足メッセージを取り出す。
  ///
  /// `notices` は VM の仕様上そもそも省略されうるので、無い場合は空に
  /// する。ただし**有るのに List でない場合は応答が壊れている**ので、
  /// 黙って空にせず落とす。
  static List<String> _extractNotices(Map<String, Object?>? json) {
    if (json == null || !json.containsKey('notices')) {
      return const <String>[];
    }
    final Object? notices = json['notices'];
    if (notices is! List) {
      throw VmServiceException(
        'reloadSources の notices を解釈できません',
        cause: notices,
      );
    }
    return <String>[
      for (final Object? notice in notices)
        if (notice is Map && notice['message'] is String)
          '${notice['message']}'
        else
          '$notice',
    ];
  }
}
