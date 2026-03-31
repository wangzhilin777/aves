param(
  [switch]$All
)

$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")

$flutter = ".\.flutter\bin\flutter.bat"
if (!(Test-Path -LiteralPath $flutter)) {
  throw "Flutter not found at $flutter"
}

function Get-AnalyzeTargets {
  if ($All) {
    return @("lib", "plugins")
  }

  $statusLines = git status --porcelain
  if (-not $statusLines) {
    return @("lib/widgets/settings/remote", "lib/widgets/common/thumbnail/decorated.dart")
  }

  $targets = @()
  foreach ($line in $statusLines) {
    if ($line.Length -lt 4) { continue }
    $path = $line.Substring(3).Trim()
    if ($path.EndsWith(".dart")) {
      $targets += $path
    }
  }

  if ($targets.Count -eq 0) {
    return @("lib/widgets/settings/remote", "lib/widgets/common/thumbnail/decorated.dart")
  }
  return @($targets | Select-Object -Unique)
}

$targets = Get-AnalyzeTargets
Write-Host "[verify] targets:"
$targets | ForEach-Object { Write-Host "  - $_" }

& $flutter analyze $targets

Write-Host "[verify] done"
