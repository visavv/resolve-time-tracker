# Installs Time Tracker into DaVinci Resolve's Workspace > Scripts menu.
#
#   .\install.ps1                   install; asks whether to open it automatically
#   .\install.ps1 -Autostart        install and open it whenever Resolve opens a project
#   .\install.ps1 -NoAutostart      install without asking
#   .\install.ps1 -RemoveAutostart  stop opening it automatically (keeps the script)
param([switch]$Autostart, [switch]$NoAutostart, [switch]$RemoveAutostart)
$ErrorActionPreference = 'Stop'
if (-not $env:APPDATA) { throw 'APPDATA is not set; this installer requires Windows.' }

$helperDir = Join-Path $env:LOCALAPPDATA 'ResolveTimeTracker'
$helper = Join-Path $helperDir 'TimeTracker-Autostart.ps1'
$shortcut = Join-Path ([Environment]::GetFolderPath('Startup')) 'Time Tracker for DaVinci Resolve.lnk'
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$helperArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$helper`""

function Stop-Helper {
    # The helper owns no windows, so stopping it never affects an open tracker.
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -like '*TimeTracker-Autostart.ps1*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

if ($RemoveAutostart) {
    Stop-Helper
    if (Test-Path -LiteralPath $shortcut) { Remove-Item -LiteralPath $shortcut -Force }
    if (Test-Path -LiteralPath $helper) { Remove-Item -LiteralPath $helper -Force }
    Write-Host 'Time Tracker will no longer open automatically. The script itself is still installed.'
    return
}

$dest = "$env:APPDATA\Blackmagic Design\DaVinci Resolve\Support\Fusion\Scripts\Utility"
if (-not (Test-Path -LiteralPath $dest)) { New-Item -ItemType Directory -Force -Path $dest | Out-Null }
Copy-Item -LiteralPath (Join-Path $PSScriptRoot "Time Tracker.lua") -Destination $dest -Force
Write-Host "Installed to: $dest"

# Right-click > Run with PowerShell passes no switches: ask, and keep the
# window open at the end so the result can be read.
$asked = $false
if (-not $Autostart -and -not $NoAutostart -and [Environment]::UserInteractive) {
    $asked = $true
    $answer = Read-Host 'Open Time Tracker automatically whenever DaVinci Resolve opens a project? (Resolve Studio) [y/N]'
    $Autostart = $answer -match '^\s*y'
}

if ($Autostart) {
    Stop-Helper
    New-Item -ItemType Directory -Force -Path $helperDir | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'autostart\TimeTracker-Autostart.ps1') -Destination $helper -Force
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut($shortcut)
    $link.TargetPath = $powershell
    $link.Arguments = $helperArgs
    $link.WindowStyle = 7 # minimized; the helper itself runs hidden
    $link.Description = 'Opens Time Tracker when DaVinci Resolve opens a project'
    $link.Save()
    Start-Process -FilePath $powershell -ArgumentList $helperArgs -WindowStyle Hidden
    Write-Host 'Auto-open is on: the tracker opens whenever Resolve opens a project, also after a reboot.'
    Write-Host 'Needs Resolve Studio with Preferences > System > General > External scripting using: Local.'
    Write-Host 'To turn it off: .\install.ps1 -RemoveAutostart'
}

Write-Host 'Close any existing tracker window, then reopen Workspace > Scripts > Time Tracker.'
Write-Host 'If the menu entry is missing, restart Resolve. Existing tracking data is preserved.'
if ($asked) { Read-Host 'Done. Press Enter to close' | Out-Null }
