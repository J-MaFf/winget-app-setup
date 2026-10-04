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
        # Capture Invoke-WingetInstall's source now, BEFORE Get-Command is mocked below. The
        # structural tests inspect this definition; routing their `Get-Command Invoke-WingetInstall`
        # through the filtered mock throws under Pester 6, which (unlike Pester 5) no longer falls
        # back to the real command when no -ParameterFilter matches and there is no default mock.
        $script:InvokeWingetInstallDef = (Get-Command Invoke-WingetInstall).Definition
        $script:GetCurrentWindowsPrincipalDef = (Get-Command Get-CurrentWindowsPrincipal).Definition

        Mock Write-Host { }
        Mock Start-Process { }

        # Mock the functions that are called

        # Mock external commands
        Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'pwsh' }
        Mock winget { 'App1' } -ParameterFilter { $args -contains 'list' }
        Mock Start-Process { }
    }

    # The old 'Administrator check' context asserted `Should -BeOfType` on framework constants
    # ([bool], the WindowsBuiltInRole enum) — tautologies that could never fail (issue #192). The
    # orchestrator's admin gate is now driven for real, with Test-IsAdmin mocked, by the 'Elevation
    # gate' context in 'Invoke-WingetInstall wiring' below.
    Context 'Administrator gate' {
        It 'Test-IsAdmin''s seam still performs the real WindowsPrincipal check (pinned structurally: every test mocks it)' {
            # Test-IsAdmin (WingetAppSetup/Public/Elevation.ps1) is covered directly in
            # Elevation.Tests.ps1 through its Get-CurrentWindowsPrincipal seam, and every orchestrator
            # test mocks Test-IsAdmin itself. So pin here that the seam still ends at the genuine .NET
            # call rather than a stub: running it would only report the test runner's own elevation
            # (and it throws off Windows).
            $probeBody = $script:GetCurrentWindowsPrincipalDef
            $probeBody | Should -Match '\[Security\.Principal\.WindowsPrincipal\]'
            $probeBody | Should -Match 'WindowsIdentity\]::GetCurrent\(\)'
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

    # The 'Winget availability gate' and 'Summary table generation' contexts were removed
    # (wgt-gq8.6): the first pinned `Exit 2` with a regex on the source, the second re-implemented
    # the summary rows inline and asserted on its own copy. Both are now driven through the real
    # orchestrator in 'Invoke-WingetInstall wiring' ('Exit-code contract' and 'Summary').
}

# The 'Retry Failed Installations' Describe was removed in issue #188: it simulated the retry
# loop with an obsolete re-inlined copy (single-string ArgumentList, no --scope machine) instead
# of exercising the real code. The retry semantics it guarded (success moves to installed,
# failure stays failed, mixed results, no-op when nothing failed, non-zero exit signalling) are
# now covered by the 'Install-AppWithVerification' Describe (per-app success/failure states) and
# the 'Invoke-WingetInstall wiring (issue #188)' Describe below.
#
# Invoke-WingetInstall returns its exit code instead of calling `exit` (wgt-gq8.6), so every path
# below - failed apps, a broken winget, a declined elevation - is driven for real and asserted on
# the returned code. Before that, any path ending in `Exit` would have ended the Pester process
# itself, so those paths were pinned with regexes over the function's source.
Describe 'Invoke-WingetInstall wiring (issue #188)' {
    BeforeAll {
        # The structural tests below read the source text; captured here too, so they do not depend
        # on 'Main Script Logic' having run first (a filtered run skips its BeforeAll).
        $script:InvokeWingetInstallDef = ${function:Invoke-WingetInstall}.ToString()
    }

    BeforeEach {
        Mock Write-Host { }
        Mock Start-Process { }
        Mock Start-Sleep { }
        # Elevated by default, so a real (non -WhatIf) run goes straight to the installs on every
        # runner; the contexts that exercise the non-admin branches mock it to $false. Never read the
        # runner's real elevation: CI runs elevated, so a test gated on it never ran there (wgt-gq8.6).
        Mock Test-IsAdmin { $true }
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
        # Healthy (no conflict) by default (issue #279); tests for the deadlock fail-fast override this.
        Mock Get-ConflictingDesktopAppInstallerVersions { @() }
        # The end-of-run winget health check launches real winget; healthy by default so a real
        # (non -WhatIf) run in these tests never probes the machine.
        Mock Wait-WingetLaunchable { $true }
        # Never wait on (or query) the machine's real Winget-AutoUpdate tasks.
        Mock Wait-WauIdle { $true }

        # Rows of every table the run prints, keyed by title; capturedRows is the main summary.
        $script:capturedRows = $null
        $script:capturedTables = @{}
        Mock Write-Table {
            $script:capturedTables[$Title] = $Rows
            if ($Title -eq 'Installation Summary') {
                $script:capturedRows = $Rows
            }
        }
        $script:errorMessages = @()
        Mock Write-ErrorMessage { $script:errorMessages += $Message }
        $script:warningMessages = @()
        Mock Write-WarningMessage { $script:warningMessages += $Message }
        $script:infoMessages = @()
        Mock Write-Info { $script:infoMessages += $Message }
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

        It 'Never ends the process itself: no exit statement and no Exit-Installer call (pinned structurally - an exit here would end the test run, not fail a test)' {
            # The entry script (build/fragments/tail.ps1) exits with the returned code and tells an
            # intended exit from an outside stop. An `exit` in here would bypass that, and the
            # behavioral tests below could not report it: it would end the Pester process instead.
            $functionAst = ${function:Invoke-WingetInstall}.Ast
            $exitStatements = $functionAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.ExitStatementAst] }, $true)
            @($exitStatements).Count | Should -Be 0
            $exitInstallerCalls = $functionAst.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Exit-Installer'
                }, $true)
            @($exitInstallerCalls).Count | Should -Be 0
        }

        It 'Routes the pre-elevation winget source update through the timeout-guarded probe instead of a bare -Wait Start-Process' {
            # The pre-elevation `winget source update` call used to run via a bare
            # `Start-Process ... -Wait` with no timeout, which could hang the whole run forever
            # on a corrupted/unreachable source. It must now reuse Invoke-WingetSourceProbe
            # (WingetBootstrap.ps1), which wraps the identical command in a 120s WaitForExit/Kill
            # timeout guard, rather than duplicating that guard a third time.
            $installBody = $script:InvokeWingetInstallDef
            $installBody | Should -Match 'Invoke-WingetSourceProbe'
            $installBody | Should -Not -Match "Start-Process -FilePath 'winget' -ArgumentList 'source', 'update'.*-Wait"
        }
    }

    Context 'Exit-code contract (returned to the entry script, which exits with it)' {
        It 'Returns 0, and nothing else, when every app installs and winget still launches at the end' {
            $result = Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive

            # Exactly one [int]: the entry script exits with the last value the function writes, so
            # a stray value in the output stream must never be the only thing it sees.
            @($result).Count | Should -Be 1
            $result | Should -BeOfType [int]
            $result | Should -Be 0
            Should -Invoke Wait-WingetLaunchable -Times 1 -Exactly
        }

        It 'Returns 1 when an app is still failed after the retry pass (issue #176)' {
            Mock Install-AppWithVerification { @{ Status = 'Failed'; InstallResult = @{ ExitCode = 1; Attempts = 1 }; FailureReason = 'VerifyNotFound' } }

            $result = Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive

            $result | Should -Be 1
            # Once in the first pass, once in the retry pass.
            Should -Invoke Install-AppWithVerification -Times 2 -Exactly
        }

        It 'Returns 0 when the retry pass recovers the only failed app' {
            $script:appCalls = 0
            Mock Install-AppWithVerification {
                $script:appCalls++
                if ($script:appCalls -eq 1) {
                    return @{ Status = 'Failed'; InstallResult = @{ ExitCode = 1 }; FailureReason = 'VerifyNotFound' }
                }
                @{ Status = 'Installed'; InstallResult = @{ ExitCode = 0 }; FailureReason = $null }
            }

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive | Should -Be 0
        }

        It 'Returns 2 and reports winget as NOT USABLE when the end-of-run probe fails and no app failed' {
            Mock Wait-WingetLaunchable { $false }

            $result = Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive

            $result | Should -Be 2
            $script:errorMessages | Should -Contain 'winget: NOT USABLE - winget could not be launched at the end of this run, so automatic updates and the next run of this installer will fail on this machine. Restart the machine and re-run the installer; if it persists, attach this transcript to a GitHub issue.'
            # The summary still prints: a broken winget is reported, not a reason to stop early.
            Should -Invoke Write-Table -Times 1 -Exactly -ParameterFilter { $Title -eq 'Installation Summary' }
        }

        It 'Returns 1, not 2, when apps failed and the end-of-run probe failed too (failed apps take precedence)' {
            Mock Install-AppWithVerification { @{ Status = 'Failed'; InstallResult = @{ ExitCode = 1 }; FailureReason = 'VerifyNotFound' } }
            Mock Wait-WingetLaunchable { $false }

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive | Should -Be 1
        }

        It 'Returns 2 without installing anything when winget is unavailable and cannot be installed' {
            Mock Test-AndInstallWinget { $false }

            $result = Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive

            $result | Should -Be 2
            $script:errorMessages | Should -Contain 'Winget is required for this script. Exiting.'
            Should -Invoke Install-AppWithVerification -Times 0 -Exactly
            Should -Invoke Install-WingetAutoUpdate -Times 0 -Exactly
            Should -Invoke Write-Table -Times 0 -Exactly
        }

        It 'Returns 3 without installing anything when an app definition fails validation' {
            $result = Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }, @{ name = 'not a package id' }) -NonInteractive

            $result | Should -Be 3
            $script:errorMessages | Should -Contain 'No valid application definitions found. Resolve the errors and re-run the script.'
            Should -Invoke Install-AppWithVerification -Times 0 -Exactly
        }

        It 'Keeps 0 when Winget-AutoUpdate could not be configured (auto-updates do not affect the exit code, issue #186)' {
            Mock Install-WingetAutoUpdate { [pscustomobject]@{ Status = 'Failed'; Version = $null } }

            $result = Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive

            $result | Should -Be 0
            ($script:errorMessages -join "`n") | Should -Match 'Auto-updates: FAILED'
        }

        It 'Returns the dry run''s outcome too, without probing winget at the end' {
            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -WhatIf -NonInteractive | Should -Be 0
            Should -Invoke Wait-WingetLaunchable -Times 0 -Exactly
        }

        It 'Records the decided exit code before the final prompt, so Ctrl+C there keeps it' {
            # Interactive run: the function asks 'Press any key to exit...' before returning. The
            # entry script's abort guard reports InstallerPendingExitCode when a stop lands there.
            # The prompt throws here to stand in for that stop (and to never reach ReadKey).
            Mock Test-EffectiveNonInteractive { $false }
            Mock Install-AppWithVerification { @{ Status = 'Failed'; InstallResult = @{ ExitCode = 1 }; FailureReason = 'VerifyNotFound' } }
            $script:InstallerPendingExitCode = $null
            $script:pendingCodeAtPrompt = 'prompt not reached'
            Mock Write-Prompt {
                $script:pendingCodeAtPrompt = $script:InstallerPendingExitCode
                throw 'stopped at the final prompt'
            }

            { Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) } | Should -Throw 'stopped at the final prompt'

            $script:pendingCodeAtPrompt | Should -Be 1
        }
    }

    Context 'Elevation gate (Test-IsAdmin mocked to $false, so it runs on any runner)' {
        BeforeEach {
            Mock Test-IsAdmin { $false }
            Mock Invoke-WingetSourceProbe { @{ Succeeded = $true; ExitCode = 0; TimedOut = $false } }
            # A run from the generated installer file, not from the imported module (issue #185).
            Mock Test-InvokedFromModuleContext { $false }
        }

        It 'Relaunches elevated, forwarding the caller''s switches, and returns 0 without installing anything' {
            $result = Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive -SkipSystemCheck

            $result | Should -Be 0
            Should -Invoke Restart-WithElevation -Times 1 -Exactly -ParameterFilter {
                ($AdditionalArguments -contains '-NonInteractive') -and ($AdditionalArguments -contains '-SkipSystemCheck') -and -not ($AdditionalArguments -contains '-WhatIf')
            }
            Should -Invoke Test-AndInstallWinget -Times 0 -Exactly
            Should -Invoke Install-AppWithVerification -Times 0 -Exactly
        }

        It 'Returns 1 and says so when the elevation is declined or fails' {
            Mock Restart-WithElevation { $null }

            $result = Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive

            $result | Should -Be 1
            $script:errorMessages | Should -Contain 'Elevation was declined or failed, so nothing was installed. Re-run the installer and approve the administrator (UAC) prompt.'
            Should -Invoke Install-AppWithVerification -Times 0 -Exactly
        }

        It 'Returns 1 with the remote elevation guidance under irm | iex, where it cannot relaunch (issues #226/#229)' {
            Mock Test-IsRunningLocally { $false }

            $result = Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive

            $result | Should -Be 1
            $script:errorMessages | Should -Contain 'This script requires administrator privileges.'
            $script:errorMessages | Should -Contain 'Auto-elevation is unavailable when running through IEX/remote execution.'
            $script:infoMessages | Should -Contain 'Open an elevated PowerShell or Windows Terminal session and run the IEX command again.'
            # No "press Enter to restart" pause any more (issue #230), and no 5-second sleep either:
            # the entry script's Exit-Installer holds the window when someone is there (P2-14).
            (@($script:errorMessages) + @($script:infoMessages)) -join "`n" | Should -Not -Match 'Press Enter|Exiting in 5 seconds'
            Should -Invoke Start-Sleep -Times 0 -Exactly -ParameterFilter { $Seconds -eq 5 }
            Should -Invoke Restart-WithElevation -Times 0 -Exactly
            Should -Invoke Install-AppWithVerification -Times 0 -Exactly
        }

        It 'Returns 1 without relaunching when called from the imported module (issue #185)' {
            Mock Test-InvokedFromModuleContext { $true }

            $result = Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive

            $result | Should -Be 1
            ($script:errorMessages -join "`n") | Should -Match 'invoked from the imported module without elevation'
            Should -Invoke Restart-WithElevation -Times 0 -Exactly
            Should -Invoke Install-AppWithVerification -Times 0 -Exactly
        }
    }

    Context 'Pre-elevation source update (real non-admin, non-WhatIf code path)' {
        # Test-IsAdmin (Public/Elevation.ps1, issue #239) wraps the admin check behind a mockable
        # command, so this drives Invoke-WingetInstall's real (non-WhatIf) pre-elevation block on
        # any machine, elevated or not. The run then stops at the (mocked) elevated relaunch.
        BeforeEach {
            Mock Test-IsAdmin { $false }
            Mock Test-IsRunningLocally { $true }
            Mock Test-InvokedFromModuleContext { $false }
            Mock Invoke-WingetSourceProbe { @{ Succeeded = $true; ExitCode = 0; TimedOut = $false } }
        }

        It 'Actually invokes Invoke-WingetSourceProbe before elevation when running non-admin, non-WhatIf' {
            Invoke-WingetInstall -NonInteractive | Should -Be 0

            Should -Invoke Invoke-WingetSourceProbe -Times 1 -Exactly
        }

        It 'Does not call Invoke-WingetSourceProbe in a dry run (-WhatIf), preserving the existing dry-run message instead' {
            Mock Install-AppWithVerification { @{ Status = 'Installed'; InstallResult = $null; FailureReason = $null } }

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -WhatIf -NonInteractive | Should -Be 0

            Should -Invoke Invoke-WingetSourceProbe -Times 0 -Exactly
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

            Invoke-WingetInstall -WhatIf -NonInteractive | Should -Be 0

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

    # IEX/remote execution (Test-IsRunningLocally false) previously ignored -WhatIf entirely and
    # unconditionally demanded elevation (exit 1), unlike the local-file branch which already
    # honored -WhatIf (issue #232). Test-IsAdmin is mocked to $false: these used to be skipped
    # whenever the test runner itself was elevated, so on the elevated CI runner they never ran.
    Context 'IEX/remote elevation dry-run (WhatIf must preview, not demand elevation)' {
        BeforeEach {
            Mock Test-IsAdmin { $false }
            Mock Test-IsRunningLocally { $false }
        }

        It 'Does not print the elevation-required errors or exit when non-admin, non-local, and -WhatIf is set' {
            Mock Install-AppWithVerification { @{ Status = 'Installed'; InstallResult = $null; FailureReason = $null } }

            $result = Invoke-WingetInstall -Apps @(@{ name = 'Contoso.OnlyApp' }) -WhatIf -NonInteractive

            $script:errorMessages | Should -Not -Contain 'This script requires administrator privileges.'
            $script:errorMessages | Should -Not -Contain 'Auto-elevation is unavailable when running through IEX/remote execution.'
            # The dry run went on to the app instead of stopping at the elevation gate with 1.
            $result | Should -Be 0
            Should -Invoke Install-AppWithVerification -Times 1 -Exactly
            Should -Invoke Start-Sleep -Times 0 -Exactly
        }

        It 'Prints a [DRY-RUN] message stating elevation would be required and no changes are made' {
            Mock Install-AppWithVerification { @{ Status = 'Installed'; InstallResult = $null; FailureReason = $null } }

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.OnlyApp' }) -WhatIf -NonInteractive

            ($script:infoMessages | Where-Object { $_ -match '\[DRY-RUN\]' -and $_ -match 'administrator' }) | Should -Not -BeNullOrEmpty
            ($script:infoMessages | Where-Object { $_ -match 'no system changes' }) | Should -Not -BeNullOrEmpty
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
        It 'Logs the not-applicable skip line with the condition description and buckets the app as Skipped' {
            Mock Install-AppWithVerification { @{ Status = 'Skipped'; InstallResult = $null; FailureReason = $null; SkipReason = 'NotApplicable' } }

            Invoke-WingetInstall -Apps @(@{ name = 'Dell.CommandUpdate.Universal'; condition = { $false }; conditionDescription = 'Dell hardware only' }) -WhatIf -NonInteractive

            # Exactly the message shape of the already-installed skip, with the gated reason.
            $script:warningMessages | Should -Contain 'Skipping: Dell.CommandUpdate.Universal (not applicable: Dell hardware only)'
            $skippedRow = @($script:capturedRows | Where-Object { $_[0] -eq 'Skipped' })[0]
            $skippedRow[1] | Should -Match 'Dell\.CommandUpdate\.Universal'
            @($script:capturedRows | Where-Object { $_[0] -eq 'Failed' }).Count | Should -Be 0
        }

        It 'Falls back to a generic reason when the entry has no conditionDescription' {
            Mock Install-AppWithVerification { @{ Status = 'Skipped'; InstallResult = $null; FailureReason = $null; SkipReason = 'NotApplicable' } }

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.GatedApp'; condition = { $false } }) -WhatIf -NonInteractive

            $script:warningMessages | Should -Contain 'Skipping: Contoso.GatedApp (not applicable: condition not met)'
        }

        It 'Keeps the already-installed skip message for skips without a SkipReason' {
            Mock Install-AppWithVerification { @{ Status = 'Skipped'; InstallResult = $null; FailureReason = $null } }

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.PresentApp' }) -WhatIf -NonInteractive

            $script:warningMessages | Should -Contain 'Skipping: Contoso.PresentApp (already installed)'
        }
    }

    Context 'Summary' {
        It 'Renders Installed, Skipped and Failed rows from the run''s outcomes' {
            Mock Install-AppWithVerification {
                switch ($App.name) {
                    'Contoso.Present' { @{ Status = 'Skipped'; InstallResult = $null; FailureReason = $null } }
                    'Contoso.Broken' { @{ Status = 'Failed'; InstallResult = @{ ExitCode = 1 }; FailureReason = 'VerifyNotFound' } }
                    default { @{ Status = 'Installed'; InstallResult = @{ ExitCode = 0 }; FailureReason = $null } }
                }
            }

            $result = Invoke-WingetInstall -Apps @(@{ name = 'Contoso.New' }, @{ name = 'Contoso.Present' }, @{ name = 'Contoso.Broken' }) -NonInteractive

            $result | Should -Be 1
            @($script:capturedRows).Count | Should -Be 3
            @($script:capturedRows | Where-Object { $_[0] -eq 'Installed' })[0][1] | Should -Be 'Contoso.New'
            @($script:capturedRows | Where-Object { $_[0] -eq 'Skipped' })[0][1] | Should -Be 'Contoso.Present'
            @($script:capturedRows | Where-Object { $_[0] -eq 'Failed' })[0][1] | Should -Be 'Contoso.Broken'
        }

        It 'Leaves out the rows of empty buckets' {
            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.New' }) -NonInteractive | Should -Be 0

            @($script:capturedRows).Count | Should -Be 1
            $script:capturedRows[0][0] | Should -Be 'Installed'
            $script:capturedTables.ContainsKey('Failed Installations') | Should -Be $false
        }

        It 'Tracks failures with their diagnostic reason and renders the failed-apps table (issue #189)' {
            Mock Install-AppWithVerification {
                @{
                    Status        = 'Failed'
                    InstallResult = @{ ExitCode = -2147009255; Attempts = 3; SessionErrorExhausted = $false; MachineScopeFellBack = $true }
                    FailureReason = 'VerifyNotFound'
                }
            }

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.Broken' }) -NonInteractive | Should -Be 1

            $failedRows = @($script:capturedTables['Failed Installations'])
            $failedRows.Count | Should -Be 1
            $failedRows[0][0] | Should -Be 'Contoso.Broken'
            # The winget exit code and retry detail, not the generic message issue #189 replaced.
            $failedRows[0][1] | Should -Be 'package not found after install; winget exit 0x80073D19, 3 attempts, machine-scope fallback: yes'
            ($script:errorMessages -join "`n") | Should -Not -Match 'No package found matching input criteria'
        }
    }

    Context 'Winget-AutoUpdate setup and the end-of-run winget check (RUN_WAU=YES removed)' {
        # A real (non -WhatIf) run, elevated through the Test-IsAdmin mock, so these run on any
        # machine. The app fails its first pass and recovers in the retry pass.
        BeforeEach {
            $script:callOrder = [System.Collections.Generic.List[string]]::new()
            $script:appCalls = 0
            Mock Install-AppWithVerification {
                $script:appCalls++
                $script:callOrder.Add("app:$($App.name)")
                if ($script:appCalls -eq 1) {
                    return @{ Status = 'Failed'; InstallResult = @{ ExitCode = 1 }; FailureReason = 'VerifyNotFound' }
                }
                @{ Status = 'Installed'; InstallResult = @{ ExitCode = 0 }; FailureReason = $null }
            }
            Mock Install-WingetAutoUpdate { $script:callOrder.Add('wau'); @{ Status = 'Configured'; Version = '2.12.0' } }
            Mock Wait-WingetLaunchable { $script:callOrder.Add('probe'); $true }
        }

        It 'Sets up WAU only after the retry pass, then probes winget once with a short budget' {
            # WAU used to be installed (with RUN_WAU=YES) before the retry pass, so its immediate
            # SYSTEM run re-provisioned App Installer while the retry pass was still using winget
            # (issues #279/#283/#284). Nothing may touch winget after WAU is set up except the probe.
            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive

            $script:callOrder | Should -Be @('app:Contoso.AppOne', 'app:Contoso.AppOne', 'wau', 'probe')
            Should -Invoke Wait-WingetLaunchable -Times 1 -Exactly -ParameterFilter {
                $TimeoutSeconds -eq 60 -and $RequiredConsecutiveSuccesses -eq 1
            }
        }

        It 'Does not wait out a WAU run after installing WAU (no post-install wait window)' {
            # The old post-WAU wait (up to 6 minutes, two consecutive probes) existed only to
            # survive the immediate WAU run; the end-of-run probe is the only call left.
            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive

            Should -Invoke Wait-WingetLaunchable -Times 0 -Exactly -ParameterFilter { $TimeoutSeconds -ne 60 }
        }

        It 'Skips the end-of-run probe in a dry run' {
            # A dry run has no retry pass, so the first-pass failure from BeforeEach would stay
            # failed; this test only needs the app to land.
            Mock Install-AppWithVerification { @{ Status = 'Installed'; InstallResult = $null; FailureReason = $null } }

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -WhatIf -NonInteractive

            Should -Invoke Wait-WingetLaunchable -Times 0 -Exactly
        }

        It 'Still reaches the retry pass, WAU setup and the summary when Windows Terminal configuration throws' {
            Mock Set-WindowsTerminalDefaults { throw 'boom from the Terminal step' }

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive | Should -Be 0

            $script:callOrder | Should -Be @('app:Contoso.AppOne', 'app:Contoso.AppOne', 'wau', 'probe')
            ($script:warningMessages -join "`n") | Should -Match 'Windows Terminal configuration failed unexpectedly: boom from the Terminal step'
            Should -Invoke Write-Table -Times 1 -Exactly
        }

        It 'Reports auto-updates as FAILED and still prints the summary when WAU setup throws' {
            Mock Install-WingetAutoUpdate { throw 'boom from WAU' }

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive | Should -Be 0

            ($script:errorMessages -join "`n") | Should -Match 'Winget-AutoUpdate setup failed unexpectedly: boom from WAU'
            ($script:errorMessages -join "`n") | Should -Match 'Auto-updates: FAILED'
            Should -Invoke Write-Table -Times 1 -Exactly
        }

        It 'Treats a throwing end-of-run probe as unknown, not as a broken winget' {
            Mock Wait-WingetLaunchable { throw 'boom from the probe' }

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive | Should -Be 0

            ($script:errorMessages -join "`n") | Should -Not -Match 'winget: NOT USABLE'
        }

        It 'Waits for a running Winget-AutoUpdate before the first winget call of a real run' {
            Mock Wait-WauIdle { $script:callOrder.Add('wau-idle'); $true }
            Mock Test-AndInstallWinget { $script:callOrder.Add('winget-check'); $true }

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive

            $script:callOrder[0] | Should -Be 'wau-idle'
            $script:callOrder[1] | Should -Be 'winget-check'
        }

        It 'Does not wait for Winget-AutoUpdate in a dry run' {
            Mock Install-AppWithVerification { @{ Status = 'Installed'; InstallResult = $null; FailureReason = $null } }

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -WhatIf -NonInteractive

            Should -Invoke Wait-WauIdle -Times 0 -Exactly
        }

        It 'Prints Auto-updates: NOT CONFIGURED when WAU was skipped for a missing framework' {
            Mock Install-WingetAutoUpdate { [pscustomobject]@{ Status = 'FrameworkMissing'; Version = '2.12.0'; FrameworkMissing = $true } }

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive

            ($script:errorMessages -join "`n") | Should -Match 'Auto-updates: NOT CONFIGURED'
        }

        It 'Prints Auto-updates: AT RISK when an existing WAU sits on a machine without the framework' {
            Mock Install-WingetAutoUpdate { [pscustomobject]@{ Status = 'AlreadyPresent'; Version = [version]'2.12.0'; FrameworkMissing = $true } }

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive

            ($script:errorMessages -join "`n") | Should -Match 'Auto-updates: AT RISK'
        }
    }

    Context 'Deadlocked DesktopAppInstaller versions (issue #279)' {
        It 'Runs the normal per-app pipeline when no conflict is present' {
            Mock Get-ConflictingDesktopAppInstallerVersions { @() }

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -WhatIf -NonInteractive

            Should -Invoke Install-AppWithVerification -Times 1 -Exactly
        }

        It 'Marks every app failed without attempting an install when a version conflict is present upfront' {
            Mock Get-ConflictingDesktopAppInstallerVersions { @('1.26.510.0', '1.29.290.0') }

            $result = Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }, @{ name = 'Contoso.AppTwo' }) -NonInteractive

            $result | Should -Be 1
            Should -Invoke Install-AppWithVerification -Times 0 -Exactly
            $failedRows = @($script:capturedTables['Failed Installations'])
            $failedRows.Count | Should -Be 2
            $failedRows[0][0] | Should -Be 'Contoso.AppOne'
            $failedRows[0][1] | Should -Be 'winget deadlocked between conflicting DesktopAppInstaller versions (1.26.510.0, 1.29.290.0); see issue #279'
        }

        It 'Skips the retry pass when the conflict was detected upfront' {
            Mock Get-ConflictingDesktopAppInstallerVersions { @('1.26.510.0', '1.29.290.0') }

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive | Should -Be 1

            ($script:warningMessages -join "`n") | Should -Match 'Skipping the retry pass'
            $script:infoMessages | Should -Not -Contain 'Retrying failed installations (1 final attempt)...'
            Should -Invoke Install-AppWithVerification -Times 0 -Exactly
        }
    }

    # Elevated through the Test-IsAdmin mock in BeforeEach; these were skipped on any runner that
    # was not itself elevated (wgt-gq8.6).
    Context 'Unattended installs (winget --silent)' {
        It 'Asks both install passes for --silent when the run is non-interactive' {
            $script:passCalls = 0
            Mock Install-AppWithVerification {
                $script:passCalls++
                if ($script:passCalls -eq 1) {
                    return @{ Status = 'Failed'; InstallResult = @{ ExitCode = 1 }; FailureReason = 'VerifyNotFound' }
                }
                @{ Status = 'Installed'; InstallResult = @{ ExitCode = 0 }; FailureReason = $null }
            }

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive | Should -Be 0

            Should -Invoke Install-AppWithVerification -Times 2 -Exactly -ParameterFilter { [bool]$Silent }
        }
    }

    Context 'Retry pass' {
        It 'Sends a first-pass failure back through the helper and buckets a recovered app as installed' {
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

            Invoke-WingetInstall -NonInteractive | Should -Be 0

            # First pass failed 7zip, the retry pass re-drove it through the helper and recovered.
            $script:sevenZipCalls | Should -Be 2
            $installedRow = @($script:capturedRows | Where-Object { $_[0] -eq 'Installed' })[0]
            $installedRow[1] | Should -Match '7zip\.7zip'
            @($script:capturedRows | Where-Object { $_[0] -eq 'Failed' }).Count | Should -Be 0
        }

        It 'Surfaces the winget exit code, attempts, and scope fallback in the failure message (issue #189)' {
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

            Invoke-WingetInstall -NonInteractive

            $failureMessage = @($script:errorMessages | Where-Object { $_ -match 'Failed to install' })[0]
            $failureMessage | Should -Match '7zip\.7zip'
            $failureMessage | Should -Match 'winget exit 0x80073D19'
            $failureMessage | Should -Match '3 attempts'
            $failureMessage | Should -Match 'machine-scope fallback: yes'
        }

        # The retry-failure messages (issue #237): the switch's selection (PreCheckTimeout vs
        # VerifyTimeout vs everything else) is what #237 fixed. A retry that stays failed returns 1.
        It 'Names the pre-check phase (not verification) when a retry fails with PreCheckTimeout (issue #237)' {
            Mock Install-AppWithVerification { @{ Status = 'Failed'; InstallResult = $null; FailureReason = 'PreCheckTimeout' } }

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive | Should -Be 1

            $script:warningMessages | Should -Contain 'Winget list timed out for retry: Contoso.AppOne. Assuming installation failed.'
            ($script:warningMessages -join "`n") | Should -Not -Match 'Verification timed out for retry'
        }

        It 'Keeps the verification-timeout wording when a retry fails with VerifyTimeout (issue #237)' {
            Mock Install-AppWithVerification { @{ Status = 'Failed'; InstallResult = @{ ExitCode = 0 }; FailureReason = 'VerifyTimeout' } }

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive | Should -Be 1

            $script:warningMessages | Should -Contain 'Verification timed out for retry: Contoso.AppOne. Assuming installation failed.'
        }

        It 'Reports any other retry failure with its formatted reason (issue #237)' {
            Mock Install-AppWithVerification { @{ Status = 'Failed'; InstallResult = @{ ExitCode = 1; Attempts = 1 }; FailureReason = 'VerifyNotFound' } }

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive | Should -Be 1

            $script:errorMessages | Should -Contain 'Retry failed: Contoso.AppOne (package not found after install; winget exit 0x00000001, 1 attempt).'
        }

        It 'Counts an unexpected error in the retry pass as a failure instead of aborting the run' {
            $script:appCalls = 0
            Mock Install-AppWithVerification {
                $script:appCalls++
                if ($script:appCalls -eq 1) {
                    return @{ Status = 'Failed'; InstallResult = @{ ExitCode = 1 }; FailureReason = 'VerifyNotFound' }
                }
                throw 'boom in the retry'
            }

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive | Should -Be 1

            ($script:errorMessages -join "`n") | Should -Match 'Retry failed: Contoso.AppOne. Error: boom in the retry'
            @($script:capturedTables['Failed Installations'])[0][1] | Should -Be 'Unexpected error: boom in the retry'
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

    It 'Forwards -Silent (<Value>) to Install-WingetPackage, for winget --silent, and leaves it out when not given' -ForEach @(
        @{ Value = $true }
        @{ Value = $false }
    ) {
        [void](Install-AppWithVerification -App @{ name = 'Given.App' } -Silent:$Value)
        # Not given: Install-WingetPackage decides itself (Test-EffectiveNonInteractive).
        [void](Install-AppWithVerification -App @{ name = 'NotGiven.App' })

        $script:expectedSilent = $Value
        Should -Invoke Install-WingetPackage -Times 1 -Exactly -ParameterFilter { $PackageId -eq 'Given.App' -and $PesterBoundParameters.ContainsKey('Silent') -and [bool]$Silent -eq $script:expectedSilent }
        Should -Invoke Install-WingetPackage -Times 1 -Exactly -ParameterFilter { $PackageId -eq 'NotGiven.App' -and -not $PesterBoundParameters.ContainsKey('Silent') }
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
        # Not the runner's real elevation: the run must take the same path on every machine.
        Mock Test-IsAdmin { $true }
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
        # Unmocked, this reads the real machine's AppX packages (issue #279 conflict check).
        Mock Get-ConflictingDesktopAppInstallerVersions { @() }

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

# P2-16: the dry run promised 'No system changes will be made' but its setup helpers ran their real
# remediation - the NuGet provider and two PSGallery modules installed for all users, App Installer
# registered, repaired or downloaded, and `winget source reset --force` - because every dry-run test
# mocked those helpers away. Here they all run for real (Test-AndInstallWingetModule,
# Test-AndInstallWinget with Register-WingetAppInstallerForUser and Invoke-WingetPackageManagerRepair
# behind it, Initialize-WingetSourcesForUser, Test-AndInstallGraphicalTools, Test-WingetSources,
# Install-AppWithVerification and the rest), on a machine where each of them has something to fix.
# Only the commands that read or change the machine are mocked: the read-only probes describe that
# machine, and every command that would change it is asserted never to run.
Describe 'Dry run leaves the machine unchanged (P2-16)' {
    BeforeEach {
        Mock Write-Host { }
        Mock Write-Warning { }
        Mock Start-Sleep { }
        Mock Test-IsRunningLocally { $true }
        Mock Restart-WithElevation { 'PowerShell' }
        Mock Write-Table { }
        $script:infoMessages = @()
        Mock Write-Info { $script:infoMessages += $Message }
        $script:warningMessages = @()
        Mock Write-WarningMessage { $script:warningMessages += $Message }
        $script:errorMessages = @()
        Mock Write-ErrorMessage { $script:errorMessages += $Message }

        # Read-only probes. No PowerShell module or NuGet provider installed; App Installer staged
        # on the machine but not registered for this account (the cross-user elevation case), so
        # the old code's first bootstrap rung had something to register.
        Mock Get-Module { $null }
        Mock Get-PackageProvider { $null }
        Mock Get-AppxPackage { @() }
        Mock Get-AppxPackage { [pscustomobject]@{ Name = 'Microsoft.DesktopAppInstaller'; Version = '1.26.510.0'; InstallLocation = $null } } -ParameterFilter { $Name -eq 'Microsoft.DesktopAppInstaller' }
        Mock Get-CimInstance { $null }
        # The legacy scheduled task, its data directory and WAU's task all "exist", so their
        # helpers reach the branch that would remove or change them.
        Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = 'present' } }
        Mock Test-Path { $false }
        Mock Test-Path { $true } -ParameterFilter { "$Path" -like '*winget-app-setup' }
        # Every winget or msiexec process goes through Invoke-ExternalProcess (review findings
        # P2-5, P2-6). The per-app `winget list` check exits 0 without listing anything (not
        # installed). Start-Process stays mocked so any other process start is visible.
        Mock Invoke-ExternalProcess { New-TestProcessResult -ExitCode 0 }
        Mock Start-Process { }

        # Commands that change the machine: none of these may run in a dry run.
        Mock Install-PackageProvider { }
        Mock Install-Module { }
        Mock Import-Module { }
        Mock Repair-WinGetPackageManager { }
        Mock Add-AppxPackage { }
        Mock Invoke-WebRequest { }
        Mock Invoke-RestMethod { }
        Mock Set-ItemProperty { }
        Mock New-ItemProperty { }
        Mock New-Item { }
        Mock Set-Content { }
        Mock Remove-Item { }
        Mock Unregister-ScheduledTask { }
        Mock Set-ScheduledTask { }
        Mock winget { $global:LASTEXITCODE = 0 }

        # Last: mocking Get-Command breaks the command lookup that Mock itself relies on for the
        # targets above (see TestHelpers.ps1). Nothing is available by default: no winget, no
        # Out-GridView, no Repair-WinGetPackageManager.
        Mock Get-Command { $null }
    }

    It 'Changes nothing on a machine where every setup helper has something to fix (<Case>)' -ForEach @(
        @{ Case = 'non-admin preview'; IsAdmin = $false }
        @{ Case = 'elevated preview'; IsAdmin = $true }
    ) {
        $script:previewIsAdmin = $IsAdmin
        Mock Test-IsAdmin { $script:previewIsAdmin }

        $result = Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -WhatIf -NonInteractive

        Should -Invoke Install-PackageProvider -Times 0 -Exactly
        Should -Invoke Install-Module -Times 0 -Exactly
        Should -Invoke Repair-WinGetPackageManager -Times 0 -Exactly
        Should -Invoke Add-AppxPackage -Times 0 -Exactly
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
        Should -Invoke Set-ItemProperty -Times 0 -Exactly
        Should -Invoke New-ItemProperty -Times 0 -Exactly
        Should -Invoke New-Item -Times 0 -Exactly
        Should -Invoke Set-Content -Times 0 -Exactly
        Should -Invoke Remove-Item -Times 0 -Exactly -ParameterFilter { [bool]$Recurse }
        Should -Invoke Unregister-ScheduledTask -Times 0 -Exactly
        Should -Invoke Set-ScheduledTask -Times 0 -Exactly
        Should -Invoke Restart-WithElevation -Times 0 -Exactly
        Should -Invoke winget -Times 0 -Exactly
        # The only process a dry run starts is the per-app `winget list` check: no installer, no
        # msiexec, no `winget source update/reset`.
        Should -Invoke Start-Process -Times 0 -Exactly
        Should -Invoke Invoke-ExternalProcess -Times 0 -Exactly -ParameterFilter { $FilePath -notmatch 'winget' -or $ArgumentList[0] -ne 'list' }
        Should -Invoke Invoke-ExternalProcess -Times 1 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'list' -and $ArgumentList -contains 'Contoso.AppOne' }

        # The preview carried on to the summary and says what a real run would have done.
        $result | Should -Be 0
        ($script:infoMessages -join "`n") | Should -Match '\[DRY-RUN\] Would remove the legacy update data directory'
        Should -Invoke Write-Table -Times 1 -Exactly -ParameterFilter { $Title -eq 'Installation Summary' }
        $dryRunLines = ($script:infoMessages | Where-Object { $_ -match '^\[DRY-RUN\]' }) -join "`n"
        $dryRunLines | Should -Match 'Microsoft\.WinGet\.Client module not found\. A real run would install it'
        $dryRunLines | Should -Match 'Winget is not available for this account\. A real run would bootstrap it'
        $dryRunLines | Should -Match 'Out-GridView is not available\. A real run would install Microsoft\.PowerShell\.GraphicalTools'
        $dryRunLines | Should -Match 'Skipping the winget source check: winget is not available for this account yet'
        $dryRunLines | Should -Match 'this preview cannot tell which apps are already installed'
        $dryRunLines | Should -Match 'Would install: Contoso\.AppOne'
        $script:errorMessages | Should -Not -Contain 'Winget is required for this script. Exiting.'
    }

    It 'Reports a broken winget source instead of resetting it when winget is present' {
        Mock Test-IsAdmin { $true }
        Mock Get-Command { [pscustomobject]@{ Name = 'winget.exe' } } -ParameterFilter { $Name -eq 'winget' }
        # The winget mock below scripts each winget command.
        Mock Invoke-WingetProcess { Invoke-TestWingetMock -ArgumentList $ArgumentList }
        Mock winget {
            if ($args[0] -eq 'source' -and $args[1] -eq 'list') {
                $global:LASTEXITCODE = 0
                return 'winget      https://cdn.winget.microsoft.com/cache'
            }
            if ($args[0] -eq 'search') {
                $global:LASTEXITCODE = -1978335217
                return 'Failed when opening source(s); try the source reset command if the problem persists. 0x8a15000f'
            }
            $global:LASTEXITCODE = 0
        }

        $result = Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -WhatIf -NonInteractive

        # Only the read-only health probe ran: `winget source list` and `winget search`.
        Should -Invoke winget -Times 0 -Exactly -ParameterFilter { $args[0] -notin @('list', 'search') -and -not ($args[0] -eq 'source' -and $args[1] -eq 'list') }
        Should -Invoke winget -Times 1 -Exactly -ParameterFilter { $args[0] -eq 'search' }
        Should -Invoke Add-AppxPackage -Times 0 -Exactly
        Should -Invoke Repair-WinGetPackageManager -Times 0 -Exactly
        Should -Invoke Start-Process -Times 0 -Exactly
        Should -Invoke Invoke-ExternalProcess -Times 0 -Exactly

        $result | Should -Be 0
        ($script:infoMessages -join "`n") | Should -Match '\[DRY-RUN\] Winget source data is corrupted\. A real run would repair it: winget source reset --force'
        $script:warningMessages | Should -Not -Contain 'Winget sources could not be repaired. Some installations may fail.'
    }
}

Describe 'Write-InstallerExitNotice (review findings P2-14 and P3-15)' {
    # What Exit-Installer prints before an early exit. Under irm | iex the exit closes the window, so
    # this block is all the teammate who files the GitHub issue gets to see.
    BeforeEach {
        $script:noticeLines = @()
        Mock Write-ErrorMessage { $script:noticeLines += "ERROR: $Message" }
        Mock Write-WarningMessage { $script:noticeLines += "WARN: $Message" }
        Mock Write-Info { $script:noticeLines += "INFO: $Message" }
        Mock Write-Host { }
        # Throws so a test can never reach [Console]::ReadKey, which would block the suite.
        Mock Write-Prompt { throw 'waited for a key press' }
        Mock Test-EffectiveNonInteractive { $true }
        Mock Test-IsContinuousIntegration { $false }
        $script:savedLogPath = $script:InstallLogPath
        $script:savedBuildId = $script:InstallerBuildId
        $script:InstallLogPath = 'C:\ProgramData\winget-app-setup\logs\install-20261004-101500.log'
        $script:InstallerBuildId = '1.0.0+0badc0de'
    }

    AfterEach {
        $script:InstallLogPath = $script:savedLogPath
        $script:InstallerBuildId = $script:savedBuildId
    }

    It 'Prints the exit code with the reason, the log file and the build' {
        Write-InstallerExitNotice -Code 1 -Reason 'a blocking pre-flight system check failed (see above)'

        $script:noticeLines | Should -Contain 'ERROR: The installer stopped early with exit code 1: a blocking pre-flight system check failed (see above).'
        $script:noticeLines | Should -Contain 'INFO: Log file: C:\ProgramData\winget-app-setup\logs\install-20261004-101500.log'
        $script:noticeLines | Should -Contain 'INFO: Installer build: 1.0.0+0badc0de'
    }

    It 'Says where to report it, with the privacy note for the public repository' {
        Write-InstallerExitNotice -Code 1

        ($script:noticeLines -join "`n") | Should -Match ([regex]::Escape('https://github.com/J-MaFf/winget-app-setup/issues/new?template=install-failure.yml'))
        ($script:noticeLines -join "`n") | Should -Match 'WARN: That repository is public, and the log names this computer and the accounts'
    }

    It 'Says what exit code <Code> means when the caller gives no reason' -ForEach @(
        @{ Code = 1; Meaning = 'administrator rights were not available or a pre-flight check failed (see above)' }
        @{ Code = 2; Meaning = 'winget is not available or could not be started (see above)' }
        @{ Code = 3; Meaning = 'the app catalog failed validation (see above)' }
        @{ Code = 5; Meaning = 'the run was aborted before it finished (see above)' }
        @{ Code = 7; Meaning = 'PowerShell 7 could not be installed, or the installer could not be relaunched under it (see above)' }
    ) {
        Write-InstallerExitNotice -Code $Code

        $script:noticeLines | Should -Contain ('ERROR: The installer stopped early with exit code {0}: {1}.' -f $Code, $Meaning)
    }

    It 'Prints the code alone when it has no known meaning and no reason' {
        Write-InstallerExitNotice -Code 64

        $script:noticeLines | Should -Contain 'ERROR: The installer stopped early with exit code 64.'
    }

    It 'Says that there is no log file when the transcript could not be started' {
        $script:InstallLogPath = $null

        Write-InstallerExitNotice -Code 3

        ($script:noticeLines -join "`n") | Should -Match 'WARN: Log file: none'
    }

    It 'Waits for a key press when someone is at the console' {
        Mock Test-EffectiveNonInteractive { $false }

        { Write-InstallerExitNotice -Code 2 } | Should -Throw 'waited for a key press'
        Should -Invoke Write-Prompt -Times 1 -Exactly -ParameterFilter { $Message -eq 'Press any key to exit...' }
    }

    It 'Never waits in a non-interactive run (RMM, scheduled task, -NonInteractive)' {
        Write-InstallerExitNotice -Code 2 -NonInteractive

        Should -Invoke Test-EffectiveNonInteractive -Times 1 -Exactly -ParameterFilter { $NonInteractive }
        Should -Invoke Write-Prompt -Times 0 -Exactly
    }

    It 'Never waits under CI, even when the console looks interactive' {
        Mock Test-EffectiveNonInteractive { $false }
        Mock Test-IsContinuousIntegration { $true }

        Write-InstallerExitNotice -Code 2

        Should -Invoke Write-Prompt -Times 0 -Exactly
    }

    It 'Never waits with -NoPause (the console stays open anyway)' {
        Mock Test-EffectiveNonInteractive { $false }

        Write-InstallerExitNotice -Code 5 -NoPause

        Should -Invoke Write-Prompt -Times 0 -Exactly
        ($script:noticeLines -join "`n") | Should -Match 'stopped early with exit code 5'
    }
}

Describe 'Get-InstallerExitCode' {
    It 'Returns 0 when no app failed and winget is still usable' {
        Get-InstallerExitCode -FailedAppCount 0 -WingetUsable $true | Should -Be 0
    }

    It 'Returns 2 when no app failed but winget can no longer be launched (never exit 0 with winget broken)' {
        Get-InstallerExitCode -FailedAppCount 0 -WingetUsable $false | Should -Be 2
    }

    It 'Returns 1 when apps failed, whatever the winget check says (failed apps take precedence)' {
        Get-InstallerExitCode -FailedAppCount 3 -WingetUsable $true | Should -Be 1
        Get-InstallerExitCode -FailedAppCount 1 -WingetUsable $false | Should -Be 1
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

        It 'Says the install ran out of time, without a fabricated exit code (review finding P2-5)' {
            $installResult = @{ ExitCode = $null; Attempts = 1; SessionErrorExhausted = $false; MachineScopeFellBack = $false; TimedOut = $true; TimeoutSeconds = 1800 }

            $reason = Format-InstallFailureReason -FailureReason 'VerifyNotFound' -InstallResult $installResult

            $reason | Should -Be 'package not found after install; 1 attempt, machine-scope fallback: no, winget install stopped after 30 minutes'
        }

        It 'Names the installer''s log (review finding P2-6)' {
            $installResult = @{ ExitCode = -1978335226; Attempts = 1; SessionErrorExhausted = $false; MachineScopeFellBack = $false; TimedOut = $false; InstallerLogPath = 'C:\ProgramData\winget-app-setup\logs\winget-install-Test.App-20261004-101500.log' }

            $reason = Format-InstallFailureReason -FailureReason 'VerifyNotFound' -InstallResult $installResult

            $reason | Should -Be 'package not found after install; winget exit 0x8A150006, 1 attempt, machine-scope fallback: no, installer log: C:\ProgramData\winget-app-setup\logs\winget-install-Test.App-20261004-101500.log'
        }

        It 'Calls out an exhausted transient launch failure without a fabricated exit code (issue #253)' {
            $installResult = @{ ExitCode = $null; Attempts = 3; SessionErrorExhausted = $false; MachineScopeFellBack = $false; LaunchErrorExhausted = $true }

            $reason = Format-InstallFailureReason -FailureReason 'VerifyNotFound' -InstallResult $installResult

            $reason | Should -Not -Match 'winget exit'
            $reason | Should -Match '3 attempts'
            $reason | Should -Match 'winget executable was transiently inaccessible through every retry'
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
