# Environment.Tests.ps1
# Tests for WingetAppSetup/Private/Environment.ps1: persisted PATH read/write helpers
# and the PATH-entry containment checks.
# Split from the old single-file suite Test-WingetAppInstall.Tests.ps1 (issue #192).

# Load the module's functions once for this file. TestHelpers.ps1 resolves the repo paths
# and dot-sources WingetAppSetup/Private + Public (the single source of truth; the
# distributable winget-app-install.ps1 is generated from it by build/Build-WingetInstallScript.ps1).
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
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
