# WingetBootstrap.Tests.ps1
# Tests for WingetAppSetup/Private/WingetBootstrap.ps1: the winget source probe
# (Invoke-WingetSourceProbe) and the shared source health check (Test-WingetSourceHealth).
# Split from the old single-file suite Test-WingetAppInstall.Tests.ps1 (issue #192).

# Load the module's functions once for this file. TestHelpers.ps1 resolves the repo paths
# and dot-sources WingetAppSetup/Private + Public (the single source of truth; the
# distributable winget-app-install.ps1 is generated from it by build/Build-WingetInstallScript.ps1).
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'Test-WingetSourceHealth (shared source probe, issue #177)' {
    BeforeEach {
        Mock Write-Host { }
        Mock Write-Success { }
        Mock Write-WarningMessage { }
    }

    It 'Reports healthy when the source is listed and a search succeeds' {
        Mock winget {
            if ($args[0] -eq 'source' -and $args[1] -eq 'list') {
                $global:LASTEXITCODE = 0
                return 'winget      https://cdn.winget.microsoft.com/cache'
            }
            elseif ($args[0] -eq 'search' -and $args[1] -eq '7zip') {
                $global:LASTEXITCODE = 0
                return '7zip.7zip    7.30'
            }
        }

        $health = Test-WingetSourceHealth

        $health.Listed | Should -Be $true
        $health.Functional | Should -Be $true
        $health.Healthy | Should -Be $true
        Should -Invoke Write-Success -Times 1 -ParameterFilter { $Message -match 'accessible and functional' }
    }

    It 'Reports not listed (and skips the search) when the winget source is missing' {
        Mock winget {
            if ($args[0] -eq 'source' -and $args[1] -eq 'list') {
                $global:LASTEXITCODE = 0
                return 'msstore      https://storeedgefd.dsx.mp.microsoft.com/v9.0'
            }
            elseif ($args[0] -eq 'search') {
                throw 'search should not run when the source is not listed'
            }
        }

        $health = Test-WingetSourceHealth

        $health.Listed | Should -Be $false
        $health.Functional | Should -Be $false
        $health.Healthy | Should -Be $false
    }

    It 'Reports not functional when the search probe exits nonzero' {
        Mock winget {
            if ($args[0] -eq 'source' -and $args[1] -eq 'list') {
                $global:LASTEXITCODE = 0
                return 'winget      https://cdn.winget.microsoft.com/cache'
            }
            elseif ($args[0] -eq 'search' -and $args[1] -eq '7zip') {
                $global:LASTEXITCODE = 1
                return '0x8a15000f Data required by the source is missing'
            }
        }

        $health = Test-WingetSourceHealth

        $health.Listed | Should -Be $true
        $health.Functional | Should -Be $false
        $health.Healthy | Should -Be $false
        Should -Invoke Write-WarningMessage -Times 1 -ParameterFilter { $Message -match 'corrupted or missing data' }
    }

    It 'Regression pin: the pre-existing nonzero-exit-code check alone catches the 0x8a15000f exit code, even with output text that does not match the prose fallback' {
        Mock winget {
            if ($args[0] -eq 'source' -and $args[1] -eq 'list') {
                $global:LASTEXITCODE = 0
                return 'winget      https://cdn.winget.microsoft.com/cache'
            }
            elseif ($args[0] -eq 'search' -and $args[1] -eq '7zip') {
                # -1978335217 is 0x8A15000F as a signed Int32. Output text deliberately avoids
                # 'failed when opening'/'data required' to prove this is caught by the generic
                # `-ne 0` branch alone, not by any dedicated numeric branch (there isn't one —
                # this HRESULT is just one of many nonzero exit codes that clause already covers).
                $global:LASTEXITCODE = -1978335217
                return 'No package found matching input criteria.'
            }
        }

        $health = Test-WingetSourceHealth

        $health.Listed | Should -Be $true
        $health.Functional | Should -Be $false
        $health.Healthy | Should -Be $false
        Should -Invoke Write-WarningMessage -Times 1 -ParameterFilter { $Message -match 'corrupted or missing data' }
    }

    It 'Reports not functional when the search exits 0 but the output text matches the corruption phrases (prose fallback)' {
        Mock winget {
            if ($args[0] -eq 'source' -and $args[1] -eq 'list') {
                $global:LASTEXITCODE = 0
                return 'winget      https://cdn.winget.microsoft.com/cache'
            }
            elseif ($args[0] -eq 'search' -and $args[1] -eq '7zip') {
                # Isolates the scenario the prose fallback exists for: winget reportedly returns
                # exit code 0 despite corrupted output in some observed cases (issues
                # #150/#172/#174/#175/#177).
                $global:LASTEXITCODE = 0
                return 'Failed when opening source(s). 0x8a15000f Data required by the source is missing.'
            }
        }

        $health = Test-WingetSourceHealth

        $health.Listed | Should -Be $true
        $health.Functional | Should -Be $false
        $health.Healthy | Should -Be $false
        Should -Invoke Write-WarningMessage -Times 1 -ParameterFilter { $Message -match 'corrupted or missing data' }
    }

    It 'Catches exit-0 corruption via the locale-independent 0x8a150 hex token when the English phrases are absent (integration-review regression)' {
        Mock winget {
            if ($args[0] -eq 'source' -and $args[1] -eq 'list') {
                $global:LASTEXITCODE = 0
                return 'winget      https://cdn.winget.microsoft.com/cache'
            }
            elseif ($args[0] -eq 'search' -and $args[1] -eq '7zip') {
                # A non-English locale (or future wording change) loses the English phrases, but
                # winget prints the hex HRESULT regardless of display language. The '0x8a150'
                # regex token is the only signal for this case — it was silently dropped once
                # during the issue-#241 rework and restored by the integration-branch review.
                $global:LASTEXITCODE = 0
                return 'Quellfehler: 0x8A15000F - Von der Quelle benoetigte Daten fehlen.'
            }
        }

        $health = Test-WingetSourceHealth

        $health.Listed | Should -Be $true
        $health.Functional | Should -Be $false
        $health.Healthy | Should -Be $false
    }

    It 'Suppresses per-step messages when -Quiet is passed' {
        Mock winget {
            if ($args[0] -eq 'source' -and $args[1] -eq 'list') {
                $global:LASTEXITCODE = 0
                return 'winget      https://cdn.winget.microsoft.com/cache'
            }
            elseif ($args[0] -eq 'search' -and $args[1] -eq '7zip') {
                $global:LASTEXITCODE = 0
                return '7zip.7zip    7.30'
            }
        }

        $health = Test-WingetSourceHealth -Quiet

        $health.Healthy | Should -Be $true
        Should -Invoke Write-Success -Times 0 -Exactly
    }
}

Describe 'Invoke-WingetSourceProbe' {
    BeforeEach {
        Mock Write-Host { }
        Mock Write-WarningMessage { }
        Mock Remove-Item { }
    }

    It 'Runs winget source update with agreement acceptance and reports success' {
        Mock Start-Process {
            $p = [pscustomobject]@{ ExitCode = 0 }
            $p | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($ms) $true }
            $p | Add-Member -MemberType ScriptMethod -Name Kill -Value { }
            $p
        }

        $result = Invoke-WingetSourceProbe

        $result.Succeeded | Should -Be $true
        $result.ExitCode | Should -Be 0
        $result.TimedOut | Should -Be $false
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            ($ArgumentList -contains 'source') -and
            ($ArgumentList -contains 'update') -and
            ($ArgumentList -contains '--name') -and
            ($ArgumentList -contains 'winget') -and
            ($ArgumentList -contains '--disable-interactivity') -and
            # --accept-source-agreements is INVALID for `winget source update` (0x8A150002); must be absent.
            ($ArgumentList -notcontains '--accept-source-agreements')
        }
    }

    It 'Passes through a failure exit code' {
        Mock Start-Process {
            # -2147009255 = 0x80073D19 ERROR_DEPLOYMENT_BLOCKED_BY_USER_LOG_OFF
            $p = [pscustomobject]@{ ExitCode = -2147009255 }
            $p | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($ms) $true }
            $p | Add-Member -MemberType ScriptMethod -Name Kill -Value { }
            $p
        }

        $result = Invoke-WingetSourceProbe

        $result.Succeeded | Should -Be $false
        $result.ExitCode | Should -Be -2147009255
        $result.TimedOut | Should -Be $false
    }

    It 'Kills the process and reports a timeout when winget hangs' {
        $script:probeKillCalled = $false
        Mock Start-Process {
            $p = [pscustomobject]@{ ExitCode = 0 }
            $p | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($ms) $false }
            $p | Add-Member -MemberType ScriptMethod -Name Kill -Value { Set-Variable -Name probeKillCalled -Value $true -Scope script }
            $p
        }

        $result = Invoke-WingetSourceProbe -TimeoutSeconds 1

        $result.Succeeded | Should -Be $false
        $result.TimedOut | Should -Be $true
        $result.ExitCode | Should -Be $null
        $script:probeKillCalled | Should -Be $true
    }

    It 'Reports failure without throwing when winget cannot start' {
        Mock Start-Process { throw 'winget not found' }

        $result = Invoke-WingetSourceProbe

        $result.Succeeded | Should -Be $false
        $result.ExitCode | Should -Be $null
        $result.TimedOut | Should -Be $false
    }

    It 'Uses unique temp file names on every run (issue #177)' {
        $script:probeRedirectPaths = @()
        Mock Start-Process {
            $script:probeRedirectPaths += @($RedirectStandardOutput, $RedirectStandardError)
            $p = [pscustomobject]@{ ExitCode = 0 }
            $p | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($ms) $true }
            $p | Add-Member -MemberType ScriptMethod -Name Kill -Value { }
            $p
        }

        [void](Invoke-WingetSourceProbe)
        [void](Invoke-WingetSourceProbe)

        $script:probeRedirectPaths.Count | Should -Be 4
        # stdout and stderr differ within one run, and neither repeats across runs.
        ($script:probeRedirectPaths | Select-Object -Unique).Count | Should -Be 4
        # Concurrent runs must not collide on the old fixed names.
        $script:probeRedirectPaths[0] | Should -Not -Be $script:probeRedirectPaths[2]
    }
}

Describe 'Test-AppxDowngradeRejection (0x80073D06 classifier, issue #265)' {
    It 'Matches the hex HRESULT regardless of case' {
        Test-AppxDowngradeRejection -Message 'Deployment failed with HRESULT: 0x80073D06, ...' | Should -Be $true
        Test-AppxDowngradeRejection -Message 'deployment failed with hresult: 0x80073d06' | Should -Be $true
    }

    It 'Matches the English phrasing when the hex code is absent' {
        Test-AppxDowngradeRejection -Message 'The package could not be installed because a higher version of this package is already installed.' |
            Should -Be $true
    }

    It 'Matches the real Repair-WinGetPackageManager failure text' {
        $message = 'Deployment failed with HRESULT: 0x80073D06, The package could not be installed because a higher version of this package is already installed.' + [Environment]::NewLine +
        'Windows cannot install package Microsoft.WindowsAppRuntime.1.8_8000.616.304.0_x64__8wekyb3d8bbwe because it has version 8000.616.304.0. A higher version 8000.921.1539.0 of this package is already installed.'

        Test-AppxDowngradeRejection -Message $message | Should -Be $true
    }

    It 'Does not match unrelated deployment failures' {
        # 0x80073D19 is the blocked-logoff error this module already handles separately; it must
        # keep escalating through the ladder rather than being short-circuited as non-retryable.
        Test-AppxDowngradeRejection -Message 'Deployment failed with HRESULT: 0x80073D19' | Should -Be $false
        Test-AppxDowngradeRejection -Message 'Network error' | Should -Be $false
    }

    It 'Treats empty and null text as not a downgrade rejection' {
        Test-AppxDowngradeRejection -Message '' | Should -Be $false
        Test-AppxDowngradeRejection -Message $null | Should -Be $false
    }
}

Describe 'Register-WingetAppInstallerForUser (issue #265)' {
    BeforeEach {
        Mock Write-Host { }
        Mock Write-Info { }
        Mock Write-Success { }
        Mock Write-WarningMessage { }
    }

    It 'Registers the staged package by family name and reports success' {
        Mock Get-AppxPackage { [pscustomobject]@{ InstallLocation = 'C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_1.26.0.0_x64__8wekyb3d8bbwe' } }
        Mock Add-AppxPackage { }

        Register-WingetAppInstallerForUser | Should -Be $true

        Should -Invoke Add-AppxPackage -Times 1 -Exactly -ParameterFilter {
            $RegisterByFamilyName -and $MainPackage -eq 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe'
        }
    }

    It 'Enumerates packages staged for other accounts, not just this one' {
        # -AllUsers is what surfaces a package staged on the machine but never registered for the
        # elevating account - the whole case this helper exists for.
        Mock Get-AppxPackage { [pscustomobject]@{ InstallLocation = 'C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_1.26.0.0_x64__8wekyb3d8bbwe' } }
        Mock Add-AppxPackage { }

        [void](Register-WingetAppInstallerForUser)

        Should -Invoke Get-AppxPackage -Times 1 -Exactly -ParameterFilter { $AllUsers }
    }

    It 'Falls back to registering from the package manifest when the family-name form fails' {
        $installLocation = 'C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_1.26.0.0_x64__8wekyb3d8bbwe'
        Mock Get-AppxPackage { [pscustomobject]@{ InstallLocation = $installLocation } }
        Mock Test-Path { $true }
        Mock Add-AppxPackage { throw 'family name registration failed' } -ParameterFilter { $RegisterByFamilyName }
        Mock Add-AppxPackage { } -ParameterFilter { $Register }

        Register-WingetAppInstallerForUser | Should -Be $true

        Should -Invoke Add-AppxPackage -Times 1 -Exactly -ParameterFilter {
            $Register -and $Path -eq (Join-Path $installLocation 'AppXManifest.xml')
        }
    }

    It 'Returns false without registering anything when App Installer is not staged' {
        Mock Get-AppxPackage { @() }
        Mock Add-AppxPackage { throw 'nothing to register' }

        Register-WingetAppInstallerForUser | Should -Be $false

        Should -Invoke Add-AppxPackage -Times 0 -Exactly
    }

    It 'Returns false when every registration form fails' {
        Mock Get-AppxPackage { [pscustomobject]@{ InstallLocation = 'C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_1.26.0.0_x64__8wekyb3d8bbwe' } }
        Mock Test-Path { $true }
        Mock Add-AppxPackage { throw 'registration failed' }

        Register-WingetAppInstallerForUser | Should -Be $false
    }

    It 'Falls back to the current-user view when the all-users enumeration is refused' {
        Mock Get-AppxPackage { throw 'access denied' } -ParameterFilter { $AllUsers }
        Mock Get-AppxPackage { [pscustomobject]@{ InstallLocation = 'C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_1.26.0.0_x64__8wekyb3d8bbwe' } } -ParameterFilter { -not $AllUsers }
        Mock Add-AppxPackage { }

        Register-WingetAppInstallerForUser | Should -Be $true
    }

    It 'Returns false when the package cannot be enumerated at all' {
        Mock Get-AppxPackage { throw 'Appx provider unavailable' }
        Mock Add-AppxPackage { throw 'nothing to register' }

        Register-WingetAppInstallerForUser | Should -Be $false

        Should -Invoke Add-AppxPackage -Times 0 -Exactly
    }
}

Describe 'Invoke-WingetPackageManagerRepair (issue #265)' {
    BeforeAll {
        # Stub so the cmdlet can be mocked on machines without the Microsoft.WinGet.Client module.
        function Repair-WinGetPackageManager { param([switch]$Latest, [switch]$Force) }
    }

    BeforeEach {
        Mock Write-Host { }
        Mock Write-WarningMessage { }
        # Safety net (#181): never let the real cmdlet run during unit tests.
        Mock Repair-WinGetPackageManager { }
        Mock Get-Command { [pscustomobject]@{ Name = 'Repair-WinGetPackageManager' } } -ParameterFilter { $Name -eq 'Repair-WinGetPackageManager' }
    }

    It 'Reports the cmdlet as unavailable without attempting a repair' {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'Repair-WinGetPackageManager' }

        $result = Invoke-WingetPackageManagerRepair

        $result.Available | Should -Be $false
        $result.Succeeded | Should -Be $false
        Should -Invoke Repair-WinGetPackageManager -Times 0 -Exactly
    }

    It 'Tries the unforced repair first and stops there when it succeeds' {
        $result = Invoke-WingetPackageManagerRepair

        $result.Succeeded | Should -Be $true
        $result.DowngradeRejected | Should -Be $false
        Should -Invoke Repair-WinGetPackageManager -Times 1 -Exactly -ParameterFilter { $Latest -and -not $Force }
    }

    It 'Escalates to -Force when the unforced repair fails for an unrelated reason' {
        $script:repairAttempts = 0
        Mock Repair-WinGetPackageManager {
            $script:repairAttempts++
            if ($script:repairAttempts -eq 1) { throw 'something else went wrong' }
        }

        $result = Invoke-WingetPackageManagerRepair

        $result.Succeeded | Should -Be $true
        Should -Invoke Repair-WinGetPackageManager -Times 2 -Exactly
        Should -Invoke Repair-WinGetPackageManager -Times 1 -Exactly -ParameterFilter { $Force }
    }

    It 'Does not escalate to -Force on a 0x80073D06 downgrade rejection' {
        Mock Repair-WinGetPackageManager {
            throw 'Deployment failed with HRESULT: 0x80073D06, The package could not be installed because a higher version of this package is already installed.'
        }

        $result = Invoke-WingetPackageManagerRepair

        $result.Available | Should -Be $true
        $result.Succeeded | Should -Be $false
        $result.DowngradeRejected | Should -Be $true
        $result.Message | Should -Match '0x80073D06'
        Should -Invoke Repair-WinGetPackageManager -Times 1 -Exactly
        Should -Invoke Write-WarningMessage -Times 1 -ParameterFilter { $Message -match 'newer framework dependency' }
    }

    It 'Reports a plain failure when both the unforced and forced repairs fail' {
        Mock Repair-WinGetPackageManager { throw 'network error' }

        $result = Invoke-WingetPackageManagerRepair

        $result.Available | Should -Be $true
        $result.Succeeded | Should -Be $false
        $result.DowngradeRejected | Should -Be $false
        $result.Message | Should -Match 'network error'
        Should -Invoke Repair-WinGetPackageManager -Times 2 -Exactly
    }
}
