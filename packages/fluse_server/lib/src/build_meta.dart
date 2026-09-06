/// `BuildMeta` は `fluse_protocol` へ移した（Task 5.5）。
///
/// **`fluse_builder` も同じものを使う。** ビルド時に記録したフラグを、
/// 増分コンパイル側が完全に再現する必要があるため（設計 §10-1）。
/// `fluse_builder` から `fluse_server` へは依存できない（設計 §2.1）ので、
/// 両方が見られる `fluse_protocol` に置いてある。
///
/// 既存の import を変えずに済ませるため、ここから再公開する。
library;

export 'package:fluse_protocol/fluse_protocol.dart'
    show BuildMeta, BuildMetaException;
