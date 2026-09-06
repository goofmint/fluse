/// 端末への導入に失敗したときに投げる例外。
final class DeviceInstallException implements Exception {
  /// `adb` が見つからない場合。
  const DeviceInstallException.adbNotFound()
    : reason = 'adb が見つかりません',
      detail = null,
      path = null,
      exitCodeValue = null,
      _aboutAdb = true;

  /// `adb` を起動できなかった場合。
  const DeviceInstallException.adbUnavailable({required String this.detail})
    : reason = 'adb を起動できません',
      path = null,
      exitCodeValue = null,
      _aboutAdb = true;

  /// 繋がっている端末が無い場合。
  const DeviceInstallException.noDevices()
    : reason = '繋がっている端末がありません',
      detail =
          'USB で繋いで「USB デバッグ」を許可してください。'
          '`adb devices` に表示されれば使えます',
      path = null,
      exitCodeValue = null,
      _aboutAdb = true;

  /// インストールが失敗した場合。
  const DeviceInstallException.installFailed({
    required int this.exitCodeValue,
    required this.detail,
  }) : reason = 'インストールに失敗しました',
       path = null,
       _aboutAdb = false;

  /// 待っても終わらなかった場合。
  const DeviceInstallException.timedOut()
    : reason = 'インストールが終わりません',
      detail = '端末の画面に確認のダイアログが出ていないか見てください',
      path = null,
      exitCodeValue = null,
      _aboutAdb = false;

  /// `fluse.yaml` へ書けなかった場合。
  const DeviceInstallException.suffixNotPersisted({
    required String this.path,
    required this.detail,
  }) : reason = 'fluse.yaml に applicationIdSuffix を書けません',
       exitCodeValue = null,
       _aboutAdb = false;

  /// 配信に使えるアドレスが見つからない場合。
  const DeviceInstallException.noLanAddress()
    : reason = '端末から届くアドレスが見つかりません',
      detail =
          'Wi-Fi に繋がっているか確認してください。'
          'この機と端末が同じネットワークに居る必要があります',
      path = null,
      exitCodeValue = null,
      _aboutAdb = false;

  /// 配る APK が見つからない場合。
  const DeviceInstallException.apkMissing({required String this.path})
    : reason = 'APK が見つかりません',
      detail = '先に `fluse init` で Preview App を作ってください',
      exitCodeValue = null,
      _aboutAdb = false;

  /// 失敗の要約。
  final String reason;

  /// 分かっている手がかり。**トークンやパスワードは載せない。**
  final String? detail;

  /// 原因となったファイル。
  final String? path;

  /// `adb` の終了コード。
  final int? exitCodeValue;

  /// `adb` にまつわる失敗か。案内の出し分けに使う。
  final bool _aboutAdb;

  @override
  String toString() {
    final StringBuffer buffer = StringBuffer('端末に入れられません: $reason');
    if (exitCodeValue != null) {
      buffer.write('（終了コード $exitCodeValue）');
    }
    if (path != null) {
      buffer.write('\n  対象: $path');
    }
    if (detail != null && detail!.isNotEmpty) {
      buffer.write('\n  詳細: $detail');
    }

    // **adb の案内は adb の話にだけ添える。** 書き込みの失敗に付けると、
    // 関係のない場所を探させることになる。
    if (_aboutAdb) {
      buffer.write(
        '\n\n  adb は Android SDK Platform-Tools に含まれています。'
        '\n  入っていない場合は、APK を HTTP で配って手で入れることもできます。'
        '\n  `fluse doctor` で環境を確認できます。',
      );
    }
    return buffer.toString();
  }
}
