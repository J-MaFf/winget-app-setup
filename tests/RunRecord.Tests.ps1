# RunRecord.Tests.ps1
# Tests for WingetAppSetup/Private/RunRecord.ps1: the machine-readable outcome of a run, its RESULT
# line and last-run.json (review finding P3-41). How Invoke-WingetInstall fills the record is tested
# in Install.Tests.ps1, and the entry script's records for early exits in EntryPoint.Tests.ps1.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'New-AppRunRecord (review finding P3-41)' {
    It 'Carries the install''s exit code, in decimal and hex' {
        $record = New-AppRunRecord -Id 'Zoom.Zoom' -Status 'Failed' -Reason 'winget install failed; winget exit 0x8A150006' -InstallResult @{ ExitCode = -1978335226; Attempts = 1 }

        $record.id | Should -Be 'Zoom.Zoom'
        $record.status | Should -Be 'Failed'
        $record.reason | Should -Be 'winget install failed; winget exit 0x8A150006'
        $record.code | Should -Be -1978335226
        $record.codeHex | Should -Be '0x8A150006'
        $record.restartRequired | Should -BeFalse
    }

    It 'Reads the exit code of a package-specific installer''s result object too' {
        $record = New-AppRunRecord -Id 'Contoso.Custom' -Status 'Installed' -InstallResult ([pscustomobject]@{ ExitCode = 3010; Installed = $true }) -RestartRequired $true

        $record.code | Should -Be 3010
        $record.codeHex | Should -Be '0x00000BC2'
        $record.restartRequired | Should -BeTrue
    }

    It 'Has no code when no installer ran, and no reason when none was given' {
        $record = New-AppRunRecord -Id 'Git.Git' -Status 'Skipped' -Reason '' -InstallResult $null

        $record.code | Should -BeNullOrEmpty
        $record.codeHex | Should -BeNullOrEmpty
        $record.reason | Should -BeNullOrEmpty
        @($record.Keys) | Should -Be @('id', 'status', 'reason', 'code', 'codeHex', 'restartRequired', 'postInstall', 'postInstallReason')
        # No post-install hook ran (work-order item 38).
        $record.postInstall | Should -BeNullOrEmpty
        $record.postInstallReason | Should -BeNullOrEmpty
    }

    # Work-order item 38: what the app's post-install hook found, for an RMM tool reading
    # last-run.json.
    It 'Carries the post-install result <Status>, with its reason' -ForEach @(
        @{ Status = 'Configured'; Reason = $null; RecordStatus = 'Installed' }
        @{ Status = 'NotConfigured'; Reason = 'no TightVNC password supplied'; RecordStatus = 'Installed' }
        @{ Status = 'Failed'; Reason = 'the service did not start'; RecordStatus = 'Failed' }
    ) {
        $record = New-AppRunRecord -Id 'Contoso.App' -Status $RecordStatus -PostInstall @{ Status = $Status; Reason = $Reason }

        $record.postInstall | Should -Be $Status
        $record.postInstallReason | Should -Be $Reason
    }

    It 'Writes the post-install result into last-run.json' {
        $record = New-InstallerRunRecord -ExitCode 0 -Apps @(New-AppRunRecord -Id 'Contoso.App' -Status 'Installed' -PostInstall @{ Status = 'NotConfigured'; Reason = 'later' })

        $json = ConvertTo-Json -InputObject $record -Depth 6 | ConvertFrom-Json

        $json.apps[0].postInstall | Should -Be 'NotConfigured'
        $json.apps[0].postInstallReason | Should -Be 'later'
    }
}

Describe 'Get-AutoUpdateResultStatus (review finding P3-41)' {
    It 'Returns <Expected> for <Name>' -ForEach @(
        @{ Name = 'no result (the run did not get that far)'; Result = $null; Expected = 'NotRun' }
        @{ Name = 'a configured install'; Result = [pscustomobject]@{ Status = 'Configured'; FrameworkMissing = $false }; Expected = 'Configured' }
        @{ Name = 'an existing install'; Result = [pscustomobject]@{ Status = 'AlreadyPresent'; FrameworkMissing = $false }; Expected = 'AlreadyPresent' }
        @{ Name = 'an existing install without its framework'; Result = [pscustomobject]@{ Status = 'AlreadyPresent'; FrameworkMissing = $true }; Expected = 'AtRisk' }
        @{ Name = 'a skipped install (framework missing)'; Result = [pscustomobject]@{ Status = 'FrameworkMissing'; FrameworkMissing = $true }; Expected = 'FrameworkMissing' }
        @{ Name = 'a failed install'; Result = @{ Status = 'Failed'; Version = $null }; Expected = 'Failed' }
        # Review finding P3-36: the states Install-WingetAutoUpdate added for WAU's scheduled task.
        @{ Name = 'an install whose task will not run'; Result = [pscustomobject]@{ Status = 'Unhealthy'; FrameworkMissing = $false; Problem = 'its scheduled task \WAU\Winget-AutoUpdate is disabled'; CheckFailed = $false }; Expected = 'Unhealthy' }
        @{ Name = 'an install whose task could not be checked'; Result = [pscustomobject]@{ Status = 'Unhealthy'; FrameworkMissing = $false; Problem = 'its scheduled task could not be checked'; CheckFailed = $true }; Expected = 'Unhealthy' }
        @{ Name = 'an existing install without its framework whose task will not run (UNHEALTHY in the summary, not AT RISK)'; Result = [pscustomobject]@{ Status = 'Unhealthy'; FrameworkMissing = $true; Problem = 'its scheduled task is missing'; CheckFailed = $false }; Expected = 'Unhealthy' }
        @{ Name = 'a dry run'; Result = [pscustomobject]@{ Status = 'DryRun'; FrameworkMissing = $false }; Expected = 'DryRun' }
    ) {
        Get-AutoUpdateResultStatus -WauResult $Result | Should -Be $Expected
    }
}

Describe 'New-InstallerRunRecord and Format-InstallerResultLine (review finding P3-41)' {
    BeforeEach {
        $script:savedBuildId = $script:InstallerBuildId
        $script:savedStarted = $script:InstallerRunStartedUtc
        $script:savedLogPath = $script:InstallLogPath
        $script:InstallerBuildId = '1.0.0+1a2b3c4d'
        $script:InstallerRunStartedUtc = [DateTime]::new(2026, 10, 4, 14, 30, 5, [DateTimeKind]::Utc)
        $script:InstallLogPath = 'C:\ProgramData\winget-app-setup\logs\install-20261004-163005.log'
        $script:apps = @(
            (New-AppRunRecord -Id 'Git.Git' -Status 'Installed' -InstallResult @{ ExitCode = 0 }),
            (New-AppRunRecord -Id 'Google.Chrome' -Status 'Installed' -InstallResult @{ ExitCode = 0 } -RestartRequired $true),
            (New-AppRunRecord -Id '7zip.7zip' -Status 'Skipped' -Reason 'already installed'),
            (New-AppRunRecord -Id 'Zoom.Zoom' -Status 'Failed' -Reason 'install failed' -InstallResult @{ ExitCode = 1603 })
        )
    }

    AfterEach {
        $script:InstallerBuildId = $script:savedBuildId
        $script:InstallerRunStartedUtc = $script:savedStarted
        $script:InstallLogPath = $script:savedLogPath
    }

    It 'Records the run: build, times, exit code, counts, apps, auto-updates, restart, winget and the log' {
        $record = New-InstallerRunRecord -ExitCode 1 -Apps $script:apps -AutoUpdates 'Configured' -AutoUpdatesVersion ([version]'2.12.0') -RestartRequired $true -WingetUsable $true -SummaryReached

        @($record.Keys) | Should -Be @('schemaVersion', 'buildId', 'startedUtc', 'endedUtc', 'exitCode', 'summaryReached', 'counts', 'apps', 'autoUpdates', 'restartRequired', 'wingetUsable', 'transcriptPath')
        $record.schemaVersion | Should -Be 1
        $record.buildId | Should -Be '1.0.0+1a2b3c4d'
        $record.startedUtc | Should -Be '2026-10-04T14:30:05Z'
        $record.endedUtc | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
        $record.exitCode | Should -Be 1
        $record.summaryReached | Should -BeTrue
        @($record.counts.Keys) | Should -Be @('installed', 'skipped', 'deferred', 'failed')
        $record.counts.installed | Should -Be 2
        $record.counts.skipped | Should -Be 1
        $record.counts.deferred | Should -Be 0
        $record.counts.failed | Should -Be 1
        @($record.apps | ForEach-Object { $_.id }) | Should -Be @('Git.Git', 'Google.Chrome', '7zip.7zip', 'Zoom.Zoom')
        $record.autoUpdates.status | Should -Be 'Configured'
        $record.autoUpdates.version | Should -Be '2.12.0'
        $record.restartRequired | Should -BeTrue
        $record.wingetUsable | Should -BeTrue
        $record.transcriptPath | Should -Be 'C:\ProgramData\winget-app-setup\logs\install-20261004-163005.log'
    }

    It 'Records a run that ended before anything was installed' {
        $record = New-InstallerRunRecord -ExitCode 2

        $record.summaryReached | Should -BeFalse
        @($record.apps).Count | Should -Be 0
        $record.counts.installed | Should -Be 0
        $record.autoUpdates.status | Should -Be 'NotRun'
        $record.autoUpdates.version | Should -BeNullOrEmpty
        $record.restartRequired | Should -BeFalse
        $record.wingetUsable | Should -BeNullOrEmpty
    }

    It 'Leaves the entry script''s values empty outside it (the imported module)' {
        $script:InstallerBuildId = $null
        $script:InstallerRunStartedUtc = $null
        $script:InstallLogPath = $null

        $record = New-InstallerRunRecord -ExitCode 0

        $record.buildId | Should -BeNullOrEmpty
        $record.startedUtc | Should -BeNullOrEmpty
        $record.transcriptPath | Should -BeNullOrEmpty
        Format-InstallerResultLine -Record $record | Should -Be 'RESULT: exit=0 installed=0 skipped=0 deferred=0 failed=0 autoupdates=NotRun restart=no build=unknown log=none'
    }

    It 'Formats one line of key=value pairs in a fixed order, with the log path last' {
        $record = New-InstallerRunRecord -ExitCode 1 -Apps $script:apps -AutoUpdates 'Configured' -RestartRequired $true -SummaryReached

        Format-InstallerResultLine -Record $record | Should -Be 'RESULT: exit=1 installed=2 skipped=1 deferred=0 failed=1 autoupdates=Configured restart=yes build=1.0.0+1a2b3c4d log=C:\ProgramData\winget-app-setup\logs\install-20261004-163005.log'
    }

    It 'Counts deferred apps on their own, neither installed nor failed, in the record and the RESULT line (review finding P3-22)' {
        # A run as SYSTEM or under cross-user elevation leaves an app with no machine-wide installer
        # for the signed-in user: Deferred, which the RESULT line always carries, 0 or not.
        $apps = $script:apps + @(
            (New-AppRunRecord -Id 'Contoso.UserOnly' -Status 'Deferred' -Reason 'winget found no machine-wide installer for it' -InstallResult @{ ExitCode = -1978335216; NoMachineScopeInstaller = $true }),
            (New-AppRunRecord -Id 'Contoso.UserOnlyToo' -Status 'Deferred' -Reason 'winget found no machine-wide installer for it')
        )

        $record = New-InstallerRunRecord -ExitCode 1 -Apps $apps -AutoUpdates 'Configured' -SummaryReached

        $record.counts.installed | Should -Be 2
        $record.counts.skipped | Should -Be 1
        $record.counts.deferred | Should -Be 2
        $record.counts.failed | Should -Be 1
        @($record.apps | Where-Object { $_.status -eq 'Deferred' })[0].codeHex | Should -Be '0x8A150010'
        Format-InstallerResultLine -Record $record | Should -Match '^RESULT: exit=1 installed=2 skipped=1 deferred=2 failed=1 autoupdates=Configured '
    }

    It 'Names an unhealthy Winget-AutoUpdate in the RESULT line of a run that exits 8 (review finding P3-36)' {
        $wauResult = [pscustomobject]@{ Status = 'Unhealthy'; Version = [version]'2.12.0'; FrameworkMissing = $false; RestartRequired = $false; Problem = 'its scheduled task is missing'; CheckFailed = $false }
        $exitCode = Get-InstallerExitCode -FailedAppCount 0 -WingetUsable $true -AutoUpdatesHealthy $false
        $record = New-InstallerRunRecord -ExitCode $exitCode -Apps @($script:apps[0]) -AutoUpdates (Get-AutoUpdateResultStatus -WauResult $wauResult) -AutoUpdatesVersion $wauResult.Version -SummaryReached

        $record.exitCode | Should -Be 8
        $record.autoUpdates.status | Should -Be 'Unhealthy'
        Format-InstallerResultLine -Record $record | Should -Match '^RESULT: exit=8 installed=1 skipped=0 deferred=0 failed=0 autoupdates=Unhealthy restart=no '
    }
}

Describe 'Save-InstallerRunRecord (review finding P3-41)' {
    BeforeEach {
        Mock Write-WarningMessage { }
        $script:directory = Join-Path $TestDrive ('logs-' + [Guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $script:directory -Force)
        $script:record = New-InstallerRunRecord -ExitCode 1 -Apps @(
            (New-AppRunRecord -Id 'Zoom.Zoom' -Status 'Failed' -Reason 'install failed' -InstallResult @{ ExitCode = -1978335226 })
        ) -AutoUpdates 'Configured' -AutoUpdatesVersion '2.12.0' -WingetUsable $true -SummaryReached
    }

    It 'Writes last-run.json as JSON that reads back with every field' {
        $path = Save-InstallerRunRecord -Record $script:record -Directory $script:directory

        $path | Should -Be (Join-Path $script:directory 'last-run.json')
        $json = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
        $json.exitCode | Should -Be 1
        $json.summaryReached | Should -BeTrue
        $json.counts.deferred | Should -Be 0
        $json.counts.failed | Should -Be 1
        @($json.apps).Count | Should -Be 1
        $json.apps[0].id | Should -Be 'Zoom.Zoom'
        $json.apps[0].code | Should -Be -1978335226
        $json.apps[0].codeHex | Should -Be '0x8A150006'
        $json.autoUpdates.status | Should -Be 'Configured'
        $json.autoUpdates.version | Should -Be '2.12.0'
        $json.wingetUsable | Should -BeTrue
    }

    It 'Writes UTF-8 without a byte order mark' {
        $path = Save-InstallerRunRecord -Record $script:record -Directory $script:directory

        $bytes = [System.IO.File]::ReadAllBytes($path)
        $bytes[0] | Should -Be ([byte][char]'{')
    }

    It 'Replaces the previous record, and leaves no temporary file behind' {
        Set-Content -LiteralPath (Join-Path $script:directory 'last-run.json') -Value '{"exitCode": 0, "old": true}'

        [void](Save-InstallerRunRecord -Record $script:record -Directory $script:directory)

        (Get-Content -Raw -LiteralPath (Join-Path $script:directory 'last-run.json') | ConvertFrom-Json).exitCode | Should -Be 1
        @(Get-ChildItem -LiteralPath $script:directory | ForEach-Object { $_.Name }) | Should -Be @('last-run.json')
    }

    It 'Keeps an apps list with one app a list in the JSON' {
        $path = Save-InstallerRunRecord -Record $script:record -Directory $script:directory

        (Get-Content -Raw -LiteralPath $path) | Should -Match '"apps":\s*\['
    }

    It 'Warns and returns $null when the record cannot be written' {
        $result = Save-InstallerRunRecord -Record $script:record -Directory (Join-Path $TestDrive 'missing-folder')

        $result | Should -BeNullOrEmpty
        Should -Invoke Write-WarningMessage -Times 1 -Exactly -ParameterFilter { $Message -match '^Could not write the run record .*last-run\.json: ' }
    }
}

Describe 'Complete-InstallerRun (review finding P3-41)' {
    BeforeEach {
        $script:savedPending = $script:InstallerRunReportPending
        $script:completeEvents = [System.Collections.Generic.List[string]]::new()
        Mock Write-InstallerEarlyExitResult { $script:completeEvents.Add("report:$ExitCode"); $null }
        Mock Unlock-InstallerRun { $script:completeEvents.Add('unlock') }
    }

    AfterEach {
        $script:InstallerRunReportPending = $script:savedPending
    }

    It 'Reports a run that has not reported yet, once, then releases the run lock' {
        $script:InstallerRunReportPending = $true

        Complete-InstallerRun -ExitCode 2
        Complete-InstallerRun -ExitCode 5

        $script:completeEvents | Should -Be @('report:2', 'unlock', 'unlock')
        $script:InstallerRunReportPending | Should -BeFalse
    }

    It 'Only releases the run lock for a run that reported at its summary, a dry run or the bootstrap phase' {
        $script:InstallerRunReportPending = $false

        Complete-InstallerRun -ExitCode 0

        $script:completeEvents | Should -Be @('unlock')
    }

    It 'Still releases the run lock when reporting fails' {
        $script:InstallerRunReportPending = $true
        Mock Write-InstallerEarlyExitResult { throw 'disk full' }

        { Complete-InstallerRun -ExitCode 1 } | Should -Not -Throw

        $script:completeEvents | Should -Be @('unlock')
    }
}

Describe 'Write-InstallerRunResult and Write-InstallerEarlyExitResult (review finding P3-41)' {
    BeforeEach {
        $script:savedRecordEnabled = $script:InstallerRunRecordEnabled
        $script:savedLogPath = $script:InstallLogPath
        $script:savedAppRecords = $script:InstallerAppRecords
        $script:savedAutoUpdate = $script:InstallerAutoUpdateResult
        $script:logDirectory = Join-Path $TestDrive ('logs-' + [Guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $script:logDirectory -Force)
        $script:InstallLogPath = Join-Path $script:logDirectory 'install-20261004-163005.log'
        $script:InstallerRunRecordEnabled = $true
        $script:InstallerAppRecords = $null
        $script:InstallerAutoUpdateResult = $null
        $script:events = [System.Collections.Generic.List[string]]::new()
        Mock Write-Host { $script:events.Add("host:$Object") }
        Mock Save-InstallerRunRecord { $script:events.Add('save'); Join-Path $Directory 'last-run.json' }
    }

    AfterEach {
        $script:InstallerRunRecordEnabled = $script:savedRecordEnabled
        $script:InstallLogPath = $script:savedLogPath
        $script:InstallerAppRecords = $script:savedAppRecords
        $script:InstallerAutoUpdateResult = $script:savedAutoUpdate
    }

    It 'Writes last-run.json next to the transcript, then prints the RESULT line last' {
        $path = Write-InstallerRunResult -Record (New-InstallerRunRecord -ExitCode 0)

        $path | Should -Be (Join-Path $script:logDirectory 'last-run.json')
        $script:events.Count | Should -Be 2
        $script:events[0] | Should -Be 'save'
        $script:events[1] | Should -Match '^host:RESULT: exit=0 '
        Should -Invoke Save-InstallerRunRecord -Times 1 -Exactly -ParameterFilter { $Directory -eq $script:logDirectory }
    }

    It 'Only prints the RESULT line for a run that does not write the record (dry run, not elevated, another run in progress, the module)' {
        $script:InstallerRunRecordEnabled = $false

        $path = Write-InstallerRunResult -Record (New-InstallerRunRecord -ExitCode 6)

        $path | Should -BeNullOrEmpty
        Should -Invoke Save-InstallerRunRecord -Times 0
        $script:events | Should -Be @("host:RESULT: exit=6 installed=0 skipped=0 deferred=0 failed=0 autoupdates=NotRun restart=no build=$(if ($script:InstallerBuildId) { $script:InstallerBuildId } else { 'unknown' }) log=$($script:InstallLogPath)")
    }

    It 'Writes no record without a transcript to put it next to' {
        $script:InstallLogPath = $null

        [void](Write-InstallerRunResult -Record (New-InstallerRunRecord -ExitCode 0))

        Should -Invoke Save-InstallerRunRecord -Times 0
        Should -Invoke Write-Host -Times 1 -Exactly
    }

    It 'Reports an unfinished run with the apps and auto-update outcome it had recorded' {
        $appRecords = [ordered]@{}
        $appRecords['Git.Git'] = New-AppRunRecord -Id 'Git.Git' -Status 'Installed' -InstallResult @{ ExitCode = 0 } -RestartRequired $true
        $appRecords['Zoom.Zoom'] = New-AppRunRecord -Id 'Zoom.Zoom' -Status 'Failed' -Reason 'install failed'
        $appRecords['Contoso.UserOnly'] = New-AppRunRecord -Id 'Contoso.UserOnly' -Status 'Deferred' -Reason 'winget found no machine-wide installer for it'
        $script:InstallerAppRecords = $appRecords
        $script:InstallerAutoUpdateResult = [pscustomobject]@{ Status = 'Configured'; Version = [version]'2.12.0' }
        $script:savedRecord = $null
        Mock Write-InstallerRunResult { $script:savedRecord = $Record }

        [void](Write-InstallerEarlyExitResult -ExitCode 5)

        $script:savedRecord.exitCode | Should -Be 5
        $script:savedRecord.summaryReached | Should -BeFalse
        $script:savedRecord.counts.installed | Should -Be 1
        $script:savedRecord.counts.deferred | Should -Be 1
        $script:savedRecord.counts.failed | Should -Be 1
        $script:savedRecord.autoUpdates.status | Should -Be 'Configured'
        $script:savedRecord.autoUpdates.version | Should -Be '2.12.0'
        $script:savedRecord.restartRequired | Should -BeTrue
        $script:savedRecord.wingetUsable | Should -BeNullOrEmpty
    }

    It 'Reports an early exit with nothing recorded as no apps and auto-updates NotRun' {
        $script:savedRecord = $null
        Mock Write-InstallerRunResult { $script:savedRecord = $Record }

        [void](Write-InstallerEarlyExitResult -ExitCode 2)

        $script:savedRecord.exitCode | Should -Be 2
        @($script:savedRecord.apps).Count | Should -Be 0
        $script:savedRecord.autoUpdates.status | Should -Be 'NotRun'
        $script:savedRecord.restartRequired | Should -BeFalse
    }
}

Describe 'Save-InstallerRunStartRecord (review of finding P3-41)' {
    BeforeEach {
        $script:savedRecordEnabled = $script:InstallerRunRecordEnabled
        $script:savedLogPath = $script:InstallLogPath
        $script:savedStartedUtc = $script:InstallerRunStartedUtc
        $script:logDirectory = Join-Path $TestDrive ('logs-' + [Guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $script:logDirectory -Force)
        $script:InstallLogPath = Join-Path $script:logDirectory 'install-20261004-163005.log'
        $script:InstallerRunRecordEnabled = $true
        $script:InstallerRunStartedUtc = [DateTime]::new(2026, 10, 4, 16, 30, 5, [DateTimeKind]::Utc)
        Mock Write-Host { }
        Mock Write-WarningMessage { }
    }

    AfterEach {
        $script:InstallerRunRecordEnabled = $script:savedRecordEnabled
        $script:InstallLogPath = $script:savedLogPath
        $script:InstallerRunStartedUtc = $script:savedStartedUtc
    }

    It 'Replaces the previous run''s record with one that has no exit code yet, and prints nothing' {
        # A run killed later (an RMM time limit) never reports: its record must not be the previous
        # run's, which may say exit code 0.
        $recordPath = Join-Path $script:logDirectory 'last-run.json'
        Set-Content -LiteralPath $recordPath -Value '{ "exitCode": 0, "startedUtc": "2026-10-03T08:00:00Z", "summaryReached": true }' -Encoding UTF8

        Save-InstallerRunStartRecord | Should -Be $recordPath

        $text = Get-Content -Raw -LiteralPath $recordPath
        $text | Should -Match '"exitCode":\s*null'
        $text | Should -Match '"endedUtc":\s*null'
        $text | Should -Match '"startedUtc":\s*"2026-10-04T16:30:05Z"'
        $record = $text | ConvertFrom-Json
        $record.summaryReached | Should -BeFalse
        @($record.apps).Count | Should -Be 0
        $record.wingetUsable | Should -BeNullOrEmpty
        $record.transcriptPath | Should -Be $script:InstallLogPath
        Should -Invoke Write-Host -Times 0
    }

    It 'Writes nothing for a run that does not write the record, or without a transcript' {
        $script:InstallerRunRecordEnabled = $false
        Save-InstallerRunStartRecord | Should -BeNullOrEmpty

        $script:InstallerRunRecordEnabled = $true
        $script:InstallLogPath = $null
        Save-InstallerRunStartRecord | Should -BeNullOrEmpty

        Test-Path -LiteralPath (Join-Path $script:logDirectory 'last-run.json') | Should -BeFalse
    }
}
