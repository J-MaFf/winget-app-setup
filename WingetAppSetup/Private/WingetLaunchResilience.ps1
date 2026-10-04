# Winget launch helpers (issues #258, #277, review findings P2-8, P3-7, P3-9, P3-10). winget.exe can
# fail to start at all when the per-user app-execution alias under %LOCALAPPDATA%\Microsoft\WindowsApps
# is broken or locked, most often while the Microsoft.DesktopAppInstaller package is being upgraded
# or re-registered (for example by a Winget-AutoUpdate run, whose Install-Prerequisites re-provisions
# App Installer). These helpers classify a failed launch and check, with one bounded
# `winget --version`, whether winget can be started at all. Invoke-WingetInstall uses that check as a
# circuit breaker: once winget cannot be started, the remaining apps fail at once with one reason
# instead of each spending its own retry budget (about 24 minutes on a wedged machine before).

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
    Returns the winget executable to launch.
.DESCRIPTION
    Every winget call goes through Invoke-WingetProcess, which calls this, so it is the one place
    that decides how winget is found:
      - Normally the bare command name 'winget', which Invoke-ExternalProcess resolves on PATH to
        the account's app-execution alias.
      - In a run as SYSTEM, the full path of the machine-wide winget.exe that
        Test-MachineWingetAvailable found and checked at the start of the run
        ($script:MachineWingetPath; review finding P2-24). SYSTEM has no alias: winget cannot be
        registered for it. When that file is gone, because App Installer was updated during the
        run and its old folder removed, the newest machine-wide winget.exe is looked up again.

    There used to be a -BypassAlias switch that launched winget.exe from the DesktopAppInstaller
    package folder under C:\Program Files\WindowsApps when the alias failed (issue #258). It never
    recovered a launch in any E2E run: every direct launch by an administrator account failed with
    'Access is denied', even against a healthy registered package, so it only added retries and
    misleading 'next attempt uses ...' lines (review finding P3-7). It was removed. SYSTEM, unlike
    an administrator account, may start that winget.exe.
.RETURNS
    [string] 'winget', or a full path to winget.exe in a SYSTEM run.
#>
function Resolve-WingetExecutable {
    $machinePath = $script:MachineWingetPath
    if ([string]::IsNullOrWhiteSpace($machinePath)) {
        return 'winget'
    }
    if (-not (Test-Path -LiteralPath $machinePath -PathType Leaf)) {
        $candidate = @(Get-MachineWingetCandidate) | Select-Object -First 1
        if ($candidate) {
            $script:MachineWingetPath = $candidate.Path
            return $candidate.Path
        }
    }
    return $machinePath
}

<#
.SYNOPSIS
    Checks that winget can be started and answers, with a bounded `winget --version`.
.DESCRIPTION
    Get-Command only proves that the app-execution alias is on PATH, not that winget can run: a
    wedged App Installer, a missing framework or an unlicensed package all leave the alias in
    place (review finding P3-9). This runs `winget --version` through Invoke-WingetProcess under
    the WingetVersion time limit and counts it as launchable only when the process started,
    exited 0 and printed a version (a line matching '^v\d', such as 'v1.12.350').

    With -Attempts above 1, a failed check is repeated after RetryDelaySeconds, for failures that
    can clear on their own: a transient launch failure (Test-TransientWingetLaunchError: winget.exe
    locked by an antivirus scan or an App Installer update in progress), a timeout, a non-zero exit
    or no version in the output. Any other launch failure (winget not on PATH, 'Access is denied')
    is final at once: waiting does not change it.

    Used by Test-AndInstallWinget (is winget usable before the run), by Invoke-WingetInstall's
    circuit breaker (after an app could not launch winget) and end-of-run check, and by
    e2e/Assert-Install.ps1. It replaced Wait-WingetLaunchable, whose multi-minute polling and
    consecutive-success streaks existed only to survive the Winget-AutoUpdate run the installer
    used to start mid-run (RUN_WAU=YES, removed; review finding P3-10).

    Runs with nothing but read-only winget calls, so a dry run can use it.
.PARAMETER Attempts
    How many times to check before giving up. Default 1.
.PARAMETER RetryDelaySeconds
    Seconds to wait between checks. Default 10.
.RETURNS
    [pscustomobject] with Launchable ([bool]), Version (the version winget printed, or $null),
    Reason (why it is not launchable, for a message; $null when it is) and Attempts (checks made).
#>
function Test-WingetLaunchable {
    param (
        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 100)]
        [int]$Attempts = 1,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 3600)]
        [int]$RetryDelaySeconds = 10
    )

    $timeoutSeconds = Get-ProcessTimeoutSeconds -Operation WingetVersion
    $reason = $null
    $run = $null
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $run = Invoke-WingetProcess -ArgumentList @('--version') -TimeoutSeconds $timeoutSeconds -Echo None
        $retryable = $true
        if ($run.LaunchFailed) {
            $reason = 'winget could not be started: {0}' -f "$($run.LaunchError)".Trim().TrimEnd('.')
            $retryable = Test-TransientWingetLaunchError -NativeErrorCode $run.LaunchErrorCode -Message $run.LaunchError
        }
        elseif ($run.TimedOut) {
            $reason = "'winget --version' did not answer within $timeoutSeconds seconds and was stopped"
        }
        elseif ($run.ExitCode -ne 0) {
            $reason = "'winget --version' exited with {0}" -f (Format-WingetExitCode -ExitCode $run.ExitCode)
        }
        else {
            $versionLine = @($run.StandardOutput | ForEach-Object { "$_".Trim() } | Where-Object { $_ -match '^v\d' }) | Select-Object -First 1
            if ($versionLine) {
                return [pscustomobject]@{ Launchable = $true; Version = $versionLine; Reason = $null; Attempts = $attempt }
            }
            $reason = "'winget --version' printed no version"
        }

        if (-not $retryable -or $attempt -ge $Attempts) {
            break
        }
        Write-WarningMessage "winget is not usable yet ($reason). Checking again in ${RetryDelaySeconds}s (check $($attempt + 1) of $Attempts)..."
        Start-Sleep -Seconds $RetryDelaySeconds
    }

    # What winget printed, if anything: the reason it gives is the useful part of the transcript.
    if ($run -and -not $run.LaunchFailed -and @($run.Output).Count -gt 0) {
        Write-ProcessOutput -Line $run.Output -Tail 10
    }
    return [pscustomobject]@{ Launchable = $false; Version = $null; Reason = $reason; Attempts = [Math]::Min($attempt, $Attempts) }
}
