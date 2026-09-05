import 'dart:math';

import 'package:fluse_protocol/fluse_protocol.dart';

import 'auth_crypto.dart';
import 'device_store.dart';
import 'fluse_logger.dart';
import 'session_contracts.dart';

/// QR / コンソール / HTTP `/` に出す1回限りのトークン（設計 §6.1）。
final class PairingToken {
  PairingToken({required this.value, required this.expiresAt});

  /// 平文のトークン。
  final String value;

  /// この時刻を過ぎたら無効。
  final DateTime expiresAt;

  bool _consumed = false;

  /// ペアリングに使われたか。
  ///
  /// **1回限り**（設計 §6.1）。盗聴された値の再利用を防ぐ唯一の手当てなので、
  /// 成立した瞬間に落とす。
  bool get isConsumed => _consumed;

  /// [now] の時点で使えるか。
  bool isValidAt(DateTime now) => !_consumed && now.isBefore(expiresAt);

  /// 使用済みにする。
  void consume() => _consumed = true;

  /// **値は含めない。** 例外文やログに混ざると漏れる。
  @override
  String toString() => 'PairingToken(expiresAt: $expiresAt)';
}

/// ペアリング成立時に発行する永続トークン（設計 §6.1）。
final class DeviceToken {
  const DeviceToken({required this.deviceId, required this.value});

  final String deviceId;

  /// 平文のトークン。端末は EncryptedSharedPreferences に保存する。
  final String value;

  /// **値は含めない。**
  @override
  String toString() => 'DeviceToken($deviceId)';
}

/// [SessionManager.authenticate] の結果。
sealed class AuthResult {
  const AuthResult();
}

/// 受け入れた。[accept] をそのまま端末へ送る。
final class AuthAccepted extends AuthResult {
  const AuthAccepted(this.accept);

  final AcceptMessage accept;

  @override
  String toString() => 'AuthAccepted(${accept.sessionId})';
}

/// 拒否した。[reject] をそのまま端末へ送って切る。
final class AuthRejected extends AuthResult {
  AuthRejected(this.code, String message)
    : reject = RejectMessage.of(code, message);

  final RejectCode code;
  final RejectMessage reject;

  @override
  String toString() => 'AuthRejected(${code.wireValue})';
}

/// ペアリングとセッションの管理（設計 §2.2.3(f) / §6.1）。
///
/// **`hello` の検証順序は設計 §3.1 で決まっている。** protocolVersion →
/// projectId → flutterRevision → appVersion → token。順序を変えると、
/// 本来もっと具体的に案内できる不一致が `AUTH_FAILED` に化けて、
/// 利用者が「トークンが違う」と誤解する。
///
/// 期待値は注入で受け取る。ここでは `projectId` も指紋も計算しない。
/// 計算元（`ProjectAnalyzer` / `Fingerprint`）は Phase 5 のタスク。
final class SessionManager {
  SessionManager({
    required this.expectedProjectId,
    required this.expectedFlutterRevision,
    required this.expectedAppVersion,
    required DeviceStoreContract deviceStore,
    this.expectedProtocolVersion = fluseProtocolVersion,
    this.heartbeatIntervalMs = defaultHeartbeatIntervalMs,
    this.pairingTokenTtl = defaultPairingTokenTtl,
    DateTime Function()? clock,
    Random? random,
    FluseLogger? logger,
  }) : _deviceStore = deviceStore,
       _clock = clock ?? DateTime.now,
       _random = random,
       _logger = logger;

  /// `pairingToken` の有効期間（設計 §6.1）。
  static const Duration defaultPairingTokenTtl = Duration(minutes: 10);

  /// 端末に `ping` を送らせる間隔。
  static const int defaultHeartbeatIntervalMs = 15000;

  /// `pubspec.yaml` の name + プロジェクト絶対パスの sha256 先頭16桁。
  final String expectedProjectId;

  /// `fluse init` の APK をビルドした Flutter SDK のリビジョン。
  final String expectedFlutterRevision;

  /// 現在の指紋。端末の Preview App が古ければ食い違う。
  final String expectedAppVersion;

  /// 受け付けるプロトコル版。
  final int expectedProtocolVersion;

  /// `accept` に載せる heartbeat 間隔。
  final int heartbeatIntervalMs;

  /// `pairingToken` の有効期間。
  final Duration pairingTokenTtl;

  final DeviceStoreContract _deviceStore;
  final DateTime Function() _clock;
  final Random? _random;
  final FluseLogger? _logger;

  PairingToken? _pairingToken;

  /// 接続中の端末。空いていれば null。
  ///
  /// Phase1 は1台のみ（設計 §10-10）。
  String? _activeDeviceId;
  String? _activeSessionId;

  /// 今有効な `pairingToken`。まだ発行していなければ null。
  PairingToken? get pairingToken => _pairingToken;

  /// 接続中の端末の `deviceId`。空いていれば null。
  String? get activeDeviceId => _activeDeviceId;

  /// 接続中のセッション ID。空いていれば null。
  String? get activeSessionId => _activeSessionId;

  /// 新しい `pairingToken` を発行する。
  ///
  /// **前のトークンは即座に失効する。** 有効な値を複数持つと、古い QR の
  /// 写真からでも入れてしまう。常に1つだけにする。
  PairingToken issuePairingToken() {
    final String value = generateToken(random: _random);
    // ログに出す前に登録する。順序を逆にすると、この間に出た行に平文が残る。
    _logger?.addSecret(value);

    final PairingToken token = PairingToken(
      value: value,
      expiresAt: _clock().add(pairingTokenTtl),
    );
    _pairingToken = token;
    _logger?.info(
      'ペアリングトークンを発行しました',
      fields: <String, Object?>{'expiresAt': token.expiresAt.toIso8601String()},
    );
    return token;
  }

  /// 今の `pairingToken` を失効させる。セッション終了時に呼ぶ。
  void expirePairingToken() => _pairingToken = null;

  /// `hello` を検証して受け入れるか決める。
  ///
  /// 非同期にしていないのは、この経路に待つ処理が無いため。`DeviceStore` の
  /// I/O は同期で、`Future` を返しても即座に完了するだけになる。呼び出し側は
  /// `await` してもしなくても同じに動く。
  AuthResult authenticate(HelloMessage hello) {
    // --- 設計 §3.1 の順序。前の段で落ちたら後ろは見ない。 ---

    if (hello.protocolVersion != expectedProtocolVersion) {
      return _reject(
        RejectCode.protocolMismatch,
        'プロトコル版が違います（サーバ: $expectedProtocolVersion, '
        'アプリ: ${hello.protocolVersion}）。fluse init をやり直してください',
        hello,
      );
    }

    if (hello.projectId != expectedProjectId) {
      return _reject(
        RejectCode.projectMismatch,
        '別のプロジェクトの Preview App です。'
        'このプロジェクトで fluse init をやり直してください',
        hello,
      );
    }

    if (hello.flutterRevision != expectedFlutterRevision) {
      return _reject(
        RejectCode.revisionMismatch,
        'Flutter SDK のリビジョンが違います（サーバ: $expectedFlutterRevision, '
        'アプリ: ${hello.flutterRevision}）。fluse init をやり直してください',
        hello,
      );
    }

    if (hello.appVersion != expectedAppVersion) {
      return _reject(
        RejectCode.appOutdated,
        'Preview App が古くなっています。fluse init をやり直してください',
        hello,
      );
    }

    // **トークン検証より前に見る。** 後ろに置くと、2台目が来ただけで
    // pairingToken が消費され、本来繋ぐはずの1台目が入れなくなる。
    final String? active = _activeDeviceId;
    if (active != null && active != hello.deviceId) {
      return _reject(
        RejectCode.tooManyDevices,
        '既に別の端末が接続しています（Phase1 は1台のみ）',
        hello,
      );
    }

    // --- token ---

    // **両方載っているのは受け付けない。** どちらを見るかで結果が変わり、
    // 片方だけ失敗したときの挙動が説明できなくなる。正しい端末は初回に
    // pairingToken、以後は deviceToken の**どちらか一方**を送る。
    if (hello.pairingToken != null && hello.deviceToken != null) {
      return _reject(
        RejectCode.authFailed,
        'pairingToken と deviceToken は同時に送れません',
        hello,
      );
    }

    final String? pairing = hello.pairingToken;
    if (pairing != null) {
      final PairingToken? issued = _pairingToken;
      if (issued == null ||
          !issued.isValidAt(_clock()) ||
          !constantTimeEquals(issued.value, pairing)) {
        return _reject(
          RejectCode.authFailed,
          'ペアリングトークンが無効です。fluse start の QR を読み直してください',
          hello,
        );
      }

      // 成立した瞬間に落とす。ここを後回しにすると、同じ QR で
      // 何台でも入れてしまう。
      issued.consume();
      final DeviceToken device = issueDeviceToken(
        hello.deviceId,
        deviceName: hello.deviceName,
      );
      return _accept(hello, issuedDeviceToken: device.value);
    }

    final String? deviceToken = hello.deviceToken;
    if (deviceToken != null) {
      final DeviceRecord? record = _deviceStore.lookup(hello.deviceId);
      if (record == null ||
          !constantTimeEquals(record.deviceToken, deviceToken)) {
        return _reject(
          RejectCode.authFailed,
          'この端末は登録されていません。QR を読み直してペアリングしてください',
          hello,
        );
      }
      return _accept(hello);
    }

    return _reject(
      RejectCode.authFailed,
      'トークンがありません。QR を読み直してペアリングしてください',
      hello,
    );
  }

  /// `deviceToken` を発行して `devices.json` に保存する。
  DeviceToken issueDeviceToken(String deviceId, {String deviceName = ''}) {
    final String value = generateToken(random: _random);
    // ログに出す前に登録する。
    _logger?.addSecret(value);

    _deviceStore.upsert(
      DeviceRecord(
        deviceId: deviceId,
        deviceToken: value,
        deviceName: deviceName,
        issuedAt: _clock().toUtc(),
      ),
    );
    _logger?.info(
      'デバイストークンを発行しました',
      fields: <String, Object?>{'deviceId': deviceId},
    );
    return DeviceToken(deviceId: deviceId, value: value);
  }

  /// 端末の登録を取り消す。以後はペアリングからやり直しになる。
  void revoke(String deviceId) {
    _deviceStore.remove(deviceId);
    if (_activeDeviceId == deviceId) {
      endSession();
    }
    _logger?.info(
      '端末の登録を取り消しました',
      fields: <String, Object?>{'deviceId': deviceId},
    );
  }

  /// 接続中のセッションを解放する。切断時に呼ぶ。
  ///
  /// **呼び忘れると2台目が永久に繋がらない。** 1台目が落ちても
  /// `_activeDeviceId` が残り、以後の接続が全部 `TOO_MANY_DEVICES` になる。
  void endSession() {
    _activeDeviceId = null;
    _activeSessionId = null;
  }

  AuthAccepted _accept(HelloMessage hello, {String? issuedDeviceToken}) {
    final String sessionId = generateToken(random: _random);
    _activeDeviceId = hello.deviceId;
    _activeSessionId = sessionId;

    _logger?.info(
      '端末を受け入れました',
      fields: <String, Object?>{
        'deviceId': hello.deviceId,
        'deviceName': hello.deviceName,
        'paired': issuedDeviceToken != null,
      },
    );
    return AuthAccepted(
      AcceptMessage(
        sessionId: sessionId,
        heartbeatIntervalMs: heartbeatIntervalMs,
        issuedDeviceToken: issuedDeviceToken,
      ),
    );
  }

  AuthRejected _reject(RejectCode code, String message, HelloMessage hello) {
    _logger?.warn(
      '端末を拒否しました',
      fields: <String, Object?>{
        'code': code.wireValue,
        'deviceId': hello.deviceId,
        'deviceName': hello.deviceName,
      },
    );
    return AuthRejected(code, message);
  }
}
