# fluse_server

増分コンパイル・DevFS 転送・VM Service 制御・TCP トンネル・WebSocket サーバ・
セッション管理を担う開発PC側サーバ。

使い方はリポジトリ直下の [README](../../README.md) にある。

## 反映の1サイクル

`HotReloadOrchestrator` が持つ（設計 §2.2.3(d)）。

```text
recompile → DevFS へ PUT → reloadSources → evict → reassemble
```

**`accept` と `reject` の使い分けがこのクラスの核心**（設計 §10-2）。

| 経路 | 送るもの |
|---|---|
| コンパイルエラー | どちらも送らない |
| reload 失敗 | 必ず `reject` |
| 成功 | `accept` |

reload に失敗した時に `accept` を送ると、`frontend_server` が「送信済み」と
誤認し、以降そのファイルの差分が二度と送られなくなる。

**`reject` だけでは足りない。** 実 `frontend_server` で確かめたところ、差分に
何が載るかは `recompile` の invalidate に入れたファイルで決まる。届かなかった
変更はこちら側が覚えて次回の invalidate に入れ直す（`unapplied`）。
検証は `test/compiler_service_l2_integration_test.dart`。

## 中身

| ファイル | 何を持つか |
|---|---|
| `compiler_service.dart` | `frontend_server` を子プロセスで駆動する |
| `dev_fs_client.dart` | DevFS への gzip HTTP PUT。並列3・リトライ |
| `vm_service_client.dart` | `reloadSources` / `evict` / `reassemble` / `listViews` |
| `tunnel_endpoint.dart` | localhost の TCP を WebSocket の binary frame で運ぶ |
| `ws_server.dart` | `/ws` / `/health` / `/apk` / 案内ページ |
| `session_manager.dart` | ペアリング・端末トークン・1台制限 |
| `asset_bundle_service.dart` | asset の差分。内容ハッシュで判定する |
| `server_runtime.dart` | 上記を繋いで1本にする |
| `timing_report.dart` | 段別の所要時間。判定は p95（設計 §8.1） |

## テスト

```console
$ cd packages/fluse_server
$ dart test
```

統合テストは前提が無ければ自分でスキップする。CI では専用ジョブが前提を
整えて実際に走らせる。

| 段階 | 何に対して | ジョブ |
|---|---|---|
| L1 | 実 WebSocket と JVM のトンネル | `l1-integration` |
| L2 | 実 `frontend_server` | `l2-integration` |
| L3 | 実 Flutter プロセス（デスクトップ） | `l3-integration` |

## 公開

`publish_to: none`。pub.dev への公開は Task 7.3。
