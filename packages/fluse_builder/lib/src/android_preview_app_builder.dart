import 'dart:io';

import 'builder_contracts.dart';
import 'keystore_info.dart';
import 'preview_app_builder.dart';
import 'project_info.dart';

/// [PreviewAppBuilder]（Android 具象）を [PreviewAppBuilderContract] へ
/// 嵌めるアダプタ（Task 10.2 / Issue #98）。
///
/// **委譲するだけ。** `PreviewAppBuilder` 本体には一切手を入れない。
final class AndroidPreviewAppBuilder implements PreviewAppBuilderContract {
  const AndroidPreviewAppBuilder(this._delegate);

  /// 実際にビルドを行う既存の具象クラス。
  final PreviewAppBuilder _delegate;

  @override
  Future<BuildResult> build({
    required ProjectInfo project,
    required File entrypoint,
    KeystoreInfo? keystore,
    String? applicationIdSuffix,
  }) async {
    // **契約は keystore を nullable にしている（iOS には概念が無いため）。**
    // だが Android には署名鍵が必須で、無いままでは `PreviewAppBuilder.build`
    // に渡す `KeystoreInfo` が作れない。黙って落ちる（`as` や null 参照の
    // 例外）代わりに、ここで何が要るかが分かる形で弾く。
    //
    // **`async` にして throw を Future の中へ入れる。** 同期に投げると、
    // `await installer.build(...)` の前段（引数の評価）でそのまま外へ
    // 抜けてしまい、呼び出し側の `try`/`await` の組み方によっては拾い損ねる。
    if (keystore == null) {
      throw ArgumentError.value(
        keystore,
        'keystore',
        'AndroidPreviewAppBuilder は keystore なしでは組み立てられません '
            '（Android の署名に必須です）',
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
