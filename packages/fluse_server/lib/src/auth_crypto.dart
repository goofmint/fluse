/// 認証で使う小さな道具（設計 §6.1）。
///
/// トークンの生成と、タイミング差から中身を推測されないための比較。
library;

import 'dart:convert';
import 'dart:math';

/// トークンのバイト長。
///
/// 設計 §6.1 が定める 32 バイト。base64url にすると 43 文字になる。
const int tokenByteLength = 32;

/// 暗号論的に安全な乱数からトークンを1つ作る。
///
/// [random] は**テストから固定列を渡すためだけ**に開いている。本番では
/// 省略して `Random.secure()` を使うこと。予測可能な乱数で作った
/// `pairingToken` は総当たりで当てられる。
String generateToken({Random? random}) {
  final Random source = random ?? Random.secure();
  final List<int> bytes = List<int>.generate(
    tokenByteLength,
    (int _) => source.nextInt(256),
    growable: false,
  );
  // パディングを外す。QR とコンソール表示に載るため、意味の無い `=` は削る。
  return base64Url.encode(bytes).replaceAll('=', '');
}

/// 2つのトークンを定数時間で比較する。
///
/// **`==` を使ってはいけない。** Dart の文字列比較は最初の食い違いで
/// 打ち切るため、応答時間から「何文字目まで合っていたか」が漏れる。
/// LAN 上から何度でも試せる以上、1文字ずつ詰められる。
///
/// 長さが違う場合も途中で戻らない。長い方に合わせて必ず同じ回数だけ回す。
/// **長さ自体は隠せない**（比較回数に出る）が、トークンは固定長なので実害は無い。
bool constantTimeEquals(String a, String b) {
  final List<int> left = utf8.encode(a);
  final List<int> right = utf8.encode(b);

  // 長さの差もフラグに畳み込む。ここで早期 return すると、
  // 「長さだけ合っている」候補を安く選別できてしまう。
  int difference = left.length ^ right.length;

  final int rounds = max(left.length, right.length);
  for (int i = 0; i < rounds; i++) {
    // 範囲外は 0 として扱う。短い側を伸ばして比較回数を揃える。
    final int x = i < left.length ? left[i] : 0;
    final int y = i < right.length ? right[i] : 0;
    difference |= x ^ y;
  }

  return difference == 0;
}
