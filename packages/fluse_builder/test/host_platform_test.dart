import 'dart:ffi' show Abi;

import 'package:fluse_builder/fluse_builder.dart';
import 'package:test/test.dart';

void main() {
  group('HostPlatform.resolve', () {
    const List<(String os, Abi abi, HostPlatform expected)> cases =
        <(String, Abi, HostPlatform)>[
          ('macos', Abi.macosArm64, HostPlatform.darwinArm64),
          ('macos', Abi.macosX64, HostPlatform.darwinX64),
          ('linux', Abi.linuxArm64, HostPlatform.linuxArm64),
          ('linux', Abi.linuxX64, HostPlatform.linuxX64),
          ('windows', Abi.windowsArm64, HostPlatform.windowsArm64),
          ('windows', Abi.windowsX64, HostPlatform.windowsX64),
        ];

    for (final (String os, Abi abi, HostPlatform expected) in cases) {
      test('$os / $abi -> ${expected.directoryName}', () {
        expect(HostPlatform.resolve(operatingSystem: os, abi: abi), expected);
      });
    }

    test('未対応の OS は例外になる', () {
      // 黙って既定値に落とすと、存在しないパスを指したまま先へ進んでしまう。
      expect(
        () =>
            HostPlatform.resolve(operatingSystem: 'fuchsia', abi: Abi.linuxX64),
        throwsA(
          isA<UnsupportedHostPlatformException>().having(
            (UnsupportedHostPlatformException e) => e.toString(),
            'message',
            contains('fuchsia'),
          ),
        ),
      );
    });

    test('引数を省略すると実行中のホストを返す', () {
      // 値そのものは環境依存なので、例外なく解決できることだけ見る。
      expect(HostPlatform.resolve().directoryName, isNotEmpty);
    });
  });

  group('engineDirectoryCandidates', () {
    test('darwin-arm64 は darwin-x64 も候補にする', () {
      // Apple Silicon でもエンジン成果物が darwin-x64 に置かれることがある。
      expect(HostPlatform.darwinArm64.engineDirectoryCandidates, <String>[
        'darwin-arm64',
        'darwin-x64',
      ]);
    });

    test('他のホストは自分のディレクトリのみ', () {
      expect(HostPlatform.linuxX64.engineDirectoryCandidates, <String>[
        'linux-x64',
      ]);
      expect(HostPlatform.windowsX64.engineDirectoryCandidates, <String>[
        'windows-x64',
      ]);
      expect(HostPlatform.darwinX64.engineDirectoryCandidates, <String>[
        'darwin-x64',
      ]);
    });
  });
}
