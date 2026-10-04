# EnvironmentPreflight.Tests.ps1
# Tests for WingetAppSetup/Private/EnvironmentPreflight.ps1 (wgt-gq8.39): the language-mode check,
# the Group Policy execution-policy check the relaunches use, the proxy check and the pre-flight
# step Invoke-WingetInstall runs for the account it installs as. The registry is never read: every
# test mocks Get-ItemProperty or the seams above it. The call sites (tail.ps1, Restart-WithElevation,
# Invoke-PowerShell7Bootstrap, Test-SystemRequirements, Invoke-WingetInstall) are tested in their
# own files.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    # A fake registry for Get-ItemProperty -LiteralPath: path -> values. A path that is not in it
    # does not exist, as Get-ItemProperty -ErrorAction Stop reports a missing key.
    function Set-TestRegistry {
        param ([hashtable]$Keys = @{})
        $script:testRegistry = $Keys
    }
    function Get-TestRegistryValue {
        param ([string]$Path)
        if ($script:testRegistry.ContainsKey($Path)) {
            return [pscustomobject]$script:testRegistry[$Path]
        }
        throw [System.Management.Automation.ItemNotFoundException]::new("Cannot find path '$Path' because it does not exist.")
    }

    $script:windowsPolicyKey = 'SOFTWARE\Policies\Microsoft\Windows\PowerShell'
    $script:corePolicyKey = 'SOFTWARE\Policies\Microsoft\PowerShellCore'
}

Describe 'Get-PowerShellLanguageMode and Test-FullLanguageMode' {
    BeforeEach {
        $script:errorMessages = @()
        Mock Write-ErrorMessage { $script:errorMessages += $Message }
    }

    It 'Reads the language mode this session runs in' {
        Get-PowerShellLanguageMode | Should -Be 'FullLanguage'
    }

    It 'Returns $true and prints nothing in FullLanguage mode' {
        Mock Get-PowerShellLanguageMode { 'FullLanguage' }

        Test-FullLanguageMode | Should -BeTrue
        $script:errorMessages | Should -HaveCount 0
    }

    It 'Returns $false with one line that names <_> mode, the cause and exit code 5' -ForEach @('ConstrainedLanguage', 'RestrictedLanguage', 'NoLanguage') {
        $mode = $_
        Mock Get-PowerShellLanguageMode { $mode }

        Test-FullLanguageMode | Should -BeFalse
        $script:errorMessages | Should -HaveCount 1
        $script:errorMessages[0] | Should -Match "in $mode mode on this PC"
        $script:errorMessages[0] | Should -Match 'application control policy \(App Control for Business/WDAC or AppLocker\)'
        $script:errorMessages[0] | Should -Match 'stops here with exit code 5 and changes nothing'
    }
}

Describe 'Get-ScriptExecutionPolicyBlock (wgt-gq8.39)' {
    BeforeEach {
        Set-TestRegistry
        Mock Get-ItemProperty { Get-TestRegistryValue -Path (@($LiteralPath)[0]) }
    }

    It 'Returns $null when Group Policy sets no execution policy for <_>' -ForEach @('WindowsPowerShell', 'PowerShell7') {
        Get-ScriptExecutionPolicyBlock -Engine $_ | Should -BeNullOrEmpty
    }

    It 'Reports a machine policy of AllSigned for Windows PowerShell, with the key and where to change it' {
        Set-TestRegistry @{ "HKLM:\$($script:windowsPolicyKey)" = @{ EnableScripts = 1; ExecutionPolicy = 'AllSigned' } }

        $block = Get-ScriptExecutionPolicyBlock -Engine WindowsPowerShell

        $block.Engine | Should -Be 'WindowsPowerShell'
        $block.Scope | Should -Be 'MachinePolicy'
        $block.Policy | Should -Be 'AllSigned'
        $block.Key | Should -Be "HKLM\$($script:windowsPolicyKey)"
        $block.GroupPolicyPath | Should -Be 'Computer Configuration > Administrative Templates > Windows Components > Windows PowerShell > Turn on Script Execution'
        $block.Description | Should -Be "Group Policy sets the Windows PowerShell execution policy for this PC to AllSigned (MachinePolicy, HKLM\$($script:windowsPolicyKey))"
    }

    It 'Reads script execution turned off (EnableScripts 0) as Restricted' {
        Set-TestRegistry @{ "HKLM:\$($script:windowsPolicyKey)" = @{ EnableScripts = 0 } }

        (Get-ScriptExecutionPolicyBlock -Engine WindowsPowerShell).Policy | Should -Be 'Restricted'
    }

    It 'Reads an execution policy PowerShell does not know as its default, Restricted' {
        Set-TestRegistry @{ "HKLM:\$($script:windowsPolicyKey)" = @{ EnableScripts = 1; ExecutionPolicy = 'SignedOnly' } }

        (Get-ScriptExecutionPolicyBlock -Engine WindowsPowerShell).Policy | Should -Be 'Restricted'
    }

    It 'Names AllSigned in its usual spelling, however the registry spells it' {
        Set-TestRegistry @{ "HKLM:\$($script:windowsPolicyKey)" = @{ EnableScripts = '1'; ExecutionPolicy = 'allsigned' } }

        (Get-ScriptExecutionPolicyBlock -Engine WindowsPowerShell).Policy | Should -BeExactly 'AllSigned'
    }

    It 'Returns $null for a machine policy of <_>, which lets the relaunched copy run' -ForEach @('RemoteSigned', 'Unrestricted', 'Bypass', 'remotesigned') {
        Set-TestRegistry @{ "HKLM:\$($script:windowsPolicyKey)" = @{ EnableScripts = 1; ExecutionPolicy = $_ } }

        Get-ScriptExecutionPolicyBlock -Engine WindowsPowerShell | Should -BeNullOrEmpty
    }

    It 'Ignores an ExecutionPolicy value without EnableScripts, as PowerShell does' {
        Set-TestRegistry @{ "HKLM:\$($script:windowsPolicyKey)" = @{ ExecutionPolicy = 'AllSigned' } }

        Get-ScriptExecutionPolicyBlock -Engine WindowsPowerShell | Should -BeNullOrEmpty
    }

    It 'Lets a machine policy that allows scripts win over a user policy of AllSigned' {
        Set-TestRegistry @{
            "HKLM:\$($script:windowsPolicyKey)" = @{ EnableScripts = 1; ExecutionPolicy = 'RemoteSigned' }
            "HKCU:\$($script:windowsPolicyKey)" = @{ EnableScripts = 1; ExecutionPolicy = 'AllSigned' }
        }

        Get-ScriptExecutionPolicyBlock -Engine WindowsPowerShell | Should -BeNullOrEmpty
    }

    It 'Reports a user policy when the machine sets none, for this account' {
        Set-TestRegistry @{
            "HKLM:\$($script:windowsPolicyKey)" = @{ ScriptBlockLogging = 1 }
            "HKCU:\$($script:windowsPolicyKey)" = @{ EnableScripts = 1; ExecutionPolicy = 'AllSigned' }
        }

        $block = Get-ScriptExecutionPolicyBlock -Engine WindowsPowerShell

        $block.Scope | Should -Be 'UserPolicy'
        $block.Key | Should -Be "HKCU\$($script:windowsPolicyKey)"
        $block.GroupPolicyPath | Should -Be 'User Configuration > Administrative Templates > Windows Components > Windows PowerShell > Turn on Script Execution'
        $block.Description | Should -Match 'for this account to AllSigned \(UserPolicy'
    }

    It 'Does not apply Windows PowerShell''s policy to PowerShell 7 without the PowerShellCore policy' {
        Set-TestRegistry @{ "HKLM:\$($script:windowsPolicyKey)" = @{ EnableScripts = 1; ExecutionPolicy = 'AllSigned' } }

        Get-ScriptExecutionPolicyBlock -Engine PowerShell7 | Should -BeNullOrEmpty
    }

    It 'Reads PowerShell 7''s own policy from the PowerShellCore key' {
        Set-TestRegistry @{ "HKLM:\$($script:corePolicyKey)" = @{ EnableScripts = 1; ExecutionPolicy = 'AllSigned' } }

        $block = Get-ScriptExecutionPolicyBlock -Engine PowerShell7

        $block.Engine | Should -Be 'PowerShell7'
        $block.Policy | Should -Be 'AllSigned'
        $block.Key | Should -Be "HKLM\$($script:corePolicyKey)"
        $block.GroupPolicyPath | Should -Be 'Computer Configuration > Administrative Templates > PowerShell Core > Turn on Script Execution'
        $block.Description | Should -Match '^Group Policy sets the PowerShell 7 execution policy for this PC to AllSigned'
    }

    It 'Follows ''Use Windows PowerShell Policy setting'' to the Windows PowerShell key for PowerShell 7' {
        Set-TestRegistry @{
            "HKLM:\$($script:corePolicyKey)"    = @{ UseWindowsPowerShellPolicySetting = 1; EnableScripts = 1; ExecutionPolicy = 'Unrestricted' }
            "HKLM:\$($script:windowsPolicyKey)" = @{ EnableScripts = 0 }
        }

        $block = Get-ScriptExecutionPolicyBlock -Engine PowerShell7

        $block.Policy | Should -Be 'Restricted'
        $block.Key | Should -Be "HKLM\$($script:windowsPolicyKey)"
        $block.GroupPolicyPath | Should -Be 'Computer Configuration > Administrative Templates > Windows Components > Windows PowerShell > Turn on Script Execution, which PowerShell 7 follows through ''Use Windows PowerShell Policy setting'' under PowerShell Core'
    }

    It 'Returns $null when PowerShell 7 follows a Windows PowerShell key that does not exist' {
        Set-TestRegistry @{ "HKLM:\$($script:corePolicyKey)" = @{ UseWindowsPowerShellPolicySetting = 1 } }

        Get-ScriptExecutionPolicyBlock -Engine PowerShell7 | Should -BeNullOrEmpty
    }
}

Describe 'Format-ElevationPolicyBlockMessage (wgt-gq8.39)' {
    It 'Says a machine policy keeps any elevated Windows PowerShell from running the script, and what to do' {
        $block = [pscustomobject]@{ Scope = 'MachinePolicy'; Description = 'Group Policy sets X'; GroupPolicyPath = 'Computer Configuration > Y' }

        $message = Format-ElevationPolicyBlockMessage -Block $block

        $message | Should -Be 'Group Policy sets X, which -ExecutionPolicy Bypass on the command line cannot override, so an elevated Windows PowerShell cannot run this script from a file. Ask whoever manages this PC''s policies to allow scripts (Computer Configuration > Y), or start it from an elevated PowerShell 7 (pwsh) session, where it needs no relaunch.'
    }

    It 'Says a user policy matters only when this account approves the UAC prompt' {
        $block = [pscustomobject]@{ Scope = 'UserPolicy'; Description = 'Group Policy sets X'; GroupPolicyPath = 'User Configuration > Y' }

        Format-ElevationPolicyBlockMessage -Block $block | Should -Match 'if this account approves the UAC prompt, the elevated Windows PowerShell cannot run this script from a file\. Approve it with another administrator account'
    }
}

Describe 'Get-WinInetProxySetting and Test-ProxySettingsPerMachine (wgt-gq8.39)' {
    BeforeEach {
        Set-TestRegistry
        Mock Get-ItemProperty { Get-TestRegistryValue -Path (@($LiteralPath)[0]) }
    }

    It 'Reads this account''s proxy server, bypass list and configuration script from HKCU' {
        Set-TestRegistry @{ 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' = @{ ProxyEnable = 1; ProxyServer = ' proxy.contoso.com:8080 '; ProxyOverride = '<local>'; AutoConfigURL = 'http://wpad.contoso.com/proxy.pac' } }

        $setting = Get-WinInetProxySetting

        $setting.ProxyServer | Should -Be 'proxy.contoso.com:8080'
        $setting.ProxyOverride | Should -Be '<local>'
        $setting.AutoConfigUrl | Should -Be 'http://wpad.contoso.com/proxy.pac'
    }

    It 'Reads another account''s settings from its hive under HKEY_USERS' {
        Set-TestRegistry @{ 'Registry::HKEY_USERS\S-1-5-21-1-2-3-1001\Software\Microsoft\Windows\CurrentVersion\Internet Settings' = @{ ProxyEnable = 1; ProxyServer = 'proxy:3128' } }

        (Get-WinInetProxySetting -UserSid 'S-1-5-21-1-2-3-1001').ProxyServer | Should -Be 'proxy:3128'
    }

    It 'Ignores a proxy server that is switched off (ProxyEnable 0), and its bypass list' {
        Set-TestRegistry @{ 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' = @{ ProxyEnable = 0; ProxyServer = 'old-proxy:80'; ProxyOverride = '<local>' } }

        $setting = Get-WinInetProxySetting

        $setting.ProxyServer | Should -Be ''
        $setting.ProxyOverride | Should -Be ''
        $setting.AutoConfigUrl | Should -Be ''
    }

    It 'Returns $null when the settings cannot be read' {
        Get-WinInetProxySetting -UserSid 'S-1-5-21-9' | Should -BeNullOrEmpty
    }

    It 'Says the proxy is per machine only when Group Policy sets ProxySettingsPerUser to 0 (<Case>)' -ForEach @(
        @{ Case = 'per machine'; Values = @{ ProxySettingsPerUser = 0 }; Expected = $true }
        @{ Case = 'per user'; Values = @{ ProxySettingsPerUser = 1 }; Expected = $false }
        @{ Case = 'value missing'; Values = @{ Other = 1 }; Expected = $false }
        @{ Case = 'no policy key'; Values = $null; Expected = $false }
    ) {
        if ($Values) {
            Set-TestRegistry @{ 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Internet Settings' = $Values }
        }

        Test-ProxySettingsPerMachine | Should -Be $Expected
    }
}

Describe 'Get-AccountSid (wgt-gq8.39)' {
    It 'Returns $null instead of throwing for an account it cannot translate' {
        Get-AccountSid -AccountName 'NO-SUCH-DOMAIN\no-such-user-wgt-gq8-39' | Should -BeNullOrEmpty
    }

    It 'Translates a well-known account to its SID' -Skip:(-not $IsWindows) {
        Get-AccountSid -AccountName 'NT AUTHORITY\SYSTEM' | Should -Be 'S-1-5-18'
    }
}

Describe 'Get-ProxyInheritanceWarning (wgt-gq8.39)' {
    BeforeEach {
        Mock Test-ProxySettingsPerMachine { $false }
        Mock Get-AccountSid { 'S-1-5-21-1-2-3-1001' }
        $script:userProxy = [pscustomobject]@{ ProxyServer = 'proxy.contoso.com:8080'; ProxyOverride = '<local>'; AutoConfigUrl = '' }
        $script:ownProxy = [pscustomobject]@{ ProxyServer = ''; ProxyOverride = ''; AutoConfigUrl = '' }
        Mock Get-WinInetProxySetting {
            if ($UserSid) {
                return $script:userProxy
            }
            $script:ownProxy
        }
        $script:systemRun = New-TestAccountContext -System -SessionUser 'CONTOSO\jdoe'
    }

    It 'Names the signed-in user''s exact proxy settings that a run as SYSTEM does not have' {
        $warning = Get-ProxyInheritanceWarning -AccountContext $script:systemRun

        $warning | Should -Be "The signed-in user 'CONTOSO\jdoe' has a proxy in their Windows Internet settings (proxy server proxy.contoso.com:8080 (bypass: <local>)) that this run as SYSTEM does not use (SYSTEM has no proxy). On a network that only allows traffic through that proxy, downloads fail; if they do, give SYSTEM the same proxy settings, or set the proxy for the whole PC, and re-run the installer."
        Should -Invoke Get-AccountSid -Times 1 -Exactly -ParameterFilter { $AccountName -eq 'CONTOSO\jdoe' }
        Should -Invoke Get-WinInetProxySetting -Times 1 -Exactly -ParameterFilter { $UserSid -eq 'S-1-5-21-1-2-3-1001' }
    }

    It 'Names the elevating admin account under cross-user elevation, and what that account has' {
        $script:userProxy = [pscustomobject]@{ ProxyServer = ''; ProxyOverride = ''; AutoConfigUrl = 'http://wpad.contoso.com/proxy.pac' }
        $script:ownProxy = [pscustomobject]@{ ProxyServer = 'other:80'; ProxyOverride = ''; AutoConfigUrl = '' }
        $context = New-TestAccountContext -ProcessUser 'CONTOSO\admin-tech' -SessionUser 'CONTOSO\jdoe' -CrossUser

        $warning = Get-ProxyInheritanceWarning -AccountContext $context

        $warning | Should -Match "\(automatic configuration script http://wpad\.contoso\.com/proxy\.pac\) that this run as 'CONTOSO\\admin-tech' does not use \('CONTOSO\\admin-tech' has proxy server other:80\)"
    }

    It 'Reads nothing and says nothing for a run as the signed-in user' {
        Get-ProxyInheritanceWarning -AccountContext (New-TestAccountContext) | Should -BeNullOrEmpty

        Should -Invoke Get-WinInetProxySetting -Times 0
        Should -Invoke Get-AccountSid -Times 0
    }

    It 'Says nothing when <Case>' -ForEach @(
        @{ Case = 'nobody is signed in'; Setup = { $script:systemRun = New-TestAccountContext -System -SessionUser '' } }
        @{ Case = 'Group Policy makes the proxy one setting for the whole PC'; Setup = { Mock Test-ProxySettingsPerMachine { $true } } }
        @{ Case = 'the signed-in account cannot be resolved'; Setup = { Mock Get-AccountSid { $null } } }
        @{ Case = 'the user''s settings cannot be read'; Setup = { $script:userProxy = $null } }
        @{ Case = 'the user has no proxy'; Setup = { $script:userProxy = [pscustomobject]@{ ProxyServer = ''; ProxyOverride = ''; AutoConfigUrl = '' } } }
        @{ Case = 'this account has the same proxy'; Setup = { $script:ownProxy = [pscustomobject]@{ ProxyServer = 'proxy.contoso.com:8080'; ProxyOverride = ''; AutoConfigUrl = '' } } }
    ) {
        . $Setup

        Get-ProxyInheritanceWarning -AccountContext $script:systemRun | Should -BeNullOrEmpty
    }

    It 'Says nothing without an account context' {
        Get-ProxyInheritanceWarning -AccountContext $null | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-EnvironmentPreflight (wgt-gq8.39)' {
    BeforeEach {
        $script:lines = @()
        Mock Write-WarningMessage { $script:lines += "WARN: $Message" }
        Mock Write-ErrorMessage { $script:lines += "ERROR: $Message" }
        Mock Write-Info { $script:lines += "INFO: $Message" }
        Mock Get-InstallAccountContext { New-TestAccountContext }
        Mock Get-ProxyInheritanceWarning { $null }
        Mock Get-PendingRestartState { New-TestRestartState }
        Mock Get-WingetPolicyBlock { $null }
        $script:blockedPolicy = [pscustomobject]@{ Name = 'EnableAppInstaller'; Policy = 'Enable App Installer' }
    }

    It 'Prints nothing and lets the run go on when nothing is wrong, returning the restart state it read' {
        $state = New-TestRestartState
        Mock Get-PendingRestartState { $state }

        $result = Invoke-EnvironmentPreflight -AccountContext (New-TestAccountContext)

        $result.ExitCode | Should -Be 0
        $result.WingetPolicyBlocked | Should -BeFalse
        $result.RestartState | Should -Be $state
        @($result.RestartPendingReasons) | Should -HaveCount 0
        $script:lines | Should -HaveCount 0
    }

    It 'Prints one line per problem, warnings first, and stops a real run with exit code 2 on the Group Policy block' {
        Mock Get-ProxyInheritanceWarning { 'PROXY WARNING' }
        Mock Get-PendingRestartState { New-TestRestartState -WindowsUpdate }
        Mock Get-WingetPolicyBlock { $script:blockedPolicy }

        $result = Invoke-EnvironmentPreflight -AccountContext (New-TestAccountContext -System -SessionUser 'CONTOSO\jdoe')

        $result.ExitCode | Should -Be 2
        $result.WingetPolicyBlocked | Should -BeTrue
        @($result.RestartPendingReasons) | Should -Be @('Windows Update has a restart pending')
        $script:lines | Should -HaveCount 3
        $script:lines[0] | Should -Be 'WARN: PROXY WARNING'
        $script:lines[1] | Should -Be 'WARN: A restart is already pending on this PC (Windows Update has a restart pending). An installer that needs a restart first fails with 0x8A15010A; if one does, restart this PC and re-run the installer.'
        $script:lines[2] | Should -Be "ERROR: Group Policy on this PC blocks winget: 'Enable App Installer' is Disabled (EnableAppInstaller = 0 under HKLM\SOFTWARE\Policies\Microsoft\Windows\AppInstaller). This installer cannot install apps until the policy allows it; ask whoever manages this PC's policies (Computer Configuration > Administrative Templates > Windows Components > Desktop App Installer) to allow it, then re-run the installer."
    }

    It 'Reports the Group Policy block in a dry run with the exit code a real run would stop with, and lets the preview go on' {
        Mock Get-WingetPolicyBlock { $script:blockedPolicy }

        $result = Invoke-EnvironmentPreflight -WhatIf -AccountContext (New-TestAccountContext)

        $result.ExitCode | Should -Be 0
        $result.WingetPolicyBlocked | Should -BeTrue
        $script:lines | Should -HaveCount 1
        $script:lines[0] | Should -Match "^INFO: \[DRY-RUN\] Group Policy on this PC blocks winget: 'Enable App Installer' is Disabled .* A real run would stop here with exit code 2\.$"
    }

    It 'Runs the read-only checks in a dry run too' {
        Mock Get-ProxyInheritanceWarning { 'PROXY WARNING' }
        Mock Get-PendingRestartState { New-TestRestartState -ComponentServicing }

        $result = Invoke-EnvironmentPreflight -WhatIf -AccountContext (New-TestAccountContext -System -SessionUser 'CONTOSO\jdoe')

        $result.ExitCode | Should -Be 0
        $script:lines | Should -HaveCount 2
        Should -Invoke Get-ProxyInheritanceWarning -Times 1 -Exactly
        Should -Invoke Get-PendingRestartState -Times 1 -Exactly
    }

    It 'Goes on when a check cannot be worked out: a proxy check that fails is skipped, a restart state that cannot be read is said' {
        Mock Get-ProxyInheritanceWarning { throw 'registry unavailable' }
        Mock Get-PendingRestartState { throw 'access denied' }

        $result = Invoke-EnvironmentPreflight -AccountContext (New-TestAccountContext)

        $result.ExitCode | Should -Be 0
        $result.RestartState | Should -BeNullOrEmpty
        $script:lines | Should -Be @('WARN: Could not check whether a restart is pending: access denied')
    }

    It 'Reads the account context itself when the caller does not pass it' {
        Invoke-EnvironmentPreflight | Out-Null

        Should -Invoke Get-InstallAccountContext -Times 1 -Exactly
    }
}
