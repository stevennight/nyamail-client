import 'dart:ffi' show Abi;
import 'dart:io' show Platform;

String windowsUpdaterScript({
  required String zipPath,
  required String installRoot,
  required String currentExe,
}) {
  final escapedZip = _escapePowerShellSingleQuoted(zipPath);
  final escapedInstallRoot = _escapePowerShellSingleQuoted(installRoot);
  final escapedCurrentExe = _escapePowerShellSingleQuoted(currentExe);
  return '''
\$ErrorActionPreference = 'Stop'
\$zip = '$escapedZip'
\$installRoot = '$escapedInstallRoot'
\$currentExe = '$escapedCurrentExe'
\$installRootFull = [System.IO.Path]::GetFullPath(\$installRoot)
\$stamp = Get-Date -Format 'yyyyMMddHHmmss'
\$target = Join-Path \$installRoot \$stamp
\$current = Join-Path \$installRoot 'current'
\$targetFull = [System.IO.Path]::GetFullPath(\$target)
\$currentFull = [System.IO.Path]::GetFullPath(\$current)
\$comparison = [System.StringComparison]::OrdinalIgnoreCase
\$installPrefix = \$installRootFull.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
if (-not \$targetFull.StartsWith(\$installPrefix, \$comparison)) {
  throw "Refusing to install outside \$installRootFull"
}
if (-not \$currentFull.StartsWith(\$installPrefix, \$comparison)) {
  throw "Refusing to update current pointer outside \$installRootFull"
}
New-Item -ItemType Directory -Force -Path \$target | Out-Null
Start-Sleep -Seconds 2
Expand-Archive -LiteralPath \$zip -DestinationPath \$target -Force
if (Test-Path -LiteralPath \$current) {
  \$currentItem = Get-Item -LiteralPath \$current -Force
  if ((\$currentItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq [System.IO.FileAttributes]::ReparsePoint) {
    [System.IO.Directory]::Delete(\$currentFull, \$false)
  } else {
    \$previous = Join-Path \$installRoot ('previous-' + \$stamp)
    Move-Item -LiteralPath \$current -Destination \$previous -Force
  }
}
New-Item -ItemType Junction -Path \$current -Target \$target | Out-Null
\$nextExe = Join-Path \$current 'nyamail.exe'
if (-not (Test-Path -LiteralPath \$nextExe)) {
  throw "Updated nyamail.exe was not found in \$current"
}
\$launchProbe = [Environment]::GetEnvironmentVariable('NYAMAIL_UPDATE_LAUNCH_PROBE')
if (-not [string]::IsNullOrWhiteSpace(\$launchProbe)) {
  Set-Content -LiteralPath \$launchProbe -Value \$nextExe -Encoding UTF8
} else {
  Start-Process -FilePath \$nextExe
}
''';
}

String _escapePowerShellSingleQuoted(String value) {
  return value.replaceAll("'", "''");
}

String currentReleasePlatform() {
  if (Platform.isWindows) return 'windows';
  if (Platform.isMacOS) return 'macos';
  if (Platform.isLinux) return 'linux';
  if (Platform.isAndroid) return 'android';
  if (Platform.isIOS) return 'ios';
  return 'unknown';
}

String currentReleaseArch() {
  switch (Abi.current()) {
    case Abi.windowsX64:
    case Abi.linuxX64:
    case Abi.macosX64:
      return 'amd64';
    case Abi.windowsArm64:
    case Abi.linuxArm64:
    case Abi.macosArm64:
      return 'arm64';
    case Abi.androidArm:
    case Abi.androidArm64:
    case Abi.androidIA32:
    case Abi.androidX64:
    case Abi.iosArm:
    case Abi.iosArm64:
    case Abi.iosX64:
      return 'universal';
    default:
      return '';
  }
}
