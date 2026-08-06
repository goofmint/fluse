# スパイク結果 — Task 1.6（GO/NO-GO ゲート）

**結論: GO。** Dart 変更・asset 変更のいずれも端末画面に反映されることを実測で確認した。
差分1サイクルの所要時間は **約 120ms** で、設計 §8.1 の目標（< 1.0秒）を大きく下回る。

ただし**設計の前提が3点間違っていた**。いずれも実測で判明し、修正方法まで確認済み（後述）。

---

## 検証環境

| 項目 | 値 |
|---|---|
| Flutter | 3.41.9 / Dart 3.11.5 / engine 42d3d75a56 |
| 端末 | Android エミュレータ（`sdk_gphone64_arm64`, Android 16, arm64-v8a） |
| アプリ | `examples/counter_app` の debug APK（`flutter build apk --debug`） |
| 経路 | `adb forward tcp:0 tcp:<VM Service ポート>`（トンネル・WebSocket・Runtime は不使用） |
| 実行 | `packages/fluse_server/tool/spike_hot_reload.dart` |

**実機ではなくエミュレータで検証した。** `adb forward` 経由の VM Service アクセスという点では
実機と同じ経路であり、反映経路の成立性を判定するには十分と判断した。
ただし**所要時間は実機で再計測すべき**（下記の計測値はエミュレータのもの）。

---

## 計測

### 初回同期（完全な dill の転送）

| 項目 | 値 |
|---|---|
| dill サイズ | 41,656,152 バイト |
| DevFS 転送 + `reloadSources` | **865〜940ms**（3回の実測） |

### 差分サイクル（Dart 1ファイル + asset 1ファイル）

| 段 | 所要時間 |
|---|---|
| `recompile` | 5〜14ms |
| DevFS 転送（差分 dill 11,936バイト + PNG） | 6〜11ms |
| isolate 特定 | 16〜18ms |
| `reloadSources` | 43〜46ms |
| `evict` | 4〜7ms |
| `reassemble` | 35〜38ms |
| **合計** | **118〜126ms** |

設計 §8.1 の目標 1.0秒に対して**約8分の1**。実機ではもう少し遅くなるはずだが、
桁が変わることはないと見てよい。

### 画面での確認

- Dart: `AppBar` の文言が APK 同梱の `fluse counter_app` から `DART + ASSET OK` に変わった
- asset: ロゴ画像が青系から赤系に差し替わった

---

## 設計の前提が間違っていた点

### 1. 初回は差分 dill ではなく**完全な dill** を送る必要がある

設計 §2.2.3(d) は「`recompile` → DevFS → `reloadSources`」の1サイクルだけを書いているが、
**接続直後にこれをやると失敗する。**

```
reloadSources → success: false
notices: ["Error while starting Kernel isolate task"]
```

原因は、端末で動いているのが **APK に同梱された `kernel_blob.bin`** であり、
こちらの `frontend_server` セッションが持つ「直前の状態」とは無関係であること。
差分だけを送っても VM は文脈を組み立てられない。

**対処**: 接続直後に1度だけ `compile()` の完全な dill を DevFS へ送り、
`reloadSources` を通す。以降は差分でよい。

→ **Task 3.5（サーバ統合）に「接続時の初回同期」を追加する必要がある。**
   `ready` を返す前にこれを済ませておかないと、最初の保存が必ず失敗する。

### 2. asset の反映には `_flutter.setAssetBundlePath` が必要

設計 §2.2.3(d) は「変更assetごとに `ext.flutter.evict`」としか書いていないが、
**これだけでは asset は反映されない。** 端末のエンジンは既定で APK 内の
`flutter_assets` しか見ないため、DevFS に置いても参照されない。

**対処**: `_flutter.listViews` で View を列挙し、各 View に対して
`_flutter.setAssetBundlePath` で DevFS 上の `build/flutter_assets/` を教える。
flutter_tools も最初の asset 更新時に1度だけ呼んでいる（`run_hot.dart:1190-1210`）。

**順序も重要**: ディレクトリの実体が DevFS 上に無いと
`Could not update asset directory.` で失敗する。**先に asset を1つ書き込んでから**
`setAssetBundlePath` を呼ぶこと。

→ **設計 §2.2.3(d) のシーケンスに追記が必要。** 実装は `VmServiceClient.listViews()` /
   `setAssetDirectory()` として本 PR に含めた。

### 3. `--filesystem-root` / `--filesystem-scheme` は使わない

設計 §2.2.3(a) の起動コマンドには
`--filesystem-root <projectRoot> --filesystem-scheme org-dartlang-root` が含まれるが、
**`flutter build apk --debug` はこれらを渡していない**（`--verbose` の実出力で確認）。

その結果 APK の kernel のライブラリ URI は `package:counter_app/main.dart` 形式になる。
増分コンパイル側を `org-dartlang-root:///lib/main.dart` にすると URI が食い違う。

**対処**: `--filesystem-*` を渡さず、エントリポイントも `package:` URI で指定する。
本スパイクは `--scheme package` でこの構成を使い、成功している。

→ **設計 §2.2.3(a) の起動コマンドから2つのフラグを落とす必要がある。**

---

## その他の確認事項

### `rootLibUri` はエントリポイントではなく DevFS 上の dill

`reloadSources(isolateId, rootLibUri: ...)` に渡すのは
**DevFS 上に置いた dill の絶対 URI**（`file:///data/user/0/<pkg>/code_cache/<fs>/main.dart.incremental.dill`）。
エントリポイントの URI を渡すと失敗する。flutter_tools も同じ（`run_hot.dart:1297, 1371`）。

DevFS 上のファイル名は `main.dart.incremental.dill`（`lib/` は付かない）。

### `frontend_server` のスナップショットの場所

実ビルドは `bin/cache/dart-sdk/bin/snapshots/frontend_server_aot.dart.snapshot` を使っている。
本スパイクは `bin/cache/artifacts/engine/<host>/` 側（Task 1.1 の実装）を使ったが、
**どちらでも動いた**（同一ファイル）。ホスト分岐が不要になるので、
`dart-sdk` 側へ寄せるほうが素直（Task 1.1 の PR #47 で保留にしていた判断）。

### `-D` は10個ある

`FLUTTER_VERSION` / `FLUTTER_CHANNEL` / `FLUTTER_GIT_URL` / `FLUTTER_FRAMEWORK_REVISION` /
`FLUTTER_ENGINE_REVISION` / `FLUTTER_DART_VERSION` / `FLUTTER_APP_FLAVOR=` /
`dart.vm.profile=false` / `dart.vm.product=false` / `flutter.dart_plugin_registrant=...`

スパイクでは `build_meta.json` を使わず、SDK の値から近いものを組み立てて通した。
**厳密な再現は Task 5.8（`fluse init`）で `build_meta.json` に記録した値を使う。**

---

## 残る未知

このゲートを通過したことで、残る大きな未知は次の1つに絞られた。

- **トンネルが生 TCP として正しく動くか**（Task 2.5 で実機なしに単独検証できる）

`adb forward` を WebSocket トンネルに置き換えるだけなので、
VM Service 側のプロトコル解釈は一切変わらない。

## 再現手順

```console
$ cd examples/counter_app
$ JAVA_HOME=<jdk17> flutter build apk --debug
$ adb install -r build/app/outputs/flutter-apk/app-debug.apk
$ adb shell am start -n com.example.counter_app/.MainActivity
$ adb logcat -d | grep "Dart VM service"
#   → http://127.0.0.1:<devicePort>/<authCode>/
$ adb forward tcp:0 tcp:<devicePort>
#   → <hostPort>

$ cd ../../packages/fluse_server
$ dart run tool/spike_hot_reload.dart \
    --vm-service http://127.0.0.1:<hostPort>/<authCode>/ \
    --project ../../examples/counter_app \
    --scheme package \
    --asset assets/images/fluse_logo.png
```
