import 'dart:convert';

import 'package:fluse_protocol/fluse_protocol.dart';
import 'package:test/test.dart';

/// `requireInt` の特殊な値だけを試すための入口。
///
/// メッセージ経由だと NaN / 無限大を JSON に載せられないため、
/// `fromJson` を直接呼ぶ。
abstract final class JsonReaderProbe {
  static void requireInt(Object? value) {
    FluseMessage.fromJson(<String, Object?>{
      'type': 'ping',
      'seq': value,
      'timestampMs': 1,
    });
  }
}

/// JSON へ落として読み直す。**実際に文字列を経由させる**ことで、
/// `jsonEncode` できない値が混ざっていないことも同時に確かめる。
FluseMessage roundTrip(FluseMessage message) => FluseMessage.fromJson(
  jsonDecode(jsonEncode(message.toJson())) as Map<String, Object?>,
);

void main() {
  group('round-trip', () {
    /// 全メッセージの代表値。型ごとに1つずつ。
    final List<FluseMessage> samples = <FluseMessage>[
      const HelloMessage(
        protocolVersion: fluseProtocolVersion,
        projectId: 'counter_app-0123456789abcdef',
        flutterRevision: '00b0c91f06209d9e4a41f71b7a512d6eb3b9c694',
        dartVersion: '3.11.5',
        appVersion: 'build-42',
        deviceId: 'device-hash',
        deviceName: 'Pixel 8',
      ),
      const VmServiceReadyMessage(
        vmServiceUri: 'http://127.0.0.1:43219/authcode/',
      ),
      const ReadyMessage(),
      const LogMessage(level: 'info', message: 'こんにちは'),
      const ErrorMessage(code: 'TUNNEL_LOST', message: '切断されました'),
      const AcceptMessage(sessionId: 'session-1', heartbeatIntervalMs: 15000),
      const RejectMessage(code: 'AUTH_FAILED', message: '認証に失敗しました'),
      const ReloadMessage(),
      const CompileErrorMessage(
        summary: 'コンパイルエラー 1 件',
        diagnostics: <DiagnosticEntry>[
          DiagnosticEntry(
            severity: DiagnosticSeverity.error,
            message: "Expected ';'",
            file: 'lib/main.dart',
            line: 12,
            col: 5,
          ),
        ],
      ),
      const CompileOkMessage(),
      const PingMessage(seq: 7, timestampMs: 1234567890),
      const PongMessage(seq: 7, timestampMs: 1234567890),
      const CloseMessage(code: 'SHUTDOWN'),
    ];

    test('設計 §2.2.1 の全メッセージを網羅している', () {
      // 型が増えたらここが落ちる。追従漏れを検出するため。
      expect(samples.map((FluseMessage m) => m.type).toSet(), <String>{
        'hello',
        'vmServiceReady',
        'ready',
        'log',
        'error',
        'accept',
        'reject',
        'reload',
        'compileError',
        'compileOk',
        'ping',
        'pong',
        'close',
      });
    });

    for (final FluseMessage sample in samples) {
      test('${sample.type} が往復する', () {
        final FluseMessage restored = roundTrip(sample);

        expect(restored.runtimeType, sample.runtimeType);
        expect(restored.toJson(), sample.toJson());
      });
    }

    test('hello の任意フィールドを含めても往復する', () {
      const HelloMessage hello = HelloMessage(
        protocolVersion: 1,
        projectId: 'p',
        flutterRevision: 'r',
        dartVersion: 'd',
        appVersion: 'a',
        deviceId: 'i',
        deviceName: 'n',
        pairingToken: 'PT-abcdefghij',
        deviceToken: 'DT-abcdefghij',
      );

      final HelloMessage restored = roundTrip(hello) as HelloMessage;

      expect(restored.pairingToken, 'PT-abcdefghij');
      expect(restored.deviceToken, 'DT-abcdefghij');
    });

    test('任意フィールドが無ければ JSON にキーごと出さない', () {
      // null を明示的に載せると、Kotlin 側で「キーはあるが null」と
      // 「キーが無い」の扱いを揃える手間が増える。
      expect(
        const CloseMessage(code: 'SHUTDOWN').toJson().containsKey('message'),
        isFalse,
      );
      expect(
        const AcceptMessage(
          sessionId: 's',
          heartbeatIntervalMs: 1,
        ).toJson().containsKey('issuedDeviceToken'),
        isFalse,
      );
    });

    test('compileError の診断が空でも往復する', () {
      final CompileErrorMessage restored =
          roundTrip(
                const CompileErrorMessage(
                  summary: '0 件',
                  diagnostics: <DiagnosticEntry>[],
                ),
              )
              as CompileErrorMessage;

      expect(restored.diagnostics, isEmpty);
    });

    test('位置を持たない診断も往復する', () {
      final CompileErrorMessage restored =
          roundTrip(
                const CompileErrorMessage(
                  summary: '1 件',
                  diagnostics: <DiagnosticEntry>[
                    DiagnosticEntry(
                      severity: DiagnosticSeverity.warning,
                      message: '位置なし',
                    ),
                  ],
                ),
              )
              as CompileErrorMessage;

      expect(restored.diagnostics.single.file, isNull);
      expect(restored.diagnostics.single.line, isNull);
      expect(restored.diagnostics.single.location, isNull);
    });
  });

  group('不正な JSON', () {
    test('type が無ければ失敗する', () {
      expect(
        () => FluseMessage.fromJson(<String, Object?>{'seq': 1}),
        throwsA(
          isA<FluseProtocolException>().having(
            (FluseProtocolException e) => e.message,
            'message',
            contains('type'),
          ),
        ),
      );
    });

    test('type が文字列でなければ失敗する', () {
      expect(
        () => FluseMessage.fromJson(<String, Object?>{'type': 42}),
        throwsA(isA<FluseProtocolException>()),
      );
    });

    test('未知の type は明示的に失敗する', () {
      // 黙って無視すると、送った側は届いたと思い込んだまま待ち続ける。
      expect(
        () => FluseMessage.fromJson(<String, Object?>{'type': 'teleport'}),
        throwsA(
          isA<FluseProtocolException>().having(
            (FluseProtocolException e) => e.message,
            'message',
            contains('teleport'),
          ),
        ),
      );
    });

    test('必須フィールドが無ければフィールド名を示して失敗する', () {
      expect(
        () =>
            FluseMessage.fromJson(<String, Object?>{'type': 'ping', 'seq': 1}),
        throwsA(
          isA<FluseProtocolException>().having(
            (FluseProtocolException e) => e.message,
            'message',
            allOf(contains('ping'), contains('timestampMs')),
          ),
        ),
      );
    });

    test('型が違えば「無い」と区別して失敗する', () {
      expect(
        () => FluseMessage.fromJson(<String, Object?>{
          'type': 'ping',
          'seq': 'いち',
          'timestampMs': 1,
        }),
        throwsA(
          isA<FluseProtocolException>().having(
            (FluseProtocolException e) => e.message,
            'message',
            allOf(contains('seq'), contains('整数')),
          ),
        ),
      );
    });

    test('任意フィールドの型が違えば失敗する', () {
      expect(
        () => FluseMessage.fromJson(<String, Object?>{
          'type': 'close',
          'code': 'SHUTDOWN',
          'message': 42,
        }),
        throwsA(isA<FluseProtocolException>()),
      );
    });

    test('整数として表せる double は受け入れる', () {
      // JSON の数値は 1.0 のように来ることがある。
      final PingMessage ping =
          FluseMessage.fromJson(<String, Object?>{
                'type': 'ping',
                'seq': 7.0,
                'timestampMs': 1.0,
              })
              as PingMessage;

      expect(ping.seq, 7);
    });

    test('キー有りで null の任意フィールドは省略と同じ扱い', () {
      // Kotlin 側が任意フィールドを null で明示送信しても失敗しない。
      final CompileErrorMessage message =
          FluseMessage.fromJson(<String, Object?>{
                'type': 'compileError',
                'summary': 's',
                'diagnostics': <Object?>[
                  <String, Object?>{
                    'severity': 'error',
                    'message': 'm',
                    'file': null,
                    'line': null,
                    'col': null,
                  },
                ],
              })
              as CompileErrorMessage;

      expect(message.diagnostics.single.file, isNull);
      expect(message.diagnostics.single.line, isNull);
      expect(message.diagnostics.single.col, isNull);
    });

    test('JSON が正確に表せない大きさの整数は拒否する', () {
      // double.toInt() は 64bit の範囲外を黙って丸める。
      expect(
        () => FluseMessage.fromJson(<String, Object?>{
          'type': 'ping',
          'seq': 1e30,
          'timestampMs': 1,
        }),
        throwsA(
          isA<FluseProtocolException>().having(
            (FluseProtocolException e) => e.message,
            'message',
            contains('正確に表せる整数'),
          ),
        ),
      );
    });

    test('int でも安全範囲外なら拒否する', () {
      expect(
        () => FluseMessage.fromJson(<String, Object?>{
          'type': 'ping',
          'seq': 9007199254740992,
          'timestampMs': 1,
        }),
        throwsA(isA<FluseProtocolException>()),
      );
    });

    test('安全範囲の境界は受け入れる', () {
      final PingMessage ping =
          FluseMessage.fromJson(<String, Object?>{
                'type': 'ping',
                'seq': 9007199254740991,
                'timestampMs': -9007199254740991,
              })
              as PingMessage;

      expect(ping.seq, 9007199254740991);
      expect(ping.timestampMs, -9007199254740991);
    });

    test('NaN や無限大は拒否する', () {
      expect(
        () => JsonReaderProbe.requireInt(double.nan),
        throwsA(isA<FluseProtocolException>()),
      );
      expect(
        () => JsonReaderProbe.requireInt(double.infinity),
        throwsA(isA<FluseProtocolException>()),
      );
    });

    test('小数は整数として受け入れない', () {
      // 丸めると別の値になる。
      expect(
        () => FluseMessage.fromJson(<String, Object?>{
          'type': 'ping',
          'seq': 7.5,
          'timestampMs': 1,
        }),
        throwsA(isA<FluseProtocolException>()),
      );
    });

    test('diagnostics の要素がオブジェクトでなければ失敗する', () {
      expect(
        () => FluseMessage.fromJson(<String, Object?>{
          'type': 'compileError',
          'summary': 's',
          'diagnostics': <Object?>['文字列'],
        }),
        throwsA(isA<FluseProtocolException>()),
      );
    });

    test('diagnostics が配列でなければ失敗する', () {
      expect(
        () => FluseMessage.fromJson(<String, Object?>{
          'type': 'compileError',
          'summary': 's',
          'diagnostics': 'まとめて1件',
        }),
        throwsA(isA<FluseProtocolException>()),
      );
    });

    test('未知の severity は失敗する', () {
      // 深刻度が分からないとオーバーレイの出し分けができない。
      // ただし**受け取った値は例外文に載せない**。severity は相手が自由に
      // 入れられるフィールドで、例外文はログに出る。
      expect(
        () => FluseMessage.fromJson(<String, Object?>{
          'type': 'compileError',
          'summary': 's',
          'diagnostics': <Object?>[
            <String, Object?>{'severity': 'fatal', 'message': 'm'},
          ],
        }),
        throwsA(
          isA<FluseProtocolException>().having(
            (FluseProtocolException e) => e.message,
            'message',
            allOf(contains('severity'), isNot(contains('fatal'))),
          ),
        ),
      );
    });
  });

  group('トークンを漏らさない', () {
    test('hello の toString にトークンが出ない', () {
      const HelloMessage hello = HelloMessage(
        protocolVersion: 1,
        projectId: 'p',
        flutterRevision: 'r',
        dartVersion: 'd',
        appVersion: 'a',
        deviceId: 'i',
        deviceName: 'n',
        pairingToken: 'PT-supersecretvalue',
        deviceToken: 'DT-supersecretvalue',
      );

      expect(hello.toString(), isNot(contains('supersecretvalue')));
    });

    test('accept の toString に発行トークンが出ない', () {
      expect(
        const AcceptMessage(
          sessionId: 's',
          heartbeatIntervalMs: 1,
          issuedDeviceToken: 'DT-supersecretvalue',
        ).toString(),
        isNot(contains('supersecretvalue')),
      );
    });

    test('vmServiceReady の toString に認証コードが出ない', () {
      // URI のパスセグメントがそのまま資格情報。
      expect(
        const VmServiceReadyMessage(
          vmServiceUri: 'http://127.0.0.1:1/xY7Kq2Lm9Ab=/',
        ).toString(),
        isNot(contains('xY7Kq2Lm9Ab')),
      );
    });

    test('例外メッセージに値が載らない', () {
      // 型が違うことだけを伝え、値そのものは出さない。
      try {
        FluseMessage.fromJson(<String, Object?>{
          'type': 'hello',
          'protocolVersion': 1,
          'projectId': 'p',
          'flutterRevision': 'r',
          'dartVersion': 'd',
          'appVersion': 'a',
          'deviceId': 'i',
          'deviceName': 'n',
          'pairingToken': <String>['PT-supersecretvalue'],
        });
        fail('例外が投げられていません');
      } on FluseProtocolException catch (error) {
        expect(error.message, isNot(contains('supersecretvalue')));
        expect(error.message, contains('pairingToken'));
      }
    });
  });

  group('コード enum', () {
    test('既知の reject コードを解決する', () {
      expect(
        const RejectMessage(code: 'PROTOCOL_MISMATCH', message: 'm').knownCode,
        RejectCode.protocolMismatch,
      );
    });

    test('未知の reject コードでも解析は成功し、knownCode が null になる', () {
      // 新しいサーバのコードを古いアプリが受け取っても、理由の文言は
      // 表示できるようにする。
      final RejectMessage reject =
          FluseMessage.fromJson(<String, Object?>{
                'type': 'reject',
                'code': 'FUTURE_REASON',
                'message': '将来の理由',
              })
              as RejectMessage;

      expect(reject.knownCode, isNull);
      expect(reject.message, '将来の理由');
    });

    test('RejectMessage.of は enum から作る', () {
      expect(
        RejectMessage.of(RejectCode.tooManyDevices, '2台目です').code,
        'TOO_MANY_DEVICES',
      );
    });

    test('CloseMessage.of は enum から作る', () {
      expect(
        CloseMessage.of(CloseCode.sessionReplaced).knownCode,
        CloseCode.sessionReplaced,
      );
    });

    test('全コードの wireValue が設計と一致する', () {
      expect(RejectCode.values.map((RejectCode c) => c.wireValue), <String>[
        'AUTH_FAILED',
        'PROJECT_MISMATCH',
        'REVISION_MISMATCH',
        'PROTOCOL_MISMATCH',
        'APP_OUTDATED',
        'TOO_MANY_DEVICES',
      ]);
      expect(CloseCode.values.map((CloseCode c) => c.wireValue), <String>[
        'SHUTDOWN',
        'SESSION_REPLACED',
        'CLIENT_EXIT',
      ]);
    });

    test('未知の値は null になる', () {
      expect(RejectCode.tryParse('NOPE'), isNull);
      expect(CloseCode.tryParse('NOPE'), isNull);
      expect(FluseErrorCode.tryParse('NOPE'), isNull);
      expect(LogLevel.tryParse('NOPE'), isNull);
    });

    test('既知の値は解決できる', () {
      expect(
        FluseErrorCode.tryParse('COMPILE_ERROR'),
        FluseErrorCode.compileError,
      );
      expect(LogLevel.tryParse('warn'), LogLevel.warn);
      expect(
        DiagnosticSeverity.tryParse('context'),
        DiagnosticSeverity.context,
      );
    });
  });

  group('protocolVersion', () {
    test('一致すれば互換', () {
      expect(isCompatibleProtocolVersion(fluseProtocolVersion), isTrue);
    });

    test('違えば非互換', () {
      // 片方だけ新しい状態を許すと、切り分けの難しい不具合になる。
      expect(isCompatibleProtocolVersion(fluseProtocolVersion + 1), isFalse);
      expect(isCompatibleProtocolVersion(fluseProtocolVersion - 1), isFalse);
    });
  });

  group('ping / pong', () {
    test('pong は ping の値をそのまま返す', () {
      // 受信側で作り直すと RTT が測れなくなる。
      const PingMessage ping = PingMessage(seq: 3, timestampMs: 999);

      final PongMessage pong = ping.toPong();

      expect(pong.seq, ping.seq);
      expect(pong.timestampMs, ping.timestampMs);
    });
  });

  _extra();

  group('DiagnosticEntry', () {
    test('location を組み立てる', () {
      expect(
        const DiagnosticEntry(
          severity: DiagnosticSeverity.error,
          message: 'm',
          file: 'lib/a.dart',
          line: 3,
          col: 7,
        ).location,
        'lib/a.dart:3:7',
      );
    });

    test('列が無ければ行までを示す', () {
      expect(
        const DiagnosticEntry(
          severity: DiagnosticSeverity.error,
          message: 'm',
          file: 'lib/a.dart',
          line: 3,
        ).location,
        'lib/a.dart:3',
      );
    });

    test('行が無ければファイルだけを示す', () {
      expect(
        const DiagnosticEntry(
          severity: DiagnosticSeverity.error,
          message: 'm',
          file: 'lib/a.dart',
        ).location,
        'lib/a.dart',
      );
    });
  });
}

/// 表示用の実装と、まだ通っていない分岐を埋めるテスト。
///
/// `toString` は例外文やログに載る。**トークンを漏らさないこと**が
/// 要件なので、実装が生きていることをここで固定する。
void _extra() {
  group('toString', () {
    test('全メッセージが type を含む簡潔な表現を返す', () {
      final Map<FluseMessage, String> expected = <FluseMessage, String>{
        const ReadyMessage(): 'ReadyMessage()',
        const ReloadMessage(): 'ReloadMessage()',
        const CompileOkMessage(): 'CompileOkMessage()',
        const LogMessage(level: 'warn', message: 'm'): 'LogMessage(warn)',
        const ErrorMessage(code: 'NO_DEVICE', message: 'm'):
            'ErrorMessage(NO_DEVICE)',
        const AcceptMessage(sessionId: 's1', heartbeatIntervalMs: 1):
            'AcceptMessage(s1)',
        const RejectMessage(code: 'AUTH_FAILED', message: 'm'):
            'RejectMessage(AUTH_FAILED)',
        const CloseMessage(code: 'SHUTDOWN'): 'CloseMessage(SHUTDOWN)',
        const PingMessage(seq: 3, timestampMs: 1): 'PingMessage(3)',
        const PongMessage(seq: 3, timestampMs: 1): 'PongMessage(3)',
      };

      expected.forEach((FluseMessage message, String text) {
        expect(message.toString(), text);
      });
    });

    test('compileError は件数を示す', () {
      expect(
        const CompileErrorMessage(
          summary: 's',
          diagnostics: <DiagnosticEntry>[
            DiagnosticEntry(severity: DiagnosticSeverity.error, message: 'm'),
          ],
        ).toString(),
        'CompileErrorMessage(1件)',
      );
    });

    test('DiagnosticEntry は位置付きなら location を前置する', () {
      expect(
        const DiagnosticEntry(
          severity: DiagnosticSeverity.error,
          message: 'まずい',
          file: 'lib/a.dart',
          line: 1,
          col: 2,
        ).toString(),
        'lib/a.dart:1:2: まずい',
      );
    });

    test('DiagnosticEntry は位置が無ければ本文だけ', () {
      expect(
        const DiagnosticEntry(
          severity: DiagnosticSeverity.info,
          message: 'ただの情報',
        ).toString(),
        'ただの情報',
      );
    });

    test('例外は接頭辞付きで表示される', () {
      expect(
        const FluseProtocolException('こわれた').toString(),
        'fluse_protocol: こわれた',
      );
    });
  });

  group('残りの検証分岐', () {
    test('必須の文字列が無ければ失敗する', () {
      expect(
        () => FluseMessage.fromJson(<String, Object?>{'type': 'log'}),
        throwsA(
          isA<FluseProtocolException>().having(
            (FluseProtocolException e) => e.message,
            'message',
            contains('level'),
          ),
        ),
      );
    });

    test('必須の文字列の型が違えば失敗する', () {
      expect(
        () => FluseMessage.fromJson(<String, Object?>{
          'type': 'log',
          'level': 1,
          'message': 'm',
        }),
        throwsA(isA<FluseProtocolException>()),
      );
    });

    test('必須の配列が無ければ失敗する', () {
      expect(
        () => FluseMessage.fromJson(<String, Object?>{
          'type': 'compileError',
          'summary': 's',
        }),
        throwsA(
          isA<FluseProtocolException>().having(
            (FluseProtocolException e) => e.message,
            'message',
            contains('diagnostics'),
          ),
        ),
      );
    });

    test('vmServiceReady の必須フィールドが無ければ失敗する', () {
      expect(
        () =>
            FluseMessage.fromJson(<String, Object?>{'type': 'vmServiceReady'}),
        throwsA(isA<FluseProtocolException>()),
      );
    });

    test('accept の必須フィールドが無ければ失敗する', () {
      expect(
        () => FluseMessage.fromJson(<String, Object?>{
          'type': 'accept',
          'sessionId': 's',
        }),
        throwsA(isA<FluseProtocolException>()),
      );
    });

    test('reject の必須フィールドが無ければ失敗する', () {
      expect(
        () => FluseMessage.fromJson(<String, Object?>{'type': 'reject'}),
        throwsA(isA<FluseProtocolException>()),
      );
    });

    test('hello の必須フィールドが無ければ失敗する', () {
      expect(
        () => FluseMessage.fromJson(<String, Object?>{'type': 'hello'}),
        throwsA(isA<FluseProtocolException>()),
      );
    });

    test('error の必須フィールドが無ければ失敗する', () {
      expect(
        () => FluseMessage.fromJson(<String, Object?>{'type': 'error'}),
        throwsA(isA<FluseProtocolException>()),
      );
    });

    test('close の必須フィールドが無ければ失敗する', () {
      expect(
        () => FluseMessage.fromJson(<String, Object?>{'type': 'close'}),
        throwsA(isA<FluseProtocolException>()),
      );
    });

    test('pong の必須フィールドが無ければ失敗する', () {
      expect(
        () => FluseMessage.fromJson(<String, Object?>{'type': 'pong'}),
        throwsA(isA<FluseProtocolException>()),
      );
    });

    test('diagnostic の message が無ければ失敗する', () {
      expect(
        () => FluseMessage.fromJson(<String, Object?>{
          'type': 'compileError',
          'summary': 's',
          'diagnostics': <Object?>[
            <String, Object?>{'severity': 'error'},
          ],
        }),
        throwsA(isA<FluseProtocolException>()),
      );
    });

    test('TunnelFrame の表示にフレームの要約が出る', () {
      expect(
        TunnelFrame.data(9, <int>[1, 2]).toString(),
        'TunnelFrame(data, stream: 9, 2バイト)',
      );
    });
  });
}
