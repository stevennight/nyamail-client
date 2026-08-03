# NyaMail Client

This repository contains the Flutter client app for Windows, Linux, macOS, Android, and iOS.

The client is local-first. It can create and unlock a local encrypted vault, add mailboxes, connect directly to mail providers, cache mail locally, and optionally connect to a self-hosted NyaMail server for encrypted sync and update checks.

## Run

Install Flutter or put a local Flutter SDK on `PATH`, then run the Windows client from the repository root:

```powershell
flutter run -d windows --dart-define NYAMAIL_API_BASE_URL=http://localhost:8080
```

Android can be run the same way when a device or emulator is available:

```powershell
flutter run -d android --dart-define NYAMAIL_API_BASE_URL=http://localhost:8080
```

Android OAuth uses an app callback instead of the desktop `127.0.0.1`
loopback server. The default redirect URI is:

```text
com.nyatori.nyamail:/oauth2redirect
```

The Android manifest registers only the URI scheme. If you need a provider
specific scheme, pass the same scheme to Gradle and Dart when building:

```powershell
$env:NYAMAIL_ANDROID_OAUTH_REDIRECT_SCHEME = "com.nyatori.nyamail"
flutter run -d android `
  --dart-define NYAMAIL_OAUTH_REDIRECT_SCHEME=com.nyatori.nyamail `
  --dart-define NYAMAIL_OAUTH_REDIRECT_PATH=/oauth2redirect
```

You can also put `nyamail.oauthRedirectScheme=...` in
`android/gradle.properties` for local builds.

Provider client IDs and secrets can be stored from the in-app OAuth providers
settings. Android can use separate Android client values and an optional
provider-specific Android redirect URI.

## Check

```powershell
flutter analyze --no-pub
flutter test --no-pub
```

## Release Builds

Use the project release wrapper so artifacts always land in the same place with
the same naming convention:

```powershell
.\scripts\build-release.ps1
```

Outputs:

```text
build/releases/nyamail-windows-x64-<version>.zip
build/releases/nyamail-windows-x64-<version>.zip.sha256
build/releases/nyamail-android-<version>.apk
build/releases/nyamail-android-<version>.apk.sha256
```

The version comes from `pubspec.yaml`, currently `1.0.4+5`. The Windows zip
contains the Flutter `Release` directory contents and excludes stale zip files
from previous builds. Use `-SkipWindows`, `-SkipAndroid`, or `-NoPub` when you
only need part of the build. Release builds use the `stable` update channel by
default.

Android release builds require a production signing key. Local builds load
`android/key.properties`; CI loads the same four values through environment
variables. A release build fails instead of falling back to the debug key when
signing is incomplete.

## GitHub Actions

`.github/workflows/ci.yml` runs analysis and tests for pull requests. Pushes to
`main`, tags matching `v*`, and manual runs also build signed Windows and
Android release artifacts with `scripts/build-release.ps1` and upload their
SHA256 files. Tag builds create a GitHub Release and attach both platform
artifacts and checksum files. To publish an existing tag, manually run the
workflow and provide that tag in the optional `release_tag` input.

Configure this repository variable in GitHub Actions:

```text
NYAMAIL_API_BASE_URL
```

Configure these repository secrets:

```text
NYAMAIL_ANDROID_KEYSTORE_BASE64
NYAMAIL_ANDROID_STORE_PASSWORD
NYAMAIL_ANDROID_KEY_ALIAS
NYAMAIL_ANDROID_KEY_PASSWORD
NYAMAIL_RELEASE_PUBLIC_KEY
```

`NYAMAIL_ANDROID_KEYSTORE_BASE64` is the Base64 encoding of the existing
`android/keystores/nyamail-release.jks` file. Keep that keystore and its
passwords backed up outside the repository; replacing it prevents signed app
updates from being installed over previous releases. OAuth provider client
settings remain user-configured inside the app and are not compiled into CI
artifacts.

Provider/OAuth smoke tools live under `tool/`.
