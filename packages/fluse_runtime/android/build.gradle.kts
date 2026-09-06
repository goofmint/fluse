group = "dev.fluse.runtime"
version = "1.0-SNAPSHOT"

buildscript {
    val kotlinVersion = "2.2.20"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:8.11.1")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
    id("kotlin-android")
}

android {
    // ワイヤ実装（`src/wire`）と同じ package 名。Task 4.3 で
    // fluse_protocol_kt から移した際、package を書き換えずに済ませた。
    namespace = "dev.fluse.runtime"

    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    sourceSets {
        getByName("main") {
            // `src/wire` はワイヤ実装（設計 §2.2.1）。Android SDK に触らず、
            // `fluse_protocol_kt` が JVM 上のゴールデン突合と L1統合テストの
            // ハーネスから同じファイルを見に行く。**コピーは作らないこと。**
            // 二重管理になると、片方だけ直った状態を検知できない。
            java.srcDirs("src/main/kotlin", "src/wire/kotlin")
        }
        getByName("test") {
            java.srcDirs("src/test/kotlin")
        }
    }

    defaultConfig {
        // 設計 §1.2。雛形の既定（24）より下げて対象端末を広く取る。
        minSdk = 21
    }

    testOptions {
        unitTests {
            isIncludeAndroidResources = true

            // **`android.util.Log` はスタブしか無い。** 既定では呼ぶだけで
            // 「not mocked」を投げるため、ログを出す経路が単体テストで
            // 通せない。戻り値は使っていないので既定値で構わない。
            isReturnDefaultValues = true
            all {
                it.useJUnitPlatform()

                it.outputs.upToDateWhen { false }

                it.testLogging {
                    events("passed", "skipped", "failed", "standardOut", "standardError")
                    showStandardStreams = true
                }
            }
        }
    }
}

dependencies {
    // deviceToken を平文で置かないための EncryptedSharedPreferences
    // （設計 §6.1）。端末を取られたときに残るのは暗号文になる。
    implementation("androidx.security:security-crypto:1.1.0")

    // **Android に `java.net.http` は無い。** `l1harness` の
    // WebSocketTunnelChannel をここへ持って来られないのはそのため。
    // 端末側の WebSocket は OkHttp で張る。MockWebServer が同じ供給元に
    // あり、完了条件の「モックWebSocketサーバ」をそのまま満たせる。
    implementation("com.squareup.okhttp3:okhttp:4.12.0")

    // FluseTunnel は streamId ごとに coroutine を立てて双方向にコピーする。
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.9.0")

    // ペアリング画面（設計 §2.2.5 の FluseConnectActivity）。
    // 権限要求に registerForActivityResult を使うため ComponentActivity が要る。
    implementation("androidx.activity:activity:1.9.3")

    // QR の読み取り。**CameraX は 1.3 系に留める。** 1.4 以降は minSdk 24 を
    // 要求し、設計 §1.2 で広く取ると決めた minSdk 21 と衝突する。
    implementation("androidx.camera:camera-core:1.3.4")
    implementation("androidx.camera:camera-camera2:1.3.4")
    implementation("androidx.camera:camera-lifecycle:1.3.4")
    implementation("androidx.camera:camera-view:1.3.4")

    // **`zxing-android-embedded` は使わない。** minSdk を引き上げるうえ、
    // 画面まで持ち込むことになる。要るのはデコードだけ。
    implementation("com.google.zxing:core:3.5.3")

    testImplementation("org.jetbrains.kotlin:kotlin-test")
    testImplementation("org.mockito:mockito-core:5.0.0")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.9.0")
    testImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")

    // **`org.json` は android.jar にスタブしか無い。** 単体テストで呼ぶと
    // 「not mocked」で落ちるため、テスト時だけ本物を載せる。
    testImplementation("org.json:json:20240303")
}
