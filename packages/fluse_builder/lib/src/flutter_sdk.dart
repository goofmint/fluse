import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:process/process.dart';

import 'host_platform.dart';
import 'sdk_not_found_exception.dart';

/// 解決済みの Flutter SDK（設計 §2.2.2）。
///
/// `fluse` は flutter_tools をライブラリとして使わず、`frontend_server` を
/// 直接起動する。そのために SDK のどこに何があるかを自分で知る必要がある。
final class FlutterSdk {
  const FlutterSdk({
    required this.root,
    required this.version,
    required this.revision,
    required this.dartVersion,
    required this.engineDirectoryName,
    required this.isWindows,
  });

  /// SDK のルート（`$FLUTTER_ROOT`）。
  final String root;

  /// フレームワークのバージョン。例: `3.41.9`
  final String version;

  /// フレームワークのリビジョン。例: `00b0c91f06209d9e4a41f71b7a512d6eb3b9c694`
  ///
  /// 端末側の Preview App と突き合わせ、不一致なら `REVISION_MISMATCH` で
  /// 弾く（設計 §5.1）。
  final String revision;

  /// Dart SDK のバージョン。例: `3.11.5`
  final String dartVersion;

  /// エンジン成果物が実在したディレクトリ名。例: `darwin-x64`
  final String engineDirectoryName;

  /// Windows のホストか。実行ファイル名の拡張子を決めるために保持する。
  ///
  /// [resolve] に渡された値をそのまま持つ。ゲッターが `Platform.isWindows`
  /// を直接見ると、解決時とパス組み立て時で判定がずれる余地ができるため。
  final bool isWindows;

  /// `flutter` 実行ファイルの名前。Windows では `flutter.bat`。
  static String flutterExecutableName({required bool isWindows}) =>
      isWindows ? 'flutter.bat' : 'flutter';

  /// `dartaotruntime` 実行ファイルの名前。Windows では `.exe` が付く。
  static String dartAotRuntimeName({required bool isWindows}) =>
      isWindows ? 'dartaotruntime.exe' : 'dartaotruntime';

  /// `flutter` 実行ファイル。`flutter build apk` の呼び出しに使う。
  String get flutterExecutable =>
      p.join(root, 'bin', flutterExecutableName(isWindows: isWindows));

  /// `frontend_server` を動かす AOT ランタイム。
  String get dartAotRuntime => p.join(
    root,
    'bin',
    'cache',
    'dart-sdk',
    'bin',
    dartAotRuntimeName(isWindows: isWindows),
  );

  /// エンジン成果物のディレクトリ。
  String get engineArtifactsDirectory =>
      p.join(root, 'bin', 'cache', 'artifacts', 'engine');

  /// 増分コンパイラのスナップショット。
  ///
  /// flutter_tools は現在このファイルを
  /// `bin/cache/dart-sdk/bin/snapshots/` からも解決する
  /// （`packages/flutter_tools/lib/src/artifacts.dart` の
  /// `_getHostArtifactPath`）。両者は同一の内容で、どちらを使っても動く。
  /// ここではエンジン成果物側を使い、[engineDirectoryName] で実在が
  /// 確認済みのディレクトリを指す。
  String get frontendServerSnapshot => p.join(
    engineArtifactsDirectory,
    engineDirectoryName,
    'frontend_server_aot.dart.snapshot',
  );

  /// `--sdk-root` に渡す patched SDK。ホストによらず `common` にある。
  String get patchedSdkRoot =>
      p.join(engineArtifactsDirectory, 'common', 'flutter_patched_sdk');

  /// Flutter SDK を解決する。
  ///
  /// ルートの決定順は **[explicitRoot]（`--flutter-sdk`）> 環境変数
  /// `FLUSE_FLUTTER_SDK` > PATH 上の `flutter`** （設計 §9.2 の優先順位）。
  ///
  /// 解決後、`flutter --version --machine` でバージョン情報を取得し、
  /// 使用する成果物が実在することまで検証する。どこかで失敗した場合は
  /// [SdkNotFoundException] を投げる。半端に解決した SDK を返すと、
  /// 後段の `frontend_server` 起動が原因不明の失敗になるため。
  static Future<FlutterSdk> resolve({
    String? explicitRoot,
    ProcessManager processManager = const LocalProcessManager(),
    Map<String, String>? environment,
    bool? isWindows,
  }) async {
    final bool onWindows = isWindows ?? Platform.isWindows;
    final Map<String, String> env = environment ?? Platform.environment;
    final String root = _resolveRoot(
      explicitRoot: explicitRoot,
      environment: env,
      isWindows: onWindows,
    );

    final _VersionInfo info = await _readVersion(
      root: root,
      processManager: processManager,
      isWindows: onWindows,
    );

    final String engineDirectoryName = _resolveEngineDirectory(root);

    final FlutterSdk sdk = FlutterSdk(
      root: root,
      version: info.version,
      revision: info.revision,
      dartVersion: info.dartVersion,
      engineDirectoryName: engineDirectoryName,
      isWindows: onWindows,
    );
    sdk._verifyArtifacts();
    return sdk;
  }

  static String _resolveRoot({
    required String? explicitRoot,
    required Map<String, String> environment,
    required bool isWindows,
  }) {
    final List<String> searched = <String>[];

    if (explicitRoot != null && explicitRoot.isNotEmpty) {
      final String normalized = p.normalize(p.absolute(explicitRoot));
      if (_looksLikeSdkRoot(normalized, isWindows: isWindows)) {
        return normalized;
      }
      throw SdkNotFoundException.rootNotFound(
        reason: '--flutter-sdk に指定された場所に flutter 実行ファイルがありません',
        searchedPaths: <String>[normalized],
      );
    }

    final String? fromEnvironment = environment['FLUSE_FLUTTER_SDK'];
    if (fromEnvironment != null && fromEnvironment.isNotEmpty) {
      final String normalized = p.normalize(p.absolute(fromEnvironment));
      if (_looksLikeSdkRoot(normalized, isWindows: isWindows)) {
        return normalized;
      }
      throw SdkNotFoundException.rootNotFound(
        reason: 'FLUSE_FLUTTER_SDK が指す場所に flutter 実行ファイルがありません',
        searchedPaths: <String>[normalized],
      );
    }

    final String? fromPath = _searchPath(
      environment: environment,
      isWindows: isWindows,
      searched: searched,
    );
    if (fromPath != null) {
      return fromPath;
    }

    throw SdkNotFoundException.rootNotFound(
      reason: 'PATH 上に flutter 実行ファイルが見つかりません',
      searchedPaths: searched,
    );
  }

  /// PATH を順に見て `bin/flutter` を持つ SDK ルートを返す。
  static String? _searchPath({
    required Map<String, String> environment,
    required bool isWindows,
    required List<String> searched,
  }) {
    final String? pathVariable = environment['PATH'] ?? environment['Path'];
    if (pathVariable == null || pathVariable.isEmpty) {
      return null;
    }

    final String separator = isWindows ? ';' : ':';
    final String executable = flutterExecutableName(isWindows: isWindows);

    for (final String entry in pathVariable.split(separator)) {
      if (entry.isEmpty) {
        continue;
      }
      final String candidate = p.join(entry, executable);
      searched.add(candidate);
      if (!File(candidate).existsSync()) {
        continue;
      }
      // `<root>/bin/flutter` の2つ上がルート。シンボリックリンク経由でも
      // 実体の位置を基準にしたいので解決してから辿る。
      //
      // existsSync との間に TOCTOU があり、リンク切れ・権限不足・実行中の
      // 削除で FileSystemException が飛ぶ。呼び出し元は SdkNotFoundException
      // だけを期待しているので、ここで変換する。
      final String resolved;
      try {
        resolved = File(candidate).resolveSymbolicLinksSync();
      } on FileSystemException catch (error) {
        throw SdkNotFoundException.rootNotFound(
          reason: 'PATH 上の flutter 実行ファイルの実体を解決できません: ${error.message}',
          searchedPaths: searched,
        );
      }
      return p.dirname(p.dirname(resolved));
    }
    return null;
  }

  static bool _looksLikeSdkRoot(String root, {required bool isWindows}) => File(
    p.join(root, 'bin', flutterExecutableName(isWindows: isWindows)),
  ).existsSync();

  static Future<_VersionInfo> _readVersion({
    required String root,
    required ProcessManager processManager,
    required bool isWindows,
  }) async {
    final String executable = p.join(
      root,
      'bin',
      flutterExecutableName(isWindows: isWindows),
    );

    final ProcessResult result;
    try {
      result = await processManager.run(<String>[
        executable,
        '--version',
        '--machine',
      ]);
    } on Object catch (error) {
      throw SdkNotFoundException.versionUnavailable(
        root: root,
        reason: 'flutter --version --machine の起動に失敗しました: $error',
      );
    }

    if (result.exitCode != 0) {
      throw SdkNotFoundException.versionUnavailable(
        root: root,
        reason:
            'flutter --version --machine が終了コード ${result.exitCode} で失敗しました'
            '${_trimmedStderr(result)}',
      );
    }

    return _parseVersion(root: root, stdout: '${result.stdout}');
  }

  /// `flutter --version --machine` の JSON を読む。
  ///
  /// 更新通知などが JSON の前に出ることがあるため、最初の `{` から
  /// 末尾の `}` までを切り出してから解析する。
  static _VersionInfo _parseVersion({
    required String root,
    required String stdout,
  }) {
    final int start = stdout.indexOf('{');
    final int end = stdout.lastIndexOf('}');
    if (start < 0 || end <= start) {
      throw SdkNotFoundException.versionUnavailable(
        root: root,
        reason: 'flutter --version --machine の出力に JSON が含まれていません',
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(stdout.substring(start, end + 1));
    } on FormatException catch (error) {
      throw SdkNotFoundException.versionUnavailable(
        root: root,
        reason: 'flutter --version --machine の JSON を解析できません: ${error.message}',
      );
    }

    if (decoded is! Map<String, Object?>) {
      throw SdkNotFoundException.versionUnavailable(
        root: root,
        reason: 'flutter --version --machine の出力が JSON オブジェクトではありません',
      );
    }

    return _VersionInfo(
      version: _requireString(decoded, 'frameworkVersion', root),
      revision: _requireString(decoded, 'frameworkRevision', root),
      // `3.11.5 (build 3.11.5)` のような表記があるため先頭のバージョンだけ取る。
      dartVersion: _requireString(
        decoded,
        'dartSdkVersion',
        root,
      ).split(' ').first,
    );
  }

  static String _requireString(
    Map<String, Object?> json,
    String key,
    String root,
  ) {
    final Object? value = json[key];
    if (value is String && value.isNotEmpty) {
      return value;
    }
    throw SdkNotFoundException.versionUnavailable(
      root: root,
      reason: 'flutter --version --machine の出力に $key がありません',
    );
  }

  /// エンジン成果物が実在するディレクトリ名を選ぶ。
  ///
  /// Apple Silicon では `darwin-arm64` ではなく `darwin-x64` に置かれる
  /// ことがあるため（[HostPlatform.engineDirectoryCandidates] 参照）、
  /// 候補を順に見て実在するものを採用する。どれも無ければ例外にする。
  static String _resolveEngineDirectory(String root) {
    final HostPlatform host = HostPlatform.resolve();
    final String engineRoot = p.join(
      root,
      'bin',
      'cache',
      'artifacts',
      'engine',
    );

    final List<String> checked = <String>[];
    for (final String name in host.engineDirectoryCandidates) {
      final String candidate = p.join(
        engineRoot,
        name,
        'frontend_server_aot.dart.snapshot',
      );
      checked.add(candidate);
      if (File(candidate).existsSync()) {
        return name;
      }
    }

    throw SdkNotFoundException.artifactsMissing(
      root: root,
      missingPaths: checked,
    );
  }

  /// 使用する成果物が全て存在することを確認する。
  void _verifyArtifacts() {
    final List<String> missing = <String>[
      if (!File(dartAotRuntime).existsSync()) dartAotRuntime,
      if (!File(frontendServerSnapshot).existsSync()) frontendServerSnapshot,
      if (!Directory(patchedSdkRoot).existsSync()) patchedSdkRoot,
    ];

    if (missing.isNotEmpty) {
      throw SdkNotFoundException.artifactsMissing(
        root: root,
        missingPaths: missing,
      );
    }
  }

  static String _trimmedStderr(ProcessResult result) {
    final String stderr = '${result.stderr}'.trim();
    return stderr.isEmpty ? '' : '\n  stderr: $stderr';
  }

  @override
  String toString() =>
      'FlutterSdk($version, revision: $revision, dart: $dartVersion, '
      'root: $root)';
}

/// `flutter --version --machine` から読み取った値。
final class _VersionInfo {
  const _VersionInfo({
    required this.version,
    required this.revision,
    required this.dartVersion,
  });

  final String version;
  final String revision;
  final String dartVersion;
}
