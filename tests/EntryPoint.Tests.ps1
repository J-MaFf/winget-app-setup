# EntryPoint.Tests.ps1
# Tests for the distribution surface around the module: the generated winget-app-install.ps1
# entry script (head/tail fragments, build stamp, transcript wiring, switch forwarding, IEX
# behavior), build determinism, and the psd1 module export surface.
# Split from the old single-file suite Test-WingetAppInstall.Tests.ps1 (issue #192).

# Load the module's functions once for this file. TestHelpers.ps1 resolves the repo paths
# and dot-sources WingetAppSetup/Private + Public (the single source of truth; the
# distributable winget-app-install.ps1 is generated from it by build/Build-WingetInstallScript.ps1).
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'Module export surface (issue #191)' {
    # The psd1 FunctionsToExport list is the single export authority; the psm1 reads it and the
    # build asserts it matches Public/*.ps1. These tests pin the reconciled surface.
    It 'No longer defines the dead ConvertTo-CommandArguments helper' {
        # Remnant of the removed homegrown updater; it had no production callers.
        Test-Path Function:\ConvertTo-CommandArguments | Should -Be $false
    }

    It 'No longer exports module-internal helpers moved to Private/' {
        $manifest = Import-PowerShellDataFile $script:ModuleManifestPath
        $manifest.FunctionsToExport | Should -Not -Contain 'Write-Prompt'
        $manifest.FunctionsToExport | Should -Not -Contain 'ConvertFrom-TerminalSettingsJson'
    }

    It 'Still exports the logging helpers consumed by winget-app-uninstall.ps1' {
        $manifest = Import-PowerShellDataFile $script:ModuleManifestPath
        foreach ($helper in @('Write-Info', 'Write-Success', 'Write-WarningMessage', 'Write-ErrorMessage', 'Format-AppList', 'Write-Table')) {
            $manifest.FunctionsToExport | Should -Contain $helper
        }
    }

    It 'FunctionsToExport exactly matches the functions defined under Public/*.ps1' {
        # Cross-platform mirror of the Build-WingetInstallScript.ps1 export assertion.
        $manifest = Import-PowerShellDataFile $script:ModuleManifestPath
        $publicFunctionNames = Get-ChildItem -Path (Join-Path $script:WingetAppSetupRoot 'Public') -Filter '*.ps1' | ForEach-Object {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$null)
            $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) |
                ForEach-Object { $_.Name }
        }
        ($manifest.FunctionsToExport | Sort-Object) | Should -Be ($publicFunctionNames | Sort-Object)
    }
}

Describe 'SkipSystemCheck elevation forwarding (issue #185)' {
    Context 'Invoke-WingetInstall parameter surface' {
        It 'Should accept a SkipSystemCheck switch parameter' {
            $command = Get-Command Invoke-WingetInstall
            $command.Parameters.ContainsKey('SkipSystemCheck') | Should -Be $true
            $command.Parameters['SkipSystemCheck'].ParameterType.Name | Should -Be 'SwitchParameter'
        }
    }

    Context 'Generated installer entry point' {
        It 'Should forward -SkipSystemCheck from the entry script into Invoke-WingetInstall' {
            $installer = Get-Content $script:InstallerScriptPath -Raw
            $installer | Should -Match 'Invoke-WingetInstall -WhatIf:\$WhatIf -NonInteractive:\$NonInteractive -SkipSystemCheck:\$SkipSystemCheck'
        }
    }
}

Describe 'Generated installer: build stamp and transcript wiring (issue #189)' {
    BeforeAll {
        $script:generatedInstaller = Get-Content -Raw -Encoding UTF8 -Path $script:InstallerScriptPath
    }

    It 'Stamps a content-derived $script:InstallerBuildId matching the module version' {
        $moduleVersion = (Import-PowerShellDataFile -Path (Join-Path $script:WingetAppSetupRoot 'WingetAppSetup.psd1')).ModuleVersion
        $expectedPattern = [regex]::Escape("`$script:InstallerBuildId = '$moduleVersion+") + '[0-9a-f]{8}'''

        $script:generatedInstaller | Should -Match $expectedPattern
    }

    It 'Wraps the dispatch in a transcript under ProgramData that never blocks the install' {
        $script:generatedInstaller | Should -Match 'Start-Transcript'
        $script:generatedInstaller | Should -Match 'Stop-Transcript'
        $script:generatedInstaller | Should -Match ([regex]::Escape("Join-Path `$env:ProgramData 'winget-app-setup\logs'"))
        $script:generatedInstaller | Should -Match ([regex]::Escape("'install-{0:yyyyMMdd-HHmmss}{1}.log'"))
        # Dry runs get a distinguishing suffix; transcript failures downgrade to a warning.
        $script:generatedInstaller | Should -Match ([regex]::Escape("if (`$WhatIf) { '-whatif' } else { '' }"))
        $script:generatedInstaller | Should -Match 'Transcript logging could not be started'
    }

    It 'Logs the log path and the build id at startup' {
        $script:generatedInstaller | Should -Match ([regex]::Escape('Write-Info "Logging this run to: $script:InstallLogPath"'))
        $script:generatedInstaller | Should -Match ([regex]::Escape('Write-Info "Installer build: $script:InstallerBuildId"'))
    }
}

Describe 'Build determinism (issue #189)' {
    BeforeAll {
        $script:buildScriptPath = Join-Path $script:RepoRoot 'build/Build-WingetInstallScript.ps1'
        $script:currentPowerShell = (Get-Process -Id $PID).Path
    }

    It 'Produces byte-identical output when the same tree is built twice' {
        # The build id must derive from CONTENT only (module version + functions hash) — anything
        # time- or git-based would make every rebuild differ and permanently break the CI -Check
        # byte-compare. Verified the way CI would notice: build twice, compare bytes.
        $firstOutput = Join-Path $TestDrive 'installer-build-one.ps1'
        $secondOutput = Join-Path $TestDrive 'installer-build-two.ps1'

        & $script:currentPowerShell -NoProfile -File $script:buildScriptPath -OutputPath $firstOutput | Out-Null
        $LASTEXITCODE | Should -Be 0
        & $script:currentPowerShell -NoProfile -File $script:buildScriptPath -OutputPath $secondOutput | Out-Null
        $LASTEXITCODE | Should -Be 0

        (Get-FileHash -Path $firstOutput -Algorithm SHA256).Hash |
            Should -Be (Get-FileHash -Path $secondOutput -Algorithm SHA256).Hash
    }
}

Describe 'IEX non-admin execution behavior' {
    BeforeAll {
        $script:isWindowsPlatform = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
        $script:isElevated = $false

        if ($script:isWindowsPlatform) {
            $script:isElevated = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
                [Security.Principal.WindowsBuiltInRole]::Administrator
            )
        }
    }

    It 'Should exit with code 1 and show remote elevation guidance' -Skip:(-not $script:isWindowsPlatform -or $script:isElevated) {

        $scriptPath = $script:InstallerScriptPath
        $psStringEscapedPath = $scriptPath.Replace("'", "''")
        $currentPowerShell = (Get-Process -Id $PID).Path
        $childCommand = @"
Get-Content -Raw -LiteralPath '$psStringEscapedPath' | Invoke-Expression
"@

        $output = & $currentPowerShell -NoLogo -NoProfile -NonInteractive -Command $childCommand 2>&1 | Out-String
        $exitCode = $LASTEXITCODE

        $exitCode | Should -Be 1
        $output | Should -Match 'This script requires administrator privileges\.'
        $output | Should -Match 'Auto-elevation is unavailable when running through IEX/remote execution\.'
        $output | Should -Match 'Open an elevated PowerShell or Windows Terminal session and run the IEX command again\.'
        $output | Should -Match 'Exiting in 5 seconds\.\.\.'
        $output | Should -Not -Match 'Press Enter to restart script with elevated privileges'
    }
}
