// fluse_protocol の Kotlin 実装を JVM 上で検証するためのモジュール。
//
// **ワイヤ実装の本体はここには無い。** Task 4.3 で
// `packages/fluse_runtime/android/src/main/kotlin/` へ移した。プラグインは
// pub.dev へ公開する単位であり、自分のディレクトリの外を参照したままでは
// 配布物が成立しないため。
//
// ここに残るのは L1統合テストのハーネス（`l1harness`）と、JVM でしか
// 回せない検証（ゴールデン突合）だけ。本体は下の srcDir で借りる。
plugins {
    kotlin("jvm") version "2.1.0"

    // L1統合テスト（Task 2.5）のハーネスを独立プロセスとして起動するために入れる。
    // Dart 側テストが `installDist` の生成物
    // （build/install/fluse_protocol_kt/bin/fluse_protocol_kt）を直接叩く。
    // **ライブラリとしての用途は変わらない。** 本番の端末側 WebSocket は
    // FluseConnection が持つ。
    application
}

repositories {
    mavenCentral()
}

dependencies {
    implementation("org.json:json:20240303")

    // FluseTunnel は streamId ごとに coroutine を立てて双方向にコピーする。
    // JVM のブロッキング Socket を使うため、実行は Dispatchers.IO に載せる。
    api("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.9.0")

    testImplementation(kotlin("test"))
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.9.0")
}

kotlin {
    jvmToolchain(17)
}

sourceSets {
    main {
        // **ワイヤ実装は fluse_runtime が持つ。** ここへコピーを置くと
        // 二重管理になり、片方だけ直った状態を検知できない。同じファイルを
        // 見に行かせて、ずれようが無いようにしておく。
        //
        // `src/wire` は Android SDK に触らないワイヤ実装だけを置く場所。
        // `src/main` には ContentProvider などが入っており、ここからは
        // 参照できない（`android.jar` が無い）。
        //
        // `l1harness` は移せない。`java.net.http` が Android に無いため。
        kotlin.srcDir("../fluse_runtime/android/src/wire/kotlin")
    }
}

application {
    // dev.fluse.runtime.l1harness は L1統合テスト専用。
    // ワイヤ実装は Task 4.3 で Android プラグインへ移したが、この
    // パッケージだけは残してある（java.net.http が Android に無い）。
    mainClass.set("dev.fluse.runtime.l1harness.MainKt")
}

tasks.test {
    useJUnitPlatform()

    // ゴールデンは Gradle の外（Dart パッケージ側）にあり、WireGoldenTest が
    // 実行時に相対パスで読む。**入力として宣言しないと**、ゴールデンだけを
    // 変えたときに test が UP-TO-DATE で飛ばされ、「片方だけ直すと
    // もう片方が落ちる」という保証がそのまま効かなくなる。
    inputs
        .file(layout.projectDirectory.file("../fluse_protocol/test/fixtures/wire_golden.json"))
        .withPropertyName("wireGolden")
        .withPathSensitivity(PathSensitivity.RELATIVE)

    testLogging {
        events("passed", "failed", "skipped")
    }
}
