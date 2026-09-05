import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'fluse_logger.dart';
import 'server_contracts.dart';

/// DevFS への転送に失敗したときに投げる。
final class DevFSException implements Exception {
  const DevFSException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() =>
      cause == null ? 'DevFS: $message' : 'DevFS: $message ($cause)';
}

/// DevFS へ書き込む1件の中身。
///
/// 差分 dill も asset も、転送時にはただのバイト列として扱う。
final class DevFSContent {
  const DevFSContent(this.bytes);

  /// ファイルの内容をそのまま読み込む。
  factory DevFSContent.fromFile(File file) =>
      DevFSContent(file.readAsBytesSync());

  factory DevFSContent.fromString(String text) =>
      DevFSContent(utf8.encode(text));

  final List<int> bytes;

  int get length => bytes.length;
}

/// DevFS への差分転送（設計 §2.2.3(c) / §8.2-4）。
///
/// flutter_tools の `devfs.dart:280-360` と同一のプロトコルを話す。
/// **同時実行3固定・60秒タイムアウト・最大10回リトライは仕様であって
/// 調整可能なチューニングではない。** `request.close()` が応答を返さない
/// dart-lang/sdk#43525 を回避するための構成なので、緩めてはいけない。
final class DevFSClient implements DevFSContract {
  DevFSClient({
    required SessionVmServiceContract vmService,
    FluseLogger? logger,
    this.maxInFlight = defaultMaxInFlight,
    this.uploadTimeout = defaultUploadTimeout,
    this.maxRetries = defaultMaxRetries,
    this.retryDelay = defaultRetryDelay,
    HttpClient? httpClient,
  }) : _vmService = vmService,
       _logger = logger,
       _httpClient = httpClient ?? HttpClient() {
    // 0 以下だとスケジューラが1件も投げられず writeAll が返らなくなる。
    // 上限は dart-lang/sdk#43525 回避のための3（緩めてはいけない）。
    if (maxInFlight < 1 || maxInFlight > defaultMaxInFlight) {
      throw ArgumentError.value(
        maxInFlight,
        'maxInFlight',
        '1..$defaultMaxInFlight を指定してください',
      );
    }
  }

  /// 同時に投げる PUT の数。
  ///
  /// dart-lang/sdk#43525（PUT に応答が返らないことがある）の影響を
  /// 抑えるため、flutter_tools と同じ3に固定する。
  static const int defaultMaxInFlight = 3;

  /// 1件あたりの応答待ち上限。
  static const Duration defaultUploadTimeout = Duration(seconds: 60);

  /// 1件あたりの再試行回数。
  static const int defaultMaxRetries = 10;

  /// 再試行の間隔。
  static const Duration defaultRetryDelay = Duration(milliseconds: 500);

  final int maxInFlight;
  final Duration uploadTimeout;
  final int maxRetries;
  final Duration retryDelay;

  final SessionVmServiceContract _vmService;
  final FluseLogger? _logger;
  final HttpClient _httpClient;

  String? _fsName;
  Uri? _baseUri;

  /// create / destroy の直列化。同時に呼ばれても遷移が交差しないようにする。
  Future<void> _lifecycle = Future<void>.value();

  /// 作成済み DevFS の名前。未作成なら null。
  @override
  String? get fsName => _fsName;

  /// 作成済み DevFS のベース URI。未作成なら null。
  @override
  Uri? get baseUri => _baseUri;

  /// DevFS を作る。
  ///
  /// 同時に呼ばれても、2つ目は1つ目の完了後に「既に作成済み」で失敗する。
  @override
  Future<Uri> create(String fsName) => _serialize(() async {
    if (_fsName != null) {
      throw DevFSException('DevFS "$_fsName" が既に作成されています');
    }
    final Uri uri = await _vmService.createDevFS(fsName);
    _fsName = fsName;
    _baseUri = uri;
    _httpClient.maxConnectionsPerHost = maxInFlight;
    return uri;
  });

  /// DevFS を消す。二重に呼んでも安全。
  ///
  /// **削除が成功してから状態を消す。** 先に消すと、RPC が失敗したときに
  /// 再試行できず、端末側に DevFS が残り続ける。
  @override
  Future<void> destroy() => _serialize(() async {
    final String? name = _fsName;
    if (name == null) {
      return;
    }
    await _vmService.deleteDevFS(name);
    _fsName = null;
    _baseUri = null;
  });

  /// ライフサイクル遷移を直列化する。
  Future<T> _serialize<T>(Future<T> Function() action) {
    final Completer<T> completer = Completer<T>();
    _lifecycle = _lifecycle.then((_) async {
      try {
        completer.complete(await action());
      } on Object catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  /// 保持している接続を閉じる。
  @override
  void close() => _httpClient.close(force: true);

  /// PUT に付けるヘッダを組み立てる。
  ///
  /// `dev_fs_uri_b64` は **DevFS 上のパスを base64 にしたもの**。
  /// 生の URI をヘッダに入れると非 ASCII で壊れるため。
  static Map<String, String> buildHeaders({
    required String fsName,
    required Uri deviceUri,
  }) => <String, String>{
    'dev_fs_name': fsName,
    'dev_fs_uri_b64': base64.encode(utf8.encode('$deviceUri')),
  };

  /// ボディを gzip 圧縮する。
  ///
  /// flutter_tools は `ZLibEncoder(gzip: true)` を使う。`dart:io` の
  /// [gzip] は同じ zlib の gzip 形式なので、そのまま受理される。
  static Uint8List compress(List<int> bytes) =>
      Uint8List.fromList(gzip.encode(bytes));

  /// まとめて DevFS に書き込む。
  ///
  /// 1件でも最終的に失敗したら [DevFSException] を投げる。部分的に
  /// 書けた状態で成功を返すと、端末側の kernel と食い違ったまま
  /// `reloadSources` に進んでしまう。
  @override
  Future<void> writeAll(Map<Uri, DevFSContent> entries) async {
    final String? name = _fsName;
    if (name == null) {
      throw const DevFSException('DevFS が未作成です。先に create() を呼んでください');
    }
    if (entries.isEmpty) {
      return;
    }

    final Uri target = _vmService.httpAddress;
    final List<MapEntry<Uri, DevFSContent>> pending = entries.entries.toList();
    final Completer<void> completer = Completer<void>();
    int inFlight = 0;
    int index = 0;

    void scheduleNext() {
      while (inFlight < maxInFlight &&
          !completer.isCompleted &&
          index < pending.length) {
        final MapEntry<Uri, DevFSContent> entry = pending[index++];
        inFlight++;
        unawaited(
          _uploadWithRetry(
            target: target,
            fsName: name,
            deviceUri: entry.key,
            content: entry.value,
          ).then(
            (_) {
              inFlight--;
              scheduleNext();
            },
            onError: (Object error, StackTrace stackTrace) {
              inFlight--;
              if (!completer.isCompleted) {
                completer.completeError(error, stackTrace);
              }
            },
          ),
        );
      }
      if (inFlight == 0 && !completer.isCompleted && index >= pending.length) {
        completer.complete();
      }
    }

    scheduleNext();
    await completer.future;

    _logger?.debug(
      'DevFS への転送が完了しました',
      fields: <String, Object?>{
        'files': entries.length,
        'bytes': entries.values.fold<int>(
          0,
          (int sum, DevFSContent c) => sum + c.length,
        ),
      },
    );
  }

  Future<void> _uploadWithRetry({
    required Uri target,
    required String fsName,
    required Uri deviceUri,
    required DevFSContent content,
  }) async {
    final Uint8List body = compress(content.bytes);
    int remaining = maxRetries;

    while (true) {
      try {
        await _upload(
          target: target,
          fsName: fsName,
          deviceUri: deviceUri,
          body: body,
        );
        return;
      } on Object catch (error) {
        if (remaining <= 0) {
          throw DevFSException('$deviceUri の転送に失敗しました', cause: error);
        }
        remaining--;
        _logger?.debug(
          'DevFS への転送を再試行します',
          fields: <String, Object?>{
            'uri': '$deviceUri',
            'remaining': remaining,
            'error': '$error',
          },
        );
        await Future<void>.delayed(retryDelay);
      }
    }
  }

  Future<void> _upload({
    required Uri target,
    required String fsName,
    required Uri deviceUri,
    required Uint8List body,
  }) async {
    final HttpClientRequest request = await _httpClient.putUrl(target);

    // Accept-Encoding が付いていると VM 側が応答を圧縮し、
    // dart-lang/sdk#43525 の症状を踏みやすくなる。
    request.headers.removeAll(HttpHeaders.acceptEncodingHeader);
    buildHeaders(
      fsName: fsName,
      deviceUri: deviceUri,
    ).forEach(request.headers.add);

    request.add(body);

    try {
      final HttpClientResponse response = await request.close().timeout(
        uploadTimeout,
      );
      // 本文を読み切らないと接続が解放されない。
      await response.drain<void>();
      // 3xx を成功にすると、転送されないまま reloadSources に進む。
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw DevFSException(
          '$deviceUri の PUT が ${response.statusCode} を返しました',
        );
      }
    } on TimeoutException {
      request.abort();
      // abort 後の done は必ず例外で終わる。ここで拾わないと未処理になる。
      try {
        await request.done;
      } on Object {
        // "Request has been aborted" が来る。想定内なので握る。
      }
      rethrow;
    }
  }
}
