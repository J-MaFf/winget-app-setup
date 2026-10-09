# Winget launch helpers. winget.exe can fail to start when its per-user alias is broken or locked,
# most often while App Installer is being upgraded or re-registered. These classify a failed launch
# and check, with one bounded `winget --version`, whether winget can be started at all, which
# Invoke-WingetInstall uses as a circuit breaker for the remaining apps.

<#
.SYNOPSIS
    Returns true when a winget launch failed for a transient reason: winget.exe briefly
    inaccessible (issues #253, #258).
.DESCRIPTION
    Transient: ERROR_CANT_ACCESS_FILE (1920) and ERROR_SHARING_VIOLATION (32). Anything else, such
    as winget missing from PATH, is not worth a retry. -NativeErrorCode decides when known, since
    it is the same in every display language (P3-6). Otherwise -Message is matched, ignoring case,
    against the English texts, PowerShell's "StandardOutputEncoding is only supported when standard
    output is redirected." for the same broken alias (issue #277), and the two messages as this
    machine words them (Get-Win32ErrorMessage).
.PARAMETER Message
    The exception message to classify.
.PARAMETER NativeErrorCode
    The Win32 error code of the failed launch, when known.
.OUTPUTS
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
    Returns Windows' text for a Win32 error code in this machine's display language, as a failed
    launch's message carries it; $null off Windows, where .NET words the codes as errno values.
.PARAMETER Code
    The Win32 error code.
.OUTPUTS
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
    Returns the winget executable to launch: the one place that decides how winget is found.
.DESCRIPTION
    Normally the bare name 'winget', which resolves on PATH to the account's alias. As SYSTEM, which
    has no alias, the machine-wide winget.exe Test-MachineWingetAvailable found
    ($script:MachineWingetPath, P2-24), looked up again when an App Installer update removed it
    during the run. Launching that winget.exe directly as an administrator fails with 'Access is
    denied', which is why there is no alias bypass (P3-7).
.OUTPUTS
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
    The alias being on PATH proves nothing (P3-9). Launchable means the process started under the
    WingetVersion time limit, exited 0 and printed a version (a line matching '^v\d').

    With -Attempts above 1, a failure that can clear on its own is checked again after
    RetryDelaySeconds: a transient launch failure, a timeout, a non-zero exit or no version. Final
    at once: any other launch failure, 0xC0000135 (STATUS_DLL_NOT_FOUND: a DLL winget.exe needs,
    such as the Visual C++ runtime, is missing) and 0x8A15003A (Group Policy turned winget off).

    Used by Initialize-Winget, by Invoke-WingetInstall's circuit breaker and end-of-run check, and
    by e2e/Assert-Install.ps1. Read-only, so a dry run can use it.
.PARAMETER Attempts
    How many times to check before giving up. Default 1.
.PARAMETER RetryDelaySeconds
    Seconds to wait between checks. Default 10.
.OUTPUTS
    [pscustomobject] with Launchable ([bool]), Version (the version winget printed, or $null),
    Reason (why it is not launchable, for a message; $null when it is), ExitCode (the last check's
    exit code; $null when winget did not start or did not finish) and Attempts (checks made).
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
    # 0xC0000135 STATUS_DLL_NOT_FOUND and 0x8A15003A BLOCKED_BY_POLICY, as the signed Int32 a
    # process exit code is: neither changes by waiting.
    $finalExitCodes = @(-1073741515, -1978335174)
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
            if ($finalExitCodes -contains $run.ExitCode) {
                $retryable = $false
            }
        }
        else {
            $versionLine = @($run.StandardOutput | ForEach-Object { "$_".Trim() } | Where-Object { $_ -match '^v\d' }) | Select-Object -First 1
            if ($versionLine) {
                return [pscustomobject]@{ Launchable = $true; Version = $versionLine; Reason = $null; ExitCode = 0; Attempts = $attempt }
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
    return [pscustomobject]@{ Launchable = $false; Version = $null; Reason = $reason; ExitCode = $run.ExitCode; Attempts = [Math]::Min($attempt, $Attempts) }
}
