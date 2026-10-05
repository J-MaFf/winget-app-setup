# The catalog entry schema: the fields an entry may carry beyond its package id, and the helpers that
# read them (Get-DefaultAppCatalog documents the fields). Runs under Windows PowerShell 5.1 too: the
# uninstaller validates the catalog and decides applicability there.

<#
.SYNOPSIS
    Returns the names of the fields a catalog entry may carry.
.OUTPUTS
    [string[]]
#>
function Get-AppDefinitionFieldName {
    return @('name', 'install', 'installerType', 'condition', 'conditionDescription', 'msixName', 'scope', 'arch', 'postInstall', 'userPhase')
}

<#
.SYNOPSIS
    Returns the architectures a catalog entry's 'arch' list may name.
.DESCRIPTION
    Windows' processor architectures, spelled as Get-OSArchitecture returns them
    (System.Runtime.InteropServices.Architecture names). Compared without regard to case.
.OUTPUTS
    [string[]]
#>
function Get-AppDefinitionArchitectureName {
    return @('X86', 'X64', 'Arm', 'Arm64')
}

<#
.SYNOPSIS
    Checks a catalog entry's optional fields: scope, arch, postInstall and userPhase.
.DESCRIPTION
    An error makes the entry invalid, and the run stops with exit code 3 before it installs anything:
      - scope: not 'machine', 'user' or 'any'.
      - arch: empty, or a name Get-AppDefinitionArchitectureName does not list (a misspelt name
        would match no PC and skip the app everywhere).
      - postInstall: neither a scriptblock nor the name of a command that exists.
      - userPhase: not $true or $false.
    A field the schema does not know (Get-AppDefinitionFieldName) is a warning: the installer
    ignores it.
.PARAMETER App
    The catalog entry.
.PARAMETER Label
    How messages name the entry, e.g. "App entry at index 3 ('Contoso.App')".
.OUTPUTS
    [pscustomobject] @{ Errors = [string[]]; Warnings = [string[]] }
#>
function Get-AppDefinitionSchemaIssue {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$App,

        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    $errors = @()
    $warnings = @()

    if ($App.ContainsKey('scope')) {
        $scope = $App['scope']
        if (-not ($scope -is [string]) -or @('machine', 'user', 'any') -notcontains $scope) {
            $errors += "$Label has an invalid 'scope' value '$scope': use 'machine', 'user' or 'any'."
        }
    }

    if ($App.ContainsKey('arch')) {
        $knownArchitectures = Get-AppDefinitionArchitectureName
        $architectures = @($App['arch'] | Where-Object { $null -ne $_ })
        if ($architectures.Count -eq 0) {
            $errors += "$Label has an empty 'arch' list: name at least one of $($knownArchitectures -join ', ')."
        }
        foreach ($architecture in $architectures) {
            if (-not ($architecture -is [string]) -or $knownArchitectures -notcontains $architecture) {
                $errors += "$Label has an invalid 'arch' value '$architecture': use one or more of $($knownArchitectures -join ', ')."
            }
        }
    }

    if ($App.ContainsKey('postInstall')) {
        $hook = $App['postInstall']
        if ($hook -is [scriptblock]) {
            # Checked when it runs: Invoke-AppPostInstall.
        }
        elseif ($hook -is [string] -and -not [string]::IsNullOrWhiteSpace($hook)) {
            # A wildcard would let Get-Command match some other command; a hook names one exactly.
            if ($hook -match '[\*\?\[\]]' -or -not (Get-Command -Name $hook -ErrorAction SilentlyContinue)) {
                $errors += "$Label has a 'postInstall' value '$hook' that names no command of this installer."
            }
        }
        else {
            $errors += "$Label has an invalid 'postInstall' value: use a scriptblock or the name of a function."
        }
    }

    if ($App.ContainsKey('userPhase') -and -not ($App['userPhase'] -is [bool])) {
        $errors += "$Label has an invalid 'userPhase' value '$($App['userPhase'])': use `$true or `$false."
    }

    $knownFields = Get-AppDefinitionFieldName
    foreach ($key in @($App.Keys)) {
        if ($knownFields -notcontains $key) {
            $warnings += "$Label has an unknown field '$key', which the installer ignores."
        }
    }

    return [pscustomobject]@{
        Errors   = $errors
        Warnings = $warnings
    }
}

<#
.SYNOPSIS
    Returns a catalog entry's install scope in lower case: 'machine', 'user' or 'any' (no scope).
.PARAMETER App
    A validated catalog entry.
.OUTPUTS
    [string]
#>
function Get-AppInstallScope {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$App
    )

    $scope = [string]$App['scope']
    if ([string]::IsNullOrWhiteSpace($scope)) {
        return 'any'
    }
    return $scope.Trim().ToLowerInvariant()
}

<#
.SYNOPSIS
    Returns whether a catalog entry is per-user work, which a run as SYSTEM or under cross-user
    elevation defers before any winget call: 'UserScope', 'UserPhase' or $null.
.PARAMETER App
    A validated catalog entry.
.OUTPUTS
    [string] 'UserScope' (scope 'user', which wins when both are set), 'UserPhase', or $null.
#>
function Get-AppPerUserDeferReason {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$App
    )

    if ((Get-AppInstallScope -App $App) -eq 'user') {
        return 'UserScope'
    }
    if ($App['userPhase'] -eq $true) {
        return 'UserPhase'
    }
    return $null
}

<#
.SYNOPSIS
    Returns the text of a not-applicable skip, what follows 'not applicable: ', for both passes and
    the uninstaller.
.DESCRIPTION
    The entry's conditionDescription when it has one; otherwise, when its arch list does not
    include this PC's architecture, 'for <list> Windows only; this PC is <architecture>'; otherwise
    'condition not met'. Only for an entry Test-AppApplicability found not applicable.
.PARAMETER App
    A validated catalog entry.
.OUTPUTS
    [string]
#>
function Get-AppNotApplicableReason {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$App
    )

    if (-not [string]::IsNullOrWhiteSpace([string]$App['conditionDescription'])) {
        return [string]$App['conditionDescription']
    }
    if ($App.ContainsKey('arch') -and $null -ne $App['arch']) {
        $architecture = $null
        try {
            $architecture = Get-OSArchitecture
        }
        catch {
            # No answer: Test-AppApplicability treated the arch list as met, so the condition decided.
        }
        $allowed = @($App['arch'])
        if ($architecture -and $allowed -notcontains $architecture) {
            return ('for {0} Windows only; this PC is {1}' -f ($allowed -join ', '), $architecture)
        }
    }
    return 'condition not met'
}

<#
.SYNOPSIS
    Turns what a post-install hook returned into its result: Configured, NotConfigured or Failed.
.DESCRIPTION
    The hook's last output is its result, either the status as a string or an object with Status
    and Reason (case-insensitive). NotConfigured and Failed without a reason get 'no reason given'.
    Anything else, no output or $true included, is Failed: 'installed' never means 'configured' by
    default.
.PARAMETER Output
    Everything the hook wrote to the pipeline.
.OUTPUTS
    [hashtable] @{ Status = 'Configured' | 'NotConfigured' | 'Failed'; Reason = <string|$null> }
#>
function ConvertTo-AppPostInstallResult {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Output
    )

    $items = @($Output | Where-Object { $null -ne $_ })
    if ($items.Count -eq 0) {
        return @{ Status = 'Failed'; Reason = 'the post-install hook returned no result (expected Configured, NotConfigured or Failed)' }
    }

    $last = $items[$items.Count - 1]
    $status = $null
    $reason = $null
    if ($last -is [string]) {
        $status = $last
    }
    elseif ($last -is [System.Collections.IDictionary]) {
        $status = [string]$last['Status']
        $reason = [string]$last['Reason']
    }
    elseif ($null -ne $last.PSObject.Properties['Status']) {
        $status = [string]$last.Status
        if ($null -ne $last.PSObject.Properties['Reason']) {
            $reason = [string]$last.Reason
        }
    }

    $knownStatus = @('Configured', 'NotConfigured', 'Failed') | Where-Object { $_ -eq "$status".Trim() } | Select-Object -First 1
    if (-not $knownStatus) {
        $shown = "$status".Trim()
        if (-not $shown) {
            $shown = [string]$last
        }
        if ($shown.Length -gt 80) {
            $shown = $shown.Substring(0, 77) + '...'
        }
        return @{ Status = 'Failed'; Reason = ("the post-install hook returned '{0}', not Configured, NotConfigured or Failed" -f $shown) }
    }
    if ($knownStatus -eq 'Configured') {
        return @{ Status = 'Configured'; Reason = $null }
    }
    if ([string]::IsNullOrWhiteSpace($reason)) {
        $reason = 'no reason given'
    }
    return @{ Status = $knownStatus; Reason = $reason.Trim() }
}

<#
.SYNOPSIS
    Runs a catalog app's post-install hook and returns whether the app is configured.
.DESCRIPTION
    Install-AppWithVerification calls it once the app is installed, on every run that finds it (so
    a hook must be idempotent), never for an app skipped, deferred or failed, and never in a dry
    run. The hook ($App.postInstall, a scriptblock or a function name) gets the catalog entry as
    its one argument and runs in this run's account (SYSTEM in an RMM run), so a hook for the
    signed-in user's own settings belongs on a userPhase entry. A throw or a written error (the
    preference is Stop here) is Failed with its message. No time limit of its own: a hook that
    starts a process should use Invoke-ExternalProcess.
.PARAMETER App
    A validated catalog entry with a postInstall hook.
.OUTPUTS
    [hashtable] @{ Status = 'Configured' | 'NotConfigured' | 'Failed'; Reason = <string|$null> }
#>
function Invoke-AppPostInstall {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$App
    )

    Write-Info "Configuring: $($App.name)"
    $ErrorActionPreference = 'Stop'
    try {
        $output = @(& $App.postInstall $App)
    }
    catch {
        $message = "$($_.Exception.Message)".Trim()
        if (-not $message) {
            $message = 'the post-install hook failed without a message'
        }
        return @{ Status = 'Failed'; Reason = $message }
    }
    return (ConvertTo-AppPostInstallResult -Output $output)
}
