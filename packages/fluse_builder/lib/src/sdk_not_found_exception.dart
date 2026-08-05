/// Flutter SDK を解決できなかったときに投げる例外。
///
/// 設計 §5.1 の `SDK_NOT_FOUND` に対応する。`doctor` へ誘導するメッセージを
/// 返し、利用者が次に何をすればよいか分かるようにする。
final class SdkNotFoundException implements Exception {
  /// SDK ルートそのものが見つからなかった場合。
  const SdkNotFoundException.rootNotFound({
    required this.reason,
    this.searchedPaths = const <String>[],
  }) : missingPaths = const <String>[],
       root = null;

  /// SDK ルートは見つかったが、必要な成果物が欠けていた場合。
  ///
  /// `flutter precache` が未実行、あるいはキャッシュが壊れているときに起きる。
  const SdkNotFoundException.artifactsMissing({
    required String this.root,
    required this.missingPaths,
  }) : reason = 'SDK の成果物が見つかりません',
       searchedPaths = const <String>[];

  /// `flutter --version --machine` の実行や解析に失敗した場合。
  const SdkNotFoundException.versionUnavailable({
    required String this.root,
    required this.reason,
  }) : missingPaths = const <String>[],
       searchedPaths = const <String>[];

  /// 失敗の要約。
  final String reason;

  /// 解決できた SDK ルート。ルート自体が見つからなかった場合は null。
  final String? root;

  /// 欠けていた成果物のパス。
  final List<String> missingPaths;

  /// ルート探索で確認した場所。
  final List<String> searchedPaths;

  @override
  String toString() {
    final StringBuffer buffer = StringBuffer('Flutter SDK を解決できません: $reason');

    if (root != null) {
      buffer.write('\n  SDK ルート: $root');
    }
    if (searchedPaths.isNotEmpty) {
      buffer.write('\n  探索した場所:');
      for (final String path in searchedPaths) {
        buffer.write('\n    $path');
      }
    }
    if (missingPaths.isNotEmpty) {
      buffer.write('\n  見つからなかったファイル:');
      for (final String path in missingPaths) {
        buffer.write('\n    $path');
      }
      buffer.write('\n  `flutter precache` を実行してキャッシュを整えてください。');
    }

    buffer.write(
      '\n\n  Flutter SDK の場所は次の優先順位で決まります:'
      '\n    1. --flutter-sdk オプション'
      '\n    2. FLUSE_FLUTTER_SDK 環境変数'
      '\n    3. PATH 上の flutter 実行ファイル'
      '\n  `fluse doctor` で環境を確認できます。',
    );

    return buffer.toString();
  }
}
