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
    # What Invoke-WindowsPowerShellScript returns (Invoke-ExternalProcess's result, in part).
    function New-PowerShellRun {
        param ([Nullable[int]]$ExitCode = 0, [string[]]$Lines = @(), [switch]$TimedOut, [string]$LaunchError)
        [pscustomobject]@{
            ExitCode       = $ExitCode
            TimedOut       = [bool]$TimedOut
            LaunchFailed   = [bool]$LaunchError
            LaunchError    = $LaunchError
            StandardOutput = $Lines
        }
    }
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
        Mock Invoke-AppxRegistration { }

        $result = Register-WingetAppInstallerForUser

        $result.Registered | Should -Be $true
        Should -Invoke Invoke-AppxRegistration -Times 1 -Exactly
        Should -Invoke Invoke-AppxRegistration -Times 1 -Exactly -ParameterFilter { $FamilyName -eq 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe' }
    }

    It 'Falls back to the package manifest when the family-name form fails' {
        Mock Invoke-AppxRegistration { throw 'family name registration failed' } -ParameterFilter { $FamilyName }
        Mock Invoke-AppxRegistration { } -ParameterFilter { $ManifestPath }

        (Register-WingetAppInstallerForUser).Registered | Should -Be $true

        Should -Invoke Invoke-AppxRegistration -Times 1 -Exactly -ParameterFilter {
            $ManifestPath -eq (Join-Path $script:installLocation 'AppXManifest.xml')
        }
    }

    It 'Registers nothing when App Installer is not on this PC' {
        Mock Get-DesktopAppInstallerPackageInfo { }
        Mock Invoke-AppxRegistration { throw 'nothing to register' }

        (Register-WingetAppInstallerForUser).Registered | Should -Be $false

        Should -Invoke Invoke-AppxRegistration -Times 0 -Exactly
    }

    It 'Registers nothing when the packages cannot be listed' {
        Mock Get-DesktopAppInstallerPackageInfo { throw 'Get-AppxPackage -AllUsers failed in Windows PowerShell (exit code 1).' }
        Mock Invoke-AppxRegistration { throw 'nothing to register' }

        (Register-WingetAppInstallerForUser).Registered | Should -Be $false

        Should -Invoke Invoke-AppxRegistration -Times 0 -Exactly
    }

    It 'Returns the AppX codes its registrations failed with, read from the HRESULT (review finding P3-27)' {
        Mock Invoke-AppxRegistration { throw (New-AppxException -HResult -2147009293 -Message 'Abhängigkeit nicht gefunden.') } -ParameterFilter { $FamilyName }
        Mock Invoke-AppxRegistration { throw 'Deployment failed with HRESULT: 0x80073D06, The package could not be installed because a higher version of this package is already installed.' } -ParameterFilter { $ManifestPath }

        $result = Register-WingetAppInstallerForUser

        $result.Registered | Should -Be $false
        $result.ErrorCodes | Should -Be @(-2147009293, -2147009274)
    }
}

# Review finding P3-29: under PowerShell 7 on Windows Server 2022 (E2E run 35406706712) the Appx
# module could not load (0x80131539). That fails every cmdlet of the module, Add-AppxPackage as well
# as Get-AppxPackage, so the registration step failed at the listing and would have failed at the
# registration; it only worked there once Repair-WinGetPackageManager had loaded Appx into the
# session. Both run in Windows PowerShell here: the real Get-DesktopAppInstallerPackageInfo and the
# real Invoke-AppxRegistration run, and both Appx cmdlets fail in this session.
Describe 'Register-WingetAppInstallerForUser under PowerShell 7 where Appx cannot load (review finding P3-29)' {
    BeforeEach {
        Mock Write-Info { }
        Mock Write-Success { }
        $script:warnings = @()
        Mock Write-WarningMessage { $script:warnings += $Message }
        $script:installLocation = Join-Path $TestDrive 'WindowsApps\Microsoft.DesktopAppInstaller_1.26.510.0_x64__8wekyb3d8bbwe'
        Mock Test-Path { $true }
        Mock Get-AppxPackage { throw [System.PlatformNotSupportedException]::new("The 'Get-AppxPackage' command was found in the module 'Appx', but the module could not be loaded. Operation is not supported on this platform. (0x80131539)") }
        Mock Add-AppxPackage { throw [System.PlatformNotSupportedException]::new("The 'Add-AppxPackage' command was found in the module 'Appx', but the module could not be loaded. Operation is not supported on this platform. (0x80131539)") }
        # Windows PowerShell, where Appx always loads, answers: it lists App Installer and registers it.
        Mock Invoke-WindowsPowerShellScript { New-PowerShellRun }
        Mock Invoke-WindowsPowerShellScript { New-PowerShellRun -Lines @("1.26.510.0|X64|Ok|$script:installLocation") } -ParameterFilter { $Script -match 'Get-AppxPackage -AllUsers' }
    }

    It 'Lists and registers App Installer through Windows PowerShell, each within its time limit' -Skip:($PSVersionTable.PSEdition -ne 'Core') {
        $result = Register-WingetAppInstallerForUser

        $result.Registered | Should -Be $true
        $script:warnings | Should -BeNullOrEmpty
        Should -Invoke Invoke-WindowsPowerShellScript -Times 1 -Exactly -ParameterFilter { $Script -match "Get-AppxPackage -AllUsers -Name 'Microsoft\.DesktopAppInstaller'" -and $TimeoutSeconds -eq (Get-ProcessTimeoutSeconds -Operation AppxQuery) }
        Should -Invoke Invoke-WindowsPowerShellScript -Times 1 -Exactly -ParameterFilter { $Script -match "Add-AppxPackage -RegisterByFamilyName -MainPackage 'Microsoft\.DesktopAppInstaller_8wekyb3d8bbwe'" -and $TimeoutSeconds -eq (Get-ProcessTimeoutSeconds -Operation AppxRegistration) }
        Should -Invoke Get-AppxPackage -Times 0 -Exactly
        Should -Invoke Add-AppxPackage -Times 0 -Exactly
    }

    It 'Returns the codes Windows PowerShell reports, read from the HRESULT it prints' -Skip:($PSVersionTable.PSEdition -ne 'Core') {
        Mock Invoke-WindowsPowerShellScript { New-PowerShellRun -ExitCode 1 -Lines @('ERR|-2147009293|Das Paket hängt von einem Framework ab, das nicht gefunden wurde.') } -ParameterFilter { $Script -match 'RegisterByFamilyName' }
        Mock Invoke-WindowsPowerShellScript { New-PowerShellRun -ExitCode 1 -Lines @('ERR|-2147009274|Deployment failed with HRESULT: 0x80073D06, The package could not be installed because a higher version of this package is already installed.') } -ParameterFilter { $Script -match 'Add-AppxPackage -Path' }

        $result = Register-WingetAppInstallerForUser

        $result.Registered | Should -Be $false
        $result.ErrorCodes | Should -Be @(-2147009293, -2147009274)
        Should -Invoke Add-AppxPackage -Times 0 -Exactly
    }
}

Describe 'Invoke-AppxRegistration (review findings P3-27, P3-29)' {
    BeforeEach {
        Mock Add-AppxPackage { throw [System.PlatformNotSupportedException]::new("The 'Add-AppxPackage' command was found in the module 'Appx', but the module could not be loaded. Operation is not supported on this platform. (0x80131539)") }
        Mock Invoke-WindowsPowerShellScript { New-PowerShellRun }
    }

    It 'Registers by family name in Windows PowerShell under PowerShell 7, within the AppxRegistration limit' -Skip:($PSVersionTable.PSEdition -ne 'Core') {
        Invoke-AppxRegistration -FamilyName 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe'

        Should -Invoke Invoke-WindowsPowerShellScript -Times 1 -Exactly -ParameterFilter {
            $Script -match "^try \{ Add-AppxPackage -RegisterByFamilyName -MainPackage 'Microsoft\.DesktopAppInstaller_8wekyb3d8bbwe' -ErrorAction Stop \}" -and
            $TimeoutSeconds -eq (Get-ProcessTimeoutSeconds -Operation AppxRegistration)
        }
        Should -Invoke Add-AppxPackage -Times 0 -Exactly
    }

    It 'Registers from a manifest, keeping an apostrophe in its path inside the quoted literal (issue #178)' -Skip:($PSVersionTable.PSEdition -ne 'Core') {
        Invoke-AppxRegistration -ManifestPath "C:\Users\O'Brien\AppXManifest.xml"

        Should -Invoke Invoke-WindowsPowerShellScript -Times 1 -Exactly -ParameterFilter {
            $Script.Contains("Add-AppxPackage -Path 'C:\Users\O''Brien\AppXManifest.xml' -Register -DisableDevelopmentMode -ErrorAction Stop")
        }
    }

    It 'Installs a package file, keeping an apostrophe in its path inside the quoted literal (wgt-gq8.63)' -Skip:($PSVersionTable.PSEdition -ne 'Core') {
        Invoke-AppxRegistration -PackagePath "C:\ProgramData\winget-app-setup\wingetsource-1\O'Neil.msix"

        Should -Invoke Invoke-WindowsPowerShellScript -Times 1 -Exactly -ParameterFilter {
            $Script.Contains("Add-AppxPackage -Path 'C:\ProgramData\winget-app-setup\wingetsource-1\O''Neil.msix' -ErrorAction Stop") -and
            $Script -notmatch '-Register'
        }
        Should -Invoke Add-AppxPackage -Times 0 -Exactly
    }

    It 'Throws the HRESULT Windows PowerShell printed, whatever language the message is in' -Skip:($PSVersionTable.PSEdition -ne 'Core') {
        Mock Invoke-WindowsPowerShellScript { New-PowerShellRun -ExitCode 1 -Lines @('WARNING: noise', 'ERR|-2147009293|Das Paket hängt von einem Framework ab, das nicht gefunden wurde.') }

        try { Invoke-AppxRegistration -FamilyName 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe'; $record = $null }
        catch { $record = $_ }

        $record | Should -Not -BeNullOrEmpty
        $record.Exception.HResult | Should -Be -2147009293
        "$record" | Should -Be 'Das Paket hängt von einem Framework ab, das nicht gefunden wurde.'
        Get-AppxErrorCode -ErrorRecord $record | Should -Be -2147009293
    }

    It 'Throws with the exit code when Windows PowerShell failed without saying why' -Skip:($PSVersionTable.PSEdition -ne 'Core') {
        Mock Invoke-WindowsPowerShellScript { New-PowerShellRun -ExitCode 1 }

        { Invoke-AppxRegistration -FamilyName 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe' } | Should -Throw '*failed in Windows PowerShell (exit code 1)*'
    }

    It 'Throws, with no AppX code, when Add-AppxPackage was stopped at its time limit' -Skip:($PSVersionTable.PSEdition -ne 'Core') {
        Mock Invoke-WindowsPowerShellScript { New-PowerShellRun -ExitCode $null -TimedOut }

        try { Invoke-AppxRegistration -PackagePath 'X:\staging\source.msix'; $record = $null }
        catch { $record = $_ }

        "$record" | Should -Be "Add-AppxPackage -Path 'X:\staging\source.msix' did not finish within 5 minutes and was stopped."
        Get-AppxErrorCode -ErrorRecord $record | Should -BeNullOrEmpty
    }

    It 'Throws when Windows PowerShell cannot be started' -Skip:($PSVersionTable.PSEdition -ne 'Core') {
        Mock Invoke-WindowsPowerShellScript { New-PowerShellRun -ExitCode $null -LaunchError 'The system cannot find the file specified' }

        { Invoke-AppxRegistration -FamilyName 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe' } | Should -Throw '*could not run: Windows PowerShell could not be started (The system cannot find the file specified)*'
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

    It 'Goes on to an unforced, then a forced repair for this account when nothing names the cause' {
        Mock Repair-WinGetPackageManager { throw $script:realRepairMessage }

        $result = Invoke-WingetPackageManagerRepair

        $result.Available | Should -Be $true
        $result.Succeeded | Should -Be $false
        Should -Invoke Repair-WinGetPackageManager -Times 2 -Exactly
        Should -Invoke Repair-WinGetPackageManager -Times 1 -Exactly -ParameterFilter { $Latest -and -not $Force -and -not $AllUsers }
        Should -Invoke Repair-WinGetPackageManager -Times 1 -Exactly -ParameterFilter { $Latest -and $Force -and -not $AllUsers }
    }

    # Review finding P3-27, the #279 wedge (E2E run 36384683838): the repair only says 'Try running
    # with -AllUsers', with no code, and used to be forced anyway.
    It 'Does not force a repair for this account after the all-users repair for a missing framework failed' {
        Mock Repair-WinGetPackageManager { throw $script:realRepairMessage }
        $script:infos = @()
        Mock Write-Info { $script:infos += $Message }

        $result = Invoke-WingetPackageManagerRepair -AllUsersFirst

        $result.Available | Should -Be $true
        $result.Succeeded | Should -Be $false
        Should -Invoke Repair-WinGetPackageManager -Times 2 -Exactly
        Should -Invoke Repair-WinGetPackageManager -Times 1 -Exactly -ParameterFilter { $AllUsers -and $Latest -and -not $Force }
        Should -Invoke Repair-WinGetPackageManager -Times 1 -Exactly -ParameterFilter { $Latest -and -not $Force -and -not $AllUsers }
        Should -Invoke Repair-WinGetPackageManager -Times 0 -Exactly -ParameterFilter { $Force }
        ($script:warnings -join "`n") | Should -Match 'Repair-WinGetPackageManager -AllUsers -Latest failed: Failed to repair winget'
        $script:infos | Should -Contain 'Not running Repair-WinGetPackageManager -Latest -Force: the Microsoft.WindowsAppRuntime.1.8 framework App Installer needs is missing, and the all-users repair for it failed, which forcing cannot fix (-Force only closes running App Installer processes).'
    }

    It 'Does not force a repair after the App Installer registration failed with <Name>' -ForEach @(
        @{ Name = '0x80073CF3 (a missing framework, issue #279)'; Codes = @(-2147009293); Shown = '0x80073CF3 ERROR_INSTALL_RESOLVE_DEPENDENCY_FAILED' }
        @{ Name = '0x80073D06 (a newer framework, issue #265)'; Codes = @(-2147009274); Shown = '0x80073D06 ERROR_INSTALL_PACKAGE_DOWNGRADE' }
        @{ Name = 'both, as on the #279 wedge'; Codes = @(-2147009293, -2147009274, -2147009293); Shown = '0x80073CF3 ERROR_INSTALL_RESOLVE_DEPENDENCY_FAILED, 0x80073D06 ERROR_INSTALL_PACKAGE_DOWNGRADE' }
    ) {
        Mock Repair-WinGetPackageManager { throw $script:realRepairMessage }
        $script:infos = @()
        Mock Write-Info { $script:infos += $Message }

        $result = Invoke-WingetPackageManagerRepair -KnownErrorCodes $Codes

        $result.Succeeded | Should -Be $false
        $result.ErrorCodes | Should -BeNullOrEmpty
        Should -Invoke Repair-WinGetPackageManager -Times 1 -Exactly
        Should -Invoke Repair-WinGetPackageManager -Times 0 -Exactly -ParameterFilter { $Force }
        $script:infos | Should -Contain "Not running Repair-WinGetPackageManager -Latest -Force: registering App Installer failed with $Shown, which forcing cannot fix (-Force only closes running App Installer processes)."
    }

    It 'Still forces the repair when the registration failed with another code' {
        Mock Repair-WinGetPackageManager { throw $script:realRepairMessage }

        [void](Invoke-WingetPackageManagerRepair -KnownErrorCodes @(-2147009255))

        Should -Invoke Repair-WinGetPackageManager -Times 1 -Exactly -ParameterFilter { $Force }
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

    It 'Goes straight on to the repair when the registration fails, keeping the codes it saw and telling the repair (P3-27)' {
        Invoke-NextWingetAccountFix -State $script:state | Should -Be $true

        Should -Invoke Invoke-WingetPackageManagerRepair -Times 1 -Exactly
        Should -Invoke Invoke-WingetPackageManagerRepair -Times 1 -Exactly -ParameterFilter { @($KnownErrorCodes) -contains -2147009293 }
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

# wgt-gq8.63: `winget source update` exits 0 when its update fails, so the run checks that winget
# can open the source the way the installs do (`--source winget`).
Describe 'Test-WingetSourceOpen (wgt-gq8.63)' {
    BeforeEach {
        Mock Write-ProcessOutput { }
    }

    It 'Opens the winget source as the installs do, quietly and under its own time limit' {
        Mock Invoke-WingetProcess { New-TestProcessResult -ExitCode 0 -Output @('PowerShell Microsoft.PowerShell 7.6.6 winget') }

        $result = Test-WingetSourceOpen

        $result.Opened | Should -Be $true
        $result.ExitCode | Should -Be 0
        Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter {
            ($ArgumentList -join ' ') -eq 'search --exact --id Microsoft.PowerShell --source winget --accept-source-agreements --disable-interactivity' -and
            $TimeoutSeconds -eq (Get-ProcessTimeoutSeconds -Operation WingetSourceOpen) -and
            $Echo -eq 'None'
        }
        Should -Invoke Write-ProcessOutput -Times 0 -Exactly
    }

    It 'Counts 0x8A150014 (nothing found) as opened' {
        Mock Invoke-WingetProcess { New-TestProcessResult -ExitCode -1978335212 -Output @('No package found matching input criteria.') }

        (Test-WingetSourceOpen).Opened | Should -Be $true
    }

    It 'Reports 0x8A15000F SOURCE_DATA_MISSING as not opened and echoes what winget said' {
        Mock Invoke-WingetProcess { New-TestProcessResult -ExitCode -1978335217 -Output @("Failed when opening source(s); try the 'source reset' command if the problem persists.", '0x8a15000f : Data required by the source is missing') }

        $result = Test-WingetSourceOpen

        $result.Opened | Should -Be $false
        $result.ExitCode | Should -Be -1978335217
        Should -Invoke Write-ProcessOutput -Times 1 -Exactly -ParameterFilter { ($Line -join ' ') -match '0x8a15000f : Data required by the source is missing' }
    }

    It 'Has no answer when winget times out or cannot be started' {
        Mock Invoke-WingetProcess { New-TestProcessResult -TimedOut }
        $timedOut = Test-WingetSourceOpen
        $timedOut.Opened | Should -BeNullOrEmpty
        $timedOut.TimedOut | Should -Be $true

        Mock Invoke-WingetProcess { New-TestProcessResult -LaunchFailed -LaunchErrorCode 2 -LaunchError 'winget not found' }
        $notStarted = Test-WingetSourceOpen
        $notStarted.Opened | Should -BeNullOrEmpty
        $notStarted.LaunchError | Should -Be 'winget not found'
    }
}

Describe 'Invoke-WingetSourceCheck (wgt-gq8.63)' {
    BeforeEach {
        Mock Invoke-WingetSourceProbe { @{ Succeeded = $true; ExitCode = 0; TimedOut = $false; LaunchError = $null } }
        Mock Test-WingetSourceOpen { @{ Opened = $true; ExitCode = 0; TimedOut = $false; LaunchError = $null } }
    }

    It 'Takes the answer of the open, not the update that exited 0' {
        Mock Test-WingetSourceOpen { @{ Opened = $false; ExitCode = -1978335217; TimedOut = $false; LaunchError = $null } }

        $result = Invoke-WingetSourceCheck

        $result.Succeeded | Should -Be $false
        $result.ExitCode | Should -Be -1978335217
        $result.Step | Should -Be 'open'
    }

    It 'Is fine when the update failed but the source opens' {
        Mock Invoke-WingetSourceProbe { @{ Succeeded = $false; ExitCode = -2147012889; TimedOut = $false; LaunchError = $null } }

        (Invoke-WingetSourceCheck).Succeeded | Should -Be $true
    }

    It 'Does not open the source after an update that <Case>' -ForEach @(
        @{ Case = 'timed out'; Update = @{ Succeeded = $false; ExitCode = $null; TimedOut = $true; LaunchError = $null } }
        @{ Case = 'could not start'; Update = @{ Succeeded = $false; ExitCode = $null; TimedOut = $false; LaunchError = 'winget not found' } }
        @{ Case = 'Group Policy blocked'; Update = @{ Succeeded = $false; ExitCode = -1978335174; TimedOut = $false; LaunchError = $null } }
    ) {
        $script:update = $Update
        Mock Invoke-WingetSourceProbe { $script:update }

        $result = Invoke-WingetSourceCheck

        $result.Succeeded | Should -Be $false
        $result.Step | Should -Be 'update'
        Should -Invoke Test-WingetSourceOpen -Times 0 -Exactly
    }
}

Describe 'Save-WebFileAsNew (wgt-gq8.63)' {
    BeforeEach {
        $script:bytes = [byte[]](1, 2, 3, 4, 5)
        Mock Invoke-WebRequest { [pscustomobject]@{ RawContentStream = [System.IO.MemoryStream]::new($script:bytes) } }
    }

    It 'Writes what it downloaded into a new file' {
        $path = Join-Path $TestDrive 'new.msix'

        Save-WebFileAsNew -Uri 'https://cdn.winget.microsoft.com/cache/source2.msix' -Path $path

        [System.IO.File]::ReadAllBytes($path) | Should -Be $script:bytes
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Uri -eq 'https://cdn.winget.microsoft.com/cache/source2.msix' -and $UseBasicParsing -and $TimeoutSec -gt 0 -and -not $OutFile }
    }

    It 'Never opens a file that is already there for writing' {
        $path = Join-Path $TestDrive 'planted.msix'
        Set-Content -LiteralPath $path -Value 'planted' -NoNewline

        { Save-WebFileAsNew -Uri 'https://cdn.winget.microsoft.com/cache/source2.msix' -Path $path } | Should -Throw

        Get-Content -Raw -LiteralPath $path | Should -Be 'planted'
    }
}

Describe 'Register-WingetSourcePackage (wgt-gq8.63)' {
    BeforeEach {
        Mock Write-Info { }
        Mock Write-Success { }
        $script:warnings = @()
        Mock Write-WarningMessage { $script:warnings += $Message }
        Mock Get-WingetSourcePackageInfo { }
        $script:stagingDir = Join-Path $TestDrive ('wingetsource-' + [guid]::NewGuid().ToString('N'))
        Mock New-WauStagingDirectory { [void](New-Item -ItemType Directory -Path $script:stagingDir); $script:stagingDir }
        $script:packageBytes = [byte[]](0x50, 0x4B, 0x03, 0x04, 7, 7)
        $script:downloads = @()
        Mock Invoke-WebRequest { $script:downloads += $Uri; [pscustomobject]@{ RawContentStream = [System.IO.MemoryStream]::new($script:packageBytes) } }
        Mock Get-AuthenticodeSignature { [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US' } } }
        # Safety net: the package is installed only through Invoke-AppxRegistration.
        Mock Add-AppxPackage { throw 'must not install a package directly' }
        $script:registered = @()
        Mock Invoke-AppxRegistration {
            $entry = @{ FamilyName = $FamilyName; PackagePath = $PackagePath; Bytes = $null }
            if ($PackagePath) {
                $entry.Bytes = [System.IO.File]::ReadAllBytes($PackagePath)
            }
            $script:registered += $entry
        }
    }

    It 'Downloads source2.msix into a new file in a folder only administrators can change, checks its Microsoft signature, installs that file and deletes it' {
        $result = Register-WingetSourcePackage

        $result.Registered | Should -Be $true
        $result.Route | Should -Be 'Download'
        $result.Reason | Should -BeNullOrEmpty
        $script:downloads | Should -Be @('https://cdn.winget.microsoft.com/cache/source2.msix')
        Should -Invoke New-WauStagingDirectory -Times 1 -Exactly -ParameterFilter { $Prefix -eq 'wingetsource' }
        Should -Invoke Get-AuthenticodeSignature -Times 1 -Exactly
        $script:registered.Count | Should -Be 1
        $script:registered[0].PackagePath | Should -BeLike (Join-Path $script:stagingDir 'source-*.msix')
        $script:registered[0].Bytes | Should -Be $script:packageBytes
        Test-Path -LiteralPath $script:stagingDir | Should -Be $false
    }

    It 'Holds the download read-locked from its signature check until Add-AppxPackage has run, then releases it' {
        # The real lock: a write handle cannot be opened on the file while it is held.
        $script:steps = @()
        $script:heldStream = $null
        Mock Open-ReadLockedFile { $script:steps += 'lock'; $script:heldStream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read); $script:heldStream }
        Mock Get-AuthenticodeSignature {
            $script:steps += 'signature'
            [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US' } }
        }
        $script:heldDuringRegistration = $null
        $script:writeRefused = $null
        Mock Invoke-AppxRegistration {
            $script:steps += 'register'
            $script:heldDuringRegistration = ($null -ne $script:heldStream) -and $script:heldStream.CanRead
            try {
                $writer = [System.IO.File]::Open($PackagePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                $writer.Dispose()
                $script:writeRefused = $false
            }
            catch {
                $script:writeRefused = $_.Exception.InnerException -is [System.IO.IOException]
            }
        }

        (Register-WingetSourcePackage).Registered | Should -Be $true

        $script:steps | Should -Be @('lock', 'signature', 'register')
        $script:heldDuringRegistration | Should -BeTrue
        $script:writeRefused | Should -BeTrue
        $script:heldStream.CanRead | Should -BeFalse
        Test-Path -LiteralPath $script:stagingDir | Should -Be $false
    }

    It 'Downloads first even when another account''s copy is on this PC, and leaves that copy alone' {
        Mock Get-WingetSourcePackageInfo { [pscustomobject]@{ Version = [version]'2026.1006.1845.38'; Architecture = 'Neutral'; Status = 'Ok'; InstallLocation = 'X:\WindowsApps\Microsoft.Winget.Source' } }

        $result = Register-WingetSourcePackage

        $result.Registered | Should -Be $true
        $result.Route | Should -Be 'Download'
        $script:downloads | Should -Be @('https://cdn.winget.microsoft.com/cache/source2.msix')
        Should -Invoke Invoke-AppxRegistration -Times 0 -Exactly -ParameterFilter { $FamilyName }
        Should -Invoke Get-WingetSourcePackageInfo -Times 0 -Exactly
    }

    It 'Registers the copy already on this PC by family name only when <Case>' -ForEach @(
        @{ Case = 'neither download works'; SignerSubject = 'CN=Microsoft Corporation, O=Microsoft Corporation'; Reason = 'it could not be downloaded from https://cdn.winget.microsoft.com/cache'; DownloadCount = 2 }
        @{ Case = 'the download is not signed by Microsoft'; SignerSubject = 'CN=Contoso Ltd, O=Contoso Ltd'; Reason = 'the package downloaded from https://cdn.winget.microsoft.com/cache/source2.msix failed its signature check*'; DownloadCount = 1 }
    ) {
        Mock Get-WingetSourcePackageInfo { [pscustomobject]@{ Version = [version]'2026.1006.1845.38'; Architecture = 'Neutral'; Status = 'Ok'; InstallLocation = 'X:\WindowsApps\Microsoft.Winget.Source' } }
        if ($DownloadCount -eq 2) {
            Mock Invoke-WebRequest { $script:downloads += $Uri; throw 'No such host is known.' }
        }
        $script:signer = $SignerSubject
        Mock Get-AuthenticodeSignature { [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = $script:signer } } }

        $result = Register-WingetSourcePackage

        $result.Registered | Should -Be $true
        $result.Route | Should -Be 'FamilyName'
        $result.Reason | Should -BeLike $Reason
        $script:downloads.Count | Should -Be $DownloadCount
        $script:registered.Count | Should -Be 1
        $script:registered[0].FamilyName | Should -Be 'Microsoft.Winget.Source_8wekyb3d8bbwe'
        $script:registered[0].PackagePath | Should -BeNullOrEmpty
        Test-Path -LiteralPath $script:stagingDir | Should -Be $false
    }

    It 'Falls back to the copy on this PC when installing the download fails, and returns both codes when that fails too' {
        Mock Get-WingetSourcePackageInfo { [pscustomobject]@{ Version = [version]'2026.1006.1845.38'; Architecture = 'Neutral'; Status = 'Ok'; InstallLocation = 'X:\WindowsApps\Microsoft.Winget.Source' } }
        Mock Invoke-AppxRegistration { throw (New-AppxException -HResult -2147009255 -Message 'Deployment failed with HRESULT: 0x80073D19, An error occurred because a user was logged off.') } -ParameterFilter { $PackagePath }
        Mock Invoke-AppxRegistration { throw (New-AppxException -HResult -2147009293) } -ParameterFilter { $FamilyName }

        $result = Register-WingetSourcePackage

        $result.Registered | Should -Be $false
        $result.Route | Should -BeNullOrEmpty
        $result.ErrorCodes | Should -Be @(-2147009255, -2147009293)
        $result.Reason | Should -BeLike 'registering it failed: Deployment failed with HRESULT: 0x80073D19*'
        Should -Invoke Invoke-AppxRegistration -Times 1 -Exactly -ParameterFilter { $FamilyName -eq 'Microsoft.Winget.Source_8wekyb3d8bbwe' }
    }

    It 'Takes source.msix, as winget does, when source2.msix cannot be downloaded' {
        Mock Invoke-WebRequest { $script:downloads += $Uri; throw 'Response status code does not indicate success: 404 (Not Found).' } -ParameterFilter { $Uri -like '*source2.msix' }

        $result = Register-WingetSourcePackage

        $result.Registered | Should -Be $true
        $script:downloads | Should -Be @('https://cdn.winget.microsoft.com/cache/source2.msix', 'https://cdn.winget.microsoft.com/cache/source.msix')
        $script:registered[0].Bytes | Should -Be $script:packageBytes
    }

    It 'Registers nothing, and says so, when neither download works and no copy is on this PC' {
        Mock Invoke-WebRequest { $script:downloads += $Uri; throw 'No such host is known.' }

        $result = Register-WingetSourcePackage

        $result.Registered | Should -Be $false
        $result.Reason | Should -Be 'it could not be downloaded from https://cdn.winget.microsoft.com/cache'
        $script:downloads.Count | Should -Be 2
        Should -Invoke Get-WingetSourcePackageInfo -Times 1 -Exactly
        Should -Invoke Invoke-AppxRegistration -Times 0 -Exactly
        $script:warnings | Should -Contain 'The downloaded winget source package could not be registered for this account: it could not be downloaded from https://cdn.winget.microsoft.com/cache.'
        Test-Path -LiteralPath $script:stagingDir | Should -Be $false
    }

    It 'Installs nothing when the download is <Case>' -ForEach @(
        @{ Case = 'signed by someone else'; Status = 'Valid'; Subject = 'CN=Contoso Ltd, O=Contoso Ltd'; Detail = 'signature status: Valid; signer: CN=Contoso Ltd, O=Contoso Ltd' }
        @{ Case = 'not signed'; Status = 'NotSigned'; Subject = $null; Detail = 'signature status: NotSigned; signer: none' }
        @{ Case = 'signed but tampered with'; Status = 'HashMismatch'; Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation'; Detail = 'signature status: HashMismatch' }
    ) {
        $script:status = $Status
        $script:subject = $Subject
        Mock Get-AuthenticodeSignature {
            $certificate = $null
            if ($script:subject) { $certificate = [pscustomobject]@{ Subject = $script:subject } }
            [pscustomobject]@{ Status = $script:status; SignerCertificate = $certificate }
        }

        $result = Register-WingetSourcePackage

        $result.Registered | Should -Be $false
        $result.Reason | Should -BeLike "*failed its signature check: it is not signed by Microsoft Corporation ($Detail*"
        Should -Invoke Invoke-AppxRegistration -Times 0 -Exactly
        Should -Invoke Add-AppxPackage -Times 0 -Exactly
        Test-Path -LiteralPath $script:stagingDir | Should -Be $false
    }

    It 'Returns the AppX code Add-AppxPackage failed with, and deletes the download' {
        Mock Invoke-AppxRegistration { throw (New-AppxException -HResult -2147009255 -Message 'Deployment failed with HRESULT: 0x80073D19, An error occurred because a user was logged off.') }

        $result = Register-WingetSourcePackage

        $result.Registered | Should -Be $false
        $result.ErrorCodes | Should -Be @(-2147009255)
        $result.Reason | Should -BeLike 'registering it failed: Deployment failed with HRESULT: 0x80073D19*'
        Test-Path -LiteralPath $script:stagingDir | Should -Be $false
    }

    It 'Says how to reset the folder when its access list cannot be set' {
        Mock New-WauStagingDirectory {
            $exception = [System.UnauthorizedAccessException]::new('icacls failed')
            throw [System.Management.Automation.ErrorRecord]::new($exception, 'RestrictedDirectoryAclFailed', [System.Management.Automation.ErrorCategory]::SecurityError, $null)
        }
        Mock Get-RestrictedDirectoryResetHint { ' HINT' }

        $result = Register-WingetSourcePackage

        $result.Registered | Should -Be $false
        $result.Reason | Should -Be 'setting up its download folder failed: icacls failed HINT'
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }
}

Describe 'Get-WingetClientRepairVersion (wgt-gq8.63)' {
    It 'Returns the version of the module Repair-WinGetPackageManager comes from' {
        Mock Get-Command { [pscustomobject]@{ Name = 'Repair-WinGetPackageManager'; Version = [version]'1.28.190'; Module = $null } } -ParameterFilter { $Name -eq 'Repair-WinGetPackageManager' }

        Get-WingetClientRepairVersion | Should -Be ([version]'1.28.190')
    }

    It 'Returns nothing when the cmdlet is not there' {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'Repair-WinGetPackageManager' }

        Get-WingetClientRepairVersion | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-NextWingetSourceFix (wgt-gq8.63)' {
    BeforeEach {
        Mock Register-WingetSourcePackage { [pscustomobject]@{ Registered = $false; ErrorCodes = @(-2147009255); Reason = 'registering it failed' } }
        Mock Invoke-WingetPackageManagerRepair { [pscustomobject]@{ Available = $true; Succeeded = $false; ErrorCodes = @() } }
        Mock Get-WingetClientRepairVersion { [version]'1.29.380' }
        Mock Reset-WingetSource { $true }
        $script:state = @{ ErrorCodes = @() }
    }

    It 'Registers the source package for 0x8A15000F and asks for a check when that worked' {
        Mock Register-WingetSourcePackage { [pscustomobject]@{ Registered = $true; ErrorCodes = @(); Reason = $null } }

        Invoke-NextWingetSourceFix -State $script:state -ExitCode -1978335217 | Should -Be $true

        Should -Invoke Invoke-WingetPackageManagerRepair -Times 0 -Exactly
        Should -Invoke Reset-WingetSource -Times 0 -Exactly
    }

    It 'Goes on to Repair-WinGetPackageManager, told the codes the registration saw, then has nothing left' {
        Invoke-NextWingetSourceFix -State $script:state -ExitCode -1978335217 | Should -Be $true
        Invoke-NextWingetSourceFix -State $script:state -ExitCode -1978335217 | Should -Be $false

        Should -Invoke Register-WingetSourcePackage -Times 1 -Exactly
        Should -Invoke Invoke-WingetPackageManagerRepair -Times 1 -Exactly -ParameterFilter { @($KnownErrorCodes) -contains -2147009255 -and -not $AllUsersFirst }
        Should -Invoke Reset-WingetSource -Times 0 -Exactly
        $script:state.ErrorCodes | Should -Contain -2147009255
    }

    It 'Skips Repair-WinGetPackageManager from a module older than 1.28.190, which never checks the source' {
        Mock Get-WingetClientRepairVersion { [version]'1.12.470' }

        Invoke-NextWingetSourceFix -State $script:state -ExitCode -1978335217 | Should -Be $false

        Should -Invoke Invoke-WingetPackageManagerRepair -Times 0 -Exactly
    }

    It 'Runs no fix at all for SYSTEM' {
        Invoke-NextWingetSourceFix -State $script:state -ExitCode -1978335217 -IsSystem | Should -Be $false

        Should -Invoke Register-WingetSourcePackage -Times 0 -Exactly
        Should -Invoke Invoke-WingetPackageManagerRepair -Times 0 -Exactly
        Should -Invoke Reset-WingetSource -Times 0 -Exactly
    }

    It 'Resets a corrupted or unconfigured source once, for SYSTEM too' {
        Invoke-NextWingetSourceFix -State $script:state -ExitCode -1978335169 -IsSystem | Should -Be $true
        Invoke-NextWingetSourceFix -State $script:state -ExitCode -1978335214 -IsSystem | Should -Be $false

        Should -Invoke Reset-WingetSource -Times 1 -Exactly
        Should -Invoke Register-WingetSourcePackage -Times 0 -Exactly
    }
}

Describe 'Get-WingetSetupAdvice for a source blocked by 0x80073D19 (wgt-gq8.63)' {
    It 'Advises running the installer signed in as the account or the SYSTEM machine phase, never winget source update, which exits 0 when it fails' {
        $advice = Get-WingetSetupAdvice -State @{ ErrorCodes = @() } -Account 'CONTOSO\admin-tech' -Source -SourceExitCode -2147009255

        $advice | Should -Be "Fix: run the installer while signed in to Windows as 'CONTOSO\admin-tech' (Windows deploys winget's packages for an account only in its own logon session), or run the machine phase as SYSTEM with rmm/Invoke-WingetAppSetup.ps1."
        $advice | Should -Not -Match 'source update'
    }

    It 'Tells the uninstaller to run itself, never the machine phase, which installs the catalog' {
        $advice = Get-WingetSetupAdvice -State @{ ErrorCodes = @() } -Account 'CONTOSO\admin-tech' -Source -SourceExitCode -2147009255 -Tool Uninstaller

        $advice | Should -Be "Fix: run the uninstaller while signed in to Windows as 'CONTOSO\admin-tech' (Windows deploys winget's packages for an account only in its own logon session), or run winget-app-uninstall.ps1 as SYSTEM."
        $advice | Should -Not -Match '\binstaller\b|rmm/'
    }
}

Describe 'Get-WingetSetupAdvice and Get-WingetSourceUnusableMessage name the tool that runs (wgt-gq8.64)' {
    BeforeAll {
        $script:crossUser = [pscustomobject]@{ IsSystem = $false; IsCrossUserElevation = $true; ProcessUser = 'CONTOSO\admin-jmaffiola'; SessionUser = 'CONTOSO\tuser' }
        $script:sameUser = [pscustomobject]@{ IsSystem = $false; IsCrossUserElevation = $false; ProcessUser = 'CONTOSO\jdoe'; SessionUser = 'CONTOSO\jdoe' }
        $script:system = [pscustomobject]@{ IsSystem = $true; IsCrossUserElevation = $false; ProcessUser = 'NT AUTHORITY\SYSTEM'; SessionUser = $null }
    }

    It 'Under cross-user elevation, advises running the <Name> signed in as the account (signing in once deploys nothing) or <System>' -ForEach @(
        @{ Tool = 'Installer'; Name = 'installer'; System = 'run the machine phase as SYSTEM with rmm/Invoke-WingetAppSetup.ps1' }
        @{ Tool = 'Uninstaller'; Name = 'uninstaller'; System = 'run winget-app-uninstall.ps1 as SYSTEM' }
    ) {
        $message = Get-WingetSourceUnusableMessage -State @{ ErrorCodes = @() } -AccountContext $script:crossUser -ExitCode -1978335217 -Tool $Tool

        $message | Should -BeLike "*Fix: 'CONTOSO\admin-jmaffiola' is elevated in the session of 'CONTOSO\tuser' and has no logon session of its own, which Windows needs to deploy winget's source package for it: run the $Name while signed in to Windows as 'CONTOSO\admin-jmaffiola', or $System."
        $message | Should -Not -Match 'sign in to Windows once'
    }

    It 'Says to re-run the <Name> in every other case' -ForEach @(
        @{ Tool = 'Installer'; Name = 'installer' }
        @{ Tool = 'Uninstaller'; Name = 'uninstaller' }
    ) {
        $lines = @(
            Get-WingetSourceUnusableMessage -State @{ ErrorCodes = @() } -AccountContext $script:sameUser -ExitCode -1978335217 -Tool $Tool
            Get-WingetSourceUnusableMessage -State @{ ErrorCodes = @(); SourceReset = $true } -AccountContext $script:sameUser -ExitCode -1978335169 -Tool $Tool
            Get-WingetSourceUnusableMessage -State @{ ErrorCodes = @() } -AccountContext $script:system -ExitCode -1978335217 -Tool $Tool
            Get-WingetSetupAdvice -State @{ ErrorCodes = @() } -Account 'CONTOSO\jdoe' -Source -SourceExitCode -1978335162 -Tool $Tool
            Get-WingetSetupAdvice -State @{ ErrorCodes = @() } -Account 'CONTOSO\jdoe' -Tool $Tool
            Get-WingetSetupAdvice -State @{ ErrorCodes = @(-2147009274) } -Account 'CONTOSO\jdoe' -Tool $Tool
        )

        foreach ($line in $lines) {
            $line | Should -BeLike "*then re-run the $Name."
            $line | Should -Not -Match 'rmm/'
        }
    }

    It 'Tells SYSTEM what to do if the <Work> fail, by the <Name>' -ForEach @(
        @{ Tool = 'Installer'; Name = 'installer'; Work = 'installs' }
        @{ Tool = 'Uninstaller'; Name = 'uninstaller'; Work = 'removals' }
    ) {
        Get-WingetSetupAdvice -State @{ ErrorCodes = @() } -Account 'SYSTEM' -Source -SourceExitCode -2147009255 -Tool $Tool |
            Should -Be "The steps that set winget up for a signed-in account do not apply to SYSTEM; if the $Work fail, run the $Name once as an administrator signed in to this PC."
    }
}

# wgt-gq8.70: once Add-AppxPackage had registered the source package, the ERROR line still sent
# the reader to the AppX deployment log, as if Windows had not deployed it.
Describe 'Get-WingetSourceUnusableMessage after the source package was registered (wgt-gq8.70)' {
    BeforeAll {
        $script:crossUser = [pscustomobject]@{ IsSystem = $false; IsCrossUserElevation = $true; ProcessUser = 'CONTOSO\admin-jmaffiola'; SessionUser = 'CONTOSO\stduser' }
        $script:sameUser = [pscustomobject]@{ IsSystem = $false; IsCrossUserElevation = $false; ProcessUser = 'CONTOSO\jdoe'; SessionUser = 'CONTOSO\jdoe' }
    }

    It 'Says the registration <Text> succeeded and points to winget''s log, not the AppX deployment log, under <Case>' -ForEach @(
        @{ Case = 'same-user elevation'; Route = 'Download'; Text = '(downloaded from https://cdn.winget.microsoft.com)'; Reason = $null; Cross = $false }
        @{ Case = 'same-user elevation'; Route = 'FamilyName'; Text = '(by family name, from the copy already on this PC)'; Reason = 'it could not be downloaded from https://cdn.winget.microsoft.com/cache'; Cross = $false }
        @{ Case = 'cross-user elevation'; Route = 'Download'; Text = '(downloaded from https://cdn.winget.microsoft.com)'; Reason = $null; Cross = $true }
        @{ Case = 'cross-user elevation'; Route = 'FamilyName'; Text = '(by family name, from the copy already on this PC)'; Reason = 'registering it failed: Deployment failed with HRESULT: 0x80073D19'; Cross = $true }
    ) {
        $account = $script:sameUser
        if ($Cross) {
            $account = $script:crossUser
        }
        $state = @{ ErrorCodes = @(); SourcePackage = [pscustomobject]@{ Registered = $true; Route = $Route; ErrorCodes = @(); Reason = $Reason } }

        $message = Get-WingetSourceUnusableMessage -State $state -AccountContext $account -ExitCode -1978335217

        $message | Should -BeLike "The winget source cannot be opened for '$($account.ProcessUser)': 'winget search --source winget' answered 0x8A15000F SOURCE_DATA_MISSING, *"
        $message | Should -BeLike "* Registering the winget source package (Microsoft.Winget.Source) for the account succeeded $Text, but winget still cannot open its source. winget's log: *"
        $fix = "* Fix: read winget's log for why it still cannot open the source, check that this PC can reach https://cdn.winget.microsoft.com, then re-run the installer."
        if ($Cross) {
            # wgt-gq8.71 review: the account's own sign-in, or SYSTEM, is still the way out.
            $fix += " If it still fails, run the installer while signed in to Windows as 'CONTOSO\admin-jmaffiola', or run the machine phase as SYSTEM with rmm/Invoke-WingetAppSetup.ps1."
        }
        $message | Should -BeLike $fix
        $message | Should -Not -BeLike '*AppXDeploymentServer*'
        $message | Should -Not -BeLike '*failed*'
        $message | Should -Not -BeLike '*no logon session*'
    }

    It 'Names the uninstaller as the tool to re-run, and as SYSTEM under cross-user elevation' {
        $state = @{ ErrorCodes = @(); SourcePackage = [pscustomobject]@{ Registered = $true; Route = 'Download'; ErrorCodes = @(); Reason = $null } }

        Get-WingetSourceUnusableMessage -State $state -AccountContext $script:crossUser -ExitCode -1978335217 -Tool Uninstaller |
            Should -BeLike "* Fix: read winget's log for why it still cannot open the source, check that this PC can reach https://cdn.winget.microsoft.com, then re-run the uninstaller. If it still fails, run the uninstaller while signed in to Windows as 'CONTOSO\admin-jmaffiola', or run winget-app-uninstall.ps1 as SYSTEM."
        Get-WingetSourceUnusableMessage -State $state -AccountContext $script:sameUser -ExitCode -1978335217 -Tool Uninstaller |
            Should -BeLike "* Fix: read winget's log for why it still cannot open the source, check that this PC can reach https://cdn.winget.microsoft.com, then re-run the uninstaller."
    }

    It 'Still says the registration succeeded when the source then answers another code, with the source settings advice' {
        $state = @{ ErrorCodes = @(); SourceReset = $true; SourcePackage = [pscustomobject]@{ Registered = $true; Route = 'Download'; ErrorCodes = @(); Reason = $null } }

        $message = Get-WingetSourceUnusableMessage -State $state -AccountContext $script:sameUser -ExitCode -1978335169

        $message | Should -BeLike '* for the account succeeded (downloaded from https://cdn.winget.microsoft.com), but winget still cannot open its source.*'
        $message | Should -BeLike "*Fix: read winget's log for why it cannot read its source settings, *"
    }

    It 'Keeps the failed registration and its advice when the package was not registered (<Case>)' -ForEach @(
        @{ Case = 'same-user'; Cross = $false; Fix = '* Fix: look in the Microsoft-Windows-AppXDeploymentServer/Operational event log*' }
        @{ Case = 'cross-user'; Cross = $true; Fix = "* Fix: 'CONTOSO\admin-jmaffiola' is elevated in the session of 'CONTOSO\stduser' and has no logon session of its own*" }
    ) {
        $account = $script:sameUser
        if ($Cross) {
            $account = $script:crossUser
        }
        $state = @{ ErrorCodes = @(); SourcePackage = [pscustomobject]@{ Registered = $false; Route = $null; ErrorCodes = @(-2147009255); Reason = 'registering it failed' } }

        $message = Get-WingetSourceUnusableMessage -State $state -AccountContext $account -ExitCode -1978335217

        $message | Should -BeLike '* Registering the winget source package (Microsoft.Winget.Source) for the account failed (0x80073D19 ERROR_DEPLOYMENT_BLOCKED_BY_USER_LOG_OFF).*'
        $message | Should -BeLike $Fix
        $message | Should -Not -BeLike '*succeeded*'
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
