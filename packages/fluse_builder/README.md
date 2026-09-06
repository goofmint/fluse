# fluse_builder

Flutter SDK 解決・プロジェクト解析・指紋計算・エントリポイント生成・keystore
管理・APK ビルドと端末インストールを担う。

使い方はリポジトリ直下の [README](../../README.md) にある。

## 位置づけ

**`fluse_server` を知らない**（設計 §2.1）。依存は `fluse_protocol` まで。
両方を使うのは `fluse_cli` の役目。

`flutter_tools` もライブラリとしては使わない（設計 §10-11）。あれは pub の
パッケージとして公開されておらず、SDK に同梱された実装に依存すると版ごとに
壊れる。必要なものは自分で解決する。

## 中身

| ファイル | 何を持つか |
|---|---|
| `flutter_sdk.dart` | SDK の解決。`--flutter-sdk` > 環境変数 > PATH |
| `project_analyzer.dart` | `pubspec.yaml` / Gradle / マニフェストを読む |
| `fingerprint.dart` | 作り直しが要る変更を8つのキーで表す |
| `entrypoint_generator.dart` | `.flutter_preview/fluse_main.dart` を作る |
| `keystore_manager.dart` | debug 用の署名鍵。**利用者の鍵には触らない** |
| `preview_app_builder.dart` | `flutter build apk --debug` |
| `device_installer.dart` | `adb install`。署名衝突時の3択 |
| `project_identity.dart` | `projectId` と `appVersion` |
| `pub_get_runner.dart` | `flutter pub get` |

## 指紋に入るもの

Dart のソースは**入らない**。あれは hot reload が運ぶ。入るのは作り直さないと
反映できないものだけ。

```text
flutter.revision / pubspec.lock / pubspec.assets / plugins
android.manifest / android.gradle / android.native / build.flags
```

## テスト

```console
$ cd packages/fluse_builder
$ dart test
```

## 公開

`publish_to: none`。pub.dev への公開は Task 7.3。
