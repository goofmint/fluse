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

`protocolVersion` は Dart 定数・Kotlin 定数・ゴールデンの 3 箇所にある。
突合はリポジトリ直下の `tool/check_protocol_version.dart` に集約した。
正規表現と JSON だけで読むので、Gradle も Dart のテスト環境も要らない。
CI（`.github/workflows/ci.yml`）ではこれを最初のジョブに置いている。

```console
$ melos run check:protocol-version
protocolVersion = 1（3 箇所すべて一致）
```

**パッケージのテストから隣のパッケージを読むことはしない。** Task 4.1 で
Kotlin のソースが `fluse_runtime` へ移ると相対パスが壊れるうえ、
`fluse_protocol` 単体を取り出した環境でテストが落ちる。突合の置き場所は
この 1 箇所だけにする。

## テスト

```console
$ cd packages/fluse_protocol_kt
$ ./gradlew test        # または gradle test
BUILD SUCCESSFUL in 3s
```

リポジトリのルートからは melos 経由でも実行できる。

```console
$ melos run test:kotlin
BUILD SUCCESSFUL in 3s
```

**JDK 17 が必要**（Gradle 8.x は JDK 26 では動かない）。
