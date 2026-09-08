import 'dart:io';

import 'android_device.dart';
import 'builder_contracts.dart';
import 'device_installer.dart';

/// [DeviceInstaller]（Android 具象）を [DeviceInstallerContract] へ
/// 嵌めるアダプタ（Task 10.2 / Issue #98）。
///
/// **委譲するだけ。** `DeviceInstaller` 本体には一切手を入れない。
final class AndroidDeviceInstaller implements DeviceInstallerContract {
  const AndroidDeviceInstaller(this._delegate);

  /// 実際に `adb` を叩く既存の具象クラス。
  final DeviceInstaller _delegate;

  /// `List<AndroidDevice>` は `List<FluseDevice>` の部分型なので、
  /// 変換せずそのまま返せる。
  @override
  Future<List<FluseDevice>> listDevices() => _delegate.listDevices();

  @override
  Future<InstallOutcome> install({
    required FluseDevice device,
    required FileSystemEntity artifact,
    required String applicationId,
    required Directory projectRoot,
  }) async {
    // **素の `as` キャスト例外を見せない。** 型が合わない呼び出しは
    // プログラミングミス（別プラットフォームの端末/成果物を渡した等）
    // なので、何が起きたかが分かる形で弾く。
    //
    // **`async` にして throw を Future の中へ入れる。** 同期に投げると、
    // 引数の評価段階でそのまま外へ抜けてしまい、呼び出し側の `try`/`await`
    // の組み方によっては拾い損ねる。
    if (device is! AndroidDevice) {
      throw ArgumentError.value(
        device,
        'device',
        'AndroidDeviceInstaller は AndroidDevice しか扱えません '
            '（渡されたのは ${device.runtimeType}）',
      );
    }
    if (artifact is! File) {
      throw ArgumentError.value(
        artifact,
        'artifact',
        'AndroidDeviceInstaller は File（APK）しか扱えません '
            '（渡されたのは ${artifact.runtimeType}）',
      );
    }

    // `DeviceInstaller.install` が返す `Installed.device` は既に
    // `FluseDevice` 型（Issue #98 で widen 済み）なので、変換せず
    // そのまま返せる。
    return _delegate.install(
      device: device,
      apk: artifact,
      applicationId: applicationId,
      projectRoot: projectRoot,
    );
  }
}
