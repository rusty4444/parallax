plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "net.samrussell.parallax"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion
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
    }

    if (ciKeystoreFile != null) {
        signingConfigs {
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
            // CI pins the same personal preview key as earlier APKs. Local
            // release builds continue to use the developer's debug key.
            signingConfig = signingConfigs.getByName(if (ciKeystoreFile != null) "personalTest" else "debug")
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
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    // AppCompat launch themes keep the biometric prompt stable on Android 8 and below.
    implementation("androidx.appcompat:appcompat:1.7.1")
}
