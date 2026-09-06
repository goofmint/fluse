/// 対象が Flutter プロジェクトでなかったときに投げる例外。
///
/// 設計 §5.1 の `PROJECT_NOT_FLUTTER` に対応する。
///
/// **判定は `pubspec.yaml` の `flutter:` セクションだけで行う。**
/// `android/` の有無で判じると、まだ `flutter create` していない
/// プロジェクトや、Android を外した構成を取り違える。
final class ProjectNotFlutterException implements Exception {
  /// `pubspec.yaml` そのものが無い場合。
  const ProjectNotFlutterException.pubspecMissing({
    required this.projectRoot,
    required this.pubspecPath,
  }) : reason = 'pubspec.yaml がありません';

  /// `pubspec.yaml` はあるが `flutter:` セクションが無い場合。
  const ProjectNotFlutterException.notFlutter({
    required this.projectRoot,
    required this.pubspecPath,
  }) : reason = 'pubspec.yaml に flutter: セクションがありません';

  /// 対象のプロジェクトルート。
  final String projectRoot;

  /// 見に行った `pubspec.yaml` の場所。
  final String pubspecPath;

  /// 失敗の要約。
  final String reason;

  @override
  String toString() =>
      'Flutter プロジェクトではありません: $reason'
      '\n  プロジェクト: $projectRoot'
      '\n  確認した pubspec: $pubspecPath'
      '\n\n  Flutter アプリのルート（pubspec.yaml のある場所）で実行してください。'
      '\n  `fluse doctor` で環境を確認できます。';
}

/// プロジェクトの解析に失敗したときに投げる例外。
///
/// **黙って既定値へ倒さない。** `applicationId` や `name` を取り違えると、
/// 別のアプリを上書きインストールしたり、サーバ側の `projectId` 突合が
/// 通らなかったりする。どちらも原因が見えにくい形で表面化する。
final class ProjectAnalysisException implements Exception {
  const ProjectAnalysisException(this.message, {this.path});

  /// 何が起きたか。
  final String message;

  /// 原因となったファイル。分からなければ null。
  final String? path;

  @override
  String toString() {
    final StringBuffer buffer = StringBuffer('プロジェクトを解析できません: $message');
    if (path != null) {
      buffer.write('\n  対象: $path');
    }
    return buffer.toString();
  }
}
