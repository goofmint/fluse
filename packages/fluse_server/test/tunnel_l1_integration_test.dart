@Timeout(Duration(minutes: 5))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:fluse_server/fluse_server.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'l1_tunnel_harness.dart';

/// L1統合テスト（Task 2.5 の完了条件）。
///
/// `TunnelEndpoint`(Dart) ⇄ `FluseTunnel`(JVM) を**実 WebSocket**で繋ぎ、
/// 10MB の双方向転送がバイト単位で一致すること、4本同時でも成立すること、
/// スループットが設計 §8.1 の目標（> 10MB/s）に届くことを見る。
///
/// 経路は次のとおり。
///
/// ```text
/// テストの Socket → TunnelEndpoint(TCP待受) → WebSocket
///   → FluseTunnel(JVM) → EchoServer(TCP) → 折り返して同じ経路を戻る
/// ```
///
/// スループットは記録するが、既定では失敗条件にしない（共有 CI ランナーで
/// 不安定になるため）。判定したいときは `FLUSE_L1_ASSERT_THROUGHPUT=1`。
///
/// JVM ハーネス（`installDist` の生成物）が無い環境ではスキップする。
/// 事前に次を実行しておくこと。
///
/// ```sh
/// cd packages/fluse_protocol_kt && ./gradlew installDist
/// ```
void main() {
  /// 転送量。設計 §8.1 の計測条件。
  const int payloadBytes = 10 * 1024 * 1024;

  /// 設計 §8.1 のスループット目標。
  const double targetBytesPerSecond = 10 * 1024 * 1024;

  /// 同時ストリーム数。
  ///
  /// DevFS の HTTP PUT が最大3並列、VM Service の WebSocket が1本で
  /// 計4本になる。これが実運用の同時接続数に相当する。
  const int concurrentStreams = 4;

  /// テストは `packages/fluse_server` を作業ディレクトリとして走る。
  final String harnessPath = p.normalize(
    p.join(
      Directory.current.path,
      '..',
      'fluse_protocol_kt',
      'build',
      'install',
      'fluse_protocol_kt',
      'bin',
      'fluse_protocol_kt',
    ),
  );

  /// 計測結果。まとめて最後に出す。
  final List<String> measurements = <String>[];

  /// スループットを失敗条件にするか。
  ///
  /// **既定では判定しない。** GitHub Actions の共有ランナーは CPU と I/O が
  /// 安定せず、JIT のウォームアップも 1 回の計測に乗る。閾値付近に来ると
  /// コードを変えていないのに赤くなり、テストが信用されなくなる。
  /// 完了条件は「計測結果を記録」なので、記録は常に行う。
  ///
  /// 手元で回帰を見たいときは `FLUSE_L1_ASSERT_THROUGHPUT=1` を付ける。
  final bool assertThroughput =
      Platform.environment['FLUSE_L1_ASSERT_THROUGHPUT'] == '1';

  /// 計測を記録し、必要なら目標との比較を失敗条件にする。
  void recordThroughput(String label, int bytes, Stopwatch stopwatch) {
    final double throughput = bytes / (stopwatch.elapsedMicroseconds / 1000000);
    final bool met = throughput > targetBytesPerSecond;
    measurements.add(
      '$label: ${_mib(throughput)} MiB/s '
      '(${stopwatch.elapsedMilliseconds}ms, 往復 ${_mib(bytes)} MiB) '
      '目標 ${_mib(targetBytesPerSecond)} MiB/s → ${met ? '達成' : '未達'}',
    );
    if (assertThroughput) {
      expect(
        throughput,
        greaterThan(targetBytesPerSecond),
        reason: '設計 §8.1 の目標 10MB/s に届いていません',
      );
    }
  }

  EchoServer? echo;
  HttpServer? wsServer;
  Process? harness;
  TunnelEndpoint? endpoint;
  Uri? localVmService;
  WebSocket? deviceSocket;
  StreamSubscription<String>? harnessStderr;

  /// 前提が揃わずスキップする理由。揃っていれば null。
  String? skipReason;

  /// ハーネスが `READY` を出すまで待つ。
  ///
  /// 出る前に流し始めると、まだ WebSocket が繋がっていない間の `open` が
  /// 落ちて、原因の分かりにくい失敗になる。
  Future<void> awaitReady(Stream<String> lines) async {
    await for (final String line in lines) {
      if (line.trim() == 'READY') {
        return;
      }
    }
    throw StateError('ハーネスが READY を出さずに終了しました');
  }

  setUpAll(() async {
    if (!File(harnessPath).existsSync()) {
      // setUpAll での markTestSkipped は後続のテストに効かない。
      // 理由を持ち回して各テストの入口で判断する。
      skipReason =
          'JVM ハーネスがありません: $harnessPath'
          '（packages/fluse_protocol_kt で ./gradlew installDist を実行してください）';
      return;
    }

    final EchoServer echoServer = await EchoServer.bind();
    echo = echoServer;

    // 端末側 WebSocket の接続先。本番では WsServer（Task 3.2）が担う。
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    wsServer = server;
    final Future<WebSocket> upgraded = server.first.then(
      WebSocketTransformer.upgrade,
    );

    final Process process = await const LocalProcessManager().start(<String>[
      harnessPath,
      'ws://${server.address.address}:${server.port}',
      '${echoServer.port}',
    ]);
    harness = process;

    // 失敗したときに原因が見えるよう、ハーネスの標準エラーは流しておく。
    harnessStderr = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((String line) => printOnFailure('[harness] $line'));

    await awaitReady(
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    ).timeout(const Duration(seconds: 60));

    final WebSocket socket = await upgraded.timeout(
      const Duration(seconds: 60),
    );
    deviceSocket = socket;

    final TunnelEndpoint tunnel = TunnelEndpoint(
      channel: WebSocketTunnelChannel(socket),
    );
    endpoint = tunnel;
    // done は監視しないと中継の停止に気づけない。失敗はテストへ伝える。
    unawaited(
      tunnel.done.catchError(
        (Object error) => printOnFailure('[endpoint] $error'),
      ),
    );

    // authCode はパスそのもの。エコーサーバ相手でも形は本物に揃える。
    localVmService = await tunnel.bind(
      'http://127.0.0.1:${echoServer.port}/l1testauthcode/',
    );
  });

  tearDownAll(() async {
    await endpoint?.close();
    await deviceSocket?.close();
    await harnessStderr?.cancel();

    final Process? process = harness;
    if (process != null) {
      // 標準入力を閉じると、ハーネスは自分から終了する。
      await process.stdin.close().catchError((Object _) {});
      final int code = await process.exitCode.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          process.kill();
          return -1;
        },
      );
      printOnFailure('[harness] exitCode=$code');
    }

    await wsServer?.close(force: true);
    await echo?.close();

    if (measurements.isNotEmpty) {
      // 完了条件の「計測結果を記録」。CI のログに残す。
      // ignore: avoid_print
      print('--- L1 スループット計測 ---\n${measurements.join('\n')}');
    }
  });

  /// 決まった種から作る検証用データ。
  ///
  /// 乱数にすると失敗が再現しない。種を固定して、落ちたら同じ列で追える。
  Uint8List makePayload(int seed) {
    final Random random = Random(seed);
    final Uint8List bytes = Uint8List(payloadBytes);
    for (int i = 0; i < bytes.length; i++) {
      bytes[i] = random.nextInt(256);
    }
    return bytes;
  }

  /// 前提が揃っていれば true。揃っていなければ理由を添えてスキップする。
  bool ensureReady() {
    final String? reason = skipReason;
    if (reason != null) {
      markTestSkipped(reason);
      return false;
    }
    return true;
  }

  /// トンネル越しに [payload] を送り、返ってきた同じ長さのバイト列を返す。
  Future<Uint8List> roundTrip(Uint8List payload) async {
    final Uri target = localVmService!;
    final Socket socket = await Socket.connect(target.host, target.port);
    // Nagle が効くと小さい書き込みが束ねられて計測がぶれる。
    socket.setOption(SocketOption.tcpNoDelay, true);

    final BytesBuilder received = BytesBuilder(copy: false);
    final Completer<void> complete = Completer<void>();
    final StreamSubscription<Uint8List> subscription = socket.listen(
      (Uint8List chunk) {
        received.add(chunk);
        if (received.length >= payload.length && !complete.isCompleted) {
          complete.complete();
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!complete.isCompleted) {
          complete.completeError(error, stackTrace);
        }
      },
      onDone: () {
        if (!complete.isCompleted) {
          complete.completeError(
            StateError('返送が ${received.length} バイトで打ち切られました'),
          );
        }
      },
    );

    socket.add(payload);
    await socket.flush();
    try {
      await complete.future;
    } finally {
      await subscription.cancel();
      socket.destroy();
    }
    return received.takeBytes();
  }

  test('10MB を双方向転送してバイト単位で一致する', () async {
    if (!ensureReady()) {
      return;
    }
    final Uint8List payload = makePayload(1);

    final Stopwatch stopwatch = Stopwatch()..start();
    final Uint8List echoed = await roundTrip(payload);
    stopwatch.stop();

    expect(echoed.length, payload.length);
    // equals() は 10M 要素だと失敗時の差分生成で現実的な時間に終わらない。
    expect(_firstMismatch(payload, echoed), -1, reason: '返送バイトが一致しません');

    // 往復なので実際には 2 倍のバイトが線を通っている。
    recordThroughput('単一ストリーム', payloadBytes * 2, stopwatch);
  });

  test('4ストリーム同時に転送してそれぞれ一致する', () async {
    if (!ensureReady()) {
      return;
    }
    final List<Uint8List> payloads = <Uint8List>[
      for (int i = 0; i < concurrentStreams; i++) makePayload(100 + i),
    ];

    final Stopwatch stopwatch = Stopwatch()..start();
    final List<Uint8List> results = await Future.wait(payloads.map(roundTrip));
    stopwatch.stop();

    for (int i = 0; i < concurrentStreams; i++) {
      expect(results[i].length, payloads[i].length, reason: 'stream $i');
      expect(
        _firstMismatch(payloads[i], results[i]),
        -1,
        reason: 'stream $i の返送バイトが一致しません',
      );
    }

    recordThroughput(
      '$concurrentStreams ストリーム同時',
      payloadBytes * concurrentStreams * 2,
      stopwatch,
    );
  });
}

/// 最初に食い違った位置。一致していれば -1。
///
/// `expect(a, equals(b))` は 10M 要素だと失敗時の差分生成が終わらない。
int _firstMismatch(Uint8List expected, Uint8List actual) {
  final int length = min(expected.length, actual.length);
  for (int i = 0; i < length; i++) {
    if (expected[i] != actual[i]) {
      return i;
    }
  }
  return expected.length == actual.length ? -1 : length;
}

String _mib(num bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);
