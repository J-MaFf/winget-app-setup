# CatalogSchema.Tests.ps1
# Tests for WingetAppSetup/Private/CatalogSchema.ps1 (work-order item 38): the declarative catalog
# fields scope, arch, postInstall and userPhase - their validation, the helpers that read them,
# and how a post-install hook's result is read. The pipeline and orchestrator wiring is tested in
# Install.Tests.ps1, Test-AppDefinitions in AppValidation.Tests.ps1.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    # A function hook, as a catalog entry names one by string.
    function Set-ZzTestAppConfiguration {
        param ($App)
        "configured $($App.name)" | Out-Null
        'Configured'
    }
}

Describe 'Get-AppDefinitionSchemaIssue (work-order item 38)' {
    It 'Accepts every valid value: <Case>' -ForEach @(
        @{ Case = 'scope machine'; App = @{ name = 'Contoso.App'; scope = 'machine' } }
        @{ Case = 'scope user'; App = @{ name = 'Contoso.App'; scope = 'user' } }
        @{ Case = 'scope any, any case'; App = @{ name = 'Contoso.App'; scope = 'Any' } }
        @{ Case = 'one architecture as a string'; App = @{ name = 'Contoso.App'; arch = 'Arm64' } }
        @{ Case = 'a list of architectures, any case'; App = @{ name = 'Contoso.App'; arch = @('x64', 'X86', 'arm', 'ARM64') } }
        @{ Case = 'a scriptblock hook'; App = @{ name = 'Contoso.App'; postInstall = { 'Configured' } } }
        @{ Case = 'a function hook'; App = @{ name = 'Contoso.App'; postInstall = 'Set-ZzTestAppConfiguration' } }
        @{ Case = 'userPhase true'; App = @{ name = 'Contoso.App'; userPhase = $true } }
        @{ Case = 'userPhase false'; App = @{ name = 'Contoso.App'; userPhase = $false } }
        @{ Case = 'every existing field'; App = @{ name = 'Contoso.App'; install = 'Install-PowerShellLatest'; installerType = 'wix'; condition = { $true }; conditionDescription = 'x'; msixName = 'Contoso.App' } }
        @{ Case = 'a quietUninstall with switches (wgt-gq8.61)'; App = @{ name = 'Contoso.App'; quietUninstall = @{ productCode = '{6BBAE539-2232-434A-A4E5-9A33560C6283}'; arguments = @('--silent', '--force_stop') } } }
        @{ Case = 'a quietUninstall with one switch as a string, a lower-case GUID and keys in any case'; App = @{ name = 'Contoso.App'; quietUninstall = @{ ProductCode ='{6bbae539-2232-434a-a4e5-9a33560c6283}'; Arguments = '/S' } } }
    ) {
        $issues = Get-AppDefinitionSchemaIssue -App $App -Label 'App entry at index 0'

        @($issues.Errors).Count | Should -Be 0
        @($issues.Warnings).Count | Should -Be 0
    }

    It 'Rejects <Case>' -ForEach @(
        @{ Case = 'an unknown scope'; App = @{ name = 'Contoso.App'; scope = 'global' }; Pattern = "invalid 'scope' value 'global': use 'machine', 'user' or 'any'" }
        @{ Case = 'a scope that is not a string'; App = @{ name = 'Contoso.App'; scope = 1 }; Pattern = "invalid 'scope' value '1'" }
        @{ Case = 'an architecture Get-OSArchitecture never returns'; App = @{ name = 'Contoso.App'; arch = @('X64', 'amd64') }; Pattern = "invalid 'arch' value 'amd64': use one or more of X86, X64, Arm, Arm64" }
        @{ Case = 'an empty arch list'; App = @{ name = 'Contoso.App'; arch = @() }; Pattern = "empty 'arch' list" }
        @{ Case = 'a null arch'; App = @{ name = 'Contoso.App'; arch = $null }; Pattern = "empty 'arch' list" }
        @{ Case = 'a hook name that names no command'; App = @{ name = 'Contoso.App'; postInstall = 'Set-ZzNoSuchConfiguration' }; Pattern = "'postInstall' value 'Set-ZzNoSuchConfiguration' that names no command" }
        @{ Case = 'a hook name with a wildcard'; App = @{ name = 'Contoso.App'; postInstall = 'Set-ZzTestApp*' }; Pattern = "'postInstall' value 'Set-ZzTestApp\*' that names no command" }
        @{ Case = 'a hook that is neither a scriptblock nor a name'; App = @{ name = 'Contoso.App'; postInstall = 42 }; Pattern = "invalid 'postInstall' value: use a scriptblock or the name of a function" }
        @{ Case = 'an empty hook name'; App = @{ name = 'Contoso.App'; postInstall = ' ' }; Pattern = "invalid 'postInstall' value" }
        @{ Case = 'a userPhase that is not a boolean'; App = @{ name = 'Contoso.App'; userPhase = 'yes' }; Pattern = "invalid 'userPhase' value 'yes': use \`$true or \`$false" }
    ) {
        $issues = Get-AppDefinitionSchemaIssue -App $App -Label "App entry at index 2 ('Contoso.App')"

        @($issues.Errors).Count | Should -Be 1
        @($issues.Errors)[0] | Should -Match ([regex]::Escape("App entry at index 2 ('Contoso.App')"))
        @($issues.Errors)[0] | Should -Match $Pattern
    }

    # wgt-gq8.61: the uninstaller runs the program this names, so a value it cannot use stops the
    # run (exit code 3) instead of failing the app at uninstall time.
    It 'Rejects a quietUninstall with <Case>' -ForEach @(
        @{ Case = 'a string instead of a hashtable'; Value = 'uninstall.exe --silent'; Pattern = "invalid 'quietUninstall' value: use @\{ productCode" }
        @{ Case = 'no value'; Value = $null; Pattern = "invalid 'quietUninstall' value" }
        @{ Case = 'no productCode'; Value = @{ arguments = @('--silent') }; Pattern = "invalid 'quietUninstall' productCode ''" }
        @{ Case = 'a productCode without braces'; Value = @{ productCode = '6BBAE539-2232-434A-A4E5-9A33560C6283'; arguments = @('--silent') }; Pattern = "invalid 'quietUninstall' productCode '6BBAE539-2232-434A-A4E5-9A33560C6283': use the braced GUID" }
        @{ Case = 'a productCode that is a path'; Value = @{ productCode = '{6BBAE539-2232-434A-A4E5-9A33560C6283}\..\Other'; arguments = @('--silent') }; Pattern = "invalid 'quietUninstall' productCode" }
        @{ Case = 'a productCode with a trailing line break'; Value = @{ productCode = "{6BBAE539-2232-434A-A4E5-9A33560C6283}`n"; arguments = @('--silent') }; Pattern = "invalid 'quietUninstall' productCode" }
        @{ Case = 'no arguments'; Value = @{ productCode = '{6BBAE539-2232-434A-A4E5-9A33560C6283}' }; Pattern = "no 'quietUninstall' arguments" }
        @{ Case = 'an empty argument list'; Value = @{ productCode = '{6BBAE539-2232-434A-A4E5-9A33560C6283}'; arguments = @() }; Pattern = "no 'quietUninstall' arguments" }
        @{ Case = 'an argument that is not a string'; Value = @{ productCode = '{6BBAE539-2232-434A-A4E5-9A33560C6283}'; arguments = @('--silent', 5) }; Pattern = "invalid 'quietUninstall' argument '5'" }
        @{ Case = 'an empty argument'; Value = @{ productCode = '{6BBAE539-2232-434A-A4E5-9A33560C6283}'; arguments = @('--silent', ' ') }; Pattern = "invalid 'quietUninstall' argument ' '" }
        @{ Case = 'an argument with a double quote'; Value = @{ productCode = '{6BBAE539-2232-434A-A4E5-9A33560C6283}'; arguments = @('--log="C:\x"') }; Pattern = "invalid 'quietUninstall' argument '--log=`"C:\\x`"': use a non-empty string without a double quote or a line break" }
        @{ Case = 'an unknown key'; Value = @{ productCode = '{6BBAE539-2232-434A-A4E5-9A33560C6283}'; arguments = @('--silent'); timeout = 60 }; Pattern = "unknown key 'timeout' in its 'quietUninstall' value" }
    ) {
        $issues = Get-AppDefinitionSchemaIssue -App @{ name = 'Contoso.App'; quietUninstall = $Value } -Label "App entry at index 2 ('Contoso.App')"

        @($issues.Errors).Count | Should -Be 1
        @($issues.Errors)[0] | Should -Match ([regex]::Escape("App entry at index 2 ('Contoso.App')"))
        @($issues.Errors)[0] | Should -Match $Pattern
        @($issues.Warnings).Count | Should -Be 0
    }

    It 'Warns about a field it does not know, without an error' {
        $issues = Get-AppDefinitionSchemaIssue -App @{ name = 'Contoso.App'; postInstal = { 'Configured' } } -Label 'App entry at index 0'

        @($issues.Errors).Count | Should -Be 0
        @($issues.Warnings).Count | Should -Be 1
        @($issues.Warnings)[0] | Should -Match "unknown field 'postInstal', which the installer ignores"
    }
}

Describe 'Get-AppInstallScope and Get-AppPerUserDeferReason (work-order item 38)' {
    It 'Reads <Scope> as <Expected>' -ForEach @(
        @{ Scope = $null; Expected = 'any' }
        @{ Scope = ''; Expected = 'any' }
        @{ Scope = 'Machine'; Expected = 'machine' }
        @{ Scope = 'USER'; Expected = 'user' }
        @{ Scope = 'any'; Expected = 'any' }
    ) {
        Get-AppInstallScope -App @{ name = 'Contoso.App'; scope = $Scope } | Should -Be $Expected
    }

    It 'Reads an entry with no scope as any' {
        Get-AppInstallScope -App @{ name = 'Contoso.App' } | Should -Be 'any'
    }

    It 'Names <Expected> for <Case>' -ForEach @(
        @{ Case = 'scope user'; App = @{ name = 'Contoso.App'; scope = 'user' }; Expected = 'UserScope' }
        @{ Case = 'userPhase'; App = @{ name = 'Contoso.App'; userPhase = $true }; Expected = 'UserPhase' }
        @{ Case = 'scope user and userPhase'; App = @{ name = 'Contoso.App'; scope = 'user'; userPhase = $true }; Expected = 'UserScope' }
        @{ Case = 'scope machine and userPhase'; App = @{ name = 'Contoso.App'; scope = 'machine'; userPhase = $true }; Expected = 'UserPhase' }
    ) {
        Get-AppPerUserDeferReason -App $App | Should -Be $Expected
    }

    It 'Names nothing for an app that is not per-user: <Case>' -ForEach @(
        @{ Case = 'no fields'; App = @{ name = 'Contoso.App' } }
        @{ Case = 'scope machine'; App = @{ name = 'Contoso.App'; scope = 'machine' } }
        @{ Case = 'scope any'; App = @{ name = 'Contoso.App'; scope = 'any' } }
        @{ Case = 'userPhase false'; App = @{ name = 'Contoso.App'; userPhase = $false } }
    ) {
        Get-AppPerUserDeferReason -App $App | Should -BeNullOrEmpty
    }
}

Describe 'Get-AppNotApplicableReason (work-order item 38)' {
    It 'Uses conditionDescription when the entry has one, for an arch skip too' {
        Mock Get-OSArchitecture { 'Arm64' }

        Get-AppNotApplicableReason -App @{ name = 'Contoso.App'; arch = 'X64'; conditionDescription = 'x64 only' } | Should -Be 'x64 only'
        Get-AppNotApplicableReason -App @{ name = 'Contoso.App'; condition = { $false }; conditionDescription = 'Dell hardware only' } | Should -Be 'Dell hardware only'
    }

    It 'Says which architectures the entry is for, and what this PC is, when it has no description' {
        Mock Get-OSArchitecture { 'X64' }

        Get-AppNotApplicableReason -App @{ name = 'Contoso.App'; arch = @('Arm64', 'X86') } | Should -Be 'for Arm64, X86 Windows only; this PC is X64'
    }

    It 'Says condition not met when the arch list allows this PC, or there is none' {
        Mock Get-OSArchitecture { 'X64' }

        Get-AppNotApplicableReason -App @{ name = 'Contoso.App'; arch = 'x64'; condition = { $false } } | Should -Be 'condition not met'
        Get-AppNotApplicableReason -App @{ name = 'Contoso.App'; condition = { $false } } | Should -Be 'condition not met'
    }

    It 'Says condition not met when the architecture cannot be read (the arch list then counted as met)' {
        Mock Get-OSArchitecture { throw 'The OS architecture could not be read.' }

        Get-AppNotApplicableReason -App @{ name = 'Contoso.App'; arch = 'X64'; condition = { $false } } | Should -Be 'condition not met'
    }
}

Describe 'ConvertTo-AppPostInstallResult (work-order item 38)' {
    It 'Reads <Case>' -ForEach @(
        @{ Case = "the string 'Configured'"; Output = @('Configured'); Status = 'Configured'; Reason = $null }
        @{ Case = 'a status in another case'; Output = @('configured'); Status = 'Configured'; Reason = $null }
        @{ Case = 'a hashtable'; Output = @(@{ Status = 'NotConfigured'; Reason = 'no secret supplied' }); Status = 'NotConfigured'; Reason = 'no secret supplied' }
        @{ Case = 'an object'; Output = @([pscustomobject]@{ Status = 'Failed'; Reason = ' service not running ' }); Status = 'Failed'; Reason = 'service not running' }
        @{ Case = 'the last of several outputs'; Output = @('stray output', 42, 'Configured'); Status = 'Configured'; Reason = $null }
        @{ Case = 'a reason for Configured, which is dropped'; Output = @(@{ Status = 'Configured'; Reason = 'ignored' }); Status = 'Configured'; Reason = $null }
        @{ Case = 'NotConfigured without a reason'; Output = @('NotConfigured'); Status = 'NotConfigured'; Reason = 'no reason given' }
        @{ Case = 'Failed without a reason'; Output = @(@{ Status = 'Failed' }); Status = 'Failed'; Reason = 'no reason given' }
    ) {
        $result = ConvertTo-AppPostInstallResult -Output $Output

        $result.Status | Should -Be $Status
        $result.Reason | Should -Be $Reason
    }

    It 'Fails a hook that did not say whether the app is configured: <Case>' -ForEach @(
        @{ Case = 'no output'; Output = @(); Pattern = 'returned no result' }
        @{ Case = 'only nulls'; Output = @($null); Pattern = 'returned no result' }
        @{ Case = '$true'; Output = @($true); Pattern = "returned 'True', not Configured, NotConfigured or Failed" }
        @{ Case = 'an unknown status'; Output = @(@{ Status = 'Done' }); Pattern = "returned 'Done', not Configured" }
        @{ Case = 'an object without a status'; Output = @(@{ Reason = 'x' }); Pattern = 'not Configured, NotConfigured or Failed' }
    ) {
        $result = ConvertTo-AppPostInstallResult -Output $Output

        $result.Status | Should -Be 'Failed'
        $result.Reason | Should -Match $Pattern
    }

    It 'Shortens a long unknown result' {
        $result = ConvertTo-AppPostInstallResult -Output @('x' * 200)

        $result.Status | Should -Be 'Failed'
        $result.Reason.Length | Should -BeLessThan 160
        $result.Reason | Should -Match '\.\.\.'
    }
}

Describe 'Invoke-AppPostInstall (work-order item 38)' {
    BeforeEach {
        Mock Write-Info { }
    }

    It 'Calls a scriptblock hook with the catalog entry and returns its result' {
        $script:hookSawApp = $null
        $app = @{ name = 'Contoso.App'; postInstall = { param($App) $script:hookSawApp = $App.name; 'Configured' } }

        $result = Invoke-AppPostInstall -App $app

        $result.Status | Should -Be 'Configured'
        $script:hookSawApp | Should -Be 'Contoso.App'
        Should -Invoke Write-Info -Times 1 -Exactly -ParameterFilter { $Message -eq 'Configuring: Contoso.App' }
    }

    It 'Passes the entry as $args[0] to a hook without a param block' {
        $script:hookSawApp = $null

        $result = Invoke-AppPostInstall -App @{ name = 'Contoso.App'; postInstall = { $script:hookSawApp = $args[0].name; @{ Status = 'NotConfigured'; Reason = 'later' } } }

        $result.Status | Should -Be 'NotConfigured'
        $result.Reason | Should -Be 'later'
        $script:hookSawApp | Should -Be 'Contoso.App'
    }

    It 'Calls a hook named by a function' {
        $result = Invoke-AppPostInstall -App @{ name = 'Contoso.App'; postInstall = 'Set-ZzTestAppConfiguration' }

        $result.Status | Should -Be 'Configured'
    }

    It 'Fails the app with the message when the hook throws' {
        $result = Invoke-AppPostInstall -App @{ name = 'Contoso.App'; postInstall = { throw 'Access to the registry key is denied.' } }

        $result.Status | Should -Be 'Failed'
        $result.Reason | Should -Be 'Access to the registry key is denied.'
    }

    It 'Fails the app when the hook writes an error, even if it then says Configured' {
        $result = Invoke-AppPostInstall -App @{ name = 'Contoso.App'; postInstall = { Write-Error 'Service tvnserver was not found.'; 'Configured' } }

        $result.Status | Should -Be 'Failed'
        $result.Reason | Should -Match 'Service tvnserver was not found'
    }
}
