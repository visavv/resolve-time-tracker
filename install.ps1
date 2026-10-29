# Installs Time Tracker into DaVinci Resolve's Workspace > Scripts menu.
#
#   .\install.ps1                   install; asks whether to open it automatically
#   .\install.ps1 -Autostart        install and open it whenever Resolve opens a project
#   .\install.ps1 -NoAutostart      install without asking
#   .\install.ps1 -RemoveAutostart  stop opening it automatically (keeps the script)
param([switch]$Autostart, [switch]$NoAutostart, [switch]$RemoveAutostart)
$ErrorActionPreference = 'Stop'
if (-not $env:APPDATA) { throw 'APPDATA is not set; this installer requires Windows.' }

# The helper lives next to the tracker's data, outside AppData: Windows
# redirects new AppData folders created from packaged (MSIX) apps into the
# app's private storage, where Task Scheduler cannot find them.
$helperDir = Join-Path $env:USERPROFILE '.resolve_time_tracker\autostart'
$helper = Join-Path $helperDir 'TimeTracker-Autostart.ps1'
$taskName = 'Time Tracker for DaVinci Resolve'
# 1.1.0 kept the helper in %LOCALAPPDATA% and started it from a Startup-folder
# shortcut. Both are removed whenever auto-open is set up or turned off.
$oldShortcut = Join-Path ([Environment]::GetFolderPath('Startup')) 'Time Tracker for DaVinci Resolve.lnk'
$oldHelper = Join-Path $env:LOCALAPPDATA 'ResolveTimeTracker\TimeTracker-Autostart.ps1'

function Stop-Helper {
    # The helper owns no windows, so stopping it never affects an open tracker.
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -like '*TimeTracker-Autostart.ps1*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Remove-AutostartEntries {
    Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue |
        Unregister-ScheduledTask -Confirm:$false
    if (Test-Path -LiteralPath $oldShortcut) { Remove-Item -LiteralPath $oldShortcut -Force }
    if (Test-Path -LiteralPath $oldHelper) { Remove-Item -LiteralPath $oldHelper -Force }
}

if ($RemoveAutostart) {
    Remove-AutostartEntries
    Stop-Helper
    if (Test-Path -LiteralPath $helper) { Remove-Item -LiteralPath $helper -Force }
    Write-Host 'Time Tracker will no longer open automatically. The script itself is still installed.'
    return
}

$dest = "$env:APPDATA\Blackmagic Design\DaVinci Resolve\Support\Fusion\Scripts\Utility"
if (-not (Test-Path -LiteralPath $dest)) { New-Item -ItemType Directory -Force -Path $dest | Out-Null }
Copy-Item -LiteralPath (Join-Path $PSScriptRoot "Time Tracker.lua") -Destination $dest -Force
Write-Host "Installed to: $dest"

# Right-click > Run with PowerShell passes no switches: ask, and keep the
# window open at the end so the result can be read. Never block a scripted run.
$asked = $false
$nonInteractive = [Environment]::GetCommandLineArgs() -match '^-NonI'
if (-not $Autostart -and -not $NoAutostart -and [Environment]::UserInteractive -and -not $nonInteractive) {
    $asked = $true
    try {
        $answer = Read-Host 'Open Time Tracker automatically whenever DaVinci Resolve opens a project? (Resolve Studio) [y/N]'
        $Autostart = $answer -match '^\s*y'
    }
    catch { $asked = $false }
}

$helperSource = Join-Path $PSScriptRoot 'autostart\TimeTracker-Autostart.ps1'
if ($Autostart -and -not (Test-Path -LiteralPath $helperSource)) {
    # Checked before touching a running helper, so a partial download changes nothing.
    Write-Host "Auto-open needs $helperSource. Download the full release zip and run install.ps1 from it."
    $Autostart = $false
}

if ($Autostart) {
    Remove-AutostartEntries
    Stop-Helper
    New-Item -ItemType Directory -Force -Path $helperDir | Out-Null
    Copy-Item -LiteralPath $helperSource -Destination $helper -Force

    # A per-user scheduled task: started at sign-in, and checked every 5
    # minutes so the helper comes back if it is ever not running. A running
    # helper keeps the task busy, so the check never starts a second copy.
    # conhost --headless runs PowerShell with no window at all, even when
    # Windows Terminal is the default terminal.
    $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $action = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\conhost.exe') `
        -Argument "--headless `"$powershell`" -NoProfile -ExecutionPolicy Bypass -File `"$helper`""
    $atLogon = New-ScheduledTaskTrigger -AtLogOn -User $user
    $everyFive = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
        -RepetitionInterval (New-TimeSpan -Minutes 5)
    $taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Seconds 0)
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $atLogon, $everyFive `
        -Settings $taskSettings -Principal $principal `
        -Description 'Opens Time Tracker when DaVinci Resolve opens a project' | Out-Null
    Start-ScheduledTask -TaskName $taskName
    Write-Host 'Auto-open is on: the tracker opens whenever Resolve opens a project, also after a reboot.'
    Write-Host 'Needs Resolve Studio with Preferences > System > General > External scripting using: Local.'
    Write-Host 'To turn it off: .\install.ps1 -RemoveAutostart'
}

Write-Host 'Close any existing tracker window, then reopen Workspace > Scripts > Time Tracker.'
Write-Host 'If the menu entry is missing, restart Resolve. Existing tracking data is preserved.'
if ($asked) { Read-Host 'Done. Press Enter to close' | Out-Null }
