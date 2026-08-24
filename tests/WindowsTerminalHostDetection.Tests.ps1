# Tests for WingetAppSetup/Private/WindowsTerminalHostDetection.ps1 (issue #271): detecting
# whether the current session's console is itself hosted by Windows Terminal (the self-lock
# condition that made winget repeatedly fail to launch while installing/verifying
# Microsoft.WindowsTerminal), and whether Windows Terminal is actually installed.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'Test-WindowsTerminalHostsCurrentSession' {
    BeforeEach {
        # Isolate every test from whatever WT_SESSION happens to be set to on the machine
        # actually running the suite (e.g. a developer running Pester from inside Windows
        # Terminal itself).
        $script:originalWtSession = $env:WT_SESSION
        $env:WT_SESSION = $null

        # Default: no delegation registry key, no matching ancestor - "not hosted".
        Mock Get-ItemProperty { throw 'key not found' } -ParameterFilter { $Path -eq 'HKCU:\Console\%%Startup' }
        Mock Get-CimInstance { $null }
    }

    AfterEach {
        $env:WT_SESSION = $script:originalWtSession
    }

    It 'Returns true when WT_SESSION is set, without probing the registry or process tree' {
        $env:WT_SESSION = '12345678-1234-1234-1234-123456789012'

        Test-WindowsTerminalHostsCurrentSession | Should -Be $true

        Should -Invoke Get-ItemProperty -Times 0
        Should -Invoke Get-CimInstance -Times 0
    }

    It 'Returns true when the default-terminal-application registry values point at Windows Terminal' {
        Mock Get-ItemProperty {
            [pscustomobject]@{
                DelegationConsole  = '{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}'
                DelegationTerminal = '{E12CFF52-A866-4C77-9A90-F570A7AA2C6B}'
            }
        } -ParameterFilter { $Path -eq 'HKCU:\Console\%%Startup' }

        Test-WindowsTerminalHostsCurrentSession | Should -Be $true
    }

    It 'Returns false when the registry values are set to something other than Windows Terminal' {
        Mock Get-ItemProperty {
            [pscustomobject]@{
                DelegationConsole  = '{B23D10C0-E52E-411E-9D5B-C09FDF709C7D}'
                DelegationTerminal = '{B23D10C0-E52E-411E-9D5B-C09FDF709C7D}'
            }
        } -ParameterFilter { $Path -eq 'HKCU:\Console\%%Startup' }

        Test-WindowsTerminalHostsCurrentSession | Should -Be $false
    }

    It 'Returns true when a parent process is WindowsTerminal.exe' {
        Mock Get-CimInstance {
            param($Filter)
            if ($Filter -match [regex]::Escape($PID)) {
                return [pscustomobject]@{ Name = 'pwsh.exe'; ParentProcessId = 999 }
            }
            [pscustomobject]@{ Name = 'WindowsTerminal.exe'; ParentProcessId = $null }
        }

        Test-WindowsTerminalHostsCurrentSession | Should -Be $true
    }

    It 'Returns true when a parent process is OpenConsole.exe' {
        Mock Get-CimInstance {
            param($Filter)
            if ($Filter -match [regex]::Escape($PID)) {
                return [pscustomobject]@{ Name = 'pwsh.exe'; ParentProcessId = 999 }
            }
            [pscustomobject]@{ Name = 'OpenConsole.exe'; ParentProcessId = $null }
        }

        Test-WindowsTerminalHostsCurrentSession | Should -Be $true
    }

    It 'Returns false when no signal indicates Windows Terminal hosting' {
        Mock Get-CimInstance { [pscustomobject]@{ Name = 'conhost.exe'; ParentProcessId = $null } }

        Test-WindowsTerminalHostsCurrentSession | Should -Be $false
    }

    It 'Fails open (returns false) when the process-ancestry probe throws' {
        Mock Get-CimInstance { throw 'WMI unavailable' }

        Test-WindowsTerminalHostsCurrentSession | Should -Be $false
    }
}

Describe 'Test-WindowsTerminalInstalled' {
    It 'Returns true when Get-AppxPackage finds a registered package' {
        Mock Get-AppxPackage { [pscustomobject]@{ Name = 'Microsoft.WindowsTerminal' } } -ParameterFilter { $Name -eq 'Microsoft.WindowsTerminal*' }
        Mock Get-WindowsTerminalSettingsPaths { throw 'must not be called when Get-AppxPackage already answered' }

        Test-WindowsTerminalInstalled | Should -Be $true
    }

    It 'Falls back to settings.json presence when Get-AppxPackage finds nothing' {
        Mock Get-AppxPackage { $null }
        Mock Get-WindowsTerminalSettingsPaths { @('C:\temp\settings.json') }

        Test-WindowsTerminalInstalled | Should -Be $true
    }

    It 'Falls back to settings.json presence when Get-AppxPackage throws' {
        Mock Get-AppxPackage { throw 'Operation is not supported on this platform.' }
        Mock Get-WindowsTerminalSettingsPaths { @('C:\temp\settings.json') }

        Test-WindowsTerminalInstalled | Should -Be $true
    }

    It 'Returns false when neither Get-AppxPackage nor settings.json find anything' {
        Mock Get-AppxPackage { $null }
        Mock Get-WindowsTerminalSettingsPaths { @() }

        Test-WindowsTerminalInstalled | Should -Be $false
    }
}
