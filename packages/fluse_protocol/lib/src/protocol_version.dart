/// このプロトコルの版。
///
/// `hello` の `protocolVersion` に載る。**サーバとランタイムで一致して
/// いなければ接続を受け付けない**（設計 §2.2.1）。メッセージの形を1つでも
/// 変えたらここを上げること。
///
/// 実際の拒否（`reject(PROTOCOL_MISMATCH)` と切断）はサーバ側の
/// `SessionManager`（Task 3.1）の責務。このパッケージは判定材料だけを
/// 提供し、副作用は持たない。
const int fluseProtocolVersion = 1;

/// 受け取った版と互換かどうか。
///
/// **厳密一致で判定する。** メッセージの追加だけなら前方互換にできる
/// ように見えるが、片方だけ新しい状態を許すと「なぜか特定の機能だけ
/// 動かない」という切り分けの難しい不具合になる。versionを上げたら
/// 両方を更新する運用にする。
bool isCompatibleProtocolVersion(int received) =>
    received == fluseProtocolVersion;
