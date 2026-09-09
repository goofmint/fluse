/// fluse が実機へ届ける対象のプラットフォーム（Issue #103）。
///
/// 今のところ実際にビルド・導入できるのは Android だけ。Phase2 で iOS に
/// 対応する第一歩として、まず `fluse.yaml` と CLI から選べる受け口だけを
/// 用意する。**この enum を消費してビルダー／インストーラの実装を切り替える
/// 処理はここには無い。** それは後続 Issue の範囲。
///
/// `dart:io` の `Platform`（ホスト OS を表す）と名前が紛らわしいため、
/// 意図的に `FluseTargetPlatform` という名前にしてある。
enum FluseTargetPlatform {
  android('android'),
  ios('ios');

  const FluseTargetPlatform(this.value);

  /// `fluse.yaml` や CLI 引数、環境変数で使う文字列表現。
  final String value;

  /// [value] から探す。見つからなければ null。
  ///
  /// **黙って既定値へ倒さない。** null を受け取った呼び出し側
  /// （`FluseConfig.validatePlatform`）が、許容値を添えたエラーにする。
  static FluseTargetPlatform? tryParse(String value) {
    for (final FluseTargetPlatform platform in FluseTargetPlatform.values) {
      if (platform.value == value) {
        return platform;
      }
    }
    return null;
  }

  @override
  String toString() => value;
}
