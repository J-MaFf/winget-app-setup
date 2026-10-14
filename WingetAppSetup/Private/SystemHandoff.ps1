# The hand-over to SYSTEM (wgt-gq8.68): under cross-user elevation, Windows can refuse to deploy
# winget's source package for the elevated account, and when the repair cannot open the source, the
# run hands the install over to a one-shot scheduled task that runs a checked copy of this installer
# as SYSTEM, whose machine-wide winget.exe keeps its source in a file. A run as SYSTEM never hands
# over again: Get-InstallAccountContext never reports cross-user elevation for SYSTEM.

<#
.SYNOPSIS
    Returns the path of a PowerShell 7 installed for the whole PC, or $null.
.DESCRIPTION
    Only %ProgramFiles%\PowerShell\7\pwsh.exe (ProgramW6432 first, for a 32-bit host): a folder only
    administrators can change, which SYSTEM can run. Never PATH or a per-user WindowsApps alias,
    which SYSTEM does not have and the signed-in user could replace. The candidate must start and
    report version 7 or newer (Test-PowerShell7Executable).
.OUTPUTS
    [string] The full path of pwsh.exe, or $null.
#>
function Find-MachinePowerShell7 {
    $roots = @($env:ProgramW6432, $env:ProgramFiles | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    foreach ($root in $roots) {
        $candidate = Join-Path $root 'PowerShell\7\pwsh.exe'
        if ((Test-Path -LiteralPath $candidate -PathType Leaf) -and (Test-PowerShell7Executable -Path $candidate)) {
            return $candidate
        }
    }
    return $null
}

<#
.SYNOPSIS
    Returns how long the hand-started run waits for the SYSTEM run, in seconds.
.DESCRIPTION
    Get-ProcessTimeoutSeconds' SystemHandoff limit; with a time budget, no longer than what is left
    of it plus 45 minutes, since an install already running when the budget runs out still finishes
    within its own limits, and the end-of-run checks follow.
.PARAMETER Budget
    Resolve-InstallerRunBudget's result, or $null.
.OUTPUTS
    [int] Seconds, at least 60.
#>
function Get-SystemHandoffWaitSeconds {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Budget
    )

    $limit = Get-ProcessTimeoutSeconds -Operation 'SystemHandoff'
    $secondsLeft = Get-InstallerRunBudgetSecondsLeft -Budget $Budget
    if ($null -ne $secondsLeft) {
        $limit = [Math]::Min($limit, $secondsLeft + 2700)
    }
    return [int][Math]::Max(60, $limit)
}

<#
.SYNOPSIS
    Returns the command line arguments of the SYSTEM task's pwsh.
.PARAMETER ScriptPath
    The checked copy of the installer.
.PARAMETER SkipSystemCheck
    Passed on as -SkipSystemCheck.
.PARAMETER BudgetArguments
    Get-InstallerRunBudgetArgument's tokens: parameter names and values without spaces or quotes.
.OUTPUTS
    [string]
#>
function Get-SystemHandoffTaskArgument {
    param (
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [Parameter(Mandatory = $false)]
        [switch]$SkipSystemCheck,

        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [ValidatePattern('^(?:-[A-Za-z][A-Za-z0-9]*|[0-9][0-9A-Za-z:.-]*)\z')]
        [string[]]$BudgetArguments = @()
    )

    $argument = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -NonInteractive' -f $ScriptPath
    if ($SkipSystemCheck) {
        $argument += ' -SkipSystemCheck'
    }
    if ($BudgetArguments.Count -gt 0) {
        $argument += ' ' + ($BudgetArguments -join ' ')
    }
    return $argument
}

<#
.SYNOPSIS
    Returns the Task Scheduler XML of the one-shot SYSTEM task.
.DESCRIPTION
    SYSTEM by its SID (S-1-5-18, the same in every display language) at the highest run level, no
    trigger (the run starts it on demand), runs on battery, and stopped by Task Scheduler after
    -TimeLimitSeconds plus 5 minutes, a backstop behind the run's own wait.
.PARAMETER Command
    The program the task runs (pwsh.exe).
.PARAMETER Arguments
    Its command line arguments.
.PARAMETER TimeLimitSeconds
    How long the run waits for the task.
.OUTPUTS
    [string]
#>
function New-SystemHandoffTaskXml {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Command,

        [Parameter(Mandatory = $true)]
        [string]$Arguments,

        [Parameter(Mandatory = $true)]
        [int]$TimeLimitSeconds
    )

    $limitMinutes = [int][Math]::Ceiling(($TimeLimitSeconds + 300) / 60)
    $escape = { param ([string]$Text) [System.Security.SecurityElement]::Escape($Text) }
    return @"
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>winget-app-setup: one run of the installer as SYSTEM, handed over by a run that could not open winget's source under cross-user elevation. Removed when the run ends.</Description>
  </RegistrationInfo>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>false</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <ExecutionTimeLimit>PT$($limitMinutes)M</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$(& $escape $Command)</Command>
      <Arguments>$(& $escape $Arguments)</Arguments>
    </Exec>
  </Actions>
</Task>
"@
}

<#
.SYNOPSIS
    Copies the installer into a new folder only SYSTEM and Administrators can change, for the SYSTEM
    task to run.
.DESCRIPTION
    Reads the file once and copies those bytes only when they still have the SHA256 the run started
    with, so a file rewritten since (it may sit in a user-writable folder) is never run as SYSTEM.
    The folder comes from New-WauStagingDirectory (wgt-gq8.46). Throws when the file cannot be read,
    changed, or cannot be copied; the folder is removed then.
.PARAMETER ScriptPath
    The running installer.
.PARAMETER ExpectedSha256
    Its SHA256 when the run started. Empty: the hash is taken now.
.OUTPUTS
    [pscustomobject] @{ Directory; Path; Sha256 }
#>
function Copy-SystemHandoffInstaller {
    param (
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ExpectedSha256
    )

    $bytes = [System.IO.File]::ReadAllBytes($ScriptPath)
    $sha256 = Get-Sha256Hex -Bytes $bytes
    if (-not [string]::IsNullOrWhiteSpace($ExpectedSha256) -and $sha256 -ne $ExpectedSha256.ToUpperInvariant()) {
        throw "$ScriptPath changed after this run started"
    }
    $directory = New-WauStagingDirectory -Prefix 'system-handoff'
    try {
        $path = Join-Path $directory 'winget-app-install.ps1'
        [System.IO.File]::WriteAllBytes($path, $bytes)
    }
    catch {
        Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
    return [pscustomobject]@{ Directory = $directory; Path = $path; Sha256 = $sha256 }
}

<#
.SYNOPSIS
    Returns whether a file has a SHA256: the check of the staged copy right before the task that
    runs it is registered.
.PARAMETER Path
    The file.
.PARAMETER Sha256
    The SHA256 it must have (hex).
.OUTPUTS
    [bool] False also when the file cannot be read.
#>
function Test-SystemHandoffCopy {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Sha256
    )

    try {
        return ((Get-Sha256Hex -Bytes ([System.IO.File]::ReadAllBytes($Path))) -eq $Sha256.ToUpperInvariant())
    }
    catch {
        return $false
    }
}

<#
.SYNOPSIS
    Waits for the SYSTEM task to end and returns its exit code, or $null when it did not end in time.
.DESCRIPTION
    Polls the task (Get-ScheduledTask, Get-ScheduledTaskInfo) until it is no longer running and its
    LastTaskResult is neither 267009 (running) nor 267011 (not yet run), and says every 5 minutes
    that it is still waiting. LastTaskResult is unsigned; the exit code is returned as the process
    returned it.
.PARAMETER TaskName
    The task.
.PARAMETER StartedUtc
    When the task was started: an earlier run's result does not count.
.PARAMETER TimeoutSeconds
    How long to wait.
.PARAMETER PollSeconds
    Seconds between two looks. Default 5.
.OUTPUTS
    [int] The exit code, or $null.
#>
function Wait-SystemHandoffTask {
    param (
        [Parameter(Mandatory = $true)]
        [string]$TaskName,

        [Parameter(Mandatory = $true)]
        [DateTime]$StartedUtc,

        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds,

        [Parameter(Mandatory = $false)]
        [int]$PollSeconds = 5
    )

    $waitStartedUtc = [DateTime]::UtcNow
    $deadlineUtc = $waitStartedUtc.AddSeconds($TimeoutSeconds)
    $nextReportUtc = $waitStartedUtc.AddMinutes(5)
    while ([DateTime]::UtcNow -lt $deadlineUtc) {
        Start-Sleep -Seconds $PollSeconds
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($task -and $info -and "$($task.State)" -ne 'Running' -and $null -ne $info.LastTaskResult -and @(267009, 267011) -notcontains [long]$info.LastTaskResult -and $info.LastRunTime -is [DateTime] -and $info.LastRunTime.ToUniversalTime() -ge $StartedUtc.AddMinutes(-1)) {
            $result = [long]$info.LastTaskResult
            if ($result -gt [int]::MaxValue) {
                $result -= 4294967296
            }
            return [int]$result
        }
        if ([DateTime]::UtcNow -ge $nextReportUtc) {
            $nextReportUtc = [DateTime]::UtcNow.AddMinutes(5)
            Write-Info ('Still waiting for the SYSTEM run ({0:N0} minutes so far).' -f ([DateTime]::UtcNow - $waitStartedUtc).TotalMinutes)
        }
    }
    return $null
}

<#
.SYNOPSIS
    Reads the SYSTEM run's last-run.json, only when it is that run's.
.DESCRIPTION
    Read-InstallerRunRecord reads it (a record SYSTEM or an administrator wrote, nothing else), and
    it counts only when it started after the task did, carries this run's build id and has an exit
    code: otherwise it is an earlier run's record, or the SYSTEM run stopped before it reported.
.PARAMETER StartedUtc
    When the task was started.
.PARAMETER BuildId
    This run's build id. Default: $script:InstallerBuildId; empty: not compared.
.PARAMETER Path
    The record. Default: Get-InstallerRunRecordPath.
.OUTPUTS
    [pscustomobject] @{ Record (Read-InstallerRunRecord's result, or $null); Problem (why there is
    none, or $null) }
#>
function Read-SystemHandoffRunRecord {
    param (
        [Parameter(Mandatory = $true)]
        [DateTime]$StartedUtc,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$BuildId = $script:InstallerBuildId,

        [Parameter(Mandatory = $false)]
        [string]$Path = (Get-InstallerRunRecordPath)
    )

    $read = Read-InstallerRunRecord -Path $Path
    if ($null -eq $read) {
        return [pscustomobject]@{ Record = $null; Problem = "there is no last-run.json at $Path that SYSTEM or an administrator wrote" }
    }
    $recordStartedUtc = [DateTime]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
    $parsed = [DateTime]::TryParseExact([string]$read.StartedUtc, "yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$recordStartedUtc)
    if (-not $parsed -or $recordStartedUtc -lt $StartedUtc.ToUniversalTime().AddSeconds(-5)) {
        return [pscustomobject]@{ Record = $null; Problem = "$Path is an earlier run's (started $($read.StartedUtc))" }
    }
    if (-not [string]::IsNullOrWhiteSpace($BuildId) -and $read.BuildId -ne $BuildId) {
        return [pscustomobject]@{ Record = $null; Problem = "$Path is installer build $($read.BuildId)'s, not this run's build $BuildId" }
    }
    if ($null -eq $read.ExitCode) {
        return [pscustomobject]@{ Record = $null; Problem = "$Path has no exit code: the SYSTEM run stopped before it reported" }
    }
    return [pscustomobject]@{ Record = $read; Problem = $null }
}

<#
.SYNOPSIS
    Hands the install over to SYSTEM: runs a checked copy of this installer as SYSTEM from a one-shot
    scheduled task, waits for it and reads its result.
.DESCRIPTION
    For a run under cross-user elevation whose winget source stays closed (Initialize-Winget's
    SourceUnusable). Needs this run's installer file and a PowerShell 7 installed for the whole PC
    (Find-MachinePowerShell7); without either, or when the copy cannot be staged or checked, or the
    task cannot be started, nothing is started and the run keeps its exit code 2. Otherwise:
      1. copies the installer into a folder only SYSTEM and Administrators can change, after
         checking it still has the SHA256 the run started with (Copy-SystemHandoffInstaller), and
         checks the copy again right before the task is registered (Test-SystemHandoffCopy);
      2. releases the run lock, which the SYSTEM run takes, and registers and starts a task with a
         name of its own, as SYSTEM at the highest run level, that runs the copy with pwsh,
         -NonInteractive, -SkipSystemCheck when given and the time budget's deadline;
      3. waits for it (Get-SystemHandoffWaitSeconds), stopping it when it does not end in time;
      4. reads the SYSTEM run's last-run.json (Read-SystemHandoffRunRecord) for its deferred apps.
    Whatever happens, the task is unregistered, the copy removed and the run lock taken again; when
    another run holds it by then, this run leaves last-run.json alone.
.PARAMETER ScriptPath
    The running installer ($PSCommandPath); empty when there is none (irm | iex, the module).
.PARAMETER ExpectedSha256
    Its SHA256 when the run started ($script:InstallerScriptSha256).
.PARAMETER Budget
    The run's time budget (Resolve-InstallerRunBudget), or $null.
.PARAMETER SkipSystemCheck
    The run's -SkipSystemCheck.
.PARAMETER AccountContext
    Get-InstallAccountContext's result, for the messages.
.OUTPUTS
    [pscustomobject] Started ([bool]); ExitCode (2 when nothing was started, else $null);
    TaskExitCode (the SYSTEM run's exit code, $null when it did not end in time); WaitSeconds;
    RunRecord (Read-InstallerRunRecord's result for the SYSTEM run, or $null); RecordProblem;
    DeferredApps ([string[]]).
#>
function Invoke-SystemHandoff {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ScriptPath,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ExpectedSha256,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Budget,

        [Parameter(Mandatory = $false)]
        [switch]$SkipSystemCheck,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$AccountContext
    )

    $notStarted = {
        param ([string]$Reason)
        Write-ErrorMessage "The install was not handed over to SYSTEM: $Reason"
        return [pscustomobject]@{ Started = $false; ExitCode = 2; TaskExitCode = $null; WaitSeconds = $null; RunRecord = $null; RecordProblem = $null; DeferredApps = [string[]]@() }
    }

    $processUser = 'this account'
    $sessionText = ''
    if ($AccountContext) {
        if ($AccountContext.ProcessUser) {
            $processUser = "'$($AccountContext.ProcessUser)'"
        }
        if ($AccountContext.SessionUser) {
            $sessionText = " in $($AccountContext.SessionUser)'s session"
        }
    }
    Write-WarningMessage "Switching to SYSTEM: winget cannot open its source for $processUser, elevated$sessionText (cross-user elevation), so this run hands the install over to a one-shot scheduled task that runs this installer build as SYSTEM, with the winget.exe installed for the whole PC. An app that installs only per user is Deferred there."

    if ([string]::IsNullOrWhiteSpace($ScriptPath)) {
        return (& $notStarted 'this run has no installer file to hand over (irm | iex in PowerShell 7, or the imported module). Run the Windows PowerShell one-liner, which saves a copy, or run winget-app-install.ps1 from a file.')
    }
    $pwshPath = Find-MachinePowerShell7
    if (-not $pwshPath) {
        return (& $notStarted 'PowerShell 7 is not installed for the whole PC (%ProgramFiles%\PowerShell\7\pwsh.exe), and the SYSTEM run needs it.')
    }

    $copy = $null
    $taskName = $null
    $registered = $false
    $relock = $false
    try {
        try {
            $copy = Copy-SystemHandoffInstaller -ScriptPath $ScriptPath -ExpectedSha256 $ExpectedSha256
        }
        catch {
            $resetHint = ''
            if ($_.FullyQualifiedErrorId -eq 'RestrictedDirectoryAclFailed' -and $_.TargetObject) {
                $resetHint = Get-RestrictedDirectoryResetHint -Path ([string]$_.TargetObject)
            }
            return (& $notStarted "the installer could not be copied for the SYSTEM run ($($_.Exception.Message)).$resetHint")
        }
        if (-not (Test-SystemHandoffCopy -Path $copy.Path -Sha256 $copy.Sha256)) {
            return (& $notStarted "the copy $($copy.Path) does not have the SHA256 $($copy.Sha256) it was written with, so it is not run as SYSTEM.")
        }

        $waitSeconds = Get-SystemHandoffWaitSeconds -Budget $Budget
        $taskArgument = Get-SystemHandoffTaskArgument -ScriptPath $copy.Path -SkipSystemCheck:$SkipSystemCheck -BudgetArguments @(Get-InstallerRunBudgetArgument -Budget $Budget)
        $taskXml = New-SystemHandoffTaskXml -Command $pwshPath -Arguments $taskArgument -TimeLimitSeconds $waitSeconds
        $taskName = 'winget-app-setup-system-' + [guid]::NewGuid().ToString('N')

        # The SYSTEM run takes the run lock itself; it is taken back below.
        if ($null -ne $script:InstallerRunLock) {
            Unlock-InstallerRun
            $relock = $true
        }
        $startedUtc = [DateTime]::UtcNow
        try {
            [void](Register-ScheduledTask -TaskName $taskName -Xml $taskXml -Force -ErrorAction Stop)
            $registered = $true
            Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
        }
        catch {
            return (& $notStarted "the scheduled task $taskName could not be registered or started: $($_.Exception.Message)")
        }

        $logDirectory = Split-Path -Parent (Get-InstallerRunRecordPath)
        Write-Info ('The SYSTEM run has started (scheduled task {0}, {1}). Its transcript is the newest install-*.log in {2}; this window waits for it, for at most {3:N0} minutes.' -f $taskName, $pwshPath, $logDirectory, ($waitSeconds / 60))
        $taskExitCode = Wait-SystemHandoffTask -TaskName $taskName -StartedUtc $startedUtc -TimeoutSeconds $waitSeconds
        if ($null -eq $taskExitCode) {
            Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        }
        $recordRead = Read-SystemHandoffRunRecord -StartedUtc $startedUtc
        $deferred = [string[]]@()
        if ($recordRead.Record) {
            $deferred = [string[]]@($recordRead.Record.DeferredApps)
        }
        return [pscustomobject]@{
            Started       = $true
            ExitCode      = $null
            TaskExitCode  = $taskExitCode
            WaitSeconds   = $waitSeconds
            RunRecord     = $recordRead.Record
            RecordProblem = $recordRead.Problem
            DeferredApps  = $deferred
        }
    }
    finally {
        if ($registered) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        }
        if ($copy -and $copy.Directory) {
            Remove-Item -LiteralPath $copy.Directory -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($relock -and (Lock-InstallerRun) -eq 'Busy') {
            # Another run started meanwhile and owns last-run.json now.
            $script:InstallerRunRecordEnabled = $false
            Write-WarningMessage 'Another run of the installer started after the SYSTEM run; this run leaves last-run.json to it.'
        }
    }
}

<#
.SYNOPSIS
    Decides the exit code of a run that handed its install over to SYSTEM.
.DESCRIPTION
    1 when the SYSTEM run left any app Deferred, so the technician at the console notices them;
    5 when the SYSTEM run did not end in time and was stopped; otherwise the SYSTEM run's own code.
.PARAMETER TaskExitCode
    The SYSTEM run's exit code, or $null.
.PARAMETER DeferredApps
    The apps it deferred.
.OUTPUTS
    [int]
#>
function Get-SystemHandoffExitCode {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[int]]$TaskExitCode,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$DeferredApps = @()
    )

    if ($null -eq $TaskExitCode) {
        return 5
    }
    if (@($DeferredApps | Where-Object { $_ }).Count -gt 0) {
        return 1
    }
    return [int]$TaskExitCode
}

<#
.SYNOPSIS
    Says how the SYSTEM run ended, which apps it deferred and who can install them, and returns the
    hand-started run's exit code (Get-SystemHandoffExitCode).
.PARAMETER Handoff
    Invoke-SystemHandoff's result.
.PARAMETER AccountContext
    Get-InstallAccountContext's result, for the signed-in user's name.
.OUTPUTS
    [int]
#>
function Write-SystemHandoffResult {
    param (
        [Parameter(Mandatory = $true)]
        [object]$Handoff,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$AccountContext
    )

    $deferred = @($Handoff.DeferredApps | Where-Object { $_ })
    if ($null -eq $Handoff.TaskExitCode) {
        Write-ErrorMessage ('The SYSTEM run did not end within {0:N0} minutes and was stopped: apps may be only partly installed. Its transcript is in {1}.' -f ($Handoff.WaitSeconds / 60), (Split-Path -Parent (Get-InstallerRunRecordPath)))
    }
    else {
        Write-Info "The SYSTEM run ended with exit code $($Handoff.TaskExitCode)."
    }
    if ($Handoff.RunRecord) {
        $systemTranscript = $null
        if ($Handoff.RunRecord.Record) {
            $systemTranscript = [string]$Handoff.RunRecord.Record.transcriptPath
        }
        if (-not [string]::IsNullOrWhiteSpace($systemTranscript)) {
            Write-Info "Transcript of the SYSTEM run (its summary, and why any app failed): $systemTranscript"
        }
    }
    elseif ($Handoff.RecordProblem) {
        Write-WarningMessage "The SYSTEM run's result could not be read: $($Handoff.RecordProblem). Which apps it deferred is not known; see its transcript."
    }
    if ($deferred.Count -gt 0) {
        $user = 'the signed-in user'
        if ($AccountContext -and $AccountContext.SessionUser) {
            $user = [string]$AccountContext.SessionUser
        }
        Write-ErrorMessage ('Deferred by the SYSTEM run, so not installed for {0}: {1}.' -f $user, ($deferred -join ', '))
        Write-ErrorMessage ("They need the Endpoint Central user phase (rmm/Invoke-WingetAppSetupUserPhase.ps1, at {0}'s next sign-in) or a run of the installer as {0}. This run exits 1 so that they are not missed." -f $user)
    }
    return (Get-SystemHandoffExitCode -TaskExitCode $Handoff.TaskExitCode -DeferredApps $deferred)
}

<#
.SYNOPSIS
    Builds the run record of a run that handed its install over to SYSTEM.
.DESCRIPTION
    The SYSTEM run's apps, auto-update outcome, restart and winget check, which this record replaces
    in last-run.json, so the user phase still finds the apps it deferred; and handoff, which says
    the run handed over: to ('SYSTEM'), reason ('SourceUnusable'), exitCode (the SYSTEM run's, or
    $null when it was stopped), recordRead (its record was read), deferred (its deferred apps) and
    transcriptPath (its transcript, or $null).
.PARAMETER Handoff
    Invoke-SystemHandoff's result.
.PARAMETER ExitCode
    This run's exit code (Write-SystemHandoffResult).
.OUTPUTS
    [System.Collections.Specialized.OrderedDictionary] (New-InstallerRunRecord)
#>
function New-SystemHandoffRunRecord {
    param (
        [Parameter(Mandatory = $true)]
        [object]$Handoff,

        [Parameter(Mandatory = $true)]
        [int]$ExitCode
    )

    $systemRecord = $null
    if ($Handoff.RunRecord) {
        $systemRecord = $Handoff.RunRecord.Record
    }
    $apps = @()
    $autoUpdates = 'NotRun'
    $autoUpdatesVersion = $null
    $restartRequired = $false
    $wingetUsable = $null
    $wingetSource = $null
    $summaryReached = $false
    $systemTranscript = $null
    if ($systemRecord) {
        $apps = @($systemRecord.apps | Where-Object { $null -ne $_ })
        if ($systemRecord.autoUpdates -and -not [string]::IsNullOrWhiteSpace([string]$systemRecord.autoUpdates.status)) {
            $autoUpdates = [string]$systemRecord.autoUpdates.status
            $autoUpdatesVersion = $systemRecord.autoUpdates.version
        }
        $restartRequired = [bool]$systemRecord.restartRequired
        if ($null -ne $systemRecord.wingetUsable) {
            $wingetUsable = [bool]$systemRecord.wingetUsable
        }
        # The SYSTEM run's own source check (wgt-gq8.66); this run's source is the one it handed over for.
        if ([string]$systemRecord.wingetSource -in @('ok', 'unusable', 'unknown')) {
            $wingetSource = [string]$systemRecord.wingetSource
        }
        $summaryReached = [bool]$systemRecord.summaryReached
        if (-not [string]::IsNullOrWhiteSpace([string]$systemRecord.transcriptPath)) {
            $systemTranscript = [string]$systemRecord.transcriptPath
        }
    }
    $taskExitCode = $null
    if ($null -ne $Handoff.TaskExitCode) {
        $taskExitCode = [int]$Handoff.TaskExitCode
    }
    $handoffEntry = [ordered]@{
        to             = 'SYSTEM'
        reason         = 'SourceUnusable'
        exitCode       = $taskExitCode
        recordRead     = ($null -ne $systemRecord)
        deferred       = [string[]]@($Handoff.DeferredApps | Where-Object { $_ })
        transcriptPath = $systemTranscript
    }
    return (New-InstallerRunRecord -ExitCode $ExitCode -Apps $apps -AutoUpdates $autoUpdates -AutoUpdatesVersion $autoUpdatesVersion -RestartRequired $restartRequired -WingetUsable $wingetUsable -WingetSource $wingetSource -SummaryReached:$summaryReached -Handoff $handoffEntry)
}
