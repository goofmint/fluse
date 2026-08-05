import 'dart:convert';

import 'package:fluse_server/fluse_server.dart';
import 'package:fluse_server/testing.dart';
import 'package:test/test.dart';

void main() {
  late MemoryLogSink sink;

  /// 時刻を固定してイベントの比較を安定させる。
  DateTime fixedClock() => DateTime.utc(2026, 8, 5, 12, 34, 56);

  FluseLogger loggerAt(
    FluseLogLevel level, {
    Iterable<String> secrets = const <String>[],
  }) => FluseLogger(
    sinks: <FluseLogSink>[sink],
    minimumLevel: level,
    secrets: secrets,
    clock: fixedClock,
  );

  Map<String, Object?> decoded(int index) =>
      jsonDecode(sink.lines[index]) as Map<String, Object?>;

  setUp(() => sink = MemoryLogSink());

  group('出力形式', () {
    test('1イベントが1行の JSON になる', () {
      loggerAt(FluseLogLevel.debug).info('compile finished');

      expect(sink.lines, hasLength(1));
      expect(sink.lines.single, isNot(contains('\n')));
      expect(decoded(0), <String, Object?>{
        'ts': '2026-08-05T12:34:56.000Z',
        'level': 'info',
        'message': 'compile finished',
      });
    });

    test('複数イベントが JSON Lines として読める', () {
      final FluseLogger logger = loggerAt(FluseLogLevel.debug)
        ..debug('a')
        ..warn('b');

      expect(logger.minimumLevel, FluseLogLevel.debug);
      final List<Map<String, Object?>> events = sink.lines
          .map((String l) => jsonDecode(l) as Map<String, Object?>)
          .toList();
      expect(events.map((Map<String, Object?> e) => e['level']), <String>[
        'debug',
        'warn',
      ]);
    });

    test('構造化フィールドを載せられる', () {
      loggerAt(FluseLogLevel.debug).info(
        'reload',
        fields: <String, Object?>{'durationMs': 128, 'files': 3},
      );

      expect(decoded(0)['durationMs'], 128);
      expect(decoded(0)['files'], 3);
    });

    test('予約キーはフィールドで上書きされない', () {
      // 上書きを許すとログの機械処理が壊れる。
      loggerAt(FluseLogLevel.debug).info(
        'real message',
        fields: <String, Object?>{'level': 'error', 'message': 'spoofed'},
      );

      expect(decoded(0)['level'], 'info');
      expect(decoded(0)['message'], 'real message');
    });

    test('JSON にできない値も落とさず文字列化する', () {
      loggerAt(FluseLogLevel.debug).info(
        'uri',
        fields: <String, Object?>{'target': Uri.parse('http://example.com/a')},
      );

      expect(decoded(0)['target'], 'http://example.com/a');
    });
  });

  group('レベルフィルタ', () {
    test('閾値未満は出力されない', () {
      loggerAt(FluseLogLevel.warn)
        ..debug('d')
        ..info('i')
        ..warn('w')
        ..error('e');

      expect(
        sink.lines.map((String l) => (jsonDecode(l) as Map)['level']),
        <String>['warn', 'error'],
      );
    });

    test('level は後から変更できる', () {
      final FluseLogger logger = loggerAt(FluseLogLevel.error)..info('skipped');
      expect(sink.lines, isEmpty);

      logger
        ..minimumLevel = FluseLogLevel.info
        ..info('emitted');
      expect(sink.lines, hasLength(1));
    });
  });

  group('resolveLevel', () {
    test('FLUSE_LOG_LEVEL を読む', () {
      expect(
        FluseLogger.resolveLevel(
          environment: <String, String>{'FLUSE_LOG_LEVEL': 'debug'},
        ),
        FluseLogLevel.debug,
      );
    });

    test('明示指定が環境変数より優先される', () {
      expect(
        FluseLogger.resolveLevel(
          explicit: 'error',
          environment: <String, String>{'FLUSE_LOG_LEVEL': 'debug'},
        ),
        FluseLogLevel.error,
      );
    });

    test('未知の値は無視して次の優先度に落ちる', () {
      expect(
        FluseLogger.resolveLevel(
          explicit: 'とてもうるさく',
          environment: <String, String>{'FLUSE_LOG_LEVEL': 'warn'},
        ),
        FluseLogLevel.warn,
      );
    });

    test('どこにも無ければ fallback', () {
      expect(
        FluseLogger.resolveLevel(environment: <String, String>{}),
        FluseLogLevel.info,
      );
    });

    test('warning は warn の別名として受け付ける', () {
      expect(FluseLogLevel.tryParse('WARNING'), FluseLogLevel.warn);
    });
  });

  group('トークンのマスク', () {
    test('フィールドのトークンは平文で残らない', () {
      loggerAt(FluseLogLevel.debug).info(
        'accepted',
        fields: <String, Object?>{
          'deviceToken': 'DT-abcdefghijklmnop',
          'deviceId': 'pixel-8',
        },
      );

      expect(decoded(0)['deviceToken'], 'DT-a***');
      expect(decoded(0)['deviceId'], 'pixel-8');
      expect(sink.lines.single, isNot(contains('abcdefghijklmnop')));
    });

    test('message 中の VM Service URI の認証コードもマスクされる', () {
      loggerAt(
        FluseLogLevel.debug,
      ).info('vm service at http://127.0.0.1:43219/xY7Kq2Lm9Ab=/');

      expect(sink.lines.single, isNot(contains('xY7Kq2Lm9Ab')));
      expect(decoded(0)['message'], contains('xY7K***'));
    });

    test('登録した秘密値は message からも消える', () {
      loggerAt(
        FluseLogLevel.debug,
        secrets: <String>['abcdefghij'],
      ).error('install failed: token abcdefghij rejected');

      expect(decoded(0)['message'], 'install failed: token abcd*** rejected');
    });

    test('addSecret で後から登録できる', () {
      final FluseLogger logger = loggerAt(FluseLogLevel.debug)
        ..addSecret('zyxwvutsrq')
        ..warn('leaked zyxwvutsrq here');

      expect(logger.minimumLevel, FluseLogLevel.debug);
      expect(decoded(0)['message'], 'leaked zyxw*** here');
    });
  });

  group('close', () {
    test('全シンクを閉じる', () async {
      final _CountingSink a = _CountingSink();
      final _CountingSink b = _CountingSink();

      await FluseLogger(sinks: <FluseLogSink>[a, b], clock: fixedClock).close();

      expect(a.closeCount, 1);
      expect(b.closeCount, 1);
    });

    test('途中のシンクが失敗しても残りを閉じ、最初の例外を投げる', () async {
      // 途中で抜けるとファイルハンドルが残る。
      final _CountingSink after = _CountingSink();
      final FluseLogger logger = FluseLogger(
        sinks: <FluseLogSink>[_FailingSink('1つ目'), _FailingSink('2つ目'), after],
        clock: fixedClock,
      );

      await expectLater(
        logger.close(),
        throwsA(
          isA<StateError>().having(
            (StateError e) => e.message,
            'message',
            '1つ目',
          ),
        ),
      );
      expect(after.closeCount, 1);
    });
  });
}

/// close の呼び出し回数を記録するシンク。
final class _CountingSink implements FluseLogSink {
  int closeCount = 0;

  @override
  void writeLine(String line) {}

  @override
  Future<void> close() async => closeCount++;
}

/// close が必ず失敗するシンク。
final class _FailingSink implements FluseLogSink {
  _FailingSink(this.label);

  final String label;

  @override
  void writeLine(String line) {}

  @override
  Future<void> close() async => throw StateError(label);
}
