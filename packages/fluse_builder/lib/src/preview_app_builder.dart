import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fluse_protocol/fluse_protocol.dart';
import 'package:path/path.dart' as p;
import 'package:process/process.dart';

import 'entrypoint_generator.dart';
import 'flutter_sdk.dart';
import 'keystore_info.dart';
import 'project_info.dart';

/// Preview App のビルドに失敗したときに投げる例外。
final class PreviewAppBuildException implements Exception {
  /// `flutter` を起動できなかった場合。
  const PreviewAppBuildException.notLaunched({required String this.detail})
    : reason = 'flutter を起動できません',
      exitCode = null,
      path = null;

  /// `flutter build apk` が失敗した場合。
  const PreviewAppBuildException.buildFailed({
    required int this.exitCode,
    required this.detail,
  }) : reason = 'flutter build apk が失敗しました',
       path = null;

  /// 待っても終わらなかった場合。
  const PreviewAppBuildException.timedOut({required Duration limit})
    : reason = 'ビルドが終わりません',
      detail = null,
      exitCode = null,
      path = null;

  /// 作られたはずの APK が無い場合。
  const PreviewAppBuildException.missingApk({required String this.path})
    : reason = 'APK が見つかりません',
      detail = null,
      exitCode = null;

  /// `--verbose` からフラグを読み取れなかった場合。
  const PreviewAppBuildException.metaUnavailable({required String this.detail})
    : reason = 'ビルドに使われたフラグを読み取れません',
      exitCode = null,
      path = null;

  /// 失敗の要約。
  final String reason;

  /// 分かっている手がかり。**署名情報は載せない。**
  final String? detail;

  final int? exitCode;

  final String? path;

  @override
  String toString() {
    final StringBuffer buffer = StringBuffer('Preview App を作れません: $reason');
    if (exitCode != null) {
      buffer.write('（終了コード $exitCode）');
    }
    if (path != null) {
      buffer.write('\n  対象: $path');
    }
    if (detail != null && detail!.isNotEmpty) {
      buffer.write('\n  詳細: $detail');
    }
    buffer.write(
      '\n\n  `flutter build apk --debug` が単体で通るか確かめてください。'
      '\n  `fluse doctor` で環境を確認できます。',
    );
    return buffer.toString();
  }
}

/// ビルドの結果。
final class BuildResult {
  const BuildResult({
    required this.apk,
    required this.applicationId,
    required this.buildMeta,
  });

  /// `.flutter_preview/build/preview.apk`。
  final File apk;

  /// 実際に端末へ入る ID。`applicationIdSuffix` を足した後の値。
  final String applicationId;

  /// このビルドで `frontend_server` に渡されたフラグ（設計 §10-1）。
  final BuildMeta buildMeta;

  @override
  String toString() => 'BuildResult(${apk.path}, $applicationId)';
}

/// ビルドの進み具合。
typedef BuildProgress = void Function(String line);

/// Preview App を組み立てる（設計 §2.2.2）。
///
/// **`flutter` は CLI として呼ぶだけ。** `packages/flutter_tools` へ path
/// 依存を張ると SDK の版に追従できなくなる（設計 §10-11）。
///
/// **利用者のプロジェクトを作り替えない。** 署名の設定は Gradle の
/// プロパティで外から渡す。`android/` に何も置かないので、指紋
/// （`android.gradle`）も汚れない。
final class PreviewAppBuilder {
  const PreviewAppBuilder({
    required this.sdk,
    this.processManager = const LocalProcessManager(),
    this.timeout = defaultTimeout,
    this.onProgress,
  });

  /// 解決済みの Flutter SDK。
  final FlutterSdk sdk;

  final ProcessManager processManager;

  /// 待つ上限。
  ///
  /// **無制限にしない。** Gradle のデーモンが固まると、待っていることにも
  /// 気づけないまま止まる。
  final Duration timeout;

  /// 1行ずつ進み具合を伝える。**ここで print しない。**
  final BuildProgress? onProgress;

  static const Duration defaultTimeout = Duration(minutes: 30);

  /// 出力先。
  static const String outputDirName = 'build';
  static const String outputApkName = 'preview.apk';

  /// `flutter build apk --debug` が置く場所。
  static const List<String> flutterApkPath = <String>[
    'build',
    'app',
    'outputs',
    'flutter-apk',
    'app-debug.apk',
  ];

  /// `build_meta.json` の置き場（設計 §2.2.2）。
  static const String cacheDirName = 'cache';
  static const String buildMetaName = 'build_meta.json';

  /// AGP が読む署名のプロパティ。
  ///
  /// **`key.properties` を置かない。** 利用者がコミットしている Gradle の
  /// ファイルを書き換えることになり、`android.gradle` の指紋も動く。
  static const String signingStoreFileProperty =
      'android.injected.signing.store.file';
  static const String signingStorePasswordProperty =
      'android.injected.signing.store.password';
  static const String signingKeyAliasProperty =
      'android.injected.signing.key.alias';
  static const String signingKeyPasswordProperty =
      'android.injected.signing.key.password';

  /// Preview App を作る。
  Future<BuildResult> build({
    required ProjectInfo project,
    required File entrypoint,
    required KeystoreInfo keystore,
    String? applicationIdSuffix,
  }) async {
    final List<String> arguments = buildArguments(
      project: project,
      entrypoint: entrypoint,
      applicationIdSuffix: applicationIdSuffix,
    );

    final _Output output = await _run(
      arguments: arguments,
      workingDirectory: project.root,
      environment: signingEnvironment(
        keystore: keystore,
        parent: Platform.environment,
      ),
    );

    if (output.exitCode != 0) {
      throw PreviewAppBuildException.buildFailed(
        exitCode: output.exitCode,
        // **そのまま載せない。** `--verbose` には署名のプロパティが出る。
        detail: mask(output.tail),
      );
    }

    final File produced = File(p.join(project.root, p.joinAll(flutterApkPath)));
    if (!produced.existsSync()) {
      throw PreviewAppBuildException.missingApk(path: produced.path);
    }

    final BuildMeta meta;
    try {
      meta = BuildMetaParser.parse(output.all);
    } on BuildMetaException catch (error) {
      // **推測で埋めない。** フラグが1つ違うだけで `reloadSources` が
      // 静かに失敗し、画面が変わらない理由が分からなくなる（設計 §10-1）。
      throw PreviewAppBuildException.metaUnavailable(detail: error.message);
    }

    final Directory previewDir = Directory(
      p.join(project.root, EntrypointGenerator.previewDirName),
    );
    meta.writeTo(File(p.join(previewDir.path, cacheDirName, buildMetaName)));

    final File apk = File(
      p.join(previewDir.path, outputDirName, outputApkName),
    );
    await apk.parent.create(recursive: true);
    await produced.copy(apk.path);

    return BuildResult(
      apk: apk,
      applicationId: effectiveApplicationId(
        project.applicationId,
        applicationIdSuffix,
      ),
      buildMeta: meta,
    );
  }

  // ------------------------------------------------------------------ 引数

  /// `flutter build apk` に渡す引数。
  static List<String> buildArguments({
    required ProjectInfo project,
    required File entrypoint,
    String? applicationIdSuffix,
  }) => <String>[
    'build',
    'apk',
    '--debug',
    // **`--verbose` は外せない。** ここから `frontend_server` のフラグを
    // 読み取る（設計 §10-1）。読めないと増分コンパイルが噛み合わない。
    '--verbose',
    '--target',
    entrypoint.path,
    if (applicationIdSuffix != null && applicationIdSuffix.isNotEmpty)
      '--application-id-suffix=$applicationIdSuffix',
  ];

  /// 実際に端末へ入る ID。
  static String effectiveApplicationId(String applicationId, String? suffix) =>
      suffix == null || suffix.isEmpty
      ? applicationId
      : '$applicationId$suffix';

  /// 署名の設定を渡すための環境。
  ///
  /// `GRADLE_OPTS` に system property として積む。**既にある値は残す。**
  /// 利用者がメモリ設定などを入れていることがある。
  static Map<String, String> signingEnvironment({
    required KeystoreInfo keystore,
    required Map<String, String> parent,
  }) {
    final List<String> options = <String>[
      if ((parent['GRADLE_OPTS'] ?? '').trim().isNotEmpty)
        parent['GRADLE_OPTS']!.trim(),
      _property(signingStoreFileProperty, keystore.file.absolute.path),
      _property(signingStorePasswordProperty, keystore.storePassword),
      _property(signingKeyAliasProperty, keystore.alias),
      _property(signingKeyPasswordProperty, keystore.keyPassword),
    ];

    return <String, String>{...parent, 'GRADLE_OPTS': options.join(' ')};
  }

  static String _property(String name, String value) =>
      '-Dorg.gradle.project.$name=$value';

  /// 署名の値を伏せる。
  ///
  /// **例外文とログの両方に効かせる。** `--verbose` の出力には Gradle へ
  /// 渡したプロパティがそのまま出る。
  static String mask(String text) {
    final RegExp pattern = RegExp(
      '(${RegExp.escape(signingStorePasswordProperty)}|'
      '${RegExp.escape(signingKeyPasswordProperty)})=([^\\s]+)',
    );
    return text.replaceAllMapped(
      pattern,
      (Match match) => '${match.group(1)}=${maskToken(match.group(2) ?? '')}',
    );
  }

  // ------------------------------------------------------------------ 実行

  Future<_Output> _run({
    required List<String> arguments,
    required String workingDirectory,
    required Map<String, String> environment,
  }) async {
    final Process process;
    try {
      process = await processManager.start(
        <String>[sdk.flutterExecutable, ...arguments],
        workingDirectory: workingDirectory,
        environment: environment,
      );
    } on ProcessException catch (error) {
      throw PreviewAppBuildException.notLaunched(detail: error.message);
    }

    final StringBuffer all = StringBuffer();
    final List<String> tail = <String>[];

    void take(String line) {
      all.writeln(line);
      // 失敗した時に見せるのは末尾だけ。全部出すと肝心の理由が埋もれる。
      tail.add(line);
      if (tail.length > tailLines) {
        tail.removeAt(0);
      }
      onProgress?.call(mask(line));
    }

    final Future<void> stdoutDone = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .forEach(take);
    final Future<void> stderrDone = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .forEach(take);

    final int exitCode;
    try {
      exitCode = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      // **残さない。** Gradle のデーモンを掴んだままだと、次のビルドが
      // 待たされる。
      process.kill(ProcessSignal.sigkill);
      unawaited(stdoutDone.catchError((Object _) {}));
      unawaited(stderrDone.catchError((Object _) {}));
      throw PreviewAppBuildException.timedOut(limit: timeout);
    }

    await Future.wait<void>(<Future<void>>[stdoutDone, stderrDone]);

    return _Output(
      exitCode: exitCode,
      all: all.toString(),
      tail: tail.join('\n'),
    );
  }

  /// 失敗時に見せる末尾の行数。
  static const int tailLines = 40;

  /// 伏せた印。テストが「伏せられたこと」を確かめるのに使う。
  static const String maskSuffixSample = maskSuffix;
}

final class _Output {
  const _Output({
    required this.exitCode,
    required this.all,
    required this.tail,
  });

  final int exitCode;

  /// 全出力。`BuildMetaParser` へ渡す。
  final String all;

  /// 末尾だけ。失敗の理由を見せるのに使う。
  final String tail;
}
