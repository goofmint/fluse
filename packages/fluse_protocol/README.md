# fluse_protocol

fluse のサーバとランタイムが交わす制御メッセージとトンネルフレームの定義・
符号化・バージョンネゴシエーション。

## 相手がいる

同じワイヤ表現を Kotlin でも手書きしている
（[`fluse_protocol_kt`](../fluse_protocol_kt)）。**片方だけ変えると壊れる。**

一致は同じファイルを両方から読むことで担保する。

```text
packages/fluse_protocol/test/fixtures/wire_golden.json
```

`protocolVersion` は Dart 定数・Kotlin 定数・ゴールデンの3箇所にある。突合は
リポジトリ直下の `tool/check_protocol_version.dart` に集約してあり、CI の
最初のジョブで走る。

## 中身

| ファイル | 何を持つか |
|---|---|
| `fluse_message.dart` | 制御メッセージ（`hello` / `ready` / `error` ほか） |
| `message_codes.dart` | `RejectCode` / `CloseCode` / `FluseErrorCode` |
| `tunnel_frame.dart` | トンネルのフレーム（`open` / `data` / `close`） |
| `diagnostic_entry.dart` | コンパイル診断1件 |
| `build_meta.dart` | ビルドフラグ。サーバと端末で同じものを見る |
| `mask.dart` | 秘匿値の伏せ字 |

## テスト

```console
$ cd packages/fluse_protocol
$ dart test
```

## 公開

`publish_to: none`。pub.dev への公開は Task 7.3。
