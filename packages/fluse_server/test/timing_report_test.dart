import 'dart:convert';

import 'package:fluse_server/fluse_server.dart';
import 'package:test/test.dart';

void main() {
  group('パーセンタイル', () {
    test('最近傍順位法で取る', () {
      final List<int> sorted = <int>[10, 20, 30, 40, 50, 60, 70, 80, 90, 100];

      expect(StageStats.percentile(sorted, 50), 50);
      expect(StageStats.percentile(sorted, 95), 100);
      expect(StageStats.percentile(sorted, 100), 100);
    });

    test('1件でも取れる', () {
      expect(StageStats.percentile(<int>[42], 95), 42);
    });

    test('空では取れない', () {
      // **0 を返さない。** 「計測していない」を「0ms」と混ぜない。
      expect(() => StageStats.percentile(<int>[], 50), throwsArgumentError);
    });
  });

  group('段の統計', () {
    test('並んでいない標本でも同じ結果になる', () {
      final StageStats stats = StageStats.of('recompile', <int>[30, 10, 20]);

      expect(stats.count, 3);
      expect(stats.minMs, 10);
      expect(stats.maxMs, 30);
      expect(stats.meanMs, 20);
      expect(stats.p50Ms, 20);
    });

    test('標本が無ければ作れない', () {
      expect(() => StageStats.of('recompile', <int>[]), throwsArgumentError);
    });
  });

  group('レポート', () {
    TimingReport reportOf(List<Map<String, int>> cycles) {
      final TimingReport report = TimingReport();
      for (final Map<String, int> cycle in cycles) {
        report.add(cycle);
      }
      return report;
    }

    test('総所要時間は段の合計になる', () {
      final TimingReport report = reportOf(<Map<String, int>>[
        <String, int>{'recompile': 100, 'devfsWrite': 50, 'reloadSources': 30},
      ]);

      final StageStats total = report.stats.firstWhere(
        (StageStats s) => s.stage == TimingReport.totalStage,
      );
      expect(total.p95Ms, 180);
    });

    test('出なかった段を 0 で埋めない', () {
      // evict は変更 asset が無ければ出ない。0ms として混ぜると
      // 平均が実態より小さく見える。
      final TimingReport report = reportOf(<Map<String, int>>[
        <String, int>{'recompile': 100},
        <String, int>{'recompile': 100, 'evict': 40},
      ]);

      final StageStats evict = report.stats.firstWhere(
        (StageStats s) => s.stage == 'evict',
      );
      expect(evict.count, 1);
      expect(evict.meanMs, 40);
    });

    test('判定は p95 で行う', () {
      // 平均は 180ms で目標（400ms）に収まるが、10回に1回 900ms 掛かる。
      // これを「達成」と呼ぶと、使っている人の体感と食い違う。
      final TimingReport report = reportOf(<Map<String, int>>[
        for (int i = 0; i < 9; i++) <String, int>{'recompile': 100},
        <String, int>{'recompile': 900},
      ]);

      final TimingVerdict compile = report.verdicts.firstWhere(
        (TimingVerdict v) => v.target.stages.contains('recompile'),
      );
      expect(compile.stats?.meanMs, 180);
      expect(compile.stats?.p95Ms, 900);
      expect(compile.met, isFalse);
    });

    test('合わせて見る目標はサイクルごとに足す', () {
      // **段ごとの p95 を足さない。** 別のサイクルで跳ねた値を足すと、
      // 実際には起きていない最悪値を作ってしまう。
      final TimingReport report = reportOf(<Map<String, int>>[
        <String, int>{'reloadSources': 200, 'reassemble': 10},
        <String, int>{'reloadSources': 10, 'reassemble': 200},
      ]);

      final TimingVerdict reload = report.verdicts.firstWhere(
        (TimingVerdict v) => v.target.stages.contains('reassemble'),
      );
      expect(reload.stats?.maxMs, 210, reason: '段ごとの最大を足せば 400 になる');
      expect(reload.met, isTrue);
    });

    test('計測が無い目標は達成にも未達にもしない', () {
      final TimingReport report = reportOf(<Map<String, int>>[
        <String, int>{'recompile': 100},
      ]);

      final TimingVerdict devfs = report.verdicts.firstWhere(
        (TimingVerdict v) => v.target.stages.contains('devfsWrite'),
      );
      expect(devfs.met, isNull);
      expect(devfs.stats, isNull);
      expect('$devfs', contains('未計測'));
    });

    test('目標を満たせば達成になる', () {
      final TimingReport report = reportOf(<Map<String, int>>[
        <String, int>{
          'recompile': 300,
          'devfsWrite': 100,
          'reloadSources': 150,
          'reassemble': 50,
        },
      ]);

      expect(
        report.verdicts.map((TimingVerdict v) => v.met),
        everyElement(isTrue),
      );
    });

    test('JSON に段と判定が入る', () {
      final TimingReport report = reportOf(<Map<String, int>>[
        <String, int>{'recompile': 100},
      ]);

      final Object? decoded = jsonDecode(report.toJsonString());
      expect(decoded, isA<Map<String, Object?>>());
      final Map<String, Object?> map = decoded! as Map<String, Object?>;
      expect(map['cycles'], 1);
      expect(map['stages'], isA<List<Object?>>());
      expect(map['targets'], hasLength(TimingReport.defaultTargets.length));
    });

    test('表に段と判定が並ぶ', () {
      final TimingReport report = reportOf(<Map<String, int>>[
        <String, int>{'recompile': 100},
      ]);

      final String rendered = report.render();
      expect(rendered, contains('recompile'));
      expect(rendered, contains('うち増分コンパイル'));
      expect(rendered, contains('1 サイクル'));
    });
  });
}
