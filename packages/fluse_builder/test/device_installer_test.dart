import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fluse_builder/fluse_builder.dart';
import 'package:path/path.dart' as p;
import 'package:process/process.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  late Directory temp;
  late File apk;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('fluse_installer_');
    apk = File(p.join(temp.path, 'preview.apk'))..writeAsStringSync('偽の APK');
  });

  tearDown(() {
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  const AndroidDevice device = AndroidDevice(
    serial: 'RF8N70XXXXX',
    model: 'Pixel 8',
  );
  const String applicationId = 'com.example.counter_app';

  DeviceInstaller installer(
    _Adb adb, {
    List<String> answers = const <String>[],
    List<String>? shown,
  }) {
    final List<String> queue = List<String>.of(answers);
    return DeviceInstaller(
      processManager: adb,
      onMessage: (String line) => shown?.add(line),
      readLine: () => queue.isEmpty ? null : queue.removeAt(0),
    );
  }

  group('端末の列挙', () {
    test('使える端末だけを返す', () async {
      // 使えないものを一覧に出すと、選んでから「入れられません」になる。
      final List<AndroidDevice> devices = DeviceInstaller.parseDevices('''
List of devices attached
RF8N70XXXXX            device product:a54x model:SM_A546E transport_id:1
emulator-5554          device product:sdk_gphone64 model:sdk_gphone64 transport_id:2
ZY223KKKKK             unauthorized
0123456789ABCDEF       offline
''');

      expect(devices.map((AndroidDevice d) => d.serial), <String>[
        'RF8N70XXXXX',
        'emulator-5554',
      ]);
    });

    test('見分けが付く名前にする', () {
      final List<AndroidDevice> devices = DeviceInstaller.parseDevices(
        'RF8N70XXXXX device model:SM_A546E transport_id:1',
      );

      // `SM_A546E` のままだと読みにくい。
      expect(devices.single.model, 'SM A546E');
      expect(devices.single.label, contains('RF8N70XXXXX'));
    });

    test('model が無ければ serial を出す', () {
      // 空欄だと選びようが無い。
      final List<AndroidDevice> devices = DeviceInstaller.parseDevices(
        'RF8N70XXXXX device',
      );

      expect(devices.single.model, 'RF8N70XXXXX');
      expect(devices.single.label, 'RF8N70XXXXX');
    });

    test('adb が無ければ次にすることを示す', () async {
      await expectLater(
        installer(_Adb(available: false)).listDevices(),
        throwsA(
          isA<DeviceInstallException>().having(
            (DeviceInstallException e) => e.toString(),
            'toString',
            allOf(contains('Platform-Tools'), contains('doctor')),
          ),
        ),
      );
    });
  });

  group('通常のインストール', () {
    test('adb install -r を呼ぶ', () async {
      final _Adb adb = _Adb(stdout: 'Success');

      final InstallOutcome outcome = await installer(adb).install(
        device: device,
        apk: apk,
        applicationId: applicationId,
        projectRoot: temp,
      );

      expect(outcome, isA<Installed>());
      expect(adb.commands.single, <String>[
        'adb',
        '-s',
        device.serial,
        'install',
        '-r',
        apk.path,
      ]);
    });

    test('失敗したら理由を添える', () async {
      final _Adb adb = _Adb(exitCode: 1, stderr: 'INSTALL_FAILED_NO_SPACE');

      await expectLater(
        installer(adb).install(
          device: device,
          apk: apk,
          applicationId: applicationId,
          projectRoot: temp,
        ),
        throwsA(
          isA<DeviceInstallException>().having(
            (DeviceInstallException e) => e.toString(),
            'toString',
            contains('INSTALL_FAILED_NO_SPACE'),
          ),
        ),
      );
    });
  });

  group('署名の衝突（設計 §5.3）', () {
    _Adb conflicting({String? afterUninstall}) => _Adb(
      // **終了コードでは分からない。** adb install は失敗しても 0 を返す。
      stdout: 'Failure [${DeviceInstaller.signatureConflictMarker}]',
      afterUninstallStdout: afterUninstall,
    );

    test('3択を出す（完了条件）', () async {
      final List<String> shown = <String>[];

      await installer(
        conflicting(afterUninstall: 'Success'),
        answers: <String>['1'],
        shown: shown,
      ).install(
        device: device,
        apk: apk,
        applicationId: applicationId,
        projectRoot: temp,
      );

      final String text = shown.join('\n');
      expect(text, contains(DeviceInstaller.signatureConflictMarker));
      expect(text, contains(applicationId));
      expect(text, contains('1) 既存アプリをアンインストールして続行'));
      expect(text, contains('2) Preview App を別IDでインストール'));
      expect(text, contains('3) 中止'));
    });

    test('1 を選ぶと消してから入れ直す', () async {
      final _Adb adb = conflicting(afterUninstall: 'Success');

      final InstallOutcome outcome =
          await installer(adb, answers: <String>['1']).install(
            device: device,
            apk: apk,
            applicationId: applicationId,
            projectRoot: temp,
          );

      expect(outcome, isA<Installed>());
      expect((outcome as Installed).reinstalled, isTrue);
      expect(adb.commands[1], <String>[
        'adb',
        '-s',
        device.serial,
        'uninstall',
        applicationId,
      ]);
      expect(adb.commands[2], contains('install'));
    });

    test('2 を選ぶと fluse.yaml に書いて作り直しを求める', () async {
      final _Adb adb = conflicting();

      final InstallOutcome outcome =
          await installer(adb, answers: <String>['2']).install(
            device: device,
            apk: apk,
            applicationId: applicationId,
            projectRoot: temp,
          );

      expect(outcome, isA<NeedsRebuild>());
      expect(
        (outcome as NeedsRebuild).applicationIdSuffix,
        DeviceInstaller.defaultSuffix,
      );
      final Object? config = loadYaml(
        File(p.join(temp.path, 'fluse.yaml')).readAsStringSync(),
      );
      expect(
        (config! as Map<Object?, Object?>)['applicationIdSuffix'],
        DeviceInstaller.defaultSuffix,
      );
      // ここでは作り直さない。APK を作るのは PreviewAppBuilder の役目。
      expect(adb.commands.length, 1);
    });

    test('3 を選ぶと何も残さない', () async {
      // 中止は失敗ではない。例外にしない。
      final _Adb adb = conflicting();

      final InstallOutcome outcome =
          await installer(adb, answers: <String>['3']).install(
            device: device,
            apk: apk,
            applicationId: applicationId,
            projectRoot: temp,
          );

      expect(outcome, isA<Aborted>());
      expect(File(p.join(temp.path, 'fluse.yaml')).existsSync(), isFalse);
      expect(adb.commands.length, 1);
    });

    test('黙って上書きしない', () async {
      // 尋ねずに消したり入れ替えたりしない。
      final _Adb adb = conflicting();

      await installer(adb, answers: <String>['3']).install(
        device: device,
        apk: apk,
        applicationId: applicationId,
        projectRoot: temp,
      );

      expect(
        adb.commands.where((List<String> c) => c.contains('uninstall')),
        isEmpty,
      );
    });

    test('答えが範囲外なら聞き直す', () async {
      final List<String> shown = <String>[];

      await installer(
        conflicting(),
        answers: <String>['9', '', '3'],
        shown: shown,
      ).install(
        device: device,
        apk: apk,
        applicationId: applicationId,
        projectRoot: temp,
      );

      expect(shown.where((String l) => l.contains('1 から 3')).length, 2);
    });

    test('入力が閉じていたら中止にする', () async {
      // パイプ越しなど。勝手に決めない。
      final InstallOutcome outcome = await installer(conflicting()).install(
        device: device,
        apk: apk,
        applicationId: applicationId,
        projectRoot: temp,
      );

      expect(outcome, isA<Aborted>());
    });
  });

  group('fluse.yaml への書き込み', () {
    test('他の設定を消さない', () async {
      File(p.join(temp.path, 'fluse.yaml')).writeAsStringSync('''
# 待ち受けるポート。
port: 8180

# 端末を1台に絞る。
serveApk: true
''');

      await const DeviceInstaller().persistSuffix(temp, '.preview');

      final String after = File(
        p.join(temp.path, 'fluse.yaml'),
      ).readAsStringSync();
      expect(after, contains('# 待ち受けるポート。'));
      expect(after, contains('port: 8180'));
      expect(after, contains('applicationIdSuffix: .preview'));
    });

    test('無ければ作る', () async {
      await const DeviceInstaller().persistSuffix(temp, '.preview');

      final Object? config = loadYaml(
        File(p.join(temp.path, 'fluse.yaml')).readAsStringSync(),
      );
      expect(
        (config! as Map<Object?, Object?>)['applicationIdSuffix'],
        '.preview',
      );
    });

    test('書き足しても壊れない', () async {
      await const DeviceInstaller().persistSuffix(temp, '.preview');
      await const DeviceInstaller().persistSuffix(temp, '.debug');

      final Object? config = loadYaml(
        File(p.join(temp.path, 'fluse.yaml')).readAsStringSync(),
      );
      expect(
        (config! as Map<Object?, Object?>)['applicationIdSuffix'],
        '.debug',
      );
    });

    test('一時ファイルを残さない', () async {
      await const DeviceInstaller().persistSuffix(temp, '.preview');

      expect(File(p.join(temp.path, 'fluse.yaml.tmp')).existsSync(), isFalse);
    });
  });

  group('adb が使えない時の配信', () {
    test('合言葉が合えば APK を返し、合わなければ 404', () async {
      // adb が無くてもブラウザから入れられるようにする。
      final List<InternetAddress> lan = await _privateAddresses();
      if (lan.isEmpty) {
        markTestSkipped('私設 IPv4 を持たない環境');
        return;
      }

      final ApkServer server = await ApkServer.serve(
        apk,
        addresses: () async => lan,
      );
      addTearDown(server.close);

      final HttpClient client = HttpClient();
      addTearDown(client.close);

      final HttpClientResponse ok = await (await client.getUrl(
        server.uri,
      )).close();
      expect(ok.statusCode, 200);
      expect(ok.headers.value('content-type'), ApkServer.contentType);
      expect(await ok.transform(utf8.decoder).join(), '偽の APK');

      // **403 にしない。** 「そこにある」と教えることになる。
      final HttpClientResponse notFound = await (await client.getUrl(
        server.uri.replace(queryParameters: <String, String>{'t': 'ちがう'}),
      )).close();
      expect(notFound.statusCode, 404);
      await notFound.drain<void>();
    });

    test('1件の失敗で受付ごと止まらない', () async {
      // `addStream` だけでなく `close()` も切断で投げる。受付の輪から
      // 抜けると、以後どの要求にも応えられなくなる。
      final List<InternetAddress> lan = await _privateAddresses();
      if (lan.isEmpty) {
        markTestSkipped('私設 IPv4 を持たない環境');
        return;
      }

      final List<Object> errors = <Object>[];
      final ApkServer server = await ApkServer.serve(
        apk,
        addresses: () async => lan,
        onError: errors.add,
      );
      addTearDown(server.close);

      final HttpClient client = HttpClient();
      addTearDown(() => client.close(force: true));

      // 1件目: 配信の途中で読めなくする。切断でも同じ経路を通る。
      apk.deleteSync();
      Directory(apk.path).createSync();
      try {
        final HttpClientResponse broken = await (await client.getUrl(
          server.uri,
        )).close();
        await broken.drain<void>();
      } on Object {
        // 相手から見れば応答が壊れる。それでよい。
      }
      Directory(apk.path).deleteSync();
      apk.writeAsStringSync('偽の APK');

      expect(errors, isNotEmpty, reason: '失敗が届いていない');

      // 2件目: それでも応えられること。
      final HttpClientResponse again = await (await client.getUrl(
        server.uri,
      )).close();

      expect(again.statusCode, 200);
      expect(await again.transform(utf8.decoder).join(), '偽の APK');
    });

    test('プライベート IPv4 だけを選ぶ', () async {
      // loopback では端末から届かない。公衆側に出すとソースを晒す。
      final InternetAddress chosen = await ApkServer.resolveLanAddress(
        addresses: () async => <InternetAddress>[
          InternetAddress('203.0.113.10'),
          InternetAddress('192.168.1.5'),
        ],
      );

      expect(chosen.address, '192.168.1.5');
    });

    test('見つからなければ何をすればよいか示す', () async {
      await expectLater(
        ApkServer.resolveLanAddress(
          addresses: () async => <InternetAddress>[
            InternetAddress('203.0.113.10'),
          ],
        ),
        throwsA(
          isA<DeviceInstallException>().having(
            (DeviceInstallException e) => e.toString(),
            'toString',
            contains('Wi-Fi'),
          ),
        ),
      );
    });

    test('私設アドレスの範囲を正しく見る', () {
      expect(ApkServer.isPrivateIPv4(InternetAddress('10.0.0.1')), isTrue);
      expect(ApkServer.isPrivateIPv4(InternetAddress('172.16.0.1')), isTrue);
      expect(ApkServer.isPrivateIPv4(InternetAddress('172.31.255.1')), isTrue);
      expect(ApkServer.isPrivateIPv4(InternetAddress('192.168.0.1')), isTrue);
      // 境界の外。
      expect(ApkServer.isPrivateIPv4(InternetAddress('172.15.0.1')), isFalse);
      expect(ApkServer.isPrivateIPv4(InternetAddress('172.32.0.1')), isFalse);
      expect(ApkServer.isPrivateIPv4(InternetAddress('192.169.0.1')), isFalse);
      expect(ApkServer.isPrivateIPv4(InternetAddress('8.8.8.8')), isFalse);
    });

    test('合言葉を定数時間で比べる', () {
      // 応答の速さから1文字ずつ詰められないようにする。
      expect(ApkServer.constantTimeEquals('abcd', 'abcd'), isTrue);
      expect(ApkServer.constantTimeEquals('abcd', 'abce'), isFalse);
      expect(ApkServer.constantTimeEquals('abcd', 'abc'), isFalse);
    });

    test('合言葉は毎回違う', () {
      expect(ApkServer.generateToken(), isNot(ApkServer.generateToken()));
    });

    test('APK が無ければ弾く', () async {
      await expectLater(
        ApkServer.serve(File(p.join(temp.path, 'ない.apk'))),
        throwsA(isA<DeviceInstallException>()),
      );
    });
  });
}

/// この機が持つ私設 IPv4。無ければ空。
Future<List<InternetAddress>> _privateAddresses() async {
  final List<NetworkInterface> interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLoopback: false,
  );
  return <InternetAddress>[
    for (final NetworkInterface each in interfaces)
      ...each.addresses.where(ApkServer.isPrivateIPv4),
  ];
}

/// `adb` の代わりに答える [ProcessManager]。
final class _Adb implements ProcessManager {
  _Adb({
    this.available = true,
    this.exitCode = 0,
    this.stdout = '',
    this.stderr = '',
    this.afterUninstallStdout,
  });

  final bool available;
  final int exitCode;
  final String stdout;
  final String stderr;

  /// `uninstall` の後の `install` が返す内容。
  final String? afterUninstallStdout;

  final List<List<String>> commands = <List<String>>[];
  bool _uninstalled = false;

  @override
  bool canRun(Object? executable, {String? workingDirectory}) => available;

  @override
  Future<Process> start(
    List<Object> command, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) async {
    final List<String> args = command.map((Object e) => '$e').toList();
    commands.add(args);

    if (args.contains('uninstall')) {
      _uninstalled = true;
      return _Process(stdout: 'Success', exitCode: 0);
    }
    if (_uninstalled && afterUninstallStdout != null) {
      return _Process(stdout: afterUninstallStdout!, exitCode: 0);
    }
    return _Process(stdout: stdout, stderr: stderr, exitCode: exitCode);
  }

  @override
  Future<ProcessResult> run(
    List<Object> command, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    Encoding? stdoutEncoding = systemEncoding,
    Encoding? stderrEncoding = systemEncoding,
  }) => throw UnsupportedError('run は使わない');

  @override
  ProcessResult runSync(
    List<Object> command, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    Encoding? stdoutEncoding = systemEncoding,
    Encoding? stderrEncoding = systemEncoding,
  }) => throw UnsupportedError('runSync は使わない');

  @override
  bool killPid(int pid, [ProcessSignal signal = ProcessSignal.sigterm]) => true;
}

final class _Process implements Process {
  _Process({required String stdout, required int exitCode, String stderr = ''})
    : _stdout = stdout,
      _stderr = stderr,
      _exitCode = exitCode;

  final String _stdout;
  final String _stderr;
  final int _exitCode;

  @override
  Stream<List<int>> get stdout => Stream<List<int>>.value(utf8.encode(_stdout));

  @override
  Stream<List<int>> get stderr => Stream<List<int>>.value(utf8.encode(_stderr));

  @override
  IOSink get stdin => throw UnsupportedError('stdin は使わない');

  @override
  Future<int> get exitCode async => _exitCode;

  @override
  int get pid => 4242;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;
}
