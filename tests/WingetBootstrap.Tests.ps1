# WingetBootstrap.Tests.ps1
# Tests for WingetAppSetup/Private/WingetBootstrap.ps1: the helpers of Initialize-Winget's one
# probe, classify, fix ladder (review findings P3-25 to P3-31). Initialize-Winget itself is tested in
# WingetCore.Tests.ps1.

# Load the module's functions once for this file. TestHelpers.ps1 resolves the repo paths
# and dot-sources WingetAppSetup/Private + Public (the single source of truth; the
# distributable winget-app-install.ps1 is generated from it by build/Build-WingetInstallScript.ps1).
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    # What the real cmdlets throw, by HRESULT: a COMException carries it as its HResult.
    function New-AppxException {
        param ([int]$HResult, [string]$Message = 'Bereitstellungsfehler.')
        [System.Runtime.InteropServices.COMException]::new($Message, $HResult)
    }
    # 0x80073CF3 ERROR_INSTALL_RESOLVE_DEPENDENCY_FAILED and 0x80073D06 ERROR_INSTALL_PACKAGE_DOWNGRADE.
    $script:missingDependency = -2147009293
    $script:downgrade = -2147009274
    # What Repair-WinGetPackageManager really throws in the #279 wedge (E2E run 36384683838).
    $script:realRepairMessage = 'Failed to repair winget. Try running with -AllUsers in administrator mode.'
}

Describe 'Get-WingetPolicyBlock (review finding P3-30)' {
    It 'Finds nothing when the App Installer policy key does not exist' {
        Mock Get-ItemProperty { throw [System.Management.Automation.ItemNotFoundException]::new('Cannot find path') }

        Get-WingetPolicyBlock | Should -BeNullOrEmpty

        Should -Invoke Get-ItemProperty -Times 1 -Exactly -ParameterFilter { $LiteralPath -eq 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppInstaller' }
    }

    It 'Names the policy when <Name> is Disabled (0)' -ForEach @(
        @{ Name = 'EnableAppInstaller'; Policy = 'Enable App Installer' }
        @{ Name = 'EnableWindowsPackageManagerCommandLineInterfaces'; Policy = 'Enable Windows Package Manager command line interfaces' }
        @{ Name = 'EnableDefaultSource'; Policy = 'Enable App Installer Default Source' }
    ) {
        $script:policyName = $Name
        Mock Get-ItemProperty { [pscustomobject]@{ EnableMicrosoftStoreSource = 0; $script:policyName = 0 } }

        $block = Get-WingetPolicyBlock

        $block.Name | Should -Be $Name
        $block.Policy | Should -Be $Policy
    }

    It 'Finds nothing when the values allow winget, or only other App Installer policies are set' {
        Mock Get-ItemProperty { [pscustomobject]@{ EnableAppInstaller = 1; EnableDefaultSource = 1; EnableMicrosoftStoreSource = 0; EnableAllowedSources = 1 } }

        Get-WingetPolicyBlock | Should -BeNullOrEmpty
    }
}

Describe 'Get-AppxErrorCode (review finding P3-27)' {
    It 'Reads the HRESULT of the exception, whatever language the message is in' {
        try { throw (New-AppxException -HResult $script:missingDependency -Message 'Das Paket hängt von einem Framework ab, das nicht gefunden wurde.') }
        catch { $record = $_ }

        Get-AppxErrorCode -ErrorRecord $record | Should -Be $script:missingDependency
    }

    It 'Reads the HRESULT of an inner exception' {
        $outer = [System.InvalidOperationException]::new('Deployment failed.', (New-AppxException -HResult $script:downgrade))

        Get-AppxErrorCode -ErrorRecord $outer | Should -Be $script:downgrade
    }

    It 'Falls back to the hex code in the message when no exception carries it' {
        try { throw 'Deployment failed with HRESULT: 0x80073D06, The package could not be installed because a higher version of this package is already installed.' }
        catch { $record = $_ }

        Get-AppxErrorCode -ErrorRecord $record | Should -Be $script:downgrade
    }

    It 'Returns nothing for the message Repair-WinGetPackageManager really throws, which has no code' {
        try { throw $script:realRepairMessage }
        catch { $record = $_ }

        Get-AppxErrorCode -ErrorRecord $record | Should -BeNullOrEmpty
    }
}

Describe 'Test-AndInstallWingetModule (lazy, review finding P3-26)' {
    BeforeEach {
        Mock Write-Info { }
        $script:warnings = @()
        Mock Write-WarningMessage { $script:warnings += $Message }
        Mock Get-PackageProvider { $null }
        Mock Install-PackageProvider { }
        $script:moduleInstalled = $false
        Mock Install-Module { $script:moduleInstalled = $true }
        Mock Import-Module { }
        # Last: mocking Get-Command breaks the lookup Mock relies on for the targets above.
        Mock Get-Command { if ($script:moduleInstalled) { [pscustomobject]@{ Name = 'Repair-WinGetPackageManager' } } } -ParameterFilter { $Name -eq 'Repair-WinGetPackageManager' }
    }

    It 'Installs nothing when Repair-WinGetPackageManager is already there' {
        $script:moduleInstalled = $true

        Test-AndInstallWingetModule | Should -Be $true

        Should -Invoke Install-Module -Times 0 -Exactly
    }

    It 'Installs the module for all users from the PowerShell Gallery only (review finding P3-20), with the NuGet provider first' {
        Test-AndInstallWingetModule | Should -Be $true

        Should -Invoke Install-PackageProvider -Times 1 -Exactly -ParameterFilter { $Name -eq 'NuGet' -and $Scope -eq 'AllUsers' }
        Should -Invoke Install-Module -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'Microsoft.WinGet.Client' -and $Repository -eq 'PSGallery' -and $Scope -eq 'AllUsers'
        }
        Should -Invoke Import-Module -Times 1 -Exactly -ParameterFilter { $Name -eq 'Microsoft.WinGet.Client' }
    }

    It 'Says the repair cannot run, and nothing about an update feature, when the Gallery cannot be reached' {
        Mock Install-Module { throw 'Unable to resolve package source https://www.powershellgallery.com/api/v2' }

        Test-AndInstallWingetModule | Should -Be $false

        ($script:warnings -join "`n") | Should -Match 'could not be installed, so Repair-WinGetPackageManager cannot run: Unable to resolve package source'
        ($script:warnings -join "`n") | Should -Not -Match 'Update functionality'
    }
}

Describe 'Register-WingetAppInstallerForUser (issue #265, review findings P3-27, P3-29)' {
    BeforeEach {
        Mock Write-Host { }
        Mock Write-Info { }
        Mock Write-Success { }
        Mock Write-WarningMessage { }
        # A TestDrive path, not a 'C:\Program Files\WindowsApps\...' literal: Join-Path checks the
        # drive exists, so off Windows a C: path never reached the -Register call (wgt-gq8.5).
        $script:installLocation = Join-Path $TestDrive 'WindowsApps\Microsoft.DesktopAppInstaller_1.26.510.0_x64__8wekyb3d8bbwe'
        Mock Get-DesktopAppInstallerPackageInfo { [pscustomobject]@{ Version = [version]'1.26.510.0'; Architecture = 'X64'; Status = 'Ok'; InstallLocation = $script:installLocation } }
        Mock Test-Path { $true }
    }

    It 'Registers the package on this PC by family name' {
        Mock Add-AppxPackage { }

        $result = Register-WingetAppInstallerForUser

        $result.Registered | Should -Be $true
        Should -Invoke Add-AppxPackage -Times 1 -Exactly -ParameterFilter {
            $RegisterByFamilyName -and $MainPackage -eq 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe'
        }
    }

    It 'Falls back to the package manifest when the family-name form fails' {
        Mock Add-AppxPackage { throw 'family name registration failed' } -ParameterFilter { $RegisterByFamilyName }
        Mock Add-AppxPackage { } -ParameterFilter { $Register }

        (Register-WingetAppInstallerForUser).Registered | Should -Be $true

        Should -Invoke Add-AppxPackage -Times 1 -Exactly -ParameterFilter {
            $Register -and $DisableDevelopmentMode -and $Path -eq (Join-Path $script:installLocation 'AppXManifest.xml')
        }
    }

    It 'Registers nothing when App Installer is not on this PC' {
        Mock Get-DesktopAppInstallerPackageInfo { }
        Mock Add-AppxPackage { throw 'nothing to register' }

        (Register-WingetAppInstallerForUser).Registered | Should -Be $false

        Should -Invoke Add-AppxPackage -Times 0 -Exactly
    }

    It 'Registers nothing when the packages cannot be listed' {
        Mock Get-DesktopAppInstallerPackageInfo { throw 'Get-AppxPackage -AllUsers failed in Windows PowerShell (exit code 1).' }
        Mock Add-AppxPackage { throw 'nothing to register' }

        (Register-WingetAppInstallerForUser).Registered | Should -Be $false

        Should -Invoke Add-AppxPackage -Times 0 -Exactly
    }

    It 'Returns the AppX codes its registrations failed with, read from the HRESULT (review finding P3-27)' {
        Mock Add-AppxPackage { throw (New-AppxException -HResult -2147009293 -Message 'Abhängigkeit nicht gefunden.') } -ParameterFilter { $RegisterByFamilyName }
        Mock Add-AppxPackage { throw 'Deployment failed with HRESULT: 0x80073D06, The package could not be installed because a higher version of this package is already installed.' } -ParameterFilter { $Register }

        $result = Register-WingetAppInstallerForUser

        $result.Registered | Should -Be $false
        $result.ErrorCodes | Should -Be @(-2147009293, -2147009274)
    }
}

# Review finding P3-29: under PowerShell 7 on Windows Server 2022 (E2E run 35406706712) the Appx
# module could not load, so Get-AppxPackage failed with 0x80131539 and the registration step ended
# before it registered anything. The real Get-DesktopAppInstallerPackageInfo runs here.
Describe 'Register-WingetAppInstallerForUser under PowerShell 7 where Appx cannot load (review finding P3-29)' {
    BeforeEach {
        Mock Write-Info { }
        Mock Write-Success { }
        Mock Write-WarningMessage { }
        $script:installLocation = Join-Path $TestDrive 'WindowsApps\Microsoft.DesktopAppInstaller_1.26.510.0_x64__8wekyb3d8bbwe'
        Mock Get-AppxPackage { throw [System.PlatformNotSupportedException]::new("The 'Get-AppxPackage' command was found in the module 'Appx', but the module could not be loaded. Operation is not supported on this platform. (0x80131539)") }
        # Windows PowerShell, where it always loads, answers.
        Mock powershell.exe { $global:LASTEXITCODE = 0; "1.26.510.0|X64|Ok|$script:installLocation" }
        Mock Add-AppxPackage { }
    }

    It 'Lists the packages through Windows PowerShell and registers App Installer' -Skip:($PSVersionTable.PSEdition -ne 'Core') {
        $result = Register-WingetAppInstallerForUser

        $result.Registered | Should -Be $true
        Should -Invoke powershell.exe -Times 1 -Exactly -ParameterFilter { "$args" -match "Get-AppxPackage -AllUsers -Name 'Microsoft\.DesktopAppInstaller'" }
        Should -Invoke Add-AppxPackage -Times 1 -Exactly -ParameterFilter { $RegisterByFamilyName }
    }
}

Describe 'Invoke-WingetPackageManagerRepair (issue #265, review findings P3-26, P3-27, P3-28)' {
    BeforeEach {
        Mock Write-Host { }
        Mock Write-Info { }
        $script:warnings = @()
        Mock Write-WarningMessage { $script:warnings += $Message }
        # Safety net (#181): never let the real cmdlet run during unit tests.
        Mock Repair-WinGetPackageManager { }
        Mock Test-AndInstallWingetModule { $true }
    }

    It 'Runs nothing when the module that provides the cmdlet cannot be installed' {
        Mock Test-AndInstallWingetModule { $false }

        $result = Invoke-WingetPackageManagerRepair -AllUsersFirst

        $result.Available | Should -Be $false
        $result.Succeeded | Should -Be $false
        Should -Invoke Repair-WinGetPackageManager -Times 0 -Exactly
    }

    It 'Tries the unforced repair for this account first, and stops there when it completes' {
        $result = Invoke-WingetPackageManagerRepair

        $result.Succeeded | Should -Be $true
        Should -Invoke Repair-WinGetPackageManager -Times 1 -Exactly
        Should -Invoke Repair-WinGetPackageManager -Times 1 -Exactly -ParameterFilter { $Latest -and -not $Force -and -not $AllUsers }
    }

    It 'Never repairs for all users unless told the framework is missing (issue #265: -AllUsers aborts on a newer framework)' {
        Mock Repair-WinGetPackageManager { throw $script:realRepairMessage }

        [void](Invoke-WingetPackageManagerRepair)

        Should -Invoke Repair-WinGetPackageManager -Times 0 -Exactly -ParameterFilter { $AllUsers }
    }

    It 'Repairs for all users first when the framework is missing, as the cmdlet itself asks (review finding P3-28)' {
        $script:calls = @()
        Mock Repair-WinGetPackageManager { $script:calls += [bool]$AllUsers; if ($AllUsers) { return } throw 'unexpected' }

        $result = Invoke-WingetPackageManagerRepair -AllUsersFirst

        $result.Succeeded | Should -Be $true
        $script:calls | Should -Be @($true)
        Should -Invoke Repair-WinGetPackageManager -Times 1 -Exactly -ParameterFilter { $AllUsers -and $Latest -and -not $Force }
    }

    It 'Goes on to this account, unforced then forced, when the failure has no code (the real wedge message)' {
        Mock Repair-WinGetPackageManager { throw $script:realRepairMessage }

        $result = Invoke-WingetPackageManagerRepair -AllUsersFirst

        $result.Available | Should -Be $true
        $result.Succeeded | Should -Be $false
        Should -Invoke Repair-WinGetPackageManager -Times 3 -Exactly
        Should -Invoke Repair-WinGetPackageManager -Times 1 -Exactly -ParameterFilter { $Force }
        ($script:warnings -join "`n") | Should -Match 'Repair-WinGetPackageManager -AllUsers -Latest failed: Failed to repair winget'
    }

    It 'Does not escalate to -Force on <Name>, which fails the same way however hard it is pushed' -ForEach @(
        @{ Name = '0x80073D06 (a newer framework, issue #265)'; Code = -2147009274 }
        @{ Name = '0x80073CF3 (a missing framework, issue #279)'; Code = -2147009293 }
    ) {
        $script:code = $Code
        Mock Repair-WinGetPackageManager { throw (New-AppxException -HResult $script:code) }

        $result = Invoke-WingetPackageManagerRepair

        $result.Succeeded | Should -Be $false
        $result.ErrorCodes | Should -Be @($Code)
        Should -Invoke Repair-WinGetPackageManager -Times 1 -Exactly
    }
}

Describe 'Invoke-NextWingetAccountFix (review findings P3-25, P3-28)' {
    BeforeEach {
        Mock Register-WingetAppInstallerForUser { [pscustomobject]@{ Registered = $false; ErrorCodes = @(-2147009293) } }
        Mock Invoke-WingetPackageManagerRepair { [pscustomobject]@{ Available = $true; Succeeded = $false; ErrorCodes = @() } }
        Mock Get-WindowsAppRuntimeStatus { [pscustomobject]@{ Present = $true; Detail = 'X64 8000.994.2142.0' } }
        $script:state = @{ ErrorCodes = @() }
    }

    It 'Registers App Installer first and asks for a check without repairing when that worked' {
        Mock Register-WingetAppInstallerForUser { [pscustomobject]@{ Registered = $true; ErrorCodes = @() } }

        Invoke-NextWingetAccountFix -State $script:state | Should -Be $true

        Should -Invoke Invoke-WingetPackageManagerRepair -Times 0 -Exactly
    }

    It 'Goes straight on to the repair when the registration fails, keeping the codes it saw' {
        Invoke-NextWingetAccountFix -State $script:state | Should -Be $true

        Should -Invoke Invoke-WingetPackageManagerRepair -Times 1 -Exactly
        $script:state.ErrorCodes | Should -Contain -2147009293
    }

    It 'Repairs for all users first only when the all-users check finds the framework missing (Present = <Present>)' -ForEach @(
        @{ Present = $false; AllUsersFirst = $true }
        @{ Present = $true; AllUsersFirst = $false }
        @{ Present = $null; AllUsersFirst = $false }
    ) {
        $script:present = $Present
        Mock Get-WindowsAppRuntimeStatus { [pscustomobject]@{ Present = $script:present; Detail = 'checked' } }

        [void](Invoke-NextWingetAccountFix -State $script:state)

        $script:expected = $AllUsersFirst
        Should -Invoke Invoke-WingetPackageManagerRepair -Times 1 -Exactly -ParameterFilter { [bool]$AllUsersFirst -eq $script:expected }
    }

    It 'Runs each fix once a run, then has none left' {
        Invoke-NextWingetAccountFix -State $script:state | Should -Be $true
        Invoke-NextWingetAccountFix -State $script:state | Should -Be $false

        Should -Invoke Register-WingetAppInstallerForUser -Times 1 -Exactly
        Should -Invoke Invoke-WingetPackageManagerRepair -Times 1 -Exactly
    }

    It 'Has nothing to check when the repair cmdlet could not be made available' {
        Mock Invoke-WingetPackageManagerRepair { [pscustomobject]@{ Available = $false; Succeeded = $false; ErrorCodes = @() } }

        Invoke-NextWingetAccountFix -State $script:state | Should -Be $false
    }
}

Describe 'Invoke-WingetSourceProbe' {
    BeforeEach {
        Mock Write-Host { }
        Mock Write-WarningMessage { }
        Mock Write-ProcessOutput { }
    }

    It 'Runs winget source update without agreement acceptance and reports success quietly' {
        Mock Invoke-WingetProcess { New-TestProcessResult -ExitCode 0 }

        $result = Invoke-WingetSourceProbe

        $result.Succeeded | Should -Be $true
        $result.ExitCode | Should -Be 0
        Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter {
            ($ArgumentList -join ' ') -eq 'source update --name winget --disable-interactivity' -and
            $TimeoutSeconds -eq (Get-ProcessTimeoutSeconds -Operation WingetSourceUpdate) -and
            $Echo -eq 'None'
        }
        Should -Invoke Write-ProcessOutput -Times 0 -Exactly
    }

    It 'Passes a failure exit code through and echoes winget''s explanation (review finding P2-6)' {
        Mock Invoke-WingetProcess { New-TestProcessResult -ExitCode -2147009255 -Output @('Failed in attempting to update the source: winget') }

        $result = Invoke-WingetSourceProbe

        $result.Succeeded | Should -Be $false
        $result.ExitCode | Should -Be -2147009255
        Should -Invoke Write-ProcessOutput -Times 1 -Exactly -ParameterFilter { ($Line -join ' ') -match 'Failed in attempting to update the source' }
    }

    It 'Reports a timeout without an exit code' {
        Mock Invoke-WingetProcess { New-TestProcessResult -TimedOut }

        $result = Invoke-WingetSourceProbe

        $result.Succeeded | Should -Be $false
        $result.TimedOut | Should -Be $true
        $result.ExitCode | Should -Be $null
    }

    It 'Reports a launch failure without throwing' {
        Mock Invoke-WingetProcess { New-TestProcessResult -LaunchFailed -LaunchErrorCode 2 -LaunchError 'winget not found' }

        $result = Invoke-WingetSourceProbe

        $result.Succeeded | Should -Be $false
        $result.ExitCode | Should -Be $null
        $result.LaunchError | Should -Be 'winget not found'
    }
}

Describe 'Reset-WingetSource (review findings P2-5, P2-6)' {
    BeforeEach {
        $script:warnings = @()
        Mock Write-WarningMessage { $script:warnings += $Message }
        $script:infos = @()
        Mock Write-Info { $script:infos += $Message }
    }

    It 'Runs winget source reset --force without --accept-source-agreements, which source reset rejects, under its time limit' {
        Mock Invoke-WingetProcess { New-TestProcessResult -ExitCode 0 }

        Reset-WingetSource | Should -Be $true

        Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter {
            ($ArgumentList -join ' ') -eq 'source reset --force --disable-interactivity' -and
            $TimeoutSeconds -eq (Get-ProcessTimeoutSeconds -Operation WingetSourceReset)
        }
        $script:infos | Should -Contain 'Source reset completed.'
    }

    It 'Says when the reset failed, with its exit code, instead of reporting it completed' {
        Mock Invoke-WingetProcess { New-TestProcessResult -ExitCode -1978335230 }

        Reset-WingetSource | Should -Be $false

        $script:warnings | Should -Contain 'Winget source reset failed with exit code 0x8A150002 INVALID_CL_ARGUMENTS.'
        $script:infos | Should -Not -Contain 'Source reset completed.'
    }
}
