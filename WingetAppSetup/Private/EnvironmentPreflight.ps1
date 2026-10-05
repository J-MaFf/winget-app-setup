# Environment pre-flight checks (wgt-gq8.39): find what about this PC keeps a run from working,
# and say it in one line before the run starts down a path that cannot succeed, instead of a
# cascade of failures and wrong repairs. Each check sits where it can still act:
#   - Constrained Language Mode: first thing in the entry script (build/fragments/tail.ps1),
#     because the run breaks on its first .NET call, long before any later step (Test-FullLanguageMode).
#   - An execution policy set by Group Policy that refuses this unsigned script: right before each
#     relaunch with -File, the Windows PowerShell 5.1 bootstrap's under pwsh and the elevated
#     relaunch (Get-ScriptExecutionPolicyBlock; the elevated window checks again for the account
#     that approved the prompt, New-ElevationVerifierCommand).
#   - For the account the run installs as, once it is elevated (Invoke-EnvironmentPreflight): a
#     proxy the signed-in user has that SYSTEM or the elevating admin does not, a restart that is
#     already pending, and App Installer's Group Policy turning winget off.
# Every check is read-only, so a dry run (-WhatIf) runs them too.

<#
.SYNOPSIS
    Returns the language mode PowerShell runs this code in ('FullLanguage', 'ConstrainedLanguage',
    'RestrictedLanguage' or 'NoLanguage').
.DESCRIPTION
    A separate function so tests can mock it. Constrained Language Mode safe and Windows PowerShell
    5.1 safe: it reads one property and converts it to a string, which every language mode allows.
#>
function Get-PowerShellLanguageMode {
    return [string]$ExecutionContext.SessionState.LanguageMode
}

<#
.SYNOPSIS
    Says in one line, and returns $false, when PowerShell does not run in Full Language Mode.
.DESCRIPTION
    An application control policy (App Control for Business, formerly WDAC, or AppLocker) runs the
    scripts it does not trust in Constrained Language Mode, and this installer is not signed. That
    mode refuses .NET method calls and most .NET types, which the installer uses from its first
    lines on: before this check, such a run printed PowerShell's errors and then died further on,
    under PowerShell 7 in its pre-flight system checks with 'UNEXPECTED ERROR' and exit code 5. No
    step can work around it.

    The entry script calls this before anything else and stops with exit code 5 (the run is aborted
    before it starts; no other code in the table fits). Only constructs every language mode allows,
    under Windows PowerShell 5.1 too: Write-Host and string formatting.
.RETURNS
    [bool] True in Full Language Mode.
#>
function Test-FullLanguageMode {
    $mode = Get-PowerShellLanguageMode
    if ($mode -eq 'FullLanguage') {
        return $true
    }
    Write-ErrorMessage ('PowerShell runs this installer in {0} mode on this PC, which an application control policy (App Control for Business/WDAC or AppLocker) sets for scripts it does not trust. The installer needs FullLanguage mode, so it stops here with exit code 5 and changes nothing: run it on a PC without that policy, or ask whoever manages the policy to allow it.' -f $mode)
    return $false
}

<#
.SYNOPSIS
    Returns $true when Group Policy's script host (gpscript.exe) started this process, directly or
    through its parents: a startup, shutdown, logon or logoff script.
.DESCRIPTION
    PowerShell applies no Group Policy execution policy (the MachinePolicy and UserPolicy scopes) in
    such a process, so that a policy never blocks a Group Policy script: it looks for
    %SystemRoot%\System32\gpscript.exe among the process's parents (HasGpScriptParent in its
    SecuritySupport). Get-ScriptExecutionPolicyBlock follows it, so an installer deployed as a
    Group Policy script is not stopped for a policy that does not apply to it. This walks
    Win32_Process's ParentProcessId the same way, at most 32 steps, and stops at a parent that
    started after its child (a process that got a parent's reused id). Windows PowerShell 5.1 safe
    and best-effort: a query that fails ends the walk, as in PowerShell's own check, and counts as
    no.
.RETURNS
    [bool]
#>
function Test-LaunchedByGroupPolicyScript {
    try {
        $gpScriptPath = [System.IO.Path]::Combine([Environment]::GetFolderPath([Environment+SpecialFolder]::System), 'gpscript.exe')
        $processId = $PID
        $childStarted = $null
        for ($depth = 0; $depth -lt 32 -and $processId; $depth++) {
            $process = Get-CimInstance -ClassName Win32_Process -Filter ('ProcessId = {0}' -f $processId) -ErrorAction Stop
            if (-not $process) {
                break
            }
            if ($null -ne $childStarted -and $null -ne $process.CreationDate -and $process.CreationDate -gt $childStarted) {
                # Not the parent: a later process that got the parent's id.
                break
            }
            if ("$($process.ExecutablePath)" -eq $gpScriptPath) {
                return $true
            }
            $childStarted = $process.CreationDate
            $processId = $process.ParentProcessId
        }
    }
    catch {
        # Best-effort: a process that cannot be read ends the walk.
    }
    return $false
}

<#
.SYNOPSIS
    Returns the Group Policy execution policy that keeps PowerShell from running this unsigned
    script with -File, even with -ExecutionPolicy Bypass, or $null.
.DESCRIPTION
    The installer relaunches itself with `-ExecutionPolicy Bypass -File <copy>` twice: the Windows
    PowerShell 5.1 bootstrap under pwsh (Invoke-PowerShell7Bootstrap), and the elevated Windows
    PowerShell (Restart-WithElevation). -ExecutionPolicy sets the Process scope, and Group Policy's
    'Turn on Script Execution' (the MachinePolicy and UserPolicy scopes) overrides every other
    scope, so under 'Allow only signed scripts' (AllSigned) or with the setting Disabled
    (Restricted) the relaunch refuses the file and the run ended with a misleading exit code 1. The
    irm | iex one-liner itself is not a script file, so the policy does not stop it before then.

    Read from the registry the way PowerShell reads it, so it works for either engine from either
    engine (and under Windows PowerShell 5.1), including PowerShell's one exemption: no Group Policy
    execution policy applies to a process that Group Policy's script host gpscript.exe started,
    directly or through its children (a startup or logon script), so then there is no block
    (Test-LaunchedByGroupPolicyScript, checked only once a policy would block):
      WindowsPowerShell  HKLM, then HKCU: SOFTWARE\Policies\Microsoft\Windows\PowerShell.
      PowerShell7        HKLM, then HKCU: SOFTWARE\Policies\Microsoft\PowerShellCore, or the Windows
                         PowerShell key above when that key sets UseWindowsPowerShellPolicySetting
                         ('Use Windows PowerShell Policy setting'). Windows PowerShell's policy alone
                         does not apply to pwsh.
    In a key, EnableScripts 0 means Restricted, and EnableScripts 1 means the ExecutionPolicy value
    (a value PowerShell does not know counts as its default, Restricted); without EnableScripts the
    key sets nothing. The first scope that sets a policy decides: a machine policy of RemoteSigned
    wins over a user policy of AllSigned. Only AllSigned and Restricted refuse the script; the
    relaunched copies are written by the installer itself, so they carry no internet zone mark that
    RemoteSigned would refuse. PowerShell 7's powershell.config.json policies are not read.
.PARAMETER Engine
    'WindowsPowerShell' (powershell.exe) or 'PowerShell7' (pwsh.exe): the program that will run the
    script.
.RETURNS
    [pscustomobject] Engine, Scope ('MachinePolicy' or 'UserPolicy'), Policy ('AllSigned' or
    'Restricted'), Key (the registry key that set it), GroupPolicyPath (where to change it) and
    Description (one sentence for a message), or $null.
#>
function Get-ScriptExecutionPolicyBlock {
    param (
        [Parameter(Mandatory = $true)]
        [ValidateSet('WindowsPowerShell', 'PowerShell7')]
        [string]$Engine
    )

    $windowsKey = 'SOFTWARE\Policies\Microsoft\Windows\PowerShell'
    $coreKey = 'SOFTWARE\Policies\Microsoft\PowerShellCore'
    $engineName = 'Windows PowerShell'
    if ($Engine -eq 'PowerShell7') {
        $engineName = 'PowerShell 7'
    }

    $scopes = @(
        @{ Name = 'MachinePolicy'; Hive = 'HKLM'; Target = 'this PC'; Node = 'Computer Configuration' },
        @{ Name = 'UserPolicy'; Hive = 'HKCU'; Target = 'this account'; Node = 'User Configuration' }
    )
    foreach ($scope in $scopes) {
        $keyPath = $windowsKey
        $templatePath = 'Windows Components > Windows PowerShell'
        $templateNote = ''
        $values = $null
        if ($Engine -eq 'PowerShell7') {
            try {
                $values = Get-ItemProperty -LiteralPath ('{0}:\{1}' -f $scope.Hive, $coreKey) -ErrorAction Stop
            }
            catch {
                # No PowerShellCore policy key in this scope: it sets nothing for pwsh.
                continue
            }
            $keyPath = $coreKey
            $templatePath = 'PowerShell Core'
            $fallback = "$($values.UseWindowsPowerShellPolicySetting)"
            if ($fallback -and $fallback -ne '0') {
                $keyPath = $windowsKey
                $templatePath = 'Windows Components > Windows PowerShell'
                $templateNote = ', which PowerShell 7 follows through ''Use Windows PowerShell Policy setting'' under PowerShell Core'
                $values = $null
            }
        }

        if ($null -eq $values) {
            try {
                $values = Get-ItemProperty -LiteralPath ('{0}:\{1}' -f $scope.Hive, $keyPath) -ErrorAction Stop
            }
            catch {
                continue
            }
        }
        $enableScripts = "$($values.EnableScripts)"
        $policy = $null
        if ($enableScripts -eq '0') {
            $policy = 'Restricted'
        }
        elseif ($enableScripts -eq '1') {
            $policy = "$($values.ExecutionPolicy)".Trim()
        }
        if (-not $policy) {
            # This scope sets nothing; the next one may.
            continue
        }

        # This scope decides the policy for the engine: no later scope can change it.
        if (@('Bypass', 'Unrestricted', 'RemoteSigned') -contains $policy) {
            return $null
        }
        if ($policy -eq 'AllSigned') {
            $policy = 'AllSigned'
        }
        else {
            $policy = 'Restricted'
        }
        if (Test-LaunchedByGroupPolicyScript) {
            # A Group Policy script: PowerShell applies neither policy scope to it or its children,
            # so -ExecutionPolicy Bypass holds for the relaunch.
            return $null
        }
        $key = '{0}\{1}' -f $scope.Hive, $keyPath
        return [pscustomobject]@{
            Engine          = $Engine
            Scope           = $scope.Name
            Policy          = $policy
            Key             = $key
            GroupPolicyPath = '{0} > Administrative Templates > {1} > Turn on Script Execution{2}' -f $scope.Node, $templatePath, $templateNote
            Description     = 'Group Policy sets the {0} execution policy for {1} to {2} ({3}, {4})' -f $engineName, $scope.Target, $policy, $scope.Name, $key
        }
    }
    return $null
}

<#
.SYNOPSIS
    Says what a Windows PowerShell execution policy set by Group Policy does to the elevated relaunch.
.DESCRIPTION
    For Restart-WithElevation and Invoke-WingetInstall's dry run. The elevated program is always
    Windows PowerShell (powershell.exe), so only its policy matters here. A machine policy refuses
    the elevated run whoever approves the UAC prompt. A user policy is this account's: it refuses
    the elevated run only when this same account approves the prompt, which cannot be known before.
.PARAMETER Block
    Get-ScriptExecutionPolicyBlock -Engine WindowsPowerShell's result.
.RETURNS
    [string]
#>
function Format-ElevationPolicyBlockMessage {
    param (
        [Parameter(Mandatory = $true)]
        [object]$Block
    )

    if ($Block.Scope -eq 'MachinePolicy') {
        return ('{0}, which -ExecutionPolicy Bypass on the command line cannot override, so an elevated Windows PowerShell cannot run this script from a file. Ask whoever manages this PC''s policies to allow scripts ({1}), or start it from an elevated PowerShell 7 (pwsh) session, where it needs no relaunch.' -f $Block.Description, $Block.GroupPolicyPath)
    }
    return ('{0}, which -ExecutionPolicy Bypass on the command line cannot override: if this account approves the UAC prompt, the elevated Windows PowerShell cannot run this script from a file. Approve it with another administrator account, or ask whoever manages the policies to allow scripts ({1}).' -f $Block.Description, $Block.GroupPolicyPath)
}

<#
.SYNOPSIS
    Returns the security identifier (S-1-5-21-...) of an account name such as CONTOSO\jdoe, or $null.
.DESCRIPTION
    A separate function so tests can mock it. $null when the name cannot be translated (an unknown
    or deleted account, or off Windows).
#>
function Get-AccountSid {
    param (
        [Parameter(Mandatory = $true)]
        [string]$AccountName
    )

    try {
        $account = New-Object System.Security.Principal.NTAccount($AccountName)
        return $account.Translate([System.Security.Principal.SecurityIdentifier]).Value
    }
    catch {
        return $null
    }
}

<#
.SYNOPSIS
    Reads an account's Windows Internet (WinINet) proxy settings, or $null when they cannot be read.
.DESCRIPTION
    The per-user settings under Software\Microsoft\Windows\CurrentVersion\Internet Settings, which
    Settings > Network & Internet > Proxy, Internet Options and the Internet Explorer Group Policy
    settings write: ProxyServer (only while ProxyEnable is 1), with its bypass list ProxyOverride,
    and AutoConfigURL (a proxy auto-configuration script). A separate function so tests can mock it.
.PARAMETER UserSid
    The account's SID: its hive is read under HKEY_USERS, where Windows loads it while the user is
    signed in. Empty: the account this process runs as (HKCU).
.RETURNS
    [pscustomobject] ProxyServer, ProxyOverride and AutoConfigUrl (each '' when not set), or $null.
#>
function Get-WinInetProxySetting {
    param (
        [Parameter(Mandatory = $false)]
        [string]$UserSid
    )

    $path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    if ($UserSid) {
        $path = 'Registry::HKEY_USERS\{0}\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -f $UserSid
    }
    try {
        $values = Get-ItemProperty -LiteralPath $path -ErrorAction Stop
    }
    catch {
        return $null
    }

    $server = ''
    $override = ''
    if ("$($values.ProxyEnable)" -eq '1') {
        $server = "$($values.ProxyServer)".Trim()
        if ($server) {
            $override = "$($values.ProxyOverride)".Trim()
        }
    }
    return [pscustomobject]@{
        ProxyServer   = $server
        ProxyOverride = $override
        AutoConfigUrl = "$($values.AutoConfigURL)".Trim()
    }
}

<#
.SYNOPSIS
    Returns $true when Group Policy makes the Windows Internet proxy settings one setting for the
    whole PC ('Make proxy settings per-machine (rather than per-user)').
.DESCRIPTION
    HKLM\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Internet Settings, ProxySettingsPerUser
    0 (NetworkProxy CSP ProxySettingsPerUser). Every account, SYSTEM included, then uses the same
    proxy. A separate function so tests can mock it.
#>
function Test-ProxySettingsPerMachine {
    try {
        $values = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
    }
    catch {
        return $false
    }
    return ("$($values.ProxySettingsPerUser)" -eq '0')
}

<#
.SYNOPSIS
    Formats WinINet proxy settings for a message: 'proxy server proxy:8080 (bypass: <local>),
    automatic configuration script http://wpad/proxy.pac', or 'no proxy'.
#>
function Format-WinInetProxySetting {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Setting
    )

    $parts = @()
    if ($Setting -and $Setting.ProxyServer) {
        $server = 'proxy server {0}' -f $Setting.ProxyServer
        if ($Setting.ProxyOverride) {
            $server += ' (bypass: {0})' -f $Setting.ProxyOverride
        }
        $parts += $server
    }
    if ($Setting -and $Setting.AutoConfigUrl) {
        $parts += 'automatic configuration script {0}' -f $Setting.AutoConfigUrl
    }
    if ($parts.Count -eq 0) {
        return 'no proxy'
    }
    return ($parts -join ', ')
}

<#
.SYNOPSIS
    Returns a one-line warning when the signed-in user has a Windows Internet proxy that the account
    this run installs as does not have, or $null.
.DESCRIPTION
    The Windows Internet (WinINet) proxy settings belong to each account. A run as SYSTEM (an RMM
    agent) or as another admin account (cross-user elevation) reads its own, not the signed-in
    user's, so on a network that only lets traffic out through the proxy the user has, its downloads
    fail (winget's downloads and source update, the PowerShell 7 and Winget-AutoUpdate MSIs, the
    network pre-flight check). The WinHTTP proxy (netsh winhttp) is one setting for the whole PC, so
    every account already shares it, and so does a WinINet proxy that Group Policy makes per-machine
    (Test-ProxySettingsPerMachine): neither is reported.

    Quiet (returns $null) for a run as the signed-in user, when nobody is signed in, when the user's
    settings cannot be read, when the user has no proxy, and when this account has the same one.
.PARAMETER AccountContext
    Get-InstallAccountContext's result.
.RETURNS
    [string] e.g. "The signed-in user 'CONTOSO\jdoe' has a proxy in their Windows Internet settings
    (proxy server proxy.contoso.com:8080 (bypass: <local>)) that this run as SYSTEM does not use
    (SYSTEM has no proxy). ...", or $null.
#>
function Get-ProxyInheritanceWarning {
    param (
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$AccountContext
    )

    if ($null -eq $AccountContext -or -not ($AccountContext.IsSystem -or $AccountContext.IsCrossUserElevation)) {
        return $null
    }
    $sessionUser = "$($AccountContext.SessionUser)"
    if ([string]::IsNullOrWhiteSpace($sessionUser)) {
        return $null
    }
    if (Test-ProxySettingsPerMachine) {
        return $null
    }
    $sid = Get-AccountSid -AccountName $sessionUser
    if (-not $sid) {
        return $null
    }
    $userProxy = Get-WinInetProxySetting -UserSid $sid
    if (-not $userProxy -or -not ($userProxy.ProxyServer -or $userProxy.AutoConfigUrl)) {
        return $null
    }
    $ownProxy = Get-WinInetProxySetting
    if ($ownProxy -and $ownProxy.ProxyServer -eq $userProxy.ProxyServer -and $ownProxy.AutoConfigUrl -eq $userProxy.AutoConfigUrl) {
        return $null
    }

    $who = 'SYSTEM'
    if (-not $AccountContext.IsSystem) {
        $who = "'$($AccountContext.ProcessUser)'"
    }
    return ("The signed-in user '{0}' has a proxy in their Windows Internet settings ({1}) that this run as {2} does not use ({2} has {3}). On a network that only allows traffic through that proxy, downloads fail; if they do, give {2} the same proxy settings, or set the proxy for the whole PC, and re-run the installer." -f $sessionUser, (Format-WinInetProxySetting -Setting $userProxy), $who, (Format-WinInetProxySetting -Setting $ownProxy))
}

<#
.SYNOPSIS
    The pre-flight checks for the account a run installs as: one line per problem, and the exit code
    when the run cannot go on.
.DESCRIPTION
    Invoke-WingetInstall runs this once it is elevated (or runs as SYSTEM), before it waits for
    Winget-AutoUpdate or sets winget up (wgt-gq8.39). Read-only, so a dry run runs it too. In this
    order:
      1. Proxy (warning): the signed-in user's proxy that this account does not have
         (Get-ProxyInheritanceWarning).
      2. Pending restart (warning, review finding P3-16): a restart Windows already wants before
         the run. Its state is returned, and the end of the run compares against it, so a restart
         this run's installs need (exit code 3010) is told apart from this one.
      3. App Installer's Group Policy (stop, review finding P3-30): winget, its command line or its
         default source turned off (Get-WingetPolicyBlock). No repair can help, so a real run stops
         with exit code 2. Initialize-Winget checks the same policy first; a run that this check
         stops never gets there, and a dry run does not call it once this check has reported the
         policy, so the line appears once.
    The warnings come first, so the line that stops the run is the last one.
.PARAMETER WhatIf
    Dry run: a policy block is reported with [DRY-RUN] and the exit code a real run would stop with,
    and the run goes on.
.PARAMETER AccountContext
    Get-InstallAccountContext's result; read here when not given.
.RETURNS
    [pscustomobject] ExitCode (0, or 2 when a real run must stop), RestartState
    (Get-PendingRestartState's result, or $null), RestartPendingReasons ([string[]]) and
    WingetPolicyBlocked ([bool]).
#>
function Invoke-EnvironmentPreflight {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$AccountContext
    )

    if ($null -eq $AccountContext) {
        $AccountContext = Get-InstallAccountContext
    }

    $proxyWarning = $null
    try {
        $proxyWarning = Get-ProxyInheritanceWarning -AccountContext $AccountContext
    }
    catch {
        # Best-effort: a warning that cannot be worked out is not a reason to stop.
        $proxyWarning = $null
    }
    if ($proxyWarning) {
        Write-WarningMessage $proxyWarning
    }

    $restartState = $null
    try {
        $restartState = Get-PendingRestartState
    }
    catch {
        Write-WarningMessage "Could not check whether a restart is pending: $_"
    }
    $restartReasons = @(Get-PendingRestartReason -State $restartState)
    if ($restartReasons.Count -gt 0) {
        Write-WarningMessage ('A restart is already pending on this PC ({0}). An installer that needs a restart first fails with 0x8A15010A; if one does, restart this PC and re-run the installer.' -f ($restartReasons -join '; '))
    }

    $exitCode = 0
    $policy = Get-WingetPolicyBlock
    if ($policy) {
        Write-WingetPolicyBlockMessage -Block $policy -WhatIf:$WhatIf
        if (-not $WhatIf) {
            $exitCode = 2
        }
    }

    return [pscustomobject]@{
        ExitCode              = $exitCode
        RestartState          = $restartState
        RestartPendingReasons = $restartReasons
        WingetPolicyBlocked   = [bool]$policy
    }
}
