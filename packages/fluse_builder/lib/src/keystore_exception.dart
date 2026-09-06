/// keystore を用意できなかったときに投げる例外。
///
/// **黙って署名なしへ倒さない。** 署名の無い APK は端末に入らない。
/// 何が足りないのかをその場で示す（設計 §5.1）。
final class KeystoreException implements Exception {
  /// `keytool` が見つからなかった場合。
  const KeystoreException.keytoolNotFound()
    : reason = 'keytool が見つかりません',
      detail = null,
      path = null,
      _aboutKeytool = true;

  /// `keytool` は動いたが失敗した場合。
  const KeystoreException.keytoolFailed({
    required int exitCode,
    required this.detail,
  }) : reason = 'keytool が失敗しました（終了コード $exitCode）',
       path = null,
       _aboutKeytool = true;

  /// `keytool` の起動そのものができなかった場合。
  const KeystoreException.keytoolUnavailable({required String this.detail})
    : reason = 'keytool を起動できません',
      path = null,
      _aboutKeytool = true;

  /// パーミッションを絞れなかった場合。
  ///
  /// **JDK の話ではない。** ここで JDK の確認を促すと、無関係な場所を
  /// 探させることになる。
  const KeystoreException.permissionFailed({
    required String this.path,
    required this.detail,
  }) : reason = 'パーミッションを 600 にできません',
       _aboutKeytool = false;

  /// `keystore.json` を読めなかった場合。
  const KeystoreException.storeUnreadable({
    required String this.path,
    required this.detail,
  }) : reason = 'keystore.json を読めません',
       _aboutKeytool = false;

  /// 作ったはずのものが無い場合。
  const KeystoreException.missingOutput({required String this.path})
    : reason = 'keystore が作られませんでした',
      detail = null,
      _aboutKeytool = true;

  /// 失敗の要約。
  final String reason;

  /// 分かっている追加の手がかり。
  ///
  /// **パスワードは載せない。** `keytool` へ渡す引数には `-storepass` が
  /// 含まれるため、コマンド列をそのまま入れてはいけない。
  final String? detail;

  /// 原因となったファイル。分からなければ null。
  final String? path;

  /// `keytool` にまつわる失敗か。案内の出し分けに使う。
  final bool _aboutKeytool;

  @override
  String toString() {
    final StringBuffer buffer = StringBuffer('keystore を用意できません: $reason');
    if (path != null) {
      buffer.write('\n  対象: $path');
    }
    if (detail != null && detail!.isNotEmpty) {
      buffer.write('\n  詳細: $detail');
    }

    // **JDK の案内は keytool の話にだけ添える。** パーミッションの失敗に
    // 付けると、関係のない場所を探させることになる。
    if (_aboutKeytool) {
      buffer.write(
        '\n\n  keytool は JDK に含まれています。次を確認してください:'
        '\n    1. JDK が入っているか（Android Studio 同梱のものでも可）'
        '\n    2. keytool が PATH にあるか'
        '\n    3. JAVA_HOME が JDK を指しているか'
        '\n  `fluse doctor` で環境を確認できます。',
      );
    }
    return buffer.toString();
  }
}
