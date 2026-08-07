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
    testImplementation(kotlin("test"))
}

kotlin {
    jvmToolchain(17)
}

tasks.test {
    useJUnitPlatform()
    testLogging {
        events("passed", "failed", "skipped")
    }
}
