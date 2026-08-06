import 'protocol_exception.dart';

/// JSON から型付きの値を取り出す小道具。
///
/// 「無い」と「型が違う」を別のメッセージで報告する。片方に丸めると、
/// 壊れたメッセージの原因が追えなくなる。
extension type JsonReader(Map<String, Object?> json) {
  /// 必須の文字列。
  String requireString(String type, String field) {
    final Object? value = json[field];
    if (value == null) {
      throw FluseProtocolException.missingField(type, field);
    }
    if (value is! String) {
      throw FluseProtocolException.wrongType(type, field, '文字列', value);
    }
    return value;
  }

  /// 省略可能な文字列。キーが無い場合と `null` の場合はどちらも null。
  String? optionalString(String type, String field) {
    final Object? value = json[field];
    if (value == null) {
      return null;
    }
    if (value is! String) {
      throw FluseProtocolException.wrongType(type, field, '文字列', value);
    }
    return value;
  }

  /// JSON が正確に表せる整数の上限（2^53 - 1）。
  ///
  /// これを超える値は `double` を経由した時点で別の値になりうる。
  /// Kotlin 側も JSON の数値を double で扱うため、この範囲に揃える。
  static const int maxSafeInteger = 9007199254740991;

  /// 同じく下限。
  static const int minSafeInteger = -9007199254740991;

  /// 必須の整数。
  ///
  /// JSON の数値は `double` で来ることがある（`1.0` など）。整数として
  /// 表せる場合だけ受け入れる。丸めると別の値になってしまうため。
  ///
  /// **範囲も検査する。** `double.toInt()` は 64bit 整数の範囲外を
  /// 黙って最大値・最小値に丸めるため、`1e30` のような値がそのまま
  /// 無意味な整数として通ってしまう。
  int requireInt(String type, String field) {
    final Object? value = json[field];
    if (value == null) {
      throw FluseProtocolException.missingField(type, field);
    }
    if (value is int) {
      return _requireSafeRange(type, field, value);
    }
    if (value is double && value.isFinite && value == value.roundToDouble()) {
      if (value < minSafeInteger || value > maxSafeInteger) {
        throw FluseProtocolException.wrongType(
          type,
          field,
          'JSON が正確に表せる整数',
          value,
        );
      }
      return value.toInt();
    }
    throw FluseProtocolException.wrongType(type, field, '整数', value);
  }

  /// 省略可能な整数。キーが無い場合と `null` の場合はどちらも null。
  ///
  /// `optionalString` と扱いを揃える。片方だけ `containsKey` で分岐すると、
  /// 「キー有り + null」を送ってくる相手に対して片方だけ失敗する。
  int? optionalInt(String type, String field) {
    if (json[field] == null) {
      return null;
    }
    return requireInt(type, field);
  }

  static int _requireSafeRange(String type, String field, int value) {
    if (value < minSafeInteger || value > maxSafeInteger) {
      throw FluseProtocolException.wrongType(
        type,
        field,
        'JSON が正確に表せる整数',
        value,
      );
    }
    return value;
  }

  /// 必須のリスト。
  List<Object?> requireList(String type, String field) {
    final Object? value = json[field];
    if (value == null) {
      throw FluseProtocolException.missingField(type, field);
    }
    if (value is! List) {
      throw FluseProtocolException.wrongType(type, field, '配列', value);
    }
    return value;
  }

  /// リストの要素をオブジェクトとして取り出す。
  static Map<String, Object?> requireObject(
    String type,
    String field,
    Object? value,
  ) {
    if (value is! Map) {
      throw FluseProtocolException.wrongType(type, field, 'オブジェクト', value);
    }
    return <String, Object?>{
      for (final MapEntry<Object?, Object?> entry in value.entries)
        '${entry.key}': entry.value,
    };
  }
}
