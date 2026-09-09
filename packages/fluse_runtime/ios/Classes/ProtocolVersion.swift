import Foundation

/// このプロトコルの版。
///
/// Dart 側の `fluseProtocolVersion`（`packages/fluse_protocol/lib/src/protocol_version.dart`）
/// および Kotlin 側の `FLUSE_PROTOCOL_VERSION`
/// （`packages/fluse_runtime/android/src/wire/kotlin/dev/fluse/protocol/ProtocolVersion.kt`）と
/// **必ず一致させること**。どれか1つだけ上げると
/// `packages/fluse_protocol/test/wire_golden_test.dart` などの突合テストが落ちる
/// （`tool/check_protocol_version.dart` が4実装を突合する）。
public let fluseProtocolVersion: Int = 1

/// 受け取った版と互換かどうか。
///
/// 厳密一致で判定する。片方だけ新しい状態を許すと「なぜか特定の機能だけ動かない」
/// という切り分けの難しい不具合になる。
///
/// 実際の拒否（`reject(PROTOCOL_MISMATCH)` と切断）はサーバ側の責務。
public func isCompatibleProtocolVersion(_ received: Int) -> Bool {
    received == fluseProtocolVersion
}
