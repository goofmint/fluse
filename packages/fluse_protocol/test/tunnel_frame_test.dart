import 'dart:typed_data';

import 'package:fluse_protocol/fluse_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('encode / decode の往復', () {
    test('data フレームが往復する', () {
      final TunnelFrame frame = TunnelFrame.data(42, <int>[1, 2, 3, 255]);

      final TunnelFrame restored = TunnelFrame.decode(frame.encode());

      expect(restored.opcode, TunnelOpcode.data);
      expect(restored.streamId, 42);
      expect(restored.payload, <int>[1, 2, 3, 255]);
    });

    test('open フレームが往復する', () {
      final TunnelFrame restored = TunnelFrame.decode(
        TunnelFrame.open(1).encode(),
      );

      expect(restored.opcode, TunnelOpcode.open);
      expect(restored.streamId, 1);
      expect(restored.payload, isEmpty);
    });

    test('close フレームが往復する', () {
      final TunnelFrame restored = TunnelFrame.decode(
        TunnelFrame.close(1).encode(),
      );

      expect(restored.opcode, TunnelOpcode.close);
      expect(restored.payload, isEmpty);
    });
  });

  group('バイト配置', () {
    test('設計どおりの並びになる', () {
      // byte0=opcode, byte1..4=streamId(BE), byte5..=payload
      final Uint8List bytes = TunnelFrame.data(0x01020304, <int>[
        0xAA,
      ]).encode();

      expect(bytes, <int>[0x02, 0x01, 0x02, 0x03, 0x04, 0xAA]);
    });

    test('streamId は big-endian', () {
      // バイト順を取り違えると別のストリームを指す。
      final Uint8List bytes = TunnelFrame.open(0x000000FF).encode();

      expect(bytes.sublist(1, 5), <int>[0x00, 0x00, 0x00, 0xFF]);
    });

    test('ヘッダは5バイト', () {
      expect(TunnelFrame.open(0).encode().length, TunnelFrame.headerLength);
    });
  });

  group('境界値', () {
    test('payload 0バイトの data フレーム', () {
      final TunnelFrame restored = TunnelFrame.decode(
        TunnelFrame.data(7, <int>[]).encode(),
      );

      expect(restored.opcode, TunnelOpcode.data);
      expect(restored.payload, isEmpty);
    });

    test('streamId = 0', () {
      expect(TunnelFrame.decode(TunnelFrame.open(0).encode()).streamId, 0);
    });

    test('streamId = 0xFFFFFFFF', () {
      // uint32 の最大値。符号付きとして解釈すると -1 になる。
      final TunnelFrame restored = TunnelFrame.decode(
        TunnelFrame.open(TunnelFrame.maxStreamId).encode(),
      );

      expect(restored.streamId, 0xFFFFFFFF);
      expect(restored.streamId, isPositive);
    });

    test('streamId = 0x80000000（最上位ビットのみ）', () {
      expect(
        TunnelFrame.decode(TunnelFrame.open(0x80000000).encode()).streamId,
        0x80000000,
      );
    });

    test('大きな payload も壊れない', () {
      final List<int> payload = List<int>.generate(
        64 * 1024,
        (int i) => i % 256,
      );

      final TunnelFrame restored = TunnelFrame.decode(
        TunnelFrame.data(1, payload).encode(),
      );

      expect(restored.payload, payload);
    });

    test('payload の上限ちょうどは通る', () {
      final List<int> payload = List<int>.filled(
        TunnelFrame.maxPayloadLength,
        0x41,
      );

      expect(
        TunnelFrame.decode(
          TunnelFrame.data(1, payload).encode(),
        ).payload.length,
        TunnelFrame.maxPayloadLength,
      );
    });

    test('上限を超える payload は encode で失敗する', () {
      // 送信側が分割する責務を持つ。
      expect(
        () => TunnelFrame.data(
          1,
          List<int>.filled(TunnelFrame.maxPayloadLength + 1, 0),
        ).encode(),
        throwsA(
          isA<FluseProtocolException>().having(
            (FluseProtocolException e) => e.message,
            'message',
            contains('分割'),
          ),
        ),
      );
    });

    test('上限を超える payload は decode でも失敗する', () {
      // 長さを信じて確保すると、壊れた相手にメモリを取らせられる。
      final List<int> bytes = <int>[
        0x02,
        0,
        0,
        0,
        1,
        ...List<int>.filled(TunnelFrame.maxPayloadLength + 1, 0),
      ];

      expect(
        () => TunnelFrame.decode(bytes),
        throwsA(isA<FluseProtocolException>()),
      );
    });

    test('バイト範囲外の payload は encode で失敗する', () {
      // Uint8List.setRange は黙って下位8ビットへ切り詰める。
      expect(
        () => TunnelFrame.data(1, <int>[0, 256]).encode(),
        throwsA(
          isA<FluseProtocolException>().having(
            (FluseProtocolException e) => e.message,
            'message',
            allOf(contains('1 番目'), contains('256')),
          ),
        ),
      );
      expect(
        () => TunnelFrame.data(1, <int>[-1]).encode(),
        throwsA(isA<FluseProtocolException>()),
      );
    });

    test('範囲外の streamId は encode で失敗する', () {
      expect(
        () => const TunnelFrame(
          opcode: TunnelOpcode.open,
          streamId: TunnelFrame.maxStreamId + 1,
        ).encode(),
        throwsA(isA<FluseProtocolException>()),
      );
      expect(
        () =>
            const TunnelFrame(opcode: TunnelOpcode.open, streamId: -1).encode(),
        throwsA(isA<FluseProtocolException>()),
      );
    });
  });

  group('壊れた入力', () {
    test('5バイト未満は失敗する', () {
      for (int length = 0; length < TunnelFrame.headerLength; length++) {
        expect(
          () => TunnelFrame.decode(List<int>.filled(length, 0x02)),
          throwsA(
            isA<FluseProtocolException>().having(
              (FluseProtocolException e) => e.message,
              'message',
              contains('短すぎ'),
            ),
          ),
          reason: '$length バイト',
        );
      }
    });

    test('未知の opcode は失敗する', () {
      // 黙って捨てると、相手は届いたと思って待ち続ける。
      expect(
        () => TunnelFrame.decode(<int>[0x09, 0, 0, 0, 1]),
        throwsA(
          isA<FluseProtocolException>().having(
            (FluseProtocolException e) => e.message,
            'message',
            contains('0x09'),
          ),
        ),
      );
    });

    test('open に payload が付いていれば失敗する', () {
      // opcode と中身が食い違ったまま先へ進めない。
      expect(
        () => TunnelFrame.decode(<int>[0x01, 0, 0, 0, 1, 0xFF]),
        throwsA(isA<FluseProtocolException>()),
      );
    });

    test('close に payload を載せようとすると encode で失敗する', () {
      expect(
        () => const TunnelFrame(
          opcode: TunnelOpcode.close,
          streamId: 1,
          payload: <int>[1],
        ).encode(),
        throwsA(isA<FluseProtocolException>()),
      );
    });
  });

  group('TunnelOpcode', () {
    test('設計どおりの値', () {
      expect(TunnelOpcode.open.value, 0x01);
      expect(TunnelOpcode.data.value, 0x02);
      expect(TunnelOpcode.close.value, 0x03);
    });

    test('既知の値を解決する', () {
      expect(TunnelOpcode.tryParse(0x02), TunnelOpcode.data);
    });

    test('未知の値は null', () {
      expect(TunnelOpcode.tryParse(0x00), isNull);
      expect(TunnelOpcode.tryParse(0xFF), isNull);
    });
  });
}
