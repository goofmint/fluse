import 'package:fluse_server/fluse_server.dart';
import 'package:test/test.dart';

void main() {
  /// 応答を1行ずつ食わせ、確定した結果を返す。
  FrontendServerResult? feed(List<String> lines, {bool expectSources = true}) {
    final FrontendServerOutputParser parser = FrontendServerOutputParser(
      expectSources: expectSources,
    );
    for (final String line in lines) {
      parser.addLine(line);
    }
    return parser.result;
  }

  group('応答の解析', () {
    test('成功した compile を解析する', () {
      final FrontendServerResult? result = feed(<String>[
        'result key1',
        'key1',
        '+org-dartlang-root:///lib/main.dart',
        '+package:flutter/material.dart',
        'key1 /tmp/app.dill 0',
      ]);

      expect(result, isNotNull);
      expect(result?.outputPath, '/tmp/app.dill');
      expect(result?.errorCount, 0);
      expect(result?.sources, <Uri>[
        Uri.parse('org-dartlang-root:///lib/main.dart'),
        Uri.parse('package:flutter/material.dart'),
      ]);
      expect(result?.diagnostics, isEmpty);
    });

    test('`result` 行より前の出力は捨てる', () {
      // frontend_server の起動時メッセージなどが混ざる。
      final FrontendServerResult? result = feed(<String>[
        'Warming up...',
        'result key1',
        'key1',
        'key1 /tmp/app.dill 0',
      ]);

      expect(result?.outputPath, '/tmp/app.dill');
      expect(result?.diagnostics, isEmpty);
    });

    test('依存ソースの削除（-uri）を反映する', () {
      final FrontendServerResult? result = feed(<String>[
        'result key1',
        'key1',
        '+package:a/a.dart',
        '+package:b/b.dart',
        '-package:a/a.dart',
        'key1 /tmp/app.dill 0',
      ]);

      expect(result?.sources, <Uri>[Uri.parse('package:b/b.dart')]);
    });

    test('出力パスに空白があっても errorCount を取り違えない', () {
      final FrontendServerResult? result = feed(<String>[
        'result key1',
        'key1',
        'key1 /tmp/my app/app.dill 3',
      ]);

      expect(result?.outputPath, '/tmp/my app/app.dill');
      expect(result?.errorCount, 3);
    });

    test('境界キーだけの行は「出力なし」', () {
      // reject の応答などで起きる。
      final FrontendServerResult? result = feed(<String>[
        'result key1',
        'key1',
      ], expectSources: false);

      expect(result, isNotNull);
      expect(result?.outputPath, isNull);
      expect(result?.errorCount, 0);
    });

    test('expectSources が false なら最初の境界行で確定する', () {
      final FrontendServerResult? result = feed(<String>[
        'result key1',
        'key1 /tmp/app.dill 0',
      ], expectSources: false);

      expect(result?.outputPath, '/tmp/app.dill');
    });

    test('確定後の行は無視する', () {
      final FrontendServerOutputParser parser = FrontendServerOutputParser()
        ..addLine('result key1')
        ..addLine('key1')
        ..addLine('key1 /tmp/app.dill 0')
        ..addLine('key1 /tmp/other.dill 9');

      expect(parser.result?.outputPath, '/tmp/app.dill');
      expect(parser.isComplete, isTrue);
    });

    test('未完了なら result は null', () {
      final FrontendServerOutputParser parser = FrontendServerOutputParser()
        ..addLine('result key1')
        ..addLine('key1');

      expect(parser.result, isNull);
      expect(parser.isComplete, isFalse);
    });

    test('依存ソース列に想定外の接頭辞が来ても壊れない', () {
      final FrontendServerResult? result = feed(<String>[
        'result key1',
        'key1',
        'なにか予期しない行',
        '+package:a/a.dart',
        'key1 /tmp/app.dill 0',
      ]);

      expect(result?.sources, <Uri>[Uri.parse('package:a/a.dart')]);
    });
  });

  group('診断の解析', () {
    test('位置付きのエラーを分解する', () {
      final FrontendServerResult? result = feed(<String>[
        'result key1',
        "org-dartlang-root:///lib/main.dart:12:5: Error: Expected ';' after this.",
        'key1',
        'key1 /tmp/app.dill 1',
      ]);

      expect(result?.errorCount, 1);
      final DiagnosticEntry entry = result!.diagnostics.single;
      expect(entry.severity, DiagnosticSeverity.error);
      expect(entry.file, 'org-dartlang-root:///lib/main.dart');
      expect(entry.line, 12);
      expect(entry.column, 5);
      expect(entry.message, "Expected ';' after this.");
      expect(entry.location, 'org-dartlang-root:///lib/main.dart:12:5');
    });

    test('URI に含まれるコロンで分解を誤らない', () {
      // `org-dartlang-root:` のコロンを位置区切りと取り違えないこと。
      final FrontendServerResult? result = feed(<String>[
        'result key1',
        'package:foo/bar.dart:3:1: Warning: unused',
        'key1',
        'key1 /tmp/app.dill 0',
      ]);

      final DiagnosticEntry entry = result!.diagnostics.single;
      expect(entry.file, 'package:foo/bar.dart');
      expect(entry.line, 3);
      expect(entry.column, 1);
      expect(entry.severity, DiagnosticSeverity.warning);
    });

    test('位置を持たない診断も拾う', () {
      final FrontendServerResult? result = feed(<String>[
        'result key1',
        'Error: something went wrong',
        'key1',
        'key1 /tmp/app.dill 1',
      ]);

      final DiagnosticEntry entry = result!.diagnostics.single;
      expect(entry.severity, DiagnosticSeverity.error);
      expect(entry.file, isNull);
      expect(entry.location, isNull);
      expect(entry.message, 'something went wrong');
    });

    test('継続行は直前の診断に連結する', () {
      // ソース抜粋とキャレット行が続く。単独で出すと文脈が失われる。
      final FrontendServerResult? result = feed(<String>[
        'result key1',
        "org-dartlang-root:///lib/main.dart:12:5: Error: Expected ';'",
        '  final x = 1',
        '            ^',
        'key1',
        'key1 /tmp/app.dill 1',
      ]);

      final DiagnosticEntry entry = result!.diagnostics.single;
      expect(entry.line, 12);
      expect(entry.message, contains('final x = 1'));
      expect(entry.raw, contains('^'));
    });

    test('複数の診断を分けて拾う', () {
      final FrontendServerResult? result = feed(<String>[
        'result key1',
        'org-dartlang-root:///lib/a.dart:1:1: Error: first',
        'org-dartlang-root:///lib/b.dart:2:2: Error: second',
        'key1',
        'key1 /tmp/app.dill 2',
      ]);

      expect(result?.diagnostics, hasLength(2));
      expect(result?.diagnostics.last.file, 'org-dartlang-root:///lib/b.dart');
    });

    test('Context 行も深刻度として扱う', () {
      final FrontendServerResult? result = feed(<String>[
        'result key1',
        'org-dartlang-root:///lib/a.dart:1:1: Context: 補足',
        'key1',
        'key1 /tmp/app.dill 0',
      ]);

      expect(result?.diagnostics.single.severity, DiagnosticSeverity.context);
    });

    test('空行は診断にしない', () {
      final FrontendServerResult? result = feed(<String>[
        'result key1',
        '',
        '   ',
        'key1',
        'key1 /tmp/app.dill 0',
      ]);

      expect(result?.diagnostics, isEmpty);
    });

    test('ラベルの無い先頭行は info として拾う', () {
      final FrontendServerResult? result = feed(<String>[
        'result key1',
        'なにかのメッセージ',
        'key1',
        'key1 /tmp/app.dill 0',
      ]);

      final DiagnosticEntry entry = result!.diagnostics.single;
      expect(entry.severity, DiagnosticSeverity.info);
      expect(entry.message, 'なにかのメッセージ');
    });
  });

  group('DiagnosticSeverity', () {
    test('ラベルから解決する', () {
      expect(DiagnosticSeverity.tryParse('Error'), DiagnosticSeverity.error);
      expect(
        DiagnosticSeverity.tryParse('warning'),
        DiagnosticSeverity.warning,
      );
      expect(
        DiagnosticSeverity.tryParse('Context'),
        DiagnosticSeverity.context,
      );
    });

    test('未知のラベルは null', () {
      expect(DiagnosticSeverity.tryParse('Fatal'), isNull);
    });
  });
}
