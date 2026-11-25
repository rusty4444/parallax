plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val parallaxPlayBuild = (providers.environmentVariable("PARALLAX_PLAY_BUILD").orNull
    ?: providers.gradleProperty("parallax.playBuild").orNull) == "true"

// The Android Auto car screen (templated messaging, src/carApp). Google Play
// accepts templated messaging apps on internal and closed testing tracks only
// and rejects them on open testing and production, so Play builds leave it
// out unless PARALLAX_CAR_TEMPLATES=true is set for such a track. Every other
// build (CI and local APKs) includes it. Car notifications are in every build.
val parallaxCarTemplates = (providers.environmentVariable("PARALLAX_CAR_TEMPLATES").orNull
    ?: providers.gradleProperty("parallax.carTemplates").orNull)
    ?.let { it == "true" }
    ?: !parallaxPlayBuild

android {
    namespace = "net.samrussell.parallax"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion
    val playBuild = parallaxPlayBuild
    val ciKeystoreFile = System.getenv("PARALLAX_KEYSTORE_FILE")?.takeIf { it.isNotBlank() }

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "net.samrussell.parallax"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        manifestPlaceholders["parallaxAutomotiveAppDesc"] =
            if (parallaxCarTemplates) "automotive_app_desc_car" else "automotive_app_desc"
    }

    signingConfigs {
        if (playBuild) {
            val uploadKeystore = providers.environmentVariable("PARALLAX_UPLOAD_KEYSTORE").orNull
                ?: providers.gradleProperty("parallax.uploadKeystore").orNull
            val uploadStorePassword = providers.environmentVariable("PARALLAX_UPLOAD_STORE_PASSWORD").orNull
            val uploadKeyPassword = providers.environmentVariable("PARALLAX_UPLOAD_KEY_PASSWORD").orNull
            require(!uploadKeystore.isNullOrBlank() && !uploadStorePassword.isNullOrBlank() && !uploadKeyPassword.isNullOrBlank()) {
                "Play builds require upload keystore path and brokered upload-key environment variables"
            }
            create("parallaxUpload") {
                storeFile = file(uploadKeystore)
                storePassword = uploadStorePassword
                keyAlias = "parallax-upload"
                keyPassword = uploadKeyPassword
            }
        } else if (ciKeystoreFile != null) {
            create("personalTest") {
                storeFile = file(ciKeystoreFile)
                storePassword = "android"
                keyAlias = "androiddebugkey"
                keyPassword = "android"
            }
        }
    }

    buildTypes {
        release {
            // Play builds use the dedicated upload key; CI pins the personal
            // preview key; local release builds use the developer's debug key.
            signingConfig = signingConfigs.getByName(
                when {
                    playBuild -> "parallaxUpload"
                    ciKeystoreFile != null -> "personalTest"
                    else -> "debug"
                }
            )
        }
    }
}

androidComponents {
    onVariants { variant ->
        if (parallaxCarTemplates) {
            variant.sources.manifests.addStaticManifestFile("src/carApp/AndroidManifest.xml")
            variant.sources.res?.addStaticSourceDirectory("src/carApp/res")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

configurations.all {
    // UnifiedPush's connector depends on JVM Tink; flutter_secure_storage ships
    // tink-android with the same classes. Keep only the Android artifact.
    exclude(group = "com.google.crypto.tink", module = "tink")
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
    // AppCompat launch themes keep the biometric prompt stable on Android 8 and below.
    implementation("androidx.appcompat:appcompat:1.8.0")
    // Video compression for sending (VideoTools.kt).
    implementation("androidx.media3:media3-transformer:1.11.1")
    implementation("androidx.media3:media3-effect:1.11.1")
    implementation("androidx.media3:media3-common:1.11.1")
    // On-device translation (TranslationTools.kt): models download per language
    // and translated text never leaves the device.
    implementation("com.google.mlkit:translate:17.0.3")
    implementation("com.google.mlkit:language-id:17.0.6")
    // Android Auto (AndroidAuto.kt, ParallaxCarApp.kt): car connection state
    // for every build, conversation templates where the car screen is built.
    // 1.8.0-rc01 carries a security fix missing from 1.7.0.
    implementation("androidx.car.app:app:1.8.0-rc01")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.18.1")
    testImplementation("androidx.test:core:1.7.0")
    testImplementation("androidx.car.app:app-testing:1.8.0-rc01")
}
