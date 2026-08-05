/// テストから使うための差し替え実装。
///
/// 本番コードの依存に混ざらないよう、`fluse_server.dart` とは別の
/// エントリポイントに分けてある。利用側は
/// `import 'package:fluse_server/testing.dart';` で取り込む。
library;

export 'src/fake_process_manager.dart'
    show FakeProcess, FakeProcessManager, UnregisteredProcessException;
export 'src/memory_log_sink.dart' show MemoryLogSink;
