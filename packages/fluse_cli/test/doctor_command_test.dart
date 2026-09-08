import 'dart:io';

import 'package:fluse_builder/fluse_builder.dart';
import 'package:fluse_cli/fluse_cli.dart';
import 'package:fluse_server/fluse_server.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'steps.dart';

void main() {
  late Directory temp;
  late Steps steps;
  late List<String> output;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('fluse_doctor_');
    steps = Steps(temp);
    output = <String>[];
    createProject(temp);
    // 整った環境を作ってから壊す。**個々のファイルを手で置かない。**
    // `init` が実際に残す形と食い違うと、検査が通っても意味が無い。
    expect(await _runInit(temp, steps), 0);
  });

  tearDown(() {
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  FluseContext context({
    FluseTargetPlatform platform = FluseTargetPlatform.android,
  }) => FluseContext.of(
    projectRoot: temp,
    config: FluseConfig(platform: platform),
    sdk: _sdk,
    logger: FluseLogger(sinks: const <FluseLogSink>[]),
    processManager: steps,
  );

  FluseContext brokenSdkContext() => FluseContext.withoutSdk(
    projectRoot: temp,
    config: const FluseConfig(),
    sdkError: const SdkNotFoundException.rootNotFound(
      reason: 'PATH に flutter がありません',
    ),
    logger: FluseLogger(sinks: const <FluseLogSink>[]),
    processManager: steps,
  );

  Future<int> runDoctor({
    FluseContext? on,
    Future<void> Function(int port)? probePort,
  }) {
    final DoctorCommand command = DoctorCommand(
      onOutput: output.add,
      probePort: probePort ?? (int _) async {},
      isWindows: false,
    );
    return command.run(
      command.argParser.parse(const <String>[]),
      on ?? context(),
    );
  }

  String text() => output.join('\n');

  group('整った環境', () {
    test('全部通って 0 で終わる', () async {
      expect(await runDoctor(), 0);

      expect(text(), contains('問題はありません'));
      expect(text(), isNot(contains('✗')));
    });

    test('見るものを全部見ている', () async {
      await runDoctor();

      for (final String name in <String>[
        'Flutter SDK',
        'adb',
        'keytool',
        'ポート 8180',
        'cache/fingerprint.json',
        'cache/build_meta.json',
        'build/preview.apk',
        'keystore',
        'devices.json',
      ]) {
        expect(text(), contains(name), reason: '$name を見ていない');
      }
    });
  });

  group('壊れた環境', () {
    test('SDK を解決できなければ SDK_NOT_FOUND を出す', () async {
      expect(await runDoctor(on: brokenSdkContext()), 1);

      expect(text(), contains('SDK_NOT_FOUND'));
      expect(text(), contains('PATH に flutter がありません'));
      // **他の検査は続ける。** 1つ落ちるたびに直しては再実行、では困る。
      expect(text(), contains('build/preview.apk'));
    });

    test('adb が無ければ指摘する', () async {
      steps.adbAvailable = false;

      expect(await runDoctor(), 1);

      expect(text(), contains('✗ adb'));
    });

    test('ポートが塞がっていれば指摘する', () async {
      expect(
        await runDoctor(
          probePort: (int port) async => throw const SocketException('使われています'),
        ),
        1,
      );

      expect(text(), contains('✗ ポート 8180'));
    });

    test('.flutter_preview が無ければ init へ誘導する', () async {
      Directory(
        p.join(temp.path, '.flutter_preview'),
      ).deleteSync(recursive: true);

      expect(await runDoctor(), 1);

      expect(text(), contains('fluse init'));
    });

    test('指紋が壊れていれば指摘する', () async {
      File(
        p.join(temp.path, '.flutter_preview', 'cache', 'fingerprint.json'),
      ).writeAsStringSync('{壊れている');

      expect(await runDoctor(), 1);

      expect(text(), contains('✗ cache/fingerprint.json'));
    });

    test('build_meta が壊れていれば指摘する', () async {
      File(
        p.join(temp.path, '.flutter_preview', 'cache', 'build_meta.json'),
      ).writeAsStringSync('{壊れている');

      expect(await runDoctor(), 1);

      expect(text(), contains('✗ cache/build_meta.json'));
    });

    test('APK が無ければ指摘する', () async {
      File(
        p.join(temp.path, '.flutter_preview', 'build', 'preview.apk'),
      ).deleteSync();

      expect(await runDoctor(), 1);

      expect(text(), contains('✗ build/preview.apk'));
    });

    test('keystore が片側だけなら指摘する', () async {
      File(
        p.join(temp.path, '.flutter_preview', 'keystore', 'keystore.json'),
      ).deleteSync();

      expect(await runDoctor(), 1);

      expect(text(), contains('✗ keystore'));
      expect(text(), contains('keystore.json'));
    });

    test('keystore.json を誰でも読めれば指摘する', () async {
      final File file = File(
        p.join(temp.path, '.flutter_preview', 'keystore', 'keystore.json'),
      );
      expect(Process.runSync('chmod', <String>['644', file.path]).exitCode, 0);

      expect(await runDoctor(), 1);

      expect(text(), contains('644'));
      // Windows に POSIX のパーミッションは無く、`chmod` も無い。
    }, skip: Platform.isWindows ? 'POSIX のパーミッションが無い' : null);

    test('実際に塞がっているポートを見つける', () async {
      // **注入した bind だけで済ませない。** 既定の実装が本当に
      // 塞がりを見つけられるかは、実際に掴んでみないと分からない。
      // 検査と同じ範囲で掴む。macOS では 127.0.0.1 と 0.0.0.0 が
      // ぶつからないため、loopback で掴んでも見つからない。
      final ServerSocket held = await ServerSocket.bind(
        InternetAddress.anyIPv4,
        0,
      );
      addTearDown(held.close);

      final DoctorCommand command = DoctorCommand(
        onOutput: output.add,
        isWindows: false,
      );
      final int code = await command.run(
        command.argParser.parse(const <String>[]),
        FluseContext.of(
          projectRoot: temp,
          config: FluseConfig(port: held.port),
          sdk: _sdk,
          logger: FluseLogger(sinks: const <FluseLogSink>[]),
          processManager: steps,
        ),
      );

      expect(code, 1);
      expect(text(), contains('✗ ポート ${held.port}'));
    });

    test('SDK が無い入れ物で sdk を読めば元の例外が出る', () {
      // **代わりの SDK を返さない。** 別の版でビルドされる方が困る。
      expect(
        () => brokenSdkContext().sdk,
        throwsA(isA<SdkNotFoundException>()),
      );
    });

    test('devices.json が壊れていれば指摘する', () async {
      File(
        p.join(temp.path, '.flutter_preview', 'devices.json'),
      ).writeAsStringSync('{壊れている');

      expect(await runDoctor(), 1);

      expect(text(), contains('✗ devices.json'));
    });
  });

  group('iOS のとき', () {
    test('adb / keytool の検査が出ない', () async {
      _writeInfoPlist(temp, hasUsageKey: true, hasAllowsLocalNetworking: true);

      await runDoctor(on: context(platform: FluseTargetPlatform.ios));

      expect(text(), isNot(contains('adb')));
      expect(text(), isNot(contains('keytool')));
    });

    test('iOS 用の検査が並ぶ', () async {
      _writeInfoPlist(temp, hasUsageKey: true, hasAllowsLocalNetworking: true);

      final int code = await runDoctor(
        on: context(platform: FluseTargetPlatform.ios),
      );

      expect(code, 0, reason: text());
      for (final String name in <String>[
        'Xcode',
        'xcrun devicectl',
        'ios/',
        'Info.plist: NSLocalNetworkUsageDescription',
        'Info.plist: NSAllowsLocalNetworking',
        'pod',
        // iOS でも Flutter SDK / ポート / .flutter_preview は共通で見る。
        'Flutter SDK',
        'ポート 8180',
      ]) {
        expect(text(), contains(name), reason: '$name を見ていない');
      }
    });

    test('xcode-select が Command Line Tools のままなら切り替え方を案内する', () async {
      _writeInfoPlist(temp, hasUsageKey: true, hasAllowsLocalNetworking: true);
      steps.xcodeSelectPath = '/Library/Developer/CommandLineTools';

      expect(
        await runDoctor(on: context(platform: FluseTargetPlatform.ios)),
        1,
      );

      expect(text(), contains('✗ Xcode'));
      expect(text(), contains('CommandLineTools'));
      expect(
        text(),
        contains(
          'sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer',
        ),
      );
    });

    test('xcrun devicectl が無ければ指摘する', () async {
      _writeInfoPlist(temp, hasUsageKey: true, hasAllowsLocalNetworking: true);
      steps.devicectlAvailable = false;

      expect(
        await runDoctor(on: context(platform: FluseTargetPlatform.ios)),
        1,
      );

      expect(text(), contains('✗ xcrun devicectl'));
    });

    test('ios/ が無ければ指摘する', () async {
      expect(
        await runDoctor(on: context(platform: FluseTargetPlatform.ios)),
        1,
      );

      expect(text(), contains('✗ ios/'));
      expect(text(), contains('flutter create --platforms=ios .'));
    });

    test('Info.plist に NSLocalNetworkUsageDescription が無ければ指摘する', () async {
      _writeInfoPlist(temp, hasUsageKey: false, hasAllowsLocalNetworking: true);

      expect(
        await runDoctor(on: context(platform: FluseTargetPlatform.ios)),
        1,
      );

      expect(text(), contains('✗ Info.plist: NSLocalNetworkUsageDescription'));
      expect(text(), contains('LAN の WebSocket に繋がりません'));
      // もう片方は揃っている。
      expect(text(), contains('✓ Info.plist: NSAllowsLocalNetworking'));
    });

    test('Info.plist に NSAllowsLocalNetworking が無ければ指摘する', () async {
      _writeInfoPlist(temp, hasUsageKey: true, hasAllowsLocalNetworking: false);

      expect(
        await runDoctor(on: context(platform: FluseTargetPlatform.ios)),
        1,
      );

      expect(text(), contains('✗ Info.plist: NSAllowsLocalNetworking'));
      expect(text(), contains('LAN の WebSocket に繋がりません'));
      expect(text(), contains('✓ Info.plist: NSLocalNetworkUsageDescription'));
    });

    test('Info.plist 自体が無ければ両方を指摘する', () async {
      expect(
        await runDoctor(on: context(platform: FluseTargetPlatform.ios)),
        1,
      );

      expect(text(), contains('✗ Info.plist: NSLocalNetworkUsageDescription'));
      expect(text(), contains('✗ Info.plist: NSAllowsLocalNetworking'));
    });
  });
}

/// `ios/Runner/Info.plist` を演じる。
///
/// [hasUsageKey] / [hasAllowsLocalNetworking] を false にすると、
/// 該当のキーだけを落とした plist を書く。**`ios/` 自体は必ず作る。**
/// `ios/` の有無は別の検査（`_checkIosDir`）が担うため、ここで
/// 混ぜない。
void _writeInfoPlist(
  Directory root, {
  required bool hasUsageKey,
  required bool hasAllowsLocalNetworking,
}) {
  final File file = File(p.join(root.path, 'ios', 'Runner', 'Info.plist'));
  file.parent.createSync(recursive: true);

  final StringBuffer buffer = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln('<plist version="1.0">')
    ..writeln('<dict>');
  if (hasUsageKey) {
    buffer
      ..writeln('  <key>NSLocalNetworkUsageDescription</key>')
      ..writeln('  <string>fluse の LAN 内ホットリロードに使います</string>');
  }
  buffer.writeln('  <key>NSAppTransportSecurity</key>');
  buffer.writeln('  <dict>');
  if (hasAllowsLocalNetworking) {
    buffer
      ..writeln('    <key>NSAllowsLocalNetworking</key>')
      ..writeln('    <true/>');
  }
  buffer
    ..writeln('  </dict>')
    ..writeln('</dict>')
    ..writeln('</plist>');

  file.writeAsStringSync(buffer.toString());
}

const FlutterSdk _sdk = FlutterSdk(
  root: '/opt/flutter',
  version: '3.41.9',
  revision: 'aaaaaaaa',
  dartVersion: '3.11.5',
  engineDirectoryName: 'darwin-arm64',
  isWindows: false,
);

Future<int> _runInit(Directory root, Steps steps) {
  final InitCommand init = InitCommand(
    keystoreManager: KeystoreManager(processManager: steps, isWindows: false),
    pubGetRunnerFactory: (FluseContext c) =>
        PubGetRunner(sdk: c.sdk, processManager: steps),
    builderFactory: (FluseContext c) =>
        PreviewAppBuilder(sdk: c.sdk, processManager: steps),
    installerFactory: (FluseContext c) => DeviceInstaller(
      processManager: steps,
      onMessage: (String _) {},
      readLine: () => '3',
    ),
  );
  return init.run(
    init.argParser.parse(const <String>[]),
    FluseContext.of(
      projectRoot: root,
      config: const FluseConfig(),
      sdk: _sdk,
      logger: FluseLogger(sinks: const <FluseLogSink>[]),
      processManager: steps,
    ),
  );
}
