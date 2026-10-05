# AppCatalog.Tests.ps1
# Tests for WingetAppSetup/Public/AppCatalog.ps1: the curated Get-DefaultAppCatalog list
# and its consistent consumption by the generated installer and the uninstaller.
# Split from the old single-file suite Test-WingetAppInstall.Tests.ps1 (issue #192).

# Load the module's functions once for this file. TestHelpers.ps1 resolves the repo paths
# and dot-sources WingetAppSetup/Private + Public (the single source of truth; the
# distributable winget-app-install.ps1 is generated from it by build/Build-WingetInstallScript.ps1).
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'App list consistency (issue #190)' {
    # The old form of this test parsed the duplicated inline lists in winget-app-install.ps1 and
    # winget-app-uninstall.ps1 and compared them. Both scripts now consume Get-DefaultAppCatalog,
    # so sync is structural; what remains worth guarding is (a) the generated installer actually
    # carries the module's catalog and (b) the uninstaller never regrows an inline copy.
    It 'Ships the module catalog inside the generated installer' {
        $installApps = Get-Content $script:InstallerScriptPath |
        ForEach-Object {
            if ($_ -match "@{name = '([^']+)'") { $matches[1] }
        } |
        Where-Object { $_ }

        $catalogNames = @(Get-DefaultAppCatalog) | ForEach-Object { $_.name }
        $installApps | Should -Be $catalogNames
    }

    It 'Uninstaller removes the Get-DefaultAppCatalog apps instead of an inline copy of the list' {
        # The script runs Invoke-WingetUninstall (review findings P2-19, P3-18), whose -Apps defaults
        # to the module catalog, as Invoke-WingetInstall's does.
        $uninstallScript = Get-Content $script:UninstallerScriptPath -Raw
        $uninstallScript | Should -Match '(?m)Invoke-WingetUninstall -WhatIf:\$WhatIf\s*$'
        $appsParameter = ${function:Invoke-WingetUninstall}.Ast.Body.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Apps' }
        $appsParameter.DefaultValue.Extent.Text | Should -Be '(Get-DefaultAppCatalog)'
        # The previously duplicated inline list (which had already drifted in metadata) is gone.
        $uninstallScript | Should -Not -Match "@\{name = '"
    }

    It 'Uninstaller reuses the module installed-check, process and elevation helpers (issue #190)' {
        $uninstallScript = Get-Content $script:UninstallerScriptPath -Raw
        # Relaunched in place: the uninstaller imports the module from its own folder (its relaunch
        # is tested in Elevation.Tests.ps1 and Uninstall.Tests.ps1).
        $uninstallScript | Should -Match 'Restart-WithElevation -ScriptPath \$PSCommandPath -InPlace'
        $uninstallScript | Should -Not -Match 'Start-Process powershell\.exe'
        $appStep = ${function:Uninstall-CatalogApp}.ToString()
        $appStep | Should -Match 'Test-WingetPackageInstalled -PackageId'
        $appStep | Should -Match 'Invoke-WingetProcess -ArgumentList'
        # No bare winget call anywhere on the uninstall path (review finding P3-18): it had no time
        # limit and its output never reached the log.
        foreach ($ast in @([System.Management.Automation.Language.Parser]::ParseFile($script:UninstallerScriptPath, [ref]$null, [ref]$null), ${function:Invoke-WingetUninstall}.Ast, ${function:Uninstall-CatalogApp}.Ast)) {
            $bareWinget = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'winget' }, $true)
            @($bareWinget).Count | Should -Be 0
        }
    }

    It 'Gets every module function the uninstaller calls from its manifest import' {
        # winget-app-uninstall.ps1 imports the module via the psd1, so a function the import does
        # not export fails at the user's prompt while dot-sourcing tests stay green (#191).
        $exported = @(Get-ManifestExportedFunctionName)
        $scriptAst = [System.Management.Automation.Language.Parser]::ParseFile($script:UninstallerScriptPath, [ref]$null, [ref]$null)
        $calledFunctions = @($scriptAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) |
                ForEach-Object { $_.GetCommandName() } |
                Where-Object { $_ -and (Get-Command -Name $_ -CommandType Function -ErrorAction SilentlyContinue) } |
                Sort-Object -Unique)
        $calledFunctions | Should -Contain 'Invoke-WingetUninstall'
        $calledFunctions | Should -Contain 'Restart-WithElevation'
        foreach ($helper in $calledFunctions) {
            $exported | Should -Contain $helper
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
        It 'Gates Dell.CommandUpdate.Universal behind a condition with a human-readable description' {
            $dellApp = @(Get-DefaultAppCatalog) | Where-Object { $_.name -eq 'Dell.CommandUpdate.Universal' }

            @($dellApp).Count | Should -Be 1
            $dellApp.condition | Should -BeOfType [scriptblock]
            $dellApp.conditionDescription | Should -Be 'Dell hardware only'
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
        It 'Gates Adobe.Acrobat.Reader.64-bit behind a condition whose description names ARM64' {
            $readerApp = @(Get-DefaultAppCatalog) | Where-Object { $_.name -eq 'Adobe.Acrobat.Reader.64-bit' }

            @($readerApp).Count | Should -Be 1
            $readerApp.condition | Should -BeOfType [scriptblock]
            $readerApp.conditionDescription | Should -Match 'ARM64'
        }

        It 'Condition is false on ARM64 and true on x64 and x86' {
            $readerApp = @(Get-DefaultAppCatalog) | Where-Object { $_.name -eq 'Adobe.Acrobat.Reader.64-bit' }

            Mock Get-OSArchitecture { 'Arm64' }
            [bool](& $readerApp.condition) | Should -Be $false

            Mock Get-OSArchitecture { 'X64' }
            [bool](& $readerApp.condition) | Should -Be $true

            Mock Get-OSArchitecture { 'X86' }
            [bool](& $readerApp.condition) | Should -Be $true
        }

        It 'Reports Reader as not applicable on ARM64 without any winget probe or install' {
            $readerApp = @(Get-DefaultAppCatalog) | Where-Object { $_.name -eq 'Adobe.Acrobat.Reader.64-bit' }
            Mock Get-OSArchitecture { 'Arm64' }
            Mock Test-WingetPackageInstalled { throw 'must not probe a not-applicable app' }
            Mock Install-WingetPackage { throw 'must not install a not-applicable app' }

            $outcome = Install-AppWithVerification -App $readerApp

            $outcome.Status | Should -Be 'Skipped'
            $outcome.SkipReason | Should -Be 'NotApplicable'
        }

        It 'Fails open when the architecture cannot be read: the app applies' {
            $readerApp = @(Get-DefaultAppCatalog) | Where-Object { $_.name -eq 'Adobe.Acrobat.Reader.64-bit' }
            Mock Write-WarningMessage { }
            Mock Get-OSArchitecture { throw 'The OS architecture could not be read.' }

            Test-AppApplicability -App $readerApp | Should -Be $true
        }

        # Gating the 64-bit Reader alone left ARM64 PCs with no PDF reader at all.
        It 'Gates Adobe.Acrobat.Reader.32-bit behind a condition whose description names ARM64' {
            $readerApp = @(Get-DefaultAppCatalog) | Where-Object { $_.name -eq 'Adobe.Acrobat.Reader.32-bit' }

            @($readerApp).Count | Should -Be 1
            $readerApp.condition | Should -BeOfType [scriptblock]
            $readerApp.conditionDescription | Should -Match 'ARM64'
        }

        It 'Offers exactly one Reader on <Architecture>: <Expected>' -ForEach @(
            @{ Architecture = 'Arm64'; Expected = 'Adobe.Acrobat.Reader.32-bit' }
            @{ Architecture = 'X64'; Expected = 'Adobe.Acrobat.Reader.64-bit' }
            @{ Architecture = 'X86'; Expected = 'Adobe.Acrobat.Reader.64-bit' }
        ) {
            $readerApps = @(Get-DefaultAppCatalog | Where-Object { $_.name -like 'Adobe.Acrobat.Reader.*' })
            $script:mockedArchitecture = $Architecture
            Mock Get-OSArchitecture { $script:mockedArchitecture }
            Mock Write-WarningMessage { }

            $applicable = @($readerApps | Where-Object { Test-AppApplicability -App $_ } | ForEach-Object { $_.name })

            $applicable | Should -Be @($Expected)
            Should -Invoke Write-WarningMessage -Times 0 -Exactly
        }

        It 'Reports the 32-bit Reader as not applicable on x64 without any winget probe or install' {
            $readerApp = @(Get-DefaultAppCatalog) | Where-Object { $_.name -eq 'Adobe.Acrobat.Reader.32-bit' }
            Mock Get-OSArchitecture { 'X64' }
            Mock Test-WingetPackageInstalled { throw 'must not probe a not-applicable app' }
            Mock Install-WingetPackage { throw 'must not install a not-applicable app' }

            $outcome = Install-AppWithVerification -App $readerApp

            $outcome.Status | Should -Be 'Skipped'
            $outcome.SkipReason | Should -Be 'NotApplicable'
        }
    }

    Context 'Deliberate catalog gating (issues #217, #271; review finding P3-32)' {
        It 'No catalog entry other than the reviewed exceptions carries a condition' {
            $conditioned = @(Get-DefaultAppCatalog) | Where-Object { $_.ContainsKey('condition') }

            @($conditioned | ForEach-Object { $_.name }) | Should -Be @('Adobe.Acrobat.Reader.64-bit', 'Adobe.Acrobat.Reader.32-bit', 'Dell.CommandUpdate.Universal', 'Microsoft.WindowsTerminal')
        }
    }
}
