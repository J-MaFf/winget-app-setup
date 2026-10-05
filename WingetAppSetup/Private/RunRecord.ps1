# The machine-readable outcome of a run (review finding P3-41): one RESULT line near the end of the
# output and %ProgramData%\winget-app-setup\logs\last-run.json. The exit code used to be the only
# signal an RMM tool could read, and per-app results existed only as console text, which RMM
# consoles cut to their last lines.

<#
.SYNOPSIS
    Builds one app's entry for the run record.
.PARAMETER Id
    The winget package id.
.PARAMETER Status
    'Installed', 'Skipped', 'Deferred' (a run for the whole PC found no machine-wide installer for
    it: neither installed nor failed, review finding P3-22) or 'Failed'.
.PARAMETER Reason
    Why the app was skipped, deferred or failed (the text the summary shows). Empty: none. For a
    deferred app it names why (Get-AppDeferReasonText): no machine-wide installer, or a catalog
    entry marked per-user (scope 'user' or userPhase), which a later run as the signed-in user
    installs.
.PARAMETER InstallResult
    The app's install result (Install-AppWithVerification's InstallResult), for its exit code, or
    $null when no installer ran.
.PARAMETER RestartRequired
    The install finished but needs a restart.
.PARAMETER PostInstall
    The result of the app's post-install hook (work-order item 38: Install-AppWithVerification's
    Configuration, @{ Status; Reason }), or $null when no hook ran.
.RETURNS
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
.RETURNS
    [string] One word for the run's 'Auto-updates:' line, for every Status Install-WingetAutoUpdate
    returns (the summary's wording in parentheses):
      'Configured'        (Configured)
      'AlreadyPresent'    (Already present)
      'AtRisk'            (AT RISK): AlreadyPresent on a machine without its framework
      'Unhealthy'         (UNHEALTHY): installed, but its scheduled task is missing, disabled, has
                          no enabled trigger or could not be checked (review finding P3-36),
                          whether or not the framework is missing too
      'FrameworkMissing'  (NOT CONFIGURED): Microsoft.WindowsAppRuntime.1.8 is missing
      'Failed'            (FAILED)
      'DryRun'            a dry run, which reports no record
      'NotRun'            the run did not get that far
    AtRisk, Unhealthy, FrameworkMissing and Failed make a run exit 8 when no app failed and winget
    still works (Get-InstallerExitCode). A Status this list does not know is returned as it is.
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
.RETURNS
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
    Invoke-WingetInstall builds it after its summary. The entry script builds it for a run that
    ended before its summary (an early exit, an abort, another run in progress), from what the run
    had recorded by then: the apps it had finished and the auto-update outcome, if it got that far.
    The build id, the start time and the transcript path come from the entry script
    ($script:InstallerBuildId, $script:InstallerRunStartedUtc, $script:InstallLogPath), and are
    $null outside it.
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
.RETURNS
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
    One line of space-separated key=value pairs, in a fixed order:

        RESULT: exit=1 installed=12 skipped=2 deferred=0 failed=1 autoupdates=Configured restart=no build=1.0.0+1a2b3c4d log=C:\ProgramData\winget-app-setup\logs\install-20261004-143000.log

    Values hold no spaces, except log, which comes last so that everything after 'log=' is the path.
    The counts are always there, in the summary's order: deferred counts the apps a run as SYSTEM
    or under cross-user elevation left for the signed-in user's own account (no machine-wide
    installer, review finding P3-22), which count neither as installed nor as failed. autoupdates
    is Get-AutoUpdateResultStatus's word, restart is yes or no, and build and log are 'unknown' and
    'none' when there is no build id or transcript. exit is the code the run ends with: after the
    summary, Get-InstallerExitCode's (1 > 2 > 8 > 3010 > 0, so 8 when auto-updates are not set up
    or unhealthy and nothing ranks above it).
.PARAMETER Record
    A record from New-InstallerRunRecord.
.RETURNS
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
    The JSON goes to a temporary file in the same folder first, which is then moved over
    last-run.json, so a reader (an RMM tool collecting it, the teammate opening it) never sees a
    half-written file. A failure warns and leaves the previous file as it was. Runs only under
    PowerShell 7 (File.Move with overwrite).
.PARAMETER Record
    A record from New-InstallerRunRecord.
.PARAMETER Directory
    The logs folder.
.RETURNS
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
    last-run.json is written only by the run that did the work: the entry script sets
    $script:InstallerRunRecordEnabled for a real, elevated run once it holds the run lock
    (Lock-InstallerRun). So a dry run, a run that is not elevated (which stops with exit code 4, or
    whose elevated run writes its own record), a run that found another one in progress (exit code
    6) and a script that calls Invoke-WingetInstall from the imported module never replace the
    record of the run that installed. The file is written next to the run's transcript
    (Get-InstallerLogDirectory), and not at all without one.

    The RESULT line is printed in every case, after the summary or the early-exit notice and before
    any 'Press any key' prompt. It is printed by the run that did the work: a run that relaunched
    itself elevated prints none of its own (the elevated window prints it). It is not always the
    last line of the output either: a run started from Windows PowerShell 5.1 (the irm | iex
    one-liner) prints the bootstrap's own lines after it, such as the PowerShell 7 run's exit code
    and any restart notice; when that bootstrap installed PowerShell 7 and the install needs a
    restart, the process exits 3010 where the line says exit=0. So a reader looks for the line that
    starts with 'RESULT: ' rather than reading the last line, and takes the exit code from the
    process. Never throws.
.PARAMETER Record
    A record from New-InstallerRunRecord.
.RETURNS
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
    Review of finding P3-41. The entry script calls this once a real, elevated run holds the run
    lock, before the run changes anything. last-run.json is otherwise written only when a run
    reports (Write-InstallerRunResult), and a run that is killed (an RMM time limit, taskkill /F)
    never reports, so without this the file would go on describing the run before it, which may
    have exited 0. This record has the new run's startedUtc, exitCode and endedUtc $null,
    summaryReached false and no apps; the run's report replaces it. A record whose exitCode is
    null therefore describes a run that is still going or was killed before it could report.

    Prints nothing (no RESULT line). Writes nothing unless $script:InstallerRunRecordEnabled is
    set and the run has a logs folder (Get-InstallerLogDirectory). Never throws.
.RETURNS
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
    block for every other way out of a run, so a run reports once whichever way it ends and releases
    the run lock before a window waits at a prompt (review finding P3-41). Reports only while
    $script:InstallerRunReportPending is set: the entry script sets it at the start of a real
    (not -WhatIf) PowerShell 7 run, and Invoke-WingetInstall clears it once it has reported after its
    summary, or when the elevated run it relaunched reported for it. A second call does nothing but
    release the lock again, which is harmless.

    Runs under Windows PowerShell 5.1 too (Exit-Installer in the bootstrap phase), where nothing is
    pending, so only Unlock-InstallerRun runs, and it has no lock to release.
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
    Called by Complete-InstallerRun for an early exit (a failed pre-flight check, another run in
    progress, winget unavailable, a catalog that failed validation, no elevation) and for an aborted
    run. The record holds what the run had recorded by then: the apps it had finished
    (Invoke-WingetInstall keeps them in $script:InstallerAppRecords) and the auto-update outcome if
    it got that far ($script:InstallerAutoUpdateResult); restartRequired is set when one of those
    apps needs a restart. summaryReached is false and wingetUsable is $null (the end-of-run
    check did not run).
.PARAMETER ExitCode
    The exit code the run ends with.
.RETURNS
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
