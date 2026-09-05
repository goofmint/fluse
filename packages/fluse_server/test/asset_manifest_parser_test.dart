import 'package:fluse_server/fluse_server.dart';
import 'package:test/test.dart';

void main() {
  group('assets', () {
    test('宣言を順に読み取る', () {
      final AssetDeclarations result = AssetManifestParser.parse('''
name: sample
flutter:
  assets:
    - assets/images/logo.png
    - assets/icons/
''');

      expect(result.assets, <String>[
        'assets/images/logo.png',
        'assets/icons/',
      ]);
    });

    test('flutter: が無ければ空', () {
      // Flutter プロジェクトでなければ asset もフォントも無い。
      expect(AssetManifestParser.parse('name: sample').isEmpty, isTrue);
    });

    test('assets: が無ければ空', () {
      final AssetDeclarations result = AssetManifestParser.parse('''
name: sample
flutter:
  uses-material-design: true
''');

      expect(result.assets, isEmpty);
      expect(result.fonts, isEmpty);
    });

    test('空の pubspec でも落ちない', () {
      expect(AssetManifestParser.parse('').isEmpty, isTrue);
    });
  });

  group('fonts', () {
    test('family と weight / style を読み取る', () {
      final AssetDeclarations result = AssetManifestParser.parse('''
name: sample
flutter:
  fonts:
    - family: Inconsolata
      fonts:
        - asset: assets/fonts/Inconsolata-Regular.ttf
        - asset: assets/fonts/Inconsolata-Bold.ttf
          weight: 700
          style: italic
''');

      expect(result.fonts, hasLength(1));
      final FontFamily family = result.fonts.single;
      expect(family.family, 'Inconsolata');
      expect(family.fonts, hasLength(2));
      expect(family.fonts.first.weight, isNull);
      expect(family.fonts.last.weight, 700);
      expect(family.fonts.last.style, 'italic');
    });

    test('weight はファイル名から推測しない', () {
      // 宣言と食い違うと、端末側の描画だけが静かにずれる。
      final AssetDeclarations result = AssetManifestParser.parse('''
name: sample
flutter:
  fonts:
    - family: Inconsolata
      fonts:
        - asset: assets/fonts/Inconsolata-Bold.ttf
''');

      expect(result.fonts.single.fonts.single.weight, isNull);
    });
  });

  group('不正な宣言', () {
    void expectRejected(String yaml, String reason) {
      expect(
        () => AssetManifestParser.parse(yaml),
        throwsA(isA<AssetManifestException>()),
        reason: reason,
      );
    }

    test('YAML として読めない', () {
      expectRejected('flutter:\n  assets:\n - "壊れた\n', '未終端の文字列');
    });

    test('flutter: がマップでない', () {
      expectRejected('flutter: sample', 'スカラー');
    });

    test('assets: がリストでない', () {
      expectRejected('flutter:\n  assets: assets/logo.png\n', 'スカラー');
    });

    test('assets: の要素が文字列でない', () {
      expectRejected('flutter:\n  assets:\n    - 42\n', '整数');
    });

    test('assets: に空の要素がある', () {
      expectRejected('flutter:\n  assets:\n    - ""\n', '空文字');
    });

    test('fonts: の family が無い', () {
      expectRejected(
        'flutter:\n  fonts:\n    - fonts:\n        - asset: a.ttf\n',
        'family 欠落',
      );
    });

    test('fonts: に fonts: が無い', () {
      // family だけでは届けるものが無い。
      expectRejected(
        'flutter:\n  fonts:\n    - family: Inconsolata\n',
        'fonts 欠落',
      );
    });

    test('font に asset が無い', () {
      expectRejected(
        'flutter:\n  fonts:\n    - family: X\n      fonts:\n        - weight: 700\n',
        'asset 欠落',
      );
    });

    test('weight が整数でない', () {
      expectRejected(
        'flutter:\n  fonts:\n    - family: X\n      fonts:\n        - asset: a.ttf\n          weight: bold\n',
        '文字列の weight',
      );
    });
  });
}
