/// ログや例外文に載せる前に秘密情報を伏せる。
///
/// 設計 §6.1 の「トークンは常にマスク（先頭4文字 + `***`）」。
///
/// `fluse_server` の `redact.dart` と同じ振る舞い。**あちらを呼ばない。**
/// `fluse_builder` から `fluse_server` へ依存すると設計 §2.1 の
/// レイヤリングが崩れる。共有できる場所はここしかない。
library;

/// マスク後に付ける記号。
const String maskSuffix = '***';

/// 先頭4文字を残して伏せる。
///
/// **5文字未満は全体を伏せる。** 4文字しかない値の先頭4文字を残すと、
/// 元の値がそのまま残ってマスクの意味が無くなる。
String maskToken(String value) {
  if (value.length < 5) {
    return maskSuffix;
  }
  return '${value.substring(0, 4)}$maskSuffix';
}
