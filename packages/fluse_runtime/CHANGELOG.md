# CHANGELOG

## 0.1.0

初回。Phase1 の端末側ランタイム一式。

- `FluseInitProvider` — ContentProvider による自動初期化。debug でのみ動き、
  初期化は背景で行う
- `FluseStore` — 端末トークンの保存。API 23 未満は Tink が平文で鍵束を書くため
  記憶のみに留める
- `DeviceIdentity` — ANDROID_ID 由来の `deviceId`。取れない場合も共有の定数へ
  倒さない
- `FluseConnection` — WebSocket 接続、`hello` / `ready`、指数バックオフでの
  再接続（1s → 2s → … → 30s）
- `FluseTunnel` — `open` を受けて端末の `127.0.0.1:<vmServicePort>` へ繋ぐ
- `FluseConnectActivity` — QR の読み取り（CameraX 1.3 系 + ZXing core）と手入力
- `FluseErrorOverlay` — コンパイルエラーの赤い画面。`compileOk` で自動解除
- `FluseCleartext` — 平文通信の可否の判定
- 権限とマニフェストの宣言は `src/debug` にのみ置く
