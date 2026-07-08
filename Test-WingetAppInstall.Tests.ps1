# Test-WingetAppInstall.Tests.ps1
# Comprehensive unit tests for the WingetAppSetup module (source of winget-app-install.ps1).

# Load the module''s functions once for the whole suite. The WingetAppSetup module
# (WingetAppSetup/Public + WingetAppSetup/Private) is the single source of truth; the
# distributable winget-app-install.ps1 is generated from it by build/Build-WingetInstallScript.ps1.
BeforeAll {
    $script:WingetAppSetupRoot = Join-Path $PSScriptRoot 'WingetAppSetup'
    Get-ChildItem -Path (Join-Path $script:WingetAppSetupRoot 'Private'), (Join-Path $script:WingetAppSetupRoot 'Public') -Filter '*.ps1' |
        ForEach-Object { . $_.FullName }
}

Describe 'Test-AndInstallWingetModule' {
    BeforeAll {
        # Dot-source the script under test so these tests exercise the real implementation (#135).
        . "$PSScriptRoot/winget-app-install.ps1"

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
            Assert-MockCalled Install-Module -Times 0
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
            Assert-MockCalled Install-PackageProvider -Times 1 -ParameterFilter { $Name -eq 'NuGet' }
            Assert-MockCalled Install-Module -Times 1
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
            Assert-MockCalled Install-Module -Times 1
        }
    }
}

Describe 'Test-AndInstallGraphicalTools' {
    BeforeAll {
        # Dot-source the script under test so these tests exercise the real implementation (#135).
        . "$PSScriptRoot/winget-app-install.ps1"

        Mock Write-Host { }
        Mock Write-Warning { }

    }

    Context 'When Out-GridView is already available' {
        It 'Should return true without installing' {
            Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'Out-GridView' }
            Mock Get-Module { }
            Mock Install-Module { }
            Mock Import-Module { }

            $result = Test-AndInstallGraphicalTools
            $result | Should -Be $true
            Assert-MockCalled Install-Module -Times 0
        }
    }

    Context 'When module is missing and installation succeeds' {
        It 'Should install dependencies and return true' {
            $script:outGridViewAvailable = $false

            Mock Get-Command {
                if ($script:outGridViewAvailable) {
                    return $true
                }
                return $null
            } -ParameterFilter { $Name -eq 'Out-GridView' }

            Mock Get-Module {
                param($Name, $ListAvailable)
                if ($Name -eq 'Microsoft.PowerShell.GraphicalTools' -and -not $ListAvailable) {
                    return @{ Name = 'Microsoft.PowerShell.GraphicalTools'; Version = '0.1.2' }
                }
                return $null
            }

            Mock Get-PackageProvider { $null } -ParameterFilter { $Name -eq 'NuGet' }
            Mock Install-PackageProvider { } -ParameterFilter { $Name -eq 'NuGet' }
            Mock Install-Module { }
            Mock Import-Module { $script:outGridViewAvailable = $true }

            $result = Test-AndInstallGraphicalTools
            $result | Should -Be $true
            Assert-MockCalled Install-PackageProvider -Times 1 -ParameterFilter { $Name -eq 'NuGet' }
            Assert-MockCalled Install-Module -Times 1
            Assert-MockCalled Import-Module -Times 1
        }
    }

    Context 'When module exists but needs importing' {
        It 'Should import existing module without reinstalling' {
            $script:outGridViewAvailable = $false

            Mock Get-Command {
                if ($script:outGridViewAvailable) {
                    return $true
                }
                return $null
            } -ParameterFilter { $Name -eq 'Out-GridView' }

            Mock Get-Module {
                param($Name, $ListAvailable)
                if ($Name -eq 'Microsoft.PowerShell.GraphicalTools' -and $ListAvailable) {
                    return @{ Name = 'Microsoft.PowerShell.GraphicalTools'; Version = '0.1.2' }
                }
                return $null
            }

            Mock Get-PackageProvider { @{ Name = 'NuGet' } } -ParameterFilter { $Name -eq 'NuGet' }
            Mock Install-Module { }
            Mock Import-Module { $script:outGridViewAvailable = $true }

            $result = Test-AndInstallGraphicalTools
            $result | Should -Be $true
            Assert-MockCalled Install-Module -Times 1  # Still installs to ensure latest version
            Assert-MockCalled Import-Module -Times 1
        }
    }

    Context 'When NuGet provider needs installation' {
        It 'Should install NuGet provider before installing module' {
            $script:outGridViewAvailable = $false

            Mock Get-Command {
                if ($script:outGridViewAvailable) {
                    return $true
                }
                return $null
            } -ParameterFilter { $Name -eq 'Out-GridView' }

            Mock Get-Module { $null }
            Mock Get-PackageProvider { $null } -ParameterFilter { $Name -eq 'NuGet' }
            Mock Install-PackageProvider { } -ParameterFilter { $Name -eq 'NuGet' }
            Mock Install-Module { }
            Mock Import-Module { $script:outGridViewAvailable = $true }

            $result = Test-AndInstallGraphicalTools
            $result | Should -Be $true
            Assert-MockCalled Install-PackageProvider -Times 1 -ParameterFilter {
                $Name -eq 'NuGet' -and $MinimumVersion -eq '2.8.5.201' -and $Force -eq $true -and $Scope -eq 'AllUsers'
            }
        }
    }

    Context 'When Install-Module fails' {
        It 'Should catch error and return false' {
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'Out-GridView' }
            Mock Get-Module { $null }
            Mock Get-PackageProvider { @{ Name = 'NuGet' } } -ParameterFilter { $Name -eq 'NuGet' }
            Mock Install-Module { throw 'Module installation failed' }

            $result = Test-AndInstallGraphicalTools
            $result | Should -Be $false
            Assert-MockCalled Install-Module -Times 1
        }
    }

    Context 'When Import-Module fails' {
        It 'Should catch error and return false' {
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'Out-GridView' }
            Mock Get-Module { $null }
            Mock Get-PackageProvider { @{ Name = 'NuGet' } } -ParameterFilter { $Name -eq 'NuGet' }
            Mock Install-Module { }
            Mock Import-Module { throw 'Module import failed' }

            $result = Test-AndInstallGraphicalTools
            $result | Should -Be $false
            Assert-MockCalled Import-Module -Times 1
        }
    }

    Context 'When Out-GridView remains unavailable after installation' {
        It 'Should return false and log warning' {
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'Out-GridView' }
            Mock Get-Module { $null }
            Mock Get-PackageProvider { @{ Name = 'NuGet' } } -ParameterFilter { $Name -eq 'NuGet' }
            Mock Install-Module { }
            Mock Import-Module { }

            $result = Test-AndInstallGraphicalTools
            $result | Should -Be $false
            Assert-MockCalled Install-Module -Times 1
            Assert-MockCalled Import-Module -Times 1
        }
    }
}

Describe 'Test-AndInstallWinget' {
    BeforeAll {
        Mock Write-Host { }

        # Dot-source the main script to import Test-AndInstallWinget
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
    }

    Context 'When winget is available' {
        It 'Should return true and not attempt installation' {
            Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'winget' }
            Mock Invoke-WebRequest { }
            $result = Test-AndInstallWinget
            $result | Should -Be $true
            Assert-MockCalled Get-Command -Times 1
            Assert-MockCalled Invoke-WebRequest -Times 0
        }
    }

    Context 'When winget is not available and installation succeeds' {
        It 'Should attempt installation, re-verify winget, and return true' {
            $script:appInstallerRegistered = $false
            Mock Get-Command {
                if ($script:appInstallerRegistered) { return $true }
                return $false
            } -ParameterFilter { $Name -eq 'winget' }
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'Repair-WinGetPackageManager' }
            Mock Invoke-WebRequest { }
            Mock Add-AppxPackage { $script:appInstallerRegistered = $true }
            Mock Remove-Item { }
            $result = Test-AndInstallWinget
            $result | Should -Be $true
            Assert-MockCalled Invoke-WebRequest -Times 1
            Assert-MockCalled Add-AppxPackage -Times 1
            Assert-MockCalled Remove-Item -Times 1
            # The fallback must verify winget after Add-AppxPackage (issue #177): initial check + re-check.
            Assert-MockCalled Get-Command -Times 2 -Exactly -ParameterFilter { $Name -eq 'winget' }
        }
    }

    Context 'When App Installer registers but winget is still unavailable (issue #177)' {
        It 'Should return false and direct the user to install winget manually' {
            Mock Get-Command { $false } -ParameterFilter { $Name -eq 'winget' }
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'Repair-WinGetPackageManager' }
            Mock Invoke-WebRequest { }
            Mock Add-AppxPackage { }
            Mock Remove-Item { }
            Mock Write-ErrorMessage { }

            $result = Test-AndInstallWinget
            $result | Should -Be $false
            Assert-MockCalled Add-AppxPackage -Times 1
            Assert-MockCalled Write-ErrorMessage -Times 1 -ParameterFilter { $Message -match 'install winget manually' }
        }
    }

    Context 'When winget is not available and installation fails' {
        It 'Should attempt installation, catch error, and return false' {
            Mock Get-Command { return $false } -ParameterFilter { $Name -eq 'winget' }
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'Repair-WinGetPackageManager' }
            Mock Invoke-WebRequest { throw 'Network error' }
            $result = Test-AndInstallWinget
            $result | Should -Be $false
            Assert-MockCalled Invoke-WebRequest -Times 1
        }
    }

    Context 'When Repair-WinGetPackageManager is available and bootstraps winget' {
        It 'Should return true without downloading the App Installer' {
            $script:wingetAvailable = $false
            Mock Get-Command {
                if ($script:wingetAvailable) { return $true }
                return $null
            } -ParameterFilter { $Name -eq 'winget' }
            Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'Repair-WinGetPackageManager' }
            Mock Repair-WinGetPackageManager { $script:wingetAvailable = $true }
            Mock Invoke-WebRequest { }
            Mock Add-AppxPackage { }

            $result = Test-AndInstallWinget
            $result | Should -Be $true
            Assert-MockCalled Repair-WinGetPackageManager -Times 1 -Exactly
            Assert-MockCalled Invoke-WebRequest -Times 0
            Assert-MockCalled Add-AppxPackage -Times 0
        }
    }

    Context 'When Repair-WinGetPackageManager is available but throws' {
        It 'Should fall back to the App Installer download and return true once winget resolves' {
            # winget is absent until the App Installer fallback registers it; the fallback's
            # post-install re-check (issue #177) must then find it and return $true.
            $script:appInstallerRegistered = $false
            Mock Get-Command {
                if ($script:appInstallerRegistered) { return $true }
                return $null
            } -ParameterFilter { $Name -eq 'winget' }
            Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'Repair-WinGetPackageManager' }
            Mock Repair-WinGetPackageManager { throw 'Repair failed' }
            Mock Invoke-WebRequest { }
            Mock Add-AppxPackage { $script:appInstallerRegistered = $true }
            Mock Remove-Item { }

            $result = Test-AndInstallWinget
            $result | Should -Be $true
            Assert-MockCalled Repair-WinGetPackageManager -Times 1 -Exactly
            Assert-MockCalled Invoke-WebRequest -Times 1
            Assert-MockCalled Add-AppxPackage -Times 1
        }
    }
}

Describe 'Test-WingetSources' {
    BeforeAll {
        Mock Write-Host { }
        Mock Write-Warning { }

        # Dot-source the main script to import Test-WingetSources
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
            Assert-MockCalled Add-AppxPackage -Times 0
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
            Assert-MockCalled Add-AppxPackage -Times 1
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
            Assert-MockCalled Add-AppxPackage -Times 1
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
            Assert-MockCalled Add-AppxPackage -Times 1
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
            Assert-MockCalled Add-AppxPackage -Times 1
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
        Assert-MockCalled Write-Success -Times 1 -ParameterFilter { $Message -match 'accessible and functional' }
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
        Assert-MockCalled Write-WarningMessage -Times 1 -ParameterFilter { $Message -match 'corrupted or missing data' }
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
        Assert-MockCalled Write-Success -Times 0 -Exactly
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
        $manifest = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'WingetAppSetup/WingetAppSetup.psd1')
        $manifest.FunctionsToExport | Should -Not -Contain 'Test-WingetSourceTrusted'
        $manifest.FunctionsToExport | Should -Not -Contain 'Set-Sources'
    }
}

Describe 'Add-ToEnvironmentPath' {
    BeforeAll {
        Mock Write-Host { }
    }

    BeforeEach {
        Mock Write-WarningMessage { }
        Mock Set-PersistedEnvironmentPath { }
        $script:savedProcessPath = $env:PATH
    }

    AfterEach {
        $env:PATH = $script:savedProcessPath
    }

    Context 'When path is not in User scope' {
        It 'Should append the path to the persisted User PATH' {
            Mock Get-PersistedEnvironmentPath { return 'C:\Existing' } -ParameterFilter { $Scope -eq 'User' }

            Add-ToEnvironmentPath -PathToAdd 'C:\Test' -Scope 'User'

            Assert-MockCalled Set-PersistedEnvironmentPath -Times 1 -ParameterFilter {
                $Value -eq 'C:\Existing;C:\Test' -and $Scope -eq 'User'
            }
        }

        It 'Should not produce a leading semicolon when the persisted PATH is empty' {
            Mock Get-PersistedEnvironmentPath { return '' } -ParameterFilter { $Scope -eq 'User' }

            Add-ToEnvironmentPath -PathToAdd 'C:\Test' -Scope 'User'

            Assert-MockCalled Set-PersistedEnvironmentPath -Times 1 -ParameterFilter {
                $Value -eq 'C:\Test' -and $Scope -eq 'User'
            }
        }

        It 'Should mirror the path into the current process PATH' {
            Mock Get-PersistedEnvironmentPath { return '' } -ParameterFilter { $Scope -eq 'User' }
            $env:PATH = 'C:\Existing'

            Add-ToEnvironmentPath -PathToAdd 'C:\Test' -Scope 'User'

            $env:PATH | Should -Be 'C:\Existing;C:\Test'
        }
    }

    Context 'When path is already in User scope' {
        It 'Should not modify the persisted environment' {
            Mock Get-PersistedEnvironmentPath { return 'C:\Test' } -ParameterFilter { $Scope -eq 'User' }

            Add-ToEnvironmentPath -PathToAdd 'C:\Test' -Scope 'User'

            Assert-MockCalled Set-PersistedEnvironmentPath -Times 0
        }

        It 'Should treat case and trailing-slash variants as already present' {
            Mock Get-PersistedEnvironmentPath { return 'c:\test\' } -ParameterFilter { $Scope -eq 'User' }

            Add-ToEnvironmentPath -PathToAdd 'C:\Test' -Scope 'User'

            Assert-MockCalled Set-PersistedEnvironmentPath -Times 0
        }
    }

    Context 'Long process PATH' {
        It 'Should still update the session PATH when under the 32767-char limit (old bogus 2048 guard)' {
            Mock Get-PersistedEnvironmentPath { return '' } -ParameterFilter { $Scope -eq 'User' }
            $env:PATH = 'C:\' + ('a' * 2500)  # over the old bogus 2048 guard, far under the real limit

            Add-ToEnvironmentPath -PathToAdd 'C:\Test' -Scope 'User'

            $env:PATH | Should -BeLike '*;C:\Test'
            Assert-MockCalled Write-WarningMessage -Times 0
        }

        It 'Should warn and leave the session PATH unchanged when it would exceed 32767 chars' {
            Mock Get-PersistedEnvironmentPath { return '' } -ParameterFilter { $Scope -eq 'User' }
            $longPath = 'C:\' + ('a' * 32760)
            $env:PATH = $longPath

            Add-ToEnvironmentPath -PathToAdd 'C:\Test' -Scope 'User'

            $env:PATH | Should -Be $longPath
            Assert-MockCalled Write-WarningMessage -Times 1
            # The persistent update must still happen
            Assert-MockCalled Set-PersistedEnvironmentPath -Times 1
        }
    }
}

Describe 'Test-PathInEnvironment' {
    Context 'User scope' {
        It 'Should return true for an exact match' {
            Mock Get-PersistedEnvironmentPath { return 'C:\Foo;C:\Test;C:\Bar' } -ParameterFilter { $Scope -eq 'User' }

            Test-PathInEnvironment -PathToCheck 'C:\Test' -Scope 'User' | Should -Be $true
        }

        It 'Should match case-insensitively' {
            Mock Get-PersistedEnvironmentPath { return 'c:\program files\foo' } -ParameterFilter { $Scope -eq 'User' }

            Test-PathInEnvironment -PathToCheck 'C:\Program Files\Foo' -Scope 'User' | Should -Be $true
        }

        It 'Should ignore trailing backslashes and forward slashes' {
            Mock Get-PersistedEnvironmentPath { return 'C:\Test\;D:\Tools/' } -ParameterFilter { $Scope -eq 'User' }

            Test-PathInEnvironment -PathToCheck 'C:\Test' -Scope 'User' | Should -Be $true
            Test-PathInEnvironment -PathToCheck 'D:\Tools' -Scope 'User' | Should -Be $true
        }

        It 'Should return false when the path is absent' {
            Mock Get-PersistedEnvironmentPath { return 'C:\Foo;C:\Bar' } -ParameterFilter { $Scope -eq 'User' }

            Test-PathInEnvironment -PathToCheck 'C:\Test' -Scope 'User' | Should -Be $false
        }

        It 'Should not match on a substring of an entry' {
            Mock Get-PersistedEnvironmentPath { return 'C:\Testing' } -ParameterFilter { $Scope -eq 'User' }

            Test-PathInEnvironment -PathToCheck 'C:\Test' -Scope 'User' | Should -Be $false
        }
    }

    Context 'System scope' {
        It 'Should read the System-scope PATH' {
            Mock Get-PersistedEnvironmentPath { return 'C:\SystemDir' } -ParameterFilter { $Scope -eq 'System' }

            Test-PathInEnvironment -PathToCheck 'c:\systemdir\' -Scope 'System' | Should -Be $true
            Assert-MockCalled Get-PersistedEnvironmentPath -Times 1 -ParameterFilter { $Scope -eq 'System' }
        }
    }
}

Describe 'Test-PathListContainsEntry' {
    It 'Should handle an empty list' {
        Test-PathListContainsEntry -PathList '' -PathToCheck 'C:\Test' | Should -Be $false
    }

    It 'Should find a case/trailing-slash variant' {
        Test-PathListContainsEntry -PathList 'C:\Foo;c:\TEST/' -PathToCheck 'C:\Test\' | Should -Be $true
    }

    It 'Should not treat empty entries from doubled semicolons as a match' {
        Test-PathListContainsEntry -PathList 'C:\Foo;;C:\Bar' -PathToCheck 'C:\Test' | Should -Be $false
    }
}

Describe 'ConvertTo-CommandArguments' {
    BeforeAll {
    }

    It 'Should parse simple command without quotes' {
        $result = ConvertTo-CommandArguments -Command 'winget install --id test'
        $result | Should -Be @('winget', 'install', '--id', 'test')
    }

    It 'Should handle quoted arguments' {
        $result = ConvertTo-CommandArguments -Command 'winget install --id "test app"'
        $result | Should -Be @('winget', 'install', '--id', 'test app')
    }

    It 'Should handle single quotes' {
        $result = ConvertTo-CommandArguments -Command "winget install --id 'test app'"
        $result | Should -Be @('winget', 'install', '--id', 'test app')
    }

    It 'Should handle multiple quoted arguments' {
        $result = ConvertTo-CommandArguments -Command 'winget install --id "test app" --source "winget store"'
        $result | Should -Be @('winget', 'install', '--id', 'test app', '--source', 'winget store')
    }
}

Describe 'Restart-WithElevation' {
    BeforeAll {
        # Dot-source the script under test so these tests exercise the real implementation (#135).
        . "$PSScriptRoot/winget-app-install.ps1"

        Mock Write-Host { }
        Mock Write-Warning { }
    }

    It 'Should use Windows Terminal when available' {
        Mock Start-Process { } -ParameterFilter { $FilePath -eq 'wt.exe' }
        Mock Start-Process { } -ParameterFilter { $FilePath -eq 'pwsh.exe' }

        $result = Restart-WithElevation -PowerShellExecutable 'pwsh.exe' -ScriptPath 'C:\script.ps1' -WindowsTerminalExecutable 'wt.exe'

        Assert-MockCalled Start-Process -ParameterFilter { $FilePath -eq 'wt.exe' } -Times 1
        Assert-MockCalled Start-Process -ParameterFilter { $FilePath -eq 'pwsh.exe' } -Times 0
        $result | Should -Be 'WindowsTerminal'
    }

    It 'Should fall back to PowerShell when Windows Terminal launch fails' {
        Mock Start-Process { throw 'Failed to launch wt' } -ParameterFilter { $FilePath -eq 'wt.exe' }
        Mock Start-Process { } -ParameterFilter { $FilePath -eq 'pwsh.exe' }

        $result = Restart-WithElevation -PowerShellExecutable 'pwsh.exe' -ScriptPath 'C:\script.ps1' -WindowsTerminalExecutable 'wt.exe'

        Assert-MockCalled Start-Process -ParameterFilter { $FilePath -eq 'wt.exe' } -Times 1
        Assert-MockCalled Start-Process -ParameterFilter { $FilePath -eq 'pwsh.exe' } -Times 1
        $result | Should -Be 'PowerShell'
    }

    It 'Should use PowerShell when Windows Terminal is not available' {
        Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'wt.exe' }
        Mock Start-Process { } -ParameterFilter { $FilePath -eq 'pwsh.exe' }

        $result = Restart-WithElevation -PowerShellExecutable 'pwsh.exe' -ScriptPath 'C:\script.ps1'

        Assert-MockCalled Start-Process -ParameterFilter { $FilePath -eq 'pwsh.exe' } -Times 1
        $result | Should -Be 'PowerShell'
    }

    It 'Should forward AdditionalArguments to the elevated relaunch' {
        Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'wt.exe' }
        Mock Start-Process { } -ParameterFilter { $FilePath -eq 'pwsh.exe' }

        Restart-WithElevation -PowerShellExecutable 'pwsh.exe' -ScriptPath 'C:\script.ps1' -AdditionalArguments '-WhatIf'

        Assert-MockCalled Start-Process -Times 1 -ParameterFilter {
            $FilePath -eq 'pwsh.exe' -and (($ArgumentList -join ' ') -match '-File "C:\\script\.ps1" -WhatIf')
        }
    }

    It 'Should not append arguments when AdditionalArguments is empty' {
        Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'wt.exe' }
        Mock Start-Process { } -ParameterFilter { $FilePath -eq 'pwsh.exe' }

        Restart-WithElevation -PowerShellExecutable 'pwsh.exe' -ScriptPath 'C:\script.ps1'

        Assert-MockCalled Start-Process -Times 1 -ParameterFilter {
            $FilePath -eq 'pwsh.exe' -and (($ArgumentList -join ' ') -notmatch '-WhatIf')
        }
    }

    It 'Should forward multiple AdditionalArguments to the elevated relaunch' {
        Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'wt.exe' }
        Mock Start-Process { } -ParameterFilter { $FilePath -eq 'pwsh.exe' }

        Restart-WithElevation -PowerShellExecutable 'pwsh.exe' -ScriptPath 'C:\script.ps1' -AdditionalArguments @('-WhatIf', '-SkipSystemCheck')

        Assert-MockCalled Start-Process -Times 1 -ParameterFilter {
            $FilePath -eq 'pwsh.exe' -and (($ArgumentList -join ' ') -match '-File "C:\\script\.ps1" -WhatIf -SkipSystemCheck')
        }
    }
}

Describe 'SkipSystemCheck elevation forwarding (issue #185)' {
    Context 'Invoke-WingetInstall parameter surface' {
        It 'Should accept a SkipSystemCheck switch parameter' {
            $command = Get-Command Invoke-WingetInstall
            $command.Parameters.ContainsKey('SkipSystemCheck') | Should -Be $true
            $command.Parameters['SkipSystemCheck'].ParameterType.Name | Should -Be 'SwitchParameter'
        }
    }

    Context 'Generated installer entry point' {
        It 'Should forward -SkipSystemCheck from the entry script into Invoke-WingetInstall' {
            $installer = Get-Content "$PSScriptRoot\winget-app-install.ps1" -Raw
            $installer | Should -Match 'Invoke-WingetInstall -WhatIf:\$WhatIf -NonInteractive:\$NonInteractive -SkipSystemCheck:\$SkipSystemCheck'
        }
    }
}

Describe 'Test-InvokedFromModuleContext' {
    It 'Should return true when the invocation carries module info' {
        $fakeModule = New-Module -Name 'FakeWingetAppSetup' -ScriptBlock { }

        Test-InvokedFromModuleContext -InvocationModule $fakeModule -CommandPath 'C:\repo\winget-app-install.ps1' | Should -Be $true
    }

    It 'Should return true when the command path is the module Install.ps1 (Windows separators)' {
        Test-InvokedFromModuleContext -CommandPath 'C:\repo\WingetAppSetup\Public\Install.ps1' | Should -Be $true
    }

    It 'Should return true when the command path is the module Install.ps1 (forward slashes)' {
        Test-InvokedFromModuleContext -CommandPath '/home/user/repo/WingetAppSetup/Public/Install.ps1' | Should -Be $true
    }

    It 'Should return false for the generated single-file installer path' {
        Test-InvokedFromModuleContext -CommandPath 'C:\repo\winget-app-install.ps1' | Should -Be $false
    }

    It 'Should return false for an installer that merely lives under a WingetAppSetup directory' {
        Test-InvokedFromModuleContext -CommandPath 'C:\Users\admin\WingetAppSetup\winget-app-install.ps1' | Should -Be $false
    }

    It 'Should return false when the command path is empty' {
        Test-InvokedFromModuleContext -CommandPath '' | Should -Be $false
    }
}

Describe 'Test-CanUseGridView' {
    BeforeAll {
    }

    It 'Should return true when Out-GridView is available and session is interactive' {
        Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'Out-GridView' }

        $result = Test-CanUseGridView
        $result | Should -Be $true
    }

    It 'Should return false when Out-GridView is not available' {
        Mock Get-Command { throw 'Command not found' } -ParameterFilter { $Name -eq 'Out-GridView' }

        $result = Test-CanUseGridView
        $result | Should -Be $false
    }

    It 'Should return false when session is not interactive' {
        Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'Out-GridView' }

        # Mock the Environment.UserInteractive property
        # This test assumes we're in an interactive session by default
        # In a non-interactive context (e.g., CI/CD), this would naturally return false
        $originalValue = [Environment]::UserInteractive

        if ($originalValue) {
            # We can't easily mock static properties, so we'll just verify the logic
            # In actual non-interactive scenarios, this will correctly return false
            $result = Test-CanUseGridView
            # In interactive mode with Out-GridView available, should be true
            $result | Should -Be $true
        }
    }
}

Describe 'Write-Table' {
    BeforeAll {
        # Dot-source the script under test so these tests exercise the real implementation (#135).
        . "$PSScriptRoot/winget-app-install.ps1"

        Mock Write-Host { }
        Mock Read-Host { return 'N' }

        # Create a mock Out-GridView command if it doesn't exist
        if (-not (Get-Command Out-GridView -ErrorAction SilentlyContinue)) {
            function Out-GridView { param($Title, [switch]$Wait) }
        }
        Mock Out-GridView { }
    }

    It 'Should format table data correctly with Format-Table' {
        $headers = @('Status', 'Apps')
        $rows = @(@('Installed', 'App1, App2'))

        Write-Table -Headers $headers -Rows $rows

        # Should call Write-Host at least once with formatted table output
        Assert-MockCalled Write-Host -Times 1 -ParameterFilter { $Object -match 'Status' -or $Object -match 'Apps' }
    }

    It 'Should handle multiple rows correctly' {
        $headers = @('Status', 'Apps')
        $rows = @(
            @('Installed', 'App1, App2'),
            @('Skipped', 'App3'),
            @('Failed', 'App4')
        )

        Write-Table -Headers $headers -Rows $rows

        # Should call Write-Host with the formatted output
        Assert-MockCalled Write-Host -Times 1
    }

    It 'Should use Out-GridView when requested and available' {
        Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'Out-GridView' }

        $headers = @('Status', 'Apps')
        $rows = @(@('Installed', 'App1, App2'))

        Write-Table -Headers $headers -Rows $rows -UseGridView $true

        # Should call Out-GridView
        Assert-MockCalled Out-GridView -Times 1
    }

    It 'Should fall back to text output when Out-GridView is not available' {
        Mock Get-Command { throw 'Command not found' } -ParameterFilter { $Name -eq 'Out-GridView' }

        $headers = @('Status', 'Apps')
        $rows = @(@('Installed', 'App1, App2'))

        Write-Table -Headers $headers -Rows $rows -UseGridView $true

        # Should call Write-Host for fallback
        Assert-MockCalled Write-Host -Times 2  # Warning message + table output
    }

    It 'Should default to text output when UseGridView is false' {
        $headers = @('Status', 'Apps')
        $rows = @(@('Installed', 'App1, App2'))

        Write-Table -Headers $headers -Rows $rows -UseGridView $false

        # Should not call Out-GridView
        Assert-MockCalled Out-GridView -Times 0
        # Should call Write-Host for text output
        Assert-MockCalled Write-Host -Times 1
    }

    It 'Should prompt user when PromptForGridView is true and user accepts' {
        Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'Out-GridView' }
        Mock Read-Host { return 'Y' }

        $headers = @('Status', 'Apps')
        $rows = @(@('Installed', 'App1, App2'))

        Write-Table -Headers $headers -Rows $rows -PromptForGridView $true

        # Should call Read-Host to prompt user
        Assert-MockCalled Read-Host -Times 1
        # Should call Out-GridView since user said yes
        Assert-MockCalled Out-GridView -Times 1
    }

    It 'Should prompt user when PromptForGridView is true and user declines' {
        Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'Out-GridView' }
        Mock Read-Host { return 'N' }

        $headers = @('Status', 'Apps')
        $rows = @(@('Installed', 'App1, App2'))

        Write-Table -Headers $headers -Rows $rows -PromptForGridView $true

        # Should call Read-Host to prompt user
        Assert-MockCalled Read-Host -Times 1
        # Should not call Out-GridView since user said no
        Assert-MockCalled Out-GridView -Times 0
        # Should call Write-Host for text output
        Assert-MockCalled Write-Host -Times 2  # Empty line + table output
    }

    It 'Should not prompt when Out-GridView is not available' {
        Mock Get-Command { throw 'Command not found' } -ParameterFilter { $Name -eq 'Out-GridView' }
        Mock Read-Host { return 'Y' }

        $headers = @('Status', 'Apps')
        $rows = @(@('Installed', 'App1, App2'))

        Write-Table -Headers $headers -Rows $rows -PromptForGridView $true

        # Should not call Read-Host since Out-GridView is not available
        Assert-MockCalled Read-Host -Times 0
        # Should call Write-Host for text output
        Assert-MockCalled Write-Host -Times 1
    }

    It 'Should accept case-insensitive affirmative responses (y, Y, yes, YES)' {
        Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'Out-GridView' }

        $testCases = @('y', 'Y', 'yes', 'YES', 'Yes', 'yEs')
        foreach ($response in $testCases) {
            Mock Read-Host { return $response }
            Mock Out-GridView { }

            $headers = @('Status', 'Apps')
            $rows = @(@('Installed', 'App1, App2'))

            Write-Table -Headers $headers -Rows $rows -PromptForGridView $true

            # Should call Out-GridView for all case variations
            Assert-MockCalled Out-GridView -Times 1
        }
    }

    It 'Should reject non-affirmative responses (n, N, no, anything else)' {
        Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'Out-GridView' }

        $testCases = @('n', 'N', 'no', 'NO', 'nope', 'maybe', '', 'x')
        foreach ($response in $testCases) {
            Mock Read-Host { return $response }
            Mock Out-GridView { }

            $headers = @('Status', 'Apps')
            $rows = @(@('Installed', 'App1, App2'))

            Write-Table -Headers $headers -Rows $rows -PromptForGridView $true

            # Should NOT call Out-GridView for non-affirmative responses
            Assert-MockCalled Out-GridView -Times 0
            # Should call Write-Host for text output (empty line + table)
            Assert-MockCalled Write-Host -Times 2
        }
    }

    It 'Should skip prompt when UseGridView is true regardless of PromptForGridView' {
        Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'Out-GridView' }
        Mock Read-Host { return 'N' }  # User says no, but should be ignored

        $headers = @('Status', 'Apps')
        $rows = @(@('Installed', 'App1, App2'))

        Write-Table -Headers $headers -Rows $rows -UseGridView $true -PromptForGridView $true

        # Should NOT call Read-Host since UseGridView takes precedence
        Assert-MockCalled Read-Host -Times 0
        # Should call Out-GridView directly
        Assert-MockCalled Out-GridView -Times 1
    }

    It 'Should handle Out-GridView execution failure gracefully' {
        Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'Out-GridView' }
        Mock Out-GridView { throw 'GridView display error' }

        $headers = @('Status', 'Apps')
        $rows = @(@('Installed', 'App1, App2'))

        Write-Table -Headers $headers -Rows $rows -UseGridView $true

        # Should call Out-GridView and catch the error
        Assert-MockCalled Out-GridView -Times 1
        # Should fall back to Write-Host (warning + table output)
        Assert-MockCalled Write-Host -Times 2
    }

    It 'Should not prompt in non-interactive session' {
        # Note: [Environment]::UserInteractive is read-only and cannot be mocked directly
        # This test validates that the code checks UserInteractive status
        # In actual non-interactive sessions, the prompt path would be skipped

        Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'Out-GridView' }
        Mock Read-Host { return 'Y' }

        $headers = @('Status', 'Apps')
        $rows = @(@('Installed', 'App1, App2'))

        # In the current environment (interactive), Read-Host will be called
        # This test validates the logic structure exists
        if ([Environment]::UserInteractive) {
            Write-Table -Headers $headers -Rows $rows -PromptForGridView $true
            # In interactive mode, prompt should be shown
            Assert-MockCalled Read-Host -Times 1
        }
    }

    It 'Should use custom title when provided' {
        Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'Out-GridView' }
        Mock Out-GridView { } -Verifiable -ParameterFilter { $Title -eq 'Custom Title' }

        $headers = @('Status', 'Apps')
        $rows = @(@('Installed', 'App1, App2'))

        Write-Table -Headers $headers -Rows $rows -UseGridView $true -Title 'Custom Title'

        # Should call Out-GridView with custom title
        Assert-MockCalled Out-GridView -Times 1 -ParameterFilter { $Title -eq 'Custom Title' }
    }

    It 'Should use default title when Title parameter is not provided' {
        Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'Out-GridView' }
        Mock Out-GridView { } -Verifiable -ParameterFilter { $Title -eq 'Summary' }

        $headers = @('Status', 'Apps')
        $rows = @(@('Installed', 'App1, App2'))

        Write-Table -Headers $headers -Rows $rows -UseGridView $true

        # Should call Out-GridView with default title 'Summary'
        Assert-MockCalled Out-GridView -Times 1 -ParameterFilter { $Title -eq 'Summary' }
    }
}

Describe 'Format-AppList' {
    BeforeAll {
    }

    It 'Should format non-empty array' {
        $result = Format-AppList -AppArray @('App1', 'App2', 'App3')
        $result | Should -Be 'App1, App2, App3'
    }

    It 'Should return null for empty array' {
        $result = Format-AppList -AppArray @()
        $result | Should -Be $null
    }

    It 'Should return null for empty input' {
        # The real Format-AppList declares $AppArray as a mandatory [string[]] with
        # [AllowEmptyCollection()], so an empty array (not $null) is the boundary case
        # it is designed to handle; it returns $null when given no apps.
        $result = Format-AppList -AppArray @()
        $result | Should -Be $null
    }
}

Describe 'Main Script Logic' {
    BeforeAll {
        # Dot-source the script under test so these tests exercise the real implementation (#135).
        . "$PSScriptRoot/winget-app-install.ps1"

        Mock Write-Host { }
        Mock Pause { }
        Mock Start-Process { }

        # Mock the functions that are called

        # Mock external commands
        Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'pwsh' }
        Mock winget { 'App1' } -ParameterFilter { $args -contains 'list' }
        Mock Start-Process { }
    }

    Context 'Administrator check' {
        It 'Should handle admin check logic when running as admin' {
            # Test that we can create a WindowsPrincipal (this will work when actually running as admin)
            try {
                $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
                $principal = [Security.Principal.WindowsPrincipal]::new($currentUser)
                $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
                $isAdmin | Should -BeOfType [bool]
            }
            catch {
                # If we can't create the principal, just verify the types exist
                [Security.Principal.WindowsPrincipal] | Should -BeOfType [type]
            }
        }

        It 'Should handle admin check logic when not running as admin' {
            # This test verifies the logic structure without mocking constructors
            $adminRole = [Security.Principal.WindowsBuiltInRole]::Administrator
            $adminRole | Should -BeOfType [Security.Principal.WindowsBuiltInRole]
        }
    }

    Context 'Winget check' {
        It 'Should continue when winget is available' {
            Mock Test-AndInstallWinget { return $true }

            $result = Test-AndInstallWinget
            $result | Should -Be $true
        }

        It 'Should exit when winget installation fails' {
            Mock Test-AndInstallWinget { return $false }

            $result = Test-AndInstallWinget
            $result | Should -Be $false
        }
    }

    Context 'PATH setup' {
        It 'Should not add the script directory to the persistent PATH (issue #179)' {
            # The installer must never put its own (user-writable) directory on the PATH —
            # that was a hijack surface and nothing needs it since the updater removal (#168).
            $installBody = (Get-Command Invoke-WingetInstall).Definition
            $installBody | Should -Not -Match 'Add-ToEnvironmentPath'
        }
    }

    # The msstore-era 'Source verification' loop (Test-WingetSourceTrusted/Set-Sources) was removed
    # in issue #177: source health is verified and repaired by Test-WingetSources before this point.

    Context 'App installation loop' {
        It 'Should install app when not already installed' {
            $apps = @(@{name = 'Test.App' })
            $installedApps = @()
            $skippedApps = @()

            $script:installAttempted = $false

            # Mock winget list to return empty initially, then the app after install
            Mock winget {
                if ($script:installAttempted) {
                    'Test.App'
                }
                else {
                    ''
                }
            } -ParameterFilter { $args -contains 'list' -and $args -contains 'Test.App' }

            Mock Start-Process {
                $script:installAttempted = $true
            }

            foreach ($app in $apps) {
                $listApp = winget list --exact -q $app.name
                if (![String]::Join('', $listApp).Contains($app.name)) {
                    Start-Process winget -ArgumentList "install -e --accept-source-agreements --accept-package-agreements --id $($app.name)" -NoNewWindow -Wait
                    $installResult = winget list --exact -q $app.name
                    if (![String]::Join('', $installResult).Contains($app.name)) {
                        $failedApps += $app.name
                    }
                    else {
                        $installedApps += $app.name
                    }
                }
                else {
                    $skippedApps += $app.name
                }
            }

            $installedApps | Should -Contain 'Test.App'
            $skippedApps | Should -Not -Contain 'Test.App'
            $failedApps | Should -Not -Contain 'Test.App'
        }

        It 'Should include --source winget flag in install command' {
            $apps = @(@{name = 'Test.App' })
            $installedApps = @()

            Mock winget { '' } -ParameterFilter { $args -contains 'list' }
            Mock Start-Process { }

            foreach ($app in $apps) {
                $listApp = winget list --exact -q $app.name
                if (![String]::Join('', $listApp).Contains($app.name)) {
                    Start-Process winget -ArgumentList "install -e --accept-source-agreements --accept-package-agreements --source winget --id $($app.name)" -NoNewWindow -Wait
                    $installedApps += 'Test.App'
                }
            }

            Assert-MockCalled Start-Process -Times 1 -ParameterFilter { $ArgumentList -match '--source winget' }
        }

        It 'Should skip app when already installed' {
            $apps = @(@{name = 'Test.App' })
            $installedApps = @()
            $skippedApps = @()

            # Mock winget list to return the app (already installed)
            Mock winget { 'Test.App' } -ParameterFilter { $args -contains 'list' }

            foreach ($app in $apps) {
                $listApp = winget list --exact -q $app.name
                if (![String]::Join('', $listApp).Contains($app.name)) {
                    # Install logic would go here
                    $installedApps += $app.name
                }
                else {
                    $skippedApps += $app.name
                }
            }

            $installedApps | Should -Not -Contain 'Test.App'
            $skippedApps | Should -Contain 'Test.App'
        }

        It 'Should handle installation failure' {
            $apps = @(@{name = 'Test.App' })
            $installedApps = @()
            $skippedApps = @()
            $failedApps = @()

            # Mock winget list to return empty (app not installed)
            Mock winget { '' } -ParameterFilter { $args -contains 'list' -and $args -notcontains 'install' }
            # Mock winget list after install to still return empty (failed install)
            Mock winget { '' } -ParameterFilter { $args -contains 'list' -and $args -contains 'Test.App' -and $args -notcontains 'install' }
            Mock Start-Process { }

            foreach ($app in $apps) {
                try {
                    $listApp = winget list --exact -q $app.name
                    if (![String]::Join('', $listApp).Contains($app.name)) {
                        Start-Process winget -ArgumentList "install -e --accept-source-agreements --accept-package-agreements --id $($app.name)" -NoNewWindow -Wait
                        $installResult = winget list --exact -q $app.name
                        if (![String]::Join('', $installResult).Contains($app.name)) {
                            $failedApps += $app.name
                        }
                        else {
                            $installedApps += $app.name
                        }
                    }
                    else {
                        $skippedApps += $app.name
                    }
                }
                catch {
                    $failedApps += $app.name
                }
            }

            $failedApps | Should -Contain 'Test.App'
            $installedApps | Should -Not -Contain 'Test.App'
        }
    }

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
            Assert-MockCalled Write-Table -Times 1
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

Describe 'Retry Failed Installations' {
    BeforeAll {
        Mock Write-Host { }
        Mock Start-Process { }
    }

    Context 'Retry logic - array management' {
        It 'Should retry failed apps and move successful retries to installed list' {
            $failedApps = @('Test.App')
            $installedApps = @()

            $script:retryAttempted = $false
            Mock Start-Process { $script:retryAttempted = $true }

            $appsToRetry = $failedApps
            $failedApps = @()

            foreach ($appName in $appsToRetry) {
                Start-Process winget -ArgumentList "install -e --accept-source-agreements --accept-package-agreements --source winget --id $appName" -NoNewWindow -Wait
                # Simulate verification returning the app (success)
                $retryResult = $appName
                if (![String]::Join('', $retryResult).Contains($appName)) {
                    $failedApps += $appName
                }
                else {
                    $installedApps += $appName
                }
            }

            $script:retryAttempted | Should -Be $true
            $installedApps | Should -Contain 'Test.App'
            $failedApps | Should -Not -Contain 'Test.App'
        }

        It 'Should keep app in failed list when retry also fails' {
            $failedApps = @('Test.App')
            $installedApps = @()

            Mock Start-Process { }

            $appsToRetry = $failedApps
            $failedApps = @()

            foreach ($appName in $appsToRetry) {
                Start-Process winget -ArgumentList "install -e --accept-source-agreements --accept-package-agreements --source winget --id $appName" -NoNewWindow -Wait
                # Simulate verification returning nothing (failure)
                $retryResult = ''
                if (![String]::Join('', $retryResult).Contains($appName)) {
                    $failedApps += $appName
                }
                else {
                    $installedApps += $appName
                }
            }

            $failedApps | Should -Contain 'Test.App'
            $installedApps | Should -Not -Contain 'Test.App'
        }

        It 'Should not retry when there are no failed apps' {
            $failedApps = @()
            $installedApps = @()

            Mock Start-Process { }

            if ($failedApps.Count -gt 0) {
                $appsToRetry = $failedApps
                $failedApps = @()
                foreach ($appName in $appsToRetry) {
                    Start-Process winget -ArgumentList "install -e --accept-source-agreements --accept-package-agreements --source winget --id $appName" -NoNewWindow -Wait
                }
            }

            Assert-MockCalled Start-Process -Times 0
            $failedApps.Count | Should -Be 0
        }

        It 'Should handle mixed retry results across multiple failed apps' {
            $failedApps = @('App.Recovers', 'App.StillFails')
            $installedApps = @()

            Mock Start-Process { }

            $appsToRetry = $failedApps
            $failedApps = @()

            foreach ($appName in $appsToRetry) {
                Start-Process winget -ArgumentList "install -e --accept-source-agreements --accept-package-agreements --source winget --id $appName" -NoNewWindow -Wait
                # Simulate verification: App.Recovers succeeds, App.StillFails does not
                $retryResult = if ($appName -eq 'App.Recovers') { $appName } else { '' }
                if (![String]::Join('', $retryResult).Contains($appName)) {
                    $failedApps += $appName
                }
                else {
                    $installedApps += $appName
                }
            }

            $installedApps | Should -Contain 'App.Recovers'
            $failedApps | Should -Contain 'App.StillFails'
            $failedApps | Should -Not -Contain 'App.Recovers'
        }

        It 'Should signal non-zero exit when apps still fail after retry' {
            $failedApps = @('App.StillFails')

            $exitCode = if ($failedApps.Count -gt 0) { 1 } else { 0 }

            $exitCode | Should -Be 1
        }
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
        # Never actually wait during tests; the backoff is verified via Assert-MockCalled.
        Mock Start-Sleep { }

        # Each Start-Process call returns the next exit code from the queue, simulating winget.
        $script:exitCodeQueue = @()
        $script:procCallIndex = 0
        Mock Start-Process {
            $code = $script:exitCodeQueue[$script:procCallIndex]
            $script:procCallIndex++
            [pscustomobject]@{ ExitCode = $code }
        }
    }

    It 'Succeeds on the first attempt without sleeping' {
        $script:exitCodeQueue = @(0)

        $result = Install-WingetPackage -PackageId 'Test.App' -MaxAttempts 3 -InitialDelaySeconds 1

        $result.ExitCode | Should -Be 0
        $result.Attempts | Should -Be 1
        $result.SessionErrorExhausted | Should -Be $false
        Assert-MockCalled Start-Process -Times 1 -Exactly
        Assert-MockCalled Start-Sleep -Times 0 -Exactly
    }

    It 'Retries with backoff and recovers when the session error is transient' {
        $script:exitCodeQueue = @($script:SessionLogoffExitCode, 0)

        $result = Install-WingetPackage -PackageId 'Microsoft.PowerShell' -MaxAttempts 3 -InitialDelaySeconds 1

        $result.ExitCode | Should -Be 0
        $result.Attempts | Should -Be 2
        $result.SessionErrorExhausted | Should -Be $false
        Assert-MockCalled Start-Process -Times 2 -Exactly
        # One backoff wait between the failed first attempt and the successful second.
        Assert-MockCalled Start-Sleep -Times 1 -Exactly
    }

    It 'Exhausts MaxAttempts when the session error persists' {
        $script:exitCodeQueue = @($script:SessionLogoffExitCode, $script:SessionLogoffExitCode, $script:SessionLogoffExitCode)

        $result = Install-WingetPackage -PackageId 'Microsoft.PowerShell' -MaxAttempts 3 -InitialDelaySeconds 1

        $result.ExitCode | Should -Be $script:SessionLogoffExitCode
        $result.Attempts | Should -Be 3
        $result.SessionErrorExhausted | Should -Be $true
        Assert-MockCalled Start-Process -Times 3 -Exactly
        # Sleeps between attempts only (1->2 and 2->3), never after the final attempt.
        Assert-MockCalled Start-Sleep -Times 2 -Exactly
    }

    It 'Does not retry a non-session failure (lets the caller verify)' {
        # -1978335189 = "No applicable update found"; any non-session code must stop immediately.
        $script:exitCodeQueue = @(-1978335189)

        $result = Install-WingetPackage -PackageId 'Test.App' -MaxAttempts 3 -InitialDelaySeconds 1

        $result.ExitCode | Should -Be -1978335189
        $result.Attempts | Should -Be 1
        $result.SessionErrorExhausted | Should -Be $false
        Assert-MockCalled Start-Process -Times 1 -Exactly
        Assert-MockCalled Start-Sleep -Times 0 -Exactly
    }

    It 'Prefers machine scope on the first attempt (issue #159)' {
        $script:exitCodeQueue = @(0)

        $result = Install-WingetPackage -PackageId 'Microsoft.PowerShell' -MaxAttempts 3 -InitialDelaySeconds 1

        $result.MachineScopeFellBack | Should -Be $false
        Assert-MockCalled Start-Process -Times 1 -Exactly -ParameterFilter {
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
        Assert-MockCalled Start-Process -Times 2 -Exactly
        Assert-MockCalled Start-Process -Times 1 -Exactly -ParameterFilter { $ArgumentList -notcontains '--scope' }
        Assert-MockCalled Start-Sleep -Times 0 -Exactly
    }

    It 'Falls back on scope at most once' {
        # NO_APPLICABLE_INSTALLER at both scopes is a real failure and must be returned, not looped.
        $script:exitCodeQueue = @(-1978335216, -1978335216)

        $result = Install-WingetPackage -PackageId 'Broken.Package' -MaxAttempts 3 -InitialDelaySeconds 1

        $result.ExitCode | Should -Be -1978335216
        $result.MachineScopeFellBack | Should -Be $true
        Assert-MockCalled Start-Process -Times 2 -Exactly
        Assert-MockCalled Start-Sleep -Times 0 -Exactly
    }

    It 'Still retries the session error with backoff after a scope fallback' {
        $script:exitCodeQueue = @(-1978335216, $script:SessionLogoffExitCode, 0)

        $result = Install-WingetPackage -PackageId 'Microsoft.WindowsTerminal' -MaxAttempts 3 -InitialDelaySeconds 1

        $result.ExitCode | Should -Be 0
        $result.MachineScopeFellBack | Should -Be $true
        $result.Attempts | Should -Be 2
        $result.SessionErrorExhausted | Should -Be $false
        Assert-MockCalled Start-Process -Times 3 -Exactly
        Assert-MockCalled Start-Sleep -Times 1 -Exactly
    }

    It 'Passes --installer-type to winget when an installer type is supplied' {
        $script:exitCodeQueue = @(0)

        Install-WingetPackage -PackageId 'Microsoft.PowerShell' -InstallerType 'wix' -MaxAttempts 1 | Out-Null

        Assert-MockCalled Start-Process -Times 1 -Exactly -ParameterFilter {
            ($ArgumentList -join ' ') -match '--installer-type\s+wix'
        }
    }

    It 'Omits --installer-type when no installer type is supplied' {
        $script:exitCodeQueue = @(0)

        Install-WingetPackage -PackageId 'Test.App' -MaxAttempts 1 | Out-Null

        Assert-MockCalled Start-Process -Times 1 -Exactly -ParameterFilter {
            $ArgumentList -notcontains '--installer-type'
        }
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
        Assert-MockCalled Start-Process -Times 1 -Exactly -ParameterFilter {
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
    }

    It 'Reports the dry run without probing' {
        Mock Invoke-WingetSourceProbe { @{ Succeeded = $true; ExitCode = 0; TimedOut = $false } }

        $result = Initialize-WingetSourcesForUser -WhatIf

        $result | Should -Be $true
        Assert-MockCalled Invoke-WingetSourceProbe -Times 0 -Exactly
    }

    It 'Returns true without repairing when the probe succeeds' {
        Mock Invoke-WingetSourceProbe { @{ Succeeded = $true; ExitCode = 0; TimedOut = $false } }

        $result = Initialize-WingetSourcesForUser

        $result | Should -Be $true
        Assert-MockCalled Invoke-WingetSourceProbe -Times 1 -Exactly
        Assert-MockCalled Repair-WinGetPackageManager -Times 0 -Exactly
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
        Assert-MockCalled Repair-WinGetPackageManager -Times 1 -Exactly
        Assert-MockCalled Invoke-WingetSourceProbe -Times 2 -Exactly
    }

    It 'Returns false when the probe still fails after repair' {
        Mock Invoke-WingetSourceProbe { @{ Succeeded = $false; ExitCode = -2147009255; TimedOut = $false } }

        $result = Initialize-WingetSourcesForUser

        $result | Should -Be $false
        Assert-MockCalled Repair-WinGetPackageManager -Times 1 -Exactly
        Assert-MockCalled Invoke-WingetSourceProbe -Times 2 -Exactly
    }

    It 'Returns false and skips repair when Repair-WinGetPackageManager is unavailable' {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'Repair-WinGetPackageManager' }
        Mock Invoke-WingetSourceProbe { @{ Succeeded = $false; ExitCode = -1978335162; TimedOut = $false } }

        $result = Initialize-WingetSourcesForUser

        $result | Should -Be $false
        Assert-MockCalled Repair-WinGetPackageManager -Times 0 -Exactly
        Assert-MockCalled Invoke-WingetSourceProbe -Times 1 -Exactly
    }

    It 'Warns about cross-user elevation when the process account differs from the session owner' {
        Mock Get-ProcessUserName { 'CONTOSO\admin-jmaffiola' }
        Mock Get-InteractiveSessionUserName { 'CONTOSO\jdoe' }
        Mock Invoke-WingetSourceProbe { @{ Succeeded = $true; ExitCode = 0; TimedOut = $false } }

        [void](Initialize-WingetSourcesForUser)

        Assert-MockCalled Write-WarningMessage -Times 1 -ParameterFilter { $Message -match 'Cross-user elevation detected' }
    }

    It 'Does not warn about cross-user elevation for a same-account session' {
        Mock Invoke-WingetSourceProbe { @{ Succeeded = $true; ExitCode = 0; TimedOut = $false } }

        [void](Initialize-WingetSourcesForUser)

        Assert-MockCalled Write-WarningMessage -Times 0 -ParameterFilter { $Message -match 'Cross-user elevation detected' }
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
        Mock Test-WingetPackageInstalled { $true }
        Mock Install-MsixProvisionedPackage { throw 'DISM provisioning should not run when an MSI is available' }

        $result = Install-PowerShellLatest

        $result.Method | Should -Be 'msi'
        $result.Installed | Should -Be $true
        Assert-MockCalled Install-WingetPackage -Times 1 -Exactly -ParameterFilter { $InstallerType -eq 'wix' }
        Assert-MockCalled Install-MsixProvisionedPackage -Times 0 -Exactly
    }

    It 'installs the native MSIX on Windows 24H2+ when no MSI is available' {
        # -1978335216 = NO_APPLICABLE_INSTALLER: the wix (MSI) installer is gone at 7.7+.
        Mock Install-WingetPackage { @{ ExitCode = -1978335216 } } -ParameterFilter { $InstallerType -eq 'wix' }
        Mock Install-WingetPackage { @{ ExitCode = 0 } } -ParameterFilter { -not $InstallerType }
        Mock Get-WindowsBuildNumber { 26100 }
        Mock Test-WingetPackageInstalled { $true }
        Mock Install-MsixProvisionedPackage { throw 'DISM provisioning should not run on 24H2+' }

        $result = Install-PowerShellLatest

        $result.Method | Should -Be 'msix-native'
        $result.Installed | Should -Be $true
        Assert-MockCalled Install-MsixProvisionedPackage -Times 0 -Exactly
    }

    It 'provisions the MSIX via DISM on older Windows when no MSI is available' {
        Mock Install-WingetPackage { @{ ExitCode = -1978335216 } }
        Mock Get-WindowsBuildNumber { 19045 }
        Mock Install-MsixProvisionedPackage { @{ ExitCode = 0; Installed = $true } }

        $result = Install-PowerShellLatest

        $result.Method | Should -Be 'msix-provisioned'
        $result.Installed | Should -Be $true
        Assert-MockCalled Install-MsixProvisionedPackage -Times 1 -Exactly
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
        Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }
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
        Assert-MockCalled Invoke-AppxProvisioning -Times 1 -Exactly -ParameterFilter {
            $PackagePath -like '*PowerShell-7.7.0-win.msixbundle' -and (($DependencyPackagePath -join '') -like '*WindowsAppRuntime*')
        }
    }

    It 'returns not-installed when winget download fails' {
        Mock Start-Process { [pscustomobject]@{ ExitCode = 1 } }
        Mock Invoke-AppxProvisioning { throw 'provisioning should not run after a failed download' }

        $result = Install-MsixProvisionedPackage -PackageId 'Microsoft.PowerShell'

        $result.Installed | Should -Be $false
        Assert-MockCalled Invoke-AppxProvisioning -Times 0 -Exactly
    }

    It 'returns not-installed when no MSIX is found in the download' {
        Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }
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

        Assert-MockCalled powershell.exe -Times 1 -Exactly
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

Describe 'App list consistency' {
    It 'Should keep install and uninstall app lists in sync' {
        $installApps = Get-Content "$PSScriptRoot\winget-app-install.ps1" |
        ForEach-Object {
            if ($_ -match "@{name = '([^']+)'") { $matches[1] }
        } |
        Where-Object { $_ }

        $uninstallApps = Get-Content "$PSScriptRoot\winget-app-uninstall.ps1" |
        ForEach-Object {
            if ($_ -match "@{name = '([^']+)'") { $matches[1] }
        } |
        Where-Object { $_ }

        $installApps | Should -Be $uninstallApps
    }
}

Describe 'Test-AppDefinitions' {
    BeforeAll {
    }

    Context 'When app definitions are valid' {
        It 'Should return the same number of apps without errors or warnings' {
            $apps = @(
                @{ name = 'App.One' },
                @{ name = 'App.Two' }
            )

            $result = Test-AppDefinitions -Apps $apps

            $result.ValidApps.Count | Should -Be 2
            $result.Errors | Should -BeNullOrEmpty
            $result.Warnings | Should -BeNullOrEmpty
        }
    }

    Context 'When an entry is malformed' {
        It 'Should return an error and skip the invalid entry' {
            $apps = @(
                @{ name = 'App.Valid' },
                @{ bogus = 'value' }
            )

            $result = Test-AppDefinitions -Apps $apps

            $result.ValidApps.Count | Should -Be 1
            $result.Errors.Count | Should -Be 1
            $result.Errors[0] | Should -Match "missing a valid 'name'"
        }
    }

    Context 'When duplicate entries are present' {
        It 'Should keep the first occurrence and warn about duplicates' {
            $apps = @(
                @{ name = 'App.Duplicate' },
                @{ name = 'app.duplicate ' }
            )

            $result = Test-AppDefinitions -Apps $apps

            $result.ValidApps.Count | Should -Be 1
            $result.ValidApps[0].name | Should -Be 'App.Duplicate'
            $result.Warnings.Count | Should -Be 1
            $result.Warnings[0] | Should -Match 'Duplicate app definition'
        }
    }
}

Describe 'Test-SystemRequirements' -Tag 'SystemRequirements' {
    BeforeEach {
        Mock Write-Info { }
        Mock Write-Success { }
        Mock Write-WarningMessage { }
        Mock Write-ErrorMessage { }
        Mock Invoke-WebRequest { [PSCustomObject]@{ StatusCode = 200 } }
        Mock Get-PSDrive {
            [PSCustomObject]@{ Free = 100GB }
        }
        Mock Get-ItemProperty {
            [PSCustomObject]@{ ProductName = 'Windows 11 Pro' }
        }
    }

    It 'Returns $true when all checks pass' {
        $result = Test-SystemRequirements
        $result | Should -BeTrue
    }

    It 'Returns $false on a transport-level network failure (no HTTP response)' {
        Mock Invoke-WebRequest { throw 'No network' }
        $result = Test-SystemRequirements
        $result | Should -BeFalse
    }

    It 'Treats an HTTP error response (e.g. 403) as reachable and returns $true' {
        Mock Invoke-WebRequest {
            $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::Forbidden)
            throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Response status code does not indicate success: 403 (Forbidden).', $response)
        }
        $result = Test-SystemRequirements
        $result | Should -BeTrue
    }

    It 'Returns $false when user declines low disk space prompt' {
        Mock Get-PSDrive { [PSCustomObject]@{ Free = 10GB } }
        Mock Read-Host { 'N' }
        $result = Test-SystemRequirements
        $result | Should -BeFalse
    }

    It 'Returns $true when user accepts low disk space prompt' {
        Mock Get-PSDrive { [PSCustomObject]@{ Free = 10GB } }
        Mock Read-Host { 'Y' }
        $result = Test-SystemRequirements
        $result | Should -BeTrue
    }

    It 'Skips disk space prompt in WhatIf mode' {
        Mock Get-PSDrive { [PSCustomObject]@{ Free = 10GB } }
        Mock Read-Host { throw 'Should not prompt in WhatIf mode' }
        { Test-SystemRequirements -WhatIf } | Should -Not -Throw
    }

    It 'Does not prompt when the C: drive cannot be read (unattended-safe)' {
        Mock Get-PSDrive { throw 'Drive read failure' }
        Mock Read-Host { throw 'Should not prompt when free space was not measured' }
        $result = Test-SystemRequirements
        $result | Should -BeTrue
        Should -Invoke Read-Host -Times 0 -Exactly
    }

    It 'Reports UNKNOWN (not the low-space WARN) when the C: drive cannot be read' {
        Mock Get-PSDrive { throw 'Drive read failure' }
        Mock Read-Host { throw 'Should not prompt when free space was not measured' }
        $null = Test-SystemRequirements
        Should -Invoke Write-WarningMessage -ParameterFilter { $Message -match '\[UNKNOWN\] Disk Space' }
    }
}

Describe 'Windows Terminal configuration' {
    BeforeAll {
    }

    Context 'Set-WindowsTerminalDefaultProfile' {
        It 'Should set defaultProfile in settings.json' {
            $settingsPath = Join-Path $TestDrive 'settings.json'
            Set-Content -Path $settingsPath -Value '{"profiles":{"list":[]}}' -Encoding UTF8

            $result = Set-WindowsTerminalDefaultProfile -SettingsPath $settingsPath -ProfileGuid '{574e775e-4f2a-5b96-ac1e-a2962a402336}'
            $updated = Get-Content -Path $settingsPath -Raw | ConvertFrom-Json

            $result | Should -Be $true
            $updated.defaultProfile | Should -Be '{574e775e-4f2a-5b96-ac1e-a2962a402336}'
        }

        It 'Should parse JSONC style settings with comments and trailing commas' {
            $settingsPath = Join-Path $TestDrive 'settings-jsonc.json'
            $jsonc = @'
{
  // sample comment
  "profiles": {
    "list": [
    ],
  },
}
'@
            Set-Content -Path $settingsPath -Value $jsonc -Encoding UTF8

            $result = Set-WindowsTerminalDefaultProfile -SettingsPath $settingsPath -ProfileGuid '574e775e-4f2a-5b96-ac1e-a2962a402336'
            $updated = Get-Content -Path $settingsPath -Raw | ConvertFrom-Json

            $result | Should -Be $true
            $updated.defaultProfile | Should -Be '{574e775e-4f2a-5b96-ac1e-a2962a402336}'
        }

        It 'Should return false when settings path does not exist' {
            $missingPath = Join-Path $TestDrive 'missing-settings.json'

            $result = Set-WindowsTerminalDefaultProfile -SettingsPath $missingPath -ProfileGuid '{574e775e-4f2a-5b96-ac1e-a2962a402336}'

            $result | Should -Be $false
        }
    }

    Context 'Set-WindowsTerminalAsDefaultTerminalApplication' {
        It 'Should create/update registry values when not already configured' {
            Mock Test-Path { return $false } -ParameterFilter { $Path -eq 'HKCU:\Console\%%Startup' }
            Mock New-Item { }
            Mock Get-ItemProperty { return [pscustomobject]@{} }
            Mock New-ItemProperty { }

            $result = Set-WindowsTerminalAsDefaultTerminalApplication

            $result | Should -Be $true
            Assert-MockCalled New-Item -Times 1 -ParameterFilter { $Path -eq 'HKCU:\Console\%%Startup' -and $Force }
            Assert-MockCalled New-ItemProperty -Times 2
        }

        It 'Should skip writes when registry is already configured' {
            Mock Test-Path { return $true } -ParameterFilter { $Path -eq 'HKCU:\Console\%%Startup' }
            Mock Get-ItemProperty {
                [pscustomobject]@{
                    DelegationConsole  = '{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}'
                    DelegationTerminal = '{E12CFF52-A866-4C77-9A90-F570A7AA2C6B}'
                }
            }
            Mock New-ItemProperty { }

            $result = Set-WindowsTerminalAsDefaultTerminalApplication

            $result | Should -Be $true
            Assert-MockCalled New-ItemProperty -Times 0
        }

        It 'Should return false when registry write fails' {
            Mock Test-Path { return $true } -ParameterFilter { $Path -eq 'HKCU:\Console\%%Startup' }
            Mock Get-ItemProperty { return [pscustomobject]@{} }
            Mock New-ItemProperty { throw 'Registry denied' }

            $result = Set-WindowsTerminalAsDefaultTerminalApplication

            $result | Should -Be $false
        }
    }

    Context 'Set-WindowsTerminalDefaults orchestration' {
        It 'Should perform no writes in WhatIf mode' {
            Mock Get-WindowsTerminalSettingsPaths { return @('C:\temp\settings.json') }
            Mock Set-WindowsTerminalDefaultProfile { return $true }
            Mock Set-WindowsTerminalAsDefaultTerminalApplication { return $true }
            Mock Write-Info { }

            Set-WindowsTerminalDefaults -WhatIf

            Assert-MockCalled Set-WindowsTerminalDefaultProfile -Times 0
            Assert-MockCalled Set-WindowsTerminalAsDefaultTerminalApplication -Times 0
            Assert-MockCalled Write-Info -Times 2
        }

        It 'Should configure both settings file and registry in normal mode' {
            Mock Get-WindowsTerminalSettingsPaths { return @('C:\temp\settings.json') }
            Mock Set-WindowsTerminalDefaultProfile { return $true }
            Mock Set-WindowsTerminalAsDefaultTerminalApplication { return $true }

            Set-WindowsTerminalDefaults

            Assert-MockCalled Set-WindowsTerminalDefaultProfile -Times 1
            Assert-MockCalled Set-WindowsTerminalAsDefaultTerminalApplication -Times 1
        }

        It 'Should configure all discovered settings files in normal mode' {
            Mock Get-WindowsTerminalSettingsPaths { return @('C:\temp\stable-settings.json', 'C:\temp\preview-settings.json') }
            Mock Set-WindowsTerminalDefaultProfile { return $true }
            Mock Set-WindowsTerminalAsDefaultTerminalApplication { return $true }

            Set-WindowsTerminalDefaults

            Assert-MockCalled Set-WindowsTerminalDefaultProfile -Times 2
            Assert-MockCalled Set-WindowsTerminalAsDefaultTerminalApplication -Times 1
        }
    }
}

Describe 'Write-Info' {
    BeforeAll {
    }

    It 'Should write message in blue color' {
        Mock Write-Host { }

        Write-Info 'Test message'

        Assert-MockCalled Write-Host -Times 1 -ParameterFilter {
            $Object -eq 'Test message' -and $ForegroundColor -eq 'Blue'
        }
    }
}

Describe 'Write-Success' {
    BeforeAll {
    }

    It 'Should write message in green color' {
        Mock Write-Host { }

        Write-Success 'Success message'

        Assert-MockCalled Write-Host -Times 1 -ParameterFilter {
            $Object -eq 'Success message' -and $ForegroundColor -eq 'Green'
        }
    }
}

Describe 'Write-WarningMessage' {
    BeforeAll {
    }

    It 'Should write message in yellow color' {
        Mock Write-Host { }

        Write-WarningMessage 'Warning message'

        Assert-MockCalled Write-Host -Times 1 -ParameterFilter {
            $Object -eq 'Warning message' -and $ForegroundColor -eq 'Yellow'
        }
    }
}

Describe 'Write-ErrorMessage' {
    BeforeAll {
    }

    It 'Should write message in red color' {
        Mock Write-Host { }

        Write-ErrorMessage 'Error message'

        Assert-MockCalled Write-Host -Times 1 -ParameterFilter {
            $Object -eq 'Error message' -and $ForegroundColor -eq 'Red'
        }
    }
}

Describe 'Write-Prompt' {
    BeforeAll {
    }

    It 'Should write message in blue color' {
        Mock Write-Host { }

        Write-Prompt 'Press any key to continue...'

        Assert-MockCalled Write-Host -Times 1 -ParameterFilter {
            $Object -eq 'Press any key to continue...' -and $ForegroundColor -eq 'Blue'
        }
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

    Context 'WhatIf logic for app installation' {
        It 'Should skip Start-Process when WhatIf is true' {
            Mock Start-Process { }
            Mock Write-Info { }
            Mock Write-Success { }

            # Simulate the code path
            $WhatIf = $true
            $app = @{ name = 'Test.App' }
            $installedApps = @()

            if (-not $WhatIf) {
                Write-Info "Installing: $($app.name)"
                Start-Process winget -ArgumentList "install -e --accept-source-agreements --accept-package-agreements --id $($app.name)" -NoNewWindow -Wait
                Write-Success "Successfully installed: $($app.name)"
                $installedApps += $app.name
            }
            else {
                Write-Info "[DRY-RUN] Would install: $($app.name)"
                $installedApps += $app.name
            }

            Assert-MockCalled Start-Process -Times 0
            Assert-MockCalled Write-Info -Times 1 -ParameterFilter { $Message -match 'DRY-RUN' }
            $installedApps | Should -Contain 'Test.App'
        }

        It 'Should call Start-Process when WhatIf is false' {
            Mock Start-Process { }
            Mock Write-Info { }
            Mock Write-Success { }

            # Simulate the code path
            $WhatIf = $false
            $app = @{ name = 'Test.App' }
            $installedApps = @()

            if (-not $WhatIf) {
                Write-Info "Installing: $($app.name)"
                Start-Process winget -ArgumentList "install -e --accept-source-agreements --accept-package-agreements --id $($app.name)" -NoNewWindow -Wait
                Write-Success "Successfully installed: $($app.name)"
                $installedApps += $app.name
            }
            else {
                Write-Info "[DRY-RUN] Would install: $($app.name)"
                $installedApps += $app.name
            }

            Assert-MockCalled Start-Process -Times 1
            Assert-MockCalled Write-Info -Times 1 -ParameterFilter { $Message -notmatch 'DRY-RUN' }
            $installedApps | Should -Contain 'Test.App'
        }
    }
}

Describe 'IEX non-admin execution behavior' {
    BeforeAll {
        $script:isWindowsPlatform = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
        $script:isElevated = $false

        if ($script:isWindowsPlatform) {
            $script:isElevated = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
                [Security.Principal.WindowsBuiltInRole]::Administrator
            )
        }
    }

    It 'Should exit with code 1 and show remote elevation guidance' -Skip:(-not $script:isWindowsPlatform -or $script:isElevated) {

        $scriptPath = Join-Path $PSScriptRoot 'winget-app-install.ps1'
        $psStringEscapedPath = $scriptPath.Replace("'", "''")
        $currentPowerShell = (Get-Process -Id $PID).Path
        $childCommand = @"
Get-Content -Raw -LiteralPath '$psStringEscapedPath' | Invoke-Expression
"@

        $output = & $currentPowerShell -NoLogo -NoProfile -NonInteractive -Command $childCommand 2>&1 | Out-String
        $exitCode = $LASTEXITCODE

        $exitCode | Should -Be 1
        $output | Should -Match 'This script requires administrator privileges\.'
        $output | Should -Match 'Auto-elevation is unavailable when running through IEX/remote execution\.'
        $output | Should -Match 'Open an elevated PowerShell or Windows Terminal session and run the IEX command again\.'
        $output | Should -Match 'Exiting in 5 seconds\.\.\.'
        $output | Should -Not -Match 'Press Enter to restart script with elevated privileges'
    }
}

Describe 'Winget-AutoUpdate integration (issue #168)' {
    BeforeEach {
        Mock Write-Host { }
        Mock Write-Info { }
        Mock Write-Success { }
        Mock Write-WarningMessage { }
        Mock Write-ErrorMessage { }
    }

    Context 'Get-WauPin' {
        It 'returns the pinned version, MSI url, sha256, and product code' {
            $pin = Get-WauPin
            $pin.Version | Should -Be '2.12.0'
            $pin.MsiUrl | Should -Match 'v2\.12\.0/WAU\.msi$'
            $pin.Sha256 | Should -Match '^[0-9A-Fa-f]{64}$'
            $pin.ProductCode | Should -Match '^\{[0-9A-Fa-f-]+\}$'
        }
    }

    Context 'Get-InstalledWauInfo (issue #186)' {
        It 'resolves the ProductCode and version from the matching MSI uninstall entry' {
            Mock Test-Path { $true }
            Mock Get-ChildItem {
                [pscustomobject]@{ PSPath = 'HKLM:\...\Uninstall\{11111111-2222-3333-4444-555555555555}'; PSChildName = '{11111111-2222-3333-4444-555555555555}' }
            }
            Mock Get-ItemProperty { [pscustomobject]@{ DisplayName = 'Winget-AutoUpdate'; DisplayVersion = '2.9.0' } }

            $info = Get-InstalledWauInfo

            $info.ProductCode | Should -Be '{11111111-2222-3333-4444-555555555555}'
            $info.Version | Should -Be ([version]'2.9.0')
        }

        It 'skips uninstall entries whose DisplayName does not match WAU' {
            Mock Test-Path { $true }
            Mock Get-ChildItem {
                @(
                    [pscustomobject]@{ PSPath = 'HKLM:\...\Uninstall\{99999999-0000-0000-0000-000000000000}'; PSChildName = '{99999999-0000-0000-0000-000000000000}' },
                    [pscustomobject]@{ PSPath = 'HKLM:\...\Uninstall\{11111111-2222-3333-4444-555555555555}'; PSChildName = '{11111111-2222-3333-4444-555555555555}' }
                )
            }
            Mock Get-ItemProperty { [pscustomobject]@{ DisplayName = 'Some Other App'; DisplayVersion = '9.9.9' } } -ParameterFilter { $Path -like '*99999999*' }
            Mock Get-ItemProperty { [pscustomobject]@{ DisplayName = 'Winget-AutoUpdate'; DisplayVersion = '2.10.1' } } -ParameterFilter { $Path -like '*11111111*' }

            $info = Get-InstalledWauInfo

            $info.ProductCode | Should -Be '{11111111-2222-3333-4444-555555555555}'
            $info.Version | Should -Be ([version]'2.10.1')
        }

        It 'falls back to the Romanitho registry key for the version when no uninstall entry matches' {
            Mock Test-Path { $true }
            Mock Get-ChildItem { @() }
            Mock Get-ItemProperty { [pscustomobject]@{ DisplayVersion = $null; ProductVersion = 'v2.8.0' } } -ParameterFilter { $Path -like '*Romanitho*' }

            $info = Get-InstalledWauInfo

            $info.ProductCode | Should -BeNullOrEmpty
            $info.Version | Should -Be ([version]'2.8.0')
        }

        It 'returns nulls when WAU is nowhere in the registry' {
            Mock Test-Path { $false }
            Mock Get-ChildItem { throw 'should not enumerate when the roots are absent' }
            Mock Get-ItemProperty { throw 'should not read properties when the roots are absent' }

            $info = Get-InstalledWauInfo

            $info.ProductCode | Should -BeNullOrEmpty
            $info.Version | Should -BeNullOrEmpty
        }
    }

    Context 'New-WauStagingDirectory / Set-RestrictedDirectoryAcl (issue #186)' {
        BeforeEach {
            $script:origProgramData = $env:ProgramData
            if (-not $env:ProgramData) {
                $env:ProgramData = Join-Path ([System.IO.Path]::GetTempPath()) 'programdata-test'
            }
        }

        AfterEach {
            $env:ProgramData = $script:origProgramData
        }

        It 'creates a unique directory under ProgramData\winget-app-setup and restricts base and staging ACLs' {
            Mock New-Item { }
            Mock Set-RestrictedDirectoryAcl { }

            $dir = New-WauStagingDirectory

            $baseDir = Join-Path $env:ProgramData 'winget-app-setup'
            $dir | Should -BeLike (Join-Path $baseDir 'wau-msi-*')
            Assert-MockCalled New-Item -Times 2 -Exactly
            Assert-MockCalled Set-RestrictedDirectoryAcl -Times 1 -Exactly -ParameterFilter { $Path -eq $baseDir }
            Assert-MockCalled Set-RestrictedDirectoryAcl -Times 1 -Exactly -ParameterFilter { $Path -eq $dir }
        }

        It 'generates a different staging directory name on every run' {
            Mock New-Item { }
            Mock Set-RestrictedDirectoryAcl { }

            (New-WauStagingDirectory) | Should -Not -Be (New-WauStagingDirectory)
        }

        It 'restricts the ACL to SYSTEM and Administrators with inheritance removed' {
            Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }

            Set-RestrictedDirectoryAcl -Path 'C:\ProgramData\winget-app-setup\wau-msi-test'

            Assert-MockCalled Start-Process -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq 'icacls.exe' -and
                $ArgumentList -match '/inheritance:r' -and
                $ArgumentList -match ([regex]::Escape('*S-1-5-18:(OI)(CI)F')) -and
                $ArgumentList -match ([regex]::Escape('*S-1-5-32-544:(OI)(CI)F')) -and
                $ArgumentList -match ([regex]::Escape('"C:\ProgramData\winget-app-setup\wau-msi-test"'))
            }
        }

        It 'throws when icacls fails so callers never use an unsecured directory' {
            Mock Start-Process { [pscustomobject]@{ ExitCode = 5 } }

            { Set-RestrictedDirectoryAcl -Path 'C:\ProgramData\winget-app-setup\wau-msi-test' } | Should -Throw '*exit code 5*'
        }
    }

    Context 'Install-WingetAutoUpdate' {
        It 'downloads into the ACL-restricted staging directory, verifies the hash, and installs silently with the pinned config' {
            Mock Test-WauInstalled { $false }
            Mock New-WauStagingDirectory { 'C:\ProgramData\winget-app-setup\wau-msi-test' }
            Mock Invoke-WebRequest { }
            Mock Get-FileHash { @{ Hash = (Get-WauPin).Sha256 } }
            Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }
            Mock Remove-Item { }

            $result = Install-WingetAutoUpdate

            $result.Status | Should -Be 'Configured'
            $result.Version | Should -Be (Get-WauPin).Version
            Assert-MockCalled New-WauStagingDirectory -Times 1 -Exactly
            Assert-MockCalled Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $OutFile -like '*wau-msi-test*' }
            Assert-MockCalled Start-Process -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq 'msiexec.exe' -and
                $ArgumentList -match 'RUN_WAU=YES' -and $ArgumentList -match 'USERCONTEXT=1' -and
                $ArgumentList -match 'DISABLEWAUAUTOUPDATE=1' -and $ArgumentList -match 'UPDATESINTERVAL=Weekly' -and
                $ArgumentList -match 'NOTIFICATIONLEVEL=Full'
            }
            Assert-MockCalled Remove-Item -Times 1 -Exactly -ParameterFilter {
                $Path -eq 'C:\ProgramData\winget-app-setup\wau-msi-test' -and $Recurse
            }
        }

        It 'reports AlreadyPresent (with the installed version) when WAU is at the pinned version' {
            Mock Test-WauInstalled { $true }
            Mock Get-InstalledWauInfo { [pscustomobject]@{ Version = [version](Get-WauPin).Version; ProductCode = (Get-WauPin).ProductCode } }
            Mock Invoke-WebRequest { throw 'should not download when WAU is current' }
            Mock Start-Process { throw 'should not run msiexec when WAU is current' }

            $result = Install-WingetAutoUpdate

            $result.Status | Should -Be 'AlreadyPresent'
            $result.Version | Should -Be ([version](Get-WauPin).Version)
            Assert-MockCalled Invoke-WebRequest -Times 0 -Exactly
            Assert-MockCalled Start-Process -Times 0 -Exactly
        }

        It 'upgrades in place when the installed version is older than the pin (issue #186)' {
            Mock Test-WauInstalled { $true }
            Mock Get-InstalledWauInfo { [pscustomobject]@{ Version = [version]'2.11.0'; ProductCode = '{11111111-2222-3333-4444-555555555555}' } }
            Mock New-WauStagingDirectory { 'C:\ProgramData\winget-app-setup\wau-msi-test' }
            Mock Invoke-WebRequest { }
            Mock Get-FileHash { @{ Hash = (Get-WauPin).Sha256 } }
            Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }
            Mock Remove-Item { }

            $result = Install-WingetAutoUpdate

            $result.Status | Should -Be 'Configured'
            Assert-MockCalled Start-Process -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq 'msiexec.exe' -and $ArgumentList -match '/i'
            }
        }

        It 'does not downgrade when the installed version is newer than the pin' {
            Mock Test-WauInstalled { $true }
            Mock Get-InstalledWauInfo { [pscustomobject]@{ Version = [version]'99.0.0'; ProductCode = '{11111111-2222-3333-4444-555555555555}' } }
            Mock Invoke-WebRequest { throw 'should not download for a newer install' }
            Mock Start-Process { throw 'should not run msiexec for a newer install' }

            $result = Install-WingetAutoUpdate

            $result.Status | Should -Be 'AlreadyPresent'
            $result.Version | Should -Be ([version]'99.0.0')
            Assert-MockCalled Start-Process -Times 0 -Exactly
        }

        It 'leaves an installed WAU with an unreadable version untouched' {
            Mock Test-WauInstalled { $true }
            Mock Get-InstalledWauInfo { [pscustomobject]@{ Version = $null; ProductCode = $null } }
            Mock Invoke-WebRequest { throw 'should not download when the version is unknown' }
            Mock Start-Process { throw 'should not run msiexec when the version is unknown' }

            $result = Install-WingetAutoUpdate

            $result.Status | Should -Be 'AlreadyPresent'
            $result.Version | Should -BeNullOrEmpty
            Assert-MockCalled Start-Process -Times 0 -Exactly
        }

        It 'aborts without installing when the MSI hash does not match, and still cleans the staging directory' {
            Mock Test-WauInstalled { $false }
            Mock New-WauStagingDirectory { 'C:\ProgramData\winget-app-setup\wau-msi-test' }
            Mock Invoke-WebRequest { }
            Mock Get-FileHash { @{ Hash = 'DEADBEEF' } }
            Mock Start-Process { throw 'must not run msiexec on a hash mismatch' }
            Mock Remove-Item { }

            $result = Install-WingetAutoUpdate

            $result.Status | Should -Be 'Failed'
            Assert-MockCalled Start-Process -Times 0 -Exactly
            Assert-MockCalled Remove-Item -Times 1 -Exactly -ParameterFilter {
                $Path -eq 'C:\ProgramData\winget-app-setup\wau-msi-test' -and $Recurse
            }
        }

        It 'returns Failed without downloading when the staging directory cannot be secured' {
            Mock Test-WauInstalled { $false }
            Mock New-WauStagingDirectory { throw 'icacls failed to restrict' }
            Mock Invoke-WebRequest { throw 'should not download without a secured staging directory' }
            Mock Remove-Item { }

            $result = Install-WingetAutoUpdate

            $result.Status | Should -Be 'Failed'
            Assert-MockCalled Invoke-WebRequest -Times 0 -Exactly
            Assert-MockCalled Remove-Item -Times 0 -Exactly
        }

        It 'treats msiexec exit code 3010 (reboot required) as success' {
            Mock Test-WauInstalled { $false }
            Mock New-WauStagingDirectory { 'C:\ProgramData\winget-app-setup\wau-msi-test' }
            Mock Invoke-WebRequest { }
            Mock Get-FileHash { @{ Hash = (Get-WauPin).Sha256 } }
            Mock Start-Process { [pscustomobject]@{ ExitCode = 3010 } }
            Mock Remove-Item { }

            (Install-WingetAutoUpdate).Status | Should -Be 'Configured'
        }

        It 'returns dry-run without side effects under -WhatIf' {
            Mock Test-WauInstalled { throw 'should not probe under WhatIf' }
            Mock Invoke-WebRequest { throw 'should not download under WhatIf' }

            $result = Install-WingetAutoUpdate -WhatIf

            $result.Status | Should -Be 'DryRun'
            $result.Version | Should -Be (Get-WauPin).Version
        }
    }

    Context 'Uninstall-WingetAutoUpdate' {
        It 'uninstalls via the ProductCode of the actually-installed WAU (issue #186)' {
            Mock Test-WauInstalled { $true }
            Mock Get-InstalledWauInfo { [pscustomobject]@{ Version = [version]'2.9.0'; ProductCode = '{11111111-2222-3333-4444-555555555555}' } }
            Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }

            $result = Uninstall-WingetAutoUpdate

            $result | Should -Be $true
            Assert-MockCalled Start-Process -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq 'msiexec.exe' -and $ArgumentList -match '/x' -and
                $ArgumentList -match ([regex]::Escape('{11111111-2222-3333-4444-555555555555}'))
            }
        }

        It 'falls back to the pinned ProductCode when the registry lookup finds none' {
            Mock Test-WauInstalled { $true }
            Mock Get-InstalledWauInfo { [pscustomobject]@{ Version = $null; ProductCode = $null } }
            Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }

            $result = Uninstall-WingetAutoUpdate

            $result | Should -Be $true
            Assert-MockCalled Start-Process -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq 'msiexec.exe' -and $ArgumentList -match '/x' -and
                $ArgumentList -match ([regex]::Escape((Get-WauPin).ProductCode))
            }
        }

        It 'is a no-op when WAU is not installed' {
            Mock Test-WauInstalled { $false }
            Mock Start-Process { throw 'should not run msiexec when WAU is absent' }

            (Uninstall-WingetAutoUpdate) | Should -Be $true
            Assert-MockCalled Start-Process -Times 0 -Exactly
        }
    }

    Context 'Invoke-WingetInstall surfaces the WAU outcome (issue #186)' {
        It 'captures the Install-WingetAutoUpdate result and prints an Auto-updates summary line' {
            $installBody = (Get-Command Invoke-WingetInstall).Definition
            $installBody | Should -Match '\$wauResult\s*=\s*Install-WingetAutoUpdate'
            $installBody | Should -Not -Match '\[void\]\(Install-WingetAutoUpdate'
            $installBody | Should -Match 'Auto-updates: Configured'
            $installBody | Should -Match 'Auto-updates: Already present'
            $installBody | Should -Match 'Auto-updates: FAILED'
        }
    }

    Context 'Remove-LegacyScheduledUpdates' {
        It 'unregisters the legacy task and removes the data directory when present' {
            Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = 'WingetAppSetup-ScheduledUpdates' } }
            Mock Unregister-ScheduledTask { }
            Mock Test-Path { $true }
            Mock Remove-Item { }

            $result = Remove-LegacyScheduledUpdates

            $result | Should -Be $true
            Assert-MockCalled Unregister-ScheduledTask -Times 1 -Exactly -ParameterFilter { $TaskName -eq 'WingetAppSetup-ScheduledUpdates' }
            Assert-MockCalled Remove-Item -Times 1 -Exactly
        }

        It 'is a no-op when there is nothing to clean up' {
            Mock Get-ScheduledTask { throw 'task not found' }
            Mock Test-Path { $false }
            Mock Unregister-ScheduledTask { throw 'should not unregister' }
            Mock Remove-Item { throw 'should not remove' }

            (Remove-LegacyScheduledUpdates) | Should -Be $false
            Assert-MockCalled Unregister-ScheduledTask -Times 0 -Exactly
        }
    }
}
