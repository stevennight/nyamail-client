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

## Check

```powershell
flutter analyze --no-pub
flutter test --no-pub
```

Provider/OAuth smoke tools live under `tool/`.
