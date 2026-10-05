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
    Says why the run record may have been written by someone other than SYSTEM or an administrator,
    or returns $null when it cannot have been.
.DESCRIPTION
    The user phase installs what last-run.json lists as Deferred in every account that signs in,
    so a record a standard user could write would let that user choose what runs in other users'
    accounts. Its folder does not rule that out: the installer's first, non-elevated launch creates
    %ProgramData%\winget-app-setup\logs for its own log, owned by the signed-in user, who can then
    change the folder's access list; and ProgramData's default access list lets any user create
    files in a folder below it. So the file itself is checked, from its own access list:
      - its owner must be SYSTEM (S-1-5-18) or Administrators (S-1-5-32-544). A standard user
        cannot make either of them the owner of a file, and an owner can always change the file's
        access list;
      - no entry that applies to the file may let another account change it: write or append data,
        delete it, change its access list or take ownership (or the generic write and all rights).
    The installer's own runs pass: SYSTEM or an elevated administrator writes the file, and it
    inherits entries for SYSTEM and Administrators (full control) and read access for others. An
    account that controls the folder can still delete or rename the record, which stops the user
    phase or repeats an earlier run's list, but it cannot make one that lists other apps.
.PARAMETER Path
    The record's path.
.RETURNS
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
    The file is read once, and its SHA256 identifies the machine run: a run replaces the file when it
    starts (exitCode null, Save-InstallerRunStartRecord) and once more when it reports
    (Write-InstallerRunResult), and nothing else writes it, so the hash of a finished run's record
    changes only when another run replaces it.

    Only a record that SYSTEM or an administrator wrote is used (Get-RunRecordTrustProblem): its
    deferred apps are installed in every account that signs in. The file is opened first so that
    nobody can replace, change or delete it until it has been read (Open-ReadLockedFile), its
    owner and access list are checked while it is open, and the bytes checked are the bytes read.

    The deferred apps are the entries with status 'Deferred', whatever deferred them: a run for the
    whole PC that found no machine-wide installer, or a catalog entry that says the app is per-user.
    The record is the contract, not the catalog. An id that is not a valid winget package id
    (Test-WingetPackageIdFormat) is left out and listed in InvalidDeferredIds: its ids end up on a
    winget command line.

    Returns $null, with a warning, when the file cannot be read, someone other than SYSTEM or an
    administrator owns it or can change it, or it is not a run record (no apps list), and $null,
    silently, when there is no file. Never throws.
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

    With the app's catalog entry (work-order item 38), the install uses its installerType, and once
    the app is there (installed now or already) its postInstall hook runs in this account
    (Complete-UserPhaseAppConfiguration): a userPhase entry's hook is what a run for the whole PC
    deferred along with the app.
.PARAMETER PackageId
    The winget package id.
.PARAMETER App
    The app's catalog entry (Get-UserPhaseCatalogEntry), or $null when this installer's catalog has
    none for the id: the app is then installed by its id alone, with no post-install hook.
.PARAMETER TimeoutSeconds
    The install's time limit (what is left of the user phase's time budget, at most 30 minutes).
.RETURNS
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
    The run record is the user phase's contract: it lists the deferred ids, whatever deferred them
    (Read-InstallerRunRecord). The catalog adds what a record cannot carry (work-order item 38): the
    postInstall hook of an entry marked userPhase, which a run for the whole PC deferred along with
    the app because it configures the signed-in user's own account, and the entry's installerType.
    The catalog is this installer copy's (Get-DefaultAppCatalog). An id it does not have (the run
    for the whole PC was another build's) is installed by its id alone. A catalog that cannot be
    read is reported in one line, and the apps are installed without their catalog settings.
.RETURNS
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
    Work-order items 34 and 38. A catalog entry marked userPhase can carry a postInstall hook that
    sets the app up in the signed-in user's own account; a run as SYSTEM or under cross-user
    elevation defers such an app before any winget call, so its hook never ran there. The user
    phase runs it in the user's account as Install-AppWithVerification does (Invoke-AppPostInstall):
    after the app was installed for this account, or found already installed. Without a catalog
    entry or a hook, the record is returned as it is.
      - Configured: 'Configured: <id>'. The record keeps its status.
      - NotConfigured: 'Not configured: <id> (<reason>)'. The record keeps its status (the app is
        installed) and the exit code does not change, but this account's user phase is not complete,
        so a later sign-in runs the hook again (Invoke-WingetUserPhase).
      - Failed, or a hook that throws: the app is Failed with 'installed, but its post-install
        configuration failed (<reason>)', so the user phase exits 1 and a later sign-in tries again.
        The install's restart and exit code stay in the record.
.PARAMETER App
    The app's catalog entry, or $null.
.PARAMETER Record
    The app's record (New-AppRunRecord), status Installed or Skipped.
.RETURNS
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
    The user phase's form of Initialize-Winget's source step. It runs at an account's first sign-in,
    when winget has never been used in it: `winget source update --name winget`
    (Invoke-WingetSourceProbe, a 2-minute limit) then downloads and registers the source for the
    account. Without it, the first command that needs the source would be the 15-second
    `winget list` check before the first install (Install-UserPhaseApp), which that work does not
    fit in, so the app would fail with PreCheckTimeout at every sign-in.

    There is no `winget source reset` here: it needs administrator rights, which the user phase does
    not have. A source that cannot be updated is reported in one line and the installs go ahead:
    each one then says why it failed, and a later sign-in tries again. Agreements that are not
    accepted yet (0x8A150046) are not a failure: each install accepts them.
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
    Returns how many whole seconds the user phase has run (the time budget's clock).
.DESCRIPTION
    A seam, so tests can move the clock without waiting for it.
.PARAMETER Stopwatch
    The user phase's stopwatch.
.RETURNS
    [int]
#>
function Get-UserPhaseElapsedSeconds {
    param (
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Stopwatch]$Stopwatch
    )

    return [int]$Stopwatch.Elapsed.TotalSeconds
}
