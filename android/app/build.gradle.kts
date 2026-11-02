import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseKeyFile = rootProject.file("key.properties")
val releaseKeys = Properties().apply {
    if (releaseKeyFile.isFile) releaseKeyFile.inputStream().use { load(it) }
}
val readerPreview = providers.gradleProperty("wenkuReaderPreview").orNull == "true"
val catalogProbe = providers.gradleProperty("wenkuCatalogProbe").orNull == "true"
check(!catalogProbe || readerPreview) { "Account read probes are restricted to the reader preview" }

android {
    namespace = "org.mewx.wenku8_flutter"
    // Legado engine AARs (libs/) were built against compileSdk 37 and AGP's
    // checkDebugAarMetadata refuses them under 36, so the host compiles
    // against 37. targetSdk/minSdk stay on the Flutter defaults below —
    // compileSdk alone changes no runtime behavior.
    compileSdk = 37
    ndkVersion = flutter.ndkVersion
    // The separately authorized API runtime must remain byte-for-byte intact.
    // AGP otherwise strips its symbols even when jniLibs contains original files.
    packaging.jniLibs.keepDebugSymbols.add("**/libcpp.so")

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.cassidy.xiaoshuowenku"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        manifestPlaceholders["wenkuAppLabel"] = "小说文库"
        testInstrumentationRunner = "org.mewx.wenku8_flutter.SessionFixtureInstrumentation"
        if (catalogProbe) testInstrumentationRunner = "org.mewx.wenku8_flutter.CatalogReadInstrumentation"
        // AGP otherwise builds upstream desktop utilities too, including the
        // DRM tool whose encryption code is intentionally disabled in this app.
        externalNativeBuild.cmake.targets.addAll(listOf("mobi", "wenku_mobi"))
    }
    if (catalogProbe) testBuildType = "release"

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
        }
    }

    if (releaseKeyFile.isFile) {
        signingConfigs.create("distribution") {
            keyAlias = releaseKeys.getProperty("keyAlias")
            keyPassword = releaseKeys.getProperty("keyPassword")
            storeFile = rootProject.file(requireNotNull(releaseKeys.getProperty("storeFile")))
            storePassword = releaseKeys.getProperty("storePassword")
        }
    }

    buildTypes {
        getByName("debug") {
            // The integration runner uninstalls its package on completion.
            // Keep rendering probes separate from the user's release data.
            applicationIdSuffix = ".render_probe"
        }
        getByName("profile") {
            applicationIdSuffix = ".profile_probe"
        }
        release {
            proguardFile(file("document-import.pro"))
            if (catalogProbe) proguardFile(file("catalog-probe.pro"))
            if (readerPreview) {
                applicationIdSuffix = ".reader_preview"
                manifestPlaceholders["wenkuAppLabel"] = "文库 · 阅读预览"
            }
            // Local previews remain install-compatible. Public distributions
            // use an owner's untracked key.properties, never an embedded key.
            signingConfig = signingConfigs.getByName(
                if (releaseKeyFile.isFile && !readerPreview) "distribution" else "debug"
            )
        }
    }

    // Match the embedded API library to the Flutter code actually compiled for
    // this APK. Otherwise a one-ABI build advertises extra, unusable ABIs solely
    // because libcpp.so exists for them. Let Flutter own split-APK filtering.
    val targets = project.findProperty("target-platform")?.toString()
    if (targets != null && project.findProperty("split-per-abi")?.toString()?.toBoolean() != true) {
        val targetAbis = targets.split(",").map { platform ->
            when (platform) {
                "android-arm" -> "armeabi-v7a"
                "android-arm64" -> "arm64-v8a"
                "android-x64" -> "x86_64"
                else -> error("Unsupported Flutter target platform: $platform")
            }
        }
        buildTypes.configureEach {
            ndk.abiFilters.clear()
            ndk.abiFilters.addAll(targetAbis)
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs_nio:2.1.5")
    // Legado engine (spike2): vendored AARs built in the legado-engine-src
    // repo with the fork's own toolchain (Gradle 9.6 / Kotlin 2.3.20) and
    // committed under libs/. Local AARs carry no POM, so the engine's
    // external dependencies are declared manually below, with versions
    // aligned to legado's gradle/libs.versions.toml.
    implementation(fileTree(mapOf("dir" to "libs", "include" to listOf("*.aar"))))
    implementation("com.squareup.okhttp3:okhttp:5.4.0")
    implementation("com.squareup.okio:okio:3.18.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.11.0")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-protobuf:1.11.0")
    implementation("org.jetbrains.kotlinx:atomicfu:0.33.0")
    implementation("androidx.room3:room3-runtime:3.0.1")
    implementation("androidx.sqlite:sqlite-framework:2.7.0")
    implementation("com.fleeksoft.ksoup:ksoup:0.2.6")
    implementation("org.jetbrains.compose.runtime:runtime:1.11.1")
    implementation("com.google.code.gson:gson:2.11.0")
    implementation("cn.hutool:hutool-crypto:5.8.22")
    implementation("org.nanohttpd:nanohttpd:2.3.1")
    implementation("org.nanohttpd:nanohttpd-websocket:2.3.1")
    implementation("androidx.collection:collection:1.6.0")
    implementation("androidx.core:core-ktx:1.18.0")
    implementation("androidx.documentfile:documentfile:1.1.0")
    implementation("com.caverock:androidsvg-aar:1.4")
    implementation("io.coil-kt.coil3:coil-network-okhttp:3.4.0")
    implementation("com.github.null2264.injekt:injekt-core:4135455a2a")
    implementation("com.github.liuyueyi.quick-chinese-transfer:quick-transfer-core:0.2.16")
    // NOTE: no org.jsoup:jsoup Maven dependency on purpose. The engine's
    // data.aar carries its own vendored org.jsoup.* classes (Kotlin port);
    // a second copy would collide in dexing (ENGINE-spike2 §3.5-3). The
    // host's single jsoup consumer (BookMarkupImport.kt) compiles against
    // the vendored copy instead.
    implementation("org.commonmark:commonmark:0.30.1")
    implementation("com.tom-roush:pdfbox-android:2.0.27.0")
    // Keep the media host classes available to the app's shared-engine wiring.
    implementation("androidx.media:media:1.7.0")
    testImplementation("junit:junit:4.13.2")
}
