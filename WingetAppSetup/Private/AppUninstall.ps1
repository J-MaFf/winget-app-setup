# The uninstaller's per-app step. Runs under Windows PowerShell 5.1 too: the uninstaller's elevated
# relaunch is System32's powershell.exe.

<#
.SYNOPSIS
    Returns why the uninstaller must not remove a shell it is running in, or $null.
.DESCRIPTION
    Removing the shell or the terminal running this script ends the run part-way, with no summary
    and no exit code. So Microsoft.PowerShell is kept when this runs in PowerShell 7
    (Get-PowerShellEdition), and Microsoft.WindowsTerminal when Windows Terminal hosts this session
    (Test-WindowsTerminalHostsCurrentSession). The reason says how to remove the app instead.
    Windows' 'Let Windows decide' default terminal leaves no trace to detect: to remove Windows
    Terminal there, run the uninstaller from a Windows Console Host window.
.PARAMETER PackageId
    The catalog app's winget package id.
.OUTPUTS
    [string] The skip reason, or $null when removing the app does not affect this run.
#>
function Get-HostingShellSkipReason {
    param (
        [Parameter(Mandatory = $true)]
        [string]$PackageId
    )

    if ($PackageId -eq 'Microsoft.PowerShell' -and (Get-PowerShellEdition) -eq 'Core') {
        return 'this uninstaller is running in PowerShell 7; to remove it, run winget-app-uninstall.ps1 from Windows PowerShell'
    }
    if ($PackageId -eq 'Microsoft.WindowsTerminal' -and (Test-WindowsTerminalHostsCurrentSession)) {
        return 'Windows Terminal hosts this window, or is set as the default terminal application, so removing it would close this window; to remove it, set the default terminal application to Windows Console Host and run winget-app-uninstall.ps1 from a window Windows Terminal does not host'
    }
    return $null
}

<#
.SYNOPSIS
    Returns whether a `winget uninstall` result says the app was removed and a restart finishes it.
.DESCRIPTION
    winget's uninstall has no restart result of its own: any non-zero return from the app's
    uninstaller ends it with 0x8A150030 after 'Uninstall failed with exit code: <n>'. msiexec's
    3010 and 1641 are successes that need a restart, so the result is True for 0x8A150030 with
    3010 or 1641 as a number of its own in the output. Only the number is matched, since the text
    is translated, and lines with a backslash (the installer log path) are not read.
.PARAMETER ExitCode
    winget's exit code, or $null when it did not run to the end.
.PARAMETER Output
    What winget printed (Invoke-WingetProcess's Output).
.OUTPUTS
    [bool]
#>
function Test-WingetUninstallRestartRequiredResult {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[int]]$ExitCode,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object[]]$Output
    )

    # 0x8A150030 APPINSTALLER_CLI_ERROR_EXEC_UNINSTALL_COMMAND_FAILED as a signed Int32.
    if ($null -eq $ExitCode -or $ExitCode -ne -1978335184) {
        return $false
    }
    foreach ($line in @($Output)) {
        $text = [string]$line
        if ($text.Contains('\')) {
            continue
        }
        if ($text -match '(?<![\w.])(3010|1641)(?![\w.])') {
            return $true
        }
    }
    return $false
}

<#
.SYNOPSIS
    Reads an app's uninstall entry under HKLM in one registry view, or returns $null when there is
    none.
.DESCRIPTION
    A seam over the .NET registry API, so a 32-bit PowerShell reads the 64-bit view too (its
    HKLM:\SOFTWARE is the WOW6432Node key). Read only. Throws when the key cannot be read.
.PARAMETER ProductCode
    The entry's key name under SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall: a braced GUID.
.PARAMETER View
    Registry64 (on 32-bit Windows, its only view) or Registry32 (the WOW6432Node key).
.OUTPUTS
    [pscustomobject] @{ View; UninstallString = <string or $null> }, or $null.
#>
function Get-AppUninstallEntry {
    param (
        [Parameter(Mandatory = $true)]
        [string]$ProductCode,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Registry64', 'Registry32')]
        [string]$View
    )

    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]$View)
    $key = $null
    try {
        $key = $baseKey.OpenSubKey("SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$ProductCode", $false)
        if ($null -eq $key) {
            return $null
        }
        $value = $key.GetValue('UninstallString')
        $uninstallString = $null
        if ($null -ne $value) {
            $uninstallString = [string]$value
        }
        return [pscustomobject]@{ View = $View; UninstallString = $uninstallString }
    }
    finally {
        if ($key) {
            $key.Dispose()
        }
        $baseKey.Dispose()
    }
}

<#
.SYNOPSIS
    Returns the program an UninstallString starts: the quoted path at its start, or the whole string
    when it does not start with a quote.
.DESCRIPTION
    What follows a quoted path is dropped: the catalog's arguments replace it. An unquoted string is
    taken whole, so one with arguments names no file and is refused later.
.PARAMETER UninstallString
    The uninstall entry's UninstallString.
.OUTPUTS
    [string], or $null when the string is empty or its opening quote is not closed.
#>
function Get-UninstallStringProgramPath {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$UninstallString
    )

    if ([string]::IsNullOrWhiteSpace($UninstallString)) {
        return $null
    }
    $text = $UninstallString.Trim()
    if (-not $text.StartsWith('"')) {
        return $text
    }
    $closingQuote = $text.IndexOf('"', 1)
    if ($closingQuote -lt 2) {
        return $null
    }
    return $text.Substring(1, $closingQuote - 1)
}

<#
.SYNOPSIS
    Returns the folders an app's own uninstaller may be run from: Program Files and Program Files
    (x86).
.DESCRIPTION
    Only administrators can change them, so an elevated or SYSTEM run starts nothing a standard user
    could have put there. ProgramW6432 first: in a 32-bit process ProgramFiles is the x86 folder.
    32-bit Windows has no ProgramW6432, and ProgramFiles is then its one Program Files folder.
.OUTPUTS
    [string[]]
#>
function Get-AppUninstallerRootDirectory {
    $programFiles = $env:ProgramW6432
    if ([string]::IsNullOrWhiteSpace($programFiles)) {
        $programFiles = $env:ProgramFiles
    }
    $roots = @()
    foreach ($candidate in @($programFiles, ${env:ProgramFiles(x86)})) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and $roots -notcontains $candidate) {
            $roots += $candidate
        }
    }
    return $roots
}

<#
.SYNOPSIS
    Finds the uninstaller a catalog entry's quietUninstall names, and the command line to run it
    with. Read only.
.DESCRIPTION
    Reads UninstallString from the HKLM uninstall entry named productCode, in the 64-bit view, then
    the 32-bit one (Get-AppUninstallEntry), and takes the program it starts
    (Get-UninstallStringProgramPath). That program must be a full, normalised path to an existing
    file with the extension .exe under a Get-AppUninstallerRootDirectory folder. It is run with the
    catalog's arguments instead of the entry's own.
.PARAMETER App
    A validated catalog entry with quietUninstall.
.OUTPUTS
    [pscustomobject] @{ FilePath; Arguments = [string[]]; CommandLine (as it is run, for messages);
    Problem (why it cannot be run, as the failure reason; $null when it can) }
#>
function Get-AppQuietUninstallCommand {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$App
    )

    $productCode = [string]$App['quietUninstall']['productCode']
    $arguments = @(@($App['quietUninstall']['arguments']) | ForEach-Object { [string]$_ })
    $command = [pscustomobject]@{ FilePath = $null; Arguments = $arguments; CommandLine = $null; Problem = $null }
    $notFound = 'its own uninstaller was not found:'

    $entry = $null
    $entryExists = $false
    foreach ($view in @('Registry64', 'Registry32')) {
        try {
            $candidate = Get-AppUninstallEntry -ProductCode $productCode -View $view
        }
        catch {
            $command.Problem = '{0} its uninstall entry {1} could not be read ({2})' -f $notFound, $productCode, "$($_.Exception.Message)".Trim().TrimEnd('.')
            return $command
        }
        if ($null -eq $candidate) {
            continue
        }
        $entryExists = $true
        if (-not [string]::IsNullOrWhiteSpace($candidate.UninstallString)) {
            $entry = $candidate
            break
        }
    }
    if (-not $entryExists) {
        $command.Problem = '{0} there is no uninstall entry {1} under HKLM' -f $notFound, $productCode
        return $command
    }
    if ($null -eq $entry) {
        $command.Problem = '{0} its uninstall entry {1} has no UninstallString' -f $notFound, $productCode
        return $command
    }

    $path = Get-UninstallStringProgramPath -UninstallString $entry.UninstallString
    $fullPath = $null
    if ($path) {
        try {
            if ([System.IO.Path]::IsPathRooted($path)) {
                $fullPath = [System.IO.Path]::GetFullPath($path)
            }
        }
        catch {
            $fullPath = $null
        }
    }
    $named = "{0} its uninstall entry {1} names '{2}'," -f $notFound, $productCode, $entry.UninstallString.Trim()
    # Normalised already: no '..', no relative or drive-relative path, no other separator.
    if (-not $fullPath -or -not [string]::Equals($fullPath, $path, [System.StringComparison]::OrdinalIgnoreCase)) {
        $command.Problem = '{0} which is not a full path to a program' -f $named
        return $command
    }
    if ([System.IO.Path]::GetExtension($fullPath) -ne '.exe') {
        $command.Problem = '{0} which is not an .exe file' -f $named
        return $command
    }
    $underRoot = $false
    foreach ($root in @(Get-AppUninstallerRootDirectory)) {
        try {
            $fullRoot = [System.IO.Path]::GetFullPath($root).TrimEnd([char[]]@('\', '/')) + [System.IO.Path]::DirectorySeparatorChar
        }
        catch {
            continue
        }
        if ($fullPath.StartsWith($fullRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            $underRoot = $true
            break
        }
    }
    if (-not $underRoot) {
        $command.Problem = '{0} which is not under Program Files or Program Files (x86)' -f $named
        return $command
    }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        $command.Problem = '{0} which does not exist' -f $named
        return $command
    }

    $command.FilePath = $fullPath
    $command.CommandLine = ('"{0}" {1}' -f $fullPath, (ConvertTo-ProcessArgumentString -ArgumentList $arguments)).TrimEnd()
    return $command
}

<#
.SYNOPSIS
    Waits until an app's HKLM uninstall entry is gone from both registry views, and returns whether
    it went.
.DESCRIPTION
    An uninstaller can hand its work to a copy of itself and exit at once (Google Drive's
    uninstall.exe does), so its exit is not the end of the removal. Checks at once, then every
    IntervalSeconds until TimeoutSeconds have passed. An entry that cannot be read counts as there.
.PARAMETER ProductCode
    The entry's key name (Get-AppUninstallEntry).
.PARAMETER TimeoutSeconds
    How long to wait at most; 0 or less checks once.
.PARAMETER IntervalSeconds
    The pause between checks. Default 5.
.OUTPUTS
    [bool] True when the entry is gone.
#>
function Wait-AppUninstallEntryRemoved {
    param (
        [Parameter(Mandatory = $true)]
        [string]$ProductCode,

        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds,

        [Parameter(Mandatory = $false)]
        [int]$IntervalSeconds = 5
    )

    if ($IntervalSeconds -lt 1) {
        $IntervalSeconds = 1
    }
    $pauses = [int][Math]::Floor([Math]::Max(0, $TimeoutSeconds) / $IntervalSeconds)
    for ($check = 0; $check -le $pauses; $check++) {
        if ($check -gt 0) {
            Start-Sleep -Seconds $IntervalSeconds
        }
        $present = $false
        foreach ($view in @('Registry64', 'Registry32')) {
            try {
                if ($null -ne (Get-AppUninstallEntry -ProductCode $ProductCode -View $view)) {
                    $present = $true
                }
            }
            catch {
                $present = $true
            }
        }
        if (-not $present) {
            return $true
        }
    }
    return $false
}

<#
.SYNOPSIS
    Runs a catalog app's own uninstaller with the catalog's arguments, in place of
    `winget uninstall`, and says what happened.
.DESCRIPTION
    Uninstall-CatalogApp's step for an entry with quietUninstall, once Get-AppQuietUninstallCommand
    has found the program:
      1. Invoke-ExternalProcess under the WingetUninstall limit, so the limit and the tree kill
         apply. Not started: UninstallLaunchFailed. Out of time: UninstallTimeout. An exit code
         other than 0, 3010 or 1641: UninstallFailed.
      2. For what is left of that limit, Wait-AppUninstallEntryRemoved. Still there:
         UninstallVerifyFailed.
      3. One Test-WingetPackageInstalled. Not listed: Uninstalled, with RestartRequired for 3010 or
         1641. Still listed, or no answer: UninstallVerifyFailed.
.PARAMETER App
    A validated catalog entry with quietUninstall.
.PARAMETER Command
    Get-AppQuietUninstallCommand's result, without a Problem.
.OUTPUTS
    [hashtable] Uninstall-CatalogApp's result.
#>
function Invoke-AppQuietUninstall {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$App,

        [Parameter(Mandatory = $true)]
        [object]$Command
    )

    $id = $App.name
    $productCode = [string]$App['quietUninstall']['productCode']
    $result = @{ Status = 'Failed'; SkipReason = $null; FailureReason = $null; Reason = $null; ExitCode = $null; RestartRequired = $false; Command = $Command.CommandLine }
    $program = "its uninstaller '{0}'" -f [System.IO.Path]::GetFileName($Command.FilePath)
    $timeoutSeconds = Get-ProcessTimeoutSeconds -Operation WingetUninstall

    Write-Info ('Uninstalling: {0} (its own uninstaller: {1})' -f $id, $Command.CommandLine)
    $run = Invoke-ExternalProcess -FilePath $Command.FilePath -ArgumentList @($Command.Arguments) -TimeoutSeconds $timeoutSeconds
    if ($run.LaunchFailed) {
        $result.FailureReason = 'UninstallLaunchFailed'
        $result.Reason = '{0} could not be started ({1})' -f $program, "$($run.LaunchError)".Trim().TrimEnd('.')
        return $result
    }
    if ($run.TimedOut) {
        $result.FailureReason = 'UninstallTimeout'
        $result.Reason = '{0} did not finish within {1} minutes and was stopped' -f $program, [Math]::Round($timeoutSeconds / 60)
        return $result
    }

    $exitCode = [int]$run.ExitCode
    $restartRequired = @(3010, 1641) -contains $exitCode
    if ($exitCode -ne 0 -and -not $restartRequired) {
        $result.FailureReason = 'UninstallFailed'
        $result.ExitCode = $exitCode
        $result.Reason = '{0} exited with {1} (0x{1:X8})' -f $program, $exitCode
        return $result
    }

    $exited = '{0} exited with {1}' -f $program, $exitCode
    $remainingSeconds = $timeoutSeconds - [int][Math]::Ceiling([double]$run.DurationSeconds)
    if (-not (Wait-AppUninstallEntryRemoved -ProductCode $productCode -TimeoutSeconds $remainingSeconds)) {
        $result.FailureReason = 'UninstallVerifyFailed'
        $result.Reason = '{0}, but its uninstall entry {1} was still there when the {2}-minute limit ran out' -f $exited, $productCode, [Math]::Round($timeoutSeconds / 60)
        return $result
    }

    $checkTimeoutSeconds = Get-ProcessTimeoutSeconds -Operation WingetListCheck
    $check = Test-WingetPackageInstalled -PackageId $id -TimeoutSeconds $checkTimeoutSeconds
    $noAnswer = $null
    if ($check.TimedOut) {
        $noAnswer = "'winget list' did not answer within $checkTimeoutSeconds seconds"
    }
    elseif ($check.LaunchFailed) {
        $noAnswer = 'winget could not be started ({0})' -f "$($check.LaunchError)".Trim().TrimEnd('.')
    }
    elseif ($check.CheckFailed) {
        $noAnswer = "'winget list' failed with {0}" -f (Format-WingetExitCode -ExitCode ([int]$check.ExitCode))
    }
    if ($noAnswer) {
        $result.FailureReason = 'UninstallVerifyFailed'
        $result.Reason = '{0} and its uninstall entry is gone, but whether winget still lists it could not be checked: {1}' -f $exited, $noAnswer
        return $result
    }
    if ($check.Installed) {
        $result.FailureReason = 'UninstallVerifyFailed'
        $result.Reason = '{0} and its uninstall entry is gone, but winget still lists it' -f $exited
        return $result
    }

    $result.Status = 'Uninstalled'
    $result.RestartRequired = $restartRequired
    return $result
}

<#
.SYNOPSIS
    Uninstalls one catalog app without prompting, and says what happened.
.DESCRIPTION
    The uninstaller's counterpart of Install-AppWithVerification, in this order:
      1. Installed check (Test-WingetPackageInstalled, WingetListCheck time limit). A winget that
         could not start, ran out of time or failed is a failure, never "not installed" (P2-19).
      2. Not installed: Skipped, NotInstalled.
      3. A shell this run depends on (Get-HostingShellSkipReason): Skipped, HostsThisRun.
      4. Not applicable by the installer's own rule (Test-AppApplicability, failing open): Skipped,
         NotApplicable, and left alone.
      5. An entry with quietUninstall: its own uninstaller (Get-AppQuietUninstallCommand). When it
         cannot be found, Failed, UninstallerNotFound, with nothing run: `winget uninstall` would
         start the same entry's command as written and wait. Otherwise Invoke-AppQuietUninstall.
      6. Any other entry: `winget uninstall --exact --id <id> --silent --accept-source-agreements
         --disable-interactivity` through Invoke-WingetProcess (WingetUninstall time limit). For an
         MSI, --silent adds /quiet. For an exe app winget runs the entry's QuietUninstallString,
         else its UninstallString, exactly as written, whatever --silent says: such an app needs
         quietUninstall when that command waits for a click. Exit 0 is Uninstalled; a 3010 or 1641
         from the app's uninstaller (Test-WingetUninstallRestartRequiredResult) is Uninstalled with
         RestartRequired; anything else is Failed.
    The installed check comes first, so an app that is not there is reported as not installed.
.PARAMETER App
    A validated catalog entry (Test-AppDefinitions).
.PARAMETER WhatIf
    Dry run: steps 1 to 4, and step 5's search for the uninstaller, run (they only read); an app
    that would be removed is reported as Uninstalled, with Command set for step 5, and nothing runs.
.OUTPUTS
    [hashtable] @{
        Status          = 'Uninstalled' | 'Skipped' | 'Failed'
        SkipReason      = 'NotInstalled' | 'HostsThisRun' | 'NotApplicable' when Skipped
        FailureReason   = 'CheckTimeout' | 'CheckLaunchFailed' | 'CheckFailed' |
                          'UninstallerNotFound' | 'UninstallLaunchFailed' | 'UninstallTimeout' |
                          'UninstallFailed' | 'UninstallVerifyFailed' when Failed
        Reason          = the text shown in parentheses after the app id
        ExitCode        = the exit code of the call that decided a failure, or $null
        RestartRequired = True when the app's uninstaller said a restart finishes removing it
        Command         = the command line of the app's own uninstaller (step 5), or $null
    }
#>
function Uninstall-CatalogApp {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$App,

        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    $id = $App.name
    $result = @{ Status = 'Failed'; SkipReason = $null; FailureReason = $null; Reason = $null; ExitCode = $null; RestartRequired = $false; Command = $null }

    $checkTimeoutSeconds = Get-ProcessTimeoutSeconds -Operation WingetListCheck
    $check = Test-WingetPackageInstalled -PackageId $id -TimeoutSeconds $checkTimeoutSeconds
    if ($check.TimedOut) {
        $result.FailureReason = 'CheckTimeout'
        $result.Reason = "could not check whether it is installed: 'winget list' did not answer within $checkTimeoutSeconds seconds"
        return $result
    }
    if ($check.LaunchFailed) {
        $result.FailureReason = 'CheckLaunchFailed'
        $result.Reason = 'could not check whether it is installed: winget could not be started ({0})' -f "$($check.LaunchError)".Trim().TrimEnd('.')
        return $result
    }
    if ($check.CheckFailed) {
        $result.FailureReason = 'CheckFailed'
        $result.ExitCode = $check.ExitCode
        $result.Reason = "could not check whether it is installed: 'winget list' failed with {0}" -f (Format-WingetExitCode -ExitCode ([int]$check.ExitCode))
        return $result
    }
    if (-not $check.Installed) {
        $result.Status = 'Skipped'
        $result.SkipReason = 'NotInstalled'
        $result.Reason = 'not installed'
        return $result
    }

    $hostReason = Get-HostingShellSkipReason -PackageId $id
    if ($hostReason) {
        $result.Status = 'Skipped'
        $result.SkipReason = 'HostsThisRun'
        $result.Reason = $hostReason
        return $result
    }

    # The installer's single applicability rule (review finding P3-34), so a condition with no
    # answer - one that throws, or writes an error and returns nothing - fails open here as well.
    if (-not (Test-AppApplicability -App $App -Purpose Uninstall)) {
        $conditionText = Get-AppNotApplicableReason -App $App
        $result.Status = 'Skipped'
        $result.SkipReason = 'NotApplicable'
        $result.Reason = "not applicable: $conditionText"
        return $result
    }

    # wgt-gq8.61: never fall back to winget here, which would run the command that waits.
    $quietCommand = $null
    if ($null -ne $App['quietUninstall']) {
        $quietCommand = Get-AppQuietUninstallCommand -App $App
        if ($quietCommand.Problem) {
            $result.FailureReason = 'UninstallerNotFound'
            $result.Reason = $quietCommand.Problem
            return $result
        }
        $result.Command = $quietCommand.CommandLine
    }

    if ($WhatIf) {
        $result.Status = 'Uninstalled'
        return $result
    }

    if ($quietCommand) {
        return (Invoke-AppQuietUninstall -App $App -Command $quietCommand)
    }

    Write-Info "Uninstalling: $id"
    $timeoutSeconds = Get-ProcessTimeoutSeconds -Operation WingetUninstall
    $run = Invoke-WingetProcess -ArgumentList @('uninstall', '--exact', '--id', $id, '--silent', '--accept-source-agreements', '--disable-interactivity') -TimeoutSeconds $timeoutSeconds
    if ($run.LaunchFailed) {
        $result.FailureReason = 'UninstallLaunchFailed'
        $result.Reason = 'winget could not be started ({0})' -f "$($run.LaunchError)".Trim().TrimEnd('.')
        return $result
    }
    if ($run.TimedOut) {
        $result.FailureReason = 'UninstallTimeout'
        $result.Reason = "'winget uninstall' did not finish within {0} minutes and was stopped" -f [Math]::Round($timeoutSeconds / 60)
        return $result
    }

    $restartRequired = Test-WingetUninstallRestartRequiredResult -ExitCode $run.ExitCode -Output $run.Output
    if ($run.ExitCode -eq 0 -or $restartRequired) {
        $result.Status = 'Uninstalled'
        $result.RestartRequired = [bool]$restartRequired
        return $result
    }

    $result.FailureReason = 'UninstallFailed'
    $result.ExitCode = $run.ExitCode
    $result.Reason = "'winget uninstall' exited with {0}" -f (Format-WingetExitCode -ExitCode ([int]$run.ExitCode))
    if ($run.LogPath -and (Test-Path -LiteralPath $run.LogPath)) {
        $result.Reason += "; uninstaller log: $($run.LogPath)"
    }
    return $result
}
