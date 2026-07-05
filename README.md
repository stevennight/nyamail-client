# NyaMail Client

This directory is the future standalone client repository root. It contains the Flutter app for Windows, Linux, macOS, Android, and iOS.

The client is local-first. It can create and unlock a local encrypted vault, add mailboxes, connect directly to mail providers, cache mail locally, and optionally connect to a self-hosted NyaMail server for encrypted sync and update checks.

## Run

From the workspace root, bootstrap the local Flutter SDK when needed:

```powershell
.\.workspace\scripts\bootstrap_flutter.ps1
```

Then run the Windows client:

```powershell
cd client
..\.cache\flutter\bin\flutter.bat run -d windows --dart-define NYAMAIL_API_BASE_URL=http://localhost:8080
```

If Flutter is already on `PATH`, `flutter run -d windows` works from this directory.

## Check

```powershell
flutter analyze --no-pub
flutter test --no-pub
```

Provider/OAuth smoke tools live under `tool/`; the current workspace wrappers in `..\.workspace\scripts` call those tools with the right arguments.
