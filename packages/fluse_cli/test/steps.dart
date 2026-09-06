import 'dart:convert';
import 'dart:io';

import 'package:fluse_builder/fluse_builder.dart';
import 'package:path/path.dart' as p;
import 'package:process/process.dart';

void createProject(Directory root) {
  void write(String relative, String contents) {
    final File file = File(p.join(root.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(contents);
  }

  write('pubspec.yaml', '''
name: counter_app
description: テスト用

dependencies:
  flutter:
    sdk: flutter

flutter:
  uses-material-design: true
''');
  write('pubspec.lock', '# 空\n');
  write(p.join('lib', 'main.dart'), 'void main() {}\n');
  write(p.join('lib', 'other.dart'), 'void main() {}\n');
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

/// 各段を演じる [ProcessManager]。
final class Steps implements ProcessManager {
  Steps(this.root);

  final Directory root;

  /// 通った段の並び。
  final List<String> order = <String>[];

  List<String> devices = <String>['AAA'];
  int pubGetExitCode = 0;
  int buildExitCode = 0;
  bool conflict = false;
  String? installedTo;

  /// `adb` が PATH にあるか。無い機を演じる時に false にする。
  bool adbAvailable = true;

  bool ran(String step) => order.contains(step);

  /// `flutter build --verbose` が出す起動コマンドを模した1行。
  static const String verboseLine =
      'executing: /opt/flutter/bin/cache/dart-sdk/bin/dartaotruntime '
      'frontend_server_aot.dart.snapshot --sdk-root /opt/flutter/x/ '
      '--incremental --target=flutter --track-widget-creation '
      '-DFLUTTER_VERSION=3.41.9';

  @override
  bool canRun(Object? executable, {String? workingDirectory}) =>
      '$executable' == 'adb' ? adbAvailable : true;

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

    if (args.contains('pub') && args.contains('get')) {
      // ここに来た時点でエントリポイントは出来ているはず。
      if (File(
        p.join(root.path, '.flutter_preview', 'fluse_main.dart'),
      ).existsSync()) {
        order.add('entrypoint');
      }
      order.add('pub get');
      return FakeProcess(exitCode: pubGetExitCode);
    }

    if (args.contains('build') && args.contains('apk')) {
      order.add('build apk');
      if (buildExitCode == 0) {
        final File apk = File(
          p.join(root.path, p.joinAll(PreviewAppBuilder.flutterApkPath)),
        );
        apk.parent.createSync(recursive: true);
        apk.writeAsStringSync('偽の APK');
      }
      return FakeProcess(exitCode: buildExitCode, stdout: verboseLine);
    }

    if (args.contains('devices')) {
      order.add('devices');
      return FakeProcess(
        stdout: <String>[
          'List of devices attached',
          for (final String serial in devices) '$serial device model:Pixel_8',
        ].join('\n'),
      );
    }

    if (args.contains('install')) {
      order.add('install');
      if (conflict) {
        return FakeProcess(
          stdout: 'Failure [${DeviceInstaller.signatureConflictMarker}]',
        );
      }
      installedTo = args[args.indexOf('-s') + 1];
      return FakeProcess(stdout: 'Success');
    }

    order.add(args.first);
    return FakeProcess();
  }

  @override
  ProcessResult runSync(
    List<Object> command, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    Encoding? stdoutEncoding = systemEncoding,
    Encoding? stderrEncoding = systemEncoding,
  }) {
    final List<String> args = command.map((Object e) => '$e').toList();
    if (args.first == 'keytool') {
      order.add('keytool');
      final File file = File(args[args.indexOf('-keystore') + 1]);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('偽の keystore');
      return ProcessResult(1, 0, '', '');
    }
    if (args.first == 'chmod') {
      return Process.runSync('chmod', args.sublist(1));
    }
    return ProcessResult(1, 0, '', '');
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
  }) async => runSync(command);

  @override
  bool killPid(int pid, [ProcessSignal signal = ProcessSignal.sigterm]) => true;
}

final class FakeProcess implements Process {
  FakeProcess({int exitCode = 0, String stdout = ''})
    : exitCodeValue = exitCode,
      stdoutText = stdout;

  final int exitCodeValue;
  final String stdoutText;

  @override
  Stream<List<int>> get stdout =>
      Stream<List<int>>.value(utf8.encode(stdoutText));

  @override
  Stream<List<int>> get stderr => const Stream<List<int>>.empty();

  @override
  IOSink get stdin => throw UnsupportedError('stdin は使わない');

  @override
  Future<int> get exitCode async => exitCodeValue;

  @override
  int get pid => 4242;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;
}
