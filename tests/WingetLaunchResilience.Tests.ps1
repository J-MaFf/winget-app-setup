# Tests for WingetAppSetup/Private/WingetLaunchResilience.ps1 (issues #258, #277): classification of
# transient winget-launch failures, resolution of a concrete winget.exe that bypasses the per-user
# app-execution alias while DesktopAppInstaller is mid-upgrade, and waiting out that window after
# Install-WingetAutoUpdate's RUN_WAU=YES background run.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'Test-TransientWingetLaunchError' {
    It 'Classifies ERROR_CANT_ACCESS_FILE as transient' {
        Test-TransientWingetLaunchError -Message 'This command cannot be run due to the error: The file cannot be accessed by the system.' |
            Should -Be $true
    }

    It 'Classifies ERROR_SHARING_VIOLATION as transient' {
        Test-TransientWingetLaunchError -Message 'The process cannot access the file because it is being used by another process.' |
            Should -Be $true
    }

    It 'Matches case-insensitively' {
        Test-TransientWingetLaunchError -Message 'THE FILE CANNOT BE ACCESSED BY THE SYSTEM.' |
            Should -Be $true
    }

    It 'Does not classify an unrelated launch failure as transient' {
        Test-TransientWingetLaunchError -Message 'The system cannot find the file specified.' |
            Should -Be $false
    }

    It 'Handles a null or empty message without throwing' {
        Test-TransientWingetLaunchError -Message $null | Should -Be $false
        Test-TransientWingetLaunchError -Message '' | Should -Be $false
    }

    It 'Classifies the native-command-invocation StandardOutputEncoding symptom as transient (issue #277)' {
        Test-TransientWingetLaunchError -Message 'StandardOutputEncoding is only supported when standard output is redirected.' |
            Should -Be $true
    }
}

Describe 'Get-ConflictingDesktopAppInstallerVersions (issue #279)' {
    It 'Returns an empty array when exactly one version is registered (the healthy case)' {
        Mock Get-AppxPackage { [pscustomobject]@{ Version = '1.26.510.0' } }

        @(Get-ConflictingDesktopAppInstallerVersions).Count | Should -Be 0
        Should -Invoke Get-AppxPackage -Times 1 -Exactly -ParameterFilter { $Name -eq 'Microsoft.DesktopAppInstaller' }
    }

    It 'Returns an empty array when no version is registered at all' {
        Mock Get-AppxPackage { $null }

        @(Get-ConflictingDesktopAppInstallerVersions).Count | Should -Be 0
    }

    It 'Returns an empty array when Get-AppxPackage throws (e.g. no Appx compatibility session)' {
        Mock Get-AppxPackage { throw 'Operation is not supported on this platform.' }

        @(Get-ConflictingDesktopAppInstallerVersions).Count | Should -Be 0
    }

    It 'Returns both distinct versions when two are simultaneously registered (the deadlock case)' {
        Mock Get-AppxPackage {
            @(
                [pscustomobject]@{ Version = '1.26.510.0' }
                [pscustomobject]@{ Version = '1.29.290.0' }
            )
        }

        $result = @(Get-ConflictingDesktopAppInstallerVersions)

        $result.Count | Should -Be 2
        $result | Should -Contain '1.26.510.0'
        $result | Should -Contain '1.29.290.0'
    }

    It 'De-duplicates when the same version appears more than once' {
        Mock Get-AppxPackage {
            @(
                [pscustomobject]@{ Version = '1.26.510.0' }
                [pscustomobject]@{ Version = '1.26.510.0' }
            )
        }

        @(Get-ConflictingDesktopAppInstallerVersions).Count | Should -Be 0
    }
}

Describe 'Resolve-WingetExecutable' {
    It 'Returns the bare command name without -BypassAlias, and never queries the package database' {
        Mock Get-AppxPackage { throw 'must not be called on the fast path' }

        Resolve-WingetExecutable | Should -Be 'winget'

        Should -Invoke Get-AppxPackage -Times 0 -Exactly
    }

    Context 'With -BypassAlias' {
        It 'Returns winget.exe under the registered DesktopAppInstaller package install location' {
            $script:installLocation = 'C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_1.26.0.0_x64__8wekyb3d8bbwe'
            Mock Get-AppxPackage { [pscustomobject]@{ Version = '1.26.0.0'; InstallLocation = $script:installLocation } }
            Mock Test-Path { $true }

            Resolve-WingetExecutable -BypassAlias | Should -Be (Join-Path $script:installLocation 'winget.exe')

            Should -Invoke Get-AppxPackage -Times 1 -Exactly -ParameterFilter { $Name -eq 'Microsoft.DesktopAppInstaller' }
        }

        It 'Prefers the newest registered version when several are visible mid-upgrade' {
            Mock Get-AppxPackage {
                @(
                    [pscustomobject]@{ Version = '1.9.25200.0'; InstallLocation = 'C:\WindowsApps\DAI_old' }
                    [pscustomobject]@{ Version = '1.26.0.0'; InstallLocation = 'C:\WindowsApps\DAI_new' }
                )
            }
            Mock Test-Path { $true }

            Resolve-WingetExecutable -BypassAlias | Should -Be (Join-Path 'C:\WindowsApps\DAI_new' 'winget.exe')
        }

        It 'Falls back to the alias when the package has no winget.exe on disk' {
            Mock Get-AppxPackage { [pscustomobject]@{ Version = '1.26.0.0'; InstallLocation = 'C:\WindowsApps\DAI' } }
            Mock Test-Path { $false }

            Resolve-WingetExecutable -BypassAlias | Should -Be 'winget'
        }

        It 'Falls back to the alias when the package is not registered' {
            Mock Get-AppxPackage { $null }

            Resolve-WingetExecutable -BypassAlias | Should -Be 'winget'
        }

        It 'Falls back to the alias when Get-AppxPackage throws (e.g. no Appx compatibility session)' {
            Mock Get-AppxPackage { throw 'Operation is not supported on this platform.' }

            Resolve-WingetExecutable -BypassAlias | Should -Be 'winget'
        }
    }
}

Describe 'Wait-WingetLaunchable (issue #277)' {
    BeforeAll {
        # Start-Process is mocked to return a fake process object exposing the WaitForExit/Kill
        # members the function actually calls - same pattern tests/WingetCore.Tests.ps1 uses for
        # its own WaitForExit-based winget checks. Defined in BeforeAll (not the Describe body)
        # so it survives into Pester's separate run phase.
        function New-FakeWingetProcess {
            param ([bool]$Exited = $true, [scriptblock]$OnKill = { })
            $p = [pscustomobject]@{ ExitCode = 0 }
            # Local (non-$script:) variable + GetNewClosure() so each fake process instance
            # captures its own $Exited value, independent of any other instance in the same test.
            $exitedCopy = $Exited
            $p | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($ms) $exitedCopy }.GetNewClosure()
            $p | Add-Member -MemberType ScriptMethod -Name Kill -Value $OnKill
            $p
        }
    }

    BeforeEach {
        Mock Remove-Item { }
        # Healthy (single-version) by default so the issue #279 deadlock check inside the failure
        # path doesn't depend on real machine state or short-circuit tests that expect retries.
        # Tests for the deadlock behavior itself override this.
        Mock Get-AppxPackage { [pscustomobject]@{ Version = '1.26.510.0' } }
    }

    It 'Requires two consecutive successful probes before declaring winget launchable (default RequiredConsecutiveSuccesses)' {
        # issue #277 follow-up: a live PR run saw the very first probe succeed within ~0.5s of
        # Install-WingetAutoUpdate finishing, then a wholly separate process hit the full lock
        # ~17s later - Task Scheduler dispatching WAU's immediate run, and WAU's own startup,
        # are not instantaneous, so one success does not prove the danger window has passed.
        Mock Start-Process { New-FakeWingetProcess }
        Mock Start-Sleep { }

        Wait-WingetLaunchable -PollIntervalSeconds 1 | Should -Be $true

        Should -Invoke Start-Process -Times 2 -Exactly -ParameterFilter { $FilePath -eq 'winget' }
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 1 }
    }

    It 'Resets the consecutive-success streak on an intervening failure, so a flaky clear does not count' {
        # success, then failure, then two more successes - the pre-failure success must not count
        # toward the two-in-a-row requirement.
        $script:callIndex = 0
        Mock Start-Process {
            $script:callIndex++
            if ($script:callIndex -eq 2) {
                throw 'This command cannot be run due to the error: The file cannot be accessed by the system.'
            }
            New-FakeWingetProcess
        }
        Mock Start-Sleep { }
        Mock Resolve-WingetExecutable {
            if ($BypassAlias) { return 'C:\WindowsApps\DAI\winget.exe' }
            'winget'
        }

        Wait-WingetLaunchable -PollIntervalSeconds 1 | Should -Be $true

        # 1 (success) + 2 (fails, transient) + 3 (success, streak=1) + 4 (success, streak=2) = 4
        Should -Invoke Start-Process -Times 4 -Exactly
    }

    It 'Retries a transient launch failure, bypassing the alias, and succeeds once it clears' {
        $script:callIndex = 0
        Mock Start-Process {
            $script:callIndex++
            if ($script:callIndex -eq 1) {
                throw 'This command cannot be run due to the error: The file cannot be accessed by the system.'
            }
            New-FakeWingetProcess
        }
        Mock Start-Sleep { }
        Mock Resolve-WingetExecutable {
            if ($BypassAlias) { return 'C:\WindowsApps\DAI\winget.exe' }
            'winget'
        }

        Wait-WingetLaunchable -PollIntervalSeconds 1 | Should -Be $true

        # 1 (fails on the bare alias) + 2 successes (bypassed) to reach the required streak.
        Should -Invoke Start-Process -Times 3 -Exactly
        Should -Invoke Start-Process -Times 2 -Exactly -ParameterFilter { $FilePath -eq 'C:\WindowsApps\DAI\winget.exe' }
        Should -Invoke Start-Sleep -Times 2 -Exactly -ParameterFilter { $Seconds -eq 1 }
    }

    It 'Also retries the native-command-invocation StandardOutputEncoding symptom (issue #277)' {
        $script:callIndex = 0
        Mock Start-Process {
            $script:callIndex++
            if ($script:callIndex -eq 1) {
                throw 'StandardOutputEncoding is only supported when standard output is redirected.'
            }
            New-FakeWingetProcess
        }
        Mock Start-Sleep { }

        Wait-WingetLaunchable -PollIntervalSeconds 1 | Should -Be $true

        Should -Invoke Start-Process -Times 3 -Exactly
    }

    It 'Returns false immediately for an unrelated (non-transient) launch failure on the bare alias, without retrying' {
        Mock Start-Process { throw 'The system cannot find the file specified.' }
        Mock Start-Sleep { }

        Wait-WingetLaunchable | Should -Be $false

        Should -Invoke Start-Process -Times 1 -Exactly
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'Keeps retrying when a resolved bypass path itself vanishes mid-poll, instead of giving up (issue #277 follow-up)' {
        # Same exemption Install-WingetPackage already documents: once on a concrete bypass path
        # (not the bare alias), the in-flight DesktopAppInstaller upgrade can delete that exact
        # package version between resolving it and launching it - ERROR_FILE_NOT_FOUND, not a
        # file-lock error, and not one of Test-TransientWingetLaunchError's classes.
        $script:callIndex = 0
        Mock Start-Process {
            $script:callIndex++
            switch ($script:callIndex) {
                1 { throw 'This command cannot be run due to the error: The file cannot be accessed by the system.' }
                2 { throw 'The system cannot find the file specified.' }
                default { New-FakeWingetProcess }
            }
        }
        Mock Start-Sleep { }
        Mock Resolve-WingetExecutable {
            if ($BypassAlias) { return 'C:\WindowsApps\DAI\winget.exe' }
            'winget'
        }

        Wait-WingetLaunchable -PollIntervalSeconds 1 | Should -Be $true

        # 1 (fails, transient) + 2 (fails, file-not-found but exempted on a bypass path) + 2
        # successes to reach the required streak = 4 total.
        Should -Invoke Start-Process -Times 4 -Exactly
        Should -Invoke Start-Sleep -Times 3 -Exactly -ParameterFilter { $Seconds -eq 1 }
    }

    It 'Kills and retries a probe that launches but never returns within ProbeTimeoutSeconds' {
        $script:killCalled = $false
        $script:callIndex = 0
        Mock Start-Process {
            $script:callIndex++
            if ($script:callIndex -eq 1) {
                return New-FakeWingetProcess -Exited $false -OnKill { Set-Variable -Name killCalled -Value $true -Scope script }
            }
            New-FakeWingetProcess
        }
        Mock Start-Sleep { }

        Wait-WingetLaunchable -PollIntervalSeconds 1 -ProbeTimeoutSeconds 1 | Should -Be $true

        $script:killCalled | Should -Be $true
        Should -Invoke Start-Process -Times 3 -Exactly
    }

    It 'Gives up once the timeout has elapsed, without sleeping further' {
        Mock Start-Process {
            throw 'This command cannot be run due to the error: The file cannot be accessed by the system.'
        }
        Mock Start-Sleep { }

        # TimeoutSeconds 0 means the deadline is already "now" by the time the first attempt
        # returns, so this proves the loop honors the deadline instead of always trying at least
        # once more - without a test that actually has to wait on real wall-clock time.
        Wait-WingetLaunchable -TimeoutSeconds 0 -PollIntervalSeconds 1 | Should -Be $false

        Should -Invoke Start-Process -Times 1 -Exactly
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'Cleans up its per-attempt probe temp files' {
        Mock Start-Process { New-FakeWingetProcess }
        Mock Start-Sleep { }

        Wait-WingetLaunchable -PollIntervalSeconds 1 | Out-Null

        # Two probe attempts (the required streak) x two files (stdout + stderr) each.
        Should -Invoke Remove-Item -Times 4 -Exactly
    }

    It 'Gives up immediately on a structural DesktopAppInstaller version conflict, instead of polling the rest of the budget (issue #279)' {
        Mock Start-Process {
            throw 'This command cannot be run due to the error: The file cannot be accessed by the system.'
        }
        Mock Start-Sleep { }
        Mock Get-AppxPackage {
            @(
                [pscustomobject]@{ Version = '1.26.510.0' }
                [pscustomobject]@{ Version = '1.29.290.0' }
            )
        }
        $script:warnings = @()
        Mock Write-WarningMessage { $script:warnings += $Message }

        # A generous timeout/poll-interval that would otherwise keep this polling for a long time -
        # proving the deadlock check short-circuits it rather than just happening to hit a deadline.
        Wait-WingetLaunchable -TimeoutSeconds 360 -PollIntervalSeconds 20 | Should -Be $false

        Should -Invoke Start-Process -Times 1 -Exactly
        Should -Invoke Start-Sleep -Times 0 -Exactly
        ($script:warnings -join "`n") | Should -Match 'deadlocked'
        ($script:warnings -join "`n") | Should -Match '1\.26\.510\.0'
        ($script:warnings -join "`n") | Should -Match '1\.29\.290\.0'
    }

    It 'Does not treat a single registered version as a deadlock' {
        $script:callIndex = 0
        Mock Start-Process {
            $script:callIndex++
            if ($script:callIndex -eq 1) {
                throw 'This command cannot be run due to the error: The file cannot be accessed by the system.'
            }
            New-FakeWingetProcess
        }
        Mock Start-Sleep { }
        Mock Get-AppxPackage { [pscustomobject]@{ Version = '1.26.510.0' } }

        # Reaches the required streak normally instead of bailing out on the one failed attempt.
        Wait-WingetLaunchable -PollIntervalSeconds 1 | Should -Be $true

        Should -Invoke Start-Process -Times 3 -Exactly
    }
}
