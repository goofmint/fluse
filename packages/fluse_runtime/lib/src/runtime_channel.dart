import 'package:flutter/services.dart';

/// Dart 側から Native へ通知する口。
///
/// 実体は [MethodChannel] だが、テストで実チャネルを叩くと Flutter の
/// バインディングが要る。必要な形だけを契約として切り出す。
abstract interface class RuntimeChannelContract {
  /// VM Service が立ち上がったことを Native へ伝える。
  Future<void> vmServiceReady(String uri);
}

/// `dev.fluse/runtime` の [MethodChannel] を使う本番実装。
final class MethodChannelRuntime implements RuntimeChannelContract {
  const MethodChannelRuntime();

  /// Kotlin 側と揃える。片方だけ変えると通知が届かなくなる。
  static const String channelName = 'dev.fluse/runtime';

  /// VM Service が立ち上がったことの通知。
  static const String vmServiceReadyMethod = 'vmServiceReady';

  static const MethodChannel _channel = MethodChannel(channelName);

  @override
  Future<void> vmServiceReady(String uri) =>
      _channel.invokeMethod<void>(vmServiceReadyMethod, uri);
}
