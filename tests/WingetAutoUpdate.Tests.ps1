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
            Should -Invoke New-Item -Times 2 -Exactly
            Should -Invoke Set-RestrictedDirectoryAcl -Times 1 -Exactly -ParameterFilter { $Path -eq $baseDir }
            Should -Invoke Set-RestrictedDirectoryAcl -Times 1 -Exactly -ParameterFilter { $Path -eq $dir }
        }

        It 'generates a different staging directory name on every run' {
            Mock New-Item { }
            Mock Set-RestrictedDirectoryAcl { }

            (New-WauStagingDirectory) | Should -Not -Be (New-WauStagingDirectory)
        }

        It 'restricts the ACL to SYSTEM and Administrators with inheritance removed' {
            Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }

            Set-RestrictedDirectoryAcl -Path 'C:\ProgramData\winget-app-setup\wau-msi-test'

            Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
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
        BeforeEach {
            # Framework present by default; the framework-gate tests below override it. Without
            # this mock the real query would run on the CI runner, which lacks the framework.
            Mock Get-WindowsAppRuntimeStatus { [pscustomobject]@{ Present = $true; Detail = 'X64 8000.921.1539.0' } }
            Mock Disable-WauLogonTrigger { $false }
        }

        It 'downloads into the ACL-restricted staging directory, verifies the hash, and installs silently with the pinned config' {
            Mock Test-WauInstalled { $false }
            Mock New-WauStagingDirectory { Join-Path $TestDrive 'wau-msi-test' }
            Mock Invoke-WebRequest { }
            Mock Get-FileHash { @{ Hash = (Get-WauPin).Sha256 } }
            Mock Invoke-ExternalProcess { New-TestProcessResult -ExitCode 0 }
            Mock Remove-Item { }

            $result = Install-WingetAutoUpdate

            $result.Status | Should -Be 'Configured'
            $result.Version | Should -Be (Get-WauPin).Version
            Should -Invoke New-WauStagingDirectory -Times 1 -Exactly
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $OutFile -like '*wau-msi-test*' }
            Should -Invoke Invoke-ExternalProcess -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq 'msiexec.exe' -and
                # No RUN_WAU=YES: an immediate WAU run re-provisions App Installer while the
                # installer is still running (issues #279/#283/#284).
                $ArgumentString -notmatch 'RUN_WAU' -and $ArgumentString -match 'UPDATESATLOGON=0' -and $ArgumentString -match 'USERCONTEXT=1' -and
                $ArgumentString -match 'DISABLEWAUAUTOUPDATE=1' -and $ArgumentString -match 'UPDATESINTERVAL=Weekly' -and
                $ArgumentString -match 'NOTIFICATIONLEVEL=Full' -and
                # Time-limited (review finding P2-5): Start-Process -Wait used to wait for ever.
                $TimeoutSeconds -eq (Get-ProcessTimeoutSeconds -Operation MsiExec)
            }
            Should -Invoke Remove-Item -Times 1 -Exactly -ParameterFilter {
                $Path -eq (Join-Path $TestDrive 'wau-msi-test') -and $Recurse
            }
            # A fresh install gets UPDATESATLOGON=0 from the MSI; no task edit needed.
            Should -Invoke Disable-WauLogonTrigger -Times 0 -Exactly
        }

        It 'downloads the MSI with a time limit (review finding P2-5)' {
            Mock Test-WauInstalled { $false }
            Mock New-WauStagingDirectory { Join-Path $TestDrive 'wau-msi-test' }
            Mock Get-WebDownloadTimeoutParameters { @{ TimeoutSec = 7 } }
            Mock Invoke-WebRequest { }
            Mock Get-FileHash { @{ Hash = (Get-WauPin).Sha256 } }
            Mock Invoke-ExternalProcess { New-TestProcessResult -ExitCode 0 }
            Mock Remove-Item { }

            (Install-WingetAutoUpdate).Status | Should -Be 'Configured'

            # -TimeoutSec is an alias of -ConnectionTimeoutSeconds on PowerShell 7.4 and newer.
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { ($ConnectionTimeoutSeconds -eq 7) -or ($TimeoutSec -eq 7) }
        }

        It 'reports Failed, and cleans up, when msiexec runs past its time limit' {
            Mock Test-WauInstalled { $false }
            Mock New-WauStagingDirectory { Join-Path $TestDrive 'wau-msi-test' }
            Mock Invoke-WebRequest { }
            Mock Get-FileHash { @{ Hash = (Get-WauPin).Sha256 } }
            Mock Invoke-ExternalProcess { New-TestProcessResult -TimedOut }
            Mock Remove-Item { }

            $result = Install-WingetAutoUpdate

            $result.Status | Should -Be 'Failed'
            Should -Invoke Write-ErrorMessage -Times 1 -Exactly -ParameterFilter { $Message -match 'msiexec did not finish within 15 minutes' }
            Should -Invoke Remove-Item -Times 1 -Exactly -ParameterFilter { $Path -eq (Join-Path $TestDrive 'wau-msi-test') -and $Recurse }
        }

        It 'reports Failed when msiexec cannot be started' {
            Mock Test-WauInstalled { $false }
            Mock New-WauStagingDirectory { Join-Path $TestDrive 'wau-msi-test' }
            Mock Invoke-WebRequest { }
            Mock Get-FileHash { @{ Hash = (Get-WauPin).Sha256 } }
            Mock Invoke-ExternalProcess { New-TestProcessResult -LaunchFailed -LaunchErrorCode 2 -LaunchError 'The system cannot find the file specified.' }
            Mock Remove-Item { }

            (Install-WingetAutoUpdate).Status | Should -Be 'Failed'
            Should -Invoke Write-ErrorMessage -Times 1 -Exactly -ParameterFilter { $Message -match 'msiexec could not be started' }
        }

        It 'reports AlreadyPresent (with the installed version) when WAU is at the pinned version' {
            Mock Test-WauInstalled { $true }
            Mock Get-InstalledWauInfo { [pscustomobject]@{ Version = [version](Get-WauPin).Version; ProductCode = (Get-WauPin).ProductCode } }
            Mock Invoke-WebRequest { throw 'should not download when WAU is current' }
            Mock Invoke-ExternalProcess { throw 'should not run msiexec when WAU is current' }

            $result = Install-WingetAutoUpdate

            $result.Status | Should -Be 'AlreadyPresent'
            $result.Version | Should -Be ([version](Get-WauPin).Version)
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
            Should -Invoke Invoke-ExternalProcess -Times 0 -Exactly
            Should -Invoke Disable-WauLogonTrigger -Times 1 -Exactly
        }

        It 'upgrades in place when the installed version is older than the pin (issue #186)' {
            Mock Test-WauInstalled { $true }
            Mock Get-InstalledWauInfo { [pscustomobject]@{ Version = [version]'2.11.0'; ProductCode = '{11111111-2222-3333-4444-555555555555}' } }
            Mock New-WauStagingDirectory { Join-Path $TestDrive 'wau-msi-test' }
            Mock Invoke-WebRequest { }
            Mock Get-FileHash { @{ Hash = (Get-WauPin).Sha256 } }
            Mock Invoke-ExternalProcess { New-TestProcessResult -ExitCode 0 }
            Mock Remove-Item { }

            $result = Install-WingetAutoUpdate

            $result.Status | Should -Be 'Configured'
            Should -Invoke Invoke-ExternalProcess -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq 'msiexec.exe' -and $ArgumentString -match '/i'
            }
        }

        It 'does not downgrade when the installed version is newer than the pin' {
            Mock Test-WauInstalled { $true }
            Mock Get-InstalledWauInfo { [pscustomobject]@{ Version = [version]'99.0.0'; ProductCode = '{11111111-2222-3333-4444-555555555555}' } }
            Mock Invoke-WebRequest { throw 'should not download for a newer install' }
            Mock Invoke-ExternalProcess { throw 'should not run msiexec for a newer install' }

            $result = Install-WingetAutoUpdate

            $result.Status | Should -Be 'AlreadyPresent'
            $result.Version | Should -Be ([version]'99.0.0')
            Should -Invoke Invoke-ExternalProcess -Times 0 -Exactly
        }

        It 'leaves an installed WAU with an unreadable version untouched' {
            Mock Test-WauInstalled { $true }
            Mock Get-InstalledWauInfo { [pscustomobject]@{ Version = $null; ProductCode = $null } }
            Mock Invoke-WebRequest { throw 'should not download when the version is unknown' }
            Mock Invoke-ExternalProcess { throw 'should not run msiexec when the version is unknown' }

            $result = Install-WingetAutoUpdate

            $result.Status | Should -Be 'AlreadyPresent'
            $result.Version | Should -BeNullOrEmpty
            Should -Invoke Invoke-ExternalProcess -Times 0 -Exactly
            Should -Invoke Disable-WauLogonTrigger -Times 1 -Exactly
        }

        It 'aborts without installing when the MSI hash does not match, and still cleans the staging directory' {
            Mock Test-WauInstalled { $false }
            Mock New-WauStagingDirectory { Join-Path $TestDrive 'wau-msi-test' }
            Mock Invoke-WebRequest { }
            Mock Get-FileHash { @{ Hash = 'DEADBEEF' } }
            Mock Invoke-ExternalProcess { throw 'must not run msiexec on a hash mismatch' }
            Mock Remove-Item { }

            $result = Install-WingetAutoUpdate

            $result.Status | Should -Be 'Failed'
            Should -Invoke Invoke-ExternalProcess -Times 0 -Exactly
            Should -Invoke Remove-Item -Times 1 -Exactly -ParameterFilter {
                $Path -eq (Join-Path $TestDrive 'wau-msi-test') -and $Recurse
            }
        }

        It 'returns Failed without downloading when the staging directory cannot be secured' {
            Mock Test-WauInstalled { $false }
            Mock New-WauStagingDirectory { throw 'icacls failed to restrict' }
            Mock Invoke-WebRequest { throw 'should not download without a secured staging directory' }
            Mock Remove-Item { }

            $result = Install-WingetAutoUpdate

            $result.Status | Should -Be 'Failed'
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
            Should -Invoke Remove-Item -Times 0 -Exactly
        }

        It 'treats msiexec exit code 3010 (reboot required) as success' {
            Mock Test-WauInstalled { $false }
            Mock New-WauStagingDirectory { Join-Path $TestDrive 'wau-msi-test' }
            Mock Invoke-WebRequest { }
            Mock Get-FileHash { @{ Hash = (Get-WauPin).Sha256 } }
            Mock Invoke-ExternalProcess { New-TestProcessResult -ExitCode 3010 }
            Mock Remove-Item { }

            (Install-WingetAutoUpdate).Status | Should -Be 'Configured'
        }

        It 'does not install WAU when Microsoft.WindowsAppRuntime.1.8 is missing (it would leave winget unusable)' {
            Mock Get-WindowsAppRuntimeStatus { [pscustomobject]@{ Present = $false; Detail = 'none registered' } }
            Mock Test-WauInstalled { $false }
            Mock Invoke-WebRequest { throw 'should not download WAU without the framework' }
            Mock Invoke-ExternalProcess { throw 'should not run msiexec without the framework' }

            $result = Install-WingetAutoUpdate

            $result.Status | Should -Be 'FrameworkMissing'
            $result.FrameworkMissing | Should -BeTrue
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
            Should -Invoke Write-ErrorMessage -Times 1 -Exactly -ParameterFilter { $Message -match 'NOT installed: Microsoft\.WindowsAppRuntime\.1\.8 is missing' }
        }

        It 'still installs WAU when the framework check itself cannot run' {
            Mock Get-WindowsAppRuntimeStatus { [pscustomobject]@{ Present = $null; Detail = 'could not query installed packages: boom' } }
            Mock Test-WauInstalled { $false }
            Mock New-WauStagingDirectory { Join-Path $TestDrive 'wau-msi-unknown' }
            Mock Invoke-WebRequest { }
            Mock Get-FileHash { @{ Hash = (Get-WauPin).Sha256 } }
            Mock Invoke-ExternalProcess { New-TestProcessResult -ExitCode 0 }
            Mock Remove-Item { }

            $result = Install-WingetAutoUpdate

            $result.Status | Should -Be 'Configured'
            Should -Invoke Write-WarningMessage -Times 1 -Exactly -ParameterFilter { $Message -match 'Could not check for Microsoft\.WindowsAppRuntime\.1\.8' }
        }

        It 'removes the at-logon trigger from an already-installed WAU and reports a missing framework' {
            Mock Get-WindowsAppRuntimeStatus { [pscustomobject]@{ Present = $false; Detail = 'none registered' } }
            Mock Test-WauInstalled { $true }
            Mock Get-InstalledWauInfo { [pscustomobject]@{ Version = [version](Get-WauPin).Version; ProductCode = (Get-WauPin).ProductCode } }
            Mock Invoke-WebRequest { throw 'should not download when WAU is current' }

            $result = Install-WingetAutoUpdate

            $result.Status | Should -Be 'AlreadyPresent'
            $result.FrameworkMissing | Should -BeTrue
            Should -Invoke Disable-WauLogonTrigger -Times 1 -Exactly
            Should -Invoke Write-ErrorMessage -Times 1 -Exactly -ParameterFilter { $Message -match 'its next update run may install a winget that cannot start' }
        }

        It 'does not upgrade an older WAU on a machine without the framework' {
            Mock Get-WindowsAppRuntimeStatus { [pscustomobject]@{ Present = $false; Detail = 'none registered' } }
            Mock Test-WauInstalled { $true }
            Mock Get-InstalledWauInfo { [pscustomobject]@{ Version = [version]'2.11.0'; ProductCode = '{00000000-0000-0000-0000-000000000000}' } }
            Mock Invoke-WebRequest { throw 'should not upgrade WAU without the framework' }

            $result = Install-WingetAutoUpdate

            $result.Status | Should -Be 'AlreadyPresent'
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        }

        It 'previews leaving an existing WAU in place and removing its logon trigger under -WhatIf' {
            Mock Test-WauInstalled { $true }
            Mock Invoke-WebRequest { throw 'should not download under WhatIf' }
            $script:infos = @()
            Mock Write-Info { $script:infos += $Message }

            $result = Install-WingetAutoUpdate -WhatIf

            $result.Status | Should -Be 'DryRun'
            ($script:infos -join "`n") | Should -Match 'already installed: would leave it in place and remove its at-logon trigger'
            Should -Invoke Disable-WauLogonTrigger -Times 0 -Exactly
            Should -Invoke Get-WindowsAppRuntimeStatus -Times 0 -Exactly
        }

        It 'returns dry-run without side effects under -WhatIf' {
            Mock Test-WauInstalled { $false }
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
            Mock Invoke-ExternalProcess { New-TestProcessResult -ExitCode 0 }

            $result = Uninstall-WingetAutoUpdate

            $result | Should -Be $true
            Should -Invoke Invoke-ExternalProcess -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq 'msiexec.exe' -and $ArgumentString -match '/x' -and
                $ArgumentString -match ([regex]::Escape('{11111111-2222-3333-4444-555555555555}')) -and
                $TimeoutSeconds -eq (Get-ProcessTimeoutSeconds -Operation MsiExec)
            }
        }

        It 'falls back to the pinned ProductCode when the registry lookup finds none' {
            Mock Test-WauInstalled { $true }
            Mock Get-InstalledWauInfo { [pscustomobject]@{ Version = $null; ProductCode = $null } }
            Mock Invoke-ExternalProcess { New-TestProcessResult -ExitCode 0 }

            $result = Uninstall-WingetAutoUpdate

            $result | Should -Be $true
            Should -Invoke Invoke-ExternalProcess -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq 'msiexec.exe' -and $ArgumentString -match '/x' -and
                $ArgumentString -match ([regex]::Escape((Get-WauPin).ProductCode))
            }
        }

        It 'returns false when msiexec runs past its time limit (review finding P2-5)' {
            Mock Test-WauInstalled { $true }
            Mock Get-InstalledWauInfo { [pscustomobject]@{ Version = [version]'2.9.0'; ProductCode = '{11111111-2222-3333-4444-555555555555}' } }
            Mock Invoke-ExternalProcess { New-TestProcessResult -TimedOut }

            Uninstall-WingetAutoUpdate | Should -Be $false
            Should -Invoke Write-ErrorMessage -Times 1 -Exactly -ParameterFilter { $Message -match 'did not finish in time' }
        }

        It 'is a no-op when WAU is not installed' {
            Mock Test-WauInstalled { $false }
            Mock Invoke-ExternalProcess { throw 'should not run msiexec when WAU is absent' }

            (Uninstall-WingetAutoUpdate) | Should -Be $true
            Should -Invoke Invoke-ExternalProcess -Times 0 -Exactly
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
            $installBody | Should -Match 'Auto-updates: NOT CONFIGURED'
            $installBody | Should -Match 'Auto-updates: AT RISK'
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
            Should -Invoke Unregister-ScheduledTask -Times 1 -Exactly -ParameterFilter { $TaskName -eq 'WingetAppSetup-ScheduledUpdates' }
            Should -Invoke Remove-Item -Times 1 -Exactly
        }

        It 'is a no-op when there is nothing to clean up' {
            Mock Get-ScheduledTask { throw 'task not found' }
            Mock Test-Path { $false }
            Mock Unregister-ScheduledTask { throw 'should not unregister' }
            Mock Remove-Item { throw 'should not remove' }

            (Remove-LegacyScheduledUpdates) | Should -Be $false
            Should -Invoke Unregister-ScheduledTask -Times 0 -Exactly
        }
    }
}

Describe 'WindowsAppRuntime framework gate for Winget-AutoUpdate (issues #279/#284)' {
    BeforeAll {
        $script:osArch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        $script:otherArch = if ($script:osArch -eq 'X64') { 'Arm64' } else { 'X64' }
    }

    Context 'Get-WindowsAppRuntimeStatus' {
        It 'is satisfied by a framework for this OS architecture at or above 8000.616.304.0' {
            Mock Get-WindowsAppRuntimePackageInfo { [pscustomobject]@{ Version = [version]'8000.921.1539.0'; Architecture = $script:osArch } }

            (Get-WindowsAppRuntimeStatus).Present | Should -BeTrue
        }

        It 'is not satisfied by an older framework only' {
            Mock Get-WindowsAppRuntimePackageInfo { [pscustomobject]@{ Version = [version]'8000.500.0.0'; Architecture = $script:osArch } }

            (Get-WindowsAppRuntimeStatus).Present | Should -BeFalse
        }

        It 'is not satisfied by a framework for another architecture only' {
            Mock Get-WindowsAppRuntimePackageInfo { [pscustomobject]@{ Version = [version]'8000.921.1539.0'; Architecture = $script:otherArch } }

            (Get-WindowsAppRuntimeStatus).Present | Should -BeFalse
        }

        It 'reports none registered when no framework package exists' {
            Mock Get-WindowsAppRuntimePackageInfo { }

            $status = Get-WindowsAppRuntimeStatus
            $status.Present | Should -BeFalse
            $status.Detail | Should -Match 'none registered'
        }

        It 'returns an unknown result ($null), not "missing", when the query fails' {
            Mock Get-WindowsAppRuntimePackageInfo { throw 'Appx module unavailable' }

            $status = Get-WindowsAppRuntimeStatus
            $status.Present | Should -BeNullOrEmpty
            $status.Detail | Should -Match 'Appx module unavailable'
        }
    }

    Context 'Get-WindowsAppRuntimePackageInfo' {
        It 'parses Version|Architecture lines from the Windows PowerShell query and skips anything else' -Skip:($PSVersionTable.PSEdition -ne 'Core') {
            Mock powershell.exe { $global:LASTEXITCODE = 0; '8000.921.1539.0|X64'; 'WARNING: noise'; '' }

            $packages = @(Get-WindowsAppRuntimePackageInfo)

            $packages.Count | Should -Be 1
            $packages[0].Version | Should -Be ([version]'8000.921.1539.0')
            $packages[0].Architecture | Should -Be 'X64'
        }

        It 'throws when the Windows PowerShell query fails' -Skip:($PSVersionTable.PSEdition -ne 'Core') {
            Mock powershell.exe { $global:LASTEXITCODE = 1 }

            { Get-WindowsAppRuntimePackageInfo } | Should -Throw '*Get-AppxPackage -AllUsers failed*'
        }
    }
}

Describe 'Disable-WauLogonTrigger' {
    BeforeAll {
        function New-FakeTrigger {
            param ([string]$ClassName)
            [pscustomobject]@{ CimClass = [pscustomobject]@{ CimClassName = $ClassName } }
        }
    }

    BeforeEach {
        Mock Write-Info { }
        Mock Write-WarningMessage { }
        Mock Test-Path { $false }
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -eq 'HKLM:\SOFTWARE\Romanitho\Winget-AutoUpdate' }
        Mock Set-ItemProperty { }
        # -RemoveParameterType: on Windows the real Set-ScheduledTask types -Trigger as
        # CimInstance[], which would reject these fake triggers before the mock body runs.
        Mock Set-ScheduledTask { } -RemoveParameterType Trigger
    }

    It 'removes the logon trigger, keeps the weekly one, and records WAU_UpdatesAtLogon = 0' {
        Mock Get-ScheduledTask { [pscustomobject]@{ Triggers = @((New-FakeTrigger 'MSFT_TaskLogonTrigger'), (New-FakeTrigger 'MSFT_TaskWeeklyTrigger')) } }

        Disable-WauLogonTrigger | Should -BeTrue

        Should -Invoke Set-ScheduledTask -Times 1 -Exactly -ParameterFilter {
            @($Trigger).Count -eq 1 -and @($Trigger)[0].CimClass.CimClassName -eq 'MSFT_TaskWeeklyTrigger'
        }
        Should -Invoke Set-ItemProperty -Times 1 -Exactly -ParameterFilter { $Name -eq 'WAU_UpdatesAtLogon' -and $Value -eq 0 }
    }

    It 'leaves a task alone when the logon trigger is its only trigger (WAU would otherwise never run)' {
        Mock Get-ScheduledTask { [pscustomobject]@{ Triggers = @((New-FakeTrigger 'MSFT_TaskLogonTrigger')) } }

        Disable-WauLogonTrigger | Should -BeFalse

        Should -Invoke Set-ScheduledTask -Times 0 -Exactly
    }

    It 'does nothing to the task when it has no logon trigger' {
        Mock Get-ScheduledTask { [pscustomobject]@{ Triggers = @((New-FakeTrigger 'MSFT_TaskWeeklyTrigger')) } }

        Disable-WauLogonTrigger | Should -BeFalse

        Should -Invoke Set-ScheduledTask -Times 0 -Exactly
    }

    It 'warns instead of throwing when the task cannot be changed' {
        Mock Get-ScheduledTask { [pscustomobject]@{ Triggers = @((New-FakeTrigger 'MSFT_TaskLogonTrigger'), (New-FakeTrigger 'MSFT_TaskWeeklyTrigger')) } }
        Mock Set-ScheduledTask { throw 'Access is denied.' } -RemoveParameterType Trigger

        { Disable-WauLogonTrigger } | Should -Not -Throw

        Should -Invoke Write-WarningMessage -Times 1 -Exactly -ParameterFilter { $Message -match 'Could not remove the Winget-AutoUpdate at-logon trigger: Access is denied' }
    }
}

Describe 'Wait-WauIdle' {
    BeforeEach {
        Mock Write-Info { }
        Mock Write-Success { }
        Mock Write-WarningMessage { }
        Mock Start-Sleep { }
    }

    It 'returns immediately when no WAU task is running' {
        Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = 'Winget-AutoUpdate'; State = 'Ready' } }

        Wait-WauIdle | Should -BeTrue

        Should -Invoke Start-Sleep -Times 0 -Exactly
        Should -Invoke Write-Info -Times 0 -Exactly
    }

    It 'returns immediately when WAU is not installed' {
        Mock Get-ScheduledTask { }

        Wait-WauIdle | Should -BeTrue
    }

    It 'waits while a WAU task is running and continues once it finishes' {
        $script:polls = 0
        Mock Get-ScheduledTask {
            $script:polls++
            $state = if ($script:polls -lt 3) { 'Running' } else { 'Ready' }
            [pscustomobject]@{ TaskName = 'Winget-AutoUpdate'; State = $state }
        }

        Wait-WauIdle -PollIntervalSeconds 1 | Should -BeTrue

        Should -Invoke Start-Sleep -Times 2 -Exactly
        Should -Invoke Write-Info -Times 1 -Exactly -ParameterFilter { $Message -match 'Winget-AutoUpdate is running \(Winget-AutoUpdate\)' }
        Should -Invoke Write-Success -Times 1 -Exactly
    }

    It 'gives up with a warning at the time limit' {
        Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = 'Winget-AutoUpdate'; State = 'Running' } }

        Wait-WauIdle -TimeoutSeconds 0 -PollIntervalSeconds 1 | Should -BeFalse

        Should -Invoke Write-WarningMessage -Times 1 -Exactly -ParameterFilter { $Message -match 'still running' }
    }
}
