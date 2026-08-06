import 'dart:typed_data';

import 'protocol_exception.dart';

/// トンネルフレームの種別（設計 §2.2.1）。
enum TunnelOpcode {
  /// 新しいストリームを開く。
  open(0x01),

  /// データ本体。
  data(0x02),

  /// ストリームを閉じる。
  close(0x03);

  const TunnelOpcode(this.value);

  /// バイト0に載る値。
  final int value;

  static TunnelOpcode? tryParse(int value) {
    for (final TunnelOpcode opcode in values) {
      if (opcode.value == value) {
        return opcode;
      }
    }
    return null;
  }
}

/// WebSocket の binary frame に載せる TCP トンネルのフレーム
/// （設計 §2.2.1）。
///
/// ```text
/// byte0      : opcode  0x01=open, 0x02=data, 0x03=close
/// byte1..4   : streamId (uint32 big-endian)
/// byte5..    : payload (data時のみ)
/// ```
///
/// **VM Service のプロトコルは一切解釈しない**（設計 §10-3）。
/// JSON-RPC over WebSocket と DevFS の HTTP PUT が同じポートに来るため、
/// 片方だけ対応した「賢い」中継を書くと必ず破綻する。ここは生の
/// バイト列を運ぶだけに徹する。
final class TunnelFrame {
  const TunnelFrame({
    required this.opcode,
    required this.streamId,
    this.payload = _empty,
  });

  /// ストリームを開くフレーム。
  TunnelFrame.open(this.streamId)
    : opcode = TunnelOpcode.open,
      payload = _empty;

  /// データを運ぶフレーム。
  TunnelFrame.data(this.streamId, this.payload) : opcode = TunnelOpcode.data;

  /// ストリームを閉じるフレーム。
  TunnelFrame.close(this.streamId)
    : opcode = TunnelOpcode.close,
      payload = _empty;

  static const List<int> _empty = <int>[];

  /// ヘッダの長さ（opcode 1バイト + streamId 4バイト）。
  static const int headerLength = 5;

  /// `streamId` の最大値。uint32 なので 0xFFFFFFFF。
  static const int maxStreamId = 0xFFFFFFFF;

  /// 1フレームに載せられる payload の上限（1 MiB）。
  ///
  /// **送信側はこれを超える前に分割する責務がある。**
  /// 上限を設けないと、壊れた相手や悪意ある相手が送る長さ宣言で
  /// メモリを一気に確保させられる。設計 §8.2-5 のバックプレッシャ閾値
  /// （送信キュー 4MB）より十分小さくし、1フレームでキューを埋めない
  /// 大きさにしてある。
  static const int maxPayloadLength = 1024 * 1024;

  final TunnelOpcode opcode;

  /// ストリームの識別子。uint32。
  final int streamId;

  /// 本体。`data` 以外では空。
  final List<int> payload;

  Uint8List encode() {
    if (streamId < 0 || streamId > maxStreamId) {
      throw FluseProtocolException('streamId が uint32 の範囲外です: $streamId');
    }
    if (opcode != TunnelOpcode.data && payload.isNotEmpty) {
      // open / close に本体を載せると、受け側の解釈が opcode と食い違う。
      throw FluseProtocolException(
        '${opcode.name} フレームに payload は載せられません'
        '（${payload.length} バイト）',
      );
    }
    if (payload.length > maxPayloadLength) {
      throw FluseProtocolException(
        'payload が上限を超えています: ${payload.length} バイト'
        '（上限 $maxPayloadLength）。送信側で分割してください',
      );
    }
    for (int i = 0; i < payload.length; i++) {
      final int byte = payload[i];
      if (byte < 0 || byte > 0xFF) {
        // Uint8List.setRange は範囲外を例外にせず下位8ビットへ切り詰める。
        // 黙って別のバイト列を送ることになる。
        throw FluseProtocolException('payload の $i 番目がバイトの範囲外です: $byte');
      }
    }

    final Uint8List bytes = Uint8List(headerLength + payload.length);
    bytes[0] = opcode.value;
    // big-endian。バイト順を取り違えると streamId が別のストリームを指す。
    bytes[1] = (streamId >> 24) & 0xFF;
    bytes[2] = (streamId >> 16) & 0xFF;
    bytes[3] = (streamId >> 8) & 0xFF;
    bytes[4] = streamId & 0xFF;
    bytes.setRange(headerLength, bytes.length, payload);
    return bytes;
  }

  static TunnelFrame decode(List<int> bytes) {
    if (bytes.length < headerLength) {
      throw FluseProtocolException(
        'トンネルフレームが短すぎます: ${bytes.length} バイト'
        '（最低 $headerLength バイト必要）',
      );
    }

    // ヘッダを読む前に全要素を検査する。範囲外が混ざっていると、
    // streamId が別の値になり、payload は Uint8List.fromList で黙って
    // 下位8ビットへ切り詰められる。どちらも気づけない壊れ方をする。
    for (int i = 0; i < bytes.length; i++) {
      final int byte = bytes[i];
      if (byte < 0 || byte > 0xFF) {
        throw FluseProtocolException('フレームの $i 番目がバイトの範囲外です: $byte');
      }
    }

    final TunnelOpcode? opcode = TunnelOpcode.tryParse(bytes[0]);
    if (opcode == null) {
      // 未知の opcode を黙って捨てると、相手は届いたと思って待ち続ける。
      throw FluseProtocolException(
        '未知の opcode: 0x${bytes[0].toRadixString(16).padLeft(2, '0')}',
      );
    }

    final int streamId =
        (bytes[1] << 24) | (bytes[2] << 16) | (bytes[3] << 8) | bytes[4];

    final int payloadLength = bytes.length - headerLength;
    if (payloadLength > maxPayloadLength) {
      // コピーする前に弾く。長さを信じて確保すると、壊れた相手に
      // メモリを一気に取らせられる。
      throw FluseProtocolException(
        'payload が上限を超えています: $payloadLength バイト'
        '（上限 $maxPayloadLength）',
      );
    }

    final List<int> payload = payloadLength == 0
        ? _empty
        : Uint8List.fromList(bytes.sublist(headerLength));

    if (opcode != TunnelOpcode.data && payload.isNotEmpty) {
      throw FluseProtocolException(
        '${opcode.name} フレームに payload が付いています（${payload.length} バイト）',
      );
    }

    return TunnelFrame(opcode: opcode, streamId: streamId, payload: payload);
  }

  @override
  String toString() =>
      'TunnelFrame(${opcode.name}, stream: $streamId, '
      '${payload.length}バイト)';
}
