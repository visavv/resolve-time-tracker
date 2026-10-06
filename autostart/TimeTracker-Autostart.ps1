# Opens Time Tracker automatically whenever DaVinci Resolve opens a project.
#
# Resolve has no "run this script at startup" hook, so this small helper runs
# hidden from your Windows Startup folder (install.ps1 -Autostart sets it up).
# It waits for Resolve to show a project, then asks Resolve to run the tracker
# exactly as Workspace > Scripts would, once per Resolve session. If you close
# the tracker window, it stays closed until Resolve is restarted.
#
# Requires DaVinci Resolve Studio with
#   Preferences > System > General > External scripting using: Local
# Log: %LOCALAPPDATA%\ResolveTimeTracker\autostart.log
param(
    [string]$Script = "$env:APPDATA\Blackmagic Design\DaVinci Resolve\Support\Fusion\Scripts\Utility\Time Tracker.lua",
    [int]$PollSeconds = 5
)
$ErrorActionPreference = 'Continue'

$stateDir = Join-Path $env:LOCALAPPDATA 'ResolveTimeTracker'
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
$logFile = Join-Path $stateDir 'autostart.log'
function Write-Log([string]$message) {
    if ((Test-Path -LiteralPath $logFile) -and (Get-Item -LiteralPath $logFile).Length -gt 256KB) {
        Move-Item -LiteralPath $logFile -Destination "$logFile.old" -Force
    }
    Add-Content -LiteralPath $logFile -Value "$(Get-Date -Format s) $message"
}

# One helper per Windows session, however many times it is started.
$mutex = New-Object System.Threading.Mutex($false, 'Local\ResolveTimeTrackerAutostart')
if (-not $mutex.WaitOne(0)) { exit 0 }

# Runs a short Lua snippet through fuscript without a console window and
# returns its output, or $null if it did not finish in time. These snippets
# never open UI, so stopping a stuck one cannot strand a script window.
function Invoke-Lua([string]$fuscript, [string]$code) {
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $fuscript
    $info.Arguments = "-l lua -x `"$code`""
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $p = [System.Diagnostics.Process]::Start($info)
    $read = $p.StandardOutput.ReadToEndAsync()
    if (-not $p.WaitForExit(20000)) {
        try { $p.Kill() } catch {}
        Write-Log 'scripting call timed out'
        return $null
    }
    return $read.Result
}

Write-Log "helper started (script: $Script)"
$launchedFor = 0      # Resolve process ID the tracker was opened for
$warnedNoProject = $false

while ($true) {
    # Require Resolve's main window: this skips a Resolve that is starting up
    # or stuck without a window, where a tracker would count unseen time.
    $resolve = Get-Process -Name Resolve -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } | Select-Object -First 1

    if (-not (Get-Process -Name Resolve -ErrorAction SilentlyContinue)) {
        if ($launchedFor) { Write-Log 'Resolve closed' }
        $launchedFor = 0
        $warnedNoProject = $false
    }
    elseif ($resolve -and $resolve.Id -ne $launchedFor) {
        $fuscript = Join-Path (Split-Path -Parent $resolve.Path) 'fuscript.exe'
        if (-not (Test-Path -LiteralPath $Script) -or -not (Test-Path -LiteralPath $fuscript)) {
            Write-Log "not found: $(if (Test-Path -LiteralPath $Script) { $fuscript } else { $Script })"
            $launchedFor = $resolve.Id
        }
        else {
            # GetCurrentPage is empty while the Project Manager is showing.
            $out = Invoke-Lua $fuscript "local r = bmd.scriptapp('Resolve'); print('TT_PAGE=' .. tostring(r and r:GetCurrentPage()))"
            if ($out -match 'TT_PAGE=(\w+)' -and $Matches[1] -ne 'nil') {
                $page = $Matches[1]
                # Run inside Resolve, like the Scripts menu: the tracker belongs
                # to Resolve and closes with it. A tracker that is already open
                # just comes to the front.
                $run = Invoke-Lua $fuscript "bmd.scriptapp('Resolve'):Fusion():RunScript([[$Script]]); print('TT_LAUNCHED')"
                $launchedFor = $resolve.Id
                if ($run -match 'TT_LAUNCHED') { Write-Log "opened tracker for Resolve $($resolve.Id) (page: $page)" }
                else { Write-Log 'asking Resolve to run the tracker failed' }
            }
            elseif (-not $warnedNoProject -and $resolve.StartTime -lt (Get-Date).AddMinutes(-3)) {
                Write-Log ('no project visible to scripting after 3 minutes. If a project is open, ' +
                    'set Preferences > System > General > External scripting using: Local (Resolve Studio)')
                $warnedNoProject = $true
            }
        }
    }
    Start-Sleep -Seconds $PollSeconds
}
