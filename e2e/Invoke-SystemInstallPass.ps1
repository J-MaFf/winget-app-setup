<#
.SYNOPSIS
    Runs the installer as SYSTEM the way Endpoint Central does, through the RMM wrapper started by a
    32-bit Windows PowerShell, and checks the run.
.DESCRIPTION
    The e2e-install-system job of .github/workflows/e2e-install.yml (work-order item 34). It
    registers a one-shot scheduled task that runs as SYSTEM:

        %SystemRoot%\SysWOW64\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive
            -ExecutionPolicy Bypass -File <checkout>\rmm\Invoke-WingetAppSetup.ps1
            -InstallerPath <checkout>\winget-app-install.ps1 -InstallerSha256 <its SHA256>

    SysWOW64's powershell.exe is the 32-bit one, as Endpoint Central's 32-bit agent starts scripts,
    so the wrapper has to relaunch itself in 64-bit Windows PowerShell through Sysnative. The wrapper
    gets the checkout's installer, not its pinned commit, so the run tests the code under review; it
    still copies it into its protected folder and checks its SHA256. The script starts the task,
    waits for it (printing the newest transcript line every minute), reads its LastTaskResult and
    removes it, then checks:

      - the exit code, with the policy of every install pass (Get-InstallPassVerdict in
        e2e/Invoke-InstallPass.ps1): 0 and 3010 pass, and 8 passes only when the run's transcript
        says auto-updates were not configured because Microsoft.WindowsAppRuntime.1.8 is missing,
        as on windows-latest;
      - the wrapper's log (install-<time>-rmm.log): it was started by a 32-bit PowerShell and
        relaunched through Sysnative, it checked the installer, and it passed the installer's exit
        code back unchanged;
      - the run's transcript says it ran as SYSTEM, and last-run.json records the same exit code
        and a run that reached its summary;
      - nothing was installed per-user into SYSTEM's own profile: no new entry under
        HKEY_USERS\S-1-5-18\Software\Microsoft\Windows\CurrentVersion\Uninstall (or its
        WOW6432Node twin), and no new folder under SYSTEM's AppData\Local\Programs (System32's and
        SysWOW64's systemprofile). A run as SYSTEM installs for the whole PC only and defers the
        rest; winget's default scope would have put a per-user app there.

    Prints an '=== E2E assertion results ===' table and exits 0 when every check passed; otherwise
    with the run's exit code when that is what failed, or 1.

    The checks are functions (Get-SystemInstallPassResult and the helpers it uses) that read only
    what they are given, so tests/E2ESystemInstallPass.Tests.ps1 runs them on any OS; the task
    handling needs Windows.

    Runs under Windows PowerShell 5.1 and PowerShell 7: ASCII only, no 7-only syntax.
.PARAMETER RmmWrapperPath
    Default: rmm\Invoke-WingetAppSetup.ps1 in the checkout.
.PARAMETER CheckoutInstallerPath
    Default: winget-app-install.ps1 in the checkout.
.PARAMETER InstallerLogDirectory
    Default: %ProgramData%\winget-app-setup\logs.
.PARAMETER TimeoutMinutes
    How long the task may run. Default 40.
.NOTES
    Exit codes: 0 = every check passed; the run's exit code or 1 = a check failed; 64 = bad
    arguments; 127 = the task could not be registered or started.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [string]$RmmWrapperPath,

    [Parameter(Mandatory = $false)]
    [string]$CheckoutInstallerPath,

    [Parameter(Mandatory = $false)]
    [string]$InstallerLogDirectory,

    [Parameter(Mandatory = $false)]
    [ValidateRange(5, 120)]
    [int]$TimeoutMinutes = 40
)

# Get-InstallPassVerdict and Get-InstallPassTranscript (and, through it, TranscriptAssertions.ps1).
# Dot-sourcing it also sets its parameters as variables here ($InstallerPath, $LogDirectory, ...),
# which is why this script's own parameters have other names.
. (Join-Path $PSScriptRoot 'Invoke-InstallPass.ps1')

$script:SystemTaskName = 'winget-app-setup-e2e-system'

<#
.SYNOPSIS
    Returns the scheduled task's command line arguments for the wrapper.
#>
function Get-SystemPassTaskArgument {
    param (
        [Parameter(Mandatory = $true)]
        [string]$WrapperPath,
        [Parameter(Mandatory = $true)]
        [string]$InstallerPath,
        [Parameter(Mandatory = $true)]
        [string]$InstallerSha256
    )

    return ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -InstallerPath "{1}" -InstallerSha256 {2}' -f $WrapperPath, $InstallerPath, $InstallerSha256)
}

<#
.SYNOPSIS
    Turns a scheduled task's LastTaskResult (an unsigned 32-bit number) into the exit code as a
    signed 32-bit number, the way the process returned it.
#>
function ConvertTo-TaskExitCode {
    param (
        [Parameter(Mandatory = $true)]
        [long]$LastTaskResult
    )

    if ($LastTaskResult -gt [int]::MaxValue) {
        return [int]($LastTaskResult - 4294967296)
    }
    return [int]$LastTaskResult
}

<#
.SYNOPSIS
    Lists what is installed per-user in SYSTEM's own profile: uninstall entries in its registry
    hive and folders under its AppData\Local\Programs.
.PARAMETER RegistryPath
    The uninstall keys to read. Default: SYSTEM's (HKEY_USERS\S-1-5-18), and their WOW6432Node twin.
.PARAMETER FolderPath
    The folders to list. Default: AppData\Local\Programs of System32's and SysWOW64's systemprofile
    (a 32-bit installer running as SYSTEM writes to the second).
.RETURNS
    [string[]] One entry per key or folder: the key or folder path, with the DisplayName of a key
    in brackets.
#>
function Get-SystemProfileInstallEntry {
    param (
        [Parameter(Mandatory = $false)]
        [string[]]$RegistryPath = @(
            'Registry::HKEY_USERS\S-1-5-18\Software\Microsoft\Windows\CurrentVersion\Uninstall',
            'Registry::HKEY_USERS\S-1-5-18\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
        ),
        [Parameter(Mandatory = $false)]
        [string[]]$FolderPath = @(
            "$env:SystemRoot\System32\config\systemprofile\AppData\Local\Programs",
            "$env:SystemRoot\SysWOW64\config\systemprofile\AppData\Local\Programs"
        )
    )

    $entries = @()
    foreach ($path in $RegistryPath) {
        if (-not (Test-Path -LiteralPath $path)) {
            continue
        }
        foreach ($key in @(Get-ChildItem -LiteralPath $path -ErrorAction SilentlyContinue)) {
            $displayName = $null
            try {
                $displayName = (Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop).DisplayName
            }
            catch {
            }
            $entry = '{0}\{1}' -f ($path -replace '^Registry::', ''), $key.PSChildName
            if ($displayName) {
                $entry = '{0} [{1}]' -f $entry, $displayName
            }
            $entries += $entry
        }
    }
    foreach ($path in $FolderPath) {
        if (-not (Test-Path -LiteralPath $path -PathType Container)) {
            continue
        }
        foreach ($item in @(Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue)) {
            $entries += $item.FullName
        }
    }
    return [string[]]$entries
}

<#
.SYNOPSIS
    Returns the entries in After that were not in Before.
#>
function Compare-SystemProfileInstallEntry {
    param (
        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [string[]]$Before = @(),
        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [string[]]$After = @()
    )

    return [string[]]@($After | Where-Object { $Before -notcontains $_ })
}

<#
.SYNOPSIS
    Checks a SYSTEM run from what it left behind.
.PARAMETER TaskExitCode
    The task's exit code (ConvertTo-TaskExitCode), or $null when the task never finished.
.PARAMETER Transcript
    The run's transcript (Get-InstallPassTranscript), or $null.
.PARAMETER WrapperLog
    The text of the wrapper's log (install-<time>-rmm.log), or $null when there is none.
.PARAMETER RunRecord
    last-run.json, parsed, or $null.
.PARAMETER NewSystemProfileEntries
    What appeared in SYSTEM's profile during the run (Compare-SystemProfileInstallEntry).
.RETURNS
    [pscustomobject] with Results (Assertion, Result 'PASS' or 'FAIL', Detail) and StepExitCode.
#>
function Get-SystemInstallPassResult {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[int]]$TaskExitCode,
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $Transcript,
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$WrapperLog,
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $RunRecord,
        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [string[]]$NewSystemProfileEntries = @()
    )

    $results = @()
    $stepExitCode = 0

    if ($null -eq $TaskExitCode) {
        $results += [pscustomobject]@{ Assertion = 'SYSTEM run exit code'; Result = 'FAIL'; Detail = 'the scheduled task did not finish' }
        $stepExitCode = 1
    }
    else {
        $verdict = Get-InstallPassVerdict -ExitCode $TaskExitCode -KnownPlatformIncompatible '' -Pass 'system' -Transcript $Transcript
        $result = 'PASS'
        if ($verdict.Outcome -eq 'failed') {
            $result = 'FAIL'
            $stepExitCode = $verdict.StepExitCode
        }
        $results += [pscustomobject]@{ Assertion = 'SYSTEM run exit code'; Result = $result; Detail = $verdict.Message }
    }

    $wrapperText = ''
    if ($WrapperLog) {
        $wrapperText = $WrapperLog
    }
    $relaunched = $wrapperText.Contains('Started by a 32-bit PowerShell on 64-bit Windows, and relaunched in 64-bit Windows PowerShell through Sysnative.')
    $relaunchDetail = 'the wrapper log does not say it was relaunched from a 32-bit PowerShell'
    if (-not $WrapperLog) {
        $relaunchDetail = 'no wrapper log (install-<time>-rmm.log) from this run'
    }
    elseif ($relaunched) {
        $relaunchDetail = 'started by SysWOW64 powershell.exe, relaunched through Sysnative'
    }
    $results += [pscustomobject]@{ Assertion = 'Wrapper relaunched in 64-bit Windows PowerShell'; Result = $(if ($relaunched) { 'PASS' } else { 'FAIL' }); Detail = $relaunchDetail }

    $checked = $wrapperText -match 'Installer checked \(SHA256 [0-9A-F]{64}\)\.'
    $results += [pscustomobject]@{ Assertion = 'Wrapper checked the installer''s SHA256'; Result = $(if ($checked) { 'PASS' } else { 'FAIL' }); Detail = $(if ($checked) { $Matches[0] } else { 'no ''Installer checked'' line in the wrapper log' }) }

    $passedBack = $false
    $passedBackDetail = 'no ''The installer exited with'' line in the wrapper log'
    if ($wrapperText -match 'The installer exited with (-?\d+)\.') {
        $installerExitCode = [int]$Matches[1]
        $passedBack = ($null -ne $TaskExitCode -and $installerExitCode -eq $TaskExitCode)
        $passedBackDetail = 'the installer exited with {0}, the task with {1}' -f $installerExitCode, $TaskExitCode
    }
    $results += [pscustomobject]@{ Assertion = 'Wrapper passed the exit code back unchanged'; Result = $(if ($passedBack) { 'PASS' } else { 'FAIL' }); Detail = $passedBackDetail }

    $ranAsSystem = $false
    $ranAsSystemDetail = 'no transcript of the run'
    if ($Transcript) {
        $ranAsSystemDetail = "$($Transcript.Name) has no 'Running as SYSTEM' line"
        if ($Transcript.Parsed.RanAsSystem) {
            $ranAsSystem = $true
            $ranAsSystemDetail = "$($Transcript.Name): Running as SYSTEM"
        }
    }
    $results += [pscustomobject]@{ Assertion = 'Installer ran as SYSTEM'; Result = $(if ($ranAsSystem) { 'PASS' } else { 'FAIL' }); Detail = $ranAsSystemDetail }

    $recordOk = $false
    $recordDetail = 'no last-run.json'
    if ($null -ne $RunRecord) {
        $recordDetail = 'exitCode {0}, summaryReached {1}, deferred: {2}' -f $RunRecord.exitCode, $RunRecord.summaryReached, ((@($RunRecord.apps | Where-Object { $_.status -eq 'Deferred' } | ForEach-Object { $_.id }) -join ', '))
        $recordOk = ($null -ne $TaskExitCode -and $null -ne $RunRecord.exitCode -and [int]$RunRecord.exitCode -eq $TaskExitCode -and $RunRecord.summaryReached -eq $true)
    }
    $results += [pscustomobject]@{ Assertion = 'last-run.json records the run'; Result = $(if ($recordOk) { 'PASS' } else { 'FAIL' }); Detail = $recordDetail }

    $newEntries = @($NewSystemProfileEntries | Where-Object { $_ })
    $profileDetail = 'nothing new under SYSTEM''s uninstall keys or AppData\Local\Programs'
    if ($newEntries.Count -gt 0) {
        $profileDetail = 'installed per-user for SYSTEM: ' + ($newEntries -join '; ')
    }
    $results += [pscustomobject]@{ Assertion = 'Nothing installed per-user into SYSTEM''s profile'; Result = $(if ($newEntries.Count -eq 0) { 'PASS' } else { 'FAIL' }); Detail = $profileDetail }

    if ($stepExitCode -eq 0 -and @($results | Where-Object { $_.Result -eq 'FAIL' }).Count -gt 0) {
        $stepExitCode = 1
    }
    return [pscustomobject]@{ Results = $results; StepExitCode = $stepExitCode }
}

if ($MyInvocation.InvocationName -ne '.') {
    $repositoryRoot = Split-Path -Parent $PSScriptRoot
    $wrapperFilePath = $RmmWrapperPath
    if (-not $wrapperFilePath) {
        $wrapperFilePath = Join-Path $repositoryRoot 'rmm\Invoke-WingetAppSetup.ps1'
    }
    $installerFilePath = $CheckoutInstallerPath
    if (-not $installerFilePath) {
        $installerFilePath = Join-Path $repositoryRoot 'winget-app-install.ps1'
    }
    $logFolder = $InstallerLogDirectory
    if (-not $logFolder) {
        $logFolder = Join-Path $env:ProgramData 'winget-app-setup\logs'
    }
    $wrapperFilePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($wrapperFilePath)
    $installerFilePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($installerFilePath)
    if (-not (Test-Path -LiteralPath $wrapperFilePath -PathType Leaf) -or -not (Test-Path -LiteralPath $installerFilePath -PathType Leaf)) {
        Write-Host "Invoke-SystemInstallPass.ps1: no wrapper at $wrapperFilePath or no installer at $installerFilePath." -ForegroundColor Red
        exit 64
    }
    $ErrorActionPreference = 'Continue'

    $installerSha256 = (Get-FileHash -LiteralPath $installerFilePath -Algorithm SHA256).Hash
    $powerShell32 = "$env:SystemRoot\SysWOW64\WindowsPowerShell\v1.0\powershell.exe"
    $taskArgument = Get-SystemPassTaskArgument -WrapperPath $wrapperFilePath -InstallerPath $installerFilePath -InstallerSha256 $installerSha256
    Write-Host "Installer under test: $installerFilePath (SHA256 $installerSha256), through $wrapperFilePath ($env:GITHUB_REF at $env:GITHUB_SHA)."
    Write-Host "The task runs as SYSTEM: $powerShell32 $taskArgument"

    $profileBefore = Get-SystemProfileInstallEntry
    try {
        $action = New-ScheduledTaskAction -Execute $powerShell32 -Argument $taskArgument
        $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes $TimeoutMinutes) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        $null = Register-ScheduledTask -TaskName $script:SystemTaskName -Action $action -Principal $principal -Settings $settings -Force -ErrorAction Stop
        $startedAt = Get-Date
        Start-ScheduledTask -TaskName $script:SystemTaskName -ErrorAction Stop
    }
    catch {
        Write-Host "Could not register or start the SYSTEM task: $($_.Exception.Message)" -ForegroundColor Red
        exit 127
    }

    # 267009 (0x41301) is 'the task is running', 267011 (0x41303) 'the task has not yet run'.
    $deadline = $startedAt.AddMinutes($TimeoutMinutes + 2)
    $taskExitCode = $null
    $lastReport = Get-Date
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 15
        $task = Get-ScheduledTask -TaskName $script:SystemTaskName -ErrorAction SilentlyContinue
        $info = Get-ScheduledTaskInfo -TaskName $script:SystemTaskName -ErrorAction SilentlyContinue
        if ($task -and $info -and "$($task.State)" -ne 'Running' -and $info.LastRunTime -ge $startedAt.AddMinutes(-1) -and @(267009, 267011) -notcontains $info.LastTaskResult) {
            $taskExitCode = ConvertTo-TaskExitCode -LastTaskResult $info.LastTaskResult
            break
        }
        if (((Get-Date) - $lastReport).TotalSeconds -ge 60) {
            $lastReport = Get-Date
            $newest = Get-ChildItem -LiteralPath $logFolder -Filter 'install-*.log' -File -ErrorAction SilentlyContinue | Sort-Object -Property LastWriteTime | Select-Object -Last 1
            $line = ''
            if ($newest) {
                $line = "$($newest.Name): " + (Get-Content -LiteralPath $newest.FullName -Tail 1 -ErrorAction SilentlyContinue)
            }
            Write-Host ('[{0:N0} min] the SYSTEM run is still going. {1}' -f ((Get-Date) - $startedAt).TotalMinutes, $line)
        }
    }
    if ($null -eq $taskExitCode) {
        Write-Host "The SYSTEM task did not finish within $($TimeoutMinutes + 2) minutes; stopping it." -ForegroundColor Red
        Stop-ScheduledTask -TaskName $script:SystemTaskName -ErrorAction SilentlyContinue
    }
    else {
        Write-Host "The SYSTEM task ended with exit code $taskExitCode."
    }
    Unregister-ScheduledTask -TaskName $script:SystemTaskName -Confirm:$false -ErrorAction SilentlyContinue

    $newProfileEntries = Compare-SystemProfileInstallEntry -Before $profileBefore -After (Get-SystemProfileInstallEntry)
    $transcript = Get-InstallPassTranscript -LogDirectory $logFolder -Since $startedAt
    $wrapperLog = $null
    $wrapperFile = @((Get-InstallTranscriptFile -LogDirectory $logFolder).Rmm | Where-Object { $_.LastWriteTime -ge $startedAt }) | Select-Object -Last 1
    if ($wrapperFile) {
        $wrapperLog = [string](Get-Content -LiteralPath $wrapperFile.FullName -Raw)
    }
    $runRecord = $null
    $runRecordPath = Join-Path $logFolder 'last-run.json'
    if (Test-Path -LiteralPath $runRecordPath -PathType Leaf) {
        try {
            $runRecord = Get-Content -LiteralPath $runRecordPath -Raw | ConvertFrom-Json
        }
        catch {
            Write-Host "Could not read ${runRecordPath}: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    $check = Get-SystemInstallPassResult -TaskExitCode $taskExitCode -Transcript $transcript -WrapperLog $wrapperLog -RunRecord $runRecord -NewSystemProfileEntries $newProfileEntries
    Write-Host ''
    Write-Host '=== E2E assertion results ==='
    Write-Host ($check.Results | Format-Table -AutoSize -Wrap | Out-String -Width 4096).TrimEnd()
    $failures = @($check.Results | Where-Object { $_.Result -eq 'FAIL' })
    if ($failures.Count -gt 0) {
        Write-Host ''
        Write-Host "FAILED: $($failures.Count) assertion(s) failed:" -ForegroundColor Red
        foreach ($failure in $failures) {
            Write-Host "  - $($failure.Assertion): $($failure.Detail)" -ForegroundColor Red
        }
    }
    else {
        Write-Host ''
        Write-Host "PASSED: all $(@($check.Results).Count) assertions passed." -ForegroundColor Green
    }
    exit $check.StepExitCode
}
