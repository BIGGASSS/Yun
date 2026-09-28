plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing is explicit; never silently fall back to the Android debug key.
val releaseSigningRequested = System.getenv("YUN_ANDROID_RELEASE_SIGNING") == "true"
fun signingSecret(name: String): String = System.getenv(name)
    ?.takeIf { it.isNotBlank() }
    ?: throw GradleException("Release signing requires $name")

android {
    namespace = "app.yun.yun"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "app.yun.yun"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // Secure storage requires API 23; API 24 also enforces our per-host
        // network security policy, including loopback-only HTTP exceptions.
        minSdk = maxOf(24, flutter.minSdkVersion)
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (releaseSigningRequested) {
            create("operatorRelease") {
                storeFile = file(signingSecret("YUN_ANDROID_KEYSTORE_PATH")).also {
                    if (!it.isFile) throw GradleException("Release keystore is missing")
                }
                storePassword = signingSecret("ANDROID_KEYSTORE_PASSWORD")
                keyAlias = signingSecret("ANDROID_KEY_ALIAS")
                keyPassword = signingSecret("ANDROID_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (releaseSigningRequested) {
                signingConfigs.getByName("operatorRelease")
            } else {
                null // Local unsigned release builds are not distribution candidates.
            }
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
