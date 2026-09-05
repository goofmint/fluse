// fluse_protocol の Kotlin 実装。
//
// **Task 4.1 で fluse_runtime の Android プラグインを作る際、このソースを
// `packages/fluse_runtime/android/src/main/kotlin/` へ移す。** 現時点では
// プラグイン雛形が無く（Task 2.3 は Task 4.1 より前に来る）、単体で JVM 上の
// JUnit を回せるようにするために独立したモジュールにしている。
plugins {
    kotlin("jvm") version "2.1.0"

    // L1統合テスト（Task 2.5）のハーネスを独立プロセスとして起動するために入れる。
    // Dart 側テストが `installDist` の生成物
    // （build/install/fluse_protocol_kt/bin/fluse_protocol_kt）を直接叩く。
    // **ライブラリとしての用途は変わらない。** 本番の端末側 WebSocket は
    // FluseConnection（Task 4.3）が持つ。
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

application {
    // dev.fluse.runtime.l1harness は L1統合テスト専用。
    // Task 4.1 で src/main/kotlin を Android プラグインへ移す際、
    // このパッケージは持って行かないこと（java.net.http が Android に無い）。
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
