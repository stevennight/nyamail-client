# NyaMail Client Codex Rules

## Release Builds

When the user asks to build, rebuild, package, or create a Windows and Android
release for NyaMail Client, use the project release wrapper instead of raw
`flutter build` commands:

```powershell
.\scripts\build-release.ps1
```

Use this as the default for requests such as:

- "构建 release"
- "重新构建"
- "给我打个 windows 和 android release"
- "打包 Windows 和 Android"

The wrapper always writes release artifacts to:

```text
build/releases/nyamail-windows-x64-<version>.zip
build/releases/nyamail-android-<version>.apk
```

The `<version>` value comes from `pubspec.yaml`, for example `0.1.0+1`.

Useful options:

```powershell
.\scripts\build-release.ps1 -NoPub
.\scripts\build-release.ps1 -SkipWindows
.\scripts\build-release.ps1 -SkipAndroid
```

Only use raw `flutter build windows` or `flutter build apk` for diagnostics or
when the user explicitly asks for Flutter's default output paths.

If the sandbox user cannot write Flutter's `windows/flutter/ephemeral` or
Gradle build files, rerun the release wrapper with escalation rather than
switching to a different output convention.

After a release build, report:

- Windows zip path, size, and SHA256.
- Android APK path, size, and SHA256.
- Whether Android signing verification passed.
- Any build warnings that matter for future maintenance.

Prefer verifying the Android APK with `apksigner verify --verbose` from the
local Android SDK build-tools. Do not print keystore passwords, OAuth secrets,
or other secret values.

OAuth provider client settings are normally configured inside the app and stored
in the local vault. Do not compile OAuth client IDs or secrets into release
builds unless the user explicitly asks for that.
