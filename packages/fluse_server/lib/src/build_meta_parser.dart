import 'build_meta.dart';

/// `flutter build --verbose` の出力から `frontend_server` の起動フラグを
/// 取り出す（設計 §10-1）。
///
/// フラグをハードコードしないのは、Flutter SDK のバージョンで既定の
/// `-D` が変わるため。実際に Flutter 3.41.9 が渡していたのは以下で、
/// **この大半は fluse 側で予測できない**。
///
/// ```text
/// -DFLUTTER_VERSION=3.41.9 -DFLUTTER_CHANNEL=stable
/// -DFLUTTER_GIT_URL=https://github.com/flutter/flutter.git
/// -DFLUTTER_FRAMEWORK_REVISION=00b0c91f06 -DFLUTTER_ENGINE_REVISION=42d3d75a56
/// -DFLUTTER_DART_VERSION=3.11.5 -DFLUTTER_APP_FLAVOR=
/// -Ddart.vm.profile=false -Ddart.vm.product=false
/// -Dflutter.dart_plugin_registrant=file:///...
/// ```
abstract final class BuildMetaParser {
  /// 行頭のタイミング接頭辞。`[        ] [   +4 ms] ` のような形。
  ///
  /// `flutter --verbose` は各行に経過時間を付ける。繰り返し現れるので
  /// 全て剥がす。
  static final RegExp _timingPrefix = RegExp(r'^(?:\[[^\]]*\]\s*)+');

  /// `frontend_server` のスナップショット。実行ファイル名は
  /// `dartaotruntime` / `dart` / `dart.exe` のいずれもありうるので、
  /// スナップショット側を目印にする。
  static const String _snapshotToken = 'frontend_server';

  /// 起動コマンドであることの裏付け。ログの言及行と区別する。
  static const String _targetToken = '--target=flutter';

  /// [verboseOutput] から [BuildMeta] を組み立てる。
  ///
  /// 起動コマンドが見つからない場合は [BuildMetaException] を投げる。
  /// 黙って既定値を返すと、フラグ不一致のまま `fluse start` が動いて
  /// 「リロードしても画面が変わらない」状態になる。
  static BuildMeta parse(String verboseOutput) {
    final List<String> tokens = extractCommandTokens(verboseOutput);

    final List<String> defines = <String>[
      for (final String token in tokens)
        if (token.startsWith('-D')) token.substring(2),
    ];

    return BuildMeta(
      trackWidgetCreation: tokens.contains('--track-widget-creation'),
      enableAsserts: tokens.contains('--enable-asserts'),
      dartDefines: defines,
    );
  }

  /// `frontend_server` の起動コマンドをトークン列として取り出す。
  static List<String> extractCommandTokens(String verboseOutput) {
    String? commandLine;

    for (final String rawLine in verboseOutput.split('\n')) {
      final String line = stripTimingPrefix(rawLine);
      if (line.contains(_snapshotToken) && line.contains(_targetToken)) {
        // 同じビルドで複数回走ることがある（program / plugin registrant）。
        // 最後のものが最終的に使われた kernel に対応する。
        commandLine = line;
      }
    }

    if (commandLine == null) {
      throw const BuildMetaException(
        'flutter build --verbose の出力に frontend_server の起動コマンドが'
        'ありません。--verbose を付けて実行しているか確認してください',
      );
    }

    return tokenize(commandLine);
  }

  /// 行頭のタイミング接頭辞を剥がす。
  static String stripTimingPrefix(String line) =>
      line.replaceFirst(_timingPrefix, '').trimRight();

  /// コマンド行をトークンに割る。
  ///
  /// 単純な空白分割では、引用符で囲まれた値（パスに空白を含む場合など）が
  /// 壊れる。引用符を解釈しつつ、引用符自体は落とす。
  static List<String> tokenize(String commandLine) {
    final List<String> tokens = <String>[];
    final StringBuffer current = StringBuffer();
    String? quote;
    bool hasToken = false;

    void flush() {
      if (hasToken) {
        tokens.add(current.toString());
        current.clear();
        hasToken = false;
      }
    }

    for (int i = 0; i < commandLine.length; i++) {
      final String char = commandLine[i];

      if (quote != null) {
        if (char == quote) {
          quote = null;
        } else {
          current.write(char);
        }
        continue;
      }

      if (char == "'" || char == '"') {
        quote = char;
        // 空文字の引数（`-DFLUTTER_APP_FLAVOR=""`）を落とさない。
        hasToken = true;
        continue;
      }

      if (char == ' ' || char == '\t') {
        flush();
        continue;
      }

      current.write(char);
      hasToken = true;
    }
    flush();

    if (quote != null) {
      // 部分的なトークンを黙って返すと、値の欠けた dartDefines を
      // build_meta.json に記録してしまう。以後 `fluse start` は常に
      // 不一致で止まり、原因が解析の破損だと分からなくなる。
      throw BuildMetaException('コマンド行の引用符 $quote が閉じていません: $commandLine');
    }

    return tokens;
  }
}
