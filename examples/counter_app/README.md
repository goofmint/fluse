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

## フォントのライセンス

`assets/fonts/Inconsolata-Regular.ttf` は SIL Open Font License 1.1。
ライセンス全文は `assets/fonts/OFL.txt` を参照。
