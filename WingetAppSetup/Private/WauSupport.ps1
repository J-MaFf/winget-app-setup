<#
.SYNOPSIS
    Reads the installed Winget-AutoUpdate (WAU) version and MSI ProductCode from the registry.
.DESCRIPTION
    From its Uninstall entry (DisplayName matching Winget-AutoUpdate, WOW6432Node too), with WAU's
    own HKLM:\SOFTWARE\Romanitho\Winget-AutoUpdate key as the version fallback. The version decides
    whether the pinned MSI upgrades it; the ProductCode uninstalls whatever version is there
    (issue #186).
.OUTPUTS
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
    Reads a directory's (or a file's, or a registry key's) owner and access entries as SIDs.
.DESCRIPTION
    A seam over Get-Acl. Every entry, explicit and inherited, by SID, so the result does not depend
    on the display language; Name is the account name when the SID resolves. Throws when the access
    list cannot be read.
.PARAMETER Path
    The directory or file to read.
.OUTPUTS
    [pscustomobject] with OwnerSid, OwnerName, InheritanceProtected ([bool], true when the
    directory inherits nothing from its parent) and AccessRules (Sid, Name, AccessControlType
    'Allow'/'Deny', IsInherited, Rights ([long], the entry's FileSystemRights access mask) and
    InheritOnly ([bool], true for an entry that only passes down to the items inside a folder and
    does not apply to the folder itself)).
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
                Rights            = [long]$rule.FileSystemRights
                InheritOnly       = (([int]$rule.PropagationFlags) -band 2) -ne 0
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
    Administrators have access entries on it (with -ReadableByUsers, standard users may also read).
.DESCRIPTION
    Checks what Set-RestrictedDirectoryAcl was meant to leave, before anything is downloaded into it
    (P2-21). Fails on another owner (an owner can always change the access list), on any entry for
    another account (allow or deny, explicit or inherited), and on inheritance still turned on.
    -ReadableByUsers allows BUILTIN\Users allow entries that cannot change the folder or its
    contents.
.PARAMETER Path
    The directory to check.
.PARAMETER ReadableByUsers
    Accept read-only allow entries for BUILTIN\Users (S-1-5-32-545), as the logs folder has.
#>
function Assert-RestrictedDirectoryAcl {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $false)]
        [switch]$ReadableByUsers
    )

    $allowedSids = @('S-1-5-18', 'S-1-5-32-544')
    # WriteData, AppendData, WriteExtendedAttributes, DeleteChild, WriteAttributes, Delete,
    # ChangePermissions, TakeOwnership, GENERIC_ALL and GENERIC_WRITE: with any of them an account
    # could add, remove or replace entries, or turn the empty folder into a junction.
    $changeRights = 0x2 -bor 0x4 -bor 0x10 -bor 0x40 -bor 0x100 -bor 0x10000 -bor 0x40000 -bor 0x80000 -bor 0x10000000 -bor 0x40000000
    $security = Get-DirectoryAccessSummary -Path $Path
    $problems = @()
    if ($allowedSids -notcontains $security.OwnerSid) {
        $problems += "it is owned by $($security.OwnerName) ($($security.OwnerSid))"
    }
    if (-not $security.InheritanceProtected) {
        $problems += 'it still inherits permissions from its parent folder'
    }
    foreach ($rule in @($security.AccessRules)) {
        if ($allowedSids -contains $rule.Sid) {
            continue
        }
        if ($ReadableByUsers -and $rule.Sid -eq 'S-1-5-32-545' -and $rule.AccessControlType -eq 'Allow' -and ([long]$rule.Rights -band $changeRights) -eq 0) {
            continue
        }
        $problems += "$($rule.Name) ($($rule.Sid)) has an access entry ($($rule.AccessControlType.ToLowerInvariant()))"
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
    Protects a staging folder, so a non-elevated process of the same user cannot swap a file between
    its hash check and its use (issue #186). Well-known SIDs, so it works on non-English Windows.
    Ownership comes first (P2-21): the installer's first, non-elevated launch creates
    %ProgramData%\winget-app-setup, owned by the signed-in user, who could otherwise grant themselves
    access again. icacls makes Administrators the owner, removes the inherited entries and replaces
    (/grant:r) SYSTEM's and Administrators' (and, with -ReadableByUsers, BUILTIN\Users' read)
    entries, and Assert-RestrictedDirectoryAcl reads the result back. Only the directory itself
    changes (no /T, no /reset).

    Never through a link (wgt-gq8.46): icacls follows one by default, and would rewrite the owner and
    access list of whatever a planted junction points to. A link is refused before icacls runs;
    icacls gets /L, so a folder swapped for a link meanwhile has the link changed, not its target;
    and a folder that is a link afterwards is refused. Both refusals have the error id
    'DirectoryIsLink'. Throws when icacls or the check fails, with the error id
    'RestrictedDirectoryAclFailed', so a caller can suggest resetting the folder only then.
.PARAMETER Path
    The directory whose ACL should be replaced.
.PARAMETER ReadableByUsers
    Also grant BUILTIN\Users read and execute, inherited by everything inside (the logs folder, review
    finding P3-14), replacing any other entry they had.
#>
function Set-RestrictedDirectoryAcl {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $false)]
        [switch]$ReadableByUsers
    )

    if (Test-FileSystemLink -Path $Path) {
        throw (New-DirectoryIsLinkError -Path $Path -Message ("'{0}' is a link (a junction or symbolic link), not a folder, so its access list was not changed." -f $Path))
    }

    $grants = '*S-1-5-18:(OI)(CI)F *S-1-5-32-544:(OI)(CI)F'
    if ($ReadableByUsers) {
        $grants += ' *S-1-5-32-545:(OI)(CI)RX'
    }
    $failure = $null
    $steps = @(
        @{
            Arguments   = "`"$Path`" /setowner *S-1-5-32-544 /L /q"
            Description = 'make Administrators the owner of'
        },
        @{
            # /inheritance:r strips inherited ACEs; /grant:r replaces any explicit entries of these
            # accounts with these (OI)(CI) grants, inherited by everything created inside.
            Arguments   = "`"$Path`" /inheritance:r /grant:r $grants /L /q"
            Description = 'restrict'
        }
    )
    foreach ($step in $steps) {
        # -WindowStyle Hidden, not -NoNewWindow: icacls prints a summary line even with /q, and
        # every elevated run locks the base and logs folders before its transcript starts.
        $proc = Start-Process -FilePath 'icacls.exe' -ArgumentList $step.Arguments -Wait -PassThru -WindowStyle Hidden
        if ($proc.ExitCode -ne 0) {
            $failure = "icacls failed to $($step.Description) '$Path' (exit code $($proc.ExitCode))."
            break
        }
    }
    if (-not $failure) {
        try {
            Assert-RestrictedDirectoryAcl -Path $Path -ReadableByUsers:$ReadableByUsers
        }
        catch {
            $failure = "$_"
        }
    }
    # Checked even after a failure: the check above reads a link's target, and the reset advice
    # that goes with 'RestrictedDirectoryAclFailed' would follow the link too.
    if (Test-FileSystemLink -Path $Path) {
        throw (New-DirectoryIsLinkError -Path $Path -Message ("'{0}' was replaced by a link (a junction or symbolic link) while its access list was being set, so it is not used." -f $Path))
    }
    if ($failure) {
        $exception = [System.InvalidOperationException]::new($failure)
        throw [System.Management.Automation.ErrorRecord]::new($exception, 'RestrictedDirectoryAclFailed', [System.Management.Automation.ErrorCategory]::SecurityError, $Path)
    }
}

<#
.SYNOPSIS
    Checks that a file carries a valid Authenticode signature from the given signer.
.DESCRIPTION
    Status 'Valid' (the signature matches the content and chains to a trusted root) and a
    certificate common name of exactly SignerCommonName, the rule Test-PowerShell7MsiSignature
    applies to the PowerShell MSI. Used for the Windows App Runtime framework and the
    Microsoft.WinGet.Client module's files.
.PARAMETER Path
    The file to check.
.PARAMETER SignerCommonName
    The common name (CN) the signing certificate must have.
.OUTPUTS
    [pscustomobject] with Valid ([bool]) and Detail (the signer, or why the check failed).
#>
function Test-AuthenticodeSigner {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$SignerCommonName
    )

    try {
        $signature = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
    }
    catch {
        return [pscustomobject]@{ Valid = $false; Detail = "its signature could not be checked: $_" }
    }

    $status = 'unknown'
    $signer = 'none'
    if ($signature) {
        if ("$($signature.Status)") {
            $status = "$($signature.Status)"
        }
        if ($signature.SignerCertificate -and $signature.SignerCertificate.Subject) {
            $signer = [string]$signature.SignerCertificate.Subject
        }
    }
    $signerPattern = '(^|,\s*)CN=' + [regex]::Escape($SignerCommonName) + '(\s*,|$)'
    if ($status -eq 'Valid' -and $signer -match $signerPattern) {
        return [pscustomobject]@{ Valid = $true; Detail = $signer }
    }
    return [pscustomobject]@{ Valid = $false; Detail = ('it is not signed by {0} (signature status: {1}; signer: {2})' -f $SignerCommonName, $status, $signer) }
}

<#
.SYNOPSIS
    Opens a file for reading so that nobody can change, rename or delete it while it is open.
.DESCRIPTION
    FileShare.Read: while the stream is open, others (msiexec) can only read the file, and its
    folder cannot be renamed, so hashing from this stream and keeping it open until msiexec ends
    installs exactly the bytes that were hashed (P2-21). The caller disposes the stream.
.PARAMETER Path
    The file to open.
.OUTPUTS
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
    Creates a fresh staging directory only SYSTEM and Administrators can change, for a download that
    runs elevated: the WAU MSI, the Windows App Runtime framework or the Microsoft.WinGet.Client
    module.
.DESCRIPTION
    Not %TEMP%, where a non-elevated process of the same user could swap the file (issue #186): a
    uniquely named folder under %ProgramData%\winget-app-setup, locked down before anything is
    downloaded. The base folder is made safe first (Initialize-ProgramDataFolder: a planted link is
    removed, never followed, and the folder is locked with Administrators as its owner, P2-21), so
    nobody unprivileged can see the per-run name or recreate the folder through the parent. Throws
    when the folder cannot be created or secured: the error id 'RestrictedDirectoryAclFailed' when
    its access list could not be set, 'DirectoryIsLink' for a link. Callers remove it.
.PARAMETER Prefix
    The start of the per-run folder's name, which ends with a new GUID. Default 'wau-msi'.
.OUTPUTS
    [string] The full path of the created staging directory.
#>
function New-WauStagingDirectory {
    param (
        [Parameter(Mandatory = $false)]
        [ValidatePattern('^[A-Za-z0-9-]+\z')]
        [string]$Prefix = 'wau-msi'
    )

    $baseDir = Initialize-ProgramDataFolder

    # Without -Force: a name that exists already, which only an administrator could have made in the
    # locked base folder, is an error rather than a folder to reuse.
    $stagingDir = Join-Path $baseDir ($Prefix + '-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -Path $stagingDir -ItemType Directory -ErrorAction Stop
    Set-RestrictedDirectoryAcl -Path $stagingDir
    return $stagingDir
}

<#
.SYNOPSIS
    Lists the packages of one Windows App Runtime framework registered for any user.
.DESCRIPTION
    A query seam for Get-WindowsAppRuntimeStatus. Needs elevation; under PowerShell 7 it runs in
    Windows PowerShell 5.1, where the Appx module always loads. Throws when the query fails.
.PARAMETER Name
    The framework's package name, Microsoft.WindowsAppRuntime.1.8 by default. It may come from the
    web (Get-WindowsAppRuntimeRequirement) and goes into a command, so only package-name characters
    are accepted.
.OUTPUTS
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
    8000.616.304.0 or newer, what winget 1.12.350 to 1.29.380 and the 1.30.140 preview list.
.DESCRIPTION
    Used when no requirement is given, and when the latest winget release's list cannot be read.
.OUTPUTS
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
.OUTPUTS
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
    A winget-cli release asset since 1.11, which Repair-WinGetPackageManager reads too:
    {"Dependencies": [{"Name": "...", "Version": "..."}, ...]}. A list for this PC's architecture is
    read as well: an "x64", "x86" or "arm64" property (any case), at the top or under
    "Dependencies", holding the list or an object with one. Only Microsoft.WindowsAppRuntime entries
    are returned (WAU installs VCLibs and UI.Xaml itself); a framework listed twice keeps its highest
    version.
.PARAMETER Json
    The file's text.
.PARAMETER Architecture
    This PC's OS architecture as Get-OSArchitecture names it (X64, X86, Arm64), for a list per
    architecture; $null or empty when it is not known.
.OUTPUTS
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
    Every WAU run as SYSTEM installs the newest winget from GitHub without its frameworks, and a
    winget missing its framework is unusable (#279/#284). So the requirement comes from that release:
    its DesktopAppInstaller_Dependencies.json, through the download link of the release GitHub marks
    latest (no API rate limit). A newer build or another family is then checked for as such, and a
    newer family does not stand in for an older one. Never stops the run: 30-second limit, and the
    built-in requirement, with a warning, when the file cannot be read or lists no Windows App
    Runtime. Writes one line naming the requirement and its source.
.OUTPUTS
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
        # The exception's message, not "$_", which for an HTTP error holds the response body (a
        # block page). One line, at most 300 characters: it can come on every run.
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
    Every WAU run as SYSTEM provisions the newest winget, which on a PC without its framework (no
    Store updates, Server) cannot register, and the old one is then refused as a downgrade: winget is
    left unusable (#279/#284). Callers keep WAU off such PCs, after Install-WingetAutoUpdate tried to
    install the pinned framework. A newer family does not satisfy a dependency on 1.8.
.PARAMETER Requirement
    The frameworks to look for (Get-WindowsAppRuntimeRequirement). Default: the built-in
    requirement (Get-DefaultWindowsAppRuntimeRequirement).
.OUTPUTS
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
    Older installer versions left WAU 2.12.0's UPDATESATLOGON default of 1, so WAU also runs at
    every logon, colliding with a technician signing in to run this installer. This removes that
    trigger and writes WAU_UpdatesAtLogon = 0, which later WAU MSI upgrades read back. A task whose
    only trigger is the logon one is left alone (WAU would never run). Best-effort: failures warn.
.OUTPUTS
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
    A WAU run re-provisions App Installer, resets winget's sources and runs MSI upgrades; this
    installer's winget work in the middle of that fails in ways that read like broken apps. Polls
    the \WAU\ tasks and returns as soon as none is running.
.PARAMETER TimeoutSeconds
    Longest time to wait before continuing anyway. Default 900 (15 minutes).
.PARAMETER PollIntervalSeconds
    Seconds between checks. Default 30.
.OUTPUTS
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
    Describes one scheduled-task trigger in a few words, for the transcript: its kind from its CIM
    class, a weekly trigger's days (DaysOfWeek: 1 Sunday, 2 Monday, 4 Tuesday ... 64 Saturday), its
    start, and '(disabled)'.
.PARAMETER Trigger
    A trigger from a scheduled task's Triggers.
.OUTPUTS
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
    WAU's registry key or msiexec's exit code 0 do not show that WAU will run (P3-36). Healthy: the
    \WAU\Winget-AutoUpdate task exists, is not disabled and has an enabled trigger. Its last run and
    result are reported, not judged (Write-WauTaskHealth prints WAU's own log). Queried with
    -ErrorAction SilentlyContinue, since a caught terminating error still lands in the transcript
    (P3-38), and the error read from -ErrorVariable: 'not found' means no task; any other error is
    CheckFailed, whether WAU will run is unknown.
.OUTPUTS
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
    Returns the path of Winget-AutoUpdate's own log, <InstallLocation>\logs\updates.log, from its
    HKLM:\SOFTWARE\Romanitho\Winget-AutoUpdate key or the default folder; $null when no folder is
    known. The file need not exist yet.
.OUTPUTS
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
    One line with the task's state, triggers, last run, result and next run (Get-WauTaskHealth),
    then the last lines of updates.log, each behind '| ' so the e2e transcript parser never reads
    them as the installer's. Best-effort.
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
    In the run's logs folder, or %ProgramData%\winget-app-setup\logs without a transcript (P3-37),
    made safe first like the transcript's (Initialize-ProgramDataFolder, wgt-gq8.46), since msiexec
    writes the log with this run's elevated rights. The folder is created when missing; when it
    cannot be, or cannot be made safe, there is no log, since msiexec fails (1622) when it cannot
    open its log.
.PARAMETER Action
    'install' or 'uninstall', for the file name.
.PARAMETER Attempt
    The attempt number, for the file name: each retry after msiexec exit code 1618 gets its own log.
.OUTPUTS
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
    try {
        if ([string]::IsNullOrWhiteSpace($directory)) {
            $directory = Initialize-ProgramDataFolder -ChildName 'logs' -ReadableByUsers
        }
        elseif (-not (Test-Path -LiteralPath $directory)) {
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
    For Install- and Uninstall-WingetAutoUpdate: each attempt logs verbosely (/l*v,
    New-WauMsiLogPath) under msiexec's time limit, and 1618 (another installation holds Windows
    Installer) waits for it (Wait-WindowsInstallerIdle) and tries again, up to 3 times within
    -InstallInProgressWaitSeconds.
.PARAMETER ArgumentString
    msiexec's arguments, without a log option.
.PARAMETER Action
    'install' or 'uninstall': the log name and the wait message.
.PARAMETER InstallInProgressWaitSeconds
    The most to wait, in all, for another installation. 0: 1618 is returned at once.
.OUTPUTS
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
