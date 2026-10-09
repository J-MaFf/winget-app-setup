# Environment pre-flight checks: say in one line what keeps a run from working, before it starts
# down a path that cannot succeed. Each check sits where it can still act: Constrained Language Mode
# first in the entry script; a Group Policy execution policy right before each -File relaunch; and,
# once elevated, the proxy, a pending restart and App Installer's Group Policy for the account the
# run installs as (Invoke-EnvironmentPreflight). All read-only, so a dry run runs them too.

<#
.SYNOPSIS
    Returns the language mode PowerShell runs this code in ('FullLanguage', 'ConstrainedLanguage',
    'RestrictedLanguage' or 'NoLanguage'). A seam for tests; safe in every language mode and 5.1.
#>
function Get-PowerShellLanguageMode {
    return [string]$ExecutionContext.SessionState.LanguageMode
}

<#
.SYNOPSIS
    Says in one line, and returns $false, when PowerShell does not run in Full Language Mode.
.DESCRIPTION
    An application control policy (App Control for Business or AppLocker) runs untrusted scripts,
    such as this unsigned one, in Constrained Language Mode, which refuses the .NET calls the
    installer makes from its first lines; nothing can work around it. The entry script calls this
    first and stops with exit code 5. Uses only what every language mode allows, under 5.1 too.
.OUTPUTS
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
    PowerShell applies no Group Policy execution policy in such a process (HasGpScriptParent in its
    SecuritySupport), and Get-ScriptExecutionPolicyBlock follows it. Walks Win32_Process's
    ParentProcessId as PowerShell does, at most 32 steps, stopping at a parent that started after
    its child (a reused id). Best-effort and 5.1-safe: a failed query ends the walk and counts as no.
.OUTPUTS
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
    The installer relaunches itself with `-ExecutionPolicy Bypass -File <copy>` from the 5.1
    bootstrap (under pwsh) and for elevation (under Windows PowerShell). Group Policy's 'Turn on
    Script Execution' overrides the Process scope, so AllSigned or Restricted refuses the relaunch;
    the irm | iex one-liner itself is not a file and gets that far. Read from the registry as
    PowerShell reads it, from either engine:
      WindowsPowerShell  HKLM, then HKCU: SOFTWARE\Policies\Microsoft\Windows\PowerShell.
      PowerShell7        HKLM, then HKCU: SOFTWARE\Policies\Microsoft\PowerShellCore, or the key
                         above when that key sets UseWindowsPowerShellPolicySetting.
    EnableScripts 0 is Restricted; 1 takes ExecutionPolicy (an unknown value counts as Restricted);
    without EnableScripts the key sets nothing. The first scope that sets a policy decides. Only
    AllSigned and Restricted block: the relaunched copies carry no internet zone mark for
    RemoteSigned to refuse. No block in a process gpscript.exe started
    (Test-LaunchedByGroupPolicyScript). powershell.config.json policies are not read.
.PARAMETER Engine
    'WindowsPowerShell' (powershell.exe) or 'PowerShell7' (pwsh.exe): the program that will run the
    script.
.OUTPUTS
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
    A machine policy refuses the elevated run whoever approves the UAC prompt; a user policy only
    when this same account approves it, which cannot be known before.
.PARAMETER Block
    Get-ScriptExecutionPolicyBlock -Engine WindowsPowerShell's result.
.OUTPUTS
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
    The per-user values under Software\Microsoft\Windows\CurrentVersion\Internet Settings:
    ProxyServer (only while ProxyEnable is 1), ProxyOverride and AutoConfigURL. A seam for tests.
.PARAMETER UserSid
    The account's SID, read under HKEY_USERS, where Windows loads a signed-in user's hive. Empty:
    this process's account (HKCU).
.OUTPUTS
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
    Returns $true when Group Policy makes the WinINet proxy one setting for the whole PC
    (ProxySettingsPerUser 0), which every account, SYSTEM included, then uses. A seam for tests.
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
    WinINet proxy settings are per account, so a run as SYSTEM or as another admin account does not
    use the user's, and on a network that only lets traffic out through it every download fails.
    The WinHTTP proxy and a per-machine WinINet proxy are shared by every account, so neither is
    reported. Quiet for a run as the signed-in user, when nobody is signed in, when the user's
    settings cannot be read or hold no proxy, and when this account has the same one.
.PARAMETER AccountContext
    Get-InstallAccountContext's result.
.OUTPUTS
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
    Invoke-WingetInstall runs it once elevated (or as SYSTEM), before the WAU wait and the winget
    setup. Read-only, so a dry run runs it too. In this order:
      1. Proxy (warning): Get-ProxyInheritanceWarning.
      2. Pending restart (warning): returned, so the end of the run can tell a restart its own
         installs need (exit code 3010) from this one.
      3. App Installer's Group Policy (stop): Get-WingetPolicyBlock; a real run stops with exit code
         2, since no repair can help. Initialize-Winget checks the same policy, so the line appears
         once.
    The warnings come first, so the line that stops the run is the last one.
.PARAMETER WhatIf
    Dry run: a policy block is reported with [DRY-RUN] and the exit code a real run would stop with,
    and the run goes on.
.PARAMETER AccountContext
    Get-InstallAccountContext's result; read here when not given.
.OUTPUTS
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
