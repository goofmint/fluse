// fluse_protocol の Kotlin 実装。
//
// **Task 4.1 で fluse_runtime の Android プラグインを作る際、このソースを
// `packages/fluse_runtime/android/src/main/kotlin/` へ移す。** 現時点では
// プラグイン雛形が無く（Task 2.3 は Task 4.1 より前に来る）、単体で JVM 上の
// JUnit を回せるようにするために独立したモジュールにしている。
plugins {
    kotlin("jvm") version "2.1.0"
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
