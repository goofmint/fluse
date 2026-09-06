# CHANGELOG

## 0.1.0

初回。Phase1 のビルド基盤一式。

- `FlutterSdk` — SDK の解決と成果物の実在確認。半端に解決した SDK は返さない
- `ProjectAnalyzer` — `pubspec.yaml` / Gradle / マニフェストからプロジェクト情報
- `Fingerprint` — 作り直しが要る変更を8つのキーで表す。Dart のソースは含めない
- `EntrypointGenerator` — `.flutter_preview/fluse_main.dart` の生成と
  `.gitignore` への追記
- `KeystoreManager` — debug 用 keystore の作成。パスワードは 600 で置く
- `PreviewAppBuilder` — `flutter build apk --debug`。ビルドフラグを
  `build_meta.json` に残す。署名のプロパティはログから伏せる
- `DeviceInstaller` — `adb devices` / `adb install`、署名衝突時の3択
- `ProjectIdentity` — `projectId`（パッケージ名 + 絶対パス）と `appVersion`
- `PubGetRunner` — `flutter pub get`
- `ApkServer` — APK の HTTP 配信（現状は未配線）
