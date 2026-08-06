import 'json_reader.dart';
import 'protocol_exception.dart';

/// 診断の深刻度。
enum DiagnosticSeverity {
  error('error'),
  warning('warning'),
  info('info'),
  context('context');

  const DiagnosticSeverity(this.wireValue);

  final String wireValue;

  static DiagnosticSeverity? tryParse(String value) {
    for (final DiagnosticSeverity severity in values) {
      if (severity.wireValue == value) {
        return severity;
      }
    }
    return null;
  }
}

/// ワイヤに載せるコンパイル診断1件（設計 §2.2.1 の `CompileErrorMessage`）。
///
/// **`fluse_server` の同名クラスとは別物。** あちらは `frontend_server` の
/// 生の出力（`raw`）を保持する内部表現で、こちらは端末へ送るための
/// 最小限の形。サーバ側で変換して載せる。
final class DiagnosticEntry {
  const DiagnosticEntry({
    required this.severity,
    required this.message,
    this.file,
    this.line,
    this.col,
  });

  /// 深刻度。既知の語彙のみを載せる。
  final DiagnosticSeverity severity;

  /// 本文。
  final String message;

  /// 対象ファイル。位置を持たない診断では null。
  final String? file;

  final int? line;
  final int? col;

  /// `file:line:col` 形式。エディタから開けるようにするための表現。
  String? get location {
    final String? path = file;
    if (path == null) {
      return null;
    }
    if (line == null) {
      return path;
    }
    return col == null ? '$path:$line' : '$path:$line:$col';
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'severity': severity.wireValue,
    'message': message,
    if (file != null) 'file': file,
    if (line != null) 'line': line,
    if (col != null) 'col': col,
  };

  static DiagnosticEntry fromJson(Map<String, Object?> json) {
    const String type = 'DiagnosticEntry';
    final JsonReader reader = JsonReader(json);

    final String rawSeverity = reader.requireString(type, 'severity');
    final DiagnosticSeverity? severity = DiagnosticSeverity.tryParse(
      rawSeverity,
    );
    if (severity == null) {
      // 深刻度が分からないとオーバーレイの出し分けができない。
      // 黙って error に丸めると、警告で赤画面になる。
      throw FluseProtocolException('$type: 未知の severity: $rawSeverity');
    }

    return DiagnosticEntry(
      severity: severity,
      message: reader.requireString(type, 'message'),
      file: reader.optionalString(type, 'file'),
      line: reader.optionalInt(type, 'line'),
      col: reader.optionalInt(type, 'col'),
    );
  }

  @override
  String toString() => location == null ? message : '$location: $message';
}
