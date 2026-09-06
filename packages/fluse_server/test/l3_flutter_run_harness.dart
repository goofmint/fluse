/// L3統合テスト（Task 6.2）の補助。**テスト専用**で、本番コードからは使わない。
///
/// `flutter run --machine` を実プロセスとして起動し、VM Service の URI を
/// 取り出して、終わったら確実に落とす。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:process/process.dart';

/// 起動中の `flutter run`。
///
/// **必ず [stop] する。** 落とし損ねると CI のランナーに Flutter の
/// プロセスが残り、次のジョブがポートやビルドディレクトリを掴めなくなる。
final class FlutterRunHarness {
  FlutterRunHarness._(this._process, this._appId, this.vmServiceUri);

  /// 起動を待つ上限。
  ///
  /// **短くしない。** 初回はネイティブ側（CMake / clang）のビルドから
  /// 始まるため、CI では分単位で掛かる。
  static const Duration defaultStartTimeout = Duration(minutes: 15);

  /// `app.stop` を待つ上限。過ぎたら kill する。
  static const Duration defaultStopTimeout = Duration(seconds: 30);

  final Process _process;

  /// daemon が振ったアプリの ID。`app.stop` に要る。
  final String _appId;

  /// `VmServiceClient.connect` へ渡せる HTTP ルート。
  final Uri vmServiceUri;

  /// 標準エラーの控え。失敗した時に出す。
  static final List<String> _stderrLines = <String>[];

  /// 出したまま拾われなかった行。失敗の診断に使う。
  static List<String> get stderrLines =>
      List<String>.unmodifiable(_stderrLines);

  /// [workingDirectory] のアプリを [device] で起動する。
  ///
  /// [flutterExecutable] は `FlutterSdk.flutterExecutable`。**PATH の
  /// `flutter` を当てにしない。** テストの他の部分が使う SDK と別物を
  /// 起動すると、リビジョン違いの分かりにくい失敗になる。
  static Future<FlutterRunHarness> start({
    required String flutterExecutable,
    required String workingDirectory,
    required String device,
    ProcessManager processManager = const LocalProcessManager(),
    Duration timeout = defaultStartTimeout,
  }) async {
    _stderrLines.clear();
    final Process process = await processManager.start(<String>[
      flutterExecutable,
      'run',
      '--machine',
      // ホットリロードの検証なので debug。**release にしない。**
      // VM Service が立たず、接続する相手が居なくなる。
      '--debug',
      '-d',
      device,
    ], workingDirectory: workingDirectory);

    // **購読は起動直後に始める。** 後から繋ぐと、その間に流れた
    // `app.debugPort` を取り逃す。
    final Completer<String> appId = Completer<String>();
    final Completer<Uri> wsUri = Completer<Uri>();
    final Completer<void> started = Completer<void>();
    final List<String> events = <String>[];

    final StreamSubscription<String> stdoutSubscription = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((String line) {
          for (final Map<String, Object?> message in parseDaemonLine(line)) {
            final Object? event = message['event'];
            if (event is! String) {
              continue;
            }
            events.add(event);
            final Object? params = message['params'];
            final Map<String, Object?> fields = params is Map<String, Object?>
                ? params
                : const <String, Object?>{};
            switch (event) {
              case 'app.start':
                final Object? id = fields['appId'];
                if (id is String && !appId.isCompleted) {
                  appId.complete(id);
                }
              case 'app.debugPort':
                final Object? uri = fields['wsUri'];
                if (uri is String && !wsUri.isCompleted) {
                  wsUri.complete(Uri.parse(uri));
                }
              case 'app.started':
                if (!started.isCompleted) {
                  started.complete();
                }
            }
          }
        });

    final StreamSubscription<String> stderrSubscription = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(_stderrLines.add);

    // プロセスが先に落ちたら待ち続けない。**待ち続けると
    // タイムアウトまで何も分からないまま止まる。**
    unawaited(
      process.exitCode.then((int code) {
        final StateError error = StateError(
          'flutter run が終了しました（exitCode=$code）\n'
          '  受け取ったイベント: ${events.join(', ')}\n'
          '  stderr: ${_stderrLines.join('\n  ')}',
        );
        for (final Completer<Object?> completer in <Completer<Object?>>[
          appId,
          wsUri,
        ]) {
          if (!completer.isCompleted) {
            completer.completeError(error);
          }
        }
        if (!started.isCompleted) {
          started.completeError(error);
        }
      }),
    );

    try {
      final Uri ws = await wsUri.future.timeout(timeout);
      final String id = await appId.future.timeout(timeout);
      await started.future.timeout(timeout);
      return FlutterRunHarness._(process, id, httpUriOf(ws));
    } on Object {
      // **待つのをやめた Future の失敗を明示的に捨てる。** 捨てないと、
      // この後の kill で exitCode 側が completeError した分が
      // 未処理のエラーとしてテスト全体を落とす。
      appId.future.ignore();
      wsUri.future.ignore();
      started.future.ignore();
      await stdoutSubscription.cancel();
      await stderrSubscription.cancel();
      process.kill();
      rethrow;
    }
  }

  /// daemon の1行を解釈する。
  ///
  /// **`[` で始まる行だけが daemon のメッセージ。** `flutter run` は
  /// 進捗やツールの警告も同じ標準出力へ書くため、素直に `jsonDecode`
  /// すると落ちる。
  static List<Map<String, Object?>> parseDaemonLine(String line) {
    final String trimmed = line.trim();
    if (!trimmed.startsWith('[')) {
      return const <Map<String, Object?>>[];
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } on FormatException {
      // JSON でない `[` 始まりの行（ログの装飾など）。読み飛ばす。
      return const <Map<String, Object?>>[];
    }
    if (decoded is! List) {
      return const <Map<String, Object?>>[];
    }
    return <Map<String, Object?>>[
      for (final Object? element in decoded)
        if (element is Map<String, Object?>) element,
    ];
  }

  /// `ws://127.0.0.1:1234/abc=/ws` を `http://127.0.0.1:1234/abc=/` にする。
  ///
  /// 認証コードはパスに入っている。**落とさない。** 落とすと接続が
  /// 拒否され、原因が分かりにくい。
  static Uri httpUriOf(Uri wsUri) {
    final List<String> segments = wsUri.pathSegments
        .where((String segment) => segment.isNotEmpty)
        .toList();
    if (segments.isNotEmpty && segments.last == 'ws') {
      segments.removeLast();
    }
    return wsUri.replace(
      scheme: 'http',
      // 末尾の空文字で `/` 終わりにする。VM Service はルートを
      // ディレクトリとして扱う。
      pathSegments: <String>[...segments, ''],
    );
  }

  /// `path:` の相対指定を [from] を基準にした絶対パスへ直す。
  ///
  /// 写した先のプロジェクトから `flutter run` するには、これが要る。
  /// `../../packages/...` のままだと写した先から辿れず、pub の解決で落ちる。
  ///
  /// **YAML として組み直さない。** コメントも並びも残したいのと、この
  /// ためだけに `yaml_edit` を依存へ足したくないため、`path:` の行だけを
  /// 見る。値は引用符で囲む。空白を含むパスでも壊れないようにするため。
  static String absolutePathDependencies(String pubspec, String from) {
    // 行末のコメントも拾う。**捨ててはいけない。** 一致しないまま
    // 相対のまま残ると、写した先で pub の解決が落ちる。
    final RegExp line = RegExp(
      r"""^(\s*path:\s*)(['"]?)([^'"#\n]+)\2(\s*(?:#.*)?)$""",
    );
    return pubspec
        .split('\n')
        .map((String text) {
          final RegExpMatch? match = line.firstMatch(text);
          if (match == null) {
            return text;
          }
          final String? captured = match.group(3);
          if (captured == null) {
            // 正規表現の形からは起きない。起きたら黙って通さない。
            throw StateError('path の値を取り出せません: $text');
          }
          final String value = captured.trim();
          if (p.isAbsolute(value)) {
            return text;
          }
          final String absolute = p.normalize(p.join(from, value));
          // **コメントの前に空白を1つ置く。** YAML は `"値"# コメント`
          // を読めない。値の側で空白を食っているので、ここで戻す。
          final String comment = (match.group(4) ?? '').trimLeft();
          final String suffix = comment.isEmpty ? '' : ' $comment';
          return '${match.group(1)}"$absolute"$suffix';
        })
        .join('\n');
  }

  /// 落とす。何度呼んでも安全。
  Future<void> stop({Duration timeout = defaultStopTimeout}) async {
    try {
      _process.stdin.writeln(
        jsonEncode(<Object>[
          <String, Object?>{
            'method': 'app.stop',
            'params': <String, Object?>{'appId': _appId},
            'id': 1,
          },
        ]),
      );
      await _process.stdin.flush();
    } on Object {
      // すでに落ちていれば書けない。kill へ進む。
    }

    await _process.exitCode.timeout(
      timeout,
      onTimeout: () {
        // **待ち続けない。** 行儀よく終われないプロセスを残すより、
        // 確実に落とす方がテストの後始末として正しい。
        _process.kill(ProcessSignal.sigkill);
        return _process.exitCode;
      },
    );
  }
}
