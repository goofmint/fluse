import 'dart:async';
import 'dart:io';

import 'package:fluse_protocol/fluse_protocol.dart';
import 'package:fluse_server/fluse_server.dart';
import 'package:fluse_server/testing.dart';
import 'package:test/test.dart';

/// テストから読み書きできる [TunnelChannel]。
///
/// `send` の完了を保留できるようにして、バックプレッシャを検証する。
final class _FakeChannel implements TunnelChannel {
  final StreamController<List<int>> _incoming =
      StreamController<List<int>>.broadcast();

  /// 送られたフレーム。
  final List<TunnelFrame> sent = <TunnelFrame>[];

  /// 保留中の送信。`releaseAll()` で完了させる。
  final List<Completer<void>> _pending = <Completer<void>>[];

  /// true の間、`send` の Future を完了させない。
  bool holdSends = false;

  @override
  Stream<List<int>> get incoming => _incoming.stream;

  @override
  Future<void> send(List<int> frame) {
    sent.add(TunnelFrame.decode(frame));
    if (!holdSends) {
      return Future<void>.value();
    }
    final Completer<void> completer = Completer<void>();
    _pending.add(completer);
    return completer.future;
  }

  /// 保留中の送信をすべて完了させる。
  void releaseAll() {
    for (final Completer<void> completer in _pending) {
      if (!completer.isCompleted) {
        completer.complete();
      }
    }
    _pending.clear();
  }

  /// 端末からフレームが届いたことにする。
  void receive(TunnelFrame frame) => _incoming.add(frame.encode());

  /// 生のバイト列をそのまま届ける。
  void receiveRaw(List<int> bytes) => _incoming.add(bytes);

  Future<void> dispose() => _incoming.close();

  /// 指定した opcode のフレームだけを取り出す。
  List<TunnelFrame> framesOf(TunnelOpcode opcode) =>
      sent.where((TunnelFrame f) => f.opcode == opcode).toList();

  /// data フレームの payload を連結する。分割されても元に戻るはず。
  List<int> get concatenatedData => <int>[
    for (final TunnelFrame frame in framesOf(TunnelOpcode.data))
      ...frame.payload,
  ];
}

void main() {
  late _FakeChannel channel;
  late TunnelEndpoint endpoint;
  late MemoryLogSink sink;

  const String remoteUri = 'http://127.0.0.1:43219/xY7Kq2Lm9Ab=/';

  /// 条件が満たされるまで少しだけ待つ。
  ///
  /// 実時間の sleep ではなくイベントループを回す。
  Future<void> waitFor(bool Function() condition, {String? reason}) async {
    for (int i = 0; i < 200; i++) {
      if (condition()) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail(reason ?? '条件が満たされませんでした');
  }

  setUp(() {
    channel = _FakeChannel();
    sink = MemoryLogSink();
    endpoint = TunnelEndpoint(
      channel: channel,
      logger: FluseLogger(
        sinks: <FluseLogSink>[sink],
        minimumLevel: FluseLogLevel.debug,
      ),
    );
  });

  tearDown(() async {
    await endpoint.close();
    await channel.dispose();
  });

  group('bind', () {
    test('authCode を保ったままローカルのポートを返す', () async {
      final Uri local = await endpoint.bind(remoteUri);

      expect(local.scheme, 'http');
      expect(local.host, '127.0.0.1');
      expect(local.port, isNot(43219));
      expect(local.port, greaterThan(0));
      // 認証コードは VM Service のパスそのもの。書き換えると通らない。
      expect(local.pathSegments.first, 'xY7Kq2Lm9Ab=');
      expect(local.path, endsWith('/'));
    });

    test('ネストしたパスも保つ', () async {
      final Uri local = await endpoint.bind('http://127.0.0.1:1/a/b/');

      expect(local.pathSegments.take(2), <String>['a', 'b']);
    });

    test('認証コードが無い URI は失敗する', () async {
      await expectLater(
        endpoint.bind('http://127.0.0.1:43219/'),
        throwsA(isA<TunnelException>()),
      );
    });

    test('二重の bind は拒否する', () async {
      await endpoint.bind(remoteUri);

      await expectLater(
        endpoint.bind(remoteUri),
        throwsA(isA<TunnelException>()),
      );
    });

    test('ログに認証コードが残らない', () async {
      await endpoint.bind(remoteUri);

      expect(sink.lines, isNotEmpty);
      expect(sink.lines.join('\n'), isNot(contains('xY7Kq2Lm9Ab')));
    });
  });

  group('TCP → トンネル', () {
    test('接続すると open フレームを送る', () async {
      final Uri local = await endpoint.bind(remoteUri);

      final Socket socket = await Socket.connect(local.host, local.port);
      await waitFor(() => channel.framesOf(TunnelOpcode.open).isNotEmpty);

      expect(channel.framesOf(TunnelOpcode.open).single.streamId, 1);
      expect(endpoint.activeStreams, 1);
      socket.destroy();
    });

    test('書き込んだバイト列が data フレームになる', () async {
      final Uri local = await endpoint.bind(remoteUri);
      final Socket socket = await Socket.connect(local.host, local.port);

      socket.add(<int>[1, 2, 3]);
      await socket.flush();
      await waitFor(() => channel.concatenatedData.length == 3);

      expect(channel.concatenatedData, <int>[1, 2, 3]);
      expect(channel.framesOf(TunnelOpcode.data).single.streamId, 1);
      socket.destroy();
    });

    test('上限を超えるデータを分割して送り、連結すると元に戻る', () async {
      // プロトコル層は自動で割らない。中継側が分割する責務を持つ。
      final Uri local = await endpoint.bind(remoteUri);
      final Socket socket = await Socket.connect(local.host, local.port);
      final List<int> payload = List<int>.generate(
        TunnelFrame.maxPayloadLength * 2 + 1234,
        (int i) => i % 256,
      );

      socket.add(payload);
      await socket.flush();
      await waitFor(
        () => channel.concatenatedData.length == payload.length,
        reason: '全バイトが届きませんでした',
      );

      expect(channel.framesOf(TunnelOpcode.data).length, greaterThan(1));
      expect(
        channel
            .framesOf(TunnelOpcode.data)
            .every(
              (TunnelFrame f) =>
                  f.payload.length <= TunnelFrame.maxPayloadLength,
            ),
        isTrue,
      );
      expect(channel.concatenatedData, payload);
      socket.destroy();
    });

    test('TCP が切れたら close フレームを送る', () async {
      final Uri local = await endpoint.bind(remoteUri);
      final Socket socket = await Socket.connect(local.host, local.port);
      await waitFor(() => endpoint.activeStreams == 1);

      await socket.close();
      socket.destroy();
      await waitFor(() => channel.framesOf(TunnelOpcode.close).isNotEmpty);

      expect(channel.framesOf(TunnelOpcode.close).single.streamId, 1);
      expect(endpoint.activeStreams, 0);
    });

    test('接続ごとに streamId を採番する', () async {
      final Uri local = await endpoint.bind(remoteUri);

      final Socket a = await Socket.connect(local.host, local.port);
      final Socket b = await Socket.connect(local.host, local.port);
      await waitFor(() => channel.framesOf(TunnelOpcode.open).length == 2);

      expect(
        channel.framesOf(TunnelOpcode.open).map((TunnelFrame f) => f.streamId),
        <int>[1, 2],
      );
      expect(endpoint.activeStreams, 2);
      a.destroy();
      b.destroy();
    });
  });

  group('トンネル → TCP', () {
    test('data フレームが TCP に書き出される', () async {
      final Uri local = await endpoint.bind(remoteUri);
      final Socket socket = await Socket.connect(local.host, local.port);
      final Future<List<int>> received = socket.fold<List<int>>(
        <int>[],
        (List<int> acc, List<int> d) => acc..addAll(d),
      );
      await waitFor(() => endpoint.activeStreams == 1);

      channel.receive(TunnelFrame.data(1, <int>[9, 8, 7]));
      await waitFor(() => channel.sent.isNotEmpty);
      await endpoint.close();

      expect(await received, <int>[9, 8, 7]);
    });

    test('close フレームで TCP が閉じる', () async {
      final Uri local = await endpoint.bind(remoteUri);
      final Socket socket = await Socket.connect(local.host, local.port);
      final Future<void> done = socket.drain<void>();
      await waitFor(() => endpoint.activeStreams == 1);

      channel.receive(TunnelFrame.close(1));
      await waitFor(() => endpoint.activeStreams == 0);

      await done;
      // 端末発の close にはこちらから close を返さない（往復しない）。
      expect(channel.framesOf(TunnelOpcode.close), isEmpty);
    });

    test('知らない streamId への data には close を返す', () async {
      await endpoint.bind(remoteUri);

      channel.receive(TunnelFrame.data(999, <int>[1]));
      await waitFor(() => channel.framesOf(TunnelOpcode.close).isNotEmpty);

      expect(channel.framesOf(TunnelOpcode.close).single.streamId, 999);
    });

    test('対向からの open は受け付けず close を返す', () async {
      // サーバ側の待ち受けはローカル TCP 起点なので、繋ぐ先が無い。
      await endpoint.bind(remoteUri);

      channel.receive(TunnelFrame.open(500));
      await waitFor(() => channel.framesOf(TunnelOpcode.close).isNotEmpty);

      expect(channel.framesOf(TunnelOpcode.close).single.streamId, 500);
    });

    test('壊れたフレームは記録するが落ちない', () async {
      await endpoint.bind(remoteUri);

      channel.receiveRaw(<int>[0x09, 0, 0, 0, 1]);
      await waitFor(() => sink.lines.any((String l) => l.contains('解釈できません')));

      expect(endpoint.activeStreams, 0);
    });
  });

  group('バックプレッシャ', () {
    test('高水位を超えると読み取りを止め、下がると再開する', () async {
      // 送信の完了を保留して、キューが溜まった状態を作る。
      final TunnelEndpoint small = TunnelEndpoint(
        channel: channel,
        highWaterMark: 4096,
        lowWaterMark: 1024,
      );
      final Uri local = await small.bind(remoteUri);
      final Socket socket = await Socket.connect(local.host, local.port);
      channel.holdSends = true;

      socket.add(List<int>.filled(8192, 0x41));
      await socket.flush();
      await waitFor(() => small.pendingBytes > 4096);

      expect(small.isPaused, isTrue);

      channel.releaseAll();
      await waitFor(() => small.pendingBytes == 0);

      expect(small.isPaused, isFalse);
      socket.destroy();
      await small.close();
    });

    test('低水位は高水位より小さくなければならない', () {
      expect(
        () => TunnelEndpoint(
          channel: channel,
          highWaterMark: 100,
          lowWaterMark: 100,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('既定値は設計の閾値に合わせる', () {
      // 設計 §8.2-5 の 4MB。
      expect(TunnelEndpoint.defaultHighWaterMark, 4 * 1024 * 1024);
      expect(
        TunnelEndpoint.defaultLowWaterMark,
        lessThan(TunnelEndpoint.defaultHighWaterMark),
      );
    });
  });

  group('close', () {
    test('全ストリームを閉じる', () async {
      final Uri local = await endpoint.bind(remoteUri);
      final Socket a = await Socket.connect(local.host, local.port);
      final Socket b = await Socket.connect(local.host, local.port);
      await waitFor(() => endpoint.activeStreams == 2);

      await endpoint.close();

      expect(endpoint.activeStreams, 0);
      a.destroy();
      b.destroy();
    });

    test('二重に呼んでも安全', () async {
      await endpoint.bind(remoteUri);

      await endpoint.close();
      await endpoint.close();

      expect(endpoint.activeStreams, 0);
    });

    test('閉じた後は新しい接続を受け付けない', () async {
      final Uri local = await endpoint.bind(remoteUri);
      await endpoint.close();

      await expectLater(
        Socket.connect(
          local.host,
          local.port,
          timeout: const Duration(seconds: 2),
        ),
        throwsA(isA<SocketException>()),
      );
    });
  });
}
