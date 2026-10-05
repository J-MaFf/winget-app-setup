# The machine-readable outcome of a run (P3-41): one RESULT line near the end of the output and
# %ProgramData%\winget-app-setup\logs\last-run.json, since RMM consoles cut console text to its end.

<#
.SYNOPSIS
    Builds one app's entry for the run record.
.PARAMETER Id
    The winget package id.
.PARAMETER Status
    'Installed', 'Skipped', 'Deferred' (left for the signed-in user's own account: neither installed
    nor failed) or 'Failed'.
.PARAMETER Reason
    Why the app was skipped, deferred or failed (the text the summary shows). Empty: none. For a
    deferred app, Get-AppDeferReasonText's: no machine-wide installer, or a per-user catalog entry.
.PARAMETER InstallResult
    The app's install result (Install-AppWithVerification's InstallResult), for its exit code, or
    $null when no installer ran.
.PARAMETER RestartRequired
    The install finished but needs a restart.
.PARAMETER PostInstall
    The result of the app's post-install hook (@{ Status; Reason }), or $null when no hook ran.
.OUTPUTS
    [System.Collections.Specialized.OrderedDictionary] id, status, reason, code (the exit code of
    the winget install or package-specific installer, or $null), codeHex (the same as 0x%08X),
    restartRequired, postInstall ('Configured', 'NotConfigured' or 'Failed', or $null when no hook
    ran) and postInstallReason (why it is not Configured, or $null).
#>
function New-AppRunRecord {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Id,

        [Parameter(Mandatory = $true)]
        [string]$Status,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Reason,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$InstallResult,

        [Parameter(Mandatory = $false)]
        [bool]$RestartRequired = $false,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$PostInstall
    )

    $code = $null
    $codeHex = $null
    if ($null -ne $InstallResult -and $null -ne $InstallResult.ExitCode) {
        $code = [int]$InstallResult.ExitCode
        $codeHex = '0x{0:X8}' -f $code
    }
    $reasonText = $null
    if (-not [string]::IsNullOrWhiteSpace($Reason)) {
        $reasonText = $Reason
    }
    $postInstallStatus = $null
    $postInstallReason = $null
    if ($null -ne $PostInstall -and -not [string]::IsNullOrWhiteSpace([string]$PostInstall.Status)) {
        $postInstallStatus = [string]$PostInstall.Status
        if (-not [string]::IsNullOrWhiteSpace([string]$PostInstall.Reason)) {
            $postInstallReason = [string]$PostInstall.Reason
        }
    }
    return [ordered]@{
        id                = $Id
        status            = $Status
        reason            = $reasonText
        code              = $code
        codeHex           = $codeHex
        restartRequired   = $RestartRequired
        postInstall       = $postInstallStatus
        postInstallReason = $postInstallReason
    }
}

<#
.SYNOPSIS
    Names the auto-update outcome of a run in one word, for the run record.
.PARAMETER WauResult
    Install-WingetAutoUpdate's result, or $null when the run did not get that far.
.OUTPUTS
    [string] One word per Install-WingetAutoUpdate Status (the summary's wording in parentheses):
      'Configured'        (Configured)
      'AlreadyPresent'    (Already present)
      'AtRisk'            (AT RISK): AlreadyPresent on a machine without its framework
      'Unhealthy'         (UNHEALTHY): installed, but its scheduled task is missing, disabled, has
                          no enabled trigger or could not be checked, framework or not
      'FrameworkMissing'  (NOT CONFIGURED): Microsoft.WindowsAppRuntime.1.8 is missing
      'Failed'            (FAILED)
      'DryRun'            a dry run, which reports no record
      'NotRun'            the run did not get that far
    AtRisk, Unhealthy, FrameworkMissing and Failed make a run exit 8 when no app failed and winget
    still works (Get-InstallerExitCode). An unknown Status is returned as it is.
#>
function Get-AutoUpdateResultStatus {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$WauResult
    )

    if ($null -eq $WauResult -or [string]::IsNullOrWhiteSpace([string]$WauResult.Status)) {
        return 'NotRun'
    }
    switch ([string]$WauResult.Status) {
        'AlreadyPresent' {
            if ($WauResult.FrameworkMissing) {
                return 'AtRisk'
            }
            return 'AlreadyPresent'
        }
        # Not AtRisk when its framework is missing too: the summary prints UNHEALTHY for it.
        'Unhealthy' { return 'Unhealthy' }
    }
    return [string]$WauResult.Status
}

<#
.SYNOPSIS
    Formats a time for the run record: UTC, ISO 8601, to the second.
.PARAMETER Time
    The time.
.OUTPUTS
    [string] For example '2026-10-04T14:30:00Z'.
#>
function Format-RunRecordTime {
    param (
        [Parameter(Mandatory = $true)]
        [DateTime]$Time
    )

    return $Time.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
}

<#
.SYNOPSIS
    Builds the record of a run: what last-run.json holds and the RESULT line shows.
.DESCRIPTION
    Invoke-WingetInstall builds it after its summary; the entry script builds it for a run that ended
    before, from what the run had recorded. The build id, start time and transcript path come from
    the entry script's $script: variables, and are $null outside it.
.PARAMETER ExitCode
    The exit code the run ends with.
.PARAMETER Apps
    The apps' entries (New-AppRunRecord), in the order they were processed.
.PARAMETER AutoUpdates
    The auto-update outcome (Get-AutoUpdateResultStatus). Default 'NotRun'.
.PARAMETER AutoUpdatesVersion
    The Winget-AutoUpdate version installed or found, or $null.
.PARAMETER RestartRequired
    The run needs a restart to finish (what makes it exit 3010 when nothing failed).
.PARAMETER WingetUsable
    The end-of-run winget check's result, or $null when it did not run.
.PARAMETER SummaryReached
    The run reached its summary.
.OUTPUTS
    [System.Collections.Specialized.OrderedDictionary]
#>
function New-InstallerRunRecord {
    param (
        [Parameter(Mandatory = $true)]
        [int]$ExitCode,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Apps = @(),

        [Parameter(Mandatory = $false)]
        [string]$AutoUpdates = 'NotRun',

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$AutoUpdatesVersion,

        [Parameter(Mandatory = $false)]
        [bool]$RestartRequired = $false,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[bool]]$WingetUsable = $null,

        [Parameter(Mandatory = $false)]
        [switch]$SummaryReached
    )

    $appList = @($Apps | Where-Object { $null -ne $_ })
    $autoUpdatesVersionText = $null
    if ($null -ne $AutoUpdatesVersion -and -not [string]::IsNullOrWhiteSpace([string]$AutoUpdatesVersion)) {
        $autoUpdatesVersionText = [string]$AutoUpdatesVersion
    }
    $startedUtc = $null
    if ($script:InstallerRunStartedUtc -is [DateTime]) {
        $startedUtc = Format-RunRecordTime -Time $script:InstallerRunStartedUtc
    }
    $buildId = $null
    if ($script:InstallerBuildId) {
        $buildId = [string]$script:InstallerBuildId
    }
    $transcriptPath = $null
    if ($script:InstallLogPath) {
        $transcriptPath = [string]$script:InstallLogPath
    }

    return [ordered]@{
        schemaVersion   = 1
        buildId         = $buildId
        startedUtc      = $startedUtc
        endedUtc        = Format-RunRecordTime -Time ([DateTime]::UtcNow)
        exitCode        = $ExitCode
        summaryReached  = [bool]$SummaryReached
        counts          = [ordered]@{
            installed = @($appList | Where-Object { $_.status -eq 'Installed' }).Count
            skipped   = @($appList | Where-Object { $_.status -eq 'Skipped' }).Count
            deferred  = @($appList | Where-Object { $_.status -eq 'Deferred' }).Count
            failed    = @($appList | Where-Object { $_.status -eq 'Failed' }).Count
        }
        apps            = $appList
        autoUpdates     = [ordered]@{
            status  = $AutoUpdates
            version = $autoUpdatesVersionText
        }
        restartRequired = $RestartRequired
        wingetUsable    = $WingetUsable
        transcriptPath  = $transcriptPath
    }
}

<#
.SYNOPSIS
    Formats the RESULT line of a run record.
.DESCRIPTION
    Space-separated key=value pairs in a fixed order:

        RESULT: exit=1 installed=12 skipped=2 deferred=0 failed=1 autoupdates=Configured restart=no build=1.0.0+1a2b3c4d log=C:\ProgramData\winget-app-setup\logs\install-20261004-143000.log

    No value holds a space but log, which comes last. The counts are always there; autoupdates is
    Get-AutoUpdateResultStatus's word; restart is yes or no; build and log are 'unknown' and 'none'
    without a build id or transcript; exit is the code the run ends with.
.PARAMETER Record
    A record from New-InstallerRunRecord.
.OUTPUTS
    [string]
#>
function Format-InstallerResultLine {
    param (
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Record
    )

    $restart = 'no'
    if ($Record.restartRequired) {
        $restart = 'yes'
    }
    $build = 'unknown'
    if ($Record.buildId) {
        $build = $Record.buildId
    }
    $log = 'none'
    if ($Record.transcriptPath) {
        $log = $Record.transcriptPath
    }
    return ('RESULT: exit={0} installed={1} skipped={2} deferred={3} failed={4} autoupdates={5} restart={6} build={7} log={8}' -f $Record.exitCode, $Record.counts.installed, $Record.counts.skipped, $Record.counts.deferred, $Record.counts.failed, $Record.autoUpdates.status, $restart, $build, $log)
}

<#
.SYNOPSIS
    Writes a run record to <folder>\last-run.json, replacing the previous one in one step.
.DESCRIPTION
    Written to a temporary file in the same folder and moved over last-run.json, so no reader sees
    a half-written file. A failure warns and leaves the previous file. PowerShell 7 only (File.Move
    with overwrite).
.PARAMETER Record
    A record from New-InstallerRunRecord.
.PARAMETER Directory
    The logs folder.
.OUTPUTS
    [string] The path written, or $null.
#>
function Save-InstallerRunRecord {
    param (
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Record,

        [Parameter(Mandatory = $true)]
        [string]$Directory
    )

    $path = Join-Path $Directory 'last-run.json'
    $temporaryPath = Join-Path $Directory ('last-run.{0}.tmp' -f [System.Guid]::NewGuid().ToString('N'))
    try {
        $json = ConvertTo-Json -InputObject $Record -Depth 6
        [System.IO.File]::WriteAllText($temporaryPath, $json, (New-Object System.Text.UTF8Encoding($false)))
        [System.IO.File]::Move($temporaryPath, $path, $true)
        return $path
    }
    catch {
        Write-WarningMessage "Could not write the run record ${path}: $($_.Exception.Message)"
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
    Reports a run's outcome: writes last-run.json, then prints the RESULT line.
.DESCRIPTION
    last-run.json is written only by the run that did the work: one with
    $script:InstallerRunRecordEnabled, which the entry script sets for a real elevated run holding
    the run lock. It goes next to the run's transcript, and nowhere without one.

    The RESULT line is printed in every case, after the summary or the early-exit notice and before
    any 'Press any key' prompt, by the run that did the work (an elevated relaunch prints it, not
    the run that asked). It need not be the last line: after a run started from Windows PowerShell
    5.1, the bootstrap prints its own lines, and exits 3010 where the line says exit=0 when its
    PowerShell 7 install needs a restart. So look for the line starting 'RESULT: ' and take the
    exit code from the process. Never throws.
.PARAMETER Record
    A record from New-InstallerRunRecord.
.OUTPUTS
    [string] The last-run.json path written, or $null.
#>
function Write-InstallerRunResult {
    param (
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Record
    )

    $savedPath = $null
    if ($script:InstallerRunRecordEnabled) {
        $directory = Get-InstallerLogDirectory
        if (-not [string]::IsNullOrWhiteSpace($directory)) {
            $savedPath = Save-InstallerRunRecord -Record $Record -Directory $directory
        }
    }
    try {
        Write-Host (Format-InstallerResultLine -Record $Record)
    }
    catch {
        Write-WarningMessage "Could not print the RESULT line: $($_.Exception.Message)"
    }
    return $savedPath
}

<#
.SYNOPSIS
    Replaces last-run.json with the record of a run that has started and not ended yet.
.DESCRIPTION
    The entry script calls it once a real, elevated run holds the run lock, before the run changes
    anything, so a run that is killed and never reports does not leave the previous run's record in
    place. The record has startedUtc, exitCode and endedUtc $null, summaryReached false and no apps:
    a null exitCode means a run still going or killed. Prints nothing; writes only with
    $script:InstallerRunRecordEnabled and a logs folder. Never throws.
.OUTPUTS
    [string] The last-run.json path written, or $null.
#>
function Save-InstallerRunStartRecord {
    if (-not $script:InstallerRunRecordEnabled) {
        return $null
    }
    $directory = Get-InstallerLogDirectory
    if ([string]::IsNullOrWhiteSpace($directory)) {
        return $null
    }
    try {
        $record = New-InstallerRunRecord -ExitCode 0
        $record.exitCode = $null
        $record.endedUtc = $null
        return (Save-InstallerRunRecord -Record $record -Directory $directory)
    }
    catch {
        Write-WarningMessage "Could not write the run record: $($_.Exception.Message)"
        return $null
    }
}

<#
.SYNOPSIS
    Ends a run's reporting: its RESULT line and last-run.json if it has not reported yet, then the
    run lock.
.DESCRIPTION
    Called by Exit-Installer before it waits for a key press, and from the entry script's finally
    block, so a run reports once however it ends and releases the lock before any prompt. Reports
    only while $script:InstallerRunReportPending is set (set at the start of a real PowerShell 7
    run, cleared once Invoke-WingetInstall has reported). A second call only releases the lock
    again. Under Windows PowerShell 5.1 nothing is pending and there is no lock.
.PARAMETER ExitCode
    The exit code the run ends with.
#>
function Complete-InstallerRun {
    param (
        [Parameter(Mandatory = $true)]
        [int]$ExitCode
    )

    if ($script:InstallerRunReportPending) {
        $script:InstallerRunReportPending = $false
        try {
            [void](Write-InstallerEarlyExitResult -ExitCode $ExitCode)
        }
        catch {
            # Reporting is best-effort; the exit code and the lock release are not.
        }
    }
    Unlock-InstallerRun
}

<#
.SYNOPSIS
    Reports the outcome of a run that ended before its summary.
.DESCRIPTION
    For an early exit or an aborted run. The record holds the apps finished by then
    ($script:InstallerAppRecords) and the auto-update outcome if it got that far
    ($script:InstallerAutoUpdateResult); restartRequired is set when one of those apps needs a
    restart, summaryReached is false and wingetUsable $null.
.PARAMETER ExitCode
    The exit code the run ends with.
.OUTPUTS
    [string] The last-run.json path written, or $null (see Write-InstallerRunResult).
#>
function Write-InstallerEarlyExitResult {
    param (
        [Parameter(Mandatory = $true)]
        [int]$ExitCode
    )

    $apps = @()
    if ($script:InstallerAppRecords) {
        $apps = @($script:InstallerAppRecords.Values)
    }
    $autoUpdateResult = $script:InstallerAutoUpdateResult
    $autoUpdateVersion = $null
    if ($null -ne $autoUpdateResult) {
        $autoUpdateVersion = $autoUpdateResult.Version
    }
    $restartRequired = @($apps | Where-Object { $_.restartRequired }).Count -gt 0
    $record = New-InstallerRunRecord -ExitCode $ExitCode -Apps $apps -AutoUpdates (Get-AutoUpdateResultStatus -WauResult $autoUpdateResult) -AutoUpdatesVersion $autoUpdateVersion -RestartRequired $restartRequired
    return (Write-InstallerRunResult -Record $record)
}

<#
.SYNOPSIS
    Prints the RESULT line of a run that stopped before it started: no app counted, no log.
.DESCRIPTION
    For the Constrained Language Mode stop, which comes before the transcript, the run lock and the
    5.1 bootstrap:

        RESULT: exit=5 installed=0 skipped=0 deferred=0 failed=0 autoupdates=NotRun restart=no build=1.0.0+1a2b3c4d log=none

    Uses only what every language mode allows, under 5.1 too, reads only $script:InstallerBuildId
    (an irm | iex console may hold an earlier run's state) and writes no last-run.json.
.PARAMETER ExitCode
    The exit code the run stops with.
#>
function Write-InstallerNotStartedResult {
    param (
        [Parameter(Mandatory = $true)]
        [int]$ExitCode
    )

    $record = [ordered]@{
        exitCode        = $ExitCode
        counts          = [ordered]@{ installed = 0; skipped = 0; deferred = 0; failed = 0 }
        autoUpdates     = [ordered]@{ status = 'NotRun' }
        restartRequired = $false
        buildId         = $script:InstallerBuildId
        transcriptPath  = $null
    }
    Write-Host (Format-InstallerResultLine -Record $record)
}
