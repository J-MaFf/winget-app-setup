# MachineContext.Tests.ps1
# Tests for WingetAppSetup/Private/MachineContext.ps1 (review findings P2-24, P3-24): finding the
# winget.exe App Installer installed for the machine, which a run as SYSTEM starts by its full path
# because SYSTEM has no winget of its own, and reading whether an MSIX app is provisioned for every
# user. The Windows layer (Get-AppxPackage -AllUsers, Get-AppxProvisionedPackage) sits behind two
# query seams that are mocked here; the WindowsApps folder is built in TestDrive.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    # A Microsoft.DesktopAppInstaller package folder with a winget.exe in it, under $Root.
    function New-TestAppInstallerFolder {
        param (
            [Parameter(Mandatory = $true)][string]$Root,
            [Parameter(Mandatory = $true)][string]$Version,
            [string]$Architecture = 'x64',
            [switch]$NoWinget
        )
        $folder = Join-Path $Root ('Microsoft.DesktopAppInstaller_{0}_{1}__8wekyb3d8bbwe' -f $Version, $Architecture)
        [void](New-Item -ItemType Directory -Path $folder -Force)
        if (-not $NoWinget) {
            Set-Content -LiteralPath (Join-Path $folder 'winget.exe') -Value 'stand-in' -Encoding ascii
        }
        return $folder
    }
}

Describe 'Get-DesktopAppInstallerPackageInfo (the Get-AppxPackage -AllUsers query seam)' {
    It 'Lists App Installer for every account through Windows PowerShell and parses Version|Architecture|Status|InstallLocation' -Skip:($PSVersionTable.PSEdition -ne 'Core') {
        Mock powershell.exe { $global:LASTEXITCODE = 0; '1.27.460.0|X64|Ok|C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_1.27.460.0_x64__8wekyb3d8bbwe'; 'WARNING: noise'; '' }

        $packages = @(Get-DesktopAppInstallerPackageInfo)

        $packages.Count | Should -Be 1
        $packages[0].Version | Should -Be ([version]'1.27.460.0')
        $packages[0].Architecture | Should -Be 'X64'
        $packages[0].Status | Should -Be 'Ok'
        $packages[0].InstallLocation | Should -Be 'C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_1.27.460.0_x64__8wekyb3d8bbwe'
        Should -Invoke powershell.exe -Times 1 -Exactly -ParameterFilter { "$args" -match "Get-AppxPackage -AllUsers -Name 'Microsoft\.DesktopAppInstaller'" }
    }

    It 'Throws when the Windows PowerShell query fails' -Skip:($PSVersionTable.PSEdition -ne 'Core') {
        Mock powershell.exe { $global:LASTEXITCODE = 1 }

        { Get-DesktopAppInstallerPackageInfo } | Should -Throw '*Get-AppxPackage -AllUsers failed*'
    }
}

Describe 'Get-MachineWingetCandidate (review finding P2-24)' {
    BeforeEach {
        Mock Write-WarningMessage { }
        $script:savedProgramW6432 = $env:ProgramW6432
        $script:savedProgramFiles = $env:ProgramFiles
        $script:programFiles = Join-Path $TestDrive ('pf-' + [guid]::NewGuid().ToString('N'))
        $script:windowsApps = Join-Path $script:programFiles 'WindowsApps'
        [void](New-Item -ItemType Directory -Path $script:windowsApps -Force)
        $env:ProgramW6432 = $script:programFiles
    }

    AfterEach {
        $env:ProgramW6432 = $script:savedProgramW6432
        $env:ProgramFiles = $script:savedProgramFiles
    }

    It 'Takes the Status Ok package with the highest version, compared as a version, not as text' {
        $old = New-TestAppInstallerFolder -Root $script:windowsApps -Version '1.9.25200.0'
        $new = New-TestAppInstallerFolder -Root $script:windowsApps -Version '1.27.460.0'
        Mock Get-DesktopAppInstallerPackageInfo {
            [pscustomobject]@{ Version = [version]'1.9.25200.0'; Architecture = 'X64'; Status = 'Ok'; InstallLocation = $old }
            [pscustomobject]@{ Version = [version]'1.27.460.0'; Architecture = 'X64'; Status = 'Ok'; InstallLocation = $new }
        }

        $candidates = @(Get-MachineWingetCandidate -ProcessorArchitecture 'AMD64')

        $candidates.Count | Should -Be 2
        $candidates[0].Path | Should -Be (Join-Path $new 'winget.exe')
        $candidates[0].Version | Should -Be ([version]'1.27.460.0')
        $candidates[0].Source | Should -Be 'Get-AppxPackage -AllUsers'
        $candidates[1].Path | Should -Be (Join-Path $old 'winget.exe')
    }

    It 'Leaves out a package whose status is not Ok, or that has no winget.exe' {
        $tampered = New-TestAppInstallerFolder -Root $script:windowsApps -Version '1.28.0.0'
        $empty = New-TestAppInstallerFolder -Root $script:windowsApps -Version '1.27.0.0' -NoWinget
        $good = New-TestAppInstallerFolder -Root $script:windowsApps -Version '1.26.510.0'
        Mock Get-DesktopAppInstallerPackageInfo {
            [pscustomobject]@{ Version = [version]'1.28.0.0'; Architecture = 'X64'; Status = 'Tampered'; InstallLocation = $tampered }
            [pscustomobject]@{ Version = [version]'1.27.0.0'; Architecture = 'X64'; Status = 'Ok'; InstallLocation = $empty }
            [pscustomobject]@{ Version = [version]'1.26.510.0'; Architecture = 'X64'; Status = 'Ok'; InstallLocation = $good }
        }

        $candidates = @(Get-MachineWingetCandidate -ProcessorArchitecture 'AMD64')

        @($candidates | ForEach-Object { $_.Path }) | Should -Be @((Join-Path $good 'winget.exe'))
    }

    It 'Does not bring a package the query turned down back through the WindowsApps folder' {
        # The query works but lists App Installer only with a status other than Ok, so it yields no
        # candidate and the folder scan runs. That package's folder, winget.exe and all, must stay
        # out (review of finding P2-24).
        $tampered = New-TestAppInstallerFolder -Root $script:windowsApps -Version '1.28.0.0'
        $remediation = New-TestAppInstallerFolder -Root $script:windowsApps -Version '1.27.460.0' -Architecture 'arm64'
        Mock Get-DesktopAppInstallerPackageInfo {
            [pscustomobject]@{ Version = [version]'1.28.0.0'; Architecture = 'X64'; Status = 'Tampered'; InstallLocation = $tampered }
            [pscustomobject]@{ Version = [version]'1.27.460.0'; Architecture = 'Arm64'; Status = 'NeedsRemediation'; InstallLocation = $remediation }
        }

        @(Get-MachineWingetCandidate -ProcessorArchitecture 'AMD64').Count | Should -Be 0
        @(Get-MachineWingetCandidate -ProcessorArchitecture 'ARM64').Count | Should -Be 0
    }

    It 'Still scans WindowsApps for the folders the query did not turn down' {
        [void](New-TestAppInstallerFolder -Root $script:windowsApps -Version '1.28.0.0')
        $other = New-TestAppInstallerFolder -Root $script:windowsApps -Version '1.27.460.0'
        Mock Get-DesktopAppInstallerPackageInfo {
            [pscustomobject]@{ Version = [version]'1.28.0.0'; Architecture = 'X64'; Status = 'Modified'; InstallLocation = '' }
        }

        @(Get-MachineWingetCandidate -ProcessorArchitecture 'AMD64' | ForEach-Object { $_.Path }) | Should -Be @((Join-Path $other 'winget.exe'))
    }

    It 'Puts the PC''s own architecture first on ARM64, and leaves arm64 out on an x64 PC' {
        $arm = New-TestAppInstallerFolder -Root $script:windowsApps -Version '1.26.0.0' -Architecture 'arm64'
        $x64 = New-TestAppInstallerFolder -Root $script:windowsApps -Version '1.27.0.0' -Architecture 'x64'
        Mock Get-DesktopAppInstallerPackageInfo {
            [pscustomobject]@{ Version = [version]'1.26.0.0'; Architecture = 'Arm64'; Status = 'Ok'; InstallLocation = $arm }
            [pscustomobject]@{ Version = [version]'1.27.0.0'; Architecture = 'X64'; Status = 'Ok'; InstallLocation = $x64 }
        }

        $onArm = @(Get-MachineWingetCandidate -ProcessorArchitecture 'ARM64')
        $onX64 = @(Get-MachineWingetCandidate -ProcessorArchitecture 'AMD64')

        $onArm[0].Path | Should -Be (Join-Path $arm 'winget.exe')
        $onArm[1].Path | Should -Be (Join-Path $x64 'winget.exe')
        @($onX64 | ForEach-Object { $_.Path }) | Should -Be @((Join-Path $x64 'winget.exe'))
    }

    It 'Looks under WindowsApps when the Get-AppxPackage query fails, and sorts by version there too' {
        [void](New-TestAppInstallerFolder -Root $script:windowsApps -Version '1.9.25200.0')
        $newest = New-TestAppInstallerFolder -Root $script:windowsApps -Version '1.27.460.0'
        [void](New-TestAppInstallerFolder -Root $script:windowsApps -Version '1.26.510.0')
        # A resource package and an unrelated folder: not App Installer's main package.
        [void](New-Item -ItemType Directory -Path (Join-Path $script:windowsApps 'Microsoft.DesktopAppInstaller_1.27.460.0_neutral_~_8wekyb3d8bbwe') -Force)
        [void](New-Item -ItemType Directory -Path (Join-Path $script:windowsApps 'Microsoft.WindowsTerminal_1.21.0.0_x64__8wekyb3d8bbwe') -Force)
        Mock Get-DesktopAppInstallerPackageInfo { throw 'The Appx module could not be loaded.' }

        $candidates = @(Get-MachineWingetCandidate -ProcessorArchitecture 'AMD64')

        $candidates.Count | Should -Be 3
        $candidates[0].Path | Should -Be (Join-Path $newest 'winget.exe')
        $candidates[0].Source | Should -Be 'WindowsApps'
        @($candidates | ForEach-Object { "$($_.Version)" }) | Should -Be @('1.27.460.0', '1.26.510.0', '1.9.25200.0')
        Should -Invoke Write-WarningMessage -Times 1 -Exactly -ParameterFilter { $Message -match 'Could not list App Installer for all accounts' }
    }

    It 'Looks under WindowsApps when the Get-AppxPackage query finds no usable package' {
        $folder = New-TestAppInstallerFolder -Root $script:windowsApps -Version '1.27.460.0'
        Mock Get-DesktopAppInstallerPackageInfo { }

        $candidates = @(Get-MachineWingetCandidate -ProcessorArchitecture 'AMD64')

        $candidates[0].Path | Should -Be (Join-Path $folder 'winget.exe')
    }

    It 'Uses ProgramW6432, the real Program Files of a 32-bit process, over ProgramFiles' {
        $folder = New-TestAppInstallerFolder -Root $script:windowsApps -Version '1.27.460.0'
        $env:ProgramFiles = Join-Path $TestDrive 'x86-program-files'
        Mock Get-DesktopAppInstallerPackageInfo { }

        $candidates = @(Get-MachineWingetCandidate -ProcessorArchitecture 'AMD64')

        $candidates[0].Path | Should -Be (Join-Path $folder 'winget.exe')
    }

    It 'Returns nothing when App Installer is not installed for the machine' {
        Mock Get-DesktopAppInstallerPackageInfo { }

        @(Get-MachineWingetCandidate -ProcessorArchitecture 'AMD64').Count | Should -Be 0
    }
}

Describe 'Test-MachineWingetAvailable (review finding P2-24)' {
    BeforeEach {
        Mock Write-Host { }
        $script:errorMessages = @()
        Mock Write-ErrorMessage { $script:errorMessages += $Message }
        $script:infoMessages = @()
        Mock Write-Info { $script:infoMessages += $Message }
        Mock Write-Success { }
        Mock Write-WarningMessage { }
        # The per-account rungs a signed-in account's run tries: none may run as SYSTEM.
        Mock Register-WingetAppInstallerForUser { throw 'must not register App Installer for SYSTEM' }
        Mock Invoke-WingetPackageManagerRepair { throw 'must not repair winget for SYSTEM' }
        Mock Invoke-WebRequest { throw 'must not download App Installer for SYSTEM' }
        Mock Add-AppxPackage { throw 'must not register a package for SYSTEM' }
        Mock Invoke-AppxRegistration { throw 'must not register a package for SYSTEM' }

        $script:newest = Join-Path $TestDrive 'Microsoft.DesktopAppInstaller_1.27.460.0_x64__8wekyb3d8bbwe\winget.exe'
        $script:older = Join-Path $TestDrive 'Microsoft.DesktopAppInstaller_1.26.510.0_x64__8wekyb3d8bbwe\winget.exe'
        foreach ($path in @($script:newest, $script:older)) {
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force)
            Set-Content -LiteralPath $path -Value 'stand-in' -Encoding ascii
        }
        Mock Get-MachineWingetCandidate {
            [pscustomobject]@{ Path = $script:newest; Version = [version]'1.27.460.0'; Architecture = 'x64'; Source = 'Get-AppxPackage -AllUsers' }
            [pscustomobject]@{ Path = $script:older; Version = [version]'1.26.510.0'; Architecture = 'x64'; Source = 'Get-AppxPackage -AllUsers' }
        }
        # Which winget.exe starts, by the path Resolve-WingetExecutable hands every winget call.
        $script:launchable = @($script:newest)
        $script:launchReason = "'winget --version' exited with 0xC0000135 STATUS_DLL_NOT_FOUND"
        $script:probedPaths = @()
        Mock Test-WingetLaunchable {
            $path = Resolve-WingetExecutable
            $script:probedPaths += $path
            if ($script:launchable -contains $path) {
                return [pscustomobject]@{ Launchable = $true; Version = 'v1.12.350'; Reason = $null; Attempts = 1 }
            }
            [pscustomobject]@{ Launchable = $false; Version = $null; Reason = $script:launchReason; Attempts = 1 }
        }
        $script:MachineWingetPath = 'C:\stale\from\an\earlier\run\winget.exe'
    }

    AfterEach {
        $script:MachineWingetPath = $null
    }

    It 'Keeps the newest machine-wide winget.exe that starts, for every later winget call' {
        Test-MachineWingetAvailable | Should -Be $true

        $script:MachineWingetPath | Should -Be $script:newest
        Resolve-WingetExecutable | Should -Be $script:newest
        $script:probedPaths | Should -Be @($script:newest)
        # The first winget.exe gets the same 75 seconds a locked or updating App Installer gets.
        Should -Invoke Test-WingetLaunchable -Times 1 -Exactly -ParameterFilter { $Attempts -eq 6 -and $RetryDelaySeconds -eq 15 }
    }

    It 'Tries the next machine-wide winget.exe when the newest does not start' {
        $script:launchable = @($script:older)

        Test-MachineWingetAvailable | Should -Be $true

        $script:probedPaths | Should -Be @($script:newest, $script:older)
        Resolve-WingetExecutable | Should -Be $script:older
    }

    It 'Fails with a message for SYSTEM, and runs none of the per-account steps, when no winget.exe starts' {
        $script:launchable = @()

        Test-MachineWingetAvailable | Should -Be $false

        $script:MachineWingetPath | Should -BeNullOrEmpty
        $text = $script:errorMessages -join "`n"
        $text | Should -Match 'winget could not be started as SYSTEM \(tried the machine-wide 2 winget\.exe files above\)'
        # The loader's 'DLL not found' gets the reported cause.
        $text | Should -Match 'Microsoft Visual C\+\+ 2015-2022 runtime'
        $text | Should -Match 'do not apply to SYSTEM and were skipped'
        $text | Should -Not -Match 'your account|log on to Windows'
        Should -Invoke Register-WingetAppInstallerForUser -Times 0 -Exactly
        Should -Invoke Invoke-WingetPackageManagerRepair -Times 0 -Exactly
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        Should -Invoke Add-AppxPackage -Times 0 -Exactly
        Should -Invoke Invoke-AppxRegistration -Times 0 -Exactly
    }

    It 'Says no machine-wide winget was found, without starting anything, when App Installer is not installed for the machine' {
        Mock Get-MachineWingetCandidate { }

        Test-MachineWingetAvailable | Should -Be $false

        $script:errorMessages -join "`n" | Should -Match 'No machine-wide winget was found'
        Should -Invoke Test-WingetLaunchable -Times 0 -Exactly
        Should -Invoke Register-WingetAppInstallerForUser -Times 0 -Exactly
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    It 'Reports what a real run would do in a dry run, as information' {
        Mock Get-MachineWingetCandidate { }

        Test-MachineWingetAvailable -WhatIf | Should -Be $false

        $script:errorMessages | Should -BeNullOrEmpty
        ($script:infoMessages -join "`n") | Should -Match '\[DRY-RUN\] No machine-wide winget was found.*A real run would stop here with exit code 2\.'
    }

    # wgt-gq8.42: when Microsoft.WinGet.Client installs, winget.exe matters only to Winget-AutoUpdate.
    Context 'Not required (-NotRequired: the WinGet client engine installs)' {
        BeforeEach {
            $script:warnings = @()
            Mock Write-WarningMessage { $script:warnings += $Message }
        }

        It 'Checks the winget.exe files the same way and keeps the one that starts' {
            Test-MachineWingetAvailable -NotRequired | Should -Be $true

            Resolve-WingetExecutable | Should -Be $script:newest
            Should -Invoke Test-WingetLaunchable -Times 1 -Exactly -ParameterFilter { $Attempts -eq 6 -and $RetryDelaySeconds -eq 15 }
        }

        It 'Warns, naming Winget-AutoUpdate and not exit code 2, when <Case>' -ForEach @(
            @{ Case = 'none starts'; NoCandidate = $false; Expected = 'The machine-wide winget\.exe could not be started as SYSTEM \(tried 2 winget\.exe files above\)\..* Winget-AutoUpdate needs it; repair or update App Installer for this PC\.' }
            @{ Case = 'there is none'; NoCandidate = $true; Expected = 'No machine-wide winget was found: .* Winget-AutoUpdate needs that winget\.exe; install or update App Installer for this PC\.' }
        ) {
            $script:launchable = @()
            if ($NoCandidate) {
                Mock Get-MachineWingetCandidate { }
            }

            Test-MachineWingetAvailable -NotRequired | Should -Be $false

            $script:errorMessages | Should -BeNullOrEmpty
            ($script:warnings -join "`n") | Should -Match $Expected
            ($script:warnings -join "`n") | Should -Not -Match 'exit code 2'
        }
    }
}

Describe 'Get-ProvisionedAppxPackageName (the Get-AppxProvisionedPackage query seam)' {
    It 'Lists the provisioned packages'' names through Windows PowerShell' -Skip:($PSVersionTable.PSEdition -ne 'Core') {
        Mock powershell.exe { $global:LASTEXITCODE = 0; 'Microsoft.WindowsTerminal'; ' Microsoft.WindowsStore '; '' }

        @(Get-ProvisionedAppxPackageName) | Should -Be @('Microsoft.WindowsTerminal', 'Microsoft.WindowsStore')
        Should -Invoke powershell.exe -Times 1 -Exactly -ParameterFilter { "$args" -match 'Get-AppxProvisionedPackage -Online' }
    }

    It 'Throws when the Windows PowerShell query fails' -Skip:($PSVersionTable.PSEdition -ne 'Core') {
        Mock powershell.exe { $global:LASTEXITCODE = 5 }

        { Get-ProvisionedAppxPackageName } | Should -Throw '*Get-AppxProvisionedPackage failed*'
    }
}

Describe 'Test-AppxPackageProvisionedForMachine (review finding P3-24)' {
    BeforeEach {
        Mock Write-WarningMessage { }
    }

    It 'Is true when the package is provisioned for every user' {
        Mock Get-ProvisionedAppxPackageName { 'Microsoft.WindowsStore'; 'Microsoft.WindowsTerminal' }

        Test-AppxPackageProvisionedForMachine -Name 'Microsoft.WindowsTerminal' | Should -Be $true
    }

    It 'Is false when it is not' {
        Mock Get-ProvisionedAppxPackageName { 'Microsoft.WindowsStore'; 'Microsoft.WindowsTerminalPreview' }

        Test-AppxPackageProvisionedForMachine -Name 'Microsoft.WindowsTerminal' | Should -Be $false
    }

    It 'Is $null, with a warning, when the provisioned packages cannot be read' {
        Mock Get-ProvisionedAppxPackageName { throw 'DISM failed' }

        $result = Test-AppxPackageProvisionedForMachine -Name 'Microsoft.WindowsTerminal'

        ($null -eq $result) | Should -BeTrue -Because 'an unreadable answer is neither yes nor no'
        Should -Invoke Write-WarningMessage -Times 1 -Exactly -ParameterFilter { $Message -match 'Could not read the apps provisioned for every user' }
    }
}
