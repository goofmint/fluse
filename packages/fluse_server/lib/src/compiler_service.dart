import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:process/process.dart';

import 'build_meta.dart';
import 'compile_output.dart';
import 'fluse_logger.dart';
import 'frontend_server_protocol.dart';
import 'reload_contracts.dart';

/// `frontend_server` の起動・駆動に失敗したときに投げる。
final class CompilerException implements Exception {
  const CompilerException(this.message);

  final String message;

  @override
  String toString() => 'frontend_server: $message';
}

/// `frontend_server` を子プロセスとして起動し、stdin プロトコルを駆動する
/// （設計 §2.2.3(a)）。
///
/// flutter_tools には依存せず、同じプロトコルを自前で話す。
///
/// **`accept` と `reject` を絶対に取り違えないこと**（設計 §10-2）。
/// reload 失敗時に `accept` を送ると `frontend_server` が「送信済み」と
/// 誤認し、以降そのファイルの差分が二度と送られなくなる。
final class CompilerService implements CompilerContract {
  CompilerService({
    required this.dartAotRuntime,
    required this.frontendServerSnapshot,
    required this.patchedSdkRoot,
    required this.projectRoot,
    required this.outputDill,
    required this.packagesPath,
    this.trackWidgetCreation = true,
    this.enableAsserts = true,
    this.dartDefines = const <String>[],
    this.fileSystemScheme = defaultFileSystemScheme,
    this.verbosity = 'error',
    this.buildMetaPath,
    ProcessManager processManager = const LocalProcessManager(),
    FluseLogger? logger,
    Random? random,
  }) : _processManager = processManager,
       _logger = logger,
       _random = random ?? Random.secure();

  /// `--filesystem-scheme` の既定値。
  ///
  /// flutter_tools と同じ値にしておく。端末側の kernel が持つ URI と
  /// 一致していないと `reloadSources` が差分を当てられない。
  static const String defaultFileSystemScheme = 'org-dartlang-root';

  /// `frontend_server` の応答を待つ既定の上限。
  ///
  /// 初回コンパイルはプロジェクト全体を読むため長い。無期限に待つと
  /// CLI が固まったまま操作できなくなる。
  static const Duration defaultCompileTimeout = Duration(minutes: 5);

  final String dartAotRuntime;
  final String frontendServerSnapshot;

  /// `flutter_patched_sdk` のディレクトリ。
  final String patchedSdkRoot;

  /// ユーザープロジェクトのルート。`--filesystem-root` に渡す。
  final String projectRoot;

  /// `--output-dill`。差分 dill の出力先。
  final String outputDill;

  /// `--packages`。通常は `<projectRoot>/.dart_tool/package_config.json`。
  final String packagesPath;

  /// `--track-widget-creation` を渡すか。
  ///
  /// **APK ビルド時と完全に一致していなければ `reloadSources` が静かに
  /// 失敗する**（設計 §10-1）。Task 1.5 の `build_meta` で突合する。
  final bool trackWidgetCreation;

  /// `--enable-asserts` を渡すか。同じく APK ビルドと一致させる。
  final bool enableAsserts;

  /// `-D<key>=<value>` の並び。`key=value` の形で渡す。
  final List<String> dartDefines;

  final String fileSystemScheme;

  /// `--verbosity`。
  final String verbosity;

  /// `.flutter_preview/cache/build_meta.json` の場所。
  ///
  /// 指定すると [start] が**フラグの突合**を行う。`fluse init` の APK
  /// ビルドと増分コンパイルでフラグが1つでも違うと `reloadSources` が
  /// 静かに失敗する（設計 §10-1）ため、起動時に検出して止める。
  ///
  /// null の場合は突合しない。単体テストなど、APK ビルドを伴わない
  /// 用途のため。
  final String? buildMetaPath;

  /// 現在の設定を [BuildMeta] として表したもの。
  BuildMeta get buildMeta => BuildMeta(
    trackWidgetCreation: trackWidgetCreation,
    enableAsserts: enableAsserts,
    dartDefines: dartDefines,
  );

  final ProcessManager _processManager;
  final FluseLogger? _logger;
  final Random _random;

  Process? _process;
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;

  /// 進行中のリクエスト。stdin は1本しかないので直列化する。
  Future<void> _queue = Future<void>.value();

  /// 現在の応答を組み立てているパーサ。
  FrontendServerOutputParser? _parser;
  Completer<FrontendServerResult>? _pending;

  /// 直前の `compile` / `recompile` に対して `accept` / `reject` の
  /// どちらも送っていないか。
  bool _needsConfirmation = false;

  /// プロセスが終了した理由。異常終了の検出に使う。
  int? _exitCode;

  bool get isRunning => _process != null && _exitCode == null;

  /// `accept` / `reject` の応答待ちかどうか。
  @override
  bool get needsConfirmation => _needsConfirmation;

  /// 起動コマンド。
  ///
  /// Task 1.5 の `build_meta` はこの並びを記録して、APK ビルド時の
  /// フラグと突合する。
  List<String> get commandLine => <String>[
    dartAotRuntime,
    frontendServerSnapshot,
    // 末尾のスラッシュは frontend_server の期待に合わせる。
    '--sdk-root',
    '${p.normalize(patchedSdkRoot)}${p.separator}',
    '--incremental',
    '--target=flutter',
    '--experimental-emit-debug-metadata',
    '--output-dill',
    outputDill,
    '--packages',
    packagesPath,
    if (trackWidgetCreation) '--track-widget-creation',
    // スキームが空なら multi-root を使わない。`flutter build apk` が
    // 生成する kernel は package: URI なので、そちらに合わせる場合は
    // 両方とも渡してはいけない。
    if (fileSystemScheme.isNotEmpty) ...<String>[
      '--filesystem-root',
      projectRoot,
      '--filesystem-scheme',
      fileSystemScheme,
    ],
    '--initialize-from-dill',
    outputDill,
    if (enableAsserts) '--enable-asserts',
    '--verbosity=$verbosity',
    for (final String define in dartDefines) '-D$define',
  ];

  /// ログに出してよい形の起動コマンド。
  ///
  /// `-D<key>=<value>` の値は API キーやトークンでありうる。
  /// [FluseLogger] のマスクはコマンド列の中身までは見ないので、ここで潰す。
  List<String> get _loggableCommandLine => <String>[
    for (final String argument in commandLine)
      if (argument.startsWith('-D') && argument.contains('='))
        '${argument.substring(0, argument.indexOf('=') + 1)}***'
      else
        argument,
  ];

  /// プロセスを起動する。
  ///
  /// [buildMetaPath] を指定している場合は、起動前にビルドフラグを突き合わせ、
  /// 不一致なら [CompilerException] を投げる。読み込みの失敗も同じ型に
  /// 揃えてある。
  Future<void> start() async {
    if (_process != null) {
      throw const CompilerException('すでに起動しています');
    }

    _verifyBuildMeta();
    File(outputDill).parent.createSync(recursive: true);

    final Process process;
    try {
      process = await _processManager.start(commandLine);
    } on Object catch (error) {
      throw CompilerException('起動できません: $error');
    }
    _process = process;
    _exitCode = null;

    // utf8.decoder は不正バイト列で FormatException を投げる。onError が
    // 無いと未捕捉例外になり、応答待ちがタイムアウトまで解放されない。
    _stdoutSubscription = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          _handleStdoutLine,
          onError: (Object error) =>
              _failPending('stdout の読み取りに失敗しました: $error'),
        );

    _stderrSubscription = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          _handleStderrLine,
          onError: (Object error) =>
              _logger?.warn('frontend_server(stderr) の読み取りに失敗: $error'),
        );

    // プロセスの終了はリクエストとは独立に起きる。ここで待つと start() が
    // 返らなくなるため、意図的に await しない。
    unawaited(process.exitCode.then(_handleExit));

    _logger?.debug(
      'frontend_server を起動しました',
      fields: <String, Object?>{'command': _loggableCommandLine},
    );
  }

  /// 初回コンパイル。
  Future<CompileOutput> compile(
    Uri mainUri, {
    Duration timeout = defaultCompileTimeout,
  }) {
    return _enqueue(() async {
      final String target = _toCompilerUri(mainUri);
      final FrontendServerResult result = await _request(
        send: (IOSink stdin) => stdin.writeln('compile $target'),
        timeout: timeout,
      );
      _needsConfirmation = true;
      return _toOutput(result);
    });
  }

  /// 差分コンパイル。
  ///
  /// [invalidated] には前回から変更されたファイルを渡す。空でもよい
  /// （その場合 `frontend_server` は差分なしの dill を返す）。
  @override
  Future<CompileOutput> recompile(
    Uri mainUri,
    List<Uri> invalidated, {
    Duration timeout = defaultCompileTimeout,
  }) {
    return _enqueue(() async {
      final String target = _toCompilerUri(mainUri);
      final String boundaryKey = _generateBoundaryKey();

      final FrontendServerResult result = await _request(
        send: (IOSink stdin) {
          stdin.writeln('recompile $target $boundaryKey');
          for (final Uri uri in invalidated) {
            stdin.writeln(_toCompilerUri(uri));
          }
          stdin.writeln(boundaryKey);
        },
        timeout: timeout,
      );
      _needsConfirmation = true;
      return _toOutput(result);
    });
  }

  /// reload が成功したことを伝える。応答は返らない。
  ///
  /// **失敗時にこれを呼んではいけない**（設計 §10-2）。
  @override
  void accept() {
    if (!_needsConfirmation) {
      return;
    }
    _requireStdin().writeln('accept');
    _needsConfirmation = false;
    _logger?.debug('frontend_server に accept を送りました');
  }

  /// reload が失敗したことを伝える。
  ///
  /// `frontend_server` は差分を「未送信」に戻すので、次回の
  /// [recompile] が同じ差分を再送する。応答が1つ返る。
  @override
  Future<CompileOutput?> reject({Duration timeout = defaultCompileTimeout}) {
    return _enqueue(() async {
      if (!_needsConfirmation) {
        return null;
      }
      final FrontendServerResult result = await _request(
        send: (IOSink stdin) => stdin.writeln('reject'),
        timeout: timeout,
        expectSources: false,
      );
      _needsConfirmation = false;
      _logger?.debug('frontend_server に reject を送りました');
      return _toOutput(result);
    });
  }

  /// プロセスを終了させる。二重に呼んでも安全。
  Future<void> shutdown() async {
    final Process? process = _process;
    if (process == null) {
      return;
    }
    // 先に手放す。並行する shutdown が同じプロセスを二重に kill しないため。
    _process = null;

    try {
      try {
        process.stdin.writeln('quit');
        await process.stdin.flush();
      } on Object catch (error) {
        // すでに落ちていれば quit は届かない。継続してよいが原因は残す。
        _logger?.debug('quit を送れませんでした: $error');
      }

      process.kill();
      await process.exitCode;
    } finally {
      // exitCode が例外で終わっても購読は必ず解放する。
      await _stdoutSubscription?.cancel();
      await _stderrSubscription?.cancel();
      _stdoutSubscription = null;
      _stderrSubscription = null;

      // 応答待ちのまま終了させられた呼び出し元を解放する。
      _failPending('shutdown により中断されました');
    }
  }

  /// 記録済みのビルドフラグと現在の設定を突き合わせる。
  ///
  /// 不一致は**静かな失敗の唯一の防波堤**なので、必ず起動を止める。
  /// ここを通過させると「リロードしても画面が変わらない」だけの状態に
  /// なり、原因の特定が極めて難しくなる。
  void _verifyBuildMeta() {
    final String? path = buildMetaPath;
    if (path == null) {
      return;
    }

    final BuildMeta recorded;
    try {
      recorded = BuildMeta.readFrom(File(path));
    } on BuildMetaException catch (error) {
      // 起動前検証の失敗は CompilerException に揃える。呼び出し元が
      // 2種類の例外を捕まえ分ける必要が無いようにする。原因は元の
      // メッセージをそのまま含める。
      throw CompilerException('ビルドフラグの記録を読めません: ${error.message}');
    }
    final List<String> differences = recorded.differencesFrom(buildMeta);
    if (differences.isEmpty) {
      return;
    }

    throw CompilerException(
      'APK のビルド時と増分コンパイルでフラグが一致しません。\n'
      'このまま起動すると reloadSources が静かに失敗し、'
      '「保存しても画面が変わらない」状態になります。\n'
      '  ${differences.join('\n  ')}\n'
      '`fluse rebuild` で APK を作り直してください。\n'
      '  build_meta: $path',
    );
  }

  // --------------------------------------------------------------- internals

  /// stdin への書き込みを直列化する。
  ///
  /// stdin は1本しかないため、複数の `compile` / `recompile` が
  /// 同時に走ると要求が混ざって応答の対応が取れなくなる。
  Future<T> _enqueue<T>(Future<T> Function() action) {
    final Completer<T> completer = Completer<T>();
    _queue = _queue.then((_) async {
      try {
        completer.complete(await action());
      } on Object catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Future<FrontendServerResult> _request({
    required void Function(IOSink stdin) send,
    required Duration timeout,
    bool expectSources = true,
  }) async {
    final IOSink stdin = _requireStdin();

    final Completer<FrontendServerResult> completer =
        Completer<FrontendServerResult>();
    _parser = FrontendServerOutputParser(expectSources: expectSources);
    _pending = completer;

    send(stdin);
    await stdin.flush();

    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      // 応答は要求と対応付けられない（`result <key>` のキーは
      // frontend_server が自分で採番し、こちらの `recompile <uri> <key>` の
      // キーは差分リストの終端記号でしかない）。したがって諦めた要求の
      // 応答が後から届くと、次の要求の結果として返ってしまう。
      // 誤った dill が DevFS へ流れるのを防ぐため、タイムアウトは
      // 回復不能として扱い、プロセスごと落とす。
      _parser = null;
      _pending = null;
      await shutdown();
      throw CompilerException(
        '$timeout 以内に応答がありませんでした。'
        'frontend_server を停止しました。start() からやり直してください',
      );
    }
  }

  IOSink _requireStdin() {
    final Process? process = _process;
    if (process == null) {
      throw const CompilerException('起動していません。先に start() を呼んでください');
    }
    if (_exitCode != null) {
      throw CompilerException('プロセスが終了コード $_exitCode で終了しています');
    }
    return process.stdin;
  }

  void _handleStdoutLine(String line) {
    final FrontendServerOutputParser? parser = _parser;
    if (parser == null) {
      // 要求していない出力。捨てずにログには残す。
      _logger?.debug('frontend_server(stdout): $line');
      return;
    }

    final FrontendServerResult? result;
    try {
      parser.addLine(line);
      result = parser.result;
    } on FormatException catch (error) {
      // 壊れた応答を成功として扱うと、エラーを含む dill が流れる。
      _failPending('応答を解釈できませんでした: ${error.message} (${error.source})');
      return;
    }
    if (result == null) {
      return;
    }

    final Completer<FrontendServerResult>? pending = _pending;
    _parser = null;
    _pending = null;
    if (pending != null && !pending.isCompleted) {
      pending.complete(result);
    }
  }

  void _handleStderrLine(String line) {
    // stderr は診断ではなく frontend_server 自体の異常。握りつぶさない。
    _logger?.warn('frontend_server(stderr): $line');
  }

  void _handleExit(int code) {
    _exitCode = code;
    _logger?.warn(
      'frontend_server が終了しました',
      fields: <String, Object?>{'exitCode': code},
    );
    _failPending('プロセスが終了コード $code で終了しました');
  }

  void _failPending(String reason) {
    final Completer<FrontendServerResult>? pending = _pending;
    _parser = null;
    _pending = null;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(CompilerException(reason));
    }
  }

  CompileOutput _toOutput(FrontendServerResult result) {
    final String? outputPath = result.outputPath;
    return CompileOutput(
      incrementalDill: outputPath == null ? null : File(outputPath),
      errorCount: result.errorCount,
      diagnostics: result.diagnostics,
      sources: result.sources,
    );
  }

  /// ファイル URI を `--filesystem-scheme` 付きの URI に変換する。
  ///
  /// `package:` URI と、既に `--filesystem-scheme` が付いた URI はそのまま
  /// 通す。それ以外は `file:` かスキーム無し（相対パス）だけを受け付け、
  /// **必ず [projectRoot] 配下であることを検証する**。`--filesystem-root`
  /// の外を指す URI は `frontend_server` が解決できず、原因の分かりにくい
  /// 失敗になるため、送る前に落とす。
  String _toCompilerUri(Uri uri) {
    if (uri.scheme == 'package' || uri.scheme == fileSystemScheme) {
      return uri.toString();
    }
    if (uri.hasScheme && !uri.isScheme('file')) {
      throw CompilerException(
        '扱えない URI スキームです: $uri\n'
        '  file: / package: / $fileSystemScheme: のいずれかを渡してください',
      );
    }

    // スキーム無しは projectRoot からの相対パスとして解決する。
    // そのまま通すと `../../secrets.dart` が検証を素通りする。
    final String absolutePath = p.normalize(
      uri.hasScheme
          ? uri.toFilePath()
          : p.join(projectRoot, p.fromUri(uri.path)),
    );

    if (!p.isWithin(projectRoot, absolutePath)) {
      throw CompilerException(
        'プロジェクト外のファイルはコンパイルできません: $absolutePath\n'
        '  projectRoot: $projectRoot',
      );
    }

    // URI のパス区切りは常に `/`。Windows の `\` を変換する。
    final String relative = p.relative(absolutePath, from: projectRoot);
    return '$fileSystemScheme:///${p.split(relative).join('/')}';
  }

  /// `recompile` の境界キー。
  ///
  /// 応答の区切りに使われるため、ソースやパスに現れない文字列である
  /// 必要がある。衝突すると応答の解析が壊れる。
  String _generateBoundaryKey() {
    const String alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final String suffix = List<String>.generate(
      16,
      (_) => alphabet[_random.nextInt(alphabet.length)],
    ).join();
    return 'fluse-$suffix';
  }
}
