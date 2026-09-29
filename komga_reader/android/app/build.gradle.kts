import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keyProperties = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) FileInputStream(f).use { load(it) }
}

// The keystore password: from KOMGA_SIGNING_PASSWORD, which tools/build.ps1 sets for one build from the copy encrypted
// with the Windows account (%USERPROFILE%\.keystores\android-release.pass) - or, failing that, from key.properties.
// No password: release builds use the debug key.
val signingPassword: String? = System.getenv("KOMGA_SIGNING_PASSWORD")?.takeIf { it.isNotEmpty() }
    ?: keyProperties.getProperty("storePassword")?.takeIf { it.isNotEmpty() && !it.startsWith("<") }
val releaseSigning = keyProperties.getProperty("storeFile") != null && signingPassword != null

android {
    namespace = "com.nickp.komga_reader"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Permanent once released: Android treats a different ID as a different app.
        applicationId = "com.nickp.komga_reader"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Release signing: android/key.properties (never committed - see key.properties.example) names the keystore,
    // which lives outside the repository. Without it, release builds fall back to the debug key (tools/build.ps1
    // warns). Android only updates an app signed with the same key, so this key must never change once released.
    signingConfigs {
        if (releaseSigning) {
            create("release") {
                storeFile = file(keyProperties.getProperty("storeFile"))
                storePassword = signingPassword
                keyAlias = keyProperties.getProperty("keyAlias") ?: "release"
                keyPassword = signingPassword // a PKCS12 keystore: one password for the store and the key
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (releaseSigning) signingConfigs.getByName("release")
                else signingConfigs.getByName("debug")
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
