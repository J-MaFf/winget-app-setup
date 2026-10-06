# The installer's fixed-name folders under %ProgramData%\winget-app-setup (wgt-gq8.46): any user can
# plant a junction there, so an elevated or SYSTEM run makes a folder safe before it uses it. Runs
# under Windows PowerShell 5.1 too (the bootstrap's transcript), so it stays 5.1-compatible.

<#
.SYNOPSIS
    Returns the attributes of a file system entry itself, never of what a link points to.
.DESCRIPTION
    [System.IO.File]::GetAttributes reads the entry at the path: a junction, symbolic link or mount
    point reports ReparsePoint (and Directory when it is a directory link), whether or not its
    target exists.
.PARAMETER Path
    The entry to read.
.OUTPUTS
    [System.IO.FileAttributes], or $null when nothing is at the path. Throws when it cannot be read.
#>
function Get-FileSystemEntryAttribute {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    try {
        return [System.IO.File]::GetAttributes($Path)
    }
    catch [System.IO.FileNotFoundException], [System.IO.DirectoryNotFoundException] {
        return $null
    }
}

<#
.SYNOPSIS
    Says whether a path is a link: a junction, symbolic link or mount point (any reparse point).
.PARAMETER Path
    The path to check. Its last part is checked, not followed.
.OUTPUTS
    [bool] False when nothing is at the path.
#>
function Test-FileSystemLink {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $attributes = Get-FileSystemEntryAttribute -Path $Path
    return ($null -ne $attributes -and ($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

<#
.SYNOPSIS
    Removes a link (junction, symbolic link or mount point) without touching what it points to.
.DESCRIPTION
    A directory link goes with a non-recursive [System.IO.Directory]::Delete (RemoveDirectory, which
    removes a junction whatever its target holds), any other link with [System.IO.File]::Delete.
    Neither follows the link. Throws when the link cannot be removed or is still there.
.PARAMETER Path
    The link.
#>
function Remove-FileSystemLink {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $attributes = Get-FileSystemEntryAttribute -Path $Path
    if ($null -eq $attributes) {
        return
    }
    if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
        throw "'$Path' is not a link."
    }
    if ($attributes -band [System.IO.FileAttributes]::Directory) {
        [System.IO.Directory]::Delete($Path, $false)
    }
    else {
        [System.IO.File]::Delete($Path)
    }
    if ($null -ne (Get-FileSystemEntryAttribute -Path $Path)) {
        throw "'$Path' is still there after it was removed."
    }
}

<#
.SYNOPSIS
    Returns the error a folder that is a link raises, with the error id 'DirectoryIsLink'.
.DESCRIPTION
    Callers tell it apart from 'RestrictedDirectoryAclFailed': takeown and icacls /reset, the advice
    for that one, would follow a link and change what it points to.
.PARAMETER Path
    The folder.
.PARAMETER Message
    What happened.
.OUTPUTS
    [System.Management.Automation.ErrorRecord]
#>
function New-DirectoryIsLinkError {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $exception = New-Object System.InvalidOperationException($Message)
    return (New-Object System.Management.Automation.ErrorRecord($exception, 'DirectoryIsLink', [System.Management.Automation.ErrorCategory]::SecurityError, $Path))
}

<#
.SYNOPSIS
    Creates a directory that only SYSTEM and Administrators can change from the moment it exists.
.DESCRIPTION
    The access list (SYSTEM and Administrators full control, inherited by everything inside, no
    entries inherited from the parent) is part of the create call, so no other account can turn the
    new, empty folder into a junction before it is locked. Does nothing when the path exists; the
    caller checks what is there. Windows only.
.PARAMETER Path
    The directory to create.
#>
function New-RestrictedDirectory {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $security = New-Object System.Security.AccessControl.DirectorySecurity
    $security.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $identity = New-Object System.Security.Principal.SecurityIdentifier($sid)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')
        $security.AddAccessRule($rule)
    }
    if ($PSVersionTable.PSEdition -eq 'Core') {
        [System.IO.FileSystemAclExtensions]::Create((New-Object System.IO.DirectoryInfo($Path)), $security)
    }
    else {
        [void][System.IO.Directory]::CreateDirectory($Path, $security)
    }
}

<#
.SYNOPSIS
    Makes %ProgramData%\winget-app-setup, or a folder in it, safe for an elevated or SYSTEM run to
    use, and returns its path.
.DESCRIPTION
    Before the first elevated run, a standard user can create these folders, or junctions in their
    place, and the installer's first, non-elevated launch creates them owned by the signed-in user.
    For the base folder, then the child folder, in that order:
      1. A link (junction, symbolic link or mount point) is removed, never followed, with a warning.
         A link that cannot be removed stops here (error id 'DirectoryIsLink').
      2. A missing base folder is created already locked (New-RestrictedDirectory); a missing child
         is created inside the locked base, whose entries it inherits.
      3. Set-RestrictedDirectoryAcl locks it (owner Administrators, only SYSTEM and Administrators
         can change it; -ReadableByUsers lets standard users read the child), with icacls /L so a
         folder swapped for a link meanwhile has the link changed, not its target, and checks that
         it is still a real folder afterwards.
    Once locked, no other account can rename, replace or relink either folder. Throws on any
    failure: 'RestrictedDirectoryAclFailed' when the access list could not be set, 'DirectoryIsLink'
    for a link, or the error of a folder that could not be created (a file in the way, a full disk).
.PARAMETER ChildName
    The folder inside %ProgramData%\winget-app-setup ('logs', 'cache'); empty for the base folder.
.PARAMETER ReadableByUsers
    Standard users may read the child folder and what is in it (the logs folder, review finding
    P3-14).
.OUTPUTS
    [string] The folder's path.
#>
function Initialize-ProgramDataFolder {
    param (
        [Parameter(Mandatory = $false)]
        [ValidatePattern('^[A-Za-z0-9-]*$')]
        [string]$ChildName = '',

        [Parameter(Mandatory = $false)]
        [switch]$ReadableByUsers
    )

    if ([string]::IsNullOrWhiteSpace($env:ProgramData)) {
        throw 'The ProgramData environment variable is not set, so the installer has no folder for its data.'
    }
    $baseDirectory = Join-Path $env:ProgramData 'winget-app-setup'
    $folders = @($baseDirectory)
    if (-not [string]::IsNullOrEmpty($ChildName)) {
        $folders += (Join-Path $baseDirectory $ChildName)
    }

    foreach ($folder in $folders) {
        $attributes = Get-FileSystemEntryAttribute -Path $folder
        if ($null -ne $attributes -and ($attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            try {
                Remove-FileSystemLink -Path $folder
            }
            catch {
                throw (New-DirectoryIsLinkError -Path $folder -Message ("'{0}' is a link (a junction or symbolic link), not a folder, and the link could not be removed: {1} Nothing was written through it. Remove the link in an elevated prompt (rmdir `"{0}`" removes a junction, not what it points to) and re-run this installer." -f $folder, $_.Exception.Message))
            }
            Write-WarningMessage ("'{0}' was a link (a junction or symbolic link), not a folder. The link was removed without changing what it pointed to, and a folder is created in its place." -f $folder)
            $attributes = $null
        }
        if ($null -eq $attributes) {
            if ($folder -eq $baseDirectory) {
                New-RestrictedDirectory -Path $folder
            }
            else {
                [void](New-Item -ItemType Directory -Path $folder -ErrorAction Stop)
            }
        }
        elseif (($attributes -band [System.IO.FileAttributes]::Directory) -eq 0) {
            throw "'$folder' is a file, not a folder."
        }
        $usersRead = [bool]$ReadableByUsers -and $folder -ne $baseDirectory
        Set-RestrictedDirectoryAcl -Path $folder -ReadableByUsers:$usersRead
    }
    return $folders[-1]
}
