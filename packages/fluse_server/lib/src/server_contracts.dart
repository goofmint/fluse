import 'dev_fs_client.dart';
import 'reload_contracts.dart';

/// `ServerRuntime` が使う `TunnelEndpoint` の面。
///
/// 実装は `final class` なのでテストから差し替えられない。統合の側が
/// 必要とする分だけを契約として切り出す。
abstract interface class TunnelContract {
  /// localhost に待ち受けを立て、VM Service として振る舞う URI を返す。
  Future<Uri> bind(String remoteVmServiceUri);

  /// 待ち受けと全ストリームを閉じる。
  Future<void> close();

  /// トンネルが終わったら完了する。
  Future<void> get done;
}

/// `ServerRuntime` が使う `VmServiceClient` の面。
///
/// [VmServiceContract]（リロードに要る分）に、セッションの開始と終了で
/// 使う操作を足したもの。
abstract interface class SessionVmServiceContract implements VmServiceContract {
  /// VM Service の HTTP ルート。DevFS の PUT 先になる。
  Uri get httpAddress;

  /// DevFS を作る。
  Future<Uri> createDevFS(String fsName);

  /// DevFS を消す。
  Future<void> deleteDevFS(String fsName);

  /// 描画中の View の一覧。[setAssetDirectory] に渡すために要る。
  Future<List<({String viewId, String? isolateId})>> listViews();

  /// asset の置き場所を端末へ教える。
  Future<void> setAssetDirectory({
    required String viewId,
    required String? isolateId,
    required Uri assetsDirectory,
  });

  /// 接続を閉じる。
  Future<void> dispose();
}

/// `ServerRuntime` が使う `DevFSClient` の面。
///
/// [DevFSWriterContract]（転送だけ）に、DevFS の作成と破棄を足したもの。
abstract interface class DevFSContract implements DevFSWriterContract {
  /// 作成済み DevFS の名前。未作成なら null。
  String? get fsName;

  /// 作成済み DevFS のベース URI。未作成なら null。
  Uri? get baseUri;

  /// DevFS を作る。
  Future<Uri> create(String fsName);

  /// DevFS を消す。
  Future<void> destroy();

  /// HTTP クライアントを閉じる。
  void close();
}

/// 未使用の import を避けるためのタイプエイリアス。
///
/// [DevFSWriterContract.writeAll] が受ける値の型。契約を読む側が
/// `dev_fs_client.dart` を辿らずに済むようにしておく。
typedef DevFSPayload = DevFSContent;
