import 'compile_output.dart';
import 'dev_fs_client.dart';
import 'vm_service_client.dart';

/// [HotReloadOrchestrator] が使う `CompilerService` の面。
///
/// 実装は `final class` なのでテストから差し替えられない。
/// オーケストレータが必要とする分だけを契約として切り出す。
abstract interface class CompilerContract {
  /// 差分コンパイルする。
  Future<CompileOutput> recompile(Uri mainUri, List<Uri> invalidated);

  /// reload が成功したことを伝える。
  ///
  /// **失敗時に呼んではいけない**（設計 §10-2）。
  void accept();

  /// reload が失敗したことを伝える。
  Future<CompileOutput?> reject();

  /// `accept` / `reject` の応答待ちかどうか。
  bool get needsConfirmation;
}

/// [HotReloadOrchestrator] が使う `DevFSClient` の面。
abstract interface class DevFSWriterContract {
  /// まとめて DevFS に書き込む。
  Future<void> writeAll(Map<Uri, DevFSContent> entries);
}

/// [HotReloadOrchestrator] が使う `VmServiceClient` の面。
abstract interface class VmServiceContract {
  /// メイン isolate を特定する。
  Future<String> findMainIsolateId();

  /// 差分を反映する。
  Future<ReloadResult> reloadSources(
    String isolateId, {
    String? rootLibUri,
    String? packagesUri,
  });

  /// 画像キャッシュから asset を追い出す。
  Future<void> evict(String isolateId, String assetPath);

  /// ウィジェットツリーを作り直す。
  Future<void> reassemble(String isolateId);
}
