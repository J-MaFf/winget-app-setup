# WingetAutoUpdate.Tests.ps1
# Tests for WingetAppSetup/Public/WingetAutoUpdate.ps1 and Private/WauSupport.ps1:
# the pinned Winget-AutoUpdate install/upgrade/uninstall flow and its staging helpers.
# Split from the old single-file suite Test-WingetAppInstall.Tests.ps1 (issue #192).

# Load the module's functions once for this file. TestHelpers.ps1 resolves the repo paths
# and dot-sources WingetAppSetup/Private + Public (the single source of truth; the
# distributable winget-app-install.ps1 is generated from it by build/Build-WingetInstallScript.ps1).
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
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
