# Tests for WingetAppSetup/Private/WindowsTerminalHostDetection.ps1 (issue #271): detecting
# whether the current session's console is itself hosted by Windows Terminal (the self-lock
# condition that made winget repeatedly fail to launch while installing/verifying
# Microsoft.WindowsTerminal), whether Windows Terminal is actually installed, and the uninstaller's
# reset of the default-terminal setting once it is not (review finding P3-18).

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

Describe 'Reset-WindowsTerminalDelegation (review finding P3-18)' {
    BeforeEach {
        Mock Write-Host { }
        $script:successMessages = @()
        Mock Write-Success { $script:successMessages += $Message }
        $script:warningMessages = @()
        Mock Write-WarningMessage { $script:warningMessages += $Message }
        $script:infoMessages = @()
        Mock Write-Info { $script:infoMessages += $Message }
        Mock Test-WindowsTerminalInstalled { $false }
        Mock Remove-ItemProperty { }

        # What Set-WindowsTerminalAsDefaultTerminalApplication writes, captured from the real
        # function so the two cannot drift apart.
        $script:written = @{}
        Mock Test-Path { $true } -ParameterFilter { $Path -eq 'HKCU:\Console\%%Startup' }
        Mock Get-ItemProperty { [pscustomobject]@{} } -ParameterFilter { $Path -eq 'HKCU:\Console\%%Startup' }
        Mock New-ItemProperty { $script:written[$Name] = $Value }
        [void](Set-WindowsTerminalAsDefaultTerminalApplication)
        $script:installerValues = [pscustomobject]@{
            DelegationConsole  = $script:written['DelegationConsole']
            DelegationTerminal = $script:written['DelegationTerminal']
        }
    }

    It 'Removes the values the installer writes once Windows Terminal is not installed' {
        Mock Get-ItemProperty { $script:installerValues } -ParameterFilter { $Path -eq 'HKCU:\Console\%%Startup' }

        Reset-WindowsTerminalDelegation | Should -BeTrue

        Should -Invoke Remove-ItemProperty -Times 1 -Exactly -ParameterFilter {
            $Path -eq 'HKCU:\Console\%%Startup' -and (@($Name | Sort-Object) -join ',') -eq 'DelegationConsole,DelegationTerminal'
        }
        $script:successMessages | Should -Contain 'Removed the default terminal application setting that named Windows Terminal, which is not installed: Windows chooses the terminal again.'
    }

    It 'Leaves the values alone while Windows Terminal is installed' {
        Mock Get-ItemProperty { $script:installerValues } -ParameterFilter { $Path -eq 'HKCU:\Console\%%Startup' }
        Mock Test-WindowsTerminalInstalled { $true }

        Reset-WindowsTerminalDelegation | Should -BeFalse

        Should -Invoke Remove-ItemProperty -Times 0 -Exactly
    }

    It 'Leaves values that name another terminal (<Case>) alone' -ForEach @(
        @{ Case = 'the console host'; Console = '{B23D10C0-E52E-411E-9D5B-C09FDF709C7D}'; Terminal = '{B23D10C0-E52E-411E-9D5B-C09FDF709C7D}' }
        @{ Case = 'Windows Terminal Preview'; Console = '{06EC847C-C0A5-46B8-92CB-7C92F6E35CD5}'; Terminal = '{86633F1F-6454-40EC-89CE-DA4EBA977EE2}' }
        @{ Case = 'Let Windows decide'; Console = '{00000000-0000-0000-0000-000000000000}'; Terminal = '{00000000-0000-0000-0000-000000000000}' }
    ) {
        $script:values = [pscustomobject]@{ DelegationConsole = $Console; DelegationTerminal = $Terminal }
        Mock Get-ItemProperty { $script:values } -ParameterFilter { $Path -eq 'HKCU:\Console\%%Startup' }

        Reset-WindowsTerminalDelegation | Should -BeFalse

        Should -Invoke Remove-ItemProperty -Times 0 -Exactly
        Should -Invoke Test-WindowsTerminalInstalled -Times 0 -Exactly
    }

    It 'Does nothing when there is no default-terminal setting' {
        Mock Get-ItemProperty { throw 'key not found' } -ParameterFilter { $Path -eq 'HKCU:\Console\%%Startup' }

        Reset-WindowsTerminalDelegation | Should -BeFalse

        Should -Invoke Remove-ItemProperty -Times 0 -Exactly
    }

    It 'Only says what it would remove in a dry run' {
        Mock Get-ItemProperty { $script:installerValues } -ParameterFilter { $Path -eq 'HKCU:\Console\%%Startup' }

        Reset-WindowsTerminalDelegation -WhatIf | Should -BeTrue

        Should -Invoke Remove-ItemProperty -Times 0 -Exactly
        ($script:infoMessages -join "`n") | Should -Match '^\[DRY-RUN\] Would remove the default terminal application setting'
    }

    It 'Warns and returns false when the values cannot be removed' {
        Mock Get-ItemProperty { $script:installerValues } -ParameterFilter { $Path -eq 'HKCU:\Console\%%Startup' }
        Mock Remove-ItemProperty { throw 'Registry denied' }

        Reset-WindowsTerminalDelegation | Should -BeFalse

        ($script:warningMessages -join "`n") | Should -Match 'Could not remove the default terminal application setting that names Windows Terminal'
    }
}
