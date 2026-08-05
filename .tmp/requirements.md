# Flutter Preview Client 基本設計書 v0.2

## 1. 概要

### 目的

Flutterアプリ開発において、Expo Goに近い開発体験を提供する。

プロジェクト毎に専用のPreview Appを自動生成し、一度インストールした後はDartコード変更のみをリアルタイムに反映する。

Production向けOTAではなく、開発用途専用とする。

---

## 2. 基本コンセプト

本システムは以下の2つのコンポーネントで構成される。

* Preview CLI
* Preview App

Preview Appは共通アプリではない。

Flutterプロジェクトから自動生成される「プロジェクト専用Preview App」とする。

これにより

* Flutter SDK
* Dart SDK
* Native Plugins
* Android/iOS設定

を対象プロジェクトと完全一致させる。

Expo Goではなく、Expo Development Clientに近い設計とする。

---

## 3. システム構成

```text
Flutter Project
│
├── pubspec.yaml
├── pubspec.lock
├── android/
├── ios/
└── lib/

        │

flutter preview init

        │

        ▼

Preview Builder

        │

Flutter SDK検出

pubspec.lock解析

Native Plugin解析

Android/iOS設定取得

        │

        ▼

Project Preview App生成

        │

端末へインストール
```

Preview Appは以後再利用する。

---

## 4. Preview App

Preview Appはプロジェクト専用に生成される。

以下を含む。

* Flutter Engine
* 対象Flutter SDK
* 対象Dart SDK
* プロジェクト内Native Plugin
* Preview Runtime
* Native Bridge
* VM Service Proxy

アプリ起動後はPreview Serverへ接続する。

---

## 5. Preview CLI

CLI名

```
flutter preview
```

サブコマンド

```
flutter preview init
flutter preview start
flutter preview doctor
flutter preview rebuild
flutter preview devices
```

### init

初回のみ実行する。

実施内容

* Flutter SDK取得
* pubspec.lock解析
* Preview App生成
* Debugビルド
* 実機インストール

---

### start

Preview Serverを起動する。

起動後

* File Watch開始
* Incremental Compiler開始
* WebSocket Server開始
* QRコード表示

---

### rebuild

Native Plugin変更時のみ使用する。

Preview Appを再生成する。

---

## 6. QRコード

サーバー起動時

```
flutter preview start
```

コンソールへ表示

```
██████████████
██ ▄▄▄▄▄ ██
██ █   █ ██
██ █▄▄▄█ ██
...
```

QRコード内容

```
preview://

host=192.168.0.10
port=8080

project=xxxxx

session=xxxxxxxx

flutter=3.39.0

revision=xxxxxxxx
```

---

## 7. Preview App初回接続

起動

↓

QRコード読み込み

↓

Session取得

↓

WebSocket接続

↓

Project確認

↓

Flutter Revision確認

↓

Ready

---

## 8. 接続シーケンス

```text
Preview App

↓

Scan QR

↓

Connect

↓

Hello

{
  projectId
  flutterRevision
  dartVersion
  appVersion
  sessionId
}

↓

Preview Server

↓

Accept

↓

Ready
```

---

## 9. 更新シーケンス

Developer

↓

Save

↓

File Watch

↓

Incremental Compile

↓

Kernel生成

↓

DevFS

↓

reloadSources

↓

reassemble

↓

画面更新

---

## 10. Preview App更新判定

以下が変更された場合

* pubspec.lock
* Flutter SDK
* Native Plugin
* Android
* iOS

Preview CLIは自動検知する。

以下を表示する。

```
Preview App is outdated.

Run:

flutter preview rebuild
```

Hot Reloadは停止する。

---

## 11. SDK整合性

Preview App生成時に

* Flutter SDK
* Dart SDK
* Engine Revision

を固定する。

起動中のSDK比較は不要。

Preview App自体が対象SDKで生成されるためである。

---

## 12. ディレクトリ構成

```
.flutter_preview/

preview/

runtime/

cache/

generated/

server/

```

生成物

```
.flutter_preview/

preview_app/

android/

ios/

lib/

```

---

## 13. Preview Server

責務

* Incremental Compile
* DevFS管理
* VM Service制御
* WebSocket
* Session管理

---

## 14. Preview Runtime

責務

* WebSocket接続
* VM Service Proxy
* Preview情報送信
* Runtime制御

FlutterコードではなくNative側に常駐する。

Hot Restart後も接続を維持できる。

---

## 15. 通信

プロトコル

WebSocket

メッセージ

Server

* Reload
* Restart
* Ping
* Close

Client

* Hello
* Ready
* Log
* Progress
* Error

---

## 16. 再ビルド条件

以下のみPreview App再生成が必要。

* pubspec.lock変更
* Flutter SDK変更
* Native Plugin追加・削除
* AndroidManifest変更
* Info.plist変更
* Build.gradle変更
* Podfile変更

その他はHot Reloadで反映する。

---

## 17. Phase

### Phase1

* Android
* Debug
* WebSocket
* QRコード接続
* Hot Reload
* Project専用Preview App

### Phase2

* iOS
* Hot Restart
* Asset同期

### Phase3

* マルチデバイス
* VS Code拡張
* Android Studio Plugin
* LAN自動検出
* USB自動接続

---

## 18. OSS構成

```
packages/

preview_cli/

preview_builder/

preview_server/

preview_runtime/

preview_protocol/

preview_qrcode/

examples/
```

---

## 19. 設計方針

* Flutter EngineはForkしない
* flutter_toolsを可能な限り利用する
* Flutter SDKの変更を最小限にする
* Preview Appはプロジェクト毎に生成する
* CLI中心のUXとする
* QRコードのみで接続を完結させる
* Expo Development Clientと同様に「プロジェクト専用クライアント」を採用する
* Production OTAは対象外とし、開発体験の高速化に特化する
