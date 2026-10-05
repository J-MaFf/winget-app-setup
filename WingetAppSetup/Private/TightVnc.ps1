# TightVNC Server configuration (work-order item 18, review finding P2-22). winget installs
# GlavSoft.TightVNC (a machine-scope MSI) with no MSI properties, which registers and starts the
# tvnserver service and opens the firewall, but sets no password: the server then refuses every
# viewer ("Server is not configured properly"), and with no control password any signed-in user can
# reconfigure the service from its tray icon, including turning authentication off. The catalog's
# post-install hook (Set-TightVncServerPassword) sets both passwords from a secret supplied at run
# time, never from this public repository:
#   - WINGET_APP_SETUP_TIGHTVNC_PASSWORD and, optionally, WINGET_APP_SETUP_TIGHTVNC_CONTROL_PASSWORD
#     in the run's environment (an RMM script, or a tech's elevated console), read once at the start
#     of the run and removed from this process's environment before winget or any installer starts;
#   - otherwise, in an interactive run, a masked prompt at the start of the run;
#   - otherwise TightVNC is reported installed but NOT configured, loudly.
# The passwords go straight into HKLM\SOFTWARE\TightVNC\Server, which the service reads: never onto
# a command line (winget logs its whole command line, and MSI logs dump their properties), never to
# the console, the transcript or the run record. The stored value is reversible (VNC's fixed-key
# DES), so the key is limited to SYSTEM and Administrators before a password is written into it.
# Research notes: TightVNC 2.8.81 source (Configurator.cpp, VncPassCrypt.cpp, DesCrypt.cpp,
# ControlApplication.cpp), Microsoft's registry security docs; verified test vectors in
# tests/TightVnc.Tests.ps1.

<#
.SYNOPSIS
    Encodes a TightVNC password the way TightVNC stores it in the registry.
.DESCRIPTION
    VNC's password obfuscation, as TightVNC's ControlApplication::getCryptedPassword and
    VncPassCrypt do it: the first 8 characters, zero-padded to 8 bytes, encrypted with single DES
    in ECB mode under VNC's fixed key. TightVNC's d3des reads each key byte least significant bit
    first, so a standard DES implementation needs the bit-reversed key, E8 4A D6 60 C4 72 1A E0
    (TightVNC's own key is 17 52 6B 06 23 4E 58 07). Anyone who can read the 8 bytes can reverse
    them, so treat the result as the password itself: never print or log it, and clear it after
    use.

    Characters after the 8th are ignored, as TightVNC ignores them (the caller warns about it). The
    characters used must be printable ASCII: TightVNC converts them to the ANSI code page, where
    anything else may encode differently from what a viewer sends. The plaintext is read from the
    SecureString through a BSTR that is zeroed and freed before this returns; it is never a
    managed string. Uses only APIs that Windows PowerShell 5.1 has too.
.PARAMETER Password
    The password. Throws when it is empty or a character it uses is not printable ASCII; the
    message never contains the password.
.RETURNS
    [byte[]] 8 bytes.
#>
function ConvertTo-TightVncPasswordBytes {
    param (
        [Parameter(Mandatory = $true)]
        [System.Security.SecureString]$Password
    )

    if ($Password.Length -lt 1) {
        throw 'The TightVNC password is empty.'
    }
    $usedLength = [Math]::Min($Password.Length, 8)
    $plain = New-Object byte[] 8
    $bstr = [IntPtr]::Zero
    $des = $null
    $encryptor = $null
    try {
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
        for ($index = 0; $index -lt $usedLength; $index++) {
            $character = [System.Runtime.InteropServices.Marshal]::ReadInt16($bstr, 2 * $index)
            if ($character -lt 0x20 -or $character -gt 0x7E) {
                throw 'The TightVNC password must use printable ASCII characters only (letters, digits, punctuation and spaces).'
            }
            $plain[$index] = [byte]$character
        }
        $des = [System.Security.Cryptography.DES]::Create()
        $des.Mode = [System.Security.Cryptography.CipherMode]::ECB
        $des.Padding = [System.Security.Cryptography.PaddingMode]::None
        $des.Key = [byte[]](0xE8, 0x4A, 0xD6, 0x60, 0xC4, 0x72, 0x1A, 0xE0)
        $encryptor = $des.CreateEncryptor()
        $encoded = $encryptor.TransformFinalBlock($plain, 0, 8)
        return , $encoded
    }
    finally {
        [Array]::Clear($plain, 0, $plain.Length)
        if ($encryptor) {
            $encryptor.Dispose()
        }
        if ($des) {
            $des.Dispose()
        }
        if ($bstr -ne [IntPtr]::Zero) {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

<#
.SYNOPSIS
    Tells whether two SecureStrings hold the same text, without making either a managed string.
.PARAMETER First
    The first value.
.PARAMETER Second
    The second value.
.RETURNS
    [bool] False when either is $null or they differ.
#>
function Test-SecureStringEqual {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [System.Security.SecureString]$First,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [System.Security.SecureString]$Second
    )

    if ($null -eq $First -or $null -eq $Second -or $First.Length -ne $Second.Length) {
        return $false
    }
    $firstBstr = [IntPtr]::Zero
    $secondBstr = [IntPtr]::Zero
    try {
        $firstBstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($First)
        $secondBstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Second)
        $same = $true
        for ($index = 0; $index -lt $First.Length; $index++) {
            if ([System.Runtime.InteropServices.Marshal]::ReadInt16($firstBstr, 2 * $index) -ne [System.Runtime.InteropServices.Marshal]::ReadInt16($secondBstr, 2 * $index)) {
                $same = $false
            }
        }
        return $same
    }
    finally {
        if ($firstBstr -ne [IntPtr]::Zero) {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($firstBstr)
        }
        if ($secondBstr -ne [IntPtr]::Zero) {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($secondBstr)
        }
    }
}

<#
.SYNOPSIS
    Tells whether two byte arrays hold the same bytes.
.PARAMETER First
    The first array, or $null.
.PARAMETER Second
    The second array, or $null.
.RETURNS
    [bool] False when either is $null or they differ.
#>
function Test-TightVncBytesEqual {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [byte[]]$First,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [byte[]]$Second
    )

    if ($null -eq $First -or $null -eq $Second -or $First.Length -ne $Second.Length) {
        return $false
    }
    for ($index = 0; $index -lt $First.Length; $index++) {
        if ($First[$index] -ne $Second[$index]) {
            return $false
        }
    }
    return $true
}

<#
.SYNOPSIS
    Moves the TightVNC passwords from this process's environment into the run's secret store.
.DESCRIPTION
    Reads WINGET_APP_SETUP_TIGHTVNC_PASSWORD and WINGET_APP_SETUP_TIGHTVNC_CONTROL_PASSWORD, keeps
    each one that is set and not empty as a read-only SecureString in $script:TightVncSecret, and
    removes both variables from this process's environment, so winget, msiexec and every other
    process this run starts afterwards does not inherit them. The process that started this one (an
    RMM agent, the Windows PowerShell 5.1 bootstrap) keeps its own copy for as long as it runs.
    Replaces any secret an earlier call stored.
#>
function Import-TightVncSecretFromEnvironment {
    $secret = @{
        Password              = $null
        PasswordSource        = $null
        ControlPassword       = $null
        ControlPasswordSource = $null
        PromptDone            = $false
        PromptReason          = $null
    }
    $variables = @(
        @{ Name = 'WINGET_APP_SETUP_TIGHTVNC_PASSWORD'; Value = 'Password'; Source = 'PasswordSource' },
        @{ Name = 'WINGET_APP_SETUP_TIGHTVNC_CONTROL_PASSWORD'; Value = 'ControlPassword'; Source = 'ControlPasswordSource' }
    )
    foreach ($variable in $variables) {
        $value = [System.Environment]::GetEnvironmentVariable($variable.Name)
        if ($null -eq $value) {
            continue
        }
        # Remove-Item, not SetEnvironmentVariable($name, $null): PowerShell passes $null to a .NET
        # string parameter as '', which on some platforms leaves the variable set, empty.
        Remove-Item -LiteralPath "Env:\$($variable.Name)" -ErrorAction SilentlyContinue
        if ($value.Length -gt 0) {
            $characters = $value.ToCharArray()
            $secure = New-Object System.Security.SecureString
            try {
                foreach ($character in $characters) {
                    $secure.AppendChar($character)
                }
            }
            finally {
                [Array]::Clear($characters, 0, $characters.Length)
            }
            $secure.MakeReadOnly()
            $secret[$variable.Value] = $secure
            $secret[$variable.Source] = $variable.Name
        }
        $value = $null
    }
    $script:TightVncSecret = $secret
}

<#
.SYNOPSIS
    Forgets the run's TightVNC passwords.
.DESCRIPTION
    Disposes the SecureStrings Import-TightVncSecretFromEnvironment or the prompt stored, so they do
    not outlive the run in a console that stays open (irm | iex). Invoke-WingetInstall calls it once
    no post-install hook can run any more, and before it reads them for a new run.
#>
function Clear-TightVncSecret {
    $secret = $script:TightVncSecret
    if ($secret) {
        foreach ($name in @('Password', 'ControlPassword')) {
            if ($secret[$name]) {
                $secret[$name].Dispose()
            }
        }
    }
    $script:TightVncSecret = $null
}

<#
.SYNOPSIS
    Asks the person at the console for the TightVNC server password, twice.
.DESCRIPTION
    Read-Host -AsSecureString shows '*' for each character and returns a SecureString (never
    -MaskInput, which returns plain text). An empty answer skips the password. A password TightVNC
    cannot use, or a confirmation that does not match, is asked for again, three times at most. A
    transcript records the prompt text but not what is typed.
.RETURNS
    [hashtable] @{ Password = <read-only SecureString, or $null>; Reason = <why there is none, or $null> }
#>
function Read-TightVncPasswordFromHost {
    Write-Info 'TightVNC Server refuses every viewer until it has a password. Type the password viewers will use (TightVNC uses only the first 8 characters), or press Enter to skip: TightVNC is then installed but NOT configured. The same password protects its control interface unless WINGET_APP_SETUP_TIGHTVNC_CONTROL_PASSWORD is set.'
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $first = Read-Host -Prompt 'TightVNC server password' -AsSecureString
        if ($null -eq $first -or $first.Length -eq 0) {
            return @{ Password = $null; Reason = 'no server password was entered at the prompt' }
        }
        $problem = $null
        try {
            $check = ConvertTo-TightVncPasswordBytes -Password $first
            [Array]::Clear($check, 0, $check.Length)
        }
        catch {
            $problem = $_.Exception.Message
        }
        if ($problem) {
            $first.Dispose()
            Write-WarningMessage "$problem Try again."
            continue
        }
        $second = Read-Host -Prompt 'Type the TightVNC server password again' -AsSecureString
        $same = Test-SecureStringEqual -First $first -Second $second
        if ($second) {
            $second.Dispose()
        }
        if ($same) {
            $first.MakeReadOnly()
            return @{ Password = $first; Reason = $null }
        }
        $first.Dispose()
        Write-WarningMessage 'The two passwords do not match. Try again.'
    }
    return @{ Password = $null; Reason = 'no usable server password was entered at the prompt (3 tries)' }
}

<#
.SYNOPSIS
    Returns the run's TightVNC passwords, reading them from the environment, or asking for the
    server password, when that has not happened yet.
.DESCRIPTION
    Reads the environment first (Import-TightVncSecretFromEnvironment) when nothing has been read
    in this run. Without a server password from there, asks for one (Read-TightVncPasswordFromHost)
    only when all of these hold: no prompt has been offered in this run yet, someone is at the
    console (-NonInteractive not set), the run is not under CI, and TightVNC Server does not
    already have its passwords (-ServerSecured not set). The answer is kept for the rest of the run,
    so a retry of the post-install hook does not ask again.
.PARAMETER NonInteractive
    The run is non-interactive: never prompt.
.PARAMETER ServerSecured
    TightVNC Server already has a server password and a control password: no prompt is needed.
.RETURNS
    [hashtable] $script:TightVncSecret: Password, PasswordSource, ControlPassword,
    ControlPasswordSource, PromptDone and PromptReason.
#>
function Get-TightVncSecret {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive,

        [Parameter(Mandatory = $false)]
        [switch]$ServerSecured
    )

    if ($null -eq $script:TightVncSecret) {
        Import-TightVncSecretFromEnvironment
    }
    $secret = $script:TightVncSecret
    if ($null -eq $secret.Password -and -not $secret.PromptDone -and -not $ServerSecured -and -not $NonInteractive -and -not (Test-IsContinuousIntegration)) {
        $secret.PromptDone = $true
        $answer = Read-TightVncPasswordFromHost
        if ($answer.Password) {
            $secret.Password = $answer.Password
            $secret.PasswordSource = 'the password entered at the prompt'
        }
        else {
            $secret.PromptReason = $answer.Reason
        }
    }
    return $secret
}

<#
.SYNOPSIS
    Reads TightVNC Server's password settings from the registry.
.DESCRIPTION
    HKLM\SOFTWARE\TightVNC\Server, which the tvnserver service reads (application mode uses HKCU
    instead). Password and ControlPassword are REG_BINARY values of 8 bytes; UseVncAuthentication
    and UseControlAuthentication are REG_DWORD, 1 for on. A value of another type, or missing,
    reads as $null. The password bytes are reversible: never print them.
.PARAMETER Path
    The key, for tests.
.RETURNS
    [hashtable] KeyExists, Password ([byte[]] or $null), UseVncAuthentication ([int] or $null),
    ControlPassword, UseControlAuthentication. Throws when the key exists but cannot be read.
#>
function Get-TightVncServerSettings {
    param (
        [Parameter(Mandatory = $false)]
        [string]$Path = 'HKLM:\SOFTWARE\TightVNC\Server'
    )

    $settings = @{
        KeyExists                = $false
        Password                 = $null
        UseVncAuthentication     = $null
        ControlPassword          = $null
        UseControlAuthentication = $null
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        return $settings
    }
    $settings.KeyExists = $true
    $values = Get-ItemProperty -LiteralPath $Path -ErrorAction Stop
    if ($null -eq $values) {
        # A key with no values at all.
        return $settings
    }
    foreach ($name in @('Password', 'ControlPassword')) {
        $property = $values.PSObject.Properties[$name]
        if ($property -and $property.Value -is [byte[]]) {
            $settings[$name] = [byte[]]$property.Value
        }
    }
    foreach ($name in @('UseVncAuthentication', 'UseControlAuthentication')) {
        $property = $values.PSObject.Properties[$name]
        if ($property -and ($property.Value -is [int] -or $property.Value -is [uint32])) {
            $settings[$name] = [int]$property.Value
        }
    }
    return $settings
}

<#
.SYNOPSIS
    Tells whether TightVNC Server has a server password and a password-protected control interface.
.PARAMETER Settings
    Get-TightVncServerSettings's result.
.RETURNS
    [bool] True when Password and ControlPassword are 8-byte values and UseVncAuthentication and
    UseControlAuthentication are both 1.
#>
function Test-TightVncServerSecured {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [hashtable]$Settings
    )

    if ($null -eq $Settings) {
        return $false
    }
    foreach ($name in @('Password', 'ControlPassword')) {
        $value = $Settings[$name]
        if (-not ($value -is [byte[]]) -or $value.Length -ne 8) {
            return $false
        }
    }
    return ($Settings['UseVncAuthentication'] -eq 1 -and $Settings['UseControlAuthentication'] -eq 1)
}

<#
.SYNOPSIS
    Says why TightVNC Server's registry key is not limited to SYSTEM and Administrators.
.DESCRIPTION
    Reads the key's owner and access entries through Get-DirectoryAccessSummary (Get-Acl, which
    reads a registry key as it reads a folder). The key holds the reversible passwords, so any of
    these is a problem: an owner other than SYSTEM (S-1-5-18) or Administrators (S-1-5-32-544), who
    could rewrite the access list; permissions still inherited from HKLM\SOFTWARE, which usually
    let every user read it; an access entry for any other account.
.PARAMETER Path
    The key.
.RETURNS
    [string[]] One line per problem; empty when the key is limited as it should be. Throws when the
    access list cannot be read.
#>
function Get-TightVncServerKeyAclProblem {
    param (
        [Parameter(Mandatory = $false)]
        [string]$Path = 'HKLM:\SOFTWARE\TightVNC\Server'
    )

    $allowedSids = @('S-1-5-18', 'S-1-5-32-544')
    $security = Get-DirectoryAccessSummary -Path $Path
    $problems = @()
    if ($allowedSids -notcontains $security.OwnerSid) {
        $problems += "it is owned by $($security.OwnerName) ($($security.OwnerSid))"
    }
    if (-not $security.InheritanceProtected) {
        $problems += 'it inherits permissions from its parent key'
    }
    foreach ($rule in @($security.AccessRules)) {
        if ($allowedSids -notcontains $rule.Sid) {
            $problems += "$($rule.Name) ($($rule.Sid)) has an access entry ($("$($rule.AccessControlType)".ToLowerInvariant()))"
        }
    }
    return $problems
}

<#
.SYNOPSIS
    Creates TightVNC Server's registry key if it is missing and limits it to SYSTEM and
    Administrators.
.DESCRIPTION
    Thin seam over the .NET registry API (Windows-only, mocked in tests). The access list gets
    full control for SYSTEM (S-1-5-18; the tvnserver service runs as LocalSystem) and
    Administrators (S-1-5-32-544), by SID so it applies on any display language, and no entries
    inherited from HKLM\SOFTWARE, which otherwise let standard users read the reversible
    passwords. TightVNC's own service creates the key with SYSTEM and Administrators entries but
    does not block inheritance, and a key the MSI or this installer creates inherits the parent's
    entries, so neither is enough on its own.

    A missing key is created with that access list, so it is never readable by others, even
    briefly; its parent (HKLM\SOFTWARE\TightVNC) is created with the default one. An existing key
    is opened with the right to change its permissions only, and its access list replaced (the
    owner is left alone). The key is in the registry view of this process, which for 64-bit
    PowerShell is the one the 64-bit tvnserver reads.
.PARAMETER SubKey
    The key under the hive.
.PARAMETER Hive
    HKEY_LOCAL_MACHINE, or another hive for tests.
#>
function Protect-TightVncServerKey {
    param (
        [Parameter(Mandatory = $false)]
        [string]$SubKey = 'SOFTWARE\TightVNC\Server',

        [Parameter(Mandatory = $false)]
        [ValidateSet('LocalMachine', 'CurrentUser')]
        [string]$Hive = 'LocalMachine'
    )

    $security = New-Object System.Security.AccessControl.RegistrySecurity
    $security.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $rule = New-Object System.Security.AccessControl.RegistryAccessRule -ArgumentList @(
            (New-Object System.Security.Principal.SecurityIdentifier -ArgumentList $sid),
            [System.Security.AccessControl.RegistryRights]::FullControl,
            [System.Security.AccessControl.InheritanceFlags]::ContainerInherit,
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        $security.AddAccessRule($rule)
    }

    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]$Hive, [Microsoft.Win32.RegistryView]::Default)
    $key = $null
    $parent = $null
    try {
        $key = $baseKey.OpenSubKey($SubKey, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, [System.Security.AccessControl.RegistryRights]'ReadKey, ChangePermissions')
        if ($null -ne $key) {
            $key.SetAccessControl($security)
            return
        }
        $separator = $SubKey.LastIndexOf('\')
        if ($separator -gt 0) {
            $parent = $baseKey.CreateSubKey($SubKey.Substring(0, $separator))
        }
        $key = $baseKey.CreateSubKey($SubKey, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, $security)
    }
    finally {
        if ($key) {
            $key.Dispose()
        }
        if ($parent) {
            $parent.Dispose()
        }
        $baseKey.Dispose()
    }
}

<#
.SYNOPSIS
    Reads the TightVNC passwords for a run from the environment, or asks for the server password,
    before anything is installed.
.DESCRIPTION
    Invoke-WingetInstall calls this once, after the elevation check and before winget or any
    installer starts, when the run's catalog has TightVNC's post-install hook
    (postInstall = 'Set-TightVncServerPassword'); otherwise it does nothing. It drops whatever an
    earlier run in this console kept, then:
      - moves WINGET_APP_SETUP_TIGHTVNC_PASSWORD and WINGET_APP_SETUP_TIGHTVNC_CONTROL_PASSWORD
        out of this process's environment (Import-TightVncSecretFromEnvironment), so no process
        this run starts inherits them;
      - without a server password from there, and when someone is at the console and TightVNC
        Server does not already have its passwords, asks for it now, so the rest of the run needs
        nobody (the post-install hook then never asks).
    A dry run changes nothing and asks nothing: it only says whether the variables are set and
    whether a real run could use them, never their values.
.PARAMETER Apps
    The run's catalog.
.PARAMETER NonInteractive
    The run's effective non-interactive state: never prompt.
.PARAMETER WhatIf
    Dry run.
#>
function Initialize-TightVncSecretForRun {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [array]$Apps,

        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive,

        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    $configuresTightVnc = @($Apps | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['postInstall'] -is [string] -and $_['postInstall'] -eq 'Set-TightVncServerPassword' }).Count -gt 0
    if (-not $configuresTightVnc) {
        return
    }

    if ($WhatIf) {
        Write-TightVncSecretPreview -NonInteractive:$NonInteractive
        return
    }

    Clear-TightVncSecret
    Import-TightVncSecretFromEnvironment
    $serverSecured = $false
    if ($null -eq $script:TightVncSecret.Password -and -not $NonInteractive) {
        # Only worth reading when a prompt could follow. Unreadable counts as not secured: the
        # post-install hook reads it again and says what is wrong.
        try {
            $serverSecured = Test-TightVncServerSecured -Settings (Get-TightVncServerSettings)
        }
        catch {
            $serverSecured = $false
        }
    }
    [void](Get-TightVncSecret -NonInteractive:$NonInteractive -ServerSecured:$serverSecured)
    # Decided for this run: the post-install hook uses what is there and never asks mid-run.
    $script:TightVncSecret.PromptDone = $true
}

<#
.SYNOPSIS
    Says, in a dry run, where a real run would get the TightVNC passwords, without their values.
.DESCRIPTION
    Reads the two variables without removing them, checks that TightVNC could use the server and
    control passwords, and prints one '[DRY-RUN] TightVNC: ...' line for each. Values are never
    shown: only whether each is set and, when it is not usable, why.
.PARAMETER NonInteractive
    The run's effective non-interactive state, for what a real run would do without a password.
#>
function Write-TightVncSecretPreview {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive
    )

    foreach ($entry in @(
            @{ Name = 'WINGET_APP_SETUP_TIGHTVNC_PASSWORD'; What = 'server password' },
            @{ Name = 'WINGET_APP_SETUP_TIGHTVNC_CONTROL_PASSWORD'; What = 'control password' }
        )) {
        $value = [System.Environment]::GetEnvironmentVariable($entry.Name)
        $isSet = -not [string]::IsNullOrEmpty($value)
        $problem = $null
        $longerThanEight = $false
        if ($isSet) {
            $longerThanEight = $value.Length -gt 8
            $characters = $value.ToCharArray()
            $secure = New-Object System.Security.SecureString
            try {
                foreach ($character in $characters) {
                    $secure.AppendChar($character)
                }
                $encoded = ConvertTo-TightVncPasswordBytes -Password $secure
                [Array]::Clear($encoded, 0, $encoded.Length)
            }
            catch {
                $problem = $_.Exception.Message
            }
            finally {
                [Array]::Clear($characters, 0, $characters.Length)
                $secure.Dispose()
            }
        }
        $value = $null

        if ($isSet -and $problem) {
            Write-WarningMessage "[DRY-RUN] TightVNC: $($entry.Name) is set (value not shown), but a real run could not use it: $problem"
        }
        elseif ($isSet) {
            $note = ''
            if ($longerThanEight) {
                $note = ' It is longer than 8 characters: TightVNC uses only the first 8.'
            }
            Write-Info "[DRY-RUN] TightVNC: a real run would set the $($entry.What) from $($entry.Name) (value not shown).$note"
        }
        elseif ($entry.What -eq 'control password') {
            Write-Info "[DRY-RUN] TightVNC: $($entry.Name) is not set: a real run would protect the control interface with the server password."
        }
        elseif ($NonInteractive) {
            Write-WarningMessage "[DRY-RUN] TightVNC: $($entry.Name) is not set: unless TightVNC Server already has its passwords, a real run would report TightVNC as installed but NOT configured."
        }
        else {
            Write-Info "[DRY-RUN] TightVNC: $($entry.Name) is not set: unless TightVNC Server already has its passwords, a real run would ask for the server password at its start."
        }
    }
}

<#
.SYNOPSIS
    TightVNC's post-install hook: sets the TightVNC Server password and control password from the
    run's secret, limits their registry key to SYSTEM and Administrators, and restarts the service.
.DESCRIPTION
    Work-order item 18 (review finding P2-22), run by Invoke-AppPostInstall once GlavSoft.TightVNC
    is installed, on every run that finds it (idempotent). Returns 'Configured', or NotConfigured or
    Failed with a reason, per the catalog's postInstall contract:

      - No tvnserver service (a viewer-only install): NotConfigured; there is no server to
        configure.
      - A server password from the run's secret (Get-TightVncSecret:
        WINGET_APP_SETUP_TIGHTVNC_PASSWORD, or the prompt at the start of an interactive run):
        Password is set to it and UseVncAuthentication to 1; ControlPassword to
        WINGET_APP_SETUP_TIGHTVNC_CONTROL_PASSWORD, or to the server password when that is not set
        (with a warning: a separate one is better), and UseControlAuthentication to 1, so a
        signed-in user cannot reconfigure or stop the service without it. Only values that differ
        are written, and the service is restarted only when one did, so a re-run with the same
        secret changes nothing and one with a new secret updates it. A password of more than 8
        characters is used, with a warning that TightVNC ignores the rest; one TightVNC cannot use
        (empty, not printable ASCII) is NotConfigured, and its value is never shown.
      - No server password supplied, and TightVNC Server already has both passwords with both
        authentication values on (an earlier run, or someone, set them): they are kept.
      - No server password supplied, and TightVNC Server lacks them: NotConfigured, with a loud
        'TightVNC installed but NOT configured' line saying how to supply one. The server refuses
        every viewer until then.

    Before a password is written, and whenever one is kept, the key is limited to SYSTEM and
    Administrators (Protect-TightVncServerKey) and checked (Get-TightVncServerKeyAclProblem): the
    stored value is reversible. The written values are read back and compared in memory, then the
    service is restarted (Restart-Service; started when it was not running), which makes it read
    them, and must end up Running. Not 'tvnserver -controlservice -reload': it needs the control
    pipe, and when it cannot connect it shows a message box that nobody can close in a SYSTEM run.
    A step that fails makes the result Failed with what failed, so the retry pass tries again.

    Never on a command line, never printed: the passwords, their encoded bytes, or the bytes already
    in the registry. Every buffer holding them is cleared before this returns.
.PARAMETER App
    The catalog entry (unused: the hook's contract passes it).
.RETURNS
    'Configured', or [hashtable] @{ Status = 'NotConfigured' | 'Failed'; Reason = <string> }.
#>
function Set-TightVncServerPassword {
    param (
        [Parameter(Mandatory = $false, Position = 0)]
        [AllowNull()]
        [object]$App
    )

    $keyPath = 'HKLM:\SOFTWARE\TightVNC\Server'
    $serviceName = 'tvnserver'
    $howToSupply = 'set WINGET_APP_SETUP_TIGHTVNC_PASSWORD (and, better, a different WINGET_APP_SETUP_TIGHTVNC_CONTROL_PASSWORD) in the environment of the run, for example in the RMM script, or run the installer interactively to be asked for it, then run the installer again'

    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if ($null -eq $service) {
        $reason = 'the TightVNC Server service (tvnserver) is not installed, so there is no server to configure'
        Write-WarningMessage "TightVNC installed but NOT configured: $reason."
        return @{ Status = 'NotConfigured'; Reason = $reason }
    }

    $settings = $null
    $after = $null
    $passwordBytes = $null
    $controlBytes = $null
    try {
        try {
            $settings = Get-TightVncServerSettings -Path $keyPath
        }
        catch {
            return @{ Status = 'Failed'; Reason = "could not read $keyPath ($($_.Exception.Message))" }
        }
        $serverSecured = Test-TightVncServerSecured -Settings $settings
        $secret = Get-TightVncSecret -NonInteractive:(Test-EffectiveNonInteractive) -ServerSecured:$serverSecured

        if ($secret.Password) {
            $source = $secret.PasswordSource
            try {
                $passwordBytes = ConvertTo-TightVncPasswordBytes -Password $secret.Password
            }
            catch {
                $reason = "the server password from $source cannot be used: $($_.Exception.Message)"
                Write-WarningMessage "TightVNC installed but NOT configured: $reason Fix it and run the installer again."
                return @{ Status = 'NotConfigured'; Reason = $reason }
            }
            if ($secret.Password.Length -gt 8) {
                Write-WarningMessage "TightVNC: the server password from $source is longer than 8 characters. TightVNC uses only the first 8: viewers must type those 8."
            }
            if ($secret.ControlPassword) {
                try {
                    $controlBytes = ConvertTo-TightVncPasswordBytes -Password $secret.ControlPassword
                }
                catch {
                    $reason = "the control password from $($secret.ControlPasswordSource) cannot be used: $($_.Exception.Message)"
                    Write-WarningMessage "TightVNC installed but NOT configured: $reason Fix it and run the installer again."
                    return @{ Status = 'NotConfigured'; Reason = $reason }
                }
                if ($secret.ControlPassword.Length -gt 8) {
                    Write-WarningMessage "TightVNC: the control password from $($secret.ControlPasswordSource) is longer than 8 characters. TightVNC uses only the first 8."
                }
                if (Test-TightVncBytesEqual -First $passwordBytes -Second $controlBytes) {
                    Write-WarningMessage 'TightVNC: the control password is the same as the server password. A different one is better: anyone who knows the server password can change the server settings from the TightVNC tray icon.'
                }
            }
            else {
                $controlBytes = [byte[]]$passwordBytes.Clone()
                Write-WarningMessage 'TightVNC: no separate control password was supplied (WINGET_APP_SETUP_TIGHTVNC_CONTROL_PASSWORD), so the server password also protects the control interface. A different control password is better: anyone who knows the server password can then change the server settings from the TightVNC tray icon.'
            }
            Write-Info "TightVNC: setting the server password from $source (value not shown)."
        }
        elseif (-not $serverSecured) {
            $why = 'no server password was supplied'
            if ($secret.PromptReason) {
                $why = $secret.PromptReason
            }
            Write-WarningMessage "TightVNC installed but NOT configured: $why, and TightVNC Server refuses every viewer until it has one. To fix it, $howToSupply."
            return @{ Status = 'NotConfigured'; Reason = "$why; set WINGET_APP_SETUP_TIGHTVNC_PASSWORD or run the installer interactively, then run it again. TightVNC Server refuses every viewer until then" }
        }
        else {
            Write-Info 'TightVNC: TightVNC Server already has a server password and a control password; keeping them. To change them, set WINGET_APP_SETUP_TIGHTVNC_PASSWORD (and WINGET_APP_SETUP_TIGHTVNC_CONTROL_PASSWORD) and run the installer again.'
        }

        # The key holds reversible passwords: limit it to SYSTEM and Administrators before writing
        # one into it, and keep it that way on every run.
        try {
            $aclProblems = @()
            if ($settings.KeyExists) {
                $aclProblems = @(Get-TightVncServerKeyAclProblem -Path $keyPath)
            }
            if (-not $settings.KeyExists -or $aclProblems.Count -gt 0) {
                Protect-TightVncServerKey
                $aclProblems = @(Get-TightVncServerKeyAclProblem -Path $keyPath)
                if ($aclProblems.Count -gt 0) {
                    return @{ Status = 'Failed'; Reason = ("could not limit {0} to SYSTEM and Administrators: {1}" -f $keyPath, ($aclProblems -join '; ')) }
                }
                Write-Info "TightVNC: limited $keyPath to SYSTEM and Administrators, so other accounts cannot read the stored passwords."
            }
        }
        catch {
            return @{ Status = 'Failed'; Reason = "could not limit $keyPath to SYSTEM and Administrators ($($_.Exception.Message))" }
        }

        $changed = @()
        if ($passwordBytes) {
            $desired = @(
                @{ Name = 'Password'; Value = $passwordBytes; Type = 'Binary' },
                @{ Name = 'UseVncAuthentication'; Value = 1; Type = 'DWord' },
                @{ Name = 'ControlPassword'; Value = $controlBytes; Type = 'Binary' },
                @{ Name = 'UseControlAuthentication'; Value = 1; Type = 'DWord' }
            )
            try {
                foreach ($value in $desired) {
                    $current = $settings[$value.Name]
                    $same = $false
                    if ($value.Type -eq 'Binary') {
                        $same = Test-TightVncBytesEqual -First $current -Second $value.Value
                    }
                    else {
                        $same = $current -eq $value.Value
                    }
                    if (-not $same) {
                        New-ItemProperty -LiteralPath $keyPath -Name $value.Name -Value $value.Value -PropertyType $value.Type -Force -ErrorAction Stop | Out-Null
                        $changed += $value.Name
                    }
                }
                $after = Get-TightVncServerSettings -Path $keyPath
            }
            catch {
                return @{ Status = 'Failed'; Reason = "could not write the passwords to $keyPath ($($_.Exception.Message))" }
            }
            $readBackMatches = (Test-TightVncBytesEqual -First $after.Password -Second $passwordBytes) -and
                (Test-TightVncBytesEqual -First $after.ControlPassword -Second $controlBytes) -and
                $after.UseVncAuthentication -eq 1 -and $after.UseControlAuthentication -eq 1
            if (-not $readBackMatches) {
                return @{ Status = 'Failed'; Reason = "the values read back from $keyPath are not the ones written" }
            }
        }
        elseif (Test-TightVncBytesEqual -First $settings.Password -Second $settings.ControlPassword) {
            Write-WarningMessage 'TightVNC: the control password is the same as the server password. A different one (WINGET_APP_SETUP_TIGHTVNC_CONTROL_PASSWORD) is better: anyone who knows the server password can change the server settings from the TightVNC tray icon.'
        }

        # The service reads the key when it starts: restart it when a value changed, and start it
        # when it is not running.
        try {
            if ($changed.Count -gt 0) {
                if ("$($service.Status)" -eq 'Running') {
                    Restart-Service -Name $serviceName -ErrorAction Stop
                }
                else {
                    Start-Service -Name $serviceName -ErrorAction Stop
                }
                Write-Info ("TightVNC: wrote {0} (values not shown) and restarted the TightVNC Server service." -f ($changed -join ', '))
            }
            else {
                if ($passwordBytes) {
                    Write-Info 'TightVNC: the server already has these passwords; nothing to change.'
                }
                if ("$($service.Status)" -ne 'Running') {
                    Start-Service -Name $serviceName -ErrorAction Stop
                    Write-Info 'TightVNC: started the TightVNC Server service, which was not running.'
                }
            }
            $status = "$((Get-Service -Name $serviceName -ErrorAction Stop).Status)"
        }
        catch {
            return @{ Status = 'Failed'; Reason = "could not restart the TightVNC Server service (tvnserver) ($($_.Exception.Message))" }
        }
        if ($status -ne 'Running') {
            return @{ Status = 'Failed'; Reason = "the TightVNC Server service (tvnserver) is $status, not Running" }
        }
        return 'Configured'
    }
    finally {
        foreach ($buffer in @($passwordBytes, $controlBytes)) {
            if ($buffer) {
                [Array]::Clear($buffer, 0, $buffer.Length)
            }
        }
        foreach ($read in @($settings, $after)) {
            if ($read) {
                foreach ($name in @('Password', 'ControlPassword')) {
                    if ($read[$name]) {
                        [Array]::Clear($read[$name], 0, $read[$name].Length)
                    }
                }
            }
        }
    }
}
