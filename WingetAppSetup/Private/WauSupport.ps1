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
    Reads a directory's owner and access entries as SIDs.
.DESCRIPTION
    Thin seam over Get-Acl (Windows-only, mocked in tests) for Assert-RestrictedDirectoryAcl.
    Every entry is read, explicit and inherited, by SID, so the result does not depend on the
    display language. Name is the account name when the SID resolves, for messages. Throws when
    the access list cannot be read.
.PARAMETER Path
    The directory to read.
.RETURNS
    [pscustomobject] with OwnerSid, OwnerName, InheritanceProtected ([bool], true when the
    directory inherits nothing from its parent) and AccessRules (Sid, Name, AccessControlType
    'Allow'/'Deny', IsInherited).
#>
function Get-DirectoryAccessSummary {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $sidType = [System.Security.Principal.SecurityIdentifier]
    $nameOf = {
        param ($Identity)
        try {
            return [string]$Identity.Translate([System.Security.Principal.NTAccount]).Value
        }
        catch {
            return [string]$Identity.Value
        }
    }

    $owner = $acl.GetOwner($sidType)
    $rules = @(foreach ($rule in @($acl.GetAccessRules($true, $true, $sidType))) {
            [pscustomobject]@{
                Sid               = [string]$rule.IdentityReference.Value
                Name              = (& $nameOf $rule.IdentityReference)
                AccessControlType = [string]$rule.AccessControlType
                IsInherited       = [bool]$rule.IsInherited
            }
        })

    $ownerSid = $null
    $ownerName = $null
    if ($owner) {
        $ownerSid = [string]$owner.Value
        $ownerName = & $nameOf $owner
    }
    return [pscustomobject]@{
        OwnerSid             = $ownerSid
        OwnerName            = $ownerName
        InheritanceProtected = [bool]$acl.AreAccessRulesProtected
        AccessRules          = $rules
    }
}

<#
.SYNOPSIS
    Throws unless a directory is owned by Administrators (or SYSTEM) and only SYSTEM and
    Administrators have access entries on it.
.DESCRIPTION
    Review finding P2-21. Checks what Set-RestrictedDirectoryAcl was meant to leave behind, from the
    directory's own access list, so a failed or partial change is caught before anything is
    downloaded into it. Fails on any of:
      - an owner other than Administrators (S-1-5-32-544) or SYSTEM (S-1-5-18): an object's owner
        can always change its access list, whatever the list says;
      - an access entry, allow or deny, explicit or inherited, for any other account;
      - inheritance from the parent folder still turned on.
.PARAMETER Path
    The directory to check.
#>
function Assert-RestrictedDirectoryAcl {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $allowedSids = @('S-1-5-18', 'S-1-5-32-544')
    $security = Get-DirectoryAccessSummary -Path $Path
    $problems = @()
    if ($allowedSids -notcontains $security.OwnerSid) {
        $problems += "it is owned by $($security.OwnerName) ($($security.OwnerSid))"
    }
    if (-not $security.InheritanceProtected) {
        $problems += 'it still inherits permissions from its parent folder'
    }
    foreach ($rule in @($security.AccessRules)) {
        if ($allowedSids -notcontains $rule.Sid) {
            $problems += "$($rule.Name) ($($rule.Sid)) has an access entry ($($rule.AccessControlType.ToLowerInvariant()))"
        }
    }
    if ($problems.Count -gt 0) {
        throw ("'{0}' is not limited to SYSTEM and Administrators: {1}." -f $Path, ($problems -join '; '))
    }
}

<#
.SYNOPSIS
    Locks a directory down to SYSTEM and Administrators (owner Administrators, full control,
    inheritance removed) and checks the result.
.DESCRIPTION
    Used to protect the WAU MSI staging directory so a same-user non-elevated process cannot swap
    the file between hash verification and msiexec (TOCTOU, issue #186). Grants use well-known SIDs
    (S-1-5-18 = SYSTEM, S-1-5-32-544 = Administrators) instead of account names so the ACL applies
    on non-English Windows.

    Ownership comes first (review finding P2-21): the installer's first, non-elevated launch
    creates %ProgramData%\winget-app-setup for its log, so the signed-in user owns it, and an owner
    can always rewrite the access list, whatever the list says. Removing the inherited entries
    alone left that user able to give themselves full control again and swap the staging folder.
    So icacls first makes Administrators the owner, then removes the inherited entries and replaces
    (/grant:r) any explicit ones for SYSTEM and Administrators, and Assert-RestrictedDirectoryAcl
    then reads the result back: any other owner or entry (an explicit entry another account added
    survives /grant:r) fails the call instead of being used.

    Changes only the directory itself (no /T and no /reset), so the explicit read grant that
    Grant-InstallLogReadAccess puts on the logs folder inside %ProgramData%\winget-app-setup stays
    in place: standard users can still open the logs. /q keeps icacls's per-folder success line
    off the console; its errors still show.

    Throws when icacls fails or the check does: callers must treat the directory as unsafe to use.
    Those two failures carry the error id 'RestrictedDirectoryAclFailed', so a caller can tell them
    from any other (icacls.exe not starting, say) and suggest resetting the folder's owner and
    access list only when that is what went wrong.
.PARAMETER Path
    The directory whose ACL should be replaced.
#>
function Set-RestrictedDirectoryAcl {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $failure = $null
    $steps = @(
        @{
            Arguments   = "`"$Path`" /setowner *S-1-5-32-544 /q"
            Description = 'make Administrators the owner of'
        },
        @{
            # /inheritance:r strips inherited ACEs; /grant:r replaces any explicit SYSTEM and
            # Administrators entries with these (OI)(CI)F grants, inherited by everything created
            # inside.
            Arguments   = "`"$Path`" /inheritance:r /grant:r *S-1-5-18:(OI)(CI)F *S-1-5-32-544:(OI)(CI)F /q"
            Description = 'restrict'
        }
    )
    foreach ($step in $steps) {
        $proc = Start-Process -FilePath 'icacls.exe' -ArgumentList $step.Arguments -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -ne 0) {
            $failure = "icacls failed to $($step.Description) '$Path' (exit code $($proc.ExitCode))."
            break
        }
    }
    if (-not $failure) {
        try {
            Assert-RestrictedDirectoryAcl -Path $Path
        }
        catch {
            $failure = "$_"
        }
    }
    if ($failure) {
        $exception = [System.InvalidOperationException]::new($failure)
        throw [System.Management.Automation.ErrorRecord]::new($exception, 'RestrictedDirectoryAclFailed', [System.Management.Automation.ErrorCategory]::SecurityError, $Path)
    }
}

<#
.SYNOPSIS
    Opens a file for reading so that nobody can change, rename or delete it while it is open.
.DESCRIPTION
    Review finding P2-21. FileShare.Read lets other processes (msiexec) open the file for reading
    only: while the returned stream is open, Windows refuses to open the file for writing or
    deleting, so it cannot be overwritten, renamed or deleted, and the folder holding it cannot be
    renamed. Hashing from this stream and keeping it open until msiexec has finished means msiexec
    installs exactly the bytes that were hashed. The caller disposes the stream.
.PARAMETER Path
    The file to open.
.RETURNS
    [System.IO.FileStream]
#>
function Open-ReadLockedFile {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
}

<#
.SYNOPSIS
    Creates a fresh, ACL-restricted staging directory for a download that runs elevated: the WAU
    MSI, or the Windows App Runtime framework (Install-WindowsAppRuntimeFramework).
.DESCRIPTION
    %TEMP% is user-writable and the previous fixed path (%TEMP%\WAU-<version>.msi) was predictable,
    so a non-elevated process running as the same user could swap the MSI between Get-FileHash and
    msiexec (issue #186). The staging directory lives under %ProgramData%\winget-app-setup, is
    uniquely named per run, and is locked to SYSTEM + Administrators BEFORE anything is downloaded
    into it. The base directory is restricted first, and its owner changed to Administrators (the
    installer's non-elevated first launch creates it, owned by the signed-in user: review finding
    P2-21), so an unprivileged process cannot observe the per-run name or delete-and-recreate the
    staging directory through rights on the parent. Both are checked after the change
    (Set-RestrictedDirectoryAcl). Throws when the directory cannot be created or secured; only a
    failure to secure it carries the error id 'RestrictedDirectoryAclFailed'. Callers own cleanup
    (Remove-Item -Recurse).
.PARAMETER Prefix
    The start of the per-run folder's name, which ends with a new GUID. Default 'wau-msi'.
.RETURNS
    [string] The full path of the created staging directory.
#>
function New-WauStagingDirectory {
    param (
        [Parameter(Mandatory = $false)]
        [ValidatePattern('^[A-Za-z0-9-]+$')]
        [string]$Prefix = 'wau-msi'
    )

    $baseDir = Join-Path $env:ProgramData 'winget-app-setup'
    $null = New-Item -Path $baseDir -ItemType Directory -Force -ErrorAction Stop
    Set-RestrictedDirectoryAcl -Path $baseDir

    $stagingDir = Join-Path $baseDir ($Prefix + '-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -Path $stagingDir -ItemType Directory -Force -ErrorAction Stop
    Set-RestrictedDirectoryAcl -Path $stagingDir
    return $stagingDir
}

<#
.SYNOPSIS
    Lists the packages of one Windows App Runtime framework registered for any user.
.DESCRIPTION
    Thin query seam for Get-WindowsAppRuntimeStatus (mocked in tests). `Get-AppxPackage -AllUsers`
    needs elevation; under PowerShell 7 it runs in Windows PowerShell 5.1, where the Appx module
    always loads - the same delegation Invoke-AppxProvisioning uses. Throws when the query fails.
.PARAMETER Name
    The framework's package name, Microsoft.WindowsAppRuntime.1.8 by default. It may come from a
    file read from the web (Get-WindowsAppRuntimeRequirement), so only the characters a package
    name can have are accepted: it goes into the Windows PowerShell command.
.RETURNS
    [pscustomobject[]] with Version ([version]) and Architecture ([string], e.g. 'X64', 'Arm64').
#>
function Get-WindowsAppRuntimePackageInfo {
    param (
        [Parameter(Mandatory = $false)]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9.\-]{2,49}\z')]
        [string]$Name = 'Microsoft.WindowsAppRuntime.1.8'
    )

    $query = "Get-AppxPackage -AllUsers -Name '$Name' -ErrorAction Stop | ForEach-Object { '{0}|{1}' -f `$_.Version, `$_.Architecture }"
    if ($PSVersionTable.PSEdition -eq 'Core') {
        $lines = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $query)
        if ($LASTEXITCODE -ne 0) {
            throw "Get-AppxPackage -AllUsers failed in Windows PowerShell (exit code $LASTEXITCODE)."
        }
    }
    else {
        $lines = @(Get-AppxPackage -AllUsers -Name $Name -ErrorAction Stop |
                ForEach-Object { '{0}|{1}' -f $_.Version, $_.Architecture })
    }

    foreach ($line in $lines) {
        $parts = "$line".Trim() -split '\|'
        $parsedVersion = $null
        if ($parts.Count -eq 2 -and [version]::TryParse($parts[0], [ref]$parsedVersion)) {
            [pscustomobject]@{ Version = $parsedVersion; Architecture = $parts[1] }
        }
    }
}

<#
.SYNOPSIS
    Returns the built-in Windows App Runtime requirement: Microsoft.WindowsAppRuntime.1.8
    8000.616.304.0 or newer.
.DESCRIPTION
    What every winget release from 1.12.350 through 1.29.380 and the 1.30.140 preview lists in its
    DesktopAppInstaller_Dependencies.json. Get-WindowsAppRuntimeStatus checks for it when it is
    given no requirement, and Get-WindowsAppRuntimeRequirement falls back to it when it cannot read
    the latest winget release's own list.
.RETURNS
    [pscustomobject] with Frameworks (one Name and MinimumVersion ([version]) per framework),
    Source ('BuiltIn') and Detail (where the requirement comes from, for messages).
#>
function Get-DefaultWindowsAppRuntimeRequirement {
    return [pscustomobject]@{
        Frameworks = @([pscustomobject]@{ Name = 'Microsoft.WindowsAppRuntime.1.8'; MinimumVersion = [version]'8000.616.304.0' })
        Source     = 'BuiltIn'
        Detail     = 'the built-in requirement'
    }
}

<#
.SYNOPSIS
    Formats a Windows App Runtime requirement for messages.
.PARAMETER Frameworks
    The requirement's Frameworks (or some of them).
.RETURNS
    [string] For example 'Microsoft.WindowsAppRuntime.1.8 >= 8000.616.304.0'; several are joined
    with ' and '.
#>
function Format-WindowsAppRuntimeRequirement {
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Frameworks
    )

    if ($Frameworks.Count -eq 0) {
        return 'no Windows App Runtime'
    }
    return (($Frameworks | ForEach-Object { '{0} >= {1}' -f $_.Name, $_.MinimumVersion }) -join ' and ')
}

<#
.SYNOPSIS
    Reads the Windows App Runtime frameworks a winget release depends on from its
    DesktopAppInstaller_Dependencies.json.
.DESCRIPTION
    That file is an asset of every winget-cli release since 1.11, and the list
    Repair-WinGetPackageManager reads too (Microsoft.WinGet.Client's WingetDependencies class):
    {"Dependencies": [{"Name": "...", "Version": "..."}, ...]}, one list for every architecture.
    A list per architecture is read as well, for this PC's: an "x64", "x86" or "arm64" property
    (any case) at the top or under "Dependencies", holding the list or an object with a
    "Dependencies" list. Only the Microsoft.WindowsAppRuntime entries are returned; the others
    (VCLibs, UI.Xaml) are ones Winget-AutoUpdate's Install-Prerequisites installs itself. A
    framework listed more than once keeps its highest version.
.PARAMETER Json
    The file's text.
.PARAMETER Architecture
    This PC's OS architecture as Get-OSArchitecture names it (X64, X86, Arm64), for a list per
    architecture; $null or empty when it is not known.
.RETURNS
    [pscustomobject[]] Name and MinimumVersion ([version]) for each Windows App Runtime framework
    the release lists; nothing when it lists none. Throws when the text is not JSON, holds no such
    list, an entry has no Name or no Version, or a Windows App Runtime entry's name or version is
    not one a package can have.
#>
function ConvertFrom-WingetDependenciesJson {
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Json,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Architecture
    )

    try {
        $document = $Json.TrimStart([char]0xFEFF) | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "it is not valid JSON ($($_.Exception.Message))"
    }
    if ($null -eq $document -or $document -isnot [System.Management.Automation.PSCustomObject]) {
        throw 'it is not a JSON object'
    }

    $dependencies = $null
    $dependenciesProperty = $document.PSObject.Properties['Dependencies']
    if ($dependenciesProperty -and $dependenciesProperty.Value -is [array]) {
        $dependencies = $dependenciesProperty.Value
    }
    elseif (-not [string]::IsNullOrWhiteSpace($Architecture)) {
        # A list per architecture: {"Dependencies": {"x64": ...}}, or {"x64": ...} at the top.
        $byArchitecture = $document
        if ($dependenciesProperty -and $dependenciesProperty.Value -is [System.Management.Automation.PSCustomObject]) {
            $byArchitecture = $dependenciesProperty.Value
        }
        $architectureProperty = $byArchitecture.PSObject.Properties[$Architecture]
        if ($architectureProperty) {
            $value = $architectureProperty.Value
            if ($value -is [array]) {
                $dependencies = $value
            }
            elseif ($value -is [System.Management.Automation.PSCustomObject] -and $value.PSObject.Properties['Dependencies'] -and $value.Dependencies -is [array]) {
                $dependencies = $value.Dependencies
            }
        }
    }
    if ($null -eq $dependencies) {
        if ([string]::IsNullOrWhiteSpace($Architecture)) {
            throw 'it holds no Dependencies list'
        }
        throw "it holds no Dependencies list, for all architectures or for $Architecture"
    }

    # PowerShell's hashtables compare keys without case, as package names are compared.
    $frameworks = @{}
    foreach ($entry in $dependencies) {
        $name = $null
        $versionText = $null
        if ($entry -is [System.Management.Automation.PSCustomObject]) {
            $name = [string]$entry.Name
            $versionText = [string]$entry.Version
        }
        if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($versionText)) {
            throw 'one of its entries has no Name or no Version'
        }
        if ($name -notlike 'Microsoft.WindowsAppRuntime*') {
            continue
        }
        if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9.\-]{2,49}\z') {
            throw "'$name' is not a package name"
        }
        $version = $null
        if (-not [version]::TryParse($versionText, [ref]$version)) {
            throw "'$versionText' ($name) is not a version"
        }
        if (-not $frameworks.ContainsKey($name) -or $frameworks[$name] -lt $version) {
            $frameworks[$name] = $version
        }
    }
    foreach ($name in @($frameworks.Keys | Sort-Object)) {
        [pscustomobject]@{ Name = $name; MinimumVersion = $frameworks[$name] }
    }
}

<#
.SYNOPSIS
    Works out which Windows App Runtime the winget release Winget-AutoUpdate installs needs.
.DESCRIPTION
    Every WAU run as SYSTEM installs the newest winget release from GitHub (Install-Prerequisites
    reads releases/latest) when the installed winget is older, without any framework it needs, and
    a winget whose framework is missing leaves winget unusable (#279/#284). Which framework that is
    comes from the release itself (product-F4, work-order item 32): its
    DesktopAppInstaller_Dependencies.json, through the download link of the release GitHub marks
    latest - the same release WAU's api.github.com query names - which the GitHub API's limit of 60
    calls an hour per address does not apply to. So a winget that needs a newer build or another
    framework family is checked for as such, rather than by the 1.8 constant, and
    Install-WindowsAppRuntimeFramework does not install its pinned 1.8 framework where that would
    not do. A newer framework family does not stand in for an older one.
    The lookup never stops the run: it has a 30-second time limit (Get-WebDownloadTimeoutParameters
    -Lookup), and when the file cannot be read (no network, a proxy, GitHub down, a format this
    does not know) or lists no Windows App Runtime, the built-in requirement
    (Get-DefaultWindowsAppRuntimeRequirement) is used, with a warning. Writes one line that names
    the requirement and where it comes from.
.RETURNS
    [pscustomobject] as Get-DefaultWindowsAppRuntimeRequirement returns it, with Source
    'LatestRelease' when it comes from the release, or 'BuiltIn'.
#>
function Get-WindowsAppRuntimeRequirement {
    $url = 'https://github.com/microsoft/winget-cli/releases/latest/download/DesktopAppInstaller_Dependencies.json'
    $fallback = Get-DefaultWindowsAppRuntimeRequirement
    $fallbackText = Format-WindowsAppRuntimeRequirement -Frameworks @($fallback.Frameworks)

    $frameworks = @()
    try {
        # Only a list per architecture needs it; the current file has one list for all.
        $architecture = $null
        try {
            $architecture = Get-OSArchitecture
        }
        catch {
            $architecture = $null
        }
        $timeouts = Get-WebDownloadTimeoutParameters -Lookup
        $response = Invoke-WebRequest @timeouts -Uri $url -UseBasicParsing -ErrorAction Stop
        # GitHub serves release assets as application/octet-stream, which PowerShell 7 returns as bytes.
        $content = $response.Content
        if ($content -is [byte[]]) {
            $content = [System.Text.Encoding]::UTF8.GetString($content)
        }
        $content = [string]$content
        if ($content.Length -gt 65536) {
            throw ('it is {0} characters long, not a list of dependencies' -f $content.Length)
        }
        $frameworks = @(ConvertFrom-WingetDependenciesJson -Json $content -Architecture $architecture)
    }
    catch {
        # The exception's message, not "$_": for an HTTP error, PowerShell 7 puts the response
        # body (a proxy's block page, GitHub's error page) in the error record's text and the
        # status line ('Response status code does not indicate success: 403 (Forbidden).') in the
        # exception. One line, at most 300 characters, as this warning can come on every run.
        $problem = [string]$_.Exception.Message
        if ([string]::IsNullOrWhiteSpace($problem)) {
            $problem = "$_"
        }
        $problem = ($problem -replace '\s+', ' ').Trim().TrimEnd('.')
        if ($problem.Length -gt 300) {
            $problem = $problem.Substring(0, 297).TrimEnd() + '...'
        }
        Write-WarningMessage "Could not read which Windows App Runtime the latest winget release needs ($url`: $problem); checking for the built-in requirement, $fallbackText."
        $fallback.Detail = "the built-in requirement (the latest winget release's DesktopAppInstaller_Dependencies.json could not be read: $problem)"
        return $fallback
    }

    if ($frameworks.Count -eq 0) {
        Write-WarningMessage "The latest winget release lists no Microsoft.WindowsAppRuntime dependency in its DesktopAppInstaller_Dependencies.json; checking for the built-in requirement, $fallbackText, anyway."
        $fallback.Detail = "the built-in requirement (the latest winget release lists no Windows App Runtime)"
        return $fallback
    }

    $requirementText = Format-WindowsAppRuntimeRequirement -Frameworks $frameworks
    Write-Info "The latest winget release needs $requirementText (its DesktopAppInstaller_Dependencies.json)."
    return [pscustomobject]@{
        Frameworks = $frameworks
        Source     = 'LatestRelease'
        Detail     = "what the latest winget release needs (its DesktopAppInstaller_Dependencies.json)"
    }
}

<#
.SYNOPSIS
    Reports whether the WindowsAppRuntime framework that winget needs is present.
.DESCRIPTION
    Every winget release from 1.12 through 1.29 (checked against DesktopAppInstaller_Dependencies.json)
    depends on Microsoft.WindowsAppRuntime.1.8 >= 8000.616.304.0, the default requirement. WAU
    installs the newest release, so the WAU gate passes what that release needs
    (Get-WindowsAppRuntimeRequirement); a newer framework family does NOT satisfy a dependency on 1.8.
    Winget-AutoUpdate's Install-Prerequisites runs on every WAU SYSTEM run and provisions the
    newest winget release from GitHub without that framework. On a machine that lacks it (no
    Microsoft Store updates, Server SKUs) the new App Installer cannot register and the old one is
    then rejected as a downgrade, which leaves winget unusable (the #279/#284 wedge). Callers use
    this to keep WAU off such machines; Install-WingetAutoUpdate first installs the pinned framework
    (Install-WindowsAppRuntimeFramework, WindowsAppRuntime.ps1) when this finds none.
.PARAMETER Requirement
    The frameworks to look for (Get-WindowsAppRuntimeRequirement). Default: the built-in
    requirement (Get-DefaultWindowsAppRuntimeRequirement).
.RETURNS
    [pscustomobject] with:
      - Present: $true when, for every framework the requirement names, a package for this OS
                 architecture at or above its minimum is registered for any user; $false when one
                 is missing; $null when the query failed.
      - Detail:  the versions found (or the query error), for messages.
      - Missing: the frameworks of the requirement (Name, MinimumVersion) this PC lacks; empty
                 when Present is $true or $null. Install-WingetAutoUpdate passes them to
                 Install-WindowsAppRuntimeFramework and names only them in its messages.
#>
function Get-WindowsAppRuntimeStatus {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Requirement
    )

    if ($null -eq $Requirement) {
        $Requirement = Get-DefaultWindowsAppRuntimeRequirement
    }
    $frameworks = @($Requirement.Frameworks)
    if ($frameworks.Count -eq 0) {
        return [pscustomobject]@{ Present = $true; Detail = 'no Windows App Runtime required'; Missing = @() }
    }

    $osArchitecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    $present = $true
    $details = @()
    $missing = @()
    foreach ($framework in $frameworks) {
        try {
            $packages = @(Get-WindowsAppRuntimePackageInfo -Name $framework.Name)
        }
        catch {
            return [pscustomobject]@{ Present = $null; Detail = "could not query installed packages: $_"; Missing = @() }
        }

        $suitable = @($packages | Where-Object { $_.Architecture -eq $osArchitecture -and $_.Version -ge [version]$framework.MinimumVersion })
        if ($suitable.Count -eq 0) {
            $present = $false
            $missing += $framework
        }
        $found = if ($packages.Count -gt 0) {
            ($packages | ForEach-Object { "$($_.Architecture) $($_.Version)" }) -join ', '
        }
        else {
            'none registered'
        }
        $details += "$($framework.Name) >= $($framework.MinimumVersion) for $osArchitecture required; found: $found"
    }

    return [pscustomobject]@{
        Present = $present
        Detail  = ($details -join '; ')
        Missing = @($missing)
    }
}

<#
.SYNOPSIS
    Removes the at-logon trigger from an already-deployed Winget-AutoUpdate task.
.DESCRIPTION
    Earlier installer versions did not pass UPDATESATLOGON, so WAU 2.12.0 defaulted it to 1 and its
    SYSTEM task also runs at every user logon. That run re-provisions App Installer and resets
    winget's sources, and it fires exactly when a technician signs in to re-run this installer, so
    the two collide. New installs pass UPDATESATLOGON=0; this brings machines deployed before that
    in line. It also writes WAU_UpdatesAtLogon = 0, which WAU's MSI reads back on later upgrades.
    The weekly trigger is left alone, and a task whose only trigger is the logon one is not
    touched (removing it would stop WAU from ever running). Best-effort: failures only warn.
.RETURNS
    [bool] True when a logon trigger was removed.
#>
function Disable-WauLogonTrigger {
    $removed = $false
    try {
        $task = Get-ScheduledTask -TaskPath '\WAU\' -TaskName 'Winget-AutoUpdate' -ErrorAction SilentlyContinue
        if ($task) {
            $triggers = @($task.Triggers)
            $logonTriggers = @($triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger' })
            $otherTriggers = @($triggers | Where-Object { $_.CimClass.CimClassName -ne 'MSFT_TaskLogonTrigger' })
            if ($logonTriggers.Count -gt 0 -and $otherTriggers.Count -gt 0) {
                Set-ScheduledTask -TaskPath '\WAU\' -TaskName 'Winget-AutoUpdate' -Trigger $otherTriggers -ErrorAction Stop | Out-Null
                Write-Info 'Removed the at-logon trigger from the Winget-AutoUpdate task; it keeps its weekly schedule.'
                $removed = $true
            }
        }
        $wauKey = 'HKLM:\SOFTWARE\Romanitho\Winget-AutoUpdate'
        if (Test-Path -LiteralPath $wauKey) {
            # An [int] value is written as REG_DWORD, the type WAU's MSI reads back.
            Set-ItemProperty -LiteralPath $wauKey -Name 'WAU_UpdatesAtLogon' -Value ([int]0) -ErrorAction Stop
        }
    }
    catch {
        Write-WarningMessage "Could not remove the Winget-AutoUpdate at-logon trigger: $_"
    }
    return $removed
}

<#
.SYNOPSIS
    Waits, with a time limit, for a running Winget-AutoUpdate task to finish.
.DESCRIPTION
    A WAU run (its weekly schedule catching up after boot, or a logon run on machines deployed
    before Disable-WauLogonTrigger) re-provisions App Installer, resets winget's sources and runs
    MSI upgrades. Starting this installer's own winget work in the middle of that produces launch
    failures and 'another installation is in progress' errors that read like broken apps. Polls
    the \WAU\ tasks and returns as soon as none is running.
.PARAMETER TimeoutSeconds
    Longest time to wait before continuing anyway. Default 900 (15 minutes).
.PARAMETER PollIntervalSeconds
    Seconds between checks. Default 30.
.RETURNS
    [bool] True when no WAU task is running (including when WAU is not installed); false when one
    was still running at the time limit.
#>
function Wait-WauIdle {
    param (
        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 900,

        [Parameter(Mandatory = $false)]
        [int]$PollIntervalSeconds = 30
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $announced = $false
    while ($true) {
        $running = @()
        try {
            $running = @(Get-ScheduledTask -TaskPath '\WAU\' -ErrorAction SilentlyContinue | Where-Object { "$($_.State)" -eq 'Running' })
        }
        catch {
            # No task scheduler cmdlets (or no access): nothing to wait for.
            return $true
        }

        if ($running.Count -eq 0) {
            if ($announced) {
                Write-Success 'Winget-AutoUpdate has finished; continuing.'
            }
            return $true
        }

        $names = ($running | ForEach-Object { $_.TaskName }) -join ', '
        if (-not $announced) {
            Write-Info "Winget-AutoUpdate is running ($names); waiting up to $([math]::Ceiling($TimeoutSeconds / 60)) minutes so it does not collide with this run..."
            $announced = $true
        }
        if ((Get-Date) -ge $deadline) {
            Write-WarningMessage "Winget-AutoUpdate is still running ($names) after $([math]::Ceiling($TimeoutSeconds / 60)) minutes; continuing anyway. Installs may fail with 'another installation is in progress'; re-run the installer later if they do."
            return $false
        }
        Start-Sleep -Seconds $PollIntervalSeconds
    }
}

<#
.SYNOPSIS
    Describes one scheduled-task trigger in a few words, for the transcript.
.DESCRIPTION
    The trigger's kind from its CIM class (MSFT_TaskWeeklyTrigger reads 'Weekly',
    MSFT_TaskLogonTrigger 'Logon'), the days of a weekly trigger (its DaysOfWeek bit mask: 1 Sunday,
    2 Monday, 4 Tuesday ... 64 Saturday), when it starts, and '(disabled)' for a disabled trigger.
.PARAMETER Trigger
    A trigger from a scheduled task's Triggers.
.RETURNS
    [string] For example 'Weekly on Tuesday from 2026-10-06T02:00:00'.
#>
function Format-ScheduledTaskTrigger {
    param (
        [Parameter(Mandatory = $true)]
        $Trigger
    )

    $text = "$($Trigger.CimClass.CimClassName)" -replace '^MSFT_Task', '' -replace 'Trigger$', ''
    if (-not $text) {
        $text = 'Unknown'
    }
    if ("$($Trigger.DaysOfWeek)" -match '^\d+$' -and [int]$Trigger.DaysOfWeek -gt 0) {
        $dayNames = @('Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday')
        $days = @(for ($day = 0; $day -lt 7; $day++) {
                if ([int]$Trigger.DaysOfWeek -band (1 -shl $day)) {
                    $dayNames[$day]
                }
            })
        $text += ' on ' + ($days -join ', ')
    }
    if ($Trigger.StartBoundary) {
        $text += " from $($Trigger.StartBoundary)"
    }
    if ($Trigger.Enabled -eq $false) {
        $text += ' (disabled)'
    }
    return $text
}

<#
.SYNOPSIS
    Reads the Winget-AutoUpdate scheduled task and says whether it will run.
.DESCRIPTION
    Review finding P3-36. WAU's registry key alone used to count as 'already present', and msiexec
    exit code 0 as 'configured', so a machine whose WAU task had been deleted or disabled, or never
    registered, showed a green 'Auto-updates' line and never updated. This reads the task WAU's MSI
    registers, \WAU\Winget-AutoUpdate, and (Get-ScheduledTaskInfo) when it last ran and with what
    result.

    Healthy: the task exists, is not disabled, and has at least one enabled trigger (a task with
    none never runs on its own). The last run's result is reported, not judged: why a WAU run went
    wrong is in WAU's own log, whose end Write-WauTaskHealth prints.

    Queried with -ErrorAction SilentlyContinue (review finding P3-38): with -ErrorAction Stop, a
    task that does not exist, the normal answer before WAU is installed, is written to the
    transcript as 'PS>TerminatingError(Get-ScheduledTask)' even when it is caught, and #283's was
    read as part of a crash. The error is still read, from -ErrorVariable: 'not found'
    (CmdletizationQuery_NotFound) means there is no task, and any other error means the task could
    not be checked (CheckFailed), which is not healthy either: whether WAU will run is unknown.
.RETURNS
    [pscustomobject] with Healthy ([bool]), Exists ([bool]), CheckFailed ([bool], $true when the
    task scheduler could not be queried, so the task's state is unknown rather than wrong), State,
    Triggers ([string[]], from Format-ScheduledTaskTrigger), LastRunTime ([datetime], $null when
    the task has never run or the time could not be read), LastTaskResult ([int64] or $null),
    NextRunTime and Problem (why it is not healthy, worded to follow 'Winget-AutoUpdate is
    installed, but', or $null).
#>
function Get-WauTaskHealth {
    $taskPath = '\WAU\'
    $taskName = 'Winget-AutoUpdate'
    $health = [pscustomobject]@{
        Healthy        = $false
        Exists         = $false
        CheckFailed    = $false
        State          = $null
        Triggers       = @()
        LastRunTime    = $null
        LastTaskResult = $null
        NextRunTime    = $null
        Problem        = $null
    }

    $task = $null
    $taskErrors = @()
    try {
        $task = @(Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction SilentlyContinue -ErrorVariable taskErrors) | Select-Object -First 1
    }
    catch {
        # The task scheduler cmdlets could not run at all.
        $taskErrors = @($_)
    }
    if (-not $task) {
        $failure = @($taskErrors | Where-Object { "$($_.FullyQualifiedErrorId)" -notlike 'CmdletizationQuery_NotFound*' }) | Select-Object -First 1
        if ($failure) {
            $health.CheckFailed = $true
            $health.Problem = "its scheduled task $taskPath$taskName could not be checked ($($failure.Exception.Message))"
        }
        else {
            $health.Problem = "its scheduled task $taskPath$taskName does not exist"
        }
        return $health
    }

    $health.Exists = $true
    $health.State = "$($task.State)"
    $triggers = @($task.Triggers | Where-Object { $null -ne $_ })
    $health.Triggers = @($triggers | ForEach-Object { Format-ScheduledTaskTrigger -Trigger $_ })
    $enabledTriggers = @($triggers | Where-Object { $_.Enabled -ne $false })

    $info = $null
    try {
        $info = Get-ScheduledTaskInfo -TaskPath $taskPath -TaskName $taskName -ErrorAction SilentlyContinue
    }
    catch {
        $info = $null
    }
    if ($info) {
        # The task scheduler gives 1999-11-30 as the last run time of a task that has never run.
        if ($info.LastRunTime -and ([datetime]$info.LastRunTime).Year -ge 2000) {
            $health.LastRunTime = [datetime]$info.LastRunTime
        }
        if ($null -ne $info.LastTaskResult) {
            $health.LastTaskResult = [int64]$info.LastTaskResult
        }
        if ($info.NextRunTime) {
            $health.NextRunTime = [datetime]$info.NextRunTime
        }
    }

    if ($health.State -eq 'Disabled') {
        $health.Problem = "its scheduled task $taskPath$taskName is disabled"
    }
    elseif ($enabledTriggers.Count -eq 0) {
        $health.Problem = "its scheduled task $taskPath$taskName has no enabled trigger, so it never runs on its own"
    }
    else {
        $health.Healthy = $true
    }
    return $health
}

<#
.SYNOPSIS
    Returns the path of Winget-AutoUpdate's own log, updates.log, or $null.
.DESCRIPTION
    WAU writes each run to <InstallLocation>\logs\updates.log, where InstallLocation is the value
    its MSI records under HKLM:\SOFTWARE\Romanitho\Winget-AutoUpdate (by default
    %ProgramFiles%\Winget-AutoUpdate\). The default folder is used when the value cannot be read.
    The file need not exist: WAU creates it on its first run.
.RETURNS
    [string] or $null when no folder is known.
#>
function Get-WauUpdatesLogPath {
    $installLocation = $null
    try {
        $installLocation = [string](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Romanitho\Winget-AutoUpdate' -Name 'InstallLocation' -ErrorAction SilentlyContinue).InstallLocation
    }
    catch {
        $installLocation = $null
    }
    if ([string]::IsNullOrWhiteSpace($installLocation)) {
        if ([string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
            return $null
        }
        $installLocation = Join-Path $env:ProgramFiles 'Winget-AutoUpdate'
    }
    return (Join-Path $installLocation.Trim() 'logs\updates.log')
}

<#
.SYNOPSIS
    Writes the state of the Winget-AutoUpdate task, and the end of WAU's log, to the transcript.
.DESCRIPTION
    Review finding P3-36: whether auto-updates work used to be invisible in the log a teammate
    attaches. One line gives the task's state, triggers, last run, last result and next run, from
    Get-WauTaskHealth; then, when WAU's updates.log exists, its last lines follow, each indented
    behind '| ' so the e2e transcript parser never reads one of WAU's lines as the installer's.
    Best-effort: a log that cannot be read is noted and the run goes on.
.PARAMETER Health
    Get-WauTaskHealth's result.
.PARAMETER LogTailLines
    How many lines of updates.log to show. Default 20.
#>
function Write-WauTaskHealth {
    param (
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Health,

        [Parameter(Mandatory = $false)]
        [int]$LogTailLines = 20
    )

    if ($Health.Exists) {
        $triggers = 'none'
        if (@($Health.Triggers).Count -gt 0) {
            $triggers = @($Health.Triggers) -join '; '
        }
        $lastRun = 'never'
        if ($Health.LastRunTime) {
            $lastRun = '{0:yyyy-MM-dd HH:mm}' -f $Health.LastRunTime
        }
        $lastResult = 'unknown'
        if ($null -ne $Health.LastTaskResult) {
            # The task scheduler's own codes (SCHED_S_*) for the results a healthy task shows.
            $lastResult = '0x{0:X8}' -f $Health.LastTaskResult
            switch ($Health.LastTaskResult) {
                0 { $lastResult += ' (success)' }
                267009 { $lastResult += ' (running now)' }
                267011 { $lastResult += ' (has not run yet)' }
                267014 { $lastResult += ' (stopped before it finished)' }
            }
        }
        $nextRun = 'none scheduled'
        if ($Health.NextRunTime) {
            $nextRun = '{0:yyyy-MM-dd HH:mm}' -f $Health.NextRunTime
        }
        Write-Info ('Winget-AutoUpdate task \WAU\Winget-AutoUpdate: state {0}; triggers: {1}; last run: {2}, result {3}; next run: {4}.' -f $Health.State, $triggers, $lastRun, $lastResult, $nextRun)
    }

    $logPath = Get-WauUpdatesLogPath
    if (-not $logPath -or -not (Test-Path -LiteralPath $logPath -PathType Leaf)) {
        return
    }
    try {
        $lines = @(Get-Content -LiteralPath $logPath -Tail $LogTailLines -ErrorAction Stop)
    }
    catch {
        Write-WarningMessage "Could not read Winget-AutoUpdate's log ($logPath): $_"
        return
    }
    Write-Info ("The last {0} lines of Winget-AutoUpdate's log ({1}):" -f $lines.Count, $logPath)
    foreach ($line in $lines) {
        Write-Host ('    | ' + $line) -ForegroundColor DarkGray
    }
}

<#
.SYNOPSIS
    Returns a new path for one msiexec verbose log of a Winget-AutoUpdate install or uninstall.
.DESCRIPTION
    Review finding P3-37: a failed WAU msiexec used to leave only its exit code (1603, say) to debug
    from. The log goes into the run's logs folder (Get-InstallerLogDirectory, next to the transcript
    a teammate attaches) or, when there is no transcript (winget-app-uninstall.ps1, the imported
    module), %ProgramData%\winget-app-setup\logs, where the installer's transcripts go. The folder
    is created when missing; when it cannot be, there is no log: msiexec fails the whole operation
    (1622) when it cannot open its log.
.PARAMETER Action
    'install' or 'uninstall', for the file name.
.PARAMETER Attempt
    The attempt number, for the file name: each retry after msiexec exit code 1618 gets its own log.
.RETURNS
    [string] wau-msi-<action>-<yyyyMMdd-HHmmss>-<attempt>.log in that folder, or $null.
#>
function New-WauMsiLogPath {
    param (
        [Parameter(Mandatory = $true)]
        [ValidateSet('install', 'uninstall')]
        [string]$Action,

        [Parameter(Mandatory = $false)]
        [int]$Attempt = 1
    )

    $directory = Get-InstallerLogDirectory
    if ([string]::IsNullOrWhiteSpace($directory)) {
        if ([string]::IsNullOrWhiteSpace($env:ProgramData)) {
            return $null
        }
        $directory = Join-Path $env:ProgramData 'winget-app-setup\logs'
    }
    try {
        if (-not (Test-Path -LiteralPath $directory)) {
            [void](New-Item -Path $directory -ItemType Directory -Force -ErrorAction Stop)
        }
    }
    catch {
        return $null
    }
    return (Join-Path $directory ('wau-msi-{0}-{1:yyyyMMdd-HHmmss}-{2}.log' -f $Action, (Get-Date), $Attempt))
}

<#
.SYNOPSIS
    Runs msiexec for Winget-AutoUpdate with a verbose log, a time limit and a wait for a busy
    Windows Installer.
.DESCRIPTION
    Shared by Install-WingetAutoUpdate and Uninstall-WingetAutoUpdate:
      - each attempt writes msiexec's verbose log (/l*v) to New-WauMsiLogPath (review finding
        P3-37), so a failure can be diagnosed from the logs folder;
      - each attempt has msiexec's time limit (Get-ProcessTimeoutSeconds -Operation MsiExec, review
        finding P2-5);
      - exit code 1618 (ERROR_INSTALL_ALREADY_RUNNING: another installation holds Windows Installer)
        waits for that installation (Wait-WindowsInstallerIdle) and tries again, up to 3 times and
        within -InstallInProgressWaitSeconds in all (review finding P2-15).
.PARAMETER ArgumentString
    msiexec's arguments, without a log option.
.PARAMETER Action
    'install' or 'uninstall': the log name and the wait message.
.PARAMETER InstallInProgressWaitSeconds
    The most to wait, in all, for another installation. 0: 1618 is returned at once.
.RETURNS
    Invoke-ExternalProcess's result of the last attempt, with LogPath set to that attempt's msiexec
    log ($null when there is none), plus BusyRetries and BusyWaitedSeconds.
#>
function Invoke-WauMsiexec {
    param (
        [Parameter(Mandatory = $true)]
        [string]$ArgumentString,

        [Parameter(Mandatory = $true)]
        [ValidateSet('install', 'uninstall')]
        [string]$Action,

        [Parameter(Mandatory = $false)]
        [int]$InstallInProgressWaitSeconds = 600
    )

    $timeoutSeconds = Get-ProcessTimeoutSeconds -Operation MsiExec
    $busyRetries = 0
    $busyWaited = 0
    while ($true) {
        $logPath = New-WauMsiLogPath -Action $Action -Attempt ($busyRetries + 1)
        $arguments = $ArgumentString
        if ($logPath) {
            $arguments = '{0} /l*v "{1}"' -f $ArgumentString, $logPath
        }
        $msiexec = Invoke-ExternalProcess -FilePath 'msiexec.exe' -ArgumentString $arguments -TimeoutSeconds $timeoutSeconds -Echo None
        $msiexec.LogPath = $logPath
        if ($msiexec.LaunchFailed) {
            # msiexec never ran, so it wrote no log.
            $msiexec.LogPath = $null
            break
        }
        if ($msiexec.TimedOut) {
            break
        }
        $busyWaitLeft = $InstallInProgressWaitSeconds - $busyWaited
        if ($msiexec.ExitCode -eq 1618 -and $busyRetries -lt 3 -and $busyWaitLeft -gt 0) {
            $busyRetries++
            Write-WarningMessage ('Windows Installer is busy with another installation (msiexec exit code 1618). Waiting for it to finish (at most {0} seconds) before retry {1} of 3 of the Winget-AutoUpdate {2}...' -f $busyWaitLeft, $busyRetries, $Action)
            $wait = Wait-WindowsInstallerIdle -MaximumSeconds $busyWaitLeft
            $busyWaited += [int]$wait.WaitedSeconds
            continue
        }
        break
    }
    $msiexec | Add-Member -NotePropertyName 'BusyRetries' -NotePropertyValue $busyRetries -Force
    $msiexec | Add-Member -NotePropertyName 'BusyWaitedSeconds' -NotePropertyValue $busyWaited -Force
    return $msiexec
}
