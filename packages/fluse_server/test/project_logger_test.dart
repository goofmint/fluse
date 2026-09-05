import 'dart:convert';
import 'dart:io';

import 'package:fluse_server/fluse_server.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('fluse_log_'));
  tearDown(() => temp.deleteSync(recursive: true));

  /// 書き出されたログファイル。
  File logFile() {
    final Directory logs = Directory(
      p.joinAll(<String>[temp.path, ...fluseLogDirectory.split('/')]),
    );
    expect(logs.existsSync(), isTrue, reason: 'ログディレクトリが作られていない');
    final List<File> files = logs.listSync().whereType<File>().toList();
    expect(files, hasLength(1));
    return files.single;
  }

  test('.flutter_preview/logs に JSON Lines を書く', () async {
    final FluseLogger logger = openProjectLogger(
      projectRoot: temp.path,
      levelOverride: 'debug',
    );

    logger
      ..info('起動しました', fields: <String, Object?>{'port': 8180})
      ..warn('注意');
    await logger.close();

    final List<String> lines = logFile()
        .readAsLinesSync()
        .where((String l) => l.isNotEmpty)
        .toList();
    expect(lines, hasLength(2));

    final Object? first = jsonDecode(lines.first);
    expect(first, isA<Map<String, Object?>>());
    final Map<String, Object?> event = first! as Map<String, Object?>;
    expect(event['level'], 'info');
    expect(event['message'], '起動しました');
    expect(event['port'], 8180);
    expect(event['ts'], isA<String>());
  });

  test('ファイル名に時刻が入り、実行ごとに別ファイルになる', () {
    // 追記で1本にまとめると、どの実行の記録か分からなくなる。
    openProjectLogger(
      projectRoot: temp.path,
      clock: () => DateTime.utc(2026, 5, 1, 12, 34, 56),
    );

    expect(p.basename(logFile().path), startsWith('fluse-2026-05-01T12-34-56'));
    // `:` は Windows のファイル名に使えない。
    expect(p.basename(logFile().path), isNot(contains(':')));
  });

  test('verbose でなければコンソールには出さない', () async {
    // ファイルは常に開く。後から追えることがログの主目的。
    final FluseLogger logger = openProjectLogger(projectRoot: temp.path);
    logger.info('記録だけ');
    await logger.close();

    expect(logFile().readAsStringSync(), contains('記録だけ'));
  });

  test('登録した秘密は出力に現れない', () async {
    final FluseLogger logger = openProjectLogger(
      projectRoot: temp.path,
      levelOverride: 'debug',
    );

    const String token = 'super-secret-token-value';
    logger
      ..addSecret(token)
      ..info('トークンは $token です')
      ..info('フィールド', fields: <String, Object?>{'pairingToken': token});
    await logger.close();

    final String content = logFile().readAsStringSync();
    expect(content, isNot(contains(token)));
  });

  test('ログレベルは環境変数より明示指定が優先する', () async {
    final FluseLogger logger = openProjectLogger(
      projectRoot: temp.path,
      levelOverride: 'error',
      environment: <String, String>{'FLUSE_LOG_LEVEL': 'debug'},
    );

    logger
      ..debug('出ない')
      ..error('出る');
    await logger.close();

    final String content = logFile().readAsStringSync();
    expect(content, isNot(contains('出ない')));
    expect(content, contains('出る'));
  });

  test('環境変数でレベルを上げられる', () async {
    final FluseLogger logger = openProjectLogger(
      projectRoot: temp.path,
      environment: <String, String>{'FLUSE_LOG_LEVEL': 'debug'},
    );

    logger.debug('詳細');
    await logger.close();

    expect(logFile().readAsStringSync(), contains('詳細'));
  });
}
