# CHANGELOG

## 0.1.0

初回。Phase1 のワイヤ表現一式。

- 制御メッセージ（`hello` / `vmServiceReady` / `ready` / `log` / `error` /
  `accept` / `reject` / `reload` / `compileError` / `compileOk` / `ping` /
  `pong` / `close`）の定義と符号化
- トンネルフレーム（`open` / `data` / `close`）
- `protocolVersion` とネゴシエーション。食い違えば `PROTOCOL_MISMATCH`
- エラーコード（設計 §5.1）: `SDK_NOT_FOUND` / `PROJECT_NOT_FLUTTER` /
  `NO_DEVICE` / `INSTALL_SIGNATURE_CONFLICT` / `PROTOCOL_MISMATCH` /
  `PROJECT_MISMATCH` / `REVISION_MISMATCH` / `APP_OUTDATED` / `COMPILE_ERROR` /
  `RELOAD_REJECTED` / `TUNNEL_LOST` / `AUTH_FAILED`
- `BuildMeta`（ビルドフラグ）とその解釈
- 秘匿値の伏せ字
- Kotlin 実装と突き合わせるゴールデン（`test/fixtures/wire_golden.json`）
