import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:process/process.dart';
import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

import 'android_device.dart';
import 'device_install_exception.dart';

/// 署名がぶつかった時に利用者が選んだ道（設計 §5.3）。
enum SignatureConflictChoice {
  /// 1) 既存を消して続ける。
  uninstall,

  /// 2) 別の ID で入れる。
  useSuffix,

  /// 3) 中止する。
  abort,
}

/// 導入の結果。
sealed class InstallOutcome {
  const InstallOutcome();
}

/// 入った。
final class Installed extends InstallOutcome {
  const Installed({required this.device, required this.reinstalled});

  final AndroidDevice device;

  /// 既存を消してから入れ直したか。
  final bool reinstalled;
}

/// 別 ID での作り直しが要る。
///
/// **ここでは作り直さない。** APK を作るのは `PreviewAppBuilder` の役目で、
/// 呼び出し側（`fluse init` / `fluse rebuild`）が改めて回す。
final class NeedsRebuild extends InstallOutcome {
  const NeedsRebuild({required this.applicationIdSuffix});

  /// `fluse.yaml` に書いた suffix。
  final String applicationIdSuffix;
}

/// 利用者が中止を選んだ。
///
/// **例外にしない。** 中止は失敗ではなく、選んだ結果。
final class Aborted extends InstallOutcome {
  const Aborted();
}

/// 端末へ Preview App を入れる（設計 §2.2.2 / §5.3）。
final class DeviceInstaller {
  const DeviceInstaller({
    this.processManager = const LocalProcessManager(),
    this.timeout = defaultTimeout,
    this.onMessage = print,
    this.readLine = _readStdin,
  });

  final ProcessManager processManager;

  /// 待つ上限。**端末側の確認ダイアログで止まることがある。**
  final Duration timeout;

  /// 利用者への表示。テストから差し替える。
  final void Function(String line) onMessage;

  /// 利用者の入力。テストから差し替える。
  final String? Function() readLine;

  static const Duration defaultTimeout = Duration(minutes: 5);

  /// 署名がぶつかった時に `adb` が返す文字列。
  static const String signatureConflictMarker =
      'INSTALL_FAILED_UPDATE_INCOMPATIBLE';

  /// 既定の suffix（設計 §5.3 の選択2）。
  static const String defaultSuffix = '.preview';

  static const String configFileName = 'fluse.yaml';
  static const String suffixKey = 'applicationIdSuffix';

  static String? _readStdin() => stdin.readLineSync();

  // ------------------------------------------------------------------ 列挙

  /// 繋がっている端末（`fluse devices` の実体）。
  Future<List<AndroidDevice>> listDevices() async {
    if (!processManager.canRun('adb')) {
      throw const DeviceInstallException.adbNotFound();
    }

    final ProcessResult result = await _run(<String>['adb', 'devices', '-l']);
    if (result.exitCode != 0) {
      throw DeviceInstallException.installFailed(
        exitCodeValue: result.exitCode,
        detail: _trimmed(result.stderr),
      );
    }
    return parseDevices('${result.stdout}');
  }

  /// `adb devices -l` の出力を読む。
  ///
  /// **`unauthorized` と `offline` は外す。** 一覧に出すと、選んでから
  /// 「入れられません」と言うことになる。使えるものだけを見せる。
  static List<AndroidDevice> parseDevices(String output) {
    final List<AndroidDevice> devices = <AndroidDevice>[];
    for (final String raw in const LineSplitter().convert(output)) {
      final String line = raw.trim();
      if (line.isEmpty || line.startsWith('List of devices')) {
        continue;
      }
      final List<String> parts = line.split(RegExp(r'\s+'));
      if (parts.length < 2) {
        continue;
      }
      if (parts[1] != 'device') {
        continue;
      }

      final Map<String, String> fields = <String, String>{};
      for (final String token in parts.skip(2)) {
        final int at = token.indexOf(':');
        if (at > 0) {
          fields[token.substring(0, at)] = token.substring(at + 1);
        }
      }

      final String serial = parts.first;
      devices.add(
        AndroidDevice(
          serial: serial,
          // 何も無ければ serial を出す。空欄だと選びようが無い。
          model: fields['model']?.replaceAll('_', ' ') ?? serial,
          product: fields['product'],
          transportId: fields['transport_id'],
        ),
      );
    }
    return List<AndroidDevice>.unmodifiable(devices);
  }

  // ------------------------------------------------------------ インストール

  /// [apk] を [device] へ入れる。
  ///
  /// 署名がぶつかったら、**黙って上書きせず**利用者に尋ねる（設計 §5.3）。
  Future<InstallOutcome> install({
    required AndroidDevice device,
    required File apk,
    required String applicationId,
    required Directory projectRoot,
  }) async {
    final ProcessResult first = await _install(device, apk);
    if (first.exitCode == 0 && !_hasConflict(first)) {
      return Installed(device: device, reinstalled: false);
    }

    if (!_hasConflict(first)) {
      throw DeviceInstallException.installFailed(
        exitCodeValue: first.exitCode,
        detail: _trimmed(first.stderr) ?? _trimmed(first.stdout),
      );
    }

    switch (askOnConflict(applicationId)) {
      case SignatureConflictChoice.uninstall:
        await _uninstall(device, applicationId);
        final ProcessResult retry = await _install(device, apk);
        if (retry.exitCode != 0 || _hasConflict(retry)) {
          throw DeviceInstallException.installFailed(
            exitCodeValue: retry.exitCode,
            detail: _trimmed(retry.stderr) ?? _trimmed(retry.stdout),
          );
        }
        return Installed(device: device, reinstalled: true);

      case SignatureConflictChoice.useSuffix:
        await persistSuffix(projectRoot, defaultSuffix);
        onMessage(
          '$configFileName に $suffixKey: $defaultSuffix を書きました。'
          '作り直してから入れ直してください',
        );
        return const NeedsRebuild(applicationIdSuffix: defaultSuffix);

      case SignatureConflictChoice.abort:
        // **何も残さない。** 選ばなかったことが分かる状態で戻す。
        return const Aborted();
    }
  }

  /// 署名がぶつかったことを伝えて選んでもらう（設計 §5.3）。
  SignatureConflictChoice askOnConflict(String applicationId) {
    onMessage(conflictMessage(applicationId));

    // **黙って進めない。** 選ぶまで待つ。
    while (true) {
      onMessage('番号を入力してください [1-3]: ');
      final String? answer = readLine()?.trim();
      switch (answer) {
        case '1':
          return SignatureConflictChoice.uninstall;
        case '2':
          return SignatureConflictChoice.useSuffix;
        case '3':
          return SignatureConflictChoice.abort;
        case null:
          // 入力が閉じた（パイプ越しなど）。勝手に決めない。
          return SignatureConflictChoice.abort;
        default:
          onMessage('1 から 3 で答えてください');
      }
    }
  }

  /// 設計 §5.3 の文言。
  static String conflictMessage(String applicationId) =>
      '''
✗ インストールに失敗しました ($signatureConflictMarker)

  端末に同じ applicationId ($applicationId) のアプリが
  別の署名でインストールされています。

  どうしますか？
    1) 既存アプリをアンインストールして続行  (adb uninstall $applicationId)
    2) Preview App を別IDでインストール      ($suffixKey $defaultSuffix)
    3) 中止''';

  /// `fluse.yaml` に suffix を書く。
  ///
  /// **他の設定を消さない。** `yaml_edit` で必要な範囲だけ差し替える。
  /// 無ければ最小の内容で作る。
  Future<void> persistSuffix(Directory projectRoot, String suffix) async {
    final String path = p.join(projectRoot.path, configFileName);
    final File file = File(path);

    final YamlEditor editor;
    try {
      if (file.existsSync()) {
        editor = YamlEditor(await file.readAsString());
        final YamlNode root = editor.parseAt(
          <Object>[],
          orElse: () => wrapAsYamlNode(null),
        );
        if (root.value != null && root is! YamlMap) {
          throw DeviceInstallException.suffixNotPersisted(
            path: path,
            detail: 'YAML のマップではありません',
          );
        }
        if (root.value == null) {
          editor.update(<Object>[], wrapAsYamlNode(<String, Object?>{}));
        }
      } else {
        editor = YamlEditor('');
        editor.update(<Object>[], wrapAsYamlNode(<String, Object?>{}));
      }
      editor.update(<Object>[suffixKey], suffix);
    } on DeviceInstallException {
      rethrow;
    } on Exception catch (error) {
      throw DeviceInstallException.suffixNotPersisted(
        path: path,
        detail: '$error',
      );
    }

    // 別の場所へ書いてから置き換える。途中で落ちても半端な内容が残らない。
    final File temporary = File('$path.tmp');
    try {
      await temporary.writeAsString(editor.toString());
      await temporary.rename(path);
    } on Object {
      if (temporary.existsSync()) {
        temporary.deleteSync();
      }
      rethrow;
    }
  }

  // ------------------------------------------------------------------ adb

  Future<ProcessResult> _install(AndroidDevice device, File apk) =>
      _run(<String>['adb', '-s', device.serial, 'install', '-r', apk.path]);

  Future<ProcessResult> _uninstall(
    AndroidDevice device,
    String applicationId,
  ) => _run(<String>['adb', '-s', device.serial, 'uninstall', applicationId]);

  /// 署名の食い違いか。
  ///
  /// **終了コードだけでは分からない。** `adb install` は失敗しても 0 を
  /// 返すことがあり、理由は出力に載る。
  static bool _hasConflict(ProcessResult result) =>
      '${result.stdout}${result.stderr}'.contains(signatureConflictMarker);

  /// 待ちすぎないように動かす。
  Future<ProcessResult> _run(List<String> command) async {
    final Process process;
    try {
      process = await processManager.start(command);
    } on ProcessException catch (error) {
      throw DeviceInstallException.adbUnavailable(detail: error.message);
    }

    final Future<String> out = _collect(process.stdout);
    final Future<String> err = _collect(process.stderr);

    final int exitCode;
    try {
      exitCode = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      // **掴んだままにしない。** 次の adb が待たされる。
      process.kill(ProcessSignal.sigkill);
      unawaited(out.catchError((Object _) => ''));
      unawaited(err.catchError((Object _) => ''));
      throw const DeviceInstallException.timedOut();
    }

    return ProcessResult(process.pid, exitCode, await out, await err);
  }

  static Future<String> _collect(Stream<List<int>> stream) =>
      stream.transform(const Utf8Decoder(allowMalformed: true)).join();

  static String? _trimmed(Object? value) {
    if (value is! String) {
      return null;
    }
    final String trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
