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
    # A Resolve path map (resolved by Resolve itself, so a non-ASCII user name
    # never passes through a command line) or a full path for testing.
    [string]$Script = 'Scripts:/Utility/Time Tracker.lua',
    [int]$PollSeconds = 5
)
$ErrorActionPreference = 'Continue'
$MaxLaunchAttempts = 3
$IdlePollSeconds = 60   # once scripting looks unavailable for this Resolve

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
    try {
        $read = $p.StandardOutput.ReadToEndAsync()
        if (-not $p.WaitForExit(20000)) {
            try { $p.Kill() } catch {}
            Write-Log 'scripting call timed out'
            return $null
        }
        return $read.Result
    }
    finally { $p.Dispose() }
}

# fuscript ships next to Resolve.exe. An elevated Resolve hides its path from
# this (non-elevated) helper, so fall back to the default install location.
function Get-Fuscript($resolve) {
    if ($resolve.Path) { return Join-Path (Split-Path -Parent $resolve.Path) 'fuscript.exe' }
    return Join-Path $env:ProgramFiles 'Blackmagic Design\DaVinci Resolve\fuscript.exe'
}

Write-Log "helper started (script: $Script)"
$session = ''          # Resolve process ID + start time: one Resolve session
$done = $false         # tracker opened (or given up on) for $session
$attempts = 0
$since = $null         # when this Resolve session was first seen
$warned = $false
$escapedScript = $Script.Replace(']]', '')  # long-bracket safety; paths never contain ]]

while ($true) {
    $all = @(Get-Process -Name Resolve -ErrorAction SilentlyContinue)
    # Require Resolve's main window: this skips a Resolve that is starting up
    # or stuck without a window, where a tracker would count unseen time.
    $resolve = $all | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero } | Select-Object -First 1
    $delay = $PollSeconds

    if ($all.Count -eq 0) {
        if ($session) { Write-Log 'Resolve closed' }
        $session = ''
    }
    elseif ($resolve) {
        $started = 0
        try { $started = $resolve.StartTime.Ticks } catch {}  # access denied if elevated
        $key = "$($resolve.Id)/$started"
        if ($key -ne $session) {
            $session = $key; $done = $false; $attempts = 0; $since = Get-Date; $warned = $false
        }
        if (-not $done) {
            $fuscript = Get-Fuscript $resolve
            if (-not (Test-Path -LiteralPath $fuscript)) {
                Write-Log "fuscript not found: $fuscript"
                $done = $true
            }
            else {
                # GetCurrentPage is empty while the Project Manager is showing.
                $out = Invoke-Lua $fuscript "local r = bmd.scriptapp('Resolve'); print('TT_PAGE=' .. tostring(r and r:GetCurrentPage()))"
                if ($out -match 'TT_PAGE=(\w+)' -and $Matches[1] -ne 'nil') {
                    $page = $Matches[1]
                    # Run inside Resolve, like the Scripts menu: the tracker belongs
                    # to Resolve and closes with it. If one is already open it just
                    # comes to the front, so retrying is harmless.
                    $run = Invoke-Lua $fuscript ("local f = bmd.scriptapp('Resolve'):Fusion(); " +
                        "local p = f:MapPath([[$escapedScript]]); " +
                        "if bmd.fileexists(p) then f:RunScript([[$escapedScript]]); print('TT_LAUNCHED') " +
                        "else print('TT_MISSING ' .. tostring(p)) end")
                    $attempts++
                    if ($run -match 'TT_LAUNCHED') {
                        Write-Log "opened tracker for Resolve $($resolve.Id) (page: $page)"
                        $done = $true
                    }
                    elseif ($run -match 'TT_MISSING (.+)') {
                        Write-Log "tracker script not installed: $($Matches[1].Trim()). Run install.ps1."
                        $done = $true
                    }
                    elseif ($attempts -ge $MaxLaunchAttempts) {
                        Write-Log "could not open the tracker after $attempts attempts; will try again next Resolve session"
                        $done = $true
                    }
                    else { Write-Log "opening the tracker failed (attempt $attempts); retrying" }
                }
                elseif ((Get-Date) -gt $since.AddMinutes(3)) {
                    if (-not $warned) {
                        Write-Log ('no project visible to scripting after 3 minutes. If a project is open, ' +
                            'set Preferences > System > General > External scripting using: Local (Resolve Studio)')
                        $warned = $true
                    }
                    $delay = $IdlePollSeconds
                }
            }
        }
    }
    Start-Sleep -Seconds $delay
}
