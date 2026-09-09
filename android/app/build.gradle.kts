import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

fun hasSigningBlock(prefix: String): Boolean {
    val storeFilePath = keystoreProperties.getProperty("$prefix.storeFile")
    return listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
        .all { !keystoreProperties.getProperty("$prefix.$it").isNullOrBlank() } &&
        !storeFilePath.isNullOrBlank() &&
        file(storeFilePath).exists()
}

val hasPlaystoreSigning = hasSigningBlock("playstore")
val hasDappstoreSigning = hasSigningBlock("dappstore")

android {
    namespace = "com.erebrus.ai"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.erebrus.ai"
        // Native llama.cpp uses APIs introduced in Android 9.
        minSdk = 28
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    flavorDimensions += "store"
    productFlavors {
        create("playstore") {
            dimension = "store"
        }
        create("dappstore") {
            dimension = "store"
        }
    }

    signingConfigs {
        create("playstoreRelease") {
            enableV2Signing = true
            enableV3Signing = true
            if (hasPlaystoreSigning) {
                storeFile = file(keystoreProperties.getProperty("playstore.storeFile"))
                storePassword = keystoreProperties.getProperty("playstore.storePassword")
                keyAlias = keystoreProperties.getProperty("playstore.keyAlias")
                keyPassword = keystoreProperties.getProperty("playstore.keyPassword")
            }
        }
        create("dappstoreRelease") {
            enableV2Signing = true
            enableV3Signing = true
            if (hasDappstoreSigning) {
                storeFile = file(keystoreProperties.getProperty("dappstore.storeFile"))
                storePassword = keystoreProperties.getProperty("dappstore.storePassword")
                keyAlias = keystoreProperties.getProperty("dappstore.keyAlias")
                keyPassword = keystoreProperties.getProperty("dappstore.keyPassword")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }

    androidComponents {
        onVariants { variant ->
            val flavorName = variant.productFlavors
                .firstOrNull { it.first == "store" }
                ?.second

            if (variant.buildType == "release") {
                when (flavorName) {
                    "playstore" -> {
                        val config = signingConfigs.getByName("playstoreRelease")
                        variant.signingConfig.setConfig(
                            if (config.storeFile != null && config.storeFile!!.exists()) {
                                config
                            } else {
                                signingConfigs.getByName("debug")
                            }
                        )
                    }
                    "dappstore" -> {
                        val config = signingConfigs.getByName("dappstoreRelease")
                        variant.signingConfig.setConfig(
                            if (config.storeFile != null && config.storeFile!!.exists()) {
                                config
                            } else {
                                signingConfigs.getByName("debug")
                            }
                        )
                    }
                }
            }
        }
    }
}

// Default debug builds to playstore so `flutter run` works without --flavor.
androidComponents {
    beforeVariants { variantBuilder ->
        val flavorName = variantBuilder.productFlavors
            .firstOrNull { it.first == "store" }
            ?.second
        if (variantBuilder.buildType == "debug" && flavorName == "dappstore") {
            variantBuilder.enable = false
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

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
