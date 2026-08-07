# fluse_protocol_kt

`fluse_protocol`（Dart）と**同一のワイヤ表現**を話す Kotlin 実装。

## なぜ独立したモジュールなのか

最終的な置き場所は `fluse_runtime` の Android 側（設計 §2.1）だが、
**Task 2.3 は Task 4.1（プラグイン雛形の作成）より前に来る**ため、
まだ置き場所が存在しない。単体で JVM 上の JUnit を回せるよう、
一時的に独立したモジュールにしてある。

Task 4.1 で `packages/fluse_runtime/android/src/main/kotlin/` へ移す。
パッケージ名 `dev.fluse.protocol` はそのまま使える。

## ワイヤ表現の一致をどう担保しているか

Dart と Kotlin が **同じファイル**を読む。

```
packages/fluse_protocol/test/fixtures/wire_golden.json
```

- Dart 側: `packages/fluse_protocol/test/wire_golden_test.dart`
- Kotlin 側: `src/test/kotlin/dev/fluse/protocol/WireGoldenTest.kt`

片方だけ変更すると、もう片方のテストが落ちる。

`protocolVersion` の突合だけは Gradle を持たない環境でも回るよう、
Dart 側のテストが Kotlin のソースを読んで比較する。

さらにテスト環境の準備すら要らない突合として
`tool/check_protocol_version.dart` がある。Dart 定数・Kotlin 定数・
ゴールデンの 3 箇所を正規表現と JSON だけで読み、食い違えば落ちる。
CI（`.github/workflows/ci.yml`）ではこれを最初のジョブに置いている。

```console
$ melos run check:protocol-version
```

## テスト

```console
$ cd packages/fluse_protocol_kt
$ ./gradlew test        # または gradle test
```

リポジトリのルートからは melos 経由でも実行できる。

```console
$ melos run test:kotlin
```

**JDK 17 が必要**（Gradle 8.x は JDK 26 では動かない）。
