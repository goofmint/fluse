# fluse

Flutter のプロジェクトを、**Wi-Fi 越しに実機へホットリロードする**開発ツール。

`flutter run` を USB に繋いだまま抱えなくても、ソースを保存すれば端末の画面が
変わる。Expo Development Client に近い体験を Flutter で作ることを狙っている。

**本番の OTA 配信ではない。** 開発中に手元の端末へ速く反映させるための道具で、
利用者へ配るアプリを更新する仕組みではない。

```console
$ fluse init     # Preview App を作って端末へ入れる（初回だけ）
$ fluse start    # サーバを立てて QR を出す
```

---

## 動くもの・動かないもの

| | |
|---|---|
| 対象 | Android 実機（minSdk 21）。**debug ビルドのみ** |
| 対象外 | iOS、release ビルド |
| 反映されるもの | Dart のソース、asset（画像・フォント） |
| 反映されないもの | 依存の追加、ネイティブ、AndroidManifest、Gradle（→ `fluse rebuild`） |

Phase1 のスコープ外は[下の節](#phase1-のスコープ外)にまとめてある。

## 前提

- Flutter SDK **3.29.0 以上**（`flutter` が PATH にあるか、`--flutter-sdk` で
  場所を渡せること）。下限の理由は[下](#端末側ランタイムが-release-に入らない理由)
- `adb`（Android SDK の platform-tools）
- `keytool`（JDK に入っている）
- 開発 PC と端末が**同じ Wi-Fi / LAN セグメント**に居ること
- 端末の「USB デバッグ」が有効で、`adb devices` に出ること

揃っているかは `fluse doctor` が見る。**先にこれを通す。**

```console
$ fluse doctor

  ✓ Flutter SDK: 3.41.9 (00b0c91f) /opt/flutter
  ✓ adb
  ✓ keytool
  ✓ ポート 8180
  ...
```

## 入れる

pub.dev への公開は準備中。**今はこのリポジトリから入れる。**

```console
$ git clone https://github.com/goofmint/fluse.git
$ cd fluse
$ dart pub global activate --source path packages/fluse_cli
```

`~/.pub-cache/bin` に PATH を通しておくと `fluse` で呼べる。

```console
$ export PATH="$PATH:$HOME/.pub-cache/bin"
```

公開後は次のように入れられるようになる。

```console
$ dart pub global activate fluse_cli
```

## 使う

### 1. Preview App を作って入れる

端末を USB で繋いでから、Flutter プロジェクトの直下で実行する。

```console
$ cd path/to/your_flutter_app
$ fluse init
```

6段ある。プロジェクトを読み、エントリポイントを作り、依存を解決し、署名鍵を
用意し、APK を作り、端末へ入れる。**最初の1回は数分かかる**（`flutter build apk`
そのものの時間）。

終わると `fluse.yaml` と `.flutter_preview/` が出来る。`.flutter_preview/` には
署名鍵が入るので、`.gitignore` に自動で足される。

### 2. サーバを立てる

```console
$ fluse start

fluse  •  Flutter 3.41.9 (00b0c91f)

  QRコードをPreview Appでスキャンしてください

  ███████████████████████████
  ...

  http://192.168.0.10:8180
  手で入れる場合のトークン: ...
  r: 手動リロード  q: 終了
```

待ち受けるアドレスは、LAN の私設 IPv4 から自動で選ぶ。複数あれば聞かれる。
既定のポートは `8180`。

### 3. 端末から繋ぐ

端末の Preview App を開いて QR を読む。カメラが使えない場合は、コンソールに
出ているトークンとホスト・ポートを手で入れる。ブラウザで
`http://<IP>:<ポート>/` を開くと、同じトークンとインストール用の APK が置いてある。

### 4. 書く

`lib/` の Dart を保存すると、そのまま端末の画面が変わる。**アプリの状態は
保たれる**（カウンタの値は0に戻らない）。asset を差し替えても反映される。

コンパイルエラーになると端末に赤い画面が出て、どこで落ちたかが行番号付きで
並ぶ。直して保存すれば自動で消える。

`r` で手動リロード、`q` で終了。

## コマンド

| コマンド | 何をするか |
|---|---|
| `fluse init` | Preview App を作って端末へ入れる。最初の1回 |
| `fluse start` | サーバを立てて端末を待つ。普段使うのはこれ |
| `fluse rebuild` | 指紋が動いていれば作り直して入れ直す（`--force` で無条件） |
| `fluse doctor` | 足りないものと壊れているものを調べる |
| `fluse devices` | 繋がっている端末とペアリング済みの端末を並べる |

## 設定（`fluse.yaml`）

`fluse init` が作る。**いつもそうしたいこと**を書く場所。

```yaml
version: 1
port: 8180
target: lib/main.dart
applicationIdSuffix: null
dartDefines: []
serveApk: true
```

| キー | 既定 | 何を決めるか |
|---|---|---|
| `port` | `8180` | 待ち受けるポート |
| `target` | `lib/main.dart` | 包む対象のエントリポイント |
| `applicationIdSuffix` | `null` | 署名がぶつかった時に付ける接尾辞 |
| `dartDefines` | `[]` | `-D` で渡す値。順序も含めて意味がある |
| `serveApk` | `true` | 案内ページから APK を配るか |

`serveApk: false` にすると、案内ページにダウンロードのボタンが出ず、`/apk` も
404 を返す。**その場合、端末へ入れる道は USB だけになる。** USB で繋いで
`fluse init`（または `fluse rebuild`）を実行するか、`fluse init` が表示する
`.flutter_preview/build/preview.apk` を手で入れる。

決め方には順序がある。**その場の指定が勝つ。**

```text
CLI 引数  >  環境変数（FLUSE_PORT）  >  fluse.yaml  >  既定値
```

---

## セキュリティ（読んでから使う）

**Phase1 の通信は平文の WebSocket。TLS は無く、サーバの正当性も確かめない**
（設計 §6.1）。次のことが起こりうる。

| 誰が | 何ができるか |
|---|---|
| 同じ LAN で盗み見ている人 | **あなたのプロジェクトのソースを読める。** 差分 dill もトークンも平文で流れる |
| 同上 | `pairingToken` / `deviceToken` を拾って、あなたの端末のふりをして繋げる |
| 経路に割り込める人 | トンネルを乗っ取り、**任意の Dart コードを端末で動かせる** |

そのうえで使ってよいのは、**信頼できる LAN で、自分の端末に対して**だけ。

**避けるべき場所**: カフェ・コワーキング・ゲスト Wi-Fi・社外の来客ネットワーク。
要するに、そこに居る人を全員知っているわけではないネットワーク。

サーバは既定で LAN の私設 IPv4 にだけ待ち受ける。`--host 0.0.0.0` を渡せば
すべてのインタフェースで待つが、**その判断は渡した人のものになる。**
何も警告しないので、書く前に上の表をもう一度読むこと。

### 端末側ランタイムが release に入らない理由

Preview App の権限（INTERNET / CAMERA）と平文通信の許可は **debug ビルドにしか
入らない**（設計 §10-4）。release の APK にこれらは載らず、CI が毎回それを
確かめている。

端末側ランタイム（`fluse_runtime`）は dev_dependency として入るため、release の
ビルドからは外れる。**ただしこれは Flutter 3.29.0 以上での話。** dev_dependency の
プラグインが Android の release ビルドから実際に外れるようになったのは
flutter/flutter#161343 からで、それを含む最初のリリースが 3.29.0。それ以前は
`.flutter-plugins-dependencies` に印が付くだけで外れない。`fluse_runtime` は
`environment.flutter` を `>=3.29.0` にしてあるので、古い Flutter では解決の
段階で弾かれる。

## Phase1 のスコープ外

| 何 | 状態 |
|---|---|
| iOS | 対象外 |
| TLS / 証明書 | 無い。上の「セキュリティ」の通り |
| `fluse` から Hot Restart を起こす | できない |
| 複数端末の同時接続 | 1台のみ。2台目は `TOO_MANY_DEVICES` で断る |

**IDE や `flutter attach` から起こした Hot Restart は別**（設計 §10-6）。
こちらは接続が維持されるように作ってある。端末側の接続は Application
スコープに居るので、Activity や isolate が作り直されても生き残る。

asset の同期は Phase2 の予定だったが、Phase1 に前倒しして入っている。

---

## うまくいかないとき

### 端末に入らない（署名がぶつかる）

```text
✗ インストールに失敗しました (INSTALL_FAILED_UPDATE_INCOMPATIBLE)
```

同じ `applicationId` のアプリが**別の署名で**入っている。普通の
`flutter run` で入れた debug ビルドがあると起きる。`fluse` は利用者の署名鍵に
触らず専用の鍵を作るため、署名が一致しない。

3つ聞かれる。

1. 既存アプリをアンインストールして続行 — **元のアプリのデータは消える**
2. Preview App を別 ID で入れる — `fluse.yaml` に `applicationIdSuffix` を書く
3. 中止

> **2 を選んでも、その場では作り直せない。** `flutter build apk` に
> applicationId を差し替えるオプションが無く、Gradle へ渡す手立てが決まって
> いないため、書き込むところまでで止まる。今は 1 を選ぶか、手で別 ID の
> ビルドを用意することになる。

### 端末が繋がらない（平文が拒否される）

Android 9（API 28）以降は既定で `ws://` を拒む。`fluse_runtime` は debug の
マニフェストで `usesCleartextTraffic` を立てるので、普通はそのまま繋がる。

**アプリが独自の `networkSecurityConfig` を持っていると、そちらが勝つ。**
その場合は debug 用の設定に、繋ぎ先を許可する項目を足す。

```xml
<!-- android/app/src/debug/res/xml/network_security_config.xml -->
<network-security-config>
  <domain-config cleartextTrafficPermitted="true">
    <domain includeSubdomains="false">192.168.0.10</domain>
  </domain-config>
</network-security-config>
```

`fluse doctor` はここまでは見ない。QR は読めるのに繋がらない、という形で出る。

### `APP_OUTDATED` と言われる

Preview App の中身と手元のプロジェクトが食い違っている。**Dart の変更では
起きない**（あれは差分で運べる）。起きるのは次を変えた時。

`pubspec.lock` / `pubspec.yaml` の asset 宣言 / AndroidManifest / Gradle /
ネイティブのソース / ビルドフラグ / Flutter のリビジョン

```console
$ fluse rebuild
```

作り直して入れ直す。差分が無いのに作り直したい時は `--force`。

繋ぐ前に食い違っていれば `fluse start` が起動前に止まり、変わったものを
並べて教える。繋いだ後に食い違えば、監視を止めて端末へ知らせる。

### 端末が繋がっていないのに APK を入れたい

`fluse start` を動かしたまま、端末のブラウザで `http://<IP>:<ポート>/` を開くと
ダウンロードできる。トークンが合わないと 404 を返す（設計 §6.2）。

> `fluse init` / `fluse rebuild` の時点で端末が無い場合は、この URL も QR も
> 出ない。出来上がった APK のパスを表示するだけなので、USB で繋ぎ直すか、
> 手で入れることになる。

---

## 中身

| パッケージ | 役割 |
|---|---|
| [`fluse_cli`](packages/fluse_cli) | `fluse` コマンド本体 |
| [`fluse_server`](packages/fluse_server) | 増分コンパイル・DevFS 転送・VM Service 制御・トンネル |
| [`fluse_builder`](packages/fluse_builder) | SDK 解決・指紋・keystore・APK ビルドと導入 |
| [`fluse_protocol`](packages/fluse_protocol) | サーバと端末が交わすワイヤ表現（Dart） |
| [`fluse_protocol_kt`](packages/fluse_protocol_kt) | 同じワイヤ表現の Kotlin 実装 |
| [`fluse_runtime`](packages/fluse_runtime) | 端末側ランタイム（Flutter プラグイン） |

```text
編集 → frontend_server で差分コンパイル → DevFS へ転送
  → reloadSources → reassemble → 画面が変わる
```

CI のデスクトップ経路での実測は p95 221ms（設計 §8.1 の目標は 1.0秒）。
内訳は [`.tmp/perf-result.md`](.tmp/perf-result.md)。

## 開発

pub workspaces なので、依存はルートで1回解決すれば全パッケージに行き渡る。

```console
$ flutter pub get
$ dart run melos:melos run test     # 全パッケージのテスト
$ dart run melos:melos run analyze  # 静的解析
$ dart run melos:melos run format   # 整形の検査
```

`fluse_runtime` は Flutter プラグインなので、素の Dart SDK ではワークスペースを
解決できない。`dart pub get` ではなく `flutter pub get` を使う。

- 手動の検証手順: [`docs/e2e-checklist.md`](docs/e2e-checklist.md)
- 性能の計測結果: [`.tmp/perf-result.md`](.tmp/perf-result.md)
