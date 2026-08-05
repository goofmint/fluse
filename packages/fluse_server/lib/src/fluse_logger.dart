import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'redact.dart';

/// ログレベル。`fluse_protocol` の `LogMessage.level` と同じ語彙を使う
/// （設計 §2.2.1）。深刻度の昇順に並べてある。
enum FluseLogLevel {
  debug,
  info,
  warn,
  error;

  /// 環境変数などの文字列から解決する。未知の値は null を返す。
  static FluseLogLevel? tryParse(String? name) {
    if (name == null) {
      return null;
    }
    final String normalized = name.trim().toLowerCase();
    for (final FluseLogLevel level in values) {
      if (level.name == normalized) {
        return level;
      }
    }
    // `warning` は `warn` の別名としてよく書かれるので受け付ける。
    if (normalized == 'warning') {
      return FluseLogLevel.warn;
    }
    return null;
  }

  /// [other] 以上の深刻度か。閾値との比較に使う。
  bool isAtLeast(FluseLogLevel other) => index >= other.index;
}

/// ログ1行の出力先。
///
/// ファイル / コンソール / テスト用インメモリを差し替えられるようにするため、
/// [FluseLogger] は具体的な出力手段を知らない。
abstract interface class FluseLogSink {
  /// 改行を含まない1行を書く。改行の付与はシンクの責務。
  void writeLine(String line);

  Future<void> close();
}

/// `.flutter_preview/logs/fluse-<timestamp>.log` に追記するシンク（設計 §5.2）。
final class FileLogSink implements FluseLogSink {
  FileLogSink(this._sink, {void Function(Object error)? onWriteError}) {
    // IOSink は書き込みエラーを同期的に投げず、done にだけ届ける。
    // 監視しないと未処理の非同期エラーになり、書き込み失敗にも気付けない。
    // ログ自身の失敗でアプリを落とすのは本末転倒なので、既定は stderr へ出すだけ。
    unawaited(
      _sink.done.catchError(
        (Object error) => (onWriteError ?? _reportToStderr)(error),
      ),
    );
  }

  /// [file] を追記モードで開く。親ディレクトリが無ければ作る。
  factory FileLogSink.open(
    File file, {
    void Function(Object error)? onWriteError,
  }) {
    file.parent.createSync(recursive: true);
    return FileLogSink(
      file.openWrite(mode: FileMode.append),
      onWriteError: onWriteError,
    );
  }

  static void _reportToStderr(Object error) =>
      stderr.writeln('fluse: ログファイルへの書き込みに失敗しました: $error');

  final IOSink _sink;

  @override
  void writeLine(String line) => _sink.writeln(line);

  @override
  Future<void> close() => _sink.close();
}

/// `--verbose` 指定時にコンソールへ流すシンク。
final class StdoutLogSink implements FluseLogSink {
  const StdoutLogSink();

  @override
  void writeLine(String line) => stdout.writeln(line);

  @override
  Future<void> close() async {}
}

/// 構造化ログ（JSON Lines）を出力するロガー。
///
/// 出力される1行は `{"ts":...,"level":...,"message":...,...fields}` の形。
/// **全ての出力経路が [redact] を通る**ので、トークンがログファイルに平文で
/// 残ることはない（設計 §6.1）。
final class FluseLogger {
  FluseLogger({
    required List<FluseLogSink> sinks,
    this.minimumLevel = FluseLogLevel.info,
    Iterable<String> secrets = const <String>[],
    DateTime Function()? clock,
  }) : _sinks = List<FluseLogSink>.unmodifiable(sinks),
       _secrets = <String>{...secrets},
       _clock = clock ?? DateTime.now;

  final List<FluseLogSink> _sinks;
  final Set<String> _secrets;
  final DateTime Function() _clock;

  /// 出力する下限のレベル。実行中に `--verbose` 相当へ切り替えられるよう
  /// 書き換え可能にしてある。
  FluseLogLevel minimumLevel;

  /// ログレベルを解決する。優先順位は CLI引数 > 環境変数 > 既定値
  /// （設計 §9.2）。`fluse.yaml` の解決は CLI 側（Task 5.7）で行うため、
  /// ここでは [explicit] として渡された値をそのまま最優先に扱う。
  static FluseLogLevel resolveLevel({
    String? explicit,
    Map<String, String>? environment,
    FluseLogLevel fallback = FluseLogLevel.info,
  }) {
    return FluseLogLevel.tryParse(explicit) ??
        FluseLogLevel.tryParse(
          (environment ?? Platform.environment)['FLUSE_LOG_LEVEL'],
        ) ??
        fallback;
  }

  /// 本文からも消したい秘密値を登録する。
  ///
  /// キー名に現れない場所（外部プロセスの stderr、例外メッセージ）に
  /// トークンが混ざる経路があるため、値そのものでも消せるようにしている。
  void addSecret(String secret) {
    if (secret.isNotEmpty) {
      _secrets.add(secret);
    }
  }

  void debug(String message, {Map<String, Object?>? fields}) =>
      log(FluseLogLevel.debug, message, fields: fields);

  void info(String message, {Map<String, Object?>? fields}) =>
      log(FluseLogLevel.info, message, fields: fields);

  void warn(String message, {Map<String, Object?>? fields}) =>
      log(FluseLogLevel.warn, message, fields: fields);

  void error(String message, {Map<String, Object?>? fields}) =>
      log(FluseLogLevel.error, message, fields: fields);

  /// 1件のログイベントを出力する。閾値未満なら何もしない。
  void log(
    FluseLogLevel level,
    String message, {
    Map<String, Object?>? fields,
  }) {
    if (!level.isAtLeast(minimumLevel)) {
      return;
    }

    final Map<String, Object?> event = <String, Object?>{
      'ts': _clock().toUtc().toIso8601String(),
      'level': level.name,
      'message': _scrub(message),
    };

    if (fields != null) {
      // マスク判定はキー名を見るため、値だけを個別に渡すと機能しない。
      // fields をまるごと通してから展開する。
      final Map<String, Object?> scrubbed = redactMap(
        fields,
        secrets: _secrets,
      );
      for (final MapEntry<String, Object?> entry in scrubbed.entries) {
        // 予約キーをフィールドで上書きさせない。上書きを許すと
        // ログの機械処理側が壊れる。
        if (event.containsKey(entry.key)) {
          continue;
        }
        event[entry.key] = entry.value;
      }
    }

    final String line = jsonEncode(event, toEncodable: _toEncodable);
    for (final FluseLogSink sink in _sinks) {
      sink.writeLine(line);
    }
  }

  /// 全てのシンクを閉じる。
  ///
  /// 1つのシンクが失敗しても残りは必ず閉じる。途中で抜けるとファイル
  /// ハンドルが残るため。失敗があれば最初の例外を再送出する。
  Future<void> close() async {
    (Object, StackTrace)? firstFailure;
    for (final FluseLogSink sink in _sinks) {
      try {
        await sink.close();
      } on Object catch (error, stackTrace) {
        firstFailure ??= (error, stackTrace);
      }
    }
    if (firstFailure != null) {
      Error.throwWithStackTrace(firstFailure.$1, firstFailure.$2);
    }
  }

  String _scrub(String text) =>
      redactSecrets(redactVmServiceUri(text), _secrets);

  /// jsonEncode が扱えない値を落とさずに残す。ログのために例外を投げるのは
  /// 本末転倒なので、文字列化した上で秘密値の除去だけは通す。
  Object? _toEncodable(Object? value) => _scrub('$value');
}
