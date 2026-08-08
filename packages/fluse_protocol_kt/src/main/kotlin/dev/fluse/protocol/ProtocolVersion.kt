package dev.fluse.protocol

/**
 * このプロトコルの版。
 *
 * Dart 側の `fluseProtocolVersion`（`packages/fluse_protocol/lib/src/protocol_version.dart`）と
 * **必ず一致させること**。片方だけ上げると
 * `packages/fluse_protocol/test/wire_golden_test.dart` の突合テストが落ちる。
 */
const val FLUSE_PROTOCOL_VERSION = 1

/**
 * 受け取った版と互換かどうか。
 *
 * 厳密一致で判定する。片方だけ新しい状態を許すと「なぜか特定の機能だけ動かない」
 * という切り分けの難しい不具合になる。
 *
 * 実際の拒否（`reject(PROTOCOL_MISMATCH)` と切断）はサーバ側の責務。
 */
fun isCompatibleProtocolVersion(received: Int): Boolean =
    received == FLUSE_PROTOCOL_VERSION
