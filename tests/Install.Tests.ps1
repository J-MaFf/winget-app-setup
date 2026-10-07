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
    # in issue #177: the winget source is updated, and repaired if needed, by Initialize-Winget before this point.

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
        Mock Restart-WithElevation { [pscustomobject]@{ Started = $true; ExitCode = 0 } }
        Mock Test-IsRunningLocally { $true }
        Mock Initialize-Winget { [pscustomobject]@{ Ready = $true; Diagnosis = 'Ok' } }
        Mock Remove-LegacyScheduledUpdates { $true }
        Mock Set-WindowsTerminalDefaults { }
        Mock Install-WingetAutoUpdate { @{ Status = 'DryRun'; Version = '2.12.0' } }
        Mock Install-AppWithVerification { @{ Status = 'Installed'; InstallResult = $null; FailureReason = $null } }
        # Every app applies. The run decides applicability itself, before the first pass, so with
        # the default catalog the real conditions would read this machine (Win32_ComputerSystem,
        # the default-terminal registry values, the process ancestry, Get-AppxPackage); their
        # wiring is tested in 'Applicability is decided once per run' and AppCatalog.Tests.ps1.
        Mock Test-AppApplicability { $true }
        # The end-of-run winget check and the circuit breaker launch real winget; healthy by default
        # so a real (non -WhatIf) run in these tests never probes the machine.
        Mock Test-WingetLaunchable { [pscustomobject]@{ Launchable = $true; Version = 'v1.12.350'; Reason = $null; Attempts = 1 } }
        # Never wait on (or query) the machine's real Winget-AutoUpdate tasks.
        Mock Wait-WauIdle { $true }
        # Never read the machine's pending-restart state (review finding P3-16): nothing pending.
        Mock Get-PendingRestartState { New-TestRestartState }
        # The environment pre-flight (wgt-gq8.39) reads neither the runner's registry nor its
        # proxy settings: no Group Policy, and no proxy to report.
        Mock Get-ProxyInheritanceWarning { $null }
        Mock Get-ScriptExecutionPolicyBlock { $null }
        Mock Get-WingetPolicyBlock { $null }
        # Never read the runner's real account or console session: a same-user run unless a test
        # says otherwise (review findings P2-24, P3-22).
        Mock Get-InstallAccountContext { New-TestAccountContext }

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
    }

    Context 'Exit-code contract (returned to the entry script, which exits with it)' {
        It 'Returns 0, and nothing else, when every app installs and winget still launches at the end' {
            $result = Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive

            # Exactly one [int]: the entry script exits with the last value the function writes, so
            # a stray value in the output stream must never be the only thing it sees.
            @($result).Count | Should -Be 1
            $result | Should -BeOfType [int]
            $result | Should -Be 0
            Should -Invoke Test-WingetLaunchable -Times 1 -Exactly
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
            Mock Test-WingetLaunchable { [pscustomobject]@{ Launchable = $false; Version = $null; Reason = 'winget could not be started: Access is denied'; Attempts = 5 } }

            $result = Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive

            $result | Should -Be 2
            # With the check's reason: 'Access is denied' is final at once, so no retry warning
            # names it and there is no winget output to show (review of item 9).
            $script:errorMessages | Should -Contain 'winget: NOT USABLE - winget did not work at the end of this run (winget could not be started: Access is denied), so automatic updates and the next run of this installer will fail on this machine. Restart the machine and re-run the installer; if it persists, attach this transcript to a GitHub issue.'
            # The summary still prints: a broken winget is reported, not a reason to stop early.
            Should -Invoke Write-Table -Times 1 -Exactly -ParameterFilter { $Title -eq 'Installation Summary' }
        }

        It 'Returns 1, not 2, when apps failed and the end-of-run probe failed too (failed apps take precedence)' {
            Mock Install-AppWithVerification { @{ Status = 'Failed'; InstallResult = @{ ExitCode = 1 }; FailureReason = 'VerifyNotFound' } }
            Mock Test-WingetLaunchable { [pscustomobject]@{ Launchable = $false; Version = $null; Reason = 'winget could not be started: Access is denied'; Attempts = 5 } }

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive | Should -Be 1
        }

        It 'Returns 2 without installing anything when winget is unavailable and cannot be installed' {
            Mock Initialize-Winget { [pscustomobject]@{ Ready = $false; Diagnosis = 'NotLaunchable' } }

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

        # Review finding P3-36: an RMM job reads only the exit code, and this used to be 0, so a
        # machine that would never update was reported as a success.
        It 'Returns 8 when the apps installed but Winget-AutoUpdate could not be configured (review finding P3-36)' {
            Mock Install-WingetAutoUpdate { [pscustomobject]@{ Status = 'Failed'; Version = $null } }

            $result = Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive

            @($result).Count | Should -Be 1
            $result | Should -Be 8
            ($script:errorMessages -join "`n") | Should -Match 'Auto-updates: FAILED'
        }

        It 'Returns 8 for every auto-update outcome printed as an error: <Status>' -ForEach @(
            @{ Status = 'FrameworkMissing'; FrameworkMissing = $true; Line = 'Auto-updates: NOT CONFIGURED - Microsoft.WindowsAppRuntime.1.8 is missing' }
            @{ Status = 'AlreadyPresent'; FrameworkMissing = $true; Line = 'Auto-updates: AT RISK - ' }
            @{ Status = 'Unhealthy'; FrameworkMissing = $false; Line = 'Auto-updates: UNHEALTHY - Winget-AutoUpdate is installed, but its scheduled task \WAU\Winget-AutoUpdate is disabled; apps will not update automatically (see above).' }
        ) {
            $script:wauResult = [pscustomobject]@{ Status = $Status; Version = [version]'2.12.0'; FrameworkMissing = $FrameworkMissing; RestartRequired = $false; Problem = 'its scheduled task \WAU\Winget-AutoUpdate is disabled' }
            Mock Install-WingetAutoUpdate { $script:wauResult }

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive | Should -Be 8

            @($script:errorMessages | Where-Object { $_.StartsWith($Line) }).Count | Should -Be 1
        }

        # Work-order item 32: the framework the latest winget release needs, which may not be 1.8.
        It 'Names the framework the latest winget release needs in the summary and returns 8: <Status>' -ForEach @(
            @{ Status = 'FrameworkMissing'; Line = 'Auto-updates: NOT CONFIGURED - Microsoft.WindowsAppRuntime.2 is missing, and Winget-AutoUpdate would leave winget unusable without it. Install the Windows App Runtime 2 (or let the Microsoft Store update App Installer), then re-run the installer.' }
            @{ Status = 'AlreadyPresent'; Line = 'Auto-updates: AT RISK - Winget-AutoUpdate is installed but Microsoft.WindowsAppRuntime.2 is missing; its next run may leave winget unusable (see above).' }
        ) {
            $script:wauResult = [pscustomobject]@{ Status = $Status; Version = [version]'2.12.0'; FrameworkMissing = $true; FrameworkName = 'Microsoft.WindowsAppRuntime.2'; FrameworkInstallError = 'the latest winget release needs Microsoft.WindowsAppRuntime.2 >= 2000.120.5.0, and the framework this installer installs, Microsoft.WindowsAppRuntime.1.8 8000.994.2142.0, does not meet that; a newer version of this installer is needed'; RestartRequired = $false }
            Mock Install-WingetAutoUpdate { $script:wauResult }

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive | Should -Be 8

            $script:errorMessages | Should -Contain $Line
            $script:errorMessages | Should -Contain "  The installer could not install it: $($script:wauResult.FrameworkInstallError)."
        }

        It 'Still names Microsoft.WindowsAppRuntime.1.8 for a result that names no framework' {
            Mock Install-WingetAutoUpdate { [pscustomobject]@{ Status = 'FrameworkMissing'; Version = [version]'2.12.0'; FrameworkMissing = $true; RestartRequired = $false } }

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive | Should -Be 8

            $script:errorMessages | Should -Contain 'Auto-updates: NOT CONFIGURED - Microsoft.WindowsAppRuntime.1.8 is missing, and Winget-AutoUpdate would leave winget unusable without it. Install the Windows App Runtime 1.8 (or let the Microsoft Store update App Installer), then re-run the installer.'
        }

        # Review of item 23: a task that could not be checked is an unknown state, not a known bad
        # one. Still 8 (auto-updates not verified), but the line must not claim apps will not update.
        It 'Returns 8 when the Winget-AutoUpdate task could not be checked, and says the outcome is unknown' {
            Mock Install-WingetAutoUpdate { [pscustomobject]@{ Status = 'Unhealthy'; Version = [version]'2.12.0'; FrameworkMissing = $false; RestartRequired = $false; Problem = 'its scheduled task \WAU\Winget-AutoUpdate could not be checked (Access is denied.)'; CheckFailed = $true } }

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive | Should -Be 8

            $script:errorMessages | Should -Contain 'Auto-updates: UNHEALTHY - Winget-AutoUpdate is installed, but its scheduled task \WAU\Winget-AutoUpdate could not be checked (Access is denied.); it is not known whether apps will update automatically (see above).'
            ($script:errorMessages -join "`n") | Should -Not -Match 'apps will not update automatically'
        }

        It 'Returns 0 when Winget-AutoUpdate is <Status> and its task will run' -ForEach @(
            @{ Status = 'Configured' }
            @{ Status = 'AlreadyPresent' }
        ) {
            $script:wauResult = [pscustomobject]@{ Status = $Status; Version = [version]'2.12.0'; FrameworkMissing = $false; RestartRequired = $false }
            Mock Install-WingetAutoUpdate { $script:wauResult }

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive | Should -Be 0

            ($script:errorMessages -join "`n") | Should -Not -Match 'Auto-updates:'
        }

        It 'Ranks failed apps (1) and an unusable winget (2) above auto-updates (8), and 8 above a needed restart (3010)' {
            Mock Install-WingetAutoUpdate { [pscustomobject]@{ Status = 'FrameworkMissing'; Version = '2.12.0'; FrameworkMissing = $true; RestartRequired = $false } }
            Mock Install-AppWithVerification { @{ Status = 'Failed'; InstallResult = @{ ExitCode = 1; Attempts = 1 }; FailureReason = 'VerifyNotFound' } }
            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive | Should -Be 1

            Mock Install-AppWithVerification { @{ Status = 'Installed'; InstallResult = @{ ExitCode = 0; Attempts = 1; RestartRequired = $true }; FailureReason = $null } }
            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive | Should -Be 8

            Mock Test-WingetLaunchable { [pscustomobject]@{ Launchable = $false; Version = $null; Reason = 'winget could not be started: Access is denied'; Attempts = 5 } }
            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive | Should -Be 2
        }

        It 'Returns the dry run''s outcome too, without probing winget at the end' {
            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -WhatIf -NonInteractive | Should -Be 0
            Should -Invoke Test-WingetLaunchable -Times 0 -Exactly
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
        # Review findings P2-11, P2-12 and P3-11: a run that is not elevated relaunches itself
        # elevated only when someone is at the console, waits for that run and returns its exit
        # code; every other run that needs administrator rights returns 4.
        BeforeEach {
            Mock Test-IsAdmin { $false }
            # No winget call before elevating (review finding P3-25): the elevated run sets winget up
            # for the account it runs as.
            Mock Invoke-WingetProcess { throw "no winget call before elevating: $($ArgumentList -join ' ')" }
            # A run from the generated installer file, not from the imported module (issue #185).
            Mock Test-InvokedFromModuleContext { $false }
            # Interactive unless the test passes -NonInteractive; never the runner's real console.
            Mock Test-EffectiveNonInteractive { [bool]$NonInteractive }
            $script:InstallerPendingExitCode = $null
            $script:InstallerScriptSha256 = 'C0FFEE' + ('0' * 58)
        }

        AfterEach {
            $script:InstallerPendingExitCode = $null
            $script:InstallerScriptSha256 = $null
        }

        It 'Relaunches elevated, waits for that run and returns its exit code <_> without installing anything here' -ForEach @(0, 1, 2, 3010) {
            $script:elevatedExitCode = $_
            Mock Restart-WithElevation { [pscustomobject]@{ Started = $true; ExitCode = $script:elevatedExitCode } }

            $result = Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -SkipSystemCheck

            $result | Should -Be $_
            Should -Invoke Restart-WithElevation -Times 1 -Exactly -ParameterFilter {
                ($AdditionalArguments -contains '-SkipSystemCheck') -and -not ($AdditionalArguments -contains '-WhatIf') -and
                -not ($AdditionalArguments -contains '-NonInteractive') -and
                # The SHA256 the entry script took at startup, so a file changed since then is not run.
                ($ExpectedSha256 -eq $script:InstallerScriptSha256)
            }
            # The elevated window showed the outcome and its own key press: the entry script adds
            # no second notice.
            $script:InstallerPendingExitCode | Should -Be $_
            Should -Invoke Invoke-WingetProcess -Times 0 -Exactly
            Should -Invoke Initialize-Winget -Times 0 -Exactly
            Should -Invoke Install-AppWithVerification -Times 0 -Exactly
        }

        It 'Returns 4 without a UAC prompt or any winget call when the run is non-interactive' {
            $result = Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive -SkipSystemCheck

            $result | Should -Be 4
            Should -Invoke Restart-WithElevation -Times 0 -Exactly
            Should -Invoke Invoke-WingetProcess -Times 0 -Exactly
            Should -Invoke Install-AppWithVerification -Times 0 -Exactly
            ($script:errorMessages -join "`n") | Should -Match 'this run is non-interactive, so there is nobody to approve a UAC prompt and none was shown'
        }

        It 'Returns 4 and says so when the elevation is declined or fails' {
            Mock Restart-WithElevation { [pscustomobject]@{ Started = $false; ExitCode = 4 } }

            $result = Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' })

            $result | Should -Be 4
            # Restart-WithElevation has already said why and what to do; this only adds the result.
            $script:errorMessages | Should -Contain 'No elevated run was started, so nothing was installed.'
            # Nothing showed an outcome yet, so the entry script explains the exit.
            $script:InstallerPendingExitCode | Should -BeNullOrEmpty
            Should -Invoke Install-AppWithVerification -Times 0 -Exactly
        }

        It 'Returns the code Restart-WithElevation gives when it starts nothing (the file changed: 5)' {
            Mock Restart-WithElevation { [pscustomobject]@{ Started = $false; ExitCode = 5 } }

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) | Should -Be 5
            # No prompt was shown, so there is none to approve.
            ($script:errorMessages -join "`n") | Should -Not -Match 'approve|declined'
        }

        It 'Returns 4 with the remote elevation guidance under irm | iex, where it cannot relaunch (issues #226/#229)' {
            Mock Test-IsRunningLocally { $false }

            $result = Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' })

            $result | Should -Be 4
            $script:errorMessages | Should -Contain 'This script requires administrator privileges.'
            $script:errorMessages | Should -Contain 'Auto-elevation is unavailable when running through IEX/remote execution.'
            $script:infoMessages | Should -Contain 'Open an elevated PowerShell or Windows Terminal session and run the IEX command again.'
            # No "press Enter to restart" pause any more (issue #230), and no 5-second sleep either:
            # the entry script's Exit-Installer holds the window when someone is there (P2-14).
            (@($script:errorMessages) + @($script:infoMessages)) -join "`n" | Should -Not -Match 'Press Enter|Exiting in 5 seconds'
            Should -Invoke Start-Sleep -Times 0 -Exactly -ParameterFilter { $Seconds -eq 5 }
            Should -Invoke Restart-WithElevation -Times 0 -Exactly
            Should -Invoke Invoke-WingetProcess -Times 0 -Exactly
            Should -Invoke Install-AppWithVerification -Times 0 -Exactly
        }

        It 'A non-interactive dry run previews the stop with exit code 4 without doing anything' {
            $result = Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -WhatIf -NonInteractive

            $result | Should -Be 0
            @($script:infoMessages | Where-Object { $_.StartsWith('[DRY-RUN] A real run would stop here with exit code 4: it needs administrator privileges, and a non-interactive run shows no UAC prompt.') }).Count | Should -Be 1
            Should -Invoke Restart-WithElevation -Times 0 -Exactly
            Should -Invoke Invoke-WingetProcess -Times 0 -Exactly
        }

        It 'An interactive dry run previews the relaunch without doing it' {
            # Interactive, so the preview ends at the final key press; stopped there.
            Mock Write-Prompt { throw 'reached the final prompt' }

            { Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -WhatIf } | Should -Throw 'reached the final prompt'

            # No source update before elevating any more, so none to preview (review finding P3-25).
            ($script:infoMessages -join "`n") | Should -Not -Match 'Would run winget source update'
            @($script:infoMessages | Where-Object { $_.StartsWith('[DRY-RUN] Would relaunch with administrator privileges.') }).Count | Should -Be 1
            Should -Invoke Restart-WithElevation -Times 0 -Exactly
            Should -Invoke Invoke-WingetProcess -Times 0 -Exactly
        }

        It 'An interactive dry run says a real run would stop with exit code 4 when Group Policy''s machine execution policy refuses the elevated relaunch (wgt-gq8.39)' {
            Mock Write-Prompt { throw 'reached the final prompt' }
            Mock Get-ScriptExecutionPolicyBlock { [pscustomobject]@{ Engine = 'WindowsPowerShell'; Scope = 'MachinePolicy'; Policy = 'AllSigned'; Key = 'HKLM\K'; GroupPolicyPath = 'Computer Configuration > P'; Description = 'Group Policy sets the Windows PowerShell execution policy for this PC to AllSigned (MachinePolicy, HKLM\K)' } }

            { Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -WhatIf } | Should -Throw 'reached the final prompt'

            Should -Invoke Get-ScriptExecutionPolicyBlock -Times 1 -Exactly -ParameterFilter { $Engine -eq 'WindowsPowerShell' }
            $stopLines = @($script:infoMessages | Where-Object { $_.StartsWith('[DRY-RUN] A real run would stop here with exit code 4, without a UAC prompt: Group Policy sets the Windows PowerShell execution policy for this PC to AllSigned') })
            $stopLines | Should -HaveCount 1
            $stopLines[0] | Should -Match 'Computer Configuration > P'
            @($script:infoMessages | Where-Object { $_.StartsWith('[DRY-RUN] Would relaunch') }) | Should -HaveCount 0
            Should -Invoke Restart-WithElevation -Times 0 -Exactly
        }

        It 'An interactive dry run previews the relaunch and adds the warning for a user execution policy (wgt-gq8.39)' {
            Mock Write-Prompt { throw 'reached the final prompt' }
            Mock Get-ScriptExecutionPolicyBlock { [pscustomobject]@{ Engine = 'WindowsPowerShell'; Scope = 'UserPolicy'; Policy = 'Restricted'; Key = 'HKCU\K'; GroupPolicyPath = 'User Configuration > P'; Description = 'Group Policy sets the Windows PowerShell execution policy for this account to Restricted (UserPolicy, HKCU\K)' } }

            { Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -WhatIf } | Should -Throw 'reached the final prompt'

            @($script:infoMessages | Where-Object { $_.StartsWith('[DRY-RUN] Would relaunch with administrator privileges.') }) | Should -HaveCount 1
            @($script:infoMessages | Where-Object { $_ -like '`[DRY-RUN`] Group Policy sets the Windows PowerShell execution policy for this account to Restricted*if this account approves the UAC prompt*' }) | Should -HaveCount 1
        }

        It 'Returns 4 without relaunching when called from the imported module (issue #185)' {
            Mock Test-InvokedFromModuleContext { $true }

            $result = Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' })

            $result | Should -Be 4
            ($script:errorMessages -join "`n") | Should -Match 'invoked from the imported module without elevation'
            Should -Invoke Restart-WithElevation -Times 0 -Exactly
            Should -Invoke Install-AppWithVerification -Times 0 -Exactly
        }
    }

    Context 'No winget call before elevation (review finding P3-25)' {
        # The run used to update the winget source before relaunching elevated. Under cross-user
        # elevation that set up the signed-in user's source, not the elevating account's, and it was
        # a fourth source probe in the run. The real non-admin path runs; it stops at the (mocked)
        # elevated relaunch.
        BeforeEach {
            Mock Test-IsAdmin { $false }
            Mock Test-IsRunningLocally { $true }
            Mock Test-InvokedFromModuleContext { $false }
            Mock Test-EffectiveNonInteractive { [bool]$NonInteractive }
            Mock Invoke-WingetProcess { throw "no winget call before elevating: $($ArgumentList -join ' ')" }
        }

        It 'Relaunches elevated without running winget first' {
            Invoke-WingetInstall | Should -Be 0

            Should -Invoke Invoke-WingetProcess -Times 0 -Exactly
            Should -Invoke Restart-WithElevation -Times 1 -Exactly
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
            # Applicability decided once per app, by the (mocked) gate, never by a real probe here.
            Should -Invoke Test-AppApplicability -Times $expectedCount -Exactly
            Should -Invoke Install-AppWithVerification -Times $expectedCount -Exactly -ParameterFilter { $Applicable -eq $true }

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

    Context 'TightVNC passwords (work-order item 18, review finding P2-22)' {
        # TightVNC's post-install hook needs a password from the environment or the console. The
        # run takes it before winget or any installer starts (a child process would inherit the
        # variable), asks for it then and not mid-run, keeps it for both passes and drops it after.
        BeforeEach {
            $script:tightVncCatalog = @(@{ name = 'GlavSoft.TightVNC'; postInstall = 'Set-TightVncServerPassword' })
            $script:TightVncSecret = $null
            Remove-Item -LiteralPath 'Env:\WINGET_APP_SETUP_TIGHTVNC_PASSWORD' -ErrorAction SilentlyContinue
            $script:events = [System.Collections.Generic.List[string]]::new()
            Mock Initialize-Winget {
                $script:events.Add(('winget setup; variable set: {0}' -f [bool][System.Environment]::GetEnvironmentVariable('WINGET_APP_SETUP_TIGHTVNC_PASSWORD')))
                [pscustomobject]@{ Ready = $true; Diagnosis = 'Ok' }
            }
            Mock Install-AppWithVerification {
                $script:events.Add(('install; password kept: {0}' -f [bool]($script:TightVncSecret -and $script:TightVncSecret.Password)))
                @{ Status = 'Installed'; InstallResult = $null; FailureReason = $null }
            }
        }

        AfterEach {
            Remove-Item -LiteralPath 'Env:\WINGET_APP_SETUP_TIGHTVNC_PASSWORD' -ErrorAction SilentlyContinue
            $script:TightVncSecret = $null
        }

        It 'Takes the password out of the environment before winget is set up, keeps it for the installs and drops it after' {
            [System.Environment]::SetEnvironmentVariable('WINGET_APP_SETUP_TIGHTVNC_PASSWORD', 'Secure!')

            Invoke-WingetInstall -Apps $script:tightVncCatalog -NonInteractive | Should -Be 0

            @($script:events) | Should -Be @('winget setup; variable set: False', 'install; password kept: True')
            [System.Environment]::GetEnvironmentVariable('WINGET_APP_SETUP_TIGHTVNC_PASSWORD') | Should -BeNullOrEmpty
            $script:TightVncSecret | Should -BeNullOrEmpty
        }

        It 'Asks for the password at the start of an interactive run, before winget is set up' {
            Mock Test-EffectiveNonInteractive { $false }
            Mock Test-IsContinuousIntegration { $false }
            Mock Test-PowerShellHostNonInteractive { $false }
            Mock Wait-TightVncPromptAnswer { $true }
            Mock Get-TightVncServerSettings { @{ KeyExists = $false; Password = $null; UseVncAuthentication = $null; ControlPassword = $null; UseControlAuthentication = $null } }
            Mock Read-Host {
                $script:events.Add('prompt')
                $secure = New-Object System.Security.SecureString
                foreach ($character in 'Secure!'.ToCharArray()) {
                    $secure.AppendChar($character)
                }
                $secure
            }
            # The final 'Press any key' would wait for a real key press.
            Mock Write-Prompt { throw 'reached the final prompt' }

            { Invoke-WingetInstall -Apps $script:tightVncCatalog } | Should -Throw 'reached the final prompt'

            @($script:events) | Should -Be @('prompt', 'prompt', 'winget setup; variable set: False', 'install; password kept: True')
        }

        It 'Leaves the variable in place in a dry run and says only whether it is set' {
            [System.Environment]::SetEnvironmentVariable('WINGET_APP_SETUP_TIGHTVNC_PASSWORD', 'Secure!')

            Invoke-WingetInstall -Apps $script:tightVncCatalog -WhatIf -NonInteractive | Should -Be 0

            [System.Environment]::GetEnvironmentVariable('WINGET_APP_SETUP_TIGHTVNC_PASSWORD') | Should -Be 'Secure!'
            $script:infoMessages | Should -Contain '[DRY-RUN] TightVNC: a real run would set the server password from WINGET_APP_SETUP_TIGHTVNC_PASSWORD (value not shown).'
            (($script:infoMessages + $script:warningMessages) -join "`n") | Should -Not -Match 'Secure!'
        }

        It 'Drops the password when the run stops early with exit code <Code>, so a console that stays open (irm | iex) does not keep it' -ForEach @(
            @{ Code = 2; Case = 'winget unusable' }
            @{ Code = 3; Case = 'catalog invalid' }
        ) {
            [System.Environment]::SetEnvironmentVariable('WINGET_APP_SETUP_TIGHTVNC_PASSWORD', 'Secure!')
            if ($Code -eq 2) {
                Mock Initialize-Winget { [pscustomobject]@{ Ready = $false; Diagnosis = 'NotLaunchable' } }
            }
            else {
                Mock Test-AppDefinitions { @{ Errors = @('a broken entry'); Warnings = @(); ValidApps = @() } }
            }

            Invoke-WingetInstall -Apps $script:tightVncCatalog -NonInteractive | Should -Be $Code

            [System.Environment]::GetEnvironmentVariable('WINGET_APP_SETUP_TIGHTVNC_PASSWORD') | Should -BeNullOrEmpty
            $script:TightVncSecret | Should -BeNullOrEmpty
        }

        It 'Does nothing for a catalog without the TightVNC hook' {
            [System.Environment]::SetEnvironmentVariable('WINGET_APP_SETUP_TIGHTVNC_PASSWORD', 'Secure!')

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.OnlyApp' }) -NonInteractive | Should -Be 0

            [System.Environment]::GetEnvironmentVariable('WINGET_APP_SETUP_TIGHTVNC_PASSWORD') | Should -Be 'Secure!'
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

        It 'Writes the summary as text only, and installs no module for a grid view, with someone at the console (work-order item 26)' {
            # An interactive run used to open the summary in an Out-GridView window as well
            # (-AutoGridView), after installing Microsoft.PowerShell.GraphicalTools and the NuGet
            # provider for all users from the PowerShell Gallery wherever Out-GridView was missing.
            Mock Test-EffectiveNonInteractive { $false }
            # Throws so the run never reaches [Console]::ReadKey after its final prompt.
            Mock Write-Prompt { throw 'reached the final prompt' }
            Mock Get-PackageProvider { $null }
            Mock Install-PackageProvider { }
            Mock Install-Module { }
            $script:summaryParameters = $null
            Mock Write-Table {
                if ($Title -eq 'Installation Summary') {
                    $script:summaryParameters = @($PesterBoundParameters.Keys | Sort-Object)
                }
            }

            { Invoke-WingetInstall -Apps @(@{ name = 'Contoso.New' }) } | Should -Throw 'reached the final prompt'

            $script:summaryParameters | Should -Be @('Headers', 'Rows', 'Title')
            Should -Invoke Install-Module -Times 0 -Exactly
            Should -Invoke Install-PackageProvider -Times 0 -Exactly
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
            # The winget exit code (named, review finding P2-15) and retry detail, not the generic
            # message issue #189 replaced.
            $failedRows[0][1] | Should -Be 'the installing account has no logon session, so Windows blocked the app package deployment; winget exit 0x80073D19 ERROR_DEPLOYMENT_BLOCKED_BY_USER_LOG_OFF, 3 attempts, machine-scope fallback: yes'
            ($script:errorMessages -join "`n") | Should -Not -Match 'No package found matching input criteria'
        }

        # wgt-gq8.35: a failed run ends with where to report it and the command that makes the
        # diagnostics bundle to attach, as a run that stops early does.
        It 'Prints the diagnostics bundle command under the summary of a failed run (exit code <ExitCode>)' -ForEach @(
            @{ ExitCode = 1; Failure = 'app' }
            @{ ExitCode = 2; Failure = 'winget' }
            @{ ExitCode = 8; Failure = 'autoupdates' }
        ) {
            switch ($Failure) {
                'app' { Mock Install-AppWithVerification { @{ Status = 'Failed'; InstallResult = @{ ExitCode = 1603 }; FailureReason = 'VerifyNotFound' } } }
                'winget' { Mock Test-WingetLaunchable { [pscustomobject]@{ Launchable = $false; Version = $null; Reason = 'the file cannot be accessed by the system'; Attempts = 1 } } }
                'autoupdates' { Mock Install-WingetAutoUpdate { [pscustomobject]@{ Status = 'Failed'; Version = '2.12.0' } } }
            }

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive | Should -Be $ExitCode

            $script:infoMessages | Should -Contain ('    ' + (Get-DiagnosticsCommandLine))
            ($script:infoMessages -join "`n") | Should -Match ([regex]::Escape('issues/new?template=install-failure.yml'))
        }

        It 'Prints no bundle command after <Kind>' -ForEach @(
            @{ Kind = 'a run that exits 0'; WhatIf = $false; Restart = $false; ExitCode = 0 }
            @{ Kind = 'a run that exits 3010 (succeeded, restart required)'; WhatIf = $false; Restart = $true; ExitCode = 3010 }
            @{ Kind = 'a dry run'; WhatIf = $true; Restart = $false; ExitCode = 0 }
        ) {
            if ($Restart) {
                Mock Install-WingetAutoUpdate { [pscustomobject]@{ Status = 'Configured'; Version = '2.12.0'; RestartRequired = $true } }
            }

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive -WhatIf:$WhatIf | Should -Be $ExitCode

            ($script:infoMessages -join "`n") | Should -Not -Match 'CollectDiagnostics'
        }
    }

    # Review findings P2-24, P3-22, P3-23: who the run installs as is decided once, and a run as
    # SYSTEM or under cross-user elevation installs for the whole PC only.
    Context 'A run for the whole PC: SYSTEM or cross-user elevation' {
        It 'Tells the winget setup it is SYSTEM and installs every app for the whole PC' {
            Mock Get-InstallAccountContext { New-TestAccountContext -System -SessionUser 'CONTOSO\jdoe' }

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.App' }) -NonInteractive | Should -Be 0

            Should -Invoke Initialize-Winget -Times 1 -Exactly -ParameterFilter { $AccountContext.IsSystem }
            Should -Invoke Install-AppWithVerification -Times 1 -Exactly -ParameterFilter { $MachineWide }
            $info = $script:infoMessages -join "`n"
            $info | Should -Match 'Running as SYSTEM'
            $info | Should -Match 'Microsoft does not support the winget command line as SYSTEM'
        }

        It 'Stops with exit code 2 when a run as SYSTEM finds no machine-wide winget it can start' {
            Mock Get-InstallAccountContext { New-TestAccountContext -System }
            Mock Initialize-Winget { [pscustomobject]@{ Ready = $false; Diagnosis = 'NotLaunchable' } }

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.App' }) -NonInteractive | Should -Be 2

            Should -Invoke Install-AppWithVerification -Times 0 -Exactly
        }

        It 'Installs every app for the whole PC under cross-user elevation, and still sets winget up for the account' {
            Mock Get-InstallAccountContext { New-TestAccountContext -CrossUser -ProcessUser 'CONTOSO\admin-tech' -SessionUser 'CONTOSO\jdoe' }

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.App' }) -NonInteractive | Should -Be 0

            Should -Invoke Install-AppWithVerification -Times 1 -Exactly -ParameterFilter { $MachineWide }
            Should -Invoke Initialize-Winget -Times 1 -Exactly -ParameterFilter { $AccountContext.IsCrossUserElevation -and -not $AccountContext.IsSystem }
            ($script:infoMessages -join "`n") | Should -Not -Match 'Running as SYSTEM'
        }

        It 'Leaves a signed-in user''s own run as it was: per-user fallback allowed' {
            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.App' }) -NonInteractive | Should -Be 0

            Should -Invoke Install-AppWithVerification -Times 1 -Exactly -ParameterFilter { -not $MachineWide }
        }

        It 'Reports a deferred app in its own summary row, as neither installed nor failed, says who can install it, and exits 0' {
            Mock Get-InstallAccountContext { New-TestAccountContext -System -SessionUser 'CONTOSO\jdoe' }
            Mock Install-AppWithVerification {
                if ($App.name -eq 'Contoso.UserOnly') {
                    return @{ Status = 'Deferred'; InstallResult = @{ ExitCode = -1978335216; NoMachineScopeInstaller = $true }; FailureReason = $null; DeferReason = 'NoMachineScopeInstaller' }
                }
                @{ Status = 'Installed'; InstallResult = @{ ExitCode = 0 }; FailureReason = $null }
            }

            $result = Invoke-WingetInstall -Apps @(@{ name = 'Contoso.MachineApp' }, @{ name = 'Contoso.UserOnly' }) -NonInteractive

            $result | Should -Be 0
            @($script:capturedRows | Where-Object { $_[0] -eq 'Installed' })[0][1] | Should -Be 'Contoso.MachineApp'
            @($script:capturedRows | Where-Object { $_[0] -eq 'Deferred' })[0][1] | Should -Be 'Contoso.UserOnly'
            @($script:capturedRows | Where-Object { $_[0] -eq 'Failed' }).Count | Should -Be 0
            # Not retried: a deferred app is not a failure.
            Should -Invoke Install-AppWithVerification -Times 2 -Exactly
            $script:warningMessages | Should -Contain 'Deferred: Contoso.UserOnly (winget found no machine-wide installer for it)'
            $script:warningMessages | Should -Contain "Deferred: Contoso.UserOnly - winget found no machine-wide installer for it that applies to this PC (0x8A150010 NO_APPLICABLE_INSTALLER with --scope machine), and a run as SYSTEM installs for the whole PC only. Not installed and not counted as failed. A per-user app can only be installed in the signed-in user's own account: by this installer run as the signed-in user when that account is an administrator, otherwise by a per-user deployment: the user phase (rmm/Invoke-WingetAppSetupUserPhase.ps1, run as the user at sign-in, for example by an Endpoint Central User Configuration script) installs the apps a run deferred, or the Microsoft Store."
        }

        It 'Names the signed-in user under cross-user elevation' {
            Mock Get-InstallAccountContext { New-TestAccountContext -CrossUser -ProcessUser 'CONTOSO\admin-tech' -SessionUser 'CONTOSO\jdoe' }
            Mock Install-AppWithVerification { @{ Status = 'Deferred'; InstallResult = $null; FailureReason = $null; DeferReason = 'NoMachineScopeInstaller' } }

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.UserOnly' }) -NonInteractive | Should -Be 0

            $script:warningMessages | Should -Contain "Deferred: Contoso.UserOnly - winget found no machine-wide installer for it that applies to this PC (0x8A150010 NO_APPLICABLE_INSTALLER with --scope machine), and installing per-user here would install for 'CONTOSO\admin-tech' instead of 'CONTOSO\jdoe'. Not installed and not counted as failed. A per-user app can only be installed in the account 'CONTOSO\jdoe': by this installer run as 'CONTOSO\jdoe' when that account is an administrator, otherwise by a per-user deployment: the user phase (rmm/Invoke-WingetAppSetupUserPhase.ps1, run as the user at sign-in, for example by an Endpoint Central User Configuration script) installs the apps a run deferred, or the Microsoft Store."
        }

        It 'Defers an app that the retry pass finds has no machine-wide installer, instead of counting it as installed' {
            Mock Get-InstallAccountContext { New-TestAccountContext -System }
            $script:successMessages = @()
            Mock Write-Success { $script:successMessages += $Message }
            $script:userOnlyCalls = 0
            Mock Install-AppWithVerification {
                $script:userOnlyCalls++
                if ($script:userOnlyCalls -eq 1) {
                    return @{ Status = 'Failed'; InstallResult = $null; FailureReason = 'PreCheckTimeout' }
                }
                @{ Status = 'Deferred'; InstallResult = $null; FailureReason = $null; DeferReason = 'NoMachineScopeInstaller' }
            }

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.UserOnly' }) -NonInteractive | Should -Be 0

            @($script:capturedRows | Where-Object { $_[0] -eq 'Deferred' })[0][1] | Should -Be 'Contoso.UserOnly'
            @($script:capturedRows | Where-Object { $_[0] -eq 'Installed' }).Count | Should -Be 0
            $script:successMessages | Should -Not -Contain 'Retry succeeded: Contoso.UserOnly'
            $script:warningMessages | Should -Contain 'Deferred: Contoso.UserOnly (winget found no machine-wide installer for it)'
            # The retry pass installs for the whole PC too: at winget's default scope it would
            # install into SYSTEM's own profile (review finding P3-22).
            Should -Invoke Install-AppWithVerification -Times 2 -Exactly -ParameterFilter { $MachineWide }
        }

        It 'Says a provisioned app is skipped because every user has it' {
            Mock Get-InstallAccountContext { New-TestAccountContext -System }
            Mock Install-AppWithVerification { @{ Status = 'Skipped'; InstallResult = $null; FailureReason = $null; SkipReason = 'Provisioned' } }

            Invoke-WingetInstall -Apps @(@{ name = 'Microsoft.WindowsTerminal'; msixName = 'Microsoft.WindowsTerminal' }) -NonInteractive | Should -Be 0

            $script:warningMessages | Should -Contain 'Skipping: Microsoft.WindowsTerminal (already provisioned for every user on this PC)'
            @($script:capturedRows | Where-Object { $_[0] -eq 'Skipped' })[0][1] | Should -Be 'Microsoft.WindowsTerminal'
        }
    }

    Context 'Environment pre-flight for the account the run installs as (wgt-gq8.39)' {
        BeforeEach {
            $script:blockedPolicy = [pscustomobject]@{ Name = 'EnableAppInstaller'; Policy = 'Enable App Installer' }
            $script:steps = @()
            Mock Wait-WauIdle { $script:steps += 'Wait-WauIdle'; $true }
            Mock Initialize-Winget { $script:steps += 'Initialize-Winget'; [pscustomobject]@{ Ready = $true; Diagnosis = 'Ok' } }
        }

        It 'Stops with exit code 2 when Group Policy turns winget off, before it waits for Winget-AutoUpdate or sets winget up, and says so once' {
            Mock Get-WingetPolicyBlock { $script:blockedPolicy }

            $result = Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive

            $result | Should -Be 2
            $script:steps | Should -HaveCount 0
            Should -Invoke Install-AppWithVerification -Times 0 -Exactly
            Should -Invoke Install-WingetAutoUpdate -Times 0 -Exactly
            @($script:errorMessages | Where-Object { $_ -like 'Group Policy on this PC blocks winget*' }) | Should -HaveCount 1
        }

        It 'A dry run reports the Group Policy block once and previews the rest without setting winget up' {
            Mock Get-WingetPolicyBlock { $script:blockedPolicy }

            $result = Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -WhatIf -NonInteractive

            $result | Should -Be 0
            Should -Invoke Initialize-Winget -Times 0 -Exactly
            @($script:infoMessages | Where-Object { $_ -like '`[DRY-RUN`] Group Policy on this PC blocks winget*A real run would stop here with exit code 2.' }) | Should -HaveCount 1
            @($script:errorMessages | Where-Object { $_ -like '*Group Policy*' }) | Should -HaveCount 0
            ($script:infoMessages -join "`n") | Should -Match '\[DRY-RUN\] winget is not available for this account, so this preview cannot tell which apps are already installed'
        }

        # Work-order items 31 and 39: the Windows App Runtime install happens inside the
        # Winget-AutoUpdate step, after the pre-flight, and adds no check of its own.
        It 'Runs the pre-flight once, before winget is set up and before Winget-AutoUpdate and its runtime install, and compares the end of the run against its restart state' {
            Mock Get-ProxyInheritanceWarning { $script:steps += 'Get-ProxyInheritanceWarning'; $null }
            Mock Get-PendingRestartState { $script:steps += 'Get-PendingRestartState'; New-TestRestartState -WindowsUpdate }
            Mock Install-WingetAutoUpdate { $script:steps += 'Install-WingetAutoUpdate'; [pscustomobject]@{ Status = 'Configured'; Version = '2.12.0'; FrameworkMissing = $false; RestartRequired = $false } }

            $result = Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive

            # The restart was pending before the run, so it does not make the run 3010.
            $result | Should -Be 0
            $script:steps | Should -Be @('Get-ProxyInheritanceWarning', 'Get-PendingRestartState', 'Wait-WauIdle', 'Initialize-Winget', 'Install-WingetAutoUpdate', 'Get-PendingRestartState')
            Should -Invoke Get-WingetPolicyBlock -Times 1 -Exactly
            @($script:warningMessages | Where-Object { $_ -like 'A restart is already pending on this PC*' }) | Should -HaveCount 1
        }

        It 'Warns once about the signed-in user''s proxy for a run as SYSTEM, before it waits for Winget-AutoUpdate, and goes on' {
            Mock Get-InstallAccountContext { New-TestAccountContext -System -SessionUser 'CONTOSO\jdoe' }
            Mock Get-ProxyInheritanceWarning { 'PROXY LINE' }
            Mock Write-WarningMessage { $script:warningMessages += $Message; $script:steps += "WARN: $Message" }

            $result = Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive

            $result | Should -Be 0
            Should -Invoke Get-ProxyInheritanceWarning -Times 1 -Exactly -ParameterFilter { $AccountContext.IsSystem -and $AccountContext.SessionUser -eq 'CONTOSO\jdoe' }
            @($script:warningMessages | Where-Object { $_ -eq 'PROXY LINE' }) | Should -HaveCount 1
            $script:steps.IndexOf('WARN: PROXY LINE') | Should -BeLessThan $script:steps.IndexOf('Wait-WauIdle')
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
            Mock Test-WingetLaunchable { $script:callOrder.Add('probe'); [pscustomobject]@{ Launchable = $true; Version = 'v1.12.350'; Reason = $null; Attempts = 1 } }
        }

        It 'Sets up WAU only after the retry pass, then probes winget once with a short budget' {
            # WAU used to be installed (with RUN_WAU=YES) before the retry pass, so its immediate
            # SYSTEM run re-provisioned App Installer while the retry pass was still using winget
            # (issues #279/#283/#284). Nothing may touch winget after WAU is set up except the probe:
            # up to five checks 15 seconds apart (about a minute, as before).
            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive

            $script:callOrder | Should -Be @('app:Contoso.AppOne', 'app:Contoso.AppOne', 'wau', 'probe')
            Should -Invoke Test-WingetLaunchable -Times 1 -Exactly -ParameterFilter {
                $Attempts -eq 5 -and $RetryDelaySeconds -eq 15
            }
        }

        It 'Skips the end-of-run probe in a dry run' {
            # A dry run has no retry pass, so the first-pass failure from BeforeEach would stay
            # failed; this test only needs the app to land.
            Mock Install-AppWithVerification { @{ Status = 'Installed'; InstallResult = $null; FailureReason = $null } }

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -WhatIf -NonInteractive

            Should -Invoke Test-WingetLaunchable -Times 0 -Exactly
        }

        It 'Still reaches the retry pass, WAU setup and the summary when Windows Terminal configuration throws' {
            Mock Set-WindowsTerminalDefaults { throw 'boom from the Terminal step' }

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive | Should -Be 0

            $script:callOrder | Should -Be @('app:Contoso.AppOne', 'app:Contoso.AppOne', 'wau', 'probe')
            ($script:warningMessages -join "`n") | Should -Match 'Windows Terminal configuration failed unexpectedly: boom from the Terminal step'
            Should -Invoke Write-Table -Times 1 -Exactly
        }

        It 'Reports auto-updates as FAILED, exits 8 and still prints the summary when WAU setup throws' {
            Mock Install-WingetAutoUpdate { throw 'boom from WAU' }

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive | Should -Be 8

            ($script:errorMessages -join "`n") | Should -Match 'Winget-AutoUpdate setup failed unexpectedly: boom from WAU'
            ($script:errorMessages -join "`n") | Should -Match 'Auto-updates: FAILED'
            Should -Invoke Write-Table -Times 1 -Exactly
        }

        It 'Treats a throwing end-of-run probe as unknown, not as a broken winget' {
            Mock Test-WingetLaunchable { throw 'boom from the probe' }

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive | Should -Be 0

            ($script:errorMessages -join "`n") | Should -Not -Match 'winget: NOT USABLE'
        }

        It 'Waits for a running Winget-AutoUpdate before the first winget call of a real run' {
            Mock Wait-WauIdle { $script:callOrder.Add('wau-idle'); $true }
            Mock Initialize-Winget { $script:callOrder.Add('winget-check'); [pscustomobject]@{ Ready = $true; Diagnosis = 'Ok' } }

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

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive | Should -Be 8

            ($script:errorMessages -join "`n") | Should -Match 'Auto-updates: NOT CONFIGURED'
        }

        It 'Prints Auto-updates: AT RISK when an existing WAU sits on a machine without the framework' {
            Mock Install-WingetAutoUpdate { [pscustomobject]@{ Status = 'AlreadyPresent'; Version = [version]'2.12.0'; FrameworkMissing = $true } }

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive | Should -Be 8

            ($script:errorMessages -join "`n") | Should -Match 'Auto-updates: AT RISK'
        }

        # Work-order item 31: the summary says why the installer's own install of the framework
        # did not help, under the Auto-updates line, and nothing when it did not try.
        It 'Says under the Auto-updates line why the framework could not be installed (<Status>)' -ForEach @(
            @{ Status = 'FrameworkMissing'; Line = 'Auto-updates: NOT CONFIGURED' }
            @{ Status = 'AlreadyPresent'; Line = 'Auto-updates: AT RISK' }
        ) {
            $script:wauStatus = $Status
            Mock Install-WingetAutoUpdate { [pscustomobject]@{ Status = $script:wauStatus; Version = '2.12.0'; FrameworkMissing = $true; FrameworkInstallError = 'installing it for all users needs administrator rights' } }

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive | Should -Be 8

            $messages = @($script:errorMessages)
            $lineIndex = -1
            for ($index = 0; $index -lt $messages.Count; $index++) {
                if ($messages[$index].StartsWith($Line)) {
                    $lineIndex = $index
                    break
                }
            }
            $lineIndex | Should -BeGreaterOrEqual 0
            $messages[$lineIndex + 1] | Should -Be '  The installer could not install it: installing it for all users needs administrator rights.'
        }

        It 'Adds no reason line when the installer did not try to install the framework' {
            Mock Install-WingetAutoUpdate { [pscustomobject]@{ Status = 'FrameworkMissing'; Version = '2.12.0'; FrameworkMissing = $true } }

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive | Should -Be 8

            ($script:errorMessages -join "`n") | Should -Not -Match 'The installer could not install it'
        }
    }

    # Review findings P2-8 and P2-10. The signature-specific deadlock gate (two DesktopAppInstaller
    # versions in the current user's AppX view) never fired on the real wedge; this generic breaker
    # replaced it. Install-AppWithVerification is mocked here; the Describe 'Wedged winget: the run
    # fails fast' below drives the real pipeline.
    Context 'Circuit breaker: winget cannot be launched' {
        BeforeEach {
            $script:apps = @(@{ name = 'Contoso.AppOne' }, @{ name = 'Contoso.AppTwo' }, @{ name = 'Contoso.AppThree' })
            $script:appCalls = [System.Collections.Generic.List[string]]::new()
            # AppOne cannot launch winget for its pre-check; the others would install.
            Mock Install-AppWithVerification {
                $script:appCalls.Add("$($App.name):$([bool]$WingetNotLaunchable)")
                if ($WingetNotLaunchable) {
                    return @{ Status = 'Failed'; InstallResult = $null; FailureReason = 'WingetNotLaunchable'; LaunchError = $null }
                }
                if ($App.name -eq 'Contoso.AppOne') {
                    return @{ Status = 'Failed'; InstallResult = $null; FailureReason = 'PreCheckLaunchFailed'; LaunchError = 'Access is denied.' }
                }
                @{ Status = 'Installed'; InstallResult = @{ ExitCode = 0 }; FailureReason = $null }
            }
            $script:notLaunchable = [pscustomobject]@{ Launchable = $false; Version = $null; Reason = 'winget could not be started: Access is denied'; Attempts = 1 }
        }

        It 'Fails the remaining apps without running winget and skips the retry pass when winget still cannot be started' {
            Mock Test-WingetLaunchable { $script:notLaunchable }

            $result = Invoke-WingetInstall -Apps $script:apps -NonInteractive

            $result | Should -Be 1
            # One breaker check right after AppOne (up to six tries 15 s apart: the 75 s an App
            # Installer update in progress needs), then one end-of-run check.
            Should -Invoke Test-WingetLaunchable -Times 1 -Exactly -ParameterFilter { $Attempts -eq 6 -and $RetryDelaySeconds -eq 15 }
            Should -Invoke Test-WingetLaunchable -Times 1 -Exactly -ParameterFilter { $Attempts -eq 1 }
            Should -Invoke Test-WingetLaunchable -Times 2 -Exactly
            # The rest went through the pipeline only to be failed without winget (so a
            # not-applicable app is still skipped), and nothing ran a second time.
            $script:appCalls | Should -Be @('Contoso.AppOne:False', 'Contoso.AppTwo:True', 'Contoso.AppThree:True')
            $script:errorMessages | Should -Contain 'winget cannot be launched on this machine (winget could not be started: Access is denied). The remaining apps are marked failed without an install attempt and are not retried. Restart the machine and re-run the installer; if it persists, attach this transcript to a GitHub issue.'
            $script:warningMessages | Should -Contain 'Skipping the retry pass: winget cannot be launched on this machine (see above); retrying would not help.'
            $script:infoMessages | Should -Not -Contain 'Retrying failed installations (1 final attempt)...'

            $failedRows = @($script:capturedTables['Failed Installations'])
            $failedRows.Count | Should -Be 3
            $failedRows[0][1] | Should -Be 'winget could not be launched for the pre-install check; launch error: Access is denied'
            $failedRows[1][1] | Should -Be 'not attempted: winget cannot be launched on this machine (see above)'
            $failedRows[2][1] | Should -Be 'not attempted: winget cannot be launched on this machine (see above)'
        }

        It 'Carries on with the next app, and retries the failed one, when winget starts again' {
            $result = Invoke-WingetInstall -Apps $script:apps -NonInteractive

            # The breaker check passed, so AppTwo and AppThree ran normally; AppOne got its retry.
            $script:appCalls | Should -Be @('Contoso.AppOne:False', 'Contoso.AppTwo:False', 'Contoso.AppThree:False', 'Contoso.AppOne:False')
            $script:infoMessages | Should -Contain 'Retrying failed installations (1 final attempt)...'
            ($script:infoMessages -join "`n") | Should -Match 'winget starts again \(v1\.12\.350\); carrying on with the next app\.'
            # AppOne failed again in the retry pass, so the breaker checked again: 2 checks + the
            # end-of-run one.
            Should -Invoke Test-WingetLaunchable -Times 3 -Exactly
            $result | Should -Be 1
        }

        It 'Does not check winget after a failure that is not about launching it' {
            Mock Install-AppWithVerification { @{ Status = 'Failed'; InstallResult = @{ ExitCode = 1 }; FailureReason = 'VerifyNotFound' } }

            Invoke-WingetInstall -Apps $script:apps -NonInteractive | Should -Be 1

            # Only the end-of-run check.
            Should -Invoke Test-WingetLaunchable -Times 1 -Exactly
            Should -Invoke Test-WingetLaunchable -Times 1 -Exactly -ParameterFilter { $Attempts -eq 5 }
        }

        It 'Trips in the retry pass too, failing the rest of the retries without running winget' {
            # Every app fails its first pass for an ordinary reason; in the retry pass AppOne cannot
            # launch winget, and winget then stays down.
            $script:pass = @{}
            Mock Install-AppWithVerification {
                $script:appCalls.Add("$($App.name):$([bool]$WingetNotLaunchable)")
                $script:pass[$App.name] = 1 + [int]$script:pass[$App.name]
                if ($WingetNotLaunchable) {
                    return @{ Status = 'Failed'; InstallResult = $null; FailureReason = 'WingetNotLaunchable'; LaunchError = $null }
                }
                if ($script:pass[$App.name] -eq 2 -and $App.name -eq 'Contoso.AppOne') {
                    return @{ Status = 'Failed'; InstallResult = @{ LaunchErrorExhausted = $true; LaunchAttempts = 5 }; FailureReason = 'InstallLaunchFailed'; LaunchError = 'The file cannot be accessed by the system.' }
                }
                @{ Status = 'Failed'; InstallResult = @{ ExitCode = 1 }; FailureReason = 'VerifyNotFound' }
            }
            Mock Test-WingetLaunchable { $script:notLaunchable }

            Invoke-WingetInstall -Apps $script:apps -NonInteractive | Should -Be 1

            $script:appCalls | Should -Be @('Contoso.AppOne:False', 'Contoso.AppTwo:False', 'Contoso.AppThree:False', 'Contoso.AppOne:False', 'Contoso.AppTwo:True', 'Contoso.AppThree:True')
            ($script:errorMessages -join "`n") | Should -Match 'Retry failed: Contoso\.AppTwo \(not attempted: winget cannot be launched on this machine \(see above\)\)\.'
            ($script:errorMessages -join "`n") | Should -Match 'Retry failed: Contoso\.AppOne \(winget could not be launched to install it; 5 failed launches, launch error: The file cannot be accessed by the system\)\.'
        }

        It 'Never checks winget in a dry run' {
            Invoke-WingetInstall -Apps $script:apps -WhatIf -NonInteractive | Out-Null

            Should -Invoke Test-WingetLaunchable -Times 0 -Exactly
        }
    }

    # Elevated through the Test-IsAdmin mock in BeforeEach; these were skipped on any runner that
    # was not itself elevated (wgt-gq8.6).
    Context 'Restart required, and the wait for another installation (review findings P2-15, P3-16)' {
        It 'Exits 3010 and says a restart is required when an installed app needs one to finish' {
            Mock Install-AppWithVerification {
                if ($App.name -eq '7zip.7zip') {
                    return @{ Status = 'Installed'; InstallResult = @{ ExitCode = -1978334967; Attempts = 1; RestartRequired = $true }; FailureReason = $null }
                }
                @{ Status = 'Installed'; InstallResult = @{ ExitCode = 0; Attempts = 1; RestartRequired = $false }; FailureReason = $null }
            }

            Invoke-WingetInstall -Apps @(@{ name = '7zip.7zip' }, @{ name = 'Google.Chrome' }) -NonInteractive | Should -Be 3010

            $script:warningMessages | Should -Contain '7zip.7zip needs a restart to finish installing (winget exit 0x8A150109 INSTALL_REBOOT_REQUIRED_TO_FINISH).'
            $script:warningMessages | Should -Contain 'Restart: REQUIRED to finish this run - restart this PC before it is used (7zip.7zip reported that a restart finishes the installation).'
            # Still an installed app in the summary, not a failure.
            @($script:capturedRows | Where-Object { $_[0] -eq 'Installed' })[0][1] | Should -Match '7zip\.7zip'
        }

        It 'Exits 3010 when the retry pass installs an app that needs a restart to finish' {
            $script:appCalls = 0
            Mock Install-AppWithVerification {
                $script:appCalls++
                if ($script:appCalls -eq 1) {
                    return @{ Status = 'Failed'; InstallResult = @{ ExitCode = 1; Attempts = 1 }; FailureReason = 'VerifyNotFound' }
                }
                @{ Status = 'Installed'; InstallResult = @{ ExitCode = 0; Attempts = 1; RestartRequired = $true }; FailureReason = $null }
            }

            Invoke-WingetInstall -Apps @(@{ name = '7zip.7zip' }) -NonInteractive | Should -Be 3010

            $script:warningMessages | Should -Contain "7zip.7zip needs a restart to finish installing (winget printed 'Restart your PC to finish installation.')."
        }

        It 'Exits 3010 when Windows gained a pending restart during the run (<Case>)' -ForEach @(
            @{ Case = 'a queued file replacement'; After = @{ FileRenames = @('\??\C:\Program Files\Git\x.dll.new -> !\??\C:\Program Files\Git\x.dll') }; Reason = '1 file replacement is queued for the next restart' }
            @{ Case = 'Windows Update'; After = @{ WindowsUpdate = $true }; Reason = 'Windows Update has a restart pending' }
        ) {
            $script:restartReads = 0
            $script:afterState = $After
            Mock Get-PendingRestartState {
                $script:restartReads++
                if ($script:restartReads -eq 1) {
                    return New-TestRestartState
                }
                New-TestRestartState @script:afterState
            }

            Invoke-WingetInstall -Apps @(@{ name = 'Git.Git' }) -NonInteractive | Should -Be 3010

            $script:restartReads | Should -Be 2
            $script:warningMessages | Should -Contain "Restart: REQUIRED to finish this run - restart this PC before it is used ($Reason)."
        }

        It 'Reports a restart that was already pending before the run, without making the run 3010' {
            Mock Get-PendingRestartState { New-TestRestartState -WindowsUpdate -FileRenames @('a -> b') }

            Invoke-WingetInstall -Apps @(@{ name = 'Git.Git' }) -NonInteractive | Should -Be 0

            ($script:warningMessages -join "`n") | Should -Match 'A restart is already pending on this PC \(Windows Update has a restart pending; 1 file replacement is queued for the next restart\)'
            $script:warningMessages | Should -Contain 'Restart: already pending before this run (Windows Update has a restart pending; 1 file replacement is queued for the next restart) - restart this PC when you can.'
            ($script:warningMessages -join "`n") | Should -Not -Match 'Restart: REQUIRED'
        }

        It 'Exits 3010 when the Winget-AutoUpdate MSI returned 3010' {
            Mock Install-WingetAutoUpdate { [pscustomobject]@{ Status = 'Configured'; Version = '2.12.0'; FrameworkMissing = $false; RestartRequired = $true } }

            Invoke-WingetInstall -Apps @(@{ name = 'Git.Git' }) -NonInteractive | Should -Be 3010

            $script:warningMessages | Should -Contain 'Restart: REQUIRED to finish this run - restart this PC before it is used (the Winget-AutoUpdate installer reported that a restart finishes the installation).'
        }

        It 'Exits 1, not 3010, when an app failed as well (failures take precedence)' {
            Mock Install-AppWithVerification {
                if ($App.name -eq '7zip.7zip') {
                    return @{ Status = 'Installed'; InstallResult = @{ ExitCode = 0; RestartRequired = $true }; FailureReason = $null }
                }
                @{ Status = 'Failed'; InstallResult = @{ ExitCode = 1; Attempts = 1 }; FailureReason = 'VerifyNotFound' }
            }

            Invoke-WingetInstall -Apps @(@{ name = '7zip.7zip' }, @{ name = 'Google.Chrome' }) -NonInteractive | Should -Be 1

            ($script:warningMessages -join "`n") | Should -Match 'Restart: REQUIRED to finish this run'
        }

        It 'Does not retry an app whose installer cannot run until Windows restarts (0x8A15010A), and says to restart' {
            $script:gitCalls = 0
            Mock Install-AppWithVerification {
                $script:gitCalls++
                @{ Status = 'Failed'; InstallResult = @{ ExitCode = -1978334966; Attempts = 1; MachineScopeFellBack = $false }; FailureReason = 'VerifyNotFound' }
            }

            Invoke-WingetInstall -Apps @(@{ name = 'Git.Git' }) -NonInteractive | Should -Be 1

            $script:gitCalls | Should -Be 1
            $script:warningMessages | Should -Contain 'Not retrying Git.Git: its installer cannot run until this PC restarts.'
            $script:errorMessages | Should -Contain 'Failed to install: Git.Git (a restart is required before this installer can run - restart this PC, then re-run the installer; winget exit 0x8A15010A INSTALL_REBOOT_REQUIRED_FOR_INSTALL, 1 attempt, machine-scope fallback: no).'
            $script:errorMessages | Should -Contain 'Restart: REQUIRED before Git.Git can install - restart this PC, then re-run the installer.'
            @($script:capturedTables['Failed Installations']).Count | Should -Be 1
        }

        It 'Shares one 10-minute wait for another installation across the run''s apps, the retry pass and Winget-AutoUpdate' {
            $script:budgets = [System.Collections.Generic.List[int]]::new()
            $script:appCalls = 0
            Mock Install-AppWithVerification {
                $script:appCalls++
                $script:budgets.Add($InstallInProgressWaitSeconds)
                if ($script:appCalls -eq 1) {
                    # The first app waited 400 seconds for another installation, then failed.
                    return @{ Status = 'Failed'; InstallResult = @{ ExitCode = -1978334974; Attempts = 4; InstallInProgressWaitedSeconds = 400 }; FailureReason = 'VerifyNotFound' }
                }
                if ($script:appCalls -eq 2) {
                    return @{ Status = 'Installed'; InstallResult = @{ ExitCode = 0; Attempts = 2; InstallInProgressWaitedSeconds = 150 }; FailureReason = $null }
                }
                @{ Status = 'Installed'; InstallResult = @{ ExitCode = 0; Attempts = 1 }; FailureReason = $null }
            }
            Mock Install-WingetAutoUpdate { $script:budgets.Add($InstallInProgressWaitSeconds); [pscustomobject]@{ Status = 'Configured'; Version = '2.12.0'; FrameworkMissing = $false; RestartRequired = $false } }

            Invoke-WingetInstall -Apps @(@{ name = 'Google.Chrome' }, @{ name = '7zip.7zip' }) -NonInteractive | Should -Be 0

            # Chrome (600 left), 7zip (200 left), Chrome's retry (50 left), then WAU (50 left).
            $script:budgets | Should -Be @(600, 200, 50, 50)
        }

        It 'Says so when an installed app''s winget exit code was not 0, instead of dropping the code' {
            Mock Install-AppWithVerification { @{ Status = 'Installed'; InstallResult = @{ ExitCode = -1978335226; Attempts = 1; InstallerLogPath = 'C:\logs\winget-install-Contoso.App.log' }; FailureReason = $null } }

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.App' }) -NonInteractive | Should -Be 0

            $script:warningMessages | Should -Contain 'winget reported 0x8A150006 SHELLEXEC_INSTALL_FAILED for Contoso.App, but it is installed; installer log: C:\logs\winget-install-Contoso.App.log.'
        }
    }

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

    # Review finding P3-41: the run's outcome in machine-readable form, for RMM tools and the
    # teammate's issue reports. RunRecord.Tests.ps1 covers the record helpers themselves.
    Context 'Run result: the RESULT line and last-run.json (review finding P3-41)' {
        BeforeEach {
            $script:reportedRecords = @()
            $script:reportEvents = [System.Collections.Generic.List[string]]::new()
            Mock Write-InstallerRunResult { $script:reportedRecords += , $Record; $script:reportEvents.Add('report'); $null }
            Mock Unlock-InstallerRun { $script:reportEvents.Add('unlock') }
            # As under the entry script, which sets it for every real run.
            $script:InstallerRunReportPending = $true
            $script:InstallerAppRecords = $null
            $script:InstallerAutoUpdateResult = $null
        }

        It 'Records every app''s final outcome, with its reason and exit code, after the summary' {
            $script:retryCalls = 0
            Mock Install-AppWithVerification {
                switch ($App.name) {
                    'Contoso.New' { @{ Status = 'Installed'; InstallResult = @{ ExitCode = 0; Attempts = 1 }; FailureReason = $null } }
                    'Contoso.Present' { @{ Status = 'Skipped'; InstallResult = $null; FailureReason = $null } }
                    'Contoso.DellOnly' { @{ Status = 'Skipped'; SkipReason = 'NotApplicable'; InstallResult = $null; FailureReason = $null } }
                    'Contoso.NeedsRestart' { @{ Status = 'Installed'; InstallResult = @{ ExitCode = -1978334967; Attempts = 1; RestartRequired = $true }; FailureReason = $null } }
                    'Contoso.Flaky' {
                        $script:retryCalls++
                        if ($script:retryCalls -eq 1) {
                            return @{ Status = 'Failed'; InstallResult = @{ ExitCode = 1603; Attempts = 1 }; FailureReason = 'CustomInstallFailed' }
                        }
                        @{ Status = 'Installed'; InstallResult = @{ ExitCode = 0; Attempts = 1 }; FailureReason = $null }
                    }
                    default { @{ Status = 'Failed'; InstallResult = @{ ExitCode = -1978335226; Attempts = 2 }; FailureReason = 'VerifyNotFound' } }
                }
            }
            Mock Install-WingetAutoUpdate { [pscustomobject]@{ Status = 'Configured'; Version = [version]'2.12.0'; FrameworkMissing = $false; RestartRequired = $false } }
            $apps = @(
                @{ name = 'Contoso.New' }, @{ name = 'Contoso.Present' }, @{ name = 'Contoso.DellOnly'; conditionDescription = 'Dell hardware only' },
                @{ name = 'Contoso.NeedsRestart' }, @{ name = 'Contoso.Flaky' }, @{ name = 'Contoso.Broken' }
            )

            Invoke-WingetInstall -Apps $apps -NonInteractive | Should -Be 1

            $script:reportedRecords.Count | Should -Be 1
            $record = $script:reportedRecords[0]
            $record.exitCode | Should -Be 1
            $record.summaryReached | Should -BeTrue
            $record.counts.installed | Should -Be 3
            $record.counts.skipped | Should -Be 2
            $record.counts.failed | Should -Be 1
            @($record.apps | ForEach-Object { $_.id }) | Should -Be @('Contoso.New', 'Contoso.Present', 'Contoso.DellOnly', 'Contoso.NeedsRestart', 'Contoso.Flaky', 'Contoso.Broken')
            $byId = @{}
            foreach ($app in $record.apps) { $byId[$app.id] = $app }
            $byId['Contoso.New'].status | Should -Be 'Installed'
            $byId['Contoso.New'].code | Should -Be 0
            $byId['Contoso.Present'].reason | Should -Be 'already installed'
            $byId['Contoso.DellOnly'].reason | Should -Be 'not applicable: Dell hardware only'
            $byId['Contoso.NeedsRestart'].restartRequired | Should -BeTrue
            $byId['Contoso.NeedsRestart'].codeHex | Should -Be '0x8A150109'
            # The retry pass replaced the first-pass failure.
            $byId['Contoso.Flaky'].status | Should -Be 'Installed'
            $byId['Contoso.Flaky'].reason | Should -BeNullOrEmpty
            $byId['Contoso.Broken'].status | Should -Be 'Failed'
            $byId['Contoso.Broken'].codeHex | Should -Be '0x8A150006'
            $byId['Contoso.Broken'].reason | Should -Be @($script:capturedTables['Failed Installations'])[0][1]
            $record.autoUpdates.status | Should -Be 'Configured'
            $record.autoUpdates.version | Should -Be '2.12.0'
            $record.restartRequired | Should -BeTrue
            $record.wingetUsable | Should -BeTrue
            $script:InstallerRunReportPending | Should -BeFalse -Because 'the entry script must not add a second RESULT line'
        }

        It 'Records each Deferred app and each not-applicable skip of a run for the whole PC, once per app, whichever pass decided it (review findings P3-22, P3-24, P3-34)' {
            # A run as SYSTEM defers an app with no machine-wide installer, in the first pass or in
            # the retry pass, skips an MSIX app provisioned for every user, and a retried app can
            # come back not applicable. Each app gets one entry, with its final outcome.
            Mock Get-InstallAccountContext { New-TestAccountContext -System }
            $script:attempts = @{}
            Mock Install-AppWithVerification {
                $script:attempts[$App.name] = 1 + [int]$script:attempts[$App.name]
                $noMachineScope = @{ ExitCode = -1978335216; Attempts = 1; NoMachineScopeInstaller = $true }
                switch ($App.name) {
                    'Contoso.UserOnly' { @{ Status = 'Deferred'; InstallResult = $noMachineScope; FailureReason = $null; DeferReason = 'NoMachineScopeInstaller' } }
                    'Contoso.DellOnly' { @{ Status = 'Skipped'; SkipReason = 'NotApplicable'; InstallResult = $null; FailureReason = $null } }
                    'Contoso.Terminal' { @{ Status = 'Skipped'; SkipReason = 'Provisioned'; InstallResult = $null; FailureReason = $null } }
                    'Contoso.LateDeferred' {
                        if ($script:attempts[$App.name] -eq 1) {
                            return @{ Status = 'Failed'; InstallResult = @{ ExitCode = -1978335226; Attempts = 1 }; FailureReason = 'VerifyNotFound' }
                        }
                        @{ Status = 'Deferred'; InstallResult = $noMachineScope; FailureReason = $null; DeferReason = 'NoMachineScopeInstaller' }
                    }
                    'Contoso.LateNotApplicable' {
                        if ($script:attempts[$App.name] -eq 1) {
                            return @{ Status = 'Failed'; InstallResult = @{ ExitCode = -1978335226; Attempts = 1 }; FailureReason = 'VerifyNotFound' }
                        }
                        @{ Status = 'Skipped'; SkipReason = 'NotApplicable'; InstallResult = $null; FailureReason = $null }
                    }
                }
            }
            # The provisioned app comes right after a not-applicable one, so a reason left over
            # from the app before it would show.
            $apps = @(
                @{ name = 'Contoso.UserOnly' },
                @{ name = 'Contoso.DellOnly'; conditionDescription = 'Dell hardware only' },
                @{ name = 'Contoso.Terminal'; msixName = 'Contoso.Terminal' },
                @{ name = 'Contoso.LateDeferred' },
                @{ name = 'Contoso.LateNotApplicable'; conditionDescription = 'ARM64 only' }
            )

            Invoke-WingetInstall -Apps $apps -NonInteractive | Should -Be 0

            $script:reportedRecords.Count | Should -Be 1
            $record = $script:reportedRecords[0]
            @($record.apps | ForEach-Object { $_.id }) | Should -Be @('Contoso.UserOnly', 'Contoso.DellOnly', 'Contoso.Terminal', 'Contoso.LateDeferred', 'Contoso.LateNotApplicable')
            @($script:InstallerAppRecords.Keys).Count | Should -Be 5
            $byId = @{}
            foreach ($app in $record.apps) { $byId[$app.id] = $app }
            $byId['Contoso.UserOnly'].status | Should -Be 'Deferred'
            $byId['Contoso.UserOnly'].reason | Should -Be 'winget found no machine-wide installer for it'
            $byId['Contoso.UserOnly'].codeHex | Should -Be '0x8A150010'
            $byId['Contoso.DellOnly'].status | Should -Be 'Skipped'
            $byId['Contoso.DellOnly'].reason | Should -Be 'not applicable: Dell hardware only'
            $byId['Contoso.Terminal'].status | Should -Be 'Skipped'
            $byId['Contoso.Terminal'].reason | Should -Be 'already provisioned for every user on this PC'
            # The retry pass replaced the first-pass failures with the final outcome.
            $byId['Contoso.LateDeferred'].status | Should -Be 'Deferred'
            $byId['Contoso.LateDeferred'].codeHex | Should -Be '0x8A150010'
            $byId['Contoso.LateNotApplicable'].status | Should -Be 'Skipped'
            $byId['Contoso.LateNotApplicable'].reason | Should -Be 'not applicable: ARM64 only'
            $record.counts.installed | Should -Be 0
            $record.counts.skipped | Should -Be 3
            $record.counts.deferred | Should -Be 2
            $record.counts.failed | Should -Be 0
            $record.exitCode | Should -Be 0
            Format-InstallerResultLine -Record $record | Should -Match '^RESULT: exit=0 installed=0 skipped=3 deferred=2 failed=0 '
            # The summary agrees with the record.
            @($script:capturedRows | Where-Object { $_[0] -eq 'Deferred' })[0][1] | Should -Be 'Contoso.UserOnly, Contoso.LateDeferred'
        }

        It 'Records exit code 8 and an unhealthy Winget-AutoUpdate when its task will not run (review finding P3-36)' {
            Mock Install-WingetAutoUpdate { [pscustomobject]@{ Status = 'Unhealthy'; Version = [version]'2.12.0'; FrameworkMissing = $false; RestartRequired = $false; Problem = 'its scheduled task \WAU\Winget-AutoUpdate is disabled'; CheckFailed = $false } }

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.New' }) -NonInteractive | Should -Be 8

            $record = $script:reportedRecords[0]
            $record.exitCode | Should -Be 8
            $record.autoUpdates.status | Should -Be 'Unhealthy'
            $record.autoUpdates.version | Should -Be '2.12.0'
            Format-InstallerResultLine -Record $record | Should -Match '^RESULT: exit=8 installed=1 skipped=0 deferred=0 failed=0 notattempted=0 autoupdates=Unhealthy restart=no '
        }

        It 'Releases the run lock once it has reported, before the final prompt' {
            # A window left open at 'Press any key to exit...' must not make the next run (an RMM
            # schedule) exit 6.
            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.New' }) -NonInteractive | Should -Be 0

            $script:reportEvents | Should -Be @('report', 'unlock')
        }

        It 'Records an app whose install threw as failed' {
            Mock Install-AppWithVerification { throw 'boom from the pipeline' }

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.Throws' }) -NonInteractive | Should -Be 1

            $app = @($script:reportedRecords[0].apps)[0]
            $app.status | Should -Be 'Failed'
            $app.reason | Should -Be 'Unexpected error: boom from the pipeline'
        }

        It 'Records the exit code the run returns, winget''s state at the end and an auto-update outcome that is at risk' {
            Mock Install-WingetAutoUpdate { [pscustomobject]@{ Status = 'AlreadyPresent'; Version = [version]'2.12.0'; FrameworkMissing = $true; RestartRequired = $false } }
            Mock Test-WingetLaunchable { [pscustomobject]@{ Launchable = $false; Version = $null; Reason = 'Access is denied'; Attempts = 5 } }

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.New' }) -NonInteractive | Should -Be 2

            $script:reportedRecords[0].exitCode | Should -Be 2
            $script:reportedRecords[0].wingetUsable | Should -BeFalse
            $script:reportedRecords[0].autoUpdates.status | Should -Be 'AtRisk'
        }

        It 'Records winget''s state at the end as unknown when the end-of-run check could not run' {
            # A check that threw is not evidence either way: the exit code treats winget as usable,
            # but the record must not claim the check found it so.
            Mock Test-WingetLaunchable { throw 'probe bug' }

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.New' }) -NonInteractive | Should -Be 0

            Should -Invoke Write-WarningMessage -ParameterFilter { $Message -match 'Could not run the end-of-run winget check' }
            $script:reportedRecords[0].Contains('wingetUsable') | Should -BeTrue
            $script:reportedRecords[0].wingetUsable | Should -BeNullOrEmpty
        }

        It 'Keeps the apps it finished where the entry script can report them if the run stops early' {
            Mock Install-AppWithVerification { @{ Status = 'Installed'; InstallResult = @{ ExitCode = 0 }; FailureReason = $null } }
            Mock Install-WingetAutoUpdate { throw 'stopped' }

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.New' }) -NonInteractive | Out-Null

            @($script:InstallerAppRecords.Keys) | Should -Be @('Contoso.New')
            $script:InstallerAutoUpdateResult.Status | Should -Be 'Failed'
        }

        It 'Reports nothing for a dry run' {
            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.New' }) -WhatIf -NonInteractive | Out-Null

            Should -Invoke Write-InstallerRunResult -Times 0
            Should -Invoke Unlock-InstallerRun -Times 0
        }

        It 'Reports nothing for a run that returns before its summary: the entry script does that' {
            Mock Initialize-Winget { [pscustomobject]@{ Ready = $false; Diagnosis = 'NotLaunchable' } }

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.New' }) -NonInteractive | Should -Be 2

            Should -Invoke Write-InstallerRunResult -Times 0
            $script:InstallerRunReportPending | Should -BeTrue
        }

        It 'Leaves the report to the elevated run it relaunched, which printed and wrote its own' {
            Mock Test-IsAdmin { $false }
            Mock Test-InvokedFromModuleContext { $false }
            Mock Test-EffectiveNonInteractive { $false }
            Mock Restart-WithElevation { [pscustomobject]@{ Started = $true; ExitCode = 1 } }

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.New' }) | Should -Be 1

            Should -Invoke Write-InstallerRunResult -Times 0
            $script:InstallerRunReportPending | Should -BeFalse
        }

        It 'Lets the entry script report a relaunch that never started (the prompt was declined)' {
            Mock Test-IsAdmin { $false }
            Mock Test-InvokedFromModuleContext { $false }
            Mock Test-EffectiveNonInteractive { $false }
            Mock Restart-WithElevation { [pscustomobject]@{ Started = $false; ExitCode = 4 } }

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.New' }) | Should -Be 4

            $script:InstallerRunReportPending | Should -BeTrue
        }
    }

    Context 'Run result: written to disk by a real run of the installer (review finding P3-41)' {
        BeforeEach {
            $script:savedLogPath = $script:InstallLogPath
            $script:savedRecordEnabled = $script:InstallerRunRecordEnabled
            $script:logDirectory = Join-Path $TestDrive ('run-result-' + [Guid]::NewGuid().ToString('N'))
            [void](New-Item -ItemType Directory -Path $script:logDirectory -Force)
            $script:InstallLogPath = Join-Path $script:logDirectory 'install-20261004-163005.log'
            $script:hostLines = [System.Collections.Generic.List[string]]::new()
            Mock Write-Host { $script:hostLines.Add([string]$Object) }
        }

        AfterEach {
            $script:InstallLogPath = $script:savedLogPath
            $script:InstallerRunRecordEnabled = $script:savedRecordEnabled
        }

        It 'Writes last-run.json next to the transcript and ends with the RESULT line, when the entry script allows it' {
            $script:InstallerRunRecordEnabled = $true

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.New' }) -NonInteractive | Should -Be 0

            $json = Get-Content -Raw -LiteralPath (Join-Path $script:logDirectory 'last-run.json') | ConvertFrom-Json
            $json.exitCode | Should -Be 0
            $json.apps[0].id | Should -Be 'Contoso.New'
            $json.transcriptPath | Should -Be $script:InstallLogPath
            $script:hostLines[$script:hostLines.Count - 1] | Should -Match '^RESULT: exit=0 installed=1 skipped=0 deferred=0 failed=0 notattempted=0 autoupdates=DryRun restart=no build=\S+ log=.*install-20261004-163005\.log$'
        }

        It 'Writes a Deferred app and the exit code 8 of an unhealthy Winget-AutoUpdate to last-run.json (review findings P3-22, P3-36)' {
            $script:InstallerRunRecordEnabled = $true
            Mock Get-InstallAccountContext { New-TestAccountContext -System }
            Mock Install-AppWithVerification {
                if ($App.name -eq 'Contoso.UserOnly') {
                    return @{ Status = 'Deferred'; InstallResult = @{ ExitCode = -1978335216; Attempts = 1; NoMachineScopeInstaller = $true }; FailureReason = $null; DeferReason = 'NoMachineScopeInstaller' }
                }
                @{ Status = 'Installed'; InstallResult = @{ ExitCode = 0; Attempts = 1 }; FailureReason = $null }
            }
            Mock Install-WingetAutoUpdate { [pscustomobject]@{ Status = 'Unhealthy'; Version = [version]'2.12.0'; FrameworkMissing = $false; RestartRequired = $false; Problem = 'its scheduled task could not be checked'; CheckFailed = $true } }

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.New' }, @{ name = 'Contoso.UserOnly' }) -NonInteractive | Should -Be 8

            $json = Get-Content -Raw -LiteralPath (Join-Path $script:logDirectory 'last-run.json') | ConvertFrom-Json
            $json.exitCode | Should -Be 8
            $json.counts.installed | Should -Be 1
            $json.counts.deferred | Should -Be 1
            $json.counts.failed | Should -Be 0
            $json.apps[1].id | Should -Be 'Contoso.UserOnly'
            $json.apps[1].status | Should -Be 'Deferred'
            $json.autoUpdates.status | Should -Be 'Unhealthy'
            $script:hostLines[$script:hostLines.Count - 1] | Should -Match '^RESULT: exit=8 installed=1 skipped=0 deferred=1 failed=0 notattempted=0 autoupdates=Unhealthy restart=no '
        }

        It 'Only prints the RESULT line when the entry script did not allow the record (or outside it)' {
            $script:InstallerRunRecordEnabled = $false

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.New' }) -NonInteractive | Should -Be 0

            Test-Path -LiteralPath (Join-Path $script:logDirectory 'last-run.json') | Should -BeFalse
            @($script:hostLines | Where-Object { $_ -like 'RESULT: *' }).Count | Should -Be 1
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

            # winget said the install failed (exit 1, a code the table does not name), so the reason
            # says that rather than 'package not found after install' (review finding P2-15).
            $script:errorMessages | Should -Contain 'Retry failed: Contoso.AppOne (winget install failed; winget exit 0x00000001, 1 attempt).'
        }

        # Review finding P3-34: every outcome other than Failed used to be 'Retry succeeded' and
        # counted as installed, a not-applicable skip included (exit 0 with the app missing).
        It 'Buckets a not-applicable retry outcome as Skipped with its reason, never as Retry succeeded or Installed' {
            $script:appCalls = 0
            Mock Install-AppWithVerification {
                $script:appCalls++
                if ($script:appCalls -eq 1) {
                    return @{ Status = 'Failed'; InstallResult = @{ ExitCode = 1 }; FailureReason = 'VerifyNotFound' }
                }
                @{ Status = 'Skipped'; InstallResult = $null; FailureReason = $null; SkipReason = 'NotApplicable' }
            }
            $script:successMessages = @()
            Mock Write-Success { $script:successMessages += $Message }

            $result = Invoke-WingetInstall -Apps @(@{ name = 'Contoso.GatedApp'; condition = { $true }; conditionDescription = 'Contoso hardware only' }) -NonInteractive

            $script:appCalls | Should -Be 2
            $script:warningMessages | Should -Contain 'Skipping: Contoso.GatedApp (not applicable: Contoso hardware only)'
            $script:successMessages | Should -Not -Contain 'Retry succeeded: Contoso.GatedApp'
            @($script:capturedRows | Where-Object { $_[0] -eq 'Installed' }).Count | Should -Be 0
            @($script:capturedRows | Where-Object { $_[0] -eq 'Skipped' })[0][1] | Should -Match 'Contoso\.GatedApp'
            @($script:capturedRows | Where-Object { $_[0] -eq 'Failed' }).Count | Should -Be 0
            $result | Should -Be 0
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

    # wgt-gq8.41: a whole-run time budget for an RMM job with a hard time limit. Once it is used up,
    # no app install, retry or Winget-AutoUpdate setup starts; what is left is NotAttempted and the
    # run returns 9. Test-InstallerRunBudgetSpent is mocked where a test needs the budget to run out
    # at a given point; RunBudget.Tests.ps1 tests the clock itself.
    Context 'Time budget (-MaxRuntimeMinutes, wgt-gq8.41)' {
        BeforeEach {
            $script:savedBudgetVariable = $env:WINGET_APP_SETUP_MAX_RUNTIME_MINUTES
            Remove-Item -Path Env:\WINGET_APP_SETUP_MAX_RUNTIME_MINUTES -ErrorAction SilentlyContinue
            $script:savedRunStarted = $script:InstallerRunStartedUtc
            $script:InstallerRunStartedUtc = [DateTime]::UtcNow
            $script:reportedRecords = @()
            Mock Write-InstallerRunResult { $script:reportedRecords += , $Record; $null }
            Mock Unlock-InstallerRun { }
            # The pipeline's own gate (tested in 'Install-AppWithVerification and the time budget').
            Mock Install-AppWithVerification {
                if ($TimeBudgetSpent) {
                    return @{ Status = 'NotAttempted'; InstallResult = $null; FailureReason = $null }
                }
                @{ Status = 'Installed'; InstallResult = @{ ExitCode = 0; Attempts = 1 }; FailureReason = $null }
            }
            Mock Install-WingetAutoUpdate { [pscustomobject]@{ Status = 'Configured'; Version = [version]'2.12.0'; FrameworkMissing = $false; RestartRequired = $false } }
            $script:apps = @(@{ name = 'Contoso.First' }, @{ name = 'Contoso.Second' }, @{ name = 'Contoso.Third' })
        }

        AfterEach {
            $script:InstallerRunStartedUtc = $script:savedRunStarted
            if ($null -eq $script:savedBudgetVariable) {
                Remove-Item -Path Env:\WINGET_APP_SETUP_MAX_RUNTIME_MINUTES -ErrorAction SilentlyContinue
            }
            else {
                $env:WINGET_APP_SETUP_MAX_RUNTIME_MINUTES = $script:savedBudgetVariable
            }
        }

        It 'Changes nothing without a budget: every app and the auto-update setup run, and no time budget is mentioned' {
            Invoke-WingetInstall -Apps $script:apps -NonInteractive | Should -Be 0

            Should -Invoke Install-AppWithVerification -Times 3 -Exactly -ParameterFilter { -not $TimeBudgetSpent }
            Should -Invoke Install-WingetAutoUpdate -Times 1 -Exactly
            # Its own default wait, as before.
            Should -Invoke Wait-WauIdle -Times 1 -Exactly -ParameterFilter { -not $PesterBoundParameters.ContainsKey('TimeoutSeconds') }
            ((@($script:infoMessages) + @($script:warningMessages)) -join "`n") | Should -Not -Match 'Time budget'
            @($script:capturedRows | Where-Object { $_[0] -eq 'Not attempted' }) | Should -HaveCount 0
        }

        It 'Starts no app install once the budget is used up: the apps left are not attempted, Winget-AutoUpdate is not set up, and it returns 9' {
            # Used up after the first app.
            $script:budgetChecks = 0
            Mock Test-InstallerRunBudgetSpent { $script:budgetChecks++; $script:budgetChecks -gt 1 }

            $result = Invoke-WingetInstall -Apps $script:apps -NonInteractive -MaxRuntimeMinutes 30

            @($result).Count | Should -Be 1
            $result | Should -Be 9
            Should -Invoke Install-AppWithVerification -Times 1 -Exactly -ParameterFilter { $App.name -eq 'Contoso.First' -and -not $TimeBudgetSpent }
            Should -Invoke Install-AppWithVerification -Times 2 -Exactly -ParameterFilter { $App.name -ne 'Contoso.First' -and $TimeBudgetSpent }
            Should -Invoke Install-WingetAutoUpdate -Times 0 -Exactly
            # winget is still checked at the end: an unusable winget (2) ranks above 9.
            Should -Invoke Test-WingetLaunchable -Times 1 -Exactly
            @($script:infoMessages | Where-Object { $_ -like 'Time budget: 30 minutes, until *' }) | Should -HaveCount 1
            $script:warningMessages | Should -Contain "Time budget: the run's 30-minute time budget was used up, so no further app install starts. The apps left are reported as not attempted; run the installer again to install them."
            $script:warningMessages | Should -Contain "Not attempted: Contoso.Second (the run's 30-minute time budget was used up)"
            $script:warningMessages | Should -Contain "Auto-updates: NOT ATTEMPTED - the run's 30-minute time budget was used up before Winget-AutoUpdate was set up; run the installer again to set it up."
            @($script:warningMessages | Where-Object { $_ -like "Time budget: USED UP - the run's 30-minute budget ran out at *Z, so these were not attempted: Contoso.Second, Contoso.Third, the Winget-AutoUpdate setup. Run the installer again to finish." }) | Should -HaveCount 1
            # Last row, after the ones e2e/TranscriptAssertions.ps1 reads.
            $script:capturedRows[-1][0] | Should -Be 'Not attempted'
            $script:capturedRows[-1][1] | Should -Match 'Contoso\.Second.*Contoso\.Third'
            ($script:errorMessages -join "`n") | Should -Not -Match 'Auto-updates:'

            $record = $script:reportedRecords[0]
            $record.exitCode | Should -Be 9
            $record.counts.installed | Should -Be 1
            $record.counts.notAttempted | Should -Be 2
            @($record.apps | ForEach-Object { '{0}={1}' -f $_.id, $_.status }) | Should -Be @('Contoso.First=Installed', 'Contoso.Second=NotAttempted', 'Contoso.Third=NotAttempted')
            @($record.apps)[1].reason | Should -Be "the run's 30-minute time budget was used up"
            $record.autoUpdates.status | Should -Be 'NotAttempted'
            Format-InstallerResultLine -Record $record | Should -Match '^RESULT: exit=9 installed=1 skipped=0 deferred=0 failed=0 notattempted=2 autoupdates=NotAttempted '
        }

        It 'Counts the budget from when the entry script started, so a run that started long ago attempts nothing' {
            # The real clock: the run started two hours ago, with a 60-minute budget.
            $script:InstallerRunStartedUtc = [DateTime]::UtcNow.AddHours(-2)

            Invoke-WingetInstall -Apps $script:apps -NonInteractive -MaxRuntimeMinutes 60 | Should -Be 9

            Should -Invoke Install-AppWithVerification -Times 3 -Exactly -ParameterFilter { $TimeBudgetSpent }
            Should -Invoke Install-WingetAutoUpdate -Times 0 -Exactly
            Should -Invoke Wait-WauIdle -Times 0 -Exactly
            $script:reportedRecords[0].counts.notAttempted | Should -Be 3
        }

        It 'Takes the budget from WINGET_APP_SETUP_MAX_RUNTIME_MINUTES when -MaxRuntimeMinutes is not given' {
            $env:WINGET_APP_SETUP_MAX_RUNTIME_MINUTES = '45'
            $script:InstallerRunStartedUtc = [DateTime]::UtcNow.AddMinutes(-50)

            Invoke-WingetInstall -Apps $script:apps -NonInteractive | Should -Be 9

            @($script:infoMessages | Where-Object { $_ -like 'Time budget: 45 minutes, until *' }) | Should -HaveCount 1
        }

        # Review of wgt-gq8.41: a -MaxRuntimeMinutes 0 that was given wins over the variable too.
        It 'Turns off the variable''s budget with a -MaxRuntimeMinutes 0 that was given' {
            $env:WINGET_APP_SETUP_MAX_RUNTIME_MINUTES = '45'
            $script:InstallerRunStartedUtc = [DateTime]::UtcNow.AddMinutes(-50)

            Invoke-WingetInstall -Apps $script:apps -NonInteractive -MaxRuntimeMinutes 0 | Should -Be 0

            Should -Invoke Install-AppWithVerification -Times 3 -Exactly -ParameterFilter { -not $TimeBudgetSpent }
            Should -Invoke Install-WingetAutoUpdate -Times 1 -Exactly
            ((@($script:infoMessages) + @($script:warningMessages)) -join "`n") | Should -Not -Match 'Time budget'
        }

        It 'Passes a -MaxRuntimeMinutes 0 that was given on to the elevated run, so it does not take the variable''s budget' {
            $env:WINGET_APP_SETUP_MAX_RUNTIME_MINUTES = '45'
            Mock Test-IsAdmin { $false }
            Mock Test-InvokedFromModuleContext { $false }
            Mock Test-EffectiveNonInteractive { $false }
            $script:InstallerScriptSha256 = 'C0FFEE' + ('0' * 58)
            $script:forwarded = $null
            Mock Restart-WithElevation { $script:forwarded = @($AdditionalArguments); [pscustomobject]@{ Started = $true; ExitCode = 0 } }

            try {
                Invoke-WingetInstall -Apps $script:apps -SkipSystemCheck -MaxRuntimeMinutes 0 | Should -Be 0
            }
            finally {
                $script:InstallerScriptSha256 = $null
                $script:InstallerPendingExitCode = $null
            }

            $script:forwarded | Should -Be @('-SkipSystemCheck', '-MaxRuntimeMinutes', '0')
        }

        It 'Lets an app finish whose install started before the deadline, and returns 0 when nothing was left' {
            # Used up only after the last app; the Winget-AutoUpdate check comes before that.
            $script:budgetChecks = 0
            Mock Test-InstallerRunBudgetSpent { $script:budgetChecks++; $script:budgetChecks -gt 4 }

            Invoke-WingetInstall -Apps $script:apps -NonInteractive -MaxRuntimeMinutes 30 | Should -Be 0

            Should -Invoke Install-AppWithVerification -Times 3 -Exactly -ParameterFilter { -not $TimeBudgetSpent }
            Should -Invoke Install-WingetAutoUpdate -Times 1 -Exactly
            ($script:warningMessages -join "`n") | Should -Not -Match 'Time budget: USED UP'
        }

        It 'Skips only the Winget-AutoUpdate setup when the budget runs out after the last app, and returns 9' {
            $script:budgetChecks = 0
            Mock Test-InstallerRunBudgetSpent { $script:budgetChecks++; $script:budgetChecks -gt 3 }

            Invoke-WingetInstall -Apps $script:apps -NonInteractive -MaxRuntimeMinutes 30 | Should -Be 9

            Should -Invoke Install-WingetAutoUpdate -Times 0 -Exactly
            $script:warningMessages | Should -Contain "Not setting up Winget-AutoUpdate (or the Windows App Runtime it needs): the run's 30-minute time budget was used up. The next run sets it up."
            @($script:warningMessages | Where-Object { $_ -like 'Time budget: USED UP - * so these were not attempted: the Winget-AutoUpdate setup. Run the installer again to finish.' }) | Should -HaveCount 1
            $script:reportedRecords[0].counts.notAttempted | Should -Be 0
            $script:reportedRecords[0].autoUpdates.status | Should -Be 'NotAttempted'
        }

        It 'Starts no retry once the budget is used up: the app stays failed and the run returns 1, not 9' {
            Mock Install-AppWithVerification { @{ Status = 'Failed'; InstallResult = @{ ExitCode = 1603; Attempts = 1 }; FailureReason = 'VerifyNotFound' } }
            # Used up after the first pass.
            $script:budgetChecks = 0
            Mock Test-InstallerRunBudgetSpent { $script:budgetChecks++; $script:budgetChecks -gt 1 }

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.First' }) -NonInteractive -MaxRuntimeMinutes 30 | Should -Be 1

            Should -Invoke Install-AppWithVerification -Times 1 -Exactly
            $script:warningMessages | Should -Contain "Time budget: the run's 30-minute time budget was used up, so no further retry starts."
            $script:warningMessages | Should -Contain "Not retrying Contoso.First: the run's 30-minute time budget was used up."
            $script:reportedRecords[0].apps[0].status | Should -Be 'Failed'
            $script:reportedRecords[0].autoUpdates.status | Should -Be 'NotAttempted'
        }

        It 'Returns 2, not 9, when winget is no longer usable at the end' {
            Mock Test-InstallerRunBudgetSpent { $true }
            Mock Test-WingetLaunchable { [pscustomobject]@{ Launchable = $false; Version = $null; Reason = 'winget could not be started: Access is denied'; Attempts = 5 } }

            Invoke-WingetInstall -Apps $script:apps -NonInteractive -MaxRuntimeMinutes 30 | Should -Be 2
        }

        It 'Waits for a running Winget-AutoUpdate no longer than the budget has left (<Left> seconds left: <Expected>)' -ForEach @(
            @{ Left = 120; Expected = 120 }
            @{ Left = 5000; Expected = 900 }
        ) {
            $script:secondsLeft = $Left
            Mock Get-InstallerRunBudgetSecondsLeft { $script:secondsLeft }

            [void](Invoke-WingetInstall -Apps $script:apps -NonInteractive -MaxRuntimeMinutes 30)

            Should -Invoke Wait-WauIdle -Times 1 -Exactly -ParameterFilter { $TimeoutSeconds -eq $Expected }
        }

        # Review of wgt-gq8.41: an install that starts just before the deadline must not then wait
        # up to 10 minutes for a busy Windows Installer.
        It 'Lets an install or the Winget-AutoUpdate setup wait for a busy Windows Installer no longer than the budget has left (<Left> seconds left: <Expected>)' -ForEach @(
            @{ Left = 120; Expected = 120 }
            @{ Left = 5000; Expected = 600 }
        ) {
            $script:secondsLeft = $Left
            Mock Get-InstallerRunBudgetSecondsLeft { $script:secondsLeft }
            # Failed in the first pass, installed by the retry.
            $script:installCalls = 0
            Mock Install-AppWithVerification {
                $script:installCalls++
                if ($script:installCalls -eq 1) {
                    return @{ Status = 'Failed'; InstallResult = @{ ExitCode = 1603; Attempts = 1 }; FailureReason = 'VerifyNotFound' }
                }
                @{ Status = 'Installed'; InstallResult = @{ ExitCode = 0; Attempts = 1 }; FailureReason = $null }
            }

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.First' }) -NonInteractive -MaxRuntimeMinutes 30 | Should -Be 0

            Should -Invoke Install-AppWithVerification -Times 2 -Exactly
            Should -Invoke Install-AppWithVerification -Times 2 -Exactly -ParameterFilter { $InstallInProgressWaitSeconds -eq $Expected }
            Should -Invoke Install-WingetAutoUpdate -Times 1 -Exactly -ParameterFilter { $InstallInProgressWaitSeconds -eq $Expected }
        }

        It 'Does not cut a dry run short, and says what a real run would do' {
            Mock Test-InstallerRunBudgetSpent { $true }

            Invoke-WingetInstall -Apps $script:apps -NonInteractive -WhatIf -MaxRuntimeMinutes 30 | Should -Be 0

            Should -Invoke Install-AppWithVerification -Times 3 -Exactly -ParameterFilter { -not $TimeBudgetSpent }
            Should -Invoke Install-WingetAutoUpdate -Times 1 -Exactly
            @($script:infoMessages | Where-Object { $_ -like '`[DRY-RUN`] Time budget: 30 minutes, until *. A real run starts no app install and no Winget-AutoUpdate setup after that, and exits 9; this preview is not cut short.' }) | Should -HaveCount 1
        }

        It 'Passes the budget, with the deadline it counts from, to the elevated run (<Case>)' -ForEach @(
            @{ Case = 'its own deadline'; Inherited = $null; StartOffsetMinutes = -10 }
            @{ Case = 'a deadline an earlier phase passed on'; Inherited = 'inherited'; StartOffsetMinutes = 0 }
        ) {
            Mock Test-IsAdmin { $false }
            Mock Test-InvokedFromModuleContext { $false }
            Mock Test-EffectiveNonInteractive { $false }
            $script:InstallerScriptSha256 = 'C0FFEE' + ('0' * 58)
            $start = [DateTime]::SpecifyKind([DateTime]::UtcNow.AddMinutes($StartOffsetMinutes), [DateTimeKind]::Utc)
            $script:InstallerRunStartedUtc = $start
            $expectedDeadline = Format-RunRecordTime -Time $start.AddMinutes(30)
            $deadlineParameter = @{}
            if ($Inherited) {
                $expectedDeadline = Format-RunRecordTime -Time $start.AddMinutes(12)
                $deadlineParameter['RunDeadlineUtc'] = $expectedDeadline
            }
            $script:forwarded = $null
            Mock Restart-WithElevation { $script:forwarded = @($AdditionalArguments); [pscustomobject]@{ Started = $true; ExitCode = 9 } }

            try {
                Invoke-WingetInstall -Apps $script:apps -SkipSystemCheck -MaxRuntimeMinutes 30 @deadlineParameter | Should -Be 9
            }
            finally {
                $script:InstallerScriptSha256 = $null
                $script:InstallerPendingExitCode = $null
            }

            $script:forwarded | Should -Be @('-SkipSystemCheck', '-MaxRuntimeMinutes', '30', '-RunDeadlineUtc', $expectedDeadline)
            Should -Invoke Install-AppWithVerification -Times 0 -Exactly
        }

        It 'Passes no budget to the elevated run without one' {
            Mock Test-IsAdmin { $false }
            Mock Test-InvokedFromModuleContext { $false }
            Mock Test-EffectiveNonInteractive { $false }
            $script:forwarded = $null
            Mock Restart-WithElevation { $script:forwarded = @($AdditionalArguments); [pscustomobject]@{ Started = $true; ExitCode = 0 } }

            try {
                Invoke-WingetInstall -Apps $script:apps -SkipSystemCheck | Should -Be 0
            }
            finally {
                $script:InstallerPendingExitCode = $null
            }

            $script:forwarded | Should -Be @('-SkipSystemCheck')
        }

        It 'Rejects a -MaxRuntimeMinutes outside 0 to 1440 when the parameter is bound (<_>)' -ForEach @(-1, 1441) {
            { Invoke-WingetInstall -Apps $script:apps -NonInteractive -MaxRuntimeMinutes $_ } | Should -Throw -ErrorId 'ParameterArgumentValidationError,Invoke-WingetInstall'
            Should -Invoke Install-AppWithVerification -Times 0 -Exactly
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

    It 'Passes the run''s remaining wait budget for another installation to Install-WingetPackage (review finding P2-15)' {
        [void](Install-AppWithVerification -App @{ name = 'Test.App' } -InstallInProgressWaitSeconds 240)
        [void](Install-AppWithVerification -App @{ name = 'Test.App' })

        Should -Invoke Install-WingetPackage -Times 1 -Exactly -ParameterFilter { $PesterBoundParameters.ContainsKey('InstallInProgressWaitSeconds') -and $InstallInProgressWaitSeconds -eq 240 }
        # Not given: Install-WingetPackage's own default.
        Should -Invoke Install-WingetPackage -Times 1 -Exactly -ParameterFilter { -not $PesterBoundParameters.ContainsKey('InstallInProgressWaitSeconds') }
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

        # Review finding P3-34: the caller's once-per-run verdict wins over the condition.
        It 'Skips the app as NotApplicable on -Applicable $false without evaluating its condition' {
            $script:conditionCalls = 0

            $result = Install-AppWithVerification -App @{ name = 'Contoso.GatedApp'; condition = { $script:conditionCalls++; $true } } -Applicable $false

            $result.Status | Should -Be 'Skipped'
            $result.SkipReason | Should -Be 'NotApplicable'
            $script:conditionCalls | Should -Be 0
            Should -Invoke Test-WingetPackageInstalled -Times 0 -Exactly
            Should -Invoke Install-WingetPackage -Times 0 -Exactly
        }

        It 'Installs the app on -Applicable $true even when its condition would now say it does not apply' {
            $script:conditionCalls = 0
            $script:checkCount = 0
            Mock Test-WingetPackageInstalled {
                $script:checkCount++
                @{ Installed = ($script:checkCount -gt 1); TimedOut = $false; ExitCode = 0 }
            }

            $result = Install-AppWithVerification -App @{ name = 'Contoso.GatedApp'; condition = { $script:conditionCalls++; $false } } -Applicable $true

            $result.Status | Should -Be 'Installed'
            $script:conditionCalls | Should -Be 0
            Should -Invoke Install-WingetPackage -Times 1 -Exactly
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

        It 'Passes -Silent:<Value> to an installer that takes -Silent, and leaves it out when not given' -ForEach @(
            @{ Value = $true }
            @{ Value = $false }
        ) {
            $script:silentCalls = @()
            function Install-FakeSilentPowerShell {
                param ([switch]$Silent)
                $script:silentCalls += , @($PSBoundParameters.ContainsKey('Silent'), [bool]$Silent)
                @{ ExitCode = 0; Installed = $true; Method = 'msi' }
            }
            $app = @{ name = 'Microsoft.PowerShell'; install = 'Install-FakeSilentPowerShell' }

            [void](Install-AppWithVerification -App $app -Silent:$Value)
            [void](Install-AppWithVerification -App $app)

            $script:silentCalls.Count | Should -Be 2
            $script:silentCalls[0][0] | Should -Be $true
            $script:silentCalls[0][1] | Should -Be $Value
            $script:silentCalls[1][0] | Should -Be $false
        }

        It 'Passes the run''s remaining wait budget to an installer that takes it, and to no other (review finding P2-15)' {
            $script:budgetCalls = @()
            function Install-FakeBudgetPowerShell {
                param ([switch]$Silent, [int]$InstallInProgressWaitSeconds)
                $script:budgetCalls += , @($PSBoundParameters.ContainsKey('InstallInProgressWaitSeconds'), $InstallInProgressWaitSeconds)
                @{ ExitCode = 0; Installed = $true; Method = 'msi' }
            }
            function Install-FakePlainBudgetPowerShell { @{ ExitCode = 0; Installed = $true; Method = 'msi' } }

            [void](Install-AppWithVerification -App @{ name = 'Microsoft.PowerShell'; install = 'Install-FakeBudgetPowerShell' } -InstallInProgressWaitSeconds 240)
            [void](Install-AppWithVerification -App @{ name = 'Microsoft.PowerShell'; install = 'Install-FakeBudgetPowerShell' })
            $plain = Install-AppWithVerification -App @{ name = 'Microsoft.PowerShell'; install = 'Install-FakePlainBudgetPowerShell' } -InstallInProgressWaitSeconds 240

            $script:budgetCalls.Count | Should -Be 2
            $script:budgetCalls[0] | Should -Be @($true, 240)
            $script:budgetCalls[1][0] | Should -Be $false
            $plain.Status | Should -Be 'Installed'
        }

        It 'Still calls an installer that has no -Silent parameter when -Silent is given' {
            function Install-FakePlainPowerShell { @{ ExitCode = 0; Installed = $true; Method = 'msi' } }

            $result = Install-AppWithVerification -App @{ name = 'Microsoft.PowerShell'; install = 'Install-FakePlainPowerShell' } -Silent

            $result.Status | Should -Be 'Installed'
        }

        It 'Maps a self-verifying installer''s <Case> to <Reason>, like every other app (review finding P3-8)' -ForEach @(
            @{ Case = 'install that could not launch winget'; Result = @{ ExitCode = $null; Installed = $false; LaunchErrorExhausted = $true; LaunchError = 'Access is denied.' }; Reason = 'InstallLaunchFailed'; LaunchError = 'Access is denied.' }
            @{ Case = 'check that could not launch winget'; Result = @{ ExitCode = 0; Installed = $false; VerifyLaunchFailed = $true; VerifyLaunchError = 'The file cannot be accessed by the system.' }; Reason = 'VerifyLaunchFailed'; LaunchError = 'The file cannot be accessed by the system.' }
            @{ Case = 'check that timed out'; Result = @{ ExitCode = 0; Installed = $false; VerifyTimedOut = $true }; Reason = 'VerifyTimeout'; LaunchError = $null }
        ) {
            $script:customResult = $Result
            $app = @{ name = 'Microsoft.PowerShell'; install = { $script:customResult } }

            $result = Install-AppWithVerification -App $app

            $result.Status | Should -Be 'Failed'
            $result.FailureReason | Should -Be $Reason
            $result.LaunchError | Should -Be $LaunchError
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

# Review finding P2-9: a `winget list` that could not start winget read as 'not installed', so
# the pipeline installed apps that were already there and reported them as 'package not found
# after install'. Only the winget process is mocked: the real Test-WingetPackageInstalled and
# Install-WingetPackage run.
# Review findings P3-22 and P3-24. A run as SYSTEM or under cross-user elevation installs for the
# whole PC: a package with no machine-scope installer used to be installed at winget's default
# scope, which is SYSTEM's own profile or the elevating admin's, and the verification, run as that
# same account, reported it installed. And an MSIX app was checked with `winget list`, which as
# SYSTEM sees no account's apps, so Windows Terminal, built into Windows 11, read as missing on every
# run and failed its verification.
Describe 'Install-AppWithVerification for the whole PC (-MachineWide; review findings P3-22, P3-24)' {
    BeforeEach {
        Mock Write-Host { }
        Mock Write-Info { }
        Mock Install-WingetPackage { @{ ExitCode = 0; Attempts = 1; SessionErrorExhausted = $false; MachineScopeFellBack = $false; NoMachineScopeInstaller = $false } }
        Mock Test-WingetPackageInstalled { @{ Installed = $false; TimedOut = $false; LaunchFailed = $false; LaunchError = $null; CheckFailed = $false; ExitCode = 0 } }
        Mock Test-AppxPackageProvisionedForMachine { $false }
    }

    It 'Asks Install-WingetPackage for machine scope only, and only for a run for the whole PC' {
        [void](Install-AppWithVerification -App @{ name = 'Contoso.App' } -MachineWide)
        [void](Install-AppWithVerification -App @{ name = 'Contoso.App' })

        Should -Invoke Install-WingetPackage -Times 1 -Exactly -ParameterFilter { $MachineScopeOnly }
        Should -Invoke Install-WingetPackage -Times 1 -Exactly -ParameterFilter { -not $MachineScopeOnly }
    }

    It 'Defers an app with no machine-scope installer instead of installing it for the account running this, without a post-install check' {
        Mock Install-WingetPackage { @{ ExitCode = -1978335216; Attempts = 1; SessionErrorExhausted = $false; MachineScopeFellBack = $false; NoMachineScopeInstaller = $true } }

        $result = Install-AppWithVerification -App @{ name = 'Contoso.UserOnlyApp' } -MachineWide

        $result.Status | Should -Be 'Deferred'
        $result.DeferReason | Should -Be 'NoMachineScopeInstaller'
        $result.FailureReason | Should -BeNullOrEmpty
        # The pre-check only: nothing was installed, so there is nothing to verify.
        Should -Invoke Test-WingetPackageInstalled -Times 1 -Exactly
    }

    It 'Defers PowerShell the same way when its own installer finds no machine-scope installer, and passes it -MachineScopeOnly' {
        Mock Install-PowerShellLatest { @{ ExitCode = -1978335216; Installed = $false; Method = 'msix-native'; NoMachineScopeInstaller = [bool]$MachineScopeOnly } }

        $result = Install-AppWithVerification -App @{ name = 'Microsoft.PowerShell'; install = 'Install-PowerShellLatest' } -MachineWide

        $result.Status | Should -Be 'Deferred'
        Should -Invoke Install-PowerShellLatest -Times 1 -Exactly -ParameterFilter { $MachineScopeOnly }
    }

    It 'Skips an MSIX app that is provisioned for every user, without winget' {
        Mock Test-AppxPackageProvisionedForMachine { $true }

        $result = Install-AppWithVerification -App @{ name = 'Microsoft.WindowsTerminal'; msixName = 'Microsoft.WindowsTerminal' } -MachineWide

        $result.Status | Should -Be 'Skipped'
        $result.SkipReason | Should -Be 'Provisioned'
        Should -Invoke Test-AppxPackageProvisionedForMachine -Times 1 -Exactly -ParameterFilter { $Name -eq 'Microsoft.WindowsTerminal' }
        Should -Invoke Test-WingetPackageInstalled -Times 0 -Exactly
        Should -Invoke Install-WingetPackage -Times 0 -Exactly
    }

    It 'Skips a provisioned MSIX app even when winget cannot be started' {
        Mock Test-AppxPackageProvisionedForMachine { $true }

        $result = Install-AppWithVerification -App @{ name = 'Microsoft.WindowsTerminal'; msixName = 'Microsoft.WindowsTerminal' } -MachineWide -WingetNotLaunchable

        $result.Status | Should -Be 'Skipped'
    }

    It 'Installs a missing MSIX app at machine scope and verifies it by provisioning, not with winget list (<Case>)' -ForEach @(
        @{ Case = 'provisioned after the install'; After = $true; Status = 'Installed'; Reason = $null }
        @{ Case = 'still not provisioned'; After = $false; Status = 'Failed'; Reason = 'VerifyNotFound' }
    ) {
        $script:provisionChecks = 0
        $script:provisionedAfter = $After
        Mock Test-AppxPackageProvisionedForMachine {
            $script:provisionChecks++
            ($script:provisionChecks -gt 1) -and $script:provisionedAfter
        }

        $result = Install-AppWithVerification -App @{ name = 'Microsoft.WindowsTerminal'; msixName = 'Microsoft.WindowsTerminal' } -MachineWide

        $result.Status | Should -Be $Status
        $result.FailureReason | Should -Be $Reason
        Should -Invoke Install-WingetPackage -Times 1 -Exactly -ParameterFilter { $MachineScopeOnly }
        Should -Invoke Test-AppxPackageProvisionedForMachine -Times 2 -Exactly
        Should -Invoke Test-WingetPackageInstalled -Times 0 -Exactly
    }

    It 'Fails an MSIX app into the retry pass when the provisioned packages cannot be read, without installing it' {
        Mock Test-AppxPackageProvisionedForMachine { $null }

        $result = Install-AppWithVerification -App @{ name = 'Microsoft.WindowsTerminal'; msixName = 'Microsoft.WindowsTerminal' } -MachineWide

        $result.Status | Should -Be 'Failed'
        $result.FailureReason | Should -Be 'MachineCheckFailed'
        Should -Invoke Install-WingetPackage -Times 0 -Exactly
    }

    It 'Lists a missing MSIX app as one a dry run would install' {
        $result = Install-AppWithVerification -App @{ name = 'Microsoft.WindowsTerminal'; msixName = 'Microsoft.WindowsTerminal' } -MachineWide -WhatIf

        $result.Status | Should -Be 'Installed'
        Should -Invoke Install-WingetPackage -Times 0 -Exactly
        Should -Invoke Test-WingetPackageInstalled -Times 0 -Exactly
    }

    It 'Checks an MSIX app with winget list as before in a signed-in user''s own run' {
        Mock Test-WingetPackageInstalled { @{ Installed = $true; TimedOut = $false; LaunchFailed = $false; LaunchError = $null; CheckFailed = $false; ExitCode = 0 } }

        $result = Install-AppWithVerification -App @{ name = 'Microsoft.WindowsTerminal'; msixName = 'Microsoft.WindowsTerminal' }

        $result.Status | Should -Be 'Skipped'
        $result.SkipReason | Should -BeNullOrEmpty
        Should -Invoke Test-AppxPackageProvisionedForMachine -Times 0 -Exactly
    }
}

Describe 'Install-AppWithVerification when winget cannot be launched (review finding P2-9)' {
    BeforeEach {
        Mock Write-Host { }
        Mock Write-WarningMessage { }
        Mock Write-Info { }
        Mock Start-Sleep { }
        Mock Test-EffectiveNonInteractive { $false }
        # Never read the machine's App Installer packages (the removed bypass path did).
        Mock Get-AppxPackage { }
        $script:launchFailure = New-TestProcessResult -LaunchFailed -LaunchErrorCode 1920 -LaunchError 'The file cannot be accessed by the system.'
    }

    It 'Fails the app as PreCheckLaunchFailed without trying to install it' {
        Mock Invoke-WingetProcess { $script:launchFailure }

        $result = Install-AppWithVerification -App @{ name = '7zip.7zip' }

        $result.Status | Should -Be 'Failed'
        $result.FailureReason | Should -Be 'PreCheckLaunchFailed'
        $result.LaunchError | Should -Be 'The file cannot be accessed by the system.'
        $result.InstallResult | Should -Be $null
        Should -Invoke Invoke-WingetProcess -Times 0 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'install' }
        Should -Invoke Invoke-WingetProcess -Times 1 -Exactly
        Format-InstallFailureReason -FailureReason $result.FailureReason -InstallResult $result.InstallResult -LaunchError $result.LaunchError |
            Should -Be 'winget could not be launched for the pre-install check; launch error: The file cannot be accessed by the system'
    }

    It 'Says that the post-install check could not launch winget, not that the package was not found' {
        $script:listCalls = 0
        Mock Invoke-WingetProcess {
            if ($ArgumentList[0] -eq 'install') {
                return New-TestProcessResult -ExitCode 0
            }
            $script:listCalls++
            if ($script:listCalls -eq 1) {
                return New-TestProcessResult -ExitCode -1978335212 -Output @('No installed package found matching input criteria.')
            }
            $script:launchFailure
        }

        $result = Install-AppWithVerification -App @{ name = '7zip.7zip' }

        $result.Status | Should -Be 'Failed'
        $result.FailureReason | Should -Be 'VerifyLaunchFailed'
        $result.LaunchError | Should -Be 'The file cannot be accessed by the system.'
        $result.InstallResult.ExitCode | Should -Be 0
        Format-InstallFailureReason -FailureReason $result.FailureReason -InstallResult $result.InstallResult -LaunchError $result.LaunchError |
            Should -Match '^winget could not be launched to verify the install; winget exit 0x00000000, 1 attempt'
    }

    It 'Fails the app as InstallLaunchFailed, without a post-install check, when winget could not be launched for the install' {
        Mock Invoke-WingetProcess {
            if ($ArgumentList[0] -eq 'install') {
                return New-TestProcessResult -LaunchFailed -LaunchErrorCode 5 -LaunchError 'Access is denied.'
            }
            New-TestProcessResult -ExitCode -1978335212 -Output @('No installed package found matching input criteria.')
        }

        $result = Install-AppWithVerification -App @{ name = '7zip.7zip' }

        $result.Status | Should -Be 'Failed'
        $result.FailureReason | Should -Be 'InstallLaunchFailed'
        $result.LaunchError | Should -Be 'Access is denied.'
        Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'list' }
    }

    It 'Runs no winget at all once the circuit breaker tripped, but still skips a not-applicable app' {
        Mock Invoke-WingetProcess { throw 'winget must not run once the breaker tripped' }

        $failed = Install-AppWithVerification -App @{ name = '7zip.7zip' } -WingetNotLaunchable
        $skipped = Install-AppWithVerification -App @{ name = 'Dell.CommandUpdate.Universal'; condition = { $false } } -WingetNotLaunchable

        $failed.Status | Should -Be 'Failed'
        $failed.FailureReason | Should -Be 'WingetNotLaunchable'
        $skipped.Status | Should -Be 'Skipped'
        $skipped.SkipReason | Should -Be 'NotApplicable'
        Should -Invoke Invoke-WingetProcess -Times 0 -Exactly
    }

    It 'Lists the app as one a real run would install in a dry run, where the run already said winget is unavailable' {
        Mock Invoke-WingetProcess { $script:launchFailure }

        $result = Install-AppWithVerification -App @{ name = '7zip.7zip' } -WhatIf

        $result.Status | Should -Be 'Installed'
        $result.FailureReason | Should -Be $null
    }

    # The rest of P2-9: a `winget list` that ran but failed (anything but 0 or 0x8A150014 without a
    # match) is no answer either. 0x8A15004B is APPINSTALLER_CLI_ERROR_FAILED_TO_OPEN_ALL_SOURCES.
    It 'Fails the app as PreCheckFailed, with the list''s exit code and without installing, when winget list ran and failed' {
        Mock Invoke-WingetProcess { New-TestProcessResult -ExitCode -1978335157 -Output @('Failed when opening source(s); try the ''source reset'' command if the problem persists.') }

        $result = Install-AppWithVerification -App @{ name = '7zip.7zip' }

        $result.Status | Should -Be 'Failed'
        $result.FailureReason | Should -Be 'PreCheckFailed'
        $result.CheckExitCode | Should -Be -1978335157
        $result.InstallResult | Should -Be $null
        Should -Invoke Invoke-WingetProcess -Times 0 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'install' }
        Format-InstallFailureReason -FailureReason $result.FailureReason -InstallResult $result.InstallResult -LaunchError $result.LaunchError -CheckExitCode $result.CheckExitCode |
            Should -Be 'winget list failed during the pre-install check with exit 0x8A15004B FAILED_TO_OPEN_ALL_SOURCES'
    }

    # wgt-gq8.63: without --source winget the list only warned that the source failed and exited
    # 0x8A150014, so the app read as not installed and an install was attempted that could not work.
    It 'Fails the app as PreCheckFailed, without installing, when the winget source cannot be opened (0x8A15000F)' {
        # What winget answers then: without --source a warning and 0x8A150014, with it 0x8A15000F.
        Mock Invoke-WingetProcess {
            if ($ArgumentList[0] -eq 'list' -and ($ArgumentList -join ' ') -notmatch '--source winget') {
                return New-TestProcessResult -ExitCode -1978335212 -Output @('Failed when searching source; results will not be included: winget', 'No installed package found matching input criteria.')
            }
            New-TestProcessResult -ExitCode -1978335217 -Output @("Failed when opening source(s); try the 'source reset' command if the problem persists.", '0x8a15000f : Data required by the source is missing')
        }

        $result = Install-AppWithVerification -App @{ name = '7zip.7zip' }

        $result.Status | Should -Be 'Failed'
        $result.FailureReason | Should -Be 'PreCheckFailed'
        $result.CheckExitCode | Should -Be -1978335217
        Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'list' -and ($ArgumentList -join ' ') -match '--source winget' }
        Should -Invoke Invoke-WingetProcess -Times 0 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'install' }
        Format-InstallFailureReason -FailureReason $result.FailureReason -InstallResult $result.InstallResult -LaunchError $result.LaunchError -CheckExitCode $result.CheckExitCode |
            Should -Be 'winget list failed during the pre-install check with exit 0x8A15000F SOURCE_DATA_MISSING'
    }

    It 'Says that the post-install winget list failed, with its exit code, not that the package was not found' {
        $script:listCalls = 0
        Mock Invoke-WingetProcess {
            if ($ArgumentList[0] -eq 'install') {
                return New-TestProcessResult -ExitCode 0
            }
            $script:listCalls++
            if ($script:listCalls -eq 1) {
                return New-TestProcessResult -ExitCode -1978335212 -Output @('No installed package found matching input criteria.')
            }
            New-TestProcessResult -ExitCode -1978335157 -Output @('Failed when opening source(s); try the ''source reset'' command if the problem persists.')
        }

        $result = Install-AppWithVerification -App @{ name = '7zip.7zip' }

        $result.Status | Should -Be 'Failed'
        $result.FailureReason | Should -Be 'VerifyFailed'
        $result.CheckExitCode | Should -Be -1978335157
        Format-InstallFailureReason -FailureReason $result.FailureReason -InstallResult $result.InstallResult -LaunchError $result.LaunchError -CheckExitCode $result.CheckExitCode |
            Should -Match '^winget list failed during the post-install check with exit 0x8A15004B FAILED_TO_OPEN_ALL_SOURCES; winget exit 0x00000000, 1 attempt'
    }

    It 'Maps a failed winget list in PowerShell''s own check to VerifyFailed too' {
        Mock Install-PowerShellLatest { @{ ExitCode = 0; Attempts = 1; Installed = $false; Method = 'msi'; VerifyTimedOut = $false; VerifyLaunchFailed = $false; VerifyLaunchError = $null; VerifyCheckFailed = $true; VerifyExitCode = -1978335157 } }
        Mock Invoke-WingetProcess { New-TestProcessResult -ExitCode -1978335212 -Output @('No installed package found matching input criteria.') }

        $result = Install-AppWithVerification -App @{ name = 'Microsoft.PowerShell'; install = 'Install-PowerShellLatest' }

        $result.Status | Should -Be 'Failed'
        $result.FailureReason | Should -Be 'VerifyFailed'
        $result.CheckExitCode | Should -Be -1978335157
    }
}

# wgt-gq8.41: with the run's time budget used up, the pipeline starts nothing that takes time, but
# still answers what needs no winget call: not applicable, and deferred to the user's own account.
Describe 'Install-AppWithVerification and the time budget (-TimeBudgetSpent, wgt-gq8.41)' {
    BeforeEach {
        Mock Write-Host { }
        Mock Write-Info { }
        Mock Install-WingetPackage { throw 'no install once the time budget is used up' }
        Mock Test-WingetPackageInstalled { throw 'no winget list once the time budget is used up' }
        Mock Test-AppxPackageProvisionedForMachine { throw 'no provisioning query once the time budget is used up' }
        Mock Install-PowerShellLatest { throw 'no package-specific installer once the time budget is used up' }
    }

    It 'Does not attempt an app that applies: no check, no install, no post-install hook (<Case>)' -ForEach @(
        @{ Case = 'a winget app'; App = @{ name = 'Contoso.App' }; MachineWide = $false }
        @{ Case = 'a package-specific installer'; App = @{ name = 'Microsoft.PowerShell'; install = 'Install-PowerShellLatest' }; MachineWide = $false }
        @{ Case = 'an MSIX app in a run for the whole PC'; App = @{ name = 'Contoso.Msix'; msixName = 'Contoso.Msix' }; MachineWide = $true }
    ) {
        $result = Install-AppWithVerification -App $App -Applicable $true -MachineWide:$MachineWide -TimeBudgetSpent

        $result.Status | Should -Be 'NotAttempted'
        $result.FailureReason | Should -BeNullOrEmpty
        $result.InstallResult | Should -BeNullOrEmpty
        Should -Invoke Test-WingetPackageInstalled -Times 0 -Exactly
        Should -Invoke Install-WingetPackage -Times 0 -Exactly
        Should -Invoke Test-AppxPackageProvisionedForMachine -Times 0 -Exactly
        Should -Invoke Install-PowerShellLatest -Times 0 -Exactly
    }

    It 'Still skips an app that does not apply' {
        $result = Install-AppWithVerification -App @{ name = 'Contoso.App' } -Applicable $false -TimeBudgetSpent

        $result.Status | Should -Be 'Skipped'
        $result.SkipReason | Should -Be 'NotApplicable'
    }

    It 'Still defers a per-user app in a run for the whole PC, so the user phase installs it' {
        $result = Install-AppWithVerification -App @{ name = 'Contoso.UserApp'; scope = 'user' } -Applicable $true -MachineWide -TimeBudgetSpent

        $result.Status | Should -Be 'Deferred'
        $result.DeferReason | Should -Be 'UserScope'
    }
}

Describe 'PowerShell''s own installer in the install pipeline (review of findings P2-5 and P2-6)' {
    # Install-AppWithVerification -> Install-PowerShellLatest -> Install-WingetPackage, with only the
    # winget process mocked: the path the catalog's Microsoft.PowerShell entry takes.
    BeforeEach {
        Mock Write-Host { }
        Mock Write-Info { }
        Mock Write-Success { }
        Mock Write-WarningMessage { }
        Mock Write-ErrorMessage { }
        # An attended console: only an explicit -Silent may add --silent.
        Mock Test-EffectiveNonInteractive { $false }
        Mock Test-WingetPackageInstalled { @{ Installed = $false; TimedOut = $false; ExitCode = 0 } }
        Mock Install-MsixProvisionedPackage { throw 'the MSI path must not fall through to DISM provisioning' }
        $script:installerLog = Join-Path $TestDrive 'winget-install-Microsoft.PowerShell-20261004-101500.log'
        Set-Content -LiteralPath $script:installerLog -Value 'MSI (s) (A0:B4) [10:15:00:000]: Product: PowerShell 7-x64 -- Installation failed.'
        Mock Invoke-WingetProcess { New-TestProcessResult -TimedOut -LogPath $script:installerLog }
    }

    It 'Installs the MSI with --silent when the run asked for -Silent (an explicit -NonInteractive)' {
        [void](Install-AppWithVerification -App @{ name = 'Microsoft.PowerShell'; install = 'Install-PowerShellLatest' } -Silent)

        Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'install' -and $ArgumentList -contains '--silent' }
    }

    It 'Names the time limit and the installer log in a stopped install''s failure reason' {
        $result = Install-AppWithVerification -App @{ name = 'Microsoft.PowerShell'; install = 'Install-PowerShellLatest' } -Silent

        $result.Status | Should -Be 'Failed'
        $result.FailureReason | Should -Be 'CustomInstallFailed'
        $reason = Format-InstallFailureReason -FailureReason $result.FailureReason -InstallResult $result.InstallResult
        $reason | Should -Match 'winget install stopped after 30 minutes'
        $reason | Should -Match ([regex]::Escape("installer log: $($script:installerLog)"))
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
        Mock Restart-WithElevation { [pscustomobject]@{ Started = $true; ExitCode = 0 } }
        Mock Test-IsRunningLocally { $true }
        Mock Initialize-Winget { [pscustomobject]@{ Ready = $true; Diagnosis = 'Ok' } }
        Mock Remove-LegacyScheduledUpdates { $true }
        Mock Set-WindowsTerminalDefaults { }
        Mock Install-WingetAutoUpdate { @{ Status = 'DryRun'; Version = '2.12.0' } }
        Mock Get-PendingRestartState { New-TestRestartState }
        Mock Get-ProxyInheritanceWarning { $null }
        Mock Get-ScriptExecutionPolicyBlock { $null }
        Mock Get-WingetPolicyBlock { $null }
        Mock Get-InstallAccountContext { New-TestAccountContext }
        Mock Install-WingetPackage { @{ ExitCode = 0; Attempts = 1; SessionErrorExhausted = $false; MachineScopeFellBack = $false } }
        Mock Test-WingetPackageInstalled { @{ Installed = $false; TimedOut = $false; LaunchFailed = $false; LaunchError = $null; ExitCode = 0 } }

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

    # Review finding P3-32: the catalog's two Reader entries, real conditions and all, with only the
    # architecture mocked. Gating the 64-bit Reader alone left an ARM64 PC with no PDF reader.
    It 'Installs <Installs> and skips <Skips> as not applicable on <Architecture>' -ForEach @(
        @{ Architecture = 'Arm64'; Installs = 'Adobe.Acrobat.Reader.32-bit'; Skips = 'Adobe.Acrobat.Reader.64-bit' }
        @{ Architecture = 'X64'; Installs = 'Adobe.Acrobat.Reader.64-bit'; Skips = 'Adobe.Acrobat.Reader.32-bit' }
    ) {
        $script:mockedArchitecture = $Architecture
        Mock Get-OSArchitecture { $script:mockedArchitecture }
        $apps = @(Get-DefaultAppCatalog | Where-Object { $_.name -like 'Adobe.Acrobat.Reader.*' })
        $skipped = $apps | Where-Object { $_.name -eq $Skips }

        Invoke-WingetInstall -Apps $apps -WhatIf -NonInteractive

        $script:warningMessages | Should -Contain "Skipping: $Skips (not applicable: $($skipped.conditionDescription))"
        Should -Invoke Test-WingetPackageInstalled -Times 1 -Exactly -ParameterFilter { $PackageId -eq $Installs }
        Should -Invoke Test-WingetPackageInstalled -Times 0 -Exactly -ParameterFilter { $PackageId -eq $Skips }
        @($script:capturedRows | Where-Object { $_[0] -eq 'Installed' })[0][1] | Should -Be $Installs
        @($script:capturedRows | Where-Object { $_[0] -eq 'Skipped' })[0][1] | Should -Be $Skips
        @($script:capturedRows | Where-Object { $_[0] -eq 'Failed' }).Count | Should -Be 0
    }
}

# Review findings P2-24, P3-22, P3-23 and P3-24, through the real orchestrator and the real
# per-app pipeline as an RMM agent runs it: as SYSTEM, with a user signed in at the console. Only
# the account, the AppX queries and the winget process are mocked. Before, such a run found no
# winget (SYSTEM has no alias), registered, repaired and downloaded App Installer for minutes and
# stopped with exit code 2; with a winget, it would have installed user-only apps into SYSTEM's own
# profile, failed Windows Terminal on every run and told the technician to sign in as SYSTEM.
Describe 'A run as SYSTEM from an RMM agent (review findings P2-24, P3-22, P3-23, P3-24)' {
    BeforeEach {
        Mock Write-Host { }
        Mock Test-IsAdmin { $true }
        Mock Test-IsRunningLocally { $true }
        Mock Test-IsSystemAccount { $true }
        Mock Get-ProcessUserName { 'NT AUTHORITY\SYSTEM' }
        Mock Get-InteractiveSessionUserName { 'CONTOSO\jdoe' }
        Mock Get-PendingRestartState { New-TestRestartState }
        Mock Get-ProxyInheritanceWarning { $null }
        Mock Get-ScriptExecutionPolicyBlock { $null }
        Mock Wait-WauIdle { $true }
        Mock Remove-LegacyScheduledUpdates { $false }
        Mock Install-WingetAutoUpdate { [pscustomobject]@{ Status = 'AlreadyPresent'; Version = '2.12.0' } }
        Mock Start-Sleep { }
        Mock Import-Module { }
        # Steps that set winget up for one account: none may run as SYSTEM.
        Mock Test-AndInstallWingetModule { throw 'must not install Microsoft.WinGet.Client for SYSTEM' }
        Mock Register-WingetAppInstallerForUser { throw 'must not register App Installer for SYSTEM' }
        Mock Invoke-WingetPackageManagerRepair { throw 'must not repair winget for SYSTEM' }
        Mock Repair-WinGetPackageManager { throw 'must not repair winget for SYSTEM' }
        Mock Invoke-WebRequest { throw 'must not download App Installer for SYSTEM' }
        Mock Add-AppxPackage { throw 'must not register a package for SYSTEM' }
        Mock Invoke-AppxRegistration { throw 'must not register a package for SYSTEM' }
        # No App Installer Group Policy on this PC (never the runner's real registry).
        Mock Get-WingetPolicyBlock { $null }
        # The console is hosted by Windows Terminal as far as the #271 check can tell; it must not
        # matter to SYSTEM.
        Mock Test-WindowsTerminalHostsCurrentSession { $true }

        # App Installer, installed for the machine.
        $script:appInstallerFolder = Join-Path $TestDrive 'WindowsApps\Microsoft.DesktopAppInstaller_1.27.460.0_x64__8wekyb3d8bbwe'
        [void](New-Item -ItemType Directory -Path $script:appInstallerFolder -Force)
        $script:machineWinget = Join-Path $script:appInstallerFolder 'winget.exe'
        Set-Content -LiteralPath $script:machineWinget -Value 'stand-in' -Encoding ascii
        Mock Get-DesktopAppInstallerPackageInfo { [pscustomobject]@{ Version = [version]'1.27.460.0'; Architecture = 'X64'; Status = 'Ok'; InstallLocation = $script:appInstallerFolder } }
        # Windows 11 provisions Windows Terminal for every user.
        Mock Get-ProvisionedAppxPackageName { 'Microsoft.WindowsStore'; 'Microsoft.WindowsTerminal' }

        # winget, as the machine-wide winget.exe answers: Contoso.MachineApp has a machine-scope
        # installer, Contoso.UserOnlyApp only a per-user one (0x8A150010 at --scope machine).
        $script:launches = @()
        $script:installedIds = @()
        Mock Invoke-ExternalProcess {
            $arguments = @($ArgumentList)
            $script:launches += [pscustomobject]@{ FilePath = $FilePath; Arguments = ($arguments -join ' ') }
            $id = $null
            $idIndex = [array]::IndexOf($arguments, '--id')
            if ($idIndex -ge 0) {
                $id = $arguments[$idIndex + 1]
            }
            switch ($arguments[0]) {
                '--version' { return New-TestProcessResult -ExitCode 0 -Output @('v1.12.350') }
                'source' {
                    if ($arguments[1] -eq 'list') {
                        return New-TestProcessResult -ExitCode 0 -Output @('Name   Argument', 'winget https://cdn.winget.microsoft.com/cache')
                    }
                    return New-TestProcessResult -ExitCode 0
                }
                'list' {
                    if ($script:installedIds -contains $id) {
                        return New-TestProcessResult -ExitCode 0 -Output @('Name Id Version', "App $id 1.0")
                    }
                    return New-TestProcessResult -ExitCode -1978335212 -Output @('No installed package found matching input criteria.')
                }
                'install' {
                    if ($arguments -contains '--scope' -and $id -eq 'Contoso.UserOnlyApp') {
                        return New-TestProcessResult -ExitCode -1978335216 -Output @('No applicable installer found; see logs for more details.')
                    }
                    $script:installedIds += $id
                    return New-TestProcessResult -ExitCode 0 -Output @('Successfully installed')
                }
            }
            New-TestProcessResult -ExitCode 0
        }

        $script:capturedRows = $null
        Mock Write-Table { if ($Title -eq 'Installation Summary') { $script:capturedRows = $Rows } }
        $script:messages = @()
        Mock Write-Info { $script:messages += $Message }
        Mock Write-Success { $script:messages += $Message }
        Mock Write-WarningMessage { $script:messages += $Message }
        Mock Write-ErrorMessage { $script:messages += $Message }

        $script:savedProgramW6432 = $env:ProgramW6432
        $env:ProgramW6432 = Join-Path $TestDrive 'no-program-files'
        # No transcript, so winget gets no --log folder to create.
        $script:InstallLogPath = $null
        $script:catalogTerminal = @(Get-DefaultAppCatalog | Where-Object { $_.name -eq 'Microsoft.WindowsTerminal' })[0]
    }

    AfterEach {
        $env:ProgramW6432 = $script:savedProgramW6432
        $script:MachineWingetPath = $null
    }

    It 'Installs the machine-wide apps with the machine-wide winget.exe, defers the user-only app and skips the provisioned Terminal' {
        $apps = @(@{ name = 'Contoso.MachineApp' }, @{ name = 'Contoso.UserOnlyApp' }, $script:catalogTerminal)

        $result = Invoke-WingetInstall -Apps $apps

        $result | Should -Be 0
        @($script:capturedRows | Where-Object { $_[0] -eq 'Installed' })[0][1] | Should -Be 'Contoso.MachineApp'
        @($script:capturedRows | Where-Object { $_[0] -eq 'Deferred' })[0][1] | Should -Be 'Contoso.UserOnlyApp'
        @($script:capturedRows | Where-Object { $_[0] -eq 'Skipped' })[0][1] | Should -Be 'Microsoft.WindowsTerminal'
        @($script:capturedRows | Where-Object { $_[0] -eq 'Failed' }).Count | Should -Be 0

        # Every winget call ran the machine-wide winget.exe: SYSTEM has no 'winget' on its PATH.
        $script:launches.Count | Should -BeGreaterThan 0
        @($script:launches | Where-Object { $_.FilePath -ne $script:machineWinget }).Count | Should -Be 0
        # Nothing at winget's default (per-user) scope, which for SYSTEM is its own profile.
        @($script:launches | Where-Object { $_.Arguments -match '^install ' -and $_.Arguments -notmatch '--scope machine' }).Count | Should -Be 0
        # Windows Terminal was decided from the machine, and never installed or listed with winget.
        @($script:launches | Where-Object { $_.Arguments -match 'Microsoft\.WindowsTerminal' }).Count | Should -Be 0
        # Unattended: winget installs silently.
        @($script:launches | Where-Object { $_.Arguments -match '^install ' -and $_.Arguments -notmatch '--silent' }).Count | Should -Be 0

        $text = $script:messages -join "`n"
        $text | Should -Match 'Skipping: Microsoft\.WindowsTerminal \(already provisioned for every user on this PC\)'
        $text | Should -Match 'Deferred: Contoso\.UserOnlyApp - winget found no machine-wide installer for it that applies to this PC \(0x8A150010 NO_APPLICABLE_INSTALLER with --scope machine\), and a run as SYSTEM installs for the whole PC only'
        $text | Should -Not -Match 'Cross-user elevation|log on to Windows|ADMIN account|NT AUTHORITY'
        Should -Invoke Test-AndInstallWingetModule -Times 0 -Exactly
        Should -Invoke Register-WingetAppInstallerForUser -Times 0 -Exactly
        Should -Invoke Invoke-WingetPackageManagerRepair -Times 0 -Exactly
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        Should -Invoke Add-AppxPackage -Times 0 -Exactly
        Should -Invoke Invoke-AppxRegistration -Times 0 -Exactly
    }

    # Work-order item 38: the catalog's per-user apps never reach winget as SYSTEM; an app that
    # allows only a machine-wide install fails instead of being deferred; and a machine app's hook
    # runs once it is installed.
    It 'Defers the catalog''s per-user apps without winget, fails a machine-only app with no machine-wide installer, and runs a hook' {
        $apps = @(
            @{ name = 'Contoso.MachineApp'; postInstall = { 'Configured' } },
            @{ name = 'Contoso.PerUserApp'; scope = 'user' },
            @{ name = 'Contoso.UserSetting'; userPhase = $true },
            @{ name = 'Contoso.UserOnlyApp'; scope = 'machine' }
        )
        $script:runRecord = $null
        Mock Write-InstallerRunResult { $script:runRecord = $Record }

        $result = Invoke-WingetInstall -Apps $apps

        $result | Should -Be 1
        @($script:capturedRows | Where-Object { $_[0] -eq 'Installed' })[0][1] | Should -Be 'Contoso.MachineApp'
        @($script:capturedRows | Where-Object { $_[0] -eq 'Deferred' })[0][1] | Should -Be 'Contoso.PerUserApp, Contoso.UserSetting'
        @($script:capturedRows | Where-Object { $_[0] -eq 'Failed' })[0][1] | Should -Be 'Contoso.UserOnlyApp'
        # winget was never asked about the per-user apps, and never at winget's default scope.
        @($script:launches | Where-Object { $_.Arguments -match 'Contoso\.(PerUserApp|UserSetting)' }).Count | Should -Be 0
        @($script:launches | Where-Object { $_.Arguments -match '^install ' -and $_.Arguments -notmatch '--scope machine' }).Count | Should -Be 0

        $text = $script:messages -join "`n"
        $text | Should -Match 'Configured: Contoso\.MachineApp'
        $text | Should -Match "Deferred: Contoso\.PerUserApp, Contoso\.UserSetting - the catalog marks them per-user \(scope 'user' or userPhase\), so they can be installed or set up only in the signed-in user's own account, and a run as SYSTEM installs for the whole PC only"
        $text | Should -Match "Failed to install: Contoso\.UserOnlyApp \(no machine-scope installer applies to this PC, and its catalog entry allows only a machine-wide install \(scope 'machine'\)"
        $text | Should -Not -Match 'Deferred: Contoso\.UserOnlyApp'

        $records = @($script:runRecord.apps)
        ($records | Where-Object { $_.id -eq 'Contoso.MachineApp' }).postInstall | Should -Be 'Configured'
        ($records | Where-Object { $_.id -eq 'Contoso.PerUserApp' }).status | Should -Be 'Deferred'
        ($records | Where-Object { $_.id -eq 'Contoso.UserSetting' }).status | Should -Be 'Deferred'
        ($records | Where-Object { $_.id -eq 'Contoso.UserOnlyApp' }).status | Should -Be 'Failed'
    }

    It 'Stops with exit code 2, saying so for SYSTEM, without any per-account step, when App Installer is not installed for the machine' {
        Mock Get-DesktopAppInstallerPackageInfo { }

        $result = Invoke-WingetInstall -Apps @(@{ name = 'Contoso.MachineApp' })

        $result | Should -Be 2
        ($script:messages -join "`n") | Should -Match 'No machine-wide winget was found'
        @($script:launches).Count | Should -Be 0
        Should -Invoke Register-WingetAppInstallerForUser -Times 0 -Exactly
        Should -Invoke Invoke-WingetPackageManagerRepair -Times 0 -Exactly
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        Should -Invoke Test-AndInstallWingetModule -Times 0 -Exactly
    }

    # wgt-gq8.42: the opt-in Microsoft.WinGet.Client engine. The engine's child pwsh is replaced
    # by a stand-in for Invoke-WingetClientRequest that answers as the module does.
    Context 'With WINGET_APP_SETUP_SYSTEM_ENGINE (the Microsoft.WinGet.Client engine)' {
        BeforeEach {
            $script:savedEngineVariable = $env:WINGET_APP_SETUP_SYSTEM_ENGINE
            $env:WINGET_APP_SETUP_SYSTEM_ENGINE = 'WinGetClient'
            $script:moduleReady = $true
            Mock Initialize-WingetClientModule {
                if (-not $script:moduleReady) {
                    return [pscustomobject]@{ Ready = $false; Reason = 'downloading the package failed: No such host is known' }
                }
                [pscustomobject]@{ Ready = $true; Reason = $null; Version = '1.29.380'; Sha256 = ('AB' * 32); Source = 'Download'; Directory = $null; ManifestPath = 'X:\m\Microsoft.WinGet.Client.psd1'; ChildScriptPath = 'X:\m\Invoke-WingetClientRequest.ps1'; PowerShellPath = 'X:\pwsh.exe'; Architecture = 'x64' }
            }
            $script:clientCalls = @()
            Mock Invoke-WingetClientRequest {
                $script:clientCalls += ('{0} {1}' -f $Operation, $PackageId).Trim()
                $response = @{ protocol = 1; operation = $Operation; stage = 'call'; ok = $true; psVersion = '7.6.6'; architecture = 'X64'; moduleVersion = '1.29.380' }
                switch ($Operation) {
                    'Probe' { $response.version = 'v1.29.380'; $response.packages = @(); $response.installedChecked = $true }
                    'Version' { $response.version = 'v1.29.380' }
                    'Installed' {
                        $response.packages = @()
                        if ($script:installedIds -contains $PackageId) {
                            $response.packages = @(@{ id = $PackageId; installedVersion = '1.0'; source = 'winget' })
                        }
                    }
                    'Install' {
                        $response.id = $PackageId
                        $response.installerErrorCode = 0
                        $response.rebootRequired = $false
                        if ($PackageId -eq 'Contoso.UserOnlyApp') {
                            $response.status = 'NoApplicableInstallers'
                            $response.hresult = -1978335216
                        }
                        else {
                            $script:installedIds += $PackageId
                            $response.status = 'Ok'
                            $response.hresult = 0
                        }
                    }
                }
                [pscustomobject]@{ Run = (New-TestProcessResult -ExitCode 0); Response = (ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $response -Depth 5)); ProtocolError = $null }
            }
            $script:engineActiveAtAutoUpdates = $null
            Mock Install-WingetAutoUpdate {
                $script:engineActiveAtAutoUpdates = Test-WingetClientEngineActive
                [pscustomobject]@{ Status = 'AlreadyPresent'; Version = '2.12.0' }
            }
            $script:runRecord = $null
            Mock Write-InstallerRunResult { $script:runRecord = $Record }
        }

        AfterEach {
            $env:WINGET_APP_SETUP_SYSTEM_ENGINE = $script:savedEngineVariable
            $script:WingetClientEngine = $null
            $script:InstallEngineRecord = $null
        }

        It 'Installs with Microsoft.WinGet.Client, defers the user-only app with -Scope System, and records the engine' {
            $apps = @(@{ name = 'Contoso.MachineApp' }, @{ name = 'Contoso.UserOnlyApp' }, $script:catalogTerminal)

            $result = Invoke-WingetInstall -Apps $apps

            $result | Should -Be 0
            @($script:capturedRows | Where-Object { $_[0] -eq 'Installed' })[0][1] | Should -Be 'Contoso.MachineApp'
            @($script:capturedRows | Where-Object { $_[0] -eq 'Deferred' })[0][1] | Should -Be 'Contoso.UserOnlyApp'
            @($script:capturedRows | Where-Object { $_[0] -eq 'Skipped' })[0][1] | Should -Be 'Microsoft.WindowsTerminal'
            $script:clientCalls | Should -Be @('Probe', 'Installed Contoso.MachineApp', 'Install Contoso.MachineApp', 'Installed Contoso.MachineApp', 'Installed Contoso.UserOnlyApp', 'Install Contoso.UserOnlyApp')
            # winget.exe installed and listed nothing; it was only checked, for Winget-AutoUpdate.
            @($script:launches | Where-Object { $_.Arguments -match '^(install|list|source) ' }).Count | Should -Be 0
            @($script:launches | Where-Object { $_.Arguments -eq '--version' -and $_.FilePath -eq $script:machineWinget }).Count | Should -BeGreaterThan 0
            # The engine's folder is gone before Winget-AutoUpdate and the end-of-run check.
            $script:engineActiveAtAutoUpdates | Should -BeFalse
            Test-WingetClientEngineActive | Should -BeFalse

            $text = $script:messages -join "`n"
            $text | Should -Match 'Running as SYSTEM \(for example from an RMM agent\): installing for the whole PC only, with the Microsoft\.WinGet\.Client module \(requested by WINGET_APP_SETUP_SYSTEM_ENGINE\), or the machine-wide winget\.exe if the module is not ready\.'
            $text | Should -Match 'Install engine: Microsoft\.WinGet\.Client 1\.29\.380 \(WinGet engine v1\.29\.380, PowerShell 7\.6\.6 x64; engine log folder '
            $text | Should -Match 'Deferred: Contoso\.UserOnlyApp - winget found no machine-wide installer for it that applies to this PC \(0x8A150010 NO_APPLICABLE_INSTALLER with -Scope System\), and a run as SYSTEM installs for the whole PC only'
            $text | Should -Not -Match 'was requested but not used'
            $script:runRecord.installEngine.requested | Should -Be 'WinGetClient'
            $script:runRecord.installEngine.used | Should -Be 'WinGetClient'
            $script:runRecord.installEngine.module.version | Should -Be '1.29.380'
            ($script:runRecord.apps | Where-Object { $_.id -eq 'Contoso.MachineApp' }).installerCode | Should -Be 0
            ($script:runRecord.apps | Where-Object { $_.id -eq 'Contoso.UserOnlyApp' }).codeHex | Should -Be '0x8A150010'
            Should -Invoke Test-AndInstallWingetModule -Times 0 -Exactly
        }

        It 'Records no installer exit code for the deferred app, whose installer never ran' {
            [void](Invoke-WingetInstall -Apps @(@{ name = 'Contoso.MachineApp' }, @{ name = 'Contoso.UserOnlyApp' }))

            ($script:runRecord.apps | Where-Object { $_.id -eq 'Contoso.MachineApp' }).installerCode | Should -Be 0
            $deferred = $script:runRecord.apps | Where-Object { $_.id -eq 'Contoso.UserOnlyApp' }
            $deferred.status | Should -Be 'Deferred'
            $deferred.installerCode | Should -BeNullOrEmpty
        }

        It 'Names the engine, not winget, when the engine stops starting mid-run, and skips the retry pass' {
            Mock Invoke-WingetClientRequest {
                $script:clientCalls += ('{0} {1}' -f $Operation, $PackageId).Trim()
                $response = @{ protocol = 1; operation = $Operation; stage = 'call'; ok = $true; psVersion = '7.6.6'; architecture = 'X64'; moduleVersion = '1.29.380' }
                switch ($Operation) {
                    'Probe' { $response.version = 'v1.29.380'; $response.packages = @(); $response.installedChecked = $true }
                    'Installed' { $response.packages = @() }
                    default {
                        $response = @{ protocol = 1; operation = $Operation; stage = 'load'; ok = $false; exceptions = @(@{ type = 'System.IO.FileLoadException'; name = 'FileLoadException'; hresult = -2146232799; message = 'Could not load file or assembly' }) }
                    }
                }
                [pscustomobject]@{ Run = (New-TestProcessResult -ExitCode 0); Response = (ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $response -Depth 5)); ProtocolError = $null }
            }

            $result = Invoke-WingetInstall -Apps @(@{ name = 'Contoso.MachineApp' }, @{ name = 'Contoso.OtherApp' })

            $result | Should -Be 1
            $script:messages | Should -Contain 'Could not start the WinGet client engine for Contoso.MachineApp: the WinGet client engine could not start: FileLoadException: Could not load file or assembly'
            $script:messages | Should -Contain 'Skipping the retry pass: the WinGet client engine cannot be started on this machine (see above); retrying would not help.'
            $text = $script:messages -join "`n"
            $text | Should -Match '(?m)^The WinGet client engine cannot be started on this machine \('
            $text | Should -Not -Match 'Could not launch winget|winget cannot be launched'
        }

        It 'Installs with winget.exe when the module is not ready, warns once more in the summary, and exits as it would have' {
            $script:moduleReady = $false

            $result = Invoke-WingetInstall -Apps @(@{ name = 'Contoso.MachineApp' })

            $result | Should -Be 0
            $script:clientCalls | Should -BeNullOrEmpty
            @($script:launches | Where-Object { $_.Arguments -match '^install ' -and $_.FilePath -eq $script:machineWinget }).Count | Should -Be 1
            $text = $script:messages -join "`n"
            $text | Should -Match 'Install engine: winget\.exe \(.+winget\.exe\), not the requested Microsoft\.WinGet\.Client: the module is not ready: downloading the package failed: No such host is known\.'
            $script:messages | Should -Contain 'Install engine: Microsoft.WinGet.Client was requested but not used (the module is not ready: downloading the package failed: No such host is known); this run installed with winget.exe.'
            $script:runRecord.installEngine.used | Should -Be 'Cli'
            $script:runRecord.installEngine.fallbackReason | Should -Be 'the module is not ready: downloading the package failed: No such host is known'
        }

        It 'Only says so in a run that is not SYSTEM, and installs with winget' {
            Mock Get-InstallAccountContext { New-TestAccountContext }

            [void](Invoke-WingetInstall -Apps @(@{ name = 'Contoso.MachineApp' }))

            $script:messages | Should -Contain 'WINGET_APP_SETUP_SYSTEM_ENGINE=WinGetClient applies only to runs as SYSTEM; this run uses winget.'
            Should -Invoke Initialize-WingetClientModule -Times 0 -Exactly
            $script:clientCalls | Should -BeNullOrEmpty
            $script:runRecord.installEngine.requested | Should -Be 'Cli'
        }

        It 'Never readies the module when the variable is unset' {
            $env:WINGET_APP_SETUP_SYSTEM_ENGINE = $null

            Invoke-WingetInstall -Apps @(@{ name = 'Contoso.MachineApp' }) | Should -Be 0

            Should -Invoke Initialize-WingetClientModule -Times 0 -Exactly
            $script:clientCalls | Should -BeNullOrEmpty
            ($script:messages -join "`n") | Should -Match 'Install engine: winget\.exe \('
            $script:runRecord.installEngine.requested | Should -Be 'Cli'
            $script:runRecord.installEngine.used | Should -Be 'Cli'
        }
    }
}

# wgt-gq8.42: with the engine active, the circuit breaker checks the engine, not winget.exe.
Describe 'Invoke-WingetLaunchCircuitBreaker with the Microsoft.WinGet.Client engine' {
    BeforeEach {
        Mock Write-WarningMessage { }
        Mock Write-Info { }
        $script:breakerErrors = @()
        Mock Write-ErrorMessage { $script:breakerErrors += $Message }
        Mock Test-WingetClientEngineActive { $true }
        Mock Test-WingetLaunchable { throw 'winget.exe is not what installs' }
    }

    It 'Trips when the engine cannot be started, saying so' {
        Mock Test-WingetClientEngineLaunchable { [pscustomobject]@{ Launchable = $false; Version = $null; Reason = 'the WinGet client engine could not start: FileLoadException: Could not load file'; ExitCode = $null; Attempts = 1 } }

        Invoke-WingetLaunchCircuitBreaker -Outcome @{ FailureReason = 'InstallLaunchFailed' } | Should -BeTrue

        Should -Invoke Test-WingetClientEngineLaunchable -Times 1 -Exactly -ParameterFilter { $Attempts -eq 6 -and $RetryDelaySeconds -eq 15 }
        $script:breakerErrors | Should -Be @('The WinGet client engine cannot be started on this machine (the WinGet client engine could not start: FileLoadException: Could not load file). The remaining apps are marked failed without an install attempt and are not retried. Restart the machine and re-run the installer; if it persists, attach this transcript to a GitHub issue.')
    }

    It 'Carries on when the engine starts again' {
        Mock Test-WingetClientEngineLaunchable { [pscustomobject]@{ Launchable = $true; Version = 'v1.29.380'; Reason = $null; ExitCode = 0; Attempts = 2 } }

        Invoke-WingetLaunchCircuitBreaker -Outcome @{ FailureReason = 'PreCheckLaunchFailed' } | Should -BeFalse

        Should -Invoke Write-Info -Times 1 -Exactly -ParameterFilter { $Message -eq 'The WinGet client engine starts again (v1.29.380); carrying on with the next app.' }
    }

    It 'Words the failure reasons for the engine' {
        Format-InstallFailureReason -FailureReason 'WingetNotLaunchable' | Should -Be 'not attempted: the WinGet client engine cannot be started on this machine (see above)'
        Format-InstallFailureReason -FailureReason 'PreCheckFailed' -CheckExitCode -1978335217 | Should -Be 'Get-WinGetPackage failed during the pre-install check with exit 0x8A15000F SOURCE_DATA_MISSING'
        Format-InstallFailureReason -FailureReason 'VerifyNotFound' -InstallResult @{ ExitCode = -1978335159; InstallerErrorCode = [long]1603; Attempts = 1; Engine = 'WinGetClient' } | Should -Be 'the MSI installer failed (its own exit code is in the log above, and in its installer log); WinGet client result 0x8A150049 MSI_INSTALL_FAILED, installer exit code 1603, 1 attempt'
        Format-InstallFailureReason -FailureReason 'VerifyNotFound' -InstallResult @{ ExitCode = 1; Engine = 'WinGetClient' } | Should -Be 'Install-WinGetPackage failed; WinGet client result 0x00000001'
        Format-InstallFailureReason -FailureReason 'InstallLaunchFailed' -InstallResult @{ ExitCode = $null; TimedOut = $true; TimeoutSeconds = 1800; Engine = 'WinGetClient' } | Should -Be 'the WinGet client engine could not be started to install it; the WinGet client install stopped after 30 minutes'
    }

    It 'Keeps the winget.exe wording otherwise' {
        Mock Test-WingetClientEngineActive { $false }

        Format-InstallFailureReason -FailureReason 'WingetNotLaunchable' | Should -Be 'not attempted: winget cannot be launched on this machine (see above)'
        Format-InstallFailureReason -FailureReason 'VerifyNotFound' -InstallResult @{ ExitCode = -1978335159; InstallerErrorCode = $null; Attempts = 1; Engine = 'Cli' } | Should -Be 'the MSI installer failed (its own exit code is in the log above, and in its installer log); winget exit 0x8A150049 MSI_INSTALL_FAILED, 1 attempt'
    }
}

# Review findings P3-25 to P3-30, through the real orchestrator and the real winget setup ladder
# (Initialize-Winget and its helpers): only the winget process, the Appx and WinGet cmdlets, the
# module installs and the registry are mocked, and the steps around the setup.
Describe 'Invoke-WingetInstall with the real winget setup ladder (review findings P3-25 to P3-30)' {
    BeforeEach {
        Mock Write-Host { }
        Mock Test-IsAdmin { $true }
        Mock Test-IsRunningLocally { $true }
        Mock Get-InstallAccountContext { New-TestAccountContext }
        Mock Get-PendingRestartState { New-TestRestartState }
        Mock Get-ProxyInheritanceWarning { $null }
        Mock Get-ScriptExecutionPolicyBlock { $null }
        Mock Wait-WauIdle { $true }
        Mock Remove-LegacyScheduledUpdates { $false }
        Mock Set-WindowsTerminalDefaults { }
        Mock Install-WingetAutoUpdate { [pscustomobject]@{ Status = 'AlreadyPresent'; Version = '2.12.0' } }
        Mock Install-AppWithVerification { @{ Status = 'Installed'; InstallResult = @{ ExitCode = 0 }; FailureReason = $null } }
        $script:sleptSeconds = 0
        Mock Start-Sleep { $script:sleptSeconds += $Seconds }
        # The Microsoft.WinGet.Client module is not installed, and installing it must be visible.
        Mock Get-Module { $null }
        Mock Get-PackageProvider { $null }
        Mock Install-PackageProvider { }
        Mock Install-Module { }
        Mock Import-Module { }
        # Commands that would change the machine.
        Mock Invoke-WebRequest { throw 'must not download App Installer' }
        Mock Add-AppxPackage { throw 'must not register a package' }
        Mock Invoke-AppxRegistration { throw 'must not register a package' }
        Mock Repair-WinGetPackageManager { throw 'must not repair App Installer' }
        Mock Get-AppxPackage { }
        # Never the runner's own Microsoft.WinGet.Client, which CI installs.
        Mock Get-WingetClientRepairVersion { $null }
        # No App Installer Group Policy (never the runner's real registry) unless a test sets one.
        Mock Get-ItemProperty { throw [System.Management.Automation.ItemNotFoundException]::new('Cannot find path') }
        # A healthy winget unless a test says otherwise.
        Mock Invoke-ExternalProcess { New-TestProcessResult -ExitCode 0 }
        Mock Invoke-ExternalProcess { New-TestProcessResult -ExitCode 0 -Output @('v1.12.350') } -ParameterFilter { $ArgumentList[0] -eq '--version' }
        $script:InstallLogPath = $null
        $script:messages = @()
        Mock Write-Info { $script:messages += "INFO: $Message" }
        Mock Write-Success { $script:messages += "OK: $Message" }
        Mock Write-WarningMessage { $script:messages += "WARN: $Message" }
        Mock Write-ErrorMessage { $script:messages += "ERROR: $Message" }
        Mock Write-Warning { $script:messages += "WARN: $Message" }
        Mock Write-Table { }
    }

    It 'Never installs or loads the Microsoft.WinGet.Client module when winget works (P3-26)' {
        Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive | Should -Be 0

        Should -Invoke Install-PackageProvider -Times 0 -Exactly
        Should -Invoke Install-Module -Times 0 -Exactly
        Should -Invoke Import-Module -Times 0 -Exactly -ParameterFilter { "$Name" -eq 'Microsoft.WinGet.Client' }
        ($script:messages -join "`n") | Should -Not -Match 'Update functionality|Microsoft\.WinGet\.Client'
        # One source update, and no other source command.
        Should -Invoke Invoke-ExternalProcess -Times 1 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'source' }
        Should -Invoke Invoke-ExternalProcess -Times 1 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -eq 'source update --name winget --disable-interactivity' }
    }

    It 'Stops with exit code 2 before running winget, naming the policy, when Group Policy turns winget off (P3-30)' {
        Mock Get-ItemProperty { [pscustomobject]@{ EnableAppInstaller = 0 } } -ParameterFilter { $LiteralPath -eq 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppInstaller' }

        Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive | Should -Be 2

        Should -Invoke Invoke-ExternalProcess -Times 0 -Exactly
        Should -Invoke Install-AppWithVerification -Times 0 -Exactly
        Should -Invoke Install-WingetAutoUpdate -Times 0 -Exactly
        ($script:messages -join "`n") | Should -Match "Group Policy on this PC blocks winget: 'Enable App Installer' is Disabled"
    }

    It 'Stops with exit code 2 at once when winget answers 0x8A15003A, repairing and resetting nothing (P3-30)' {
        Mock Invoke-ExternalProcess { New-TestProcessResult -ExitCode -1978335174 -Output @('This operation is disabled by Group Policy : Enable App Installer') } -ParameterFilter { $ArgumentList[0] -eq '--version' }

        Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive | Should -Be 2

        $script:sleptSeconds | Should -Be 0
        Should -Invoke Invoke-ExternalProcess -Times 1 -Exactly
        Should -Invoke Repair-WinGetPackageManager -Times 0 -Exactly
        Should -Invoke Add-AppxPackage -Times 0 -Exactly
        Should -Invoke Invoke-AppxRegistration -Times 0 -Exactly
        Should -Invoke Install-WingetAutoUpdate -Times 0 -Exactly
        ($script:messages -join "`n") | Should -Match 'Group Policy on this PC blocks winget'
    }

    It 'Stops with exit code 2 before any app or Winget-AutoUpdate work when Initialize-Winget finds the source unusable (wgt-gq8.63)' {
        Mock Initialize-Winget { [pscustomobject]@{ Ready = $false; Diagnosis = 'SourceUnusable' } }

        Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive | Should -Be 2

        Should -Invoke Install-AppWithVerification -Times 0 -Exactly
        Should -Invoke Install-WingetAutoUpdate -Times 0 -Exactly
        Should -Invoke Remove-LegacyScheduledUpdates -Times 0 -Exactly
        $script:messages | Should -Contain 'ERROR: Nothing was installed and Winget-AutoUpdate was not set up: winget cannot open its source for this account (see above). Exiting.'
    }

    # wgt-gq8.63, the owner's real-PC run (cross-user elevation): `winget source update` printed
    # 'Cancelled' and exited 0, every install then failed with 0x8A15000F, and Winget-AutoUpdate was
    # set up anyway.
    It 'Registers the source package and stops with exit code 2, installing nothing, when the source still cannot be opened after an update that exited 0' {
        Mock Get-InstallAccountContext { New-TestAccountContext -CrossUser -ProcessUser 'KFI\admin-jmaffiola' -SessionUser 'KFI\tuser' }
        Mock Invoke-ExternalProcess { New-TestProcessResult -ExitCode 0 -Output @('Updating source: winget...', 'Cancelled') } -ParameterFilter { $ArgumentList[0] -eq 'source' -and $ArgumentList[1] -eq 'update' }
        Mock Invoke-ExternalProcess { New-TestProcessResult -ExitCode -1978335217 -Output @("Failed when opening source(s); try the 'source reset' command if the problem persists.", '0x8a15000f : Data required by the source is missing') } -ParameterFilter { $ArgumentList[0] -eq 'search' }
        # No copy of the source package on this PC; the download is Microsoft's, and Windows refuses
        # to deploy it for an account with no logon session.
        Mock Invoke-WindowsPowerShellScript { [pscustomobject]@{ ExitCode = 0; TimedOut = $false; LaunchFailed = $false; LaunchError = $null; StandardOutput = @() } }
        $script:sourceStaging = Join-Path $TestDrive 'wingetsource-owner-run'
        Mock New-WauStagingDirectory { [void](New-Item -ItemType Directory -Path $script:sourceStaging -Force); $script:sourceStaging }
        Mock Invoke-WebRequest { [pscustomobject]@{ RawContentStream = [System.IO.MemoryStream]::new([byte[]](1, 2, 3)) } }
        Mock Get-AuthenticodeSignature { [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US' } } }
        Mock Invoke-AppxRegistration { throw [System.Runtime.InteropServices.COMException]::new('Deployment failed with HRESULT: 0x80073D19, An error occurred because a user was logged off.', -2147009255) }

        Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive | Should -Be 2

        Should -Invoke Invoke-AppxRegistration -Times 1 -Exactly -ParameterFilter { $PackagePath -like (Join-Path $script:sourceStaging 'source-*.msix') }
        Should -Invoke Install-AppWithVerification -Times 0 -Exactly
        Should -Invoke Install-WingetAutoUpdate -Times 0 -Exactly
        Should -Invoke Invoke-ExternalProcess -Times 0 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'install' -or ($ArgumentList[0] -eq 'source' -and $ArgumentList[1] -eq 'reset') }
        $text = $script:messages -join "`n"
        $text | Should -Not -Match 'up to date'
        $text | Should -Match "ERROR: The winget source cannot be opened for 'KFI\\admin-jmaffiola': 'winget search --source winget' answered 0x8A15000F SOURCE_DATA_MISSING"
        $text | Should -Match 'Registering the winget source package \(Microsoft\.Winget\.Source\) for the account failed \(0x80073D19 ERROR_DEPLOYMENT_BLOCKED_BY_USER_LOG_OFF\)'
        $text | Should -Match 'run the installer while signed in to Windows as .KFI\\admin-jmaffiola., or run the machine phase as SYSTEM with rmm/Invoke-WingetAppSetup\.ps1'
        Test-Path -LiteralPath $script:sourceStaging | Should -Be $false
    }

    It 'Installs as usual once registering the source package makes it open' {
        $script:searches = 0
        Mock Invoke-ExternalProcess {
            $script:searches++
            if ($script:searches -eq 1) { return New-TestProcessResult -ExitCode -1978335217 -Output @('0x8a15000f : Data required by the source is missing') }
            New-TestProcessResult -ExitCode 0
        } -ParameterFilter { $ArgumentList[0] -eq 'search' }
        Mock Register-WingetSourcePackage { [pscustomobject]@{ Registered = $true; ErrorCodes = @(); Reason = $null } }

        Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive | Should -Be 0

        Should -Invoke Register-WingetSourcePackage -Times 1 -Exactly
        Should -Invoke Install-AppWithVerification -Times 1 -Exactly
        Should -Invoke Install-WingetAutoUpdate -Times 1 -Exactly
    }

    It 'Repairs nothing when the source update times out: a repair cannot fix a network (P3-28)' {
        Mock Invoke-ExternalProcess { New-TestProcessResult -TimedOut } -ParameterFilter { $ArgumentList[0] -eq 'source' -and $ArgumentList[1] -eq 'update' }

        Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive | Should -Be 0

        Should -Invoke Repair-WinGetPackageManager -Times 0 -Exactly
        Should -Invoke Add-AppxPackage -Times 0 -Exactly
        Should -Invoke Invoke-AppxRegistration -Times 0 -Exactly
        Should -Invoke Invoke-ExternalProcess -Times 0 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'source' -and $ArgumentList[1] -eq 'reset' }
        @($script:messages | Where-Object { $_ -like 'WARN: The winget source could not be set up*' }).Count | Should -Be 1
    }

    # E2E run 36384683838, second pass: three ladders, three wrong diagnoses ('Installations may fail
    # with 0x80073D19', 'source "winget" appears to be missing', a source.msix rejection), the
    # aka.ms/getwinget download, and never the -AllUsers repair the cmdlet asked for.
    It 'On the #279 wedge, repairs for all users first and gives one diagnosis that names the missing framework (P3-25, P3-27, P3-28)' {
        Mock Invoke-ExternalProcess { New-TestProcessResult -LaunchFailed -LaunchErrorCode 1920 -LaunchError 'The file cannot be accessed by the system.' } -ParameterFilter { $ArgumentList[0] -eq '--version' }
        $script:newFolder = Join-Path $TestDrive 'Microsoft.DesktopAppInstaller_1.29.290.0_x64__8wekyb3d8bbwe'
        Mock Get-DesktopAppInstallerPackageInfo { [pscustomobject]@{ Version = [version]'1.29.290.0'; Architecture = 'X64'; Status = 'Ok'; InstallLocation = $script:newFolder } }
        Mock Get-AppxPackage { [pscustomobject]@{ Name = 'Microsoft.DesktopAppInstaller'; InstallLocation = $script:newFolder } }
        # The registration seam (Add-AppxPackage, in Windows PowerShell under PowerShell 7) fails as
        # Add-AppxPackage does there: with the HRESULT.
        Mock Invoke-AppxRegistration { throw [System.Runtime.InteropServices.COMException]::new('Deployment failed with HRESULT: 0x80073CF3, Package failed updates, dependency or conflict validation. Provide the framework "Microsoft.WindowsAppRuntime.1.8"', -2147009293) }
        Mock Get-WindowsAppRuntimePackageInfo { }
        Mock Test-AndInstallWingetModule { $true }
        Mock Repair-WinGetPackageManager { throw 'Failed to repair winget. Try running with -AllUsers in administrator mode.' }

        Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -NonInteractive | Should -Be 2

        Should -Invoke Repair-WinGetPackageManager -Times 1 -Exactly -ParameterFilter { $AllUsers }
        # Not forced: the registration's 0x80073CF3 says forcing cannot help (P3-27).
        Should -Invoke Repair-WinGetPackageManager -Times 0 -Exactly -ParameterFilter { $Force }
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        Should -Invoke Install-AppWithVerification -Times 0 -Exactly
        $diagnosis = @($script:messages | Where-Object { $_ -like 'ERROR: *' -and $_ -ne 'ERROR: Winget is required for this script. Exiting.' })
        $diagnosis.Count | Should -Be 1
        $diagnosis[0] | Should -Match '0x80073CF3 ERROR_INSTALL_RESOLVE_DEPENDENCY_FAILED.*Fix: install the Microsoft\.WindowsAppRuntime\.1\.8 framework'
        ($script:messages -join "`n") | Should -Not -Match 'Installations may fail with 0x80073D19|appears to be missing|source\.msix|install winget manually'
    }
}

# Review finding P3-34: the first pass and the retry pass each evaluated an app's condition, and
# Set-WindowsTerminalDefaults (between them) writes the default-terminal values the Windows Terminal
# condition reads. An app that failed in the first pass could then come back 'not applicable' in
# the retry pass and be counted as installed (exit 0, app missing). Here the real per-app pipeline
# runs; only winget and the steps around the installs are mocked.
Describe 'Applicability is decided once per run (review finding P3-34)' {
    BeforeEach {
        Mock Write-Host { }
        Mock Start-Process { }
        Mock Start-Sleep { }
        Mock Test-IsAdmin { $true }
        Mock Restart-WithElevation { [pscustomobject]@{ Started = $true; ExitCode = 0 } }
        Mock Test-IsRunningLocally { $true }
        Mock Initialize-Winget { [pscustomobject]@{ Ready = $true; Diagnosis = 'Ok' } }
        Mock Remove-LegacyScheduledUpdates { $true }
        Mock Install-WingetAutoUpdate { @{ Status = 'DryRun'; Version = '2.12.0' } }
        Mock Test-WingetLaunchable { [pscustomobject]@{ Launchable = $true; Version = 'v1.12.350'; Reason = $null; Attempts = 1 } }
        Mock Wait-WauIdle { $true }
        Mock Get-PendingRestartState { New-TestRestartState }
        Mock Get-ProxyInheritanceWarning { $null }
        Mock Get-ScriptExecutionPolicyBlock { $null }
        Mock Get-WingetPolicyBlock { $null }
        Mock Get-InstallAccountContext { New-TestAccountContext }
        # The app never installs: both passes attempt it and it stays failed.
        Mock Install-WingetPackage { @{ ExitCode = 1; Attempts = 1; SessionErrorExhausted = $false; MachineScopeFellBack = $false } }
        Mock Test-WingetPackageInstalled { @{ Installed = $false; TimedOut = $false; LaunchFailed = $false; LaunchError = $null; ExitCode = 0 } }

        # Stands in for the real Windows Terminal step: it changes what the condition reads.
        $script:terminalConfigured = $false
        Mock Set-WindowsTerminalDefaults { $script:terminalConfigured = $true }

        $script:capturedRows = $null
        Mock Write-Table { if ($Title -eq 'Installation Summary') { $script:capturedRows = $Rows } }
        $script:warningMessages = @()
        Mock Write-WarningMessage { $script:warningMessages += $Message }
        $script:successMessages = @()
        Mock Write-Success { $script:successMessages += $Message }
        Mock Write-ErrorMessage { }
        Mock Write-Info { }
    }

    It 'Evaluates the condition once, before Set-WindowsTerminalDefaults, and retries the app the first pass attempted' {
        $script:conditionCalls = 0
        $apps = @(@{ name = 'Contoso.Terminal'; condition = { $script:conditionCalls++; -not $script:terminalConfigured }; conditionDescription = 'not hosted by itself' })

        $result = Invoke-WingetInstall -Apps $apps -NonInteractive

        $script:conditionCalls | Should -Be 1
        # Attempted in both passes, and still failed: never 'not applicable', never installed.
        Should -Invoke Install-WingetPackage -Times 2 -Exactly -ParameterFilter { $PackageId -eq 'Contoso.Terminal' }
        $script:successMessages | Should -Not -Contain 'Retry succeeded: Contoso.Terminal'
        ($script:warningMessages -join "`n") | Should -Not -Match 'not applicable'
        @($script:capturedRows | Where-Object { $_[0] -eq 'Installed' }).Count | Should -Be 0
        @($script:capturedRows | Where-Object { $_[0] -eq 'Failed' })[0][1] | Should -Match 'Contoso\.Terminal'
        $result | Should -Be 1
    }

    It 'Keeps a condition that failed open in the first pass applicable in the retry pass' {
        # A CIM error in the first pass (fail open, so the install was attempted), a clean answer
        # in the second: the retry pass used to report that as 'Retry succeeded'.
        $script:conditionCalls = 0
        $apps = @(@{ name = 'Contoso.VendorTool'; condition = { $script:conditionCalls++; if ($script:conditionCalls -eq 1) { throw 'RPC server is unavailable' }; $false }; conditionDescription = 'Contoso hardware only' })

        $result = Invoke-WingetInstall -Apps $apps -NonInteractive

        $script:conditionCalls | Should -Be 1
        Should -Invoke Install-WingetPackage -Times 2 -Exactly -ParameterFilter { $PackageId -eq 'Contoso.VendorTool' }
        ($script:warningMessages -join "`n") | Should -Match 'Condition for Contoso\.VendorTool failed to evaluate \(RPC server is unavailable\); treating as applicable'
        $script:successMessages | Should -Not -Contain 'Retry succeeded: Contoso.VendorTool'
        @($script:capturedRows | Where-Object { $_[0] -eq 'Installed' }).Count | Should -Be 0
        $result | Should -Be 1
    }
}

Describe 'Test-AppApplicability (issue #217; review findings P3-33, P3-34)' {
    BeforeEach {
        $script:conditionWarnings = @()
        Mock Write-WarningMessage { $script:conditionWarnings += $Message }
    }

    It 'Treats an app without a condition as applicable' {
        Test-AppApplicability -App @{ name = 'Contoso.App' } | Should -Be $true
        $script:conditionWarnings.Count | Should -Be 0
    }

    It 'Returns the condition''s verdict' {
        Test-AppApplicability -App @{ name = 'Contoso.App'; condition = { $true } } | Should -Be $true
        Test-AppApplicability -App @{ name = 'Contoso.App'; condition = { $false } } | Should -Be $false
        $script:conditionWarnings.Count | Should -Be 0
    }

    It 'Fails open when the condition throws: warns and treats the app as applicable' {
        Test-AppApplicability -App @{ name = 'Contoso.App'; condition = { throw 'probe broke' } } | Should -Be $true

        $script:conditionWarnings | Should -Contain 'Condition for Contoso.App failed to evaluate (probe broke); treating as applicable and attempting the install.'
    }

    It 'Fails open when the condition writes a non-terminating error instead of answering' {
        # A probe that writes an error and returns nothing used to read as "does not apply".
        Test-AppApplicability -App @{ name = 'Contoso.App'; condition = { Write-Error 'Access denied'; $false } } | Should -Be $true

        ($script:conditionWarnings -join "`n") | Should -Match 'Condition for Contoso\.App failed to evaluate \(Access denied\)'
    }

    It 'Applies the same rule for the uninstaller, and says what failing open does there (review finding P3-18)' {
        Test-AppApplicability -App @{ name = 'Contoso.App'; condition = { $false } } -Purpose Uninstall | Should -Be $false
        Test-AppApplicability -App @{ name = 'Contoso.App'; condition = { throw 'probe broke' } } -Purpose Uninstall | Should -Be $true

        $script:conditionWarnings | Should -Be @('Condition for Contoso.App failed to evaluate (probe broke); treating as applicable and attempting the uninstall.')
    }
}

# The issue form a teammate fills in after a failed run (review findings P3-15, P3-36, P3-41): its
# exit-code hint must explain every code the installer can exit with, including the codes added
# since (6: another run in progress; 8: auto-updates not working) and 3010.
Describe 'The install-failure issue form explains every exit code' {
    It 'Explains exit code <_>' -ForEach @('1', '2', '3', '4', '5', '6', '7', '8', '9', '3010') {
        $form = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot '.github/ISSUE_TEMPLATE/install-failure.yml')
        $form -match '(?m)^\s+id: exit-code\s*\r?\n(?:.*\r?\n)*?\s+description: (?<description>.+)$' | Should -BeTrue
        $Matches.description | Should -Match ('(?<![\d])' + $_ + ' = ')
    }
}

# Work-order items 35 and 39 added causes to exit codes 2, 4, 5 and 7 (Group Policy's App Installer
# and execution policies, Constrained Language Mode). The early-exit notice, the issue form and the
# readme's table must say the same.
Describe 'The early-exit notice, the issue form and the readme agree on what an exit code means' {
    BeforeAll {
        $form = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot '.github/ISSUE_TEMPLATE/install-failure.yml')
        $null = $form -match '(?m)^\s+id: exit-code\s*\r?\n(?:.*\r?\n)*?\s+description: (?<description>.+)$'
        $script:formDescription = $Matches.description
        $script:readmeText = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'readme.md')

        function Get-FormMeaning {
            param ([string]$Code)
            $found = [regex]::Match($script:formDescription, ('(?<![\d]){0} = (?<text>[^;]+)' -f $Code))
            return $found.Groups['text'].Value
        }

        function Get-ReadmeMeaning {
            param ([string]$Code)
            $found = [regex]::Match($script:readmeText, ('(?m)^\| {0} \| (?<text>.+) \|\s*$' -f $Code))
            return $found.Groups['text'].Value
        }

        function Get-NoticeMeaning {
            param ([int]$Code)
            $script:noticeErrors = @()
            Mock Write-ErrorMessage { $script:noticeErrors += $Message }
            Mock Write-WarningMessage { }
            Mock Write-Info { }
            Mock Write-Host { }
            Mock Write-InstallerReportHint { }
            Write-InstallerExitNotice -Code $Code -NoPause
            return (@($script:noticeErrors) -join ' ')
        }
    }

    It 'Names Group Policy for exit code 2 in all three' {
        Get-FormMeaning -Code 2 | Should -Match 'Group Policy'
        Get-ReadmeMeaning -Code 2 | Should -Match 'Group Policy'
        Get-NoticeMeaning -Code 2 | Should -Match 'Group Policy'
    }

    It 'Names Group Policy''s execution policy for exit code 4 in all three' {
        Get-FormMeaning -Code 4 | Should -Match 'execution policy'
        Get-ReadmeMeaning -Code 4 | Should -Match 'execution policy'
        Get-NoticeMeaning -Code 4 | Should -Match 'execution policy'
    }

    It 'Names Constrained Language Mode for exit code 5 in the issue form and the readme' {
        Get-FormMeaning -Code 5 | Should -Match 'Constrained Language Mode'
        Get-ReadmeMeaning -Code 5 | Should -Match 'Constrained Language Mode'
    }

    It 'Names PowerShell 7''s execution policy for exit code 7 in the issue form and the readme' {
        Get-FormMeaning -Code 7 | Should -Match 'execution policy'
        Get-ReadmeMeaning -Code 7 | Should -Match 'execution policy'
    }

    It 'Says in the readme what -CollectDiagnostics exits with' {
        Get-ReadmeMeaning -Code 5 | Should -Match '-CollectDiagnostics.*exits 0 when it saved the diagnostics bundle, 5 when it could not'
    }
}

# Review findings P2-8, P2-9 and P2-10: with winget.exe unable to start (E2E run 36384683838, second
# pass, every app already installed), each app spent 9 launches and 75 seconds of backoff, twice:
# about 24 minutes, then every app reported as 'package not found after install'. Here the real
# per-app pipeline runs (Install-AppWithVerification, Test-WingetPackageInstalled,
# Install-WingetPackage, Install-PowerShellLatest, the circuit breaker and Test-WingetLaunchable);
# only the winget process and the setup steps around the installs are mocked.
Describe 'Wedged winget: the run fails fast (review findings P2-8, P2-9, P2-10)' {
    BeforeEach {
        Mock Write-Host { }
        Mock Test-IsAdmin { $true }
        Mock Test-IsRunningLocally { $true }
        Mock Wait-WauIdle { $true }
        Mock Initialize-Winget { [pscustomobject]@{ Ready = $true; Diagnosis = 'Ok' } }
        Mock Remove-LegacyScheduledUpdates { $true }
        Mock Set-WindowsTerminalDefaults { }
        # Auto-updates set up, so the exit code here is about the apps and winget only (a run whose
        # WAU was skipped for a missing framework exits 8, review finding P3-36).
        Mock Install-WingetAutoUpdate { [pscustomobject]@{ Status = 'Configured'; Version = '2.12.0'; FrameworkMissing = $false; RestartRequired = $false } }
        Mock Get-PendingRestartState { New-TestRestartState }
        Mock Get-ProxyInheritanceWarning { $null }
        Mock Get-ScriptExecutionPolicyBlock { $null }
        Mock Get-WingetPolicyBlock { $null }
        Mock Get-InstallAccountContext { New-TestAccountContext }
        # Never read the machine's App Installer packages, and never start a real process: the
        # removed deadlock detector and Wait-WingetLaunchable did both.
        Mock Get-AppxPackage { }
        Mock Start-Process { throw 'Access is denied.' }
        $script:sleptSeconds = 0
        Mock Start-Sleep { $script:sleptSeconds += $Seconds }

        $script:capturedTables = @{}
        Mock Write-Table { $script:capturedTables[$Title] = $Rows }
        $script:errorMessages = @()
        Mock Write-ErrorMessage { $script:errorMessages += $Message }
        $script:warningMessages = @()
        Mock Write-WarningMessage { $script:warningMessages += $Message }
        $script:infoMessages = @()
        Mock Write-Info { $script:infoMessages += $Message }

        # The catalog's shape: eight apps, one not applicable here, PowerShell with its own installer.
        $script:catalog = @(
            @{ name = '7zip.7zip' }
            @{ name = 'GlavSoft.TightVNC' }
            @{ name = 'Google.Chrome' }
            @{ name = 'Git.Git' }
            @{ name = 'Klocman.BulkCrapUninstaller' }
            @{ name = 'Dell.CommandUpdate.Universal'; condition = { $false }; conditionDescription = 'Dell hardware only' }
            @{ name = 'Microsoft.PowerShell'; install = 'Install-PowerShellLatest' }
            @{ name = 'Microsoft.WindowsTerminal' }
        )
    }

    It 'Stops after one app and one check when winget cannot start (<Case>)' -ForEach @(
        @{ Case = 'a lock that could clear, 1920'; Code = 1920; Message = 'The file cannot be accessed by the system.'; MaxLaunches = 8; MaxSleep = 75 }
        @{ Case = 'access denied, 5'; Code = 5; Message = 'Access is denied.'; MaxLaunches = 3; MaxSleep = 0 }
    ) {
        $script:launchCode = $Code
        $script:launchMessage = $Message
        $script:launches = 0
        Mock Invoke-WingetProcess {
            $script:launches++
            New-TestProcessResult -LaunchFailed -LaunchErrorCode $script:launchCode -LaunchError $script:launchMessage
        }

        $result = Invoke-WingetInstall -Apps $script:catalog -NonInteractive

        $result | Should -Be 1
        # Before: 9 launches and 75 seconds of backoff per app, in both passes (144 launches and
        # 1200 seconds for these 8 apps). Now: the first app's pre-check, the breaker's check (six
        # tries 15 s apart for a lock that could clear, one for access denied) and the end-of-run
        # check.
        $script:launches | Should -BeLessOrEqual $MaxLaunches
        $script:sleptSeconds | Should -BeLessOrEqual $MaxSleep
        Should -Invoke Invoke-WingetProcess -Times 0 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'install' }
        $script:infoMessages | Should -Not -Contain 'Retrying failed installations (1 final attempt)...'

        # Every applicable app failed with a reason that says winget could not be launched; none
        # says 'package not found after install'. The not-applicable app is still skipped.
        $failedRows = @($script:capturedTables['Failed Installations'])
        $failedRows.Count | Should -Be 7
        $failedRows[0][0] | Should -Be '7zip.7zip'
        $failedRows[0][1] | Should -Be ('winget could not be launched for the pre-install check; launch error: {0}' -f $Message.TrimEnd('.'))
        @($failedRows | Select-Object -Skip 1 | ForEach-Object { $_[1] } | Sort-Object -Unique) | Should -Be @('not attempted: winget cannot be launched on this machine (see above)')
        @($failedRows | Where-Object { $_[1] -match 'not found after install' }).Count | Should -Be 0
        $script:warningMessages | Should -Contain 'Skipping: Dell.CommandUpdate.Universal (not applicable: Dell hardware only)'
        ($script:errorMessages -join "`n") | Should -Match '(?m)^winget cannot be launched on this machine \(winget could not be started: '
        ($script:errorMessages -join "`n") | Should -Match 'winget: NOT USABLE'
    }

    It 'Carries on normally when only one launch failed and winget starts again' {
        $script:launches = 0
        Mock Invoke-WingetProcess {
            $script:launches++
            if ($script:launches -eq 1) {
                return New-TestProcessResult -LaunchFailed -LaunchErrorCode 1920 -LaunchError 'The file cannot be accessed by the system.'
            }
            if ($ArgumentList[0] -eq '--version') {
                return New-TestProcessResult -ExitCode 0 -Output @('v1.12.350')
            }
            # Every app is installed already.
            New-TestProcessResult -ExitCode 0 -Output @("$($ArgumentList[3])  1.0  winget")
        }

        $result = Invoke-WingetInstall -Apps $script:catalog -NonInteractive

        # 7zip failed its first pre-check, the breaker found winget working, the other apps were
        # skipped as installed, and 7zip's retry found it installed too.
        $result | Should -Be 0
        ($script:infoMessages -join "`n") | Should -Match 'winget starts again'
        $script:capturedTables.ContainsKey('Failed Installations') | Should -BeFalse
    }

    It 'Rides out a <Seconds>-second lock that starts at a pre-check: every app installs and the run returns 0' -ForEach @(
        @{ Seconds = 30 }
        @{ Seconds = 60 }
    ) {
        # Review of item 9: the pre-check and the post-install check do not retry a failed launch,
        # so the breaker's own check is all the tolerance such a lock gets. An App Installer update
        # in progress (issues #253/#258) outlasts 15 seconds; with two tries 10 s apart the breaker
        # tripped on it and failed every app. Simulated time: each winget launch takes a second and
        # Start-Sleep advances the clock. Nothing is installed yet.
        $script:clock = 0
        $script:lockSeconds = $Seconds
        $script:installed = @{}
        Mock Start-Sleep { $script:clock += $Seconds; $script:sleptSeconds += $Seconds }
        Mock Invoke-WingetProcess {
            $script:clock++
            if ($script:clock -le $script:lockSeconds) {
                return New-TestProcessResult -LaunchFailed -LaunchErrorCode 1920 -LaunchError 'The file cannot be accessed by the system.'
            }
            $arguments = @($ArgumentList)
            $id = $arguments[[array]::IndexOf($arguments, '--id') + 1]
            switch ($arguments[0]) {
                '--version' { return New-TestProcessResult -ExitCode 0 -Output @('v1.12.350') }
                'install' {
                    $script:installed[$id] = $true
                    return New-TestProcessResult -ExitCode 0
                }
                'list' {
                    if ($script:installed[$id]) {
                        return New-TestProcessResult -ExitCode 0 -Output @("$id  1.0  winget")
                    }
                    return New-TestProcessResult -ExitCode -1978335212 -Output @('No installed package found matching input criteria.')
                }
            }
            throw "unexpected winget call: $($arguments -join ' ')"
        }

        $result = Invoke-WingetInstall -Apps $script:catalog -NonInteractive

        $result | Should -Be 0
        ($script:infoMessages -join "`n") | Should -Match 'winget starts again'
        $script:capturedTables.ContainsKey('Failed Installations') | Should -BeFalse
        # The seven applicable apps: six in the first pass, 7zip (whose pre-check hit the lock) in
        # the retry pass.
        @($script:installed.Keys | Sort-Object) | Should -Be @('7zip.7zip', 'Git.Git', 'GlavSoft.TightVNC', 'Google.Chrome', 'Klocman.BulkCrapUninstaller', 'Microsoft.PowerShell', 'Microsoft.WindowsTerminal')
        $script:infoMessages | Should -Contain 'Retrying failed installations (1 final attempt)...'
        # Bounded: the breaker waits at most 75 seconds.
        $script:sleptSeconds | Should -BeLessOrEqual 75
    }
}

# P2-16: the dry run promised 'No system changes will be made' but its setup helpers ran their real
# remediation - the NuGet provider and two PSGallery modules installed for all users, App Installer
# registered, repaired or downloaded, and `winget source reset --force` - because every dry-run test
# mocked those helpers away. Here they all run for real (Initialize-Winget with
# Register-WingetAppInstallerForUser and Invoke-WingetPackageManagerRepair behind it,
# Install-AppWithVerification and the rest), on a machine where each of them has something to fix.
# Only the commands that read or change the machine are mocked: the read-only probes describe that
# machine, and every command that would change it is asserted never to run.
Describe 'Dry run leaves the machine unchanged (P2-16)' {
    BeforeEach {
        Mock Write-Host { }
        Mock Write-Warning { }
        Mock Start-Sleep { }
        Mock Test-IsRunningLocally { $true }
        Mock Restart-WithElevation { [pscustomobject]@{ Started = $true; ExitCode = 0 } }
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
        Mock Get-PendingRestartState { New-TestRestartState }
        Mock Get-ProxyInheritanceWarning { $null }
        Mock Get-ScriptExecutionPolicyBlock { $null }
        # The legacy scheduled task, its data directory and WAU's task all "exist", so their
        # helpers reach the branch that would remove or change them.
        Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = 'present' } }
        Mock Test-Path { $false }
        Mock Test-Path { $true } -ParameterFilter { "$Path" -like '*winget-app-setup' }
        # Every winget or msiexec process goes through Invoke-ExternalProcess (review findings
        # P2-5, P2-6). The per-app `winget list` check exits 0 without listing anything (not
        # installed), and `winget --version` cannot start (no winget for this account). Start-Process
        # stays mocked so any other process start is visible.
        Mock Invoke-ExternalProcess { New-TestProcessResult -ExitCode 0 }
        Mock Invoke-ExternalProcess { New-TestProcessResult -LaunchFailed -LaunchErrorCode 2 -LaunchError "'winget' was not found on PATH." } -ParameterFilter { $ArgumentList[0] -eq '--version' }
        Mock Start-Process { }

        # Commands that change the machine: none of these may run in a dry run.
        Mock Install-PackageProvider { }
        Mock Install-Module { }
        Mock Import-Module { }
        Mock Repair-WinGetPackageManager { }
        Mock Add-AppxPackage { }
        Mock Invoke-AppxRegistration { }
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
        # A same-user run, whatever account runs the suite, and no App Installer Group Policy.
        Mock Get-InstallAccountContext { New-TestAccountContext }
        Mock Get-WingetPolicyBlock { $null }

        # Last: mocking Get-Command breaks the command lookup that Mock itself relies on for the
        # targets above (see TestHelpers.ps1). Nothing is available by default: no winget, no
        # Repair-WinGetPackageManager.
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
        Should -Invoke Invoke-AppxRegistration -Times 0 -Exactly
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
        # The only processes a dry run starts are the read-only `winget --version` launch check and
        # the per-app `winget list` check: no installer, no msiexec, no `winget source update/reset`.
        Should -Invoke Start-Process -Times 0 -Exactly
        Should -Invoke Invoke-ExternalProcess -Times 0 -Exactly -ParameterFilter { $FilePath -notmatch 'winget' -or $ArgumentList[0] -notin @('list', '--version') }
        Should -Invoke Invoke-ExternalProcess -Times 1 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'list' -and $ArgumentList -contains 'Contoso.AppOne' }

        # The preview carried on to the summary and says what a real run would have done.
        $result | Should -Be 0
        ($script:infoMessages -join "`n") | Should -Match '\[DRY-RUN\] Would remove the legacy update data directory'
        Should -Invoke Write-Table -Times 1 -Exactly -ParameterFilter { $Title -eq 'Installation Summary' }
        $dryRunLines = ($script:infoMessages | Where-Object { $_ -match '^\[DRY-RUN\]' }) -join "`n"
        $dryRunLines | Should -Match 'Winget is not available for this account \(winget could not be started: .winget. was not found on PATH\)\. A real run would set it up: .*Repair-WinGetPackageManager \(installing its Microsoft\.WinGet\.Client module from the PowerShell Gallery first if it is missing\)'
        $dryRunLines | Should -Match 'this preview cannot tell which apps are already installed'
        $dryRunLines | Should -Match 'Would install: Contoso\.AppOne'
        $script:errorMessages | Should -Not -Contain 'Winget is required for this script. Exiting.'
    }

    # Work-order items 31 and 39: the pre-flight runs once in a dry run too, and the preview of the
    # Winget-AutoUpdate step still says that it would install the pinned Windows App Runtime first.
    It 'Runs the pre-flight once and previews the Windows App Runtime install with Winget-AutoUpdate, installing neither' {
        Mock Test-IsAdmin { $true }
        $script:preflightCalls = @()
        Mock Get-ProxyInheritanceWarning { $script:preflightCalls += 'proxy'; $null }
        Mock Get-PendingRestartState { $script:preflightCalls += 'restart'; New-TestRestartState }
        Mock Install-WindowsAppRuntimeFramework { throw 'a dry run installs no framework' }
        Mock Invoke-AppxProvisioning { throw 'a dry run provisions nothing' }

        $result = Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -WhatIf -NonInteractive

        $result | Should -Be 0
        $script:preflightCalls | Should -Be @('proxy', 'restart')
        $pin = Get-WindowsAppRuntimePin
        $preview = '*would first install the pinned Windows App Runtime {0} (framework {1}) for all users*' -f $pin.Release, $pin.FrameworkVersion
        @($script:infoMessages | Where-Object { $_.StartsWith('[DRY-RUN]') -and $_ -like $preview }) | Should -HaveCount 1
        Should -Invoke Install-WindowsAppRuntimeFramework -Times 0 -Exactly
        Should -Invoke Invoke-AppxProvisioning -Times 0 -Exactly
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    It 'Neither updates nor resets the winget source when winget is present, and says what a real run would do' {
        Mock Test-IsAdmin { $true }
        Mock Invoke-ExternalProcess { New-TestProcessResult -ExitCode 0 -Output @('v1.12.350') } -ParameterFilter { $ArgumentList[0] -eq '--version' }

        $result = Invoke-WingetInstall -Apps @(@{ name = 'Contoso.AppOne' }) -WhatIf -NonInteractive

        # Only the read-only checks ran: `winget --version` and the per-app `winget list`.
        Should -Invoke Invoke-ExternalProcess -Times 0 -Exactly -ParameterFilter { $ArgumentList[0] -notin @('list', '--version') }
        Should -Invoke Add-AppxPackage -Times 0 -Exactly
        Should -Invoke Invoke-AppxRegistration -Times 0 -Exactly
        Should -Invoke Repair-WinGetPackageManager -Times 0 -Exactly
        Should -Invoke Start-Process -Times 0 -Exactly

        $result | Should -Be 0
        ($script:infoMessages -join "`n") | Should -Match '\[DRY-RUN\] Would update the winget source for .CONTOSO\\admin-tech. \(winget source update --name winget\), check that winget can open it \(winget search --source winget\), and fix it if it cannot: .*registering the winget source package \(Microsoft\.Winget\.Source\).*winget source reset --force'
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
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
        @{ Code = 1; Meaning = 'a pre-flight check failed (see above)' }
        @{ Code = 2; Meaning = 'winget is not available, could not be started, cannot open its source, or is turned off by Group Policy (see above)' }
        @{ Code = 3; Meaning = 'the app catalog failed validation (see above)' }
        @{ Code = 4; Meaning = 'administrator rights are required, and this run was not elevated, or Group Policy''s execution policy keeps the elevated window from running the installer (see above)' }
        @{ Code = 5; Meaning = 'the run was aborted before it finished (see above)' }
        @{ Code = 6; Meaning = 'another run of the installer is in progress on this PC' }
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

    # Review finding P3-16: 3010 is "succeeded, restart required" to RMM tools and Intune. The
    # adopted precedence is 1 > 2 > 9 > 8 > 3010 > 0.
    It 'Returns 3010 when nothing failed, winget works and the run needs a restart to finish' {
        Get-InstallerExitCode -FailedAppCount 0 -WingetUsable $true -RestartRequired $true | Should -Be 3010
    }

    It 'Ranks failed apps (1) and an unusable winget (2) above a needed restart' {
        Get-InstallerExitCode -FailedAppCount 2 -WingetUsable $true -RestartRequired $true | Should -Be 1
        Get-InstallerExitCode -FailedAppCount 0 -WingetUsable $false -RestartRequired $true | Should -Be 2
    }

    # Review finding P3-36: apps installed, but automatic updates not configured or unhealthy.
    It 'Returns 8 when nothing failed and winget works, but auto-updates are not healthy' {
        Get-InstallerExitCode -FailedAppCount 0 -WingetUsable $true -AutoUpdatesHealthy $false | Should -Be 8
    }

    It 'Ranks 8 below failed apps (1) and an unusable winget (2), and above a needed restart (3010)' {
        Get-InstallerExitCode -FailedAppCount 1 -WingetUsable $true -AutoUpdatesHealthy $false | Should -Be 1
        Get-InstallerExitCode -FailedAppCount 0 -WingetUsable $false -AutoUpdatesHealthy $false | Should -Be 2
        Get-InstallerExitCode -FailedAppCount 0 -WingetUsable $true -AutoUpdatesHealthy $false -RestartRequired $true | Should -Be 8
        Get-InstallerExitCode -FailedAppCount 0 -WingetUsable $true -AutoUpdatesHealthy $true -RestartRequired $true | Should -Be 3010
    }

    # wgt-gq8.41: the time budget was used up before some apps or the auto-update setup. The adopted
    # precedence is 1 > 2 > 9 > 8 > 3010 > 0.
    It 'Returns 9 when nothing failed and winget works, but the time budget left work not attempted' {
        Get-InstallerExitCode -FailedAppCount 0 -WingetUsable $true -WorkNotAttempted $true | Should -Be 9
    }

    It 'Ranks 9 below failed apps (1) and an unusable winget (2), and above auto-updates (8) and a needed restart (3010)' {
        Get-InstallerExitCode -FailedAppCount 1 -WingetUsable $true -WorkNotAttempted $true | Should -Be 1
        Get-InstallerExitCode -FailedAppCount 0 -WingetUsable $false -WorkNotAttempted $true | Should -Be 2
        Get-InstallerExitCode -FailedAppCount 0 -WingetUsable $true -WorkNotAttempted $true -AutoUpdatesHealthy $false | Should -Be 9
        Get-InstallerExitCode -FailedAppCount 0 -WingetUsable $true -WorkNotAttempted $true -RestartRequired $true | Should -Be 9
        Get-InstallerExitCode -FailedAppCount 0 -WingetUsable $true -WorkNotAttempted $false -RestartRequired $true | Should -Be 3010
    }
}

Describe 'Format-InstallFailureReason (issue #189)' {
    Context 'With the full Install-WingetPackage result shape' {
        It 'Includes the hex exit code, attempt count, and machine-scope fallback' {
            $installResult = @{ ExitCode = -2147009255; Attempts = 3; SessionErrorExhausted = $false; MachineScopeFellBack = $true }

            $reason = Format-InstallFailureReason -FailureReason 'VerifyNotFound' -InstallResult $installResult

            $reason | Should -Be 'the installing account has no logon session, so Windows blocked the app package deployment; winget exit 0x80073D19 ERROR_DEPLOYMENT_BLOCKED_BY_USER_LOG_OFF, 3 attempts, machine-scope fallback: yes'
        }

        It 'Uses singular wording for a single attempt' {
            $installResult = @{ ExitCode = -1978335212; Attempts = 1; SessionErrorExhausted = $false; MachineScopeFellBack = $false }

            $reason = Format-InstallFailureReason -FailureReason 'VerifyNotFound' -InstallResult $installResult

            $reason | Should -Be 'winget found no package with that id; winget exit 0x8A150014 NO_APPLICATIONS_FOUND, 1 attempt, machine-scope fallback: no'
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

            $reason | Should -Be 'the installer failed (its own exit code is in the log above, and in its installer log); winget exit 0x8A150006 SHELLEXEC_INSTALL_FAILED, 1 attempt, machine-scope fallback: no, installer log: C:\ProgramData\winget-app-setup\logs\winget-install-Test.App-20261004-101500.log'
        }

        It 'Says that winget could not be launched for the install, with its failed launches and error, and no fabricated exit code (issue #253)' {
            $installResult = @{ ExitCode = $null; Attempts = 0; SessionErrorExhausted = $false; MachineScopeFellBack = $false; LaunchErrorExhausted = $true; LaunchAttempts = 5; LaunchError = 'The file cannot be accessed by the system.' }

            $reason = Format-InstallFailureReason -FailureReason 'InstallLaunchFailed' -InstallResult $installResult -LaunchError $installResult.LaunchError

            $reason | Should -Be 'winget could not be launched to install it; machine-scope fallback: no, 5 failed launches, launch error: The file cannot be accessed by the system'
        }
    }

    Context 'When winget reported why the install failed (review finding P2-15)' {
        It 'Says another installation was in progress, names the code and the time waited, instead of ''package not found after install''' {
            $installResult = @{ ExitCode = -1978334974; Attempts = 4; SessionErrorExhausted = $false; MachineScopeFellBack = $false; InstallInProgressWaitedSeconds = 600 }

            $reason = Format-InstallFailureReason -FailureReason 'VerifyNotFound' -InstallResult $installResult

            $reason | Should -Be 'another installation was in progress (Windows Installer was busy) - re-run the installer once it has finished; winget exit 0x8A150102 INSTALL_INSTALL_IN_PROGRESS, 4 attempts, machine-scope fallback: no, waited 600 seconds for another installation'
        }

        It 'Gives a package-specific installer''s known code the same reason' {
            $reason = Format-InstallFailureReason -FailureReason 'CustomInstallFailed' -InstallResult @{ ExitCode = -1978334975; Installed = $false }

            $reason | Should -Be 'the app is running - close it, then re-run the installer; winget exit 0x8A150101 INSTALL_PACKAGE_IN_USE'
        }

        It 'Keeps ''package not found after install'' when winget reported success' {
            Format-InstallFailureReason -FailureReason 'VerifyNotFound' -InstallResult @{ ExitCode = 0; Attempts = 1 } |
                Should -Be 'package not found after install; winget exit 0x00000000, 1 attempt'
        }
    }

    Context 'When winget could not be launched (review findings P2-8, P2-9)' {
        It 'Names the step <Reason> could not launch winget for, and the error' -ForEach @(
            @{ Reason = 'PreCheckLaunchFailed'; Expected = 'winget could not be launched for the pre-install check; launch error: Access is denied' }
            @{ Reason = 'VerifyLaunchFailed'; Expected = 'winget could not be launched to verify the install; launch error: Access is denied' }
        ) {
            Format-InstallFailureReason -FailureReason $Reason -InstallResult $null -LaunchError 'Access is denied.' | Should -Be $Expected
        }

        It 'Gives every app the circuit breaker failed one short reason' {
            Format-InstallFailureReason -FailureReason 'WingetNotLaunchable' -InstallResult $null |
                Should -Be 'not attempted: winget cannot be launched on this machine (see above)'
        }
    }

    Context 'When a run for the whole PC could not read the provisioned packages (review finding P3-24)' {
        It 'Says what could not be checked' {
            Format-InstallFailureReason -FailureReason 'MachineCheckFailed' -InstallResult $null |
                Should -Be 'could not check whether it is provisioned for every user on this PC (see the warning above)'
        }
    }

    Context 'When winget list ran but failed (review finding P2-9)' {
        It 'Names the check <Reason> and the list''s own exit code, apart from the install''s' -ForEach @(
            @{ Reason = 'PreCheckFailed'; InstallResult = $null; Expected = 'winget list failed during the pre-install check with exit 0x8A15004B FAILED_TO_OPEN_ALL_SOURCES' }
            @{ Reason = 'VerifyFailed'; InstallResult = @{ ExitCode = 0; Attempts = 1; MachineScopeFellBack = $false }; Expected = 'winget list failed during the post-install check with exit 0x8A15004B FAILED_TO_OPEN_ALL_SOURCES; winget exit 0x00000000, 1 attempt, machine-scope fallback: no' }
        ) {
            Format-InstallFailureReason -FailureReason $Reason -InstallResult $InstallResult -CheckExitCode -1978335157 | Should -Be $Expected
        }

        It 'Leaves the exit code out when there is none, and ignores it for other reasons' {
            Format-InstallFailureReason -FailureReason 'PreCheckFailed' -InstallResult $null | Should -Be 'winget list failed during the pre-install check'
            Format-InstallFailureReason -FailureReason 'VerifyNotFound' -InstallResult $null -CheckExitCode -1978335157 | Should -Be 'package not found after install'
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

Describe 'Write-DeferredAppsSummary (review findings P3-22, P3-23)' {
    BeforeEach {
        $script:warningMessages = @()
        Mock Write-WarningMessage { $script:warningMessages += $Message }
    }

    It 'Says nothing when no app was deferred' {
        Write-DeferredAppsSummary -DeferredApps @() -AccountContext (New-TestAccountContext -System)
        Write-DeferredAppsSummary -DeferredApps $null -AccountContext (New-TestAccountContext -System)

        Should -Invoke Write-WarningMessage -Times 0 -Exactly
    }

    It 'Names every deferred app in one line, for SYSTEM' {
        Write-DeferredAppsSummary -DeferredApps @('Contoso.One', 'Contoso.Two') -AccountContext (New-TestAccountContext -System -SessionUser 'CONTOSO\jdoe')

        $script:warningMessages | Should -Be @("Deferred: Contoso.One, Contoso.Two - winget found no machine-wide installer for them that applies to this PC (0x8A150010 NO_APPLICABLE_INSTALLER with --scope machine), and a run as SYSTEM installs for the whole PC only. Not installed and not counted as failed. A per-user app can only be installed in the signed-in user's own account: by this installer run as the signed-in user when that account is an administrator, otherwise by a per-user deployment: the user phase (rmm/Invoke-WingetAppSetupUserPhase.ps1, run as the user at sign-in, for example by an Endpoint Central User Configuration script) installs the apps a run deferred, or the Microsoft Store.")
    }
}

Describe 'Write-InstalledAppNote: per-user installs (review finding P3-22)' {
    BeforeEach {
        $script:infoMessages = @()
        Mock Write-Info { $script:infoMessages += $Message }
        Mock Write-WarningMessage { }
    }

    It 'Says an app that fell back to winget''s default scope was installed for this account only' {
        Write-InstalledAppNote -AppName 'Microsoft.WindowsTerminal' -InstallResult @{ ExitCode = 0; MachineScopeFellBack = $true; RestartRequired = $false } | Should -Be $false

        $script:infoMessages | Should -Be @('Microsoft.WindowsTerminal has no machine-wide installer, so it was installed for this account only.')
    }

    It 'Says nothing more for a machine-wide install' {
        Write-InstalledAppNote -AppName '7zip.7zip' -InstallResult @{ ExitCode = 0; MachineScopeFellBack = $false; RestartRequired = $false } | Should -Be $false

        $script:infoMessages | Should -BeNullOrEmpty
    }
}

# wgt-gq8.42: Microsoft.WinGet.Client prints no restart warning, and it is not winget.exe.
Describe 'Write-InstalledAppNote with the Microsoft.WinGet.Client engine' {
    BeforeEach {
        $script:noteWarnings = @()
        Mock Write-WarningMessage { $script:noteWarnings += $Message }
        Mock Write-Info { }
    }

    It 'Names the installer''s 3010 as the restart, not a winget warning' {
        Write-InstalledAppNote -AppName 'Contoso.MsiApp' -InstallResult @{ ExitCode = 0; RestartRequired = $true; InstallerErrorCode = [long]3010; Engine = 'WinGetClient' } | Should -BeTrue

        $script:noteWarnings | Should -Be @('Contoso.MsiApp needs a restart to finish installing (the installer exited 3010, ERROR_SUCCESS_REBOOT_REQUIRED).')
    }

    It 'Names the WinGet client result of a restart the installer started' {
        Write-InstalledAppNote -AppName 'Contoso.MsiApp' -InstallResult @{ ExitCode = -1978334965; RestartRequired = $true; InstallerErrorCode = [long]1641; Engine = 'WinGetClient' } | Should -BeTrue

        $script:noteWarnings | Should -Be @('Contoso.MsiApp needs a restart to finish installing (WinGet client result 0x8A15010B INSTALL_REBOOT_INITIATED).')
    }

    It 'Names Install-WinGetPackage for another code, when the app is installed anyway' {
        Write-InstalledAppNote -AppName 'Contoso.MsiApp' -InstallResult @{ ExitCode = -1978335159; RestartRequired = $false; InstallerErrorCode = [long]1603; Engine = 'WinGetClient' } | Should -BeFalse

        $script:noteWarnings | Should -Be @('Install-WinGetPackage reported 0x8A150049 MSI_INSTALL_FAILED for Contoso.MsiApp, but it is installed.')
    }

    It 'Keeps the winget.exe texts for winget.exe' {
        Write-InstalledAppNote -AppName '7zip.7zip' -InstallResult @{ ExitCode = 0; RestartRequired = $true; InstallerErrorCode = $null; Engine = 'Cli' } | Should -BeTrue
        Write-InstalledAppNote -AppName '7zip.7zip' -InstallResult @{ ExitCode = -1978335159; RestartRequired = $false; Engine = 'Cli' } | Should -BeFalse

        $script:noteWarnings | Should -Be @("7zip.7zip needs a restart to finish installing (winget printed 'Restart your PC to finish installation.').", 'winget reported 0x8A150049 MSI_INSTALL_FAILED for 7zip.7zip, but it is installed.')
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

    It 'Takes the title the uninstaller passes' {
        Write-FailedAppsSummary -FailedApps @(@{ Name = '7zip.7zip'; Reason = 'not installed' }) -Title 'Failed Uninstalls'

        $script:failedSummaryCalls[0].Title | Should -Be 'Failed Uninstalls'
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

# Work-order item 38: the declarative catalog fields (scope, arch, postInstall, userPhase) in the
# per-app pipeline. Only the winget boundary (Install-WingetPackage, Test-WingetPackageInstalled)
# and the provisioning check are mocked.
Describe 'Install-AppWithVerification: declarative catalog fields (work-order item 38)' {
    BeforeEach {
        Mock Write-Host { }
        $script:infoMessages = @()
        Mock Write-Info { $script:infoMessages += $Message }
        Mock Install-WingetPackage { @{ ExitCode = 0; Attempts = 1; SessionErrorExhausted = $false; MachineScopeFellBack = $false; NoMachineScopeInstaller = $false } }
        # Not installed before the install, installed after it.
        $script:checks = 0
        Mock Test-WingetPackageInstalled {
            $script:checks++
            @{ Installed = ($script:checks -gt 1); TimedOut = $false; LaunchFailed = $false; LaunchError = $null; CheckFailed = $false; ExitCode = 0 }
        }
        Mock Test-AppxPackageProvisionedForMachine { $false }
        $script:hookRuns = 0
        $script:checksAtHook = $null
    }

    Context 'scope' {
        It 'Leaves an entry without a scope to Install-WingetPackage''s default' {
            [void](Install-AppWithVerification -App @{ name = 'Contoso.App' })

            Should -Invoke Install-WingetPackage -Times 1 -Exactly -ParameterFilter { -not $PesterBoundParameters.ContainsKey('Scope') -and -not $MachineScopeOnly }
        }

        It 'Installs a scope user app with -Scope user in a run as the signed-in user' {
            $result = Install-AppWithVerification -App @{ name = 'Contoso.UserApp'; scope = 'user' }

            $result.Status | Should -Be 'Installed'
            Should -Invoke Install-WingetPackage -Times 1 -Exactly -ParameterFilter { $Scope -eq 'user' -and -not $MachineScopeOnly }
        }

        It 'Fails, never defers, a scope machine app with no machine-scope installer in <Run>' -ForEach @(
            @{ Run = 'a run as the signed-in user'; MachineWide = $false }
            @{ Run = 'a run for the whole PC'; MachineWide = $true }
        ) {
            Mock Install-WingetPackage { @{ ExitCode = -1978335216; Attempts = 1; SessionErrorExhausted = $false; MachineScopeFellBack = $false; NoMachineScopeInstaller = $true } }

            $result = Install-AppWithVerification -App @{ name = 'Contoso.MachineOnly'; scope = 'machine' } -MachineWide:$MachineWide

            $result.Status | Should -Be 'Failed'
            $result.FailureReason | Should -Be 'NoMachineScopeInstaller'
            $result.InstallResult.ExitCode | Should -Be -1978335216
            Should -Invoke Install-WingetPackage -Times 1 -Exactly -ParameterFilter { $Scope -eq 'machine' }
        }

        It 'Gives a package-specific installer -MachineScopeOnly for scope machine, and fails the app when it finds no machine-scope installer' {
            Mock Install-PowerShellLatest { @{ ExitCode = -1978335216; Installed = $false; Method = 'msix-native'; NoMachineScopeInstaller = [bool]$MachineScopeOnly } }

            $result = Install-AppWithVerification -App @{ name = 'Microsoft.PowerShell'; install = 'Install-PowerShellLatest'; scope = 'machine' }

            $result.Status | Should -Be 'Failed'
            $result.FailureReason | Should -Be 'NoMachineScopeInstaller'
            Should -Invoke Install-PowerShellLatest -Times 1 -Exactly -ParameterFilter { $MachineScopeOnly }
        }
    }

    Context 'scope user and userPhase in a run for the whole PC' {
        It 'Defers <Case> before any winget call, with DeferReason <Reason>' -ForEach @(
            @{ Case = 'a scope user app'; App = @{ name = 'Contoso.UserApp'; scope = 'user' }; Reason = 'UserScope' }
            @{ Case = 'a userPhase app'; App = @{ name = 'Contoso.UserSetting'; userPhase = $true }; Reason = 'UserPhase' }
            @{ Case = 'a userPhase MSIX app with a hook'; App = @{ name = 'Contoso.Msix'; msixName = 'Contoso.Msix'; userPhase = $true; postInstall = { $script:hookRuns++; 'Configured' } }; Reason = 'UserPhase' }
        ) {
            $result = Install-AppWithVerification -App $App -MachineWide

            $result.Status | Should -Be 'Deferred'
            $result.DeferReason | Should -Be $Reason
            $result.FailureReason | Should -BeNullOrEmpty
            $result.InstallResult | Should -BeNullOrEmpty
            Should -Invoke Test-WingetPackageInstalled -Times 0 -Exactly
            Should -Invoke Install-WingetPackage -Times 0 -Exactly
            Should -Invoke Test-AppxPackageProvisionedForMachine -Times 0 -Exactly
            $script:hookRuns | Should -Be 0
        }

        It 'Defers a per-user app even when winget cannot be started' {
            $result = Install-AppWithVerification -App @{ name = 'Contoso.UserApp'; scope = 'user' } -MachineWide -WingetNotLaunchable

            $result.Status | Should -Be 'Deferred'
            $result.DeferReason | Should -Be 'UserScope'
        }

        It 'Still skips a per-user app that does not apply to this PC' {
            $result = Install-AppWithVerification -App @{ name = 'Contoso.UserApp'; scope = 'user'; condition = { $false } } -MachineWide

            $result.Status | Should -Be 'Skipped'
            $result.SkipReason | Should -Be 'NotApplicable'
        }

        It 'Installs a userPhase app as usual in a run as the signed-in user' {
            $result = Install-AppWithVerification -App @{ name = 'Contoso.UserSetting'; userPhase = $true }

            $result.Status | Should -Be 'Installed'
            Should -Invoke Install-WingetPackage -Times 1 -Exactly -ParameterFilter { -not $MachineScopeOnly }
        }
    }

    Context 'postInstall' {
        It 'Runs the hook once the install is verified, and carries its result' {
            $result = Install-AppWithVerification -App @{ name = 'Contoso.App'; postInstall = { $script:hookRuns++; $script:checksAtHook = $script:checks; 'Configured' } }

            $result.Status | Should -Be 'Installed'
            $result.Configuration.Status | Should -Be 'Configured'
            $script:hookRuns | Should -Be 1
            # After the post-install check, not before it.
            $script:checksAtHook | Should -Be 2
            $script:infoMessages | Should -Contain 'Configuring: Contoso.App'
        }

        It 'Runs the hook for an app that is already installed' {
            Mock Test-WingetPackageInstalled { @{ Installed = $true; TimedOut = $false; LaunchFailed = $false; LaunchError = $null; CheckFailed = $false; ExitCode = 0 } }

            $result = Install-AppWithVerification -App @{ name = 'Contoso.App'; postInstall = { $script:hookRuns++; 'Configured' } }

            $result.Status | Should -Be 'Skipped'
            $result.Configuration.Status | Should -Be 'Configured'
            $script:hookRuns | Should -Be 1
            Should -Invoke Install-WingetPackage -Times 0 -Exactly
        }

        It 'Runs the hook for an MSIX app provisioned for every user, in a run for the whole PC' {
            Mock Test-AppxPackageProvisionedForMachine { $true }

            $result = Install-AppWithVerification -App @{ name = 'Contoso.Msix'; msixName = 'Contoso.Msix'; postInstall = { $script:hookRuns++; 'Configured' } } -MachineWide

            $result.Status | Should -Be 'Skipped'
            $result.SkipReason | Should -Be 'Provisioned'
            $result.Configuration.Status | Should -Be 'Configured'
        }

        It 'Runs the hook after a package-specific installer reports Installed' {
            Mock Install-PowerShellLatest { @{ ExitCode = 0; Installed = $true; Method = 'msi' } }

            $result = Install-AppWithVerification -App @{ name = 'Microsoft.PowerShell'; install = 'Install-PowerShellLatest'; postInstall = { $script:hookRuns++; 'Configured' } }

            $result.Status | Should -Be 'Installed'
            $result.Configuration.Status | Should -Be 'Configured'
        }

        It 'Keeps an app its hook could not configure installed, with the reason' {
            $result = Install-AppWithVerification -App @{ name = 'Contoso.App'; postInstall = { @{ Status = 'NotConfigured'; Reason = 'no password supplied' } } }

            $result.Status | Should -Be 'Installed'
            $result.FailureReason | Should -BeNullOrEmpty
            $result.Configuration.Status | Should -Be 'NotConfigured'
            $result.Configuration.Reason | Should -Be 'no password supplied'
        }

        It 'Fails an installed app whose hook <Case>' -ForEach @(
            @{ Case = 'returns Failed'; Hook = { @{ Status = 'Failed'; Reason = 'the service did not start' } }; Reason = 'the service did not start' }
            @{ Case = 'throws'; Hook = { throw 'Access to the registry key is denied.' }; Reason = 'Access to the registry key is denied.' }
            @{ Case = 'returns nothing'; Hook = { }; Reason = 'the post-install hook returned no result (expected Configured, NotConfigured or Failed)' }
        ) {
            $result = Install-AppWithVerification -App @{ name = 'Contoso.App'; postInstall = $Hook }

            $result.Status | Should -Be 'Failed'
            $result.FailureReason | Should -Be 'PostInstallFailed'
            $result.Configuration.Status | Should -Be 'Failed'
            $result.Configuration.Reason | Should -Be $Reason
            # The install itself succeeded; its result is kept, and so is what this call did.
            $result.InstallResult.ExitCode | Should -Be 0
            $result.StatusBeforeHook | Should -Be 'Installed'
        }

        It 'Fails an already-installed app whose hook fails, so it is retried and counted' {
            Mock Test-WingetPackageInstalled { @{ Installed = $true; TimedOut = $false; LaunchFailed = $false; LaunchError = $null; CheckFailed = $false; ExitCode = 0 } }

            $result = Install-AppWithVerification -App @{ name = 'Contoso.App'; postInstall = { 'Failed' } }

            $result.Status | Should -Be 'Failed'
            $result.FailureReason | Should -Be 'PostInstallFailed'
            $result.SkipReason | Should -BeNullOrEmpty
            $result.StatusBeforeHook | Should -Be 'Skipped'
            $result.InstallResult | Should -BeNullOrEmpty
        }

        It 'Does not run the hook for an app that was not installed: <Case>' -ForEach @(
            @{ Case = 'not applicable'; App = @{ condition = { $false } }; Parameters = @{}; Status = 'Skipped' }
            @{ Case = 'deferred for want of a machine-scope installer'; App = @{}; Parameters = @{ MachineWide = $true }; Status = 'Deferred'; NoMachineScope = $true }
            @{ Case = 'still missing after the install'; App = @{}; Parameters = @{}; Status = 'Failed'; NeverInstalled = $true }
            @{ Case = 'winget cannot be started'; App = @{}; Parameters = @{ WingetNotLaunchable = $true }; Status = 'Failed' }
        ) {
            if ($NoMachineScope) {
                Mock Install-WingetPackage { @{ ExitCode = -1978335216; Attempts = 1; SessionErrorExhausted = $false; MachineScopeFellBack = $false; NoMachineScopeInstaller = $true } }
            }
            if ($NeverInstalled) {
                Mock Test-WingetPackageInstalled { @{ Installed = $false; TimedOut = $false; LaunchFailed = $false; LaunchError = $null; CheckFailed = $false; ExitCode = 0 } }
            }
            $entry = @{ name = 'Contoso.App'; postInstall = { $script:hookRuns++; 'Configured' } }
            foreach ($key in $App.Keys) {
                $entry[$key] = $App[$key]
            }

            $result = Install-AppWithVerification -App $entry @Parameters

            $result.Status | Should -Be $Status
            $result.FailureReason | Should -Not -Be 'PostInstallFailed'
            $result.ContainsKey('Configuration') | Should -BeFalse
            $script:hookRuns | Should -Be 0
        }

        It 'Does not run the hook in a dry run, and says it would (<Case>)' -ForEach @(
            @{ Case = 'an app a real run would install'; Installed = $false; Status = 'Installed' }
            @{ Case = 'an app already installed'; Installed = $true; Status = 'Skipped' }
        ) {
            $script:alreadyInstalled = $Installed
            Mock Test-WingetPackageInstalled { @{ Installed = $script:alreadyInstalled; TimedOut = $false; LaunchFailed = $false; LaunchError = $null; CheckFailed = $false; ExitCode = 0 } }

            $result = Install-AppWithVerification -App @{ name = 'Contoso.App'; postInstall = { $script:hookRuns++; 'Configured' } } -WhatIf

            $result.Status | Should -Be $Status
            $result.ContainsKey('Configuration') | Should -BeFalse
            $script:hookRuns | Should -Be 0
            $script:infoMessages | Should -Contain '[DRY-RUN] Would run the post-install configuration of Contoso.App.'
        }
    }
}

Describe 'Test-AppApplicability: the arch list (work-order item 38)' {
    BeforeEach {
        $script:warnings = @()
        Mock Write-WarningMessage { $script:warnings += $Message }
    }

    It 'Applies on <Architecture> when the arch list is <Arch>: <Expected>' -ForEach @(
        @{ Arch = 'X64'; Architecture = 'X64'; Expected = $true }
        @{ Arch = 'x64'; Architecture = 'X64'; Expected = $true }
        @{ Arch = 'X64'; Architecture = 'Arm64'; Expected = $false }
        @{ Arch = @('Arm64', 'X86'); Architecture = 'Arm64'; Expected = $true }
        @{ Arch = @('Arm64', 'X86'); Architecture = 'X64'; Expected = $false }
    ) {
        $script:mockedArchitecture = $Architecture
        Mock Get-OSArchitecture { $script:mockedArchitecture }

        Test-AppApplicability -App @{ name = 'Contoso.App'; arch = $Arch } | Should -Be $Expected
        $script:warnings | Should -BeNullOrEmpty
    }

    It 'Needs both the arch list and the condition to allow the app' {
        Mock Get-OSArchitecture { 'X64' }

        Test-AppApplicability -App @{ name = 'Contoso.App'; arch = 'X64'; condition = { $false } } | Should -BeFalse
        Test-AppApplicability -App @{ name = 'Contoso.App'; arch = 'Arm64'; condition = { $true } } | Should -BeFalse
        Test-AppApplicability -App @{ name = 'Contoso.App'; arch = 'X64'; condition = { $true } } | Should -BeTrue
    }

    It 'Does not run the condition when the arch list rules the PC out' {
        Mock Get-OSArchitecture { 'Arm64' }

        Test-AppApplicability -App @{ name = 'Contoso.App'; arch = 'X64'; condition = { throw 'must not run' } } | Should -BeFalse
        $script:warnings | Should -BeNullOrEmpty
    }

    It 'Fails open when the architecture cannot be read, warns, and lets the condition decide (<Purpose>)' -ForEach @(
        @{ Purpose = 'Install'; Attempt = 'attempting the install' }
        @{ Purpose = 'Uninstall'; Attempt = 'attempting the uninstall' }
    ) {
        Mock Get-OSArchitecture { throw 'The OS architecture could not be read.' }

        Test-AppApplicability -App @{ name = 'Contoso.App'; arch = 'X64' } -Purpose $Purpose | Should -BeTrue
        Test-AppApplicability -App @{ name = 'Contoso.App'; arch = 'X64'; condition = { $false } } -Purpose $Purpose | Should -BeFalse

        $script:warnings[0] | Should -Be "Architecture check for Contoso.App failed (The OS architecture could not be read.); treating its arch list as met and $Attempt."
    }

    It 'Does not read the architecture for an entry without an arch list' {
        Mock Get-OSArchitecture { throw 'must not be read' }

        Test-AppApplicability -App @{ name = 'Contoso.App' } | Should -BeTrue
        Should -Invoke Get-OSArchitecture -Times 0 -Exactly
    }
}

# Work-order item 38 through the real orchestrator and the real per-app pipeline: only the winget
# boundary, the account and the steps around the installs are mocked.
Describe 'Invoke-WingetInstall: declarative catalog fields (work-order item 38)' {
    BeforeEach {
        Mock Write-Host { }
        Mock Start-Process { }
        Mock Start-Sleep { }
        Mock Test-IsAdmin { $true }
        Mock Restart-WithElevation { [pscustomobject]@{ Started = $true; ExitCode = 0 } }
        Mock Test-IsRunningLocally { $true }
        Mock Initialize-Winget { [pscustomobject]@{ Ready = $true; Diagnosis = 'Ok' } }
        Mock Remove-LegacyScheduledUpdates { $true }
        Mock Set-WindowsTerminalDefaults { }
        Mock Install-WingetAutoUpdate { [pscustomobject]@{ Status = 'AlreadyPresent'; Version = '2.12.0' } }
        Mock Test-WingetLaunchable { [pscustomobject]@{ Launchable = $true; Version = 'v1.12.350'; Reason = $null; Attempts = 1 } }
        Mock Wait-WauIdle { $true }
        Mock Get-PendingRestartState { New-TestRestartState }
        Mock Get-InstallAccountContext { New-TestAccountContext }
        Mock Test-AppxPackageProvisionedForMachine { $false }

        # winget: an app is installed once Install-WingetPackage ran for it.
        $script:installedIds = @()
        Mock Install-WingetPackage {
            $script:installedIds += $PackageId
            @{ ExitCode = 0; Attempts = 1; SessionErrorExhausted = $false; MachineScopeFellBack = $false; NoMachineScopeInstaller = $false }
        }
        Mock Test-WingetPackageInstalled { @{ Installed = ($script:installedIds -contains $PackageId); TimedOut = $false; LaunchFailed = $false; LaunchError = $null; CheckFailed = $false; ExitCode = 0 } }

        $script:capturedTables = @{}
        Mock Write-Table { $script:capturedTables[$Title] = $Rows }
        $script:messages = @()
        Mock Write-Info { $script:messages += $Message }
        Mock Write-Success { $script:messages += $Message }
        Mock Write-WarningMessage { $script:messages += $Message }
        Mock Write-ErrorMessage { $script:messages += $Message }
        $script:runRecord = $null
        Mock Write-InstallerRunResult { $script:runRecord = $Record }
        $script:hookCalls = 0
    }

    It 'Installs a scope user app with --scope user, runs the hooks and reports one the hook could not configure, as the signed-in user' {
        $apps = @(
            @{ name = 'Contoso.UserApp'; scope = 'user' },
            @{ name = 'Contoso.Configured'; userPhase = $true; postInstall = { 'Configured' } },
            @{ name = 'Contoso.Unconfigured'; postInstall = { @{ Status = 'NotConfigured'; Reason = 'no password supplied' } } }
        )

        $result = Invoke-WingetInstall -Apps $apps -NonInteractive

        $result | Should -Be 0
        Should -Invoke Install-WingetPackage -Times 1 -Exactly -ParameterFilter { $PackageId -eq 'Contoso.UserApp' -and $Scope -eq 'user' }
        @($script:capturedTables['Installation Summary'] | Where-Object { $_[0] -eq 'Installed' })[0][1] | Should -Be 'Contoso.UserApp, Contoso.Configured, Contoso.Unconfigured'
        $script:messages | Should -Contain 'Configured: Contoso.Configured'
        $script:messages | Should -Contain 'Not configured: Contoso.Unconfigured (no password supplied)'
        $script:messages | Should -Contain 'Configuration: NOT DONE for Contoso.Unconfigured (no password supplied) - installed, but the post-install configuration did not finish. Not counted as failed; re-run the installer once the reason is fixed.'

        $records = @($script:runRecord.apps)
        ($records | Where-Object { $_.id -eq 'Contoso.UserApp' }).postInstall | Should -BeNullOrEmpty
        ($records | Where-Object { $_.id -eq 'Contoso.Configured' }).postInstall | Should -Be 'Configured'
        $unconfigured = $records | Where-Object { $_.id -eq 'Contoso.Unconfigured' }
        $unconfigured.status | Should -Be 'Installed'
        $unconfigured.postInstall | Should -Be 'NotConfigured'
        $unconfigured.postInstallReason | Should -Be 'no password supplied'
    }

    It 'Exits 1 when a hook fails in both passes, with the hook''s reason as the app''s failure reason' {
        $apps = @(@{ name = 'Contoso.App'; postInstall = { $script:hookCalls++; @{ Status = 'Failed'; Reason = 'the service did not start' } } })

        $result = Invoke-WingetInstall -Apps $apps -NonInteractive

        $result | Should -Be 1
        # The first pass and the retry pass, which finds the app installed and runs the hook again.
        $script:hookCalls | Should -Be 2
        Should -Invoke Install-WingetPackage -Times 1 -Exactly
        $script:messages | Should -Contain 'Failed to install: Contoso.App (installed, but its post-install configuration failed (the service did not start)).'
        $failedRows = $script:capturedTables['Failed Installations']
        $failedRows[0][0] | Should -Be 'Contoso.App'
        $failedRows[0][1] | Should -Be 'installed, but its post-install configuration failed (the service did not start)'
        $record = @($script:runRecord.apps)[0]
        $record.status | Should -Be 'Failed'
        $record.postInstall | Should -Be 'Failed'
        $record.postInstallReason | Should -Be 'the service did not start'
        $script:runRecord.counts.failed | Should -Be 1
    }

    It 'Recovers in the retry pass when the hook succeeds the second time' {
        $apps = @(@{ name = 'Contoso.App'; postInstall = { $script:hookCalls++; if ($script:hookCalls -eq 1) { throw 'locked' }; 'Configured' } })

        $result = Invoke-WingetInstall -Apps $apps -NonInteractive

        $result | Should -Be 0
        $script:messages | Should -Contain 'Retry succeeded: Contoso.App'
        $script:messages | Should -Contain 'Configured: Contoso.App'
        $record = @($script:runRecord.apps)[0]
        $record.status | Should -Be 'Installed'
        $record.postInstall | Should -Be 'Configured'
    }

    It 'Keeps the install''s restart and exit code when its hook fails in the first pass and succeeds in the retry pass' {
        Mock Install-WingetPackage {
            $script:installedIds += $PackageId
            @{ ExitCode = -1978334967; Attempts = 1; SessionErrorExhausted = $false; MachineScopeFellBack = $false; NoMachineScopeInstaller = $false; RestartRequired = $true }
        }
        $apps = @(@{ name = 'Contoso.App'; postInstall = { $script:hookCalls++; if ($script:hookCalls -eq 1) { throw 'locked' }; 'Configured' } })

        $result = Invoke-WingetInstall -Apps $apps -NonInteractive

        $result | Should -Be 3010
        Should -Invoke Install-WingetPackage -Times 1 -Exactly
        $script:hookCalls | Should -Be 2
        # Printed once, with the first pass's install, which is the only one.
        @($script:messages | Where-Object { $_ -eq 'Contoso.App needs a restart to finish installing (winget exit 0x8A150109 INSTALL_REBOOT_REQUIRED_TO_FINISH).' }).Count | Should -Be 1
        $script:messages | Should -Contain 'Retry succeeded: Contoso.App'
        @($script:capturedTables['Installation Summary'] | Where-Object { $_[0] -eq 'Installed' })[0][1] | Should -Be 'Contoso.App'
        $record = @($script:runRecord.apps)[0]
        $record.status | Should -Be 'Installed'
        $record.restartRequired | Should -BeTrue
        $record.codeHex | Should -Be '0x8A150109'
        $record.postInstall | Should -Be 'Configured'
    }

    It 'Counts the install''s restart, and keeps its exit code in the record, when its hook fails in both passes' {
        Mock Install-WingetPackage {
            $script:installedIds += $PackageId
            @{ ExitCode = -1978334967; Attempts = 1; SessionErrorExhausted = $false; MachineScopeFellBack = $true; NoMachineScopeInstaller = $false; RestartRequired = $true }
        }
        $apps = @(@{ name = 'Contoso.App'; postInstall = { $script:hookCalls++; 'Failed' } })

        $result = Invoke-WingetInstall -Apps $apps -NonInteractive

        $result | Should -Be 1
        $script:messages | Should -Contain 'Contoso.App has no machine-wide installer, so it was installed for this account only.'
        @($script:messages | Where-Object { $_ -eq 'Contoso.App needs a restart to finish installing (winget exit 0x8A150109 INSTALL_REBOOT_REQUIRED_TO_FINISH).' }).Count | Should -Be 1
        $record = @($script:runRecord.apps)[0]
        $record.status | Should -Be 'Failed'
        $record.restartRequired | Should -BeTrue
        $record.codeHex | Should -Be '0x8A150109'
        $script:runRecord.restartRequired | Should -BeTrue
    }

    It 'Reports an app that was already installed as skipped when only its hook needed the retry pass' {
        $script:installedIds = @('Contoso.App')
        $apps = @(@{ name = 'Contoso.App'; postInstall = { $script:hookCalls++; if ($script:hookCalls -eq 1) { throw 'locked' }; 'Configured' } })

        $result = Invoke-WingetInstall -Apps $apps -NonInteractive

        $result | Should -Be 0
        Should -Invoke Install-WingetPackage -Times 0 -Exactly
        $script:messages | Should -Contain 'Configured: Contoso.App'
        @($script:capturedTables['Installation Summary'] | Where-Object { $_[0] -eq 'Skipped' })[0][1] | Should -Be 'Contoso.App'
        @($script:capturedTables['Installation Summary'] | Where-Object { $_[0] -eq 'Installed' }).Count | Should -Be 0
        $record = @($script:runRecord.apps)[0]
        $record.status | Should -Be 'Skipped'
        $record.reason | Should -Be 'already installed'
        $record.postInstall | Should -Be 'Configured'
        $script:runRecord.counts.installed | Should -Be 0
        $script:runRecord.counts.skipped | Should -Be 1
    }

    It 'Does not retry a scope machine app that has no machine-scope installer' {
        Mock Install-WingetPackage { @{ ExitCode = -1978335216; Attempts = 1; SessionErrorExhausted = $false; MachineScopeFellBack = $false; NoMachineScopeInstaller = $true } }

        $result = Invoke-WingetInstall -Apps @(@{ name = 'Contoso.MachineOnly'; scope = 'machine' }) -NonInteractive

        $result | Should -Be 1
        Should -Invoke Install-WingetPackage -Times 1 -Exactly
        Should -Invoke Test-WingetPackageInstalled -Times 1 -Exactly
        $script:messages | Should -Contain "Not retrying Contoso.MachineOnly: no machine-scope installer applies to this PC, and its catalog entry allows only a machine-wide install (scope 'machine')."
        $script:messages | Should -Not -Contain 'Retrying: Contoso.MachineOnly'
        $script:capturedTables['Failed Installations'][0][0] | Should -Be 'Contoso.MachineOnly'
        (@($script:runRecord.apps)[0]).status | Should -Be 'Failed'
    }

    It 'Defers the per-user apps under cross-user elevation, before any winget call, and says why in the line, the summary and the record' {
        Mock Get-InstallAccountContext { New-TestAccountContext -CrossUser -ProcessUser 'CONTOSO\admin-tech' -SessionUser 'CONTOSO\jdoe' }
        $apps = @(
            @{ name = 'Contoso.MachineApp' },
            @{ name = 'Contoso.UserApp'; scope = 'user' },
            @{ name = 'Contoso.UserSetting'; userPhase = $true; postInstall = { $script:hookCalls++; 'Configured' } }
        )

        $result = Invoke-WingetInstall -Apps $apps -NonInteractive

        $result | Should -Be 0
        @($script:capturedTables['Installation Summary'] | Where-Object { $_[0] -eq 'Deferred' })[0][1] | Should -Be 'Contoso.UserApp, Contoso.UserSetting'
        @($script:capturedTables['Installation Summary'] | Where-Object { $_[0] -eq 'Installed' })[0][1] | Should -Be 'Contoso.MachineApp'
        Should -Invoke Test-WingetPackageInstalled -Times 0 -Exactly -ParameterFilter { $PackageId -ne 'Contoso.MachineApp' }
        Should -Invoke Install-WingetPackage -Times 0 -Exactly -ParameterFilter { $PackageId -ne 'Contoso.MachineApp' }
        $script:hookCalls | Should -Be 0

        $script:messages | Should -Contain "Deferred: Contoso.UserApp (per-user app (catalog scope 'user'): it installs only into the signed-in user's own account)"
        $script:messages | Should -Contain "Deferred: Contoso.UserSetting (per-user setup (catalog userPhase): it needs the signed-in user's own account)"
        $script:messages | Should -Contain "Deferred: Contoso.UserApp, Contoso.UserSetting - the catalog marks them per-user (scope 'user' or userPhase), so they can be installed or set up only in the account 'CONTOSO\jdoe', and installing per-user here would install for 'CONTOSO\admin-tech' instead of 'CONTOSO\jdoe'. Not installed and not counted as failed. This installer run as 'CONTOSO\jdoe' installs them when that account is an administrator; otherwise a per-user deployment does: the user phase (rmm/Invoke-WingetAppSetupUserPhase.ps1, run as the user at sign-in, for example by an Endpoint Central User Configuration script) installs and sets up the apps a run deferred, or the Microsoft Store."
        # Not the 0x8A150010 explanation: winget was never asked about them.
        ($script:messages -join "`n") | Should -Not -Match 'NO_APPLICABLE_INSTALLER'

        $records = @($script:runRecord.apps)
        ($records | Where-Object { $_.id -eq 'Contoso.UserApp' }).status | Should -Be 'Deferred'
        ($records | Where-Object { $_.id -eq 'Contoso.UserApp' }).reason | Should -Be "per-user app (catalog scope 'user'): it installs only into the signed-in user's own account"
        ($records | Where-Object { $_.id -eq 'Contoso.UserSetting' }).reason | Should -Be "per-user setup (catalog userPhase): it needs the signed-in user's own account"
        $script:runRecord.counts.deferred | Should -Be 2
    }

    It 'Returns 3, before installing anything, for a catalog entry with an invalid field' {
        $result = Invoke-WingetInstall -Apps @(@{ name = 'Contoso.App' }, @{ name = 'Contoso.Bad'; scope = 'everyone' }) -NonInteractive

        $result | Should -Be 3
        Should -Invoke Install-WingetPackage -Times 0 -Exactly
        ($script:messages -join "`n") | Should -Match "App entry at index 1 \('Contoso\.Bad'\) has an invalid 'scope' value 'everyone'"
    }

    It 'Skips an app whose arch list rules this PC out, naming the architectures' {
        Mock Get-OSArchitecture { 'Arm64' }

        $result = Invoke-WingetInstall -Apps @(@{ name = 'Contoso.X64Only'; arch = 'X64' }, @{ name = 'Contoso.Anywhere' }) -NonInteractive

        $result | Should -Be 0
        $script:messages | Should -Contain 'Skipping: Contoso.X64Only (not applicable: for X64 Windows only; this PC is Arm64)'
        Should -Invoke Test-WingetPackageInstalled -Times 0 -Exactly -ParameterFilter { $PackageId -eq 'Contoso.X64Only' }
        (@($script:runRecord.apps) | Where-Object { $_.id -eq 'Contoso.X64Only' }).reason | Should -Be 'not applicable: for X64 Windows only; this PC is Arm64'
    }
}

Describe 'Reporting the declarative catalog fields (work-order item 38)' {
    BeforeEach {
        $script:warningMessages = @()
        Mock Write-WarningMessage { $script:warningMessages += $Message }
        $script:successMessages = @()
        Mock Write-Success { $script:successMessages += $Message }
    }

    It 'Format-InstallFailureReason gives a failed hook''s reason, without the successful install''s details' {
        $reason = Format-InstallFailureReason -FailureReason 'PostInstallFailed' -InstallResult @{ ExitCode = 0; Attempts = 1; MachineScopeFellBack = $false } -PostInstallReason ' the service did not start '

        $reason | Should -Be 'installed, but its post-install configuration failed (the service did not start)'
        Format-InstallFailureReason -FailureReason 'PostInstallFailed' | Should -Be 'installed, but its post-install configuration failed (no reason given)'
    }

    It 'Format-InstallFailureReason says a scope machine app has no machine-scope installer' {
        $reason = Format-InstallFailureReason -FailureReason 'NoMachineScopeInstaller' -InstallResult @{ ExitCode = -1978335216; Attempts = 1; MachineScopeFellBack = $false }

        $reason | Should -Be "no machine-scope installer applies to this PC, and its catalog entry allows only a machine-wide install (scope 'machine'); winget exit 0x8A150010 NO_APPLICABLE_INSTALLER, 1 attempt, machine-scope fallback: no"
    }

    It 'Get-AppDeferReasonText words each deferral' {
        Get-AppDeferReasonText -DeferReason 'NoMachineScopeInstaller' | Should -Be 'winget found no machine-wide installer for it'
        Get-AppDeferReasonText -DeferReason $null | Should -Be 'winget found no machine-wide installer for it'
        Get-AppDeferReasonText -DeferReason 'UserScope' | Should -Match "catalog scope 'user'"
        Get-AppDeferReasonText -DeferReason 'UserPhase' | Should -Match 'catalog userPhase'
    }

    It 'Write-DeferredAppsSummary explains the per-user apps on a line of their own, for SYSTEM' {
        Write-DeferredAppsSummary -DeferredApps @('Contoso.NoMachine') -PerUserApps @('Contoso.UserApp') -AccountContext (New-TestAccountContext -System -SessionUser 'CONTOSO\jdoe')

        $script:warningMessages.Count | Should -Be 2
        $script:warningMessages[0] | Should -Match '^Deferred: Contoso\.NoMachine - winget found no machine-wide installer for it'
        $script:warningMessages[1] | Should -Be "Deferred: Contoso.UserApp - the catalog marks it per-user (scope 'user' or userPhase), so it can be installed or set up only in the signed-in user's own account, and a run as SYSTEM installs for the whole PC only. Not installed and not counted as failed. This installer run as the signed-in user installs it when that account is an administrator; otherwise a per-user deployment does: the user phase (rmm/Invoke-WingetAppSetupUserPhase.ps1, run as the user at sign-in, for example by an Endpoint Central User Configuration script) installs and sets up the apps a run deferred, or the Microsoft Store."
    }

    It 'Write-DeferredAppsSummary says nothing about per-user apps when there are none' {
        Write-DeferredAppsSummary -DeferredApps @() -PerUserApps @() -AccountContext (New-TestAccountContext -System)
        Write-DeferredAppsSummary -PerUserApps $null -AccountContext (New-TestAccountContext -System)

        Should -Invoke Write-WarningMessage -Times 0 -Exactly
    }

    It 'Write-AppPostInstallResult prints the result and returns whether the app is not configured' {
        Write-AppPostInstallResult -AppName 'Contoso.App' -Configuration @{ Status = 'Configured'; Reason = $null } | Should -BeFalse
        Write-AppPostInstallResult -AppName 'Contoso.Other' -Configuration @{ Status = 'NotConfigured'; Reason = 'later' } | Should -BeTrue
        Write-AppPostInstallResult -AppName 'Contoso.Failed' -Configuration @{ Status = 'Failed'; Reason = 'x' } | Should -BeFalse
        Write-AppPostInstallResult -AppName 'Contoso.None' -Configuration $null | Should -BeFalse

        $script:successMessages | Should -Be @('Configured: Contoso.App')
        $script:warningMessages | Should -Be @('Not configured: Contoso.Other (later)')
    }

    It 'Write-NotConfiguredAppsSummary names every app with its reason in one line, and nothing when there is none' {
        Write-NotConfiguredAppsSummary -NotConfiguredApps @()
        Write-NotConfiguredAppsSummary -NotConfiguredApps $null
        Should -Invoke Write-WarningMessage -Times 0 -Exactly

        Write-NotConfiguredAppsSummary -NotConfiguredApps @(@{ Name = 'Contoso.One'; Reason = 'a' }, @{ Name = 'Contoso.Two'; Reason = 'b' })

        $script:warningMessages | Should -Be @('Configuration: NOT DONE for Contoso.One (a); Contoso.Two (b) - installed, but the post-install configuration did not finish. Not counted as failed; re-run the installer once the reason is fixed.')
    }
}
