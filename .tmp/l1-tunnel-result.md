# L1統合テスト結果 — Task 2.5（トンネル 10MB 双方向転送）

**結論: 目標達成。** `TunnelEndpoint`(Dart) ⇄ `FluseTunnel`(JVM) を実 WebSocket で
繋いだ 10MB の双方向転送は**バイト単位で完全一致**し、4ストリーム同時転送も成立した。
スループットは設計 §8.1 の目標（**> 10MB/s**）を大きく上回る。

---

## 検証環境

| 項目 | 値 |
|---|---|
| ホスト | macOS 26.5.1 / Apple M5 |
| Dart | 3.11.5 (stable) macos_arm64 |
| JDK | OpenJDK 17.0.19（Homebrew） |
| 経路 | ローカルループバックのみ（TCP ⇄ WebSocket ⇄ TCP、実ネットワークは介さない） |
| 実行 | `packages/fluse_server/test/tunnel_l1_integration_test.dart` |
| ハーネス | `dev.fluse.runtime.l1harness`（`./gradlew installDist` の生成物を別プロセス起動） |

**LAN ではなくループバックで計測した。** 目的は「フレーム設計とバックプレッシャが
10MB 級の転送に耐えるか」の判定であり、実効値は Wi-Fi の帯域で頭打ちになる。
ここで見るべきは**中継そのものが律速にならないこと**。

経路は次のとおり。

```text
テストの Socket → TunnelEndpoint(TCP待受) → WebSocket
  → FluseTunnel(JVM) → エコーサーバ(TCP) → 折り返して同じ経路を戻る
```

---

## 計測

スループットは**往復のバイト数**（送り 10MiB + 返り 10MiB）を経過時間で割った値。

### 単一ストリーム（10MiB 往復）

| 試行 | 所要時間 | スループット |
|---|---|---|
| 1 | 70ms | 285.5 MiB/s |
| 2 | 77ms | 257.2 MiB/s |
| 3 | 68ms | 292.5 MiB/s |

### 4ストリーム同時（各 10MiB 往復 / 計 80MiB）

| 試行 | 所要時間 | スループット |
|---|---|---|
| 1 | 144ms | 553.0 MiB/s |
| 2 | 155ms | 514.5 MiB/s |
| 3 | 141ms | 565.0 MiB/s |

4本は DevFS の HTTP PUT 最大3並列 + VM Service の WebSocket 1本という
実運用の同時接続数（Issue #14 の備考）に対応する。

### 目標との比較

| 指標 | 目標（設計 §8.1） | 実測（最小値） | 判定 |
|---|---|---|---|
| トンネル実効スループット | > 10MB/s | 257.2 MiB/s（単一） / 514.5 MiB/s（4本） | **達成** |

バイト一致は 3 試行とも全ストリームで完全一致。

---

## 所見

- **フレーム設計の見直しは不要。** 1MiB 上限のフレームと 64KiB の読み取り単位で、
  ループバックでは中継が律速にならない。目標に対して 25倍以上の余裕がある。
- **バックプレッシャは今回発火していない。** 高水位 4MiB（設計 §8.2-5）に対して、
  ループバックでは送信が詰まらないため到達しない。閾値の妥当性は
  Wi-Fi 経由の L3（Task 6.3）で改めて見る必要がある。
- **目標未達だった場合の次アクション**（今回は不要）: 高水位 4MiB とフレームサイズを
  見直す。とくに `READ_BUFFER_LENGTH`（64KiB）を上げるとフレーム数が減り、
  WebSocket のメッセージ境界処理のコストが下がる。

---

## 再実行の手順

```sh
cd packages/fluse_protocol_kt && ./gradlew installDist
cd ../fluse_server && dart test test/tunnel_l1_integration_test.dart -r expanded
```

ハーネスが未ビルドの環境ではテストは自己スキップする。CI では
`l1-integration` ジョブが Dart と JDK 17 を1ランナーに揃えて実行する。
