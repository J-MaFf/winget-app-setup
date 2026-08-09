# Tests for WingetAppSetup/Private/WingetLaunchResilience.ps1 (issue #258): classification of
# transient Start-Process winget-launch failures, and resolution of a concrete winget.exe that
# bypasses the per-user app-execution alias while DesktopAppInstaller is mid-upgrade.

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
