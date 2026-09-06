import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'device_install_exception.dart';

/// `adb` が使えない時に APK を配るための小さなサーバ（設計 §2.2.3(f)）。
///
/// **`fluse_server` の `WsServer` は使えない。** あちらは `fluse start` が
/// 立てるもので、`fluse init` の時点ではまだ動いていない。また
/// `fluse_builder` から `fluse_server` へは依存できない（設計 §2.1）。
///
/// 配るのは1ファイルだけなので、`dart:io` の `HttpServer` で足りる。
final class ApkServer {
  ApkServer._(this._server, this.uri);

  final HttpServer _server;

  /// 端末のブラウザで開く場所。
  final Uri uri;

  /// APK の Content-Type。これ以外だと Android がインストーラを開かない。
  static const String contentType = 'application/vnd.android.package-archive';

  /// 合言葉の長さ（バイト）。
  static const int tokenByteLength = 32;

  /// [apk] を LAN 上へ出す。
  ///
  /// **合言葉を付ける。** APK には Dart のソース（kernel）が入っている
  /// （設計 §6.1）。URL を知られただけで取られては困る。
  ///
  /// [onError] には1件ごとの失敗が届く。多くは端末側が途中で切っただけ
  /// だが、握り潰すと「なぜか落ちてこない」で終わる。
  static Future<ApkServer> serve(
    File apk, {
    int port = 0,
    Future<List<InternetAddress>> Function()? addresses,
    Random? random,
    void Function(Object error)? onError,
  }) async {
    if (!apk.existsSync()) {
      throw DeviceInstallException.apkMissing(path: apk.path);
    }

    final InternetAddress bind = await resolveLanAddress(addresses: addresses);
    final String token = generateToken(random: random);
    final HttpServer server = await HttpServer.bind(bind, port);

    final Uri uri = Uri(
      scheme: 'http',
      host: bind.address,
      port: server.port,
      path: '/apk',
      queryParameters: <String, String>{'t': token},
    );

    unawaited(_listen(server, apk, token, onError));
    return ApkServer._(server, uri);
  }

  static Future<void> _listen(
    HttpServer server,
    File apk,
    String token,
    void Function(Object error)? onError,
  ) async {
    await for (final HttpRequest request in server) {
      // **1件ぶんを丸ごと囲む。** `close()` も切断で投げる。ここから
      // 抜けると受付ごと終わり、以後どのリクエストにも応えられなくなる。
      try {
        await _respond(request, apk, token);
      } on Object catch (error) {
        // 多くは端末側が途中で切っただけ。**握り潰さない。**
        // 気づけないと「なぜか落ちてこない」で終わる。
        onError?.call(error);

        // **閉じてから次へ行く。** 開いたままだと、相手は来ない応答を
        // 待ち続ける。既に切れていれば、この close も投げる。
        try {
          await request.response.close();
        } on Object {
          // 相手が居ない。これ以上できることは無い。
        }
      }
    }
  }

  static Future<void> _respond(
    HttpRequest request,
    File apk,
    String token,
  ) async {
    // **合わなければ 404。** 403 にすると「そこにある」と教えてしまう
    // （設計 §4.2(b) と揃える）。
    if (request.uri.path != '/apk' ||
        !constantTimeEquals(request.uri.queryParameters['t'] ?? '', token)) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    request.response
      ..headers.set(HttpHeaders.contentTypeHeader, contentType)
      ..headers.set(HttpHeaders.contentLengthHeader, '${apk.lengthSync()}')
      ..headers.set(
        'content-disposition',
        'attachment; filename="preview.apk"',
      );

    // 丸ごと読み込まない。150MB を超えることがある。
    await request.response.addStream(apk.openRead());
    await request.response.close();
  }

  Future<void> close() => _server.close(force: true);

  // ------------------------------------------------------------------ 道具

  /// 端末から届くアドレスを1つ選ぶ。
  ///
  /// **loopback では届かない。** 端末は別の機械。逆に `0.0.0.0` にすると、
  /// 公衆 Wi-Fi でソース入りの APK を晒すことになる（設計 §6.1）。
  static Future<InternetAddress> resolveLanAddress({
    Future<List<InternetAddress>> Function()? addresses,
  }) async {
    final List<InternetAddress> found = await (addresses ?? _systemAddresses)();
    final List<InternetAddress> private = found.where(isPrivateIPv4).toList();
    if (private.isEmpty) {
      throw const DeviceInstallException.noLanAddress();
    }
    return private.first;
  }

  /// LAN の中だけで使われる IPv4 か。
  static bool isPrivateIPv4(InternetAddress address) {
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

  static Future<List<InternetAddress>> _systemAddresses() async {
    final List<NetworkInterface> interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    return <InternetAddress>[
      for (final NetworkInterface each in interfaces) ...each.addresses,
    ];
  }

  /// 予測されにくい合言葉。
  static String generateToken({Random? random}) {
    final Random source = random ?? Random.secure();
    final List<int> bytes = List<int>.generate(
      tokenByteLength,
      (int _) => source.nextInt(256),
      growable: false,
    );
    // URL に載るので、記号の出ない base64url にして `=` を落とす。
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  /// 合言葉を定数時間で比べる。
  ///
  /// **`==` を使ってはいけない。** 最初の食い違いで打ち切るため、応答の
  /// 速さから「何文字目まで合っていたか」が漏れる。LAN 上から何度でも
  /// 試せる以上、1文字ずつ詰められる。
  static bool constantTimeEquals(String a, String b) {
    if (a.length != b.length) {
      return false;
    }
    int diff = 0;
    for (int i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}
