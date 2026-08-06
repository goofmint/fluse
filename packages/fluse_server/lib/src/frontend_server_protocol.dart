import 'compile_output.dart';

/// `frontend_server` の stdout を解釈する状態機械。
///
/// プロトコルは次の形（flutter_tools の `StdoutHandler` と同一）。
///
/// ```text
/// result <boundaryKey>
/// <診断行>...
/// <boundaryKey>                       ← ここから依存ソースの列挙
/// +<uri>
/// -<uri>
/// <boundaryKey> <outputPath> <errorCount>
/// ```
///
/// 最後の行が `<boundaryKey>` だけの場合は「出力なし」を意味する。
/// `reject` の応答のように依存ソースを列挙しない応答もあるため、
/// [expectSources] で切り替える。
final class FrontendServerOutputParser {
  FrontendServerOutputParser({this.expectSources = true});

  /// 依存ソースの列挙（`+uri` / `-uri`）を伴う応答か。
  ///
  /// `compile` / `recompile` は true、`reject` は false。
  final bool expectSources;

  String? _boundaryKey;
  _ParserState _state = _ParserState.collectDiagnostics;
  final List<String> _diagnosticLines = <String>[];
  final List<Uri> _sources = <Uri>[];
  FrontendServerResult? _result;

  /// 結果が確定していれば返す。まだなら null。
  FrontendServerResult? get result => _result;

  /// 応答が完了したか。
  bool get isComplete => _result != null;

  /// stdout の1行を食わせる。
  void addLine(String line) {
    if (_result != null) {
      return;
    }

    const String resultPrefix = 'result ';
    final String? boundaryKey = _boundaryKey;
    if (boundaryKey == null) {
      if (line.startsWith(resultPrefix)) {
        _boundaryKey = line.substring(resultPrefix.length);
      }
      // `result` 行より前の出力は応答に属さないので捨てる。
      return;
    }

    if (line.startsWith(boundaryKey)) {
      _handleBoundary(line, boundaryKey);
      return;
    }

    switch (_state) {
      case _ParserState.collectDiagnostics:
        _diagnosticLines.add(line);
      case _ParserState.collectSources:
        _addSource(line);
    }
  }

  void _handleBoundary(String line, String boundaryKey) {
    if (expectSources && _state == _ParserState.collectDiagnostics) {
      _state = _ParserState.collectSources;
      return;
    }

    if (line.length <= boundaryKey.length) {
      // 出力なし。エラー数も分からないので 0 とする。
      _result = FrontendServerResult(
        outputPath: null,
        errorCount: 0,
        diagnostics: parseDiagnostics(_diagnosticLines),
        sources: List<Uri>.unmodifiable(_sources),
      );
      return;
    }

    // `<boundaryKey> <outputPath> <errorCount>`。
    // outputPath に空白が含まれうるので、区切りは最後の空白で取る。
    final int lastSpace = line.lastIndexOf(' ');
    if (lastSpace <= boundaryKey.length) {
      // `<key> <outputPath>` のようにエラー数が無い形。
      throw FormatException('frontend_server の境界行を解釈できません', line);
    }
    final String outputPath = line.substring(boundaryKey.length + 1, lastSpace);
    final int? errorCount = int.tryParse(line.substring(lastSpace + 1).trim());
    if (errorCount == null || errorCount < 0) {
      // 0 に落とすとコンパイル成功として扱われ、エラーを含む dill が
      // DevFS 転送と reloadSources に流れる。負数も同様に hasErrors を
      // false にしてしまうため、どちらも必ず表面化させる。
      throw FormatException('frontend_server のエラー数を解釈できません', line);
    }

    _result = FrontendServerResult(
      outputPath: outputPath,
      errorCount: errorCount,
      diagnostics: parseDiagnostics(_diagnosticLines),
      sources: List<Uri>.unmodifiable(_sources),
    );
  }

  void _addSource(String line) {
    if (line.isEmpty) {
      return;
    }
    switch (line[0]) {
      case '+':
        _sources.add(Uri.parse(line.substring(1)));
      case '-':
        _sources.remove(Uri.parse(line.substring(1)));
      default:
      // 想定外の接頭辞。壊れた応答として扱わず読み飛ばす。
    }
  }

  /// `<uri>:<line>:<col>: <Severity>: <message>` を切り出す。
  ///
  /// URI にコロンが含まれる（`org-dartlang-root:///lib/main.dart`）ため、
  /// 素朴な split では分解できない。行末側から数字2つを探す。
  static final RegExp _locatedDiagnostic = RegExp(
    r'^(.*):(\d+):(\d+): (Error|Warning|Info|Context): (.*)$',
  );

  static final RegExp _unlocatedDiagnostic = RegExp(
    r'^(Error|Warning|Info|Context): (.*)$',
  );

  /// 診断行の列を [DiagnosticEntry] に変換する。
  ///
  /// 深刻度ラベルを持たない行（前の診断の続き）は、直前の診断の
  /// 本文に連結する。単独の行として出すと CLI で文脈が失われるため。
  static List<DiagnosticEntry> parseDiagnostics(List<String> lines) {
    final List<DiagnosticEntry> entries = <DiagnosticEntry>[];

    for (final String line in lines) {
      if (line.trim().isEmpty) {
        continue;
      }

      final DiagnosticEntry? parsed = _parseDiagnosticLine(line);
      if (parsed != null) {
        entries.add(parsed);
        continue;
      }

      if (entries.isEmpty) {
        // ラベルを持たない先頭行。深刻度が分からないので info 扱いにする。
        entries.add(
          DiagnosticEntry.withoutLocation(
            severity: DiagnosticSeverity.info,
            message: line,
            raw: line,
          ),
        );
        continue;
      }

      // ソース抜粋やキャレット行。直前の診断に属する。
      entries.add(_appendLine(entries.removeLast(), line));
    }

    return List<DiagnosticEntry>.unmodifiable(entries);
  }

  /// 深刻度ラベルを持つ行を解釈する。持たなければ null。
  static DiagnosticEntry? _parseDiagnosticLine(String line) {
    final RegExpMatch? located = _locatedDiagnostic.firstMatch(line);
    if (located != null) {
      final DiagnosticSeverity? severity = _severityOf(located, 4);
      if (severity != null) {
        return DiagnosticEntry(
          severity: severity,
          message: located.group(5) ?? '',
          raw: line,
          file: located.group(1),
          line: int.tryParse(located.group(2) ?? ''),
          column: int.tryParse(located.group(3) ?? ''),
        );
      }
    }

    final RegExpMatch? unlocated = _unlocatedDiagnostic.firstMatch(line);
    if (unlocated != null) {
      final DiagnosticSeverity? severity = _severityOf(unlocated, 1);
      if (severity != null) {
        return DiagnosticEntry.withoutLocation(
          severity: severity,
          message: unlocated.group(2) ?? '',
          raw: line,
        );
      }
    }

    return null;
  }

  static DiagnosticSeverity? _severityOf(RegExpMatch match, int group) {
    final String? label = match.group(group);
    return label == null ? null : DiagnosticSeverity.tryParse(label);
  }

  /// 継続行を直前の診断に連結した新しい診断を返す。
  static DiagnosticEntry _appendLine(DiagnosticEntry previous, String line) =>
      DiagnosticEntry(
        severity: previous.severity,
        message: '${previous.message}\n$line',
        raw: '${previous.raw}\n$line',
        file: previous.file,
        line: previous.line,
        column: previous.column,
      );
}

/// 解析結果。[CompileOutput] への変換は呼び出し側が行う
/// （`outputPath` を [File] にするかどうかを決めるため）。
final class FrontendServerResult {
  const FrontendServerResult({
    required this.outputPath,
    required this.errorCount,
    required this.diagnostics,
    required this.sources,
  });

  final String? outputPath;
  final int errorCount;
  final List<DiagnosticEntry> diagnostics;
  final List<Uri> sources;
}

enum _ParserState { collectDiagnostics, collectSources }
