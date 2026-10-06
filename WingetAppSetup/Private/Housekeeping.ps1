# Retention for what the installer leaves on disk (P3-42): without it an RMM schedule's runs grew the
# transcripts, installer logs and temporary installer copies without bound.

<#
.SYNOPSIS
    Deletes the installer's old logs and the leftover temporary copies of the installer and the
    uninstaller (they share the folder names), never the current run's.
.DESCRIPTION
    The entry script calls it once a real elevated run holds the run lock, so two runs never prune
    at once and a dry run changes nothing. It keeps the logs of the newest KeepTranscripts
    transcripts (Remove-OldInstallerLog), removes copy folders older than TempCopyMaxAgeHours
    (Remove-StaleInstallerCopy) and Microsoft.WinGet.Client folders as old
    (Remove-StaleWingetClientFolder). The defaults here are the one place the numbers are set.
    Never stops a run: a failure warns.
.PARAMETER LogDirectory
    The logs folder. Default: the folder of this run's transcript (Get-InstallerLogDirectory);
    nothing is pruned there when there is none.
.PARAMETER KeepTranscripts
    How many install-*.log transcripts to keep, newest first. A run writes up to four (bootstrap,
    RMM wrapper, PowerShell 7 run, elevated relaunch), so 30 keeps at least the last 7 runs.
.PARAMETER TempRoot
    The folders to look for leftover copies in. Default: Get-ElevatedCopyRoot (%SystemRoot%\Temp),
    plus, as SYSTEM, this process's temp folder and Get-SystemProfileTempRoot, since a SYSTEM
    bootstrap saves its copies in whichever its environment names. Never another account's temp
    folder, whose entries that account's non-elevated processes can replace.
.PARAMETER TempCopyMaxAgeHours
    A copy folder at least this old is removed; no run lasts this long.
.PARAMETER CurrentScriptPath
    The path of the running installer ($PSCommandPath). Its folder is never removed.
.PARAMETER StagingRoot
    Where the Microsoft.WinGet.Client engine's folders are. Default:
    %ProgramData%\winget-app-setup.
.OUTPUTS
    [pscustomobject] @{ LogsRemoved; CopiesRemoved; WingetClientFoldersRemoved }.
#>
function Invoke-InstallerHousekeeping {
    param (
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$LogDirectory,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 1000)]
        [int]$KeepTranscripts = 30,

        [Parameter(Mandatory = $false)]
        [string[]]$TempRoot,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 8760)]
        [int]$TempCopyMaxAgeHours = 24,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$CurrentScriptPath,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$StagingRoot
    )

    $logsRemoved = 0
    $copiesRemoved = 0
    $wingetClientFoldersRemoved = 0
    try {
        if (-not $PSBoundParameters.ContainsKey('LogDirectory')) {
            $LogDirectory = Get-InstallerLogDirectory
        }
        if (-not [string]::IsNullOrWhiteSpace($LogDirectory)) {
            $logsRemoved = Remove-OldInstallerLog -LogDirectory $LogDirectory -KeepTranscripts $KeepTranscripts -CurrentTranscriptPath $script:InstallLogPath
        }
        if (-not $PSBoundParameters.ContainsKey('TempRoot')) {
            $TempRoot = @(Get-ElevatedCopyRoot)
            if (Test-IsSystemAccount) {
                $TempRoot = @([System.IO.Path]::GetTempPath(), (Get-SystemProfileTempRoot)) + $TempRoot
            }
        }
        $copiesRemoved = Remove-StaleInstallerCopy -Root $TempRoot -MaxAgeHours $TempCopyMaxAgeHours -CurrentScriptPath $CurrentScriptPath
        if ($logsRemoved -gt 0 -or $copiesRemoved -gt 0) {
            Write-Info ('Removed {0} old log file(s), keeping the logs of the newest {1} transcripts, and {2} leftover temporary copy folder(s) of the installer.' -f $logsRemoved, $KeepTranscripts, $copiesRemoved)
        }
        if (-not $PSBoundParameters.ContainsKey('StagingRoot') -and -not [string]::IsNullOrWhiteSpace($env:ProgramData)) {
            $StagingRoot = Join-Path $env:ProgramData 'winget-app-setup'
        }
        if (-not [string]::IsNullOrWhiteSpace($StagingRoot)) {
            $wingetClientFoldersRemoved = Remove-StaleWingetClientFolder -Root $StagingRoot -MaxAgeHours $TempCopyMaxAgeHours
            if ($wingetClientFoldersRemoved -gt 0) {
                Write-Info ('Removed {0} leftover Microsoft.WinGet.Client folder(s) from {1}.' -f $wingetClientFoldersRemoved, $StagingRoot)
            }
        }
    }
    catch {
        Write-WarningMessage "Could not remove the installer's old logs and temporary copies: $($_.Exception.Message.Trim().TrimEnd('.')). Continuing."
    }
    return [pscustomobject]@{ LogsRemoved = $logsRemoved; CopiesRemoved = $copiesRemoved; WingetClientFoldersRemoved = $wingetClientFoldersRemoved }
}

<#
.SYNOPSIS
    Returns SYSTEM's own temp folder: %SystemRoot%\System32\config\systemprofile\AppData\Local\Temp.
.DESCRIPTION
    Where a SYSTEM run's 5.1 bootstrap saves its copies when started with SYSTEM's profile
    environment, as a scheduled task is; the PowerShell 7 run that cleans up may see another temp
    folder (.NET 7+ asks GetTempPath2, which names C:\Windows\SystemTemp). Only SYSTEM and
    Administrators can change entries there. Built by string concatenation (Join-Path rejects a C:
    path off Windows); a function so tests can point it elsewhere.
.OUTPUTS
    [string]
#>
function Get-SystemProfileTempRoot {
    return (Get-WindowsDirectoryPath) + '\System32\config\systemprofile\AppData\Local\Temp'
}

<#
.SYNOPSIS
    Keeps the newest transcripts in the logs folder and the installer logs of their runs, and
    deletes the rest.
.DESCRIPTION
    Reads the start time (yyyyMMdd-HHmmss) in the names the installer gives its logs:
      - transcripts: install-<time>[-bootstrap|-rmm|-userphase][-whatif].log;
      - installer logs: winget-<install|upgrade|uninstall|repair>-<package id>-<time>[-<n>].log and
        pwsh-msi-<time>-<attempt>.log.
    When there are more than KeepTranscripts transcripts, the older ones go, and so does every
    installer log older than the oldest transcript kept (a run writes its installer logs after its
    transcript starts). Names decide the order, not file timestamps. Other files (last-run.json) and
    the current transcript are never touched; a file that cannot be deleted is left for the next run.
.PARAMETER LogDirectory
    The logs folder.
.PARAMETER KeepTranscripts
    How many transcripts to keep.
.PARAMETER CurrentTranscriptPath
    This run's transcript, never deleted.
.OUTPUTS
    [int] The number of files deleted.
#>
function Remove-OldInstallerLog {
    [OutputType([int])]
    param (
        [Parameter(Mandatory = $true)]
        [string]$LogDirectory,

        [Parameter(Mandatory = $true)]
        [int]$KeepTranscripts,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$CurrentTranscriptPath
    )

    if (-not (Test-Path -LiteralPath $LogDirectory -PathType Container)) {
        return 0
    }

    $transcripts = @()
    $installerLogs = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $LogDirectory -File -Force -ErrorAction Stop)) {
        if ($file.Name -match '^install-(\d{8}-\d{6})(?:-bootstrap|-rmm|-userphase)?(?:-whatif)?\.log$') {
            $transcripts += [pscustomobject]@{ File = $file; Stamp = $Matches[1] }
        }
        elseif ($file.Name -match '^(?:winget-(?:install|upgrade|uninstall|repair)-.+|pwsh-msi)-(\d{8}-\d{6})(?:-\d+)?\.log$') {
            $installerLogs += [pscustomobject]@{ File = $file; Stamp = $Matches[1] }
        }
    }
    if ($transcripts.Count -le $KeepTranscripts) {
        return 0
    }

    # Newest first; the name breaks a tie between the transcripts of one second.
    $ordered = @($transcripts | Sort-Object -Property @{ Expression = 'Stamp'; Descending = $true }, @{ Expression = { $_.File.Name }; Descending = $true })
    $oldestKeptStamp = $ordered[$KeepTranscripts - 1].Stamp
    $toDelete = @($ordered | Select-Object -Skip $KeepTranscripts)
    $toDelete += @($installerLogs | Where-Object { [string]::CompareOrdinal($_.Stamp, $oldestKeptStamp) -lt 0 })

    $removed = 0
    foreach ($entry in $toDelete) {
        if ($CurrentTranscriptPath -and [string]::Equals($entry.File.FullName, $CurrentTranscriptPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        try {
            Remove-Item -LiteralPath $entry.File.FullName -Force -ErrorAction Stop
            $removed++
        }
        catch {
            # Open in another process, or already gone: the next run tries again.
        }
    }
    return $removed
}

<#
.SYNOPSIS
    Deletes the leftover temporary copy folders of the installer and the uninstaller.
.DESCRIPTION
    winget-app-setup-<32 hex> (the bootstrap's copy, the elevated relaunch's checked copy),
    winget-app-setup-elevate-<32 hex> and winget-app-setup-pwsh-<32 hex> folders are removed by the
    run that made them, unless it was killed. This removes those at least MaxAgeHours old. Any
    account can create such names in %SystemRoot%\Temp, so a folder goes only when SYSTEM or
    Administrators own it and it is a flat folder of files: links, subfolders and unreadable owners
    are left alone, as is the running installer's folder. It deletes the files it listed, then the
    folder without recursing, so a file added meanwhile keeps the folder.

    Root must be a folder where a non-administrator cannot rename or replace what SYSTEM or
    Administrators own (%SystemRoot%\Temp, SYSTEM's temp folder), never a user profile's.
.PARAMETER Root
    The folders to look in. Duplicates and folders that do not exist are skipped.
.PARAMETER MaxAgeHours
    The age (last write time) from which a folder is removed.
.PARAMETER CurrentScriptPath
    The running installer's path; its folder is kept.
.OUTPUTS
    [int] The number of folders deleted.
#>
function Remove-StaleInstallerCopy {
    [OutputType([int])]
    param (
        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [string[]]$Root = @(),

        [Parameter(Mandatory = $true)]
        [int]$MaxAgeHours,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$CurrentScriptPath
    )

    $cutoffUtc = [DateTime]::UtcNow.AddHours(-$MaxAgeHours)
    $allowedOwnerSids = @('S-1-5-18', 'S-1-5-32-544')
    $currentDirectory = $null
    if (-not [string]::IsNullOrWhiteSpace($CurrentScriptPath)) {
        $currentDirectory = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($CurrentScriptPath)).TrimEnd('\', '/')
    }

    $removed = 0
    $seenRoots = @{}
    foreach ($rootPath in $Root) {
        if ([string]::IsNullOrWhiteSpace($rootPath)) {
            continue
        }
        $rootKey = $rootPath.TrimEnd('\', '/').ToUpperInvariant()
        if ($seenRoots.ContainsKey($rootKey)) {
            continue
        }
        $seenRoots[$rootKey] = $true
        if (-not (Test-Path -LiteralPath $rootPath -PathType Container)) {
            continue
        }

        $candidates = @(Get-ChildItem -LiteralPath $rootPath -Directory -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^winget-app-setup-(?:elevate-|pwsh-)?[0-9a-fA-F]{32}$' })
        foreach ($directory in $candidates) {
            if ($directory.LastWriteTimeUtc -gt $cutoffUtc) {
                continue
            }
            if ($directory.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                continue
            }
            if ($currentDirectory -and [string]::Equals($directory.FullName.TrimEnd('\', '/'), $currentDirectory, [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }
            try {
                # Made by an administrator or SYSTEM, so by the installer's elevated or SYSTEM run;
                # a folder another account made is left alone, whatever its name and age.
                $ownerSid = (Get-DirectoryAccessSummary -Path $directory.FullName).OwnerSid
                if ($allowedOwnerSids -notcontains $ownerSid) {
                    continue
                }
                $children = @(Get-ChildItem -LiteralPath $directory.FullName -Force -ErrorAction Stop)
                $foreign = @($children | Where-Object { $_.PSIsContainer -or ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) })
                if ($foreign.Count -gt 0) {
                    continue
                }
                foreach ($child in $children) {
                    Remove-Item -LiteralPath $child.FullName -Force -ErrorAction Stop
                }
                # Not Remove-Item: on a folder that is not empty (something was added meanwhile) it
                # asks for confirmation instead of failing.
                [System.IO.Directory]::Delete($directory.FullName, $false)
                $removed++
            }
            catch {
                # In use, not this account's to delete, or its owner could not be read: left alone.
            }
        }
    }
    return $removed
}

<#
.SYNOPSIS
    Deletes the Microsoft.WinGet.Client engine's leftover folders.
.DESCRIPTION
    A run as SYSTEM that opted in to the engine extracts the module into
    %ProgramData%\winget-app-setup\wingetclient-<32 hex> and removes it when it ends, unless it was
    killed. This removes those at least MaxAgeHours old that SYSTEM or Administrators own and that
    are not links, with everything in them (a link inside is removed, not followed).
.PARAMETER Root
    The folder to look in (%ProgramData%\winget-app-setup, which only SYSTEM and Administrators can
    change). Missing: nothing to do.
.PARAMETER MaxAgeHours
    The age (last write time) from which a folder is removed.
.OUTPUTS
    [int] The number of folders deleted.
#>
function Remove-StaleWingetClientFolder {
    [OutputType([int])]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [int]$MaxAgeHours
    )

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        return 0
    }
    $cutoffUtc = [DateTime]::UtcNow.AddHours(-$MaxAgeHours)
    $allowedOwnerSids = @('S-1-5-18', 'S-1-5-32-544')
    $removed = 0
    $candidates = @(Get-ChildItem -LiteralPath $Root -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^wingetclient-[0-9a-fA-F]{32}$' })
    foreach ($directory in $candidates) {
        if ($directory.LastWriteTimeUtc -gt $cutoffUtc) {
            continue
        }
        if ($directory.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            continue
        }
        try {
            $ownerSid = (Get-DirectoryAccessSummary -Path $directory.FullName).OwnerSid
            if ($allowedOwnerSids -notcontains $ownerSid) {
                continue
            }
            # .NET deletes a link inside the folder without following it.
            [System.IO.Directory]::Delete($directory.FullName, $true)
            $removed++
        }
        catch {
            # In use, or its owner could not be read: left for a later run.
        }
    }
    return $removed
}
