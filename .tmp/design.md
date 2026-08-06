# 詳細設計書 - fluse (Flutter Preview Client)

対象: 要件定義書 `.tmp/requirements.md` v0.2 + 合意済み設計判断
検証環境: Flutter 3.41.9 / Dart 3.11.5 / engine rev `00b0c91f06209d9e4a41f71b7a512d6eb3b9c694`

---

## 0. 本設計書の前提（要件定義からの確定・変更点）

| 項目 | 要件書 | 本設計での確定 |
|---|---|---|
| CLI | `flutter preview` | **独立CLI `fluse`**（`dart pub global activate fluse_cli`）。`flutter` のサブコマンドは flutter_tools 内でハードコードされており外部拡張不可 |
| コンパイラ | flutter_tools を利用 | **`frontend_server_aot.dart.snapshot` を直接プロセス起動**。DevFS / VM Service は `package:vm_service` で自前実装。flutter_tools には依存しない |
| VM Service 接続 | VM Service Proxy | **生TCPトンネル（プロトコル非依存）**。Android の VM Service は端末 127.0.0.1 にバインドされるため必須 |
| Asset同期 | Phase2 | **Phase1 に移動**（DevFS が kernel と同一経路で扱うため実質同時に実装される） |
| パッケージ名 | `preview_*` | **`fluse_*`**（CLI名 / pub.dev 名前空間との整合） |
| `preview_qrcode` | 独立パッケージ | **`fluse_cli` に内包** |
| Preview App 生成 | 専用プロジェクトを生成 | **ユーザープロジェクトをそのまま debug ビルドし、エントリポイントのみ差し替える**（後述 2.2.2） |

---

## 1. アーキテクチャ概要

### 1.1 システム構成図

```text
┌──────────────────────── 開発PC ────────────────────────┐
│                                                        │
│  fluse_cli ── init / start / rebuild / doctor / devices│
│      │                                                 │
│      ├─ fluse_builder ─┐                               │
│      │    SDK解決       │  (init / rebuild 時のみ)      │
│      │    指紋計算       ├──► flutter build apk --debug │
│      │    keystore生成   │        │                     │
│      │    entrypoint生成 ┘        ▼                     │
│      │                        preview.apk               │
│      │                            │                     │
│      └─ fluse_server (start 時)   │                     │
│           ├ FileWatcher           │                     │
│           ├ CompilerService ──► frontend_server (子プロセス)
│           ├ AssetBundleService    │                     │
│           ├ DevFSClient  ─┐       │                     │
│           ├ VmServiceClient┤      │                     │
│           │      ▲         │      │                     │
│           │      │ TCP(localhost:任意)                  │
│           ├ TunnelEndpoint │      │                     │
│           ├ SessionManager │      │                     │
│           └ WsServer :8180 ┘      │                     │
└───────────────│───────────────────│─────────────────────┘
                │ WebSocket (LAN)   │ adb install / HTTP配信
                │  ├ text : 制御JSON│
                │  └ binary: TCPトンネル
┌───────────────▼───────────────────▼─────────────────────┐
│                   Android 実機                           │
│  ┌──── fluse_runtime (dev_dependency plugin) ────────┐  │
│  │  Kotlin側 (プロセス常駐 / Hot Restart耐性)          │  │
│  │    FluseInitProvider    自動初期化                  │  │
│  │    FluseConnectActivity QRスキャン / 手入力         │  │
│  │    FluseConnection      WebSocket + 認証 + 再接続   │  │
│  │    FluseTunnel          WS binary ⇄ 127.0.0.1:VMS  │  │
│  │    FluseErrorOverlay    コンパイルエラー表示         │  │
│  │  Dart側                                            │  │
│  │    flusePreviewMain()   Service.getInfo() → 通知    │  │
│  └────────────────────────────────────────────────────┘ │
│  ┌──── Flutter Engine (debug/JIT) ───────────────────┐  │
│  │  Dart VM Service  http+ws://127.0.0.1:<port>/<auth>│  │
│  │  ユーザーアプリ (kernel_blob.bin 同梱 → DevFSで更新)│  │
│  └────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────┘
```

### 1.2 技術スタック

| 領域 | 選定 |
|---|---|
| CLI / Server / Builder / Protocol | Dart 3.11+（Flutter非依存の純Dart） |
| Runtime (Android) | Kotlin 1.9+ / minSdk 21 / CameraX + ZXing core |
| Runtime (Dart側) | Flutter plugin（`dart:developer` の `Service.getInfo()`） |
| モノレポ管理 | melos |
| 主要ライブラリ | `package:vm_service` ^15.0.2 / `package:args` / `package:watcher` / `package:shelf` + `shelf_web_socket` / `package:qr` / `package:archive` (gzip) / `package:crypto` |
| ビルド | `flutter build apk --debug`（flutter_tools を CLI として呼ぶ。ライブラリ依存はしない） |
| テスト | `package:test` / `package:mockito`、Kotlin は JUnit + Robolectric |

---

## 2. コンポーネント設計

### 2.1 コンポーネント一覧

| パッケージ | 責務 | 依存 |
|---|---|---|
| `fluse_protocol` | メッセージ定義・JSON/バイナリ符号化・バージョンネゴシエーション | なし |
| `fluse_builder` | SDK解決 / プロジェクト解析 / 指紋計算 / entrypoint生成 / keystore管理 / ビルド / インストール | `fluse_protocol` |
| `fluse_server` | 増分コンパイル / DevFS / VM Service制御 / トンネル / WebSocket / セッション | `fluse_protocol`, `vm_service` |
| `fluse_cli` | コマンド解析 / QR描画 / コンソールUI / ライフサイクル統括 | 全部 |
| `fluse_runtime` | 端末側常駐クライアント（Kotlin）+ Dartエントリポイントラッパ | `fluse_protocol`(Dart側のみ) |

### 2.2 各コンポーネントの詳細

#### 2.2.1 `fluse_protocol`

- **目的**: サーバ／ランタイム間の唯一の契約。Dart と Kotlin の両方で同一のワイヤ表現を実装する。
- **公開インターフェース**:

```dart
/// 制御メッセージ（WebSocket text frame / JSON）
sealed class FluseMessage {
  String get type;
  Map<String, Object?> toJson();
  static FluseMessage fromJson(Map<String, Object?> json);
}

// Client -> Server
final class HelloMessage extends FluseMessage {      // type: 'hello'
  final int protocolVersion;
  final String projectId;
  final String flutterRevision;
  final String dartVersion;
  final String appVersion;      // init時に埋め込まれたビルドID
  final String deviceId;        // ANDROID_ID由来のハッシュ
  final String deviceName;
  final String? pairingToken;   // 初回ペアリング時のみ
  final String? deviceToken;    // ペアリング済みの場合
}
final class VmServiceReadyMessage extends FluseMessage { // type: 'vmServiceReady'
  final String vmServiceUri;    // http://127.0.0.1:PORT/AUTHCODE/
}
final class ReadyMessage extends FluseMessage {}      // type: 'ready'
final class LogMessage extends FluseMessage {         // type: 'log'
  final String level;           // debug|info|warn|error
  final String message;
}
final class ErrorMessage extends FluseMessage {       // type: 'error'
  final String code;
  final String message;
  final String? detail;
}

// Server -> Client
final class AcceptMessage extends FluseMessage {      // type: 'accept'
  final String sessionId;
  final String? issuedDeviceToken; // ペアリング成立時に発行
  final int heartbeatIntervalMs;
}
final class RejectMessage extends FluseMessage {      // type: 'reject'
  final String code;   // AUTH_FAILED | PROJECT_MISMATCH | REVISION_MISMATCH
                       // | PROTOCOL_MISMATCH | APP_OUTDATED
  final String message;
}
final class ReloadMessage extends FluseMessage {}     // type: 'reload' (進捗通知用)
final class CompileErrorMessage extends FluseMessage {// type: 'compileError'
  final String summary;
  final List<DiagnosticEntry> diagnostics;
}
final class CompileOkMessage extends FluseMessage {}  // type: 'compileOk' (オーバーレイ解除)
// 双方向（keepalive）
final class PingMessage extends FluseMessage {        // type: 'ping'
  final int seq;                // 対応する pong と突き合わせる
  final int timestampMs;        // 送信側の時刻（RTT 計測用）
}
final class PongMessage extends FluseMessage {        // type: 'pong'
  final int seq;                // 受信した ping の seq をそのまま返す
  final int timestampMs;        // ping の timestampMs をそのまま返す
}

// 双方向（正常終了の通知。異常終了は WebSocket の close フレームに委ねる）
final class CloseMessage extends FluseMessage {       // type: 'close'
  final String code;            // SHUTDOWN | SESSION_REPLACED | CLIENT_EXIT
  final String? message;
}
```

`ping` は `AcceptMessage.heartbeatIntervalMs` の間隔でサーバから送出し、端末は同じ
`seq` / `timestampMs` を載せた `pong` を返す。2回連続で応答が無ければ切断とみなす。

```dart
/// トンネルフレーム（WebSocket binary frame）
/// byte0      : opcode  0x01=open, 0x02=data, 0x03=close
/// byte1..4   : streamId (uint32 big-endian)
/// byte5..    : payload (data時のみ)
final class TunnelFrame {
  final TunnelOpcode opcode;
  final int streamId;
  final Uint8List payload;
  Uint8List encode();
  static TunnelFrame decode(Uint8List bytes);
}
```

- **内部実装方針**: Kotlin 側は同一仕様を手書き実装（コード生成はしない。メッセージ数が20未満で、生成器の保守コストが上回るため）。`protocolVersion` 不一致は `reject(PROTOCOL_MISMATCH)` で即切断する。

#### 2.2.2 `fluse_builder`

- **目的**: 「プロジェクト専用 Preview App」を作る。**新規プロジェクトを生成するのではなく、ユーザープロジェクト自体を debug ビルドし、エントリポイントだけ差し替える**。

  この方式を採る理由:
  1. Android設定（Manifest / build.gradle / Podfile）が定義上ズレない
  2. Native Plugin の解決が Flutter 標準のまま
  3. `flutter build apk --debug` がそのまま使えるため flutter_tools への依存が CLI 呼び出しだけで済む

- **公開インターフェース**:

```dart
class FlutterSdk {
  final String root;          // $FLUTTER_ROOT
  final String version;       // 3.41.9
  final String revision;      // 00b0c91f...
  final String dartVersion;   // 3.11.5
  String get dartAotRuntime;  // bin/cache/dart-sdk/bin/dartaotruntime
  String get frontendServerSnapshot;
      // bin/cache/artifacts/engine/<host>/frontend_server_aot.dart.snapshot
  String get patchedSdkRoot;
      // bin/cache/artifacts/engine/common/flutter_patched_sdk
  static Future<FlutterSdk> resolve({String? explicitRoot});
}

class ProjectAnalyzer {
  Future<ProjectInfo> analyze(Directory projectRoot);
}
class ProjectInfo {
  final String packageName;      // pubspec.yaml の name
  final String applicationId;    // build.gradle から抽出
  final String defaultTarget;    // lib/main.dart
  final List<PluginRef> plugins; // .flutter-plugins-dependencies より
  final Fingerprint fingerprint;
}

/// 再ビルド要否判定（要件16に対応）
class Fingerprint {
  final Map<String, String> entries; // 論理名 -> sha256
  bool isCompatibleWith(Fingerprint other);
  List<String> diff(Fingerprint other);   // 変更されたキーの一覧
  static Future<Fingerprint> compute(ProjectInfo p, FlutterSdk sdk);
}

class EntrypointGenerator {
  /// .flutter_preview/fluse_main.dart を生成
  Future<File> generate({required ProjectInfo project, required String userTarget});
}

class KeystoreManager {
  /// .flutter_preview/keystore/fluse-debug.keystore を生成（keytool 使用）
  Future<KeystoreInfo> ensure(Directory previewDir);
}

class PreviewAppBuilder {
  Future<BuildResult> build({
    required ProjectInfo project,
    required File entrypoint,
    required KeystoreInfo keystore,
    String? applicationIdSuffix,
  });
}

class DeviceInstaller {
  Future<List<AndroidDevice>> listDevices();          // adb devices -l
  Future<void> installViaAdb(AndroidDevice d, File apk);
  Uri serveOverHttp(File apk);                        // フォールバック導線
}
```

- **指紋の対象**（要件10 / 16）:

| 論理名 | 対象 |
|---|---|
| `flutter.revision` | `FlutterSdk.revision` |
| `pubspec.lock` | ファイル内容 |
| `pubspec.assets` | `pubspec.yaml` の `flutter:` セクション（assets / fonts 宣言のみ） |
| `plugins` | `.flutter-plugins-dependencies` の正規化JSON |
| `android.manifest` | `android/app/src/*/AndroidManifest.xml` 全て |
| `android.gradle` | `android/**/*.gradle`, `*.gradle.kts`, `gradle.properties`, `gradle-wrapper.properties` |
| `android.native` | `android/app/src/main/{java,kotlin,jni,res}/**` |
| `build.flags` | `frontend_server` に渡すフラグ集合（後述の整合性要件） |

`.flutter_preview/cache/fingerprint.json` に保存し、`fluse start` 起動時と File Watch 中に比較する。

- **エントリポイント生成物**:

```dart
// .flutter_preview/fluse_main.dart （自動生成 / 編集禁止）
import 'package:fluse_runtime/fluse_runtime.dart';
import 'package:<packageName>/main.dart' as app;   // userTarget から解決

Future<void> main() => flusePreviewMain(app.main);
```

ユーザーの `main()` は `Future<void> main() async` である場合があるため、
`flusePreviewMain` のシグネチャは以下とし、`appMain()` の完了を待ってから
VM Service URI を通知する。生成する `main()` も `Future<void>` を返し、
アプリ側の完了とエラーを呼び出し元へ伝播させる。

```dart
Future<void> flusePreviewMain(FutureOr<void> Function() appMain);
```

`userTarget` が `lib/` 配下なら `package:` URI に、外なら絶対 `file:` URI に解決する。
ビルドは `flutter build apk --debug --target=.flutter_preview/fluse_main.dart` で行う。

- **`fluse_runtime` の注入**: `fluse init` がユーザーの `pubspec.yaml` の `dev_dependencies` に `fluse_runtime` を追記する。
  Flutter 3.27+ は dev_dependency のプラグインを **debug には含め release では除外する**（`flutter_plugins.dart:1261` で検証済み）。したがって本番ビルドは一切汚染されない。追記は idempotent とし、既存の場合は何もしない。

#### 2.2.3 `fluse_server`

- **目的**: 増分コンパイルから画面反映までの全工程を担う。

**(a) CompilerService** — `frontend_server` の stdin プロトコルを駆動する。

```dart
class CompilerService {
  Future<void> start();     // プロセス起動
  Future<CompileOutput> compile(Uri mainUri);
  Future<CompileOutput> recompile(Uri mainUri, List<Uri> invalidated);
  void accept();            // reload成功時
  void reject();            // reload失敗時（次回 recompile が同じ差分を再送する）
  Future<void> shutdown();
}
class CompileOutput {
  final File? incrementalDill;   // 差分dill（DevFSへPUTする実体）
  final int errorCount;
  final List<DiagnosticEntry> diagnostics;
  final List<Uri> sources;
}
```

起動コマンド（実物検証済み）:

```text
<dartAotRuntime> <frontend_server_aot.dart.snapshot>
  --sdk-root <flutter_patched_sdk>/
  --incremental
  --target=flutter
  --experimental-emit-debug-metadata
  --output-dill .flutter_preview/cache/app.dill
  --packages .dart_tool/package_config.json
  --track-widget-creation
  --initialize-from-dill .flutter_preview/cache/app.dill
  --enable-asserts
  --verbosity=error
  [-D<key>=<value> ...]
```

> **`--filesystem-root` / `--filesystem-scheme` は渡さない**（Task 1.6 のスパイクで確定）。
> `flutter build apk --debug` はこの2つを渡しておらず、APK 内の kernel のライブラリ URI は
> `package:<name>/main.dart` 形式になる。増分コンパイル側だけ `org-dartlang-root:///` に
> すると URI が食い違い、差分が当たらない。**エントリポイントも `package:` URI で指定する。**

stdin/stdout プロトコル:
```text
compile <uri>\n
recompile <uri> <boundaryKey>\n<invalidated uri>\n...\n<boundaryKey>\n
accept\n
reject\n
```
stdout は `result <boundaryKey>` … `<boundaryKey> <outputPath> <errorCount>` で区切られる。

> **整合性要件（重要）**: `fluse init` 時の APK ビルドと `fluse start` の増分コンパイルは、`--track-widget-creation` / `-D` / `--enable-asserts` が**完全一致**していなければ `reloadSources` が失敗する。init が使ったフラグ集合を `.flutter_preview/cache/build_meta.json` に記録し、start はそれを読んで再現する。不一致は起動時にエラーとして検出する。

**(b) AssetBundleService** — `pubspec.yaml` の assets/fonts 宣言から asset マニフェストを構築し、変更されたファイルを列挙する。出力は DevFS 上の `build/flutter_assets/<archivePath>` に写像する。

**(c) DevFSClient** — flutter_tools の実装（`devfs.dart:280-360`）と同一プロトコル。

```dart
class DevFSClient {
  Future<Uri> create(String fsName);          // vm_service の createDevFS RPC
  Future<void> writeAll(Map<Uri, DevFSContent> entries); // 最大3並列のHTTP PUT
  Future<void> destroy();
}
```
PUT 仕様: VM Service の HTTP ルートへ `PUT`、ヘッダ `dev_fs_name: <fsName>` / `dev_fs_uri_b64: base64(utf8(deviceUri))`、ボディは gzip 圧縮、`Accept-Encoding` は削除、同時実行 3、失敗時は最大10回リトライ。

**(d) HotReloadOrchestrator** — 反映の1サイクル。

```text
接続直後に1度だけ（初回同期）
  ├ CompilerService.compile(mainUri)          … 完全な dill
  ├ DevFSClient.writeAll({完全なdill})
  ├ vmService.reloadSources(isolateId, rootLibUri: <DevFS上のdill>)
  ├ 変更assetを1つ以上 DevFS へ置く
  ├ _flutter.listViews → 各Viewへ _flutter.setAssetBundlePath(<DevFS>/build/flutter_assets/)
  └ ext.flutter.reassemble(isolateId)

以降、FileWatcher が変更検知するたびに
  └ debounce 50ms / 指紋変更なら中断してrebuild要求
      ├ CompilerService.recompile(invalidated)
      │    ├ errorCount > 0 → compileError を CLI と App の両方へ → 終了(rejectはしない)
      │    └ ok
      ├ DevFSClient.writeAll({差分dill, 変更asset})
      ├ vmService.reloadSources(isolateId, rootLibUri: <DevFS上のdill>)
      │    ├ success:false → CompilerService.reject() → notices を表示し中断
      │    └ success:true  → CompilerService.accept()
      ├ 変更assetごとに ext.flutter.evict(<archivePath>)
      └ ext.flutter.reassemble(isolateId)
```

> **初回同期を飛ばしてはいけない**（Task 1.6 のスパイクで確定）。端末で動いているのは
> APK 同梱の `kernel_blob.bin` であり、`frontend_server` セッションの「直前の状態」とは
> 無関係。いきなり差分を送ると `reloadSources` が
> `Error while starting Kernel isolate task` で拒否する。

> **`rootLibUri` は DevFS 上に置いた dill の絶対 URI**。エントリポイントの URI ではない。
> DevFS 上のファイル名は `main.dart.incremental.dill`（`lib/` は付かない）。

> **asset の反映には `_flutter.setAssetBundlePath` が必要**（Task 1.6 のスパイクで確定）。
> 端末のエンジンは既定で APK 内の `flutter_assets` しか見ないため、DevFS へ置いても
> 参照されない。`evict` だけでは Dart は反映されるのに画像だけ古いまま、という
> 分かりにくい状態になる。**ディレクトリの実体が無いと失敗する**ので、
> 先に asset を1つ書き込んでから呼ぶこと。

**(e) TunnelEndpoint** — サーバ側のトンネル終端。

```dart
class TunnelEndpoint {
  /// localhost に TCP リッスンを立て、接続をWSトンネル経由で端末VM Serviceへ中継する。
  /// 返る Uri は http://127.0.0.1:<localPort>/<authCode>/ で、
  /// VmService / DevFSClient はこれを本物のVM Serviceとして扱える。
  Future<Uri> bind(String remoteVmServiceUri);
  Future<void> close();
}
```

端末の VM Service は `127.0.0.1` にしかバインドされないため、LAN から直接到達できない。プロトコルを解釈しない生 TCP 中継にすることで、JSON-RPC over WebSocket と DevFS の HTTP PUT を**単一の実装**で通す。

**(f) SessionManager / 認証**

```dart
class SessionManager {
  PairingToken issuePairingToken();       // start毎に新規・TTL 10分・1回限り
  Future<AuthResult> authenticate(HelloMessage hello);
  DeviceToken issueDeviceToken(String deviceId);  // 永続・.flutter_preview/devices.json
  Future<void> revoke(String deviceId);
}
```

- `pairingToken`: 32バイト乱数（`Random.secure()`）を base64url 化。
  **公開経路は QR / コンソール表示 / HTTP `/` の3つ**（QR を読めない端末のための手入力導線を
  要件として持つため。§2.2.5 の `FluseConnectActivity` と Task 5.9 を参照）。
  ただし以下を制約とする。
  - **ログファイルには絶対に出力しない**（§6.1 の `redact()` 対象）。コンソールは
    `fluse start` の対話表示のみで、`.flutter_preview/logs/` には残さない。
  - HTTP `/` は LAN 上の誰でも到達できるため、`start` のセッション中のみ有効な値を返し、
    セッション終了時に失効させる。
  - ペアリング成立後は即座に失効させ、以後は `deviceToken` に切り替える（単回利用）。
- `deviceToken`: ペアリング成立時にサーバが発行し、端末は EncryptedSharedPreferences に保存。以後は QR 再スキャン不要。
- 検証は定数時間比較を用いる。

#### 2.2.4 `fluse_cli`

```text
fluse init      [--flutter-sdk <path>] [--application-id-suffix <s>] [--target <path>] [--device <id>]
fluse start     [--port <n>] [--host <ip>] [--target <path>] [-d <deviceId>]
fluse rebuild   [--force]
fluse doctor
fluse devices
```

`start` のコンソール表示:
```text
fluse 0.1.0  •  Flutter 3.41.9 (00b0c91f)

  QRコードをPreview Appでスキャンしてください

  ██████████████  ...

  http://192.168.0.10:8180
  端末が見つからない場合は  fluse start --host <IP>

  [1台接続] Pixel 8 (android-arm64)
  r: 手動リロード  q: 終了
```

#### 2.2.5 `fluse_runtime`

**Dart側**:
```dart
/// 生成されたエントリポイントから呼ばれる唯一の公開API
void flusePreviewMain(void Function() appMain) {
  appMain();                       // ユーザーアプリを先に起動（初回フレームを遅延させない）
  scheduleMicrotask(_reportVmService);
}

Future<void> _reportVmService() async {
  WidgetsFlutterBinding.ensureInitialized();
  final ServiceProtocolInfo info = await Service.getInfo();
  final Uri? uri = info.serverUri;
  if (uri == null) return;         // release等でVM Service無効
  await const MethodChannel('dev.fluse/runtime')
      .invokeMethod<void>('vmServiceReady', uri.toString());
}
```
`appMain()` を先に呼ぶのは、ユーザーアプリの binding 初期化順序に干渉しないため。Hot Restart のたびに再実行されるが、Native 側で同一 URI は冪等に処理する。

**Kotlin側**:

| クラス | 責務 |
|---|---|
| `FluseInitProvider : ContentProvider` | 自動初期化。`ActivityLifecycleCallbacks` を登録するだけ（ユーザーのManifest変更不要） |
| `FluseConnectActivity` | QRスキャン（CameraX + ZXing）／ホスト・トークン手入力フォールバック |
| `FluseConnection` | Applicationスコープの単一インスタンス。WebSocket接続・`hello`/`accept`・指数バックオフ再接続・heartbeat。**Hot Restart で破棄されない** |
| `FluseTunnel` | binary frame ⇄ `Socket("127.0.0.1", vmServicePort)`。streamIdごとにコルーチンで双方向コピー |
| `FluseErrorOverlay` | `compileError` 受信時に `WindowManager` 経由で赤画面を重畳。Dart isolate の状態に依存しない |
| `FluseBadge` | 画面隅の小バッジ。接続状態表示＋タップで `FluseConnectActivity` 再表示 |
| `FluseStore` | EncryptedSharedPreferences（deviceToken / lastHost / lastPort） |

**起動シーケンス**:
```text
FluseInitProvider.onCreate
  └ ActivityLifecycleCallbacks 登録
      └ 最初の Activity onResume
          ├ FluseStore に deviceToken あり
          │   └ lastHost:lastPort へ接続 → hello(deviceToken)
          │       └ 失敗 → FluseConnectActivity 起動
          └ なし → FluseConnectActivity 起動 → QR → hello(pairingToken)
                    → accept(issuedDeviceToken) → 保存
（並行して）
Dart main → flusePreviewMain → Service.getInfo() → MethodChannel
  └ FluseConnection.send(vmServiceReady)
```

---

## 3. データフロー

### 3.1 初回接続（要件7・8に対応）

```text
App                          Server
 │                             │
 │──ws connect────────────────►│
 │──hello{proto,projectId,     │
 │        flutterRevision,     │
 │        appVersion,          │  検証:
 │        deviceId, token}────►│   protocolVersion
 │                             │   projectId 一致
 │                             │   flutterRevision 一致
 │                             │   appVersion == 現指紋
 │◄─accept{sessionId,          │   token
 │         issuedDeviceToken}──│
 │──vmServiceReady{uri}───────►│
 │                             ├─ TunnelEndpoint.bind()
 │◄═══tunnel(binary)══════════►├─ VmService.connect(localUri)
 │                             ├─ createDevFS('fluse')
 │                             ├─ 初回 compile + writeAll
 │                             ├─ reloadSources + reassemble
 │◄─ready──────────────────────│
```

### 3.2 更新シーケンス（要件9に対応）

```text
保存
 └ FileWatcher (debounce 50ms)
     ├ 指紋対象ファイル？ ──Yes──► APP_OUTDATED を表示し Watch 停止
     └ No
        └ recompile → 差分dill
            └ DevFS PUT (gzip, 並列3)
                └ reloadSources(rootLibUri)
                    ├ success ─► accept → evict(assets) → reassemble → 画面更新
                    └ failure ─► reject → notices表示
```

### 3.3 データ変換

| 段階 | 入力 | 出力 |
|---|---|---|
| コンパイル | 変更 `.dart` の URI 集合 | 差分 kernel（`.incremental.dill`） |
| Asset収集 | `pubspec.yaml` assets宣言 + ファイル mtime/hash | `Map<archivePath, bytes>` |
| DevFS転送 | 上記 | gzip ストリーム + `dev_fs_uri_b64` ヘッダ |
| リロード | DevFS上の `fluse_main.dart` URI | `ReloadReport{success, notices}` |

---

## 4. APIインターフェース

### 4.1 内部API

`fluse_cli` が統括する起動フロー:

```dart
abstract interface class FluseCommand {
  String get name;
  Future<int> run(ArgResults args, FluseContext ctx);
}

class FluseContext {
  final Directory projectRoot;
  final Directory previewDir;      // .flutter_preview/
  final FluseConfig config;        // fluse.yaml
  final FlutterSdk sdk;
  final Logger logger;
}
```

### 4.2 外部API

**(a) QR ペイロード**

```text
fluse://connect?v=1&h=192.168.0.10&p=8180&pid=<projectId>&t=<pairingToken>&rev=00b0c91f
```

| キー | 内容 |
|---|---|
| `v` | プロトコルバージョン |
| `h` / `p` | サーバのLAN IP / ポート |
| `pid` | projectId（`pubspec.yaml` name + プロジェクト絶対パスの sha256 先頭16桁） |
| `t` | pairingToken（base64url, 32バイト） |
| `rev` | Flutter revision 先頭8桁（不一致を早期検出するため） |

**(b) HTTPエンドポイント**（`fluse_server`）

| メソッド | パス | 用途 |
|---|---|---|
| `GET` | `/` | インストール案内HTML（APKリンク + 手入力用トークン表示） |
| `GET` | `/apk?t=<pairingToken>` | `preview.apk` を `application/vnd.android.package-archive` で配信。**`t` が現行 `pairingToken` と一致しない場合は 404** |
| `GET` | `/ws` | WebSocket アップグレード |
| `GET` | `/health` | 疎通確認（`doctor` 用） |

**(c) 外部プロセス呼び出し**

| コマンド | 用途 |
|---|---|
| `flutter build apk --debug --target=...` | Preview App ビルド |
| `flutter pub get` | `fluse_runtime` 追記後の解決 |
| `adb devices -l` / `adb install -r` / `adb uninstall` | 端末操作 |
| `keytool -genkeypair` | 専用keystore生成 |
| `<dartaotruntime> frontend_server_aot.dart.snapshot` | 増分コンパイル |

---

## 5. エラーハンドリング

### 5.1 エラー分類

| 分類 | 検出 | 対処 |
|---|---|---|
| `SDK_NOT_FOUND` | `flutter` が PATH にない / `--flutter-sdk` 不正 | `doctor` へ誘導して終了 |
| `PROJECT_NOT_FLUTTER` | `pubspec.yaml` に `flutter:` がない | 終了 |
| `NO_DEVICE` | `adb devices` が空 | APK配信URL + 2枚目のQRを表示して継続 |
| `INSTALL_SIGNATURE_CONFLICT` | `adb install` が `INSTALL_FAILED_UPDATE_INCOMPATIBLE` | **専用対話**（後述 5.3） |
| `PROTOCOL_MISMATCH` | `hello` の `protocolVersion` 不一致 | `reject` → App側に「fluseを更新してください」 |
| `PROJECT_MISMATCH` | `projectId` 不一致 | `reject` → 「別プロジェクトのPreview Appです」 |
| `REVISION_MISMATCH` | `flutterRevision` 不一致 | `reject` → `fluse rebuild` を案内 |
| `APP_OUTDATED` | 指紋差分を検出 | Watch停止 + `fluse rebuild` を案内（要件10） |
| `COMPILE_ERROR` | `errorCount > 0` | **CLIコンソールとApp画面の両方**に表示。Watchは継続 |
| `RELOAD_REJECTED` | `ReloadReport.success == false` | `reject()` して notices を表示。次回保存で再試行 |
| `TUNNEL_LOST` | TCP/WS切断 | 指数バックオフ再接続（1s→2s→4s→最大30s）。VM Service再取得を待つ |
| `AUTH_FAILED` | トークン不一致 / TTL切れ | `reject` → App は再スキャン画面へ |

### 5.2 エラー通知

- **CLIコンソール**: 単一行サマリ + 折りたたみ詳細。コンパイルエラーは `file:line:col` 形式（クリック可能）。
- **App画面**: `compileError` を Native の `FluseErrorOverlay` が受け、`WindowManager` の TYPE_APPLICATION_OVERLAY 相当のビューで赤画面表示。**Dart側に依存しない**ため、Dart が起動不能な状態でも表示できる。`compileOk` で自動解除。
- **ログ**: `.flutter_preview/logs/fluse-<timestamp>.log` に全イベントを JSON Lines で保存。`--verbose` でコンソールにも出す。

### 5.3 署名衝突の専用フロー（設計判断で合意した副作用への対処）

デフォルト `applicationId` は本番と同一、署名は fluse 専用 keystore のため、通常の `flutter run` でインストール済みの debug アプリと衝突する。

```text
✗ インストールに失敗しました (INSTALL_FAILED_UPDATE_INCOMPATIBLE)

  端末に同じ applicationId (com.example.myapp) のアプリが
  別の署名でインストールされています。

  どうしますか？
    1) 既存アプリをアンインストールして続行  (adb uninstall com.example.myapp)
    2) Preview App を別IDでインストール      (--application-id-suffix .preview)
    3) 中止
```
選択2は `fluse.yaml` に `applicationIdSuffix` を永続化し、以後の `rebuild` にも適用する。**黙って上書きはしない。**

---

## 6. セキュリティ設計

### 6.1 認証・認可

**脅威モデル**: 主リスクは「LAN上の第三者が Preview Server に接続し、プロジェクトのDartソースを DevFS 経由で受け取る（ソース漏洩）」。副次的に「悪意あるサーバのQRを読ませて任意Dartコードを流し込む」。

**対策**:

| 層 | 対策 |
|---|---|
| ペアリング | `pairingToken`(32バイト乱数, TTL 10分, 1回限り)。QR / コンソール / HTTP `/` に平文表示（手入力導線用。§2.2.3 の制約を参照） |
| 再接続 | サーバ発行の `deviceToken` を端末の EncryptedSharedPreferences に保存。`.flutter_preview/devices.json` と突合 |
| バインド | WebSocket/HTTP は既定でプライベートIPにのみバインド。`--host 0.0.0.0` は明示指定時のみ、かつ警告を出す |
| トンネル | 認証済みセッションのみが `vmServiceReady` を送れる。未認証接続からのトンネルフレームは即切断 |
| 比較 | トークン比較は定数時間 |
| ログ | トークンは常にマスク（先頭4文字 + `***`） |

**Phase1で受け入れるリスク（明示・意図的な設計判断）**:

通信は平文 WebSocket であり、TLS もサーバ認証も持たない（§0 / §10-10）。したがって以下を受け入れる。

- LAN上の**受動的盗聴者はソースを閲覧できる**。
- `hello` で送る `pairingToken` / `deviceToken` も**平文で流れるため盗聴・再利用されうる**。
  `deviceToken` は永続トークンであり、盗まれれば以後のセッションにも接続できる。
- 能動的な攻撃者は**中間者としてトンネルを乗っ取り、任意の Dart コードを流し込める**。

この受容は「開発用途・信頼できるLAN・開発者本人の端末のみ」という前提に立つ。前提を守るための
緩和策として、**既定でプライベートIPにのみバインドし**、`--host 0.0.0.0` は明示指定かつ警告付き
とする。前提が成り立たない環境（カフェ / 共用オフィス / ゲストWi-Fi）での利用は非推奨であり、
README（Task 7.1）に明記する。

TLS とサーバ認証の導入は Phase3。Phase3 まで `deviceToken` の永続化をやめるべきかは
別途判断する（やめると毎回QRスキャンが必要になり、本ツールの価値を大きく損なうため、
現時点では利便性を優先する）。

### 6.2 データ保護

- `.flutter_preview/` 全体を `fluse init` が `.gitignore` に追記する（`secret` / `devices.json` / `keystore/` を含むため必須）。
- keystore のパスワードは `.flutter_preview/keystore/keystore.json` に保存（600 パーミッション）。debug 専用であり、配布物の署名には使わない。
- APK には Dart ソース（kernel_blob.bin）が含まれるため、HTTP 配信は `/apk?t=<pairingToken>` として現行トークンとの一致を要求し、不一致は 404 を返す。トークンは案内ページ `/` が生成するリンクに埋め込むため、利用者が手で入力する必要はない。これは「インストール前の**アプリ**はトークンを持てない」が「案内ページを開く**ブラウザ**は持てる」ことを利用している。
  - ただし `/` 自体は認証されないため、これは総当たり／ポートスキャン程度の相手を弾く措置にすぎない。実効的な境界はプライベートIPへのバインドであり、§6.1 の受容リスクは変わらない。
  - `serveApk: false`（`--no-serve-apk`）で配信そのものを無効化できる。既定は `true`（adb 不在時の唯一のインストール導線であるため）。

---

## 7. テスト戦略

### 7.1 単体テスト

| 対象 | 方針 | カバレッジ目標 |
|---|---|---|
| `fluse_protocol` | 全メッセージの round-trip、不正JSON、バージョン不一致、TunnelFrame の境界値（0バイトpayload / 最大streamId） | 95% |
| `fluse_builder` | `Fingerprint` の差分検出（各キーを1つずつ変えたテーブルテスト）、`EntrypointGenerator` の URI 解決（lib配下 / lib外 / ネスト） | 90% |
| `fluse_server` | `CompilerService` の stdout パーサ（boundaryKey分割、エラー混在）、`DevFSClient` のヘッダ生成・リトライ、`SessionManager` の TTL / 定数時間比較 | 85% |
| `fluse_cli` | 引数解析、QRペイロード生成 | 80% |
| Kotlin | `FluseTunnel` のフレーム分割・再結合、`FluseConnection` のバックオフ | 80% |

外部プロセス（`flutter` / `adb` / `keytool` / `frontend_server`）は `ProcessManager` 抽象越しにモックする。

### 7.2 統合テスト

| レベル | 内容 |
|---|---|
| L1: トンネル | ローカルにダミーTCPエコーサーバを立て、`TunnelEndpoint` ⇄ `FluseTunnel`(JVM) 間で 10MB を双方向転送し完全一致を確認 |
| L2: コンパイル | 実 `frontend_server` に対して最小Flutterプロジェクトを compile → recompile し、差分dillが生成されエラー数が期待通りか確認 |
| L3: 疑似端末 | Dart で「VM Service を持つ Flutter アプリ」の代わりに `flutter test --machine` ではなく、**ホスト上で `flutter run -d <desktop>` した実プロセス**に対して DevFS + reloadSources を実行し、reassemble まで通ることを確認（Androidを介さず反映経路だけを検証） |
| L4: E2E | Android実機に対して `init` → `start` → ファイル変更 → 画面反映 まで。CIでは実行せず手動シナリオとして `docs/e2e-checklist.md` に記載 |

---

## 8. パフォーマンス最適化

### 8.1 想定される負荷

| 指標 | 目標 |
|---|---|
| 1ファイル変更 → 画面反映（LAN, 中規模アプリ） | **< 1.0秒** |
| うち増分コンパイル | < 400ms |
| うち DevFS 転送（差分dill 50–500KB） | < 200ms |
| うち reloadSources + reassemble | < 300ms |
| `fluse init`（初回、キャッシュなし） | 2–5分（Gradleビルド律速） |
| トンネル実効スループット | > 10MB/s（Wi-Fi 5想定） |

### 8.2 最適化方針

1. **`--initialize-from-dill`** を必ず指定し、`start` の初回コンパイルを増分にする。
2. **`accept`/`reject` の厳密運用**: reload 失敗時に `accept` すると frontend_server の状態が実機とズレて以降の全リロードが壊れる。必ず `reject` する。
3. **debounce 50ms**: 保存時の複数イベント（エディタの atomic write は create/delete/modify を連発する）を1回に畳む。
4. **DevFS 並列3固定**: flutter_tools と同値。Dart の PUT 応答バグ（dart-lang/sdk#43525）回避のため 60秒タイムアウト + 最大10回リトライを踏襲。
5. **トンネルのバックプレッシャ**: WebSocket 送信キューが閾値（4MB）を超えたら TCP 読み取りを一時停止し、メモリ膨張を防ぐ。
6. **Asset は差分のみ**: `archivePath -> (size, mtime, sha256)` をキャッシュし、変更分だけ PUT + `evict`。
7. **指紋計算のコスト**: `android.native` は再帰走査になるためファイルパス+mtime+size の合成ハッシュを一次判定に使い、一致時は内容ハッシュを省略する。

---

## 9. デプロイメント

### 9.1 配布構成

| 成果物 | 配布方法 |
|---|---|
| `fluse_cli` | pub.dev。`dart pub global activate fluse_cli` → 実行ファイル名 `fluse` |
| `fluse_server` / `fluse_builder` / `fluse_protocol` | pub.dev（`fluse_cli` の依存） |
| `fluse_runtime` | pub.dev（ユーザープロジェクトの `dev_dependencies`） |

melos でバージョンを一括管理し、`fluse_cli` と `fluse_runtime` の `protocolVersion` を CI で突合する。

### 9.2 設定管理

**`fluse.yaml`（プロジェクトルート / コミット対象）**
```yaml
version: 1
port: 8180
target: lib/main.dart
applicationIdSuffix: null      # 署名衝突時に .preview 等が入る
dartDefines: []
serveApk: true
```

**`.flutter_preview/`（全て gitignore）**
```text
.flutter_preview/
  secret                    # projectSecret (600)
  devices.json              # ペアリング済み端末
  keystore/
    fluse-debug.keystore
    keystore.json           # パスワード (600)
  cache/
    fingerprint.json        # 再ビルド判定
    build_meta.json         # init時のfrontend_serverフラグ
    app.dill                # --initialize-from-dill シード
    assets.json             # asset差分キャッシュ
  build/
    preview.apk
  fluse_main.dart           # 生成エントリポイント
  logs/
    fluse-<timestamp>.log
```

環境変数: `FLUSE_FLUTTER_SDK` / `FLUSE_PORT` / `FLUSE_LOG_LEVEL`。優先順位は CLI引数 > 環境変数 > `fluse.yaml` > 既定値。

---

## 10. 実装上の注意事項

1. **ビルドフラグの整合性が最重要**。`fluse init` の APK ビルドと `fluse start` の `frontend_server` 引数（特に `--track-widget-creation`、`-D`、`--enable-asserts`）が1つでも違うと `reloadSources` が静かに失敗する。`build_meta.json` による突合を最初に実装し、不一致を起動時エラーにすること。

2. **`accept`/`reject` を絶対に取り違えない**。reload 失敗時に `accept` すると frontend_server が「送信済み」と誤認し、以降そのファイルの差分が二度と送られなくなる。デバッグが極めて困難な不具合になる。

3. **VM Service はプロトコルを解釈せず素通しする**。JSON-RPC over WebSocket と DevFS の HTTP PUT が同一ポートに来るため、片方だけ対応した「賢い」プロキシを書くと必ず破綻する。生TCP中継を維持すること。

4. **`android:usesCleartextTraffic`**: `ws://` は API 28+ で既定拒否される。`fluse_runtime` の Android ライブラリの `src/debug/AndroidManifest.xml` で `tools:replace="android:usesCleartextTraffic"` を用いて有効化する。dev_dependency のため release ビルドには一切影響しないが、**ユーザーアプリが独自の `networkSecurityConfig` を持つ場合に debug ビルドでマージ競合が起きうる**。この競合は検出して明示的なエラーメッセージを出すこと。

5. **`flusePreviewMain` はユーザーの `main()` を先に呼ぶ**。先に `WidgetsFlutterBinding.ensureInitialized()` を呼ぶと、独自 binding や `runZonedGuarded` を使うアプリの初期化順序を壊す。

6. **Hot Restart 耐性**: ここでいう耐性とは、**IDE や `flutter attach` などユーザー側の操作で Hot Restart が起きても接続が壊れないこと**を指す（fluse 自身が Hot Restart をトリガする機能は Phase1 では提供しない。項目10を参照）。`FluseConnection` は Activity ではなく Application スコープに置く。Hot Restart は Dart isolate のみを作り直すので Android プロセスは生きており、接続は維持される。ただし `vmServiceReady` は再送されるため、Native 側は同一URIを冪等に扱うこと。

7. **`.flutter_preview/` の gitignore 追記は init で必ず行う**。`secret` と `keystore/` が漏れる。追記は idempotent に。

8. **`pubspec.yaml` への追記は最小限**。`dev_dependencies` に `fluse_runtime` の1行のみ。フォーマットやコメントを破壊しないよう、YAML 全体を再シリアライズせず**行単位で挿入**する（`package:yaml_edit` を使う）。

9. **`projectId` は絶対パスを含める**。同一 `name` のプロジェクトが複数ある環境（テンプレートから作った複数アプリ）で誤接続を防ぐ。

10. **Phase1 のスコープ外を明示的に落とす**: iOS、**Hot Restart の能動的トリガ**（`fluse` からの再起動指示 / `R` キー相当の UI）、マルチデバイス同時接続、TLS。`fluse start` に2台目が接続してきたら `reject(TOO_MANY_DEVICES)` を返し、曖昧な半対応を作らない。なお**ユーザー起因の Hot Restart に対する接続維持は Phase1 のスコープ内**であり（項目6）、Task 6.3 の E2E で検証する。

11. **`flutter build apk --debug` は flutter_tools を CLI として呼ぶだけに留める**。`packages/flutter_tools` への path dependency は SDK バージョン追従が破綻するため禁止（設計方針として厳守）。

---

## 11. 要件トレーサビリティ

| 要件 | 対応セクション |
|---|---|
| 4. Preview App の構成 | 2.2.2（プロジェクト自体をビルド）/ 2.2.5 |
| 5. CLI サブコマンド | 2.2.4 |
| 6. QRコード | 4.2(a) / 2.2.4 |
| 7–8. 初回接続・接続シーケンス | 3.1 / 2.2.3(f) |
| 9. 更新シーケンス | 3.2 / 2.2.3(d) |
| 10. 更新判定 | 2.2.2 指紋 / 5.1 `APP_OUTDATED` |
| 11. SDK整合性 | 2.2.2 / 10-1（ビルドフラグ整合性まで拡張） |
| 12. ディレクトリ構成 | 9.2（要件書から再設計） |
| 13. Preview Server 責務 | 2.2.3 |
| 14. Preview Runtime 責務 | 2.2.5 |
| 15. 通信メッセージ | 2.2.1 |
| 16. 再ビルド条件 | 2.2.2 指紋テーブル |
| 17. Phase1 | 10-10（Asset同期のみ Phase1 へ前倒し） |
| 18. OSS構成 | 2.1（`fluse_*` に改名、`preview_qrcode` 廃止） |
| 19. 設計方針 | 10-11（flutter_tools 非依存を厳守）/ 全体 |
