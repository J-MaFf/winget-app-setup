# Winget launch resilience helpers (issues #258, #277). Start-Process (or PowerShell's own native
# command invocation) can fail to launch winget.exe at all when the per-user app-execution alias
# under %LOCALAPPDATA%\Microsoft\WindowsApps is broken or locked - most commonly because the
# Microsoft.DesktopAppInstaller MSIX package is being upgraded or re-registered at that moment (e.g.
# by a Winget-AutoUpdate run, whose Install-Prerequisites re-provisions App Installer; the installer
# no longer starts one mid-run - RUN_WAU=YES was removed). These helpers classify that failure,
# resolve a concrete winget.exe path that bypasses the alias entirely so retries can recover instead
# of hammering the same broken reparse point, and wait out the window in one place.

<#
.SYNOPSIS
    Returns true when a winget launch failed for a transient reason.
.DESCRIPTION
    The transient class is winget.exe's own file being briefly inaccessible (issues #253/#258):
    ERROR_CANT_ACCESS_FILE (1920, "The file cannot be accessed by the system.") and
    ERROR_SHARING_VIOLATION (32, "...being used by another process."). Anything else (e.g. winget
    genuinely missing from PATH) is a real failure the caller should not retry.

    Invoke-ExternalProcess reports the Win32 error code of a failed launch, and -NativeErrorCode
    classifies by that code, which is the same in every display language (review finding P3-6).
    Without a code, -Message is matched instead: against the English texts, against the
    "StandardOutputEncoding is only supported when standard output is redirected." message
    PowerShell's native-command invocation throws for the same broken alias (issue #277), and
    against the two Win32 messages as this machine words them (Get-Win32ErrorMessage), so a German
    "Das System kann auf die Datei nicht zugreifen" matches too. All matching ignores case.
.PARAMETER Message
    The exception message to classify.
.PARAMETER NativeErrorCode
    The Win32 error code of the failed launch, when known.
.RETURNS
    [bool]
#>
function Test-TransientWingetLaunchError {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[int]]$NativeErrorCode
    )

    # ERROR_SHARING_VIOLATION and ERROR_CANT_ACCESS_FILE.
    $transientCodes = @(32, 1920)
    if ($null -ne $NativeErrorCode -and $transientCodes -contains $NativeErrorCode) {
        return $true
    }
    if ([string]::IsNullOrWhiteSpace($Message)) {
        return $false
    }
    if ($Message -match 'cannot be accessed by the system|being used by another process|StandardOutputEncoding is only supported when standard output is redirected') {
        return $true
    }
    foreach ($code in $transientCodes) {
        $localized = "$(Get-Win32ErrorMessage -Code $code)".Trim().TrimEnd('.')
        if ($localized.Length -gt 0 -and $Message.IndexOf($localized, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return $true
        }
    }
    return $false
}

<#
.SYNOPSIS
    Returns the text Windows gives a Win32 error code, in this machine's display language.
.DESCRIPTION
    The message Start-Process embeds when it cannot launch a program comes from the same Windows
    message table (FormatMessage), so matching against it works in any display language (review
    finding P3-6). Off Windows the .NET runtime words error codes as errno values, which mean
    something else, so nothing is returned there.
.PARAMETER Code
    The Win32 error code.
.RETURNS
    [string] The message, or $null off Windows.
#>
function Get-Win32ErrorMessage {
    param (
        [Parameter(Mandatory = $true)]
        [int]$Code
    )

    if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
        return $null
    }
    return (New-Object System.ComponentModel.Win32Exception($Code)).Message
}

<#
.SYNOPSIS
    Returns the distinct Microsoft.DesktopAppInstaller versions currently registered, when more
    than one is present at once.
.DESCRIPTION
    Normally exactly one Microsoft.DesktopAppInstaller (winget) version is registered. Two GitHub-
    hosted E2E runs (issue #279) observed a structural deadlock instead: a second version appeared
    mid-job alongside the already-working one, and neither could finish registering - the newer
    version failed because it depends on a framework (Microsoft.WindowsAppRuntime.1.8 as of this
    writing) not present on the runner, and the older version was then rejected by AppX because the
    newer one is "already installed". The newer version came from Winget-AutoUpdate's own
    Install-Prerequisites, which provisions the latest winget release from GitHub without the
    WindowsAppRuntime framework it needs; the installer used to start that WAU run itself
    (RUN_WAU=YES, now removed). The runner image only made it permanent by lacking the framework.

    Unlike the transient app-execution-alias breakage Wait-WingetLaunchable and
    Install-WingetPackage retry through, this is a structural conflict between two package versions
    that no amount of waiting or retrying resolves - the same wedged state is still there minutes
    later. Callers use this to recognize that case and fail fast with a clear diagnostic instead of
    burning a full retry budget (or, per app, N retry budgets) against a dead end.
.RETURNS
    [string[]] The distinct version strings found. Empty when zero or exactly one version is
    present (the healthy case, or winget not present/queryable at all). Two or more entries means a
    conflict.
#>
function Get-ConflictingDesktopAppInstallerVersions {
    try {
        $versions = @(Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -ErrorAction Stop |
                Select-Object -ExpandProperty Version -Unique)
    }
    catch {
        # Get-AppxPackage can fail under PowerShell 7 when the Appx compatibility session is
        # unavailable (same caveat Resolve-WingetExecutable documents) - nothing conclusive to
        # report either way, so treat it the same as "nothing found".
        return @()
    }
    if ($versions.Count -le 1) {
        return @()
    }
    return $versions
}

<#
.SYNOPSIS
    Resolves the winget executable to launch, optionally bypassing the app-execution alias.
.DESCRIPTION
    By default returns the bare command name 'winget', which Invoke-ExternalProcess resolves through
    PATH to the per-user app-execution alias - the fast path that works whenever winget is healthy.

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
    A Winget-AutoUpdate (WAU) run was observed (issue #277) to hold the per-user app-execution
    alias - or the DesktopAppInstaller package's files themselves - in a broken/inaccessible state
    for several minutes (up to ~5.5 minutes across two GitHub-hosted E2E runs), far longer than the
    75s budget Install-WingetPackage's own launch retries cover for a single package (issue #258).
    The installer used to start such a run itself (RUN_WAU=YES, now removed). Invoke-WingetInstall
    now calls this once, briefly, as its end-of-run health check, so a run cannot exit 0 while
    leaving winget unusable; e2e/Assert-Install.ps1 calls it before its own winget checks.

    Polls with a cheap `winget --version` launch (Start-Process, output discarded) rather than
    sleeping a fixed duration, so a machine where WAU's run finishes quickly is not held up
    unnecessarily. Each attempt re-resolves the executable, bypassing the alias after the first
    launch exception — the same pattern Install-WingetPackage's own launch retries use. Each probe
    is itself bounded by ProbeTimeoutSeconds and killed if it hangs, the same WaitForExit/Kill
    pattern every other timeout-guarded winget call in this module uses (e.g.
    Invoke-WingetSourceProbe) — otherwise a probe that launches but never returns would block this
    function past TimeoutSeconds indefinitely, since that deadline is only checked between attempts.

    Requires RequiredConsecutiveSuccesses probes in a row, PollIntervalSeconds apart, before
    declaring winget launchable - not just one (issue #277 follow-up; written when the installer
    still started WAU immediately). A single success right after a WAU install did not prove the
    danger window had passed: Task
    Scheduler dispatching WAU's immediate run, and WAU's own startup, are not instantaneous, so a
    probe run in that gap can see winget healthy moments before WAU's own winget calls actually
    start breaking it. A live PR run observed exactly this: the very first probe succeeded within
    ~0.5s of the WAU install finishing, but a completely separate process attempting its own winget
    calls ~17s later hit the full lock. Requiring the probe to stay healthy across more than one
    check, spaced apart, catches that case instead of declaring victory in a lull.
.PARAMETER TimeoutSeconds
    Maximum time to keep polling before giving up. Default 360 (6 minutes) — comfortably past the
    longest lock window observed so far.
.PARAMETER PollIntervalSeconds
    Seconds to wait between polls - both after a failure and between the confirming probes
    RequiredConsecutiveSuccesses needs. Default 20.
.PARAMETER ProbeTimeoutSeconds
    Maximum seconds to wait for a single `winget --version` probe before killing it and counting
    that attempt as still-unlaunchable. Default 30 — generous for a command that does no network or
    source I/O.
.PARAMETER RequiredConsecutiveSuccesses
    How many probes in a row must succeed before winget is declared launchable. Default 2, so a
    momentary gap before the real interference begins doesn't read as "all clear".
.RETURNS
    [bool] True once winget has launched and exited successfully RequiredConsecutiveSuccesses
    times in a row. A probe that exits non-zero counts as a failure (a winget that starts but
    cannot run is not usable); a $null exit code - PowerShell occasionally cannot read one from a
    Start-Process object - is treated as success rather than reporting a healthy winget as broken.
    False if it never reached that streak before TimeoutSeconds elapsed, or if a launch attempt
    failed with something other than the known transient class (e.g. winget genuinely missing).
    Best-effort either way: callers keep their own retry/backoff paths as a fallback, this just
    makes hitting them far less likely.
#>
function Wait-WingetLaunchable {
    param (
        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 360,

        [Parameter(Mandatory = $false)]
        [int]$PollIntervalSeconds = 20,

        [Parameter(Mandatory = $false)]
        [int]$ProbeTimeoutSeconds = 30,

        [Parameter(Mandatory = $false)]
        [int]$RequiredConsecutiveSuccesses = 2
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $bypassAlias = $false
    $consecutiveSuccesses = 0

    while ($true) {
        $tempSuffix = [System.IO.Path]::GetRandomFileName()
        $stdoutFile = Join-Path $env:TEMP "winget_launch_probe_output_$tempSuffix.txt"
        $stderrFile = Join-Path $env:TEMP "winget_launch_probe_error_$tempSuffix.txt"
        $succeeded = $false
        try {
            $wingetExecutable = Resolve-WingetExecutable -BypassAlias:$bypassAlias
            $probeProcess = Start-Process -FilePath $wingetExecutable -ArgumentList '--version' -NoNewWindow -PassThru -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
            if ($probeProcess.WaitForExit($ProbeTimeoutSeconds * 1000)) {
                $probeExitCode = $probeProcess.ExitCode
                $succeeded = ($null -eq $probeExitCode) -or ($probeExitCode -eq 0)
            }
            else {
                # Launched but never returned - kill it and fall through to the same retry path as
                # a launch exception; not necessarily an alias problem, so bypassAlias is left as-is.
                try { $probeProcess.Kill() } catch { }
            }
        }
        catch {
            # Same exemption Install-WingetPackage documents (issue #258): once probing a concrete
            # bypass path (not the bare alias), the DesktopAppInstaller upgrade in flight can delete
            # that exact package version between resolving it and launching it, surfacing as
            # ERROR_FILE_NOT_FOUND - not one of Test-TransientWingetLaunchError's classes - rather
            # than a file-lock error. On the bare alias an unrecognized error might mean winget is
            # genuinely missing and is worth surfacing; on a bypass path it's presumed to be the
            # same upgrade race, so re-resolve and keep polling instead of giving up early.
            if (-not (Test-TransientWingetLaunchError -Message $_.Exception.Message) -and -not $bypassAlias) {
                return $false
            }
            $bypassAlias = $true
        }
        finally {
            Remove-Item $stdoutFile -ErrorAction SilentlyContinue
            Remove-Item $stderrFile -ErrorAction SilentlyContinue
        }

        if ($succeeded) {
            $consecutiveSuccesses++
            if ($consecutiveSuccesses -ge $RequiredConsecutiveSuccesses) {
                return $true
            }
        }
        else {
            $consecutiveSuccesses = 0
            # A structural version conflict (issue #279) never clears - no point burning the rest
            # of the budget polling into it. Checked only on a failed attempt, since this is an
            # explanation for failure, not a routine cost every healthy probe should pay.
            $conflictingVersions = Get-ConflictingDesktopAppInstallerVersions
            if ($conflictingVersions.Count -gt 1) {
                Write-WarningMessage "winget is deadlocked between $($conflictingVersions.Count) conflicting DesktopAppInstaller versions ($($conflictingVersions -join ', ')) - a structural AppX conflict outside this installer's control, not a transient lock. Giving up early instead of polling the rest of the wait budget; see issue #279."
                return $false
            }
        }

        if ((Get-Date) -ge $deadline) {
            return $false
        }
        Start-Sleep -Seconds $PollIntervalSeconds
    }
}
