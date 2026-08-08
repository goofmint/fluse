import 'dart:convert';
import 'dart:io';

import 'package:fluse_protocol/fluse_protocol.dart';
import 'package:test/test.dart';

/// Dart 実装と Kotlin 実装が**同じファイル**を読んで検証する。
///
/// どちらか片方だけを直しても、もう片方のテストが落ちる。ワイヤ表現が
/// ずれたまま気づかない事態を防ぐための唯一の共有仕様。
/// Kotlin 側は `packages/fluse_protocol_kt` の `WireGoldenTest` が
/// このファイルを読む。
final File _golden = File('test/fixtures/wire_golden.json');

List<int> _hexToBytes(String hex) => <int>[
  for (int i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
];

String _bytesToHex(List<int> bytes) =>
    bytes.map((int b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  late Map<String, Object?> golden;

  setUpAll(() {
    golden = jsonDecode(_golden.readAsStringSync()) as Map<String, Object?>;
  });

  test('protocolVersion がゴールデンと一致する', () {
    expect(golden['protocolVersion'], fluseProtocolVersion);
  });

  group('TunnelFrame のゴールデン', () {
    test('encode がゴールデンのバイト列と一致する', () {
      for (final Object? entry in golden['tunnelFrames']! as List<Object?>) {
        final Map<String, Object?> frame = entry! as Map<String, Object?>;
        final String name = '${frame['name']}';

        final TunnelFrame built = TunnelFrame(
          opcode: TunnelOpcode.values.byName('${frame['opcode']}'),
          streamId: frame['streamId']! as int,
          payload: _hexToBytes('${frame['payloadHex']}'),
        );

        expect(
          _bytesToHex(built.encode()),
          frame['bytesHex'],
          reason: '$name の符号化が違います',
        );
      }
    });

    test('decode がゴールデンのバイト列を復元する', () {
      for (final Object? entry in golden['tunnelFrames']! as List<Object?>) {
        final Map<String, Object?> frame = entry! as Map<String, Object?>;
        final String name = '${frame['name']}';

        final TunnelFrame decoded = TunnelFrame.decode(
          _hexToBytes('${frame['bytesHex']}'),
        );

        expect(decoded.opcode.name, frame['opcode'], reason: name);
        expect(decoded.streamId, frame['streamId'], reason: name);
        expect(_bytesToHex(decoded.payload), frame['payloadHex'], reason: name);
      }
    });

    test('不正なバイト列はゴールデンの通り拒否する', () {
      for (final Object? entry
          in golden['invalidTunnelFrames']! as List<Object?>) {
        final Map<String, Object?> frame = entry! as Map<String, Object?>;

        expect(
          () => TunnelFrame.decode(_hexToBytes('${frame['bytesHex']}')),
          throwsA(isA<FluseProtocolException>()),
          reason: '${frame['name']} が拒否されていません',
        );
      }
    });
  });

  group('制御メッセージのゴールデン', () {
    test('fromJson → toJson が完全に一致する', () {
      for (final Object? entry in golden['messages']! as List<Object?>) {
        final Map<String, Object?> sample = entry! as Map<String, Object?>;
        final Map<String, Object?> json =
            sample['json']! as Map<String, Object?>;

        final FluseMessage message = FluseMessage.fromJson(json);

        expect(message.toJson(), json, reason: '${sample['name']} の往復が一致しません');
      }
    });

    test('全メッセージ型がゴールデンに含まれている', () {
      // 型を増やしたらゴールデンにも足す。Kotlin 側の追従漏れを防ぐ。
      final Set<String> covered = <String>{
        for (final Object? entry in golden['messages']! as List<Object?>)
          '${((entry! as Map<String, Object?>)['json']! as Map<String, Object?>)['type']}',
      };

      expect(covered, <String>{
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

    test('不正なメッセージはゴールデンの通り拒否する', () {
      for (final Object? entry in golden['invalidMessages']! as List<Object?>) {
        final Map<String, Object?> sample = entry! as Map<String, Object?>;

        expect(
          () => FluseMessage.fromJson(sample['json']! as Map<String, Object?>),
          throwsA(isA<FluseProtocolException>()),
          reason: '${sample['name']} が拒否されていません',
        );
      }
    });
  });

  test('未知のコードでも解析は成功する', () {
    // 新しいサーバのコードを古いアプリが受け取っても、文言は表示できる。
    // Kotlin 側も同じ標本で同じことを検証する。
    final Map<String, Object?> json =
        (golden['messages']! as List<Object?>)
                .cast<Map<String, Object?>>()
                .firstWhere(
                  (Map<String, Object?> e) => e['name'] == 'rejectUnknownCode',
                )['json']!
            as Map<String, Object?>;

    final RejectMessage reject = FluseMessage.fromJson(json) as RejectMessage;

    expect(reject.knownCode, isNull);
    expect(reject.message, '将来の理由');
  });
}
