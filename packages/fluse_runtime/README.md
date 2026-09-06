# fluse_runtime

ユーザープロジェクトの dev_dependencies に入る端末側ランタイム。接続・
トンネル・エラー表示を担う。

`fluse init` が対象プロジェクトの `pubspec.yaml` へ追記する。手で入れるものでは
ない。使い方はリポジトリ直下の [README](../../README.md) にある。

## dev_dependency である理由

**release ビルドに入れない。** dev_dependency のプラグインは debug にだけ
含まれる。権限（INTERNET / CAMERA）も平文通信の許可も、release の APK には
載らない（設計 §10-4）。

**これは Flutter 3.29.0 以上での話。** dev_dependency のプラグインが Android の
release ビルドから実際に外れるようになったのは flutter/flutter#161343 からで、
それを含む最初のリリースが 3.29.0。それ以前は
`.flutter-plugins-dependencies` に印が付くだけで外れない。`environment.flutter`
を `>=3.29.0` にしてあるのはこのため。**下げてはいけない。**

宣言は `android/src/main/AndroidManifest.xml` ではなく
`android/src/debug/AndroidManifest.xml` に置いてある。`src/main` は空。
CI（`release-manifest` ジョブ）が、release の統合マニフェストに fluse の痕跡が
無いことを毎回確かめている。

## 中身（Android / Kotlin）

| クラス | 何をするか |
|---|---|
| `FluseInitProvider` | ContentProvider による自動初期化。debug でのみ動く |
| `FluseStore` | 端末トークンの保存。API 23 未満は記憶のみに留める |
| `FluseConnection` | WebSocket 接続と再接続（1s → 2s → … → 30s） |
| `FluseTunnel` | `open` を受けて端末の VM Service へ自分から繋ぐ |
| `FluseConnectActivity` | QR の読み取りと手入力 |
| `FluseErrorOverlay` | コンパイルエラーの赤い画面。手では閉じられない |
| `FluseCleartext` | 平文通信の可否を見る |

接続は Application スコープに居る。**Activity や isolate が作り直されても
生き残る**（設計 §10-6）。IDE から Hot Restart しても繋がったまま。

## テスト

Kotlin の単体テストは、例示アプリの Android プロジェクト経由で走らせる。
プラグイン単体では Flutter エンジンの成果物が無くビルドできない。

```console
$ cd examples/counter_app/android
$ gradle :fluse_runtime:testDebugUnitTest
```

Dart 側は `flutter test`。

## 公開

`publish_to: none`。pub.dev への公開は Task 7.3。
