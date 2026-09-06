# 性能計測結果 — Task 6.4（反映経路の所要時間）

**結論: デスクトップ経路では設計 §8.1 の目標を全て満たす。** 1ファイル変更から
画面反映まで **p95 221ms**（目標 1.0秒）。各段も目標内に収まる。

**ただし実機での計測は未実施。** ここで測ったのは CI 上のデスクトップ Flutter に
対する経路で、**トンネルと Runtime を通っていない**。実機の数字はこれに Wi-Fi の
往復が乗る。§8.1 の目標は実機に対するものなので、この結果は「サーバ側の処理が
律速ではない」ことを示すに留まる。

---

## 検証環境

| 項目 | 値 |
|---|---|
| 実行 | GitHub Actions `ubuntu-latest`（`l3-integration` ジョブ） |
| 対象 | `examples/counter_app` をデスクトップ（Linux / GTK）で起動 |
| Flutter | stable（`subosito/flutter-action@v2`） |
| 経路 | ホスト内のみ。DevFS も VM Service も loopback |
| テスト | `packages/fluse_server/test/reload_pipeline_l3_integration_test.dart` |

**共有ランナーで測っている。** CPU も I/O も他と分け合うため、絶対値は環境で
動く。ここで見たいのは**どの段が支配的か**と**目標に対する余裕**。

経路は次のとおり。トンネル（WebSocket 中継）と Runtime（端末側）は通らない。

```text
ファイル変更 → frontend_server で差分コンパイル → DevFS へ HTTP PUT
  → reloadSources → （asset があれば evict）→ reassemble
```

---

## 計測

22サイクル（うち先頭3回はウォームアップとして捨てた後の値）。**判定は p95。**
平均で通っても、10回に1回1秒かかるなら使っている人の体感は「遅い」になる。

| 段 | p50 | p95 | min | max | 回数 |
|---|---|---|---|---|---|
| recompile（増分コンパイル） | 12ms | 23ms | 10ms | 31ms | 22 |
| devfsWrite（DevFS 転送） | 4ms | 9ms | 4ms | 9ms | 22 |
| resolveIsolate（isolate 特定） | 20ms | 20ms | 20ms | 20ms | 1 |
| reloadSources | 95ms | 105ms | 64ms | 106ms | 22 |
| reassemble | 87ms | 98ms | 81ms | 316ms | 22 |
| evict（asset 追い出し） | 8ms | 8ms | 8ms | 8ms | 1 |
| **合計** | **202ms** | **221ms** | 192ms | 440ms | 22 |

`resolveIsolate` と `evict` の回数が1なのは、出た回だけ数えているため。
isolate は一度特定したら使い回す。`evict` は変更 asset があるサイクルにしか
出ない。**出なかった段を 0ms として混ぜない**（混ぜると平均が実態より小さく見える）。

`reassemble` の max 316ms は asset を差し替えたサイクル。画像が変わるので
ウィジェットツリーの作り直しが重くなる。p95 に出ていないのは、22回のうち
1回だけだから。

## 目標との比較（設計 §8.1）

| 指標 | 目標 | 実測（p95） | 判定 |
|---|---|---|---|
| 1ファイル変更 → 画面反映 | < 1.0秒 | 221ms | **達成** |
| うち増分コンパイル | < 400ms | 23ms | **達成** |
| うち DevFS 転送 | < 200ms | 9ms | **達成** |
| うち reloadSources + reassemble | < 300ms | 195ms | **達成** |
| トンネル実効スループット | > 10MB/s | 257.2 MiB/s（単一） / 514.5 MiB/s（4本） | **達成**（`.tmp/l1-tunnel-result.md`） |

`reloadSources + reassemble` はサイクルごとに足してから分布を取っている。
**段ごとの p95 を足していない。** 別々のサイクルで跳ねた値を合成すると、
実際には起きていない最悪値を作ってしまう（足すと 203ms、実測は 195ms）。

---

## 所見

**支配的なのは VM 側**。`reloadSources` + `reassemble` で合計の 9割を占める。
`recompile`（23ms）と `devfsWrite`（9ms）はどちらも目標の 1/10 以下で、
ここを削っても体感は変わらない。

設計 §8.2 の最適化（デバウンス 50ms、DevFS の並列3・gzip、asset の内容
ハッシュによる差分判定、4MB のバックプレッシャ）は実装済みで、いずれも
**緩めていない**。目標に届いている今、これらを触る理由が無い。

余裕は 1.0秒 に対して 221ms。実機ではこれに Wi-Fi の往復が乗るが、
差分 dill は counter_app 規模で 12KB 程度なので、**11.9MB/s 出ていれば
残り 779ms に収まる**計算になる。L1 の実測（257 MiB/s、ループバック）は
中継そのものが律速でないことを示している。実際の Wi-Fi は数十Mbps 程度
なので、この見積もりでは足りる。**ただし実測していない。**

### 測れていないもの

| 何 | なぜ | どこで埋めるか |
|---|---|---|
| 実機での総所要時間 | Android 実機と adb が要る | 下の手順 |
| トンネル + Runtime の往復 | 同上 | 同上 |
| 実 Wi-Fi 上のスループット | L1 はループバック計測 | 同上 |

---

## 再実行の手順

### CI（デスクトップ経路）

`l3-integration` ジョブが毎回出す。ログの `== L3 反映経路の所要時間 ==` を見る。

目標に届かなくなった時に落としたい場合は、環境変数を立てる。**既定では
落とさない。** 共有ランナーの数字は環境で動くうえ、§8.1 の目標は実機に
対するもの。

```yaml
env:
  FLUSE_L3_ASSERT_TIMING: "1"
```

### 実機（トンネルと Runtime を通らない経路）

1. `examples/counter_app` をビルドして実機に入れ、起動する
2. logcat から VM Service の URI を取る
3. `adb forward tcp:0 tcp:<端末側ポート>`
4. 回して測る

```console
$ cd packages/fluse_server
$ dart run tool/spike_hot_reload.dart \
    --vm-service http://127.0.0.1:<ホスト側ポート>/<認証コード>/ \
    --project <counter_app のパス> \
    --cycles 20 --warmup 3 \
    --report ../../.tmp/perf-device.json
```

`--cycles` は測る回数、`--warmup` は捨てる回数。毎回ソースの中身を変えるので、
「差分が空で速い」という数字にはならない。

### 実機（フルスタック）

`docs/e2e-checklist.md` のシナリオ1を実行し、1-4（Dart を変える）で
保存から画面が変わるまでを見る。**ここだけは段別に割れない。** 端末側の
時刻とホストの時刻を突き合わせる仕組みが無いため、体感と実測の突き合わせに留まる。

---

## この結果をどう読むか

| 読み方 | 可否 |
|---|---|
| サーバ側の処理が律速か | **判断できる**（していない） |
| どの段を最適化すべきか | **判断できる**（VM 側。ただし今は余裕がある） |
| 実機で 1.0秒 に収まるか | **判断できない**（Wi-Fi の往復が未計測） |
