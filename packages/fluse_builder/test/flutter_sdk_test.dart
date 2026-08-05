import 'dart:io';

import 'package:fluse_builder/fluse_builder.dart';
import 'package:fluse_server/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Flutter 3.41.9 の `flutter --version --machine` を模した出力。
const String _machineJson = '''
{
  "frameworkVersion": "3.41.9",
  "channel": "stable",
  "frameworkRevision": "00b0c91f06209d9e4a41f71b7a512d6eb3b9c694",
  "engineRevision": "42d3d75a56efe1a2e9902f52dc8006099c45d937",
  "dartSdkVersion": "3.11.5",
  "flutterVersion": "3.41.9"
}
''';

void main() {
  late Directory temp;
  late String sdkRoot;
  late String flutterExecutable;
  late FakeProcessManager processManager;

  /// エンジン成果物を置くディレクトリ名。実行中のホストに合わせる。
  final String engineDirectory =
      HostPlatform.resolve().engineDirectoryCandidates.first;

  /// 完全な SDK ツリーを作る。[engineDirectoryName] を変えると
  /// ホスト向け成果物の置き場所を差し替えられる。
  void createSdkTree({
    required String root,
    String? engineDirectoryName,
    bool withDartAotRuntime = true,
    bool withFrontendServer = true,
    bool withPatchedSdk = true,
  }) {
    File(p.join(root, 'bin', 'flutter'))
      ..createSync(recursive: true)
      ..writeAsStringSync('#!/bin/sh\n');

    if (withDartAotRuntime) {
      File(
        p.join(root, 'bin', 'cache', 'dart-sdk', 'bin', 'dartaotruntime'),
      ).createSync(recursive: true);
    }
    if (withFrontendServer) {
      File(
        p.join(
          root,
          'bin',
          'cache',
          'artifacts',
          'engine',
          engineDirectoryName ?? engineDirectory,
          'frontend_server_aot.dart.snapshot',
        ),
      ).createSync(recursive: true);
    }
    if (withPatchedSdk) {
      Directory(
        p.join(
          root,
          'bin',
          'cache',
          'artifacts',
          'engine',
          'common',
          'flutter_patched_sdk',
        ),
      ).createSync(recursive: true);
    }
  }

  /// `flutter --version --machine` の応答を登録する。
  void registerVersion(String executable, {String stdout = _machineJson}) {
    processManager.registerRun(<String>[
      executable,
      '--version',
      '--machine',
    ], ProcessResult(1, 0, stdout, ''));
  }

  setUp(() {
    temp = Directory.systemTemp.createTempSync('fluse_sdk_test.');
    // macOS の /var は /private/var へのシンボリックリンクなので、
    // PATH 探索の結果と比較できるよう先に解決しておく。
    sdkRoot = p.join(temp.resolveSymbolicLinksSync(), 'flutter');
    flutterExecutable = p.join(sdkRoot, 'bin', 'flutter');
    processManager = FakeProcessManager();
  });

  tearDown(() => temp.deleteSync(recursive: true));

  group('ルートの解決順', () {
    test('--flutter-sdk（explicitRoot）を最優先で使う', () async {
      createSdkTree(root: sdkRoot);
      registerVersion(flutterExecutable);

      final FlutterSdk sdk = await FlutterSdk.resolve(
        explicitRoot: sdkRoot,
        processManager: processManager,
        environment: <String, String>{
          'FLUSE_FLUTTER_SDK': '/nowhere',
          'PATH': '/nowhere/bin',
        },
      );

      expect(sdk.root, sdkRoot);
    });

    test('explicitRoot が無ければ FLUSE_FLUTTER_SDK を使う', () async {
      createSdkTree(root: sdkRoot);
      registerVersion(flutterExecutable);

      final FlutterSdk sdk = await FlutterSdk.resolve(
        processManager: processManager,
        environment: <String, String>{
          'FLUSE_FLUTTER_SDK': sdkRoot,
          'PATH': '/nowhere/bin',
        },
      );

      expect(sdk.root, sdkRoot);
    });

    test('どちらも無ければ PATH を探索する', () async {
      createSdkTree(root: sdkRoot);
      registerVersion(flutterExecutable);

      final FlutterSdk sdk = await FlutterSdk.resolve(
        processManager: processManager,
        environment: <String, String>{
          'PATH': '/nowhere/bin:${p.join(sdkRoot, 'bin')}',
        },
      );

      expect(sdk.root, sdkRoot);
    });

    test('PATH は先頭から順に見る', () async {
      final String other = p.join(temp.resolveSymbolicLinksSync(), 'other');
      createSdkTree(root: other);
      createSdkTree(root: sdkRoot);
      registerVersion(p.join(other, 'bin', 'flutter'));

      final FlutterSdk sdk = await FlutterSdk.resolve(
        processManager: processManager,
        environment: <String, String>{
          'PATH': '${p.join(other, 'bin')}:${p.join(sdkRoot, 'bin')}',
        },
      );

      expect(sdk.root, other);
    });
  });

  group('バージョン情報の取得', () {
    test('frameworkVersion / frameworkRevision / dartSdkVersion を読む', () async {
      createSdkTree(root: sdkRoot);
      registerVersion(flutterExecutable);

      final FlutterSdk sdk = await FlutterSdk.resolve(
        explicitRoot: sdkRoot,
        processManager: processManager,
        environment: <String, String>{},
      );

      expect(sdk.version, '3.41.9');
      expect(sdk.revision, '00b0c91f06209d9e4a41f71b7a512d6eb3b9c694');
      expect(sdk.dartVersion, '3.11.5');
    });

    test('dartSdkVersion のビルド情報は落とす', () async {
      createSdkTree(root: sdkRoot);
      registerVersion(
        flutterExecutable,
        stdout: _machineJson.replaceFirst(
          '"dartSdkVersion": "3.11.5"',
          '"dartSdkVersion": "3.11.5 (build 3.11.5-edge.abc)"',
        ),
      );

      final FlutterSdk sdk = await FlutterSdk.resolve(
        explicitRoot: sdkRoot,
        processManager: processManager,
        environment: <String, String>{},
      );

      expect(sdk.dartVersion, '3.11.5');
    });

    test('JSON の前に別の出力があっても解析できる', () async {
      // 更新通知などが混ざることがある。
      createSdkTree(root: sdkRoot);
      registerVersion(
        flutterExecutable,
        stdout: 'A new version of Flutter is available!\n$_machineJson',
      );

      final FlutterSdk sdk = await FlutterSdk.resolve(
        explicitRoot: sdkRoot,
        processManager: processManager,
        environment: <String, String>{},
      );

      expect(sdk.version, '3.41.9');
    });
  });

  group('パスの解決', () {
    test('検証済みの実パスを組み立てる', () async {
      createSdkTree(root: sdkRoot);
      registerVersion(flutterExecutable);

      final FlutterSdk sdk = await FlutterSdk.resolve(
        explicitRoot: sdkRoot,
        processManager: processManager,
        environment: <String, String>{},
      );

      expect(
        sdk.dartAotRuntime,
        p.join(sdkRoot, 'bin', 'cache', 'dart-sdk', 'bin', 'dartaotruntime'),
      );
      expect(
        sdk.frontendServerSnapshot,
        p.join(
          sdkRoot,
          'bin',
          'cache',
          'artifacts',
          'engine',
          engineDirectory,
          'frontend_server_aot.dart.snapshot',
        ),
      );
      expect(
        sdk.patchedSdkRoot,
        p.join(
          sdkRoot,
          'bin',
          'cache',
          'artifacts',
          'engine',
          'common',
          'flutter_patched_sdk',
        ),
      );
    });

    test('解決したパスは全て実在する', () async {
      createSdkTree(root: sdkRoot);
      registerVersion(flutterExecutable);

      final FlutterSdk sdk = await FlutterSdk.resolve(
        explicitRoot: sdkRoot,
        processManager: processManager,
        environment: <String, String>{},
      );

      expect(File(sdk.dartAotRuntime).existsSync(), isTrue);
      expect(File(sdk.frontendServerSnapshot).existsSync(), isTrue);
      expect(Directory(sdk.patchedSdkRoot).existsSync(), isTrue);
    });
  });

  group('Windows のパス', () {
    // 解決時とパス組み立て時で判定がずれないよう、isWindows は
    // インスタンスが保持する。
    FlutterSdk sdkFor({required bool isWindows}) => FlutterSdk(
      root: r'C:\src\flutter',
      version: '3.41.9',
      revision: '0' * 40,
      dartVersion: '3.11.5',
      engineDirectoryName: 'windows-x64',
      isWindows: isWindows,
    );

    test('実行ファイル名に拡張子が付く', () {
      expect(FlutterSdk.flutterExecutableName(isWindows: true), 'flutter.bat');
      expect(
        FlutterSdk.dartAotRuntimeName(isWindows: true),
        'dartaotruntime.exe',
      );
    });

    test('非 Windows では拡張子が付かない', () {
      expect(FlutterSdk.flutterExecutableName(isWindows: false), 'flutter');
      expect(FlutterSdk.dartAotRuntimeName(isWindows: false), 'dartaotruntime');
    });

    test('ゲッターが isWindows を反映する', () {
      final FlutterSdk windows = sdkFor(isWindows: true);
      expect(p.basename(windows.flutterExecutable), 'flutter.bat');
      expect(p.basename(windows.dartAotRuntime), 'dartaotruntime.exe');

      final FlutterSdk posix = sdkFor(isWindows: false);
      expect(p.basename(posix.flutterExecutable), 'flutter');
      expect(p.basename(posix.dartAotRuntime), 'dartaotruntime');
    });

    test('スナップショットと patched SDK は拡張子を持たない', () {
      final FlutterSdk windows = sdkFor(isWindows: true);
      expect(
        p.basename(windows.frontendServerSnapshot),
        'frontend_server_aot.dart.snapshot',
      );
      expect(p.basename(windows.patchedSdkRoot), 'flutter_patched_sdk');
    });
  });

  group('SDK 未検出', () {
    test('PATH に flutter が無ければ例外になる', () async {
      await expectLater(
        FlutterSdk.resolve(
          processManager: processManager,
          environment: <String, String>{'PATH': '/nowhere/bin'},
        ),
        throwsA(
          isA<SdkNotFoundException>().having(
            (SdkNotFoundException e) => e.toString(),
            'message',
            allOf(contains('PATH'), contains('fluse doctor')),
          ),
        ),
      );
    });

    test('PATH 自体が無くても例外になる', () async {
      await expectLater(
        FlutterSdk.resolve(
          processManager: processManager,
          environment: <String, String>{},
        ),
        throwsA(isA<SdkNotFoundException>()),
      );
    });

    test('explicitRoot が SDK でなければ、その場所を示して失敗する', () async {
      final String wrong = p.join(temp.path, 'not-an-sdk');
      Directory(wrong).createSync(recursive: true);

      await expectLater(
        FlutterSdk.resolve(
          explicitRoot: wrong,
          processManager: processManager,
          environment: <String, String>{},
        ),
        throwsA(
          isA<SdkNotFoundException>().having(
            (SdkNotFoundException e) => e.toString(),
            'message',
            allOf(contains('--flutter-sdk'), contains(wrong)),
          ),
        ),
      );
    });

    test('FLUSE_FLUTTER_SDK が SDK でなければ、環境変数名を示して失敗する', () async {
      await expectLater(
        FlutterSdk.resolve(
          processManager: processManager,
          environment: <String, String>{
            'FLUSE_FLUTTER_SDK': p.join(temp.path, 'missing'),
          },
        ),
        throwsA(
          isA<SdkNotFoundException>().having(
            (SdkNotFoundException e) => e.toString(),
            'message',
            contains('FLUSE_FLUTTER_SDK'),
          ),
        ),
      );
    });
  });

  group('成果物の欠損', () {
    test('frontend_server が無ければ、そのパスを示して失敗する', () async {
      createSdkTree(root: sdkRoot, withFrontendServer: false);
      registerVersion(flutterExecutable);

      await expectLater(
        FlutterSdk.resolve(
          explicitRoot: sdkRoot,
          processManager: processManager,
          environment: <String, String>{},
        ),
        throwsA(
          isA<SdkNotFoundException>().having(
            (SdkNotFoundException e) => e.toString(),
            'message',
            allOf(
              contains('frontend_server_aot.dart.snapshot'),
              contains('flutter precache'),
            ),
          ),
        ),
      );
    });

    test('dartaotruntime が無ければ、そのパスを示して失敗する', () async {
      createSdkTree(root: sdkRoot, withDartAotRuntime: false);
      registerVersion(flutterExecutable);

      await expectLater(
        FlutterSdk.resolve(
          explicitRoot: sdkRoot,
          processManager: processManager,
          environment: <String, String>{},
        ),
        throwsA(
          isA<SdkNotFoundException>().having(
            (SdkNotFoundException e) => e.missingPaths,
            'missingPaths',
            contains(contains('dartaotruntime')),
          ),
        ),
      );
    });

    test('patched SDK が無ければ、そのパスを示して失敗する', () async {
      createSdkTree(root: sdkRoot, withPatchedSdk: false);
      registerVersion(flutterExecutable);

      await expectLater(
        FlutterSdk.resolve(
          explicitRoot: sdkRoot,
          processManager: processManager,
          environment: <String, String>{},
        ),
        throwsA(
          isA<SdkNotFoundException>().having(
            (SdkNotFoundException e) => e.missingPaths,
            'missingPaths',
            contains(contains('flutter_patched_sdk')),
          ),
        ),
      );
    });
  });

  group('flutter --version の失敗', () {
    test('終了コードが非ゼロなら stderr を添えて失敗する', () async {
      createSdkTree(root: sdkRoot);
      processManager.registerRun(<String>[
        flutterExecutable,
        '--version',
        '--machine',
      ], ProcessResult(1, 1, '', 'Flutter SDK is broken'));

      await expectLater(
        FlutterSdk.resolve(
          explicitRoot: sdkRoot,
          processManager: processManager,
          environment: <String, String>{},
        ),
        throwsA(
          isA<SdkNotFoundException>().having(
            (SdkNotFoundException e) => e.toString(),
            'message',
            contains('Flutter SDK is broken'),
          ),
        ),
      );
    });

    test('JSON が含まれていなければ失敗する', () async {
      createSdkTree(root: sdkRoot);
      registerVersion(flutterExecutable, stdout: 'not json at all');

      await expectLater(
        FlutterSdk.resolve(
          explicitRoot: sdkRoot,
          processManager: processManager,
          environment: <String, String>{},
        ),
        throwsA(isA<SdkNotFoundException>()),
      );
    });

    test('必要なキーが欠けていれば、そのキー名を示して失敗する', () async {
      createSdkTree(root: sdkRoot);
      registerVersion(
        flutterExecutable,
        stdout: '{"frameworkVersion": "3.41.9"}',
      );

      await expectLater(
        FlutterSdk.resolve(
          explicitRoot: sdkRoot,
          processManager: processManager,
          environment: <String, String>{},
        ),
        throwsA(
          isA<SdkNotFoundException>().having(
            (SdkNotFoundException e) => e.toString(),
            'message',
            contains('frameworkRevision'),
          ),
        ),
      );
    });

    test('プロセス起動そのものが失敗しても例外に変換する', () async {
      createSdkTree(root: sdkRoot);
      // registerRun していないので FakeProcessManager が投げる。

      await expectLater(
        FlutterSdk.resolve(
          explicitRoot: sdkRoot,
          processManager: processManager,
          environment: <String, String>{},
        ),
        throwsA(
          isA<SdkNotFoundException>().having(
            (SdkNotFoundException e) => e.toString(),
            'message',
            contains('起動に失敗'),
          ),
        ),
      );
    });
  });

  test('実環境の Flutter SDK を解決できる', () async {
    // 完了条件「ローカルの Flutter 3.41.9 に対し全パスが解決でき、存在検証が通る」。
    // PATH に flutter が無い環境ではスキップする。
    final FlutterSdk sdk;
    try {
      sdk = await FlutterSdk.resolve();
    } on SdkNotFoundException {
      markTestSkipped('PATH に Flutter SDK が無いためスキップ');
      return;
    }

    expect(sdk.version, isNotEmpty);
    expect(sdk.revision, hasLength(40));
    expect(sdk.dartVersion, matches(RegExp(r'^\d+\.\d+\.\d+')));
    expect(File(sdk.dartAotRuntime).existsSync(), isTrue);
    expect(File(sdk.frontendServerSnapshot).existsSync(), isTrue);
    expect(Directory(sdk.patchedSdkRoot).existsSync(), isTrue);
    expect(File(sdk.flutterExecutable).existsSync(), isTrue);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
