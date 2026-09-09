import 'dart:io';

import 'builder_contracts.dart';
import 'keystore_info.dart';
import 'preview_app_builder.dart';
import 'project_info.dart';

/// [PreviewAppBuilder] を [PreviewAppBuilderContract] へ嵌めるアダプタ
/// （Task 10.2 / Issue #98）。
///
/// **`PreviewAppBuilder` 本体は一切変えない。** 動いている Android の実装に
/// 手を入れると、既存のテストと実機での挙動を両方壊しかねない。契約の形に
/// 合わせる責務はこのアダプタだけが負う。
final class AndroidPreviewAppBuilder implements PreviewAppBuilderContract {
  const AndroidPreviewAppBuilder(this._delegate);

  final PreviewAppBuilder _delegate;

  @override
  Future<BuildResult> build({
    required ProjectInfo project,
    required File entrypoint,
    KeystoreInfo? keystore,
    String? applicationIdSuffix,
  }) {
    // **`keystore` が無ければ既定値へ倒さず、ここで止める。** 契約では
    // iOS（automatic signing）を通すために nullable にしているが、
    // `PreviewAppBuilder.build` は Android の署名に keystore を必ず使う。
    // 何もしないまま素通しすると `PreviewAppBuilder.build` 側の
    // `required KeystoreInfo keystore` で型エラーになるだけで、
    // 「なぜ keystore が要るのか」が呼び出し側から見えなくなる。
    if (keystore == null) {
      throw ArgumentError.value(
        keystore,
        'keystore',
        'Android のビルドには keystore が要ります',
      );
    }

    return _delegate.build(
      project: project,
      entrypoint: entrypoint,
      keystore: keystore,
      applicationIdSuffix: applicationIdSuffix,
    );
  }
}
