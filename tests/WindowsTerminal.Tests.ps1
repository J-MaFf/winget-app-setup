# WindowsTerminal.Tests.ps1
# Tests for WingetAppSetup/Public/WindowsTerminal.ps1 and Private/Jsonc.ps1: default
# profile configuration, JSONC sanitizing, registry defaults, and orchestration.
# Split from the old single-file suite Test-WingetAppInstall.Tests.ps1 (issue #192).

# Load the module's functions once for this file. TestHelpers.ps1 resolves the repo paths
# and dot-sources WingetAppSetup/Private + Public (the single source of truth; the
# distributable winget-app-install.ps1 is generated from it by build/Build-WingetInstallScript.ps1).
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'Windows Terminal configuration' {
    BeforeAll {
    }

    Context 'Set-WindowsTerminalDefaultProfile' {
        It 'Should set defaultProfile in settings.json' {
            $settingsPath = Join-Path $TestDrive 'settings.json'
            Set-Content -Path $settingsPath -Value '{"profiles":{"list":[]}}' -Encoding UTF8

            $result = Set-WindowsTerminalDefaultProfile -SettingsPath $settingsPath -ProfileGuid '{574e775e-4f2a-5b96-ac1e-a2962a402336}'
            $updated = Get-Content -Path $settingsPath -Raw | ConvertFrom-Json

            $result | Should -Be $true
            $updated.defaultProfile | Should -Be '{574e775e-4f2a-5b96-ac1e-a2962a402336}'
        }

        It 'Should parse JSONC style settings with comments and trailing commas' {
            $settingsPath = Join-Path $TestDrive 'settings-jsonc.json'
            $jsonc = @'
{
  // sample comment
  "profiles": {
    "list": [
    ],
  },
}
'@
            Set-Content -Path $settingsPath -Value $jsonc -Encoding UTF8

            $result = Set-WindowsTerminalDefaultProfile -SettingsPath $settingsPath -ProfileGuid '574e775e-4f2a-5b96-ac1e-a2962a402336'
            $updated = Get-Content -Path $settingsPath -Raw | ConvertFrom-Json

            $result | Should -Be $true
            $updated.defaultProfile | Should -Be '{574e775e-4f2a-5b96-ac1e-a2962a402336}'
        }

        It 'Should return false when settings path does not exist' {
            $missingPath = Join-Path $TestDrive 'missing-settings.json'

            $result = Set-WindowsTerminalDefaultProfile -SettingsPath $missingPath -ProfileGuid '{574e775e-4f2a-5b96-ac1e-a2962a402336}'

            $result | Should -Be $false
        }
    }

    Context 'Convert-JsoncToJson sanitizer' {
        It 'Should strip a trailing inline comment after a value' {
            $jsonc = @'
{
  "copyOnSelect": true, // keep this setting
  "defaultProfile": "{574e775e-4f2a-5b96-ac1e-a2962a402336}"
}
'@
            $sanitized = Convert-JsoncToJson -JsonText $jsonc

            $sanitized | Should -Not -Match 'keep this setting'
            $parsed = $sanitized | ConvertFrom-Json
            $parsed.copyOnSelect | Should -BeTrue
            $parsed.defaultProfile | Should -Be '{574e775e-4f2a-5b96-ac1e-a2962a402336}'
        }

        It 'Should preserve comment-like sequences inside string values' {
            $jsonc = @'
{
  "commandline": "cmd /* not a comment */ //still-not",
  "url": "https://example.com/path"
}
'@
            $parsed = Convert-JsoncToJson -JsonText $jsonc | ConvertFrom-Json

            $parsed.commandline | Should -Be 'cmd /* not a comment */ //still-not'
            $parsed.url | Should -Be 'https://example.com/path'
        }

        It 'Should honor escaped quotes so \" does not end the string' {
            $jsonc = @'
{
  "name": "quoted \" // not a comment",
  "next": 1 // real comment
}
'@
            $sanitized = Convert-JsoncToJson -JsonText $jsonc

            $sanitized | Should -Not -Match 'real comment'
            $parsed = $sanitized | ConvertFrom-Json
            $parsed.name | Should -Be 'quoted " // not a comment'
            $parsed.next | Should -Be 1
        }

        It 'Should strip full-line comments' {
            $jsonc = @'
{
  // full-line comment
  "a": 1
}
'@
            $sanitized = Convert-JsoncToJson -JsonText $jsonc

            $sanitized | Should -Not -Match 'full-line comment'
            ($sanitized | ConvertFrom-Json).a | Should -Be 1
        }

        It 'Should strip block comments spanning multiple lines' {
            $jsonc = @'
{
  /* block comment
     spanning lines */
  "a": 1,
  "b": /* inline block */ 2
}
'@
            $sanitized = Convert-JsoncToJson -JsonText $jsonc

            $sanitized | Should -Not -Match 'block comment'
            $parsed = $sanitized | ConvertFrom-Json
            $parsed.a | Should -Be 1
            $parsed.b | Should -Be 2
        }

        It 'Should remove trailing commas, including one separated from the closer by a comment' {
            $jsonc = @'
{
  "list": [1, 2, /* trailing */ ],
  "a": 1,
}
'@
            $parsed = Convert-JsoncToJson -JsonText $jsonc | ConvertFrom-Json

            $parsed.list.Count | Should -Be 2
            $parsed.a | Should -Be 1
        }

        It 'Should not treat comma-plus-closer content inside strings as a trailing comma' {
            $jsonc = @'
{
  "text": "a, ]"
}
'@
            (Convert-JsoncToJson -JsonText $jsonc | ConvertFrom-Json).text | Should -Be 'a, ]'
        }

        It 'Should parse settings with a trailing inline comment end-to-end' {
            $jsonc = @'
{
  "copyOnSelect": true, // keep
  "profiles": { "list": [] }
}
'@
            $parsed = ConvertFrom-TerminalSettingsJson -JsonText $jsonc

            $parsed | Should -Not -BeNullOrEmpty
            $parsed.copyOnSelect | Should -BeTrue
        }
    }

    Context 'Set-WindowsTerminalAsDefaultTerminalApplication' {
        It 'Should create/update registry values when not already configured' {
            Mock Test-Path { return $false } -ParameterFilter { $Path -eq 'HKCU:\Console\%%Startup' }
            Mock New-Item { }
            Mock Get-ItemProperty { return [pscustomobject]@{} }
            Mock New-ItemProperty { }

            $result = Set-WindowsTerminalAsDefaultTerminalApplication

            $result | Should -Be $true
            Assert-MockCalled New-Item -Times 1 -ParameterFilter { $Path -eq 'HKCU:\Console\%%Startup' -and $Force }
            Assert-MockCalled New-ItemProperty -Times 2
        }

        It 'Should skip writes when registry is already configured' {
            Mock Test-Path { return $true } -ParameterFilter { $Path -eq 'HKCU:\Console\%%Startup' }
            Mock Get-ItemProperty {
                [pscustomobject]@{
                    DelegationConsole  = '{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}'
                    DelegationTerminal = '{E12CFF52-A866-4C77-9A90-F570A7AA2C6B}'
                }
            }
            Mock New-ItemProperty { }

            $result = Set-WindowsTerminalAsDefaultTerminalApplication

            $result | Should -Be $true
            Assert-MockCalled New-ItemProperty -Times 0
        }

        It 'Should return false when registry write fails' {
            Mock Test-Path { return $true } -ParameterFilter { $Path -eq 'HKCU:\Console\%%Startup' }
            Mock Get-ItemProperty { return [pscustomobject]@{} }
            Mock New-ItemProperty { throw 'Registry denied' }

            $result = Set-WindowsTerminalAsDefaultTerminalApplication

            $result | Should -Be $false
        }
    }

    Context 'Set-WindowsTerminalDefaults orchestration' {
        BeforeEach {
            # Deterministic same-user elevation state by default; cross-user tests override.
            Mock Get-ProcessUserName { 'CONTOSO\jdoe' }
            Mock Get-InteractiveSessionUserName { 'CONTOSO\jdoe' }
            Mock Write-WarningMessage { }
        }

        It 'Should perform no writes in WhatIf mode' {
            Mock Get-WindowsTerminalSettingsPaths { return @('C:\temp\settings.json') }
            Mock Set-WindowsTerminalDefaultProfile { return $true }
            Mock Set-WindowsTerminalAsDefaultTerminalApplication { return $true }
            Mock Write-Info { }

            Set-WindowsTerminalDefaults -WhatIf

            Assert-MockCalled Set-WindowsTerminalDefaultProfile -Times 0
            Assert-MockCalled Set-WindowsTerminalAsDefaultTerminalApplication -Times 0
            Assert-MockCalled Write-Info -Times 2
        }

        It 'Should configure both settings file and registry in normal mode' {
            Mock Get-WindowsTerminalSettingsPaths { return @('C:\temp\settings.json') }
            Mock Set-WindowsTerminalDefaultProfile { return $true }
            Mock Set-WindowsTerminalAsDefaultTerminalApplication { return $true }

            Set-WindowsTerminalDefaults

            Assert-MockCalled Set-WindowsTerminalDefaultProfile -Times 1
            Assert-MockCalled Set-WindowsTerminalAsDefaultTerminalApplication -Times 1
        }

        It 'Should configure all discovered settings files in normal mode' {
            Mock Get-WindowsTerminalSettingsPaths { return @('C:\temp\stable-settings.json', 'C:\temp\preview-settings.json') }
            Mock Set-WindowsTerminalDefaultProfile { return $true }
            Mock Set-WindowsTerminalAsDefaultTerminalApplication { return $true }

            Set-WindowsTerminalDefaults

            Assert-MockCalled Set-WindowsTerminalDefaultProfile -Times 2
            Assert-MockCalled Set-WindowsTerminalAsDefaultTerminalApplication -Times 1
        }

        It 'Should not emit the cross-user warning when process and session users match' {
            Mock Get-WindowsTerminalSettingsPaths { return @('C:\temp\settings.json') }
            Mock Set-WindowsTerminalDefaultProfile { return $true }
            Mock Set-WindowsTerminalAsDefaultTerminalApplication { return $true }

            Set-WindowsTerminalDefaults

            Assert-MockCalled Write-WarningMessage -Times 0 -ParameterFilter { $Message -match 'CROSS-USER ELEVATION' }
        }

        It 'Should warn loudly and still apply per-user config when cross-user elevation is detected' {
            Mock Get-WindowsTerminalSettingsPaths { return @('C:\temp\settings.json') }
            Mock Set-WindowsTerminalDefaultProfile { return $true }
            Mock Set-WindowsTerminalAsDefaultTerminalApplication { return $true }
            Mock Get-ProcessUserName { 'CONTOSO\admin-tech' }
            Mock Get-InteractiveSessionUserName { 'CONTOSO\jdoe' }

            Set-WindowsTerminalDefaults

            Assert-MockCalled Write-WarningMessage -ParameterFilter { $Message -match 'CROSS-USER ELEVATION' }
            Assert-MockCalled Write-WarningMessage -ParameterFilter { $Message -match "NOT to 'CONTOSO\\jdoe'" }
            Assert-MockCalled Write-WarningMessage -ParameterFilter { $Message -match "applied to 'CONTOSO\\admin-tech' only" }
            # Honest reporting only: the per-user writes still target the process account.
            Assert-MockCalled Set-WindowsTerminalDefaultProfile -Times 1
            Assert-MockCalled Set-WindowsTerminalAsDefaultTerminalApplication -Times 1
        }

        It 'Should warn about cross-user elevation in WhatIf mode without the applied-to caveat' {
            Mock Get-WindowsTerminalSettingsPaths { return @('C:\temp\settings.json') }
            Mock Set-WindowsTerminalDefaultProfile { return $true }
            Mock Set-WindowsTerminalAsDefaultTerminalApplication { return $true }
            Mock Write-Info { }
            Mock Get-ProcessUserName { 'CONTOSO\admin-tech' }
            Mock Get-InteractiveSessionUserName { 'CONTOSO\jdoe' }

            Set-WindowsTerminalDefaults -WhatIf

            Assert-MockCalled Write-WarningMessage -ParameterFilter { $Message -match 'CROSS-USER ELEVATION' }
            Assert-MockCalled Write-WarningMessage -Times 0 -ParameterFilter { $Message -match 'remains unconfigured' }
            Assert-MockCalled Set-WindowsTerminalDefaultProfile -Times 0
        }

        It 'Should not emit the cross-user warning when the interactive user is unknown' {
            Mock Get-WindowsTerminalSettingsPaths { return @('C:\temp\settings.json') }
            Mock Set-WindowsTerminalDefaultProfile { return $true }
            Mock Set-WindowsTerminalAsDefaultTerminalApplication { return $true }
            Mock Get-ProcessUserName { 'CONTOSO\admin-tech' }
            Mock Get-InteractiveSessionUserName { $null }

            Set-WindowsTerminalDefaults

            Assert-MockCalled Write-WarningMessage -Times 0 -ParameterFilter { $Message -match 'CROSS-USER ELEVATION' }
        }
    }
}
