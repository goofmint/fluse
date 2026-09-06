import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:fluse_builder/fluse_builder.dart';
import 'package:fluse_cli/fluse_cli.dart';
import 'package:fluse_server/fluse_server.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late List<String> shown;

  const FlutterSdk sdk = FlutterSdk(
    root: '/opt/flutter',
    version: '3.41.9',
    revision: '00b0c91f06209d9e4a41f71b7a512d6eb3b9c694',
    dartVersion: '3.11.5',
    engineDirectoryName: 'darwin-arm64',
    isWindows: false,
  );

  setUp(() {
    temp = Directory.systemTemp.createTempSync('fluse_start_');
    shown = <String>[];
    _createProject(temp);
  });

  tearDown(() {
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  FluseContext context() => FluseContext.of(
    projectRoot: temp,
    config: const FluseConfig(),
    sdk: sdk,
    logger: FluseLogger(sinks: const <FluseLogSink>[]),
  );

  /// 保存済みの指紋と build_meta を置く。
  Future<void> saveState({bool matching = true}) async {
    final ProjectInfo project = await const ProjectAnalyzer().analyze(temp);
    const BuildMeta(
      trackWidgetCreation: true,
      enableAsserts: true,
      dartDefines: <String>[],
    ).writeTo(
      File(p.join(temp.path, '.flutter_preview', 'cache', 'build_meta.json')),
    );
    final Fingerprint fingerprint = await Fingerprint.compute(
      project,
      sdk,
      buildFlags: const <String>['--track-widget-creation', '--enable-asserts'],
    );
    await (matching
            ? fingerprint
            : Fingerprint(
                entries: <String, String>{
                  ...fingerprint.entries,
                  Fingerprint.keyAndroidNative: 'ちがう値',
                },
              ))
        .writeTo(
          File(
            p.join(temp.path, '.flutter_preview', 'cache', 'fingerprint.json'),
          ),
        );
  }

  late List<String> answers;
  late _FakeServer? started;

  /// テスト用の合言葉。
  ///
  /// **リテラルで書かない。** ダミーであっても、資格情報の形をした
  /// 文字列がリポジトリに残ると本物と見分けが付かない。
  late String pairingToken;

  late List<String> keys;

  StartCommand command({
    List<InternetAddress> addresses = const <InternetAddress>[],
  }) {
    keys = <String>['q'];
    answers = <String>['q'];
    started = null;
    pairingToken = _secret();
    return StartCommand(
      onOutput: shown.add,
      addresses: () async => addresses.isEmpty
          ? <InternetAddress>[InternetAddress('192.168.1.5')]
          : addresses,
      readLine: () => answers.isEmpty ? null : answers.removeAt(0),
      keyLines: () => Stream<String>.fromIterable(keys),
      serverFactory: (StartRequest request) async {
        final _FakeServer server = _FakeServer(request);
        started = server;
        return StartedServer(
          uri: Uri.parse('http://${request.host}:${request.port}'),
          pairingToken: pairingToken,
          close: server.close,
          reload: server.reload,
        );
      },
    );
  }

  Future<int> runStart({
    List<String> arguments = const <String>[],
    List<InternetAddress> addresses = const <InternetAddress>[],
    List<String>? typed,
    List<String>? pressed,
  }) async {
    final StartCommand start = command(addresses: addresses);
    if (typed != null) {
      answers = List<String>.of(typed);
    }
    if (pressed != null) {
      keys = List<String>.of(pressed);
    }
    return start.run(start.argParser.parse(arguments), context());
  }

  group('起動と表示（完了条件）', () {
    test('QR と接続先を出す', () async {
      await saveState();

      expect(await runStart(), 0);

      final String text = shown.join('\n');
      // QR は上下ハーフブロックで描く。
      expect(text, contains('█'));
      expect(text, contains('QRコードをPreview Appでスキャンしてください'));
      expect(text, contains('http://192.168.1.5:8180'));
    });

    test('手で入れるための合言葉を平文で出す', () async {
      // QR を読めない端末のための導線（設計 §4.2(b)）。
      await saveState();

      await runStart();

      expect(shown.join('\n'), contains(pairingToken));
    });

    test('端末が見つからない時の逃げ道を出す', () async {
      await saveState();

      await runStart();

      expect(shown.join('\n'), contains('fluse start --host'));
    });

    test('キーの案内を出す', () async {
      await saveState();

      await runStart();

      expect(shown.join('\n'), contains('r: 手動リロード'));
      expect(shown.join('\n'), contains('q: 終了'));
    });

    test('サーバに projectId と appVersion を渡す', () async {
      await saveState();

      await runStart();

      expect(started?.request.projectId.length, ProjectIdentity.hashLength);
      expect(
        started?.request.appVersion.length,
        ProjectIdentity.appVersionLength,
      );
    });
  });

  group('QR の中身', () {
    test('設計 §4.2(a) の形で組む', () {
      final String token = _secret();
      final String uri = ConnectUri.build(
        lanHost: '192.168.0.10',
        port: 8180,
        projectId: '0123456789abcdef',
        pairingToken: token,
        flutterRevision: '00b0c91f06209d9e4a41f71b7a512d6eb3b9c694',
      );

      expect(uri, startsWith('fluse://connect?'));
      final Uri parsed = Uri.parse(uri);
      expect(parsed.queryParameters['v'], '1');
      expect(parsed.queryParameters['h'], '192.168.0.10');
      expect(parsed.queryParameters['p'], '8180');
      expect(parsed.queryParameters['pid'], '0123456789abcdef');
      expect(parsed.queryParameters['t'], token);
      // 全部載せると QR の版が上がって収まらない。
      expect(parsed.queryParameters['rev'], '00b0c91f');
    });

    test('短い revision はそのまま', () {
      expect(ConnectUri.shortRevision('abc'), 'abc');
    });

    test('描いた QR に静穏帯がある', () {
      // 無いと端末が読み取り位置を決められない。
      // **末尾を削って調べない。** 静穏帯は空行なので、削ると
      // 「あるかどうか」を確かめられなくなる。
      final List<String> lines = ConsoleQr.render(
        'fluse://connect?v=1',
      ).split('\n');
      // 末尾の改行で出来る空要素を落とす。
      if (lines.isNotEmpty && lines.last.isEmpty) {
        lines.removeLast();
      }

      // 上下4マス＝2行ぶん。
      expect(lines[0].trim(), isEmpty);
      expect(lines[1].trim(), isEmpty);
      expect(lines[lines.length - 1].trim(), isEmpty);
      expect(lines[lines.length - 2].trim(), isEmpty);
      // 左右にも空きがあること。
      expect(lines[2].startsWith('    '), isTrue);
    });

    test('長い URI でも描ける', () {
      final String uri = ConnectUri.build(
        lanHost: '192.168.100.200',
        port: 65535,
        projectId: '0123456789abcdef',
        pairingToken: _secret(),
        flutterRevision: '00b0c91f06209d9e4a41f71b7a512d6eb3b9c694',
      );

      expect(ConsoleQr.render(uri), isNotEmpty);
    });
  });

  group('指紋の照合', () {
    test('食い違えば APP_OUTDATED を出して起動しない', () async {
      // 古い APK のまま繋ぐと、差分を送っても反映されない理由が
      // 分からなくなる（設計 §5.1）。
      await saveState(matching: false);

      expect(await runStart(), 1);
      expect(shown.join('\n'), contains('APP_OUTDATED'));
      expect(shown.join('\n'), contains('fluse rebuild'));
      expect(started, isNull);
    });

    test('変わったキーの名前を出す', () async {
      await saveState(matching: false);

      await runStart();

      expect(shown.join('\n'), contains(Fingerprint.keyAndroidNative));
    });

    test('指紋が無ければ起動しない', () async {
      // 読めないことを「差分なし」と読み替えない。
      expect(await runStart(), 1);
      expect(started, isNull);
    });
  });

  group('アドレスの選択', () {
    test('1つなら自動で使う', () async {
      await saveState();

      await runStart(addresses: <InternetAddress>[InternetAddress('10.0.0.5')]);

      expect(shown.join('\n'), contains('http://10.0.0.5:'));
    });

    test('複数あれば選ばせる', () async {
      // 端末から届かない側を選ぶと「QR は出るのに繋がらない」になる。
      await saveState();

      await runStart(
        addresses: <InternetAddress>[
          InternetAddress('10.0.0.5'),
          InternetAddress('192.168.1.5'),
        ],
        typed: <String>['2'],
      );

      expect(shown.join('\n'), contains('どのアドレスで待ち受けますか'));
      expect(shown.join('\n'), contains('http://192.168.1.5:'));
    });

    test('--host があれば選ばせない', () async {
      await saveState();

      await runStart(
        arguments: <String>['--host', '0.0.0.0'],
        addresses: <InternetAddress>[
          InternetAddress('10.0.0.5'),
          InternetAddress('192.168.1.5'),
        ],
      );

      expect(shown.join('\n'), isNot(contains('どのアドレスで待ち受けますか')));
      expect(shown.join('\n'), contains('http://0.0.0.0:'));
    });

    test('見つからなければ次の手を示す', () async {
      await saveState();

      final StartCommand start = StartCommand(
        onOutput: shown.add,
        addresses: () async => <InternetAddress>[],
        readLine: () => 'q',
        serverFactory: (StartRequest _) async => throw StateError('起動してはいけない'),
      );

      expect(await start.run(start.argParser.parse(<String>[]), context()), 1);
      expect(shown.join('\n'), contains('--host'));
    });
  });

  group('キー入力', () {
    test('q で畳む', () async {
      // 掴んだままだと次の start がポートを取れない。
      await saveState();

      await runStart(pressed: <String>['q']);

      expect(started?.closed, isTrue);
    });

    test('入力が閉じても畳む', () async {
      await saveState();

      await runStart(pressed: <String>[]);

      expect(started?.closed, isTrue);
    });

    test('r は受け付けて続ける', () async {
      await saveState();

      await runStart(pressed: <String>['r', 'q']);

      expect(started?.reloads, 1);
      expect(started?.closed, isTrue);
    });
  });

  group('待っている間も動く', () {
    test('キー待ちがサーバを止めない', () async {
      // **同期で読むと isolate ごと止まる。** その間サーバは接続を捌けず、
      // QR を出しても端末が繋がらない。
      await saveState();

      final HttpServer real = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      real.listen((HttpRequest request) async {
        request.response.statusCode = 200;
        await request.response.close();
      });

      // キーはすぐには来ない。その間に外から叩けること。
      final Completer<void> release = Completer<void>();
      final StartCommand start = StartCommand(
        onOutput: shown.add,
        addresses: () async => <InternetAddress>[
          InternetAddress('192.168.1.5'),
        ],
        readLine: () => null,
        keyLines: () async* {
          await release.future;
          yield 'q';
        },
        serverFactory: (StartRequest request) async => StartedServer(
          uri: Uri.parse('http://127.0.0.1:${real.port}'),
          pairingToken: _secret(),
          close: real.close,
          reload: () async {},
        ),
      );

      final Future<int> running = start.run(
        start.argParser.parse(<String>[]),
        context(),
      );

      // 待っている最中に応答が返ること。
      final HttpClient client = HttpClient();
      final HttpClientResponse response = await (await client.getUrl(
        Uri.parse('http://127.0.0.1:${real.port}/'),
      )).close();
      expect(response.statusCode, 200);
      await response.drain<void>();
      client.close();

      release.complete();
      expect(await running, 0);
    });
  });

  group('オプション', () {
    test('--port が効く', () async {
      await saveState();

      await runStart(arguments: <String>['--port', '9000']);

      expect(started?.request.port, 9000);
    });

    test('数でない --port は弾く', () async {
      await saveState();

      expect(await runStart(arguments: <String>['--port', 'にせん']), 1);
    });
  });
}

/// 立ち上がったことにするサーバ。
final class _FakeServer {
  _FakeServer(this.request);

  final StartRequest request;
  bool closed = false;
  int reloads = 0;

  Future<void> close() async {
    closed = true;
  }

  Future<void> reload() async {
    reloads++;
  }
}

void _createProject(Directory root) {
  void write(String relative, String contents) {
    final File file = File(p.join(root.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(contents);
  }

  write('pubspec.yaml', '''
name: counter_app
flutter:
  uses-material-design: true
''');
  write('pubspec.lock', '# 空\n');
  write(p.join('lib', 'main.dart'), 'void main() {}\n');
  write(p.join('android', 'app', 'build.gradle.kts'), '''
android {
    namespace = "com.example.counter_app"
    defaultConfig {
        applicationId = "com.example.counter_app"
    }
}
''');
  write(
    p.join('android', 'app', 'src', 'main', 'AndroidManifest.xml'),
    '<manifest />\n',
  );
}

/// テスト用の秘密。リテラルで書かず、実行のたびに作る。
String _secret() {
  final Random random = Random.secure();
  final List<int> bytes = List<int>.generate(
    24,
    (int _) => random.nextInt(256),
  );
  return base64Url.encode(bytes).replaceAll('=', '');
}
