import 'dart:io';

import 'device_installer.dart';
import 'keystore_info.dart';
import 'preview_app_builder.dart';
import 'project_info.dart';

/// Android / iOS を横断して扱う「端末」の面（Task 10.1 / Issue #97）。
///
/// `AndroidDevice` はフィールドが `serial` / `model` のように Android 固有の
/// 語彙のままで、iOS のシミュレータ／実機を同じ形で表すことができない。
/// `DeviceInstallerContract` が platform 非依存に端末を扱えるよう、
/// 消費者（`fluse init` / `fluse devices` の CLI 層）が実際に読む3つの
/// ゲッターだけを契約として切り出す。
///
/// **フィールドもコンストラクタも持たせない。** 実装（`AndroidDevice` /
/// 後続の `IosDevice`）ごとに保持したい情報は異なる。ここでは「呼び出し側が
/// 読める形」だけを決める。
abstract interface class FluseDevice {
  /// `DeviceInstallerContract.install` に渡す識別子。
  ///
  /// Android では `adb -s` に渡す serial、iOS では `xcrun simctl` /
  /// `devicectl` が識別に使う UDID に対応する。
  String get id;

  /// 利用者が端末を選ぶ画面に出す名前。
  String get name;

  /// シミュレータ／エミュレータなら true。
  ///
  /// iOS ではシミュレータと実機で配布物の形（`.app` の Provisioning）が
  /// 変わるため、呼び出し側が分岐に使う。
  bool get isSimulator;
}

/// `PreviewAppBuilder` が持つ、`fluse init` / `fluse rebuild` から見た面。
///
/// Android の実装（`PreviewAppBuilder.build`）は署名に使う keystore を
/// 必ず要求する。iOS は Xcode の automatic signing に乗るため、
/// `KeystoreInfo` に相当する概念自体が無い。
abstract interface class PreviewAppBuilderContract {
  /// Preview App を組み立てる。
  ///
  /// **[keystore] は意図的に nullable にしている。** ここを
  /// `required KeystoreInfo keystore` にすると、iOS 版の実装
  /// （`IosPreviewAppBuilder`、Issue #99）が「持たない値」を要求される形に
  /// なり、この契約を実装できなくなる。既存の `PreviewAppBuilder.build` は
  /// Android 向けのまま `required KeystoreInfo keystore` を保ち、この契約
  /// には合わせない（Issue #98 で結線する）。
  Future<BuildResult> build({
    required ProjectInfo project,
    required File entrypoint,
    KeystoreInfo? keystore,
    String? applicationIdSuffix,
  });
}

/// `DeviceInstaller` が持つ、`fluse init` / `fluse devices` から見た面。
abstract interface class DeviceInstallerContract {
  /// 繋がっている端末の一覧。
  Future<List<FluseDevice>> listDevices();

  /// [artifact] を [device] へ入れる。
  ///
  /// **引数名は `apk` ではなく `artifact`。** Android では APK
  /// （`File`）を指すが、iOS では `.app` バンドル（`Directory`）を指す。
  /// `BuildResult.artifact`（本ファイルの extension）が返す型と揃えている。
  Future<InstallOutcome> install({
    required FluseDevice device,
    required FileSystemEntity artifact,
    required String applicationId,
    required Directory projectRoot,
  });
}

/// [BuildResult] を platform 非依存に読むための拡張（Task 10.1 / Issue #97）。
extension BuildResultArtifact on BuildResult {
  /// このビルドが作った成果物。
  ///
  /// **`FileSystemEntity` を返す。** Android の成果物は APK
  /// （`File`）だが、iOS の成果物は `.app` バンドル
  /// （`Directory`）になる。`PreviewAppBuilderContract.build` の戻り値を
  /// 両者で共通に扱えるよう、`BuildResult` 本体には触れずここで橋渡しする。
  ///
  /// **今はまだ `File` しか返らない。** 裏にいる [BuildResult.apk] が
  /// `File` のままだからで、`.app` のディレクトリを載せられるのは
  /// `IosPreviewAppBuilder`（Issue #99）で [BuildResult] を一般化して
  /// からになる。ここを先に直そうとすると
  /// `DeviceInstaller.install({required File apk})` のシグネチャまで
  /// 変えることになり、「既存の具象クラスには手を入れない」という
  /// Task 10.1 の前提が崩れる。**呼び出し側の型だけ先に広げておき、
  /// 中身は Issue #99 で入れ替える。**
  FileSystemEntity get artifact => apk;
}
