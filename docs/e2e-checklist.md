# E2E 手動チェックリスト（Task 6.3）

設計 §7.2 の **L4（手動シナリオ）**。CI では実行しない。実機と人の目でしか
確かめられないものだけを置く。

自動テストで足りるものはここに書かない。L1（トンネル）・L2（実
`frontend_server`）・L3（実 Flutter プロセス）は CI が毎回回している。
ここに残るのは、**QR を読む・画面が変わる・選択肢に答える**といった、
機械が代われない部分。

## 検証環境

実施のたびに埋める。**版を残さないと、次に落ちた時に何が変わったのか
分からなくなる。**

| 項目 | 値 |
|---|---|
| 実施日 | |
| OS | |
| Flutter SDK | `flutter --version` の version / revision |
| adb | `adb version`（Android SDK platform-tools） |
| JDK | `keytool` が動くこと（`java -version`） |
| 対象実機 | 機種 / Android 版 |
| fluse | `fluse --version`（導入は下の「fluse の入れ方」） |

### fluse の入れ方

pub.dev への公開は Task 7.3。**それまでは、このリポジトリから入れる。**

```console
$ dart pub global activate --source path packages/fluse_cli
```

`~/.pub-cache/bin` に PATH が通っていること。

## 共通の前提

- 対象が Flutter プロジェクトであること（`pubspec.yaml` に `flutter:` がある）
- 実機が USB で繋がり、`adb devices` に出ること（USB デバッグを許可済み）
- PC と実機が**同じ Wi-Fi**に居ること。別セグメントだと QR は読めても繋がらない
- `fluse doctor` が全項目 OK であること

```console
$ fluse doctor
```

`doctor` は Flutter SDK / adb / keytool / ポートの空き / `.flutter_preview` の
整合（指紋・build_meta・APK・署名鍵・`devices.json`）を見る。**ここが赤い
まま先へ進まない。** 後段の失敗が環境のせいなのか実装のせいなのか
分からなくなる。

### QR に載っているもの（設計 §4.2(a)）

```text
fluse://connect?v=1&h=<LAN IP>&p=<ポート>&pid=<projectId>&t=<トークン>&rev=<先頭8桁>
```

| キー | 中身 | なぜ要るか |
|---|---|---|
| `v` | プロトコル版 | 食い違えば `PROTOCOL_MISMATCH` |
| `h` / `p` | 繋ぎ先 | LAN の私設 IPv4。複数 NIC がある機では選ぶ |
| `pid` | プロジェクトの識別子 | 別プロジェクトへ繋いだら `PROJECT_MISMATCH` |
| `t` | ペアリングトークン | 1回限り。**実値をここへ書き写さない** |
| `rev` | Flutter リビジョンの先頭8桁 | 食い違えば `REVISION_MISMATCH` |

## シナリオ一覧

| # | 何を見るか | 結果 |
|---|---|---|
| 1 | init → start → 接続 → 変更 → エラー → 復旧 → Hot Restart → 再接続 | 未実施 |
| 2 | adb が無い時の APK 配信 | 未実施 |
| 3 | 署名衝突の3択 | 未実施 |
| 4 | `pubspec.lock` 変更 → `APP_OUTDATED` → `rebuild` | 未実施 |

---

## シナリオ1: 通しで動くこと

### 1-1. `fluse init`

```console
$ fluse init
```

**期待**: 6段が順に流れ、最後に Preview App が実機へ入る。

| 段 | 出ること |
|---|---|
| 1/6 | プロジェクトを読む（packageName / applicationId / プラグイン数） |
| 2/6 | `.flutter_preview/fluse_main.dart` を作る |
| 3/6 | `pub get`（`fluse_runtime` を解決する。飛ばすと端末にランタイムが入らない） |
| 4/6 | `.flutter_preview/keystore/` に署名鍵を作る（2回目以降は作り直さない） |
| 5/6 | `flutter build apk --debug`。数分かかる |
| 6/6 | 端末へ入る |

- `fluse.yaml` が出来ていること
- `.gitignore` に `.flutter_preview/` が入っていること（設計 §10-7）
- 端末のアプリ一覧に Preview App が出ること

### 1-2. `fluse start`

```console
$ fluse start
```

**期待**:

- 指紋の突き合わせを通る（食い違えばシナリオ4へ）
- LAN の私設 IPv4 が選ばれる。複数あれば番号で聞かれる
- ターミナルに QR が出る
- `http://<IP>:<ポート>` と手入力用トークンが出る
- `r: 手動リロード  q: 終了` が出る

### 1-3. QR を読む

**操作**: 実機で Preview App を開き、QR を読む。

**期待**: 読み取った瞬間に画面が閉じ、接続される。CLI 側に接続のログが出る。

**カメラが無い / 読めない場合**: アプリの手入力欄に、CLI が出した
トークンを貼る。ホストとポートも手で入れる。

### 1-4. Dart を変える

**操作**: `lib/` の `.dart` を保存する（画面に見える文字を変えると分かりやすい）。

**期待**: 1秒前後で実機の画面が変わる。**アプリの状態は保たれる**
（カウンタの値が0に戻らない）。CLI にリロードのログが出る。

### 1-5. asset を変える

**操作**: `pubspec.yaml` の `flutter: assets:` に載っているファイルを差し替える。

**期待**: 画像が新しいものに変わる。**Dart は変えていないのに変わる**
（DevFS へ転送 → `evict` → `reassemble`）。

### 1-6. コンパイルエラーを出す

**操作**: `lib/main.dart` に `int broken = ;` のような行を足して保存する。

**期待**:

- 実機に赤いオーバーレイが出る。1行に `<印> <file>:<line>:<col>: <message>` の形で並ぶ
- CLI に `COMPILE_ERROR` が出る
- **監視は止まらない**。次の保存を待っている
- **オーバーレイは手で閉じられない**（設計 §5.2）。消し方は直すことだけ

### 1-7. 直す

**操作**: 足した行を消して保存する。

**期待**: オーバーレイがひとりでに消える。画面が新しい内容になる。

### 1-8. Hot Restart

**操作**: IDE や `flutter attach` から Hot Restart を起こす。

**期待**: **接続が切れない**。`FluseConnection` は Application スコープに
居るので、Activity や isolate が作り直されても生き残る（設計 §10-6）。
再送された `vmServiceReady` は二重に扱われない。

### 1-9. 切れて、戻る

**操作**: PC の Wi-Fi を切る、または `fluse start` を落として立て直す。

**期待**:

- 実機側が `TUNNEL_LOST` を出し、`1s → 2s → 4s → …（上限30s）` で繋ぎ直す
- 繋がったら待ち時間が初期値へ戻る
- 繋がった後、そのまま 1-4 の変更が反映される

---

## シナリオ2: adb が無い時の APK 配信

**前提**: `fluse start` が動いていること。`fluse.yaml` の `serveApk` が
`true`（既定）であること。

**操作**: 実機のブラウザで `http://<IP>:<ポート>/` を開く。

**期待**:

- 案内ページが出る
- 「Preview App をダウンロード」から APK が落ちてくる
- 同じページに手入力用のトークンが出ている

**トークンの検証**: `/apk?t=` のトークンが違うと **404** が返る（設計 §6.2）。
403 にすると「ファイルはあるが権限が無い」と教えることになるため。

> **既知の制約**: `fluse init` / `fluse rebuild` の時点で端末が繋がって
> いない場合、**HTTP 配信の URL も2枚目の QR も出ない**。出来上がった APK の
> ローカルパスを表示するだけで、USB で繋ぎ直すか手で入れることになる。
> 配信の部品（`fluse_builder` の `ApkServer`）は在るが、`init` /
> `rebuild` からは呼ばれていない（呼んでいるのはテストのみ）。
> 動く配信経路は `fluse start` 中の `/apk` だけ。設計 §5.1 の `NO_DEVICE`
> が想定する導線は、この点で未完成。

---

## シナリオ3: 署名がぶつかった時の3択

**前提**: 同じ `applicationId` の debug ビルドを、**普通の `flutter run` で**
先に実機へ入れておく。署名が違うため `fluse` の APK は上書きできない。

**操作**: `fluse init`（または `fluse rebuild`）を実行する。

**期待**: install の段でこう聞かれる（設計 §5.3）。

```text
✗ インストールに失敗しました (INSTALL_FAILED_UPDATE_INCOMPATIBLE)

  端末に同じ applicationId (<applicationId>) のアプリが
  別の署名でインストールされています。

  どうしますか？
    1) 既存アプリをアンインストールして続行  (adb uninstall <applicationId>)
    2) Preview App を別IDでインストール      (applicationIdSuffix .preview)
    3) 中止
```

| 選ぶもの | 期待 |
|---|---|
| 1 | 既存を消してから入る。**元のアプリのデータは消える** |
| 2 | `fluse.yaml` に `applicationIdSuffix` を書いて終わる。作り直しが要る |
| 3 | 何もせず終わる。失敗ではない |

**1〜3 以外を入れた場合**: `1 から 3 で答えてください` と聞き直す。**勝手に
決めない**（既存アプリを消す判断を代わりにしてはいけない）。

> **既知の制約**: 2 を選ぶと `fluse.yaml` には書かれるが、**別 ID での
> ビルドはまだできない**。`flutter build apk` に applicationId を差し替える
> オプションが無く（`--application-id-suffix` は存在しない）、Gradle 側へ
> 渡す手立てが決まっていないため、その場で作り直さず終わる。

---

## シナリオ4: `pubspec.lock` を変えて作り直す

**前提**: シナリオ1で繋がったまま。

**操作**: `pubspec.yaml` に依存を1つ足して `flutter pub get` する
（`pubspec.lock` が変わる）。

**期待**:

- 監視が止まる
- 実機へ `APP_OUTDATED` が届く。文言は
  `Preview App が古くなりました。fluse rebuild を実行してください`
- CLI にも同じ警告が出る

指紋に入るのは Dart のソースではなく、**作り直さないと反映できないもの**
だけ（`pubspec.lock` / `pubspec.yaml` の asset 宣言 / Android のマニフェスト /
Gradle / ネイティブ / ビルドフラグ / Flutter リビジョン）。Dart の変更は
Hot Reload が運ぶので指紋には入らない。

**繋ぐ前に差分がある場合**: `fluse start` が起動前に止まる。

```text
✗ APP_OUTDATED: 端末の Preview App が古くなっています

  変わったもの:
    pubspec.lock

  `fluse rebuild` で作り直してください。
```

**復旧**:

```console
$ fluse rebuild
```

**期待**: 変わったものの一覧が出て、作り直し → 入れ直しまで進む。
その後 `fluse start` で繋ぎ直すと、そのまま反映が続く。

差分が無い時に強制するなら `fluse rebuild --force`。

---

## 既知の制約（まとめ）

| 何 | 状態 | 追うところ |
|---|---|---|
| `init` / `rebuild` での APK 配信導線 | 未配線。`ApkServer` はテストからのみ | シナリオ2 |
| 別 ID での Preview App ビルド | 未対応。`fluse.yaml` に書くまで | シナリオ3 |

## 実施結果

実施したら、シナリオ一覧の「結果」を `OK` / `NG（内容）` に書き換える。
期待と違ったものは、**設計にどう書いてあるか → 実際に何が起きたか →
どうしたか → どこで追うか** の順で残す。`.tmp/spike-result.md` と同じ形。
