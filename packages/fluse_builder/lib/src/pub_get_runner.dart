import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:process/process.dart';

import 'flutter_sdk.dart';

/// `flutter pub get` に失敗したときに投げる例外。
final class PubGetException implements Exception {
  /// `flutter` を起動できなかった場合。
  const PubGetException.notLaunched({required String this.detail})
    : reason = 'flutter を起動できません',
      exitCode = null;

  /// 失敗して終わった場合。
  const PubGetException.failed({
    required int this.exitCode,
    required this.detail,
  }) : reason = 'flutter pub get が失敗しました';

  /// 待っても終わらなかった場合。
  const PubGetException.timedOut()
    : reason = 'flutter pub get が終わりません',
      detail = 'ネットワークに繋がっているか確認してください',
      exitCode = null;

  /// 失敗の要約。
  final String reason;

  /// 分かっている手がかり。
  final String? detail;

  final int? exitCode;

  @override
  String toString() {
    final StringBuffer buffer = StringBuffer('依存を解決できません: $reason');
    if (exitCode != null) {
      buffer.write('（終了コード $exitCode）');
    }
    if (detail != null && detail!.isNotEmpty) {
      buffer.write('\n  詳細: $detail');
    }
    buffer.write(
      '\n\n  `flutter pub get` が単体で通るか確かめてください。'
      '\n  `fluse doctor` で環境を確認できます。',
    );
    return buffer.toString();
  }
}

/// `flutter pub get` を回す。
///
/// **`fluse init` は pubspec に1行足す。** 足した後に解決し直さないと、
/// `fluse_runtime` が `.flutter-plugins-dependencies` に載らず、
/// Preview App にランタイムが入らない。
final class PubGetRunner {
  const PubGetRunner({
    required this.sdk,
    this.processManager = const LocalProcessManager(),
    this.timeout = defaultTimeout,
    this.onProgress,
  });

  /// 解決済みの Flutter SDK。
  final FlutterSdk sdk;

  final ProcessManager processManager;

  /// 待つ上限。**無制限にしない。** 取りに行く先が黙ると気づけない。
  final Duration timeout;

  /// 1行ずつ進み具合を伝える。
  final void Function(String line)? onProgress;

  static const Duration defaultTimeout = Duration(minutes: 10);

  /// [projectRoot] で `flutter pub get` を回す。
  Future<void> run(Directory projectRoot) async {
    final Process process;
    try {
      process = await processManager.start(<String>[
        sdk.flutterExecutable,
        'pub',
        'get',
      ], workingDirectory: projectRoot.path);
    } on ProcessException catch (error) {
      throw PubGetException.notLaunched(detail: error.message);
    }

    final List<String> tail = <String>[];
    void take(String line) {
      tail.add(line);
      if (tail.length > tailLines) {
        tail.removeAt(0);
      }
      onProgress?.call(line);
    }

    final Future<void> out = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .forEach(take);
    final Future<void> err = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .forEach(take);

    final int exitCode;
    try {
      exitCode = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      // **掴んだままにしない。** pub のロックが残ると次も失敗する。
      process.kill(ProcessSignal.sigkill);
      unawaited(out.catchError((Object _) {}));
      unawaited(err.catchError((Object _) {}));
      throw const PubGetException.timedOut();
    }

    await Future.wait<void>(<Future<void>>[out, err]);

    if (exitCode != 0) {
      throw PubGetException.failed(exitCode: exitCode, detail: tail.join('\n'));
    }
  }

  /// 失敗時に見せる末尾の行数。
  static const int tailLines = 30;
}
