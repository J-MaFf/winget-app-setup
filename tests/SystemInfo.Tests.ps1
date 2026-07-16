# SystemInfo.Tests.ps1
# Tests for WingetAppSetup/Private/SystemInfo.ps1: OS build number and manufacturer lookups.
# Split from the old single-file suite Test-WingetAppInstall.Tests.ps1 (issue #192).
# Renamed from Environment.Tests.ps1 when the dead PATH-mutation helpers (Add-ToEnvironmentPath,
# Test-PathInEnvironment, Test-PathListContainsEntry, Get-PersistedEnvironmentPath,
# Set-PersistedEnvironmentPath — orphaned since the homegrown updater was removed, issue #168/#179)
# were deleted along with their tests, leaving only the still-live functions in this file.

# Load the module's functions once for this file. TestHelpers.ps1 resolves the repo paths
# and dot-sources WingetAppSetup/Private + Public (the single source of truth; the
# distributable winget-app-install.ps1 is generated from it by build/Build-WingetInstallScript.ps1).
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'Get-ComputerManufacturer (issue #217)' {
    BeforeEach {
        Mock Get-CimInstance { [pscustomobject]@{ Manufacturer = 'Dell Inc.' } }
    }

    It 'Returns the Win32_ComputerSystem manufacturer as a string' {
        $manufacturer = Get-ComputerManufacturer

        $manufacturer | Should -Be 'Dell Inc.'
        $manufacturer | Should -BeOfType [string]
        Should -Invoke Get-CimInstance -Times 1 -Exactly -ParameterFilter { $ClassName -eq 'Win32_ComputerSystem' }
    }
}
