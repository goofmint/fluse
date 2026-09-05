import 'device_store.dart';

/// [SessionManager] が使う `DeviceStore` の面。
///
/// 実装は `final class` でファイルを持つ。認証のテストまで実 I/O に
/// 巻き込まれないよう、必要な操作だけを契約として切り出す。
abstract interface class DeviceStoreContract {
  /// 登録済みの端末。無ければ null。
  DeviceRecord? lookup(String deviceId);

  /// 登録または上書きして永続化する。
  void upsert(DeviceRecord record);

  /// 登録を消して永続化する。
  void remove(String deviceId);
}
