# The user phase's state. A run as SYSTEM records in last-run.json the apps it deferred to the
# signed-in user; Invoke-WingetUserPhase installs them for each user at sign-in, once per machine run,
# keeping what it did in the user's user-phase.json. rmm/Invoke-WingetAppSetupUserPhase.ps1 makes the
# same decision before it downloads anything, so Get-UserPhaseDecision and Test-RmmUserPhasePending
# must stay the same.

<#
.SYNOPSIS
    Returns the path of the machine's run record: %ProgramData%\winget-app-setup\logs\last-run.json.
.OUTPUTS
    [string]
#>
function Get-InstallerRunRecordPath {
    return (Join-Path $env:ProgramData 'winget-app-setup\logs\last-run.json')
}

<#
.SYNOPSIS
    Returns the path of this account's user-phase state: %LOCALAPPDATA%\winget-app-setup\user-phase.json.
.OUTPUTS
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
.OUTPUTS
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
    Says why the run record may have been written by someone other than SYSTEM or an administrator,
    or returns $null when it cannot have been.
.DESCRIPTION
    The user phase installs what the record lists in every account, so a record a standard user
    could write would let them choose what runs in other users' accounts. Its folder does not rule
    that out (the installer's first, non-elevated launch may have created it, and ProgramData lets
    any user create files), so the file is checked:
      - its owner must be SYSTEM (S-1-5-18) or Administrators (S-1-5-32-544), which a standard user
        cannot make the owner;
      - no entry may let another account write, append, delete, change permissions or take
        ownership (or hold generic write or all rights).
    The installer's own records pass. An account that controls the folder can still delete or
    rename the record, but cannot make one that lists other apps.
.PARAMETER Path
    The record's path.
.OUTPUTS
    [string] What is wrong (for a warning), or $null when the record can be trusted. Never throws:
    an access list that cannot be read is a problem too.
#>
function Get-RunRecordTrustProblem {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $trustedSids = @('S-1-5-18', 'S-1-5-32-544')
    # WriteData, AppendData, Delete, ChangePermissions (WRITE_DAC), TakeOwnership (WRITE_OWNER),
    # GENERIC_ALL and GENERIC_WRITE.
    $changeRights = 0x2 -bor 0x4 -bor 0x10000 -bor 0x40000 -bor 0x80000 -bor 0x10000000 -bor 0x40000000
    try {
        $security = Get-DirectoryAccessSummary -Path $Path
    }
    catch {
        return "its owner and access list could not be read ($($_.Exception.Message))"
    }

    $problems = @()
    if ($trustedSids -notcontains [string]$security.OwnerSid) {
        $problems += "it is owned by $($security.OwnerName) ($($security.OwnerSid)), not by SYSTEM or Administrators"
    }
    foreach ($rule in @($security.AccessRules)) {
        if ($null -eq $rule -or [string]$rule.AccessControlType -ne 'Allow' -or $rule.InheritOnly -or $trustedSids -contains [string]$rule.Sid) {
            continue
        }
        if (([long]$rule.Rights -band $changeRights) -ne 0) {
            $problems += "$($rule.Name) ($($rule.Sid)) can change it"
        }
    }
    if ($problems.Count -eq 0) {
        return $null
    }
    return ($problems -join '; ')
}

<#
.SYNOPSIS
    Reads the machine's run record (last-run.json) for the user phase.
.DESCRIPTION
    Read once; its SHA256 identifies the machine run, since only a run replaces the file (when it
    starts and when it reports). The file is held open against changes while its owner and access
    list are checked (Get-RunRecordTrustProblem), so the bytes checked are the bytes read. The
    deferred apps are the entries with status 'Deferred', whatever deferred them: the record is the
    contract, not the catalog. An id that is not a valid package id is left out and listed in
    InvalidDeferredIds, because the ids reach a winget command line.

    $null with a warning when the file cannot be read, is not trusted or is not a run record; $null
    silently when there is no file. Never throws.
.PARAMETER Path
    The record's path (Get-InstallerRunRecordPath).
.OUTPUTS
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
    $stream = $null
    try {
        $stream = Open-ReadLockedFile -Path $Path
        $trustProblem = Get-RunRecordTrustProblem -Path $Path
        if ($trustProblem) {
            Write-WarningMessage "Ignoring the run record ${Path}: $trustProblem. Only a record that SYSTEM or an administrator wrote is used, since the apps it defers are installed in every account that signs in. The next run of the installer for the whole PC replaces it."
            return $null
        }
        $buffer = New-Object System.IO.MemoryStream
        $stream.CopyTo($buffer)
        $bytes = $buffer.ToArray()
        $text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes).TrimStart([char]0xFEFF)
        $record = ConvertFrom-Json -InputObject $text -ErrorAction Stop
    }
    catch {
        Write-WarningMessage "Could not read the run record ${Path}: $($_.Exception.Message)"
        return $null
    }
    finally {
        if ($stream) {
            $stream.Dispose()
        }
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
.OUTPUTS
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
    No work (Run false, and the user phase ends silently) when:
      - NoRecord: there is no run record, or it cannot be read;
      - RunNotFinished: the run has not reported yet (exitCode null);
      - Done: this account's state is for this run (same record SHA256) and complete;
      - GaveUp: this account already tried MaxAttempts times for this run.
    Otherwise New or Pending, with this attempt's number. A run with nothing deferred still has work
    once per account: the Windows Terminal defaults, which a SYSTEM run never sets. Must match
    rmm/Invoke-WingetAppSetupUserPhase.ps1's Test-RmmUserPhasePending (tests/RmmWrapper.Tests.ps1).
.PARAMETER Record
    Read-InstallerRunRecord's result, or $null.
.PARAMETER State
    Read-UserPhaseState's result, or $null.
.PARAMETER MaxAttempts
    How many times to try for one run before giving up.
.OUTPUTS
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
    Written to a temporary file in the same folder and moved over the state file, creating the folder
    when needed. A failure warns, and the user phase runs again at the next sign-in. PowerShell 7
    only (File.Move with overwrite).
.PARAMETER Path
    The state file (Get-UserPhaseStatePath).
.PARAMETER State
    What to write.
.OUTPUTS
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
    The user phase's Install-AppWithVerification. `winget list` as the user sees the user's apps and
    the PC's, so an app there either way is Skipped. Otherwise Install-WingetPackage -UserScopeOnly
    -Silent (a machine-wide installer would ask for administrator rights), then checked again. A
    check that could not answer fails the app. With a catalog entry, its installerType is used and
    its postInstall hook runs once the app is there (Complete-UserPhaseAppConfiguration).
.PARAMETER PackageId
    The winget package id.
.PARAMETER App
    The app's catalog entry (Get-UserPhaseCatalogEntry), or $null when this installer's catalog has
    none for the id: the app is then installed by its id alone, with no post-install hook.
.PARAMETER TimeoutSeconds
    The install's time limit (what is left of the user phase's time budget, at most 30 minutes).
.OUTPUTS
    New-AppRunRecord's entry: status Installed, Skipped (already installed) or Failed, with the
    reason and winget's exit code, and postInstall and postInstallReason when a hook ran.
#>
function Install-UserPhaseApp {
    param (
        [Parameter(Mandatory = $true)]
        [string]$PackageId,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [hashtable]$App,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 86400)]
        [int]$TimeoutSeconds
    )

    $checkTimeoutSeconds = Get-ProcessTimeoutSeconds -Operation WingetListCheck
    $preCheck = Test-WingetPackageInstalled -PackageId $PackageId -TimeoutSeconds $checkTimeoutSeconds
    if ($preCheck.Installed) {
        Write-WarningMessage "Skipping: $PackageId (already installed)"
        return (Complete-UserPhaseAppConfiguration -App $App -Record (New-AppRunRecord -Id $PackageId -Status 'Skipped' -Reason 'already installed'))
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
    $installParameters = @{
        PackageId                    = $PackageId
        UserScopeOnly                = $true
        Silent                       = $true
        TimeoutSeconds               = $TimeoutSeconds
        InstallInProgressRetries     = 1
        InstallInProgressWaitSeconds = [Math]::Min(120, $TimeoutSeconds)
    }
    if ($null -ne $App -and -not [string]::IsNullOrWhiteSpace([string]$App['installerType'])) {
        $installParameters['InstallerType'] = [string]$App['installerType']
    }
    $installResult = Install-WingetPackage @installParameters
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
            return (Complete-UserPhaseAppConfiguration -App $App -Record (New-AppRunRecord -Id $PackageId -Status 'Installed' -InstallResult $installResult -RestartRequired $restartRequired))
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

<#
.SYNOPSIS
    Returns this installer's catalog entries by package id, for the user phase.
.DESCRIPTION
    The record lists the deferred ids; the catalog adds what it cannot carry: installerType and the
    postInstall hook of a userPhase entry. An id this copy's catalog lacks (another build's run) is
    installed by its id alone; a catalog that cannot be read is reported in one line.
.OUTPUTS
    [hashtable] Package id (compared without regard to case) to catalog entry.
#>
function Get-UserPhaseCatalogEntry {
    $entries = @{}
    try {
        foreach ($app in @(Get-DefaultAppCatalog)) {
            if ($app -is [hashtable] -and -not [string]::IsNullOrWhiteSpace([string]$app['name']) -and -not $entries.ContainsKey([string]$app['name'])) {
                $entries[[string]$app['name']] = $app
            }
        }
    }
    catch {
        Write-WarningMessage "Could not read this installer's app catalog, so the deferred apps are installed without their catalog settings (post-install configuration, installer type): $($_.Exception.Message)"
    }
    return $entries
}

<#
.SYNOPSIS
    Runs a deferred app's post-install hook in the user phase, once the app is there, and records the
    result.
.DESCRIPTION
    A run for the whole PC defers a userPhase entry, hook and all; this runs the hook in the user's
    account, as Install-AppWithVerification would (Invoke-AppPostInstall). Without an entry or a hook
    the record is returned as it is.
      - Configured: 'Configured: <id>'; the record keeps its status.
      - NotConfigured: 'Not configured: <id> (<reason>)'; the record keeps its status and the exit
        code, but the user phase is not complete, so a later sign-in runs the hook again.
      - Failed, or a hook that throws: the app is Failed ('installed, but its post-install
        configuration failed (<reason>)'), so the user phase exits 1 and tries again later.
.PARAMETER App
    The app's catalog entry, or $null.
.PARAMETER Record
    The app's record (New-AppRunRecord), status Installed or Skipped.
.OUTPUTS
    The record, with postInstall and postInstallReason set when the hook ran.
#>
function Complete-UserPhaseAppConfiguration {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [hashtable]$App,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Record
    )

    if ($null -eq $App -or $null -eq $App['postInstall']) {
        return $Record
    }
    $configuration = Invoke-AppPostInstall -App $App
    $Record['postInstall'] = [string]$configuration.Status
    $Record['postInstallReason'] = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$configuration.Reason)) {
        $Record['postInstallReason'] = [string]$configuration.Reason
    }
    if ($configuration.Status -eq 'Failed') {
        $reason = Format-InstallFailureReason -FailureReason 'PostInstallFailed' -PostInstallReason $configuration.Reason
        Write-ErrorMessage "Failed to install: $($Record['id']) ($reason)."
        $Record['status'] = 'Failed'
        $Record['reason'] = $reason
        return $Record
    }
    [void](Write-AppPostInstallResult -AppName ([string]$Record['id']) -Configuration $configuration)
    return $Record
}

<#
.SYNOPSIS
    Updates the winget source for the signed-in user before the user phase's installs.
.DESCRIPTION
    At an account's first sign-in winget has never been used there, and the source update
    (Invoke-WingetSourceProbe, 2-minute limit) registers it; otherwise the 15-second `winget list`
    check before the first install would do that work and time out at every sign-in. No `source
    reset`: it needs administrator rights. A failure is one line and the installs go ahead.
    Agreements not accepted yet (0x8A150046) are not a failure: each install accepts them.
#>
function Update-UserPhaseWingetSource {
    Write-Info 'Updating the winget source for this account (this may take a moment)...'
    $source = Invoke-WingetSourceProbe
    if ($source.Succeeded) {
        Write-Success 'The winget source is up to date for this account.'
        return
    }
    # 0x8A150046 SOURCE_AGREEMENTS_NOT_ACCEPTED, as the signed Int32 winget exits with.
    if ($source.ExitCode -eq -1978335162) {
        Write-Info 'The winget source agreements are not accepted for this account yet (0x8A150046); each install accepts them.'
        return
    }
    $detail = 'it did not finish in time and was stopped'
    if ($source.LaunchError) {
        $detail = "winget could not be started: $($source.LaunchError)"
    }
    elseif (-not $source.TimedOut) {
        $detail = 'exit code {0}' -f (Format-WingetExitCode -ExitCode $source.ExitCode)
    }
    Write-WarningMessage "The winget source could not be updated for this account ($detail). The installs may fail; a later sign-in tries again."
}

<#
.SYNOPSIS
    Returns how many whole seconds the user phase has run: a seam for the time budget's clock.
.PARAMETER Stopwatch
    The user phase's stopwatch.
.OUTPUTS
    [int]
#>
function Get-UserPhaseElapsedSeconds {
    param (
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Stopwatch]$Stopwatch
    )

    return [int]$Stopwatch.Elapsed.TotalSeconds
}
