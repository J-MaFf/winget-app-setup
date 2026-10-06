# E2ERealPcTestPlan.Tests.ps1
# Tests for e2e/Invoke-RealPcTestPlan.ps1, the real-PC owner-test-plan harness (bead wgt-gq8.60).
# The install, scheduled-task and ACL-reading work needs Windows; the pure parts tested here read
# only what they are given: stage ordering and dependency logic (-Stage / -SkipStage), the change
# plan, the gate decision and the -ReportPath check (the refusal paths), the evaluation of each
# stage's checks from fixture last-run.json files, transcripts and console output, the ACL/SDDL
# comparison, the secret scans, the one-liner and module-query scripts, and the report and
# exit-code logic. The entry point, three stages and the S4U planting task's COM registration
# (against a stand-in service) also run here with every changing and Windows-only command mocked. Dot-sourcing the harness defines its functions and runs nothing
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

    # The error a failed COM call (RegisterTaskDefinition) gives a script, built as PowerShell builds
    # it: a MethodInvocationException ('ComMethodTargetInvocation') around a TargetInvocationException
    # around the exception .NET maps the HRESULT to (UnauthorizedAccessException for 0x80070005,
    # ArgumentException for 0x80070057; a COMException only for a code with no type of its own).
    # PowerShell 7 (ComInvoker.cs) puts the COM error's description on the TargetInvocationException;
    # Windows PowerShell's CLR puts it on the mapped exception and leaves .NET's generic text outside.
    function New-RealPcComMethodError {
        param (
            [Parameter(Mandatory = $true)][int]$HResult,
            [string]$Description = $null,
            [switch]$WindowsPowerShell
        )
        $mapped = [System.Runtime.InteropServices.Marshal]::GetExceptionForHR($HResult)
        if ($WindowsPowerShell) {
            $inner = $mapped
            if ($Description) {
                if ($mapped -is [System.Runtime.InteropServices.COMException]) {
                    $inner = [System.Runtime.InteropServices.COMException]::new($Description, $HResult)
                }
                else {
                    $inner = [System.Activator]::CreateInstance($mapped.GetType(), [object[]]@($Description))
                }
            }
            $invocation = [System.Reflection.TargetInvocationException]::new($inner)
        }
        elseif ($Description) {
            $invocation = [System.Reflection.TargetInvocationException]::new($Description, $mapped)
        }
        else {
            $invocation = [System.Reflection.TargetInvocationException]::new($mapped)
        }
        $inner = $invocation.InnerException
        $outer = [System.Management.Automation.MethodInvocationException]::new(('Exception calling "RegisterTaskDefinition" with "7" argument(s): "{0}"' -f $inner.Message), $invocation)
        return [System.Management.Automation.ErrorRecord]::new($outer, 'ComMethodTargetInvocation', 'NotSpecified', $null)
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
            'Register-RealPcPlantTask', 'New-RealPcAdminJunction', 'Invoke-RealPcProcess', 'Invoke-RealPcInstaller', 'Invoke-RealPcModuleJson', 'Remove-RealPcHarnessLeftover',
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
        Mock Register-RealPcPlantTask { }
        Mock New-RealPcAdminJunction { }
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
        (Get-RealPcJunctionPlantResult -UserCreated $true -TaskStep 'Start' -TaskProblem 'The service is not running. (0x80070426)').Note | Should -Match 'failed \(starting the S4U task: The service is not running\. \(0x80070426\)\)'
        (Get-RealPcJunctionPlantResult -UserCreated $true -TaskResult $null).Note | Should -Match 'did not finish in time'
        $failed = Get-RealPcJunctionPlantResult -UserCreated $true -TaskResult -2147023511 -JunctionAfterTask $false
        $failed.PlantedBy | Should -Be 'Admin'
        $failed.Note | Should -Match 'ended with 0x80070569'
        (Get-RealPcJunctionPlantResult -UserCreated $true -TaskResult 0 -JunctionAfterTask $false).Note | Should -Match 'no junction appeared'
    }

    It 'Names the registration step, on one line, when registering the task failed (wgt-gq8.62)' {
        # The runner's report said 'could not be started (Access is denied.' and broke the line there:
        # the error's text ends in CR/LF, and it was registration, not the start, that was refused.
        $plant = Get-RealPcJunctionPlantResult -UserCreated $true -TaskStep 'Register' -TaskProblem "Access is denied.`r`n (0x80070005)"
        $plant.PlantedBy | Should -Be 'Admin'
        $plant.Note | Should -Match 'registering the S4U task: Access is denied\. \(0x80070005\)'
        $plant.Note | Should -Not -Match 'could not be started'
        $plant.Note | Should -Not -Match "[`r`n]"
        (Get-RealPcJunctionPlantResult -UserCreated $false -UserProblem "blocked`r`nby policy").Note | Should -Not -Match "[`r`n]"
    }

    It 'Says the temporary user lacks the batch-logon right when the task ended with 0x80070569' {
        # ERROR_LOGON_TYPE_NOT_GRANTED, as LastTaskResult (unsigned) and as the signed exit code.
        foreach ($result in @(2147943785, -2147023511)) {
            $plant = Get-RealPcJunctionPlantResult -UserCreated $true -TaskResult $result -JunctionAfterTask $false
            $plant.PlantedBy | Should -Be 'Admin'
            $plant.Note | Should -Match 'ended with 0x80070569: the temporary user lacks Log on as a batch job'
        }
        (Get-RealPcJunctionPlantResult -UserCreated $true -TaskResult 1 -JunctionAfterTask $false).Note | Should -Not -Match 'batch job'
        # The same code from Start-ScheduledTask (at registration a missing right is only
        # SCHED_S_BATCH_LOGON_PROBLEM, a success code PowerShell's COM call drops).
        $started = Get-RealPcJunctionPlantResult -UserCreated $true -TaskStep 'Start' -TaskProblem 'Logon failure: the user has not been granted the requested logon type at this computer. (0x80070569)'
        $started.Note | Should -Match 'starting the S4U task: .*\(0x80070569\)\); the temporary user lacks Log on as a batch job'
    }
}

Describe 'ConvertTo-RealPcTaskProblem (wgt-gq8.62)' {
    It 'Gives a failed COM call''s description and its HRESULT (<Name>)' -ForEach @(
        @{ Name = 'PowerShell 7, E_ACCESSDENIED'; HResult = -2147024891; Description = "Access is denied.`r`n"; WindowsPowerShell = $false; Expected = 'Access is denied. (0x80070005)' }
        @{ Name = 'PowerShell 7, E_INVALIDARG'; HResult = -2147024809; Description = "The parameter is incorrect.`r`n"; WindowsPowerShell = $false; Expected = 'The parameter is incorrect. (0x80070057)' }
        @{ Name = 'Windows PowerShell, E_ACCESSDENIED'; HResult = -2147024891; Description = "Access is denied.`r`n"; WindowsPowerShell = $true; Expected = 'Access is denied. (0x80070005)' }
        @{ Name = 'Windows PowerShell, E_INVALIDARG'; HResult = -2147024809; Description = "The parameter is incorrect.`r`n"; WindowsPowerShell = $true; Expected = 'The parameter is incorrect. (0x80070057)' }
        @{ Name = 'Windows PowerShell, no description'; HResult = -2147024891; Description = 'Access is denied. (Exception from HRESULT: 0x80070005 (E_ACCESSDENIED))'; WindowsPowerShell = $true; Expected = 'Access is denied. (0x80070005)' }
        @{ Name = 'a code with no exception type of its own'; HResult = -2147023511; Description = "Logon failure: the user has not been granted the requested logon type at this computer.`r`n"; WindowsPowerShell = $false; Expected = 'Logon failure: the user has not been granted the requested logon type at this computer. (0x80070569)' }
    ) {
        # wgt-gq8.62 review: .NET maps 0x80070005 to an UnauthorizedAccessException, not a
        # COMException, so the code has to come from the text's suffix or the HResult.
        $record = New-RealPcComMethodError -HResult $HResult -Description $Description -WindowsPowerShell:$WindowsPowerShell
        $record.Exception.InnerException.InnerException -is [System.Runtime.InteropServices.ExternalException] | Should -Be ($HResult -eq -2147023511)
        ConvertTo-RealPcTaskProblem -ErrorRecord $record | Should -BeExactly $Expected
    }

    It 'Gives the code once, from the mapped exception, when the COM error has no description' {
        $problem = ConvertTo-RealPcTaskProblem -ErrorRecord (New-RealPcComMethodError -HResult -2147024891)
        $problem | Should -Match '^\S.* \(0x80070005\)$'
        ([regex]::Matches($problem, '0x80070005')).Count | Should -Be 1
        $problem | Should -Not -Match "[`r`n]"
    }

    It 'Adds no code to an ordinary .NET error, nor a CLR code to a COM call''s' {
        $plain = [System.Management.Automation.ErrorRecord]::new([System.ArgumentException]::new('bad value'), 'ArgumentException', 'InvalidArgument', $null)
        ConvertTo-RealPcTaskProblem -ErrorRecord $plain | Should -BeExactly 'bad value'
        $invocation = [System.Reflection.TargetInvocationException]::new([System.InvalidOperationException]::new('not now'))
        $clr = [System.Management.Automation.ErrorRecord]::new([System.Management.Automation.MethodInvocationException]::new('outer', $invocation), 'ComMethodTargetInvocation', 'NotSpecified', $null)
        ConvertTo-RealPcTaskProblem -ErrorRecord $clr | Should -BeExactly 'not now'
    }

    It 'Reads the HRESULT from a ScheduledTasks cmdlet''s error id and drops the CR/LF its text ends in' {
        $record = [System.Management.Automation.ErrorRecord]::new([System.Exception]::new("Access is denied.`r`n"), 'HRESULT 0x80070005,Register-ScheduledTask', 'PermissionDenied', $null)
        ConvertTo-RealPcTaskProblem -ErrorRecord $record | Should -BeExactly 'Access is denied. (0x80070005)'
    }

    It 'Gives only the text when the error has no HRESULT' {
        $record = [System.Management.Automation.ErrorRecord]::new([System.InvalidOperationException]::new('something else'), 'Other', 'InvalidOperation', $null)
        ConvertTo-RealPcTaskProblem -ErrorRecord $record | Should -BeExactly 'something else'
    }
}

Describe 'Get-RealPcBatchLogonRightLine (wgt-gq8.62)' {
    BeforeAll {
        $script:SeceditExport = @(
            '[Unicode]'
            'Unicode=yes'
            '[Privilege Rights]'
            'SeNetworkLogonRight = *S-1-1-0,*S-1-5-32-544,*S-1-5-32-545,*S-1-5-32-551'
            'SeDenyBatchLogonRightX = not this one'
            'SeBatchLogonRight = *S-1-5-32-544,*S-1-5-32-551,*S-1-5-32-559,WGTabcdefgh,*S-1-5-21-1-2-3-1001'
            'SeDenyInteractiveLogonRight = Guest'
            '[Version]'
            'signature="$CHICAGO$"'
        ) -join "`r`n"
    }

    It 'Keeps only the batch-logon lines, and says when a right is not assigned' {
        $lines = @(Get-RealPcBatchLogonRightLine -Text $script:SeceditExport)
        $lines.Count | Should -Be 2
        $lines[0] | Should -BeExactly 'SeBatchLogonRight = *S-1-5-32-544,*S-1-5-32-551,*S-1-5-32-559,WGTabcdefgh,*S-1-5-21-1-2-3-1001'
        $lines[1] | Should -BeExactly 'SeDenyBatchLogonRight = (not assigned)'
        ($lines -join "`n") | Should -Not -Match 'SeNetworkLogonRight|Guest'
    }

    It 'Hides the temporary user''s name and SID, whatever the case' {
        $lines = @(Get-RealPcBatchLogonRightLine -Text $script:SeceditExport -HideName @('wgtAbcdefgh', 'S-1-5-21-1-2-3-1001', ''))
        $lines[0] | Should -BeExactly 'SeBatchLogonRight = *S-1-5-32-544,*S-1-5-32-551,*S-1-5-32-559,[temporary user],*[temporary user]'
        ($lines -join "`n") | Should -Not -Match '(?i)wgtabcdefgh|S-1-5-21-1-2-3-1001'
        # report.md puts the line in a table unescaped, where '<...>' would be an HTML tag and vanish.
        ($lines -join "`n") | Should -Not -Match '[<>]'
        $markdown = Format-RealPcReport -MachineFacts ([ordered]@{ 'Log on as a batch job (secedit)' = ($lines -join '; ') }) -StageResult @() -Markdown
        ($markdown -join "`n") | Should -Match '\| Log on as a batch job \(secedit\) \| SeBatchLogonRight = .*\[temporary user\]'
    }

    It 'Reads a deny line too' {
        $lines = @(Get-RealPcBatchLogonRightLine -Text "SeDenyBatchLogonRight = *S-1-5-32-546`r`nSeBatchLogonRight = *S-1-5-32-544")
        $lines | Should -Be @('SeBatchLogonRight = *S-1-5-32-544', 'SeDenyBatchLogonRight = *S-1-5-32-546')
    }
}

Describe 'Read-RealPcBatchLogonRight (secedit, read-only)' {
    BeforeEach {
        $script:SavedTmpDir = $env:TMPDIR
        $env:TMPDIR = Join-Path $TestDrive ('tmp-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $env:TMPDIR -Force
        $script:SeceditArguments = @()
        Mock Invoke-RealPcProcess {
            $script:SeceditArguments = @($ArgumentList)
            $exportPath = $ArgumentList[[array]::IndexOf($ArgumentList, '/cfg') + 1]
            # secedit writes UTF-16 with a byte-order mark.
            [System.IO.File]::WriteAllText($exportPath, "[Privilege Rights]`r`nSeBatchLogonRight = *S-1-5-32-544,wgtAbcdefgh`r`n", [System.Text.Encoding]::Unicode)
            return [pscustomobject]@{ ExitCode = 0; Output = @() }
        }
    }

    AfterEach {
        $env:TMPDIR = $script:SavedTmpDir
    }

    It 'Exports only the user rights, keeps the batch-logon lines and deletes its temporary file' {
        $lines = @(Read-RealPcBatchLogonRight -HideName @('wgtAbcdefgh'))
        $lines | Should -Be @('SeBatchLogonRight = *S-1-5-32-544,[temporary user]', 'SeDenyBatchLogonRight = (not assigned)')
        $script:SeceditArguments[0..2] | Should -Be @('/export', '/areas', 'USER_RIGHTS')
        Should -Invoke Invoke-RealPcProcess -Times 1 -Exactly -ParameterFilter { $FilePath -like '*\System32\secedit.exe' }
        $exportPath = $script:SeceditArguments[[array]::IndexOf($script:SeceditArguments, '/cfg') + 1]
        Test-Path -LiteralPath (Split-Path -Parent $exportPath) | Should -BeFalse
    }

    It 'Says why when secedit fails, and still deletes the folder' {
        Mock Invoke-RealPcProcess {
            $script:SeceditArguments = @($ArgumentList)
            return [pscustomobject]@{ ExitCode = 1; Output = @() }
        }
        @(Read-RealPcBatchLogonRight) | Should -Be @('secedit /export could not read the user rights (exit 1)')
        $exportPath = $script:SeceditArguments[[array]::IndexOf($script:SeceditArguments, '/cfg') + 1]
        Test-Path -LiteralPath (Split-Path -Parent $exportPath) | Should -BeFalse
    }
}

Describe 'Register-RealPcPlantTask (the COM call, with a stand-in service)' {
    BeforeEach {
        $script:Registered = $null
        $script:FakeAction = [pscustomobject]@{ Path = ''; Arguments = '' }
        $actions = [pscustomobject]@{}
        $actions | Add-Member -MemberType ScriptMethod -Name Create -Value { param($type) $script:FakeActionType = $type; return $script:FakeAction }
        $script:FakeDefinition = [pscustomobject]@{
            RegistrationInfo = [pscustomobject]@{ Description = '' }
            Principal        = [pscustomobject]@{ LogonType = 3; RunLevel = 1 }
            Settings         = [pscustomobject]@{ ExecutionTimeLimit = 'PT72H'; DisallowStartIfOnBatteries = $true; StopIfGoingOnBatteries = $true }
            Actions          = $actions
        }
        $folder = [pscustomobject]@{}
        $folder | Add-Member -MemberType ScriptMethod -Name RegisterTaskDefinition -Value {
            param($Path, $Definition, $Flags, $UserId, $Password, $LogonType, $Sddl)
            $script:Registered = [pscustomobject]@{ Path = $Path; Definition = $Definition; Flags = $Flags; UserId = $UserId; Password = $Password; LogonType = $LogonType; Sddl = $Sddl }
        }
        $script:FakeService = [pscustomobject]@{ Folder = $folder }
        $script:FakeService | Add-Member -MemberType ScriptMethod -Name NewTask -Value { param($flags) return $script:FakeDefinition }
        $script:FakeService | Add-Member -MemberType ScriptMethod -Name GetFolder -Value { param($path) $script:FolderPath = $path; return $this.Folder }
        Mock New-RealPcTaskService { return $script:FakeService }
        $script:PlantSecret = ConvertTo-SecureString -String 'Pw3456789abcdefghjkmAa9!' -AsPlainText -Force
    }

    It 'Registers an S4U, limited task for the user, with its password, in the root folder' {
        Register-RealPcPlantTask -TaskName 'winget-app-setup-plantjunction' -UserId 'PC\wgtAbcdefgh' -Password $script:PlantSecret -Execute 'C:\Windows\System32\cmd.exe' -Argument '/c mklink /J "a" "b"'
        $script:FolderPath | Should -Be '\'
        $script:Registered.Path | Should -Be 'winget-app-setup-plantjunction'
        $script:Registered.Flags | Should -Be 6
        $script:Registered.UserId | Should -Be 'PC\wgtAbcdefgh'
        $script:Registered.Password | Should -BeExactly 'Pw3456789abcdefghjkmAa9!'
        $script:Registered.LogonType | Should -Be 2
        $script:Registered.Sddl | Should -BeNullOrEmpty
        $script:Registered.Definition.Principal.LogonType | Should -Be 2
        $script:Registered.Definition.Principal.RunLevel | Should -Be 0
        $script:Registered.Definition.Settings.ExecutionTimeLimit | Should -Be 'PT5M'
        $script:Registered.Definition.Settings.DisallowStartIfOnBatteries | Should -BeFalse
        $script:Registered.Definition.Settings.StopIfGoingOnBatteries | Should -BeFalse
        $script:FakeActionType | Should -Be 0
        $script:FakeAction.Path | Should -Be 'C:\Windows\System32\cmd.exe'
        $script:FakeAction.Arguments | Should -Be '/c mklink /J "a" "b"'
    }

    It 'Lets a refused registration through to the caller, with its HRESULT' {
        # As PowerShell 7 gives a refused RegisterTaskDefinition: no COMException in it.
        $script:RefusedRecord = New-RealPcComMethodError -HResult -2147024891 -Description "Access is denied.`r`n"
        $script:FakeService.Folder | Add-Member -MemberType ScriptMethod -Name RegisterTaskDefinition -Value { throw $script:RefusedRecord } -Force
        { Register-RealPcPlantTask -TaskName 't' -UserId 'PC\wgtAbcdefgh' -Password $script:PlantSecret -Execute 'cmd.exe' } | Should -Throw '*Access is denied*'
        $problem = $null
        try {
            Register-RealPcPlantTask -TaskName 't' -UserId 'PC\wgtAbcdefgh' -Password $script:PlantSecret -Execute 'cmd.exe'
        }
        catch {
            $problem = ConvertTo-RealPcTaskProblem -ErrorRecord $_
        }
        $problem | Should -BeExactly 'Access is denied. (0x80070005)'
    }
}

Describe 'Invoke-RealPcLinkGuardSetupStage (wiring, with every outside call mocked)' {
    BeforeEach {
        $script:SavedPublic = $env:PUBLIC
        $script:SavedProgramData = $env:ProgramData
        $env:PUBLIC = Join-Path $TestDrive ('public-' + [guid]::NewGuid().ToString('N'))
        $env:ProgramData = Join-Path $TestDrive ('programdata-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $env:PUBLIC -Force
        $null = New-Item -ItemType Directory -Path $env:ProgramData -Force
        $script:LinkGuardEvidence = Join-Path $TestDrive ('evidence-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:LinkGuardEvidence -Force
        $script:RealPcOptions = [pscustomobject]@{ UseOneLiner = $false; Branch = 'b'; ResetProgramData = $false }
        $script:LinkGuard = [pscustomobject]@{ VictimFolder = $null; VictimBefore = @(); TempUser = $null; TempUserName = $null; PlantedBy = 'Admin'; PlantNote = ''; Planted = $false }
        $script:MachineFacts = [ordered]@{ OS = 'Windows 11' }
        $script:JunctionThere = $false
        $script:UserPasswordText = $null
        $script:PlantPasswordText = $null
        $script:PlantPassword = $null

        # A known name and password, so the test can look for them in everything the stage reports.
        Mock New-RealPcRandomSecret {
            if ($Length -eq 8) {
                return 'Abcdefgh'
            }
            return 'Pw3456789abcdefghjkm'
        }
        Mock Get-RealPcAclSnapshotTree { return @([pscustomobject]@{ Path = $Path; Owner = 'S-1-5-32-544'; Sddl = 'D:X' }) }
        Mock New-LocalUser {
            $script:UserPasswordText = [System.Net.NetworkCredential]::new('', $Password).Password
            return [pscustomobject]@{ Name = $Name; SID = [pscustomobject]@{ Value = 'S-1-5-21-1-2-3-1001' } }
        }
        Mock Add-RealPcUserToGroup { return $null }
        Mock Register-RealPcPlantTask {
            $script:PlantPassword = $Password
            $script:PlantPasswordText = [System.Net.NetworkCredential]::new('', $Password).Password
        }
        Mock Start-ScheduledTask {
            # Has the password been disposed of by the time the task starts?
            $script:DisposedBeforeStart = $true
            try {
                $null = $script:PlantPassword.Copy()
                $script:DisposedBeforeStart = $false
            }
            catch {
            }
            $script:JunctionThere = $true
        }
        Mock Wait-RealPcScheduledTask { return 0 }
        Mock Unregister-ScheduledTask { }
        Mock Test-RealPcReparsePoint { return $script:JunctionThere }
        Mock New-RealPcAdminJunction { $script:JunctionThere = $true }
        Mock Read-RealPcBatchLogonRight { return @('SeBatchLogonRight = *S-1-5-32-544,*S-1-5-32-551,*S-1-5-32-559', 'SeDenyBatchLogonRight = (not assigned)') }
    }

    AfterEach {
        $env:PUBLIC = $script:SavedPublic
        $env:ProgramData = $script:SavedProgramData
    }

    It 'Registers the S4U task with the user''s own password, kept until then, and credits the standard user' {
        $script:DisposedBeforeStart = $null
        $rows = @(Invoke-RealPcLinkGuardSetupStage -EvidenceFolder $script:LinkGuardEvidence)

        Should -Invoke Register-RealPcPlantTask -Times 1 -Exactly -ParameterFilter {
            $Password -is [securestring] -and $UserId -like '*\wgt*' -and $TaskName -eq 'winget-app-setup-plantjunction' -and $Argument -like '/c mklink /J *'
        }
        $script:PlantPasswordText | Should -BeExactly 'Pw3456789abcdefghjkmAa9!'
        $script:PlantPasswordText | Should -BeExactly $script:UserPasswordText
        # Disposed of once the task is registered, before it starts.
        $script:DisposedBeforeStart | Should -BeTrue
        { $null = $script:PlantPassword.Copy() } | Should -Throw '*disposed*'
        Should -Invoke Start-ScheduledTask -Times 1 -Exactly
        Should -Invoke Unregister-ScheduledTask -Times 1 -Exactly -ParameterFilter { $TaskName -eq 'winget-app-setup-plantjunction' }
        Should -Invoke New-RealPcAdminJunction -Times 0 -Exactly
        $script:LinkGuard.PlantedBy | Should -Be 'StandardUser'
        $script:LinkGuard.Planted | Should -BeTrue
        ($rows | Where-Object { $_.Check -eq 'Planted the junction at the ProgramData folder' }).Result | Should -Be 'PASS'
    }

    It 'Records who holds the batch-logon right, with the temporary user hidden, in the evidence and the machine facts' {
        $null = Invoke-RealPcLinkGuardSetupStage -EvidenceFolder $script:LinkGuardEvidence
        Should -Invoke Read-RealPcBatchLogonRight -Times 1 -Exactly -ParameterFilter { $HideName -contains 'wgtAbcdefgh' -and $HideName -contains 'S-1-5-21-1-2-3-1001' }
        $script:MachineFacts['Log on as a batch job (secedit)'] | Should -Be 'SeBatchLogonRight = *S-1-5-32-544,*S-1-5-32-551,*S-1-5-32-559; SeDenyBatchLogonRight = (not assigned)'
        [System.IO.File]::ReadAllText((Join-Path $script:LinkGuardEvidence 'batch-logon-rights.txt')) | Should -Match 'SeDenyBatchLogonRight = \(not assigned\)'
    }

    It 'Puts neither the password nor the user''s name in any row, the report or the evidence' {
        $rows = @(Invoke-RealPcLinkGuardSetupStage -EvidenceFolder $script:LinkGuardEvidence)
        $stage = [pscustomobject]@{ Name = 'LinkGuardSetup'; Number = 1; Item = '11'; DurationSeconds = 2; Rows = $rows }
        $text = @(
            @($rows | ForEach-Object { '{0} {1}' -f $_.Check, $_.Detail })
            $script:LinkGuard.PlantNote
            (Format-RealPcReport -MachineFacts $script:MachineFacts -StageResult @($stage) -Markdown)
            (Format-RealPcReport -MachineFacts $script:MachineFacts -StageResult @($stage))
            @(Get-ChildItem -LiteralPath $script:LinkGuardEvidence -File -Recurse | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) })
        ) -join "`n"
        $text | Should -Not -BeNullOrEmpty
        $text | Should -Not -Match 'Pw3456789abcdefghjkm'
        $text | Should -Not -Match '(?i)wgtAbcdefgh'
    }

    It 'Falls back to the admin, names the registration step, and still unregisters, when registration is refused' {
        # As Windows PowerShell 5.1, which the harness starts under, gives a refused COM call.
        $script:RefusedRecord = New-RealPcComMethodError -HResult -2147024891 -Description "Access is denied.`r`n" -WindowsPowerShell
        Mock Register-RealPcPlantTask {
            $script:PlantPassword = $Password
            throw $script:RefusedRecord
        }
        $rows = @(Invoke-RealPcLinkGuardSetupStage -EvidenceFolder $script:LinkGuardEvidence)

        Should -Invoke Start-ScheduledTask -Times 0 -Exactly
        Should -Invoke Unregister-ScheduledTask -Times 1 -Exactly -ParameterFilter { $TaskName -eq 'winget-app-setup-plantjunction' }
        Should -Invoke New-RealPcAdminJunction -Times 1 -Exactly
        { $null = $script:PlantPassword.Copy() } | Should -Throw '*disposed*'
        $script:LinkGuard.PlantedBy | Should -Be 'Admin'
        $script:LinkGuard.PlantNote | Should -Match 'registering the S4U task: Access is denied\. \(0x80070005\)'
        $script:LinkGuard.PlantNote | Should -Not -Match "[`r`n]"
        $script:LinkGuard.PlantNote | Should -Not -Match 'could not be started'
        # The user is still recorded, so the cleanup removes it.
        $script:LinkGuard.TempUser | Should -Be 'wgtAbcdefgh'
        $planted = $rows | Where-Object { $_.Check -eq 'Planted the junction at the ProgramData folder' }
        $planted.Result | Should -Be 'PASS'
        $planted.Detail | Should -Match 'registering the S4U task'
    }

    It 'Says the user lacks the batch-logon right when its task ends with 0x80070569' {
        Mock Start-ScheduledTask { }
        Mock Wait-RealPcScheduledTask { return -2147023511 }
        $null = Invoke-RealPcLinkGuardSetupStage -EvidenceFolder $script:LinkGuardEvidence
        $script:LinkGuard.PlantedBy | Should -Be 'Admin'
        $script:LinkGuard.PlantNote | Should -Match 'lacks Log on as a batch job'
        Should -Invoke New-RealPcAdminJunction -Times 1 -Exactly
        Should -Invoke Unregister-ScheduledTask -Times 1 -Exactly
    }

    It 'Disposes of the password when the user cannot be created, and registers no task' {
        Mock New-LocalUser {
            $script:PlantPassword = $Password
            throw 'blocked by policy'
        }
        $null = Invoke-RealPcLinkGuardSetupStage -EvidenceFolder $script:LinkGuardEvidence
        { $null = $script:PlantPassword.Copy() } | Should -Throw '*disposed*'
        Should -Invoke Register-RealPcPlantTask -Times 0 -Exactly
        $script:LinkGuard.PlantNote | Should -Match 'could not be created \(blocked by policy\)'
    }
}

Describe 'Remove-RealPcHarnessLeftover (the always-run cleanup)' {
    BeforeEach {
        $script:LinkGuard = [pscustomobject]@{ VictimFolder = $null; VictimBefore = @(); TempUser = $null; TempUserName = $null; PlantedBy = 'Admin'; PlantNote = ''; Planted = $false }
        $script:PlantTaskRegistered = $true
        Mock Get-ScheduledTask {
            if ($script:PlantTaskRegistered -and $TaskName -contains 'winget-app-setup-plantjunction') {
                return [pscustomobject]@{ TaskName = 'winget-app-setup-plantjunction' }
            }
        }
        Mock Stop-ScheduledTask { }
        Mock Unregister-ScheduledTask { $script:PlantTaskRegistered = $false }
    }

    It 'Unregisters a planting task the stage left registered' {
        $rows = @(Remove-RealPcHarnessLeftover)
        Should -Invoke Unregister-ScheduledTask -Times 1 -Exactly -ParameterFilter { $TaskName -contains 'winget-app-setup-plantjunction' }
        ($rows | Where-Object { $_.Check -eq 'Removed the leftover scheduled task winget-app-setup-plantjunction' }).Result | Should -Be 'PASS'
    }
}

Describe 'The password reaches only New-LocalUser and Register-RealPcPlantTask (static)' {
    It 'Never hands it to anything else, and never runs schtasks or Register-ScheduledTask for the plant' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:HarnessPath, [ref]$null, [ref]$null)
        $stage = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-RealPcLinkGuardSetupStage' }, $true)
        $stage | Should -Not -BeNullOrEmpty
        $uses = @($stage.FindAll({ param($node) $node -is [System.Management.Automation.Language.VariableExpressionAst] -and $node.VariablePath.UserPath -eq 'secure' }, $true))
        $uses.Count | Should -BeGreaterThan 2
        $receivers = @(foreach ($use in $uses) {
                $parent = $use.Parent
                while ($null -ne $parent -and $parent -isnot [System.Management.Automation.Language.CommandAst] -and $parent -isnot [System.Management.Automation.Language.StatementAst]) {
                    $parent = $parent.Parent
                }
                if ($parent -is [System.Management.Automation.Language.CommandAst]) {
                    $parent.GetCommandName()
                }
            })
        @($receivers | Sort-Object -Unique) | Should -Be @('New-LocalUser', 'Register-RealPcPlantTask')
        $stageCommands = @($stage.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
        $stageCommands | Should -Not -Contain 'Register-ScheduledTask'
        $allCommands = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { [string]$_.GetCommandName() })
        @($allCommands | Where-Object { $_ -match '(?i)schtasks' }) | Should -BeNullOrEmpty
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
