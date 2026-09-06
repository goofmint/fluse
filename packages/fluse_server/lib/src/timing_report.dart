import 'dart:convert';

/// 1つの段の統計。
///
/// **平均だけでは足りない。** たまに跳ねる段は平均に埋もれるが、
/// 使っている人はその1回を「遅い」と感じる。p95 まで見る。
final class StageStats {
  const StageStats({
    required this.stage,
    required this.count,
    required this.minMs,
    required this.maxMs,
    required this.meanMs,
    required this.p50Ms,
    required this.p95Ms,
  });

  /// 段の名前。`HotReloadOrchestrator` の `stage*` と対応する。
  final String stage;

  /// 何回分か。
  final int count;

  /// 一番速かった回（ミリ秒）。
  final int minMs;

  /// 一番遅かった回（ミリ秒）。
  final int maxMs;

  /// 平均（ミリ秒）。**これだけを見ない。** たまに跳ねる段は埋もれる。
  final double meanMs;

  /// 中央値（ミリ秒）。普段どのくらいか。
  final int p50Ms;

  /// 95 パーセンタイル（ミリ秒）。**判定はこれで行う。**
  final int p95Ms;

  /// [samples] から作る。空では作れない。
  static StageStats of(String stage, List<int> samples) {
    if (samples.isEmpty) {
      // **0 で埋めない。** 「計測していない」と「0ms だった」は違う。
      throw ArgumentError.value(samples, 'samples', '$stage の計測がありません');
    }
    final List<int> sorted = List<int>.of(samples)..sort();
    return StageStats(
      stage: stage,
      count: sorted.length,
      minMs: sorted.first,
      maxMs: sorted.last,
      meanMs: sorted.reduce((int a, int b) => a + b) / sorted.length,
      p50Ms: percentile(sorted, 50),
      p95Ms: percentile(sorted, 95),
    );
  }

  /// 昇順に並んだ [sorted] の [rank] パーセンタイル。
  ///
  /// **最近傍順位法**（切り上げ）。補間しないのは、元が整数ミリ秒で
  /// 標本数も少なく、補間しても精度が上がらないため。
  static int percentile(List<int> sorted, int rank) {
    if (sorted.isEmpty) {
      throw ArgumentError.value(sorted, 'sorted', '空です');
    }
    final int index = ((rank / 100) * sorted.length).ceil() - 1;
    return sorted[index.clamp(0, sorted.length - 1)];
  }

  /// レポートに貼る形。キーはフィールド名と同じ。
  Map<String, Object?> toJson() => <String, Object?>{
    'stage': stage,
    'count': count,
    'minMs': minMs,
    'maxMs': maxMs,
    'meanMs': meanMs,
    'p50Ms': p50Ms,
    'p95Ms': p95Ms,
  };

  @override
  String toString() =>
      '$stage: p50 ${p50Ms}ms / p95 ${p95Ms}ms '
      '(min ${minMs}ms, max ${maxMs}ms, $count回)';
}

/// 設計 §8.1 の目標1つ分。
final class TimingTarget {
  const TimingTarget({
    required this.label,
    required this.stages,
    required this.budgetMs,
  });

  /// 表に出す名前。
  final String label;

  /// 合計して見る段。空なら総所要時間そのもの。
  final List<String> stages;

  /// 上限（ミリ秒）。
  final int budgetMs;
}

/// 反映サイクルの計測をまとめる（設計 §8.1）。
///
/// **判定は p95 で行う。** 平均で通っても、5回に1回1秒かかるなら
/// 目標を満たしているとは言えない。
final class TimingReport {
  TimingReport({List<TimingTarget> targets = defaultTargets})
    : _targets = targets;

  /// 総所要時間を指す予約語。[TimingTarget.stages] が空の時に使う。
  static const String totalStage = 'total';

  /// 設計 §8.1 の目標。
  static const List<TimingTarget> defaultTargets = <TimingTarget>[
    TimingTarget(label: '1ファイル変更 → 画面反映', stages: <String>[], budgetMs: 1000),
    TimingTarget(
      label: 'うち増分コンパイル',
      stages: <String>['recompile'],
      budgetMs: 400,
    ),
    TimingTarget(
      label: 'うち DevFS 転送',
      stages: <String>['devfsWrite'],
      budgetMs: 200,
    ),
    TimingTarget(
      label: 'うち reloadSources + reassemble',
      stages: <String>['reloadSources', 'reassemble'],
      budgetMs: 300,
    ),
  ];

  final List<TimingTarget> _targets;

  /// サイクル1回分の `timings` をそのまま並べる。
  ///
  /// **段ごとの配列にしてはいけない。** 段が出たり出なかったりするため
  /// （`evict` は変更 asset があるサイクルにしか出ない）、段ごとに詰めると
  /// 同じ添字が別のサイクルを指し、合わせて見る目標の合計が混ざる。
  final List<Map<String, int>> _timings = <Map<String, int>>[];

  /// 記録したサイクル数。
  int get cycles => _timings.length;

  /// 1サイクル分を足す。
  ///
  /// [timings] は `HotReloadResult.timings`。**現れなかった段は
  /// 0 で埋めない。** 出ていない段（差分 asset が無ければ `evict` は
  /// 出ない）を 0ms として混ぜると、平均が実態より小さく見える。
  void add(Map<String, int> timings) {
    _timings.add(<String, int>{
      ...timings,
      totalStage: timings.values.fold(0, (int sum, int ms) => sum + ms),
    });
  }

  /// 記録済みの段（`total` を含む）。出た回だけ数える。
  List<StageStats> get stats {
    final Map<String, List<int>> samples = <String, List<int>>{};
    for (final Map<String, int> cycle in _timings) {
      for (final MapEntry<String, int> entry in cycle.entries) {
        samples.putIfAbsent(entry.key, () => <int>[]).add(entry.value);
      }
    }
    return <StageStats>[
      for (final MapEntry<String, List<int>> entry in samples.entries)
        StageStats.of(entry.key, entry.value),
    ];
  }

  /// 目標との比較。標本の無い段を含む目標は落とさず `null` で返す。
  List<TimingVerdict> get verdicts => <TimingVerdict>[
    for (final TimingTarget target in _targets) _verdictOf(target),
  ];

  TimingVerdict _verdictOf(TimingTarget target) {
    final List<String> stages = target.stages.isEmpty
        ? <String>[totalStage]
        : target.stages;

    // 合計を見る目標は、サイクルごとに足してから分布を取る。
    // **段ごとの p95 を足さない。** 別のサイクルで跳ねた値を足すと、
    // 実際には起きていない最悪値を作ってしまう。
    //
    // **段が1つでも欠けたサイクルは数えない。** 片方だけを足すと合計が
    // 実際より小さくなり、届いていない目標を「達成」と判じてしまう。
    final List<int> combined = <int>[];
    for (final Map<String, int> cycle in _timings) {
      int sum = 0;
      bool complete = true;
      for (final String stage in stages) {
        final int? ms = cycle[stage];
        if (ms == null) {
          complete = false;
          break;
        }
        sum += ms;
      }
      if (complete) {
        combined.add(sum);
      }
    }

    if (combined.isEmpty) {
      return TimingVerdict(target: target, stats: null);
    }
    return TimingVerdict(
      target: target,
      stats: StageStats.of(target.label, combined),
    );
  }

  /// 人が読む表。
  String render() {
    final StringBuffer buffer = StringBuffer()
      ..writeln('計測 ${_timings.length} サイクル')
      ..writeln();
    for (final StageStats stat in stats) {
      buffer.writeln('  $stat');
    }
    buffer
      ..writeln()
      ..writeln('  設計 §8.1 との比較（判定は p95）');
    for (final TimingVerdict verdict in verdicts) {
      buffer.writeln('  $verdict');
    }
    return buffer.toString();
  }

  /// 機械が読む形。レポートに貼るために使う。
  String toJsonString() =>
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'cycles': _timings.length,
        'stages': <Object?>[for (final StageStats stat in stats) stat.toJson()],
        'targets': <Object?>[
          for (final TimingVerdict verdict in verdicts) verdict.toJson(),
        ],
      });
}

/// 目標1つ分の判定。
final class TimingVerdict {
  const TimingVerdict({required this.target, required this.stats});

  /// 比べた相手。
  final TimingTarget target;

  /// 標本が無ければ null。
  final StageStats? stats;

  /// 目標を満たしたか。標本が無ければ null（「達成」でも「未達」でもない）。
  bool? get met {
    final StageStats? measured = stats;
    return measured == null ? null : measured.p95Ms <= target.budgetMs;
  }

  /// レポートに貼る形。`met` は未計測なら null。
  Map<String, Object?> toJson() => <String, Object?>{
    'label': target.label,
    'budgetMs': target.budgetMs,
    'stages': target.stages,
    'met': met,
    if (stats != null) 'stats': stats!.toJson(),
  };

  @override
  String toString() {
    final StageStats? measured = stats;
    if (measured == null) {
      return '${target.label}: 未計測（目標 ${target.budgetMs}ms）';
    }
    return '${target.label}: p95 ${measured.p95Ms}ms '
        '(p50 ${measured.p50Ms}ms) 目標 ${target.budgetMs}ms → '
        '${met! ? '達成' : '未達'}';
  }
}
