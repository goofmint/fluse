import 'package:test/test.dart';

import 'l3_flutter_run_harness.dart';

/// ハーネスのうち、実プロセスを起動せずに確かめられる部分。
///
/// **ここだけは実機（実 CI）を待たずに見る。** daemon の行の読み方と
/// URI の組み替えを間違えると、CI でしか出ない失敗になり、
/// 1回15分のジョブで詰めることになる。
void main() {
  group('daemon の行', () {
    test('配列に包まれたメッセージを取り出す', () {
      final List<Map<String, Object?>> messages =
          FlutterRunHarness.parseDaemonLine(
            '[{"event":"app.start","params":{"appId":"abc"}}]',
          );

      expect(messages, hasLength(1));
      expect(messages.single['event'], 'app.start');
    });

    test('JSON でない行は読み飛ばす', () {
      // `flutter run` は進捗や警告も同じ標準出力へ書く。
      expect(
        FlutterRunHarness.parseDaemonLine('Launching lib/main.dart'),
        isEmpty,
      );
      expect(FlutterRunHarness.parseDaemonLine(''), isEmpty);
      expect(FlutterRunHarness.parseDaemonLine('[壊れている'), isEmpty);
    });

    test('配列でない JSON は読み飛ばす', () {
      expect(
        FlutterRunHarness.parseDaemonLine('{"event":"app.start"}'),
        isEmpty,
      );
    });
  });

  group('pubspec の path 依存', () {
    test('相対を絶対に直す', () {
      const String pubspec = '''
dev_dependencies:
  fluse_runtime:
    path: ../../packages/fluse_runtime
''';

      expect(
        FlutterRunHarness.absolutePathDependencies(
          pubspec,
          '/repo/examples/app',
        ),
        contains('path: "/repo/packages/fluse_runtime"'),
      );
    });

    test('絶対はそのまま', () {
      const String pubspec = '    path: /already/absolute\n';

      expect(
        FlutterRunHarness.absolutePathDependencies(pubspec, '/repo'),
        pubspec,
      );
    });

    test('他の行は触らない', () {
      // **`path:` に見えるだけの行を書き換えない。** コメントや、
      // asset の宣言まで書き換えるとプロジェクトが壊れる。
      const String pubspec = '''
name: counter_app
# path: ../../どこか
flutter:
  assets:
    - assets/images/fluse_logo.png
''';

      expect(
        FlutterRunHarness.absolutePathDependencies(pubspec, '/repo'),
        pubspec,
      );
    });
  });

  group('VM Service の URI', () {
    test('ws を http に直し、末尾の ws を落とす', () {
      expect(
        FlutterRunHarness.httpUriOf(
          Uri.parse('ws://127.0.0.1:1234/AbC=/ws'),
        ).toString(),
        'http://127.0.0.1:1234/AbC=/',
      );
    });

    test('認証コードを落とさない', () {
      // 落とすと接続が拒否され、原因が分かりにくい失敗になる。
      final Uri http = FlutterRunHarness.httpUriOf(
        Uri.parse('ws://127.0.0.1:9999/tOkEn123/ws'),
      );

      expect(http.pathSegments, contains('tOkEn123'));
    });

    test('ws が付いていない場合はそのまま', () {
      expect(
        FlutterRunHarness.httpUriOf(
          Uri.parse('ws://127.0.0.1:1/xyz/'),
        ).toString(),
        'http://127.0.0.1:1/xyz/',
      );
    });
  });
}
