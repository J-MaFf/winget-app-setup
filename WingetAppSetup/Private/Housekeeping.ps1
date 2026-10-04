# Retention for what the installer leaves on disk (review finding P3-42). Every run used to add a
# transcript, per-app installer logs and, on the Windows PowerShell 5.1 irm | iex path, a full copy
# of the installer in a temp folder, and nothing ever removed them: an RMM schedule that starts the
# installer every 90 minutes grew them without bound.

<#
.SYNOPSIS
    Deletes the installer's old logs and its leftover temporary copies, never the current run's.
.DESCRIPTION
    Called by the generated entry script once a real (not -WhatIf) elevated run holds the run lock
    (Lock-InstallerRun), so two runs never prune at the same time and a dry run changes nothing.
    It keeps the logs of the newest KeepTranscripts transcripts (Remove-OldInstallerLog) and removes
    the installer's temporary copy folders older than TempCopyMaxAgeHours
    (Remove-StaleInstallerCopy). The retention numbers are this function's parameter defaults, the
    one place they are set. Housekeeping never stops a run: any failure warns and the run goes on.
.PARAMETER LogDirectory
    The logs folder. Default: the folder of this run's transcript (Get-InstallerLogDirectory);
    nothing is pruned there when there is none.
.PARAMETER KeepTranscripts
    How many install-*.log transcripts to keep, newest first. A run started from Windows PowerShell
    writes two (the bootstrap's and the PowerShell 7 run's), and one that relaunches itself elevated
    writes up to four, so 30 keeps the logs of at least the last 7 runs.
.PARAMETER TempRoot
    The folders to look for leftover copies in. Default: the elevated relaunch's copy folder
    (Get-ElevatedCopyRoot, %SystemRoot%\Temp), plus, when the run is SYSTEM (an RMM run, whose temp
    folders are system folders), this process's temp folder and SYSTEM's profile temp folder
    (Get-SystemProfileTempRoot): the Windows PowerShell 5.1 bootstrap of a SYSTEM run saves its
    copies in whichever of %SystemRoot%\Temp and that profile folder its environment names, which
    need not be the folder the PowerShell 7 run calls its own. Any other account's temp folder is
    in a user profile, where that account's processes that are not elevated can rename and replace
    entries, so an elevated run leaves it alone (review of finding P3-42).
.PARAMETER TempCopyMaxAgeHours
    A copy folder at least this old is removed. No run lasts this long, so a folder this old does
    not belong to a run still in progress.
.PARAMETER CurrentScriptPath
    The path of the running installer ($PSCommandPath). Its folder is never removed.
.RETURNS
    [pscustomobject] @{ LogsRemoved; CopiesRemoved }.
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
        [string]$CurrentScriptPath
    )

    $logsRemoved = 0
    $copiesRemoved = 0
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
    }
    catch {
        Write-WarningMessage "Could not remove the installer's old logs and temporary copies: $($_.Exception.Message.Trim().TrimEnd('.')). Continuing."
    }
    return [pscustomobject]@{ LogsRemoved = $logsRemoved; CopiesRemoved = $copiesRemoved }
}

<#
.SYNOPSIS
    Returns SYSTEM's own temp folder: %SystemRoot%\System32\config\systemprofile\AppData\Local\Temp.
.DESCRIPTION
    Where the Windows PowerShell 5.1 bootstrap of a run as SYSTEM saves the installer's copy and the
    PowerShell 7 MSI download when it was started with SYSTEM's profile environment, as a scheduled
    task running as SYSTEM is (a service such as an RMM agent usually has %SystemRoot%\Temp,
    Get-ElevatedCopyRoot, instead). The PowerShell 7 run that cleans up need not call this folder
    its own: .NET 7 and later ask Windows' GetTempPath2, which names C:\Windows\SystemTemp for
    SYSTEM where Windows has it. Only SYSTEM and Administrators can change entries in this folder,
    which Remove-StaleInstallerCopy requires of a root. Built by string concatenation, as
    Get-ElevatedCopyRoot is (Join-Path rejects a C: path off Windows); a function so tests can
    point it elsewhere.
.RETURNS
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
    Works on the file names the installer gives its logs, each of which carries the local time it
    was started at (yyyyMMdd-HHmmss):
      - transcripts: install-<time>.log, with -bootstrap and/or -whatif before .log;
      - installer logs: winget-<install|upgrade|uninstall|repair>-<package id>-<time>[-<n>].log
        (winget's --log, Invoke-WingetProcess) and pwsh-msi-<time>-<attempt>.log (msiexec's log of
        the PowerShell 7 MSI, Install-PowerShell7FromMsi).
    The newest KeepTranscripts transcripts are kept. When there are more, the older ones are
    deleted, and so is every installer log older than the oldest transcript kept: a run writes its
    installer logs after its transcript starts, so the logs of every run whose transcript is kept
    stay. The order comes from the time in the names, not from file timestamps, which copying or
    touching a file changes. Other files (last-run.json, anything a person put there) are
    never touched, nor is the current run's transcript. A file that cannot be deleted (open in
    another process) is left for the next run.
.PARAMETER LogDirectory
    The logs folder.
.PARAMETER KeepTranscripts
    How many transcripts to keep.
.PARAMETER CurrentTranscriptPath
    This run's transcript, never deleted.
.RETURNS
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
        if ($file.Name -match '^install-(\d{8}-\d{6})(?:-bootstrap)?(?:-whatif)?\.log$') {
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
    Deletes the installer's leftover temporary copy folders.
.DESCRIPTION
    The installer makes folders named winget-app-setup-<32 hex digits> (the Windows PowerShell 5.1
    bootstrap's downloaded copy for an irm | iex run, and the elevated relaunch's checked copy under
    %SystemRoot%\Temp), winget-app-setup-elevate-<32 hex digits> (the copy staged for the elevated
    window) and winget-app-setup-pwsh-<32 hex digits> (the PowerShell 7 MSI download). Each is
    removed by the run that made it, but a run that is killed, or whose window is closed, leaves its
    folder behind.

    This removes such folders once they are MaxAgeHours old. The name and the age alone do not show
    who made a folder: any account can create entries in %SystemRoot%\Temp and choose their names
    (review of finding P3-42). So a folder is removed only when it is owned by SYSTEM (S-1-5-18)
    or Administrators (S-1-5-32-544), which an account that is not an administrator cannot make
    it, and only when it is a flat folder of files: a folder that is a link, or holds a folder or
    a link, is left alone, as is a folder whose owner cannot be read. It also skips the running
    installer's own folder. Within a folder it removes, it deletes the files it listed, one by one,
    then the folder itself without recursing; a file added meanwhile makes that last step fail and
    the folder stays.

    Root must be a folder in which an account that is not an administrator cannot rename or
    replace what SYSTEM or Administrators own, such as %SystemRoot%\Temp or SYSTEM's own temp
    folder (see Invoke-InstallerHousekeeping), never a user profile's temp folder.
.PARAMETER Root
    The folders to look in. Duplicates and folders that do not exist are skipped.
.PARAMETER MaxAgeHours
    The age (last write time) from which a folder is removed.
.PARAMETER CurrentScriptPath
    The running installer's path; its folder is kept.
.RETURNS
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
