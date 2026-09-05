import 'dart:math';

import 'package:fluse_server/fluse_server.dart';
import 'package:test/test.dart';

void main() {
  group('generateToken', () {
    test('base64url の文字だけを使い、パディングを含まない', () {
      final String token = generateToken(random: Random(1));

      expect(token, matches(RegExp(r'^[A-Za-z0-9_-]+$')));
      expect(token, isNot(contains('=')));
    });

    test('32バイト分の長さになる', () {
      // 32バイトを base64 にすると 44 文字（うち末尾1文字がパディング）。
      expect(generateToken(random: Random(1)).length, 43);
    });

    test('呼ぶたびに違う値になる', () {
      final Random random = Random(1);

      expect(
        generateToken(random: random),
        isNot(generateToken(random: random)),
      );
    });
  });

  group('constantTimeEquals', () {
    test('同じ文字列なら true', () {
      expect(constantTimeEquals('abcdef', 'abcdef'), isTrue);
    });

    test('1文字でも違えば false', () {
      expect(constantTimeEquals('abcdef', 'abcdeF'), isFalse);
    });

    test('長さが違えば false', () {
      expect(constantTimeEquals('abc', 'abcdef'), isFalse);
      expect(constantTimeEquals('abcdef', 'abc'), isFalse);
    });

    test('前方が一致する部分文字列でも false', () {
      // 早期 return していると「長さだけ違う」を安く判別できてしまう。
      expect(constantTimeEquals('token', 'token123'), isFalse);
    });

    test('空文字どうしは true、片方だけ空なら false', () {
      expect(constantTimeEquals('', ''), isTrue);
      expect(constantTimeEquals('', 'a'), isFalse);
      expect(constantTimeEquals('a', ''), isFalse);
    });

    test('マルチバイト文字も扱える', () {
      expect(constantTimeEquals('とーくん', 'とーくん'), isTrue);
      expect(constantTimeEquals('とーくん', 'とーくM'), isFalse);
    });
  });
}
