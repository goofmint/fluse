import 'package:fluse_protocol/fluse_protocol.dart';

/// QR に載せる繋ぎ先（設計 §4.2(a)）。
///
/// ```text
/// fluse://connect?v=1&h=192.168.0.10&p=8180&pid=<projectId>&t=<pairingToken>&rev=00b0c91f
/// ```
///
/// **端末側の `FluseConnectUri` と同じ形でなければならない。** 片方だけ
/// 変えると、読み取れているのに繋がらない状態になる。
abstract final class ConnectUri {
  static const String scheme = 'fluse';
  static const String host = 'connect';

  /// `rev` に載せる桁数。
  static const int revisionLength = 8;

  /// 組み立てる。
  ///
  /// **`Uri` に組ませる。** 自前で `&` を繋ぐと、値に `&` や `=` が入った
  /// 時に壊れる。`pairingToken` は base64url なので普段は無害だが、
  /// 組み立て方に例外を作らない。
  static String build({
    required String lanHost,
    required int port,
    required String projectId,
    required String pairingToken,
    required String flutterRevision,
  }) => Uri(
    scheme: scheme,
    host: host,
    queryParameters: <String, String>{
      'v': '$fluseProtocolVersion',
      'h': lanHost,
      'p': '$port',
      'pid': projectId,
      't': pairingToken,
      'rev': shortRevision(flutterRevision),
    },
  ).toString();

  /// 先頭だけを取る。
  ///
  /// 全部載せると QR の版が上がり、コンソールに収まらなくなる。
  /// 食い違いの早期検出が目的なので、先頭8桁で足りる（設計 §4.2(a)）。
  static String shortRevision(String revision) =>
      revision.length <= revisionLength
      ? revision
      : revision.substring(0, revisionLength);
}
