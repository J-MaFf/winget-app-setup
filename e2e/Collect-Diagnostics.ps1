<#
.SYNOPSIS
    Records what the machine looked like around an end-to-end install run, without ever failing.
.DESCRIPTION
    .github/workflows/e2e-install.yml runs this before the first install pass, after it, and at the
    end of the job. Earlier red runs kept only the installer transcripts, so #279 was blamed on
    Store servicing and #283 on an exception escaping try/catch, when the cause was a
    Winget-AutoUpdate run re-provisioning App Installer and upgrading PowerShell 7 mid-job. Each
    call writes into <OutputDirectory>\<Label>\:

      snapshot.txt  pwsh.exe versions; the Microsoft.DesktopAppInstaller and
                    Microsoft.WindowsAppRuntime* AppX packages registered for any user and those
                    provisioned for new users; the \WAU\ scheduled tasks with their last run; and
                    one status line per source.

    With -IncludeLogs it also writes:

      events-MsiInstaller.txt    Application-log MsiInstaller events since -Since.
      events-RestartManager.txt  Application-log Microsoft-Windows-RestartManager events.
      events-AppXDeployment.txt  Microsoft-Windows-AppXDeploymentServer/Operational errors and
                                 warnings.
      wau-logs\                  A copy of Winget-AutoUpdate's logs folder.

    Every source is optional. A missing or failing source is recorded in snapshot.txt and the
    script still exits 0, so diagnostics never turn a run red or hide the real failure.

    The workflow runs it under Windows PowerShell 5.1 (shell: powershell), which a broken or
    removed PowerShell 7 cannot take down, so keep it free of PowerShell 7-only syntax and
    non-ASCII characters. Under PowerShell 7 the AppX cmdlets may fail; that is recorded too.
.PARAMETER OutputDirectory
    Folder that receives one subfolder per label. Created if missing.
.PARAMETER Label
    Name of this snapshot's subfolder, e.g. '1-before-first-pass'. Prefix a number so the
    snapshots sort in the order they were taken.
.PARAMETER IncludeLogs
    Also collect the event logs and Winget-AutoUpdate's log files (the end-of-job snapshot).
.PARAMETER Since
    Start of the event-log window. Default: the last boot, which on a fresh hosted runner covers
    the whole job.
.PARAMETER WauLogDirectory
    Winget-AutoUpdate's logs folder. Default: the 'logs' folder under the InstallLocation that WAU
    records in HKLM:\SOFTWARE\Romanitho\Winget-AutoUpdate, else under
    %ProgramFiles%\Winget-AutoUpdate.
.NOTES
    Exit code: always 0.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory,

    [Parameter(Mandatory = $true)]
    [string]$Label,

    [Parameter(Mandatory = $false)]
    [switch]$IncludeLogs,

    [Parameter(Mandatory = $false)]
    [datetime]$Since,

    [Parameter(Mandatory = $false)]
    [string]$WauLogDirectory
)

$ErrorActionPreference = 'Stop'

$report = New-Object System.Collections.Generic.List[string]
$sources = New-Object System.Collections.Generic.List[string]

function Add-SourceStatus {
    param ([string]$Source, [string]$Status)
    # One line per source: some cmdlet errors span several lines.
    $sources.Add(('{0}: {1}' -f $Source, ($Status.Trim() -replace '\s*[\r\n]+\s*', ' ')))
}

function Write-TextFile {
    # UTF-8 without a BOM on both 5.1 and 7, so the issue reporter can embed the file as-is.
    param ([string]$Path, [string[]]$Lines)
    if ($null -eq $Lines) { $Lines = @() }
    [System.IO.File]::WriteAllLines($Path, [string[]]$Lines)
}

try {
    $targetDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath((Join-Path $OutputDirectory $Label))
    $null = New-Item -ItemType Directory -Path $targetDirectory -Force
}
catch {
    Write-Warning "E2E diagnostics: cannot create the output folder for '$Label' ($($_.Exception.Message)); nothing was collected."
    exit 0
}

$report.Add("E2E diagnostics snapshot: $Label")
$report.Add(('Taken {0:yyyy-MM-ddTHH:mm:ssZ} by PowerShell {1} ({2})' -f (Get-Date).ToUniversalTime(), $PSVersionTable.PSVersion, $PSVersionTable.PSEdition))
if ($env:ImageOS -or $env:ImageVersion) {
    $report.Add("Runner image: $env:ImageOS $env:ImageVersion")
}

# --- PowerShell 7 -------------------------------------------------------------------------
# Read from the files and the registry instead of launching pwsh, so a broken install cannot
# hang this step. A version change between snapshots means something upgraded PowerShell 7
# under the running installer (#283).
$report.Add('')
$report.Add('== PowerShell 7 (pwsh) ==')
try {
    $pwshCommands = @(Get-Command -Name 'pwsh' -CommandType Application -All -ErrorAction SilentlyContinue)
    if ($pwshCommands.Count -eq 0) {
        $report.Add('pwsh: not found on PATH')
    }
    foreach ($command in $pwshCommands) {
        $version = $null
        try {
            $version = (Get-Item -LiteralPath $command.Source).VersionInfo.ProductVersion
        }
        catch {
            $version = $null
        }
        if (-not $version) { $version = 'version unknown' }
        $report.Add(('{0}  {1}' -f $command.Source, $version))
    }
    $installedVersionsKey = 'HKLM:\SOFTWARE\Microsoft\PowerShellCore\InstalledVersions'
    if (Test-Path -LiteralPath $installedVersionsKey) {
        foreach ($key in @(Get-ChildItem -LiteralPath $installedVersionsKey)) {
            $entry = Get-ItemProperty -LiteralPath $key.PSPath
            $report.Add(('Registered install: {0} at {1}' -f $entry.SemanticVersion, $entry.InstallLocation))
        }
    }
    if ($pwshCommands.Count -gt 0) {
        Add-SourceStatus 'pwsh' 'OK'
    }
    else {
        Add-SourceStatus 'pwsh' 'MISSING (not on PATH)'
    }
}
catch {
    Add-SourceStatus 'pwsh' "ERROR: $($_.Exception.Message)"
}

# --- AppX: App Installer (winget) and the WindowsAppRuntime framework ---------------------
# -AllUsers, because the #279/#284 wedge was visible only across users: a newer App Installer
# provisioned machine-wide that could not register without Microsoft.WindowsAppRuntime.1.8.
$report.Add('')
$report.Add('== AppX packages registered for any user ==')
try {
    $packages = @(
        foreach ($name in @('Microsoft.DesktopAppInstaller', 'Microsoft.WindowsAppRuntime*')) {
            Get-AppxPackage -AllUsers -Name $name -ErrorAction Stop
        }
    )
    if ($packages.Count -eq 0) {
        $report.Add('none')
    }
    foreach ($package in @($packages | Sort-Object -Property Name, PackageFullName)) {
        $report.Add(('{0} {1} {2} Status={3} Framework={4}' -f $package.Name, $package.Version, $package.Architecture, $package.Status, $package.IsFramework))
        $report.Add("  PackageFullName: $($package.PackageFullName)")
        $report.Add("  InstallLocation: $($package.InstallLocation)")
        $users = @($package.PackageUserInformation | ForEach-Object { "$_" })
        if ($users.Count -gt 0) {
            $report.Add("  Users: $($users -join '; ')")
        }
    }
    Add-SourceStatus 'AppX (all users)' "OK, $($packages.Count) package(s)"
}
catch {
    $report.Add('not collected (see Sources)')
    Add-SourceStatus 'AppX (all users)' "ERROR: $($_.Exception.Message)"
}

$report.Add('')
$report.Add('== AppX packages provisioned for new users ==')
try {
    $provisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop | Where-Object {
            $_.DisplayName -like 'Microsoft.DesktopAppInstaller*' -or $_.DisplayName -like 'Microsoft.WindowsAppRuntime*'
        })
    if ($provisioned.Count -eq 0) {
        $report.Add('none')
    }
    foreach ($package in @($provisioned | Sort-Object -Property PackageName)) {
        $report.Add(('{0} {1} ({2})' -f $package.DisplayName, $package.Version, $package.PackageName))
    }
    Add-SourceStatus 'AppX (provisioned)' "OK, $($provisioned.Count) package(s)"
}
catch {
    $report.Add('not collected (see Sources)')
    Add-SourceStatus 'AppX (provisioned)' "ERROR: $($_.Exception.Message)"
}

# --- Winget-AutoUpdate scheduled tasks -------------------------------------------------------
# A LastRunTime inside the job means WAU ran while the installer was working.
$report.Add('')
$report.Add('== Winget-AutoUpdate scheduled tasks (\WAU\) ==')
try {
    $tasks = @()
    try {
        $tasks = @(Get-ScheduledTask -TaskPath '\WAU\' -ErrorAction Stop)
    }
    catch {
        # Get-ScheduledTask reports an empty folder as an error.
        if ($_.FullyQualifiedErrorId -notlike 'CmdletizationQuery_NotFound*') { throw }
    }
    if ($tasks.Count -eq 0) {
        $report.Add('none')
    }
    foreach ($task in $tasks) {
        $triggers = @($task.Triggers | ForEach-Object { "$($_.CimClass.CimClassName)" -replace '^MSFT_Task', '' }) -join ', '
        $line = '{0} State={1} Triggers=[{2}]' -f $task.TaskName, $task.State, $triggers
        try {
            $info = Get-ScheduledTaskInfo -InputObject $task -ErrorAction Stop
            $line += (' LastRun={0:yyyy-MM-ddTHH:mm:ss} LastResult=0x{1:X8} NextRun={2:yyyy-MM-ddTHH:mm:ss}' -f $info.LastRunTime, [int64]$info.LastTaskResult, $info.NextRunTime)
        }
        catch {
            $line += " (run info unavailable: $($_.Exception.Message))"
        }
        $report.Add($line)
    }
    Add-SourceStatus 'WAU tasks' "OK, $($tasks.Count) task(s)"
}
catch {
    $report.Add('not collected (see Sources)')
    Add-SourceStatus 'WAU tasks' "ERROR: $($_.Exception.Message)"
}

if ($IncludeLogs) {
    # --- Event logs ------------------------------------------------------------------------
    # MsiInstaller shows which MSI ran when (WAU's own MSI upgrades included), RestartManager
    # shows what was shut down to replace files in use, and AppXDeploymentServer shows why an
    # App Installer registration was rejected (0x80073CF3, 0x80073D06).
    if ($PSBoundParameters.ContainsKey('Since')) {
        $windowStart = $Since
    }
    else {
        try {
            $windowStart = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
        }
        catch {
            $windowStart = (Get-Date).AddHours(-6)
        }
    }
    $windowText = '{0:yyyy-MM-ddTHH:mm:ss}' -f $windowStart

    $eventSources = @(
        @{ Name = 'MsiInstaller events'; File = 'events-MsiInstaller.txt'; Filter = @{ LogName = 'Application'; ProviderName = 'MsiInstaller' } },
        @{ Name = 'RestartManager events'; File = 'events-RestartManager.txt'; Filter = @{ LogName = 'Application'; ProviderName = 'Microsoft-Windows-RestartManager' } },
        @{ Name = 'AppX deployment errors/warnings'; File = 'events-AppXDeployment.txt'; Filter = @{ LogName = 'Microsoft-Windows-AppXDeploymentServer/Operational'; Level = @(1, 2, 3) } }
    )
    foreach ($eventSource in $eventSources) {
        $filter = $eventSource.Filter.Clone()
        $filter.StartTime = $windowStart
        try {
            $events = @(Get-WinEvent -FilterHashtable $filter -MaxEvents 5000 -ErrorAction Stop | Sort-Object -Property TimeCreated)
            $lines = New-Object System.Collections.Generic.List[string]
            foreach ($logEvent in $events) {
                $lines.Add(('{0:yyyy-MM-ddTHH:mm:ss.fff} [{1}] {2} id={3}' -f $logEvent.TimeCreated, $logEvent.LevelDisplayName, $logEvent.ProviderName, $logEvent.Id))
                foreach ($messageLine in ("$($logEvent.Message)".Trim() -split "`r?`n")) {
                    $lines.Add('    ' + $messageLine)
                }
            }
            Write-TextFile -Path (Join-Path $targetDirectory $eventSource.File) -Lines $lines.ToArray()
            Add-SourceStatus $eventSource.Name "$($events.Count) since $windowText -> $($eventSource.File)"
        }
        catch {
            if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') {
                Add-SourceStatus $eventSource.Name "none since $windowText"
            }
            else {
                Add-SourceStatus $eventSource.Name "ERROR: $($_.Exception.Message)"
            }
        }
    }

    # --- Winget-AutoUpdate logs -----------------------------------------------------------
    try {
        if (-not $WauLogDirectory) {
            $wauRoot = $null
            $wauKey = 'HKLM:\SOFTWARE\Romanitho\Winget-AutoUpdate'
            if (Test-Path -LiteralPath $wauKey) {
                $wauRoot = (Get-ItemProperty -LiteralPath $wauKey).InstallLocation
            }
            if (-not $wauRoot -and $env:ProgramFiles) {
                $wauRoot = Join-Path $env:ProgramFiles 'Winget-AutoUpdate'
            }
            if ($wauRoot) {
                $WauLogDirectory = Join-Path $wauRoot 'logs'
            }
        }
        if ($WauLogDirectory -and (Test-Path -LiteralPath $WauLogDirectory -PathType Container)) {
            $destination = Join-Path $targetDirectory 'wau-logs'
            $null = New-Item -ItemType Directory -Path $destination -Force
            # One entry at a time, so a log WAU holds open does not stop the rest from copying.
            $copyErrors = New-Object System.Collections.Generic.List[string]
            foreach ($item in @(Get-ChildItem -LiteralPath $WauLogDirectory -Force)) {
                try {
                    Copy-Item -LiteralPath $item.FullName -Destination $destination -Recurse -Force -ErrorAction Stop
                }
                catch {
                    $copyErrors.Add("$($item.Name): $($_.Exception.Message)")
                }
            }
            $copied = @(Get-ChildItem -LiteralPath $destination -Recurse -File).Count
            $status = "$copied file(s) from $WauLogDirectory -> wau-logs"
            if ($copyErrors.Count -gt 0) {
                $status += "; not copied: $($copyErrors -join '; ')"
            }
            Add-SourceStatus 'WAU logs' $status
        }
        elseif ($WauLogDirectory) {
            Add-SourceStatus 'WAU logs' "not present ($WauLogDirectory)"
        }
        else {
            Add-SourceStatus 'WAU logs' 'not present (no Winget-AutoUpdate install location found)'
        }
    }
    catch {
        Add-SourceStatus 'WAU logs' "ERROR: $($_.Exception.Message)"
    }
}

$report.Add('')
$report.Add('== Sources ==')
foreach ($line in $sources) {
    $report.Add($line)
}

try {
    Write-TextFile -Path (Join-Path $targetDirectory 'snapshot.txt') -Lines $report.ToArray()
}
catch {
    Write-Warning "E2E diagnostics: could not write snapshot.txt ($($_.Exception.Message))."
}
Write-Host ($report.ToArray() -join [Environment]::NewLine)
exit 0
