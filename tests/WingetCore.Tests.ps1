# WingetCore.Tests.ps1
# Tests for WingetAppSetup/Public/WingetCore.ps1: winget bootstrap, source health/repair,
# package install (0x80073d19 backoff, scope fallback), installed-checks, per-user source
# init, and the PowerShell always-latest / MSIX provisioning strategies.
# Split from the old single-file suite Test-WingetAppInstall.Tests.ps1 (issue #192).

# Load the module's functions once for this file. TestHelpers.ps1 resolves the repo paths
# and dot-sources WingetAppSetup/Private + Public (the single source of truth; the
# distributable winget-app-install.ps1 is generated from it by build/Build-WingetInstallScript.ps1).
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'Test-AndInstallWingetModule' {
    BeforeAll {
        Mock Write-Host { }
        Mock Write-Warning { }

    }

    Context 'When module is already available' {
        It 'Should return true without installing' {
            Mock Get-Module { @{ Name = 'Microsoft.WinGet.Client' } } -ParameterFilter { $Name -eq 'Microsoft.WinGet.Client' -and $ListAvailable }
            Mock Get-PackageProvider { }
            Mock Install-PackageProvider { }
            Mock Install-Module { }

            $result = Test-AndInstallWingetModule
            $result | Should -Be $true
            Should -Invoke Install-Module -Times 0
        }
    }

    Context 'When module is missing and installation succeeds' {
        It 'Should install dependencies and return true' {
            $script:moduleInstalled = $false

            Mock Get-Module {
                if ($script:moduleInstalled) {
                    return @{ Name = 'Microsoft.WinGet.Client' }
                }
                return $null
            } -ParameterFilter { $Name -eq 'Microsoft.WinGet.Client' -and $ListAvailable }

            Mock Get-PackageProvider { $null } -ParameterFilter { $Name -eq 'NuGet' }
            Mock Install-PackageProvider { } -ParameterFilter { $Name -eq 'NuGet' }
            Mock Install-Module { $script:moduleInstalled = $true }

            $result = Test-AndInstallWingetModule
            $result | Should -Be $true
            Should -Invoke Install-PackageProvider -Times 1 -ParameterFilter { $Name -eq 'NuGet' }
            Should -Invoke Install-Module -Times 1
        }
    }

    Context 'When module installation fails' {
        It 'Should return false and emit warning' {
            Mock Get-Module { $null } -ParameterFilter { $Name -eq 'Microsoft.WinGet.Client' -and $ListAvailable }
            Mock Get-PackageProvider { $null } -ParameterFilter { $Name -eq 'NuGet' }
            Mock Install-PackageProvider { }
            Mock Install-Module { throw 'Failure installing module' }

            $result = Test-AndInstallWingetModule
            $result | Should -Be $false
            Should -Invoke Install-Module -Times 1
        }
    }

    # P2-16: a dry run used to install the NuGet provider and this module for all users.
    Context 'Dry run (-WhatIf)' {
        BeforeEach {
            Mock Get-PackageProvider { $null }
            Mock Install-PackageProvider { }
            Mock Install-Module { }
            $script:infoMessages = @()
            Mock Write-Info { $script:infoMessages += $Message }
        }

        It 'Reports what a real run would install and installs nothing when the module is missing' {
            Mock Get-Module { $null } -ParameterFilter { $Name -eq 'Microsoft.WinGet.Client' -and $ListAvailable }

            Test-AndInstallWingetModule -WhatIf | Should -Be $false

            Should -Invoke Get-PackageProvider -Times 0 -Exactly
            Should -Invoke Install-PackageProvider -Times 0 -Exactly
            Should -Invoke Install-Module -Times 0 -Exactly
            ($script:infoMessages -join "`n") | Should -Match '\[DRY-RUN\] Microsoft\.WinGet\.Client module not found\. A real run would install it for all users'
        }

        It 'Still reports an installed module as available' {
            Mock Get-Module { @{ Name = 'Microsoft.WinGet.Client' } } -ParameterFilter { $Name -eq 'Microsoft.WinGet.Client' -and $ListAvailable }

            Test-AndInstallWingetModule -WhatIf | Should -Be $true

            Should -Invoke Install-Module -Times 0 -Exactly
            $script:infoMessages.Count | Should -Be 0
        }
    }
}

Describe 'Test-AndInstallWinget' {
    BeforeAll {
        Mock Write-Host { }
    }

    BeforeEach {
        # Safety net (#181): never let the real Repair-WinGetPackageManager run during unit
        # tests — it downloads and re-registers the App Installer. The cmdlet exists on dev
        # machines and CI (Microsoft.WinGet.Client is installed), so Pester can mock it
        # unconditionally.
        Mock Repair-WinGetPackageManager { }
        # Default: the repair cmdlet appears absent, so tests exercise the plain
        # aka.ms/getwinget fallback unless a test overrides this lookup.
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'Repair-WinGetPackageManager' }
        # Default: nothing to register for this account, so the ladder's first rung (issue #265)
        # is a no-op and the pre-existing repair/download behavior below is what gets exercised.
        # Mocked as a seam rather than mocking Get-AppxPackage/Add-AppxPackage directly, so an
        # accidental miss can never reach the real AppX deployment cmdlets.
        Mock Register-WingetAppInstallerForUser { $false }
        # Whether winget can be started (review finding P3-9: a real `winget --version`, not
        # Get-Command). Tests flip $script:wingetLaunchable from the rung that fixes winget.
        $script:wingetLaunchable = $false
        Mock Test-WingetLaunchable {
            if ($script:wingetLaunchable) {
                return [pscustomobject]@{ Launchable = $true; Version = 'v1.12.350'; Reason = $null; Attempts = 1 }
            }
            [pscustomobject]@{ Launchable = $false; Version = $null; Reason = "winget could not be started: 'winget' was not found on PATH"; Attempts = 1 }
        }
    }

    Context 'When winget is available' {
        It 'Should return true and not attempt installation' {
            $script:wingetLaunchable = $true
            Mock Invoke-WebRequest { }
            $result = Test-AndInstallWinget
            $result | Should -Be $true
            Should -Invoke Test-WingetLaunchable -Times 1 -Exactly
            Should -Invoke Register-WingetAppInstallerForUser -Times 0 -Exactly
            Should -Invoke Invoke-WebRequest -Times 0
        }
    }

    Context 'When winget is not available and installation succeeds' {
        It 'Should attempt installation, re-verify winget, and return true' {
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'Repair-WinGetPackageManager' }
            Mock Invoke-WebRequest { }
            Mock Add-AppxPackage { $script:wingetLaunchable = $true }
            Mock Remove-Item { }
            $result = Test-AndInstallWinget
            $result | Should -Be $true
            Should -Invoke Invoke-WebRequest -Times 1
            Should -Invoke Add-AppxPackage -Times 1
            Should -Invoke Remove-Item -Times 1
            # The fallback must verify winget after Add-AppxPackage (issue #177): initial check + re-check.
            Should -Invoke Test-WingetLaunchable -Times 2 -Exactly
        }
    }

    Context 'When App Installer registers but winget is still unavailable (issue #177)' {
        It 'Should return false and direct the user to install winget manually' {
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'Repair-WinGetPackageManager' }
            Mock Invoke-WebRequest { }
            Mock Add-AppxPackage { }
            Mock Remove-Item { }
            Mock Write-ErrorMessage { }

            $result = Test-AndInstallWinget
            $result | Should -Be $false
            Should -Invoke Add-AppxPackage -Times 1
            Should -Invoke Write-ErrorMessage -Times 1 -ParameterFilter { $Message -match 'install winget manually' }
        }
    }

    Context 'When winget is not available and installation fails' {
        It 'Should attempt installation, catch error, and return false' {
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'Repair-WinGetPackageManager' }
            Mock Invoke-WebRequest { throw 'Network error' }
            $result = Test-AndInstallWinget
            $result | Should -Be $false
            Should -Invoke Invoke-WebRequest -Times 1
        }
    }

    Context 'When Repair-WinGetPackageManager is available and bootstraps winget' {
        It 'Should return true without downloading the App Installer' {
            Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'Repair-WinGetPackageManager' }
            Mock Repair-WinGetPackageManager { $script:wingetLaunchable = $true }
            Mock Invoke-WebRequest { }
            Mock Add-AppxPackage { }

            $result = Test-AndInstallWinget
            $result | Should -Be $true
            Should -Invoke Repair-WinGetPackageManager -Times 1 -Exactly
            Should -Invoke Invoke-WebRequest -Times 0
            Should -Invoke Add-AppxPackage -Times 0
        }
    }

    Context 'When Repair-WinGetPackageManager is available but throws' {
        It 'Should fall back to the App Installer download and return true once winget resolves' {
            # winget is absent until the App Installer fallback registers it; the fallback's
            # post-install re-check (issue #177) must then find it and return $true.
            Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'Repair-WinGetPackageManager' }
            Mock Repair-WinGetPackageManager { throw 'Repair failed' }
            Mock Invoke-WebRequest { }
            Mock Add-AppxPackage { $script:wingetLaunchable = $true }
            Mock Remove-Item { }

            $result = Test-AndInstallWinget
            $result | Should -Be $true
            # Unforced then forced (issue #265): a non-downgrade failure still escalates to -Force,
            # which remains the documented remedy for a broken App Installer registration.
            Should -Invoke Repair-WinGetPackageManager -Times 2 -Exactly
            Should -Invoke Repair-WinGetPackageManager -Times 1 -Exactly -ParameterFilter { -not $Force }
            Should -Invoke Repair-WinGetPackageManager -Times 1 -Exactly -ParameterFilter { $Force }
            Should -Invoke Invoke-WebRequest -Times 1
            Should -Invoke Add-AppxPackage -Times 1
        }
    }

    Context 'When App Installer is already staged on the machine (issue #265)' {
        It 'Registers it for this account and returns true without repairing or downloading' {
            Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'Repair-WinGetPackageManager' }
            Mock Register-WingetAppInstallerForUser { $script:wingetLaunchable = $true; return $true }
            Mock Invoke-WebRequest { }
            Mock Add-AppxPackage { }

            $result = Test-AndInstallWinget

            $result | Should -Be $true
            Should -Invoke Register-WingetAppInstallerForUser -Times 1 -Exactly
            Should -Invoke Repair-WinGetPackageManager -Times 0 -Exactly
            Should -Invoke Invoke-WebRequest -Times 0
            Should -Invoke Add-AppxPackage -Times 0
        }

        It 'Falls through to the repair cmdlet when registration does not make winget start' {
            # Registration can report success without winget being able to start, so winget is
            # started to check rather than trusting the registration result.
            Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'Repair-WinGetPackageManager' }
            Mock Register-WingetAppInstallerForUser { $true }
            Mock Repair-WinGetPackageManager { $script:wingetLaunchable = $true }
            Mock Invoke-WebRequest { }
            Mock Add-AppxPackage { }

            $result = Test-AndInstallWinget

            $result | Should -Be $true
            Should -Invoke Register-WingetAppInstallerForUser -Times 1 -Exactly
            Should -Invoke Repair-WinGetPackageManager -Times 1 -Exactly
            Should -Invoke Invoke-WebRequest -Times 0
        }
    }

    Context 'When the repair cmdlet is blocked by a dependency downgrade (issue #265)' {
        It 'Does not retry with -Force and falls through to the App Installer download' {
            Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'Repair-WinGetPackageManager' }
            Mock Repair-WinGetPackageManager {
                throw 'Deployment failed with HRESULT: 0x80073D06, The package could not be installed because a higher version of this package is already installed.'
            }
            Mock Invoke-WebRequest { }
            Mock Add-AppxPackage { $script:wingetLaunchable = $true }
            Mock Remove-Item { }

            $result = Test-AndInstallWinget

            $result | Should -Be $true
            # One attempt only: -Force cannot fix a rejection caused by a NEWER dependency already
            # being present, and retrying would burn a second multi-hundred-megabyte download.
            Should -Invoke Repair-WinGetPackageManager -Times 1 -Exactly
            Should -Invoke Add-AppxPackage -Times 1
        }
    }

    # P2-16: a dry run used to register or repair App Installer, or download and install it.
    Context 'Dry run (-WhatIf)' {
        BeforeEach {
            Mock Invoke-WingetPackageManagerRepair { @{ Available = $true; Succeeded = $true; DowngradeRejected = $false; MissingFrameworkDependency = $false; Message = '' } }
            Mock Invoke-WebRequest { }
            Mock Add-AppxPackage { }
            Mock Remove-Item { }
            $script:infoMessages = @()
            Mock Write-Info { $script:infoMessages += $Message }
        }

        It 'Reports the bootstrap a real run would attempt and runs none of it when winget is missing' {
            # Every rung is available, so only the -WhatIf short-circuit keeps them from running.
            Mock Get-Command { $true } -ParameterFilter { $Name -eq 'Repair-WinGetPackageManager' }
            Mock Register-WingetAppInstallerForUser { $true }

            Test-AndInstallWinget -WhatIf | Should -Be $false

            Should -Invoke Register-WingetAppInstallerForUser -Times 0 -Exactly
            Should -Invoke Invoke-WingetPackageManagerRepair -Times 0 -Exactly
            Should -Invoke Repair-WinGetPackageManager -Times 0 -Exactly
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
            Should -Invoke Add-AppxPackage -Times 0 -Exactly
            ($script:infoMessages -join "`n") | Should -Match '\[DRY-RUN\] Winget is not available for this account \(winget could not be started: .*\)\. A real run would bootstrap it'
        }

        It 'Still reports winget as available when it can be started' {
            $script:wingetLaunchable = $true

            Test-AndInstallWinget -WhatIf | Should -Be $true

            Should -Invoke Register-WingetAppInstallerForUser -Times 0 -Exactly
            $script:infoMessages.Count | Should -Be 0
        }
    }
}

# Review finding P3-9: Test-AndInstallWinget's checks were `Get-Command winget`, which only proves the
# alias is on PATH. Run 35406706712 printed 'Winget bootstrapped successfully' after both repair
# attempts failed, then every winget call failed with 'No applicable app licenses found'. These run
# the real Test-WingetLaunchable against a mocked Invoke-WingetProcess.
Describe 'Test-AndInstallWinget with winget on PATH but unable to run (review finding P3-9)' {
    BeforeEach {
        Mock Write-Host { }
        Mock Repair-WinGetPackageManager { }
        Mock Register-WingetAppInstallerForUser { $false }
        Mock Write-Success { }
        $script:warnings = @()
        Mock Write-WarningMessage { $script:warnings += $Message }
        Mock Write-ErrorMessage { }
        Mock Write-Info { }
        Mock Start-Sleep { }
        Mock Invoke-WebRequest { throw 'Network error' }
        # The alias is on PATH (Get-Command finds it) but winget cannot run.
        Mock Get-Command { [pscustomobject]@{ Name = 'winget.exe'; Source = 'C:\Users\admin\AppData\Local\Microsoft\WindowsApps\winget.exe' } } -ParameterFilter { $Name -eq 'winget' }
        Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'Repair-WinGetPackageManager' }
        Mock Invoke-WingetProcess { New-TestProcessResult -ExitCode -1978335230 -Output @('No applicable app licenses found.') } -ParameterFilter { $ArgumentList[0] -eq '--version' }
        Mock Invoke-WingetPackageManagerRepair { @{ Available = $true; Succeeded = $false; DowngradeRejected = $false; MissingFrameworkDependency = $false; Message = 'Repair-WinGetPackageManager failed' } }
    }

    It 'Does not report success after the repair attempts failed, and says that winget cannot run' {
        $result = Test-AndInstallWinget

        $result | Should -Be $false
        Should -Invoke Write-Success -Times 0 -Exactly
        Should -Invoke Invoke-WingetPackageManagerRepair -Times 1 -Exactly
        ($script:warnings -join "`n") | Should -Match "Winget is present but cannot run after the repair attempt: 'winget --version' exited with 0x8A150002"
    }

    It 'Does not take an alias on PATH as a usable winget at the start of the run' {
        Test-AndInstallWinget | Out-Null

        Should -Invoke Invoke-WingetProcess -ParameterFilter { $ArgumentList[0] -eq '--version' }
        $script:warnings | Should -Contain "Winget is not available: 'winget --version' exited with 0x8A150002."
    }
}

Describe 'Test-WingetSources' {
    BeforeAll {
        Mock Write-Host { }
        Mock Write-Warning { }
        # Every winget call goes through Invoke-WingetProcess (review findings P2-5, P2-6); the
        # tests below script winget itself, with Mock winget.
        Mock Invoke-WingetProcess { Invoke-TestWingetMock -ArgumentList $ArgumentList }
    }

    Context 'When winget sources are listed and functional' {
        It 'Should return true without attempting repair' {
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
            Mock Add-AppxPackage { }

            $result = Test-WingetSources
            $result | Should -Be $true
            Should -Invoke Add-AppxPackage -Times 0
        }
    }

    Context 'When winget source is corrupted (0x8a15000f)' {
        It 'Should detect corruption and attempt repair with source reset' {
            $script:searchCount = 0
            Mock winget {
                if ($args[0] -eq 'source' -and $args[1] -eq 'list') {
                    $global:LASTEXITCODE = 0
                    return 'winget      https://cdn.winget.microsoft.com/cache'
                }
                elseif ($args[0] -eq 'search' -and $args[1] -eq '7zip') {
                    $script:searchCount++
                    if ($script:searchCount -eq 1) {
                        # First call: corrupted data
                        $global:LASTEXITCODE = 1
                        return 'Failed when opening source(s); try the source reset command if the problem persists. 0x8a15000f Data required by the source is missing'
                    }
                    # After reset: works
                    $global:LASTEXITCODE = 0
                    return '7zip.7zip    7.30'
                }
                elseif ($args[0] -eq 'source' -and $args[1] -eq 'reset') {
                    $global:LASTEXITCODE = 0
                    return 'Source reset completed'
                }
            }
            Mock Add-AppxPackage { }

            $result = Test-WingetSources
            $result | Should -Be $true
            Should -Invoke Add-AppxPackage -Times 1
        }
    }

    Context 'When winget sources are missing entirely' {
        It 'Should attempt repair with source reset and Add-AppxPackage' {
            # Poison any exit code left over from other tests so this test only
            # passes when the mock choreography below is complete (#181).
            $global:LASTEXITCODE = 1
            $script:listCallCount = 0
            Mock winget {
                # Set $global:LASTEXITCODE on EVERY simulated call: production reads it
                # right after each search, and stale values leak between tests (#181).
                if ($args[0] -eq 'source' -and $args[1] -eq 'list') {
                    $script:listCallCount++
                    $global:LASTEXITCODE = 0
                    if ($script:listCallCount -eq 1) {
                        # Initially: only msstore, no winget
                        return 'msstore      https://storeedgefd.dsx.mp.microsoft.com/v9.0'
                    }
                    # After repair: winget source is restored
                    return 'winget      https://cdn.winget.microsoft.com/cache'
                }
                elseif ($args[0] -eq 'search' -and $args[1] -eq '7zip') {
                    # Production performs a single post-repair search in this scenario
                    $global:LASTEXITCODE = 0
                    return '7zip.7zip    7.30'
                }
                elseif ($args[0] -eq 'source' -and $args[1] -eq 'reset') {
                    $global:LASTEXITCODE = 0
                    return 'Source reset completed'
                }
            }
            Mock Add-AppxPackage { }

            $result = Test-WingetSources
            $result | Should -Be $true
            Should -Invoke Add-AppxPackage -Times 1
        }
    }

    Context 'When winget sources repair fails' {
        It 'Should return false when Add-AppxPackage throws error' {
            Mock winget {
                if ($args[0] -eq 'source' -and $args[1] -eq 'list') {
                    return 'msstore      https://storeedgefd.dsx.mp.microsoft.com/v9.0'
                }
                elseif ($args[0] -eq 'source' -and $args[1] -eq 'reset') {
                    return 'Source reset completed'
                }
            }
            Mock Add-AppxPackage { throw 'Network error' }

            $result = Test-WingetSources
            $result | Should -Be $false
        }
    }

    Context 'When winget source is corrupted and source reset fails' {
        It 'Should still attempt Add-AppxPackage as fallback' {
            $script:listCallCount = 0
            $script:searchCallCount = 0
            Mock winget {
                if ($args[0] -eq 'source' -and $args[1] -eq 'list') {
                    $script:listCallCount++
                    if ($script:listCallCount -eq 1) {
                        # Initially: source is listed
                        return 'winget      https://cdn.winget.microsoft.com/cache'
                    }
                    # After repair attempt: still listed (but Add-AppxPackage will fix it)
                    return 'winget      https://cdn.winget.microsoft.com/cache'
                }
                elseif ($args[0] -eq 'search' -and $args[1] -eq '7zip') {
                    $script:searchCallCount++
                    if ($script:searchCallCount -eq 1) {
                        # Initially: corrupted
                        $global:LASTEXITCODE = 1
                        return '0x8a15000f Data required by the source is missing'
                    }
                    # After Add-AppxPackage: works
                    $global:LASTEXITCODE = 0
                    return '7zip.7zip    7.30'
                }
                elseif ($args[0] -eq 'source' -and $args[1] -eq 'reset') {
                    # Reset fails
                    throw 'Access denied'
                }
            }
            Mock Add-AppxPackage { }

            $result = Test-WingetSources
            $result | Should -Be $true
            Should -Invoke Add-AppxPackage -Times 1
        }
    }

    Context 'When winget source list throws an exception' {
        It 'Should attempt repair and handle the error gracefully' {
            # Poison any exit code left over from other tests so this test only
            # passes when the mock choreography below is complete (#181).
            $global:LASTEXITCODE = 1
            $script:listCount = 0
            Mock winget {
                # Set $global:LASTEXITCODE on EVERY simulated call: production reads it
                # right after each search, and stale values leak between tests (#181).
                if ($args[0] -eq 'source' -and $args[1] -eq 'list') {
                    $script:listCount++
                    if ($script:listCount -eq 1) {
                        throw 'Access denied'
                    }
                    # After repair, list succeeds
                    $global:LASTEXITCODE = 0
                    return 'winget      https://cdn.winget.microsoft.com/cache'
                }
                elseif ($args[0] -eq 'search' -and $args[1] -eq '7zip') {
                    # Production performs a single post-repair search in this scenario
                    $global:LASTEXITCODE = 0
                    return '7zip.7zip    7.30'
                }
                elseif ($args[0] -eq 'source' -and $args[1] -eq 'reset') {
                    $global:LASTEXITCODE = 0
                    return 'Source reset completed'
                }
            }
            Mock Add-AppxPackage { }

            $result = Test-WingetSources
            $result | Should -Be $true
            Should -Invoke Add-AppxPackage -Times 1
        }
    }

    Context 'Source reset (review findings P2-5, P2-6)' {
        It 'Runs winget source reset without --accept-source-agreements, which source reset rejects, under its time limit' {
            Mock winget {
                if ($args[0] -eq 'source' -and $args[1] -eq 'list') {
                    $global:LASTEXITCODE = 0
                    return 'winget      https://cdn.winget.microsoft.com/cache'
                }
                if ($args[0] -eq 'search') {
                    $global:LASTEXITCODE = -1978335217
                    return '0x8a15000f Data required by the source is missing'
                }
                if ($args -contains '--accept-source-agreements') {
                    $global:LASTEXITCODE = -1978335230
                    return 'usage: winget source reset [[-n] <name>] [--force]'
                }
                $global:LASTEXITCODE = 0
            }
            Mock Add-AppxPackage { }

            [void](Test-WingetSources)

            Should -Invoke winget -Times 1 -Exactly -ParameterFilter {
                $args[0] -eq 'source' -and $args[1] -eq 'reset' -and $args -contains '--force' -and $args -notcontains '--accept-source-agreements'
            }
            Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter {
                $ArgumentList[1] -eq 'reset' -and $TimeoutSeconds -eq (Get-ProcessTimeoutSeconds -Operation WingetSourceReset)
            }
        }

        It 'Says when the reset failed, with its exit code, instead of reporting it completed' {
            $script:resetWarnings = @()
            Mock Write-WarningMessage { $script:resetWarnings += $Message }
            $script:resetInfos = @()
            Mock Write-Info { $script:resetInfos += $Message }
            Mock winget {
                if ($args[0] -eq 'source' -and $args[1] -eq 'list') {
                    $global:LASTEXITCODE = 0
                    return 'winget      https://cdn.winget.microsoft.com/cache'
                }
                if ($args[0] -eq 'search') {
                    $global:LASTEXITCODE = -1978335217
                    return '0x8a15000f Data required by the source is missing'
                }
                if ($args[1] -eq 'reset') {
                    $global:LASTEXITCODE = -1978335230
                    return 'An unexpected error occurred'
                }
            }
            Mock Add-AppxPackage { }

            [void](Test-WingetSources)

            $script:resetWarnings | Should -Contain 'Winget source reset failed with exit code 0x8A150002.'
            $script:resetInfos | Should -Not -Contain 'Source reset completed.'
        }
    }

    Context 'Functional probe arguments (issue #177)' {
        It 'Should pass --accept-source-agreements to the winget search probe' {
            $script:searchArgs = $null
            Mock winget {
                if ($args[0] -eq 'source' -and $args[1] -eq 'list') {
                    $global:LASTEXITCODE = 0
                    return 'winget      https://cdn.winget.microsoft.com/cache'
                }
                elseif ($args[0] -eq 'search' -and $args[1] -eq '7zip') {
                    $script:searchArgs = $args
                    $global:LASTEXITCODE = 0
                    return '7zip.7zip    7.30'
                }
            }
            Mock Add-AppxPackage { }

            $result = Test-WingetSources

            $result | Should -Be $true
            # --accept-source-agreements is valid for `winget search` (unlike `winget source
            # update`, issues #174/#175) and stops a fresh account's unaccepted agreements
            # (0x8A150046) from being misdiagnosed as source corruption.
            $script:searchArgs | Should -Contain '--accept-source-agreements'
            $script:searchArgs | Should -Contain '--disable-interactivity'
            $script:searchArgs | Should -Contain '--source'
        }
    }

    # P2-16: a dry run used to run `winget source reset --force` (which also drops any source added
    # beyond the defaults) and re-register the source package.
    Context 'Dry run (-WhatIf)' {
        BeforeEach {
            Mock Add-AppxPackage { }
            $script:infoMessages = @()
            Mock Write-Info { $script:infoMessages += $Message }
            $script:warningMessages = @()
            Mock Write-WarningMessage { $script:warningMessages += $Message }
        }

        It 'Reports the repair of a corrupted source without resetting sources or registering the source package' {
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

            Test-WingetSources -WhatIf | Should -Be $false

            Should -Invoke winget -Times 0 -Exactly -ParameterFilter { $args -contains 'reset' }
            Should -Invoke Add-AppxPackage -Times 0 -Exactly
            ($script:infoMessages -join "`n") | Should -Match '\[DRY-RUN\] Winget source data is corrupted\. A real run would repair it: winget source reset --force'
            ($script:warningMessages -join "`n") | Should -Not -Match 'Attempting to repair'
        }

        It 'Reports a missing source the same way, without repairing it' {
            Mock winget {
                $global:LASTEXITCODE = 0
                if ($args[0] -eq 'source' -and $args[1] -eq 'list') {
                    return 'msstore      https://storeedgefd.dsx.mp.microsoft.com/v9.0'
                }
            }

            Test-WingetSources -WhatIf | Should -Be $false

            Should -Invoke winget -Times 0 -Exactly -ParameterFilter { $args -contains 'reset' }
            Should -Invoke Add-AppxPackage -Times 0 -Exactly
            ($script:infoMessages -join "`n") | Should -Match '\[DRY-RUN\] Winget source "winget" appears to be missing\. A real run would repair it'
        }

        It 'Returns true for a healthy source without a dry-run line' {
            Mock winget {
                $global:LASTEXITCODE = 0
                if ($args[0] -eq 'source' -and $args[1] -eq 'list') {
                    return 'winget      https://cdn.winget.microsoft.com/cache'
                }
                return '7zip.7zip    7.30'
            }

            Test-WingetSources -WhatIf | Should -Be $true

            ($script:infoMessages -join "`n") | Should -Not -Match '\[DRY-RUN\]'
        }
    }
}

Describe 'msstore-era source-trust helpers removed (issue #177)' {
    # Test-WingetSourceTrusted trusted error output (no $LASTEXITCODE check on merged stderr) and
    # Set-Sources was only reachable from the removed Install.ps1 trusted-sources loop; source
    # health is verified (and repaired) solely by Test-WingetSources now.
    It 'No longer defines Test-WingetSourceTrusted' {
        Test-Path Function:\Test-WingetSourceTrusted | Should -Be $false
    }

    It 'No longer defines Set-Sources' {
        Test-Path Function:\Set-Sources | Should -Be $false
    }

    It 'No longer exports either helper from the module manifest' {
        $manifest = Import-PowerShellDataFile $script:ModuleManifestPath
        $manifest.FunctionsToExport | Should -Not -Contain 'Test-WingetSourceTrusted'
        $manifest.FunctionsToExport | Should -Not -Contain 'Set-Sources'
    }
}

Describe 'Install-WingetPackage (0x80073d19 session-error backoff)' {
    BeforeAll {
        # 0x80073D19 (ERROR_INSTALL_USER_LOGOFF) as the signed Int32 winget reports.
        $script:SessionLogoffExitCode = -2147009255
    }

    BeforeEach {
        Mock Write-Host { }
        Mock Write-WarningMessage { }
        # Never actually wait during tests; the backoff is verified via Should -Invoke.
        Mock Start-Sleep { }

        # An attended run unless a test says otherwise (no --silent).
        Mock Test-EffectiveNonInteractive { $false }

        # Each winget run returns the next exit code from the queue, simulating winget.
        $script:exitCodeQueue = @()
        $script:procCallIndex = 0
        Mock Invoke-WingetProcess {
            $code = $script:exitCodeQueue[$script:procCallIndex]
            $script:procCallIndex++
            New-TestProcessResult -ExitCode $code
        }
    }

    It 'Succeeds on the first attempt without sleeping' {
        $script:exitCodeQueue = @(0)

        $result = Install-WingetPackage -PackageId 'Test.App' -MaxAttempts 3 -InitialDelaySeconds 1

        $result.ExitCode | Should -Be 0
        $result.Attempts | Should -Be 1
        $result.SessionErrorExhausted | Should -Be $false
        Should -Invoke Invoke-WingetProcess -Times 1 -Exactly
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'Retries with backoff and recovers when the session error is transient' {
        $script:exitCodeQueue = @($script:SessionLogoffExitCode, 0)

        $result = Install-WingetPackage -PackageId 'Microsoft.PowerShell' -MaxAttempts 3 -InitialDelaySeconds 1

        $result.ExitCode | Should -Be 0
        $result.Attempts | Should -Be 2
        $result.SessionErrorExhausted | Should -Be $false
        Should -Invoke Invoke-WingetProcess -Times 2 -Exactly
        # One backoff wait between the failed first attempt and the successful second.
        Should -Invoke Start-Sleep -Times 1 -Exactly
    }

    It 'Exhausts MaxAttempts when the session error persists' {
        $script:exitCodeQueue = @($script:SessionLogoffExitCode, $script:SessionLogoffExitCode, $script:SessionLogoffExitCode)

        $result = Install-WingetPackage -PackageId 'Microsoft.PowerShell' -MaxAttempts 3 -InitialDelaySeconds 1

        $result.ExitCode | Should -Be $script:SessionLogoffExitCode
        $result.Attempts | Should -Be 3
        $result.SessionErrorExhausted | Should -Be $true
        Should -Invoke Invoke-WingetProcess -Times 3 -Exactly
        # Sleeps between attempts only (1->2 and 2->3), never after the final attempt.
        Should -Invoke Start-Sleep -Times 2 -Exactly
    }

    It 'Does not retry a non-session failure (lets the caller verify)' {
        # -1978335189 = "No applicable update found"; any non-session code must stop immediately.
        $script:exitCodeQueue = @(-1978335189)

        $result = Install-WingetPackage -PackageId 'Test.App' -MaxAttempts 3 -InitialDelaySeconds 1

        $result.ExitCode | Should -Be -1978335189
        $result.Attempts | Should -Be 1
        $result.SessionErrorExhausted | Should -Be $false
        Should -Invoke Invoke-WingetProcess -Times 1 -Exactly
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'Prefers machine scope on the first attempt (issue #159)' {
        $script:exitCodeQueue = @(0)

        $result = Install-WingetPackage -PackageId 'Microsoft.PowerShell' -MaxAttempts 3 -InitialDelaySeconds 1

        $result.MachineScopeFellBack | Should -Be $false
        Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter {
            ($ArgumentList -contains '--scope') -and ($ArgumentList -contains 'machine')
        }
    }

    It 'Falls back to default scope when the package has no machine-scope installer' {
        # -1978335216 = 0x8A150010 NO_APPLICABLE_INSTALLER (e.g. MSIX-only Microsoft.WindowsTerminal).
        $script:exitCodeQueue = @(-1978335216, 0)

        $result = Install-WingetPackage -PackageId 'Microsoft.WindowsTerminal' -MaxAttempts 3 -InitialDelaySeconds 1

        $result.ExitCode | Should -Be 0
        $result.MachineScopeFellBack | Should -Be $true
        # The scope fallback is not a session-error retry: it must not consume an attempt or sleep.
        $result.Attempts | Should -Be 1
        Should -Invoke Invoke-WingetProcess -Times 2 -Exactly
        Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter { $ArgumentList -notcontains '--scope' }
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'Falls back on scope at most once' {
        # NO_APPLICABLE_INSTALLER at both scopes is a real failure and must be returned, not looped.
        $script:exitCodeQueue = @(-1978335216, -1978335216)

        $result = Install-WingetPackage -PackageId 'Broken.Package' -MaxAttempts 3 -InitialDelaySeconds 1

        $result.ExitCode | Should -Be -1978335216
        $result.MachineScopeFellBack | Should -Be $true
        Should -Invoke Invoke-WingetProcess -Times 2 -Exactly
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'Still retries the session error with backoff after a scope fallback' {
        $script:exitCodeQueue = @(-1978335216, $script:SessionLogoffExitCode, 0)

        $result = Install-WingetPackage -PackageId 'Microsoft.WindowsTerminal' -MaxAttempts 3 -InitialDelaySeconds 1

        $result.ExitCode | Should -Be 0
        $result.MachineScopeFellBack | Should -Be $true
        $result.Attempts | Should -Be 2
        $result.SessionErrorExhausted | Should -Be $false
        Should -Invoke Invoke-WingetProcess -Times 3 -Exactly
        Should -Invoke Start-Sleep -Times 1 -Exactly
    }

    It 'Passes --installer-type to winget when an installer type is supplied' {
        $script:exitCodeQueue = @(0)

        Install-WingetPackage -PackageId 'Microsoft.PowerShell' -InstallerType 'wix' -MaxAttempts 1 | Out-Null

        Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter {
            ($ArgumentList -join ' ') -match '--installer-type\s+wix'
        }
    }

    It 'Omits --installer-type when no installer type is supplied' {
        $script:exitCodeQueue = @(0)

        Install-WingetPackage -PackageId 'Test.App' -MaxAttempts 1 | Out-Null

        Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter {
            $ArgumentList -notcontains '--installer-type'
        }
    }

    It 'Installs from the winget source with both agreement-acceptance flags (issue #172)' {
        $script:exitCodeQueue = @(0)

        Install-WingetPackage -PackageId 'Test.App' -MaxAttempts 1 | Out-Null

        Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter {
            (($ArgumentList -join ' ') -match '--source winget') -and
            ($ArgumentList -contains '--accept-source-agreements') -and
            ($ArgumentList -contains '--accept-package-agreements')
        }
    }
}

Describe 'Install-WingetPackage (transient launch-exception backoff, issue #253)' {
    BeforeEach {
        Mock Write-Host { }
        Mock Write-WarningMessage { }
        Mock Write-Info { }
        # Never actually wait during tests; the backoff is verified via Should -Invoke.
        Mock Start-Sleep { }
        Mock Test-EffectiveNonInteractive { $false }
    }

    It 'Retries with backoff and recovers when winget fails to launch with a transient file-lock error' {
        $script:callIndex = 0
        Mock Invoke-WingetProcess {
            $script:callIndex++
            if ($script:callIndex -eq 1) {
                return New-TestProcessResult -LaunchFailed -LaunchErrorCode 1920 -LaunchError 'The file cannot be accessed by the system.'
            }
            New-TestProcessResult -ExitCode 0
        }

        $result = Install-WingetPackage -PackageId 'Klocman.BulkCrapUninstaller' -MaxAttempts 3 -InitialDelaySeconds 1

        $result.ExitCode | Should -Be 0
        # A failed launch never ran winget, so it does not consume an install attempt (issue #258).
        $result.Attempts | Should -Be 1
        $result.LaunchAttempts | Should -Be 1
        $result.LaunchErrorExhausted | Should -Be $false
        Should -Invoke Invoke-WingetProcess -Times 2 -Exactly
        Should -Invoke Start-Sleep -Times 1 -Exactly
    }

    It 'Retries the same winget, never a winget.exe under the App Installer package folder (review finding P3-7)' {
        # The package folder launch (Resolve-WingetExecutable -BypassAlias) failed with 'Access is
        # denied' in every E2E run and was removed. A registered package is visible here, so a
        # leftover lookup would hand its path to the retry.
        $script:installLocation = Join-Path $TestDrive 'WindowsApps/Microsoft.DesktopAppInstaller_1.26.510.0_x64__8wekyb3d8bbwe'
        Mock Get-AppxPackage { [pscustomobject]@{ Name = 'Microsoft.DesktopAppInstaller'; Version = '1.26.510.0'; InstallLocation = $script:installLocation } }
        Mock Test-Path { $true }
        $script:callIndex = 0
        Mock Invoke-WingetProcess {
            $script:callIndex++
            if ($script:callIndex -lt 3) {
                return New-TestProcessResult -LaunchFailed -LaunchErrorCode 1920 -LaunchError 'The file cannot be accessed by the system.'
            }
            New-TestProcessResult -ExitCode 0
        }

        $result = Install-WingetPackage -PackageId 'Microsoft.WindowsTerminal' -MaxAttempts 3 -InitialDelaySeconds 1

        $result.ExitCode | Should -Be 0
        $result.LaunchAttempts | Should -Be 2
        Should -Invoke Invoke-WingetProcess -Times 3 -Exactly
        Should -Invoke Invoke-WingetProcess -Times 0 -Exactly -ParameterFilter { $WingetPath -and $WingetPath -ne 'winget' }
        Should -Invoke Get-AppxPackage -Times 0 -Exactly
    }

    It 'Also retries the sibling sharing-violation launch exception' {
        $script:callIndex = 0
        Mock Invoke-WingetProcess {
            $script:callIndex++
            if ($script:callIndex -eq 1) {
                return New-TestProcessResult -LaunchFailed -LaunchErrorCode 32 -LaunchError 'The process cannot access the file because it is being used by another process.'
            }
            New-TestProcessResult -ExitCode 0
        }

        $result = Install-WingetPackage -PackageId 'Microsoft.WindowsTerminal' -MaxAttempts 3 -InitialDelaySeconds 1

        $result.ExitCode | Should -Be 0
        $result.LaunchErrorExhausted | Should -Be $false
        Should -Invoke Invoke-WingetProcess -Times 2 -Exactly
    }

    It 'Exhausts MaxLaunchAttempts when winget.exe stays transiently inaccessible, returning a null ExitCode' {
        Mock Invoke-WingetProcess {
            New-TestProcessResult -LaunchFailed -LaunchErrorCode 1920 -LaunchError 'The file cannot be accessed by the system.'
        }

        $result = Install-WingetPackage -PackageId 'Microsoft.PowerShell' -MaxAttempts 3 -InitialDelaySeconds 1 -MaxLaunchAttempts 3

        $result.ExitCode | Should -Be $null
        # No install ever ran: failed launches have their own budget and counter (issue #258).
        $result.Attempts | Should -Be 0
        $result.LaunchAttempts | Should -Be 3
        $result.LaunchErrorExhausted | Should -Be $true
        $result.LaunchError | Should -Be 'The file cannot be accessed by the system.'
        Should -Invoke Invoke-WingetProcess -Times 3 -Exactly
        # Sleeps between launch attempts only (1->2 and 2->3), never after the final attempt.
        Should -Invoke Start-Sleep -Times 2 -Exactly
    }

    It 'Gives launch failures a larger default budget than install attempts (75s window, issue #258)' {
        Mock Invoke-WingetProcess {
            New-TestProcessResult -LaunchFailed -LaunchErrorCode 1920 -LaunchError 'The file cannot be accessed by the system.'
        }
        $script:launchWaits = @()
        Mock Start-Sleep { $script:launchWaits += $Seconds }

        $result = Install-WingetPackage -PackageId 'Microsoft.WindowsTerminal' -MaxAttempts 3 -InitialDelaySeconds 5

        $result.LaunchErrorExhausted | Should -Be $true
        $result.LaunchAttempts | Should -Be 5
        Should -Invoke Invoke-WingetProcess -Times 5 -Exactly
        # Doubling backoff sized to outlast an App Installer re-registration window.
        $script:launchWaits | Should -Be @(5, 10, 20, 40)
    }

    It 'Reports a launch failure that waiting does not change (<Case>) at once, without retrying or throwing' -ForEach @(
        @{ Case = 'file not found'; Code = 2; Message = 'The system cannot find the file specified.' }
        @{ Case = 'access denied'; Code = 5; Message = 'Access is denied.' }
    ) {
        # It used to throw, so the run reported an 'Unexpected error' and Invoke-WingetInstall's
        # circuit breaker never saw that winget could not be launched.
        $script:launchCode = $Code
        $script:launchMessage = $Message
        Mock Invoke-WingetProcess {
            New-TestProcessResult -LaunchFailed -LaunchErrorCode $script:launchCode -LaunchError $script:launchMessage
        }

        $result = Install-WingetPackage -PackageId 'Test.App' -MaxAttempts 3 -InitialDelaySeconds 1

        $result.LaunchErrorExhausted | Should -Be $true
        $result.LaunchError | Should -Be $Message
        $result.ExitCode | Should -Be $null
        $result.Attempts | Should -Be 0
        $result.LaunchAttempts | Should -Be 1
        Should -Invoke Invoke-WingetProcess -Times 1 -Exactly
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }
}

Describe 'Install-WingetPackage (time limit, installer log, --silent and launch codes; review findings P2-5, P2-6, P3-6)' {
    BeforeEach {
        Mock Write-Host { }
        Mock Write-Info { }
        Mock Write-WarningMessage { }
        Mock Write-ErrorMessage { }
        Mock Start-Sleep { }
        Mock Test-EffectiveNonInteractive { $false }
        Mock Invoke-WingetProcess { New-TestProcessResult -ExitCode 0 }
    }

    It 'Runs winget install through Invoke-WingetProcess under the install time limit' {
        [void](Install-WingetPackage -PackageId 'Test.App' -MaxAttempts 1)

        # No -WingetPath: Invoke-WingetProcess resolves winget itself (Resolve-WingetExecutable).
        Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter {
            $ArgumentList[0] -eq 'install' -and $TimeoutSeconds -eq (Get-ProcessTimeoutSeconds -Operation WingetInstall) -and -not $WingetPath
        }
    }

    It 'Passes --silent when the run is unattended' {
        Mock Test-EffectiveNonInteractive { $true }

        [void](Install-WingetPackage -PackageId 'Test.App' -MaxAttempts 1)

        Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter { $ArgumentList -contains '--silent' }
    }

    It 'Leaves --silent out when someone is at the console' {
        [void](Install-WingetPackage -PackageId 'Test.App' -MaxAttempts 1)

        Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter { $ArgumentList -notcontains '--silent' }
    }

    It 'Follows an explicit -Silent over the detection (<Case>)' -ForEach @(
        @{ Case = '-Silent on an attended console'; Detected = $false; Silent = $true; Expected = $true }
        @{ Case = '-Silent:$false in an unattended run'; Detected = $true; Silent = $false; Expected = $false }
    ) {
        $script:detected = $Detected
        Mock Test-EffectiveNonInteractive { $script:detected }

        [void](Install-WingetPackage -PackageId 'Test.App' -MaxAttempts 1 -Silent:$Silent)

        $script:expected = $Expected
        Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter { ($ArgumentList -contains '--silent') -eq $script:expected }
    }

    It 'Reports a timed-out install with no exit code and does not retry it' {
        Mock Invoke-WingetProcess { New-TestProcessResult -TimedOut }

        $result = Install-WingetPackage -PackageId 'Test.App' -MaxAttempts 3

        $result.TimedOut | Should -Be $true
        $result.TimeoutSeconds | Should -Be (Get-ProcessTimeoutSeconds -Operation WingetInstall)
        $result.ExitCode | Should -Be $null
        $result.Attempts | Should -Be 1
        $result.SessionErrorExhausted | Should -Be $false
        Should -Invoke Invoke-WingetProcess -Times 1 -Exactly
        Should -Invoke Write-ErrorMessage -Times 1 -Exactly -ParameterFilter { $Message -eq 'Install of Test.App did not finish within 30 minutes and was stopped.' }
    }

    It 'Returns the installer log winget wrote, and names it when the install failed' {
        $script:installerLog = Join-Path $TestDrive 'winget-install-Test.App-20261004-101500.log'
        Set-Content -LiteralPath $script:installerLog -Value 'MSI (s) Return value 3.'
        Mock Invoke-WingetProcess { New-TestProcessResult -ExitCode -1978335226 -LogPath $script:installerLog }

        $result = Install-WingetPackage -PackageId 'Test.App' -MaxAttempts 1

        $result.InstallerLogPath | Should -Be $script:installerLog
        $result.TimedOut | Should -Be $false
        Should -Invoke Write-Info -Times 1 -Exactly -ParameterFilter { $Message -eq "Installer log for Test.App: $script:installerLog" }
    }

    It 'Returns no installer log when the installer wrote none' {
        Mock Invoke-WingetProcess { New-TestProcessResult -ExitCode 0 -LogPath (Join-Path $TestDrive 'never-written.log') }

        (Install-WingetPackage -PackageId 'Test.App' -MaxAttempts 1).InstallerLogPath | Should -Be $null
    }

    It 'Retries a launch failure recognized by its Win32 code, whatever language the message is in' {
        $script:callIndex = 0
        Mock Invoke-WingetProcess {
            $script:callIndex++
            if ($script:callIndex -eq 1) {
                return New-TestProcessResult -LaunchFailed -LaunchErrorCode 1920 -LaunchError 'Das System kann auf die Datei nicht zugreifen.'
            }
            New-TestProcessResult -ExitCode 0
        }

        $result = Install-WingetPackage -PackageId 'Test.App' -MaxAttempts 3 -InitialDelaySeconds 1

        $result.ExitCode | Should -Be 0
        $result.LaunchAttempts | Should -Be 1
        Should -Invoke Invoke-WingetProcess -Times 2 -Exactly
    }
}

Describe 'Install-WingetPackage with a real process (review findings P2-5, P2-6)' {
    # The fake winget below really runs: Resolve-WingetExecutable hands its path to the install.
    BeforeEach {
        Mock Start-Sleep { }
        Mock Test-EffectiveNonInteractive { $false }
        Mock Write-Info { }
        Mock Write-ErrorMessage { }
    }

    It 'Writes winget''s own output, including the installer''s exit code, into the transcript' {
        $script:fakeWinget = New-FakeExecutable -Directory $TestDrive -Name 'fake-winget' -StandardOutput 'Found Test App [Test.App] Version 1.0', 'Starting package install...', 'Installer failed with exit code: 1603' -ExitCode 1
        Mock Resolve-WingetExecutable { $script:fakeWinget }
        $transcript = Join-Path $TestDrive 'install-transcript.log'

        Start-Transcript -LiteralPath $transcript | Out-Null
        try {
            $result = Install-WingetPackage -PackageId 'Test.App' -MaxAttempts 1
        }
        finally {
            Stop-Transcript | Out-Null
        }

        $result.ExitCode | Should -Be 1
        $logged = Get-Content -LiteralPath $transcript -Raw
        $logged | Should -Match ([regex]::Escape('Found Test App [Test.App] Version 1.0'))
        $logged | Should -Match ([regex]::Escape('Installer failed with exit code: 1603'))
    }

    It 'Stops an install that runs past its time limit instead of waiting for ever' {
        $script:fakeWinget = New-FakeExecutable -Directory $TestDrive -Name 'fake-winget-hang' -StandardOutput 'Starting package install...' -SleepSeconds 30
        Mock Resolve-WingetExecutable { $script:fakeWinget }
        Mock Get-ProcessTimeoutSeconds { 3 }
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        $result = Install-WingetPackage -PackageId 'Test.App' -MaxAttempts 3

        $stopwatch.Stop()
        $result.TimedOut | Should -Be $true
        $result.ExitCode | Should -Be $null
        $stopwatch.Elapsed.TotalSeconds | Should -BeLessThan 25
    }
}

Describe 'Test-WingetPackageInstalled (timeout support, issue #188)' {
    BeforeEach {
        Mock Write-Host { }
    }

    Context 'Without -TimeoutSeconds (backward-compatible [bool] call)' {
        It 'Returns $true when winget lists the package' {
            Mock Invoke-WingetProcess { New-TestProcessResult -Output @('Name    Id       Version', '7-Zip   Test.App 24.09') }

            $result = Test-WingetPackageInstalled -PackageId 'Test.App'

            $result | Should -BeOfType [bool]
            $result | Should -Be $true
        }

        It 'Returns $false when winget does not list the package' {
            Mock Invoke-WingetProcess { New-TestProcessResult -ExitCode -1978335212 -Output @('No installed package found matching input criteria.') }

            Test-WingetPackageInstalled -PackageId 'Test.App' | Should -Be $false
        }

        It 'Returns $false when winget cannot be started' {
            Mock Invoke-WingetProcess { New-TestProcessResult -LaunchFailed -LaunchErrorCode 2 -LaunchError 'winget not found' }

            Test-WingetPackageInstalled -PackageId 'Test.App' | Should -Be $false
        }

        It 'Returns $false when winget list times out' {
            Mock Invoke-WingetProcess { New-TestProcessResult -TimedOut -Output @('Test.App  1.0') }

            Test-WingetPackageInstalled -PackageId 'Test.App' | Should -Be $false
        }

        It 'Is time-limited too (review finding P2-5): it used to call winget inline with no limit' {
            Mock Invoke-WingetProcess { New-TestProcessResult -Output @('Test.App  1.0') }

            Test-WingetPackageInstalled -PackageId 'Test.App' | Should -Be $true

            Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter {
                $TimeoutSeconds -eq (Get-ProcessTimeoutSeconds -Operation WingetList) -and $Echo -eq 'None' -and $ArgumentList[0] -eq 'list'
            }
        }

        It 'Returns $false when the output only contains a different id that has the target as a substring (CLAUDE.md regex enforcement)' {
            Mock Invoke-WingetProcess { New-TestProcessResult -Output @('Name       Id           Version', 'Foo BarBaz Foo.BarBaz  1.0') }

            Test-WingetPackageInstalled -PackageId 'Foo.Bar' | Should -Be $false
        }

        It 'Still returns $true for a real matching line when a substring-only lookalike is also present' {
            Mock Invoke-WingetProcess { New-TestProcessResult -Output @('Name       Id           Version', 'Foo Bar    Foo.Bar      1.0', 'Foo BarBaz Foo.BarBaz  1.0') }

            Test-WingetPackageInstalled -PackageId 'Foo.Bar' | Should -Be $true
        }
    }

    Context 'With -TimeoutSeconds' {
        It 'Reports installed with the process exit code when the id appears in the output' {
            Mock Invoke-WingetProcess { New-TestProcessResult -ExitCode 0 -Output @('Test.App  1.2.3  winget') }

            $result = Test-WingetPackageInstalled -PackageId 'Test.App' -TimeoutSeconds 15

            $result.Installed | Should -Be $true
            $result.TimedOut | Should -Be $false
            $result.ExitCode | Should -Be 0
            Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter {
                ($ArgumentList -contains 'list') -and
                ($ArgumentList -contains '--exact') -and
                ($ArgumentList -contains '--id') -and
                ($ArgumentList -contains 'Test.App') -and
                ($ArgumentList -contains '--accept-source-agreements') -and
                $TimeoutSeconds -eq 15 -and
                # Quiet: the per-app checks would otherwise print winget's table twice per app.
                $Echo -eq 'None'
            }
        }

        It 'Reports not-installed when the output only contains a different id that has the target as a substring' {
            Mock Invoke-WingetProcess { New-TestProcessResult -ExitCode -1978335212 -Output @('Foo.BarBaz  1.0.0  winget') }

            $result = Test-WingetPackageInstalled -PackageId 'Foo.Bar' -TimeoutSeconds 15

            $result.Installed | Should -Be $false
        }

        It 'Reports not-installed when the output does not mention the id' {
            Mock Invoke-WingetProcess { New-TestProcessResult -ExitCode -1978335212 -Output @('No installed package found matching input criteria.') }

            $result = Test-WingetPackageInstalled -PackageId 'Test.App' -TimeoutSeconds 15

            $result.Installed | Should -Be $false
            $result.TimedOut | Should -Be $false
            $result.ExitCode | Should -Be -1978335212
        }

        It 'Looks for the id in standard output only, as before' {
            Mock Invoke-WingetProcess { New-TestProcessResult -ExitCode -1978335212 -StandardError @('Test.App could not be listed') }

            (Test-WingetPackageInstalled -PackageId 'Test.App' -TimeoutSeconds 15).Installed | Should -Be $false
        }

        It 'Reports a timed-out winget list distinctly from not-installed (issue #176)' {
            Mock Invoke-WingetProcess { New-TestProcessResult -TimedOut -Output @('Test.App  1.2.3  winget') }

            $result = Test-WingetPackageInstalled -PackageId 'Test.App' -TimeoutSeconds 1

            $result.Installed | Should -Be $false
            $result.TimedOut | Should -Be $true
            $result.ExitCode | Should -Be $null
        }

        It 'Reports a winget that could not be started as LaunchFailed, not as not installed (review finding P2-9, <Case>)' -ForEach @(
            @{ Case = 'transient lock'; Code = 1920; Message = 'The file cannot be accessed by the system.' }
            @{ Case = 'access denied'; Code = 5; Message = 'Access is denied.' }
        ) {
            # It used to read as not installed, so the pipeline installed apps that were already
            # there and reported them as 'package not found after install'. Not retried here: the
            # caller decides, and Invoke-WingetInstall's circuit breaker checks once for the run.
            $script:launchCode = $Code
            $script:launchMessage = $Message
            Mock Invoke-WingetProcess { New-TestProcessResult -LaunchFailed -LaunchErrorCode $script:launchCode -LaunchError $script:launchMessage }

            $result = Test-WingetPackageInstalled -PackageId 'Test.App' -TimeoutSeconds 15

            $result.LaunchFailed | Should -Be $true
            $result.LaunchError | Should -Be $Message
            $result.Installed | Should -Be $false
            $result.TimedOut | Should -Be $false
            $result.ExitCode | Should -Be $null
            Should -Invoke Invoke-WingetProcess -Times 1 -Exactly
        }

        It 'Says LaunchFailed is false whenever winget answered (<Case>)' -ForEach @(
            @{ Case = 'installed'; Result = { New-TestProcessResult -ExitCode 0 -Output @('Test.App  1.0  winget') } }
            @{ Case = 'not installed'; Result = { New-TestProcessResult -ExitCode -1978335212 -Output @('No installed package found matching input criteria.') } }
            @{ Case = 'timed out'; Result = { New-TestProcessResult -TimedOut } }
        ) {
            $script:processResult = & $Result
            Mock Invoke-WingetProcess { $script:processResult }

            $result = Test-WingetPackageInstalled -PackageId 'Test.App' -TimeoutSeconds 15

            $result.LaunchFailed | Should -Be $false
            $result.LaunchError | Should -Be $null
        }
    }
}

Describe 'Initialize-WingetSourcesForUser (cross-user bootstrap, issue #159)' {
    BeforeAll {
        # Stub so the cmdlet can be mocked on machines without the Microsoft.WinGet.Client module.
        function Repair-WinGetPackageManager { param([switch]$Latest, [switch]$Force) }
    }

    BeforeEach {
        Mock Write-Host { }
        Mock Write-WarningMessage { }
        Mock Repair-WinGetPackageManager { }
        Mock Get-ProcessUserName { 'CONTOSO\admin-jmaffiola' }
        Mock Get-InteractiveSessionUserName { 'CONTOSO\admin-jmaffiola' }
        # Repair-WinGetPackageManager resolves as available unless a test overrides this.
        Mock Get-Command { [pscustomobject]@{ Name = 'Repair-WinGetPackageManager' } } -ParameterFilter { $Name -eq 'Repair-WinGetPackageManager' }
        # Default: nothing staged to register for this account, so the ladder's first rung
        # (issue #265) is a no-op and the repair path below is what gets exercised.
        Mock Register-WingetAppInstallerForUser { $false }
    }

    It 'Reports the dry run without probing' {
        Mock Invoke-WingetSourceProbe { @{ Succeeded = $true; ExitCode = 0; TimedOut = $false } }

        $result = Initialize-WingetSourcesForUser -WhatIf

        $result | Should -Be $true
        Should -Invoke Invoke-WingetSourceProbe -Times 0 -Exactly
    }

    It 'Returns true without repairing when the probe succeeds' {
        Mock Invoke-WingetSourceProbe { @{ Succeeded = $true; ExitCode = 0; TimedOut = $false } }

        $result = Initialize-WingetSourcesForUser

        $result | Should -Be $true
        Should -Invoke Invoke-WingetSourceProbe -Times 1 -Exactly
        Should -Invoke Repair-WinGetPackageManager -Times 0 -Exactly
    }

    It 'Repairs the package manager and succeeds when the re-probe passes' {
        $script:probeCallCount = 0
        Mock Invoke-WingetSourceProbe {
            $script:probeCallCount++
            if ($script:probeCallCount -eq 1) {
                # First probe: blocked per-user bootstrap (0x80073D19).
                return @{ Succeeded = $false; ExitCode = -2147009255; TimedOut = $false }
            }
            return @{ Succeeded = $true; ExitCode = 0; TimedOut = $false }
        }

        $result = Initialize-WingetSourcesForUser

        $result | Should -Be $true
        Should -Invoke Repair-WinGetPackageManager -Times 1 -Exactly
        Should -Invoke Invoke-WingetSourceProbe -Times 2 -Exactly
    }

    It 'Returns false when the probe still fails after repair' {
        Mock Invoke-WingetSourceProbe { @{ Succeeded = $false; ExitCode = -2147009255; TimedOut = $false } }

        $result = Initialize-WingetSourcesForUser

        $result | Should -Be $false
        Should -Invoke Repair-WinGetPackageManager -Times 1 -Exactly
        Should -Invoke Invoke-WingetSourceProbe -Times 2 -Exactly
    }

    It 'Returns false and skips repair when Repair-WinGetPackageManager is unavailable' {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'Repair-WinGetPackageManager' }
        Mock Invoke-WingetSourceProbe { @{ Succeeded = $false; ExitCode = -1978335162; TimedOut = $false } }

        $result = Initialize-WingetSourcesForUser

        $result | Should -Be $false
        Should -Invoke Repair-WinGetPackageManager -Times 0 -Exactly
        Should -Invoke Invoke-WingetSourceProbe -Times 1 -Exactly
    }

    It 'Registers the staged App Installer before repairing and succeeds when the re-probe passes (issue #265)' {
        $script:probeCallCount = 0
        Mock Invoke-WingetSourceProbe {
            $script:probeCallCount++
            if ($script:probeCallCount -eq 1) {
                return @{ Succeeded = $false; ExitCode = -2147009255; TimedOut = $false }
            }
            return @{ Succeeded = $true; ExitCode = 0; TimedOut = $false }
        }
        Mock Register-WingetAppInstallerForUser { $true }

        $result = Initialize-WingetSourcesForUser

        $result | Should -Be $true
        Should -Invoke Register-WingetAppInstallerForUser -Times 1 -Exactly
        Should -Invoke Repair-WinGetPackageManager -Times 0 -Exactly
        Should -Invoke Invoke-WingetSourceProbe -Times 2 -Exactly
    }

    It 'Names the dependency conflict in its remediation advice when the repair is downgrade-rejected (issue #265)' {
        Mock Invoke-WingetSourceProbe { @{ Succeeded = $false; ExitCode = -2147009255; TimedOut = $false } }
        Mock Repair-WinGetPackageManager {
            throw 'Deployment failed with HRESULT: 0x80073D06, The package could not be installed because a higher version of this package is already installed.'
        }

        $result = Initialize-WingetSourcesForUser

        $result | Should -Be $false
        Should -Invoke Repair-WinGetPackageManager -Times 1 -Exactly
        Should -Invoke Write-WarningMessage -Times 1 -ParameterFilter { $Message -match 'update App Installer from the Microsoft Store' }
    }

    It 'Names the missing framework in its remediation advice when the repair hits a missing-framework-dependency rejection (issue #279)' {
        Mock Invoke-WingetSourceProbe { @{ Succeeded = $false; ExitCode = -2147009255; TimedOut = $false } }
        Mock Repair-WinGetPackageManager {
            throw ('Deployment failed with HRESULT: 0x80073CF3, Package failed updates, dependency or conflict validation.' + [Environment]::NewLine +
                'Windows cannot install package Microsoft.DesktopAppInstaller_1.29.290.0_x64__8wekyb3d8bbwe because this package depends on a framework that could not be found. Provide the framework "Microsoft.WindowsAppRuntime.1.8" published by "CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US", with neutral or x64 processor architecture and minimum version 8000.616.304.0, along with this package to install.')
        }

        $result = Initialize-WingetSourcesForUser

        $result | Should -Be $false
        Should -Invoke Repair-WinGetPackageManager -Times 1 -Exactly
        Should -Invoke Write-WarningMessage -Times 1 -ParameterFilter { $Message -match 'Microsoft.WindowsAppRuntime.1.8' }
    }

    It 'Warns about cross-user elevation when the process account differs from the session owner' {
        Mock Get-ProcessUserName { 'CONTOSO\admin-jmaffiola' }
        Mock Get-InteractiveSessionUserName { 'CONTOSO\jdoe' }
        Mock Invoke-WingetSourceProbe { @{ Succeeded = $true; ExitCode = 0; TimedOut = $false } }

        [void](Initialize-WingetSourcesForUser)

        Should -Invoke Write-WarningMessage -Times 1 -ParameterFilter { $Message -match 'Cross-user elevation detected' }
    }

    It 'Does not warn about cross-user elevation for a same-account session' {
        Mock Invoke-WingetSourceProbe { @{ Succeeded = $true; ExitCode = 0; TimedOut = $false } }

        [void](Initialize-WingetSourcesForUser)

        Should -Invoke Write-WarningMessage -Times 0 -ParameterFilter { $Message -match 'Cross-user elevation detected' }
    }
}

Describe 'Install-PowerShellLatest (always-latest strategy, issue #166)' {
    BeforeEach {
        Mock Write-Host { }
        Mock Write-Info { }
        Mock Write-Success { }
        Mock Write-WarningMessage { }
        Mock Write-ErrorMessage { }
    }

    It 'installs the MSI while one is available and verifies via winget' {
        Mock Install-WingetPackage { @{ ExitCode = 0 } }
        Mock Test-WingetPackageInstalled { @{ Installed = $true; TimedOut = $false; ExitCode = 0 } }
        Mock Install-MsixProvisionedPackage { throw 'DISM provisioning should not run when an MSI is available' }

        $result = Install-PowerShellLatest

        $result.Method | Should -Be 'msi'
        $result.Installed | Should -Be $true
        Should -Invoke Install-WingetPackage -Times 1 -Exactly -ParameterFilter { $InstallerType -eq 'wix' }
        Should -Invoke Install-MsixProvisionedPackage -Times 0 -Exactly
        # Timeout-guarded verification is pinned separately below ('passes a 15-second timeout...').
    }

    It 'installs the native MSIX on Windows 24H2+ when no MSI is available' {
        # -1978335216 = NO_APPLICABLE_INSTALLER: the wix (MSI) installer is gone at 7.7+.
        Mock Install-WingetPackage { @{ ExitCode = -1978335216 } } -ParameterFilter { $InstallerType -eq 'wix' }
        Mock Install-WingetPackage { @{ ExitCode = 0 } } -ParameterFilter { -not $InstallerType }
        Mock Get-WindowsBuildNumber { 26100 }
        Mock Test-WingetPackageInstalled { @{ Installed = $true; TimedOut = $false; ExitCode = 0 } }
        Mock Install-MsixProvisionedPackage { throw 'DISM provisioning should not run on 24H2+' }

        $result = Install-PowerShellLatest

        $result.Method | Should -Be 'msix-native'
        $result.Installed | Should -Be $true
        Should -Invoke Install-MsixProvisionedPackage -Times 0 -Exactly
        # Timeout-guarded verification is pinned separately below ('passes a 15-second timeout...').
    }

    It 'provisions the MSIX via DISM on older Windows when no MSI is available' {
        Mock Install-WingetPackage { @{ ExitCode = -1978335216 } }
        Mock Get-WindowsBuildNumber { 19045 }
        Mock Install-MsixProvisionedPackage { @{ ExitCode = 0; Installed = $true } }

        $result = Install-PowerShellLatest

        $result.Method | Should -Be 'msix-provisioned'
        $result.Installed | Should -Be $true
        Should -Invoke Install-MsixProvisionedPackage -Times 1 -Exactly
    }

    It 'passes a 15-second timeout (matching Install-AppWithVerification) to the MSI-path verification call' {
        Mock Install-WingetPackage { @{ ExitCode = 0 } }
        Mock Test-WingetPackageInstalled { @{ Installed = $true; TimedOut = $false; ExitCode = 0 } }
        Mock Install-MsixProvisionedPackage { throw 'DISM provisioning should not run when an MSI is available' }

        [void](Install-PowerShellLatest)

        Should -Invoke Test-WingetPackageInstalled -Times 1 -Exactly -ParameterFilter { $TimeoutSeconds -eq 15 }
    }

    It 'passes a 15-second timeout to the native-MSIX-path verification call' {
        Mock Install-WingetPackage { @{ ExitCode = -1978335216 } } -ParameterFilter { $InstallerType -eq 'wix' }
        Mock Install-WingetPackage { @{ ExitCode = 0 } } -ParameterFilter { -not $InstallerType }
        Mock Get-WindowsBuildNumber { 26100 }
        Mock Test-WingetPackageInstalled { @{ Installed = $true; TimedOut = $false; ExitCode = 0 } }
        Mock Install-MsixProvisionedPackage { throw 'DISM provisioning should not run on 24H2+' }

        [void](Install-PowerShellLatest)

        Should -Invoke Test-WingetPackageInstalled -Times 1 -Exactly -ParameterFilter { $TimeoutSeconds -eq 15 }
    }

    It 'treats a timed-out MSI-path verification as not installed rather than throwing' {
        Mock Install-WingetPackage { @{ ExitCode = 0 } }
        Mock Test-WingetPackageInstalled { @{ Installed = $false; TimedOut = $true; ExitCode = $null } }
        Mock Install-MsixProvisionedPackage { throw 'DISM provisioning should not run when an MSI is available' }

        $result = Install-PowerShellLatest

        $result.Method | Should -Be 'msi'
        $result.Installed | Should -Be $false
    }

    It 'forwards -Silent:<Value> to both winget installs, and leaves it out when not given' -ForEach @(
        @{ Value = $true }
        @{ Value = $false }
    ) {
        Mock Install-WingetPackage { @{ ExitCode = -1978335216 } } -ParameterFilter { $InstallerType -eq 'wix' }
        Mock Install-WingetPackage { @{ ExitCode = 0 } } -ParameterFilter { -not $InstallerType }
        Mock Get-WindowsBuildNumber { 26100 }
        Mock Test-WingetPackageInstalled { @{ Installed = $true; TimedOut = $false; ExitCode = 0 } }
        Mock Install-MsixProvisionedPackage { throw 'DISM provisioning should not run on 24H2+' }

        [void](Install-PowerShellLatest -Silent:$Value)

        $script:expectedSilent = $Value
        Should -Invoke Install-WingetPackage -Times 2 -Exactly -ParameterFilter { $PesterBoundParameters.ContainsKey('Silent') -and [bool]$Silent -eq $script:expectedSilent }

        [void](Install-PowerShellLatest)

        # Not given: Install-WingetPackage decides itself (Test-EffectiveNonInteractive).
        Should -Invoke Install-WingetPackage -Times 2 -Exactly -ParameterFilter { -not $PesterBoundParameters.ContainsKey('Silent') }
    }

    It 'returns a stopped install''s time limit and installer log, so the failure reason names them (review of P2-5/P2-6, <Method>)' -ForEach @(
        @{ Method = 'msi'; WixExitCode = $null }
        @{ Method = 'msix-native'; WixExitCode = -1978335216 }
    ) {
        $script:wixExitCode = $WixExitCode
        $script:logPath = Join-Path $TestDrive 'winget-install-Microsoft.PowerShell-20261004-101500.log'
        Mock Install-WingetPackage {
            if ($InstallerType -eq 'wix' -and $null -ne $script:wixExitCode) {
                return @{ ExitCode = $script:wixExitCode; TimedOut = $false; TimeoutSeconds = 1800; InstallerLogPath = $null }
            }
            @{ ExitCode = $null; Attempts = 1; TimedOut = $true; TimeoutSeconds = 1800; InstallerLogPath = $script:logPath }
        }
        Mock Get-WindowsBuildNumber { 26100 }
        Mock Test-WingetPackageInstalled { @{ Installed = $false; TimedOut = $false; ExitCode = 0 } }
        Mock Install-MsixProvisionedPackage { throw 'DISM provisioning should not run here' }

        $result = Install-PowerShellLatest

        $result.Method | Should -Be $Method
        $result.Installed | Should -Be $false
        $result.TimedOut | Should -Be $true
        $result.TimeoutSeconds | Should -Be 1800
        $result.InstallerLogPath | Should -Be $script:logPath
        $reason = Format-InstallFailureReason -FailureReason 'CustomInstallFailed' -InstallResult $result
        $reason | Should -Match 'winget install stopped after 30 minutes'
        $reason | Should -Match ([regex]::Escape("installer log: $($script:logPath)"))
    }

    It 'returns Install-WingetPackage''s whole result, so PowerShell''s failure reason says why like every other app''s (review finding P3-8)' {
        # The #284 summary read 'Microsoft.PowerShell  installer reported failure' while every other
        # app named its exit code, attempts and launch errors: only ExitCode survived.
        Mock Install-WingetPackage { @{ ExitCode = -2147009255; Attempts = 3; SessionErrorExhausted = $true; MachineScopeFellBack = $false; LaunchErrorExhausted = $false; LaunchAttempts = 0; LaunchError = $null; TimedOut = $false; TimeoutSeconds = 1800; InstallerLogPath = $null } }
        Mock Test-WingetPackageInstalled { @{ Installed = $false; TimedOut = $false; LaunchFailed = $false; LaunchError = $null; ExitCode = -1978335212 } }
        Mock Install-MsixProvisionedPackage { throw 'DISM provisioning should not run when an MSI is available' }

        $result = Install-PowerShellLatest

        $result.Method | Should -Be 'msi'
        $result.Installed | Should -Be $false
        $result.Attempts | Should -Be 3
        $result.SessionErrorExhausted | Should -Be $true
        $result.MachineScopeFellBack | Should -Be $false
        $result.VerifyTimedOut | Should -Be $false
        $result.VerifyLaunchFailed | Should -Be $false
        Format-InstallFailureReason -FailureReason 'CustomInstallFailed' -InstallResult $result |
            Should -Be 'installer reported failure; winget exit 0x80073D19, 3 attempts, machine-scope fallback: no, session error 0x80073D19 persisted through every retry'
    }

    It 'says whether its winget check timed out or could not start winget' {
        Mock Install-WingetPackage { @{ ExitCode = 0; Attempts = 1; MachineScopeFellBack = $false; LaunchErrorExhausted = $false } }
        Mock Install-MsixProvisionedPackage { throw 'DISM provisioning should not run when an MSI is available' }

        Mock Test-WingetPackageInstalled { @{ Installed = $false; TimedOut = $true; LaunchFailed = $false; LaunchError = $null; ExitCode = $null } }
        $timedOut = Install-PowerShellLatest
        $timedOut.VerifyTimedOut | Should -Be $true
        $timedOut.VerifyLaunchFailed | Should -Be $false

        Mock Test-WingetPackageInstalled { @{ Installed = $false; TimedOut = $false; LaunchFailed = $true; LaunchError = 'Access is denied.'; ExitCode = $null } }
        $launchFailed = Install-PowerShellLatest
        $launchFailed.VerifyLaunchFailed | Should -Be $true
        $launchFailed.VerifyLaunchError | Should -Be 'Access is denied.'
        $launchFailed.Installed | Should -Be $false
    }

    It 'skips its winget check when winget could not be launched for the install' {
        Mock Install-WingetPackage { @{ ExitCode = $null; Attempts = 0; LaunchErrorExhausted = $true; LaunchAttempts = 1; LaunchError = 'Access is denied.' } }
        Mock Test-WingetPackageInstalled { throw 'the check must not run: winget did not start for the install' }
        Mock Install-MsixProvisionedPackage { throw 'DISM provisioning should not run when an MSI is available' }

        $result = Install-PowerShellLatest

        $result.Installed | Should -Be $false
        $result.LaunchErrorExhausted | Should -Be $true
        $result.LaunchError | Should -Be 'Access is denied.'
        Should -Invoke Test-WingetPackageInstalled -Times 0 -Exactly
    }
}

Describe 'Install-MsixProvisionedPackage (DISM provisioning, issue #166)' {
    BeforeEach {
        Mock Write-Host { }
        Mock Write-Info { }
        Mock Write-Success { }
        Mock Write-ErrorMessage { }
        Mock New-Item { }
        Mock Remove-Item { }
    }

    It 'downloads, provisions, and verifies the MSIX for all users' {
        Mock Invoke-WingetProcess { New-TestProcessResult -ExitCode 0 }
        Mock Get-ChildItem {
            @(
                [pscustomobject]@{ Name = 'PowerShell-7.7.0-win.msixbundle'; Extension = '.msixbundle'; FullName = 'C:\dl\PowerShell-7.7.0-win.msixbundle' },
                [pscustomobject]@{ Name = 'Microsoft.WindowsAppRuntime.msix'; Extension = '.msix'; FullName = 'C:\dl\Dependencies\Microsoft.WindowsAppRuntime.msix' },
                [pscustomobject]@{ Name = 'PowerShell_License1.xml'; Extension = '.xml'; FullName = 'C:\dl\PowerShell_License1.xml' }
            )
        }
        Mock Invoke-AppxProvisioning { $true }
        Mock Test-AppxPackageProvisioned { $true }

        $result = Install-MsixProvisionedPackage -PackageId 'Microsoft.PowerShell'

        $result.Installed | Should -Be $true
        Should -Invoke Invoke-AppxProvisioning -Times 1 -Exactly -ParameterFilter {
            $PackagePath -like '*PowerShell-7.7.0-win.msixbundle' -and (($DependencyPackagePath -join '') -like '*WindowsAppRuntime*')
        }
        # Time-limited (review finding P2-5): it used to wait with no limit.
        Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter {
            $ArgumentList[0] -eq 'download' -and $TimeoutSeconds -eq (Get-ProcessTimeoutSeconds -Operation WingetDownload)
        }
    }

    It 'returns not-installed when winget download fails' {
        Mock Invoke-WingetProcess { New-TestProcessResult -ExitCode 1 }
        Mock Invoke-AppxProvisioning { throw 'provisioning should not run after a failed download' }

        $result = Install-MsixProvisionedPackage -PackageId 'Microsoft.PowerShell'

        $result.Installed | Should -Be $false
        $result.ExitCode | Should -Be 1
        Should -Invoke Invoke-AppxProvisioning -Times 0 -Exactly
    }

    It 'returns not-installed without provisioning when winget download times out' {
        Mock Invoke-WingetProcess { New-TestProcessResult -TimedOut }
        Mock Invoke-AppxProvisioning { throw 'provisioning should not run after a timed-out download' }

        $result = Install-MsixProvisionedPackage -PackageId 'Microsoft.PowerShell'

        $result.Installed | Should -Be $false
        $result.ExitCode | Should -Be $null
        Should -Invoke Invoke-AppxProvisioning -Times 0 -Exactly
        Should -Invoke Write-ErrorMessage -Times 1 -Exactly -ParameterFilter { $Message -match 'did not finish in time' }
    }

    It 'returns not-installed when no MSIX is found in the download' {
        Mock Invoke-WingetProcess { New-TestProcessResult -ExitCode 0 }
        Mock Get-ChildItem { @() }
        Mock Invoke-AppxProvisioning { throw 'provisioning should not run when no package was found' }

        $result = Install-MsixProvisionedPackage -PackageId 'Microsoft.PowerShell'

        $result.Installed | Should -Be $false
    }
}

Describe 'Invoke-AppxProvisioning (delegated command quoting, issue #178)' {
    # Under pwsh, Invoke-AppxProvisioning delegates to Windows PowerShell 5.1 by string-building
    # an elevated powershell.exe -Command payload. Every path interpolated into that string sits
    # inside a single-quoted literal, so embedded apostrophes must be doubled — otherwise a path
    # like C:\Users\O'Brien\... unbalances the quoting (or breaks out of the literal entirely).
    # These tests mock the powershell.exe invocation boundary and inspect the -Command argument.
    BeforeEach {
        Mock Write-ErrorMessage { }
        $script:capturedCommand = $null
        Mock powershell.exe { $script:capturedCommand = "$($args[-1])"; $global:LASTEXITCODE = 0 }
    }

    It 'escapes an apostrophe in PackagePath by doubling the single quote' {
        [void](Invoke-AppxProvisioning -PackagePath "C:\Users\O'Brien\pkg.msix")

        Should -Invoke powershell.exe -Times 1 -Exactly
        $script:capturedCommand | Should -BeLike "*-PackagePath 'C:\Users\O''Brien\pkg.msix'*"
        $script:capturedCommand | Should -Not -BeLike "*-PackagePath 'C:\Users\O'Brien*"
    }

    It 'escapes apostrophes in every DependencyPackagePath element before joining' {
        [void](Invoke-AppxProvisioning -PackagePath 'C:\dl\pkg.msix' -DependencyPackagePath @(
                "C:\Users\O'Brien\dep1.msix",
                "C:\Users\D'Arcy\dep2.msix"
            ))

        $script:capturedCommand | Should -BeLike "*-DependencyPackagePath @('C:\Users\O''Brien\dep1.msix','C:\Users\D''Arcy\dep2.msix')*"
    }

    It 'escapes an apostrophe in LicensePath' {
        Mock Test-Path { $true }

        [void](Invoke-AppxProvisioning -PackagePath 'C:\dl\pkg.msix' -LicensePath "C:\Users\O'Brien\license.xml")

        $script:capturedCommand | Should -BeLike "*-LicensePath 'C:\Users\O''Brien\license.xml'*"
    }

    It 'leaves apostrophe-free paths unchanged and skips the license when none exists' {
        $result = Invoke-AppxProvisioning -PackagePath 'C:\dl\pkg.msixbundle' -DependencyPackagePath @('C:\dl\Dependencies\runtime.msix')

        $result | Should -Be $true
        $script:capturedCommand | Should -BeLike "*-PackagePath 'C:\dl\pkg.msixbundle' -DependencyPackagePath @('C:\dl\Dependencies\runtime.msix') -SkipLicense*"
    }
}
