import 'package:fluse_protocol/fluse_protocol.dart';
import 'package:fluse_server/fluse_server.dart';
import 'package:fluse_server/testing.dart';
import 'package:test/test.dart';

/// `devices.json` を触らずに登録状態だけを持つ [DeviceStoreContract]。
final class FakeDeviceStore implements DeviceStoreContract {
  final Map<String, DeviceRecord> records = <String, DeviceRecord>{};

  /// upsert された順の記録。呼ばれたことの検証に使う。
  final List<DeviceRecord> upserts = <DeviceRecord>[];
  final List<String> removals = <String>[];

  @override
  DeviceRecord? lookup(String deviceId) => records[deviceId];

  @override
  void upsert(DeviceRecord record) {
    records[record.deviceId] = record;
    upserts.add(record);
  }

  @override
  void remove(String deviceId) {
    records.remove(deviceId);
    removals.add(deviceId);
  }
}

void main() {
  const String projectId = 'counter_app-0123456789abcdef';
  const String flutterRevision = '42d3d75a56';
  const String appVersion = 'fingerprint-aaaa';

  late FakeDeviceStore store;
  late MemoryLogSink sink;
  late FluseLogger logger;
  late DateTime now;

  SessionManager build({
    String expectedProjectId = projectId,
    String expectedFlutterRevision = flutterRevision,
    String expectedAppVersion = appVersion,
  }) => SessionManager(
    expectedProjectId: expectedProjectId,
    expectedFlutterRevision: expectedFlutterRevision,
    expectedAppVersion: expectedAppVersion,
    deviceStore: store,
    clock: () => now,
    logger: logger,
  );

  HelloMessage hello({
    int protocolVersion = fluseProtocolVersion,
    String id = projectId,
    String revision = flutterRevision,
    String version = appVersion,
    String deviceId = 'device-1',
    String deviceName = 'Pixel 8',
    String? pairingToken,
    String? deviceToken,
  }) => HelloMessage(
    protocolVersion: protocolVersion,
    projectId: id,
    flutterRevision: revision,
    dartVersion: '3.11.5',
    appVersion: version,
    deviceId: deviceId,
    deviceName: deviceName,
    pairingToken: pairingToken,
    deviceToken: deviceToken,
  );

  /// 拒否されたことと、その理由コードを取り出す。
  RejectCode rejectedCode(AuthResult result) {
    expect(result, isA<AuthRejected>());
    return (result as AuthRejected).code;
  }

  AcceptMessage accepted(AuthResult result) {
    expect(result, isA<AuthAccepted>());
    return (result as AuthAccepted).accept;
  }

  setUp(() {
    store = FakeDeviceStore();
    sink = MemoryLogSink();
    logger = FluseLogger(
      sinks: <FluseLogSink>[sink],
      minimumLevel: FluseLogLevel.debug,
    );
    now = DateTime.utc(2026, 5, 1, 12);
  });

  group('reject コード', () {
    test('protocolVersion が違えば PROTOCOL_MISMATCH', () {
      final SessionManager manager = build();
      final PairingToken token = manager.issuePairingToken();

      final AuthResult result = manager.authenticate(
        hello(
          protocolVersion: fluseProtocolVersion + 1,
          pairingToken: token.value,
        ),
      );

      expect(rejectedCode(result), RejectCode.protocolMismatch);
    });

    test('projectId が違えば PROJECT_MISMATCH', () {
      final SessionManager manager = build();
      final PairingToken token = manager.issuePairingToken();

      final AuthResult result = manager.authenticate(
        hello(id: 'other_app-ffffffffffffffff', pairingToken: token.value),
      );

      expect(rejectedCode(result), RejectCode.projectMismatch);
    });

    test('flutterRevision が違えば REVISION_MISMATCH', () {
      final SessionManager manager = build();
      final PairingToken token = manager.issuePairingToken();

      final AuthResult result = manager.authenticate(
        hello(revision: 'deadbeef', pairingToken: token.value),
      );

      expect(rejectedCode(result), RejectCode.revisionMismatch);
    });

    test('appVersion が違えば APP_OUTDATED', () {
      final SessionManager manager = build();
      final PairingToken token = manager.issuePairingToken();

      final AuthResult result = manager.authenticate(
        hello(version: 'fingerprint-bbbb', pairingToken: token.value),
      );

      expect(rejectedCode(result), RejectCode.appOutdated);
    });

    test('トークンが違えば AUTH_FAILED', () {
      final SessionManager manager = build();
      manager.issuePairingToken();

      final AuthResult result = manager.authenticate(
        hello(pairingToken: 'まったく違うトークン'),
      );

      expect(rejectedCode(result), RejectCode.authFailed);
    });

    test('pairingToken と deviceToken を同時に送れば AUTH_FAILED', () {
      // どちらを見るかで結果が変わると、失敗の説明ができなくなる。
      final SessionManager manager = build();
      final PairingToken pairing = manager.issuePairingToken();
      final DeviceToken device = manager.issueDeviceToken('device-1');

      final AuthResult result = manager.authenticate(
        hello(pairingToken: pairing.value, deviceToken: device.value),
      );

      expect(rejectedCode(result), RejectCode.authFailed);
      expect(pairing.isConsumed, isFalse);
    });

    test('トークンが無ければ AUTH_FAILED', () {
      final SessionManager manager = build();
      manager.issuePairingToken();

      expect(
        rejectedCode(manager.authenticate(hello())),
        RejectCode.authFailed,
      );
    });

    test('2台目は TOO_MANY_DEVICES', () {
      final SessionManager manager = build();
      final PairingToken token = manager.issuePairingToken();
      accepted(manager.authenticate(hello(pairingToken: token.value)));

      final PairingToken second = manager.issuePairingToken();
      final AuthResult result = manager.authenticate(
        hello(deviceId: 'device-2', pairingToken: second.value),
      );

      expect(rejectedCode(result), RejectCode.tooManyDevices);
    });

    test('2台目の拒否では pairingToken を消費しない', () {
      // 消費してしまうと、繋ぐはずの1台目が入れなくなる。
      final SessionManager manager = build();
      final PairingToken first = manager.issuePairingToken();
      accepted(manager.authenticate(hello(pairingToken: first.value)));

      final PairingToken second = manager.issuePairingToken();
      manager.authenticate(
        hello(deviceId: 'device-2', pairingToken: second.value),
      );

      expect(second.isConsumed, isFalse);
    });

    test('endSession の後は別の端末を受け入れる', () {
      final SessionManager manager = build();
      final PairingToken first = manager.issuePairingToken();
      accepted(manager.authenticate(hello(pairingToken: first.value)));

      manager.endSession();
      final PairingToken second = manager.issuePairingToken();
      final AuthResult result = manager.authenticate(
        hello(deviceId: 'device-2', pairingToken: second.value),
      );

      expect(accepted(result).issuedDeviceToken, isNotNull);
    });
  });

  group('検証順序（設計 §3.1）', () {
    test('全部食い違っていれば protocolVersion が最初に出る', () {
      final SessionManager manager = build();

      final AuthResult result = manager.authenticate(
        hello(
          protocolVersion: fluseProtocolVersion + 1,
          id: 'other',
          revision: 'other',
          version: 'other',
        ),
      );

      expect(rejectedCode(result), RejectCode.protocolMismatch);
    });

    test('projectId と revision が食い違えば projectId が先', () {
      final SessionManager manager = build();

      final AuthResult result = manager.authenticate(
        hello(id: 'other', revision: 'other', version: 'other'),
      );

      expect(rejectedCode(result), RejectCode.projectMismatch);
    });

    test('revision と appVersion が食い違えば revision が先', () {
      final SessionManager manager = build();

      final AuthResult result = manager.authenticate(
        hello(revision: 'other', version: 'other'),
      );

      expect(rejectedCode(result), RejectCode.revisionMismatch);
    });

    test('appVersion の不一致はトークン検証より先', () {
      // 逆順にすると「アプリが古い」が AUTH_FAILED に化けて誤解を招く。
      final SessionManager manager = build();

      final AuthResult result = manager.authenticate(
        hello(version: 'other', pairingToken: 'でたらめ'),
      );

      expect(rejectedCode(result), RejectCode.appOutdated);
    });
  });

  group('pairingToken', () {
    test('成功すると deviceToken を発行して devices.json に保存する', () {
      final SessionManager manager = build();
      final PairingToken token = manager.issuePairingToken();

      final AcceptMessage accept = accepted(
        manager.authenticate(hello(pairingToken: token.value)),
      );

      expect(accept.issuedDeviceToken, isNotNull);
      expect(store.upserts, hasLength(1));
      expect(store.upserts.single.deviceId, 'device-1');
      expect(store.upserts.single.deviceToken, accept.issuedDeviceToken);
      expect(store.upserts.single.deviceName, 'Pixel 8');
      expect(store.upserts.single.issuedAt, now);
    });

    test('TTL を過ぎたら AUTH_FAILED', () {
      final SessionManager manager = build();
      final PairingToken token = manager.issuePairingToken();

      now = now.add(
        SessionManager.defaultPairingTokenTtl + const Duration(seconds: 1),
      );

      expect(
        rejectedCode(manager.authenticate(hello(pairingToken: token.value))),
        RejectCode.authFailed,
      );
    });

    test('TTL 内なら受け入れる', () {
      final SessionManager manager = build();
      final PairingToken token = manager.issuePairingToken();

      now = now.add(
        SessionManager.defaultPairingTokenTtl - const Duration(seconds: 1),
      );

      expect(
        accepted(
          manager.authenticate(hello(pairingToken: token.value)),
        ).sessionId,
        isNotEmpty,
      );
    });

    test('1回使ったら再利用できない', () {
      final SessionManager manager = build();
      final PairingToken token = manager.issuePairingToken();
      accepted(manager.authenticate(hello(pairingToken: token.value)));
      manager.endSession();

      expect(
        rejectedCode(manager.authenticate(hello(pairingToken: token.value))),
        RejectCode.authFailed,
      );
    });

    test('再発行すると前のトークンは通らない', () {
      // 有効な値が複数あると、古い QR の写真からでも入れてしまう。
      final SessionManager manager = build();
      final PairingToken first = manager.issuePairingToken();
      manager.issuePairingToken();

      expect(
        rejectedCode(manager.authenticate(hello(pairingToken: first.value))),
        RejectCode.authFailed,
      );
    });

    test('発行前の認証は AUTH_FAILED', () {
      final SessionManager manager = build();

      expect(
        rejectedCode(manager.authenticate(hello(pairingToken: 'なにか'))),
        RejectCode.authFailed,
      );
    });
  });

  group('deviceToken', () {
    test('登録済みなら受け入れ、新しいトークンは発行しない', () {
      final SessionManager manager = build();
      final DeviceToken issued = manager.issueDeviceToken('device-1');

      final AcceptMessage accept = accepted(
        manager.authenticate(hello(deviceToken: issued.value)),
      );

      expect(accept.issuedDeviceToken, isNull);
      expect(
        accept.heartbeatIntervalMs,
        SessionManager.defaultHeartbeatIntervalMs,
      );
    });

    test('未登録の端末は AUTH_FAILED', () {
      final SessionManager manager = build();

      expect(
        rejectedCode(manager.authenticate(hello(deviceToken: 'にせトークン'))),
        RejectCode.authFailed,
      );
    });

    test('別の端末のトークンでは通らない', () {
      final SessionManager manager = build();
      final DeviceToken issued = manager.issueDeviceToken('device-1');

      expect(
        rejectedCode(
          manager.authenticate(
            hello(deviceId: 'device-2', deviceToken: issued.value),
          ),
        ),
        RejectCode.authFailed,
      );
    });

    test('revoke すると以後は認証できない', () {
      final SessionManager manager = build();
      final DeviceToken issued = manager.issueDeviceToken('device-1');

      manager.revoke('device-1');

      expect(store.removals, <String>['device-1']);
      expect(
        rejectedCode(manager.authenticate(hello(deviceToken: issued.value))),
        RejectCode.authFailed,
      );
    });

    test('接続中の端末を revoke するとセッションも解放する', () {
      final SessionManager manager = build();
      final PairingToken token = manager.issuePairingToken();
      accepted(manager.authenticate(hello(pairingToken: token.value)));

      manager.revoke('device-1');

      expect(manager.activeDeviceId, isNull);
      expect(manager.activeSessionId, isNull);
    });

    test('同じ端末の再接続は受け入れる', () {
      // SESSION_REPLACED の経路。1台制限に引っかけてはいけない。
      final SessionManager manager = build();
      final PairingToken token = manager.issuePairingToken();
      final AcceptMessage first = accepted(
        manager.authenticate(hello(pairingToken: token.value)),
      );

      final AcceptMessage second = accepted(
        manager.authenticate(hello(deviceToken: first.issuedDeviceToken)),
      );

      expect(second.sessionId, isNot(first.sessionId));
    });
  });

  group('ログ', () {
    test('pairingToken の平文を出さない', () {
      final SessionManager manager = build();
      final PairingToken token = manager.issuePairingToken();

      expect(sink.lines, isNotEmpty);
      for (final String line in sink.lines) {
        expect(line, isNot(contains(token.value)));
      }
    });

    test('deviceToken の平文を出さない', () {
      final SessionManager manager = build();
      final PairingToken token = manager.issuePairingToken();
      final AcceptMessage accept = accepted(
        manager.authenticate(hello(pairingToken: token.value)),
      );

      // 空だとループが1回も回らず、検証していないのに通ってしまう。
      expect(sink.lines, isNotEmpty);
      for (final String line in sink.lines) {
        expect(line, isNot(contains(accept.issuedDeviceToken!)));
        expect(line, isNot(contains(token.value)));
      }
    });

    test('拒否は理由コードとともに記録する', () {
      final SessionManager manager = build();
      manager.authenticate(hello(id: 'other'));

      expect(
        sink.lines.where((String l) => l.contains('PROJECT_MISMATCH')),
        isNotEmpty,
      );
    });
  });

  group('値オブジェクト', () {
    test('PairingToken の toString に値を含めない', () {
      final SessionManager manager = build();
      final PairingToken token = manager.issuePairingToken();

      expect(token.toString(), isNot(contains(token.value)));
    });

    test('DeviceToken の toString に値を含めない', () {
      final SessionManager manager = build();
      final DeviceToken token = manager.issueDeviceToken('device-1');

      expect(token.toString(), isNot(contains(token.value)));
    });
  });
}
