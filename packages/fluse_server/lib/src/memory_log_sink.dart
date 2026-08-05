import 'fluse_logger.dart';

/// 書かれた行をメモリに保持する [FluseLogSink]。
///
/// ログ出力の検証に使う。ファイルを作らずに済むため、テストが並列に
/// 走っても互いに干渉しない。
final class MemoryLogSink implements FluseLogSink {
  final List<String> lines = <String>[];

  @override
  void writeLine(String line) => lines.add(line);

  @override
  Future<void> close() async {}
}
