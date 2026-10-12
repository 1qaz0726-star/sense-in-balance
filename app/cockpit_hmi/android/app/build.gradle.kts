import java.util.Base64

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.auohack.cockpit_hmi"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        // The PC demonstration coexists with the team's differently signed APK.
        val desktopDemo = (project.findProperty("dart-defines") as? String)
            .orEmpty().split(',').any {
                runCatching {
                    String(Base64.getDecoder().decode(it), Charsets.UTF_8)
                }.getOrNull() == "REPAIR_DESKTOP_DEMO=true"
            }
        applicationId = if (desktopDemo) "com.auohack.cockpit_hmi.desktopdemo" else "com.auohack.cockpit_hmi"
        manifestPlaceholders["appLabel"] = if (desktopDemo) "不用重講 PC 實測" else "座艙 HMI"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        // Official competition rules V11 require HMI apps to target API 34.
        targetSdk = 34
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            // R8 在 flutter_gemma / MediaPipe 的原生與反射程式碼上會失敗（slm_probe 踩過）
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

flutter {
    source = "../.."
}
