import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'fingerprint.dart';
import 'project_info.dart';

/// サーバと端末が同じものを見ているかを確かめるための値（設計 §4.2(a)）。
abstract final class ProjectIdentity {
  /// `projectId` に使うハッシュの桁数。
  static const int hashLength = 16;

  /// `appVersion` の桁数。
  static const int appVersionLength = 16;

  /// このプロジェクトの `projectId`。
  ///
  /// **絶対パスを混ぜる**（設計 §10-9）。テンプレートから作った同名の
  /// プロジェクトが複数ある環境で、名前だけだと取り違える。
  ///
  /// 端末側は `pubspec.yaml` の name もパスも知らないため、ここで作った
  /// 値を QR と `app_info.json` の両方へ載せて突き合わせる。
  static String projectIdOf(ProjectInfo project) =>
      projectId(packageName: project.packageName, root: project.root);

  /// [packageName] と [root] から作る。
  static String projectId({required String packageName, required String root}) {
    final Digest digest = sha256.convert(utf8.encode('$packageName $root'));
    return digest.toString().substring(0, hashLength);
  }

  /// 今のビルドを表す `appVersion`。
  ///
  /// **8つのキーを1つに畳む。** `hello` に載せる値なので短くしたいのと、
  /// どのキーが変わったかを端末に伝える必要が無いため（差分の内訳は
  /// サーバ側が持つ）。
  ///
  /// 指紋が1つでも動けば値が変わる。サーバは食い違いを見て
  /// `APP_OUTDATED` を返す（設計 §5.1）。
  static String appVersionOf(Fingerprint fingerprint) {
    // 並びを決めてから畳む。Map の順序に左右されないようにする。
    final List<String> keys = fingerprint.entries.keys.toList()..sort();
    final StringBuffer buffer = StringBuffer();
    for (final String key in keys) {
      buffer
        ..write(key)
        ..write('=')
        ..write(fingerprint.entries[key])
        ..write('\n');
    }
    return sha256
        .convert(utf8.encode(buffer.toString()))
        .toString()
        .substring(0, appVersionLength);
  }
}
