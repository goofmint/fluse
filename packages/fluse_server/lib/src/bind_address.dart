/// 待ち受けアドレスの決め方（設計 §6.1）。
///
/// **既定ではプライベート IP にだけバインドする。** 平文の WebSocket で
/// ソースを流す以上、届く範囲を絞ることが実効的な唯一の境界になる。
library;

import 'dart:io';

/// バインド先を決められなかったときに投げる。
final class BindAddressException implements Exception {
  const BindAddressException(this.message);

  final String message;

  @override
  String toString() => 'bind: $message';
}

/// 全インタフェースに開く指定。
const String anyHost = '0.0.0.0';

/// [host] が全インタフェースへの公開を意味するか。
///
/// 一致したら呼び出し側は警告を出すこと（設計 §6.1）。
bool isAnyHost(String host) => host == anyHost || host == '::';

/// RFC1918 のプライベート IPv4 か。
///
/// `dart:io` の [InternetAddress] は判定を持たないので自前で見る。
bool isPrivateIPv4(InternetAddress address) {
  if (address.type != InternetAddressType.IPv4) {
    return false;
  }
  final List<int> octets = address.rawAddress;
  return switch (octets[0]) {
    // 10.0.0.0/8
    10 => true,
    // 172.16.0.0/12
    172 => octets[1] >= 16 && octets[1] <= 31,
    // 192.168.0.0/16
    192 => octets[1] == 168,
    _ => false,
  };
}

/// この機に付いている IPv4 を全て集める。
///
/// **`NetworkInterface` を注入点にしない。** `addresses` の要素型は SDK の
/// 版で変わる（3.13 で `InterfaceAddress` になった）ため、偽物を作ると
/// 特定の版でだけ解析が落ちる。差し替えるのはアドレスの列にする。
Future<List<InternetAddress>> _systemAddresses() async {
  final List<NetworkInterface> interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLoopback: false,
    includeLinkLocal: false,
  );
  return <InternetAddress>[
    for (final NetworkInterface interface in interfaces) ...interface.addresses,
  ];
}

/// この機に付いているプライベート IPv4 を列挙する。
///
/// 見つからなければ空。Wi-Fi に繋がっていない、あるいは仮想環境の中に
/// 居る場合に起こりうる。
Future<List<InternetAddress>> listPrivateIPv4({
  Future<List<InternetAddress>> Function()? addresses,
}) async {
  final List<InternetAddress> found = await (addresses ?? _systemAddresses)();
  return found.where(isPrivateIPv4).toList();
}

/// 待ち受けるアドレスを決める。
///
/// [host] が指定されていればそれをそのまま使う（`0.0.0.0` も含む。
/// 明示指定は利用者の判断として尊重し、警告だけ出す）。省略された場合は
/// **プライベート IPv4 を1つ選ぶ**。
///
/// LAN 上の端末から届く必要があるため、既定を loopback にはできない。
/// 逆に既定を `0.0.0.0` にすると、うっかり公衆 Wi-Fi でソースを晒す。
Future<InternetAddress> resolveBindAddress({
  String? host,
  Future<List<InternetAddress>> Function()? addresses,
}) async {
  if (host != null) {
    final InternetAddress? parsed = InternetAddress.tryParse(host);
    if (parsed == null) {
      throw BindAddressException('IP アドレスとして読めません: $host');
    }
    return parsed;
  }

  final List<InternetAddress> candidates = await listPrivateIPv4(
    addresses: addresses,
  );
  if (candidates.isEmpty) {
    throw BindAddressException(
      'プライベート IP が見つかりません。'
      'LAN に接続しているか確認するか、--host で明示してください',
    );
  }
  // 複数あっても選び方の根拠が無い。最初の1つを使い、実際に使った値は
  // 呼び出し側がログと QR に出す。
  return candidates.first;
}
