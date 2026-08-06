import 'dart:io';

/// 診断の深刻度。
///
/// `frontend_server` が流す CFE のメッセージ行に現れる語をそのまま扱う。
enum DiagnosticSeverity {
  error,
  warning,
  info,

  /// 直前の診断に付随する補足行（`Context: ...`）。単独では意味を持たない。
  context;

  /// 行頭のラベルから解決する。未知のラベルは null。
  static DiagnosticSeverity? tryParse(String label) {
    final String normalized = label.trim().toLowerCase();
    for (final DiagnosticSeverity severity in values) {
      if (severity.name == normalized) {
        return severity;
      }
    }
    return null;
  }
}

/// コンパイル診断1件。
///
/// CFE は `<uri>:<line>:<col>: <Severity>: <message>` の形で出す。
/// 位置を持たない行（`Error: ...` だけ）もあるため、位置は null 許容。
final class DiagnosticEntry {
  const DiagnosticEntry({
    required this.severity,
    required this.message,
    required this.raw,
    this.file,
    this.line,
    this.column,
  });

  /// 位置情報を持たない診断。
  const DiagnosticEntry.withoutLocation({
    required this.severity,
    required this.message,
    required this.raw,
  }) : file = null,
       line = null,
       column = null;

  final DiagnosticSeverity severity;

  /// 診断本文。深刻度ラベルと位置を取り除いたもの。
  final String message;

  /// `frontend_server` が出した行そのもの。CLI に原文を出すために保持する。
  final String raw;

  /// 対象ファイル。`--filesystem-scheme` を付けた URI 文字列のまま保持する。
  final String? file;

  final int? line;
  final int? column;

  /// `file:line:col` 形式。エディタから開けるようにするための表現。
  String? get location {
    final String? path = file;
    if (path == null) {
      return null;
    }
    if (line == null) {
      return path;
    }
    return column == null ? '$path:$line' : '$path:$line:$column';
  }

  @override
  String toString() => raw;
}

/// 1回のコンパイル結果。
final class CompileOutput {
  const CompileOutput({
    required this.errorCount,
    required this.diagnostics,
    required this.sources,
    this.incrementalDill,
  });

  /// 差分 dill。DevFS へ PUT する実体。
  ///
  /// `frontend_server` が出力を返さなかった場合（`reject` の応答など）は null。
  final File? incrementalDill;

  /// `frontend_server` が報告したエラー数。
  ///
  /// **0 かどうかだけで判定すること。** 診断行の数を数えても一致しない
  /// （`Context:` の補足行が混ざるため）。
  final int errorCount;

  final List<DiagnosticEntry> diagnostics;

  /// このコンパイルが依存しているソース。`recompile` の差分計算に使う。
  final List<Uri> sources;

  bool get hasErrors => errorCount > 0;

  /// CLI に出す1行サマリ。
  String get summary =>
      hasErrors ? 'コンパイルエラー $errorCount 件' : 'コンパイル成功（${sources.length} ソース）';

  @override
  String toString() =>
      'CompileOutput(errorCount: $errorCount, '
      'dill: ${incrementalDill?.path}, sources: ${sources.length})';
}
