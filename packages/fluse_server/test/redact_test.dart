import 'package:fluse_server/fluse_server.dart';
import 'package:test/test.dart';

void main() {
  group('maskToken', () {
    // 「先頭4文字 + ***」（設計 §6.1）と、その規則が破綻する短い値の扱い。
    const List<(String input, String expected, String why)> cases =
        <(String, String, String)>[
          ('abcdefghijklmnop', 'abcd***', '通常のトークンは先頭4文字だけ残る'),
          ('abcde', 'abcd***', '5文字ちょうどでも規則どおり'),
          ('abcd', '***', '4文字だと先頭4文字＝全体になるため全マスク'),
          ('abc', '***', '4文字未満も全マスク'),
          ('', '***', '空文字も全マスク（分岐を持たせない）'),
        ];

    for (final (String input, String expected, String why) in cases) {
      test('${input.isEmpty ? '(空文字)' : input} -> $expected : $why', () {
        expect(maskToken(input), expected);
      });
    }
  });

  group('redact', () {
    test('秘密キーの値をマスクする', () {
      final Object? result = redact(<String, Object?>{
        'pairingToken': 'PT-abcdefghijklmnop',
        'deviceToken': 'DT-abcdefghijklmnop',
        'projectSecret': 'PS-abcdefghijklmnop',
        'password': 'hunter22222',
      });

      expect(result, <String, Object?>{
        'pairingToken': 'PT-a***',
        'deviceToken': 'DT-a***',
        'projectSecret': 'PS-a***',
        'password': 'hunt***',
      });
    });

    test('キー名の表記ゆれを拾う', () {
      final Object? result = redact(<String, Object?>{
        'device_token': 'abcdefghij',
        'issuedDeviceToken': 'abcdefghij',
        'AUTHCODE': 'abcdefghij',
      });

      expect(result, <String, Object?>{
        'device_token': 'abcd***',
        'issuedDeviceToken': 'abcd***',
        'AUTHCODE': 'abcd***',
      });
    });

    test('秘密でないキーは変更しない', () {
      final Map<String, Object?> input = <String, Object?>{
        'deviceId': 'pixel-8',
        'port': 8180,
        'ready': true,
        'diagnostics': <String>['a', 'b'],
        'nothing': null,
      };

      expect(redact(input), input);
    });

    test('入れ子の Map / List も再帰的に処理する', () {
      final Object? result = redact(<String, Object?>{
        'session': <String, Object?>{
          'deviceToken': 'abcdefghij',
          'devices': <Map<String, Object?>>[
            <String, Object?>{'pairingToken': 'zyxwvutsrq'},
          ],
        },
      });

      expect(result, <String, Object?>{
        'session': <String, Object?>{
          'deviceToken': 'abcd***',
          'devices': <Map<String, Object?>>[
            <String, Object?>{'pairingToken': 'zyxw***'},
          ],
        },
      });
    });

    test('秘密キーの値が文字列でなくてもマスクする', () {
      // 構造ごと出してしまうと中身が漏れるため、まるごと潰す。
      expect(
        redact(<String, Object?>{
          'token': <String, Object?>{'value': 'abcdefghij'},
        }),
        <String, Object?>{'token': '***'},
      );
    });

    test('引数を変更しない', () {
      final Map<String, Object?> input = <String, Object?>{
        'deviceToken': 'abcdefghij',
      };
      redact(input);
      expect(input['deviceToken'], 'abcdefghij');
    });

    test('secrets に渡した値は本文からも消える', () {
      final Object? result = redact(
        <String, Object?>{
          'message': 'adb install failed with token abcdefghij',
        },
        secrets: <String>['abcdefghij'],
      );

      expect(result, <String, Object?>{
        'message': 'adb install failed with token abcd***',
      });
    });
  });

  group('redactVmServiceUri', () {
    test('認証コードのパスセグメントをマスクする', () {
      expect(
        redactVmServiceUri('http://127.0.0.1:43219/xY7Kq2Lm9Ab=/'),
        'http://127.0.0.1:43219/xY7K***/',
      );
    });

    test('文中に埋まっていても URI 単体なら処理する', () {
      // ログの message はまるごと1本の URI であることが多い。
      expect(
        redactVmServiceUri('ws://192.168.0.10:8181/AbCdEfGhIjK=/ws'),
        'ws://192.168.0.10:8181/AbCd***/ws',
      );
    });

    test('短いパスは認証コードとみなさない', () {
      expect(
        redactVmServiceUri('http://127.0.0.1:8180/health'),
        'http://127.0.0.1:8180/health',
      );
    });

    test('パスの無い URI はそのまま', () {
      expect(
        redactVmServiceUri('http://127.0.0.1:8180'),
        'http://127.0.0.1:8180',
      );
    });

    test('URI でない文字列はそのまま', () {
      expect(redactVmServiceUri('just a message'), 'just a message');
    });
  });

  group('redactSecrets', () {
    test('登録した秘密値を置換する', () {
      expect(
        redactSecrets('token=abcdefghij done', <String>['abcdefghij']),
        'token=abcd*** done',
      );
    });

    test('短すぎる秘密値は無視する（誤爆を避ける）', () {
      // 4文字以下を消し始めると、無関係な単語まで壊れる。
      expect(redactSecrets('a cat sat', <String>['cat']), 'a cat sat');
    });
  });
}
