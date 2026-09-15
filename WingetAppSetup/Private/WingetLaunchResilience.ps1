# Winget launch resilience helpers (issues #258, #277). Start-Process (or PowerShell's own native
# command invocation) can fail to launch winget.exe at all when the per-user app-execution alias
# under %LOCALAPPDATA%\Microsoft\WindowsApps is broken or locked - most commonly because the
# Microsoft.DesktopAppInstaller MSIX package is being upgraded or re-registered at that moment (e.g.
# by a background Winget-AutoUpdate run, which the installer itself kicks off via RUN_WAU=YES).
# These helpers classify that failure, resolve a concrete winget.exe path that bypasses the alias
# entirely so retries can recover instead of hammering the same broken reparse point, and wait out
# the window in one place right after the RUN_WAU-triggering install so callers further downstream
# don't each have to race it independently.

<#
.SYNOPSIS
    Returns true when a winget-launch exception message indicates a transient failure.
.DESCRIPTION
    Matches the Win32 errors Start-Process surfaces as a terminating exception when winget.exe's own
    file is transiently inaccessible (issues #253/#258): ERROR_CANT_ACCESS_FILE (1920, "The file
    cannot be accessed by the system.") and the sibling ERROR_SHARING_VIOLATION ("...being used by
    another process."). Also matches the message PowerShell's native-command invocation throws for
    the same underlying condition when a caller captures output directly (e.g. `$out = @(winget list
    ... 2>&1)`) instead of going through Start-Process: "StandardOutputEncoding is only supported
    when standard output is redirected." (issue #277) — a .NET Process-class symptom of resolving the
    same broken/mid-registration app-execution alias, just surfaced through a different code path.
    Matched case-insensitively; anything else (e.g. winget genuinely missing from PATH) is a real
    failure the caller should not retry.
.PARAMETER Message
    The exception message to classify.
.RETURNS
    [bool]
#>
function Test-TransientWingetLaunchError {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Message
    )

    return $Message -match 'cannot be accessed by the system|being used by another process|StandardOutputEncoding is only supported when standard output is redirected'
}

<#
.SYNOPSIS
    Resolves the winget executable to launch, optionally bypassing the app-execution alias.
.DESCRIPTION
    By default returns the bare command name 'winget', which Start-Process resolves through PATH to
    the per-user app-execution alias - the fast path that works whenever winget is healthy.

    With -BypassAlias, resolves the real winget.exe inside the registered
    Microsoft.DesktopAppInstaller package's install location instead (the documented workaround for
    contexts where the alias is unusable, e.g. SYSTEM). This matters during a DesktopAppInstaller
    upgrade (issue #258): the alias reparse point can stay broken or locked for the whole
    registration window, while Get-AppxPackage always reports the currently registered package - so
    re-resolving on each retry converges on a launchable executable as soon as the new package
    version lands. Falls back to 'winget' when the package (or its winget.exe) cannot be resolved,
    preserving the prior behavior.
.PARAMETER BypassAlias
    Resolve the concrete winget.exe under the DesktopAppInstaller package install location instead
    of relying on the PATH alias.
.RETURNS
    [string] An absolute path to winget.exe, or the bare command name 'winget'.
#>
function Resolve-WingetExecutable {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$BypassAlias
    )

    if (-not $BypassAlias) {
        return 'winget'
    }

    try {
        # Newest registered version first: mid-upgrade both old and new can briefly be visible, and
        # the newest is the one whose files are guaranteed to exist once registration completes.
        $package = Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -ErrorAction Stop |
            Sort-Object -Property { [version]$_.Version } -Descending |
            Select-Object -First 1
        if ($package -and $package.InstallLocation) {
            $candidate = Join-Path $package.InstallLocation 'winget.exe'
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                return $candidate
            }
        }
    }
    catch {
        # Get-AppxPackage can fail under PowerShell 7 when the Appx compatibility session is
        # unavailable; the alias fallback below keeps the caller's retry loop functional.
    }

    return 'winget'
}

<#
.SYNOPSIS
    Waits for winget.exe to become launchable again, retrying while it hits a transient launch
    failure.
.DESCRIPTION
    Install-WingetAutoUpdate installs Winget-AutoUpdate (WAU) with RUN_WAU=YES, which makes WAU run
    an update pass immediately instead of waiting for its 2 AM schedule. That immediate run's own
    winget invocations were observed (issue #277) to hold the per-user app-execution alias — or the
    DesktopAppInstaller package's files themselves — in a broken/inaccessible state for several
    minutes (up to ~5.5 minutes across two GitHub-hosted E2E runs), far longer than the 75s budget
    Install-WingetPackage's own launch retries cover for a single package (issue #258). Anything that
    touches winget right after Install-WingetAutoUpdate returns — this script's own failed-install
    retry pass a few lines later, a second end-to-end install run, or e2e/Assert-Install.ps1's
    post-install checks — used to race that window on essentially every attempt.

    Polls with a cheap `winget --version` launch (Start-Process, output discarded) rather than
    sleeping a fixed duration, so a machine where WAU's run finishes quickly is not held up
    unnecessarily. Each attempt re-resolves the executable, bypassing the alias after the first
    launch exception — the same pattern Install-WingetPackage's own launch retries use. Each probe
    is itself bounded by ProbeTimeoutSeconds and killed if it hangs, the same WaitForExit/Kill
    pattern every other timeout-guarded winget call in this module uses (e.g.
    Invoke-WingetSourceProbe) — otherwise a probe that launches but never returns would block this
    function past TimeoutSeconds indefinitely, since that deadline is only checked between attempts.
.PARAMETER TimeoutSeconds
    Maximum time to keep polling before giving up. Default 360 (6 minutes) — comfortably past the
    longest lock window observed so far.
.PARAMETER PollIntervalSeconds
    Seconds to wait between polls. Default 15.
.PARAMETER ProbeTimeoutSeconds
    Maximum seconds to wait for a single `winget --version` probe before killing it and counting
    that attempt as still-unlaunchable. Default 30 — generous for a command that does no network or
    source I/O.
.RETURNS
    [bool] True as soon as winget launches successfully. False if it was still unlaunchable when
    TimeoutSeconds elapsed, or if a launch attempt failed with something other than the known
    transient class (e.g. winget genuinely missing). Best-effort either way: callers keep their own
    retry/backoff paths as a fallback, this just makes hitting them far less likely.
#>
function Wait-WingetLaunchable {
    param (
        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 360,

        [Parameter(Mandatory = $false)]
        [int]$PollIntervalSeconds = 15,

        [Parameter(Mandatory = $false)]
        [int]$ProbeTimeoutSeconds = 30
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $bypassAlias = $false

    while ($true) {
        $tempSuffix = [System.IO.Path]::GetRandomFileName()
        $stdoutFile = Join-Path $env:TEMP "winget_launch_probe_output_$tempSuffix.txt"
        $stderrFile = Join-Path $env:TEMP "winget_launch_probe_error_$tempSuffix.txt"
        try {
            $wingetExecutable = Resolve-WingetExecutable -BypassAlias:$bypassAlias
            $probeProcess = Start-Process -FilePath $wingetExecutable -ArgumentList '--version' -NoNewWindow -PassThru -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
            if ($probeProcess.WaitForExit($ProbeTimeoutSeconds * 1000)) {
                return $true
            }
            # Launched but never returned - kill it and fall through to the same retry path as a
            # launch exception; not necessarily an alias problem, so bypassAlias is left as-is.
            try { $probeProcess.Kill() } catch { }
        }
        catch {
            if (-not (Test-TransientWingetLaunchError -Message $_.Exception.Message)) {
                return $false
            }
            $bypassAlias = $true
        }
        finally {
            Remove-Item $stdoutFile -ErrorAction SilentlyContinue
            Remove-Item $stderrFile -ErrorAction SilentlyContinue
        }

        if ((Get-Date) -ge $deadline) {
            return $false
        }
        Start-Sleep -Seconds $PollIntervalSeconds
    }
}
