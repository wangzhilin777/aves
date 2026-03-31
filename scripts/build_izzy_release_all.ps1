param(
  [switch]$UseCnMirror = $true
)

$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")

$lockPath = Join-Path (Get-Location) "pubspec.lock"
$lockBackupPath = "$lockPath.build_backup"
$hasLockFile = Test-Path -LiteralPath $lockPath
if ($hasLockFile) {
  Copy-Item -LiteralPath $lockPath -Destination $lockBackupPath -Force
}

if ($UseCnMirror) {
  $env:PUB_HOSTED_URL = "https://pub.flutter-io.cn"
  $env:FLUTTER_STORAGE_BASE_URL = "https://storage.flutter-io.cn"
  Write-Host "[env] Using CN mirror for pub/flutter storage"
}

$flutter = ".\.flutter\bin\flutter.bat"
if (!(Test-Path -LiteralPath $flutter)) {
  throw "Flutter not found at $flutter"
}

$pubspec = Get-Content pubspec.yaml -Raw
$version = [regex]::Match($pubspec, 'version:\s*([^\r\n]+)').Groups[1].Value.Trim()
if ([string]::IsNullOrWhiteSpace($version)) {
  throw "Failed to read version from pubspec.yaml"
}
Write-Host "[build] version: $version"

try {
  if ($hasLockFile) {
    try {
      & $flutter pub get --enforce-lockfile
    } catch {
      Write-Warning "[build] --enforce-lockfile not supported, fallback to plain pub get"
      & $flutter pub get
    }
  } else {
    & $flutter pub get
  }

  Write-Host "[build] universal apk (all abi)"
  & $flutter build apk --flavor izzy -t lib/main_izzy.dart --release

  Write-Host "[build] split-per-abi apk"
  & $flutter build apk --flavor izzy -t lib/main_izzy.dart --split-per-abi --release

  $outDir = "android\app\build\outputs\flutter-apk"
  $renameMap = @{
    "app-izzy-release.apk" = "app-izzy-release-$version.apk"
    "app-armeabi-v7a-izzy-release.apk" = "app-armeabi-v7a-izzy-release-$version.apk"
    "app-arm64-v8a-izzy-release.apk" = "app-arm64-v8a-izzy-release-$version.apk"
    "app-x86_64-izzy-release.apk" = "app-x86_64-izzy-release-$version.apk"
  }

  foreach ($src in $renameMap.Keys) {
    $srcPath = Join-Path $outDir $src
    if (Test-Path -LiteralPath $srcPath) {
      $dstPath = Join-Path $outDir $renameMap[$src]
      Copy-Item -LiteralPath $srcPath -Destination $dstPath -Force
      Write-Host "[done] $dstPath"
    }
  }
} finally {
  if (Test-Path -LiteralPath $lockBackupPath) {
    Move-Item -LiteralPath $lockBackupPath -Destination $lockPath -Force
    Write-Host "[clean] restored pubspec.lock from backup"
  }
}
