# E2ERealPcTestPlan.Tests.ps1
# Tests for e2e/Invoke-RealPcTestPlan.ps1, the real-PC owner-test-plan harness (bead wgt-gq8.60).
# The install, scheduled-task and ACL-reading work needs Windows; the pure parts tested here read
# only what they are given: stage ordering and dependency logic (-Stage / -SkipStage), the change
# plan, the gate decision (the refusal paths), the evaluation of each stage's checks from fixture
# last-run.json files and constructed transcripts, the ACL/SDDL comparison, the secret-redaction
# check, and the report and exit-code logic. Dot-sourcing the harness defines its functions and runs
# nothing (its main block is guarded), as the other e2e scripts are loaded by their tests.

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
            [switch]$LinkRemoved,
            [string]$AutoUpdates = 'Configured (Winget-AutoUpdate v2.12.0).',
            [switch]$RuntimeInstalled,
            [switch]$NoRuntimeLine
        )
        $lines = @('Installer build: 1.0.0+5ea1f00d')
        if ($LinkRemoved) {
            $lines += "'C:\ProgramData\winget-app-setup' was a link (a junction or symbolic link), not a folder. The link was removed without changing what it pointed to, and a folder is created in its place."
        }
        if ($RuntimeInstalled) {
            $lines += 'Windows App Runtime: installed Microsoft.WindowsAppRuntime.1.8 8000.994.2142.0 (X64) for all users.'
        }
        elseif (-not $NoRuntimeLine) {
            # No 'Windows App Runtime:' line at all (the run found it already there).
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
        ($plan -join "`n") | Should -Not -Match 'the uninstaller stage'
    }

    It 'Always says where the report goes' {
        $plan = Get-RealPcChangePlan -Stages @() -ReportFolder 'C:\report-xyz'
        ($plan -join "`n") | Should -Match 'C:\\report-xyz'
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

    It 'Accepts exit 8 only with the framework-missing reason in the transcript' {
        $good = New-RealPcTestTranscript -AutoUpdates 'NOT CONFIGURED - Microsoft.WindowsAppRuntime.1.8 is missing, and Winget-AutoUpdate would leave winget unusable without it.'
        (Get-RealPcInstallExitVerdict -ExitCode 8 -Transcript $good).Passed | Should -BeTrue
        $bad = New-RealPcTestTranscript -AutoUpdates 'FAILED - something else'
        (Get-RealPcInstallExitVerdict -ExitCode 8 -Transcript $bad).Passed | Should -BeFalse
    }
}

Describe 'Get-RealPcRunRecordResult' {
    It 'Passes a schema-1 record that reached its summary with the matching exit code and no failure' {
        $record = Get-FirstRunRecord
        $rows = Get-RealPcRunRecordResult -RunRecord $record -ExpectedExitCode 0
        @($rows | Where-Object { $_.Result -eq 'FAIL' }) | Should -BeNullOrEmpty
    }

    It 'Fails when no record was written' {
        $rows = Get-RealPcRunRecordResult -RunRecord $null -ExpectedExitCode 0
        @($rows | Where-Object { $_.Result -eq 'FAIL' }).Count | Should -BeGreaterThan 0
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
        $rows = Get-RealPcAutoUpdateResult -Transcript $transcript -WauTaskHealth $wau
        (($rows | Where-Object { $_.Check -match 'no at-logon trigger' }).Result) | Should -Be 'FAIL'
    }

    It 'Fails when TightVNC is not Configured but a password was supplied' {
        $record = Get-FirstRunRecord
        ($record.apps | Where-Object { $_.id -eq 'GlavSoft.TightVNC' }).postInstall = 'NotConfigured'
        $transcript = New-RealPcTestTranscript
        $rows = Get-RealPcAutoUpdateResult -Transcript $transcript -RunRecord $record -ExpectTightVncConfigured
        (($rows | Where-Object { $_.Check -match 'TightVNC' }).Result) | Should -Be 'FAIL'
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
}

Describe 'Get-RealPcTimeBudget* (item 8)' {
    It 'Passes the spent-budget run: exit 9, app NotAttempted, notattempted >= 1' {
        $record = [pscustomobject]@{ apps = @([pscustomobject]@{ id = '7zip.7zip'; status = 'NotAttempted' }) }
        $rows = Get-RealPcTimeBudgetSpentResult -ExitCode 9 -RunRecord $record -ResultLine 'RESULT: exit=9 installed=0 skipped=0 deferred=0 failed=0 notattempted=1 autoupdates=NotAttempted restart=no build=x log=y'
        @($rows | Where-Object { $_.Result -eq 'FAIL' }) | Should -BeNullOrEmpty
    }

    It 'Fails the spent-budget run when the exit code is not 9' {
        $record = [pscustomobject]@{ apps = @([pscustomobject]@{ id = '7zip.7zip'; status = 'NotAttempted' }) }
        $rows = Get-RealPcTimeBudgetSpentResult -ExitCode 0 -RunRecord $record -ResultLine 'RESULT: notattempted=1'
        (($rows | Where-Object { $_.Check -match 'exits 9' }).Result) | Should -Be 'FAIL'
    }

    It 'Passes the finish run: exit 0 and the app Installed' {
        $record = [pscustomobject]@{ apps = @([pscustomobject]@{ id = '7zip.7zip'; status = 'Installed' }) }
        $rows = Get-RealPcTimeBudgetFinishResult -ExitCode 0 -RunRecord $record
        @($rows | Where-Object { $_.Result -eq 'FAIL' }) | Should -BeNullOrEmpty
    }
}

Describe 'Get-RealPcSecretLeak and Get-RealPcDiagnosticsResult (item 6)' {
    It 'Finds a secret in a bundle file, case-insensitively' {
        $leak = Get-RealPcSecretLeak -Entry @{ 'system.txt' = 'user=wgtsetup123456 and more' } -Secret @('WGTSETUP123456')
        $leak.Count | Should -Be 1
    }

    It 'Finds no leak when the secret is absent' {
        (Get-RealPcSecretLeak -Entry @{ 'system.txt' = 'nothing here' } -Secret @('topsecret')).Count | Should -Be 0
    }

    It 'Ignores an empty secret' {
        (Get-RealPcSecretLeak -Entry @{ 'a' = 'x' } -Secret @('', '   ')).Count | Should -Be 0
    }

    It 'Passes a bundle with every expected entry and no secret' {
        $names = @('README.txt', 'system.txt', 'winget.txt', 'appx.txt', 'wau-updates-log-tail.txt', 'logs/install-20261006.log')
        $text = @{ 'README.txt' = 'clean'; 'system.txt' = 'clean' }
        $rows = Get-RealPcDiagnosticsResult -EntryName $names -EntryText $text -Secret @('throwawaypw', 'wgtsetup1')
        @($rows | Where-Object { $_.Result -eq 'FAIL' }) | Should -BeNullOrEmpty
    }

    It 'Fails a bundle that leaks the test password' {
        $names = @('README.txt', 'system.txt', 'winget.txt', 'appx.txt', 'wau-updates-log-tail.txt', 'logs/x.log')
        $text = @{ 'system.txt' = 'TightVNC password throwawaypw was set' }
        $rows = Get-RealPcDiagnosticsResult -EntryName $names -EntryText $text -Secret @('throwawaypw')
        (($rows | Where-Object { $_.Check -match 'no secret' }).Result) | Should -Be 'FAIL'
    }

    It 'Fails a bundle missing an expected entry' {
        $names = @('README.txt')
        $rows = Get-RealPcDiagnosticsResult -EntryName $names -EntryText @{} -Secret @()
        (($rows | Where-Object { $_.Check -match 'winget.txt' }).Result) | Should -Be 'FAIL'
    }
}

Describe 'Get-RealPcUninstallerResult (item 9)' {
    It 'Passes a clean uninstall: WhatIf unchanged, exit 0, kept apps left, WAU gone' {
        $rows = Get-RealPcUninstallerResult `
            -WhatIfInstalledBefore @('7zip.7zip', 'Microsoft.PowerShell') -WhatIfInstalledAfter @('Microsoft.PowerShell', '7zip.7zip') `
            -WhatIfWauBefore $true -WhatIfWauAfter $true `
            -ExitCode 0 -InstalledAfter @('Microsoft.PowerShell', 'Microsoft.WindowsTerminal') -WauPresentAfter $false
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

Describe 'Get-RealPcLinkGuardResult (item 11)' {
    It 'Passes a correct link-guard outcome' {
        $base = New-RealPcAclSummary
        $logs = New-RealPcAclSummary -Rules @(
            @{ Sid = 'S-1-5-18'; Rights = 2032127 },
            @{ Sid = 'S-1-5-32-544'; Rights = 2032127 },
            @{ Sid = 'S-1-5-32-545'; Rights = 1179817 }
        )
        $victim = @([pscustomobject]@{ Path = 'C:\Users\Public\victim'; Owner = 'S-1-5-32-544'; Sddl = 'D:X' })
        $transcript = "'C:\ProgramData\winget-app-setup' was a link (a junction or symbolic link), not a folder. The link was removed without changing what it pointed to."
        $rows = Get-RealPcLinkGuardResult -BaseIsReparsePoint $false -BaseAcl $base -LogsAcl $logs -TranscriptText $transcript -VictimBefore $victim -VictimAfter $victim
        @($rows | Where-Object { $_.Result -eq 'FAIL' }) | Should -BeNullOrEmpty
    }

    It 'Fails when the base folder is still a reparse point' {
        $rows = Get-RealPcLinkGuardResult -BaseIsReparsePoint $true -TranscriptText ''
        (($rows | Where-Object { $_.Check -match 'real directory' }).Result) | Should -Be 'FAIL'
    }

    It 'Fails when the removed-link warning is missing' {
        $rows = Get-RealPcLinkGuardResult -BaseIsReparsePoint $false -TranscriptText 'no warning here'
        (($rows | Where-Object { $_.Check -match 'link was removed' }).Result) | Should -Be 'FAIL'
    }

    It 'Fails when the victim folder changed, and notes planting as admin' {
        $before = @([pscustomobject]@{ Path = 'C:\v'; Owner = 'S-1'; Sddl = 'D:X' })
        $after = @([pscustomobject]@{ Path = 'C:\v'; Owner = 'S-2'; Sddl = 'D:X' })
        $rows = Get-RealPcLinkGuardResult -BaseIsReparsePoint $false -TranscriptText 'was a link ... removed' -VictimBefore $before -VictimAfter $after -PlantedAsAdmin
        (($rows | Where-Object { $_.Check -match 'kept their owner and SDDL' }).Result) | Should -Be 'FAIL'
        (($rows | Where-Object { $_.Check -match 'standard user' }).Result) | Should -Be 'SKIP'
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

Describe 'Format-RealPcReport' {
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
}

Describe 'Harness stays runnable by Windows PowerShell 5.1' {
    It 'Is ASCII only, parses cleanly, and uses no PowerShell 7-only syntax' {
        $bytes = [System.IO.File]::ReadAllBytes($script:HarnessPath)
        @($bytes | Where-Object { $_ -gt 0x7F }).Count | Should -Be 0
        $tokens = $null
        $parseErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($script:HarnessPath, [ref]$tokens, [ref]$parseErrors)
        $parseErrors | Should -BeNullOrEmpty
        $ps7OnlyKinds = @('QuestionQuestion', 'QuestionQuestionEquals', 'QuestionDot', 'QuestionLBracket', 'AndAnd', 'OrOr', 'QuestionMark')
        @($tokens | Where-Object { $ps7OnlyKinds -contains $_.Kind.ToString() } | ForEach-Object { "$($_.Kind) at line $($_.Extent.StartLineNumber)" }) | Should -BeNullOrEmpty
    }

    It 'Defines its functions when dot-sourced and runs nothing (the main block is guarded)' {
        Get-Command -Name 'Resolve-RealPcTestPlanStage' -CommandType Function -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Get-Command -Name 'Get-RealPcGateDecision' -CommandType Function -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}
