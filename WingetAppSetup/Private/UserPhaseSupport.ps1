# The user phase's state (work-order item 34). A run for the whole PC (as SYSTEM, from an RMM agent
# such as ManageEngine Endpoint Central) records in last-run.json the apps it deferred to the
# signed-in user's own account. Invoke-WingetUserPhase, run as each user at sign-in, installs those
# for that user and sets the user's Windows Terminal defaults, once per machine run: it keeps what
# it did in the user's own user-phase.json. rmm/Invoke-WingetAppSetupUserPhase.ps1 makes the same
# decision before it downloads anything (Test-RmmUserPhasePending), so the rule in
# Get-UserPhaseDecision and that function must stay the same.

<#
.SYNOPSIS
    Returns the path of the machine's run record: %ProgramData%\winget-app-setup\logs\last-run.json.
.RETURNS
    [string]
#>
function Get-InstallerRunRecordPath {
    return (Join-Path $env:ProgramData 'winget-app-setup\logs\last-run.json')
}

<#
.SYNOPSIS
    Returns the path of this account's user-phase state: %LOCALAPPDATA%\winget-app-setup\user-phase.json.
.RETURNS
    [string]
#>
function Get-UserPhaseStatePath {
    return (Join-Path $env:LOCALAPPDATA 'winget-app-setup\user-phase.json')
}

<#
.SYNOPSIS
    Returns the SHA256 of some bytes as upper-case hex, the form Get-FileHash prints.
.PARAMETER Bytes
    The bytes.
.RETURNS
    [string]
#>
function Get-Sha256Hex {
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]]$Bytes
    )

    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-', '')
    }
    finally {
        $algorithm.Dispose()
    }
}

<#
.SYNOPSIS
    Reads the machine's run record (last-run.json) for the user phase.
.DESCRIPTION
    The file is read once, and its SHA256 identifies the machine run: a run replaces the file when it
    starts (exitCode null, Save-InstallerRunStartRecord) and once more when it reports
    (Write-InstallerRunResult), and nothing else writes it, so the hash of a finished run's record
    changes only when another run replaces it.

    The deferred apps are the entries with status 'Deferred', whatever deferred them: a run for the
    whole PC that found no machine-wide installer, or a catalog entry that says the app is per-user.
    The record is the contract, not the catalog. An id that is not a valid winget package id
    (Test-WingetPackageIdFormat) is left out and listed in InvalidDeferredIds: the file is only
    writable by administrators and SYSTEM, but its ids end up on a winget command line.

    Returns $null, with a warning, when the file cannot be read or is not a run record (no apps
    list), and $null, silently, when there is no file. Never throws.
.PARAMETER Path
    The record's path (Get-InstallerRunRecordPath).
.RETURNS
    [pscustomobject] with Path, Sha256, BuildId, StartedUtc, ExitCode ([int], or $null while the run
    has not reported), DeferredApps ([string[]], in record order, each once) and InvalidDeferredIds
    ([string[]]); or $null.
#>
function Read-InstallerRunRecord {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes).TrimStart([char]0xFEFF)
        $record = ConvertFrom-Json -InputObject $text -ErrorAction Stop
    }
    catch {
        Write-WarningMessage "Could not read the run record ${Path}: $($_.Exception.Message)"
        return $null
    }
    if ($null -eq $record -or $null -eq $record.PSObject.Properties['apps']) {
        Write-WarningMessage "The run record $Path has no apps list; ignoring it."
        return $null
    }

    $deferred = @()
    $invalid = @()
    foreach ($app in @($record.apps)) {
        if ($null -eq $app -or [string]$app.status -ne 'Deferred') {
            continue
        }
        $id = [string]$app.id
        if (-not (Test-WingetPackageIdFormat -PackageId $id)) {
            $invalid += $id
        }
        elseif ($deferred -notcontains $id) {
            $deferred += $id
        }
    }

    $exitCode = $null
    if ($null -ne $record.exitCode) {
        $exitCode = [int]$record.exitCode
    }
    # ConvertFrom-Json in PowerShell 7 turns an ISO 8601 string into a DateTime; the record's own
    # form is kept for messages.
    $startedUtc = $null
    if ($record.startedUtc -is [DateTime]) {
        $startedUtc = Format-RunRecordTime -Time $record.startedUtc
    }
    elseif ($null -ne $record.startedUtc) {
        $startedUtc = [string]$record.startedUtc
    }
    $buildId = $null
    if ($record.buildId) {
        $buildId = [string]$record.buildId
    }

    return [pscustomobject]@{
        Path               = $Path
        Sha256             = Get-Sha256Hex -Bytes $bytes
        BuildId            = $buildId
        StartedUtc         = $startedUtc
        ExitCode           = $exitCode
        DeferredApps       = [string[]]$deferred
        InvalidDeferredIds = [string[]]$invalid
    }
}

<#
.SYNOPSIS
    Reads this account's user-phase state, or $null when there is none or it cannot be read.
.PARAMETER Path
    The state file (Get-UserPhaseStatePath).
.RETURNS
    [pscustomobject] with RecordSha256 ([string]), Complete ([bool]) and Attempts ([int]); or $null.
    Never throws: a state that cannot be read counts as none, so the user phase runs again.
#>
function Read-UserPhaseState {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    try {
        $state = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($Path)) -ErrorAction Stop
    }
    catch {
        Write-WarningMessage "Could not read the user-phase state ${Path}: $($_.Exception.Message)"
        return $null
    }
    if ($null -eq $state) {
        return $null
    }
    $attempts = 0
    if ($null -ne $state.attempts) {
        $attempts = [int]$state.attempts
    }
    return [pscustomobject]@{
        RecordSha256 = [string]$state.recordSha256
        Complete     = ($state.complete -eq $true)
        Attempts     = $attempts
    }
}

<#
.SYNOPSIS
    Decides whether the user phase has work for this account.
.DESCRIPTION
    No work (Run false), so the user phase ends at once and prints nothing, when:
      - NoRecord: there is no run record (no run for the whole PC happened, or it cannot be read);
      - RunNotFinished: the run has not reported yet (exitCode null): it is still going, or it was
        killed, and a later run replaces the record;
      - Done: this account's state is for this run (same record SHA256) and says it is complete;
      - GaveUp: this account already tried MaxAttempts times for this run.
    Otherwise there is work: New (first time for this run) or Pending (an earlier attempt left
    something), and Attempt is this attempt's number. A run with nothing deferred still has work
    once per account: the Windows Terminal defaults, which a run as SYSTEM never sets for anyone.

    rmm/Invoke-WingetAppSetupUserPhase.ps1 (Test-RmmUserPhasePending) applies the same rule before
    it downloads the installer; tests/RmmWrapper.Tests.ps1 checks that the two agree.
.PARAMETER Record
    Read-InstallerRunRecord's result, or $null.
.PARAMETER State
    Read-UserPhaseState's result, or $null.
.PARAMETER MaxAttempts
    How many times to try for one run before giving up.
.RETURNS
    [pscustomobject] with Run ([bool]), Reason and Attempt ([int], 0 when there is no work).
#>
function Get-UserPhaseDecision {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Record,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$State,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 100)]
        [int]$MaxAttempts
    )

    if ($null -eq $Record) {
        return [pscustomobject]@{ Run = $false; Reason = 'NoRecord'; Attempt = 0 }
    }
    if ($null -eq $Record.ExitCode) {
        return [pscustomobject]@{ Run = $false; Reason = 'RunNotFinished'; Attempt = 0 }
    }
    if ($null -ne $State -and [string]::Equals([string]$State.RecordSha256, [string]$Record.Sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
        if ($State.Complete) {
            return [pscustomobject]@{ Run = $false; Reason = 'Done'; Attempt = 0 }
        }
        if ([int]$State.Attempts -ge $MaxAttempts) {
            return [pscustomobject]@{ Run = $false; Reason = 'GaveUp'; Attempt = 0 }
        }
        return [pscustomobject]@{ Run = $true; Reason = 'Pending'; Attempt = [int]$State.Attempts + 1 }
    }
    return [pscustomobject]@{ Run = $true; Reason = 'New'; Attempt = 1 }
}

<#
.SYNOPSIS
    Writes this account's user-phase state, replacing the previous one in one step.
.DESCRIPTION
    Written to a temporary file in the same folder first, then moved over the state file, so a
    sign-in that reads it never sees half a file. The folder is created when needed. A failure warns;
    the user phase then runs again at the next sign-in. Runs under PowerShell 7 (File.Move with
    overwrite), as the user phase does.
.PARAMETER Path
    The state file (Get-UserPhaseStatePath).
.PARAMETER State
    What to write.
.RETURNS
    [string] The path written, or $null.
#>
function Save-UserPhaseState {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$State
    )

    $directory = Split-Path -Parent $Path
    $temporaryPath = Join-Path $directory ('user-phase.{0}.tmp' -f [System.Guid]::NewGuid().ToString('N'))
    try {
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            [void](New-Item -Path $directory -ItemType Directory -Force -ErrorAction Stop)
        }
        $json = ConvertTo-Json -InputObject $State -Depth 6
        [System.IO.File]::WriteAllText($temporaryPath, $json, (New-Object System.Text.UTF8Encoding($false)))
        [System.IO.File]::Move($temporaryPath, $Path, $true)
        return $Path
    }
    catch {
        Write-WarningMessage "Could not write the user-phase state ${Path}: $($_.Exception.Message)"
        try {
            if (Test-Path -LiteralPath $temporaryPath) {
                Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction Stop
            }
        }
        catch {
        }
        return $null
    }
}

<#
.SYNOPSIS
    Installs one deferred app for the signed-in user: per-user scope only, checked before and after.
.DESCRIPTION
    The user phase's form of Install-AppWithVerification. `winget list` run as the user sees both the
    user's own apps and the PC's, so an app already there either way is Skipped. Otherwise it is
    installed with Install-WingetPackage -UserScopeOnly -Silent (`--scope user`, never another
    scope: a machine-wide installer would ask for administrator rights) and checked again. A check
    that could not answer fails the app rather than installing it blind.
.PARAMETER PackageId
    The winget package id.
.PARAMETER TimeoutSeconds
    The install's time limit (what is left of the user phase's time budget, at most 30 minutes).
.RETURNS
    New-AppRunRecord's entry: status Installed, Skipped (already installed) or Failed, with the
    reason and winget's exit code.
#>
function Install-UserPhaseApp {
    param (
        [Parameter(Mandatory = $true)]
        [string]$PackageId,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 86400)]
        [int]$TimeoutSeconds
    )

    $checkTimeoutSeconds = Get-ProcessTimeoutSeconds -Operation WingetListCheck
    $preCheck = Test-WingetPackageInstalled -PackageId $PackageId -TimeoutSeconds $checkTimeoutSeconds
    if ($preCheck.Installed) {
        Write-WarningMessage "Skipping: $PackageId (already installed)"
        return (New-AppRunRecord -Id $PackageId -Status 'Skipped' -Reason 'already installed')
    }
    $preCheckReason = $null
    if ($preCheck.TimedOut) {
        $preCheckReason = 'PreCheckTimeout'
    }
    elseif ($preCheck.LaunchFailed) {
        $preCheckReason = 'PreCheckLaunchFailed'
    }
    elseif ($preCheck.CheckFailed) {
        $preCheckReason = 'PreCheckFailed'
    }
    if ($preCheckReason) {
        $reason = Format-InstallFailureReason -FailureReason $preCheckReason -LaunchError $preCheck.LaunchError -CheckExitCode $preCheck.ExitCode
        Write-ErrorMessage "Failed to install: $PackageId ($reason)."
        return (New-AppRunRecord -Id $PackageId -Status 'Failed' -Reason $reason)
    }

    Write-Info "Installing for this account: $PackageId"
    $installResult = Install-WingetPackage -PackageId $PackageId -UserScopeOnly -Silent -TimeoutSeconds $TimeoutSeconds -InstallInProgressRetries 1 -InstallInProgressWaitSeconds ([Math]::Min(120, $TimeoutSeconds))
    # The user phase never falls back to another scope, so the machine-scope detail would only mislead.
    $reportedResult = $installResult.Clone()
    $reportedResult.Remove('MachineScopeFellBack')

    $failureReason = $null
    $launchError = $null
    $checkExitCode = $null
    $restartRequired = $false
    if ($installResult.LaunchErrorExhausted) {
        $failureReason = 'InstallLaunchFailed'
        $launchError = $installResult.LaunchError
    }
    elseif ($installResult.NoUserScopeInstaller) {
        $failureReason = 'NoUserScopeInstaller'
    }
    else {
        $verify = Test-WingetPackageInstalled -PackageId $PackageId -TimeoutSeconds $checkTimeoutSeconds
        if ($verify.Installed) {
            Write-Success "Successfully installed for this account: $PackageId"
            $restartRequired = [bool](Write-InstalledAppNote -AppName $PackageId -InstallResult $installResult)
            return (New-AppRunRecord -Id $PackageId -Status 'Installed' -InstallResult $installResult -RestartRequired $restartRequired)
        }
        if ($verify.TimedOut) {
            $failureReason = 'VerifyTimeout'
        }
        elseif ($verify.LaunchFailed) {
            $failureReason = 'VerifyLaunchFailed'
            $launchError = $verify.LaunchError
        }
        elseif ($verify.CheckFailed) {
            $failureReason = 'VerifyFailed'
            $checkExitCode = $verify.ExitCode
        }
        else {
            $failureReason = 'VerifyNotFound'
        }
    }
    $reason = Format-InstallFailureReason -FailureReason $failureReason -InstallResult $reportedResult -LaunchError $launchError -CheckExitCode $checkExitCode
    Write-ErrorMessage "Failed to install: $PackageId ($reason)."
    return (New-AppRunRecord -Id $PackageId -Status 'Failed' -Reason $reason -InstallResult $installResult)
}
