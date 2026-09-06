# fluse_cli

`fluse` コマンド本体。init / start / rebuild / doctor / devices の解析、QR 描画、
コンソールUI、ライフサイクル統括を担う。

使い方はリポジトリ直下の [README](../../README.md) にある。ここに書くのは、
このパッケージが何を持っていて何を持たないか。

## 位置づけ

**振り分けと表示だけを持つ。** 実際の処理は下の層にある（設計 §2.1）。

```text
fluse_cli ──> fluse_builder   （SDK 解決 / 指紋 / keystore / ビルド / 導入）
          └─> fluse_server    （コンパイル / 転送 / トンネル / セッション）
```

逆向きの依存は無い。`fluse_builder` は `fluse_server` を知らない。

## 中身

| ファイル | 何を持つか |
|---|---|
| `fluse_command_runner.dart` | サブコマンドの振り分け。`package:args` の解析だけを借りる |
| `fluse_context.dart` | 全コマンドが共有するもの。外部プロセスもログもここから差し替える |
| `fluse_config.dart` | `fluse.yaml`。CLI引数 > 環境変数 > ファイル > 既定値 |
| `init_command.dart` | 6段（解析 → エントリポイント → pub get → 鍵 → ビルド → 導入） |
| `start_command.dart` | サーバを立てて QR を出し、キー入力を待つ |
| `rebuild_command.dart` | 指紋が動いていれば作り直す |
| `doctor_command.dart` | 環境と `.flutter_preview` の整合を調べる |
| `devices_command.dart` | 繋がっている端末とペアリング済みの端末 |
| `console_qr.dart` | QR をコンソールへ描く。`package:qr` は行列までしか作らない |
| `connect_uri.dart` | `fluse://connect?...`。端末側と同じ形でなければならない |

## `package:args` の `Command` を使わない理由

あちらは実行の入口も抱えるため、`FluseContext` を渡す口が無い。解析だけを
借りて、実行は `FluseCommand` が持つ。`FluseContext` の組み立てを呼び出し側
（`bin/fluse.dart`）に委ねているのは、SDK の解決が失敗しても `doctor` だけは
動かしたいため。

## テスト

```console
$ cd packages/fluse_cli
$ dart test
```

## 公開

`publish_to: none`。pub.dev への公開は Task 7.3。
