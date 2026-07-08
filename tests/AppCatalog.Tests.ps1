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

    It 'Uninstaller iterates Get-DefaultAppCatalog instead of an inline copy of the list' {
        $uninstallScript = Get-Content $script:UninstallerScriptPath -Raw
        $uninstallScript | Should -Match '\$apps = Get-DefaultAppCatalog'
        # The previously duplicated inline list (which had already drifted in metadata) is gone.
        $uninstallScript | Should -Not -Match "@\{name = '"
    }

    It 'Uninstaller reuses the module installed-check and elevation helpers (issue #190)' {
        $uninstallScript = Get-Content $script:UninstallerScriptPath -Raw
        $uninstallScript | Should -Match 'Test-WingetPackageInstalled -PackageId'
        $uninstallScript | Should -Match 'Restart-WithElevation -PowerShellExecutable'
        # The hand-rolled winget list probe and Start-Process relaunch are gone.
        $uninstallScript | Should -Not -Match 'winget list --exact'
        $uninstallScript | Should -Not -Match 'Start-Process powershell\.exe'
    }

    It 'Exports everything the uninstaller calls from the manifest (psd1 gates module imports)' {
        # winget-app-uninstall.ps1 imports the module via the psd1, so a helper missing from
        # FunctionsToExport fails at the user's prompt while dot-sourcing tests stay green (#191).
        $manifest = Import-PowerShellDataFile $script:ModuleManifestPath
        foreach ($helper in @('Get-DefaultAppCatalog', 'Test-WingetPackageInstalled', 'Restart-WithElevation')) {
            $manifest.FunctionsToExport | Should -Contain $helper
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
            $app.name | Should -Match '^[\w][\w.\-]+\.[\w][\w.\-]+'
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

        It 'No other catalog entry carries a condition (gating stays deliberate and reviewed)' {
            $conditioned = @(Get-DefaultAppCatalog) | Where-Object { $_.ContainsKey('condition') }

            @($conditioned | ForEach-Object { $_.name }) | Should -Be @('Dell.CommandUpdate.Universal')
        }
    }
}
