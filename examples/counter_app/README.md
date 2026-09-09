# counter_app

fluse の検証用サンプル Flutter アプリ。`flutter create` の標準カウンタに、
**fluse が扱う3つの経路**を意図的に含めてある。

| 画面上の要素 | 検証対象 |
|---|---|
| ロゴ画像 | 画像 asset の同期（DevFS 経由での差分転送） |
| `Inconsolata 0O 1lI` | フォント asset の同期と `FontManifest.json` の生成 |
| ドキュメントディレクトリのパス | Native Plugin の解決（`path_provider`） |
| カウンタ | Hot Reload 時に状態が保持されることの確認 |

## pub workspace の外にある

このアプリはルートの `workspace:` に含めていない。Flutter SDK に依存する
アプリであり、純 Dart のワークスペース（`packages/*`）の解決に混ぜる必要が
ないため。依存解決はこのディレクトリで独立して行う。

```console
$ cd examples/counter_app
$ flutter pub get
```

## ビルド

```console
$ flutter build apk --debug
```

### JDK について

**Gradle 8.14 は JDK 26 以降では動作しない。** JDK 26 が既定の環境では
`assembleDebug` が `* What went wrong:` に Java のバージョン番号だけを出して
失敗する。JDK 17 を明示して実行すること。

```console
$ JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home \
    flutter build apk --debug
```

恒久的に切り替える場合は `flutter config --jdk-dir=<path>` を使う。
パスは環境によって異なるため、リポジトリにはハードコードしていない。

## `path_provider` の解決経路について

`path_provider_android` は Java プラグインクラスを持たず、`jni` /
`jni_flutter` 経由で Android API を直接呼ぶ。したがって
`GeneratedPluginRegistrant` に登録されるのは `JniPlugin` と
`JniFlutterPlugin` であり、`PathProviderPlugin` は現れない。

```text
.flutter-plugins-dependencies:
  jni                   []
  jni_flutter           ['jni']
  path_provider_android ['jni', 'jni_flutter']
```

APK には `libdartjni.so` が同梱される。プラグイン解決に加えて
**ネイティブライブラリの同梱経路まで検証対象に入る**ため、
Task 4.1 以降の Preview App ビルドの確認素材として都合がよい。

## 動作確認

実機にインストールして以下を確認する。

- ロゴ画像とカウンタが表示される
- `Inconsolata 0O 1lI` が等幅フォントで表示される（`0` と `O`、`1` と `l` と `I` が区別できる）
- ドキュメントディレクトリのパスが表示される
  （`path_provider の呼び出しに失敗:` と出た場合はプラグイン解決に失敗している）

## iOS

`ios/Runner/Info.plist` に `NSLocalNetworkUsageDescription` と
`NSAppTransportSecurity` → `NSAllowsLocalNetworking` を追加してある
（それぞれ Android の `INTERNET` 権限 / `usesCleartextTraffic` に相当。
設計 §10-4 の iOS 版）。許可範囲を LAN に限定するため
`NSAllowsArbitraryLoads` は使わず、QR が IP とポートを直接運ぶため
`NSBonjourServices` も追加していない。

### ビルド

```console
$ flutter build ios --debug --no-codesign
```

`--no-codesign` はコード署名なしでビルドするためのフラグ。実機に配布するには
別途 Apple Developer のプロビジョニングが必要だが、シミュレータでの動作確認
だけならこれで足りる。

### シミュレータでの実行

一覧に出る UUID を控えて渡す。**`<simulator id>` のような山括弧のまま
実行しないこと。** シェルが `<` を入力リダイレクトと解釈して、ID が
`flutter run` に渡らない。

```console
$ xcrun simctl list devices available | grep iPhone
    iPhone 16 (A1B2C3D4-1234-5678-9ABC-DEF012345678) (Shutdown)
$ open -a Simulator
$ SIMULATOR_UUID=A1B2C3D4-1234-5678-9ABC-DEF012345678
$ flutter run -d "$SIMULATOR_UUID"
```

### `path_provider` の解決経路について

`path_provider_foundation` は `dartPluginClass`（`objective_c` パッケージ経由の
Dart FFI）で実装されており、Android の `path_provider_android` と同じく
ネイティブの `PathProviderPlugin` クラスを持たない。したがって
`ios/Runner/GeneratedPluginRegistrant.m` の `registerWithRegistry:` は空の
ままになるが、これは異常ではない。ビルド成果物の `Runner.app/Frameworks/`
に `objective_c.framework` が同梱されていることで解決経路を確認できる。

### 動作確認

シミュレータで起動して以下を確認する。

- `assets/images/fluse_logo.png` の画像が描画される
- font `Inconsolata` が描画される（`0` と `O`、`1` と `l` と `I` が区別できる）
- `path_provider` の `getApplicationDocumentsDirectory()` が解決し、
  `MissingPluginException` にならない

## フォントのライセンス

`assets/fonts/Inconsolata-Regular.ttf` は SIL Open Font License 1.1。
ライセンス全文は `assets/fonts/OFL.txt` を参照。
