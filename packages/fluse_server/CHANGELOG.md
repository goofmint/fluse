# CHANGELOG

## 0.1.0

初回。Phase1 のサーバ側一式。

- `CompilerService` — `frontend_server` の起動・`compile` / `recompile` /
  `accept` / `reject`、診断の解釈
- `DevFSClient` — DevFS の作成と gzip HTTP PUT（並列3・リトライ）
- `VmServiceClient` — `reloadSources` / `evict` / `reassemble` / `listViews` /
  `setAssetDirectory`
- `HotReloadOrchestrator` — 反映の1サイクル。届かなかった変更の持ち越し
- `TunnelEndpoint` — localhost の TCP を WebSocket の binary frame で運ぶ
- `WsServer` — `/ws` / `/health` / `/apk`（トークン検証、不一致は 404）/ 案内ページ
- `SessionManager` — ペアリングトークン、端末トークン、1台制限
- `AssetBundleService` — asset の差分。内容ハッシュで判定
- `FileWatcher` — 50ms のデバウンス、指紋対象の変更で監視停止
- `FluseLogger` — 構造化ログと秘匿値の伏せ字
- `TimingReport` — 段別の所要時間。判定は p95
