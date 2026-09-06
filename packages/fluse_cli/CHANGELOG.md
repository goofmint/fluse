# CHANGELOG

## 0.1.0

初回。Phase1 の CLI 一式。

- `fluse init` — 解析 → エントリポイント生成 → `pub get` → keystore →
  APK ビルド → 端末へ導入の6段。どの段で止まったかが分かるようにしてある
- `fluse start` — 指紋の突き合わせ、待ち受けアドレスの選択、サーバ起動、
  コンソールへの QR 描画、`r`（手動リロード）/ `q`（終了）
- `fluse rebuild` — 指紋の差分を出して作り直し、入れ直す（`--force` で無条件）
- `fluse doctor` — Flutter SDK / adb / keytool / ポート / `.flutter_preview` の
  整合。1つ落ちても他の検査は続ける
- `fluse devices` — 繋がっている端末とペアリング済みの端末。`deviceToken` は出さない
- `fluse.yaml` の読み書き。CLI引数 > 環境変数 > ファイル > 既定値
- 共通オプション `--flutter-sdk` / `--verbose` / `--version` / `--help`
