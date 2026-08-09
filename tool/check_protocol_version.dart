// Dart / Kotlin / ゴールデンの `protocolVersion` が一致していることを検査する。
//
// 3 つは別々のファイルに書かれている。片方だけ上げると、ワイヤ表現が
// 食い違ったまま「なぜか特定の機能だけ動かない」不具合になる（設計 §9.1）。
// テストでも突合しているが、テストは実行環境（JDK / Dart SDK）が揃って
// はじめて動く。この検査は正規表現だけで完結するので、CI の最初に置ける。
//
// 使い方: dart run tool/check_protocol_version.dart
// 一致すれば 0、食い違えば 1 で終了する。
import 'dart:convert';
import 'dart:io';

/// 検査対象。パスはリポジトリルートからの相対。
const _dartSource = 'packages/fluse_protocol/lib/src/protocol_version.dart';
const _kotlinSource =
    'packages/fluse_protocol_kt/src/main/kotlin/dev/fluse/protocol/ProtocolVersion.kt';
const _goldenSource = 'packages/fluse_protocol/test/fixtures/wire_golden.json';

/// `const int fluseProtocolVersion = 1;`
final _dartPattern = RegExp(
  r'const\s+int\s+fluseProtocolVersion\s*=\s*(\d+)\s*;',
);

/// `const val FLUSE_PROTOCOL_VERSION = 1`
final _kotlinPattern = RegExp(
  r'const\s+val\s+FLUSE_PROTOCOL_VERSION\s*(?::\s*Int\s*)?=\s*(\d+)',
);

void main(List<String> args) {
  final versions = <String, int>{
    _dartSource: _extractWithPattern(_dartSource, _dartPattern),
    _kotlinSource: _extractWithPattern(_kotlinSource, _kotlinPattern),
    _goldenSource: _extractFromGolden(_goldenSource),
  };

  final distinct = versions.values.toSet();
  if (distinct.length != 1) {
    stderr.writeln('protocolVersion が食い違っています:');
    versions.forEach((path, version) => stderr.writeln('  $version  $path'));
    stderr.writeln(
      '\n変更したら 3 つすべてを同じ値に揃えること。'
      'メッセージの形を変えたのであれば全部を上げる。',
    );
    exit(1);
  }

  stdout.writeln('protocolVersion = ${distinct.single}（3 箇所すべて一致）');
}

/// ソースから定数値を 1 つだけ取り出す。
///
/// 見つからない・複数見つかる場合は、定義の書き換えでこの検査が
/// 素通りしている状態なので落とす。**黙って 0 件を通さない。**
int _extractWithPattern(String path, RegExp pattern) {
  final matches = pattern.allMatches(_read(path)).toList();
  if (matches.isEmpty) {
    _fail(
      '$path から protocolVersion の定義を見つけられません。'
      'このスクリプトの正規表現も更新すること。',
    );
  }
  if (matches.length > 1) {
    _fail('$path に protocolVersion の定義が ${matches.length} 個あります。');
  }
  return int.parse(matches.single.group(1)!);
}

int _extractFromGolden(String path) {
  final decoded = jsonDecode(_read(path));
  if (decoded is! Map<String, dynamic>) {
    _fail('$path の中身が JSON オブジェクトではありません。');
  }
  final version = decoded['protocolVersion'];
  if (version is! int) {
    _fail('$path の protocolVersion が整数ではありません: $version');
  }
  return version;
}

String _read(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    _fail(
      '$path が見つかりません。'
      'リポジトリルートから実行しているか確認すること。',
    );
  }
  return file.readAsStringSync();
}

Never _fail(String message) {
  stderr.writeln(message);
  exit(1);
}
