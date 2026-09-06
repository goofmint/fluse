import 'fluse_config.dart';

/// `fluse.yaml` を読み書きできなかったときに投げる例外。
///
/// **黙って既定値へ倒さない。** 書いた設定が効いていないことに気づけず、
/// 「ポートを変えたのに繋がらない」といった形で表面化する。
final class FluseConfigException implements Exception {
  const FluseConfigException(this.message, {this.path});

  /// 何が起きたか。
  final String message;

  /// 原因となったファイル。分からなければ null。
  final String? path;

  @override
  String toString() {
    final StringBuffer buffer = StringBuffer('設定を読めません: $message');
    if (path != null) {
      buffer.write('\n  対象: $path');
    }
    // **次に何をすればよいかまで書く。** 何が違うかだけでは直せない。
    buffer.write(
      '\n\n  ${FluseConfig.fileName} か、指定した値を直してから実行し直してください。'
      '\n  `fluse doctor` で環境を確認できます。',
    );
    return buffer.toString();
  }
}
