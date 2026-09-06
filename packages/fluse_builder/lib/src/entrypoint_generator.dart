import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

import 'project_info.dart';

/// エントリポイントの生成や追記に失敗したときに投げる例外。
final class EntrypointGeneratorException implements Exception {
  const EntrypointGeneratorException(this.message, {this.path});

  final String message;

  /// 原因となったファイル。分からなければ null。
  final String? path;

  @override
  String toString() {
    final StringBuffer buffer = StringBuffer('エントリポイントを用意できません: $message');
    if (path != null) {
      buffer.write('\n  対象: $path');
    }
    return buffer.toString();
  }
}

/// 生成したものと、書き換えたかどうか。
final class EntrypointResult {
  const EntrypointResult({
    required this.entrypoint,
    required this.addedDependency,
    required this.addedGitignore,
  });

  /// 生成した `.flutter_preview/fluse_main.dart`。
  final File entrypoint;

  /// `pubspec.yaml` に `fluse_runtime` を足したか。
  final bool addedDependency;

  /// `.gitignore` に `.flutter_preview/` を足したか。
  final bool addedGitignore;

  /// 何も書き換えなかったか。2回目以降はこれが true になる。
  bool get isUnchanged => !addedDependency && !addedGitignore;
}

/// プレビュー用のエントリポイントを用意する（設計 §2.2.2）。
///
/// **利用者の資産を壊さない。** ここが触るのは3つだけで、そのいずれも
/// 二度実行して同じ結果になる。
///
/// 1. `.flutter_preview/fluse_main.dart` を作る（自動生成物。毎回上書き）
/// 2. `pubspec.yaml` の `dev_dependencies` に1行足す
/// 3. `.gitignore` に `.flutter_preview/` を1行足す
final class EntrypointGenerator {
  const EntrypointGenerator();

  /// 置き場所（設計 §2.2.2 の `.flutter_preview/`）。
  static const String previewDirName = '.flutter_preview';

  /// 生成するファイル名。
  static const String entrypointName = 'fluse_main.dart';

  /// 追記するパッケージ名。
  static const String runtimePackage = 'fluse_runtime';

  /// `.gitignore` に足す行。
  ///
  /// **必ず足す。** `.flutter_preview/` には `secret` と `keystore/` が入る
  /// （設計 §10-7）。取り込まれると資格情報がリポジトリに残る。
  static const String gitignoreEntry = '$previewDirName/';

  /// 既定のバージョン制約。
  static const String defaultConstraint = '^0.1.0';

  /// [userTarget] を包むエントリポイントを用意する。
  ///
  /// [userTarget] はプロジェクトルートからの相対パス、または絶対パス。
  Future<EntrypointResult> generate({
    required ProjectInfo project,
    required String userTarget,
    String constraint = defaultConstraint,
  }) async {
    final String root = project.root;
    final String importUri = resolveTargetUri(
      root: root,
      packageName: project.packageName,
      userTarget: userTarget,
    );

    // **順序を崩さない。**
    //
    // 1. pubspec を先に片付ける。ここで落ちうるため、生成物を作った後だと
    //    「置き場だけが残る」状態になる。
    // 2. 置き場を作ったら、中身を書く前に無視設定を入れる。`secret` と
    //    署名鍵が入る場所なので、無視されないまま残す時間を作らない
    //    （設計 §10-7）。
    final bool addedDependency = await _ensureDependency(root, constraint);

    final File entrypoint = File(p.join(root, previewDirName, entrypointName));
    await entrypoint.parent.create(recursive: true);
    final bool addedGitignore = await _ensureGitignore(root);

    // 自動生成物なので毎回上書きする。中身が同じなら差分は出ない。
    await entrypoint.writeAsString(buildSource(importUri));

    return EntrypointResult(
      entrypoint: entrypoint,
      addedDependency: addedDependency,
      addedGitignore: addedGitignore,
    );
  }

  // ------------------------------------------------------------ URI の解決

  /// `import` に書く URI を決める。
  ///
  /// **`lib/` の中と外で変える。** `lib/` 配下は `package:` で参照できるが、
  /// 外にあるファイルは `package:` では届かない。`file:` で直に指す。
  ///
  /// `lib/` 外を対象にできるのは、`main.dart` を `bin/` や `tool/` に
  /// 置いている構成があるため。ここで弾くとそのプロジェクトが使えない。
  static String resolveTargetUri({
    required String root,
    required String packageName,
    required String userTarget,
  }) {
    if (userTarget.isEmpty) {
      throw const EntrypointGeneratorException('エントリポイントが指定されていません');
    }

    final String absolute = p.normalize(
      p.isAbsolute(userTarget) ? userTarget : p.join(root, userTarget),
    );
    final String libRoot = p.normalize(p.join(root, 'lib'));

    if (p.isWithin(libRoot, absolute)) {
      // 区切りは `/` に揃える。Windows の `\` は URI に書けない。
      final String relative = p
          .split(p.relative(absolute, from: libRoot))
          .join('/');
      return 'package:$packageName/$relative';
    }

    return p.toUri(absolute).toString();
  }

  // ------------------------------------------------------------ 生成する中身

  /// `.flutter_preview/fluse_main.dart` の中身（設計 §2.2.2）。
  ///
  /// **利用者に編集させない。** ここを直しても次の生成で消える。その旨を
  /// 先頭に書いておく。
  static String buildSource(String importUri) =>
      '''
// このファイルは fluse が生成します。**手で編集しないでください。**
// 次に `fluse init` / `fluse rebuild` を実行した時点で書き換わります。
//
// 役割は、利用者の main() を flusePreviewMain() で包むことだけ
// （設計 §2.2.2 / §2.2.5）。
import 'package:fluse_runtime/fluse_runtime.dart';
import '$importUri' as app;

Future<void> main() => flusePreviewMain(app.main);
''';

  // ------------------------------------------------------------- pubspec

  /// `dev_dependencies` に `fluse_runtime` を1行だけ足す。
  ///
  /// **YAML を組み直さない。** 再シリアライズすると利用者のコメントと
  /// 並びが失われる（設計 §10-8）。`yaml_edit` は元の文字列を保ったまま
  /// 必要な範囲だけを差し替える。
  ///
  /// 既にあれば何もしない。版が違っても書き換えない。**利用者が意図して
  /// 固定している可能性がある。**
  Future<bool> _ensureDependency(String root, String constraint) async {
    final String path = p.join(root, 'pubspec.yaml');
    final File file = File(path);
    if (!file.existsSync()) {
      throw EntrypointGeneratorException('pubspec.yaml がありません', path: path);
    }

    final String original = await file.readAsString();
    final YamlEditor editor;
    try {
      editor = YamlEditor(original);
      // 壊れた YAML はここで気づく。書き換えてから落ちるのを避ける。
      editor.parseAt(<Object>[], orElse: () => wrapAsYamlNode(null));
    } on Exception catch (error) {
      throw EntrypointGeneratorException(
        'pubspec.yaml を YAML として読めません: $error',
        path: path,
      );
    }

    // **`dependencies` 側も見る。** そちらに入れている利用者に対して
    // `dev_dependencies` へも足すと、二重の依存になって
    // `unnecessary_dev_dependency` に引っかかる。
    final YamlNode dependencies = editor.parseAt(<Object>[
      'dependencies',
    ], orElse: () => wrapAsYamlNode(null));
    if (dependencies is YamlMap && dependencies.containsKey(runtimePackage)) {
      return false;
    }

    final YamlNode devDependencies = editor.parseAt(<Object>[
      'dev_dependencies',
    ], orElse: () => wrapAsYamlNode(null));

    if (devDependencies is YamlMap &&
        devDependencies.containsKey(runtimePackage)) {
      return false;
    }
    if (devDependencies.value != null && devDependencies is! YamlMap) {
      throw EntrypointGeneratorException(
        'pubspec.yaml の dev_dependencies がマップではありません',
        path: path,
      );
    }

    if (devDependencies.value == null) {
      // 無ければ作る。**ブロックスタイルで置く。** 既定のフロースタイル
      // （`{a: b}`）は pubspec の見た目から浮く。
      editor.update(
        <Object>['dev_dependencies'],
        wrapAsYamlNode(<String, Object?>{
          runtimePackage: constraint,
        }, collectionStyle: CollectionStyle.BLOCK),
      );
    } else {
      editor.update(<Object>['dev_dependencies', runtimePackage], constraint);
    }

    await file.writeAsString(editor.toString());
    return true;
  }

  // ------------------------------------------------------------ .gitignore

  /// `.gitignore` に `.flutter_preview/` を足す。
  Future<bool> _ensureGitignore(String root) async {
    final String path = p.join(root, '.gitignore');
    final File file = File(path);

    final String original = file.existsSync() ? await file.readAsString() : '';
    if (_ignoresPreviewDir(original)) {
      return false;
    }

    final StringBuffer buffer = StringBuffer(original);
    if (original.isNotEmpty && !original.endsWith('\n')) {
      buffer.write('\n');
    }
    if (original.isNotEmpty) {
      buffer.write('\n');
    }
    buffer
      ..write('# fluse の作業場所。**取り込まないこと。**\n')
      ..write('# 接続用の secret と署名鍵が入る（設計 §10-7）。\n')
      ..write('$gitignoreEntry\n');

    await file.writeAsString(buffer.toString());
    return true;
  }

  /// 既に無視されているか。
  ///
  /// 書き方に幅がある（`/` の有無、先頭の `/`）。**取りこぼすと二重に
  /// 書き足す**ので、いずれの形も同じものとして見る。
  static bool _ignoresPreviewDir(String contents) {
    for (final String raw in contents.split('\n')) {
      final String line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) {
        continue;
      }
      // 否定（`!`）は無視の解除。足す必要があるので数えない。
      if (line.startsWith('!')) {
        continue;
      }
      final String normalized = line
          .replaceAll(RegExp(r'^/+'), '')
          .replaceAll(RegExp(r'/+$'), '');
      if (normalized == previewDirName) {
        return true;
      }
    }
    return false;
  }
}
