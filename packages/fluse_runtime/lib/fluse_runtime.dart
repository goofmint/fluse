/// Preview App に組み込まれる端末側ランタイム。
///
/// Dart 側は [flusePreviewMain] でユーザーの `main()` をラップし、
/// VM Service の URI を Kotlin 側へ通知する。Kotlin 側の常駐実装
/// （接続・トンネル・エラーオーバーレイ）は Task 4.2 以降で追加する。
library;

import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/widgets.dart';

import 'src/runtime_channel.dart';

export 'src/runtime_channel.dart' show RuntimeChannelContract;

/// VM Service の情報を取る。テストから差し替えるために切り出す。
typedef ServiceInfoReader = Future<Uri?> Function();

/// 実際の VM Service から `serverUri` を読む。
Future<Uri?> _readServerUri() async =>
    (await developer.Service.getInfo()).serverUri;

/// 生成された `.flutter_preview/fluse_main.dart` から呼ばれる入口
/// （設計 §2.2.3 / §10-5）。
///
/// **[appMain] を最初に呼ぶ。** ここで先に
/// `WidgetsFlutterBinding.ensureInitialized()` を呼んではいけない。
/// 独自の binding を使うアプリや、`runZonedGuarded` の中で
/// `runApp` するアプリの初期化順序を壊す。バインディングの生成は
/// アプリ自身の責務で、こちらは後追いするだけにする。
///
/// [appMain] は `Future<void> main() async` でありうるので、**完了を
/// 待ってから**通知する。待たずに進むと、アプリがまだ準備できていない
/// うちにサーバが差分を投げ始める。
///
/// アプリの失敗は呼び出し元へそのまま返す（設計 §2.2.3）。ただし
/// **失敗しても通知はする。** VM Service は立っているので、繋いでおけば
/// 起動時のエラーをプレビュー越しに直せる。
///
/// release ビルドなど VM Service が無効な環境では `serverUri` が null に
/// なる。**そのときは何もしない。** 例外にすると、プレビュー用の
/// エントリポイントを踏んだだけで本番相当のビルドが起動しなくなる。
Future<void> flusePreviewMain(
  FutureOr<void> Function() appMain, {
  RuntimeChannelContract channel = const MethodChannelRuntime(),
  ServiceInfoReader? serviceInfo,
  void Function(Object error, StackTrace stackTrace)? onError,
}) async {
  try {
    await appMain();
  } finally {
    // 通知は待たない。ここで待つと、アプリの起動完了が VM Service との
    // やり取りの分だけ遅れる。
    unawaited(
      _reportVmService(
        channel: channel,
        serviceInfo: serviceInfo ?? _readServerUri,
        onError: onError,
      ),
    );
  }
}

Future<void> _reportVmService({
  required RuntimeChannelContract channel,
  required ServiceInfoReader serviceInfo,
  void Function(Object error, StackTrace stackTrace)? onError,
}) async {
  try {
    // appMain() が binding を作っていない可能性は残る（runApp を
    // 呼ばないアプリなど）。MethodChannel には binding が要るので、
    // ここで確実にしておく。既に作られていれば何もしない。
    WidgetsFlutterBinding.ensureInitialized();

    final Uri? serverUri = await serviceInfo();
    if (serverUri == null) {
      // VM Service が無効。プレビューは成立しないが、アプリ自体は
      // そのまま動かす。
      return;
    }

    // **Hot Restart のたびにここを通る。** main() が作り直されるため、
    // 同じ URI が繰り返し届く。Native 側は冪等に受けること
    // （上書きで受ける。接続の張り直しは Task 4.3 の範囲）。
    await channel.vmServiceReady(serverUri.toString());
  } on Object catch (error, stackTrace) {
    // **通知の失敗でアプリを落とさない。** プレビューが繋がらないのは
    // 困るが、アプリが起動しない方がもっと困る。
    if (onError != null) {
      onError(error, stackTrace);
      return;
    }
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'fluse_runtime',
        context: ErrorDescription('VM Service の URI を通知できませんでした'),
      ),
    );
  }
}
