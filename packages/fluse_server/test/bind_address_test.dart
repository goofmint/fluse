import 'dart:io';

import 'package:fluse_server/fluse_server.dart';
import 'package:test/test.dart';

void main() {
  group('isPrivateIPv4', () {
    test('RFC1918 の範囲を認める', () {
      for (final String ip in <String>[
        '10.0.0.1',
        '10.255.255.254',
        '172.16.0.1',
        '172.31.255.254',
        '192.168.0.1',
        '192.168.255.254',
      ]) {
        expect(isPrivateIPv4(InternetAddress(ip)), isTrue, reason: ip);
      }
    });

    test('範囲外は認めない', () {
      for (final String ip in <String>[
        '8.8.8.8',
        // 172.16.0.0/12 の外側。/16 と誤って実装すると通ってしまう。
        '172.15.0.1',
        '172.32.0.1',
        '192.167.0.1',
        '192.169.0.1',
        '127.0.0.1',
        '0.0.0.0',
      ]) {
        expect(isPrivateIPv4(InternetAddress(ip)), isFalse, reason: ip);
      }
    });

    test('IPv6 は対象外', () {
      expect(isPrivateIPv4(InternetAddress('fd00::1')), isFalse);
    });
  });

  group('isAnyHost', () {
    test('全公開の指定を見分ける', () {
      expect(isAnyHost('0.0.0.0'), isTrue);
      expect(isAnyHost('::'), isTrue);
      expect(isAnyHost('192.168.0.10'), isFalse);
      expect(isAnyHost('127.0.0.1'), isFalse);
    });
  });

  group('resolveBindAddress', () {
    // NetworkInterface は偽装しない。addresses の要素型が SDK の版で変わる
    // （3.13 で InterfaceAddress になった）ため、偽物を作ると特定の版でだけ
    // 解析が落ちる。
    Future<List<InternetAddress>> addresses(List<String> ips) async =>
        <InternetAddress>[for (final String ip in ips) InternetAddress(ip)];

    test('host 指定があればそのまま使う', () async {
      final InternetAddress address = await resolveBindAddress(
        host: '127.0.0.1',
        addresses: () => addresses(<String>['192.168.0.10']),
      );

      expect(address.address, '127.0.0.1');
    });

    test('0.0.0.0 の明示指定も尊重する（警告は呼び出し側の責務）', () async {
      final InternetAddress address = await resolveBindAddress(
        host: '0.0.0.0',
        addresses: () => addresses(<String>['192.168.0.10']),
      );

      expect(address.address, '0.0.0.0');
    });

    test('host が読めなければ失敗する', () async {
      await expectLater(
        resolveBindAddress(host: 'ほすと'),
        throwsA(isA<BindAddressException>()),
      );
    });

    test('host 未指定ならプライベート IPv4 を選ぶ', () async {
      final InternetAddress address = await resolveBindAddress(
        addresses: () => addresses(<String>['203.0.113.5', '192.168.0.10']),
      );

      expect(address.address, '192.168.0.10');
    });

    test('プライベート IPv4 が無ければ失敗する', () async {
      // 既定を 0.0.0.0 に倒すと、うっかり公衆 Wi-Fi でソースを晒す。
      await expectLater(
        resolveBindAddress(addresses: () => addresses(<String>['203.0.113.5'])),
        throwsA(isA<BindAddressException>()),
      );
    });
  });
}
