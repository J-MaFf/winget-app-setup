# TightVnc.Tests.ps1
# Tests for WingetAppSetup/Private/TightVnc.ps1 (work-order item 18, review finding P2-22): the
# TightVNC Server password encoding, where the run gets the secret (environment, prompt, or
# nowhere), and the catalog's post-install hook that writes it to HKLM\SOFTWARE\TightVNC\Server,
# limits that key to SYSTEM and Administrators and restarts the service. The registry, the ACL and
# the service are mocked at their seams; Protect-TightVncServerKey has one Windows-only test
# against a throwaway HKCU key. The Invoke-WingetInstall wiring is tested in Install.Tests.ps1.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    function New-TestSecureString {
        param ([string]$Value)
        $secure = New-Object System.Security.SecureString
        foreach ($character in $Value.ToCharArray()) {
            $secure.AppendChar($character)
        }
        return $secure
    }

    function ConvertFrom-TestHex {
        param ([string]$Hex)
        return , [byte[]]@(for ($index = 0; $index -lt $Hex.Length; $index += 2) { [Convert]::ToByte($Hex.Substring($index, 2), 16) })
    }

    function ConvertTo-TestHex {
        param ([byte[]]$Bytes)
        return (($Bytes | ForEach-Object { $_.ToString('X2') }) -join '')
    }

    $script:PasswordVariable = 'WINGET_APP_SETUP_TIGHTVNC_PASSWORD'
    $script:ControlVariable = 'WINGET_APP_SETUP_TIGHTVNC_CONTROL_PASSWORD'
    $script:KeyPath = 'HKLM:\SOFTWARE\TightVNC\Server'
    $script:CatalogEntry = @(Get-DefaultAppCatalog) | Where-Object { $_.name -eq 'GlavSoft.TightVNC' } | Select-Object -First 1
}

AfterAll {
    Remove-Item -LiteralPath "Env:\$($script:PasswordVariable)" -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath "Env:\$($script:ControlVariable)" -ErrorAction SilentlyContinue
    $script:TightVncSecret = $null
}

Describe 'ConvertTo-TightVncPasswordBytes (VNC password obfuscation)' {
    # Published and cross-checked vectors (research note: TightVNC's own DesCrypt.cpp compiled,
    # OpenSSL des-ecb, Python cryptography): 'Secure!' is a TightVNC 2.8.11
    # HKLM\SOFTWARE\TightVNC\Server\Password value, 'bar' is vncpasswd.py's README vector.
    It 'Encodes <Plain> as <Hex>' -ForEach @(
        @{ Plain = 'Secure!'; Hex = 'D7A514D8C556AADE' }
        @{ Plain = 'bar'; Hex = '9CA3F3686574F277' }
        @{ Plain = 'password'; Hex = 'DBD83CFD727A1458' }
        @{ Plain = '12345678'; Hex = 'F0E43164F6C2E373' }
        @{ Plain = 'P@ssw0rd'; Hex = '317C13DDB544C6C7' }
        @{ Plain = 'abc'; Hex = '9C0A172D3482E122' }
    ) {
        $bytes = ConvertTo-TightVncPasswordBytes -Password (New-TestSecureString $Plain)

        $bytes.GetType().FullName | Should -Be 'System.Byte[]'
        $bytes.Length | Should -Be 8
        ConvertTo-TestHex $bytes | Should -Be $Hex
    }

    It 'Uses only the first 8 characters, as TightVNC does' {
        $bytes = ConvertTo-TightVncPasswordBytes -Password (New-TestSecureString 'P@ssw0rd-LongerThan8')

        ConvertTo-TestHex $bytes | Should -Be '317C13DDB544C6C7'
    }

    It 'Rejects an empty password' {
        { ConvertTo-TightVncPasswordBytes -Password (New-TestSecureString '') } | Should -Throw 'The TightVNC password is empty.'
    }

    It 'Rejects a character TightVNC may encode differently (<Case>), without showing the password' -ForEach @(
        @{ Case = 'a tab'; Plain = "ab`tcd" }
        @{ Case = 'a non-ASCII letter'; Plain = "pa$([char]0x00E4)ss" }
    ) {
        $thrown = $null
        try {
            ConvertTo-TightVncPasswordBytes -Password (New-TestSecureString $Plain)
        }
        catch {
            $thrown = $_.Exception.Message
        }

        $thrown | Should -Be 'The TightVNC password must use printable ASCII characters only (letters, digits, punctuation and spaces).'
    }

    It 'Ignores a character after the 8th, as TightVNC never reads it' {
        { ConvertTo-TightVncPasswordBytes -Password (New-TestSecureString "abcdefgh`t") } | Should -Not -Throw
    }
}

Describe 'Test-SecureStringEqual' {
    It 'Is <Expected> for <First> and <Second>' -ForEach @(
        @{ First = 'abc'; Second = 'abc'; Expected = $true }
        @{ First = 'abc'; Second = 'abd'; Expected = $false }
        @{ First = 'abc'; Second = 'abcd'; Expected = $false }
    ) {
        Test-SecureStringEqual -First (New-TestSecureString $First) -Second (New-TestSecureString $Second) | Should -Be $Expected
    }

    It 'Is false for a missing value' {
        Test-SecureStringEqual -First (New-TestSecureString 'abc') -Second $null | Should -BeFalse
    }
}

Describe 'Where a run gets the TightVNC passwords (Import-TightVncSecretFromEnvironment, Get-TightVncSecret)' {
    BeforeEach {
        $script:TightVncSecret = $null
        Remove-Item -LiteralPath "Env:\$($script:PasswordVariable)" -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath "Env:\$($script:ControlVariable)" -ErrorAction SilentlyContinue
        $script:answers = [System.Collections.Generic.Queue[string]]::new()
        Mock Read-Host { New-TestSecureString $script:answers.Dequeue() }
        Mock Test-IsContinuousIntegration { $false }
        $script:infoMessages = @()
        Mock Write-Info { $script:infoMessages += $Message }
        $script:warningMessages = @()
        Mock Write-WarningMessage { $script:warningMessages += $Message }
    }

    It 'Takes both passwords from the environment and removes the variables from this process' {
        [System.Environment]::SetEnvironmentVariable($script:PasswordVariable, 'Secure!')
        [System.Environment]::SetEnvironmentVariable($script:ControlVariable, 'bar')

        $secret = Get-TightVncSecret

        ConvertTo-TestHex (ConvertTo-TightVncPasswordBytes -Password $secret.Password) | Should -Be 'D7A514D8C556AADE'
        ConvertTo-TestHex (ConvertTo-TightVncPasswordBytes -Password $secret.ControlPassword) | Should -Be '9CA3F3686574F277'
        $secret.PasswordSource | Should -Be $script:PasswordVariable
        $secret.ControlPasswordSource | Should -Be $script:ControlVariable
        $secret.Password.IsReadOnly() | Should -BeTrue
        [System.Environment]::GetEnvironmentVariables().Contains($script:PasswordVariable) | Should -BeFalse
        [System.Environment]::GetEnvironmentVariables().Contains($script:ControlVariable) | Should -BeFalse
        Should -Invoke Read-Host -Times 0 -Exactly
    }

    It 'Treats the control password as optional' {
        [System.Environment]::SetEnvironmentVariable($script:PasswordVariable, 'Secure!')

        $secret = Get-TightVncSecret

        $secret.Password | Should -Not -BeNullOrEmpty
        $secret.ControlPassword | Should -BeNullOrEmpty
    }

    It 'Asks twice, masked, when the environment has none and someone is at the console' {
        $script:answers.Enqueue('Secure!')
        $script:answers.Enqueue('Secure!')

        $secret = Get-TightVncSecret

        ConvertTo-TestHex (ConvertTo-TightVncPasswordBytes -Password $secret.Password) | Should -Be 'D7A514D8C556AADE'
        $secret.PasswordSource | Should -Be 'the password entered at the prompt'
        Should -Invoke Read-Host -Times 2 -Exactly -ParameterFilter { $AsSecureString -and -not $MaskInput }
    }

    It 'Asks again when the two entries differ or TightVNC cannot use the first one' {
        $script:answers.Enqueue('Secure!')
        $script:answers.Enqueue('Secure?')
        $script:answers.Enqueue("ab`tc")
        $script:answers.Enqueue('bar')
        $script:answers.Enqueue('bar')

        $secret = Get-TightVncSecret

        ConvertTo-TestHex (ConvertTo-TightVncPasswordBytes -Password $secret.Password) | Should -Be '9CA3F3686574F277'
        Should -Invoke Read-Host -Times 5 -Exactly
        $script:warningMessages | Should -Contain 'The two passwords do not match. Try again.'
        ($script:warningMessages -join "`n") | Should -Match 'printable ASCII characters only.*Try again\.'
    }

    It 'Gives up after three failed tries' {
        foreach ($answer in @('aaa', 'bbb', 'aaa', 'bbb', 'aaa', 'bbb')) {
            $script:answers.Enqueue($answer)
        }

        $secret = Get-TightVncSecret

        $secret.Password | Should -BeNullOrEmpty
        $secret.PromptReason | Should -Be 'no usable server password was entered at the prompt (3 tries)'
    }

    It 'Takes an empty answer as skipping the password' {
        $script:answers.Enqueue('')

        $secret = Get-TightVncSecret

        $secret.Password | Should -BeNullOrEmpty
        $secret.PromptReason | Should -Be 'no server password was entered at the prompt'
        Should -Invoke Read-Host -Times 1 -Exactly
    }

    It 'Never asks <Case>' -ForEach @(
        @{ Case = 'in a non-interactive run'; NonInteractive = $true; ServerSecured = $false; Ci = $false }
        @{ Case = 'when TightVNC Server already has its passwords'; NonInteractive = $false; ServerSecured = $true; Ci = $false }
        @{ Case = 'under CI'; NonInteractive = $false; ServerSecured = $false; Ci = $true }
    ) {
        $script:underCi = $Ci
        Mock Test-IsContinuousIntegration { $script:underCi }

        $secret = Get-TightVncSecret -NonInteractive:$NonInteractive -ServerSecured:$ServerSecured

        $secret.Password | Should -BeNullOrEmpty
        Should -Invoke Read-Host -Times 0 -Exactly
    }

    It 'Asks once per run, so a retried hook does not ask again' {
        $script:answers.Enqueue('')

        [void](Get-TightVncSecret)
        $secret = Get-TightVncSecret

        $secret.Password | Should -BeNullOrEmpty
        Should -Invoke Read-Host -Times 1 -Exactly
    }

    It 'Forgets the passwords when cleared' {
        [System.Environment]::SetEnvironmentVariable($script:PasswordVariable, 'Secure!')
        $secret = Get-TightVncSecret
        $stored = $secret.Password

        Clear-TightVncSecret

        $script:TightVncSecret | Should -BeNullOrEmpty
        # Disposed: its contents can no longer be read.
        { ConvertTo-TightVncPasswordBytes -Password $stored } | Should -Throw
    }
}

Describe 'Initialize-TightVncSecretForRun (the start of an install run)' {
    BeforeEach {
        $script:TightVncSecret = $null
        Remove-Item -LiteralPath "Env:\$($script:PasswordVariable)" -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath "Env:\$($script:ControlVariable)" -ErrorAction SilentlyContinue
        $script:answers = [System.Collections.Generic.Queue[string]]::new()
        Mock Read-Host { New-TestSecureString $script:answers.Dequeue() }
        Mock Test-IsContinuousIntegration { $false }
        Mock Get-TightVncServerSettings { @{ KeyExists = $false; Password = $null; UseVncAuthentication = $null; ControlPassword = $null; UseControlAuthentication = $null } }
        $script:infoMessages = @()
        Mock Write-Info { $script:infoMessages += $Message }
        $script:warningMessages = @()
        Mock Write-WarningMessage { $script:warningMessages += $Message }
    }

    It 'Leaves the environment alone for a catalog without the TightVNC hook' {
        [System.Environment]::SetEnvironmentVariable($script:PasswordVariable, 'Secure!')

        Initialize-TightVncSecretForRun -Apps @(@{ name = 'GlavSoft.TightVNC' }, @{ name = '7zip.7zip' })

        [System.Environment]::GetEnvironmentVariable($script:PasswordVariable) | Should -Be 'Secure!'
        $script:TightVncSecret | Should -BeNullOrEmpty
        Should -Invoke Read-Host -Times 0 -Exactly
    }

    It 'Takes the passwords out of the environment for the default catalog' {
        [System.Environment]::SetEnvironmentVariable($script:PasswordVariable, 'Secure!')

        Initialize-TightVncSecretForRun -Apps @(Get-DefaultAppCatalog) -NonInteractive

        [System.Environment]::GetEnvironmentVariable($script:PasswordVariable) | Should -BeNullOrEmpty
        $script:TightVncSecret.Password | Should -Not -BeNullOrEmpty
        $script:TightVncSecret.PromptDone | Should -BeTrue
        Should -Invoke Read-Host -Times 0 -Exactly
    }

    It 'Asks at the start of an interactive run when TightVNC Server has no password, and the hook never asks again' {
        $script:answers.Enqueue('Secure!')
        $script:answers.Enqueue('Secure!')

        Initialize-TightVncSecretForRun -Apps @($script:CatalogEntry)
        $secret = Get-TightVncSecret

        ConvertTo-TestHex (ConvertTo-TightVncPasswordBytes -Password $secret.Password) | Should -Be 'D7A514D8C556AADE'
        Should -Invoke Read-Host -Times 2 -Exactly
    }

    It 'Does not ask when TightVNC Server already has its passwords' {
        Mock Get-TightVncServerSettings { @{ KeyExists = $true; Password = [byte[]](1..8); UseVncAuthentication = 1; ControlPassword = [byte[]](11..18); UseControlAuthentication = 1 } }

        Initialize-TightVncSecretForRun -Apps @($script:CatalogEntry)
        $secret = Get-TightVncSecret

        $secret.Password | Should -BeNullOrEmpty
        Should -Invoke Read-Host -Times 0 -Exactly
    }

    It 'Does not ask in a non-interactive run, and the hook does not ask mid-run either' {
        Initialize-TightVncSecretForRun -Apps @($script:CatalogEntry) -NonInteractive
        $secret = Get-TightVncSecret

        $secret.Password | Should -BeNullOrEmpty
        Should -Invoke Read-Host -Times 0 -Exactly
    }

    It 'Drops the passwords an earlier run in this console kept' {
        [System.Environment]::SetEnvironmentVariable($script:PasswordVariable, 'Secure!')
        Initialize-TightVncSecretForRun -Apps @($script:CatalogEntry) -NonInteractive

        Initialize-TightVncSecretForRun -Apps @($script:CatalogEntry) -NonInteractive

        $script:TightVncSecret.Password | Should -BeNullOrEmpty
    }

    It 'Says in a dry run whether the passwords are set, never their values, and leaves them in place' {
        [System.Environment]::SetEnvironmentVariable($script:PasswordVariable, 'Secure!-Longer')

        Initialize-TightVncSecretForRun -Apps @($script:CatalogEntry) -WhatIf

        [System.Environment]::GetEnvironmentVariable($script:PasswordVariable) | Should -Be 'Secure!-Longer'
        $script:TightVncSecret | Should -BeNullOrEmpty
        Should -Invoke Read-Host -Times 0 -Exactly
        $all = ($script:infoMessages + $script:warningMessages) -join "`n"
        $all | Should -Match '\[DRY-RUN\] TightVNC: a real run would set the server password from WINGET_APP_SETUP_TIGHTVNC_PASSWORD \(value not shown\)\. It is longer than 8 characters'
        $all | Should -Match 'WINGET_APP_SETUP_TIGHTVNC_CONTROL_PASSWORD is not set: a real run would protect the control interface with the server password'
        $all | Should -Not -Match 'Secure!'
    }

    It 'Says in a dry run why a password could not be used' {
        [System.Environment]::SetEnvironmentVariable($script:ControlVariable, "pa$([char]0x00E4)ss")

        Initialize-TightVncSecretForRun -Apps @($script:CatalogEntry) -WhatIf -NonInteractive

        ($script:warningMessages -join "`n") | Should -Match 'WINGET_APP_SETUP_TIGHTVNC_CONTROL_PASSWORD is set \(value not shown\), but a real run could not use it: The TightVNC password must use printable ASCII'
        ($script:warningMessages -join "`n") | Should -Match 'WINGET_APP_SETUP_TIGHTVNC_PASSWORD is not set: unless TightVNC Server already has its passwords, a real run would report TightVNC as installed but NOT configured'
    }
}

Describe 'Get-TightVncServerSettings' {
    It 'Reads the binary passwords and the authentication values' {
        Mock Test-Path { $true }
        Mock Get-ItemProperty { [pscustomobject]@{ Password = [byte[]](1..8); ControlPassword = [byte[]](11..18); UseVncAuthentication = 1; UseControlAuthentication = 0; RfbPort = 5900 } }

        $settings = Get-TightVncServerSettings

        $settings.KeyExists | Should -BeTrue
        $settings.Password | Should -Be ([byte[]](1..8))
        $settings.ControlPassword | Should -Be ([byte[]](11..18))
        $settings.UseVncAuthentication | Should -Be 1
        $settings.UseControlAuthentication | Should -Be 0
        Should -Invoke Get-ItemProperty -Times 1 -Exactly -ParameterFilter { $LiteralPath -eq 'HKLM:\SOFTWARE\TightVNC\Server' }
    }

    It 'Reads a value of the wrong type as missing' {
        Mock Test-Path { $true }
        Mock Get-ItemProperty { [pscustomobject]@{ Password = 'not binary'; UseVncAuthentication = '1' } }

        $settings = Get-TightVncServerSettings

        $settings.Password | Should -BeNullOrEmpty
        $settings.UseVncAuthentication | Should -BeNullOrEmpty
    }

    It 'Reads a key with no values as one without passwords' {
        Mock Test-Path { $true }
        Mock Get-ItemProperty { }

        $settings = Get-TightVncServerSettings

        $settings.KeyExists | Should -BeTrue
        $settings.Password | Should -BeNullOrEmpty
        Test-TightVncServerSecured -Settings $settings | Should -BeFalse
    }

    It 'Reports a missing key without reading it' {
        Mock Test-Path { $false }
        Mock Get-ItemProperty { throw 'must not read a missing key' }

        $settings = Get-TightVncServerSettings

        $settings.KeyExists | Should -BeFalse
        Test-TightVncServerSecured -Settings $settings | Should -BeFalse
    }
}

Describe 'Test-TightVncServerSecured' {
    It 'Is <Expected> when <Case>' -ForEach @(
        @{ Case = 'both passwords and both authentication values are set'; Expected = $true; Settings = @{ Password = [byte[]](1..8); UseVncAuthentication = 1; ControlPassword = [byte[]](11..18); UseControlAuthentication = 1 } }
        @{ Case = 'there is no control password'; Expected = $false; Settings = @{ Password = [byte[]](1..8); UseVncAuthentication = 1; ControlPassword = $null; UseControlAuthentication = 1 } }
        @{ Case = 'the control interface is not protected'; Expected = $false; Settings = @{ Password = [byte[]](1..8); UseVncAuthentication = 1; ControlPassword = [byte[]](11..18); UseControlAuthentication = 0 } }
        @{ Case = 'VNC authentication is off'; Expected = $false; Settings = @{ Password = [byte[]](1..8); UseVncAuthentication = 0; ControlPassword = [byte[]](11..18); UseControlAuthentication = 1 } }
        @{ Case = 'the password is not 8 bytes'; Expected = $false; Settings = @{ Password = [byte[]](1..9); UseVncAuthentication = 1; ControlPassword = [byte[]](11..18); UseControlAuthentication = 1 } }
    ) {
        Test-TightVncServerSecured -Settings $Settings | Should -Be $Expected
    }
}

Describe 'Get-TightVncServerKeyAclProblem' {
    It 'Accepts a key limited to SYSTEM and Administrators' {
        Mock Get-DirectoryAccessSummary {
            [pscustomobject]@{ OwnerSid = 'S-1-5-32-544'; OwnerName = 'BUILTIN\Administrators'; InheritanceProtected = $true; AccessRules = @(
                    [pscustomobject]@{ Sid = 'S-1-5-18'; Name = 'NT AUTHORITY\SYSTEM'; AccessControlType = 'Allow'; IsInherited = $false }
                    [pscustomobject]@{ Sid = 'S-1-5-32-544'; Name = 'BUILTIN\Administrators'; AccessControlType = 'Allow'; IsInherited = $false }
                )
            }
        }

        @(Get-TightVncServerKeyAclProblem) | Should -BeNullOrEmpty
        Should -Invoke Get-DirectoryAccessSummary -Times 1 -Exactly -ParameterFilter { $Path -eq 'HKLM:\SOFTWARE\TightVNC\Server' }
    }

    It 'Names every way other accounts could read it' {
        Mock Get-DirectoryAccessSummary {
            [pscustomobject]@{ OwnerSid = 'S-1-5-21-1-2-3-1001'; OwnerName = 'CONTOSO\user'; InheritanceProtected = $false; AccessRules = @(
                    [pscustomobject]@{ Sid = 'S-1-5-18'; Name = 'NT AUTHORITY\SYSTEM'; AccessControlType = 'Allow'; IsInherited = $true }
                    [pscustomobject]@{ Sid = 'S-1-5-32-545'; Name = 'BUILTIN\Users'; AccessControlType = 'Allow'; IsInherited = $true }
                )
            }
        }

        $problems = @(Get-TightVncServerKeyAclProblem)

        $problems | Should -Be @(
            'it is owned by CONTOSO\user (S-1-5-21-1-2-3-1001)'
            'it inherits permissions from its parent key'
            'BUILTIN\Users (S-1-5-32-545) has an access entry (allow)'
        )
    }
}

Describe 'Set-TightVncServerPassword (the GlavSoft.TightVNC post-install hook, review finding P2-22)' {
    BeforeEach {
        $script:TightVncSecret = $null
        Remove-Item -LiteralPath "Env:\$($script:PasswordVariable)" -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath "Env:\$($script:ControlVariable)" -ErrorAction SilentlyContinue

        # A fake HKLM\SOFTWARE\TightVNC\Server. Reads and writes copy the byte arrays, as the
        # registry does: the hook clears its own buffers before it returns.
        $script:keyExists = $false
        $script:registry = @{}
        $script:writes = @()
        Mock Test-Path { $script:keyExists } -ParameterFilter { $LiteralPath -eq 'HKLM:\SOFTWARE\TightVNC\Server' }
        Mock Test-Path { $false }
        Mock Get-ItemProperty {
            $copy = [ordered]@{}
            foreach ($name in $script:registry.Keys) {
                $value = $script:registry[$name]
                if ($value -is [byte[]]) {
                    $value = [byte[]]$value.Clone()
                }
                $copy[$name] = $value
            }
            [pscustomobject]$copy
        }
        Mock New-ItemProperty {
            $stored = $Value
            if ($stored -is [byte[]]) {
                $stored = [byte[]]$stored.Clone()
            }
            $script:registry[$Name] = $stored
            $script:writes += [pscustomobject]@{ Path = $LiteralPath; Name = $Name; Type = $PropertyType; Force = [bool]$Force }
            [pscustomobject]@{ $Name = $stored }
        }
        $script:aclProblems = @('it inherits permissions from its parent key')
        Mock Get-TightVncServerKeyAclProblem { $script:aclProblems }
        Mock Protect-TightVncServerKey { $script:keyExists = $true; $script:aclProblems = @() }

        $script:serviceStatus = 'Running'
        Mock Get-Service { [pscustomobject]@{ Name = 'tvnserver'; Status = $script:serviceStatus } }
        Mock Restart-Service { $script:serviceStatus = 'Running' }
        Mock Start-Service { $script:serviceStatus = 'Running' }

        Mock Test-EffectiveNonInteractive { $true }
        Mock Test-IsContinuousIntegration { $false }
        $script:answers = [System.Collections.Generic.Queue[string]]::new()
        Mock Read-Host { New-TestSecureString $script:answers.Dequeue() }

        $script:messages = @()
        Mock Write-Info { $script:messages += $Message }
        Mock Write-WarningMessage { $script:messages += $Message }
        Mock Write-Success { $script:messages += $Message }
        Mock Write-ErrorMessage { $script:messages += $Message }
        Mock Write-Host { $script:messages += "$Object" }
    }

    AfterEach {
        Remove-Item -LiteralPath "Env:\$($script:PasswordVariable)" -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath "Env:\$($script:ControlVariable)" -ErrorAction SilentlyContinue
    }

    It 'Is the GlavSoft.TightVNC catalog entry''s post-install hook' {
        $script:CatalogEntry.postInstall | Should -Be 'Set-TightVncServerPassword'
        $validation = Test-AppDefinitions -Apps @($script:CatalogEntry)
        @($validation.Errors).Count | Should -Be 0
        @($validation.Warnings).Count | Should -Be 0
    }

    It 'Reports TightVNC installed but NOT configured, loudly, when no password is supplied in a non-interactive run (the finding''s false success)' {
        $result = Invoke-AppPostInstall -App $script:CatalogEntry

        $result.Status | Should -Be 'NotConfigured'
        $result.Reason | Should -Be 'no server password was supplied; set WINGET_APP_SETUP_TIGHTVNC_PASSWORD or run the installer interactively, then run it again. TightVNC Server refuses every viewer until then'
        ($script:messages -join "`n") | Should -Match 'TightVNC installed but NOT configured: no server password was supplied, and TightVNC Server refuses every viewer until it has one\. To fix it, set WINGET_APP_SETUP_TIGHTVNC_PASSWORD'
        $script:writes | Should -BeNullOrEmpty
        Should -Invoke Protect-TightVncServerKey -Times 0 -Exactly
        Should -Invoke Restart-Service -Times 0 -Exactly
        Should -Invoke Read-Host -Times 0 -Exactly
    }

    It 'Sets both passwords from the environment, locks the key first, restarts the service and never shows the secret' {
        [System.Environment]::SetEnvironmentVariable($script:PasswordVariable, 'Secure!')
        [System.Environment]::SetEnvironmentVariable($script:ControlVariable, 'bar')
        Mock Protect-TightVncServerKey {
            # The key is locked before any password is written into it.
            $script:writes | Should -BeNullOrEmpty
            $script:keyExists = $true
            $script:aclProblems = @()
        }

        $result = Invoke-AppPostInstall -App $script:CatalogEntry

        $result.Status | Should -Be 'Configured'
        ConvertTo-TestHex $script:registry['Password'] | Should -Be 'D7A514D8C556AADE'
        ConvertTo-TestHex $script:registry['ControlPassword'] | Should -Be '9CA3F3686574F277'
        $script:registry['UseVncAuthentication'] | Should -Be 1
        $script:registry['UseControlAuthentication'] | Should -Be 1
        @($script:writes | ForEach-Object { '{0}:{1}' -f $_.Name, $_.Type }) | Should -Be @('Password:Binary', 'UseVncAuthentication:DWord', 'ControlPassword:Binary', 'UseControlAuthentication:DWord')
        @($script:writes | Where-Object { $_.Path -ne 'HKLM:\SOFTWARE\TightVNC\Server' }) | Should -BeNullOrEmpty
        Should -Invoke Protect-TightVncServerKey -Times 1 -Exactly
        Should -Invoke Restart-Service -Times 1 -Exactly -ParameterFilter { $Name -eq 'tvnserver' }
        Should -Invoke Start-Service -Times 0 -Exactly
        [System.Environment]::GetEnvironmentVariable($script:PasswordVariable) | Should -BeNullOrEmpty
        $all = $script:messages -join "`n"
        $all | Should -Match 'TightVNC: setting the server password from WINGET_APP_SETUP_TIGHTVNC_PASSWORD \(value not shown\)\.'
        $all | Should -Match 'wrote Password, UseVncAuthentication, ControlPassword, UseControlAuthentication \(values not shown\)'
        foreach ($secretText in @('Secure!', 'bar', 'D7A514D8C556AADE', '9CA3F3686574F277', '215 165 20 216')) {
            $all | Should -Not -Match ([regex]::Escape($secretText))
        }
        $all | Should -Not -Match 'no separate control password'
    }

    It 'Changes nothing on a re-run with the same secret' {
        $script:keyExists = $true
        $script:aclProblems = @()
        $script:registry = @{ Password = (ConvertFrom-TestHex 'D7A514D8C556AADE'); UseVncAuthentication = 1; ControlPassword = (ConvertFrom-TestHex '9CA3F3686574F277'); UseControlAuthentication = 1; RfbPort = 5900 }
        [System.Environment]::SetEnvironmentVariable($script:PasswordVariable, 'Secure!')
        [System.Environment]::SetEnvironmentVariable($script:ControlVariable, 'bar')

        $result = Set-TightVncServerPassword -App $script:CatalogEntry

        $result | Should -Be 'Configured'
        $script:writes | Should -BeNullOrEmpty
        Should -Invoke Protect-TightVncServerKey -Times 0 -Exactly
        Should -Invoke Restart-Service -Times 0 -Exactly
        Should -Invoke Start-Service -Times 0 -Exactly
        $script:messages | Should -Contain 'TightVNC: the server already has these passwords; nothing to change.'
    }

    It 'Updates the passwords on a re-run with a different secret' {
        $script:keyExists = $true
        $script:aclProblems = @()
        $script:registry = @{ Password = (ConvertFrom-TestHex 'D7A514D8C556AADE'); UseVncAuthentication = 1; ControlPassword = (ConvertFrom-TestHex '9CA3F3686574F277'); UseControlAuthentication = 1 }
        [System.Environment]::SetEnvironmentVariable($script:PasswordVariable, 'password')
        [System.Environment]::SetEnvironmentVariable($script:ControlVariable, '12345678')

        $result = Set-TightVncServerPassword -App $script:CatalogEntry

        $result | Should -Be 'Configured'
        @($script:writes.Name) | Should -Be @('Password', 'ControlPassword')
        ConvertTo-TestHex $script:registry['Password'] | Should -Be 'DBD83CFD727A1458'
        ConvertTo-TestHex $script:registry['ControlPassword'] | Should -Be 'F0E43164F6C2E373'
        Should -Invoke Restart-Service -Times 1 -Exactly
    }

    It 'Protects the control interface with the server password when no control password is supplied, and says so' {
        [System.Environment]::SetEnvironmentVariable($script:PasswordVariable, 'Secure!')

        $result = Set-TightVncServerPassword -App $script:CatalogEntry

        $result | Should -Be 'Configured'
        ConvertTo-TestHex $script:registry['ControlPassword'] | Should -Be 'D7A514D8C556AADE'
        $script:registry['UseControlAuthentication'] | Should -Be 1
        ($script:messages -join "`n") | Should -Match 'no separate control password was supplied \(WINGET_APP_SETUP_TIGHTVNC_CONTROL_PASSWORD\), so the server password also protects the control interface'
    }

    It 'Warns that TightVNC uses only the first 8 characters of a longer password' {
        [System.Environment]::SetEnvironmentVariable($script:PasswordVariable, 'P@ssw0rd-LongerThan8')
        [System.Environment]::SetEnvironmentVariable($script:ControlVariable, 'bar')

        $result = Set-TightVncServerPassword -App $script:CatalogEntry

        $result | Should -Be 'Configured'
        ConvertTo-TestHex $script:registry['Password'] | Should -Be '317C13DDB544C6C7'
        ($script:messages -join "`n") | Should -Match 'the server password from WINGET_APP_SETUP_TIGHTVNC_PASSWORD is longer than 8 characters\. TightVNC uses only the first 8'
        ($script:messages -join "`n") | Should -Not -Match 'LongerThan8'
    }

    It 'Reports a password TightVNC cannot use as NotConfigured, without showing it or writing anything' {
        [System.Environment]::SetEnvironmentVariable($script:PasswordVariable, "S$([char]0x00E9)cure")

        $result = Set-TightVncServerPassword -App $script:CatalogEntry

        $result.Status | Should -Be 'NotConfigured'
        $result.Reason | Should -Be 'the server password from WINGET_APP_SETUP_TIGHTVNC_PASSWORD cannot be used: The TightVNC password must use printable ASCII characters only (letters, digits, punctuation and spaces).'
        $script:writes | Should -BeNullOrEmpty
        ($script:messages -join "`n") | Should -Not -Match 'cure'
    }

    It 'Uses the password entered at the prompt when the hook runs on its own in an interactive session' {
        Mock Test-EffectiveNonInteractive { $false }
        $script:answers.Enqueue('Secure!')
        $script:answers.Enqueue('Secure!')

        $result = Set-TightVncServerPassword -App $script:CatalogEntry

        $result | Should -Be 'Configured'
        ConvertTo-TestHex $script:registry['Password'] | Should -Be 'D7A514D8C556AADE'
        ($script:messages -join "`n") | Should -Match 'setting the server password from the password entered at the prompt \(value not shown\)'
    }

    It 'Reports a skipped prompt as NotConfigured' {
        Mock Test-EffectiveNonInteractive { $false }
        $script:answers.Enqueue('')

        $result = Set-TightVncServerPassword -App $script:CatalogEntry

        $result.Status | Should -Be 'NotConfigured'
        $result.Reason | Should -Match '^no server password was entered at the prompt; set WINGET_APP_SETUP_TIGHTVNC_PASSWORD'
        $script:writes | Should -BeNullOrEmpty
    }

    It 'Keeps the passwords TightVNC Server already has when none is supplied, without asking' {
        Mock Test-EffectiveNonInteractive { $false }
        $script:keyExists = $true
        $script:aclProblems = @()
        $script:registry = @{ Password = (ConvertFrom-TestHex 'D7A514D8C556AADE'); UseVncAuthentication = 1; ControlPassword = (ConvertFrom-TestHex '9CA3F3686574F277'); UseControlAuthentication = 1 }

        $result = Set-TightVncServerPassword -App $script:CatalogEntry

        $result | Should -Be 'Configured'
        $script:writes | Should -BeNullOrEmpty
        Should -Invoke Read-Host -Times 0 -Exactly
        Should -Invoke Restart-Service -Times 0 -Exactly
        ($script:messages -join "`n") | Should -Match 'already has a server password and a control password; keeping them'
    }

    It 'Locks the key of a server it keeps the passwords of, when other accounts can read it' {
        $script:keyExists = $true
        $script:aclProblems = @('BUILTIN\Users (S-1-5-32-545) has an access entry (allow)')
        $script:registry = @{ Password = (ConvertFrom-TestHex 'D7A514D8C556AADE'); UseVncAuthentication = 1; ControlPassword = (ConvertFrom-TestHex 'D7A514D8C556AADE'); UseControlAuthentication = 1 }

        $result = Set-TightVncServerPassword -App $script:CatalogEntry

        $result | Should -Be 'Configured'
        Should -Invoke Protect-TightVncServerKey -Times 1 -Exactly
        $script:writes | Should -BeNullOrEmpty
        ($script:messages -join "`n") | Should -Match 'the control password is the same as the server password'
    }

    It 'Does not take a server without both protections as configured: <Case>' -ForEach @(
        @{ Case = 'no control password'; Registry = @{ Password = [byte[]](1..8); UseVncAuthentication = 1 } }
        @{ Case = 'authentication off'; Registry = @{ Password = [byte[]](1..8); UseVncAuthentication = 0; ControlPassword = [byte[]](11..18); UseControlAuthentication = 1 } }
    ) {
        $script:keyExists = $true
        $script:aclProblems = @()
        $script:registry = $Registry

        $result = Set-TightVncServerPassword -App $script:CatalogEntry

        $result.Status | Should -Be 'NotConfigured'
        $script:writes | Should -BeNullOrEmpty
    }

    It 'Reports a PC without the TightVNC Server service as NotConfigured, without touching the registry' {
        Mock Get-Service { $null }
        [System.Environment]::SetEnvironmentVariable($script:PasswordVariable, 'Secure!')

        $result = Set-TightVncServerPassword -App $script:CatalogEntry

        $result.Status | Should -Be 'NotConfigured'
        $result.Reason | Should -Be 'the TightVNC Server service (tvnserver) is not installed, so there is no server to configure'
        Should -Invoke Get-ItemProperty -Times 0 -Exactly
        $script:writes | Should -BeNullOrEmpty
    }

    It 'Fails, without writing a password, when the key cannot be limited to SYSTEM and Administrators' {
        [System.Environment]::SetEnvironmentVariable($script:PasswordVariable, 'Secure!')
        Mock Protect-TightVncServerKey { $script:keyExists = $true }
        $script:aclProblems = @('BUILTIN\Users (S-1-5-32-545) has an access entry (allow)')

        $result = Set-TightVncServerPassword -App $script:CatalogEntry

        $result.Status | Should -Be 'Failed'
        $result.Reason | Should -Be 'could not limit HKLM:\SOFTWARE\TightVNC\Server to SYSTEM and Administrators: BUILTIN\Users (S-1-5-32-545) has an access entry (allow)'
        $script:writes | Should -BeNullOrEmpty
    }

    It 'Fails when locking the key throws' {
        [System.Environment]::SetEnvironmentVariable($script:PasswordVariable, 'Secure!')
        Mock Protect-TightVncServerKey { throw 'Requested registry access is not allowed.' }

        $result = Set-TightVncServerPassword -App $script:CatalogEntry

        $result.Status | Should -Be 'Failed'
        $result.Reason | Should -Be 'could not limit HKLM:\SOFTWARE\TightVNC\Server to SYSTEM and Administrators (Requested registry access is not allowed.)'
        $script:writes | Should -BeNullOrEmpty
    }

    It 'Fails when the values read back are not the ones written' {
        [System.Environment]::SetEnvironmentVariable($script:PasswordVariable, 'Secure!')
        Mock New-ItemProperty { $script:writes += [pscustomobject]@{ Name = $Name } }

        $result = Set-TightVncServerPassword -App $script:CatalogEntry

        $result.Status | Should -Be 'Failed'
        $result.Reason | Should -Be 'the values read back from HKLM:\SOFTWARE\TightVNC\Server are not the ones written'
        Should -Invoke Restart-Service -Times 0 -Exactly
    }

    It 'Starts the service instead of restarting it when it was not running' {
        [System.Environment]::SetEnvironmentVariable($script:PasswordVariable, 'Secure!')
        $script:serviceStatus = 'Stopped'

        $result = Set-TightVncServerPassword -App $script:CatalogEntry

        $result | Should -Be 'Configured'
        Should -Invoke Start-Service -Times 1 -Exactly -ParameterFilter { $Name -eq 'tvnserver' }
        Should -Invoke Restart-Service -Times 0 -Exactly
    }

    It 'Fails when the service does not end up running' {
        [System.Environment]::SetEnvironmentVariable($script:PasswordVariable, 'Secure!')
        Mock Restart-Service { $script:serviceStatus = 'Stopped' }

        $result = Set-TightVncServerPassword -App $script:CatalogEntry

        $result.Status | Should -Be 'Failed'
        $result.Reason | Should -Be 'the TightVNC Server service (tvnserver) is Stopped, not Running'
    }

    It 'Fails when the service cannot be restarted' {
        [System.Environment]::SetEnvironmentVariable($script:PasswordVariable, 'Secure!')
        Mock Restart-Service { throw 'Service tvnserver cannot be started.' }

        $result = Set-TightVncServerPassword -App $script:CatalogEntry

        $result.Status | Should -Be 'Failed'
        $result.Reason | Should -Be 'could not restart the TightVNC Server service (tvnserver) (Service tvnserver cannot be started.)'
    }

    It 'Writes no stray output, so its result is its only output' {
        [System.Environment]::SetEnvironmentVariable($script:PasswordVariable, 'Secure!')

        $output = @(Set-TightVncServerPassword -App $script:CatalogEntry)

        $output.Count | Should -Be 1
        $output[0] | Should -Be 'Configured'
    }
}

Describe 'Install-AppWithVerification runs the TightVNC hook once TightVNC is installed (review finding P2-22)' {
    BeforeEach {
        $script:TightVncSecret = $null
        Remove-Item -LiteralPath "Env:\$($script:PasswordVariable)" -ErrorAction SilentlyContinue
        $script:installed = $false
        Mock Test-WingetPackageInstalled { @{ Installed = $script:installed; TimedOut = $false; LaunchFailed = $false; LaunchError = $null; CheckFailed = $false; ExitCode = 0 } }
        Mock Install-WingetPackage { $script:installed = $true; @{ Success = $true; ExitCode = 0 } }
        Mock Get-Service { [pscustomobject]@{ Name = 'tvnserver'; Status = 'Running' } }
        Mock Test-Path { $false }
        Mock Get-ItemProperty { throw 'the key does not exist' }
        Mock Test-EffectiveNonInteractive { $true }
        Mock Write-Info { }
        Mock Write-WarningMessage { }
    }

    It 'Leaves a freshly installed TightVNC without a password installed but NotConfigured, instead of a plain success' {
        $outcome = Install-AppWithVerification -App $script:CatalogEntry -Applicable $true

        $outcome.Status | Should -Be 'Installed'
        $outcome.Configuration.Status | Should -Be 'NotConfigured'
        $outcome.Configuration.Reason | Should -Match 'no server password was supplied'
    }
}

Describe 'Protect-TightVncServerKey on Windows (real registry, a throwaway HKCU key)' -Skip:(-not $IsWindows) {
    BeforeAll {
        $script:testRoot = "Software\winget-app-setup-tests\$([guid]::NewGuid().ToString('N'))"
        $script:testSubKey = "$($script:testRoot)\Server"
        $script:testPath = "HKCU:\$($script:testSubKey)"
    }

    AfterAll {
        # The key now grants only SYSTEM and Administrators: give this account its access back (as
        # its owner it may change the access list), then remove the test keys.
        try {
            $hive = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser, [Microsoft.Win32.RegistryView]::Default)
            $key = $hive.OpenSubKey($script:testSubKey, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, [System.Security.AccessControl.RegistryRights]'ReadPermissions, ChangePermissions')
            if ($key) {
                $security = New-Object System.Security.AccessControl.RegistrySecurity
                $security.AddAccessRule((New-Object System.Security.AccessControl.RegistryAccessRule -ArgumentList @([System.Security.Principal.WindowsIdentity]::GetCurrent().User, 'FullControl', 'ContainerInherit', 'None', 'Allow')))
                $key.SetAccessControl($security)
                $key.Dispose()
            }
            $hive.DeleteSubKeyTree($script:testRoot, $false)
            $testsKey = $hive.OpenSubKey('Software\winget-app-setup-tests')
            if ($testsKey) {
                $empty = $testsKey.SubKeyCount -eq 0 -and $testsKey.ValueCount -eq 0
                $testsKey.Dispose()
                if ($empty) {
                    $hive.DeleteSubKey('Software\winget-app-setup-tests', $false)
                }
            }
            $hive.Dispose()
        }
        catch {
            Write-Warning "Could not remove the test key HKCU:\$($script:testRoot): $_"
        }
    }

    It 'Creates a missing key limited to SYSTEM and Administrators, and limits an existing key again' {
        Protect-TightVncServerKey -SubKey $script:testSubKey -Hive CurrentUser

        $summary = Get-DirectoryAccessSummary -Path $script:testPath
        $summary.InheritanceProtected | Should -BeTrue
        @($summary.AccessRules | ForEach-Object { $_.Sid } | Sort-Object) | Should -Be @('S-1-5-18', 'S-1-5-32-544')
        @($summary.AccessRules | Where-Object { $_.AccessControlType -ne 'Allow' -or $_.IsInherited }) | Should -BeNullOrEmpty

        # A second call finds the key and replaces its access list (it is already right here).
        { Protect-TightVncServerKey -SubKey $script:testSubKey -Hive CurrentUser } | Should -Not -Throw
        $again = Get-DirectoryAccessSummary -Path $script:testPath
        @($again.AccessRules | ForEach-Object { $_.Sid } | Sort-Object) | Should -Be @('S-1-5-18', 'S-1-5-32-544')
        $again.InheritanceProtected | Should -BeTrue
    }
}
