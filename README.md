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

Provider/OAuth smoke tools live under `tool/`.
