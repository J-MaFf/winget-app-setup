# Elevation.Tests.ps1
# Tests for WingetAppSetup/Public/Elevation.ps1 and Private/Elevation.ps1:
# Restart-WithElevation and the module-context invocation detection.
# Split from the old single-file suite Test-WingetAppInstall.Tests.ps1 (issue #192).

# Load the module's functions once for this file. TestHelpers.ps1 resolves the repo paths
# and dot-sources WingetAppSetup/Private + Public (the single source of truth; the
# distributable winget-app-install.ps1 is generated from it by build/Build-WingetInstallScript.ps1).
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'Test-IsAdmin' {
    BeforeAll {
        # Dot-source the script under test so these tests exercise the real implementation (#135).
        . $script:InstallerScriptPath

        Mock Write-Host { }
        Mock Write-Warning { }
    }

    It 'Returns $true when the current principal is in the Administrator role' {
        Mock Get-CurrentWindowsPrincipal {
            [PSCustomObject]@{ } | Add-Member -MemberType ScriptMethod -Name IsInRole -Value { param($role) $true } -PassThru
        }

        Test-IsAdmin | Should -Be $true
    }

    It 'Returns $false when the current principal is not in the Administrator role' {
        Mock Get-CurrentWindowsPrincipal {
            [PSCustomObject]@{ } | Add-Member -MemberType ScriptMethod -Name IsInRole -Value { param($role) $false } -PassThru
        }

        Test-IsAdmin | Should -Be $false
    }

    It 'Fails safe: returns $true and warns instead of propagating when the identity check throws (issue: consolidate-admin-check-helper)' {
        # This is the behavior PowerShell7Bootstrap.ps1 already had before consolidation and the
        # other two call sites (Install.ps1, winget-app-uninstall.ps1) lacked; Test-IsAdmin now
        # applies it everywhere. Mocking Get-CurrentWindowsPrincipal (rather than the static
        # WindowsIdentity/WindowsPrincipal .NET calls, which Pester cannot mock directly) simulates
        # the underlying check throwing.
        Mock Get-CurrentWindowsPrincipal { throw 'simulated identity check failure' }
        Mock Write-WarningMessage { }

        Test-IsAdmin | Should -Be $true
        Should -Invoke Write-WarningMessage -Times 1
    }
}

Describe 'Restart-WithElevation' {
    BeforeAll {
        # Dot-source the script under test so these tests exercise the real implementation (#135).
        . $script:InstallerScriptPath

        Mock Write-Host { }
        Mock Write-Warning { }
    }

    It 'Should use Windows Terminal when available' {
        Mock Start-Process { } -ParameterFilter { $FilePath -eq 'wt.exe' }
        Mock Start-Process { } -ParameterFilter { $FilePath -eq 'pwsh.exe' }

        $result = Restart-WithElevation -PowerShellExecutable 'pwsh.exe' -ScriptPath 'C:\script.ps1' -WindowsTerminalExecutable 'wt.exe'

        Should -Invoke Start-Process -ParameterFilter { $FilePath -eq 'wt.exe' } -Times 1
        Should -Invoke Start-Process -ParameterFilter { $FilePath -eq 'pwsh.exe' } -Times 0
        $result | Should -Be 'WindowsTerminal'
    }

    It 'Should fall back to PowerShell when Windows Terminal launch fails' {
        Mock Start-Process { throw 'Failed to launch wt' } -ParameterFilter { $FilePath -eq 'wt.exe' }
        Mock Start-Process { } -ParameterFilter { $FilePath -eq 'pwsh.exe' }

        $result = Restart-WithElevation -PowerShellExecutable 'pwsh.exe' -ScriptPath 'C:\script.ps1' -WindowsTerminalExecutable 'wt.exe'

        Should -Invoke Start-Process -ParameterFilter { $FilePath -eq 'wt.exe' } -Times 1
        Should -Invoke Start-Process -ParameterFilter { $FilePath -eq 'pwsh.exe' } -Times 1
        $result | Should -Be 'PowerShell'
    }

    It 'Should use PowerShell when Windows Terminal is not available' {
        Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'wt.exe' }
        Mock Start-Process { } -ParameterFilter { $FilePath -eq 'pwsh.exe' }

        $result = Restart-WithElevation -PowerShellExecutable 'pwsh.exe' -ScriptPath 'C:\script.ps1'

        Should -Invoke Start-Process -ParameterFilter { $FilePath -eq 'pwsh.exe' } -Times 1
        $result | Should -Be 'PowerShell'
    }

    It 'Should forward AdditionalArguments to the elevated relaunch' {
        Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'wt.exe' }
        Mock Start-Process { } -ParameterFilter { $FilePath -eq 'pwsh.exe' }

        Restart-WithElevation -PowerShellExecutable 'pwsh.exe' -ScriptPath 'C:\script.ps1' -AdditionalArguments '-WhatIf'

        Should -Invoke Start-Process -Times 1 -ParameterFilter {
            $FilePath -eq 'pwsh.exe' -and (($ArgumentList -join ' ') -match '-File "C:\\script\.ps1" -WhatIf')
        }
    }

    It 'Should not append arguments when AdditionalArguments is empty' {
        Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'wt.exe' }
        Mock Start-Process { } -ParameterFilter { $FilePath -eq 'pwsh.exe' }

        Restart-WithElevation -PowerShellExecutable 'pwsh.exe' -ScriptPath 'C:\script.ps1'

        Should -Invoke Start-Process -Times 1 -ParameterFilter {
            $FilePath -eq 'pwsh.exe' -and (($ArgumentList -join ' ') -notmatch '-WhatIf')
        }
    }

    It 'Should forward multiple AdditionalArguments to the elevated relaunch' {
        Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'wt.exe' }
        Mock Start-Process { } -ParameterFilter { $FilePath -eq 'pwsh.exe' }

        Restart-WithElevation -PowerShellExecutable 'pwsh.exe' -ScriptPath 'C:\script.ps1' -AdditionalArguments @('-WhatIf', '-SkipSystemCheck')

        Should -Invoke Start-Process -Times 1 -ParameterFilter {
            $FilePath -eq 'pwsh.exe' -and (($ArgumentList -join ' ') -match '-File "C:\\script\.ps1" -WhatIf -SkipSystemCheck')
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
