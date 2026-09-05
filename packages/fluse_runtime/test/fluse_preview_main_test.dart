import 'dart:async';

import 'package:fluse_runtime/fluse_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

/// 呼ばれた順と引数を記録するだけの [RuntimeChannelContract]。
final class FakeRuntimeChannel implements RuntimeChannelContract {
  final List<String> notified = <String>[];

  /// vmServiceReady が投げる例外。通知の失敗を作る。
  Object? failure;

  @override
  Future<void> vmServiceReady(String uri) async {
    notified.add(uri);
    final Object? error = failure;
    if (error != null) {
      throw error;
    }
  }
}

void main() {
  // MethodChannel を使わない経路でも、binding の初期化は通る。
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeRuntimeChannel channel;
  late List<String> order;

  setUp(() {
    channel = FakeRuntimeChannel();
    order = <String>[];
  });

  /// マイクロタスクが片付くまで進める。
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('appMain を通知より先に呼ぶ', () async {
    // 先に ensureInitialized を呼ぶと、独自 binding や runZonedGuarded を
    // 使うアプリの初期化順序を壊す（設計 §10-5）。
    final Future<void> done = flusePreviewMain(
      () => order.add('appMain'),
      channel: channel,
      serviceInfo: () async {
        order.add('serviceInfo');
        return Uri.parse('http://127.0.0.1:1/abcdefghij/');
      },
    );

    // appMain は同期で走り終えている。通知はまだ。
    expect(order, <String>['appMain']);

    await done;
    await settle();
    expect(order, <String>['appMain', 'serviceInfo']);
  });

  test('非同期の appMain は完了を待ってから通知する', () async {
    // 待たずに進むと、アプリがまだ準備できていないうちにサーバが
    // 差分を投げ始める（設計 §2.2.3）。
    final Completer<void> appReady = Completer<void>();

    final Future<void> done = flusePreviewMain(
      () async {
        order.add('appMain:start');
        await appReady.future;
        order.add('appMain:done');
      },
      channel: channel,
      serviceInfo: () async {
        order.add('serviceInfo');
        return Uri.parse('http://127.0.0.1:1/abcdefghij/');
      },
    );
    await settle();

    expect(order, <String>['appMain:start'], reason: 'まだ通知しない');

    appReady.complete();
    await done;
    await settle();

    expect(order, <String>['appMain:start', 'appMain:done', 'serviceInfo']);
  });

  test('appMain の失敗は呼び出し元へ返す', () async {
    // 設計 §2.2.3。生成される main() が Future<void> を返すのは、
    // アプリ側の完了とエラーを伝えるため。
    await expectLater(
      flusePreviewMain(
        () async => throw StateError('起動に失敗'),
        channel: channel,
        serviceInfo: () async => Uri.parse('http://127.0.0.1:1/abcdefghij/'),
      ),
      throwsStateError,
    );
    await settle();

    // 失敗しても通知はする。繋いでおけば起動時のエラーを直せる。
    expect(channel.notified, hasLength(1));
  });

  test('serverUri を Native へ渡す', () async {
    await flusePreviewMain(
      () {},
      channel: channel,
      serviceInfo: () async => Uri.parse('http://127.0.0.1:45123/abcdefghij/'),
    );
    await settle();

    expect(channel.notified, <String>['http://127.0.0.1:45123/abcdefghij/']);
  });

  test('serverUri が null なら何もしない', () async {
    // release ビルドなど VM Service が無効な環境。例外にすると、
    // プレビュー用の入口を踏んだだけでアプリが起動しなくなる。
    bool started = false;
    await flusePreviewMain(
      () => started = true,
      channel: channel,
      serviceInfo: () async => null,
    );
    await settle();

    expect(started, isTrue);
    expect(channel.notified, isEmpty);
  });

  test('通知に失敗してもアプリは動き続ける', () async {
    // プレビューが繋がらないのは困るが、アプリが起動しない方が困る。
    final List<Object> errors = <Object>[];
    channel.failure = StateError('チャネルがありません');

    await flusePreviewMain(
      () => order.add('appMain'),
      channel: channel,
      serviceInfo: () async => Uri.parse('http://127.0.0.1:1/abcdefghij/'),
      onError: (Object error, StackTrace _) => errors.add(error),
    );
    await settle();

    expect(order, <String>['appMain']);
    expect(errors, hasLength(1));
  });

  test('VM Service の取得に失敗してもアプリは動き続ける', () async {
    final List<Object> errors = <Object>[];

    await flusePreviewMain(
      () => order.add('appMain'),
      channel: channel,
      serviceInfo: () async => throw StateError('取れません'),
      onError: (Object error, StackTrace _) => errors.add(error),
    );
    await settle();

    expect(order, <String>['appMain']);
    expect(channel.notified, isEmpty);
    expect(errors, hasLength(1));
  });

  test('Hot Restart で再度通知しても受け付ける', () async {
    // main() が作り直されるため、同じ URI が繰り返し届く。
    // 冪等に受けるのは Native 側の責務。
    const String uri = 'http://127.0.0.1:1/abcdefghij/';
    for (int i = 0; i < 2; i++) {
      await flusePreviewMain(
        () {},
        channel: channel,
        serviceInfo: () async => Uri.parse(uri),
      );
      await settle();
    }

    expect(channel.notified, <String>[uri, uri]);
  });
}
