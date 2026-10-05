<#
.SYNOPSIS
    The user phase: installs, for the signed-in user, the apps a run for the whole PC deferred, and
    sets that user's Windows Terminal defaults. Run as the user, at sign-in, never elevated.
.DESCRIPTION
    Work-order item 34. A run as SYSTEM (an RMM agent such as ManageEngine Endpoint Central) installs
    only what installs for the whole PC: an app with no machine-wide installer is reported Deferred
    in last-run.json, and the per-user Windows Terminal defaults are skipped. Neither can be done for
    a user from SYSTEM. This finishes the job in each user's own account; it is what
    rmm/Invoke-WingetAppSetupUserPhase.ps1 runs (an Endpoint Central User Configuration script,
    Every Logon), after it has dot-sourced a checked copy of winget-app-install.ps1.

    It ends at once, printing nothing, when there is nothing to do for this account
    (Get-UserPhaseDecision): no run record, a run that has not reported yet, or this account has
    already finished this run, or tried MaxAttempts times. Otherwise, once per machine run:
      1. It records the attempt first (user-phase.json, Save-UserPhaseState), so an attempt that is
         killed still counts toward MaxAttempts.
      2. It starts a transcript in the user's %LOCALAPPDATA%\winget-app-setup\logs
         (Start-InstallerTranscript -UserPhase), keeping the newest 10.
      3. When the record lists deferred apps: it checks that winget starts for this account (up to
         four checks 15 seconds apart: Windows registers App Installer for an account shortly after
         its first sign-in), updates the winget source for it (Update-UserPhaseWingetSource: on an
         account's first use of winget that also registers the source, which the 15-second
         `winget list` check before each install has no time for) and installs each app with
         `--scope user` (Install-UserPhaseApp), while the time budget lasts. An app the budget no
         longer covers is NotAttempted.
      4. It sets the Windows Terminal defaults (Set-WindowsTerminalDefaults -PassThru: the targeted
         defaultProfile edit and the default terminal application). Unless that reports Applied
         (this account has no Terminal settings.json yet because Terminal was never opened, an edit
         failed, or the step was skipped), the step counts as not done, and a later sign-in tries
         again.
      5. It records the outcome (complete when every deferred app is installed or was already there
         and the Terminal step is done), prints one 'USER PHASE RESULT:' line and returns the exit
         code.
    It never prompts (winget runs with --disable-interactivity and --silent) and never asks for
    elevation itself: it installs with --scope user only, and a per-user installer needs no
    administrator rights. One that elevates itself anyway would still show a UAC prompt, which is
    why an app the user phase installs is worth one check on a pilot PC.
.PARAMETER RunRecordPath
    The machine's run record. Default: Get-InstallerRunRecordPath.
.PARAMETER StatePath
    This account's state. Default: Get-UserPhaseStatePath.
.PARAMETER MaxMinutes
    The time budget, counted from the start of the attempt, so the winget check and the source
    update count toward it. No install starts once less than a minute of it is left, and each
    install's time limit is what is left (at most 30 minutes), so the whole phase takes about this
    long at most, plus the Terminal step. Default 15.
.PARAMETER MaxAttempts
    How many sign-ins may try for one machine run before the user phase gives up on it. Default 3.
.OUTPUTS
    [int] 0 = done, or nothing to do; 1 = a deferred app failed to install or was not attempted in
    the time budget; 2 = winget cannot be started for this account (nothing was installed); 3010 = done,
    but an install needs a restart to finish; 5 = an unexpected error (in the transcript). A later
    sign-in tries again after 1, 2 or 5 while attempts are left.
#>
function Invoke-WingetUserPhase {
    [OutputType([int])]
    param (
        [Parameter(Mandatory = $false)]
        [string]$RunRecordPath = (Get-InstallerRunRecordPath),

        [Parameter(Mandatory = $false)]
        [string]$StatePath = (Get-UserPhaseStatePath),

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 240)]
        [int]$MaxMinutes = 15,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 100)]
        [int]$MaxAttempts = 3
    )

    if (Test-IsSystemAccount) {
        Write-Info 'The user phase installs for the signed-in user, so it has nothing to do as SYSTEM: run it as the user (for example as an Endpoint Central User Configuration script).'
        return 0
    }

    $record = Read-InstallerRunRecord -Path $RunRecordPath
    $state = Read-UserPhaseState -Path $StatePath
    $decision = Get-UserPhaseDecision -Record $record -State $state -MaxAttempts $MaxAttempts
    if (-not $decision.Run) {
        return 0
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $budgetSeconds = $MaxMinutes * 60
    $appRecords = [ordered]@{}
    $terminalStatus = 'NotRun'
    $exitCode = 5
    $newState = [ordered]@{
        schemaVersion        = 1
        recordSha256         = $record.Sha256
        machineRunStartedUtc = $record.StartedUtc
        machineRunBuildId    = $record.BuildId
        attempts             = $decision.Attempt
        complete             = $false
        exitCode             = $null
        updatedUtc           = Format-RunRecordTime -Time ([DateTime]::UtcNow)
        apps                 = @()
        terminalDefaults     = $terminalStatus
        transcriptPath       = $null
    }
    # Counted before any work, so an attempt that is killed (sign-out, the RMM's time limit) still
    # counts toward MaxAttempts.
    [void](Save-UserPhaseState -Path $StatePath -State $newState)

    $previousLogPath = $script:InstallLogPath
    $script:InstallLogPath = Start-InstallerTranscript -UserPhase
    $transcriptStarted = [bool]$script:InstallLogPath
    try {
        if ($script:InstallLogPath) {
            Write-Info "Logging the user phase to: $script:InstallLogPath"
            try {
                [void](Remove-OldInstallerLog -LogDirectory (Split-Path -Parent $script:InstallLogPath) -KeepTranscripts 10 -CurrentTranscriptPath $script:InstallLogPath)
            }
            catch {
                Write-WarningMessage "Could not remove old user-phase logs: $($_.Exception.Message)"
            }
        }
        if ($script:InstallerBuildId) {
            Write-Info "Installer build: $script:InstallerBuildId"
        }
        $buildText = 'unknown build'
        if ($record.BuildId) {
            $buildText = "build $($record.BuildId)"
        }
        Write-Info ('User phase for {0}, attempt {1} of {2}: following up the run for the whole PC that started {3} ({4}, exit code {5}).' -f (Get-ProcessUserName), $decision.Attempt, $MaxAttempts, $record.StartedUtc, $buildText, $record.ExitCode)
        foreach ($invalidId in $record.InvalidDeferredIds) {
            Write-WarningMessage "Ignoring a deferred entry in $($record.Path) that is not a winget package id: '$invalidId'."
        }

        $deferredApps = @($record.DeferredApps)
        $wingetUsable = $true
        if ($deferredApps.Count -eq 0) {
            Write-Info 'The run for the whole PC deferred no apps to this account.'
        }
        else {
            Write-Info ('Apps the run for the whole PC left for each account (installed per-user, with --scope user): {0}' -f ($deferredApps -join ', '))
            $probe = Test-WingetLaunchable -Attempts 4 -RetryDelaySeconds 15
            if (-not $probe.Launchable) {
                $wingetUsable = $false
                $reason = "winget could not be started for this account: $($probe.Reason)"
                Write-ErrorMessage "$reason. Windows sets winget up for an account shortly after its first sign-in; the user phase tries again at the next sign-in."
                foreach ($id in $deferredApps) {
                    $appRecords[$id] = New-AppRunRecord -Id $id -Status 'NotAttempted' -Reason $reason
                }
            }
            else {
                Update-UserPhaseWingetSource
                foreach ($id in $deferredApps) {
                    $remainingSeconds = $budgetSeconds - (Get-UserPhaseElapsedSeconds -Stopwatch $stopwatch)
                    if ($remainingSeconds -lt 60) {
                        Write-WarningMessage "Not installing $id now: the user phase's $MaxMinutes-minute time budget is spent. The next sign-in tries again."
                        $appRecords[$id] = New-AppRunRecord -Id $id -Status 'NotAttempted' -Reason "the user phase's $MaxMinutes-minute time budget was spent"
                        continue
                    }
                    try {
                        $appRecords[$id] = Install-UserPhaseApp -PackageId $id -TimeoutSeconds ([Math]::Min(1800, $remainingSeconds))
                    }
                    catch {
                        Write-ErrorMessage "Failed to install: $id. Error: $_"
                        $appRecords[$id] = New-AppRunRecord -Id $id -Status 'Failed' -Reason "Unexpected error: $_"
                    }
                }
            }
        }

        # The Windows Terminal defaults are per-user, and a run as SYSTEM sets them for nobody. A
        # settings.json appears only once Terminal has been opened, so until then the step is not
        # done and a later sign-in tries again; so does one that failed or was skipped.
        try {
            $terminalStatus = [string](@(Set-WindowsTerminalDefaults -PassThru)[-1])
            if (@('Applied', 'SettingsNotFound', 'Failed', 'Skipped') -notcontains $terminalStatus) {
                $terminalStatus = 'Failed'
            }
            switch ($terminalStatus) {
                'SettingsNotFound' { Write-Info 'Windows Terminal has no settings.json for this account yet (it creates one when it is first opened); the next sign-in sets its default profile.' }
                'Failed' { Write-WarningMessage 'The Windows Terminal defaults could not all be set (see above); the next sign-in tries again.' }
                'Skipped' { Write-WarningMessage 'The Windows Terminal defaults were not set for this account (see above); the next sign-in tries again.' }
            }
        }
        catch {
            $terminalStatus = 'Failed'
            Write-WarningMessage "Windows Terminal configuration failed unexpectedly: $_"
        }

        $records = @($appRecords.Values)
        $unfinished = @($records | Where-Object { @('Installed', 'Skipped') -notcontains $_.status })
        $restartApps = @($records | Where-Object { $_.restartRequired } | ForEach-Object { $_.id })
        if (-not $wingetUsable) {
            $exitCode = 2
        }
        elseif ($unfinished.Count -gt 0) {
            $exitCode = 1
        }
        elseif ($restartApps.Count -gt 0) {
            $exitCode = 3010
            Write-WarningMessage ('Restart: REQUIRED to finish installing {0}.' -f ($restartApps -join ', '))
        }
        else {
            $exitCode = 0
        }
        $newState.complete = ($unfinished.Count -eq 0) -and ($terminalStatus -eq 'Applied')
        if (-not $newState.complete -and $decision.Attempt -ge $MaxAttempts) {
            Write-WarningMessage "This was the last of $MaxAttempts attempts for this run for the whole PC; the user phase does not try again until the next one."
        }
    }
    catch {
        Write-ErrorMessage "UNEXPECTED ERROR - the user phase stopped before it finished: $($_.Exception.Message)"
        if ($_.ScriptStackTrace) {
            Write-ErrorMessage "Stack trace:`n$($_.ScriptStackTrace)"
        }
        $exitCode = 5
    }
    finally {
        $records = @($appRecords.Values)
        $newState.exitCode = $exitCode
        $newState.updatedUtc = Format-RunRecordTime -Time ([DateTime]::UtcNow)
        $newState.apps = $records
        $newState.terminalDefaults = $terminalStatus
        $newState.transcriptPath = $script:InstallLogPath
        [void](Save-UserPhaseState -Path $StatePath -State $newState)
        $log = 'none'
        if ($script:InstallLogPath) {
            $log = $script:InstallLogPath
        }
        Write-Host ('USER PHASE RESULT: exit={0} installed={1} skipped={2} failed={3} terminal={4} attempt={5}/{6} complete={7} log={8}' -f $exitCode, @($records | Where-Object { $_.status -eq 'Installed' }).Count, @($records | Where-Object { $_.status -eq 'Skipped' }).Count, @($records | Where-Object { @('Installed', 'Skipped') -notcontains $_.status }).Count, $terminalStatus, $decision.Attempt, $MaxAttempts, ([string]$newState.complete).ToLowerInvariant(), $log)
        if ($transcriptStarted) {
            try {
                [void](Stop-Transcript)
            }
            catch {
            }
        }
        $script:InstallLogPath = $previousLogPath
    }
    return $exitCode
}
