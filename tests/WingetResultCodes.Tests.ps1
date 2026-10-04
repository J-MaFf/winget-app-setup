# WingetResultCodes.Tests.ps1
# Tests for WingetAppSetup/Private/WingetResultCodes.ps1: the one table of winget exit codes the
# installer names and acts on (review findings P2-15 and P3-16).

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'Get-WingetExitCodeInfo' {
    # Hex values from winget's returnCodes.md; the Int32 is what winget's process exit code holds.
    It 'Names <Hex> <Name> with class "<Class>"' -ForEach @(
        @{ Hex = '8A150102'; Name = 'INSTALL_INSTALL_IN_PROGRESS'; Class = 'InstallInProgress' }
        @{ Hex = '8A150101'; Name = 'INSTALL_PACKAGE_IN_USE'; Class = 'InUse' }
        @{ Hex = '8A150103'; Name = 'INSTALL_FILE_IN_USE'; Class = 'InUse' }
        @{ Hex = '8A150111'; Name = 'INSTALL_PACKAGE_IN_USE_BY_APPLICATION'; Class = 'InUse' }
        @{ Hex = '8A150109'; Name = 'INSTALL_REBOOT_REQUIRED_TO_FINISH'; Class = 'RestartRequired' }
        @{ Hex = '8A15010A'; Name = 'INSTALL_REBOOT_REQUIRED_FOR_INSTALL'; Class = 'RestartRequiredFirst' }
        @{ Hex = '8A15010B'; Name = 'INSTALL_REBOOT_INITIATED'; Class = 'RestartRequired' }
        @{ Hex = '8A150105'; Name = 'INSTALL_DISK_FULL'; Class = '' }
        @{ Hex = '8A15003A'; Name = 'BLOCKED_BY_POLICY'; Class = '' }
        @{ Hex = '8A15010F'; Name = 'INSTALL_BLOCKED_BY_POLICY'; Class = '' }
        @{ Hex = '8A150010'; Name = 'NO_APPLICABLE_INSTALLER'; Class = '' }
        @{ Hex = '8A15002B'; Name = 'UPDATE_NOT_APPLICABLE'; Class = '' }
        @{ Hex = '80004004'; Name = 'E_ABORT'; Class = '' }
        @{ Hex = '80073D19'; Name = 'ERROR_DEPLOYMENT_BLOCKED_BY_USER_LOG_OFF'; Class = '' }
    ) {
        $code = [Convert]::ToInt32($Hex, 16)

        $info = Get-WingetExitCodeInfo -ExitCode $code

        $info.ExitCode | Should -Be $code
        $info.Hex | Should -Be "0x$Hex"
        $info.Name | Should -Be $Name
        $info.Class | Should -Be $Class
        $info.Meaning | Should -Not -BeNullOrEmpty
    }

    It 'Returns nothing for <Case>' -ForEach @(
        @{ Case = 'success (0)'; Code = 0 }
        @{ Case = 'no exit code'; Code = $null }
        @{ Case = 'a code it does not know'; Code = 1 }
    ) {
        Get-WingetExitCodeInfo -ExitCode $Code | Should -BeNullOrEmpty
    }

    It 'Gives every named code a meaning that can follow "Failed to install: X (" and is plain ASCII' {
        # The generated installer must stay ASCII (Windows PowerShell 5.1 parses it), and the meaning
        # is the first clause of a failure reason.
        $definition = (Get-Command Get-WingetExitCodeInfo).Definition
        $hexes = [regex]::Matches($definition, "'0x([0-9A-F]{8})' = @\(") | ForEach-Object { $_.Groups[1].Value }
        @($hexes).Count | Should -BeGreaterThan 40

        foreach ($hex in $hexes) {
            $info = Get-WingetExitCodeInfo -ExitCode ([Convert]::ToInt32($hex, 16))
            $info.Name | Should -Match '^[A-Z0-9_]+$'
            $info.Meaning | Should -Match '^[a-z0-9]'
            $info.Meaning | Should -Not -Match '[^\x20-\x7E]'
            $info.Meaning | Should -Not -Match '[.;]$'
        }
    }
}

Describe 'Format-WingetExitCode' {
    It 'Prints a known code in hex with its name' {
        Format-WingetExitCode -ExitCode -1978334974 | Should -Be '0x8A150102 INSTALL_INSTALL_IN_PROGRESS'
    }

    It 'Prints <Case> in hex only' -ForEach @(
        @{ Case = 'an unknown code'; Code = 1; Expected = '0x00000001' }
        @{ Case = 'success'; Code = 0; Expected = '0x00000000' }
        @{ Case = 'an unknown HRESULT'; Code = -2147024891; Expected = '0x80070005' }
    ) {
        Format-WingetExitCode -ExitCode $Code | Should -Be $Expected
    }
}

Describe 'Test-RestartRequiredFirst' {
    It 'Is true for 0x8A15010A, the installer that cannot run until Windows restarts' {
        Test-RestartRequiredFirst -InstallResult @{ ExitCode = -1978334966 } | Should -BeTrue
    }

    It 'Is false for <Case>' -ForEach @(
        @{ Case = 'no install result'; Result = $null }
        @{ Case = 'no exit code'; Result = @{ ExitCode = $null } }
        @{ Case = 'success'; Result = @{ ExitCode = 0 } }
        @{ Case = 'a restart that finishes the install (0x8A150109)'; Result = @{ ExitCode = -1978334967 } }
        @{ Case = 'another installation in progress'; Result = @{ ExitCode = -1978334974 } }
    ) {
        Test-RestartRequiredFirst -InstallResult $Result | Should -BeFalse
    }
}

Describe 'Test-WingetRestartRequiredResult' {
    It 'Is true for <Case>' -ForEach @(
        @{ Case = 'winget 1.6 and older (0x8A150109)'; Code = -1978334967; Output = @() }
        @{ Case = 'an installer that started a restart (0x8A15010B, MSI 1641)'; Code = -1978334965; Output = @() }
        @{ Case = 'winget 1.7 and later (exit 0 with its restart warning)'; Code = 0; Output = @('Starting package install...', 'Restart your PC to finish installation.') }
    ) {
        Test-WingetRestartRequiredResult -ExitCode $Code -Output $Output | Should -BeTrue
    }

    It 'Is false for <Case>' -ForEach @(
        @{ Case = 'a plain success'; Code = 0; Output = @('Starting package install...', 'Successfully installed') }
        @{ Case = 'no exit code (winget did not run to the end)'; Code = $null; Output = @('Restart your PC to finish installation.') }
        @{ Case = 'a restart required before the installer can run (0x8A15010A)'; Code = -1978334966; Output = @() }
        @{ Case = 'a failure that printed the restart warning'; Code = -1978334974; Output = @('Restart your PC to finish installation.') }
        @{ Case = 'no output'; Code = 0; Output = $null }
    ) {
        Test-WingetRestartRequiredResult -ExitCode $Code -Output $Output | Should -BeFalse
    }
}
