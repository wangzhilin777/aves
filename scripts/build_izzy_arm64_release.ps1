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

$everythingPath = "E:\Program Files\Everything-1.4.1.1009.x64\Everything.exe"
if (Test-Path -LiteralPath $everythingPath) {
  Write-Host "[env] Everything found at: $everythingPath"
} else {
  Write-Warning "[env] Everything not found at expected path: $everythingPath"
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

Write-Host "[build] flutter pub get"
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

  Write-Host "[build] building izzy arm64 release apk"
  & $flutter build apk `
    --flavor izzy `
    -t lib/main_izzy.dart `
    --target-platform android-arm64 `
    --release

  Write-Host "[done] output:"
  Write-Host "android\app\build\outputs\flutter-apk\app-arm64-v8a-izzy-release.apk"
} finally {
  if (Test-Path -LiteralPath $lockBackupPath) {
    Move-Item -LiteralPath $lockBackupPath -Destination $lockPath -Force
    Write-Host "[clean] restored pubspec.lock from backup"
  }
}
