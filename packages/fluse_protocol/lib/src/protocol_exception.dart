/// ワイヤ表現を解釈できなかったときに投げる。
///
/// **トークンなどの値は載せない。** このメッセージはログにもコンソールにも
/// 出るため、`pairingToken` や `deviceToken` が混ざると漏れる。
/// 何のフィールドが、どう期待と違ったかだけを書く。
final class FluseProtocolException implements Exception {
  const FluseProtocolException(this.message);

  /// 欠けているフィールドについての定型。
  factory FluseProtocolException.missingField(String type, String field) =>
      FluseProtocolException('$type: $field がありません');

  /// 型が違うフィールドについての定型。
  ///
  /// 値そのものは載せず、実際の型だけを示す。
  factory FluseProtocolException.wrongType(
    String type,
    String field,
    String expected,
    Object? actual,
  ) => FluseProtocolException(
    '$type: $field が $expected ではありません（実際は ${actual.runtimeType}）',
  );

  final String message;

  @override
  String toString() => 'fluse_protocol: $message';
}
