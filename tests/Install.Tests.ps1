# Install.Tests.ps1
# Tests for WingetAppSetup/Public/Install.ps1 plus its private collaborators
# (Private/InstallVerification.ps1, Private/FailureReporting.ps1): the Invoke-WingetInstall
# orchestrator wiring, the shared install-and-verify pipeline, and failure reporting.
# Split from the old single-file suite Test-WingetAppInstall.Tests.ps1 (issue #192).

# Load the module's functions once for this file. TestHelpers.ps1 resolves the repo paths
# and dot-sources WingetAppSetup/Private + Public (the single source of truth; the
# distributable winget-app-install.ps1 is generated from it by build/Build-WingetInstallScript.ps1).
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'Main Script Logic' {
    BeforeAll {
        # Dot-source the script under test so these tests exercise the real implementation (#135).
        . $script:InstallerScriptPath

        # Capture Invoke-WingetInstall's source now, BEFORE Get-Command is mocked below. The
        # structural tests inspect this definition; routing their `Get-Command Invoke-WingetInstall`
        # through the filtered mock throws under Pester 6, which (unlike Pester 5) no longer falls
        # back to the real command when no -ParameterFilter matches and there is no default mock.
        $script:InvokeWingetInstallDef = (Get-Command Invoke-WingetInstall).Definition

        Mock Write-Host { }
        Mock Start-Process { }

        # Mock the functions that are called

        # Mock external commands
        Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'pwsh' }
        Mock winget { 'App1' } -ParameterFilter { $args -contains 'list' }
        Mock Start-Process { }
    }

    # The old 'Administrator check' context asserted `Should -BeOfType` on framework constants
    # ([bool], the WindowsBuiltInRole enum) — tautologies that could never fail (issue #192).
    # The replacement below pins the real gate structurally; the non-admin behavior itself is
    # exercised end-to-end by 'IEX non-admin execution behavior' in tests/EntryPoint.Tests.ps1.
    Context 'Administrator gate' {
        It 'Performs a real WindowsPrincipal role check and refuses to install without elevation' {
            $installBody = $script:InvokeWingetInstallDef
            $installBody | Should -Match '\[Security\.Principal\.WindowsPrincipal\]'
            $installBody | Should -Match 'IsInRole\(\[Security\.Principal\.WindowsBuiltInRole\]'
            $installBody | Should -Match 'This script requires administrator privileges'
        }
    }

    # The old 'Winget check' context mocked Test-AndInstallWinget and then asserted the mock's
    # own return value — a tautology that tested nothing (issue #192). The behavior it pretended
    # to guard is the orchestrator's hard stop when winget cannot be installed; that gate is
    # pinned structurally below because driving it for real would `Exit 2` the test process.
    Context 'Winget availability gate' {
        It 'Exits with code 2 when winget cannot be installed (dependency-failure exit code)' {
            $installBody = $script:InvokeWingetInstallDef
            $installBody | Should -Match 'if \(-not \(Test-AndInstallWinget\)\)'
            $installBody | Should -Match "(?s)Winget is required for this script\. Exiting\.'\s*Exit 2"
        }
    }

    Context 'PATH setup' {
        It 'Should not add the script directory to the persistent PATH (issue #179)' {
            # The installer must never put its own (user-writable) directory on the PATH —
            # that was a hijack surface and nothing needs it since the updater removal (#168).
            $installBody = $script:InvokeWingetInstallDef
            $installBody | Should -Not -Match 'Add-ToEnvironmentPath'
        }
    }

    # The msstore-era 'Source verification' loop (Test-WingetSourceTrusted/Set-Sources) was removed
    # in issue #177: source health is verified and repaired by Test-WingetSources before this point.

    # The 'App installation loop' context was removed in issue #188: it re-inlined an obsolete
    # copy of the install loop (single-string ArgumentList, no --scope machine) instead of
    # exercising the real code. The behavior it guarded is now covered for real by the
    # 'Install-AppWithVerification' and 'Invoke-WingetInstall wiring' Describes below, and the
    # --source winget flag assertion lives in the 'Install-WingetPackage' Describe
    # (tests/WingetCore.Tests.ps1).

    Context 'Summary table generation' {
        It 'Should format summary table with install, skip, and fail results' {
            $installedApps = @('App1', 'App2')
            $skippedApps = @('App3')
            $failedApps = @('App4')

            Mock Format-AppList { param($AppArray) if ($AppArray) { return $AppArray -join ', ' } return $null }
            Mock Write-Table { }

            $headers = @('Status', 'Apps')
            $rows = @()

            $appList = Format-AppList -AppArray $installedApps
            if ($appList) { $rows += , @('Installed', $appList) }

            $appList = Format-AppList -AppArray $skippedApps
            if ($appList) { $rows += , @('Skipped', $appList) }

            $appList = Format-AppList -AppArray $failedApps
            if ($appList) { $rows += , @('Failed', $appList) }

            Write-Table -Headers $headers -Rows $rows

            $rows.Count | Should -Be 3
            Should -Invoke Write-Table -Times 1
        }

        It 'Should handle empty result arrays' {
            $installedApps = @()

            Mock Format-AppList { param($AppArray) if ($AppArray -and $AppArray.Count -gt 0) { return $AppArray -join ', ' } return $null }
            Mock Write-Table { }

            $headers = @('Status', 'Apps')
            $rows = @()

            $appList = Format-AppList -AppArray $installedApps
            if ($appList) { $rows += , @('Installed', $appList) }

            Write-Table -Headers $headers -Rows $rows

            $rows.Count | Should -Be 0
        }
    }
}

# The 'Retry Failed Installations' Describe was removed in issue #188: it simulated the retry
# loop with an obsolete re-inlined copy (single-string ArgumentList, no --scope machine) instead
# of exercising the real code. The retry semantics it guarded (success moves to installed,
# failure stays failed, mixed results, no-op when nothing failed, non-zero exit signalling) are
# now covered by the 'Install-AppWithVerification' Describe (per-app success/failure states) and
# the 'Invoke-WingetInstall wiring (issue #188)' Describe below.
Describe 'Invoke-WingetInstall wiring (issue #188)' {
    BeforeDiscovery {
        # Elevation state must be known at discovery time for -Skip to work: values assigned in
        # run-phase BeforeAll blocks are not visible to -Skip expressions.
        $script:wiringIsElevated = $false
        if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
            $script:wiringIsElevated = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
                [Security.Principal.WindowsBuiltInRole]::Administrator
            )
        }
    }

    BeforeEach {
        Mock Write-Host { }
        Mock Start-Process { }
        Mock Restart-WithElevation { 'PowerShell' }
        Mock Test-IsRunningLocally { $true }
        Mock Test-AndInstallWingetModule { $true }
        Mock Import-Module { }
        Mock Test-AndInstallWinget { $true }
        Mock Initialize-WingetSourcesForUser { $true }
        Mock Test-AndInstallGraphicalTools { $true }
        Mock Test-WingetSources { $true }
        Mock Remove-LegacyScheduledUpdates { $true }
        Mock Set-WindowsTerminalDefaults { }
        Mock Install-WingetAutoUpdate { @{ Status = 'DryRun'; Version = '2.12.0' } }
        Mock Install-AppWithVerification { @{ Status = 'Installed'; InstallResult = $null; FailureReason = $null } }

        $script:capturedRows = $null
        Mock Write-Table { $script:capturedRows = $Rows }
    }

    Context 'Structure: the shared helper replaced the inline verify blocks' {
        It 'Routes both the first pass and the retry pass through Install-AppWithVerification' {
            $installBody = $script:InvokeWingetInstallDef
            ([regex]::Matches($installBody, 'Install-AppWithVerification')).Count | Should -Be 2
        }

        It 'No longer inlines Start-Process winget list verification blocks' {
            $installBody = $script:InvokeWingetInstallDef
            $installBody | Should -Not -Match 'RedirectStandardOutput'
            $installBody | Should -Not -Match 'WaitForExit'
            $installBody | Should -Not -Match 'winget_(list|verify|retry_verify)_'
        }

        It 'Still exits 1 when apps remain failed after the retry pass (issue #176)' {
            $installBody = $script:InvokeWingetInstallDef
            $installBody | Should -Match 'if \(\$failedApps\.Count -gt 0\) \{\s*Exit 1\s*\}'
        }

        It 'Tracks failures as objects with reasons and renders the failed-apps summary (issue #189)' {
            $installBody = $script:InvokeWingetInstallDef
            $installBody | Should -Match 'Format-InstallFailureReason'
            $installBody | Should -Match 'Write-FailedAppsSummary'
            $installBody | Should -Match '\$failedApps \+= @\{ Name ='
            # The generic message the diagnostic detail replaces (issue #189).
            $installBody | Should -Not -Match 'No package found matching input criteria'
        }
    }

    Context 'Dry run (executes the real orchestrator end-to-end without system changes)' {
        It 'Drives every curated app through the helper with -WhatIf and buckets the results' {
            $script:verifiedApps = @()
            Mock Install-AppWithVerification {
                $script:verifiedApps += $App.name
                if ($App.name -eq 'Google.Chrome') {
                    return @{ Status = 'Skipped'; InstallResult = $null; FailureReason = $null }
                }
                @{ Status = 'Installed'; InstallResult = $null; FailureReason = $null }
            }

            Invoke-WingetInstall -WhatIf -NonInteractive

            # One helper call per app in the curated catalog (the -Apps default; issue #190),
            # every one of them in dry-run mode, and no second (retry) round.
            $expectedCount = @(Get-DefaultAppCatalog).Count
            $script:verifiedApps.Count | Should -Be $expectedCount
            $script:verifiedApps | Should -Contain '7zip.7zip'
            $script:verifiedApps | Should -Contain 'Microsoft.WindowsTerminal'
            Should -Invoke Install-AppWithVerification -Times $expectedCount -Exactly -ParameterFilter { [bool]$WhatIf }

            # Bucket routing: Skipped and Installed land in their own summary rows, nothing Failed.
            $installedRow = @($script:capturedRows | Where-Object { $_[0] -eq 'Installed' })[0]
            $skippedRow = @($script:capturedRows | Where-Object { $_[0] -eq 'Skipped' })[0]
            $installedRow[1] | Should -Match '7zip\.7zip'
            $installedRow[1] | Should -Not -Match 'Google\.Chrome'
            $skippedRow[1] | Should -Match 'Google\.Chrome'
            @($script:capturedRows | Where-Object { $_[0] -eq 'Failed' }).Count | Should -Be 0
        }
    }

    Context 'Catalog injection (issue #190)' {
        It 'Accepts an -Apps parameter defaulting to Get-DefaultAppCatalog' {
            $command = Get-Command Invoke-WingetInstall
            $command.Parameters.ContainsKey('Apps') | Should -Be $true
            $command.Parameters['Apps'].ParameterType.Name | Should -Be 'Array'
            # Structural pin on the default: the curated catalog function, not an inline list.
            $command.Definition | Should -Match '\[array\]\$Apps = \(Get-DefaultAppCatalog\)'
        }

        It 'Drives an injected one-app catalog through the helper instead of the curated list' {
            $script:verifiedApps = @()
            Mock Install-AppWithVerification {
                $script:verifiedApps += $App.name
                @{ Status = 'Installed'; InstallResult = $null; FailureReason = $null }
            }

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.OnlyApp' }) -WhatIf -NonInteractive

            $script:verifiedApps | Should -Be @('Contoso.OnlyApp')
            Should -Invoke Install-AppWithVerification -Times 1 -Exactly
        }
    }

    Context 'Not-applicable skip wiring (issue #217)' {
        BeforeEach {
            $script:skipWarnings = @()
            Mock Write-WarningMessage { $script:skipWarnings += $Message }
        }

        It 'Logs the not-applicable skip line with the condition description and buckets the app as Skipped' {
            Mock Install-AppWithVerification { @{ Status = 'Skipped'; InstallResult = $null; FailureReason = $null; SkipReason = 'NotApplicable' } }

            Invoke-WingetInstall -Apps @(@{ name = 'Dell.CommandUpdate.Universal'; condition = { $false }; conditionDescription = 'Dell hardware only' }) -WhatIf -NonInteractive

            # Exactly the message shape of the already-installed skip, with the gated reason.
            $script:skipWarnings | Should -Contain 'Skipping: Dell.CommandUpdate.Universal (not applicable: Dell hardware only)'
            $skippedRow = @($script:capturedRows | Where-Object { $_[0] -eq 'Skipped' })[0]
            $skippedRow[1] | Should -Match 'Dell\.CommandUpdate\.Universal'
            @($script:capturedRows | Where-Object { $_[0] -eq 'Failed' }).Count | Should -Be 0
        }

        It 'Falls back to a generic reason when the entry has no conditionDescription' {
            Mock Install-AppWithVerification { @{ Status = 'Skipped'; InstallResult = $null; FailureReason = $null; SkipReason = 'NotApplicable' } }

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.GatedApp'; condition = { $false } }) -WhatIf -NonInteractive

            $script:skipWarnings | Should -Contain 'Skipping: Contoso.GatedApp (not applicable: condition not met)'
        }

        It 'Keeps the already-installed skip message for skips without a SkipReason' {
            Mock Install-AppWithVerification { @{ Status = 'Skipped'; InstallResult = $null; FailureReason = $null } }

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.PresentApp' }) -WhatIf -NonInteractive

            $script:skipWarnings | Should -Contain 'Skipping: Contoso.PresentApp (already installed)'
        }
    }

    Context 'Retry pass (needs elevation: the non-dry-run path performs the real admin gate)' {
        It 'Sends a first-pass failure back through the helper and buckets a recovered app as installed' -Skip:(-not $script:wiringIsElevated) {
            $script:sevenZipCalls = 0
            Mock Install-AppWithVerification {
                if ($App.name -eq '7zip.7zip') {
                    $script:sevenZipCalls++
                    if ($script:sevenZipCalls -eq 1) {
                        return @{ Status = 'Failed'; InstallResult = @{ ExitCode = 1 }; FailureReason = 'VerifyNotFound' }
                    }
                    return @{ Status = 'Installed'; InstallResult = @{ ExitCode = 0 }; FailureReason = $null }
                }
                @{ Status = 'Skipped'; InstallResult = $null; FailureReason = $null }
            }

            Invoke-WingetInstall -NonInteractive

            # First pass failed 7zip, the retry pass re-drove it through the helper and recovered.
            $script:sevenZipCalls | Should -Be 2
            $installedRow = @($script:capturedRows | Where-Object { $_[0] -eq 'Installed' })[0]
            $installedRow[1] | Should -Match '7zip\.7zip'
            @($script:capturedRows | Where-Object { $_[0] -eq 'Failed' }).Count | Should -Be 0
        }

        It 'Surfaces the winget exit code, attempts, and scope fallback in the failure message (issue #189)' -Skip:(-not $script:wiringIsElevated) {
            $script:sevenZipAttempts = 0
            Mock Install-AppWithVerification {
                if ($App.name -eq '7zip.7zip') {
                    $script:sevenZipAttempts++
                    if ($script:sevenZipAttempts -eq 1) {
                        return @{
                            Status        = 'Failed'
                            InstallResult = @{ ExitCode = -2147009255; Attempts = 3; SessionErrorExhausted = $false; MachineScopeFellBack = $true }
                            FailureReason = 'VerifyNotFound'
                        }
                    }
                    return @{ Status = 'Installed'; InstallResult = @{ ExitCode = 0 }; FailureReason = $null }
                }
                @{ Status = 'Skipped'; InstallResult = $null; FailureReason = $null }
            }
            $script:errorMessages = @()
            Mock Write-ErrorMessage { $script:errorMessages += $Message }

            Invoke-WingetInstall -NonInteractive

            $failureMessage = @($script:errorMessages | Where-Object { $_ -match 'Failed to install' })[0]
            $failureMessage | Should -Match '7zip\.7zip'
            $failureMessage | Should -Match 'winget exit 0x80073D19'
            $failureMessage | Should -Match '3 attempts'
            $failureMessage | Should -Match 'machine-scope fallback: yes'
        }

        It 'Names the pre-check phase (not verification) when a retry fails with PreCheckTimeout' -Skip:(-not $script:wiringIsElevated) {
            Mock Install-AppWithVerification {
                if ($App.name -eq '7zip.7zip') {
                    return @{ Status = 'Failed'; InstallResult = $null; FailureReason = 'PreCheckTimeout' }
                }
                @{ Status = 'Skipped'; InstallResult = $null; FailureReason = $null }
            }
            $script:warningMessages = @()
            Mock Write-WarningMessage { $script:warningMessages += $Message }

            Invoke-WingetInstall -NonInteractive

            $retryMessage = @($script:warningMessages | Where-Object { $_ -match '7zip\.7zip' -and $_ -match 'retry' })[0]
            $retryMessage | Should -Not -BeNullOrEmpty
            $retryMessage | Should -Not -Match 'Verification timed out'
            $retryMessage | Should -Match 'Winget list timed out|pre-check|pre-install check'
        }

        It 'Keeps the verification-timeout wording when a retry fails with VerifyTimeout' -Skip:(-not $script:wiringIsElevated) {
            Mock Install-AppWithVerification {
                if ($App.name -eq '7zip.7zip') {
                    return @{ Status = 'Failed'; InstallResult = @{ ExitCode = 0 }; FailureReason = 'VerifyTimeout' }
                }
                @{ Status = 'Skipped'; InstallResult = $null; FailureReason = $null }
            }
            $script:warningMessages = @()
            Mock Write-WarningMessage { $script:warningMessages += $Message }

            Invoke-WingetInstall -NonInteractive

            $retryMessage = @($script:warningMessages | Where-Object { $_ -match '7zip\.7zip' -and $_ -match 'retry' })[0]
            $retryMessage | Should -Match 'Verification timed out for retry: 7zip\.7zip'
        }
    }
}

Describe 'Install-AppWithVerification (shared install-and-verify pipeline, issue #188)' {
    BeforeEach {
        Mock Write-Host { }

        # Boundary mocks with safe defaults; individual tests override what they exercise.
        Mock Install-WingetPackage { @{ ExitCode = 0; Attempts = 1; SessionErrorExhausted = $false; MachineScopeFellBack = $false } }
        Mock Test-WingetPackageInstalled { @{ Installed = $false; TimedOut = $false; ExitCode = 0 } }
    }

    It 'Skips an app that is already installed without dispatching an install' {
        Mock Test-WingetPackageInstalled { @{ Installed = $true; TimedOut = $false; ExitCode = 0 } }

        $result = Install-AppWithVerification -App @{ name = 'Test.App' }

        $result.Status | Should -Be 'Skipped'
        $result.InstallResult | Should -Be $null
        $result.FailureReason | Should -Be $null
        Should -Invoke Install-WingetPackage -Times 0 -Exactly
        Should -Invoke Test-WingetPackageInstalled -Times 1 -Exactly
    }

    It 'Installs a missing app and reports Installed when the post-verify finds it' {
        $script:checkCount = 0
        Mock Test-WingetPackageInstalled {
            $script:checkCount++
            if ($script:checkCount -eq 1) {
                return @{ Installed = $false; TimedOut = $false; ExitCode = 0 }
            }
            @{ Installed = $true; TimedOut = $false; ExitCode = 0 }
        }

        $result = Install-AppWithVerification -App @{ name = 'Test.App' }

        $result.Status | Should -Be 'Installed'
        $result.FailureReason | Should -Be $null
        # The Install-WingetPackage result comes back intact so exit codes can be surfaced (#189).
        $result.InstallResult.ExitCode | Should -Be 0
        $result.InstallResult.Attempts | Should -Be 1
        Should -Invoke Install-WingetPackage -Times 1 -Exactly -ParameterFilter { $PackageId -eq 'Test.App' }
        # Pre-check and post-verify both run under the 15-second timeout guard.
        Should -Invoke Test-WingetPackageInstalled -Times 2 -Exactly -ParameterFilter { $TimeoutSeconds -eq 15 }
    }

    It 'Forwards the app''s installerType override to Install-WingetPackage' {
        [void](Install-AppWithVerification -App @{ name = 'Test.App'; installerType = 'wix' })

        Should -Invoke Install-WingetPackage -Times 1 -Exactly -ParameterFilter { $InstallerType -eq 'wix' }
    }

    It 'Reports Failed with the install result intact when the install ran but verification cannot find the app' {
        Mock Install-WingetPackage { @{ ExitCode = 0; Attempts = 2; SessionErrorExhausted = $false; MachineScopeFellBack = $true } }
        # Default Test-WingetPackageInstalled mock: not installed before or after.

        $result = Install-AppWithVerification -App @{ name = 'Test.App' }

        $result.Status | Should -Be 'Failed'
        $result.FailureReason | Should -Be 'VerifyNotFound'
        $result.InstallResult.ExitCode | Should -Be 0
        $result.InstallResult.Attempts | Should -Be 2
        $result.InstallResult.MachineScopeFellBack | Should -Be $true
    }

    It 'Marks a pre-check timeout as Failed without attempting the install (issue #176)' {
        Mock Test-WingetPackageInstalled { @{ Installed = $false; TimedOut = $true; ExitCode = $null } }

        $result = Install-AppWithVerification -App @{ name = 'Test.App' }

        $result.Status | Should -Be 'Failed'
        $result.FailureReason | Should -Be 'PreCheckTimeout'
        $result.InstallResult | Should -Be $null
        Should -Invoke Install-WingetPackage -Times 0 -Exactly
    }

    It 'Marks a verification timeout as Failed and keeps the install result (issue #176)' {
        $script:checkCount = 0
        Mock Test-WingetPackageInstalled {
            $script:checkCount++
            if ($script:checkCount -eq 1) {
                return @{ Installed = $false; TimedOut = $false; ExitCode = 0 }
            }
            @{ Installed = $false; TimedOut = $true; ExitCode = $null }
        }

        $result = Install-AppWithVerification -App @{ name = 'Test.App' }

        $result.Status | Should -Be 'Failed'
        $result.FailureReason | Should -Be 'VerifyTimeout'
        $result.InstallResult.ExitCode | Should -Be 0
        Should -Invoke Install-WingetPackage -Times 1 -Exactly
    }

    Context 'Applicability conditions (issue #217)' {
        BeforeEach {
            $script:conditionWarnings = @()
            Mock Write-WarningMessage { $script:conditionWarnings += $Message }
        }

        It 'Skips a condition-false app as NotApplicable without any winget probe or install' {
            $result = Install-AppWithVerification -App @{ name = 'Dell.CommandUpdate.Universal'; condition = { $false }; conditionDescription = 'Dell hardware only' }

            $result.Status | Should -Be 'Skipped'
            $result.SkipReason | Should -Be 'NotApplicable'
            $result.InstallResult | Should -Be $null
            $result.FailureReason | Should -Be $null
            # The gate runs BEFORE the pre-check: no winget probe, no install dispatch.
            Should -Invoke Test-WingetPackageInstalled -Times 0 -Exactly
            Should -Invoke Install-WingetPackage -Times 0 -Exactly
        }

        It 'Reports the same NotApplicable skip in a dry run (-WhatIf)' {
            $result = Install-AppWithVerification -App @{ name = 'Dell.CommandUpdate.Universal'; condition = { $false }; conditionDescription = 'Dell hardware only' } -WhatIf

            $result.Status | Should -Be 'Skipped'
            $result.SkipReason | Should -Be 'NotApplicable'
            Should -Invoke Test-WingetPackageInstalled -Times 0 -Exactly
            Should -Invoke Install-WingetPackage -Times 0 -Exactly
        }

        It 'Runs the normal install flow when the condition is true' {
            $script:checkCount = 0
            Mock Test-WingetPackageInstalled {
                $script:checkCount++
                if ($script:checkCount -eq 1) {
                    return @{ Installed = $false; TimedOut = $false; ExitCode = 0 }
                }
                @{ Installed = $true; TimedOut = $false; ExitCode = 0 }
            }

            $result = Install-AppWithVerification -App @{ name = 'Dell.CommandUpdate.Universal'; condition = { $true }; conditionDescription = 'Dell hardware only' }

            $result.Status | Should -Be 'Installed'
            $result.SkipReason | Should -Be $null
            Should -Invoke Install-WingetPackage -Times 1 -Exactly -ParameterFilter { $PackageId -eq 'Dell.CommandUpdate.Universal' }
            Should -Invoke Test-WingetPackageInstalled -Times 2 -Exactly
        }

        It 'Fails open when the condition throws: warns and proceeds with the install' {
            $script:checkCount = 0
            Mock Test-WingetPackageInstalled {
                $script:checkCount++
                if ($script:checkCount -eq 1) {
                    return @{ Installed = $false; TimedOut = $false; ExitCode = 0 }
                }
                @{ Installed = $true; TimedOut = $false; ExitCode = 0 }
            }

            $result = Install-AppWithVerification -App @{ name = 'Dell.CommandUpdate.Universal'; condition = { throw 'CIM unavailable' }; conditionDescription = 'Dell hardware only' }

            # A broken probe must never silently drop an app: the install proceeds normally.
            $result.Status | Should -Be 'Installed'
            $result.SkipReason | Should -Be $null
            Should -Invoke Install-WingetPackage -Times 1 -Exactly
            $failOpenWarning = @($script:conditionWarnings | Where-Object { $_ -match 'failed to evaluate' })[0]
            $failOpenWarning | Should -Match 'Dell\.CommandUpdate\.Universal'
            $failOpenWarning | Should -Match 'CIM unavailable'
            $failOpenWarning | Should -Match 'treating as applicable'
        }

        It 'Leaves SkipReason unset for an already-installed skip so the two skips stay distinguishable' {
            Mock Test-WingetPackageInstalled { @{ Installed = $true; TimedOut = $false; ExitCode = 0 } }

            $result = Install-AppWithVerification -App @{ name = 'Test.App' }

            $result.Status | Should -Be 'Skipped'
            $result.SkipReason | Should -Be $null
        }
    }

    Context 'Package-specific installers ($app.install dispatch)' {
        It 'Dispatches to the named self-verifying installer instead of Install-WingetPackage' {
            function Install-FakePowerShell { @{ ExitCode = 0; Installed = $true; Method = 'msi' } }

            $result = Install-AppWithVerification -App @{ name = 'Microsoft.PowerShell'; install = 'Install-FakePowerShell' }

            $result.Status | Should -Be 'Installed'
            $result.FailureReason | Should -Be $null
            # The custom installer's result is passed through intact (ExitCode/Method for #189).
            $result.InstallResult.Method | Should -Be 'msi'
            $result.InstallResult.ExitCode | Should -Be 0
            Should -Invoke Install-WingetPackage -Times 0 -Exactly
            # Only the pre-check runs: the custom installer self-verifies (a DISM-provisioned
            # PowerShell never shows up under `winget list` for the elevating account).
            Should -Invoke Test-WingetPackageInstalled -Times 1 -Exactly
        }

        It 'Trusts a self-verifying installer''s failure result and reports CustomInstallFailed' {
            $app = @{ name = 'Microsoft.PowerShell'; install = { @{ ExitCode = -1; Installed = $false; Method = 'msix-provisioned' } } }

            $result = Install-AppWithVerification -App $app

            $result.Status | Should -Be 'Failed'
            $result.FailureReason | Should -Be 'CustomInstallFailed'
            $result.InstallResult.ExitCode | Should -Be -1
            Should -Invoke Install-WingetPackage -Times 0 -Exactly
        }
    }

    Context 'Dry run (-WhatIf)' {
        It 'Reports a missing app as would-install without dispatching anything' {
            $result = Install-AppWithVerification -App @{ name = 'Test.App' } -WhatIf

            $result.Status | Should -Be 'Installed'
            $result.InstallResult | Should -Be $null
            $result.FailureReason | Should -Be $null
            Should -Invoke Install-WingetPackage -Times 0 -Exactly
        }

        It 'Still reports an already-installed app as Skipped' {
            Mock Test-WingetPackageInstalled { @{ Installed = $true; TimedOut = $false; ExitCode = 0 } }

            (Install-AppWithVerification -App @{ name = 'Test.App' } -WhatIf).Status | Should -Be 'Skipped'
        }

        It 'Still counts a hung pre-check as Failed in a dry run (issue #176)' {
            Mock Test-WingetPackageInstalled { @{ Installed = $false; TimedOut = $true; ExitCode = $null } }

            $result = Install-AppWithVerification -App @{ name = 'Test.App' } -WhatIf

            $result.Status | Should -Be 'Failed'
            $result.FailureReason | Should -Be 'PreCheckTimeout'
        }

        It 'Never invokes a package-specific installer in a dry run' {
            $result = Install-AppWithVerification -App @{ name = 'Microsoft.PowerShell'; install = { throw 'must not run in a dry run' } } -WhatIf

            $result.Status | Should -Be 'Installed'
        }
    }
}

Describe 'Not-applicable gating end-to-end (issue #217)' {
    # Drives the REAL Install-AppWithVerification through the real orchestrator (dry run, so no
    # elevation is needed): only the orchestration boundary and the winget probes are mocked.
    BeforeEach {
        Mock Write-Host { }
        Mock Start-Process { }
        Mock Restart-WithElevation { 'PowerShell' }
        Mock Test-IsRunningLocally { $true }
        Mock Test-AndInstallWingetModule { $true }
        Mock Import-Module { }
        Mock Test-AndInstallWinget { $true }
        Mock Initialize-WingetSourcesForUser { $true }
        Mock Test-AndInstallGraphicalTools { $true }
        Mock Test-WingetSources { $true }
        Mock Remove-LegacyScheduledUpdates { $true }
        Mock Set-WindowsTerminalDefaults { }
        Mock Install-WingetAutoUpdate { @{ Status = 'DryRun'; Version = '2.12.0' } }
        Mock Install-WingetPackage { @{ ExitCode = 0; Attempts = 1; SessionErrorExhausted = $false; MachineScopeFellBack = $false } }
        Mock Test-WingetPackageInstalled { @{ Installed = $false; TimedOut = $false; ExitCode = 0 } }

        $script:capturedRows = $null
        Mock Write-Table { $script:capturedRows = $Rows }
        $script:warningMessages = @()
        Mock Write-WarningMessage { $script:warningMessages += $Message }
    }

    It 'Gates a condition-false app before any winget probe and reports the not-applicable skip' {
        $apps = @(
            @{ name = 'Dell.CommandUpdate.Universal'; condition = { $false }; conditionDescription = 'Dell hardware only' },
            @{ name = 'Contoso.NormalApp' }
        )

        Invoke-WingetInstall -Apps $apps -WhatIf -NonInteractive

        # The gated app was skipped with the reason line; the ungated app went through the
        # normal dry-run pipeline (pre-check probe ran for it, and only for it).
        $script:warningMessages | Should -Contain 'Skipping: Dell.CommandUpdate.Universal (not applicable: Dell hardware only)'
        Should -Invoke Test-WingetPackageInstalled -Times 1 -Exactly -ParameterFilter { $PackageId -eq 'Contoso.NormalApp' }
        Should -Invoke Test-WingetPackageInstalled -Times 0 -Exactly -ParameterFilter { $PackageId -eq 'Dell.CommandUpdate.Universal' }

        $skippedRow = @($script:capturedRows | Where-Object { $_[0] -eq 'Skipped' })[0]
        $skippedRow[1] | Should -Match 'Dell\.CommandUpdate\.Universal'
        $installedRow = @($script:capturedRows | Where-Object { $_[0] -eq 'Installed' })[0]
        $installedRow[1] | Should -Match 'Contoso\.NormalApp'
        @($script:capturedRows | Where-Object { $_[0] -eq 'Failed' }).Count | Should -Be 0
    }
}

Describe 'Format-InstallFailureReason (issue #189)' {
    Context 'With the full Install-WingetPackage result shape' {
        It 'Includes the hex exit code, attempt count, and machine-scope fallback' {
            $installResult = @{ ExitCode = -2147009255; Attempts = 3; SessionErrorExhausted = $false; MachineScopeFellBack = $true }

            $reason = Format-InstallFailureReason -FailureReason 'VerifyNotFound' -InstallResult $installResult

            $reason | Should -Be 'package not found after install; winget exit 0x80073D19, 3 attempts, machine-scope fallback: yes'
        }

        It 'Uses singular wording for a single attempt' {
            $installResult = @{ ExitCode = -1978335212; Attempts = 1; SessionErrorExhausted = $false; MachineScopeFellBack = $false }

            $reason = Format-InstallFailureReason -FailureReason 'VerifyNotFound' -InstallResult $installResult

            $reason | Should -Be 'package not found after install; winget exit 0x8A150014, 1 attempt, machine-scope fallback: no'
        }

        It 'Calls out exhausted 0x80073D19 session retries' {
            $installResult = @{ ExitCode = -2147009255; Attempts = 3; SessionErrorExhausted = $true; MachineScopeFellBack = $false }

            $reason = Format-InstallFailureReason -FailureReason 'VerifyNotFound' -InstallResult $installResult

            $reason | Should -Match 'winget exit 0x80073D19'
            $reason | Should -Match 'session error 0x80073D19 persisted through every retry'
        }
    }

    Context 'With a custom installer result shape (ExitCode/Installed only)' {
        It 'Formats the exit code without inventing attempts or fallback detail' {
            $reason = Format-InstallFailureReason -FailureReason 'CustomInstallFailed' -InstallResult @{ ExitCode = 1603; Installed = $false }

            $reason | Should -Be 'installer reported failure; winget exit 0x00000643'
        }
    }

    Context 'With no install result (timeouts, exceptions)' {
        It 'Maps PreCheckTimeout to the pre-install check wording' {
            Format-InstallFailureReason -FailureReason 'PreCheckTimeout' -InstallResult $null |
                Should -Be 'winget list timed out during the pre-install check'
        }

        It 'Maps VerifyTimeout to the verification wording' {
            Format-InstallFailureReason -FailureReason 'VerifyTimeout' -InstallResult $null |
                Should -Be 'post-install verification timed out'
        }

        It 'Falls back to a generic reason for unknown failure kinds' {
            Format-InstallFailureReason -FailureReason $null -InstallResult $null | Should -Be 'install failed'
        }
    }
}

Describe 'Write-FailedAppsSummary (issue #189)' {
    BeforeEach {
        Mock Write-Host { }
        $script:failedSummaryCalls = @()
        Mock Write-Table { $script:failedSummaryCalls += , @{ Headers = $Headers; Rows = $Rows; Title = $Title } }
    }

    It 'Renders one row per failed app with a Reason column' {
        $failed = @(
            @{ Name = '7zip.7zip'; Reason = 'package not found after install; winget exit 0x80073D19, 3 attempts, machine-scope fallback: no' },
            @{ Name = 'Google.Chrome'; Reason = 'post-install verification timed out' }
        )

        Write-FailedAppsSummary -FailedApps $failed

        $script:failedSummaryCalls.Count | Should -Be 1
        $call = $script:failedSummaryCalls[0]
        $call.Headers | Should -Be @('App', 'Reason')
        $call.Title | Should -Be 'Failed Installations'
        $call.Rows.Count | Should -Be 2
        $call.Rows[0][0] | Should -Be '7zip.7zip'
        $call.Rows[0][1] | Should -Match '0x80073D19'
        $call.Rows[1][0] | Should -Be 'Google.Chrome'
        $call.Rows[1][1] | Should -Be 'post-install verification timed out'
    }

    It 'Renders nothing when no apps failed' {
        Write-FailedAppsSummary -FailedApps @()
        Write-FailedAppsSummary -FailedApps $null

        Should -Invoke Write-Table -Times 0 -Exactly
    }
}

Describe 'WhatIf Mode - Unit Tests' {
    BeforeAll {
    }

    Context 'WhatIf parameter acceptance' {
        It 'Should accept WhatIf parameter without error' {
            $command = Get-Command Invoke-WingetInstall
            $command.Parameters.ContainsKey('WhatIf') | Should -Be $true
            $command.Parameters['WhatIf'].ParameterType.Name | Should -Be 'SwitchParameter'
        }

        It 'Should accept NonInteractive parameter without error' {
            $command = Get-Command Invoke-WingetInstall
            $command.Parameters.ContainsKey('NonInteractive') | Should -Be $true
            $command.Parameters['NonInteractive'].ParameterType.Name | Should -Be 'SwitchParameter'
        }
    }

    # The 'WhatIf logic for source trust' context was removed in issue #177 along with the
    # Install.ps1 trusted-sources loop it simulated (Test-WingetSourceTrusted/Set-Sources);
    # the 'WhatIf logic for PATH updates' context was removed in issue #179 with the PATH block.

    # The 'WhatIf logic for app installation' context was removed in issue #188: it simulated the
    # dry-run branch with a re-inlined obsolete copy of the install loop. The dry-run behavior is
    # now tested for real against Install-AppWithVerification ('dry run (-WhatIf)' context) and
    # against the whole orchestrator in 'Invoke-WingetInstall wiring (issue #188)'.
}
