import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

val signingProperties = Properties()
val signingPropertiesFile = rootProject.file("key.properties")
if (signingPropertiesFile.exists()) {
    signingProperties.load(FileInputStream(signingPropertiesFile))
}

fun signingValue(propertyName: String, environmentName: String): String? {
    val value = signingProperties.getProperty(propertyName) ?: System.getenv(environmentName)
    return value?.trim()?.takeIf { it.isNotEmpty() }
}

fun configValue(propertyName: String, environmentName: String, defaultValue: String): String {
    return (project.findProperty(propertyName) as String?)
        ?.trim()
        ?.takeIf { it.isNotEmpty() }
        ?: System.getenv(environmentName)?.trim()?.takeIf { it.isNotEmpty() }
        ?: defaultValue
}

val releaseStoreFilePath = signingValue("storeFile", "NYAMAIL_ANDROID_STORE_FILE")
val releaseStorePassword = signingValue("storePassword", "NYAMAIL_ANDROID_STORE_PASSWORD")
val releaseKeyAlias = signingValue("keyAlias", "NYAMAIL_ANDROID_KEY_ALIAS")
val releaseKeyPassword = signingValue("keyPassword", "NYAMAIL_ANDROID_KEY_PASSWORD")
val oauthRedirectScheme = configValue(
    "nyamail.oauthRedirectScheme",
    "NYAMAIL_ANDROID_OAUTH_REDIRECT_SCHEME",
    "com.nyatori.nyamail"
)
val hasReleaseSigning = listOf(
    releaseStoreFilePath,
    releaseStorePassword,
    releaseKeyAlias,
    releaseKeyPassword,
).all { it != null }

gradle.taskGraph.whenReady {
    val buildsRelease = allTasks.any { task ->
        task.name.contains("release", ignoreCase = true)
    }
    if (buildsRelease && !hasReleaseSigning) {
        throw GradleException(
            "Android release signing is not configured. Provide android/key.properties " +
                "or the four NYAMAIL_ANDROID_* signing environment variables."
        )
    }
    if (buildsRelease && !rootProject.file(releaseStoreFilePath!!).isFile) {
        throw GradleException(
            "Android release keystore was not found at the configured storeFile path."
        )
    }
}

android {
    namespace = "com.nyatori.nyamail"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "com.nyatori.nyamail"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = maxOf(flutter.minSdkVersion, 24)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        manifestPlaceholders["nyamailOAuthRedirectScheme"] = oauthRedirectScheme
    }

    signingConfigs {
        create("release") {
            if (hasReleaseSigning) {
                storeFile = rootProject.file(releaseStoreFilePath!!)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            if (hasReleaseSigning) {
                signingConfig = signingConfigs.getByName("release")
            }
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("com.google.android.gms:play-services-auth:21.3.0")
}

flutter {
    source = "../.."
}
