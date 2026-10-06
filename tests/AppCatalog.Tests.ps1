# AppCatalog.Tests.ps1
# Tests for WingetAppSetup/Public/AppCatalog.ps1: the curated Get-DefaultAppCatalog list
# and its consistent consumption by the generated installer and uninstaller.
# Split from the old single-file suite Test-WingetAppInstall.Tests.ps1 (issue #192).

# Load the module's functions once for this file. TestHelpers.ps1 resolves the repo paths
# and dot-sources WingetAppSetup/Private + Public (the single source of truth; the
# distributable winget-app-install.ps1 is generated from it by build/Build-WingetInstallScript.ps1).
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'App list consistency (issue #190)' {
    # The old form of this test parsed the duplicated inline lists in winget-app-install.ps1 and
    # winget-app-uninstall.ps1 and compared them. Both scripts are now generated from the module and
    # consume Get-DefaultAppCatalog, so sync is structural; what remains worth guarding is (a) the
    # generated scripts actually carry the module's catalog and (b) the uninstaller's entry block
    # never regrows an inline copy.
    It 'Ships the module catalog inside the generated installer' {
        $installApps = Get-Content $script:InstallerScriptPath |
        ForEach-Object {
            if ($_ -match "@{name = '([^']+)'") { $matches[1] }
        } |
        Where-Object { $_ }

        $catalogNames = @(Get-DefaultAppCatalog) | ForEach-Object { $_.name }
        $installApps | Should -Be $catalogNames
    }

    It 'Ships the module catalog inside the generated uninstaller too' {
        # winget-app-uninstall.ps1 is generated from the module as the installer is (wgt-gq8.43), so
        # it carries the same Get-DefaultAppCatalog.
        $uninstallApps = Get-Content $script:UninstallerScriptPath |
        ForEach-Object {
            if ($_ -match "@{name = '([^']+)'") { $matches[1] }
        } |
        Where-Object { $_ }

        $catalogNames = @(Get-DefaultAppCatalog) | ForEach-Object { $_.name }
        $uninstallApps | Should -Be $catalogNames
    }

    It 'Uninstaller removes the Get-DefaultAppCatalog apps instead of an inline copy of the list' {
        # Its entry block runs Invoke-WingetUninstall (review findings P2-19, P3-18), whose -Apps
        # defaults to the module catalog, as Invoke-WingetInstall's does.
        $entryBlock = Get-Content (Join-Path $script:RepoRoot 'build/fragments/uninstall-tail.ps1') -Raw
        $entryBlock | Should -Match '(?m)Invoke-WingetUninstall -WhatIf:\$WhatIf\s*$'
        $appsParameter = ${function:Invoke-WingetUninstall}.Ast.Body.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Apps' }
        $appsParameter.DefaultValue.Extent.Text | Should -Be '(Get-DefaultAppCatalog)'
        # The previously duplicated inline list (which had already drifted in metadata) is gone.
        $entryBlock | Should -Not -Match "@\{name = '"
    }

    It 'Uninstaller reuses the module installed-check, process and elevation helpers (issue #190)' {
        $entryBlock = Get-Content (Join-Path $script:RepoRoot 'build/fragments/uninstall-tail.ps1') -Raw
        # Relaunched as a checked copy, as the installer is (wgt-gq8.43; its relaunch is tested in
        # Uninstall.Tests.ps1 and EntryPoint.Tests.ps1).
        $entryBlock | Should -Match 'Restart-WithElevation -ScriptPath \$PSCommandPath -ExpectedSha256 \$uninstallerSha256 -NonInteractive:\$NonInteractive'
        $entryBlock | Should -Not -Match 'Start-Process powershell\.exe|Import-Module'
        $appStep = ${function:Uninstall-CatalogApp}.ToString()
        $appStep | Should -Match 'Test-WingetPackageInstalled -PackageId'
        $appStep | Should -Match 'Invoke-WingetProcess -ArgumentList'
        # No bare winget call anywhere in the uninstaller (review finding P3-18): it had no time limit
        # and its output never reached the log.
        foreach ($ast in @([System.Management.Automation.Language.Parser]::ParseFile($script:UninstallerScriptPath, [ref]$null, [ref]$null), ${function:Invoke-WingetUninstall}.Ast, ${function:Uninstall-CatalogApp}.Ast)) {
            $bareWinget = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'winget' }, $true)
            @($bareWinget).Count | Should -Be 0
        }
    }

    It 'Defines in the generated uninstaller every module function its entry block calls' {
        # Nothing is imported from beside it any more (wgt-gq8.43): a function the entry block calls
        # must be in the file itself. The build's reference guard checks every call; this pins the
        # ones the entry block makes.
        $scriptAst = [System.Management.Automation.Language.Parser]::ParseFile($script:UninstallerScriptPath, [ref]$null, [ref]$null)
        $defined = @($scriptAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) | ForEach-Object { $_.Name })
        $entryAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoRoot 'build/fragments/uninstall-tail.ps1'), [ref]$null, [ref]$null)
        $calledFunctions = @($entryAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) |
                ForEach-Object { $_.GetCommandName() } |
                Where-Object { $_ -and (Get-Command -Name $_ -CommandType Function -ErrorAction SilentlyContinue) } |
                Sort-Object -Unique)
        $calledFunctions | Should -Contain 'Invoke-WingetUninstall'
        $calledFunctions | Should -Contain 'Restart-WithElevation'
        foreach ($helper in $calledFunctions) {
            $defined | Should -Contain $helper
        }
    }
}

Describe 'Get-DefaultAppCatalog (issue #190)' {
    It 'Returns a non-empty array in which every entry is a hashtable with a well-formed package id' {
        $catalog = @(Get-DefaultAppCatalog)

        $catalog.Count | Should -BeGreaterThan 0
        foreach ($app in $catalog) {
            $app | Should -BeOfType [hashtable]
            $app.ContainsKey('name') | Should -Be $true
            # Same package-id shape Install-WingetPackage validates before trusting winget output.
            $app.name | Should -Match '^[\w][\w.\-]+\.[\w][\w.\-]+\z'
        }
    }

    It 'Passes Test-AppDefinitions cleanly (no errors, warnings, or dropped entries)' {
        $catalog = @(Get-DefaultAppCatalog)

        $result = Test-AppDefinitions -Apps $catalog

        $result.Errors.Count | Should -Be 0
        $result.Warnings.Count | Should -Be 0
        @($result.ValidApps).Count | Should -Be $catalog.Count
    }

    It 'Preserves the PowerShell custom install strategy (issues #163/#166)' {
        $psApp = @(Get-DefaultAppCatalog) | Where-Object { $_.name -eq 'Microsoft.PowerShell' }

        @($psApp).Count | Should -Be 1
        $psApp.install | Should -Be 'Install-PowerShellLatest'
    }

    Context 'Manufacturer-aware gating for Dell Command Update (issue #217)' {
        BeforeEach {
            # The manufacturer tests are about the condition; the arch list is tested below.
            Mock Get-OSArchitecture { 'X64' }
        }

        It 'Gates Dell.CommandUpdate.Universal behind a condition with a human-readable description' {
            $dellApp = @(Get-DefaultAppCatalog) | Where-Object { $_.name -eq 'Dell.CommandUpdate.Universal' }

            @($dellApp).Count | Should -Be 1
            $dellApp.condition | Should -BeOfType [scriptblock]
            $dellApp.conditionDescription | Should -Match '^Dell hardware'
        }

        It 'Condition is true on Dell hardware and false on non-Dell hardware' {
            $dellApp = @(Get-DefaultAppCatalog) | Where-Object { $_.name -eq 'Dell.CommandUpdate.Universal' }

            Mock Get-ComputerManufacturer { 'Dell Inc.' }
            [bool](& $dellApp.condition) | Should -Be $true

            Mock Get-ComputerManufacturer { 'Microsoft Corporation' }
            [bool](& $dellApp.condition) | Should -Be $false
        }

        # Review finding P3-33: with no answer from CIM the condition used to read "not Dell" and
        # skip Dell Command Update on a Dell PC with exit 0. Fail open = attempt the install.
        It 'Fails open when the manufacturer query writes a non-terminating error: the app applies' {
            $dellApp = @(Get-DefaultAppCatalog) | Where-Object { $_.name -eq 'Dell.CommandUpdate.Universal' }
            Mock Write-WarningMessage { }
            Mock Get-CimInstance { Write-Error 'Invalid class' }

            Test-AppApplicability -App $dellApp | Should -Be $true
            Should -Invoke Write-WarningMessage -Times 1 -Exactly -ParameterFilter { $Message -match 'Dell\.CommandUpdate\.Universal' -and $Message -match 'Invalid class' }
        }

        It 'Fails open when Win32_ComputerSystem reports no manufacturer' {
            $dellApp = @(Get-DefaultAppCatalog) | Where-Object { $_.name -eq 'Dell.CommandUpdate.Universal' }
            Mock Write-WarningMessage { }
            Mock Get-CimInstance { [pscustomobject]@{ Manufacturer = '' } }

            Test-AppApplicability -App $dellApp | Should -Be $true
        }

        It 'Attempts the install, not a not-applicable skip, when the manufacturer query fails' {
            $dellApp = @(Get-DefaultAppCatalog) | Where-Object { $_.name -eq 'Dell.CommandUpdate.Universal' }
            Mock Write-WarningMessage { }
            Mock Write-Info { }
            Mock Get-CimInstance { Write-Error 'RPC server is unavailable' }
            Mock Install-WingetPackage { @{ ExitCode = 0; Attempts = 1 } }
            $script:dellChecks = 0
            Mock Test-WingetPackageInstalled {
                $script:dellChecks++
                @{ Installed = ($script:dellChecks -gt 1); TimedOut = $false; LaunchFailed = $false; LaunchError = $null; ExitCode = 0 }
            }

            $outcome = Install-AppWithVerification -App $dellApp

            $outcome.SkipReason | Should -Not -Be 'NotApplicable'
            $outcome.Status | Should -Be 'Installed'
            Should -Invoke Install-WingetPackage -Times 1 -Exactly -ParameterFilter { $PackageId -eq 'Dell.CommandUpdate.Universal' }
        }
    }

    Context 'Windows Terminal self-lock gating (issue #271)' {
        It 'Gates Microsoft.WindowsTerminal behind a condition with a human-readable description' {
            $wtApp = @(Get-DefaultAppCatalog) | Where-Object { $_.name -eq 'Microsoft.WindowsTerminal' }

            @($wtApp).Count | Should -Be 1
            $wtApp.condition | Should -BeOfType [scriptblock]
            $wtApp.conditionDescription | Should -Match 'issue #271'
        }

        It 'Condition is false when the current session is hosted by Windows Terminal, true otherwise' {
            $wtApp = @(Get-DefaultAppCatalog) | Where-Object { $_.name -eq 'Microsoft.WindowsTerminal' }
            Mock Test-IsSystemAccount { $false }

            Mock Test-WindowsTerminalHostsCurrentSession { $true }
            [bool](& $wtApp.condition) | Should -Be $false

            Mock Test-WindowsTerminalHostsCurrentSession { $false }
            [bool](& $wtApp.condition) | Should -Be $true
        }

        It 'Condition is true for a run as SYSTEM, which has no Terminal session to lock (review finding P3-24)' {
            $wtApp = @(Get-DefaultAppCatalog) | Where-Object { $_.name -eq 'Microsoft.WindowsTerminal' }
            Mock Test-IsSystemAccount { $true }
            Mock Test-WindowsTerminalHostsCurrentSession { $true }

            [bool](& $wtApp.condition) | Should -Be $true
        }

        It 'Names its MSIX package, so a run for the whole PC decides it from provisioning (review finding P3-24)' {
            $wtApp = @(Get-DefaultAppCatalog) | Where-Object { $_.name -eq 'Microsoft.WindowsTerminal' }

            $wtApp.msixName | Should -Be 'Microsoft.WindowsTerminal'
        }

        # Review finding P3-35: default-terminal values left behind after Windows Terminal was
        # removed made the catalog skip the Windows Terminal install as 'not applicable' forever.
        It 'Applies when the default-terminal values point at Windows Terminal but Windows Terminal is not installed' {
            $wtApp = @(Get-DefaultAppCatalog) | Where-Object { $_.name -eq 'Microsoft.WindowsTerminal' }
            # Not SYSTEM, which short-circuits the condition to true (review finding P3-24): this
            # test is about the default-terminal values, so the session check must actually run.
            Mock Test-IsSystemAccount { $false }
            $savedWtSession = $env:WT_SESSION
            $env:WT_SESSION = $null
            try {
                Mock Get-ItemProperty {
                    [pscustomobject]@{
                        DelegationConsole  = '{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}'
                        DelegationTerminal = '{E12CFF52-A866-4C77-9A90-F570A7AA2C6B}'
                    }
                } -ParameterFilter { $Path -eq 'HKCU:\Console\%%Startup' }
                Mock Get-AppxPackage { }
                Mock Get-CimInstance { [pscustomobject]@{ Name = 'conhost.exe'; ParentProcessId = $null } }

                [bool](& $wtApp.condition) | Should -Be $true
            }
            finally {
                $env:WT_SESSION = $savedWtSession
            }
        }
    }

    # Review finding P3-32: Adobe.Acrobat.Reader.64-bit has only an x64 installer, which Adobe does
    # not support on ARM64 Windows, so an ARM64 PC failed it in both passes on every run (exit 1).
    # ARM64 PCs get Adobe.Acrobat.Reader.32-bit (x86), the build Adobe supports there, instead.
    Context 'Architecture gating for Adobe Acrobat Reader (review finding P3-32)' {
        BeforeEach {
            $script:warnings = @()
            Mock Write-WarningMessage { $script:warnings += $Message }
        }

        It 'Gates Adobe.Acrobat.Reader.64-bit to x64 Windows with an arch list, and says why' {
            $readerApp = @(Get-DefaultAppCatalog) | Where-Object { $_.name -eq 'Adobe.Acrobat.Reader.64-bit' }

            @($readerApp).Count | Should -Be 1
            @($readerApp.arch) | Should -Be @('X64')
            $readerApp.ContainsKey('condition') | Should -BeFalse
            $readerApp.conditionDescription | Should -Match 'ARM64'
        }

        # Gating the 64-bit Reader alone left ARM64 PCs with no PDF reader at all. 32-bit Windows
        # cannot run the 64-bit Reader's x64 installer either.
        It 'Gates Adobe.Acrobat.Reader.32-bit to ARM64 and 32-bit Windows with an arch list, and says why' {
            $readerApp = @(Get-DefaultAppCatalog) | Where-Object { $_.name -eq 'Adobe.Acrobat.Reader.32-bit' }

            @($readerApp).Count | Should -Be 1
            @($readerApp.arch) | Should -Be @('Arm64', 'X86')
            $readerApp.ContainsKey('condition') | Should -BeFalse
            $readerApp.conditionDescription | Should -Match 'ARM64'
        }

        It 'Offers exactly one Reader on <Architecture>: <Expected>' -ForEach @(
            @{ Architecture = 'Arm64'; Expected = 'Adobe.Acrobat.Reader.32-bit' }
            @{ Architecture = 'X64'; Expected = 'Adobe.Acrobat.Reader.64-bit' }
            @{ Architecture = 'X86'; Expected = 'Adobe.Acrobat.Reader.32-bit' }
        ) {
            $readerApps = @(Get-DefaultAppCatalog | Where-Object { $_.name -like 'Adobe.Acrobat.Reader.*' })
            $script:mockedArchitecture = $Architecture
            Mock Get-OSArchitecture { $script:mockedArchitecture }

            $applicable = @($readerApps | Where-Object { Test-AppApplicability -App $_ } | ForEach-Object { $_.name })

            $applicable | Should -Be @($Expected)
            $script:warnings | Should -BeNullOrEmpty
        }

        It 'Gives the skip line the description, not the bare architecture list, on <Architecture>' -ForEach @(
            @{ Architecture = 'Arm64'; Name = 'Adobe.Acrobat.Reader.64-bit'; Reason = 'its only installer is x64, and Adobe supports only the 32-bit Reader on ARM64 Windows' }
            @{ Architecture = 'X64'; Name = 'Adobe.Acrobat.Reader.32-bit'; Reason = 'ARM64 and 32-bit Windows only; x64 PCs get the 64-bit Reader' }
        ) {
            $readerApp = @(Get-DefaultAppCatalog) | Where-Object { $_.name -eq $Name }
            $script:mockedArchitecture = $Architecture
            Mock Get-OSArchitecture { $script:mockedArchitecture }

            Get-AppNotApplicableReason -App $readerApp | Should -Be $Reason
        }

        It 'Reports the <Name> as not applicable on <Architecture> without any winget probe or install' -ForEach @(
            @{ Architecture = 'Arm64'; Name = 'Adobe.Acrobat.Reader.64-bit' }
            @{ Architecture = 'X64'; Name = 'Adobe.Acrobat.Reader.32-bit' }
        ) {
            $readerApp = @(Get-DefaultAppCatalog) | Where-Object { $_.name -eq $Name }
            $script:mockedArchitecture = $Architecture
            Mock Get-OSArchitecture { $script:mockedArchitecture }
            Mock Test-WingetPackageInstalled { throw 'must not probe a not-applicable app' }
            Mock Install-WingetPackage { throw 'must not install a not-applicable app' }

            $outcome = Install-AppWithVerification -App $readerApp

            $outcome.Status | Should -Be 'Skipped'
            $outcome.SkipReason | Should -Be 'NotApplicable'
        }

        It 'Fails open when the architecture cannot be read: both Readers apply, with a warning each' {
            $readerApps = @(Get-DefaultAppCatalog | Where-Object { $_.name -like 'Adobe.Acrobat.Reader.*' })
            Mock Get-OSArchitecture { throw 'The OS architecture could not be read.' }

            foreach ($readerApp in $readerApps) {
                Test-AppApplicability -App $readerApp | Should -Be $true
            }
            @($script:warnings).Count | Should -Be 2
        }
    }

    # winget's only Google Drive installer is labelled x64, but Google's update server sends ARM64
    # PCs the same file and Drive runs natively on Windows 11 ARM64, so it is not gated off ARM64.
    Context 'Google Drive on ARM64' {
        It 'Applies on <Architecture> without a warning' -ForEach @(
            @{ Architecture = 'X64' }
            @{ Architecture = 'Arm64' }
        ) {
            $driveApp = @(Get-DefaultAppCatalog) | Where-Object { $_.name -eq 'Google.GoogleDrive' }
            $script:mockedArchitecture = $Architecture
            Mock Get-OSArchitecture { $script:mockedArchitecture }
            Mock Write-WarningMessage { }

            @($driveApp).Count | Should -Be 1
            Test-AppApplicability -App $driveApp | Should -Be $true
            Should -Invoke Write-WarningMessage -Times 0 -Exactly
        }
    }

    # wgt-gq8.61: `winget uninstall` ran Drive's bare uninstall.exe, which asked for a confirmation
    # nobody could give until the 15-minute limit stopped it.
    Context 'Google Drive removal' {
        It 'Removes Google Drive with its own uninstaller and Google''s silent switches' {
            $driveApp = @(Get-DefaultAppCatalog) | Where-Object { $_.name -eq 'Google.GoogleDrive' }

            $driveApp.quietUninstall.productCode | Should -Be '{6BBAE539-2232-434A-A4E5-9A33560C6283}'
            @($driveApp.quietUninstall.arguments) | Should -Be @('--silent', '--force_stop')
        }

        It 'No catalog entry other than the reviewed ones carries quietUninstall' {
            $quiet = @(Get-DefaultAppCatalog) | Where-Object { $_.ContainsKey('quietUninstall') }

            @($quiet | ForEach-Object { $_.name }) | Should -Be @('Google.GoogleDrive')
        }
    }

    # winget has only Dell's x64 build of Dell Command Update; on ARM64 it would install that with
    # the Arm64 .NET Desktop Runtime its dependency resolves to. Dell ships its ARM64 build apart.
    Context 'Architecture gating for Dell Command Update' {
        BeforeEach {
            $script:warnings = @()
            Mock Write-WarningMessage { $script:warnings += $Message }
            Mock Get-ComputerManufacturer { 'Dell Inc.' }
        }

        It 'Gates Dell.CommandUpdate.Universal to x64 Windows with an arch list' {
            $dellApp = @(Get-DefaultAppCatalog) | Where-Object { $_.name -eq 'Dell.CommandUpdate.Universal' }

            @($dellApp.arch) | Should -Be @('X64')
        }

        It 'Applies on a Dell PC with <Architecture> Windows: <Expected>' -ForEach @(
            @{ Architecture = 'X64'; Expected = $true }
            @{ Architecture = 'Arm64'; Expected = $false }
            @{ Architecture = 'X86'; Expected = $false }
        ) {
            $dellApp = @(Get-DefaultAppCatalog) | Where-Object { $_.name -eq 'Dell.CommandUpdate.Universal' }
            $script:mockedArchitecture = $Architecture
            Mock Get-OSArchitecture { $script:mockedArchitecture }

            Test-AppApplicability -App $dellApp | Should -Be $Expected
            $script:warnings | Should -BeNullOrEmpty
        }

        It 'Names both gates in the reason an ARM64 Dell PC is given' {
            $dellApp = @(Get-DefaultAppCatalog) | Where-Object { $_.name -eq 'Dell.CommandUpdate.Universal' }
            Mock Get-OSArchitecture { 'Arm64' }

            $reason = Get-AppNotApplicableReason -App $dellApp

            $reason | Should -Match 'Dell hardware'
            $reason | Should -Match 'x64 Windows only'
            $reason | Should -Match 'ARM64'
        }

        It 'Skips it on an ARM64 Dell PC without asking for the manufacturer or calling winget' {
            $dellApp = @(Get-DefaultAppCatalog) | Where-Object { $_.name -eq 'Dell.CommandUpdate.Universal' }
            Mock Get-OSArchitecture { 'Arm64' }
            Mock Test-WingetPackageInstalled { throw 'must not probe a not-applicable app' }
            Mock Install-WingetPackage { throw 'must not install a not-applicable app' }

            $outcome = Install-AppWithVerification -App $dellApp

            $outcome.Status | Should -Be 'Skipped'
            $outcome.SkipReason | Should -Be 'NotApplicable'
            Should -Invoke Get-ComputerManufacturer -Times 0 -Exactly
        }
    }

    Context 'Deliberate catalog gating (issues #217, #271; review finding P3-32)' {
        It 'No catalog entry other than the reviewed exceptions carries a condition' {
            $conditioned = @(Get-DefaultAppCatalog) | Where-Object { $_.ContainsKey('condition') }

            @($conditioned | ForEach-Object { $_.name }) | Should -Be @('Dell.CommandUpdate.Universal', 'Microsoft.WindowsTerminal')
        }

        It 'No catalog entry other than the reviewed exceptions carries an arch list, and each says why' {
            $gated = @(Get-DefaultAppCatalog) | Where-Object { $_.ContainsKey('arch') }

            @($gated | ForEach-Object { $_.name }) | Should -Be @('Adobe.Acrobat.Reader.64-bit', 'Adobe.Acrobat.Reader.32-bit', 'Dell.CommandUpdate.Universal')
            foreach ($app in $gated) {
                $app.conditionDescription | Should -Not -BeNullOrEmpty -Because "$($app.name)'s skip line should say why it does not apply"
            }
        }
    }
}
