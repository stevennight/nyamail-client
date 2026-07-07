param(
  [switch]$SkipWindows,
  [switch]$SkipAndroid,
  [switch]$NoPub,
  [string]$ApiBaseUrl = "http://localhost:8080",
  [string]$ReleaseChannel = "dev",
  [string]$ReleasePublicKey = "",
  [string]$GmailOAuthClientId = "",
  [string]$GmailOAuthClientSecret = "",
  [string]$GmailAndroidOAuthClientId = "",
  [string]$GmailAndroidOAuthClientSecret = "",
  [string]$GmailAndroidOAuthRedirectUri = "",
  [string]$OutlookOAuthClientId = "",
  [string]$OutlookOAuthClientSecret = "",
  [string]$OutlookAndroidOAuthClientId = "",
  [string]$OutlookAndroidOAuthClientSecret = "",
  [string]$OutlookAndroidOAuthRedirectUri = "",
  [string]$AndroidOAuthRedirectScheme = "com.nyatori.nyamail",
  [string]$OAuthRedirectPath = "/oauth2redirect"
)

$ErrorActionPreference = "Stop"
$Root = Resolve-Path (Join-Path $PSScriptRoot "..")
$WorkspaceRoot = Resolve-Path (Join-Path $Root "..")

function Invoke-Checked {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [string[]]$Arguments = @()
  )

  & $FilePath @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "$FilePath failed with exit code $LASTEXITCODE"
  }
}

function Get-FlutterCommand {
  $workspaceFlutter = Join-Path $WorkspaceRoot ".cache\flutter\bin\flutter.bat"
  if (Test-Path -LiteralPath $workspaceFlutter) {
    return $workspaceFlutter
  }
  $pathFlutter = Get-Command flutter -ErrorAction SilentlyContinue
  if ($pathFlutter) {
    return $pathFlutter.Source
  }
  throw "Flutter was not found. Put Flutter on PATH or install it at $workspaceFlutter."
}

function Get-PubspecVersion {
  $pubspec = Join-Path $Root "pubspec.yaml"
  foreach ($line in Get-Content -LiteralPath $pubspec -Encoding UTF8) {
    if ($line -match "^\s*version:\s*(.+?)\s*$") {
      return $Matches[1].Trim().Trim('"').Trim("'")
    }
  }
  throw "Could not find version in $pubspec."
}

function Get-BuildVersionParts {
  param([Parameter(Mandatory = $true)][string]$Version)

  if ($Version -match "^(.+)\+([0-9]+)$") {
    return @{
      Name = $Matches[1]
      Number = $Matches[2]
    }
  }
  return @{
    Name = $Version
    Number = "1"
  }
}

function New-ArtifactSummary {
  param([Parameter(Mandatory = $true)][string]$Path)

  $item = Get-Item -LiteralPath $Path
  $hash = Get-FileHash -LiteralPath $Path -Algorithm SHA256
  return [pscustomobject]@{
    Path = $item.FullName
    SizeMB = [math]::Round($item.Length / 1MB, 2)
    SHA256 = $hash.Hash
  }
}

$Version = Get-PubspecVersion
$VersionParts = Get-BuildVersionParts -Version $Version
$Flutter = Get-FlutterCommand
$ReleasesDir = Join-Path $Root "build\releases"
New-Item -ItemType Directory -Force -Path $ReleasesDir | Out-Null

$flutterCache = Join-Path $WorkspaceRoot ".cache\flutter"
if (Test-Path -LiteralPath $flutterCache) {
  $env:GIT_CONFIG_COUNT = "1"
  $env:GIT_CONFIG_KEY_0 = "safe.directory"
  $env:GIT_CONFIG_VALUE_0 = ($flutterCache -replace "\\", "/")
}
$env:FLUTTER_SUPPRESS_ANALYTICS = "true"
$env:FLUTTER_SWIFT_PACKAGE_MANAGER = "false"
$env:PUB_CACHE = Join-Path $WorkspaceRoot ".cache\pub"
$env:APPDATA = Join-Path $WorkspaceRoot ".cache\appdata"
$env:LOCALAPPDATA = Join-Path $WorkspaceRoot ".cache\localappdata"

$dartDefines = @(
  "NYAMAIL_API_BASE_URL=$ApiBaseUrl",
  "NYAMAIL_RELEASE_CHANNEL=$ReleaseChannel",
  "NYAMAIL_RELEASE_PUBLIC_KEY=$ReleasePublicKey",
  "NYAMAIL_GMAIL_OAUTH_CLIENT_ID=$GmailOAuthClientId",
  "NYAMAIL_GMAIL_OAUTH_CLIENT_SECRET=$GmailOAuthClientSecret",
  "NYAMAIL_GMAIL_ANDROID_OAUTH_CLIENT_ID=$GmailAndroidOAuthClientId",
  "NYAMAIL_GMAIL_ANDROID_OAUTH_CLIENT_SECRET=$GmailAndroidOAuthClientSecret",
  "NYAMAIL_GMAIL_ANDROID_OAUTH_REDIRECT_URI=$GmailAndroidOAuthRedirectUri",
  "NYAMAIL_OUTLOOK_OAUTH_CLIENT_ID=$OutlookOAuthClientId",
  "NYAMAIL_OUTLOOK_OAUTH_CLIENT_SECRET=$OutlookOAuthClientSecret",
  "NYAMAIL_OUTLOOK_ANDROID_OAUTH_CLIENT_ID=$OutlookAndroidOAuthClientId",
  "NYAMAIL_OUTLOOK_ANDROID_OAUTH_CLIENT_SECRET=$OutlookAndroidOAuthClientSecret",
  "NYAMAIL_OUTLOOK_ANDROID_OAUTH_REDIRECT_URI=$OutlookAndroidOAuthRedirectUri",
  "NYAMAIL_OAUTH_REDIRECT_SCHEME=$AndroidOAuthRedirectScheme",
  "NYAMAIL_OAUTH_REDIRECT_PATH=$OAuthRedirectPath"
)

function New-FlutterBuildArguments {
  param([Parameter(Mandatory = $true)][string[]]$BaseArguments)

  $arguments = @()
  $arguments += $BaseArguments
  if ($NoPub) {
    $arguments += "--no-pub"
  }
  $arguments += @("--build-name", $VersionParts.Name, "--build-number", $VersionParts.Number)
  foreach ($define in $dartDefines) {
    $arguments += @("--dart-define", $define)
  }
  return $arguments
}

Push-Location $Root
try {
  if (-not $NoPub) {
    Invoke-Checked -FilePath $Flutter -Arguments @("pub", "get")
  }

  $artifacts = @()

  if (-not $SkipWindows) {
    Invoke-Checked -FilePath $Flutter -Arguments (New-FlutterBuildArguments -BaseArguments @("build", "windows", "--release"))

    $windowsBuild = Join-Path $Root "build\windows\x64\runner\Release"
    $windowsExe = Join-Path $windowsBuild "nyamail.exe"
    if (-not (Test-Path -LiteralPath $windowsExe)) {
      throw "Windows build output was not found: $windowsExe"
    }

    $windowsZip = Join-Path $ReleasesDir "nyamail-windows-x64-$Version.zip"
    $windowsFiles = Get-ChildItem -LiteralPath $windowsBuild -Force |
      Where-Object { -not ($_.Extension -ieq ".zip") } |
      Select-Object -ExpandProperty FullName
    Compress-Archive -LiteralPath $windowsFiles -DestinationPath $windowsZip -Force
    $artifacts += New-ArtifactSummary -Path $windowsZip
  }

  if (-not $SkipAndroid) {
    $previousAndroidScheme = $env:NYAMAIL_ANDROID_OAUTH_REDIRECT_SCHEME
    try {
      $env:NYAMAIL_ANDROID_OAUTH_REDIRECT_SCHEME = $AndroidOAuthRedirectScheme
      Invoke-Checked -FilePath $Flutter -Arguments (New-FlutterBuildArguments -BaseArguments @("build", "apk", "--release"))
    } finally {
      if ($null -eq $previousAndroidScheme) {
        Remove-Item Env:\NYAMAIL_ANDROID_OAUTH_REDIRECT_SCHEME -ErrorAction SilentlyContinue
      } else {
        $env:NYAMAIL_ANDROID_OAUTH_REDIRECT_SCHEME = $previousAndroidScheme
      }
    }

    $androidApk = Join-Path $Root "build\app\outputs\flutter-apk\app-release.apk"
    if (-not (Test-Path -LiteralPath $androidApk)) {
      throw "Android build output was not found: $androidApk"
    }

    $androidOut = Join-Path $ReleasesDir "nyamail-android-$Version.apk"
    Copy-Item -LiteralPath $androidApk -Destination $androidOut -Force
    $artifacts += New-ArtifactSummary -Path $androidOut
  }

  Write-Host "Release artifacts:"
  $artifacts | Format-Table -AutoSize
} finally {
  Pop-Location
}
