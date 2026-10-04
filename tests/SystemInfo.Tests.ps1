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

# Review finding P3-33: a CIM failure is a non-terminating error, so without -ErrorAction Stop
# Get-ComputerManufacturer returned '' and the Dell condition read "not Dell": Dell Command Update
# was skipped as not applicable on a Dell PC and the run exited 0. With no answer it now throws,
# and a throwing condition fails open (Test-AppApplicability), so the install is attempted.
Describe 'Get-ComputerManufacturer without an answer (review finding P3-33)' {
    It 'Throws when the CIM query writes a non-terminating error' {
        Mock Get-CimInstance { Write-Error 'Invalid class' }

        { Get-ComputerManufacturer } | Should -Throw '*Invalid class*'
    }

    It 'Throws when Win32_ComputerSystem reports an empty manufacturer' {
        Mock Get-CimInstance { [pscustomobject]@{ Manufacturer = '  ' } }

        { Get-ComputerManufacturer } | Should -Throw '*no manufacturer*'
    }

    It 'Throws when the query returns no instance at all' {
        Mock Get-CimInstance { }

        { Get-ComputerManufacturer } | Should -Throw '*no manufacturer*'
    }
}

# Review finding P3-32: the seam for the catalog's architecture gate (Adobe.Acrobat.Reader.64-bit).
Describe 'Get-OSArchitecture (review finding P3-32)' {
    It 'Returns the OS architecture as .NET reports it, never the process view from the environment' {
        $architecture = Get-OSArchitecture

        $architecture | Should -BeOfType [string]
        $architecture | Should -Be ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString())
        $architecture | Should -BeIn @('X64', 'Arm64', 'X86', 'Arm')
    }

    It 'Does not read PROCESSOR_ARCHITECTURE, which an x64 process under emulation on ARM64 sees as AMD64' {
        $savedArchitecture = $env:PROCESSOR_ARCHITECTURE
        $savedArchitectureW6432 = $env:PROCESSOR_ARCHITEW6432
        try {
            $expected = Get-OSArchitecture
            $env:PROCESSOR_ARCHITECTURE = 'IA64'
            $env:PROCESSOR_ARCHITEW6432 = 'IA64'

            Get-OSArchitecture | Should -Be $expected
        }
        finally {
            $env:PROCESSOR_ARCHITECTURE = $savedArchitecture
            $env:PROCESSOR_ARCHITEW6432 = $savedArchitectureW6432
        }
    }
}
