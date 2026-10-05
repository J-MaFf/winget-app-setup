# The catalog entry schema (work-order item 38): the fields an app definition may carry beyond its
# package id, and the helpers that read them. Get-DefaultAppCatalog (Public/AppCatalog.ps1)
# documents every field for catalog authors; Test-AppDefinitions checks them with
# Get-AppDefinitionSchemaIssue before a run uses any of them, so a mistyped value stops the run
# with exit code 3 instead of misbehaving halfway through it. Runs under Windows PowerShell 5.1
# too: the uninstaller validates the catalog and decides applicability there.

<#
.SYNOPSIS
    Returns the names of the fields a catalog entry may carry.
.RETURNS
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
.RETURNS
    [string[]]
#>
function Get-AppDefinitionArchitectureName {
    return @('X86', 'X64', 'Arm', 'Arm64')
}

<#
.SYNOPSIS
    Checks a catalog entry's optional schema fields: scope, arch, postInstall and userPhase.
.DESCRIPTION
    Test-AppDefinitions calls this for every entry whose package id is valid. An error makes the
    entry invalid, and the run then stops with exit code 3 before it installs anything:
      - scope: 'machine', 'user' or 'any'.
      - arch: one architecture name or a list of them, each one of Get-AppDefinitionArchitectureName,
        and at least one. A misspelt name would otherwise match no PC and skip the app everywhere.
      - postInstall: a scriptblock, or the name of a command that exists (a function of this
        installer). A name that resolves to nothing would otherwise fail the app on every run
        after it installed.
      - userPhase: $true or $false.
    A field the schema does not know (Get-AppDefinitionFieldName) is a warning, not an error: the
    installer ignores it, so a misspelt optional field is reported instead of silently dropped.
.PARAMETER App
    The catalog entry.
.PARAMETER Label
    How messages name the entry, e.g. "App entry at index 3 ('Contoso.App')".
.RETURNS
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
    Returns a catalog entry's install scope: 'machine', 'user' or 'any'.
.DESCRIPTION
    'any' when the entry has no scope (today's behaviour: prefer a machine-wide install, and fall
    back to winget's default scope unless the run installs for the whole PC only). Lower case, so
    callers can compare it as they like.
.PARAMETER App
    A validated catalog entry.
.RETURNS
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
    Returns whether a catalog entry marks the app as per-user work, and why: 'UserScope', 'UserPhase'
    or $null.
.DESCRIPTION
    A run as SYSTEM or under cross-user elevation installs for the whole PC only, so it defers such
    an app before any winget call (Install-AppWithVerification): scope 'user' installs into one
    account's profile, and userPhase marks an app or setting that needs the signed-in user's own
    account. Any other run installs it as usual.
.PARAMETER App
    A validated catalog entry.
.RETURNS
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
    Returns the text of a not-applicable skip for a catalog entry: what follows 'not applicable: '.
.DESCRIPTION
    The one place the skip reason is worded, for the installer's two passes and the uninstaller.
    The entry's conditionDescription when it has one: it describes the entry's applicability gates,
    its arch list and its condition alike. Otherwise, when the entry's arch list does not include
    this PC's architecture, 'for <list> Windows only; this PC is <architecture>'. Otherwise
    'condition not met'. Call it only for an entry Test-AppApplicability found not applicable.
.PARAMETER App
    A validated catalog entry.
.RETURNS
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
    The last object the hook wrote is its result, so stray output from the commands it runs does not
    count. It is either the status as a string, or an object with a Status and a Reason (a hashtable
    or any object with those properties). The status is matched without regard to case.
    NotConfigured and Failed without a reason get 'no reason given'. Anything else, including no
    output at all or $true, is a hook that did not say whether the app is configured: Failed, with
    what it returned, so 'installed' never means 'configured' by default.
.PARAMETER Output
    Everything the hook wrote to the pipeline.
.RETURNS
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
    Install-AppWithVerification calls this once the app is installed: verified after its install,
    already installed, or already provisioned for every user, never for an app that was skipped as
    not applicable, deferred or failed, and never in a dry run. So a hook runs on every run that
    finds its app, and must be idempotent: it checks the setting and changes only what differs.

    The hook ($App.postInstall) is a scriptblock or the name of a function, called with the app's
    catalog entry as its one positional argument (param($App), or $args[0]). It runs in this run's
    account: SYSTEM in an RMM run, or the elevating admin under cross-user elevation, so a hook that
    configures the signed-in user's own settings belongs on an entry marked userPhase, which such a
    run defers. What it returns is read by ConvertTo-AppPostInstallResult. A hook that throws, or
    writes an error (the preference is Stop here, as for catalog conditions), is Failed with the
    error's message. It has no time limit of its own: a hook that starts a process should use
    Invoke-ExternalProcess.
.PARAMETER App
    A validated catalog entry with a postInstall hook.
.RETURNS
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
