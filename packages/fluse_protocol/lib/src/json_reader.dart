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

  /// 必須の整数。
  ///
  /// JSON の数値は `double` で来ることがある（`1.0` など）。整数として
  /// 表せる場合だけ受け入れる。丸めると別の値になってしまうため。
  int requireInt(String type, String field) {
    final Object? value = json[field];
    if (value == null) {
      throw FluseProtocolException.missingField(type, field);
    }
    if (value is int) {
      return value;
    }
    if (value is double && value == value.roundToDouble() && value.isFinite) {
      return value.toInt();
    }
    throw FluseProtocolException.wrongType(type, field, '整数', value);
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
