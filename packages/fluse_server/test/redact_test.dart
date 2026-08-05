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

    test('URI 単体を処理する', () {
      expect(
        redactVmServiceUri('ws://192.168.0.10:8181/AbCdEfGhIjK=/ws'),
        'ws://192.168.0.10:8181/AbCd***/ws',
      );
    });

    test('地の文に埋まった URI だけを置換する', () {
      expect(
        redactVmServiceUri(
          'vm service at http://127.0.0.1:43219/xY7Kq2Lm9Ab=/ に接続しました',
        ),
        'vm service at http://127.0.0.1:43219/xY7K***/ に接続しました',
      );
    });

    test('1つの文に複数の URI があれば全て処理する', () {
      expect(
        redactVmServiceUri(
          'from http://127.0.0.1:1/aaaaaaaaaa/ to ws://127.0.0.1:2/bbbbbbbbbb/',
        ),
        'from http://127.0.0.1:1/aaaa***/ to ws://127.0.0.1:2/bbbb***/',
      );
    });

    test('URI として解釈できない文字列はそのまま返す', () {
      // Uri.tryParse が null を返す入力。
      expect(redactVmServiceUri('http://[::'), 'http://[::');
    });

    test('クエリの秘密パラメータをマスクする', () {
      // 設計 §4.2(b) の /apk?t=<pairingToken>。
      expect(
        redactVmServiceUri('http://192.168.0.10:8180/apk?t=abcdefghij'),
        'http://192.168.0.10:8180/apk?t=abcd***',
      );
      expect(
        redactVmServiceUri(
          'http://192.168.0.10:8180/x?deviceToken=abcdefghij&d=pixel',
        ),
        'http://192.168.0.10:8180/x?deviceToken=abcd***&d=pixel',
      );
    });

    test('重複したクエリキーの値を落とさない', () {
      // queryParameters は重複キーを潰すため、組み立て直すと値が消える。
      expect(
        redactVmServiceUri(
          'http://192.168.0.10:8180/x?tag=a&tag=b&t=abcdefghij',
        ),
        'http://192.168.0.10:8180/x?tag=a&tag=b&t=abcd***',
      );
    });

    test('重複した秘密キーは全てマスクする', () {
      expect(
        redactVmServiceUri(
          'http://192.168.0.10:8180/x?t=abcdefghij&t=zyxwvutsrq',
        ),
        'http://192.168.0.10:8180/x?t=abcd***&t=zyxw***',
      );
    });

    test('秘密でないクエリは変更しない', () {
      expect(
        redactVmServiceUri('http://192.168.0.10:8180/health?verbose=1'),
        'http://192.168.0.10:8180/health?verbose=1',
      );
    });

    test('userInfo は無条件にマスクする', () {
      expect(
        redactVmServiceUri('http://user:hunter2@127.0.0.1:8180/health'),
        'http://***@127.0.0.1:8180/health',
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
