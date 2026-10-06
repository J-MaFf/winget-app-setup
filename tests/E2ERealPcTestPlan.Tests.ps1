# E2ERealPcTestPlan.Tests.ps1
# Tests for e2e/Invoke-RealPcTestPlan.ps1, the real-PC owner-test-plan harness (bead wgt-gq8.60).
# The install, scheduled-task and ACL-reading work needs Windows; the pure parts tested here read
# only what they are given: stage ordering and dependency logic (-Stage / -SkipStage), the change
# plan, the gate decision and the -ReportPath check (the refusal paths), the evaluation of each
# stage's checks from fixture last-run.json files, transcripts and console output, the ACL/SDDL
# comparison, the secret scans, the one-liner and module-query scripts, and the report and
# exit-code logic. The entry point and two stages also run here with every changing and
# Windows-only command mocked. Dot-sourcing the harness defines its functions and runs nothing
# (its main block is guarded), as the other e2e scripts are loaded by their tests.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    # Pulls in the harness and, through it, e2e/Invoke-SystemInstallPass.ps1 and its chain
    # (Invoke-InstallPass.ps1 -> TranscriptAssertions.ps1), so Get-InstallPassVerdict and
    # ConvertFrom-InstallTranscript are available to the evaluators under test.
    . (Join-Path $script:RepoRoot 'e2e/Invoke-RealPcTestPlan.ps1')

    $script:FixtureDirectory = Join-Path $PSScriptRoot 'fixtures/e2e'
    $script:HarnessPath = Join-Path $script:RepoRoot 'e2e/Invoke-RealPcTestPlan.ps1'

    function Get-FirstRunRecord {
        $text = [string](Get-Content -Raw -LiteralPath (Join-Path $script:FixtureDirectory 'realpc-firstrun-last-run.json'))
        return (ConvertFrom-Json -InputObject $text)
    }

    # A parsed transcript (Name + Parsed) from constructed lines, like E2ESystemInstallPass does.
    function New-RealPcTestTranscript {
        param (
            [string]$AutoUpdates = 'Configured (Winget-AutoUpdate v2.12.0).',
            [switch]$RuntimeInstalled
        )
        $lines = @('Installer build: 1.0.0+5ea1f00d')
        if ($RuntimeInstalled) {
            $lines += 'Windows App Runtime: installed Microsoft.WindowsAppRuntime.1.8 8000.994.2142.0 (X64) for all users.'
        }
        $lines += @('Summary:', '', 'Status    Apps', '------    ----', 'Installed 7zip.7zip')
        $lines += "Auto-updates: $AutoUpdates"
        return [pscustomobject]@{ Name = 'install-20261006-100000.log'; Parsed = (ConvertFrom-InstallTranscript -Content ($lines -join "`n")) }
    }

    # An expectation object as Get-SystemPassAppExpectation returns.
    function New-RealPcExpectation {
        param (
            [Parameter(Mandatory = $true)][string]$Id,
            [Parameter(Mandatory = $true)][string]$Expected,
            [string]$Reason = $null,
            [string[]]$AlreadyPresentReasons = @('already installed'),
            [bool]$MustInstall = $false
        )
        return [pscustomobject]@{ Id = $Id; Expected = $Expected; Reason = $Reason; AlreadyPresentReasons = $AlreadyPresentReasons; MustInstall = $MustInstall }
    }

    # A Get-DirectoryAccessSummary-shaped object.
    function New-RealPcAclSummary {
        param (
            [string]$OwnerSid = 'S-1-5-32-544',
            [bool]$InheritanceProtected = $true,
            [object[]]$Rules = @(
                @{ Sid = 'S-1-5-18'; Rights = 2032127 },
                @{ Sid = 'S-1-5-32-544'; Rights = 2032127 }
            )
        )
        $accessRules = @(foreach ($rule in $Rules) {
                $type = 'Allow'
                if ($rule.Type) { $type = $rule.Type }
                [pscustomobject]@{ Sid = $rule.Sid; AccessControlType = $type; Rights = [long]$rule.Rights; InheritOnly = [bool]$rule.InheritOnly }
            })
        return [pscustomobject]@{ OwnerSid = $OwnerSid; InheritanceProtected = $InheritanceProtected; AccessRules = $accessRules }
    }

    # A report-path state as Get-RealPcReportPathState returns.
    function New-RealPcReportPathState {
        param ([bool]$Exists = $false, [bool]$IsDirectory = $false, [bool]$IsEmpty = $true, [bool]$IsReparsePoint = $false, [bool]$ZipExists = $false, [bool]$LocalFolderInUse = $false)
        return [pscustomobject]@{ Exists = $Exists; IsDirectory = $IsDirectory; IsEmpty = $IsEmpty; IsReparsePoint = $IsReparsePoint; ZipExists = $ZipExists; LocalFolderInUse = $LocalFolderInUse }
    }
}

Describe 'Resolve-RealPcTestPlanStage' {
    It 'Runs every non-optional stage in order with no selection' {
        $result = Resolve-RealPcTestPlanStage
        @($result.Stages | ForEach-Object { $_.Name }) | Should -Be @('Preflight', 'LinkGuardSetup', 'FirstRun', 'ReRun', 'System', 'TimeBudget', 'Diagnostics', 'Uninstaller', 'Report')
        $result.Errors | Should -BeNullOrEmpty
    }

    It 'Leaves the optional WinGetClient stage out unless asked' {
        $without = Resolve-RealPcTestPlanStage
        @($without.Stages | ForEach-Object { $_.Name }) | Should -Not -Contain 'WinGetClient'
        $with = Resolve-RealPcTestPlanStage -IncludeOptional @('WinGetClient')
        @($with.Stages | ForEach-Object { $_.Name }) | Should -Contain 'WinGetClient'
    }

    It 'Adds a requested stage''s dependencies and explains them' {
        $result = Resolve-RealPcTestPlanStage -Requested @('Uninstaller')
        $names = @($result.Stages | ForEach-Object { $_.Name })
        $names | Should -Contain 'FirstRun'
        $names | Should -Contain 'LinkGuardSetup'
        $names | Should -Contain 'Report'
        ($result.Explanations -join ' ') | Should -Match "Added 'FirstRun'"
    }

    It 'Always keeps Preflight and Report even when only one stage is requested' {
        $result = Resolve-RealPcTestPlanStage -Requested @('Diagnostics')
        @($result.Stages | ForEach-Object { $_.Name }) | Should -Contain 'Preflight'
        @($result.Stages | ForEach-Object { $_.Name }) | Should -Contain 'Report'
    }

    It 'Brings FirstRun along with LinkGuardSetup, which plants a junction only FirstRun removes' {
        $result = Resolve-RealPcTestPlanStage -Requested @('LinkGuardSetup')
        @($result.Stages | ForEach-Object { $_.Name }) | Should -Be @('Preflight', 'LinkGuardSetup', 'FirstRun', 'Report')
        ($result.Explanations -join ' ') | Should -Match "Added 'FirstRun': 'LinkGuardSetup'"
    }

    It 'Refuses to skip FirstRun while LinkGuardSetup runs' {
        $result = Resolve-RealPcTestPlanStage -Requested @('LinkGuardSetup') -Skip @('FirstRun')
        @($result.Stages | ForEach-Object { $_.Name }) | Should -Contain 'FirstRun'
        ($result.Explanations -join ' ') | Should -Match "Cannot skip 'FirstRun': LinkGuardSetup"
    }

    It 'Refuses to skip a stage others still depend on, and keeps it' {
        $result = Resolve-RealPcTestPlanStage -Skip @('FirstRun')
        @($result.Stages | ForEach-Object { $_.Name }) | Should -Contain 'FirstRun'
        ($result.Explanations -join ' ') | Should -Match "Cannot skip 'FirstRun'"
    }

    It 'Skips a leaf stage nothing depends on' {
        $result = Resolve-RealPcTestPlanStage -Skip @('Diagnostics')
        @($result.Stages | ForEach-Object { $_.Name }) | Should -Not -Contain 'Diagnostics'
    }

    It 'Cannot skip an always-run stage' {
        $result = Resolve-RealPcTestPlanStage -Skip @('Report')
        @($result.Stages | ForEach-Object { $_.Name }) | Should -Contain 'Report'
        ($result.Explanations -join ' ') | Should -Match "Cannot skip 'Report'"
    }

    It 'Reports an unknown stage name as an error and returns no stages' {
        $result = Resolve-RealPcTestPlanStage -Requested @('Nope')
        $result.Stages | Should -BeNullOrEmpty
        ($result.Errors -join ' ') | Should -Match "unknown stage 'Nope'"
    }
}

Describe 'Get-RealPcGateDecision (refusal paths)' {
    It 'Plan-only never proceeds and exits 0' {
        $gate = Get-RealPcGateDecision -PlanOnly
        $gate.Proceed | Should -BeFalse
        $gate.ExitCode | Should -Be 0
    }

    It 'Refuses with exit 2 when not elevated' {
        $gate = Get-RealPcGateDecision -Elevated $false -Confirmed $true
        $gate.Proceed | Should -BeFalse
        $gate.ExitCode | Should -Be 2
        $gate.Reason | Should -Match 'elevated'
    }

    It 'Refuses with exit 2 when elevated but not confirmed' {
        $gate = Get-RealPcGateDecision -Elevated $true -Confirmed $false
        $gate.Proceed | Should -BeFalse
        $gate.ExitCode | Should -Be 2
        $gate.Reason | Should -Match 'disposable'
    }

    It 'Proceeds when elevated and confirmed' {
        $gate = Get-RealPcGateDecision -Elevated $true -Confirmed $true
        $gate.Proceed | Should -BeTrue
        $gate.ExitCode | Should -Be 0
    }
}

Describe 'Get-RealPcReportPathProblem' {
    It 'Accepts a folder that does not exist yet' {
        Get-RealPcReportPathProblem -Path 'C:\r' -State (New-RealPcReportPathState) | Should -BeNullOrEmpty
    }

    It 'Accepts an existing empty folder' {
        Get-RealPcReportPathProblem -Path 'C:\r' -State (New-RealPcReportPathState -Exists $true -IsDirectory $true -IsEmpty $true) | Should -BeNullOrEmpty
    }

    It 'Refuses a folder that is not empty, since all of it would go into the zip' {
        Get-RealPcReportPathProblem -Path 'C:\Users\me\Desktop' -State (New-RealPcReportPathState -Exists $true -IsDirectory $true -IsEmpty $false) | Should -Match 'not empty'
    }

    It 'Refuses a link, a file, an existing zip and a local folder in use' {
        Get-RealPcReportPathProblem -Path 'C:\r' -State (New-RealPcReportPathState -Exists $true -IsDirectory $true -IsReparsePoint $true) | Should -Match 'is a link'
        Get-RealPcReportPathProblem -Path 'C:\r' -State (New-RealPcReportPathState -Exists $true -IsDirectory $false) | Should -Match 'is a file'
        Get-RealPcReportPathProblem -Path 'C:\r' -State (New-RealPcReportPathState -ZipExists $true) | Should -Match 'r\.zip'' already exists'
        Get-RealPcReportPathProblem -Path 'C:\r' -State (New-RealPcReportPathState -LocalFolderInUse $true) | Should -Match 'r-local'
    }

    It 'Reads the state of a real folder (Get-RealPcReportPathState)' {
        $folder = Join-Path $TestDrive 'report-in-use'
        $null = New-Item -ItemType Directory -Path $folder
        Set-Content -LiteralPath (Join-Path $folder 'old.txt') -Value 'x'
        $state = Get-RealPcReportPathState -Path $folder
        $state.Exists | Should -BeTrue
        $state.IsEmpty | Should -BeFalse
        Get-RealPcReportPathProblem -Path $folder -State $state | Should -Match 'not empty'
        (Get-RealPcReportPathState -Path (Join-Path $TestDrive 'fresh')).Exists | Should -BeFalse
    }
}

Describe 'Get-RealPcChangePlan' {
    It 'Names the temporary user only when the link-guard stage runs' {
        $stages = (Resolve-RealPcTestPlanStage).Stages
        $plan = Get-RealPcChangePlan -Stages $stages -ReportFolder 'C:\report' -PublicVictimFolder 'C:\Users\Public\victim'
        ($plan -join "`n") | Should -Match 'temporary STANDARD local user'
    }

    It 'Omits the temporary-user and uninstaller lines when those stages are not selected' {
        $registry = Get-RealPcTestPlanStage
        $stages = @($registry | Where-Object { $_.Name -in @('Preflight', 'Diagnostics', 'Report') })
        $plan = Get-RealPcChangePlan -Stages $stages -ReportFolder 'C:\report'
        ($plan -join "`n") | Should -Not -Match 'temporary STANDARD local user'
        ($plan -join "`n") | Should -Not -Match 'with the uninstaller'
    }

    It 'Says the uninstaller removes PowerShell 7, and Windows Terminal unless it hosts the window' {
        $plan = (Get-RealPcChangePlan -Stages (Resolve-RealPcTestPlanStage).Stages -ReportFolder 'C:\report') -join "`n"
        $plan | Should -Match 'PowerShell 7 is removed too'
        $plan | Should -Match 'Windows Terminal unless it hosts this window'
        $plan | Should -Not -Match 'except PowerShell 7'
    }

    It 'Says -ResetProgramData renames the existing folder aside, and only then' {
        $stages = (Resolve-RealPcTestPlanStage).Stages
        ((Get-RealPcChangePlan -Stages $stages -ResetProgramData) -join "`n") | Should -Match 'rename it to winget-app-setup-old-<time>.*never delete'
        ((Get-RealPcChangePlan -Stages $stages) -join "`n") | Should -Not -Match 'winget-app-setup-old'
    }

    It 'Always says where the report, the zip and the local manual steps go' {
        $plan = (Get-RealPcChangePlan -Stages @() -ReportFolder 'C:\report-xyz') -join "`n"
        $plan | Should -Match 'C:\\report-xyz'
        $plan | Should -Match 'C:\\report-xyz-local \(never zipped\)'
    }
}

Describe 'Invoke-RealPcTestPlanMain (plan only and refusals change nothing)' {
    BeforeAll {
        # Every command that changes the PC, or a stage that would.
        $script:ChangingCommands = @(
            'New-Item', 'Rename-Item', 'Remove-Item', 'Set-Content', 'Copy-Item', 'Move-Item', 'Start-Transcript',
            'New-LocalUser', 'Register-ScheduledTask', 'Start-ScheduledTask', 'Unregister-ScheduledTask',
            'Invoke-RealPcProcess', 'Invoke-RealPcInstaller', 'Invoke-RealPcModuleJson', 'Remove-RealPcHarnessLeftover',
            'Invoke-RealPcPreflightStage', 'Invoke-RealPcLinkGuardSetupStage', 'Invoke-RealPcFirstRunStage', 'Invoke-RealPcReRunStage',
            'Invoke-RealPcSystemStage', 'Invoke-RealPcTimeBudgetStage', 'Invoke-RealPcDiagnosticsStage', 'Invoke-RealPcUninstallerStage'
        )
    }

    BeforeEach {
        Mock New-Item { }
        Mock Rename-Item { }
        Mock Remove-Item { }
        Mock Set-Content { }
        Mock Copy-Item { }
        Mock Move-Item { }
        Mock Start-Transcript { }
        Mock New-LocalUser { }
        Mock Register-ScheduledTask { }
        Mock Start-ScheduledTask { }
        Mock Unregister-ScheduledTask { }
        Mock Invoke-RealPcProcess { }
        Mock Invoke-RealPcInstaller { }
        Mock Invoke-RealPcModuleJson { }
        Mock Remove-RealPcHarnessLeftover { }
        Mock Invoke-RealPcPreflightStage { }
        Mock Invoke-RealPcLinkGuardSetupStage { }
        Mock Invoke-RealPcFirstRunStage { }
        Mock Invoke-RealPcReRunStage { }
        Mock Invoke-RealPcSystemStage { }
        Mock Invoke-RealPcTimeBudgetStage { }
        Mock Invoke-RealPcDiagnosticsStage { }
        Mock Invoke-RealPcUninstallerStage { }
        Mock Read-Host { 'no' }
        Mock Test-RealPcElevated { $true }
        $script:MainReport = Join-Path $TestDrive ('report-' + [guid]::NewGuid().ToString('N'))
    }

    It '-WhatIf prints the plan, changes nothing and returns 0' {
        $exitCode = @(Invoke-RealPcTestPlanMain -WhatIf -ReportPath $script:MainReport)[-1]
        $exitCode | Should -Be 0
        foreach ($command in $script:ChangingCommands) {
            Should -Invoke $command -Times 0 -Exactly -Because "-WhatIf must not run $command"
        }
        Should -Invoke Read-Host -Times 0 -Exactly
        Test-Path -LiteralPath $script:MainReport | Should -BeFalse
    }

    It '-Plan is the same as -WhatIf' {
        @(Invoke-RealPcTestPlanMain -Plan -ReportPath $script:MainReport)[-1] | Should -Be 0
        Should -Invoke Invoke-RealPcFirstRunStage -Times 0 -Exactly
        Should -Invoke New-Item -Times 0 -Exactly
    }

    It 'Refuses with 2 and changes nothing when not elevated' {
        Mock Test-RealPcElevated { $false }
        @(Invoke-RealPcTestPlanMain -ConfirmDisposableMachine -ReportPath $script:MainReport)[-1] | Should -Be 2
        foreach ($command in $script:ChangingCommands) {
            Should -Invoke $command -Times 0 -Exactly -Because "a refused run must not run $command"
        }
    }

    It 'Refuses with 2 and changes nothing when the operator does not type the phrase' {
        @(Invoke-RealPcTestPlanMain -ReportPath $script:MainReport)[-1] | Should -Be 2
        Should -Invoke Read-Host -Times 1 -Exactly
        foreach ($command in $script:ChangingCommands) {
            Should -Invoke $command -Times 0 -Exactly -Because "an unconfirmed run must not run $command"
        }
    }

    It 'Refuses with 2 a -ReportPath that already holds files' {
        $inUse = Join-Path $TestDrive 'in-use'
        $null = [System.IO.Directory]::CreateDirectory($inUse)
        [System.IO.File]::WriteAllText((Join-Path $inUse 'keep.txt'), 'x')
        @(Invoke-RealPcTestPlanMain -ConfirmDisposableMachine -ReportPath $inUse)[-1] | Should -Be 2
        Should -Invoke Invoke-RealPcPreflightStage -Times 0 -Exactly
        Should -Invoke New-Item -Times 0 -Exactly
    }

    It 'Refuses with 2 an unknown stage name' {
        @(Invoke-RealPcTestPlanMain -Stage 'Nope' -ConfirmDisposableMachine -ReportPath $script:MainReport)[-1] | Should -Be 2
        Should -Invoke Invoke-RealPcPreflightStage -Times 0 -Exactly
    }
}

Describe 'Get-RealPcInstallExitVerdict' {
    It 'Passes exit 0 and 3010' {
        (Get-RealPcInstallExitVerdict -ExitCode 0).Passed | Should -BeTrue
        (Get-RealPcInstallExitVerdict -ExitCode 3010).Passed | Should -BeTrue
    }

    It 'Fails exit 2' {
        (Get-RealPcInstallExitVerdict -ExitCode 2).Passed | Should -BeFalse
    }

    It 'Fails an exit code that was not read, instead of reading it as 0' {
        $verdict = Get-RealPcInstallExitVerdict -ExitCode $null
        $verdict.Passed | Should -BeFalse
        $verdict.Message | Should -Match 'exit code not read'
    }

    It 'Accepts exit 8 only with the framework-missing reason in the transcript' {
        $good = New-RealPcTestTranscript -AutoUpdates 'NOT CONFIGURED - Microsoft.WindowsAppRuntime.1.8 is missing, and Winget-AutoUpdate would leave winget unusable without it.'
        (Get-RealPcInstallExitVerdict -ExitCode 8 -Transcript $good).Passed | Should -BeTrue
        $bad = New-RealPcTestTranscript -AutoUpdates 'FAILED - something else'
        (Get-RealPcInstallExitVerdict -ExitCode 8 -Transcript $bad).Passed | Should -BeFalse
    }
}

Describe 'Test-RealPcRunRecordFresh' {
    It 'Accepts a record that started after the stage started' {
        $record = [pscustomobject]@{ startedUtc = '2026-10-06T10:00:05Z' }
        (Test-RealPcRunRecordFresh -RunRecord $record -Since ([datetime]::SpecifyKind([datetime]'2026-10-06T10:00:04', 'Utc'))).Fresh | Should -BeTrue
    }

    It 'Rejects a record an earlier run left' {
        $record = [pscustomobject]@{ startedUtc = '2026-10-06T09:00:00Z' }
        $result = Test-RealPcRunRecordFresh -RunRecord $record -Since ([datetime]::SpecifyKind([datetime]'2026-10-06T10:00:00', 'Utc'))
        $result.Fresh | Should -BeFalse
        $result.Detail | Should -Match 'from an earlier run'
    }

    It 'Reads a startedUtc that PowerShell 7 already turned into a [datetime]' {
        $record = [pscustomobject]@{ startedUtc = [datetime]::SpecifyKind([datetime]'2026-10-06T10:00:05', 'Utc') }
        (Test-RealPcRunRecordFresh -RunRecord $record -Since ([datetime]::SpecifyKind([datetime]'2026-10-06T10:00:00', 'Utc'))).Fresh | Should -BeTrue
    }

    It 'Rejects a record without a readable startedUtc' {
        (Test-RealPcRunRecordFresh -RunRecord ([pscustomobject]@{ startedUtc = 'soon' }) -Since (Get-Date)).Fresh | Should -BeFalse
    }
}

Describe 'Get-RealPcRunRecordResult' {
    It 'Passes a schema-1 record that reached its summary with the matching exit code and no failure' {
        $record = Get-FirstRunRecord
        $rows = Get-RealPcRunRecordResult -RunRecord $record -ExpectedExitCode 0
        @($rows | Where-Object { $_.Result -eq 'FAIL' }) | Should -BeNullOrEmpty
    }

    It 'Fails when no record was written, with the reason' {
        $rows = Get-RealPcRunRecordResult -RunRecord $null -RunRecordProblem 'last-run.json is from an earlier run' -ExpectedExitCode 0
        $rows.Result | Should -Be 'FAIL'
        $rows.Detail | Should -Match 'earlier run'
    }

    It 'Fails when an app is recorded Failed' {
        $record = Get-FirstRunRecord
        $record.apps[0].status = 'Failed'
        $rows = Get-RealPcRunRecordResult -RunRecord $record
        (($rows | Where-Object { $_.Check -eq 'No app failed' }).Result) | Should -Be 'FAIL'
    }

    It 'Fails when the recorded exit code does not match the process exit code' {
        $record = Get-FirstRunRecord
        $rows = Get-RealPcRunRecordResult -RunRecord $record -ExpectedExitCode 1
        (($rows | Where-Object { $_.Check -eq 'last-run.json records the exit code' }).Result) | Should -Be 'FAIL'
    }
}

Describe 'Get-RealPcAppResult' {
    It 'Passes an Installed applicable app and a not-applicable skip with the right reason' {
        $record = Get-FirstRunRecord
        $expectation = @(
            New-RealPcExpectation -Id '7zip.7zip' -Expected 'Installed'
            New-RealPcExpectation -Id 'Adobe.Acrobat.Reader.32-bit' -Expected 'NotApplicable' -Reason 'not applicable: ARM64 and 32-bit Windows only; x64 PCs get the 64-bit Reader'
        )
        $rows = Get-RealPcAppResult -RunRecord $record -AppExpectation $expectation
        @($rows | Where-Object { $_.Result -eq 'FAIL' }) | Should -BeNullOrEmpty
    }

    It 'Tolerates an applicable app recorded as already installed (preinstalled on the machine)' {
        $record = Get-FirstRunRecord
        $record.apps[0].status = 'Skipped'
        $record.apps[0].reason = 'already installed'
        $expectation = @(New-RealPcExpectation -Id '7zip.7zip' -Expected 'Installed')
        $rows = Get-RealPcAppResult -RunRecord $record -AppExpectation $expectation
        (($rows | Where-Object { $_.Check -like 'App installed or present: 7zip.7zip' }).Result) | Should -Be 'PASS'
    }

    It 'Fails an applicable app recorded Failed' {
        $record = Get-FirstRunRecord
        $record.apps[0].status = 'Failed'
        $expectation = @(New-RealPcExpectation -Id '7zip.7zip' -Expected 'Installed')
        $rows = Get-RealPcAppResult -RunRecord $record -AppExpectation $expectation
        (($rows | Where-Object { $_.Check -like '*7zip.7zip' }).Result) | Should -Be 'FAIL'
    }

    It 'Fails a not-applicable app whose recorded reason differs' {
        $record = Get-FirstRunRecord
        $expectation = @(New-RealPcExpectation -Id 'Adobe.Acrobat.Reader.32-bit' -Expected 'NotApplicable' -Reason 'not applicable: something else')
        $rows = Get-RealPcAppResult -RunRecord $record -AppExpectation $expectation
        (($rows | Where-Object { $_.Check -like 'App not applicable*' }).Result) | Should -Be 'FAIL'
    }

    It 'Fails, with the reason, when the expectations could not be built' {
        $rows = Get-RealPcAppResult -RunRecord (Get-FirstRunRecord) -AppExpectation $null -AppExpectationProblem 'the module query gave no answer'
        $rows.Result | Should -Be 'FAIL'
        $rows.Detail | Should -Match 'module query gave no answer'
    }
}

Describe 'Get-RealPcAutoUpdateResult' {
    It 'Passes a Configured run with a healthy WAU task that has no at-logon trigger and TightVNC Configured' {
        $record = Get-FirstRunRecord
        $transcript = New-RealPcTestTranscript -RuntimeInstalled
        $wau = [pscustomobject]@{ Exists = $true; Healthy = $true; Triggers = @('Weekly from 2026-10-06T02:00:00') }
        $rows = Get-RealPcAutoUpdateResult -Transcript $transcript -RunRecord $record -WauTaskHealth $wau -WindowsAppRuntimePresent $true -ExpectTightVncConfigured
        @($rows | Where-Object { $_.Result -eq 'FAIL' }) | Should -BeNullOrEmpty
    }

    It 'Fails when the WAU task still has an at-logon trigger' {
        $transcript = New-RealPcTestTranscript
        $wau = [pscustomobject]@{ Exists = $true; Healthy = $true; Triggers = @('Weekly from 2026-10-06T02:00:00', 'Logon') }
        $rows = Get-RealPcAutoUpdateResult -Transcript $transcript -WauTaskHealth $wau -WindowsAppRuntimePresent $true
        (($rows | Where-Object { $_.Check -match 'no at-logon trigger' }).Result) | Should -Be 'FAIL'
    }

    It 'Fails when TightVNC is not Configured but a password was supplied' {
        $record = Get-FirstRunRecord
        ($record.apps | Where-Object { $_.id -eq 'GlavSoft.TightVNC' }).postInstall = 'NotConfigured'
        $transcript = New-RealPcTestTranscript
        $rows = Get-RealPcAutoUpdateResult -Transcript $transcript -RunRecord $record -WindowsAppRuntimePresent $true -ExpectTightVncConfigured
        (($rows | Where-Object { $_.Check -match 'TightVNC' }).Result) | Should -Be 'FAIL'
    }

    It 'Fails the runtime row, with the reason, when its status could not be read (never drops it)' {
        $rows = Get-RealPcAutoUpdateResult -Transcript (New-RealPcTestTranscript) -WindowsAppRuntimeProblem 'the module query gave no answer'
        $row = $rows | Where-Object { $_.Check -eq 'Windows App Runtime present' }
        $row.Result | Should -Be 'FAIL'
        $row.Detail | Should -Match 'module query gave no answer'
    }
}

Describe 'Get-RealPcReRunResult' {
    It 'Passes a re-run: exit 0, apps present, runtime not installed again, WAU already present' {
        $record = Get-FirstRunRecord
        foreach ($app in @($record.apps | Where-Object { $_.status -eq 'Installed' })) {
            $app.status = 'Skipped'
            $app.reason = 'already installed'
        }
        $transcript = New-RealPcTestTranscript -AutoUpdates 'Already present (Winget-AutoUpdate v2.12.0).'
        $expectation = @(New-RealPcExpectation -Id '7zip.7zip' -Expected 'AlreadyPresent')
        $rows = Get-RealPcReRunResult -ExitCode 0 -Transcript $transcript -RunRecord $record -AppExpectation $expectation
        @($rows | Where-Object { $_.Result -eq 'FAIL' }) | Should -BeNullOrEmpty
    }

    It 'Fails a re-run that installed the Windows App Runtime again' {
        $transcript = New-RealPcTestTranscript -RuntimeInstalled -AutoUpdates 'Already present.'
        $rows = Get-RealPcReRunResult -ExitCode 0 -Transcript $transcript
        (($rows | Where-Object { $_.Check -match 'Windows App Runtime again' }).Result) | Should -Be 'FAIL'
    }

    It 'Fails instead of dropping the per-app rows when the expectations or the record are missing' {
        $transcript = New-RealPcTestTranscript -AutoUpdates 'Already present.'
        $noExpectation = Get-RealPcReRunResult -ExitCode 0 -Transcript $transcript -RunRecord (Get-FirstRunRecord) -AppExpectation $null -AppExpectationProblem 'query failed'
        (($noExpectation | Where-Object { $_.Check -eq 'Re-run apps recorded' }).Result) | Should -Be 'FAIL'
        $noRecord = Get-RealPcReRunResult -ExitCode 0 -Transcript $transcript -RunRecord $null -RunRecordProblem 'last-run.json is from an earlier run' -AppExpectation @(New-RealPcExpectation -Id '7zip.7zip' -Expected 'AlreadyPresent')
        (($noRecord | Where-Object { $_.Check -eq 'Re-run apps recorded' }).Detail) | Should -Match 'earlier run'
    }

    It 'Fails an exit code that was not read' {
        $rows = Get-RealPcReRunResult -ExitCode $null -Transcript (New-RealPcTestTranscript -AutoUpdates 'Already present.')
        (($rows | Where-Object { $_.Check -match 'exit code' }).Result) | Should -Be 'FAIL'
    }
}

Describe 'Get-RealPcTimeBudget* and Get-RealPcUninstallCheckRow (item 8)' {
    It 'Passes the spent-budget run: exit 9, app NotAttempted, notattempted >= 1' {
        $record = [pscustomobject]@{ apps = @([pscustomobject]@{ id = '7zip.7zip'; status = 'NotAttempted' }) }
        $rows = Get-RealPcTimeBudgetSpentResult -ExitCode 9 -RunRecord $record -ResultLine 'RESULT: exit=9 installed=0 skipped=0 deferred=0 failed=0 notattempted=1 autoupdates=NotAttempted restart=no build=x log=y'
        @($rows | Where-Object { $_.Result -eq 'FAIL' }) | Should -BeNullOrEmpty
    }

    It 'Fails the spent-budget run when the exit code is not 9, or was not read' {
        $record = [pscustomobject]@{ apps = @([pscustomobject]@{ id = '7zip.7zip'; status = 'NotAttempted' }) }
        (((Get-RealPcTimeBudgetSpentResult -ExitCode 0 -RunRecord $record -ResultLine 'RESULT: notattempted=1') | Where-Object { $_.Check -match 'exits 9' }).Result) | Should -Be 'FAIL'
        (((Get-RealPcTimeBudgetSpentResult -ExitCode $null -RunRecord $record -ResultLine 'RESULT: notattempted=1') | Where-Object { $_.Check -match 'exits 9' }).Detail) | Should -Match 'not read'
    }

    It 'Passes the finish run: exit 0 and the app Installed' {
        $record = [pscustomobject]@{ apps = @([pscustomobject]@{ id = '7zip.7zip'; status = 'Installed' }) }
        $rows = Get-RealPcTimeBudgetFinishResult -ExitCode 0 -RunRecord $record
        @($rows | Where-Object { $_.Result -eq 'FAIL' }) | Should -BeNullOrEmpty
    }

    It 'Fails the finish run on a stale record, with the reason' {
        $rows = Get-RealPcTimeBudgetFinishResult -ExitCode 0 -RunRecord $null -RunRecordProblem 'last-run.json is from an earlier run'
        (($rows | Where-Object { $_.Check -match 'installed on the finish run' }).Detail) | Should -Match 'earlier run'
    }

    It 'Reads the RESULT line from console output' {
        Get-RealPcResultLineFromText -Text (Get-Content -Raw -LiteralPath (Join-Path $script:FixtureDirectory 'realpc-firstrun-console.txt')) | Should -Match '^RESULT: exit=0 .*notattempted=0'
        Get-RealPcResultLineFromText -Text 'nothing here' | Should -Be ''
    }

    It 'Passes the removal check only when winget answers that the app is gone' {
        (Get-RealPcUninstallCheckRow -AppId '7zip.7zip' -Present $false -UninstallExitCode 0).Result | Should -Be 'PASS'
        (Get-RealPcUninstallCheckRow -AppId '7zip.7zip' -Present $true -UninstallExitCode 0).Result | Should -Be 'FAIL'
        $unknown = Get-RealPcUninstallCheckRow -AppId '7zip.7zip' -Present $null -UninstallExitCode -1978335211
        $unknown.Result | Should -Be 'FAIL'
        $unknown.Detail | Should -Match 'could not answer'
    }
}

Describe 'Get-RealPcWingetListVerdict' {
    It 'Reads 0 as installed and 0x8A150014 (no package found) as not installed' {
        Get-RealPcWingetListVerdict -ExitCode 0 | Should -BeTrue
        Get-RealPcWingetListVerdict -ExitCode -1978335212 | Should -BeFalse
    }

    It 'Reads every other result, and no result, as no answer' {
        Get-RealPcWingetListVerdict -ExitCode -1978335211 | Should -BeNullOrEmpty
        Get-RealPcWingetListVerdict -ExitCode 1 | Should -BeNullOrEmpty
        Get-RealPcWingetListVerdict -ExitCode $null | Should -BeNullOrEmpty
    }
}

Describe 'Preflight rows' {
    It 'Passes reachable hosts, any HTTP status included, and fails one with no answer' {
        $rows = Get-RealPcReachabilityResult -Probe @(
            [pscustomobject]@{ Url = 'https://github.com/'; Reachable = $true; Detail = 'HTTP 200' }
            [pscustomobject]@{ Url = 'https://aka.ms/'; Reachable = $true; Detail = 'HTTP 301' }
            [pscustomobject]@{ Url = 'https://www.powershellgallery.com/'; Reachable = $false; Detail = 'no answer: NameResolutionFailure' }
        )
        @($rows | Where-Object { $_.Result -eq 'PASS' }).Count | Should -Be 2
        ($rows | Where-Object { $_.Result -eq 'FAIL' }).Check | Should -Be 'Internet: www.powershellgallery.com reachable'
    }

    It 'Warns (SKIP) about catalog apps that are already installed, and passes a fresh machine' {
        (Get-RealPcInstalledCatalogRow -CatalogId @('7zip.7zip', 'Git.Git') -Installed @('Git.Git')).Result | Should -Be 'SKIP'
        (Get-RealPcInstalledCatalogRow -CatalogId @('7zip.7zip', 'Git.Git') -Installed @('Git.Git')).Detail | Should -Match 'already installed: Git\.Git'
        (Get-RealPcInstalledCatalogRow -CatalogId @('7zip.7zip', 'Git.Git')).Result | Should -Be 'PASS'
        (Get-RealPcInstalledCatalogRow -CatalogId @('7zip.7zip') -Unknown @('7zip.7zip')).Detail | Should -Match 'could not answer'
        (Get-RealPcInstalledCatalogRow -CatalogId @()).Result | Should -Be 'SKIP'
    }
}

Describe 'Secret scans (item 6 and the report zip)' {
    It 'Labels the secrets, and adds the first 8 characters of a longer TightVNC password' {
        $set = Get-RealPcSecretSet -TightVncPassword 'abcdefghij' -TempUserName 'wgtXYZ'
        $set['the TightVNC test password'] | Should -Be 'abcdefghij'
        $set['the first 8 characters of the TightVNC test password'] | Should -Be 'abcdefgh'
        $set['the temporary user''s name'] | Should -Be 'wgtXYZ'
        (Get-RealPcSecretSet -TightVncPassword 'abcdefgh').Count | Should -Be 1
    }

    It 'Finds a secret in a bundle file, case-insensitively, and names it by label, never by value' {
        $leak = @(Get-RealPcSecretLeak -Entry @{ 'system.txt' = 'user=wgtsetup123456 and more' } -Secret ([ordered]@{ 'the temporary user''s name' = 'WGTSETUP123456' }))
        $leak.Count | Should -Be 1
        $leak[0].Name | Should -Be 'system.txt'
        $leak[0].Label | Should -Be 'the temporary user''s name'
        ($leak | Out-String) | Should -Not -Match 'WGTSETUP123456'
    }

    It 'Finds no leak when the secret is absent, and ignores an empty secret' {
        @(Get-RealPcSecretLeak -Entry @{ 'system.txt' = 'nothing here' } -Secret @{ 'pw' = 'topsecret' }).Count | Should -Be 0
        @(Get-RealPcSecretLeak -Entry @{ 'a' = 'x' } -Secret @{ 'a' = ''; 'b' = '   ' }).Count | Should -Be 0
    }

    It 'Passes a bundle with every expected entry and no secret' {
        $names = @('README.txt', 'system.txt', 'winget.txt', 'appx.txt', 'wau-updates-log-tail.txt', 'logs/install-20261006.log')
        $text = @{ 'README.txt' = 'clean'; 'system.txt' = 'clean' }
        $rows = Get-RealPcDiagnosticsResult -EntryName $names -EntryText $text -Secret (Get-RealPcSecretSet -TightVncPassword 'throwawy1' -TempUserName 'wgtsetup1')
        @($rows | Where-Object { $_.Result -eq 'FAIL' }) | Should -BeNullOrEmpty
    }

    It 'Fails a bundle that leaks the working first 8 characters of the test password, without printing them' {
        $names = @('README.txt', 'system.txt', 'winget.txt', 'appx.txt', 'wau-updates-log-tail.txt', 'logs/x.log')
        $text = @{ 'system.txt' = 'TightVNC password Abcd2345 was set' }
        $row = (Get-RealPcDiagnosticsResult -EntryName $names -EntryText $text -Secret (Get-RealPcSecretSet -TightVncPassword 'Abcd2345XYZ')) | Where-Object { $_.Check -match 'no secret' }
        $row.Result | Should -Be 'FAIL'
        $row.Detail | Should -Match 'system\.txt holds the first 8 characters'
        $row.Detail | Should -Not -Match 'Abcd2345'
    }

    It 'Fails a bundle missing an expected entry' {
        $rows = Get-RealPcDiagnosticsResult -EntryName @('README.txt') -EntryText @{} -Secret @{}
        (($rows | Where-Object { $_.Check -match 'winget.txt' }).Result) | Should -Be 'FAIL'
    }

    It 'Scans every file in a folder and the entries of a zip in it (Get-RealPcFolderSecretLeak)' {
        $folder = Join-Path $TestDrive 'report-scan'
        $null = New-Item -ItemType Directory -Path (Join-Path $folder 'evidence/2-FirstRun') -Force
        Set-Content -LiteralPath (Join-Path $folder 'report.md') -Value 'all clean'
        Set-Content -LiteralPath (Join-Path $folder 'evidence/2-FirstRun/console.txt') -Value 'password is pw7Secr8'
        $zipSource = Join-Path $TestDrive 'zip-source'
        $null = New-Item -ItemType Directory -Path $zipSource -Force
        Set-Content -LiteralPath (Join-Path $zipSource 'system.txt') -Value 'PW7SECR8 in a bundle'
        Set-Content -LiteralPath (Join-Path $zipSource 'clean.txt') -Value 'nothing'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::CreateFromDirectory($zipSource, (Join-Path $folder 'evidence/diagnostics.zip'))

        $leaks = @(Get-RealPcFolderSecretLeak -Path $folder -Secret (Get-RealPcSecretSet -TightVncPassword 'pw7Secr8'))
        $leaks.Count | Should -Be 2
        @($leaks | ForEach-Object { $_.Name -replace '\\', '/' }) | Should -Contain 'evidence/2-FirstRun/console.txt'
        @($leaks | ForEach-Object { $_.Name -replace '\\', '/' }) | Should -Contain 'evidence/diagnostics.zip!system.txt'
        @($leaks | ForEach-Object { Split-Path -Leaf $_.File }) | Should -Not -Contain 'report.md'
    }
}

Describe 'Get-RealPcUninstallerResult (item 9)' {
    It 'Passes a clean uninstall: WhatIf unchanged, exit 0, kept apps left, WAU gone' {
        $rows = Get-RealPcUninstallerResult `
            -WhatIfInstalledBefore @('7zip.7zip', 'Microsoft.PowerShell') -WhatIfInstalledAfter @('Microsoft.PowerShell', '7zip.7zip') `
            -WhatIfWauBefore $true -WhatIfWauAfter $true `
            -ExitCode 0 -InstalledAfter @('Microsoft.WindowsTerminal') -WauPresentAfter $false
        @($rows | Where-Object { $_.Result -eq 'FAIL' }) | Should -BeNullOrEmpty
    }

    It 'Fails when the -WhatIf preview changed the installed set' {
        $rows = Get-RealPcUninstallerResult `
            -WhatIfInstalledBefore @('7zip.7zip') -WhatIfInstalledAfter @() `
            -WhatIfWauBefore $true -WhatIfWauAfter $true `
            -ExitCode 0 -InstalledAfter @() -WauPresentAfter $false
        (($rows | Where-Object { $_.Check -match 'WhatIf changed nothing' }).Result) | Should -Be 'FAIL'
    }

    It 'Fails when a removable catalog app is still installed' {
        $rows = Get-RealPcUninstallerResult `
            -WhatIfInstalledBefore @('7zip.7zip') -WhatIfInstalledAfter @('7zip.7zip') `
            -WhatIfWauBefore $false -WhatIfWauAfter $false `
            -ExitCode 0 -InstalledAfter @('7zip.7zip', 'Microsoft.PowerShell') -WauPresentAfter $false
        (($rows | Where-Object { $_.Check -match 'Catalog apps removed' }).Result) | Should -Be 'FAIL'
    }

    It 'Fails when Winget-AutoUpdate is still present' {
        $rows = Get-RealPcUninstallerResult `
            -WhatIfInstalledBefore @() -WhatIfInstalledAfter @() `
            -WhatIfWauBefore $true -WhatIfWauAfter $true `
            -ExitCode 0 -InstalledAfter @() -WauPresentAfter $true
        (($rows | Where-Object { $_.Check -match 'Winget-AutoUpdate removed' }).Result) | Should -Be 'FAIL'
    }

    It 'Fails when winget could not answer for an app, rather than counting it removed' {
        $rows = Get-RealPcUninstallerResult -ExitCode 0 -InstalledAfter @() -UnknownIds @('Git.Git', 'Git.Git') -WhatIfWauBefore $true -WhatIfWauAfter $true -WauPresentAfter $false
        $row = $rows | Where-Object { $_.Check -eq 'winget answered for every catalog app' }
        $row.Result | Should -Be 'FAIL'
        $row.Detail | Should -Match 'Git\.Git, so'
    }

    It 'Fails an uninstall exit code that was not read' {
        $rows = Get-RealPcUninstallerResult -ExitCode $null -WhatIfWauBefore $true -WhatIfWauAfter $true
        (($rows | Where-Object { $_.Check -match 'Real uninstall exits' }).Result) | Should -Be 'FAIL'
    }
}

Describe 'Get-RealPcRestrictedFolderProblem' {
    It 'Accepts a base folder owned by Administrators with only SYSTEM and Administrators' {
        Get-RealPcRestrictedFolderProblem -Summary (New-RealPcAclSummary) | Should -BeNullOrEmpty
    }

    It 'Accepts the logs folder with a read-only Users entry under -ReadableByUsers' {
        $summary = New-RealPcAclSummary -Rules @(
            @{ Sid = 'S-1-5-18'; Rights = 2032127 },
            @{ Sid = 'S-1-5-32-544'; Rights = 2032127 },
            @{ Sid = 'S-1-5-32-545'; Rights = 1179817 }
        )
        Get-RealPcRestrictedFolderProblem -Summary $summary -ReadableByUsers | Should -BeNullOrEmpty
    }

    It 'Rejects a Users entry that can change the folder' {
        $summary = New-RealPcAclSummary -Rules @(
            @{ Sid = 'S-1-5-18'; Rights = 2032127 },
            @{ Sid = 'S-1-5-32-545'; Rights = 2032127 }
        )
        Get-RealPcRestrictedFolderProblem -Summary $summary -ReadableByUsers | Should -Match 'S-1-5-32-545'
    }

    It 'Rejects a folder owned by someone else' {
        $summary = New-RealPcAclSummary -OwnerSid 'S-1-5-21-1-2-3-1001'
        Get-RealPcRestrictedFolderProblem -Summary $summary | Should -Match 'owned by'
    }

    It 'Rejects a folder that still inherits entries' {
        $summary = New-RealPcAclSummary -InheritanceProtected $false
        Get-RealPcRestrictedFolderProblem -Summary $summary | Should -Match 'inherits'
    }
}

Describe 'Compare-RealPcAclSnapshot' {
    It 'Reports unchanged when owner and SDDL match' {
        $before = @([pscustomobject]@{ Path = 'C:\v'; Owner = 'S-1'; Sddl = 'D:X' }, [pscustomobject]@{ Path = 'C:\v\m.txt'; Owner = 'S-1'; Sddl = 'D:Y' })
        (Compare-RealPcAclSnapshot -Before $before -After $before).Unchanged | Should -BeTrue
    }

    It 'Reports changed when an owner changed' {
        $before = @([pscustomobject]@{ Path = 'C:\v'; Owner = 'S-1'; Sddl = 'D:X' })
        $after = @([pscustomobject]@{ Path = 'C:\v'; Owner = 'S-2'; Sddl = 'D:X' })
        $compare = Compare-RealPcAclSnapshot -Before $before -After $after
        $compare.Unchanged | Should -BeFalse
        $compare.Detail | Should -Match 'owner changed'
    }

    It 'Reports changed when the SDDL changed' {
        $before = @([pscustomobject]@{ Path = 'C:\v'; Owner = 'S-1'; Sddl = 'D:X' })
        $after = @([pscustomobject]@{ Path = 'C:\v'; Owner = 'S-1'; Sddl = 'D:Z' })
        (Compare-RealPcAclSnapshot -Before $before -After $after).Unchanged | Should -BeFalse
    }

    It 'Reports changed when a path is gone' {
        $before = @([pscustomobject]@{ Path = 'C:\v'; Owner = 'S-1'; Sddl = 'D:X' }, [pscustomobject]@{ Path = 'C:\v\m.txt'; Owner = 'S-1'; Sddl = 'D:Y' })
        $after = @([pscustomobject]@{ Path = 'C:\v'; Owner = 'S-1'; Sddl = 'D:X' })
        (Compare-RealPcAclSnapshot -Before $before -After $after).Detail | Should -Match 'is gone'
    }
}

Describe 'Get-RealPcJunctionPlantResult' {
    It 'Credits the standard user only when its task exited 0 and the junction is there' {
        (Get-RealPcJunctionPlantResult -UserCreated $true -TaskResult 0 -JunctionAfterTask $true).PlantedBy | Should -Be 'StandardUser'
    }

    It 'Gives the real reason for the admin fallback' {
        (Get-RealPcJunctionPlantResult -UserCreated $false -UserProblem 'blocked by policy').Note | Should -Match 'could not be created \(blocked by policy\)'
        (Get-RealPcJunctionPlantResult -UserCreated $true -TaskProblem 'Access is denied').Note | Should -Match 'could not be started \(Access is denied\)'
        (Get-RealPcJunctionPlantResult -UserCreated $true -TaskResult $null).Note | Should -Match 'did not finish in time'
        $failed = Get-RealPcJunctionPlantResult -UserCreated $true -TaskResult -2147023511 -JunctionAfterTask $false
        $failed.PlantedBy | Should -Be 'Admin'
        $failed.Note | Should -Match 'ended with 0x80070569'
        (Get-RealPcJunctionPlantResult -UserCreated $true -TaskResult 0 -JunctionAfterTask $false).Note | Should -Match 'no junction appeared'
    }
}

Describe 'Get-RealPcLinkGuardResult (item 11)' {
    BeforeAll {
        $script:GoodBase = New-RealPcAclSummary
        $script:GoodLogs = New-RealPcAclSummary -Rules @(
            @{ Sid = 'S-1-5-18'; Rights = 2032127 },
            @{ Sid = 'S-1-5-32-544'; Rights = 2032127 },
            @{ Sid = 'S-1-5-32-545'; Rights = 1179817 }
        )
        $script:Victim = @([pscustomobject]@{ Path = 'C:\Users\Public\victim'; Owner = 'S-1-5-32-544'; Sddl = 'D:X' })
        # A real installer transcript has no removed-link warning: the installer prints it before its
        # transcript starts. Only the console output has it.
        $script:RealTranscript = [string](Get-Content -Raw -LiteralPath (Join-Path $script:FixtureDirectory 'first-pass.txt'))
        $script:RealConsole = [string](Get-Content -Raw -LiteralPath (Join-Path $script:FixtureDirectory 'realpc-firstrun-console.txt'))
    }

    It 'Passes a correct link-guard outcome, finding the warning in the console output as the installer prints it' {
        $script:RealTranscript | Should -Not -Match 'was a link'
        $rows = Get-RealPcLinkGuardResult -BaseIsReparsePoint $false -BaseAcl $script:GoodBase -LogsAcl $script:GoodLogs -ConsoleText $script:RealConsole -TranscriptText $script:RealTranscript -VictimBefore $script:Victim -VictimAfter $script:Victim -PlantedBy 'StandardUser' -PlantNote 'planted by the temporary standard user'
        @($rows | Where-Object { $_.Result -eq 'FAIL' }) | Should -BeNullOrEmpty
        ($rows | Where-Object { $_.Check -match 'link was removed' }).Detail | Should -Match 'console output'
        ($rows | Where-Object { $_.Check -match 'standard user' }).Result | Should -Be 'PASS'
    }

    It 'Fails when neither the console output nor the transcript has the warning' {
        $rows = Get-RealPcLinkGuardResult -BaseIsReparsePoint $false -ConsoleText 'no warning here' -TranscriptText $script:RealTranscript
        (($rows | Where-Object { $_.Check -match 'link was removed' }).Result) | Should -Be 'FAIL'
    }

    It 'Fails when the base folder is still a reparse point' {
        $rows = Get-RealPcLinkGuardResult -BaseIsReparsePoint $true -TranscriptText ''
        (($rows | Where-Object { $_.Check -match 'real directory' }).Result) | Should -Be 'FAIL'
    }

    It 'Fails when the victim folder changed, and skips the standard-user row with the real reason when the admin planted it' {
        $before = @([pscustomobject]@{ Path = 'C:\v'; Owner = 'S-1'; Sddl = 'D:X' })
        $after = @([pscustomobject]@{ Path = 'C:\v'; Owner = 'S-2'; Sddl = 'D:X' })
        $rows = Get-RealPcLinkGuardResult -BaseIsReparsePoint $false -ConsoleText $script:RealConsole -VictimBefore $before -VictimAfter $after -PlantedBy 'Admin' -PlantNote 'the standard user''s planting task ended with 0x80070569, so the admin planted the junction'
        (($rows | Where-Object { $_.Check -match 'kept their owner and SDDL' }).Result) | Should -Be 'FAIL'
        $plantRow = $rows | Where-Object { $_.Check -match 'standard user' }
        $plantRow.Result | Should -Be 'SKIP'
        $plantRow.Detail | Should -Match '0x80070569'
    }
}

Describe 'Invoke-RealPcFirstRunStage (wiring, with every outside call mocked)' {
    BeforeEach {
        $script:InstallerHasRun = $false
        $script:TightVncPassword = 'Tvnc2345'
        $script:StageTimeoutMinutes = 60
        $script:LinkGuard = [pscustomobject]@{ VictimFolder = $null; VictimBefore = @(); TempUser = $null; TempUserName = $null; PlantedBy = 'StandardUser'; PlantNote = 'planted by the temporary standard user'; Planted = $true }
        $script:FirstRunEvidence = Join-Path $TestDrive 'evidence-firstrun'
        $null = New-Item -ItemType Directory -Path $script:FirstRunEvidence -Force

        # Terminal applies before the run; the run's Windows Terminal step makes it not apply after.
        Mock Get-RealPcAppExpectation {
            if ($script:InstallerHasRun) {
                $expected = 'NotApplicable'
                $reason = 'not applicable: winget cannot self-update Windows Terminal from a session Windows Terminal itself is hosting (issue #271)'
            }
            else {
                $expected = 'Installed'
                $reason = $null
            }
            return [pscustomobject]@{ Value = @([pscustomobject]@{ Id = 'Microsoft.WindowsTerminal'; Expected = $expected; Reason = $reason; AlreadyPresentReasons = @('already installed'); MustInstall = $false }); Problem = $null }
        }
        Mock Invoke-RealPcInstaller {
            $script:InstallerHasRun = $true
            return [pscustomobject]@{ ExitCode = 0; Output = @((Get-Content -LiteralPath (Join-Path $script:FixtureDirectory 'realpc-firstrun-console.txt'))) }
        }
        Mock Get-InstallPassTranscript { return (New-RealPcTestTranscript) }
        Mock Read-RealPcRunRecord { return [pscustomobject]@{ Record = (Get-FirstRunRecord); Problem = $null } }
        Mock Get-RealPcTranscriptText { return [string](Get-Content -Raw -LiteralPath (Join-Path $script:FixtureDirectory 'first-pass.txt')) }
        Mock Get-RealPcWauTaskHealth { return [pscustomobject]@{ Exists = $true; Healthy = $true; Triggers = @('Daily') } }
        Mock Invoke-RealPcModuleJson { return [pscustomobject]@{ Ok = $true; Value = [pscustomobject]@{ Present = $true; Detail = 'found' }; Problem = $null } }
        Mock Test-RealPcReparsePoint { return $false }
        Mock Get-RealPcFolderAclSummary {
            if ($Path -match 'logs$') {
                return (New-RealPcAclSummary -Rules @(@{ Sid = 'S-1-5-18'; Rights = 2032127 }, @{ Sid = 'S-1-5-32-544'; Rights = 2032127 }, @{ Sid = 'S-1-5-32-545'; Rights = 1179817 }))
            }
            return (New-RealPcAclSummary)
        }
        Mock Remove-RealPcLinkGuardArtifact { return @() }
    }

    It 'Checks the apps against applicability decided before the run, not after the Terminal step changed it' {
        $rows = Invoke-RealPcFirstRunStage -EvidenceFolder $script:FirstRunEvidence
        ($rows | Where-Object { $_.Check -match 'Microsoft.WindowsTerminal' }).Result | Should -Be 'PASS'
        Should -Invoke Get-RealPcAppExpectation -Times 1 -Exactly
    }

    It 'Finds the removed-link warning in the console output when no transcript has it' {
        $rows = Invoke-RealPcFirstRunStage -EvidenceFolder $script:FirstRunEvidence
        $row = $rows | Where-Object { $_.Check -match 'link was removed' }
        $row.Result | Should -Be 'PASS'
        $row.Detail | Should -Match 'console output'
    }

    It 'Gives the installer a time budget, the TightVNC test password and a console log' {
        $null = Invoke-RealPcFirstRunStage -EvidenceFolder $script:FirstRunEvidence
        Should -Invoke Invoke-RealPcInstaller -Times 1 -Exactly -ParameterFilter {
            $Environment['WINGET_APP_SETUP_MAX_RUNTIME_MINUTES'] -eq '60' -and $Environment['WINGET_APP_SETUP_TIGHTVNC_PASSWORD'] -eq 'Tvnc2345' -and $ConsoleLogPath -like '*console.txt'
        }
    }

    It 'Fails the exit-code row, instead of reading it as 0, when the installer gave no exit code' {
        Mock Invoke-RealPcInstaller { $script:InstallerHasRun = $true; return [pscustomobject]@{ ExitCode = $null; Output = @() } }
        $rows = Invoke-RealPcFirstRunStage -EvidenceFolder $script:FirstRunEvidence
        ($rows | Where-Object { $_.Check -match 'First run exit code' }).Result | Should -Be 'FAIL'
    }
}

Describe 'Invoke-RealPcUninstallerStage (wiring)' {
    BeforeEach {
        $script:CatalogId = @('7zip.7zip')
        $script:UninstallerEvidence = Join-Path $TestDrive 'evidence-uninstaller'
        $null = New-Item -ItemType Directory -Path $script:UninstallerEvidence -Force
        Mock Invoke-RealPcProcess { return [pscustomobject]@{ ExitCode = 0; Output = @() } }
        Mock Get-RealPcInstalledCatalogId { return [pscustomobject]@{ Installed = @(); Unknown = @() } }
        Mock Get-RealPcWauTaskHealth { return [pscustomobject]@{ Exists = $false; Healthy = $false; Triggers = @() } }
    }

    It 'Runs the -WhatIf preview non-interactively, so it never waits for a key press' {
        $null = Invoke-RealPcUninstallerStage -EvidenceFolder $script:UninstallerEvidence
        Should -Invoke Invoke-RealPcProcess -Times 1 -Exactly -ParameterFilter { $ArgumentList -contains '-WhatIf' -and $ArgumentList -contains '-NonInteractive' }
        Should -Invoke Invoke-RealPcProcess -Times 1 -Exactly -ParameterFilter { $ArgumentList -notcontains '-WhatIf' -and $ArgumentList -contains '-NonInteractive' }
    }
}

Describe 'One-liner and module-query scripts' {
    It 'Renders arguments: parameter names as they are, values quoted' {
        ConvertTo-RealPcScriptArgumentText -ArgumentList @('-MaxRuntimeMinutes', '1', '-RunDeadlineUtc', '2026-10-06T10:00:00Z', 'it''s') | Should -Be "-MaxRuntimeMinutes '1' -RunDeadlineUtc '2026-10-06T10:00:00Z' 'it''s'"
    }

    It 'Pipes the downloaded text to iex with no arguments, and serves it to the relaunch download' {
        $script = Get-RealPcOneLinerScript -Url 'https://raw.githubusercontent.com/J-MaFf/winget-app-setup/refs/heads/claude/x/winget-app-install.ps1'
        $script | Should -Match "WingetAppSetupTestPlanUrl = 'https://raw\.githubusercontent\.com/J-MaFf/winget-app-setup/refs/heads/claude/x/winget-app-install\.ps1'"
        $script | Should -Match 'function global:Invoke-RestMethod'
        ($script -split "`n")[-1] | Should -Be '$global:WingetAppSetupTestPlanText | iex'
        $parseErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseInput($script, [ref]$null, [ref]$parseErrors)
        $parseErrors | Should -BeNullOrEmpty
    }

    It 'Passes arguments through a script block, so a spent budget reaches the installer' {
        $script = Get-RealPcOneLinerScript -Url 'https://example.invalid/winget-app-install.ps1' -ArgumentList @('-MaxRuntimeMinutes', '1', '-RunDeadlineUtc', '2026-10-06T10:00:00Z')
        ($script -split "`n")[-1] | Should -Be "& ([scriptblock]::Create(`$global:WingetAppSetupTestPlanText)) -MaxRuntimeMinutes '1' -RunDeadlineUtc '2026-10-06T10:00:00Z'"
        $parseErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseInput($script, [ref]$null, [ref]$parseErrors)
        $parseErrors | Should -BeNullOrEmpty
    }

    It 'The shim answers the relaunch URLs (raw main and jsDelivr) and nothing else' {
        $script = Get-RealPcOneLinerScript -Url 'https://example.invalid/x'
        $pattern = [regex]::Match($script, "-match '([^']+)'").Groups[1].Value
        'https://raw.githubusercontent.com/J-MaFf/winget-app-setup/refs/heads/main/winget-app-install.ps1' | Should -Match $pattern
        'https://cdn.jsdelivr.net/gh/J-MaFf/winget-app-setup@main/winget-app-install.ps1' | Should -Match $pattern
        'https://www.powershellgallery.com/api/v2/package/x' | Should -Not -Match $pattern
    }

    It 'Takes the answer after the sentinel and ignores what else the child printed' {
        $output = @('Condition for Dell failed to evaluate; treating as applicable.', ($script:ModuleJsonSentinel + '["7zip.7zip","Git.Git"]'))
        $read = Get-RealPcModuleJsonResult -Output $output
        $read.Ok | Should -BeTrue
        @($read.Value) | Should -Be @('7zip.7zip', 'Git.Git')
    }

    It 'Reports a missing or broken answer instead of returning nothing' {
        $missing = Get-RealPcModuleJsonResult -Output @('Import-Module : failed')
        $missing.Ok | Should -BeFalse
        $missing.Problem | Should -Match 'Import-Module : failed'
        (Get-RealPcModuleJsonResult -Output @($script:ModuleJsonSentinel + '{not json')).Ok | Should -BeFalse
    }

    It 'A module query runs end to end in a child PowerShell and answers with the catalog ids' {
        $query = Get-RealPcModuleQueryScript -Body '$result = @(Get-DefaultAppCatalog | ForEach-Object { [string]$_.name })' -ManifestPath $script:ModuleManifestPath -SystemPassPath (Join-Path $script:RepoRoot 'e2e/Invoke-SystemInstallPass.ps1')
        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($query))
        $output = @(& (Get-Process -Id $PID).Path -NoProfile -NonInteractive -OutputFormat Text -EncodedCommand $encoded 2>$null | ForEach-Object { [string]$_ })
        $read = Get-RealPcModuleJsonResult -Output $output
        $read.Ok | Should -BeTrue -Because ($output -join "`n")
        @($read.Value) | Should -Contain '7zip.7zip'
        @($read.Value) | Should -Contain 'Microsoft.WindowsTerminal'
    }

    It 'The expectation query runs end to end in a child PowerShell, whatever the module prints on the way' {
        # Off Windows the Dell condition's CIM probe fails, so the module prints a fail-open warning
        # before the answer: the sentinel keeps it out of the JSON.
        foreach ($variant in @(@{}, @{ AlreadyPresent = $true }, @{ System = $true; AlreadyPresent = $true })) {
            $body = Get-RealPcAppExpectationQuery @variant
            $query = Get-RealPcModuleQueryScript -Body $body -ManifestPath $script:ModuleManifestPath -SystemPassPath (Join-Path $script:RepoRoot 'e2e/Invoke-SystemInstallPass.ps1')
            $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($query))
            $output = @(& (Get-Process -Id $PID).Path -NoProfile -NonInteractive -OutputFormat Text -EncodedCommand $encoded 2>$null | ForEach-Object { [string]$_ })
            $read = Get-RealPcModuleJsonResult -Output $output
            $read.Ok | Should -BeTrue -Because ($output -join "`n")
            $expectations = @($read.Value)
            @($expectations | ForEach-Object { $_.Id }) | Should -Contain 'GlavSoft.TightVNC'
            @($expectations | ForEach-Object { $_.Expected } | Sort-Object -Unique) | ForEach-Object { $_ | Should -BeIn @('Installed', 'AlreadyPresent', 'NotApplicable', 'Deferred') }
            if ($variant.AlreadyPresent) {
                @($expectations | Where-Object { $_.Expected -eq 'Installed' }) | Should -BeNullOrEmpty
            }
        }
    }
}

Describe 'Get-RealPcExitCode' {
    It 'Returns 2 on refusal' {
        Get-RealPcExitCode -Refused | Should -Be 2
    }

    It 'Returns 1 when any row failed' {
        Get-RealPcExitCode -Rows @([pscustomobject]@{ Result = 'PASS' }, [pscustomobject]@{ Result = 'FAIL' }) | Should -Be 1
    }

    It 'Returns 0 when every row passed or skipped' {
        Get-RealPcExitCode -Rows @([pscustomobject]@{ Result = 'PASS' }, [pscustomobject]@{ Result = 'SKIP' }) | Should -Be 0
    }
}

Describe 'Format-RealPcReport and the manual steps' {
    BeforeAll {
        $script:SampleStages = @(
            [pscustomobject]@{ Name = 'Preflight'; Number = 0; Item = '0'; DurationSeconds = 3; Rows = @([pscustomobject]@{ Check = 'Running elevated'; Result = 'PASS'; Detail = 'administrator' }) }
            [pscustomobject]@{ Name = 'FirstRun'; Number = 2; Item = '1+4+5+11'; DurationSeconds = 120; Rows = @([pscustomobject]@{ Check = 'First run exit code'; Result = 'FAIL'; Detail = 'exit 2' }) }
        )
        $script:Facts = [ordered]@{ OS = 'Windows 11'; Build = '26100' }
    }

    It 'Marks the overall result FAIL when any row failed, in markdown' {
        $report = Format-RealPcReport -MachineFacts $script:Facts -StageResult $script:SampleStages -ManualLeftovers @('do the ARM64 check') -Markdown
        $report | Should -Match 'Overall: FAIL'
        $report | Should -Match '# Real-PC test plan report'
        $report | Should -Match 'Stage 2 FirstRun'
        $report | Should -Match 'do the ARM64 check'
    }

    It 'Writes a plain-text variant with the same facts and rows' {
        $report = Format-RealPcReport -MachineFacts $script:Facts -StageResult $script:SampleStages -ManualLeftovers @()
        $report | Should -Match 'Real-PC test plan report'
        $report | Should -Match 'OS: Windows 11'
        $report | Should -Match '\[FAIL\] First run exit code'
    }

    It 'Marks overall PASS when nothing failed' {
        $stages = @([pscustomobject]@{ Name = 'Preflight'; Number = 0; Item = '0'; DurationSeconds = 1; Rows = @([pscustomobject]@{ Check = 'x'; Result = 'PASS'; Detail = '' }) })
        (Format-RealPcReport -MachineFacts $script:Facts -StageResult $stages) | Should -Match 'Overall: PASS'
    }

    It 'Says, next to the password, whether TightVNC is still there to connect to' {
        $after = (Get-RealPcManualStepText -TightVncPassword 'Tvnc2345' -UninstallerRan) -join "`n"
        $after | Should -Match 'Tvnc2345'
        $after | Should -Match 'Uninstaller stage ran, which removes TightVNC'
        $after | Should -Match 'not in the report zip'
        ((Get-RealPcManualStepText -TightVncPassword 'Tvnc2345') -join "`n") | Should -Match 'still installed with this password'
    }

    It 'Points the TightVNC leftover at the local folder, not the zip' {
        ((Get-RealPcManualLeftover) -join "`n") | Should -Match '-local; it is not in the zip'
    }
}

Describe 'Harness stays runnable by Windows PowerShell 5.1' {
    It 'Is ASCII only and parses cleanly' {
        $bytes = [System.IO.File]::ReadAllBytes($script:HarnessPath)
        @($bytes | Where-Object { $_ -gt 0x7F }).Count | Should -Be 0
        $tokens = $null
        $parseErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($script:HarnessPath, [ref]$tokens, [ref]$parseErrors)
        $parseErrors | Should -BeNullOrEmpty
    }

    It 'Passes the build''s own PowerShell-7-only syntax guard (Get-PowerShell7OnlySyntax)' {
        # The guard build/Build-WingetInstallScript.ps1 runs on the generated scripts, loaded from the
        # build script itself: operator tokens (nested ones in expandable strings too), clean { }
        # blocks and the background operator.
        $buildAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoRoot 'build/Build-WingetInstallScript.ps1'), [ref]$null, [ref]$null)
        $definition = $buildAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-PowerShell7OnlySyntax' }, $false)
        $definition | Should -Not -BeNullOrEmpty
        . ([scriptblock]::Create($definition.Extent.Text))
        $tokens = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:HarnessPath, [ref]$tokens, [ref]$null)
        @(Get-PowerShell7OnlySyntax -Ast $ast -Tokens $tokens | ForEach-Object { '{0} at line {1}' -f $_.Kind, $_.Line }) | Should -BeNullOrEmpty
    }

    It 'Defines its functions when dot-sourced and runs nothing (the main block is guarded)' {
        Get-Command -Name 'Resolve-RealPcTestPlanStage' -CommandType Function -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command -Name 'Invoke-RealPcTestPlanMain' -CommandType Function -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}
