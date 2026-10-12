# TightVNC Server configuration (P2-22). winget installs TightVNC with no password, so the server
# refuses every viewer, and with no control password any signed-in user can reconfigure it. The
# post-install hook (Set-TightVncServerPassword) sets both from a secret supplied at run time, never
# from this public repository: WINGET_APP_SETUP_TIGHTVNC_PASSWORD (and _CONTROL_PASSWORD), taken out
# of the environment at the start of the PowerShell 7 run before winget starts; otherwise a masked
# prompt at the start of an interactive run (5 minutes at most); otherwise TightVNC is reported NOT
# configured. The passwords go into HKLM\SOFTWARE\TightVNC\Server through the .NET registry API:
# never on a command line or as a cmdlet argument (module logging records those), never in the
# console, transcript or run record. The stored value is reversible (VNC's fixed-key DES), so the key
# is limited to SYSTEM and Administrators first. Sources: TightVNC 2.8.81 (Configurator.cpp,
# VncPassCrypt.cpp, DesCrypt.cpp, ControlApplication.cpp); test vectors in tests/TightVnc.Tests.ps1.

<#
.SYNOPSIS
    Encodes a TightVNC password the way TightVNC stores it in the registry.
.DESCRIPTION
    The first 8 characters, zero-padded to 8 bytes, encrypted with single DES (ECB) under VNC's
    fixed key. TightVNC's d3des reads key bytes least significant bit first, so standard DES needs
    the bit-reversed key E8 4A D6 60 C4 72 1A E0 (TightVNC's is 17 52 6B 06 23 4E 58 07). The result
    is as good as the password: never print or log it, and clear it after use. Characters past the
    8th are ignored, as TightVNC does. Only printable ASCII, since TightVNC converts to the ANSI code
    page. The plaintext goes through a BSTR that is zeroed and freed, never a managed string.
    Windows PowerShell 5.1 APIs only.
.PARAMETER Password
    The password. Throws when it is empty or a character it uses is not printable ASCII; the
    message never contains the password.
.OUTPUTS
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
.OUTPUTS
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
.OUTPUTS
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
    Keeps WINGET_APP_SETUP_TIGHTVNC_PASSWORD and WINGET_APP_SETUP_TIGHTVNC_CONTROL_PASSWORD, when set
    and not empty, as read-only SecureStrings in $script:TightVncSecret and removes both variables,
    so no process this run starts afterwards inherits them. The parent process, and processes
    started before this call, keep their copies. Replaces any earlier secret.
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
    Forgets the run's TightVNC passwords, so they do not outlive the run in a console that stays open
    (under irm | iex $script: is the console's global scope).
.DESCRIPTION
    Invoke-WingetInstall calls it once no hook can run, before its early returns, and before a new
    run reads them; the entry script's finally block calls it again for an aborted run.
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
    Waits until someone at the console starts typing, for at most a time limit.
.DESCRIPTION
    A seam over [Console]::KeyAvailable, polled a few times a second; no key is read, so it stays
    for Read-Host. Keeps an unwatched console from holding the run, and the run lock (exit 6 for
    every other run), past the limit. Returns $true at once when the console cannot be watched.
.PARAMETER TimeoutSeconds
    How long to wait.
.OUTPUTS
    [bool] $true when a key is waiting (or the console cannot be watched), $false when the time
    ran out.
#>
function Wait-TightVncPromptAnswer {
    param (
        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds
    )

    try {
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        while (-not [System.Console]::KeyAvailable) {
            if ([DateTime]::UtcNow -ge $deadline) {
                return $false
            }
            Start-Sleep -Milliseconds 250
        }
        return $true
    }
    catch {
        return $true
    }
}

<#
.SYNOPSIS
    Asks the person at the console for the TightVNC server password, twice.
.DESCRIPTION
    Read-Host -AsSecureString (never -MaskInput, which returns plain text); a transcript records the
    prompt, not what is typed. Empty skips it; an unusable password or a mismatch is asked again,
    three times at most. Each time it first waits for typing to start (Wait-TightVncPromptAnswer,
    -TimeoutSeconds), so an unanswered prompt does not block other runs. A host started with
    -NonInteractive makes Read-Host throw, which is reported as the reason, not as an error.
.PARAMETER TimeoutSeconds
    How long to wait for someone to start typing. Default 300 (5 minutes).
.OUTPUTS
    [hashtable] @{ Password = <read-only SecureString, or $null>; Reason = <why there is none, or $null> }
#>
function Read-TightVncPasswordFromHost {
    param (
        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 300
    )

    $minutes = [Math]::Max(1, [int][Math]::Round($TimeoutSeconds / 60))
    Write-Info ("TightVNC Server needs a password before viewers can connect, and a control password so that signed-in users cannot reconfigure it. Type the password viewers will use (TightVNC uses only the first 8 characters), or press Enter to skip: TightVNC is then installed but NOT configured. Nothing typed within {0} minutes counts as skipping. The same password protects the control interface unless WINGET_APP_SETUP_TIGHTVNC_CONTROL_PASSWORD is set or TightVNC Server already has a separate control password." -f $minutes)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Write-Host -NoNewline 'TightVNC server password: '
        if (-not (Wait-TightVncPromptAnswer -TimeoutSeconds $TimeoutSeconds)) {
            Write-Host ''
            return @{ Password = $null; Reason = ('nobody answered the TightVNC password prompt within {0} minutes' -f $minutes) }
        }
        $first = $null
        $second = $null
        try {
            $first = Read-Host -AsSecureString
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
        }
        catch [System.Management.Automation.PSInvalidOperationException] {
            if ($first) {
                $first.Dispose()
            }
            Write-Host ''
            return @{ Password = $null; Reason = "the password could not be asked for ($($_.Exception.Message.Trim()))" }
        }
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
    Reads the environment first, once per run. Without a server password from there it asks only
    when no prompt was offered in this run yet, someone is at the console, the run is not under CI,
    TightVNC Server lacks its passwords and PowerShell was not started with -NonInteractive. The
    answer is kept for the run, so a retry of the hook does not ask again.
.PARAMETER NonInteractive
    The run is non-interactive: never prompt.
.PARAMETER ServerSecured
    TightVNC Server already has a server password and a control password: no prompt is needed.
.OUTPUTS
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
        if (Test-PowerShellHostNonInteractive) {
            $secret.PromptReason = 'no server password was supplied, and PowerShell was started with -NonInteractive, so none could be asked for'
        }
        else {
            $answer = Read-TightVncPasswordFromHost
            if ($answer.Password) {
                $secret.Password = $answer.Password
                $secret.PasswordSource = 'the password entered at the prompt'
            }
            else {
                $secret.PromptReason = $answer.Reason
            }
        }
    }
    return $secret
}

<#
.SYNOPSIS
    Returns the name of the registry value that marks a TightVNC Server restart still owed.
.DESCRIPTION
    A REG_DWORD 1 written before a password value changes and removed once tvnserver has restarted,
    which is when it reads its passwords. Left behind by a failed or interrupted restart, it makes
    the next attempt restart the service although the values are already right. TightVNC ignores it.
.OUTPUTS
    [string]
#>
function Get-TightVncRestartMarkerName {
    return 'WingetAppSetupRestartPending'
}

<#
.SYNOPSIS
    Reads TightVNC Server's password settings from HKLM\SOFTWARE\TightVNC\Server, which the
    tvnserver service reads.
.DESCRIPTION
    Password and ControlPassword are 8-byte REG_BINARY; UseVncAuthentication and
    UseControlAuthentication are REG_DWORD, 1 for on. Another type, or none, reads as $null. The
    password bytes are reversible: never print them.
.PARAMETER Path
    The key, for tests.
.OUTPUTS
    [hashtable] KeyExists, Password ([byte[]] or $null), UseVncAuthentication ([int] or $null),
    ControlPassword, UseControlAuthentication, and RestartPending ([bool]: the restart marker,
    Get-TightVncRestartMarkerName, is 1). Throws when the key exists but cannot be read.
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
        RestartPending           = $false
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
    $marker = $values.PSObject.Properties[(Get-TightVncRestartMarkerName)]
    if ($marker -and ($marker.Value -is [int] -or $marker.Value -is [uint32]) -and [int]$marker.Value -eq 1) {
        $settings.RestartPending = $true
    }
    return $settings
}

<#
.SYNOPSIS
    Tells whether TightVNC Server has a server password and a password-protected control interface.
.PARAMETER Settings
    Get-TightVncServerSettings's result.
.OUTPUTS
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
    Says, in words, what a TightVNC Server that is not fully secured lets through, from the settings
    read, so the message never claims more than they show.
.DESCRIPTION
      - UseVncAuthentication not 1 (missing means on): it accepts every viewer without a password;
      - otherwise no 8-byte Password: it refuses every viewer;
      - no 8-byte ControlPassword, or UseControlAuthentication not 1: any signed-in user can
        reconfigure or stop it from its tray icon.
    A secured server with UseVncAuthentication missing gets 'UseVncAuthentication is not set to 1'.
.PARAMETER Settings
    Get-TightVncServerSettings's result.
.OUTPUTS
    [string[]] One clause per gap, each starting with a word that may begin a sentence or follow a
    semicolon; empty when Test-TightVncServerSecured holds.
#>
function Get-TightVncServerSecurityGap {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$Settings
    )

    if (Test-TightVncServerSecured -Settings $Settings) {
        return @()
    }
    $gaps = @()
    $hasPassword = $Settings['Password'] -is [byte[]] -and $Settings['Password'].Length -eq 8
    $hasControlPassword = $Settings['ControlPassword'] -is [byte[]] -and $Settings['ControlPassword'].Length -eq 8
    if ($null -ne $Settings['UseVncAuthentication'] -and $Settings['UseVncAuthentication'] -ne 1) {
        $gaps += 'VNC authentication is turned off (UseVncAuthentication), so TightVNC Server accepts every viewer WITHOUT a password'
    }
    elseif (-not $hasPassword) {
        $gaps += 'TightVNC Server has no password, so it refuses every viewer'
    }
    if (-not $hasControlPassword -or $Settings['UseControlAuthentication'] -ne 1) {
        $gaps += 'its control interface has no password, so any signed-in user can reconfigure or stop it from the TightVNC tray icon'
    }
    if ($gaps.Count -eq 0) {
        $gaps += 'UseVncAuthentication is not set to 1'
    }
    return $gaps
}

<#
.SYNOPSIS
    Says why TightVNC Server's registry key is not limited to SYSTEM and Administrators.
.DESCRIPTION
    Read with Get-DirectoryAccessSummary. Problems: an owner other than SYSTEM or Administrators
    (it could rewrite the access list); entries still inherited from HKLM\SOFTWARE (which usually let
    every user read the reversible passwords); an entry for any other account.
.PARAMETER Path
    The key.
.OUTPUTS
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
    A seam over the .NET registry API. Full control for SYSTEM (tvnserver runs as LocalSystem) and
    Administrators, by SID, and nothing inherited from HKLM\SOFTWARE; neither TightVNC's own key nor
    one the MSI creates blocks inheritance. A missing key is created with that list, so it is never
    readable by others even briefly (its parent with the default one); an existing key is opened
    with the right to change permissions only and its list replaced, owner untouched. In this
    process's registry view, which for 64-bit PowerShell is the 64-bit tvnserver's.
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
    Writes one value into TightVNC Server's registry key.
.DESCRIPTION
    A seam over RegistryKey.SetValue, not New-ItemProperty: module logging writes a cmdlet's
    parameter values (the reversible password bytes) to the event log, a .NET call it does not. The
    key must exist (Protect-TightVncServerKey), in this process's registry view.
.PARAMETER Name
    The value name.
.PARAMETER Value
    A [byte[]] for Binary, an [int] for DWord.
.PARAMETER Kind
    Binary or DWord.
.PARAMETER SubKey
    The key under the hive.
.PARAMETER Hive
    HKEY_LOCAL_MACHINE, or another hive for tests.
#>
function Set-TightVncServerValue {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [object]$Value,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Binary', 'DWord')]
        [string]$Kind,

        [Parameter(Mandatory = $false)]
        [string]$SubKey = 'SOFTWARE\TightVNC\Server',

        [Parameter(Mandatory = $false)]
        [ValidateSet('LocalMachine', 'CurrentUser')]
        [string]$Hive = 'LocalMachine'
    )

    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]$Hive, [Microsoft.Win32.RegistryView]::Default)
    $key = $null
    try {
        $key = $baseKey.OpenSubKey($SubKey, $true)
        if ($null -eq $key) {
            throw "the key $Hive\$SubKey does not exist"
        }
        $key.SetValue($Name, $Value, [Microsoft.Win32.RegistryValueKind]$Kind)
    }
    finally {
        if ($key) {
            $key.Dispose()
        }
        $baseKey.Dispose()
    }
}

<#
.SYNOPSIS
    Removes one value from TightVNC Server's registry key, if it is there: a seam over the .NET
    registry API. A missing key or value is not an error.
.PARAMETER Name
    The value name.
.PARAMETER SubKey
    The key under the hive.
.PARAMETER Hive
    HKEY_LOCAL_MACHINE, or another hive for tests.
#>
function Remove-TightVncServerValue {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $false)]
        [string]$SubKey = 'SOFTWARE\TightVNC\Server',

        [Parameter(Mandatory = $false)]
        [ValidateSet('LocalMachine', 'CurrentUser')]
        [string]$Hive = 'LocalMachine'
    )

    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]$Hive, [Microsoft.Win32.RegistryView]::Default)
    $key = $null
    try {
        $key = $baseKey.OpenSubKey($SubKey, $true)
        if ($key) {
            $key.DeleteValue($Name, $false)
        }
    }
    finally {
        if ($key) {
            $key.Dispose()
        }
        $baseKey.Dispose()
    }
}

<#
.SYNOPSIS
    Makes sure TightVNC Server's registry key is limited to SYSTEM and Administrators: when it is
    missing or others could read it, Protect-TightVncServerKey, then a second check.
.PARAMETER Path
    The key, as Get-TightVncServerSettings and Get-TightVncServerKeyAclProblem take it.
.PARAMETER KeyExists
    Get-TightVncServerSettings's KeyExists.
.OUTPUTS
    [string] $null when the key is limited as it should be, otherwise the reason it could not be
    (for a Failed result).
#>
function Set-TightVncServerKeyProtection {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [bool]$KeyExists
    )

    try {
        $aclProblems = @()
        if ($KeyExists) {
            $aclProblems = @(Get-TightVncServerKeyAclProblem -Path $Path)
        }
        if (-not $KeyExists -or $aclProblems.Count -gt 0) {
            Protect-TightVncServerKey
            $aclProblems = @(Get-TightVncServerKeyAclProblem -Path $Path)
            if ($aclProblems.Count -gt 0) {
                return ("could not limit {0} to SYSTEM and Administrators: {1}" -f $Path, ($aclProblems -join '; '))
            }
            Write-Info "TightVNC: limited $Path to SYSTEM and Administrators, so other accounts cannot read the stored passwords."
        }
    }
    catch {
        return "could not limit $Path to SYSTEM and Administrators ($($_.Exception.Message))"
    }
    return $null
}

<#
.SYNOPSIS
    Reads the TightVNC passwords for a run from the environment, or asks for the server password,
    before anything is installed.
.DESCRIPTION
    Invoke-WingetInstall calls it once, after the elevation check and before winget starts, when the
    catalog has TightVNC's hook. It drops what an earlier run in this console kept, moves the
    variables out of the environment so no installer inherits them, and, without a server password,
    asks now when someone is at the console and the server lacks its passwords, so the rest of the
    run needs nobody (5 minutes at most, since the run holds the lock). A dry run changes and asks
    nothing: it says whether the variables are set and usable, never their values.
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
    Says, in a dry run, where a real run would get the TightVNC passwords: one '[DRY-RUN] TightVNC:
    ...' line for each variable, set or not and usable or why not, never its value. Reads them
    without removing them.
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
    Runs on every run that finds GlavSoft.TightVNC installed, so it is idempotent. Per the catalog's
    postInstall contract:
      - No tvnserver service (a viewer-only install): NotConfigured.
      - A server password from the run's secret (Get-TightVncSecret): Password and
        UseVncAuthentication 1; ControlPassword from WINGET_APP_SETUP_TIGHTVNC_CONTROL_PASSWORD and
        UseControlAuthentication 1. Without that variable, a separate control password the server
        already has is kept; otherwise the server password protects control too, with a warning.
        Only differing values are written. Over 8 characters warns that TightVNC ignores the rest;
        an unusable password is NotConfigured, never shown.
      - No password supplied, and the server already secured: kept.
      - No password supplied, and the server not secured: NotConfigured, with a loud line that says
        what it lets through (Get-TightVncServerSecurityGap) and how to supply a password.
    The key is limited to SYSTEM and Administrators before a password is written and whenever it
    holds one. Values are written with Set-TightVncServerValue, read back and compared in memory.

    tvnserver reads its passwords only when it starts, so the service is restarted (or started when
    stopped) after a change, or when the restart marker says an earlier change never got its
    restart; the marker goes only once the service is Running again, so a failed restart is Failed
    and retried. Not 'tvnserver -controlservice -reload', which shows a message box nobody can close
    as SYSTEM. The passwords and their bytes are never on a command line or printed, and every
    buffer is cleared before this returns.
.PARAMETER App
    The catalog entry (unused: the hook's contract passes it).
.OUTPUTS
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
    $restartMarker = Get-TightVncRestartMarkerName
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
                # A separate control password the server already has is kept: the server password
                # there would give every viewer control. One equal to the server password follows it.
                $existingControl = $settings.ControlPassword
                $keepsControl = $existingControl -is [byte[]] -and $existingControl.Length -eq 8 -and
                    $settings.UseControlAuthentication -eq 1 -and
                    -not (Test-TightVncBytesEqual -First $existingControl -Second $settings.Password)
                if ($keepsControl) {
                    $controlBytes = [byte[]]$existingControl.Clone()
                    Write-Info 'TightVNC: no control password was supplied (WINGET_APP_SETUP_TIGHTVNC_CONTROL_PASSWORD); keeping the separate control password TightVNC Server already has.'
                    if (Test-TightVncBytesEqual -First $passwordBytes -Second $controlBytes) {
                        Write-WarningMessage 'TightVNC: the control password is the same as the server password. A different one is better: anyone who knows the server password can change the server settings from the TightVNC tray icon.'
                    }
                }
                else {
                    $controlBytes = [byte[]]$passwordBytes.Clone()
                    Write-WarningMessage 'TightVNC: no separate control password was supplied (WINGET_APP_SETUP_TIGHTVNC_CONTROL_PASSWORD), so the server password also protects the control interface. A different control password is better: anyone who knows the server password can then change the server settings from the TightVNC tray icon.'
                }
            }
            Write-Info "TightVNC: setting the server password from $source (value not shown)."
        }
        elseif (-not $serverSecured) {
            $why = 'no server password was supplied'
            if ($secret.PromptReason) {
                $why = $secret.PromptReason
            }
            $gaps = @(Get-TightVncServerSecurityGap -Settings $settings)
            # A password already in the key (a partly configured server) is reversible: limit the
            # key even though nothing is written now.
            if ($null -ne $settings.Password -or $null -ne $settings.ControlPassword) {
                $protectionProblem = Set-TightVncServerKeyProtection -Path $keyPath -KeyExists ([bool]$settings.KeyExists)
                if ($protectionProblem) {
                    return @{ Status = 'Failed'; Reason = $protectionProblem }
                }
            }
            $sentences = @($gaps | ForEach-Object { $_.Substring(0, 1).ToUpperInvariant() + $_.Substring(1) + '.' })
            Write-WarningMessage ("TightVNC installed but NOT configured: {0}. {1} To fix it, {2}." -f $why, ($sentences -join ' '), $howToSupply)
            return @{ Status = 'NotConfigured'; Reason = ("{0}; {1}; set WINGET_APP_SETUP_TIGHTVNC_PASSWORD or run the installer interactively, then run it again" -f $why, ($gaps -join '; ')) }
        }
        else {
            Write-Info 'TightVNC: TightVNC Server already has a server password and a control password; keeping them. To change them, set WINGET_APP_SETUP_TIGHTVNC_PASSWORD (and WINGET_APP_SETUP_TIGHTVNC_CONTROL_PASSWORD) and run the installer again.'
        }

        # The key holds reversible passwords: limit it to SYSTEM and Administrators before writing
        # one into it, and keep it that way on every run.
        $protectionProblem = Set-TightVncServerKeyProtection -Path $keyPath -KeyExists ([bool]$settings.KeyExists)
        if ($protectionProblem) {
            return @{ Status = 'Failed'; Reason = $protectionProblem }
        }

        $changed = @()
        if ($passwordBytes) {
            $desired = @(
                @{ Name = 'Password'; Value = $passwordBytes; Type = 'Binary' },
                @{ Name = 'UseVncAuthentication'; Value = 1; Type = 'DWord' },
                @{ Name = 'ControlPassword'; Value = $controlBytes; Type = 'Binary' },
                @{ Name = 'UseControlAuthentication'; Value = 1; Type = 'DWord' }
            )
            $toWrite = @()
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
                    $toWrite += $value
                }
            }
            try {
                if ($toWrite.Count -gt 0) {
                    # Before the first value: a restart is owed from here on, until one finishes.
                    Set-TightVncServerValue -Name $restartMarker -Value 1 -Kind 'DWord'
                    foreach ($value in $toWrite) {
                        Set-TightVncServerValue -Name $value.Name -Value $value.Value -Kind $value.Type
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

        # Restart when this call changed a value or an earlier restart never finished (the marker);
        # only a stopped service is merely started, since any other may have read the old values.
        $restartNeeded = $changed.Count -gt 0 -or [bool]$settings.RestartPending
        try {
            if ($restartNeeded) {
                if ("$($service.Status)" -eq 'Stopped') {
                    Start-Service -Name $serviceName -ErrorAction Stop
                }
                else {
                    Restart-Service -Name $serviceName -ErrorAction Stop
                }
                if ($changed.Count -gt 0) {
                    Write-Info ("TightVNC: wrote {0} (values not shown) and restarted the TightVNC Server service." -f ($changed -join ', '))
                }
                else {
                    Write-Info 'TightVNC: restarted the TightVNC Server service, which had not loaded the passwords written to it earlier (that restart failed or was interrupted).'
                }
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
        if ($restartNeeded) {
            try {
                Remove-TightVncServerValue -Name $restartMarker
            }
            catch {
                # Harmless: the next run restarts the service once more and tries again.
                Write-WarningMessage "TightVNC: could not remove the $restartMarker marker from $keyPath ($($_.Exception.Message)); the next run restarts the TightVNC Server service once more."
            }
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
