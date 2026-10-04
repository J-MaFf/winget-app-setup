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
    Creates a fresh, ACL-restricted staging directory for the WAU MSI download.
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

<#
.SYNOPSIS
    Lists the Microsoft.WindowsAppRuntime.1.8 framework packages registered for any user.
.DESCRIPTION
    Thin query seam for Get-WindowsAppRuntimeStatus (mocked in tests). `Get-AppxPackage -AllUsers`
    needs elevation; under PowerShell 7 it runs in Windows PowerShell 5.1, where the Appx module
    always loads - the same delegation Invoke-AppxProvisioning uses. Throws when the query fails.
.RETURNS
    [pscustomobject[]] with Version ([version]) and Architecture ([string], e.g. 'X64', 'Arm64').
#>
function Get-WindowsAppRuntimePackageInfo {
    $query = "Get-AppxPackage -AllUsers -Name 'Microsoft.WindowsAppRuntime.1.8' -ErrorAction Stop | ForEach-Object { '{0}|{1}' -f `$_.Version, `$_.Architecture }"
    if ($PSVersionTable.PSEdition -eq 'Core') {
        $lines = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $query)
        if ($LASTEXITCODE -ne 0) {
            throw "Get-AppxPackage -AllUsers failed in Windows PowerShell (exit code $LASTEXITCODE)."
        }
    }
    else {
        $lines = @(Get-AppxPackage -AllUsers -Name 'Microsoft.WindowsAppRuntime.1.8' -ErrorAction Stop |
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
    Reports whether the WindowsAppRuntime framework that current winget releases need is present.
.DESCRIPTION
    Every winget release from 1.12 through 1.29 (checked against DesktopAppInstaller_Dependencies.json)
    depends on Microsoft.WindowsAppRuntime.1.8 >= 8000.616.304.0. WAU installs the newest release,
    so re-check this requirement when winget moves to a newer framework (and when Get-WauPin is
    bumped); a newer framework family does NOT satisfy a dependency on 1.8.
    Winget-AutoUpdate's Install-Prerequisites runs on every WAU SYSTEM run and provisions the
    newest winget release from GitHub without that framework. On a machine that lacks it (no
    Microsoft Store updates, Server SKUs) the new App Installer cannot register and the old one is
    then rejected as a downgrade, which leaves winget unusable (the #279/#284 wedge). Callers use
    this to keep WAU off such machines.
.PARAMETER MinimumVersion
    The lowest framework version that satisfies current winget releases.
.RETURNS
    [pscustomobject] with:
      - Present: $true when a package for this OS architecture at or above MinimumVersion is
                 registered for any user; $false when none is; $null when the query failed.
      - Detail:  the versions found (or the query error), for messages.
#>
function Get-WindowsAppRuntimeStatus {
    param (
        [Parameter(Mandatory = $false)]
        [version]$MinimumVersion = [version]'8000.616.304.0'
    )

    try {
        $packages = @(Get-WindowsAppRuntimePackageInfo)
    }
    catch {
        return [pscustomobject]@{ Present = $null; Detail = "could not query installed packages: $_" }
    }

    $osArchitecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    $suitable = @($packages | Where-Object { $_.Architecture -eq $osArchitecture -and $_.Version -ge $MinimumVersion })
    $found = if ($packages.Count -gt 0) {
        ($packages | ForEach-Object { "$($_.Architecture) $($_.Version)" }) -join ', '
    }
    else {
        'none registered'
    }

    return [pscustomobject]@{
        Present = ($suitable.Count -gt 0)
        Detail  = "Microsoft.WindowsAppRuntime.1.8 >= $MinimumVersion for $osArchitecture required; found: $found"
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
