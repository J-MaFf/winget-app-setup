function Get-WindowsBuildNumber {
    <#
    .SYNOPSIS
        Returns the current Windows OS build number as an integer (e.g. 19045, 26100).
    .DESCRIPTION
        Wrapped in a function so callers (and tests) can reason about the build gate used to decide
        how to install the latest PowerShell: winget's machine-scope MSIX provisioning only works on
        build 26100 (Windows 11 24H2) and later (issue #166).
    #>
    return [int][System.Environment]::OSVersion.Version.Build
}

<#
.SYNOPSIS
    Checks whether a semicolon-delimited PATH-style list already contains a path entry.
.DESCRIPTION
    Windows paths are case-insensitive and trailing separators are not significant, so
    'C:\Program Files\Foo' and 'c:\program files\foo\' are the same directory. Each entry is
    compared to the target with trailing '\'/'/' trimmed, using OrdinalIgnoreCase, to keep
    repeated runs from appending duplicate PATH entries (issue #179).
.PARAMETER PathList
    The semicolon-delimited list to search (e.g. the value of $env:PATH).
.PARAMETER PathToCheck
    The path entry to look for.
#>
function Test-PathListContainsEntry {
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$PathList,

        [Parameter(Mandatory = $true)]
        [string]$PathToCheck
    )

    $normalizedTarget = $PathToCheck.TrimEnd('\', '/')
    foreach ($entry in ($PathList -split ';')) {
        if ([string]::Equals($entry.TrimEnd('\', '/'), $normalizedTarget, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

<#
.SYNOPSIS
    Reads the persistent PATH value for the given scope.
.DESCRIPTION
    Thin wrapper around [System.Environment]::GetEnvironmentVariable so callers (and tests)
    do not have to touch the unmockable static method directly.
.PARAMETER Scope
    'User' reads the per-user PATH; 'System' reads the machine PATH.
#>
function Get-PersistedEnvironmentPath {
    param (
        [Parameter(Mandatory = $true)]
        [ValidateSet('User', 'System')]
        [string]$Scope
    )

    $target = if ($Scope -eq 'System') { [System.EnvironmentVariableTarget]::Machine } else { [System.EnvironmentVariableTarget]::User }
    return [string][System.Environment]::GetEnvironmentVariable('PATH', $target)
}

<#
.SYNOPSIS
    Writes the persistent PATH value for the given scope.
.DESCRIPTION
    Thin wrapper around [System.Environment]::SetEnvironmentVariable so callers (and tests)
    do not have to touch the unmockable static method directly.
.PARAMETER Value
    The full PATH value to persist.
.PARAMETER Scope
    'User' writes the per-user PATH; 'System' writes the machine PATH.
#>
function Set-PersistedEnvironmentPath {
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value,

        [Parameter(Mandatory = $true)]
        [ValidateSet('User', 'System')]
        [string]$Scope
    )

    $target = if ($Scope -eq 'System') { [System.EnvironmentVariableTarget]::Machine } else { [System.EnvironmentVariableTarget]::User }
    [System.Environment]::SetEnvironmentVariable('PATH', $Value, $target)
}

<#
.SYNOPSIS
    Adds a specified path to the environment PATH variable.
.DESCRIPTION
    This function adds a specified path to the persistent PATH variable for either the user or the
    system scope (skipping case-insensitive/trailing-slash duplicates), and mirrors the change into
    the current process PATH so the new entry is usable in the same session.
.PARAMETER PathToAdd
    The path to add to the environment PATH variable.
.PARAMETER Scope
    The scope to which the path should be added. Valid values are 'User' and 'System'.
#>
function Add-ToEnvironmentPath {
    param (
        [Parameter(Mandatory = $true)]
        [string]$PathToAdd,

        [Parameter(Mandatory = $true)]
        [ValidateSet('User', 'System')]
        [string]$Scope
    )

    # Check if the path is already in the environment PATH variable
    if (-not (Test-PathInEnvironment -PathToCheck $PathToAdd -Scope $Scope)) {
        $persistedPath = Get-PersistedEnvironmentPath -Scope $Scope
        $newPersistedPath = if ([string]::IsNullOrEmpty($persistedPath)) { $PathToAdd } else { "$persistedPath;$PathToAdd" }
        Set-PersistedEnvironmentPath -Value $newPersistedPath -Scope $Scope

        # Mirror into the current process PATH so the entry is usable this session. Environment
        # variable values are capped at 32767 characters on Windows (not 2048 — issue #179).
        if (-not (Test-PathListContainsEntry -PathList $env:PATH -PathToCheck $PathToAdd)) {
            $newProcessPath = "$env:PATH;$PathToAdd"
            if ($newProcessPath.Length -le 32767) {
                $env:PATH = $newProcessPath
            }
            else {
                Write-WarningMessage 'Current process PATH would exceed the Windows environment variable limit (32767 chars). Path added to persistent environment but not to current session.'
            }
        }
    }
}

<#
.SYNOPSIS
    Checks if a specified path is in the environment PATH variable.
.DESCRIPTION
    This function checks if a specified path is in the persistent environment PATH variable for
    either the user or the system scope. Comparison is case-insensitive and ignores trailing
    path separators.
.PARAMETER PathToCheck
    The path to check in the environment PATH variable.
.PARAMETER Scope
    The scope in which to check the path. Valid values are 'User' and 'System'.
#>
function Test-PathInEnvironment {
    param (
        [Parameter(Mandatory = $true)]
        [string]$PathToCheck,

        [Parameter(Mandatory = $true)]
        [ValidateSet('User', 'System')]
        [string]$Scope
    )

    $envPath = Get-PersistedEnvironmentPath -Scope $Scope
    return Test-PathListContainsEntry -PathList $envPath -PathToCheck $PathToCheck
}

<#
.SYNOPSIS
    Converts a command string into an array of arguments, properly handling quoted arguments.
.DESCRIPTION
    This function takes a command string and splits it into individual arguments while
    correctly handling quoted strings that may contain spaces.
.PARAMETER Command
    The command string to convert
.RETURNS
    An array of parsed command arguments
#>
function ConvertTo-CommandArguments {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Command
    )

    $commandArgs = @()
    $currentArg = ''
    $inQuotes = $false
    $quoteChar = ''

    for ($i = 0; $i -lt $Command.Length; $i++) {
        $char = $Command[$i]

        if ($inQuotes) {
            if ($char -eq $quoteChar) {
                $inQuotes = $false
                $quoteChar = ''
            }
            else {
                $currentArg += $char
            }
        }
        elseif ($char -eq '"' -or $char -eq "'") {
            $inQuotes = $true
            $quoteChar = $char
        }
        elseif ($char -eq ' ') {
            if ($currentArg) {
                $commandArgs += $currentArg
                $currentArg = ''
            }
        }
        else {
            $currentArg += $char
        }
    }

    if ($currentArg) {
        $commandArgs += $currentArg
    }

    return $commandArgs
}

