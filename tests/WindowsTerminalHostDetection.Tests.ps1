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

    It 'Returns true when the default-terminal-application registry values point at an installed Windows Terminal' {
        Mock Get-ItemProperty {
            [pscustomobject]@{
                DelegationConsole  = '{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}'
                DelegationTerminal = '{E12CFF52-A866-4C77-9A90-F570A7AA2C6B}'
            }
        } -ParameterFilter { $Path -eq 'HKCU:\Console\%%Startup' }
        Mock Test-WindowsTerminalInstalled { $true }

        Test-WindowsTerminalHostsCurrentSession | Should -Be $true
    }

    # Review finding P3-35: nothing clears these values when Windows Terminal is removed, and a
    # delegation to a Windows Terminal that is not there hosts nothing. Counting them anyway made
    # the catalog skip the Windows Terminal install as 'not applicable' on every later run.
    It 'Ignores the default-terminal-application registry values while Windows Terminal is not installed' {
        Mock Get-ItemProperty {
            [pscustomobject]@{
                DelegationConsole  = '{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}'
                DelegationTerminal = '{E12CFF52-A866-4C77-9A90-F570A7AA2C6B}'
            }
        } -ParameterFilter { $Path -eq 'HKCU:\Console\%%Startup' }
        Mock Test-WindowsTerminalInstalled { $false }

        Test-WindowsTerminalHostsCurrentSession | Should -Be $false
        Should -Invoke Test-WindowsTerminalInstalled -Times 1 -Exactly
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
    BeforeEach {
        $script:stableSettingsPath = 'C:\Users\u\AppData\Local\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'
        $script:previewSettingsPath = 'C:\Users\u\AppData\Local\Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json'
        $script:unpackagedSettingsPath = 'C:\Users\u\AppData\Local\Microsoft\Windows Terminal\settings.json'
    }

    It 'Returns true when Get-AppxPackage finds the Microsoft.WindowsTerminal package' {
        Mock Get-AppxPackage { [pscustomobject]@{ Name = 'Microsoft.WindowsTerminal' } } -ParameterFilter { $Name -eq 'Microsoft.WindowsTerminal' }
        Mock Get-AppxPackage { }
        Mock Get-WindowsTerminalSettingsPaths { throw 'must not be called when Get-AppxPackage already answered' }

        Test-WindowsTerminalInstalled | Should -Be $true
    }

    # Review findings P3-34, P3-35: the wildcard query also matched Windows Terminal Preview, and a
    # settings.json left behind counted as an installed Windows Terminal.
    It 'Asks Get-AppxPackage for exactly Microsoft.WindowsTerminal, so Windows Terminal Preview does not count' {
        Mock Get-AppxPackage { [pscustomobject]@{ Name = 'Microsoft.WindowsTerminalPreview' } } -ParameterFilter { $Name -eq 'Microsoft.WindowsTerminal*' }
        Mock Get-AppxPackage { }
        Mock Get-WindowsTerminalSettingsPaths { @($script:previewSettingsPath) }

        Test-WindowsTerminalInstalled | Should -Be $false
        Should -Invoke Get-AppxPackage -Times 1 -Exactly -ParameterFilter { $Name -eq 'Microsoft.WindowsTerminal' }
    }

    It 'Trusts Get-AppxPackage when it finds no package, whatever settings.json was left behind' {
        Mock Get-AppxPackage { $null }
        Mock Get-WindowsTerminalSettingsPaths { @($script:stableSettingsPath, $script:unpackagedSettingsPath) }

        Test-WindowsTerminalInstalled | Should -Be $false
    }

    It 'Falls back to the stable package''s settings.json when Get-AppxPackage throws' {
        Mock Get-AppxPackage { throw 'Operation is not supported on this platform.' }
        Mock Get-WindowsTerminalSettingsPaths { @($script:stableSettingsPath) }

        Test-WindowsTerminalInstalled | Should -Be $true
    }

    It 'Does not count a Preview or unpackaged settings.json when Get-AppxPackage throws' {
        Mock Get-AppxPackage { throw 'Operation is not supported on this platform.' }
        Mock Get-WindowsTerminalSettingsPaths { @($script:previewSettingsPath, $script:unpackagedSettingsPath) }

        Test-WindowsTerminalInstalled | Should -Be $false
    }

    It 'Returns false when Get-AppxPackage throws and no settings.json exists' {
        Mock Get-AppxPackage { throw 'Operation is not supported on this platform.' }
        Mock Get-WindowsTerminalSettingsPaths { @() }

        Test-WindowsTerminalInstalled | Should -Be $false
    }
}
