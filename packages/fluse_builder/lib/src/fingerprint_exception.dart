/// 指紋の計算・保存・読込に失敗したときに投げる例外。
///
/// **黙って「差分なし」に倒さない。** 指紋が読めない状態で古い APK を
/// 使い続けると、直したはずの変更が反映されない理由が分からなくなる
/// （設計 §5.1 の `APP_OUTDATED`）。
final class FingerprintException implements Exception {
  const FingerprintException(this.message, {this.path});

  /// 何が起きたか。
  final String message;

  /// 原因となったファイル。分からなければ null。
  final String? path;

  @override
  String toString() {
    final StringBuffer buffer = StringBuffer('指紋を扱えません: $message');
    if (path != null) {
      buffer.write('\n  対象: $path');
    }
    return buffer.toString();
  }
}
