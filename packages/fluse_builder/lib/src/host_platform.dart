import 'dart:ffi' show Abi;
import 'dart:io' show Platform;

/// Flutter SDK のエンジン成果物ディレクトリを表すホストプラットフォーム。
///
/// `bin/cache/artifacts/engine/<name>/` の `<name>` に対応する。
/// 命名は flutter_tools の `getNameForHostPlatform`
/// （`packages/flutter_tools/lib/src/base/os.dart`）に合わせてある。
enum HostPlatform {
  darwinX64('darwin-x64'),
  darwinArm64('darwin-arm64'),
  linuxX64('linux-x64'),
  linuxArm64('linux-arm64'),
  windowsX64('windows-x64'),
  windowsArm64('windows-arm64');

  const HostPlatform(this.directoryName);

  /// `bin/cache/artifacts/engine/` 配下のディレクトリ名。
  final String directoryName;

  /// 実行中のホストを判定する。
  ///
  /// [operatingSystem] と [abi] はテストのために差し替えられる。既定では
  /// `Platform.operatingSystem` と `Abi.current()` を使う。
  ///
  /// 未対応の OS では [UnsupportedHostPlatformException] を投げる。
  /// 黙って既定値に落とすと、存在しないパスを指したまま先へ進んでしまい、
  /// 原因の分からない失敗になるため。
  static HostPlatform resolve({String? operatingSystem, Abi? abi}) {
    final String os = operatingSystem ?? Platform.operatingSystem;
    final Abi currentAbi = abi ?? Abi.current();
    final bool isArm64 = _arm64Abis.contains(currentAbi);

    return switch (os) {
      'macos' => isArm64 ? HostPlatform.darwinArm64 : HostPlatform.darwinX64,
      'linux' => isArm64 ? HostPlatform.linuxArm64 : HostPlatform.linuxX64,
      'windows' =>
        isArm64 ? HostPlatform.windowsArm64 : HostPlatform.windowsX64,
      _ => throw UnsupportedHostPlatformException(os),
    };
  }

  /// エンジン成果物が実際に置かれているディレクトリ名の候補を、
  /// 優先順に返す。
  ///
  /// Apple Silicon では**ホストは `darwin-arm64` だが、エンジン成果物は
  /// `darwin-x64` に置かれる**ことがある。flutter_tools 自身も
  /// `artifacts.dart` で `darwin_arm64` を `darwin_x64` に読み替えている
  /// （Android 向け gen_snapshot が x64 バイナリのままであるため）。
  /// どちらが存在するかは SDK のバージョンとダウンロード状況で変わるので、
  /// 呼び出し側が実在するものを選べるように候補を返す。
  List<String> get engineDirectoryCandidates => switch (this) {
    HostPlatform.darwinArm64 => <String>[directoryName, 'darwin-x64'],
    _ => <String>[directoryName],
  };

  static const Set<Abi> _arm64Abis = <Abi>{
    Abi.macosArm64,
    Abi.linuxArm64,
    Abi.windowsArm64,
    Abi.androidArm64,
    Abi.iosArm64,
  };
}

/// 対応していないホスト OS で実行された場合に投げる。
final class UnsupportedHostPlatformException implements Exception {
  const UnsupportedHostPlatformException(this.operatingSystem);

  /// `Platform.operatingSystem` の値。
  final String operatingSystem;

  @override
  String toString() =>
      'fluse は $operatingSystem に対応していません。'
      '対応しているのは macOS / Linux / Windows です。';
}
