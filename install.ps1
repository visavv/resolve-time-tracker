# Installs Time Tracker into DaVinci Resolve's Workspace > Scripts menu.
$ErrorActionPreference = 'Stop'
if (-not $env:APPDATA) { throw 'APPDATA is not set; this installer requires Windows.' }
$dest = "$env:APPDATA\Blackmagic Design\DaVinci Resolve\Support\Fusion\Scripts\Utility"
if (-not (Test-Path -LiteralPath $dest)) { New-Item -ItemType Directory -Force -Path $dest | Out-Null }
Copy-Item -LiteralPath (Join-Path $PSScriptRoot "Time Tracker.lua") -Destination $dest -Force
Write-Host "Installed to: $dest"
Write-Host 'Close any existing tracker window, then reopen Workspace > Scripts > Time Tracker.'
Write-Host 'If the menu entry is missing, restart Resolve. Existing tracking data is preserved.'
