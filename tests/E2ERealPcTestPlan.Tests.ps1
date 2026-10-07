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
        Get-RealPcReportPathProblem -Path 'C:\r' -State (New-RealPcReportPathState -LocalFolderInUse $true) | Should -Match 'winget-app-setup-localsecrets-r'' already exists'
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
        $plan | Should -Match 'C:\\winget-app-setup-localsecrets-report-xyz \(never zipped\)'
    }
}

Describe 'Invoke-RealPcTestPlanMain (plan only and refusals change nothing)' {
    BeforeAll {
        # Every command that changes the PC, or a stage that would.
        $script:ChangingCommands = @(
            'New-Item', 'Rename-Item', 'Remove-Item', 'Set-Content', 'Copy-Item', 'Move-Item', 'Start-Transcript',
            'New-LocalUser', 'Register-ScheduledTask', 'Start-ScheduledTask', 'Unregister-ScheduledTask',
            'Register-RealPcPlantTask', 'New-RealPcAdminJunction', 'Invoke-RealPcProcess', 'Invoke-RealPcInstaller', 'Invoke-RealPcModuleJson', 'Remove-RealPcHarnessLeftover', 'Save-RealPcArpSnapshot',
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
        Mock Save-RealPcArpSnapshot { }
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
        Mock Invoke-RealPcWingetSourceCheck { return [pscustomobject]@{ ExitCode = 0; Output = @('PowerShell Microsoft.PowerShell 7.6.6 winget') } }
        Mock Get-RealPcWingetSourcePackage { return '2026.1006.2038.44' }
        $script:WingetSourceChecks = @()
        $script:WingetSourceOpen = $null
        $script:FirstRunRecord = $null
    }

    It 'Checks the winget source again after the run, and keeps the run record for the later stages' {
        # As on the owner's PC once the source package was registered: Preflight could not open it.
        $script:WingetSourceChecks = @([pscustomobject]@{ When = ''; ExitCode = -1978335217; Opened = $false })
        $script:WingetSourceOpen = $false
        $rows = Invoke-RealPcFirstRunStage -EvidenceFolder $script:FirstRunEvidence
        $row = $rows | Where-Object { $_.Check -eq 'winget can open its source in this account (after the first run)' }
        $row.Result | Should -Be 'PASS'
        $row.Detail | Should -Match 'Microsoft\.Winget\.Source for this account: 2026\.1006\.2038\.44'
        $script:WingetSourceOpen | Should -Be $true
        @($script:WingetSourceChecks).Count | Should -Be 2
        $script:FirstRunRecord.buildId | Should -Be '1.0.0+5ea1f00d'
        [System.IO.File]::ReadAllText((Join-Path $script:FirstRunEvidence 'winget-source-check.txt')) | Should -Match 'after the first run; exit 0x00000000'
        Should -Invoke Invoke-RealPcWingetSourceCheck -Times 1 -Exactly
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
        Mock Invoke-RealPcWingetSourceCheck { return [pscustomobject]@{ ExitCode = 0; Output = @('PowerShell Microsoft.PowerShell 7.6.6 winget') } }
        Mock Get-RealPcWingetSourcePackage { return '2026.1006.2038.44' }
        $script:WingetSourceChecks = @()
        $script:WingetSourceOpen = $true
        # Get-RealPcWauTaskHealth's calls: before the preview, after it, after the real uninstall.
        $script:WauReads = 0
    }

    It 'Runs the -WhatIf preview non-interactively, so it never waits for a key press' {
        $null = Invoke-RealPcUninstallerStage -EvidenceFolder $script:UninstallerEvidence
        Should -Invoke Invoke-RealPcProcess -Times 1 -Exactly -ParameterFilter { $ArgumentList -contains '-WhatIf' -and $ArgumentList -contains '-NonInteractive' }
        Should -Invoke Invoke-RealPcProcess -Times 1 -Exactly -ParameterFilter { $ArgumentList -notcontains '-WhatIf' -and $ArgumentList -contains '-NonInteractive' }
    }

    It 'Fails each run that called apps not installed, and the success exit, while winget could not see this account''s apps' {
        # The owner's stage: the source check failed, both runs printed 'Skipping: <id> (not
        # installed)', and the real one removed Winget-AutoUpdate and exited 0.
        Mock Invoke-RealPcWingetSourceCheck { return [pscustomobject]@{ ExitCode = -1978335217; Output = @('0x8a15000f : Data required by the source is missing') } }
        Mock Get-RealPcWingetSourcePackage { return 'not registered' }
        Mock Get-RealPcWauTaskHealth { $script:WauReads++; return [pscustomobject]@{ Exists = ($script:WauReads -lt 3); Healthy = $true; Triggers = @('Daily') } }
        Mock Invoke-RealPcProcess {
            $name = 'realpc-sourcedatamissing-uninstall-console.txt'
            if ($ArgumentList -contains '-WhatIf') {
                $name = 'realpc-sourcedatamissing-whatif-console.txt'
            }
            return [pscustomobject]@{ ExitCode = 0; Output = @(Get-Content -LiteralPath (Join-Path $script:FixtureDirectory $name)) }
        }
        Mock Get-RealPcInstalledCatalogId { return [pscustomobject]@{ Installed = @(); Unknown = @('7zip.7zip') } }
        $rows = @(Invoke-RealPcUninstallerStage -EvidenceFolder $script:UninstallerEvidence)
        $real = $rows | Where-Object { $_.Check -like 'Uninstaller (real uninstall)*' }
        $real.Result | Should -Be 'FAIL'
        $real.Detail | Should -Match 'uninstaller could not see installed apps: it skipped .*7zip\.7zip'
        ($rows | Where-Object { $_.Check -like 'Uninstaller (preview)*' }).Result | Should -Be 'FAIL'
        $exit = $rows | Where-Object { $_.Check -eq 'Real uninstall stops with exit 2 while winget cannot open its source' }
        $exit.Result | Should -Be 'FAIL'
        $exit.Detail | Should -Be 'exit 0: reported success although winget could not see this account''s apps'
        ($rows | Where-Object { $_.Check -eq 'Winget-AutoUpdate kept while winget cannot open its source' }).Result | Should -Be 'FAIL'
        ($rows | Where-Object { $_.Check -eq 'winget can open its source in this account (before the uninstaller)' }).Result | Should -Be 'FAIL'
        @($rows | Where-Object { $_.Result -eq 'PASS' }) | Should -BeNullOrEmpty
        [System.IO.File]::ReadAllText((Join-Path $script:UninstallerEvidence 'winget-source-check.txt')) | Should -Match 'before the uninstaller; exit 0x8A15000F \(SOURCE_DATA_MISSING\); Microsoft\.Winget\.Source for this account: not registered'
    }

    It 'Passes the uninstaller that refuses with exit 2 and keeps Winget-AutoUpdate while the source is closed' {
        Mock Invoke-RealPcWingetSourceCheck { return [pscustomobject]@{ ExitCode = -1978335217; Output = @() } }
        Mock Get-RealPcWauTaskHealth { return [pscustomobject]@{ Exists = $true; Healthy = $true; Triggers = @('Daily') } }
        Mock Invoke-RealPcProcess {
            if ($ArgumentList -contains '-WhatIf') {
                return [pscustomobject]@{ ExitCode = 0; Output = @('[DRY-RUN] winget cannot be started for this account yet. A real run would stop with exit code 2 before removing anything.') }
            }
            return [pscustomobject]@{ ExitCode = 2; Output = @('winget cannot open its source for this account (see above), so nothing was uninstalled: without it winget cannot tell which apps are installed. Winget-AutoUpdate was left in place, so the apps keep getting updates.') }
        }
        $rows = @(Invoke-RealPcUninstallerStage -EvidenceFolder $script:UninstallerEvidence)
        $exit = $rows | Where-Object { $_.Check -eq 'Real uninstall stops with exit 2 while winget cannot open its source' }
        $exit.Result | Should -Be 'PASS'
        $exit.Detail | Should -Match '^exit 2: refused'
        ($rows | Where-Object { $_.Check -eq 'Winget-AutoUpdate kept while winget cannot open its source' }).Result | Should -Be 'PASS'
        @($rows | Where-Object { $_.Result -eq 'FAIL' } | ForEach-Object { $_.Check }) | Should -Be @('winget can open its source in this account (before the uninstaller)')
    }

    It 'Judges the uninstaller as usual when the source opens before it, although an earlier check failed' {
        # The check after the first run failed; a later installer run repaired the source.
        $script:WingetSourceChecks = @([pscustomobject]@{ When = 'after the first run'; ExitCode = -1978335217; Opened = $false; SourcePackage = 'not registered' })
        $script:WingetSourceOpen = $false
        Mock Get-RealPcWauTaskHealth { $script:WauReads++; return [pscustomobject]@{ Exists = ($script:WauReads -lt 3); Healthy = $true; Triggers = @('Daily') } }
        $rows = @(Invoke-RealPcUninstallerStage -EvidenceFolder $script:UninstallerEvidence)
        $script:WingetSourceOpen | Should -Be $true
        ($rows | Where-Object { $_.Check -eq 'winget can open its source in this account (before the uninstaller)' }).Result | Should -Be 'PASS'
        ($rows | Where-Object { $_.Check -eq 'Real uninstall exits 0 or 3010' }).Result | Should -Be 'PASS'
        ($rows | Where-Object { $_.Check -eq 'Winget-AutoUpdate removed' }).Result | Should -Be 'PASS'
        @($rows | Where-Object { $_.Check -like '*while winget cannot open its source' }) | Should -BeNullOrEmpty
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

    It 'Points the TightVNC leftover at the local folder by its real path, not the zip' {
        ((Get-RealPcManualLeftover -LocalFolder 'C:\Temp\winget-app-setup-localsecrets-real-pc-report') -join "`n") | Should -Match 'manual-steps\.txt \(in C:\\Temp\\winget-app-setup-localsecrets-real-pc-report; it is not in the zip\)'
        ((Get-RealPcManualLeftover) -join "`n") | Should -Match 'winget-app-setup-localsecrets-\.\.\. folder next to the report folder \(the run prints its exact path\); it is not in the zip'
    }
}

Describe 'winget lookups ask the winget source (wgt-gq8.65 H1)' {
    BeforeEach {
        # winget as on the owner's PC (2026-10-06): without --source the broken 'winget' source is
        # only a warning and an installed app reads 'no package found' (0x8A150014); with it, the
        # lookup fails with SOURCE_DATA_MISSING (0x8A15000F).
        Mock winget {
            if ($args -contains '--source') {
                'Failed when opening source(s); try the ''source reset'' command if the problem persists.'
                '0x8a15000f : Data required by the source is missing'
                $global:LASTEXITCODE = -1978335217
            }
            else {
                'Failed when searching source; results will not be included: winget'
                'No installed package found matching input criteria.'
                $global:LASTEXITCODE = -1978335212
            }
        }
    }

    It 'Reads a lookup through a source that cannot open as no answer, never as not installed' {
        Test-RealPcWingetInstalled -Id '7zip.7zip' | Should -BeNullOrEmpty
        Should -Invoke winget -Times 1 -Exactly -ParameterFilter { $args[0] -eq 'list' -and ($args -join ' ') -match '--id 7zip\.7zip --exact --source winget' }
    }

    It 'Uninstalls from the winget source too, and keeps the exit code' {
        $result = Invoke-RealPcWingetUninstall -Id '7zip.7zip'
        $result.ExitCode | Should -Be -1978335217
        $result.Problem | Should -BeNullOrEmpty
        Should -Invoke winget -Times 1 -Exactly -ParameterFilter { $args[0] -eq 'uninstall' -and ($args -join ' ') -match '--id 7zip\.7zip --exact --source winget --silent' }
    }

    It 'Checks the source with a search of the winget source, and keeps what winget printed' {
        $result = Invoke-RealPcWingetSourceCheck
        $result.ExitCode | Should -Be -1978335217
        ($result.Output -join "`n") | Should -Match 'Data required by the source is missing'
        Should -Invoke winget -Times 1 -Exactly -ParameterFilter { ($args -join ' ') -eq 'search --id Microsoft.PowerShell --exact --source winget --accept-source-agreements --disable-interactivity' }
    }

    It 'Gives no exit code, and no answer, when winget cannot run' {
        Mock winget { throw [System.Management.Automation.CommandNotFoundException]::new('winget is not here') }
        (Invoke-RealPcWingetSourceCheck).ExitCode | Should -BeNullOrEmpty
        (Invoke-RealPcWingetUninstall -Id '7zip.7zip').Problem | Should -Match '^not run: '
        Test-RealPcWingetInstalled -Id '7zip.7zip' | Should -BeNullOrEmpty
    }
}

Describe 'The source check, the cross-user fact and the report banner (wgt-gq8.65 H2)' {
    BeforeEach {
        $script:WingetSourceChecks = @()
        $script:WingetSourceOpen = $null
    }

    It 'Names the winget codes the owner''s run showed' {
        Format-RealPcWingetExitCode -ExitCode -1978335217 | Should -Be '0x8A15000F (SOURCE_DATA_MISSING)'
        Format-RealPcWingetExitCode -ExitCode -1978335212 | Should -Be '0x8A150014 (NO_APPLICATIONS_FOUND)'
        Format-RealPcWingetExitCode -ExitCode 0 | Should -Be '0x00000000'
        Format-RealPcWingetExitCode -ExitCode $null | Should -Be 'no exit code'
    }

    It 'Passes the source check only on exit 0' {
        (Get-RealPcWingetSourceRow -ExitCode 0 -SourcePackage '2026.1006.2038.44').Result | Should -Be 'PASS'
        foreach ($code in @(-1978335217, -1978335212, 1)) {
            (Get-RealPcWingetSourceRow -ExitCode $code).Result | Should -Be 'FAIL'
        }
        $noAnswer = Get-RealPcWingetSourceRow -ExitCode $null
        $noAnswer.Result | Should -Be 'FAIL'
        $noAnswer.Detail | Should -Match 'did not run to the end'
    }

    It 'Says what SOURCE_DATA_MISSING means, and names the check after the first run' {
        $row = Get-RealPcWingetSourceRow -ExitCode -1978335217 -When 'after the first run' -SourcePackage 'not registered'
        $row.Check | Should -Be 'winget can open its source in this account (after the first run)'
        $row.Detail | Should -Match '0x8A15000F \(SOURCE_DATA_MISSING\); Microsoft\.Winget\.Source for this account: not registered'
        $row.Detail | Should -Match 'cross-user elevation \(0x80073D19, issue #159\)'
    }

    It 'Compares the signed-in and the elevated account by SID' {
        Get-RealPcCrossUserElevation -ElevatedUser 'CONTOSO\admin-tech' -ElevatedSid 'S-1-5-21-1-2-3-1107' -SessionUser 'CONTOSO\jdoe' -SessionUserSid 'S-1-5-21-1-2-3-1104' | Should -Be 'yes (signed in as CONTOSO\jdoe S-1-5-21-1-2-3-1104, elevated as CONTOSO\admin-tech S-1-5-21-1-2-3-1107)'
        Get-RealPcCrossUserElevation -ElevatedUser 'PC\admin' -ElevatedSid 'S-1-5-21-9-500' -SessionUser 'pc\ADMIN' -SessionUserSid 's-1-5-21-9-500' | Should -Be 'no (signed in and elevated as PC\admin)'
        Get-RealPcCrossUserElevation -ElevatedUser 'PC\admin' -ElevatedSid 'S-1-5-21-9-500' | Should -Match '^unknown \(no signed-in user found in this session'
        Get-RealPcCrossUserElevation | Should -Match '^unknown'
    }

    It 'Records each check for the later stages, and starts the report with a warning when one failed' {
        (Add-RealPcWingetSourceCheck -ExitCode -1978335217 -SourcePackage 'not registered').Result | Should -Be 'FAIL'
        $script:WingetSourceOpen | Should -Be $false
        (Add-RealPcWingetSourceCheck -ExitCode 0 -When 'after the first run').Result | Should -Be 'PASS'
        $script:WingetSourceOpen | Should -Be $true
        $script:WingetSourceChecks[0].SourcePackage | Should -Be 'not registered'
        $banner = @(Get-RealPcReportBanner -SourceCheck $script:WingetSourceChecks -Account 'CONTOSO\admin-tech' -CrossUser 'yes (signed in as CONTOSO\jdoe S-1, elevated as CONTOSO\admin-tech S-2)' -StageName @('Preflight', 'FirstRun', 'Uninstaller'))
        $banner[0] | Should -Be 'WARNING: winget could not open its ''winget'' source in the account this harness ran as (CONTOSO\admin-tech) (at Preflight: 0x8A15000F (SOURCE_DATA_MISSING)).'
        ($banner -join "`n") | Should -Match 'It opened after the first run, so the stages after that asked winget as usual\.'
        ($banner -join "`n") | Should -Match 'Cross-user elevation: yes \(signed in as CONTOSO\\jdoe'
        @(Get-RealPcReportBanner -SourceCheck @([pscustomobject]@{ When = ''; ExitCode = 0; Opened = $true })) | Should -BeNullOrEmpty
        @(Get-RealPcReportBanner) | Should -BeNullOrEmpty
    }

    It 'Says the installer and uninstaller ran with a blind winget only when the latest check still failed, and only those that ran' {
        $opened = @(
            [pscustomobject]@{ When = ''; ExitCode = -1978335217; Opened = $false }
            [pscustomobject]@{ When = 'after the first run'; ExitCode = 0; Opened = $true }
        )
        $text = (Get-RealPcReportBanner -SourceCheck $opened -StageName @('Preflight', 'FirstRun', 'Uninstaller')) -join "`n"
        $text | Should -Not -Match 'blind winget'
        $text | Should -Match 'Until it opened, winget read every installed app as not installed there'
        $closed = @(
            [pscustomobject]@{ When = ''; ExitCode = -1978335217; Opened = $false }
            [pscustomobject]@{ When = 'after the first run'; ExitCode = -1978335217; Opened = $false }
        )
        $both = @(Get-RealPcReportBanner -SourceCheck $closed -StageName @('Preflight', 'FirstRun', 'ReRun', 'Uninstaller'))
        $both[1] | Should -Be 'While it cannot, winget reads every installed app as not installed there: the checks that ask it are SKIP or FAIL, never PASS. The installer and the uninstaller ran in this account with the same blind winget.'
        $both[0] | Should -Match '\(at Preflight: 0x8A15000F \(SOURCE_DATA_MISSING\); after the first run: 0x8A15000F'
        (@(Get-RealPcReportBanner -SourceCheck $closed -StageName @('Preflight', 'FirstRun'))[1]) | Should -Match ' The installer ran in this account with the same blind winget\.$'
        (@(Get-RealPcReportBanner -SourceCheck $closed -StageName @('Preflight'))[1]) | Should -Be 'While it cannot, winget reads every installed app as not installed there: the checks that ask it are SKIP or FAIL, never PASS.'
    }

    It 'Makes a failed check SKIP, keeping its code, when a later check opened the source' {
        $row = Get-RealPcWingetSourceRow -ExitCode -1978335217 -SourcePackage 'not registered' -OpenedLater 'after the first run'
        $row.Check | Should -Be 'winget can open its source in this account'
        $row.Result | Should -Be 'SKIP'
        $row.Detail | Should -Match '^winget search --id Microsoft\.PowerShell --exact --source winget: 0x8A15000F \(SOURCE_DATA_MISSING\); Microsoft\.Winget\.Source for this account: not registered\. It opened after the first run;'
        $row.Detail | Should -Match 'cross-user elevation \(0x80073D19, issue #159\)'
        $row.Detail | Should -Match 'not a product result$'
        (Get-RealPcWingetSourceRow -ExitCode 0 -OpenedLater 'after the first run').Result | Should -Be 'PASS'
    }

    It 'Puts the warning under the title of both reports, before the overall result' {
        $stages = @([pscustomobject]@{ Name = 'Preflight'; Number = 0; Item = '0'; DurationSeconds = 1; Rows = @([pscustomobject]@{ Check = 'x'; Result = 'FAIL'; Detail = '' }) })
        $banner = @('WARNING: winget could not open its source.', 'Second line.')
        $text = Format-RealPcReport -MachineFacts ([ordered]@{ OS = 'Windows 11' }) -StageResult $stages -Banner $banner
        $text.IndexOf('!! WARNING: winget could not open its source.') | Should -BeGreaterThan 0
        $text.IndexOf('!! WARNING: winget could not open its source.') | Should -BeLessThan $text.IndexOf('Overall:')
        $text | Should -Match '(?m)^!! Second line\.'
        $markdown = Format-RealPcReport -MachineFacts ([ordered]@{ OS = 'Windows 11' }) -StageResult $stages -Banner $banner -Markdown
        $markdown.IndexOf('> **WARNING: winget could not open its source.**') | Should -BeGreaterThan 0
        $markdown.IndexOf('> **WARNING: winget could not open its source.**') | Should -BeLessThan $markdown.IndexOf('**Overall:')
        (Format-RealPcReport -MachineFacts ([ordered]@{ OS = 'Windows 11' }) -StageResult $stages) | Should -Not -Match '!!'
    }
}

Describe 'Update-RealPcPreflightSourceRow (Preflight''s check once a later one opened the source)' {
    BeforeAll {
        function New-RealPcSourceStage {
            param ([string]$Name, [object[]]$Rows)
            return [pscustomobject]@{ Name = $Name; Number = 0; Item = '0'; DurationSeconds = 5; Rows = $Rows }
        }
    }

    BeforeEach {
        $script:SourceStages = @(
            New-RealPcSourceStage -Name 'Preflight' -Rows @(
                (New-TestPlanRow -Check 'Running elevated' -Result 'PASS' -Detail 'administrator'),
                (Get-RealPcWingetSourceRow -ExitCode -1978335217 -SourcePackage 'not registered')
            )
            New-RealPcSourceStage -Name 'FirstRun' -Rows @(Get-RealPcWingetSourceRow -ExitCode 0 -When 'after the first run')
        )
    }

    It 'Turns Preflight''s FAIL into SKIP when the latest check opened the source, and changes nothing else' {
        $checks = @(
            [pscustomobject]@{ When = ''; ExitCode = -1978335217; Opened = $false; SourcePackage = 'not registered' }
            [pscustomobject]@{ When = 'after the first run'; ExitCode = 0; Opened = $true; SourcePackage = '2026.1006.2038.44' }
        )
        $updated = @(Update-RealPcPreflightSourceRow -StageResult $script:SourceStages -SourceCheck $checks)
        $updated.Count | Should -Be 2
        $row = $updated[0].Rows | Where-Object { $_.Check -eq 'winget can open its source in this account' }
        $row.Result | Should -Be 'SKIP'
        $row.Detail | Should -Match 'Microsoft\.Winget\.Source for this account: not registered\. It opened after the first run;'
        ($updated[0].Rows | Where-Object { $_.Check -eq 'Running elevated' }).Result | Should -Be 'PASS'
        $updated[0].DurationSeconds | Should -Be 5
        $updated[1].Rows[0].Result | Should -Be 'PASS'
        Get-RealPcExitCode -Rows @($updated | ForEach-Object { $_.Rows }) | Should -Be 0
        # The input is left as it was.
        ($script:SourceStages[0].Rows | Where-Object { $_.Check -eq 'winget can open its source in this account' }).Result | Should -Be 'FAIL'
    }

    It 'Keeps the FAIL while the latest check still fails, or when Preflight did not check' {
        $closed = @(
            [pscustomobject]@{ When = ''; ExitCode = -1978335217; Opened = $false; SourcePackage = 'not registered' }
            [pscustomobject]@{ When = 'after the first run'; ExitCode = 0; Opened = $true; SourcePackage = '' }
            [pscustomobject]@{ When = 'before the uninstaller'; ExitCode = -1978335217; Opened = $false; SourcePackage = '' }
        )
        $updated = @(Update-RealPcPreflightSourceRow -StageResult $script:SourceStages -SourceCheck $closed)
        ($updated[0].Rows | Where-Object { $_.Check -eq 'winget can open its source in this account' }).Result | Should -Be 'FAIL'
        $noPreflight = @([pscustomobject]@{ When = 'after the first run'; ExitCode = 0; Opened = $true; SourcePackage = '' })
        $same = @(Update-RealPcPreflightSourceRow -StageResult $script:SourceStages -SourceCheck $noPreflight)
        ($same[0].Rows | Where-Object { $_.Check -eq 'winget can open its source in this account' }).Result | Should -Be 'FAIL'
        @(Update-RealPcPreflightSourceRow -StageResult @() -SourceCheck @()) | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-RealPcPreflightStage (wiring, with every outside call mocked)' {
    BeforeEach {
        $script:MachineFacts = [ordered]@{}
        $script:ReportFolder = Join-Path $TestDrive 'report'
        $script:RealPcOptions = [pscustomobject]@{ UseOneLiner = $false; Branch = 'b'; ResetProgramData = $false }
        $script:WingetSourceChecks = @()
        $script:WingetSourceOpen = $null
        $script:PreflightEvidence = Join-Path $TestDrive ('evidence-preflight-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:PreflightEvidence -Force

        Mock Get-CimInstance { return [pscustomobject]@{ Caption = 'Microsoft Windows 11 Pro'; BuildNumber = '26200' } }
        Mock Test-RealPcElevated { return $true }
        Mock Test-RealPcWindowsSandbox { return $false }
        Mock Test-RealPcWingetPresent { return $true }
        Mock Test-RealPcUrlReachable { return [pscustomobject]@{ Url = $Url; Reachable = $true; Detail = 'HTTP 200' } }
        Mock Get-RealPcCatalogId { return @('7zip.7zip', 'Microsoft.PowerShell') }
        Mock Test-RealPcWingetInstalled { return $null }
        # As on the owner's PC (names made up): a standard user signed in over Remote Desktop, the
        # window elevated as an administrator whose winget source package was never registered.
        Mock Get-RealPcAccountFact {
            return [pscustomobject]@{
                ElevatedUser   = 'CONTOSO\admin-tech'
                ElevatedSid    = 'S-1-5-21-1-2-3-1107'
                ProfileCreated = '2026-10-06 14:30:00'
                SessionUser    = 'CONTOSO\jdoe'
                SessionUserSid = 'S-1-5-21-1-2-3-1104'
                ConsoleUser    = ''
                Sessions       = @('SESSIONNAME USERNAME ID STATE TYPE DEVICE', 'console 1 Conn', '>rdp-tcp#0 jdoe 2 Active')
            }
        }
        Mock Get-RealPcWingetFact {
            $raw = [ordered]@{}
            $raw['winget --info (exit 0x00000000)'] = @('Windows Package Manager v1.29.380')
            $raw['winget source list (exit 0x00000000)'] = @('winget      https://cdn.winget.microsoft.com/cache')
            $raw['Get-AppxPackage -AllUsers -Name Microsoft.Winget.Source (PackageUserInformation)'] = @('no account has it registered')
            return [pscustomobject]@{ WingetVersion = 'v1.29.380'; AppInstallerVersion = '1.29.380.0'; SourcePackage = 'not registered'; Raw = $raw }
        }
        Mock Invoke-RealPcWingetSourceCheck {
            return [pscustomobject]@{ ExitCode = -1978335217; Output = @('Failed when opening source(s); try the ''source reset'' command if the problem persists.', '0x8a15000f : Data required by the source is missing') }
        }
    }

    It 'Fails the source check, skips the installed-apps row, and records who is signed in (the owner''s run)' {
        $rows = @(Invoke-RealPcPreflightStage -EvidenceFolder $script:PreflightEvidence)
        $source = $rows | Where-Object { $_.Check -eq 'winget can open its source in this account' }
        $source.Result | Should -Be 'FAIL'
        $source.Detail | Should -Match '0x8A15000F \(SOURCE_DATA_MISSING\); Microsoft\.Winget\.Source for this account: not registered'
        $installed = $rows | Where-Object { $_.Check -eq 'No catalog app installed yet' }
        $installed.Result | Should -Be 'SKIP'
        $installed.Detail | Should -Match 'winget cannot see this account''s apps'
        $script:WingetSourceOpen | Should -Be $false
        $script:MachineFacts['Cross-user elevation'] | Should -Match '^yes \(signed in as CONTOSO\\jdoe S-1-5-21-1-2-3-1104, elevated as CONTOSO\\admin-tech'
        $script:MachineFacts['winget version'] | Should -Be 'v1.29.380'
        $script:MachineFacts['winget source package (this account)'] | Should -Be 'not registered'
        $script:MachineFacts['Sessions (qwinsta)'] | Should -Match 'rdp-tcp#0 jdoe 2 Active'
        $info = [System.IO.File]::ReadAllText((Join-Path $script:PreflightEvidence 'winget-info.txt'))
        $info | Should -Match '== winget search --id Microsoft\.PowerShell --exact --source winget \(the source check; exit 0x8A15000F \(SOURCE_DATA_MISSING\)\) =='
        $info | Should -Match 'Data required by the source is missing'
        $info | Should -Match '== winget --info \(exit 0x00000000\) =='
        $info | Should -Match 'no account has it registered'
    }

    It 'Passes the source check, and asks winget what is installed, when the source opens' {
        Mock Invoke-RealPcWingetSourceCheck { return [pscustomobject]@{ ExitCode = 0; Output = @('PowerShell Microsoft.PowerShell 7.6.6 winget') } }
        Mock Test-RealPcWingetInstalled { return $false }
        $rows = @(Invoke-RealPcPreflightStage -EvidenceFolder $script:PreflightEvidence)
        ($rows | Where-Object { $_.Check -eq 'winget can open its source in this account' }).Result | Should -Be 'PASS'
        ($rows | Where-Object { $_.Check -eq 'No catalog app installed yet' }).Result | Should -Be 'PASS'
        $script:WingetSourceOpen | Should -Be $true
    }

    It 'Skips the source check on a PC that has no winget yet, and leaves the later stages to ask' {
        Mock Test-RealPcWingetPresent { return $false }
        $rows = @(Invoke-RealPcPreflightStage -EvidenceFolder $script:PreflightEvidence)
        $source = $rows | Where-Object { $_.Check -eq 'winget can open its source in this account' }
        $source.Result | Should -Be 'SKIP'
        $source.Detail | Should -Match 'the check runs again after it'
        Should -Invoke Invoke-RealPcWingetSourceCheck -Times 0 -Exactly
        $script:WingetSourceOpen | Should -BeNullOrEmpty
        @($script:WingetSourceChecks).Count | Should -Be 0
    }
}

Describe 'Replaying the owner''s run of 2026-10-06 (winget source data missing, wgt-gq8.65 H3/H4)' {
    BeforeAll {
        $script:OwnerRecord = ConvertFrom-Json -InputObject ([string](Get-Content -Raw -LiteralPath (Join-Path $script:FixtureDirectory 'realpc-sourcedatamissing-last-run.json')))
        $script:OwnerWhatIfConsole = [string](Get-Content -Raw -LiteralPath (Join-Path $script:FixtureDirectory 'realpc-sourcedatamissing-whatif-console.txt'))
        $script:OwnerUninstallConsole = [string](Get-Content -Raw -LiteralPath (Join-Path $script:FixtureDirectory 'realpc-sourcedatamissing-uninstall-console.txt'))
    }

    It 'Fails the time-budget removal check when winget uninstall found no package (0x8A150014)' {
        # The owner's row passed: 'winget uninstall exit -1978335212; winget no longer lists it'.
        $row = Get-RealPcUninstallCheckRow -AppId '7zip.7zip' -Present $false -UninstallExitCode -1978335212
        $row.Result | Should -Be 'FAIL'
        $row.Detail | Should -Be 'winget uninstall 0x8A150014 (NO_APPLICATIONS_FOUND): winget found no package; not removed'
    }

    It 'Skips the time-budget removal check when winget cannot see this account''s apps, and fails an uninstall that did not run' {
        $blind = Get-RealPcUninstallCheckRow -AppId '7zip.7zip' -Present $null -UninstallExitCode -1978335217 -SourceOpen $false
        $blind.Result | Should -Be 'SKIP'
        $blind.Detail | Should -Match '^winget uninstall 0x8A15000F \(SOURCE_DATA_MISSING\); winget cannot see this account''s apps'
        $notRun = Get-RealPcUninstallCheckRow -AppId '7zip.7zip' -Present $false -UninstallExitCode $null -UninstallProblem 'not run: winget is not here'
        $notRun.Result | Should -Be 'FAIL'
        $notRun.Detail | Should -Match 'did not run to the end'
    }

    It 'Lets no uninstaller row pass on what a blind winget found' {
        # Every lookup found nothing, the uninstaller skipped every app as not installed, removed
        # Winget-AutoUpdate and exited 0, and the old rows all passed.
        $rows = Get-RealPcUninstallerResult -WhatIfInstalledBefore @() -WhatIfInstalledAfter @() -WhatIfWauBefore $true -WhatIfWauAfter $true -ExitCode 0 -InstalledAfter @() -UnknownIds @() -WauPresentAfter $false -SourceOpen $false -WhatIfConsoleText $script:OwnerWhatIfConsole -UninstallConsoleText $script:OwnerUninstallConsole
        @($rows | Where-Object { $_.Result -eq 'PASS' }) | Should -BeNullOrEmpty
        ($rows | Where-Object { $_.Check -eq 'winget answered for every catalog app' }).Result | Should -Be 'SKIP'
        ($rows | Where-Object { $_.Check -eq 'Uninstaller -WhatIf changed nothing' }).Result | Should -Be 'SKIP'
        ($rows | Where-Object { $_.Check -eq 'Catalog apps removed (except what the uninstaller keeps on purpose)' }).Result | Should -Be 'SKIP'
        $exit = $rows | Where-Object { $_.Check -eq 'Real uninstall stops with exit 2 while winget cannot open its source' }
        $exit.Result | Should -Be 'FAIL'
        $exit.Detail | Should -Be 'exit 0: reported success although winget could not see this account''s apps'
        @($rows | Where-Object { $_.Check -eq 'Real uninstall exits 0 or 3010' }) | Should -BeNullOrEmpty
        $real = $rows | Where-Object { $_.Check -like 'Uninstaller (real uninstall)*' }
        $real.Result | Should -Be 'FAIL'
        $real.Detail | Should -Match 'uninstaller could not see installed apps: it skipped 7zip\.7zip, .*Google\.Chrome'
        ($rows | Where-Object { $_.Check -like 'Uninstaller (preview)*' }).Result | Should -Be 'FAIL'
        $wau = $rows | Where-Object { $_.Check -eq 'Winget-AutoUpdate kept while winget cannot open its source' }
        $wau.Result | Should -Be 'FAIL'
        $wau.Detail | Should -Match 'removed although winget could not see this account''s apps'
    }

    It 'Passes the refusal the product owes while the source is closed: exit 2, nothing skipped as not installed, Winget-AutoUpdate kept' {
        $refusal = 'winget cannot open its source for this account (see above), so nothing was uninstalled: without it winget cannot tell which apps are installed. Winget-AutoUpdate was left in place, so the apps keep getting updates.'
        $rows = Get-RealPcUninstallerResult -WhatIfWauBefore $true -WhatIfWauAfter $true -ExitCode 2 -WauPresentAfter $true -SourceOpen $false -WhatIfConsoleText '[DRY-RUN] A real run would stop with exit code 2 before removing anything.' -UninstallConsoleText $refusal
        @($rows | Where-Object { $_.Result -eq 'FAIL' }) | Should -BeNullOrEmpty
        @($rows | Where-Object { $_.Result -eq 'PASS' } | ForEach-Object { $_.Check }) | Should -Be @(
            'Real uninstall stops with exit 2 while winget cannot open its source',
            'Uninstaller (preview) called no app it could not see ''not installed''',
            'Uninstaller (real uninstall) called no app it could not see ''not installed''',
            'Winget-AutoUpdate kept while winget cannot open its source'
        )
        ($rows | Where-Object { $_.Check -like 'Real uninstall stops*' }).Detail | Should -Be 'exit 2: refused, as winget could not open its source in this account'
    }

    It 'Fails other exit codes while the source is closed, and skips Winget-AutoUpdate when it was never there' {
        foreach ($code in @(3010, 1, 5)) {
            (Get-RealPcUninstallerResult -ExitCode $code -SourceOpen $false -WhatIfWauBefore $true -WhatIfWauAfter $true -WauPresentAfter $true | Where-Object { $_.Check -like 'Real uninstall stops*' }).Result | Should -Be 'FAIL'
        }
        (Get-RealPcUninstallerResult -ExitCode 1 -SourceOpen $false -WhatIfWauBefore $true -WhatIfWauAfter $true -WauPresentAfter $true | Where-Object { $_.Check -like 'Real uninstall stops*' }).Detail | Should -Be 'exit 1, not 2 (winget could not open its source in this account)'
        (Get-RealPcUninstallerResult -ExitCode $null -SourceOpen $false | Where-Object { $_.Check -like 'Real uninstall stops*' }).Result | Should -Be 'FAIL'
        $never = Get-RealPcUninstallerResult -ExitCode 2 -SourceOpen $false -WhatIfWauBefore $false -WhatIfWauAfter $false -WauPresentAfter $false | Where-Object { $_.Check -like 'Winget-AutoUpdate*' }
        $never.Result | Should -Be 'SKIP'
        $never.Detail | Should -Match 'was not installed before the real uninstall'
    }

    It 'Skips the -WhatIf row when winget listed no catalog app before or after, and fails a changed Winget-AutoUpdate' {
        $empty = Get-RealPcUninstallerResult -WhatIfInstalledBefore @() -WhatIfInstalledAfter @() -WhatIfWauBefore $true -WhatIfWauAfter $true -ExitCode 0 -WauPresentAfter $false -SourceOpen $true
        ($empty | Where-Object { $_.Check -eq 'Uninstaller -WhatIf changed nothing' }).Result | Should -Be 'SKIP'
        ($empty | Where-Object { $_.Check -eq 'Winget-AutoUpdate removed' }).Result | Should -Be 'PASS'
        $changed = Get-RealPcUninstallerResult -WhatIfWauBefore $true -WhatIfWauAfter $false -ExitCode 0 -SourceOpen $false
        ($changed | Where-Object { $_.Check -eq 'Uninstaller -WhatIf changed nothing' }).Result | Should -Be 'FAIL'
        # The uninstaller's own lines are only read when winget could not see this account's apps.
        @(Get-RealPcUninstallerResult -ExitCode 0 -SourceOpen $true -UninstallConsoleText $script:OwnerUninstallConsole | Where-Object { $_.Check -like 'Uninstaller (*' }) | Should -BeNullOrEmpty
    }

    It 'Reads the apps the uninstaller skipped as not installed from its console' {
        $ids = @(Get-RealPcNotInstalledSkip -Text $script:OwnerUninstallConsole)
        $ids.Count | Should -Be 11
        $ids | Should -Contain 'Adobe.Acrobat.Reader.64-bit'
        $ids | Should -Contain 'Microsoft.WindowsTerminal'
        @(Get-RealPcNotInstalledSkip -Text 'Skipping: Microsoft.PowerShell (runs this uninstaller)') | Should -BeNullOrEmpty
        @(Get-RealPcNotInstalledSkip -Text '') | Should -BeNullOrEmpty
    }

    It 'Expects the re-run and the SYSTEM run to install or find what the first run failed, not to find it already there' {
        $expectation = @(
            New-RealPcExpectation -Id '7zip.7zip' -Expected 'AlreadyPresent'
            New-RealPcExpectation -Id 'Git.Git' -Expected 'AlreadyPresent'
            New-RealPcExpectation -Id 'Adobe.Acrobat.Reader.32-bit' -Expected 'NotApplicable' -Reason 'not applicable: ARM64 and 32-bit Windows only; x64 PCs get the 64-bit Reader' -AlreadyPresentReasons @()
        )
        $adjusted = Set-RealPcFirstRunExpectation -AppExpectation $expectation -FirstRunRecord $script:OwnerRecord
        @($adjusted.Value | ForEach-Object { $_.Expected }) | Should -Be @('Installed', 'Installed', 'NotApplicable')
        @($adjusted.Value | Where-Object { $_.MustInstall }) | Should -BeNullOrEmpty
        @($adjusted.Changed).Count | Should -Be 2
        @($adjusted.Changed)[0] | Should -Match '^7zip\.7zip \(Failed \(the winget source data is missing; winget exit 0x8A15000F'
    }

    It 'Passes the owner''s SYSTEM run, which found 7-Zip and installed Git and BCU, instead of three wrong-reason FAILs' {
        $expectation = @(
            New-RealPcExpectation -Id '7zip.7zip' -Expected 'AlreadyPresent'
            New-RealPcExpectation -Id 'Git.Git' -Expected 'AlreadyPresent'
            New-RealPcExpectation -Id 'Klocman.BulkCrapUninstaller' -Expected 'AlreadyPresent'
        )
        $system = [pscustomobject]@{ schemaVersion = 1; apps = @(
                [pscustomobject]@{ id = '7zip.7zip'; status = 'Skipped'; reason = 'already installed' }
                [pscustomobject]@{ id = 'Git.Git'; status = 'Installed'; reason = $null }
                [pscustomobject]@{ id = 'Klocman.BulkCrapUninstaller'; status = 'Installed'; reason = $null }
            )
        }
        $adjusted = (Set-RealPcFirstRunExpectation -AppExpectation $expectation -FirstRunRecord $script:OwnerRecord).Value
        $rows = @(Get-SystemPassAppResult -RunRecord $system -AppExpectation $adjusted)
        @($rows | Where-Object { $_.Result -eq 'FAIL' }) | Should -BeNullOrEmpty
        ($rows | Where-Object { $_.Assertion -match 'Git\.Git' }).Assertion | Should -Be 'App installed: Git.Git'
        # What the stage checked before: 'App already present on the second run' failed for Git.
        (@(Get-SystemPassAppResult -RunRecord $system -AppExpectation $expectation) | Where-Object { $_.Assertion -match 'Git\.Git' }).Result | Should -Be 'FAIL'
    }
}

Describe 'Expectations from the first run, and the re-run''s Installed branch (wgt-gq8.65 H4)' {
    It 'Keeps AlreadyPresent for what the first run left installed, and changes the rest' {
        $expectation = @(
            New-RealPcExpectation -Id '7zip.7zip' -Expected 'AlreadyPresent'
            New-RealPcExpectation -Id 'Microsoft.WindowsTerminal' -Expected 'AlreadyPresent'
        )
        $record = Get-FirstRunRecord
        $record.apps[0].status = 'Skipped'
        $record.apps[0].reason = 'already installed'
        ($record.apps | Where-Object { $_.id -eq 'Microsoft.WindowsTerminal' }).status = 'NotAttempted'
        $adjusted = Set-RealPcFirstRunExpectation -AppExpectation $expectation -FirstRunRecord $record
        @($adjusted.Value | ForEach-Object { $_.Expected }) | Should -Be @('AlreadyPresent', 'Installed')
        @($adjusted.Changed) | Should -Be @('Microsoft.WindowsTerminal (NotAttempted)')
        $none = Set-RealPcFirstRunExpectation -AppExpectation $expectation -FirstRunRecord $null
        @($none.Value | ForEach-Object { $_.Expected }) | Should -Be @('Installed', 'Installed')
        @($none.Changed)[0] | Should -Be '7zip.7zip (the first run left no last-run.json)'
    }

    It 'Names the changed apps in one SKIP row, and adds none when nothing changed' {
        $row = @(Get-RealPcFirstRunGapRow -Changed @('Git.Git (Failed (x))') -Run 'The re-run')
        $row.Count | Should -Be 1
        $row[0].Result | Should -Be 'SKIP'
        $row[0].Check | Should -Be 'Apps the first run did not leave installed'
        $row[0].Detail | Should -Be 'The re-run expects these installed or found, not already there: Git.Git (Failed (x))'
        @(Get-RealPcFirstRunGapRow -Changed @()) | Should -BeNullOrEmpty
    }

    It 'Passes an app the re-run installed or found, and fails one it did not' {
        $record = [pscustomobject]@{ apps = @(
                [pscustomobject]@{ id = '7zip.7zip'; status = 'Installed'; reason = $null }
                [pscustomobject]@{ id = 'Git.Git'; status = 'Skipped'; reason = 'already installed' }
                [pscustomobject]@{ id = 'Google.Chrome'; status = 'Failed'; reason = 'x' }
            )
        }
        $expectation = @(
            New-RealPcExpectation -Id '7zip.7zip' -Expected 'Installed'
            New-RealPcExpectation -Id 'Git.Git' -Expected 'Installed'
            New-RealPcExpectation -Id 'Google.Chrome' -Expected 'Installed'
        )
        $rows = Get-RealPcReRunResult -ExitCode 0 -Transcript (New-RealPcTestTranscript -AutoUpdates 'Already present.') -RunRecord $record -AppExpectation $expectation
        ($rows | Where-Object { $_.Check -eq 'Re-run installed or found: 7zip.7zip' }).Result | Should -Be 'PASS'
        ($rows | Where-Object { $_.Check -eq 'Re-run installed or found: Git.Git' }).Result | Should -Be 'PASS'
        ($rows | Where-Object { $_.Check -eq 'Re-run installed or found: Google.Chrome' }).Result | Should -Be 'FAIL'
    }

    It 'Never drops an app''s row: an expectation it has no check for fails' {
        $record = [pscustomobject]@{ apps = @([pscustomobject]@{ id = '7zip.7zip'; status = 'Installed'; reason = $null }) }
        $rows = Get-RealPcReRunResult -ExitCode 0 -Transcript (New-RealPcTestTranscript -AutoUpdates 'Already present.') -RunRecord $record -AppExpectation @(New-RealPcExpectation -Id '7zip.7zip' -Expected 'Something')
        $row = $rows | Where-Object { $_.Check -eq 'Re-run recorded: 7zip.7zip' }
        $row.Result | Should -Be 'FAIL'
        $row.Detail | Should -Match 'no check for the expectation ''Something'''
    }
}

Describe 'Invoke-RealPcReRunStage (wiring, after the owner''s failed first run)' {
    BeforeEach {
        $script:TightVncPassword = 'Tvnc2345'
        $script:StageTimeoutMinutes = 60
        $script:ReRunEvidence = Join-Path $TestDrive 'evidence-rerun'
        $null = New-Item -ItemType Directory -Path $script:ReRunEvidence -Force
        $script:FirstRunRecord = ConvertFrom-Json -InputObject ([string](Get-Content -Raw -LiteralPath (Join-Path $script:FixtureDirectory 'realpc-sourcedatamissing-last-run.json')))
        Mock Get-RealPcAppExpectation { return [pscustomobject]@{ Value = @([pscustomobject]@{ Id = '7zip.7zip'; Expected = 'AlreadyPresent'; Reason = $null; AlreadyPresentReasons = @('already installed'); MustInstall = $false }); Problem = $null } }
        Mock Invoke-RealPcInstaller { return [pscustomobject]@{ ExitCode = 0; Output = @() } }
        Mock Get-InstallPassTranscript { return (New-RealPcTestTranscript -AutoUpdates 'Already present (Winget-AutoUpdate v2.12.0).') }
        Mock Read-RealPcRunRecord { return [pscustomobject]@{ Record = [pscustomobject]@{ schemaVersion = 1; summaryReached = $true; exitCode = 0; apps = @([pscustomobject]@{ id = '7zip.7zip'; status = 'Installed'; reason = $null }) }; Problem = $null } }
    }

    It 'Accepts an install of an app the first run failed, and says why in a SKIP row' {
        $rows = @(Invoke-RealPcReRunStage -EvidenceFolder $script:ReRunEvidence)
        ($rows | Where-Object { $_.Check -eq 'Re-run installed or found: 7zip.7zip' }).Result | Should -Be 'PASS'
        @($rows | Where-Object { $_.Check -like 'Re-run skipped as present*' }) | Should -BeNullOrEmpty
        $gap = $rows | Where-Object { $_.Check -eq 'Apps the first run did not leave installed' }
        $gap.Result | Should -Be 'SKIP'
        $gap.Detail | Should -Match '^The re-run expects these installed or found, not already there: 7zip\.7zip \(Failed'
    }
}

Describe 'Apps & features snapshots and the winget logs kept (wgt-gq8.65 H5)' {
    It 'Writes the uninstall entries sorted by name, with version, install date, hive and key' {
        $entries = @(
            [pscustomobject]@{ DisplayName = 'TightVNC'; DisplayVersion = '2.8.81.0'; InstallDate = '20260901'; Key = '{0942F49D-681B-404B-9AA5-AAC9FAECEF44}'; Hive = 'HKLM64' }
            [pscustomobject]@{ DisplayName = '7-Zip 26.03 (x64)'; DisplayVersion = '26.03'; InstallDate = ''; Key = '7-Zip'; Hive = 'HKLM64' }
            [pscustomobject]@{ DisplayName = 'Google Chrome'; DisplayVersion = '154.0.8037.98'; InstallDate = '20260915'; Key = 'Google Chrome'; Hive = 'HKLM32' }
        )
        $lines = @((Format-RealPcArpSnapshot -Entry $entries -Title 'before stage 0 Preflight') -split '\r?\n' | Where-Object { $_ })
        $lines[0] | Should -Be 'Apps & features (uninstall entries) before stage 0 Preflight: 3 entries. Evidence only; no check reads it.'
        $lines[3] | Should -Be '7-Zip 26.03 (x64) | 26.03 |  | HKLM64\7-Zip'
        $lines[4] | Should -Be 'Google Chrome | 154.0.8037.98 | 20260915 | HKLM32\Google Chrome'
        $lines[5] | Should -Be 'TightVNC | 2.8.81.0 | 20260901 | HKLM64\{0942F49D-681B-404B-9AA5-AAC9FAECEF44}'
    }

    It 'Takes the snapshot before Preflight and after each stage that installs or uninstalls' {
        Get-RealPcArpSnapshotMoment -StageName 'Preflight' | Should -Be 'Before'
        foreach ($name in @('FirstRun', 'ReRun', 'System', 'WinGetClient', 'TimeBudget', 'Uninstaller')) {
            Get-RealPcArpSnapshotMoment -StageName $name | Should -Be 'After'
        }
        foreach ($name in @('LinkGuardSetup', 'Diagnostics', 'Report')) {
            Get-RealPcArpSnapshotMoment -StageName $name | Should -BeNullOrEmpty
        }
    }

    It 'Keeps the first 15 and the last 25 winget logs of a long stage, oldest first' {
        $start = [datetime]'2026-10-06T14:33:00'
        $logs = @(1..60 | ForEach-Object { [pscustomobject]@{ Name = ('WinGet-{0:D2}.log' -f $_); LastWriteTime = $start.AddSeconds($_) } })
        [array]::Reverse($logs)
        $pick = Select-RealPcWingetLog -Log $logs
        @($pick.Selected).Count | Should -Be 40
        $pick.Selected[0].Name | Should -Be 'WinGet-01.log'
        $pick.Selected[14].Name | Should -Be 'WinGet-15.log'
        $pick.Selected[15].Name | Should -Be 'WinGet-36.log'
        $pick.Selected[39].Name | Should -Be 'WinGet-60.log'
        $pick.Total | Should -Be 60
        $pick.Dropped | Should -Be 20
        (Select-RealPcWingetLog -Log @($logs | Select-Object -First 40)).Dropped | Should -Be 0
        (Select-RealPcWingetLog -Log @()).Total | Should -Be 0
    }

    It 'Copies a stage''s winget logs by that rule and gives the counts in winget-logs README.txt' {
        $since = (Get-Date).AddMinutes(-30)
        $diag = Join-Path $TestDrive 'DiagOutputDir'
        $null = New-Item -ItemType Directory -Path $diag -Force
        for ($index = 1; $index -le 45; $index++) {
            $path = Join-Path $diag ('WinGet-{0:D2}.log' -f $index)
            [System.IO.File]::WriteAllText($path, "log $index")
            [System.IO.File]::SetLastWriteTime($path, $since.AddSeconds($index))
        }
        $old = Join-Path $diag 'WinGet-old.log'
        [System.IO.File]::WriteAllText($old, 'before the stage')
        [System.IO.File]::SetLastWriteTime($old, $since.AddMinutes(-5))
        $installerLogs = Join-Path $TestDrive 'installer-logs'
        $null = New-Item -ItemType Directory -Path $installerLogs -Force
        $evidence = Join-Path $TestDrive 'evidence-logs'

        Save-RealPcStageEvidence -Folder $evidence -LogDirectory $installerLogs -Since $since -WingetLogSource ([ordered]@{ user = $diag; system = (Join-Path $TestDrive 'no-such-folder') })

        $copied = @(Get-ChildItem -LiteralPath (Join-Path $evidence 'winget-logs') -Filter '*.log' | ForEach-Object { $_.Name })
        $copied.Count | Should -Be 40
        $copied | Should -Contain 'user-WinGet-01.log'
        $copied | Should -Contain 'user-WinGet-15.log'
        $copied | Should -Contain 'user-WinGet-21.log'
        $copied | Should -Contain 'user-WinGet-45.log'
        $copied | Should -Not -Contain 'user-WinGet-16.log'
        $copied | Should -Not -Contain 'user-WinGet-old.log'
        $readme = [System.IO.File]::ReadAllText((Join-Path (Join-Path $evidence 'winget-logs') 'README.txt'))
        $readme | Should -Match 'user: 45 written during the stage, 40 copied, 5 left out'
        $readme | Should -Match 'system: 0 written during the stage, 0 copied, 0 left out'
    }
}

Describe 'The finish lines and the folder never to send (wgt-gq8.65 H6)' {
    It 'Names the local folder so a wildcard on the report folder''s name cannot match it' {
        Get-RealPcLocalFolderPath -ReportPath 'C:\Users\Public\winget-app-setup-testplan-20261006-143344' | Should -Be 'C:\Users\Public\winget-app-setup-localsecrets-20261006-143344'
        Get-RealPcLocalFolderPath -ReportPath 'D:\reports\run1\' | Should -Be 'D:\reports\winget-app-setup-localsecrets-run1'
        Get-RealPcLocalFolderPath -ReportPath '/tmp/r' | Should -Be '/tmp/winget-app-setup-localsecrets-r'
        Get-RealPcLocalFolderPath -ReportPath 'C:\winget-app' | Should -Be 'C:\localsecrets-winget-app'
        foreach ($leaf in @('winget-app-setup-testplan-20261006-143344', 'r', 'winget', 'w', 'winget-app-setup-localsecrets-x', 'localsecrets')) {
            $name = (Get-RealPcLocalFolderPath -ReportPath ('C:\x\' + $leaf)) -replace '^.*\\', ''
            ($name -like ($leaf + '*')) | Should -BeFalse -Because "a '$leaf*' wildcard must not match '$name'"
            ($name -like 'winget-app-setup-testplan-*') | Should -BeFalse
        }
    }

    It 'Ends with report.txt''s exact path, a ready-to-paste copy command, the zip and the folder not to send' {
        $lines = @(Get-RealPcFinishLine -ReportTextPath 'C:\Users\Public\winget-app-setup-testplan-20261006-143344\report.txt' -ZipPath 'C:\Users\Public\winget-app-setup-testplan-20261006-143344.zip' -ManualStepsPath 'C:\Users\Public\winget-app-setup-localsecrets-20261006-143344\manual-steps.txt' -LocalFolder 'C:\Users\Public\winget-app-setup-localsecrets-20261006-143344')
        $lines | Should -Contain 'Report: C:\Users\Public\winget-app-setup-testplan-20261006-143344\report.txt'
        $lines | Should -Contain "  Get-Content -LiteralPath 'C:\Users\Public\winget-app-setup-testplan-20261006-143344\report.txt' -Raw -Encoding UTF8 | Set-Clipboard"
        $lines | Should -Contain 'Send this zip back: C:\Users\Public\winget-app-setup-testplan-20261006-143344.zip'
        $lines | Should -Contain 'Do not send C:\Users\Public\winget-app-setup-localsecrets-20261006-143344: it holds the TightVNC test password.'
        $lines | Should -Contain 'The report and the zip name this PC''s accounts and their SIDs: send them privately, or replace the names before you post them on a public issue or pull request.'
        ($lines -join "`n") | Should -Not -Match '\*'
    }

    It 'Doubles a single quote in the path, typographic ones too, so the pasted line still parses and names the path' {
        $lines = @(Get-RealPcFinishLine -ReportTextPath "C:\Users\O'Brien\r\report.txt")
        $lines[2] | Should -Be "  Get-Content -LiteralPath 'C:\Users\O''Brien\r\report.txt' -Raw -Encoding UTF8 | Set-Clipboard"
        $lines | Should -Contain 'There is no zip to send (see the lines above).'
        # A profile named with U+2019, which PowerShell's tokenizer also reads as a single quote.
        $typographic = 'C:\Users\O' + [char]0x2019 + 'Brien\r\report.txt'
        foreach ($path in @("C:\Users\O'Brien\r\report.txt", $typographic)) {
            $line = @(Get-RealPcFinishLine -ReportTextPath $path)[2].Trim()
            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseInput($line, [ref]$null, [ref]$parseErrors)
            $parseErrors | Should -BeNullOrEmpty
            $argument = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $node.StringConstantType -eq 'SingleQuoted' }, $true)
            $argument.Value | Should -Be $path
        }
    }

    It 'Offers nothing to paste or send when the report or the zip held the test password' {
        $lines = @(Get-RealPcFinishLine -ReportTextPath 'C:\r\report.txt' -ZipPath 'C:\r.zip' -LocalFolder 'C:\winget-app-setup-localsecrets-r' -HoldsSecret)
        ($lines -join "`n") | Should -Not -Match 'Set-Clipboard'
        ($lines -join "`n") | Should -Not -Match 'Send this zip back'
        $lines | Should -Contain 'Do not paste or send this report, the report folder or a zip of it: the TightVNC test password was found in the report or the zip (see the lines above).'
        $lines | Should -Contain 'Do not send C:\winget-app-setup-localsecrets-r: it holds the TightVNC test password.'
    }
}

Describe 'Invoke-RealPcTestPlanMain (the report and its finish lines, every stage mocked)' {
    BeforeEach {
        $script:Printed = @()
        $script:MainRun = Join-Path $TestDrive ('main-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:MainRun -Force
        $script:MainReportPath = Join-Path $script:MainRun 'report'
        Mock Write-RealPcLine { $script:Printed += $Message }
        Mock Test-RealPcElevated { $true }
        Mock Test-RealPcWindowsSandbox { $false }
        Mock New-RealPcRandomSecret { 'Tvnc2345' }
        Mock Start-Transcript { }
        Mock Stop-Transcript { }
        Mock Get-RealPcArpSnapshotMoment { $null }
        Mock Save-RealPcArpSnapshot { }
        Mock Save-RealPcStageEvidence { }
        Mock Remove-RealPcHarnessLeftover { @() }
        # Preflight could not open the source; the check after the first run did.
        Mock Invoke-RealPcPreflightStage { @(Add-RealPcWingetSourceCheck -ExitCode -1978335217 -SourcePackage 'not registered') }
        Mock Invoke-RealPcLinkGuardSetupStage { @() }
        Mock Invoke-RealPcFirstRunStage { @(Add-RealPcWingetSourceCheck -ExitCode 0 -When 'after the first run' -SourcePackage '2026.1006.2038.44') }
    }

    It 'Reports Preflight''s source check as SKIP once the source opened, and ends with the copy line' {
        $exitCode = @(Invoke-RealPcTestPlanMain -Stage 'FirstRun' -ConfirmDisposableMachine -ReportPath $script:MainReportPath)[-1]
        $exitCode | Should -Be 0
        $report = [System.IO.File]::ReadAllText((Join-Path $script:MainReportPath 'report.txt'))
        $report | Should -Match '\[SKIP\] winget can open its source in this account: .*It opened after the first run;'
        $report | Should -Match '!! Until it opened, winget read every installed app as not installed there'
        $report | Should -Not -Match 'blind winget'
        $report | Should -Match ([regex]::Escape('manual-steps.txt (in ' + (Join-Path $script:MainRun 'winget-app-setup-localsecrets-report') + '; it is not in the zip)'))
        $script:Printed | Should -Contain ("  Get-Content -LiteralPath '{0}' -Raw -Encoding UTF8 | Set-Clipboard" -f (Join-Path $script:MainReportPath 'report.txt'))
        $script:Printed | Should -Contain ('Send this zip back: {0}.zip' -f $script:MainReportPath)
    }

    It 'Offers no copy line, and fails the run, when the report itself holds the test password' {
        Mock Invoke-RealPcFirstRunStage { @(New-TestPlanRow -Check 'Leaky check' -Result 'PASS' -Detail 'printed Tvnc2345 by mistake') }
        $exitCode = @(Invoke-RealPcTestPlanMain -Stage 'FirstRun' -ConfirmDisposableMachine -ReportPath $script:MainReportPath)[-1]
        $exitCode | Should -Be 1
        ($script:Printed -join "`n") | Should -Not -Match 'Set-Clipboard'
        ($script:Printed -join "`n") | Should -Match 'The report held the TightVNC test password \(report\.txt \(the TightVNC test password\); report\.md'
        $script:Printed | Should -Contain 'Do not paste or send this report, the report folder or a zip of it: the TightVNC test password was found in the report or the zip (see the lines above).'
        # The zip holds report.txt, so its own scan deletes it too.
        Test-Path -LiteralPath ($script:MainReportPath + '.zip') | Should -BeFalse
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
