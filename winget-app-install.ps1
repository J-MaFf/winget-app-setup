<#PSScriptInfo

.VERSION 1.0.0

.GUID b5b5f614-90c3-42a9-94e3-b7dd6e6de262

.AUTHOR Joey Maffiola

.EXTERNALMODULEDEPENDENCIES winget, Microsoft.WinGet.Client

.TAGS winget, installation, automation

.PROJECTURI https://github.com/J-MaFf/winget-app-setup

.RELEASENOTES Initial version

.Changelog
    1.0.0 - This is the initial version of the script. It installs a list of programs using winget.
#>


<#
.SYNOPSIS
 Installs a list of programs using winget.

.DESCRIPTION
 This script installs a curated list of programs from winget. The authoritative
 list is the $apps array in Invoke-WingetInstall (WingetAppSetup/Public/Install.ps1,
 inlined below in this generated file). Run the script with -WhatIf to preview the
 exact set of planned installs without making any system changes.

.PARAMETER WhatIf
 When specified, performs all pre-flight checks and displays planned actions without making any system changes.

.PARAMETER SkipSystemCheck
 Bypasses the pre-flight system checks (OS version, disk space, network) for headless or automated use.

.PARAMETER NonInteractive
 Suppresses all interactive prompts (elevation pause, grid-view prompt, final "press any key") for
 unattended runs (RMM, CI, scheduled tasks). Also auto-detected when the session is non-interactive
 or stdin is redirected.
#>

param (
    [Parameter(Mandatory = $false)]
    [switch]$WhatIf,
    [Parameter(Mandatory = $false)]
    [switch]$SkipSystemCheck,
    [Parameter(Mandatory = $false)]
    [switch]$NonInteractive
)

# ------------------------------------------------------------------------------------------------
# GENERATED FILE - DO NOT EDIT BY HAND.
# This script is assembled from the WingetAppSetup module by build/Build-WingetInstallScript.ps1.
# Edit the function source under WingetAppSetup/Public and WingetAppSetup/Private, then re-run the
# build to regenerate this file. See readme.md ("Project layout") for details.
# ------------------------------------------------------------------------------------------------

# ------------------------------------------------Functions------------------------------------------------

# --- Elevation ---
<#
.SYNOPSIS
    Detects if the script is running locally or from a remote source (e.g., via IEX).
.DESCRIPTION
    Checks if $PSScriptRoot is non-empty and represents a valid directory.
    Returns $true for local execution (file on disk), $false for remote execution (piped script).
.RETURNS
    [bool] True if running locally, False if running remotely.
#>
function Test-IsRunningLocally {
    # Check if $PSScriptRoot is non-empty and valid
    if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        return $false
    }

    # Verify it's an actual directory path
    try {
        $null = Get-Item -LiteralPath $PSScriptRoot -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

<#
.SYNOPSIS
    Returns the account name the current process is running as (DOMAIN\user), or $null.
#>
function Get-ProcessUserName {
    try {
        return [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    }
    catch {
        return $null
    }
}

<#
.SYNOPSIS
    Returns the account name that owns the interactive console session (DOMAIN\user), or $null.
.DESCRIPTION
    Win32_ComputerSystem.UserName reports the interactively logged-on console user regardless of
    which account the current (possibly elevated) process runs as. Comparing it with
    Get-ProcessUserName detects cross-user elevation — running elevated as a different account
    than the logged-on user — where winget's per-user MSIX bootstrap is blocked by the AppX
    deployment service with 0x80073D19 because the process account has no interactive logon
    session (issue #159).
#>
function Get-InteractiveSessionUserName {
    try {
        $userName = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).UserName
        if ([string]::IsNullOrWhiteSpace($userName)) {
            return $null
        }
        return $userName
    }
    catch {
        return $null
    }
}

<#
.SYNOPSIS
    Detects whether Invoke-WingetInstall is executing from the WingetAppSetup module rather than
    the generated single-file installer.
.DESCRIPTION
    Auto-elevation relaunches $PSCommandPath. When Invoke-WingetInstall comes from the imported
    module, $PSCommandPath resolves to WingetAppSetup/Public/Install.ps1 — a functions-only file —
    so the elevated window would define a function and exit without installing anything
    (issue #185). Callers use this check to fail fast with guidance instead of silently
    relaunching a no-op.
.PARAMETER InvocationModule
    The caller's $MyInvocation.MyCommand.Module. Non-null when the function was invoked from an
    imported module.
.PARAMETER CommandPath
    The caller's $PSCommandPath. Matched against the module layout to also catch a dot-sourced
    WingetAppSetup/Public/Install.ps1, where the module info is null but the defining file is
    still functions-only.
.RETURNS
    [bool] True when running from module context (relaunching $PSCommandPath would be a no-op).
#>
function Test-InvokedFromModuleContext {
    param (
        [Parameter(Mandatory = $false)]
        [System.Management.Automation.PSModuleInfo]$InvocationModule,

        [Parameter(Mandatory = $false)]
        [string]$CommandPath
    )

    if ($null -ne $InvocationModule) {
        return $true
    }

    return [bool]($CommandPath -match '[\\/]WingetAppSetup[\\/]Public[\\/]Install\.ps1$')
}

<#
.SYNOPSIS
    Relaunches the script with elevated privileges, preferring Windows Terminal when available.
.DESCRIPTION
    Attempts to restart the current script in an elevated session. When Windows Terminal is installed,
    the script is relaunched inside an elevated Windows Terminal tab running the specified PowerShell
    executable. If Windows Terminal is unavailable or fails to start, the function falls back to the
    standard Start-Process call for the provided PowerShell executable.
.PARAMETER PowerShellExecutable
    The PowerShell executable to use when relaunching (for example, pwsh.exe or powershell.exe).
.PARAMETER ScriptPath
    The full path to the script that should be relaunched.
.PARAMETER WindowsTerminalExecutable
    Optional explicit path to the Windows Terminal executable (wt.exe). When not supplied, the
    function attempts to discover it automatically.
.PARAMETER AdditionalArguments
    Optional switches/arguments to forward to the elevated relaunch (for example, '-WhatIf'). These
    are appended after the -File argument so the elevated session inherits the caller's intent.
.RETURNS
    [string] Returns 'WindowsTerminal' when the Windows Terminal relaunch path succeeds, otherwise
    returns 'PowerShell'.
#>
function Restart-WithElevation {
    param (
        [Parameter(Mandatory = $true)]
        [string]$PowerShellExecutable,

        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [Parameter(Mandatory = $false)]
        [string]$WindowsTerminalExecutable,

        [Parameter(Mandatory = $false)]
        [string[]]$AdditionalArguments = @()
    )

    $quotedScriptPath = '"' + $ScriptPath.Replace('"', '`"') + '"'
    $commandArguments = "-NoProfile -ExecutionPolicy Bypass -File $quotedScriptPath"
    if ($AdditionalArguments.Count -gt 0) {
        $commandArguments += ' ' + ($AdditionalArguments -join ' ')
    }
    $windowsTerminalPath = $WindowsTerminalExecutable

    if (-not $windowsTerminalPath) {
        $wtCommand = Get-Command -Name 'wt.exe' -ErrorAction SilentlyContinue
        if ($wtCommand) {
            $windowsTerminalPath = $wtCommand.Source
        }
    }

    if ($windowsTerminalPath) {
        Write-Info 'Attempting to relaunch script in Windows Terminal with elevated privileges...'
        try {
            Start-Process $windowsTerminalPath -ArgumentList @("$PowerShellExecutable $commandArguments") -Verb RunAs
            return 'WindowsTerminal'
        }
        catch {
            Write-Warning "Failed to start Windows Terminal: $_"
        }
    }

    Write-Info 'Relaunching script in standard PowerShell window with elevated privileges...'
    Start-Process $PowerShellExecutable -ArgumentList $commandArguments -Verb RunAs
    return 'PowerShell'
}

# --- Environment ---
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

# --- GraphicalTools ---
<#
.SYNOPSIS
    Checks if Out-GridView is available in the current session.
.DESCRIPTION
    Determines whether Out-GridView can be used by checking if the session is
    interactive and if the Out-GridView command is available. This is used to
    decide whether to offer or use the interactive grid view functionality.
.OUTPUTS
    Returns $true if Out-GridView is available, $false otherwise.
#>
function Test-CanUseGridView {
    # Check if we're in an interactive session
    if (-not [Environment]::UserInteractive) {
        return $false
    }

    # Check if Out-GridView is available
    try {
        Get-Command Out-GridView -ErrorAction Stop | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

<#
.SYNOPSIS
    Ensures Out-GridView is available by installing Microsoft.PowerShell.GraphicalTools when required.
.DESCRIPTION
    Checks for the Out-GridView cmdlet and, when missing, installs the Microsoft.PowerShell.GraphicalTools module including NuGet provider remediation.
.RETURNS
    [bool] True when Out-GridView can be invoked, otherwise False.
#>
function Test-AndInstallGraphicalTools {
    try {
        if (Get-Command Out-GridView -ErrorAction SilentlyContinue) {
            return $true
        }

        $graphicalModule = Get-Module -ListAvailable -Name 'Microsoft.PowerShell.GraphicalTools'
        if (-not $graphicalModule) {
            Write-WarningMessage 'Microsoft.PowerShell.GraphicalTools module is missing. Installing to enable Out-GridView...'
        }
        else {
            Write-WarningMessage 'Microsoft.PowerShell.GraphicalTools module found but Out-GridView is unavailable. Importing module...'
        }

        $nugetProvider = Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue
        if (-not $nugetProvider) {
            Write-WarningMessage 'NuGet package provider not found. Installing...'
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null
        }

        Install-Module -Name Microsoft.PowerShell.GraphicalTools -Scope AllUsers -Force -AllowClobber -ErrorAction Stop
        Import-Module Microsoft.PowerShell.GraphicalTools -ErrorAction Stop
        Write-Success 'Microsoft.PowerShell.GraphicalTools is loaded for this session.'

        if (Get-Command Out-GridView -ErrorAction SilentlyContinue) {
            Write-Success 'Out-GridView is available for interactive summaries.'
            return $true
        }

        Write-Warning 'Microsoft.PowerShell.GraphicalTools installation completed, but Out-GridView is still unavailable.'
    }
    catch {
        Write-Warning "Failed to install Microsoft.PowerShell.GraphicalTools module: $_"
    }

    return $false
}

# --- Jsonc ---
<#
.SYNOPSIS
    Converts JSONC (JSON with comments) text to strict JSON.
.DESCRIPTION
    Character-scanner sanitizer for Windows Terminal settings files, which commonly carry
    // line comments (including trailing inline ones), /* */ block comments (possibly
    spanning lines), and trailing commas. The previous regex approach (issue #187) missed
    trailing inline comments and could corrupt string values containing comment-like
    sequences such as "/*" or "//" — and because Set-WindowsTerminalDefaultProfile writes
    the parsed object back to settings.json, a corrupted parse would persist the damage.

    The scanner tracks JSON string state (honoring backslash escapes like \" and \\), so
    comment markers and commas inside string values are never touched. Outside strings it:
      - drops // comments up to (not including) the end-of-line, and
      - drops /* */ comments, spanning lines, replaced with a single space so adjacent
        tokens cannot fuse, and
      - drops a trailing comma whose next non-whitespace character is '}' or ']'
        (whitespace between comma and closer is preserved).

    Comment stripping and trailing-comma removal run as two passes so a comma separated
    from its closing brace only by a comment ("1, /* c */ }") is still removed.
.PARAMETER JsonText
    JSONC text to sanitize.
.RETURNS
    [string] Strict-JSON text suitable for ConvertFrom-Json on Windows PowerShell 5.1.
#>
function Convert-JsoncToJson {
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$JsonText
    )

    # Pass 1: strip // and /* */ comments, string-aware.
    $length = $JsonText.Length
    $withoutComments = [System.Text.StringBuilder]::new($length)
    $inString = $false
    $i = 0

    while ($i -lt $length) {
        $currentChar = $JsonText[$i]

        if ($inString) {
            [void]$withoutComments.Append($currentChar)
            if ($currentChar -eq '\') {
                # Copy the escaped character verbatim so \" does not end the string.
                if ($i + 1 -lt $length) {
                    [void]$withoutComments.Append($JsonText[$i + 1])
                    $i += 2
                    continue
                }
            }
            elseif ($currentChar -eq '"') {
                $inString = $false
            }
            $i++
            continue
        }

        if ($currentChar -eq '"') {
            $inString = $true
            [void]$withoutComments.Append($currentChar)
            $i++
            continue
        }

        if ($currentChar -eq '/' -and $i + 1 -lt $length) {
            $nextChar = $JsonText[$i + 1]
            if ($nextChar -eq '/') {
                # Line comment: skip to end of line, keeping the line break itself.
                $i += 2
                while ($i -lt $length -and $JsonText[$i] -ne "`r" -and $JsonText[$i] -ne "`n") {
                    $i++
                }
                continue
            }
            if ($nextChar -eq '*') {
                # Block comment: skip past the closing */ (an unterminated comment
                # swallows the rest of the text, matching JSONC tokenizer behavior).
                $i += 2
                while ($i + 1 -lt $length -and -not ($JsonText[$i] -eq '*' -and $JsonText[$i + 1] -eq '/')) {
                    $i++
                }
                $i = [System.Math]::Min($i + 2, $length)
                [void]$withoutComments.Append(' ')
                continue
            }
        }

        [void]$withoutComments.Append($currentChar)
        $i++
    }

    # Pass 2: drop trailing commas (a ',' whose next non-whitespace char is '}' or ']'),
    # string-aware for values like "a, ]" that must survive untouched.
    $commentFreeText = $withoutComments.ToString()
    $length = $commentFreeText.Length
    $sanitized = [System.Text.StringBuilder]::new($length)
    $inString = $false
    $i = 0

    while ($i -lt $length) {
        $currentChar = $commentFreeText[$i]

        if ($inString) {
            [void]$sanitized.Append($currentChar)
            if ($currentChar -eq '\') {
                if ($i + 1 -lt $length) {
                    [void]$sanitized.Append($commentFreeText[$i + 1])
                    $i += 2
                    continue
                }
            }
            elseif ($currentChar -eq '"') {
                $inString = $false
            }
            $i++
            continue
        }

        if ($currentChar -eq '"') {
            $inString = $true
            [void]$sanitized.Append($currentChar)
            $i++
            continue
        }

        if ($currentChar -eq ',') {
            $lookahead = $i + 1
            while ($lookahead -lt $length -and [char]::IsWhiteSpace($commentFreeText[$lookahead])) {
                $lookahead++
            }
            if ($lookahead -lt $length -and ($commentFreeText[$lookahead] -eq '}' -or $commentFreeText[$lookahead] -eq ']')) {
                # Trailing comma: drop it; the whitespace and closer are appended normally.
                $i++
                continue
            }
        }

        [void]$sanitized.Append($currentChar)
        $i++
    }

    return $sanitized.ToString()
}

# --- WauSupport ---
<#
.SYNOPSIS
    Reads the installed Winget-AutoUpdate (WAU) version and MSI ProductCode from the registry.
.DESCRIPTION
    The MSI Uninstall entry (HKLM Uninstall key whose DisplayName matches Winget-AutoUpdate) is
    authoritative for both the installed DisplayVersion and the ProductCode (the key's name); the
    WOW6432Node hive is scanned too in case a WAU build registered 32-bit. WAU's own configuration
    key (HKLM:\SOFTWARE\Romanitho\Winget-AutoUpdate) serves as a version fallback when the uninstall
    entry is missing or unparsable. Callers use the version to decide whether the pinned MSI should
    upgrade an older install, and the ProductCode to uninstall whatever WAU version is actually
    present instead of only the pinned one (issue #186).
.RETURNS
    [pscustomobject] with:
      - Version:     [version] of the installed WAU, or $null when it cannot be determined.
      - ProductCode: '{GUID}' of the installed WAU MSI, or $null when no uninstall entry matches.
#>
function Get-InstalledWauInfo {
    $version = $null
    $productCode = $null

    $uninstallRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $uninstallRoots) {
        if ($productCode) { break }
        if (-not (Test-Path $root)) { continue }
        foreach ($key in @(Get-ChildItem -Path $root -ErrorAction SilentlyContinue)) {
            $entry = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
            if (-not $entry -or $entry.DisplayName -notlike 'Winget-AutoUpdate*') { continue }
            if ($key.PSChildName -match '^\{[0-9A-Fa-f\-]+\}$') {
                $productCode = $key.PSChildName
            }
            $parsedVersion = $null
            if ($entry.DisplayVersion -and [version]::TryParse(([string]$entry.DisplayVersion -replace '^[vV]', ''), [ref]$parsedVersion)) {
                $version = $parsedVersion
            }
            break
        }
    }

    if (-not $version) {
        $wauKey = 'HKLM:\SOFTWARE\Romanitho\Winget-AutoUpdate'
        if (Test-Path $wauKey) {
            $entry = Get-ItemProperty -Path $wauKey -ErrorAction SilentlyContinue
            foreach ($candidate in @($entry.DisplayVersion, $entry.ProductVersion)) {
                $parsedVersion = $null
                if ($candidate -and [version]::TryParse(([string]$candidate -replace '^[vV]', ''), [ref]$parsedVersion)) {
                    $version = $parsedVersion
                    break
                }
            }
        }
    }

    return [pscustomobject]@{
        Version     = $version
        ProductCode = $productCode
    }
}

<#
.SYNOPSIS
    Locks a directory down to SYSTEM and Administrators (full control, inheritance removed).
.DESCRIPTION
    Used to protect the WAU MSI staging directory so a same-user non-elevated process cannot swap
    the file between hash verification and msiexec (TOCTOU, issue #186). Grants use well-known SIDs
    (S-1-5-18 = SYSTEM, S-1-5-32-544 = Administrators) instead of account names so the ACL applies
    on non-English Windows. Throws when icacls reports failure — callers must treat the directory
    as unsafe to use.
.PARAMETER Path
    The directory whose ACL should be replaced.
#>
function Set-RestrictedDirectoryAcl {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    # /inheritance:r strips inherited ACEs; the (OI)(CI)F grants leave SYSTEM and the local
    # Administrators group as the only principals, inherited by everything created inside.
    $icaclsArgs = "`"$Path`" /inheritance:r /grant *S-1-5-18:(OI)(CI)F *S-1-5-32-544:(OI)(CI)F"
    $proc = Start-Process -FilePath 'icacls.exe' -ArgumentList $icaclsArgs -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -ne 0) {
        throw "icacls failed to restrict '$Path' (exit code $($proc.ExitCode))."
    }
}

<#
.SYNOPSIS
    Creates a fresh, ACL-restricted staging directory for the WAU MSI download.
.DESCRIPTION
    %TEMP% is user-writable and the previous fixed path (%TEMP%\WAU-<version>.msi) was predictable,
    so a non-elevated process running as the same user could swap the MSI between Get-FileHash and
    msiexec (issue #186). The staging directory lives under %ProgramData%\winget-app-setup, is
    uniquely named per run, and is locked to SYSTEM + Administrators BEFORE anything is downloaded
    into it. The base directory is restricted first so an unprivileged process cannot observe the
    per-run name or delete-and-recreate the staging directory through rights on the parent. Throws
    when the directory cannot be created or secured. Callers own cleanup (Remove-Item -Recurse).
.RETURNS
    [string] The full path of the created staging directory.
#>
function New-WauStagingDirectory {
    $baseDir = Join-Path $env:ProgramData 'winget-app-setup'
    $null = New-Item -Path $baseDir -ItemType Directory -Force -ErrorAction Stop
    Set-RestrictedDirectoryAcl -Path $baseDir

    $stagingDir = Join-Path $baseDir ('wau-msi-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -Path $stagingDir -ItemType Directory -Force -ErrorAction Stop
    Set-RestrictedDirectoryAcl -Path $stagingDir
    return $stagingDir
}

# --- WingetBootstrap ---
<#
.SYNOPSIS
    Updates the winget source for the current account to force its per-user first-use bootstrap.
.DESCRIPTION
    Runs `winget source update --name winget --disable-interactivity` under a timeout guard. This is
    the lightest command that forces winget's per-user first-use bootstrap: it registers the
    Microsoft.Winget.Source package for the invoking account. Exit code 0 therefore means the account
    can reach the winget source — the only source the install phase uses (`--source winget`).

    Do NOT pass `--accept-source-agreements` here: it is not a valid argument for `winget source
    update` and makes winget reject the whole command with 0x8A150002 (INVALID_CL_ARGUMENTS,
    -1978335230), which false-failed this probe on every machine (issue #172-followup). Source
    agreements are accepted where the flag is valid — the install commands all pass
    `--accept-source-agreements` (Install-WingetPackage), and the caller handles a genuine
    0x8A150046 (agreements-not-accepted) result explicitly.

    The probe is deliberately scoped to the winget source: msstore can fail for an account that
    has never logged on interactively even when the winget source is healthy
    (microsoft/winget-cli#5398/#6334), and probing it would report a false failure for the only
    source that matters here.
.PARAMETER TimeoutSeconds
    Maximum seconds to wait for winget before killing the process. Default 120.
.RETURNS
    [hashtable] @{ Succeeded = <bool>; ExitCode = <int or $null>; TimedOut = <bool> }
    ExitCode is $null when the process timed out or failed to start.
#>
function Invoke-WingetSourceProbe {
    param (
        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 120
    )

    # Unique per-run temp files: fixed names made concurrent runs (or a stale locked file from a
    # killed run) fail Start-Process, which read as a false probe failure (issue #177).
    $tempSuffix = [System.IO.Path]::GetRandomFileName()
    $stdoutFile = Join-Path $env:TEMP "winget_source_probe_output_$tempSuffix.txt"
    $stderrFile = Join-Path $env:TEMP "winget_source_probe_error_$tempSuffix.txt"

    try {
        $probeProcess = Start-Process -FilePath 'winget' `
            -ArgumentList 'source', 'update', '--name', 'winget', '--disable-interactivity' `
            -NoNewWindow `
            -PassThru `
            -RedirectStandardOutput $stdoutFile `
            -RedirectStandardError $stderrFile

        if (-not $probeProcess.WaitForExit($TimeoutSeconds * 1000)) {
            Write-WarningMessage "Winget source update timed out after $TimeoutSeconds seconds. Terminating process..."
            try { $probeProcess.Kill() } catch { }
            return @{ Succeeded = $false; ExitCode = $null; TimedOut = $true }
        }

        return @{
            Succeeded = ($probeProcess.ExitCode -eq 0)
            ExitCode  = $probeProcess.ExitCode
            TimedOut  = $false
        }
    }
    catch {
        Write-WarningMessage "Winget source update failed to run: $_"
        return @{ Succeeded = $false; ExitCode = $null; TimedOut = $false }
    }
    finally {
        Remove-Item $stdoutFile -ErrorAction SilentlyContinue
        Remove-Item $stderrFile -ErrorAction SilentlyContinue
    }
}

<#
.SYNOPSIS
    Checks that the winget source is both listed and functional for the current account.
.DESCRIPTION
    Two-step health probe used by Test-WingetSources before and after its repair attempt (one
    shared implementation so the two probes cannot diverge — issue #177):

      1. Listed: `winget source list` output mentions the winget source.
      2. Functional: a real `winget search 7zip --source winget` succeeds (exit code 0 and no
         corruption markers such as 0x8a15000f in the output).

    The search passes `--accept-source-agreements` — valid for `winget search`, unlike
    `winget source update` (issues #174/#175) — so a fresh account's unaccepted source agreements
    (0x8A150046) are accepted inline instead of being misdiagnosed as source corruption and
    triggering a pointless `winget source reset --force` + repair cycle.
.PARAMETER Quiet
    Suppresses the per-step success/corruption messages; used for the post-repair re-probe where
    the caller reports the overall outcome itself.
.RETURNS
    [hashtable] @{ Listed = <bool>; Functional = <bool>; Healthy = <bool> }
    Healthy is True only when the source is listed AND functional.
#>
function Test-WingetSourceHealth {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$Quiet
    )

    # First check: verify source is listed
    try {
        $output = winget source list --disable-interactivity --accept-source-agreements 2>&1
        $sourceIsListed = [bool]($output -match 'winget')
    }
    catch {
        Write-WarningMessage "Winget source list failed: $_"
        $sourceIsListed = $false
    }

    # Second check: verify source is functional (not corrupted) by attempting a search
    $sourceIsFunctional = $false
    if ($sourceIsListed) {
        try {
            # Actually test if the source works by attempting a search.
            # Use '7zip' as a known package that always exists.
            $searchOutput = winget search 7zip --source winget --disable-interactivity --accept-source-agreements 2>&1
            $searchExitCode = $LASTEXITCODE

            # Check for corruption error code 0x8a15000f or similar source errors
            if ($searchOutput -match '0x8a150|failed when opening|data required' -or $searchExitCode -ne 0) {
                if (-not $Quiet) {
                    Write-WarningMessage 'Winget source is listed but contains corrupted or missing data.'
                }
                $sourceIsFunctional = $false
            }
            else {
                if (-not $Quiet) {
                    Write-Success 'Winget sources are accessible and functional.'
                }
                $sourceIsFunctional = $true
            }
        }
        catch {
            if (-not $Quiet) {
                Write-WarningMessage "Winget source functionality test failed: $_"
            }
            $sourceIsFunctional = $false
        }
    }

    return @{
        Listed     = $sourceIsListed
        Functional = $sourceIsFunctional
        Healthy    = ($sourceIsListed -and $sourceIsFunctional)
    }
}

# --- AppValidation ---
<#
.SYNOPSIS
    Validates the list of application definitions before processing.
.DESCRIPTION
    Ensures each entry in the apps array is a hashtable containing a non-empty string `name` value and removes duplicates, warning about any issues.
.PARAMETER Apps
    The collection of application definition hash tables to validate.
.RETURNS
    [pscustomobject] containing ValidApps, Errors, and Warnings arrays.
#>
function Test-AppDefinitions {
    param (
        [Parameter(Mandatory = $true)]
        [array]$Apps
    )

    $errors = @()
    $warnings = @()
    $validatedApps = @()
    $seenNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    for ($i = 0; $i -lt $Apps.Count; $i++) {
        $app = $Apps[$i]
        if (-not ($app -is [hashtable])) {
            $errors += "App entry at index $i is not a hashtable."
            continue
        }

        if (-not $app.ContainsKey('name') -or -not ($app['name'] -is [string]) -or [string]::IsNullOrWhiteSpace($app['name'])) {
            $errors += "App entry at index $i is missing a valid 'name' value."
            continue
        }

        $name = $app['name'].Trim()
        if (-not $seenNames.Add($name)) {
            $warnings += "Duplicate app definition detected for '$name'. Subsequent entry ignored."
            continue
        }

        $app['name'] = $name
        $validatedApps += $app
    }

    return [pscustomobject]@{
        ValidApps = $validatedApps
        Errors    = $errors
        Warnings  = $warnings
    }
}

# --- Install ---
<#
.SYNOPSIS
    Executes the winget installation workflow when the script runs directly.
.DESCRIPTION
    Performs prerequisite checks, validates application definitions, installs requested apps, processes updates, and displays a summary when invoked.
.PARAMETER WhatIf
    When specified, the script performs all pre-flight checks and displays planned actions without making any system changes.
.PARAMETER NonInteractive
    Suppresses all interactive prompts (elevation pause, grid-view prompt, final "press any key")
    for unattended runs (RMM, CI, scheduled tasks). Also auto-detected when the session is
    non-interactive or stdin is redirected.
.PARAMETER SkipSystemCheck
    Pass-through of the entry script's -SkipSystemCheck switch. Used only so an elevated relaunch
    inherits the caller's intent to bypass the pre-flight system checks (issue #185); the checks
    themselves run in the entry script before this function is called.
.NOTES
    Exit codes: 0 = success, 1 = one or more apps failed to install, 2 = winget unavailable,
    3 = app-definition validation failed or no valid apps remain.
#>
function Invoke-WingetInstall {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf,
        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive,

        [Parameter(Mandatory = $false)]
        [switch]$SkipSystemCheck
    )

    # Effective non-interactive mode: explicit switch, a non-interactive session (e.g. service,
    # scheduled task, pwsh -NonInteractive), or redirected stdin (piped/irm|iex wrappers). A
    # console probe failure means there is no usable console, so treat that as non-interactive.
    $inputRedirected = $false
    try {
        $inputRedirected = [System.Console]::IsInputRedirected
    }
    catch {
        $inputRedirected = $true
    }
    $effectiveNonInteractive = $NonInteractive -or (-not [Environment]::UserInteractive) -or $inputRedirected

    if ($WhatIf) {
        Write-Info '=== DRY-RUN MODE ENABLED ==='
        Write-Info 'No system changes will be made. This is a simulation of what would happen.'
        Write-Host ''
    }

    # Determine which PowerShell executable to use
    $psExecutable = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }

    # Accept the winget source agreement in the user context before elevating. Agreements are
    # per-user and won't carry into the elevated process; running the update here surfaces any
    # interactive prompt while we still have the normal user's identity. Scoped to --name winget —
    # the only source this tool installs from — so it never triggers msstore's agreement/first-use
    # handshake, which fails in non-interactive/cross-user contexts (issue #172).
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] 'Administrator')
    if (-not $isAdmin -and (Test-IsRunningLocally)) {
        if ($WhatIf) {
            Write-Info '[DRY-RUN] Would run winget source update --name winget to prompt for source agreement acceptance in user context'
        }
        else {
            Write-Info 'Updating the winget source — accept any prompts that appear to continue...'
            Start-Process -FilePath 'winget' -ArgumentList 'source', 'update', '--name', 'winget' -Wait -NoNewWindow
        }
    }

    # Check if the script is run as administrator
    If (-NOT $isAdmin) {
        if (Test-IsRunningLocally) {
            # A dry run makes no system changes, so it never needs elevation. Relaunching
            # elevated here would (a) be a surprising side effect for a preview and (b) — if
            # the flag were ever dropped across the elevation boundary — silently turn a
            # dry run into a real install. Stay in the current session and continue the preview.
            if ($WhatIf) {
                Write-Info '[DRY-RUN] Would relaunch with administrator privileges. Continuing the preview in the current (non-elevated) session; no system changes will be made.'
            }
            else {
                # Elevation relaunches $PSCommandPath. When Invoke-WingetInstall comes from the
                # imported (or dot-sourced) module, that path is WingetAppSetup/Public/Install.ps1 —
                # a functions-only file — so the elevated window would define a function and exit
                # without installing anything (issue #185). Fail fast with guidance instead.
                if (Test-InvokedFromModuleContext -InvocationModule $MyInvocation.MyCommand.Module -CommandPath $PSCommandPath) {
                    Write-ErrorMessage 'Invoke-WingetInstall was invoked from the imported module without elevation; auto-elevation cannot relaunch a module function. Run winget-app-install.ps1, or start from an already-elevated session.'
                    return
                }
                if ($effectiveNonInteractive) {
                    Write-ErrorMessage 'This script requires administrator privileges. Restarting with elevated privileges...'
                }
                else {
                    Write-ErrorMessage 'This script requires administrator privileges. Press Enter to restart script with elevated privileges.'
                    Pause
                }
                # Relaunch the script with administrator privileges, forwarding the caller's
                # switches so the elevated session inherits the same intent: -SkipSystemCheck so
                # the pre-flight checks the caller explicitly bypassed are not re-run in the
                # elevated session (issue #185); the effective non-interactive state because the
                # elevated child gets a fresh console and would otherwise re-detect as interactive
                # and block on prompts; and -WhatIf as a safety net so a dry run could never
                # escalate into changes (unreachable today — a dry run never relaunches — but
                # kept so the forwarding stays correct if that ever changes).
                $elevationArgs = @()
                if ($WhatIf) { $elevationArgs += '-WhatIf' }
                if ($effectiveNonInteractive) { $elevationArgs += '-NonInteractive' }
                if ($SkipSystemCheck) { $elevationArgs += '-SkipSystemCheck' }
                Restart-WithElevation -PowerShellExecutable $psExecutable -ScriptPath $PSCommandPath -AdditionalArguments $elevationArgs | Out-Null
                Exit
            }
        }
        else {
            # IEX/remote execution has no local script path to relaunch from.
            Write-ErrorMessage 'This script requires administrator privileges.'
            Write-ErrorMessage 'Auto-elevation is unavailable when running through IEX/remote execution.'
            Write-Info 'Open an elevated PowerShell or Windows Terminal session and run the IEX command again.'
            Write-Info 'Exiting in 5 seconds...'
            Start-Sleep -Seconds 5
            Exit 1
        }
    }
    else {
        Write-Success 'Starting...'
    }

    # Ensure the WinGet PowerShell module is available before touching winget itself:
    # Test-AndInstallWinget and Initialize-WingetSourcesForUser use Repair-WinGetPackageManager
    # to bootstrap winget for accounts that have no interactive logon session (issue #159).
    if (-not (Test-AndInstallWingetModule)) {
        Write-Warning 'Microsoft.WinGet.Client module is not available. Update functionality will use fallback CLI methods.'
    }

    # Import required modules
    try {
        Import-Module Microsoft.WinGet.Client -ErrorAction Stop
        Write-Success 'Successfully imported Microsoft.WinGet.Client module'
    }
    catch {
        Write-Warning "Failed to import Microsoft.WinGet.Client module: $_"
        Write-Warning 'Update functionality will use fallback CLI methods'
    }

    # Check if winget is available and install if necessary
    if (-not (Test-AndInstallWinget)) {
        Write-ErrorMessage 'Winget is required for this script. Exiting.'
        Exit 2
    }

    # Initialize winget sources and agreements for the account performing the installs. This is
    # what prevents 0x80073d19 when the script is elevated as a different account than the
    # logged-on user (issues #104/#150, #159).
    [void](Initialize-WingetSourcesForUser -WhatIf:$WhatIf)

    if (-not (Test-AndInstallGraphicalTools)) {
        Write-Warning 'Out-GridView will be unavailable; results will be displayed in text mode only.'
    }

    # Verify winget sources are accessible and auto-repair if broken
    if (-not (Test-WingetSources)) {
        Write-WarningMessage 'Winget sources could not be repaired. Some installations may fail.'
    }

    # Migrate away from the old homegrown scheduled-update task if a prior version installed one;
    # ongoing updates are now handled by Winget-AutoUpdate, set up after the app installs (issue #168).
    [void](Remove-LegacyScheduledUpdates -WhatIf:$WhatIf)

    # Note: earlier versions added the script's own directory (often Downloads/) to the persistent
    # User PATH here for the homegrown updater. The updater is gone (#168) and a user-writable
    # directory on the PATH of an elevating account is a hijack surface, so no PATH changes are
    # made anymore (issue #179).

    $apps = @(
        @{name = '7zip.7zip' },
        @{name = 'GlavSoft.TightVNC' },
        @{name = 'Adobe.Acrobat.Reader.64-bit' },
        @{name = 'Google.Chrome' },
        @{name = 'Google.GoogleDrive' },
        @{name = 'Git.Git' },
        @{name = 'Klocman.BulkCrapUninstaller' },
        @{name = 'Dell.CommandUpdate.Universal' },
        # PowerShell needs a version-agnostic install strategy (no pinning — always the latest):
        # winget installs PowerShell 7.6+ as an MSIX by default, which registers per-user and fails
        # to deploy in an elevated cross-user / machine-scope context ("The current system
        # configuration does not support the installation of this package"). Install-PowerShellLatest
        # prefers the MSI while it exists (<= 7.6), and once the MSI is gone (7.7+) installs the latest
        # MSIX machine-wide — natively on Windows 24H2+, or via DISM provisioning on older Windows
        # (issues #163/#166). It self-verifies, so the loop must not re-check it with `winget list`.
        @{name = 'Microsoft.PowerShell'; install = 'Install-PowerShellLatest' },
        @{name = 'Microsoft.WindowsTerminal' }
    );

    $validationResult = Test-AppDefinitions -Apps $apps

    foreach ($validationWarning in $validationResult.Warnings) {
        Write-Warning $validationWarning
    }

    if ($validationResult.Errors.Count -gt 0) {
        foreach ($validationError in $validationResult.Errors) {
            Write-ErrorMessage $validationError
        }
        Write-ErrorMessage 'No valid application definitions found. Resolve the errors and re-run the script.'
        Exit 3
    }

    $apps = $validationResult.ValidApps

    if ($apps.Count -eq 0) {
        Write-ErrorMessage 'No application definitions remain after validation. Add at least one valid entry and re-run the script.'
        Exit 3
    }

    Write-Info 'Installing the following Apps:'
    ForEach ($app in $apps) {
        Write-Info $app.name
    }

    $installedApps = @()
    $skippedApps = @()
    $failedApps = @()

    # No separate source-trust pass here: only the winget community source is used (every install
    # forces --source winget), and its health was already verified — and repaired if needed — by
    # Test-WingetSources above (issues #172, #177).

    Foreach ($app in $apps) {
        try {
            # Run winget list with timeout to prevent hanging
            $listProcess = Start-Process -FilePath 'winget' `
                -ArgumentList 'list', '--exact', '--id', $app.name, '--accept-source-agreements' `
                -NoNewWindow `
                -PassThru `
                -RedirectStandardOutput "$env:TEMP\winget_list_output.txt" `
                -RedirectStandardError "$env:TEMP\winget_list_error.txt"

            # Wait up to 15 seconds for the list command
            if (-not $listProcess.WaitForExit(15000)) {
                Write-WarningMessage "Winget list timed out for $($app.name). Marking as failed; it will be retried."
                $listProcess.Kill()
                Remove-Item "$env:TEMP\winget_list_output.txt" -ErrorAction SilentlyContinue
                Remove-Item "$env:TEMP\winget_list_error.txt" -ErrorAction SilentlyContinue
                # Mark the app failed instead of silently dropping it: it then flows through the
                # retry pass, appears in the summary, and drives the non-zero exit code (issue #176).
                $failedApps += $app.name
                continue
            }

            $listApp = Get-Content "$env:TEMP\winget_list_output.txt" -ErrorAction SilentlyContinue

            # Cleanup temp files
            Remove-Item "$env:TEMP\winget_list_output.txt" -ErrorAction SilentlyContinue
            Remove-Item "$env:TEMP\winget_list_error.txt" -ErrorAction SilentlyContinue

            if (![String]::Join('', $listApp).Contains($app.name)) {
                if (-not $WhatIf) {
                    Write-Info "Installing: $($app.name)"
                    if ($app.install) {
                        # Package-specific installer that performs its own verification (e.g.
                        # PowerShell, whose DISM-provisioned MSIX path never shows up under
                        # `winget list` for the elevating account). Trust its Installed result.
                        $installOutcome = & $app.install
                        if ($installOutcome.Installed) {
                            Write-Success "Successfully installed: $($app.name)"
                            $installedApps += $app.name
                        }
                        else {
                            Write-ErrorMessage "Failed to install: $($app.name)."
                            $failedApps += $app.name
                        }
                    }
                    else {
                        # Install through the helper so the transient 0x80073d19 session error is
                        # retried with backoff (issue #150) instead of failing on the first hit.
                        [void](Install-WingetPackage -PackageId $app.name -InstallerType $app.installerType)

                        # Verify installation with timeout
                        $verifyProcess = Start-Process -FilePath 'winget' `
                            -ArgumentList 'list', '--exact', '--id', $app.name, '--accept-source-agreements' `
                            -NoNewWindow `
                            -PassThru `
                            -RedirectStandardOutput "$env:TEMP\winget_verify_output.txt" `
                            -RedirectStandardError "$env:TEMP\winget_verify_error.txt"

                        if ($verifyProcess.WaitForExit(15000)) {
                            $installResult = Get-Content "$env:TEMP\winget_verify_output.txt" -ErrorAction SilentlyContinue
                            if (![String]::Join('', $installResult).Contains($app.name)) {
                                Write-ErrorMessage "Failed to install: $($app.name). No package found matching input criteria."
                                $failedApps += $app.name
                            }
                            else {
                                Write-Success "Successfully installed: $($app.name)"
                                $installedApps += $app.name
                            }
                        }
                        else {
                            Write-WarningMessage "Verification timed out for: $($app.name). Assuming installation failed."
                            $verifyProcess.Kill()
                            $failedApps += $app.name
                        }

                        # Cleanup temp files
                        Remove-Item "$env:TEMP\winget_verify_output.txt" -ErrorAction SilentlyContinue
                        Remove-Item "$env:TEMP\winget_verify_error.txt" -ErrorAction SilentlyContinue
                    }
                }
                else {
                    Write-Info "[DRY-RUN] Would install: $($app.name)"
                    $installedApps += $app.name
                }
            }
            else {
                Write-WarningMessage "Skipping: $($app.name) (already installed)"
                $skippedApps += $app.name
            }
        }
        catch {
            Write-ErrorMessage "Failed to install: $($app.name). Error: $_"
            $failedApps += $app.name
        }
    }

    # Ongoing app updates are handled by Winget-AutoUpdate (set up below), which runs as SYSTEM on a
    # schedule — not an install-time pass that upgrades every installed app synchronously as the
    # elevating admin (that was slow, silent, and largely failed under cross-user elevation; issue #170).

    # Configure Windows Terminal defaults(issue #74): default profile and default terminal app.
    Set-WindowsTerminalDefaults -WhatIf:$WhatIf

    # Set up ongoing automatic updates via Winget-AutoUpdate (issue #168). Best-effort: a failure
    # here warns but does not fail the install; the outcome is captured and surfaced next to the
    # final summary instead of being a scrolled-past warning (issue #186).
    $wauResult = Install-WingetAutoUpdate -WhatIf:$WhatIf

    # Retry any failed installations once before producing the final summary
    if ($failedApps.Count -gt 0) {
        if (-not $WhatIf) {
            Write-Host ''
            Write-Info 'Retrying failed installations (1 final attempt)...'

            $appsToRetry = $failedApps
            $failedApps = @()

            foreach ($appName in $appsToRetry) {
                try {
                    Write-Info "Retrying: $appName"
                    $appDef = $apps | Where-Object { $_.name -eq $appName } | Select-Object -First 1
                    if ($appDef.install) {
                        # Package-specific self-verifying installer (e.g. PowerShell). Trust its result.
                        $retryOutcome = & $appDef.install
                        if ($retryOutcome.Installed) {
                            Write-Success "Retry succeeded: $appName"
                            $installedApps += $appName
                        }
                        else {
                            Write-ErrorMessage "Retry failed: $appName"
                            $failedApps += $appName
                        }
                    }
                    else {
                        # Route the final retry through the same helper so a lingering 0x80073d19
                        # session error gets its backoff retries here too (issue #150).
                        [void](Install-WingetPackage -PackageId $appName -InstallerType $appDef.installerType)

                        # Verify installation with timeout
                        $verifyProcess = Start-Process -FilePath 'winget' `
                            -ArgumentList 'list', '--exact', '--id', $appName, '--accept-source-agreements' `
                            -NoNewWindow `
                            -PassThru `
                            -RedirectStandardOutput "$env:TEMP\winget_retry_verify_output.txt" `
                            -RedirectStandardError "$env:TEMP\winget_retry_verify_error.txt"

                        if ($verifyProcess.WaitForExit(15000)) {
                            $retryResult = Get-Content "$env:TEMP\winget_retry_verify_output.txt" -ErrorAction SilentlyContinue
                            if (![String]::Join('', $retryResult).Contains($appName)) {
                                Write-ErrorMessage "Retry failed: $appName"
                                $failedApps += $appName
                            }
                            else {
                                Write-Success "Retry succeeded: $appName"
                                $installedApps += $appName
                            }
                        }
                        else {
                            Write-WarningMessage "Verification timed out for retry: $appName. Assuming installation failed."
                            try { $verifyProcess.Kill() } catch { }
                            $failedApps += $appName
                        }

                        # Cleanup temp files
                        Remove-Item "$env:TEMP\winget_retry_verify_output.txt" -ErrorAction SilentlyContinue
                        Remove-Item "$env:TEMP\winget_retry_verify_error.txt" -ErrorAction SilentlyContinue
                    }
                }
                catch {
                    Write-ErrorMessage "Retry failed: $appName. Error: $_"
                    $failedApps += $appName
                }
            }
        }
        else {
            Write-Host ''
            Write-Info '[DRY-RUN] Would retry the following failed installations:'
            foreach ($appName in $failedApps) {
                Write-Info "[DRY-RUN] Would retry: $appName"
            }
        }
    }

    # Display the summary of the installation
    if ($WhatIf) {
        Write-Host ''
        Write-Info '=== DRY-RUN SUMMARY ==='
        Write-Info 'The following actions would have been performed:'
    }
    else {
        Write-Info 'Summary:'
    }

    $headers = @('Status', 'Apps')
    $rows = @()

    $appList = Format-AppList -AppArray $installedApps
    if ($appList) {
        $rows += , @('Installed', $appList)
    }

    $appList = Format-AppList -AppArray $skippedApps
    if ($appList) {
        $rows += , @('Skipped', $appList)
    }

    $appList = Format-AppList -AppArray $failedApps
    if ($appList) {
        $rows += , @('Failed', $appList)
    }

    Write-Table -Headers $headers -Rows $rows -PromptForGridView (-not $effectiveNonInteractive) -Title 'Installation Summary'

    # Surface the auto-update outcome with the summary so a machine that finished without an update
    # mechanism is visible at the end of the run (issue #186). Deliberately does not affect the exit
    # code: the documented 0/1/2/3 contract stays scoped to app installs and winget availability.
    switch ($wauResult.Status) {
        'Configured' { Write-Success "Auto-updates: Configured (Winget-AutoUpdate v$($wauResult.Version))." }
        'AlreadyPresent' {
            if ($wauResult.Version) {
                Write-Success "Auto-updates: Already present (v$($wauResult.Version))."
            }
            else {
                Write-WarningMessage 'Auto-updates: Already present (installed version could not be determined).'
            }
        }
        'DryRun' { Write-Info "[DRY-RUN] Auto-updates: Would configure Winget-AutoUpdate v$($wauResult.Version)." }
        default { Write-ErrorMessage 'Auto-updates: FAILED - Winget-AutoUpdate could not be installed; apps will not update automatically. Re-run the installer to retry.' }
    }

    # Keep the console window open until the user presses a key. Skipped in non-interactive mode
    # so unattended runs never block (and the failure exit below stays reachable).
    if (-not $effectiveNonInteractive) {
        Write-Prompt 'Press any key to exit...'
        [void][System.Console]::ReadKey($true)
    }

    if ($failedApps.Count -gt 0) {
        Exit 1
    }
}

# --- Logging ---
<#
.SYNOPSIS
    Writes an informational message in blue color.
.DESCRIPTION
    Helper function for consistent informational and action messages throughout the script.
.PARAMETER Message
    The message to display
#>
function Write-Info {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message
    )
    Write-Host $Message -ForegroundColor Blue
}

<#
.SYNOPSIS
    Writes a success message in green color.
.DESCRIPTION
    Helper function for consistent success messages throughout the script.
.PARAMETER Message
    The message to display
#>
function Write-Success {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message
    )
    Write-Host $Message -ForegroundColor Green
}

<#
.SYNOPSIS
    Writes a warning message in yellow color.
.DESCRIPTION
    Helper function for consistent warning and skip messages throughout the script.
    Named Write-WarningMessage to avoid conflict with built-in Write-Warning cmdlet.
.PARAMETER Message
    The message to display
#>
function Write-WarningMessage {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message
    )
    Write-Host $Message -ForegroundColor Yellow
}

<#
.SYNOPSIS
    Writes an error message in red color.
.DESCRIPTION
    Helper function for consistent error messages throughout the script.
    Named Write-ErrorMessage to avoid conflict with built-in Write-Error cmdlet.
.PARAMETER Message
    The message to display
#>
function Write-ErrorMessage {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message
    )
    Write-Host $Message -ForegroundColor Red
}

<#
.SYNOPSIS
    Writes a prompt message in blue color.
.DESCRIPTION
    Helper function for consistent user prompt messages throughout the script.
.PARAMETER Message
    The message to display
#>
function Write-Prompt {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message
    )
    Write-Host $Message -ForegroundColor Blue
}

<#
.SYNOPSIS
    Formats an array of app names for display in the summary table.
.DESCRIPTION
    This function checks if an array has content and formats it as a comma-separated string.
.PARAMETER AppArray
    The array of app names to format
.RETURNS
    A formatted string of app names, or $null if the array is empty
#>
function Format-AppList {
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowNull()]
        [string[]]$AppArray
    )

    if ($AppArray -and $AppArray.Count -gt 0) {
        return $AppArray -join ', '
    }
    return $null
}

<#
.SYNOPSIS
    Displays a formatted table of results, with optional interactive GUI view.
.DESCRIPTION
    Renders a summary table using PowerShell's built-in Format-Table for improved
    readability and alignment. Optionally displays the data in Out-GridView when
    running in an interactive session with GUI support.
.PARAMETER Headers
    Array of column header names
.PARAMETER Rows
    Array of row data (each row is an array matching the header count)
.PARAMETER UseGridView
    When set to $true and Out-GridView is available, displays results interactively
.PARAMETER PromptForGridView
    When set to $true, asks the user if they want to use Out-GridView (if available)
#>
function Write-Table {
    param (
        [Parameter(Mandatory = $true)]
        [string[]]$Headers,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[][]]$Rows,
        [Parameter(Mandatory = $false)]
        [bool]$UseGridView = $false,
        [Parameter(Mandatory = $false)]
        [bool]$PromptForGridView = $false,
        [Parameter(Mandatory = $false)]
        [string]$Title = 'Summary'
    )

    # Convert rows to objects for Format-Table
    $tableData = @()
    foreach ($row in $Rows) {
        $obj = New-Object PSObject
        for ($i = 0; $i -lt $Headers.Count; $i++) {
            $obj | Add-Member -MemberType NoteProperty -Name $Headers[$i] -Value $row[$i]
        }
        $tableData += $obj
    }

    $shouldUseGridView = $UseGridView

    # Prompt user if requested and Out-GridView is available
    if ($PromptForGridView -and -not $UseGridView) {
        if (Test-CanUseGridView) {
            Write-Host ''
            $response = Read-Host 'Would you like to view the results in an interactive grid view? (Y/N)'
            if ($response -match '^[Yy]') {
                $shouldUseGridView = $true
            }
        }
    }

    # Try to use Out-GridView if requested and available
    if ($shouldUseGridView) {
        if (-not (Test-CanUseGridView)) {
            Write-WarningMessage 'Out-GridView is not available. Falling back to text output.'
        }
        else {
            try {
                $tableData | Out-GridView -Title $Title -Wait
                return
            }
            catch {
                Write-WarningMessage "Failed to display grid view: $_. Falling back to text output."
            }
        }
    }

    # Use Format-Table for text output
    $output = $tableData | Format-Table -AutoSize | Out-String
    Write-Host $output.TrimEnd()
}

# --- SystemChecks ---
<#
.SYNOPSIS
    Runs pre-flight system checks (OS version, disk space, network) before installation.
.DESCRIPTION
    Warns on Windows older than 10 21H2 (build 19044, non-blocking), warns and prompts to
    continue when C: has less than 50 GB free (measured only — an unreadable drive reports
    UNKNOWN and never prompts), and blocks when cdn.winget.microsoft.com is unreachable over
    HTTPS (network is required for winget). The network probe uses Invoke-WebRequest, which
    honors system proxy settings; any HTTP response — including 4xx/5xx — counts as reachable,
    and only a transport-level failure (no response at all) blocks. In -WhatIf mode the
    disk-space prompt is skipped.
.PARAMETER WhatIf
    When specified, reports intended checks without prompting on low disk space.
.RETURNS
    [bool] True when it is safe to proceed; False when a blocking check fails or the user declines.
#>
function Test-SystemRequirements {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    $results = @()
    $proceed = $true

    # --- OS Version (warn only, Windows 10 21H2 = build 19044) ---
    try {
        $build = [System.Environment]::OSVersion.Version.Build
        $osName = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).ProductName
        if ($build -ge 19044) {
            $results += [PSCustomObject]@{ Check = 'OS Version'; Status = 'OK'; Detail = $osName }
        }
        else {
            $results += [PSCustomObject]@{ Check = 'OS Version'; Status = 'WARN'; Detail = "$osName (build $build — Windows 10 21H2 or later recommended)" }
        }
    }
    catch {
        $results += [PSCustomObject]@{ Check = 'OS Version'; Status = 'WARN'; Detail = "Could not determine OS version: $_" }
    }

    # --- Disk Space on C: (warn + prompt if under 50 GB) ---
    $freeGB = $null
    try {
        $drive = Get-PSDrive -Name C -ErrorAction Stop
        $freeGB = [Math]::Round($drive.Free / 1GB, 1)
        if ($freeGB -ge 50) {
            $results += [PSCustomObject]@{ Check = 'Disk Space'; Status = 'OK'; Detail = "${freeGB} GB free on C:" }
        }
        else {
            $results += [PSCustomObject]@{ Check = 'Disk Space'; Status = 'WARN'; Detail = "${freeGB} GB free on C: (50 GB recommended)" }
        }
    }
    catch {
        # Distinct from the low-space WARN: free space could not be measured, so the
        # low-disk prompt below must not fire ($freeGB stays $null).
        $results += [PSCustomObject]@{ Check = 'Disk Space'; Status = 'UNKNOWN'; Detail = "Could not read C: drive: $_" }
    }

    # --- Network (blocking — required for winget) ---
    # Proxy-aware HTTPS probe: Invoke-WebRequest honors system proxy settings, unlike a raw
    # TCP test (Test-NetConnection), which false-fails on proxy-only networks (#184). Any HTTP
    # response — even 4xx/5xx — proves the CDN is reachable; only a transport-level failure
    # (no response at all) blocks.
    try {
        # -UseBasicParsing is a no-op on PowerShell 7 but prevents a false FAIL on Windows
        # PowerShell 5.1 (README launch path) when the IE parsing engine is unavailable.
        $null = Invoke-WebRequest -Uri 'https://cdn.winget.microsoft.com/cache' -Method Head -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
        $results += [PSCustomObject]@{ Check = 'Network'; Status = 'OK'; Detail = 'HTTPS probe of cdn.winget.microsoft.com succeeded' }
    }
    catch {
        $response = $_.Exception.Response
        if ($null -ne $response) {
            $results += [PSCustomObject]@{ Check = 'Network'; Status = 'OK'; Detail = "cdn.winget.microsoft.com reachable (HTTP $([int]$response.StatusCode))" }
        }
        else {
            $results += [PSCustomObject]@{ Check = 'Network'; Status = 'FAIL'; Detail = "Cannot reach cdn.winget.microsoft.com over HTTPS — network is required: $($_.Exception.Message)" }
            $proceed = $false
        }
    }

    # --- Display results ---
    Write-Host ''
    Write-Info 'Pre-flight System Checks:'
    foreach ($r in $results) {
        $icon = switch ($r.Status) { 'OK' { '[OK]' } 'WARN' { '[WARN]' } 'UNKNOWN' { '[UNKNOWN]' } 'FAIL' { '[FAIL]' } }
        $msg = "$icon $($r.Check): $($r.Detail)"
        switch ($r.Status) {
            'OK' { Write-Success $msg }
            'WARN' { Write-WarningMessage $msg }
            'UNKNOWN' { Write-WarningMessage $msg }
            'FAIL' { Write-ErrorMessage $msg }
        }
    }
    Write-Host ''

    if (-not $proceed) {
        return $false
    }

    # Prompt only when free space was actually measured below the threshold
    # (skip prompt in WhatIf mode; never prompt when the drive could not be read).
    if ($null -ne $freeGB -and $freeGB -lt 50 -and -not $WhatIf) {
        $choice = Read-Host 'Disk space is below the 50 GB recommendation. Continue anyway? (Y/N)'
        if ($choice -notin @('Y', 'y')) {
            Write-WarningMessage 'Installation cancelled by user due to low disk space.'
            return $false
        }
    }

    return $true
}

# --- WindowsTerminal ---
<#
.SYNOPSIS
    Attempts to parse Windows Terminal settings content, including JSONC variants.
.DESCRIPTION
    Tries ConvertFrom-Json first (PowerShell 7+ tolerates JSONC natively). If parsing
    fails — Windows PowerShell 5.1 rejects comments and trailing commas — sanitizes the
    text with the string-aware Convert-JsoncToJson scanner and retries. The previous
    regex sanitizer missed trailing inline // comments and could corrupt string values
    containing comment-like sequences (issue #187).
.PARAMETER JsonText
    Raw settings content.
.RETURNS
    Parsed settings object when successful; otherwise $null.
#>
function ConvertFrom-TerminalSettingsJson {
    param (
        [Parameter(Mandatory = $true)]
        [string]$JsonText
    )

    if ([string]::IsNullOrWhiteSpace($JsonText)) {
        return [pscustomobject]@{}
    }

    try {
        # ConvertFrom-Json -Depth is unavailable in Windows PowerShell 5.1.
        return $JsonText | ConvertFrom-Json
    }
    catch {
        # Windows Terminal settings are often JSONC; strip comments and trailing commas.
        $sanitizedJson = Convert-JsoncToJson -JsonText $JsonText

        try {
            # Keep parsing compatible with both Windows PowerShell and PowerShell 7+.
            return $sanitizedJson | ConvertFrom-Json
        }
        catch {
            return $null
        }
    }
}

<#
.SYNOPSIS
    Resolves the most likely Windows Terminal settings file path.
.DESCRIPTION
    Prefers the stable packaged path, then preview, then unpackaged path.
.RETURNS
    [string] Existing settings path when found; otherwise $null.
#>
function Get-WindowsTerminalSettingsPath {
    $settingsPaths = Get-WindowsTerminalSettingsPaths
    if ($settingsPaths.Count -gt 0) {
        return $settingsPaths[0]
    }

    return $null
}

<#
.SYNOPSIS
    Resolves all discovered Windows Terminal settings file paths.
.DESCRIPTION
    Includes packaged channels (stable/preview/dev/canary-style package names)
    and unpackaged path when present.
.RETURNS
    [string[]] Existing settings paths when found; otherwise an empty array.
#>
function Get-WindowsTerminalSettingsPaths {
    $candidatePaths = @(
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'),
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\settings.json')
    )

    $packagesRoot = Join-Path $env:LOCALAPPDATA 'Packages'
    if (Test-Path -Path $packagesRoot) {
        try {
            $dynamicPaths = Get-ChildItem -Path $packagesRoot -Directory -Filter 'Microsoft.WindowsTerminal*' -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName 'LocalState\settings.json' }

            if ($dynamicPaths) {
                $candidatePaths += $dynamicPaths
            }
        }
        catch {
            # Best-effort discovery only; keep static candidates if enumeration fails.
        }
    }

    $existingPaths = @()

    foreach ($path in $candidatePaths) {
        if (Test-Path -Path $path) {
            $existingPaths += $path
        }
    }

    return @($existingPaths | Select-Object -Unique)
}

<#
.SYNOPSIS
    Sets Windows Terminal default profile to a provided GUID.
.DESCRIPTION
    Reads settings.json, updates defaultProfile, and writes updated JSON.
.PARAMETER SettingsPath
    Full path to the Windows Terminal settings file.
.PARAMETER ProfileGuid
    Profile GUID to set as default. Braces are added when missing.
.RETURNS
    [bool] True when configuration is applied or already in desired state; otherwise False.
#>
function Set-WindowsTerminalDefaultProfile {
    param (
        [Parameter(Mandatory = $true)]
        [string]$SettingsPath,

        [Parameter(Mandatory = $true)]
        [string]$ProfileGuid
    )

    if (-not (Test-Path -Path $SettingsPath)) {
        Write-WarningMessage "Windows Terminal settings file not found at '$SettingsPath'."
        return $false
    }

    $normalizedGuid = if ($ProfileGuid.StartsWith('{') -and $ProfileGuid.EndsWith('}')) {
        $ProfileGuid
    }
    else {
        "{$ProfileGuid}"
    }

    try {
        $settingsContent = Get-Content -Path $SettingsPath -Raw -ErrorAction Stop
    }
    catch {
        Write-WarningMessage "Unable to read Windows Terminal settings: $_"
        return $false
    }

    $settingsObject = ConvertFrom-TerminalSettingsJson -JsonText $settingsContent
    if (-not $settingsObject) {
        Write-WarningMessage 'Unable to parse Windows Terminal settings.json. Skipping default profile update.'
        return $false
    }

    if ($settingsObject.defaultProfile -eq $normalizedGuid) {
        Write-Success 'Windows Terminal default profile is already set to PowerShell 7.'
        return $true
    }

    $settingsObject | Add-Member -MemberType NoteProperty -Name 'defaultProfile' -Value $normalizedGuid -Force

    try {
        $updatedJson = $settingsObject | ConvertTo-Json -Depth 100
        Set-Content -Path $SettingsPath -Value $updatedJson -Encoding UTF8 -ErrorAction Stop
        Write-Success 'Configured Windows Terminal default profile to PowerShell 7.'
        return $true
    }
    catch {
        Write-WarningMessage "Failed to update Windows Terminal settings.json: $_"
        return $false
    }
}

<#
.SYNOPSIS
    Sets Windows Terminal as the default terminal application via registry.
.DESCRIPTION
    Writes DelegationConsole and DelegationTerminal values under HKCU:\Console\%%Startup.
.RETURNS
    [bool] True when configuration is applied or already in desired state; otherwise False.
#>
function Set-WindowsTerminalAsDefaultTerminalApplication {
    $registryPath = 'HKCU:\Console\%%Startup'
    $delegationConsole = '{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}'
    $delegationTerminal = '{E12CFF52-A866-4C77-9A90-F570A7AA2C6B}'

    try {
        if (-not (Test-Path -Path $registryPath)) {
            New-Item -Path $registryPath -Force | Out-Null
        }

        $existingValues = Get-ItemProperty -Path $registryPath -ErrorAction SilentlyContinue
        if ($existingValues -and
            $existingValues.DelegationConsole -eq $delegationConsole -and
            $existingValues.DelegationTerminal -eq $delegationTerminal) {
            Write-Success 'Windows Terminal is already configured as the default terminal application.'
            return $true
        }

        New-ItemProperty -Path $registryPath -Name 'DelegationConsole' -PropertyType String -Value $delegationConsole -Force | Out-Null
        New-ItemProperty -Path $registryPath -Name 'DelegationTerminal' -PropertyType String -Value $delegationTerminal -Force | Out-Null
        Write-Success 'Configured Windows Terminal as the default terminal application.'
        return $true
    }
    catch {
        Write-WarningMessage "Failed to set default terminal application in registry: $_"
        return $false
    }
}

<#
.SYNOPSIS
    Configures Windows Terminal defaults for shell profile and terminal delegation.
.DESCRIPTION
    Applies both issue #74 requirements: PowerShell 7 default profile and Windows Terminal
    default terminal application setting.

    Both writes are strictly per-user: settings.json lives under the process account's
    %LOCALAPPDATA% and the delegation values under its HKCU hive. Under this repo's
    documented cross-user scenario — a tech elevating as an admin-* account on a user's
    machine (issue #159) — that means the ADMIN account's terminal gets configured, not the
    logged-on user's. This function reuses the #159 detection (Get-ProcessUserName vs
    Get-InteractiveSessionUserName) to warn loudly and report honestly in that case
    (issue #187). It deliberately does NOT write to another user's profile or registry
    hive — impersonation/HKU writes are out of scope.
.PARAMETER WhatIf
    When provided, only reports intended actions.
#>
function Set-WindowsTerminalDefaults {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    $powerShell7ProfileGuid = '{574e775e-4f2a-5b96-ac1e-a2962a402336}'
    $settingsPaths = @(Get-WindowsTerminalSettingsPaths)

    # Cross-user elevation detection (issue #187), reusing the #159 helpers.
    $processUser = Get-ProcessUserName
    $sessionUser = Get-InteractiveSessionUserName
    $isCrossUserElevation = [bool]($processUser -and $sessionUser -and ($processUser -ne $sessionUser))
    if ($isCrossUserElevation) {
        Write-WarningMessage '================================ CROSS-USER ELEVATION ================================'
        Write-WarningMessage "Running as '$processUser' while '$sessionUser' owns the interactive session."
        Write-WarningMessage 'Windows Terminal settings.json and the HKCU default-terminal values are PER-USER:'
        Write-WarningMessage "everything below is applied to '$processUser' (the ADMIN account), NOT to '$sessionUser'."
        Write-WarningMessage "'$sessionUser' will be left unconfigured. Re-run this script as '$sessionUser' to configure their terminal."
        Write-WarningMessage '======================================================================================'
    }

    if ($WhatIf) {
        if ($settingsPaths.Count -gt 0) {
            Write-Info "[DRY-RUN] Would set defaultProfile to $powerShell7ProfileGuid in $($settingsPaths.Count) Windows Terminal settings file(s)"
        }
        else {
            Write-Info '[DRY-RUN] Would set Windows Terminal defaultProfile to PowerShell 7 when settings.json is available'
        }
        Write-Info '[DRY-RUN] Would set HKCU:\Console\%%Startup DelegationConsole and DelegationTerminal to Windows Terminal values'
        return
    }

    if ($settingsPaths.Count -gt 0) {
        foreach ($settingsPath in $settingsPaths) {
            [void](Set-WindowsTerminalDefaultProfile -SettingsPath $settingsPath -ProfileGuid $powerShell7ProfileGuid)
        }
    }
    else {
        Write-WarningMessage 'Windows Terminal settings.json was not found. Skipping default profile configuration.'
    }

    [void](Set-WindowsTerminalAsDefaultTerminalApplication)

    # Honest reporting under cross-user elevation: the per-step success messages above refer
    # to the PROCESS account's profile, so close with the caveat rather than an implied
    # machine-wide success (issue #187).
    if ($isCrossUserElevation) {
        Write-WarningMessage "Windows Terminal defaults were applied to '$processUser' only; '$sessionUser' remains unconfigured."
    }
}

# --- WingetAutoUpdate ---
<#
.SYNOPSIS
    Returns the pinned Winget-AutoUpdate (WAU) release metadata.
.DESCRIPTION
    We deploy a specific, SHA256-verified WAU release rather than tracking latest, and disable WAU's
    own self-update, so an upstream change can never roll out to managed machines unreviewed. Bump
    all fields together to move to a newer WAU (verify the new SHA256 against the winget-pkgs manifest
    for that version). See issue #168.
#>
function Get-WauPin {
    return @{
        Version     = '2.12.0'
        MsiUrl      = 'https://github.com/Romanitho/Winget-AutoUpdate/releases/download/v2.12.0/WAU.msi'
        Sha256      = 'F5AB2303FDF82FBFCB2248CCA4F96479FE17D74584A528B0F86B3DBE9F9E9718'
        ProductCode = '{FB0EB14E-95AC-45D7-A951-432316FFCBD4}'
    }
}

<#
.SYNOPSIS
    Returns true when Winget-AutoUpdate appears to be installed on this machine.
.DESCRIPTION
    WAU records its configuration under HKLM and registers a scheduled task 'Winget-AutoUpdate' under
    the '\WAU\' task path. Either is a reliable indicator that WAU is already set up, so the installer
    can leave an existing (possibly customized) WAU configuration untouched.
#>
function Test-WauInstalled {
    if (Test-Path 'HKLM:\SOFTWARE\Romanitho\Winget-AutoUpdate') {
        return $true
    }
    try {
        if (Get-ScheduledTask -TaskName 'Winget-AutoUpdate' -TaskPath '\WAU\' -ErrorAction Stop) {
            return $true
        }
    }
    catch { }
    return $false
}

<#
.SYNOPSIS
    Installs (or upgrades) and configures Winget-AutoUpdate (WAU) to keep installed apps current.
.DESCRIPTION
    Downloads the pinned WAU MSI into an ACL-restricted staging directory (SYSTEM + Administrators
    only, so a non-elevated process cannot swap the file between hash verification and msiexec —
    issue #186), verifies its SHA256, and installs it silently with the configuration this project
    standardizes on (issue #168):
      - Weekly updates at 02:00 (WAU runs as SYSTEM for machine-scope packages and spawns a user-context
        task in the logged-on session for user-scope packages, which avoids the cross-user 0x80073d19
        class the homegrown updater fought).
      - USERCONTEXT=1 so user-scope apps update in the real interactive session.
      - DISABLEWAUAUTOUPDATE=1 so WAU stays on this pinned version until we bump it deliberately.
      - Full notifications; skip on metered connections.
    Version-aware (issue #186): because DISABLEWAUAUTOUPDATE=1 pins deployed machines, a bumped
    Get-WauPin would otherwise only ever reach brand-new installs. When WAU is present but older
    than the pin, the pinned MSI is run anyway — msiexec upgrades in place and re-applies this
    project's standard configuration — making installer re-runs the WAU upgrade vehicle. An
    equal/newer installed version, or one whose version cannot be read, is left untouched
    (configuration included).
    Best-effort: any failure warns and returns a Failed result rather than aborting the install.
.PARAMETER WhatIf
    When specified, only reports intended actions.
.RETURNS
    [pscustomobject] with:
      - Status:  'Configured' (installed or upgraded this run), 'AlreadyPresent' (left as-is),
                 'Failed', or 'DryRun' (under -WhatIf).
      - Version: the pinned version for Configured/Failed/DryRun; the installed version
                 (or $null when unreadable) for AlreadyPresent.
#>
function Install-WingetAutoUpdate {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    $pin = Get-WauPin

    if ($WhatIf) {
        Write-Info "[DRY-RUN] Would install Winget-AutoUpdate $($pin.Version) (weekly updates at 02:00, Full notifications, self-update disabled)."
        return [pscustomobject]@{ Status = 'DryRun'; Version = $pin.Version }
    }

    if (Test-WauInstalled) {
        $installed = Get-InstalledWauInfo
        if ($installed.Version -and $installed.Version -lt [version]$pin.Version) {
            Write-Info "Winget-AutoUpdate v$($installed.Version) is older than the pinned v$($pin.Version); upgrading in place..."
        }
        else {
            $versionLabel = if ($installed.Version) { "v$($installed.Version)" } else { 'version unknown' }
            Write-Success "Winget-AutoUpdate is already installed ($versionLabel); leaving its configuration unchanged."
            return [pscustomobject]@{ Status = 'AlreadyPresent'; Version = $installed.Version }
        }
    }
    else {
        Write-Info "Setting up automatic app updates via Winget-AutoUpdate $($pin.Version)..."
    }

    $stagingDir = $null
    try {
        # Download, verify, and install from a locked-down per-run directory instead of the
        # predictable %TEMP% path a same-user non-elevated process could tamper with (issue #186).
        $stagingDir = New-WauStagingDirectory
        $msiPath = Join-Path $stagingDir "WAU-$($pin.Version).msi"
        Invoke-WebRequest -Uri $pin.MsiUrl -OutFile $msiPath -UseBasicParsing -ErrorAction Stop

        $actualHash = (Get-FileHash -Path $msiPath -Algorithm SHA256).Hash
        if ($actualHash -ne $pin.Sha256) {
            Write-ErrorMessage "Winget-AutoUpdate MSI hash mismatch (expected $($pin.Sha256), got $actualHash). Skipping installation."
            return [pscustomobject]@{ Status = 'Failed'; Version = $pin.Version }
        }

        # Bake the configuration in via MSI properties (the winget-package install path allows no
        # install-time customization). Single quoted-path argument string for reliable msiexec parsing.
        $msiArgs = "/i `"$msiPath`" /qn /norestart RUN_WAU=YES USERCONTEXT=1 DISABLEWAUAUTOUPDATE=1 UPDATESINTERVAL=Weekly UPDATESATTIME=02:00:00 NOTIFICATIONLEVEL=Full DONOTRUNONMETERED=1"
        $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -Wait -PassThru

        # 3010 = ERROR_SUCCESS_REBOOT_REQUIRED — still a success.
        if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) {
            Write-Success "Winget-AutoUpdate $($pin.Version) installed. Apps will update weekly at 2 AM."
            return [pscustomobject]@{ Status = 'Configured'; Version = $pin.Version }
        }

        Write-ErrorMessage "Winget-AutoUpdate install failed (msiexec exit code $($proc.ExitCode))."
        return [pscustomobject]@{ Status = 'Failed'; Version = $pin.Version }
    }
    catch {
        Write-ErrorMessage "Failed to install Winget-AutoUpdate: $_"
        return [pscustomobject]@{ Status = 'Failed'; Version = $pin.Version }
    }
    finally {
        if ($stagingDir) {
            Remove-Item -Path $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

<#
.SYNOPSIS
    Uninstalls Winget-AutoUpdate (WAU) via the MSI product code of the installed version.
.DESCRIPTION
    Resolves the ProductCode of the WAU actually installed from its uninstall registry entry
    (issue #186): every MSI version of WAU has its own ProductCode, so uninstalling with only the
    pinned code makes msiexec exit 1605 ('unknown product') against any other installed version and
    leaves WAU in place. Falls back to the pinned ProductCode when the registry lookup finds none.
.PARAMETER WhatIf
    When specified, only reports intended actions.
.RETURNS
    [bool] True when WAU was removed (or was not installed), otherwise False.
#>
function Uninstall-WingetAutoUpdate {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    if (-not (Test-WauInstalled)) {
        Write-WarningMessage 'Winget-AutoUpdate is not installed; nothing to remove.'
        return $true
    }

    if ($WhatIf) {
        Write-Info '[DRY-RUN] Would uninstall Winget-AutoUpdate.'
        return $true
    }

    $productCode = (Get-InstalledWauInfo).ProductCode
    if (-not $productCode) {
        $productCode = (Get-WauPin).ProductCode
    }
    Write-Info 'Uninstalling Winget-AutoUpdate...'
    $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList "/x $productCode /qn /norestart" -Wait -PassThru

    if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) {
        Write-Success 'Winget-AutoUpdate uninstalled.'
        return $true
    }

    Write-ErrorMessage "Winget-AutoUpdate uninstall failed (msiexec exit code $($proc.ExitCode))."
    return $false
}

<#
.SYNOPSIS
    Removes the legacy homegrown scheduled-update task and its %APPDATA% data.
.DESCRIPTION
    Auto-updates are now handled by Winget-AutoUpdate (issue #168). Earlier versions registered a
    Windows scheduled task 'WingetAppSetup-ScheduledUpdates' (under '\winget-app-setup\') that ran a
    helper deployed to %APPDATA%\winget-app-setup — a helper that self-downloads from the repo and
    would break once removed. This migration unregisters that task and deletes the data directory so
    already-deployed machines transition cleanly. Safe to call when nothing is present (no-op).
.PARAMETER WhatIf
    When specified, only reports intended actions.
.RETURNS
    [bool] True when something was removed, otherwise False.
#>
function Remove-LegacyScheduledUpdates {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    $taskName = 'WingetAppSetup-ScheduledUpdates'
    $taskPath = '\winget-app-setup\'
    $appDataDir = Join-Path $env:APPDATA 'winget-app-setup'
    $removed = $false

    try {
        $task = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction Stop
    }
    catch {
        $task = $null
    }
    if ($task) {
        if ($WhatIf) {
            Write-Info "[DRY-RUN] Would remove the legacy scheduled task '$taskPath$taskName'."
        }
        else {
            Unregister-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Confirm:$false -ErrorAction SilentlyContinue
            Write-Info 'Removed the legacy scheduled-update task (updates are now handled by Winget-AutoUpdate).'
        }
        $removed = $true
    }

    if (Test-Path $appDataDir) {
        if ($WhatIf) {
            Write-Info "[DRY-RUN] Would remove the legacy update data directory '$appDataDir'."
        }
        else {
            Remove-Item -Path $appDataDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        $removed = $true
    }

    return $removed
}

# --- WingetCore ---
<#
.SYNOPSIS
    Ensures the Microsoft.WinGet.Client module is available, installing it if necessary.
.DESCRIPTION
    Checks for the module locally and attempts installation via PowerShell Gallery when missing, including ensuring the NuGet provider is present.
.RETURNS
    [bool] True when the module is available (either already installed or installed successfully), otherwise False.
#>
function Test-AndInstallWingetModule {
    try {
        if (Get-Module -ListAvailable -Name 'Microsoft.WinGet.Client') {
            return $true
        }

        Write-WarningMessage 'Microsoft.WinGet.Client module not found. Attempting installation...'

        $nugetProvider = Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue
        if (-not $nugetProvider) {
            Write-WarningMessage 'NuGet package provider not found. Installing...'
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null
        }

        Install-Module -Name Microsoft.WinGet.Client -Scope AllUsers -Force -AllowClobber -ErrorAction Stop

        $installedModule = Get-Module -ListAvailable -Name 'Microsoft.WinGet.Client' | Select-Object -First 1
        if ($installedModule) {
            if ($installedModule.Version) {
                Write-Success "Microsoft.WinGet.Client module installed successfully (Version: $($installedModule.Version))"
            }
            else {
                Write-Success 'Microsoft.WinGet.Client module installed successfully'
            }
            return $true
        }

        Write-Warning 'Microsoft.WinGet.Client module installation completed, but module is still not detected.'
    }
    catch {
        Write-Warning "Failed to install Microsoft.WinGet.Client module: $_"
    }

    return $false
}

<#
.SYNOPSIS
    Checks if winget is available and attempts to install it if not.
.DESCRIPTION
    This function verifies if winget is installed and available. If not, it attempts to install the Microsoft App Installer.
.RETURNS
    [bool] True if winget is available or successfully installed, otherwise False.
#>
function Test-AndInstallWinget {
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Success 'Winget is available.'
        return $true
    }
    else {
        # Prefer Repair-WinGetPackageManager when the WinGet PowerShell module is available: it
        # registers the App Installer package for the current account even without an interactive
        # logon session, where a plain Add-AppxPackage is blocked with 0x80073D19
        # (microsoft/winget-cli#3862, issue #159).
        if (Get-Command Repair-WinGetPackageManager -ErrorAction SilentlyContinue) {
            Write-WarningMessage 'Winget is not available. Bootstrapping it via Repair-WinGetPackageManager...'
            try {
                Repair-WinGetPackageManager -Latest -Force -ErrorAction Stop
                if (Get-Command winget -ErrorAction SilentlyContinue) {
                    Write-Success 'Winget bootstrapped successfully via Repair-WinGetPackageManager.'
                    return $true
                }
                Write-WarningMessage 'Repair-WinGetPackageManager completed but winget is still unavailable. Falling back to App Installer download...'
            }
            catch {
                Write-WarningMessage "Repair-WinGetPackageManager failed: $_. Falling back to App Installer download..."
            }
        }

        Write-WarningMessage 'Winget is not available. Attempting to install Microsoft App Installer...'
        try {
            $url = 'https://aka.ms/getwinget'
            $outFile = "$env:TEMP\Microsoft.DesktopAppInstaller.appxbundle"
            Invoke-WebRequest -Uri $url -OutFile $outFile -UseBasicParsing
            Add-AppxPackage $outFile
            Remove-Item $outFile -ErrorAction SilentlyContinue

            # Verify the registration actually made winget available, like the Repair path above —
            # Add-AppxPackage can complete without winget landing on PATH (issue #177).
            if (Get-Command winget -ErrorAction SilentlyContinue) {
                Write-Success 'Microsoft App Installer installed successfully. Winget is now available.'
                return $true
            }

            Write-ErrorMessage 'Microsoft App Installer was registered, but winget is still unavailable.'
            Write-ErrorMessage 'Please install winget manually from https://aka.ms/getwinget'
            return $false
        }
        catch {
            Write-ErrorMessage "Failed to install winget: $_"
            Write-ErrorMessage 'Please install winget manually from https://aka.ms/getwinget'
            return $false
        }
    }
}

<#
.SYNOPSIS
    Tests if winget sources are accessible and attempts to repair them if broken.
.DESCRIPTION
    Runs a basic winget source list command to verify the "winget" source is accessible.
    If the source is broken or missing (e.g., when running as admin on a standard user
    account), the function attempts to re-register it using Add-AppxPackage from the
    Microsoft CDN. After repair, it retries the source check once. If still failing, a
    clear error message with manual remediation guidance is displayed.
.RETURNS
    [bool] True if winget sources are accessible (or successfully repaired), otherwise False.
#>
function Test-WingetSources {
    Write-Info 'Checking winget sources...'

    # Probe the source (listed + functional). The same helper is reused for the post-repair
    # re-probe below so the two checks can never diverge again (issue #177).
    $health = Test-WingetSourceHealth

    # If both checks pass, sources are good
    if ($health.Healthy) {
        return $true
    }

    # If source is missing entirely, attempt repair
    if (-not $health.Listed) {
        Write-WarningMessage 'Winget source "winget" appears to be missing. Attempting to repair...'
    }
    else {
        Write-WarningMessage 'Winget source data is corrupted. Attempting to repair...'
    }

    # Attempt repair: first try source reset, then re-register package
    try {
        Write-Info 'Running winget source reset...'
        $resetOutput = winget source reset --force --disable-interactivity --accept-source-agreements 2>&1
        Write-Info 'Source reset completed.'
    }
    catch {
        Write-WarningMessage "Winget source reset failed: $_"
    }

    try {
        Write-Info 'Re-registering winget source package...'
        Add-AppxPackage -Path 'https://cdn.winget.microsoft.com/cache/source.msix' -ErrorAction Stop
        Write-Info 'Winget source package registered. Retrying source check...'
    }
    catch {
        Write-ErrorMessage "Failed to register winget source package: $_"
        Write-ErrorMessage 'Manual remediation steps:'
        Write-ErrorMessage '  1. Run as local user (not as admin): Add-AppxPackage -Path "https://cdn.winget.microsoft.com/cache/source.msix"'
        Write-ErrorMessage '  2. Or run: winget source reset --force'
        return $false
    }

    # Retry both checks after repair (quiet: this function reports the outcome itself)
    $health = Test-WingetSourceHealth -Quiet

    if ($health.Healthy) {
        Write-Success 'Winget sources are now accessible and functional.'
        return $true
    }

    Write-ErrorMessage 'Winget sources are still not accessible after repair attempt.'
    Write-ErrorMessage 'Manual remediation steps:'
    Write-ErrorMessage '  1. Run as local user (not as admin): Add-AppxPackage -Path "https://cdn.winget.microsoft.com/cache/source.msix"'
    Write-ErrorMessage '  2. Or run: winget source reset --force'
    return $false
}

<#
.SYNOPSIS
    Initializes winget sources and agreements for the account performing the installs.
.DESCRIPTION
    Winget state — source registration and agreement acceptance — is per-user. When the script is
    elevated as a different account than the interactively logged-on user (e.g. an admin-* account
    entered at the UAC prompt), that account has no interactive logon session, and winget's
    first-use bootstrap (registering the Microsoft.Winget.Source MSIX package for the account) is
    blocked by the AppX deployment service with 0x80073D19
    (ERROR_DEPLOYMENT_BLOCKED_BY_USER_LOG_OFF). Every install then fails, and no amount of
    retrying helps because the missing per-user state is persistent (issues #81/#104/#150, #159).

    This function probes with `winget source update --name winget` (which forces the winget-source
    first-use bootstrap; agreements are accepted by the install commands, which pass
    `--accept-source-agreements`). When the probe fails, it bootstraps winget for the account via
    Repair-WinGetPackageManager — which registers the App Installer and Microsoft.Winget.Source
    packages even without an interactive logon session (microsoft/winget-cli#6334) — and probes
    again.
.PARAMETER WhatIf
    When specified, only reports intended actions without executing.
.RETURNS
    [bool] True when sources are initialized and agreements accepted for the current account,
    otherwise False.
#>
function Initialize-WingetSourcesForUser {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    if ($WhatIf) {
        Write-Info '[DRY-RUN] Would initialize winget sources and agreements for the current account'
        return $true
    }

    # 0x80073D19 (ERROR_DEPLOYMENT_BLOCKED_BY_USER_LOG_OFF) as a signed Int32.
    $deploymentBlockedExitCode = -2147009255
    # 0x8A150046 (APPINSTALLER_CLI_ERROR_SOURCE_AGREEMENTS_NOT_ACCEPTED) as a signed Int32.
    $agreementsNotAcceptedExitCode = -1978335162

    $processUser = Get-ProcessUserName
    $sessionUser = Get-InteractiveSessionUserName
    $isCrossUserElevation = ($processUser -and $sessionUser -and ($processUser -ne $sessionUser))
    if ($isCrossUserElevation) {
        Write-WarningMessage "Cross-user elevation detected: running as '$processUser' while '$sessionUser' owns the interactive session."
        Write-WarningMessage "Winget sources and agreements are per-user; initializing them for '$processUser'."
    }

    Write-Info 'Initializing winget sources for the current account (this may take a moment)...'
    $probe = Invoke-WingetSourceProbe
    if ($probe.Succeeded) {
        Write-Success 'Winget sources are initialized and agreements accepted for this account.'
        return $true
    }

    if ($probe.ExitCode -eq $deploymentBlockedExitCode) {
        Write-WarningMessage 'Winget source bootstrap was blocked by the AppX deployment service (0x80073D19): this account has no interactive logon session.'
    }
    elseif ($probe.ExitCode -eq $agreementsNotAcceptedExitCode) {
        Write-WarningMessage 'Winget source agreements are not yet accepted for this account (0x8A150046).'
    }
    elseif ($null -ne $probe.ExitCode) {
        Write-WarningMessage "Winget source update failed with exit code: $($probe.ExitCode)"
    }

    # Bootstrap via the WinGet PowerShell module: unlike winget's own first-use bootstrap (and
    # unlike a plain Add-AppxPackage), Repair-WinGetPackageManager registers the App Installer and
    # Microsoft.Winget.Source packages for the current account even without an interactive logon
    # session (microsoft/winget-cli#6334).
    if (Get-Command Repair-WinGetPackageManager -ErrorAction SilentlyContinue) {
        Write-Info 'Bootstrapping winget for this account via Repair-WinGetPackageManager...'
        try {
            Repair-WinGetPackageManager -Latest -Force -ErrorAction Stop
        }
        catch {
            Write-WarningMessage "Repair-WinGetPackageManager failed: $_"
        }

        $probe = Invoke-WingetSourceProbe
        if ($probe.Succeeded) {
            Write-Success 'Winget sources initialized for this account after repair.'
            return $true
        }
    }
    else {
        Write-WarningMessage 'Repair-WinGetPackageManager is unavailable (Microsoft.WinGet.Client module missing); skipping winget bootstrap repair.'
    }

    Write-WarningMessage "Winget sources could not be initialized for '$processUser'. Installations may fail with 0x80073D19."
    if ($isCrossUserElevation) {
        Write-WarningMessage "Fix: log on to Windows interactively as '$processUser' once (this registers winget for that account), or run 'winget source update' from any session running as '$processUser', then re-run this script."
    }
    return $false
}

<#
.SYNOPSIS
    Installs a single winget package, retrying the transient 0x80073d19 session error with backoff.
.DESCRIPTION
    Runs `winget install` for one package id and captures winget's real process exit code via
    Start-Process -PassThru -Wait. Exit code 0x80073d19 (ERROR_INSTALL_USER_LOGOFF — "an error
    occurred because a user was logged off") is a transient MSIX/session-deployment race: an
    immediate retry simply hits the same race, which is why issues #81/#100/#102 left it unresolved.
    When that specific code is seen, this function waits with an increasing backoff and retries, up
    to MaxAttempts. Any other exit code (success or a real failure) is returned immediately so the
    caller can verify the result with `winget list` as before.

    winget's output is intentionally left unredirected so its native progress is still shown to the
    user; the session error is identified purely from the exit code, which winget reports as
    0x80073d19 for this failure.

    Installs prefer `--scope machine` (issue #159): user-scope installs land in the elevated
    account's profile rather than the logged-on user's, and packages that ship both MSIX and MSI
    installers (e.g. Microsoft.PowerShell) resolve at user scope to the MSIX — whose per-user AppX
    deployment is exactly what 0x80073D19 blocks under cross-user elevation. When a package has no
    machine-scope installer (e.g. the MSIX-only Microsoft.WindowsTerminal), winget returns
    0x8A150010 (NO_APPLICABLE_INSTALLER) and the install is retried once at winget's default scope.
.PARAMETER PackageId
    The winget package id to install (e.g. 'Microsoft.PowerShell').
.PARAMETER InstallerType
    Optional winget installer-type override (e.g. 'wix' to force the MSI), passed as
    `--installer-type <value>`. Needed for PowerShell: even with --scope machine, winget's
    installer-type precedence still selects the default MSIX, whose machine-scope provisioning fails
    as a packaged app on Windows < build 26100 with 0x8A150113 ("system configuration does not
    support"). Forcing 'wix' installs the machine-wide MSI instead (issue #163).
.PARAMETER MaxAttempts
    Maximum number of install attempts while the session error keeps recurring. Default 3.
.PARAMETER InitialDelaySeconds
    Seconds to wait before the first retry; the wait doubles on each subsequent retry. Default 5.
.RETURNS
    [hashtable] @{ ExitCode = <int>; Attempts = <int>; SessionErrorExhausted = <bool>; MachineScopeFellBack = <bool> }
    SessionErrorExhausted is True only when every attempt failed with the session error.
    MachineScopeFellBack is True when the package had no machine-scope installer and the install
    was retried at winget's default scope. Attempts counts install attempts at the finally
    selected scope; the one-time scope fallback does not consume a session-error attempt.
#>
function Install-WingetPackage {
    param (
        [Parameter(Mandatory = $true)]
        [string]$PackageId,

        [Parameter(Mandatory = $false)]
        [string]$InstallerType,

        [Parameter(Mandatory = $false)]
        [int]$MaxAttempts = 3,

        [Parameter(Mandatory = $false)]
        [int]$InitialDelaySeconds = 5
    )

    # 0x80073D19 (ERROR_DEPLOYMENT_BLOCKED_BY_USER_LOG_OFF) as a signed Int32, which is how winget
    # reports it through Process.ExitCode.
    $sessionLogoffExitCode = -2147009255
    # 0x8A150010 (APPINSTALLER_CLI_ERROR_NO_APPLICABLE_INSTALLER) as a signed Int32: returned when
    # the --scope machine requirement filters out every installer in the package's manifest.
    $noApplicableInstallerExitCode = -1978335216

    $attempt = 0
    $delay = $InitialDelaySeconds
    $exitCode = 0
    $useMachineScope = $true
    $machineScopeFellBack = $false

    while ($attempt -lt $MaxAttempts) {
        $attempt++

        $installArgs = @(
            'install', '-e',
            '--accept-source-agreements', '--accept-package-agreements',
            '--source', 'winget',
            '--id', $PackageId
        )
        if ($useMachineScope) {
            $installArgs += @('--scope', 'machine')
        }
        if (-not [string]::IsNullOrWhiteSpace($InstallerType)) {
            $installArgs += @('--installer-type', $InstallerType)
        }

        $proc = Start-Process -FilePath 'winget' -ArgumentList $installArgs -NoNewWindow -Wait -PassThru
        $exitCode = $proc.ExitCode

        # No installer matched the machine-scope requirement (e.g. MSIX-only packages such as
        # Microsoft.WindowsTerminal, which only install per-user). Fall back to winget's default
        # scope once; this is a manifest property, not a transient error, so it does not consume
        # one of the session-error attempts.
        if ($useMachineScope -and $exitCode -eq $noApplicableInstallerExitCode) {
            Write-Info "$PackageId has no machine-scope installer. Retrying with winget's default scope..."
            $useMachineScope = $false
            $machineScopeFellBack = $true
            $attempt--
            continue
        }

        # Anything other than the transient session error (success or a real failure) is final here;
        # the caller verifies the actual install state with `winget list`.
        if ($exitCode -ne $sessionLogoffExitCode) {
            break
        }

        if ($attempt -lt $MaxAttempts) {
            Write-WarningMessage "Install of $PackageId hit transient session error 0x80073D19 (a user was logged off). Waiting ${delay}s before retry $($attempt + 1) of ${MaxAttempts}..."
            Start-Sleep -Seconds $delay
            $delay = $delay * 2
        }
        else {
            Write-WarningMessage "Install of $PackageId still failing with session error 0x80073D19 after ${MaxAttempts} attempts."
        }
    }

    return @{
        ExitCode              = $exitCode
        Attempts              = $attempt
        SessionErrorExhausted = ($exitCode -eq $sessionLogoffExitCode)
        MachineScopeFellBack  = $machineScopeFellBack
    }
}

<#
.SYNOPSIS
    Returns true when winget reports the given package id as installed for the current account.
.PARAMETER PackageId
    The winget package id to check.
#>
function Test-WingetPackageInstalled {
    param (
        [Parameter(Mandatory = $true)]
        [string]$PackageId
    )

    try {
        $output = winget list --exact --id $PackageId --accept-source-agreements --disable-interactivity 2>&1
        return ([String]::Join('', $output)).Contains($PackageId)
    }
    catch {
        return $false
    }
}

<#
.SYNOPSIS
    Returns true when an MSIX/Appx package matching the given DisplayName/PackageName pattern is
    provisioned for all users on this machine.
.PARAMETER NameLike
    A wildcard pattern matched against provisioned packages' DisplayName and PackageName.
#>
function Test-AppxPackageProvisioned {
    param (
        [Parameter(Mandatory = $true)]
        [string]$NameLike
    )

    try {
        $provisioned = Get-AppxProvisionedPackage -Online -ErrorAction Stop
        return [bool]($provisioned | Where-Object { $_.DisplayName -like $NameLike -or $_.PackageName -like $NameLike })
    }
    catch {
        return $false
    }
}

<#
.SYNOPSIS
    Provisions a downloaded MSIX package (and its dependencies) for all users via DISM.
.DESCRIPTION
    Thin, mockable wrapper around Add-AppxProvisionedPackage. The Appx/DISM provider is unreliable
    under PowerShell 7 (it throws 0x80131539 "Operation is not supported on this platform"), so when
    running under pwsh the provisioning is delegated to Windows PowerShell 5.1. Returns True on
    success. A winget-source MSIX has no Store license, so -SkipLicense is used when no license file
    was downloaded alongside it.
.PARAMETER PackagePath
    Full path to the .msixbundle/.msix to provision.
.PARAMETER DependencyPackagePath
    Full paths to dependency packages (e.g. Microsoft.WindowsAppRuntime, VCLibs).
.PARAMETER LicensePath
    Optional path to a downloaded license .xml.
#>
function Invoke-AppxProvisioning {
    param (
        [Parameter(Mandatory = $true)]
        [string]$PackagePath,

        [Parameter(Mandatory = $false)]
        [string[]]$DependencyPackagePath = @(),

        [Parameter(Mandatory = $false)]
        [string]$LicensePath
    )

    $hasLicense = $LicensePath -and (Test-Path $LicensePath)

    try {
        if ($PSVersionTable.PSEdition -eq 'Core') {
            # Delegate to Windows PowerShell 5.1, where the Appx/DISM provider works.
            # Every path is interpolated into a single-quoted literal inside the delegated
            # -Command string, so escape embedded single quotes by doubling them (issue #178).
            # Otherwise an apostrophe in a path (e.g. C:\Users\O'Brien\...) unbalances the
            # quoting — breaking provisioning at best, and at worst letting a crafted filename
            # break out of the literal inside an elevated powershell.exe -Command.
            $escapedPackagePath = $PackagePath.Replace("'", "''")
            $depClause = if ($DependencyPackagePath.Count -gt 0) {
                $escapedDependencyPaths = @($DependencyPackagePath | ForEach-Object { $_.Replace("'", "''") })
                "-DependencyPackagePath @('" + ($escapedDependencyPaths -join "','") + "')"
            }
            else { '' }
            $licClause = if ($hasLicense) { "-LicensePath '$($LicensePath.Replace("'", "''"))'" } else { '-SkipLicense' }
            $command = "Add-AppxProvisionedPackage -Online -PackagePath '$escapedPackagePath' $depClause $licClause -ErrorAction Stop | Out-Null"
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $command
            return ($LASTEXITCODE -eq 0)
        }

        $params = @{ Online = $true; PackagePath = $PackagePath; ErrorAction = 'Stop' }
        if ($DependencyPackagePath.Count -gt 0) { $params.DependencyPackagePath = $DependencyPackagePath }
        if ($hasLicense) { $params.LicensePath = $LicensePath } else { $params.SkipLicense = $true }
        Add-AppxProvisionedPackage @params | Out-Null
        return $true
    }
    catch {
        Write-ErrorMessage "Add-AppxProvisionedPackage failed for '$PackagePath': $_"
        return $false
    }
}

<#
.SYNOPSIS
    Installs the latest MSIX build of a winget package machine-wide by provisioning it via DISM.
.DESCRIPTION
    Used for the holdout case where a package is MSIX-only (e.g. PowerShell 7.7+) AND the machine is
    Windows older than build 26100, where winget cannot machine-scope-provision an MSIX because it
    calls the provisioning API from a packaged process. This function instead downloads the latest
    MSIX (plus dependencies and license) with `winget download`, then provisions it for all users
    with Add-AppxProvisionedPackage from a NON-packaged process, which is not subject to that bug
    (issue #166).

    VALIDATION NOTE: the DISM path is dormant until a package's winget default becomes MSIX-only
    (PowerShell 7.7 GA). It is covered by unit tests with mocked external calls, but the end-to-end
    behavior (winget download layout, license handling, all-users provisioning under cross-user
    elevation) should be validated on a real Windows 10 machine before it is relied upon.
.PARAMETER PackageId
    The winget package id to provision (e.g. 'Microsoft.PowerShell').
.PARAMETER VerifyNameLike
    Wildcard matched against provisioned package names to confirm success. Defaults to *<last id
    segment>* (e.g. '*PowerShell*').
.RETURNS
    [hashtable] @{ ExitCode = <int>; Installed = <bool> }
#>
function Install-MsixProvisionedPackage {
    param (
        [Parameter(Mandatory = $true)]
        [string]$PackageId,

        [Parameter(Mandatory = $false)]
        [string]$VerifyNameLike
    )

    if (-not $VerifyNameLike) {
        $VerifyNameLike = '*' + ($PackageId -split '\.')[-1] + '*'
    }

    $downloadDir = Join-Path $env:TEMP ('winget-msix-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null

    try {
        Write-Info "Downloading the latest MSIX for $PackageId to provision it machine-wide..."
        $downloadArgs = @(
            'download', '-e', '--id', $PackageId, '--source', 'winget', '--installer-type', 'msix',
            '--accept-source-agreements', '--accept-package-agreements',
            '--download-directory', $downloadDir
        )
        $download = Start-Process -FilePath 'winget' -ArgumentList $downloadArgs -NoNewWindow -Wait -PassThru
        if ($download.ExitCode -ne 0) {
            Write-ErrorMessage "winget download failed for $PackageId (exit code $($download.ExitCode))."
            return @{ ExitCode = $download.ExitCode; Installed = $false }
        }

        $downloaded = Get-ChildItem -Path $downloadDir -Recurse -File -ErrorAction SilentlyContinue
        $bundle = $downloaded |
            Where-Object { $_.Extension -in '.msixbundle', '.appxbundle', '.msix', '.appx' -and $_.FullName -notmatch '[\\/]Dependencies[\\/]' } |
            Select-Object -First 1
        if (-not $bundle) {
            Write-ErrorMessage "No MSIX package was found in the winget download for $PackageId."
            return @{ ExitCode = -1; Installed = $false }
        }
        $dependencies = @($downloaded |
                Where-Object { $_.Extension -in '.msix', '.appx' -and $_.FullName -match '[\\/]Dependencies[\\/]' } |
                ForEach-Object { $_.FullName })
        $license = $downloaded | Where-Object { $_.Extension -eq '.xml' -and $_.Name -match 'License' } | Select-Object -First 1

        Write-Info "Provisioning $($bundle.Name) for all users..."
        $provisioned = Invoke-AppxProvisioning -PackagePath $bundle.FullName -DependencyPackagePath $dependencies -LicensePath $license.FullName

        $installed = $provisioned -and (Test-AppxPackageProvisioned -NameLike $VerifyNameLike)
        if ($installed) {
            Write-Success "$PackageId provisioned machine-wide via DISM."
        }
        else {
            Write-ErrorMessage "Failed to provision $PackageId machine-wide."
        }
        return @{ ExitCode = if ($installed) { 0 } else { -1 }; Installed = $installed }
    }
    finally {
        Remove-Item -Path $downloadDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

<#
.SYNOPSIS
    Installs the newest available PowerShell, choosing a delivery that works in an elevated
    cross-user / machine-scope context (no version pinning).
.DESCRIPTION
    winget's default already tracks the latest PowerShell, so this never pins a version. It only
    chooses HOW to deliver the latest so the install works machine-wide when the script is elevated
    as a different account than the logged-on user (issues #163/#166):

      1. Prefer the MSI while the current line still ships one (<= 7.6). The MSI installs machine-wide,
         works on any Windows build, and is runnable under Task Scheduler.
      2. Once the MSI is gone (7.7+), winget offers only the MSIX:
         - Windows 24H2+ (build >= 26100): winget can machine-scope-provision the MSIX, so install the
           default package directly.
         - Older Windows: winget's machine-scope MSIX provisioning is broken (it calls the provisioning
           API from a packaged process), so provision the MSIX for all users via DISM instead.

    The result's Installed flag is authoritative — the DISM-provisioned path does not appear under
    `winget list` for the elevating account, so the caller must not re-verify PowerShell with winget.
.RETURNS
    [hashtable] @{ ExitCode = <int>; Installed = <bool>; Method = 'msi' | 'msix-native' | 'msix-provisioned' }
#>
function Install-PowerShellLatest {
    param (
        [Parameter(Mandatory = $false)]
        [string]$PackageId = 'Microsoft.PowerShell'
    )

    # 0x8A150010 (APPINSTALLER_CLI_ERROR_NO_APPLICABLE_INSTALLER) as a signed Int32 — what winget
    # returns for `--installer-type wix` once the manifest no longer ships an MSI.
    $noApplicableInstallerExitCode = -1978335216

    # 1. Prefer the MSI while the latest version still ships one.
    $result = Install-WingetPackage -PackageId $PackageId -InstallerType 'wix'
    if ($result.ExitCode -ne $noApplicableInstallerExitCode) {
        return @{ ExitCode = $result.ExitCode; Installed = (Test-WingetPackageInstalled -PackageId $PackageId); Method = 'msi' }
    }

    # 2. No MSI for the latest version (7.7+): install the latest MSIX machine-wide.
    Write-Info "No MSI is available for the latest $PackageId; installing the MSIX package instead."
    if ((Get-WindowsBuildNumber) -ge 26100) {
        $result = Install-WingetPackage -PackageId $PackageId
        return @{ ExitCode = $result.ExitCode; Installed = (Test-WingetPackageInstalled -PackageId $PackageId); Method = 'msix-native' }
    }

    $provision = Install-MsixProvisionedPackage -PackageId $PackageId
    return @{ ExitCode = $provision.ExitCode; Installed = $provision.Installed; Method = 'msix-provisioned' }
}

# ------------------------------------------------Main Script------------------------------------------------

if ($MyInvocation.InvocationName -ne '.') {
    if (-not $SkipSystemCheck) {
        if ($WhatIf) {
            Write-Info '[DRY-RUN] Running pre-flight system checks (OS version, disk space, network).'
            if (-not (Test-SystemRequirements -WhatIf:$WhatIf)) {
                Write-WarningMessage '[DRY-RUN] A blocking pre-flight check failed — a real run would abort here.'
            }
        }
        elseif (-not (Test-SystemRequirements -WhatIf:$WhatIf)) {
            exit 1
        }
    }

    # Forward -SkipSystemCheck so an elevated relaunch inherits the caller's intent to bypass the
    # pre-flight checks (issue #185); the checks themselves already ran (or were skipped) above.
    Invoke-WingetInstall -WhatIf:$WhatIf -NonInteractive:$NonInteractive -SkipSystemCheck:$SkipSystemCheck
}
