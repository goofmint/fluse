import 'dart:io';

/// 用意した debug 用 keystore（設計 §2.2.2）。
///
/// **配布物の署名には使わない。** `fluse` が作るのは、プレビュー用の APK を
/// 端末へ入れるためだけの鍵。パスワードは `keystore.json` に平文で置く
/// （設計 §9.2）ので、本番の鍵と同じ扱いをしてはいけない。
final class KeystoreInfo {
  const KeystoreInfo({
    required this.file,
    required this.alias,
    required this.storePassword,
    required this.keyPassword,
  });

  /// `.flutter_preview/keystore/fluse-debug.keystore`。
  final File file;

  /// 鍵の別名。
  final String alias;

  /// keystore 全体のパスワード。
  final String storePassword;

  /// 鍵そのもののパスワード。
  final String keyPassword;

  /// **パスワードは含めない。** 例外文やログに混ざると漏れる。
  @override
  String toString() => 'KeystoreInfo(${file.path}, alias: $alias)';
}
