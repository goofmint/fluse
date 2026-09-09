import 'dart:io';

import 'android_device.dart';
import 'builder_contracts.dart';
import 'device_installer.dart';

/// [AndroidDevice] を [FluseDevice] として見せるための包み紙
/// （Task 10.2 / Issue #98）。
///
/// `AndroidDevice` 自体は変えない。`implements FluseDevice` を足すと
/// `fluse_builder` の外（iOS 側の実装が来る Issue #99 より前）から
/// Android 固有の語彙（`serial` / `model`）が契約の一部に見えてしまう。
final class _WrappedAndroidDevice implements FluseDevice {
  const _WrappedAndroidDevice(this.device);

  /// 包んだ元の値。[AndroidDeviceInstaller.install] で取り出す。
  final AndroidDevice device;

  @override
  String get id => device.serial;

  @override
  String get name => device.label;

  /// **常に false。** `adb devices -l` は実機とエミュレータを区別する
  /// フィールドを返さない（`AndroidDevice` にも持たせていない）。
  /// `emulator-5554` のような serial から推測することもできなくはないが、
  /// 実機の serial が偶然その形式に一致しない保証が無く、当てずっぽうの
  /// 判定になる。分からないものは「わかる」ふりをせず false で揃える。
  @override
  bool get isSimulator => false;
}

/// [DeviceInstaller] を [DeviceInstallerContract] へ嵌めるアダプタ
/// （Task 10.2 / Issue #98）。
///
/// **`DeviceInstaller` 本体は一切変えない。** adb を叩く実装は動作確認済み
/// で、ここでは型を契約に合わせるだけに徹する。
final class AndroidDeviceInstaller implements DeviceInstallerContract {
  const AndroidDeviceInstaller(this._delegate);

  final DeviceInstaller _delegate;

  @override
  Future<List<FluseDevice>> listDevices() async {
    final List<AndroidDevice> devices = await _delegate.listDevices();
    return <FluseDevice>[
      for (final AndroidDevice device in devices) _WrappedAndroidDevice(device),
    ];
  }

  @override
  Future<InstallOutcome> install({
    required FluseDevice device,
    required FileSystemEntity artifact,
    required String applicationId,
    required Directory projectRoot,
  }) {
    // **このアダプタが作った包み紙でなければ弾く。** iOS 側の `FluseDevice`
    // 実装が紛れ込んだまま `adb -s <id>` へ渡すと、存在しない serial として
    // 静かに失敗するか、たまたま一致した別の端末を書き換えかねない。
    if (device is! _WrappedAndroidDevice) {
      throw ArgumentError.value(
        device,
        'device',
        'AndroidDeviceInstaller が返した FluseDevice ではありません',
      );
    }

    // Android の成果物は APK（File）だけ。iOS の `.app`（Directory）が
    // 来た場合は `DeviceInstaller.install` の `required File apk` に
    // 合わず、ここで意味を説明した上で止める。
    if (artifact is! File) {
      throw ArgumentError.value(
        artifact,
        'artifact',
        'Android のインストールには File（APK）が要ります',
      );
    }

    // **`InstallOutcome` はそのまま返す。** `Installed.device` は
    // `AndroidDevice` のままにしておかないと、CLI 側が読んでいる
    // `outcome.device.label` が失われる（builder_contracts.dart 側は
    // まだ変換先を持たない）。
    return _delegate.install(
      device: device.device,
      apk: artifact,
      applicationId: applicationId,
      projectRoot: projectRoot,
    );
  }
}
