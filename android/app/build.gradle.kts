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

android {
    namespace = "org.mewx.wenku8_flutter"
    // Legado engine AARs under libs/ were built against compileSdk 37; AGP's
    // AAR metadata check rejects them under 36.
    compileSdk = 37
    ndkVersion = flutter.ndkVersion
    packaging.jniLibs.keepDebugSymbols.add("**/libcpp.so")
    packaging.resources.excludes.add("META-INF/INDEX.LIST")

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // Same id as the personal fork build so installing this shell upgrades
        // the existing install and keeps the local library on device.
        applicationId = "com.cassidy.xiaoshuowenku"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        manifestPlaceholders["wenkuAppLabel"] = "轻小说文库"
        // AGP otherwise builds upstream desktop utilities too, including the
        // DRM tool whose encryption code is intentionally disabled in this app.
        externalNativeBuild.cmake.targets.addAll(listOf("mobi", "wenku_mobi"))
    }

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
        debug {
            applicationIdSuffix = ".probe"
        }
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                file("document-import.pro"),
                file("legado-keep.pro")
            )
            if (readerPreview) {
                applicationIdSuffix = ".reader_preview"
            }
            // Local previews remain install-compatible. Public distributions
            // use an owner's untracked key.properties, never an embedded key.
            signingConfig = signingConfigs.getByName(
                if (releaseKeyFile.isFile && !readerPreview) "distribution" else "debug"
            )
        }
    }

    // Match native document import libraries to the selected Flutter targets.
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
    implementation("org.apache.poi:poi-scratchpad:5.5.1")
    implementation("com.github.albfernandez:juniversalchardet:2.0.4")
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs_nio:2.1.5")
    // jsoup ships inside the Legado data.aar (see libs/); declaring it here
    // duplicates org.jsoup.* classes at the release class check.
    implementation("org.commonmark:commonmark:0.30.1")
    implementation("com.tom-roush:pdfbox-android:2.0.27.0")
    // Keep the media host classes available to the app's shared-engine wiring.
    implementation("androidx.media:media:1.7.0")
    // Legado engine: vendored AARs carry no POM, so their external
    // dependencies are declared manually below.
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
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-cbor:1.9.0")
    implementation("androidx.collection:collection:1.6.0")
    implementation("androidx.core:core-ktx:1.18.0")
    implementation("androidx.webkit:webkit:1.16.0")
    implementation("androidx.documentfile:documentfile:1.1.0")
    implementation("com.caverock:androidsvg-aar:1.4")
    implementation("io.coil-kt.coil3:coil-network-okhttp:3.4.0")
    implementation("com.github.null2264.injekt:injekt-core:4135455a2a")
    implementation("com.github.liuyueyi.quick-chinese-transfer:quick-transfer-core:0.2.16")
}
