import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:process/process.dart';

import 'keystore_exception.dart';
import 'keystore_info.dart';

/// debug 用の keystore を用意する（設計 §2.2.2）。
///
/// **本番の署名鍵には触らない。** `fluse` 専用の鍵を作り、プレビュー用の
/// APK だけをそれで署名する。利用者の鍵を借りると、`fluse` を試しただけで
/// 配布物の署名に関わることになる。
///
/// この判断の副作用として、既に入っている debug ビルドと署名が食い違い、
/// `INSTALL_FAILED_UPDATE_INCOMPATIBLE` が起きうる。その扱いは Task 5.6。
final class KeystoreManager {
  const KeystoreManager({
    this.processManager = const LocalProcessManager(),
    bool? isWindows,
  }) : _isWindows = isWindows;

  /// 外部プロセスの実行。テストから差し替える。
  final ProcessManager processManager;

  final bool? _isWindows;

  bool get _windows => _isWindows ?? Platform.isWindows;

  /// keystore を置く場所。
  static const String directoryName = 'keystore';

  static const String keystoreFileName = 'fluse-debug.keystore';

  /// パスワードの置き場。**600 で置く**（設計 §9.2）。
  static const String passwordFileName = 'keystore.json';

  /// 鍵の別名。
  static const String alias = 'fluse-debug';

  /// このファイル形式の版。
  static const int currentSchemaVersion = 1;

  /// パスワードのバイト数。
  static const int passwordByteLength = 32;

  /// 鍵の有効期間（日）。
  ///
  /// **短いと切れた時に入らなくなる。** 期限切れの鍵で署名した APK は
  /// 端末が受け付けない。debug 用なので長く取る（Android の debug 鍵と
  /// 同じ 30 年相当）。
  static const int validityDays = 10950;

  /// 証明書の名前。debug 用と分かる固定値にする。
  static const String distinguishedName =
      'CN=fluse debug, OU=fluse, O=fluse, C=US';

  /// 鍵の長さ。
  static const int keySize = 2048;

  /// [previewDir]（`.flutter_preview/`）に keystore を用意する。
  ///
  /// 既にあれば作り直さない。**作り直すと署名が変わり**、端末に入っている
  /// Preview App を上書きできなくなる。
  Future<KeystoreInfo> ensure(Directory previewDir) async {
    final Directory dir = Directory(p.join(previewDir.path, directoryName));
    final File keystore = File(p.join(dir.path, keystoreFileName));
    final File passwords = File(p.join(dir.path, passwordFileName));

    // **両方揃っている時だけ使い回す。** 片方だけあっても開けない。
    if (keystore.existsSync() && passwords.existsSync()) {
      return _read(keystore, passwords);
    }

    // **作る前に確かめる。** 途中まで作って落ちると、次回に中途半端な
    // ものを使い回そうとする。
    if (!await _canRunKeytool()) {
      throw const KeystoreException.keytoolNotFound();
    }

    await dir.create(recursive: true);

    final String storePassword = generatePassword();
    // store と key で分ける必要は無いが、揃えておくと PKCS12 で警告が出ない。
    final String keyPassword = storePassword;

    // **作り直す前に消す。** 片方だけ残っていると `keytool` が
    // 「別名が既にある」と言って失敗する。
    if (keystore.existsSync()) {
      keystore.deleteSync();
    }

    await _runKeytool(
      keystore: keystore,
      storePassword: storePassword,
      keyPassword: keyPassword,
    );

    if (!keystore.existsSync()) {
      throw KeystoreException.missingOutput(path: keystore.path);
    }

    await _writePasswords(
      passwords,
      storePassword: storePassword,
      keyPassword: keyPassword,
    );

    return KeystoreInfo(
      file: keystore,
      alias: alias,
      storePassword: storePassword,
      keyPassword: keyPassword,
    );
  }

  /// 予測されにくいパスワードを作る。
  ///
  /// `fluse_server` の `generateToken` と同じ作り方。**あちらを呼ばない。**
  /// `fluse_builder` から `fluse_server` へ依存すると、設計 §2.1 の
  /// レイヤリングが崩れる。
  static String generatePassword({Random? random}) {
    final Random source = random ?? Random.secure();
    final List<int> bytes = List<int>.generate(
      passwordByteLength,
      (int _) => source.nextInt(256),
      growable: false,
    );
    // `keytool` の引数に載るため、記号の少ない base64url にする。
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  // ---------------------------------------------------------------- keytool

  Future<bool> _canRunKeytool() async {
    try {
      return processManager.canRun('keytool');
    } on Object catch (error) {
      throw KeystoreException.keytoolUnavailable(detail: '$error');
    }
  }

  Future<void> _runKeytool({
    required File keystore,
    required String storePassword,
    required String keyPassword,
  }) async {
    final List<String> command = <String>[
      'keytool',
      '-genkeypair',
      '-keystore',
      keystore.path,
      '-storetype',
      'PKCS12',
      '-alias',
      alias,
      '-keyalg',
      'RSA',
      '-keysize',
      '$keySize',
      '-validity',
      '$validityDays',
      '-dname',
      distinguishedName,
      '-storepass',
      storePassword,
      '-keypass',
      keyPassword,
    ];

    final ProcessResult result;
    try {
      result = await processManager.run(command);
    } on ProcessException catch (error) {
      throw KeystoreException.keytoolUnavailable(detail: error.message);
    }

    if (result.exitCode != 0) {
      // **コマンド列は載せない。** `-storepass` がそのまま出る。
      throw KeystoreException.keytoolFailed(
        exitCode: result.exitCode,
        detail: _trimmed(result.stderr),
      );
    }
  }

  static String? _trimmed(Object? stderr) {
    if (stderr is! String) {
      return null;
    }
    final String trimmed = stderr.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  // -------------------------------------------------------------- パスワード

  Future<KeystoreInfo> _read(File keystore, File passwords) async {
    final Object? document;
    try {
      document = jsonDecode(await passwords.readAsString());
    } on FormatException catch (error) {
      throw KeystoreException.storeUnreadable(
        path: passwords.path,
        detail: error.message,
      );
    }
    if (document is! Map<String, Object?>) {
      throw KeystoreException.storeUnreadable(
        path: passwords.path,
        detail: 'JSON のオブジェクトではありません',
      );
    }

    final Object? version = document['schemaVersion'];
    if (version is! int || version < 1 || version > currentSchemaVersion) {
      throw KeystoreException.storeUnreadable(
        path: passwords.path,
        detail: 'schemaVersion が不正です',
      );
    }

    final Object? storedAlias = document['alias'];
    final Object? storePassword = document['storePassword'];
    final Object? keyPassword = document['keyPassword'];
    if (storedAlias is! String ||
        storePassword is! String ||
        keyPassword is! String) {
      throw KeystoreException.storeUnreadable(
        path: passwords.path,
        detail: '必要な項目が足りません',
      );
    }

    return KeystoreInfo(
      file: keystore,
      alias: storedAlias,
      storePassword: storePassword,
      keyPassword: keyPassword,
    );
  }

  /// パスワードを書く。
  ///
  /// **書き終える前に読ませない。** 別のファイルへ書いてから置き換える。
  /// 途中で落ちても、半端な内容が残らない。
  Future<void> _writePasswords(
    File file, {
    required String storePassword,
    required String keyPassword,
  }) async {
    final Map<String, Object?> document = <String, Object?>{
      'schemaVersion': currentSchemaVersion,
      'alias': alias,
      'storePassword': storePassword,
      'keyPassword': keyPassword,
    };

    final File temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(document)}\n',
    );
    // **先に絞ってから置き換える。** 置き換えてから絞ると、その間だけ
    // 誰でも読める状態になる。
    await _restrict(temporary);
    await temporary.rename(file.path);
  }

  /// 持ち主だけが読めるようにする（設計 §9.2）。
  ///
  /// Dart にパーミッションを変える手段が無いため `chmod` を呼ぶ。
  /// Windows には POSIX のパーミッションが無いので何もしない。
  Future<void> _restrict(File file) async {
    if (_windows) {
      return;
    }
    final ProcessResult result;
    try {
      result = await processManager.run(<String>['chmod', '600', file.path]);
    } on ProcessException catch (error) {
      throw KeystoreException.keytoolUnavailable(detail: error.message);
    }
    if (result.exitCode != 0) {
      // **黙って続けない。** 読めるまま残ると、パスワードが他の利用者に
      // 見える状態になる。
      throw KeystoreException.storeUnreadable(
        path: file.path,
        detail: 'パーミッションを 600 にできません: ${_trimmed(result.stderr) ?? ''}',
      );
    }
  }
}
