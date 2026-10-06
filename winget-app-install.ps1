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
 list is returned by Get-DefaultAppCatalog (WingetAppSetup/Public/AppCatalog.ps1,
 inlined below in this generated file) and shared with winget-app-uninstall.ps1.
 Run the script with -WhatIf to preview the exact set of planned installs without
 making any system changes.

.PARAMETER WhatIf
 When specified, performs all pre-flight checks and displays planned actions without making any system changes.

.PARAMETER SkipSystemCheck
 Bypasses the pre-flight system checks (OS version, disk space, network) for headless or automated use.

.PARAMETER NonInteractive
 Suppresses the interactive extra for unattended runs (RMM, CI, scheduled tasks): the "press any
 key to exit" that holds the window at the end of a run or after an early failure. Also turned on
 by the environment variable WINGET_APP_SETUP_NONINTERACTIVE=1 (or true, or yes), for the
 irm | iex one-liner, which cannot pass a switch, and auto-detected when the session is
 non-interactive or stdin is redirected; under CI the early-failure key press is skipped too. The
 installer asks no yes/no questions on any path (issue #230). It asks one question: TightVNC's
 server password, at the start of an interactive run when WINGET_APP_SETUP_TIGHTVNC_PASSWORD is not
 set and TightVNC Server has no password yet (skipped when nobody starts typing within 5 minutes).
 This switch suppresses that question too: TightVNC is then reported as installed but not
 configured.

.PARAMETER CollectDiagnostics
 Installs nothing: makes a diagnostics bundle to attach to a GitHub issue after a failed run, and
 prints where it saved it. The .zip holds the latest run's transcripts (the RMM wrapper's log
 too), installer logs and last-run.json, this account's user-phase state and logs when the user
 phase ran in it, the end of Winget-AutoUpdate's updates.log, the App Installer and Windows App
 Runtime packages for every account and provisioned for new ones (and the framework this build
 pins), the execution policy, the App Installer and Store Group Policy, the pending-restart state,
 the Winget-AutoUpdate task, winget --version and --info, and the Windows build and architecture. Account and computer names, user
 profile folders, the SIDs of real accounts and email addresses are replaced with placeholders,
 because the repository's issues are public. It changes nothing on the PC (no log, no run lock, no
 PowerShell 7 install, no elevation) and works without winget; run it from PowerShell started as
 administrator to include everything. The irm | iex one-liner cannot pass a switch, so a failed run
 prints this command instead:
     & ([scriptblock]::Create((irm "https://raw.githubusercontent.com/J-MaFf/winget-app-setup/refs/heads/main/winget-app-install.ps1"))) -CollectDiagnostics
 Exit code 0 when the bundle was saved, 5 when it could not be.

.PARAMETER MaxRuntimeMinutes
 A time budget for the whole run, in minutes (1 to 1440), for an RMM job that is stopped after a
 fixed time: once it is used up, the run starts no further app install, retry or Winget-AutoUpdate
 setup, reports what it did not reach as not attempted (in the summary, the RESULT line and
 last-run.json), and exits 9 so that the next run finishes the job. An install or Winget-AutoUpdate
 setup already running is not stopped: it ends within its own time limits (30 minutes for one winget
 install), and the end-of-run winget check takes up to about 4 minutes, so set the budget about 45
 minutes below the RMM's limit. The clock starts when this script starts, before the PowerShell 7
 relaunch. Not given, the environment variable WINGET_APP_SETUP_MAX_RUNTIME_MINUTES decides, for the
 irm | iex one-liner, which cannot pass a parameter: unset, empty or 0 means no budget, and a value
 that is not a whole number from 0 to 1440 is ignored with a warning. A value given here wins over
 the variable, and 0 turns its budget off. A dry run (-WhatIf) shows the budget but is not cut short.

.PARAMETER RunDeadlineUtc
 Internal: the deadline of the time budget (yyyy-MM-ddTHH:mm:ssZ), passed on by the installer's own
 relaunches (to PowerShell 7, and elevated) and by rmm/Invoke-WingetAppSetup.ps1, so the budget
 counts from the first start of the run. It never extends the budget -MaxRuntimeMinutes sets.
#>

param (
    [Parameter(Mandatory = $false)]
    [switch]$WhatIf,
    [Parameter(Mandatory = $false)]
    [switch]$SkipSystemCheck,
    [Parameter(Mandatory = $false)]
    [switch]$NonInteractive,
    [Parameter(Mandatory = $false)]
    [switch]$CollectDiagnostics,
    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 1440)]
    [int]$MaxRuntimeMinutes = 0,
    [Parameter(Mandatory = $false)]
    [string]$RunDeadlineUtc
)

# ------------------------------------------------------------------------------------------------
# GENERATED FILE - DO NOT EDIT BY HAND.
# This script is assembled from the WingetAppSetup module by build/Build-WingetInstallScript.ps1,
# without the comments of the module and of the entry block below: read them in the source. Edit
# the function source under WingetAppSetup/Public and WingetAppSetup/Private, or the entry block in
# build/fragments/tail.ps1, then re-run the build to regenerate this file.
# See readme.md ("Project layout") for details.
# Build id: 1.0.0+507e8f9e (module version + SHA256 fragment of this whole script; issue #189).
# ------------------------------------------------------------------------------------------------

# Content-derived build identity, logged at startup so a transcript from a remote machine
# identifies exactly which installer build produced it (issue #189).
$script:InstallerBuildId = '1.0.0+507e8f9e'

# ------------------------------------------------Functions------------------------------------------------

# --- AppUninstall ---
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

function Test-WingetUninstallRestartRequiredResult {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[int]]$ExitCode,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object[]]$Output
    )

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

    if (-not (Test-AppApplicability -App $App -Purpose Uninstall)) {
        $conditionText = Get-AppNotApplicableReason -App $App
        $result.Status = 'Skipped'
        $result.SkipReason = 'NotApplicable'
        $result.Reason = "not applicable: $conditionText"
        return $result
    }

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

# --- CatalogSchema ---
function Get-AppDefinitionFieldName {
    return @('name', 'install', 'installerType', 'condition', 'conditionDescription', 'msixName', 'scope', 'arch', 'postInstall', 'userPhase', 'quietUninstall')
}

function Get-AppDefinitionArchitectureName {
    return @('X86', 'X64', 'Arm', 'Arm64')
}

function Get-AppDefinitionSchemaIssue {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$App,

        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    $errors = @()
    $warnings = @()

    if ($App.ContainsKey('scope')) {
        $scope = $App['scope']
        if (-not ($scope -is [string]) -or @('machine', 'user', 'any') -notcontains $scope) {
            $errors += "$Label has an invalid 'scope' value '$scope': use 'machine', 'user' or 'any'."
        }
    }

    if ($App.ContainsKey('arch')) {
        $knownArchitectures = Get-AppDefinitionArchitectureName
        $architectures = @($App['arch'] | Where-Object { $null -ne $_ })
        if ($architectures.Count -eq 0) {
            $errors += "$Label has an empty 'arch' list: name at least one of $($knownArchitectures -join ', ')."
        }
        foreach ($architecture in $architectures) {
            if (-not ($architecture -is [string]) -or $knownArchitectures -notcontains $architecture) {
                $errors += "$Label has an invalid 'arch' value '$architecture': use one or more of $($knownArchitectures -join ', ')."
            }
        }
    }

    if ($App.ContainsKey('postInstall')) {
        $hook = $App['postInstall']
        if ($hook -is [scriptblock]) {
        }
        elseif ($hook -is [string] -and -not [string]::IsNullOrWhiteSpace($hook)) {
            if ($hook -match '[\*\?\[\]]' -or -not (Get-Command -Name $hook -ErrorAction SilentlyContinue)) {
                $errors += "$Label has a 'postInstall' value '$hook' that names no command of this installer."
            }
        }
        else {
            $errors += "$Label has an invalid 'postInstall' value: use a scriptblock or the name of a function."
        }
    }

    if ($App.ContainsKey('userPhase') -and -not ($App['userPhase'] -is [bool])) {
        $errors += "$Label has an invalid 'userPhase' value '$($App['userPhase'])': use `$true or `$false."
    }

    if ($App.ContainsKey('quietUninstall')) {
        $errors += @(Get-AppQuietUninstallSchemaIssue -Value $App['quietUninstall'] -Label $Label)
    }

    $knownFields = Get-AppDefinitionFieldName
    foreach ($key in @($App.Keys)) {
        if ($knownFields -notcontains $key) {
            $warnings += "$Label has an unknown field '$key', which the installer ignores."
        }
    }

    return [pscustomobject]@{
        Errors   = $errors
        Warnings = $warnings
    }
}

function Get-AppQuietUninstallSchemaIssue {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    $usage = "use @{ productCode = '{<GUID>}'; arguments = @('<switch>', ...) }"
    if (-not ($Value -is [System.Collections.IDictionary])) {
        return @("$Label has an invalid 'quietUninstall' value: $usage.")
    }

    $errors = @()
    foreach ($key in @($Value.Keys)) {
        if (@('productCode', 'arguments') -notcontains [string]$key) {
            $errors += "$Label has an unknown key '$key' in its 'quietUninstall' value: $usage."
        }
    }

    $productCode = $Value['productCode']
    if (-not ($productCode -is [string]) -or $productCode -notmatch '^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}\z') {
        $errors += "$Label has an invalid 'quietUninstall' productCode '$productCode': use the braced GUID its uninstall entry is named after, such as '{00000000-0000-0000-0000-000000000000}'."
    }

    $arguments = @()
    if ($null -ne $Value['arguments']) {
        $arguments = @($Value['arguments'])
    }
    if ($arguments.Count -eq 0) {
        $errors += "$Label has no 'quietUninstall' arguments: name the switches that make its uninstaller run without asking."
    }
    foreach ($argument in $arguments) {
        if (-not ($argument -is [string]) -or [string]::IsNullOrWhiteSpace($argument) -or $argument -match '["\r\n]') {
            $errors += "$Label has an invalid 'quietUninstall' argument '$argument': use a non-empty string without a double quote or a line break."
        }
    }
    return $errors
}

function Get-AppInstallScope {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$App
    )

    $scope = [string]$App['scope']
    if ([string]::IsNullOrWhiteSpace($scope)) {
        return 'any'
    }
    return $scope.Trim().ToLowerInvariant()
}

function Get-AppPerUserDeferReason {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$App
    )

    if ((Get-AppInstallScope -App $App) -eq 'user') {
        return 'UserScope'
    }
    if ($App['userPhase'] -eq $true) {
        return 'UserPhase'
    }
    return $null
}

function Get-AppNotApplicableReason {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$App
    )

    if (-not [string]::IsNullOrWhiteSpace([string]$App['conditionDescription'])) {
        return [string]$App['conditionDescription']
    }
    if ($App.ContainsKey('arch') -and $null -ne $App['arch']) {
        $architecture = $null
        try {
            $architecture = Get-OSArchitecture
        }
        catch {
        }
        $allowed = @($App['arch'])
        if ($architecture -and $allowed -notcontains $architecture) {
            return ('for {0} Windows only; this PC is {1}' -f ($allowed -join ', '), $architecture)
        }
    }
    return 'condition not met'
}

function ConvertTo-AppPostInstallResult {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Output
    )

    $items = @($Output | Where-Object { $null -ne $_ })
    if ($items.Count -eq 0) {
        return @{ Status = 'Failed'; Reason = 'the post-install hook returned no result (expected Configured, NotConfigured or Failed)' }
    }

    $last = $items[$items.Count - 1]
    $status = $null
    $reason = $null
    if ($last -is [string]) {
        $status = $last
    }
    elseif ($last -is [System.Collections.IDictionary]) {
        $status = [string]$last['Status']
        $reason = [string]$last['Reason']
    }
    elseif ($null -ne $last.PSObject.Properties['Status']) {
        $status = [string]$last.Status
        if ($null -ne $last.PSObject.Properties['Reason']) {
            $reason = [string]$last.Reason
        }
    }

    $knownStatus = @('Configured', 'NotConfigured', 'Failed') | Where-Object { $_ -eq "$status".Trim() } | Select-Object -First 1
    if (-not $knownStatus) {
        $shown = "$status".Trim()
        if (-not $shown) {
            $shown = [string]$last
        }
        if ($shown.Length -gt 80) {
            $shown = $shown.Substring(0, 77) + '...'
        }
        return @{ Status = 'Failed'; Reason = ("the post-install hook returned '{0}', not Configured, NotConfigured or Failed" -f $shown) }
    }
    if ($knownStatus -eq 'Configured') {
        return @{ Status = 'Configured'; Reason = $null }
    }
    if ([string]::IsNullOrWhiteSpace($reason)) {
        $reason = 'no reason given'
    }
    return @{ Status = $knownStatus; Reason = $reason.Trim() }
}

function Invoke-AppPostInstall {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$App
    )

    Write-Info "Configuring: $($App.name)"
    $ErrorActionPreference = 'Stop'
    try {
        $output = @(& $App.postInstall $App)
    }
    catch {
        $message = "$($_.Exception.Message)".Trim()
        if (-not $message) {
            $message = 'the post-install hook failed without a message'
        }
        return @{ Status = 'Failed'; Reason = $message }
    }
    return (ConvertTo-AppPostInstallResult -Output $output)
}

# --- Diagnostics ---
function Get-DiagnosticsCommandLine {
    return '& ([scriptblock]::Create((irm "https://raw.githubusercontent.com/J-MaFf/winget-app-setup/refs/heads/main/winget-app-install.ps1"))) -CollectDiagnostics'
}

function Write-InstallerReportHint {
    Write-Info 'To report this, open https://github.com/J-MaFf/winget-app-setup/issues/new?template=install-failure.yml and give the exit code, the installer build and a diagnostics bundle (or the log file).'
    Write-Info 'A diagnostics bundle is a .zip of the installer''s logs and the state of winget, App Installer and auto-updates on this PC, with account and computer names removed. Making one changes nothing. Run this in PowerShell (as administrator, for everything it can collect), then attach the file it names:'
    Write-Info ('    ' + (Get-DiagnosticsCommandLine))
    Write-WarningMessage 'That repository is public, and the log names this computer and the accounts that ran the installer: remove or redact the log''s header before attaching it. The bundle has those names removed already; look through it anyway.'
}

function Read-DiagnosticsTextFile {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $false)]
        [long]$MaxBytes = 4MB
    )

    $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
    try {
        $length = $stream.Length
        $head = New-Object byte[] 4
        $headCount = $stream.Read($head, 0, 4)
        $encoding = New-Object System.Text.UTF8Encoding($false)
        $preamble = 0
        $twoByte = $false
        if ($headCount -ge 2 -and $head[0] -eq 0xFF -and $head[1] -eq 0xFE) {
            $encoding = [System.Text.Encoding]::Unicode
            $preamble = 2
            $twoByte = $true
        }
        elseif ($headCount -ge 2 -and $head[0] -eq 0xFE -and $head[1] -eq 0xFF) {
            $encoding = [System.Text.Encoding]::BigEndianUnicode
            $preamble = 2
            $twoByte = $true
        }
        elseif ($headCount -ge 3 -and $head[0] -eq 0xEF -and $head[1] -eq 0xBB -and $head[2] -eq 0xBF) {
            $preamble = 3
        }
        elseif ($headCount -eq 4 -and $head[0] -ne 0 -and $head[1] -eq 0 -and $head[2] -ne 0 -and $head[3] -eq 0) {
            $encoding = [System.Text.Encoding]::Unicode
            $twoByte = $true
        }

        $start = [long]$preamble
        $note = $null
        if ($length - $preamble -gt $MaxBytes) {
            $start = $length - $MaxBytes
            if ($twoByte -and (($start - $preamble) % 2) -ne 0) {
                $start++
            }
            $note = '[The first {0} bytes of this file were left out; its last {1} bytes follow.]' -f ($start - $preamble), ($length - $start)
        }
        [void]$stream.Seek($start, [System.IO.SeekOrigin]::Begin)
        $count = [int]($length - $start)
        $buffer = New-Object byte[] $count
        $offset = 0
        while ($offset -lt $count) {
            $read = $stream.Read($buffer, $offset, $count - $offset)
            if ($read -le 0) {
                break
            }
            $offset += $read
        }
        $text = $encoding.GetString($buffer, 0, $offset)
        if ($note) {
            $text = $note + [Environment]::NewLine + $text
        }
        return $text
    }
    finally {
        $stream.Dispose()
    }
}

function Get-DiagnosticsPathLeaf {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ''
    }
    $trimmed = $Path.Trim().TrimEnd('\', '/')
    $index = $trimmed.LastIndexOfAny([char[]]@('\', '/'))
    return $trimmed.Substring($index + 1)
}

function ConvertFrom-DiagnosticsLogStamp {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Stamp
    )

    $parsed = [DateTime]::MinValue
    if ([DateTime]::TryParseExact($Stamp, 'yyyyMMdd-HHmmss', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
        return $parsed
    }
    return $null
}

function Select-DiagnosticsLogFile {
    param (
        [Parameter(Mandatory = $true)]
        [string]$LogDirectory,

        [Parameter(Mandatory = $false)]
        [int]$WindowMinutes = 60,

        [Parameter(Mandatory = $false)]
        [int]$MaximumTranscripts = 6,

        [Parameter(Mandatory = $false)]
        [int]$MaximumInstallerLogs = 40
    )

    $files = @(Get-ChildItem -LiteralPath $LogDirectory -File -Force -ErrorAction Stop)
    $transcripts = @()
    $installerLogs = @()
    $runRecord = $null
    foreach ($file in $files) {
        if ($file.Name -match '^install-(?<stamp>\d{8}-\d{6})(?:-bootstrap|-rmm|-userphase)?\.log$') {
            $time = ConvertFrom-DiagnosticsLogStamp -Stamp $Matches['stamp']
            if ($null -ne $time) {
                $transcripts += [pscustomobject]@{ File = $file; Stamp = $Matches['stamp']; Time = $time }
            }
        }
        elseif ($file.Name -match '^(?:winget-(?:install|upgrade|uninstall|repair)-.+|pwsh-msi|wau-msi-(?:install|uninstall))-(?<stamp>\d{8}-\d{6})(?:-\d+)?\.log$') {
            $installerLogs += [pscustomobject]@{ File = $file; Stamp = $Matches['stamp'] }
        }
        elseif ($file.Name -eq 'last-run.json') {
            $runRecord = $file
        }
    }

    $newestFirst = @($transcripts | Sort-Object -Property @{ Expression = 'Stamp'; Descending = $true }, @{ Expression = { $_.File.Name }; Descending = $true })
    $selected = @()
    if ($newestFirst.Count -gt 0) {
        $windowStart = $newestFirst[0].Time.AddMinutes(-$WindowMinutes)
        $selected = @($newestFirst | Where-Object { $_.Time -ge $windowStart } | Select-Object -First $MaximumTranscripts)
    }

    if ($null -ne $runRecord) {
        $namedTranscript = $null
        try {
            $record = (Read-DiagnosticsTextFile -Path $runRecord.FullName -MaxBytes 1MB) | ConvertFrom-Json
            if ($record -and $record.transcriptPath) {
                $namedTranscript = Get-DiagnosticsPathLeaf -Path ([string]$record.transcriptPath)
            }
        }
        catch {
            $namedTranscript = $null
        }
        if ($namedTranscript) {
            $alreadySelected = @($selected | Where-Object { $_.File.Name -eq $namedTranscript }).Count -gt 0
            if (-not $alreadySelected) {
                $selected += @($transcripts | Where-Object { $_.File.Name -eq $namedTranscript })
            }
        }
    }

    $selectedLogs = @()
    if ($selected.Count -gt 0) {
        $oldestStamp = @($selected | Sort-Object -Property Stamp | Select-Object -First 1)[0].Stamp
        $selectedLogs = @($installerLogs | Where-Object { [string]::CompareOrdinal($_.Stamp, $oldestStamp) -ge 0 } |
                Sort-Object -Property @{ Expression = 'Stamp'; Descending = $true }, @{ Expression = { $_.File.Name }; Descending = $true } |
                Select-Object -First $MaximumInstallerLogs)
    }

    return [pscustomobject]@{
        Transcripts   = @($selected | Sort-Object -Property Stamp, @{ Expression = { $_.File.Name } } | ForEach-Object { $_.File })
        InstallerLogs = @($selectedLogs | Sort-Object -Property Stamp, @{ Expression = { $_.File.Name } } | ForEach-Object { $_.File })
        RunRecord     = $runRecord
        Files         = $files
    }
}

function Get-DiagnosticsRegistryValue {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    $item = Get-ItemProperty -LiteralPath $Path -ErrorAction Stop
    $values = [ordered]@{}
    foreach ($property in @($item.PSObject.Properties)) {
        if (@('PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider') -contains $property.Name) {
            continue
        }
        $values[$property.Name] = $property.Value
    }
    return $values
}

function Get-DiagnosticsProfileList {
    try {
        $keys = @(Get-ChildItem -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -ErrorAction Stop)
    }
    catch {
        return
    }
    foreach ($key in $keys) {
        $profilePath = $null
        try {
            $profilePath = [string](Get-ItemProperty -LiteralPath $key.PSPath -Name 'ProfileImagePath' -ErrorAction Stop).ProfileImagePath
        }
        catch {
            $profilePath = $null
        }
        [pscustomobject]@{ Sid = [string]$key.PSChildName; ProfilePath = $profilePath }
    }
}

function Get-DiagnosticsSidAccountName {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Sid
    )

    try {
        $identifier = New-Object System.Security.Principal.SecurityIdentifier($Sid)
        return $identifier.Translate([System.Security.Principal.NTAccount]).Value
    }
    catch {
        return $null
    }
}

function Get-DiagnosticsIdentityHint {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$AccountContext
    )

    $computers = @($env:COMPUTERNAME)
    $dnsDomains = @($env:USERDNSDOMAIN)
    $domains = @($env:USERDOMAIN)
    $users = @($env:USERNAME)
    $organizations = @()
    try {
        $computers += [System.Net.Dns]::GetHostName()
    }
    catch {
    }
    try {
        $dnsDomains += [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().DomainName
    }
    catch {
    }

    $accounts = @()
    if ($AccountContext) {
        $accounts += @([string]$AccountContext.ProcessUser, [string]$AccountContext.SessionUser)
    }
    foreach ($userProfile in @(Get-DiagnosticsProfileList)) {
        if ("$($userProfile.Sid)" -notmatch '^S-1-(?:5-21|12-1)-') {
            continue
        }
        if ($userProfile.ProfilePath) {
            $users += Get-DiagnosticsPathLeaf -Path ([string]$userProfile.ProfilePath)
        }
        $accounts += Get-DiagnosticsSidAccountName -Sid $userProfile.Sid
    }
    foreach ($account in $accounts) {
        if ([string]::IsNullOrWhiteSpace($account)) {
            continue
        }
        $parts = ([string]$account).Split('\')
        if ($parts.Count -ge 2) {
            $domains += $parts[0]
            $users += $parts[$parts.Count - 1]
        }
        else {
            $users += $parts[0]
        }
    }

    try {
        $windows = Get-DiagnosticsRegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        if ($windows) {
            $users += [string]$windows['RegisteredOwner']
            $organizations += [string]$windows['RegisteredOrganization']
        }
    }
    catch {
    }

    return [pscustomobject]@{
        ComputerNames = @($computers)
        DnsDomains    = @($dnsDomains)
        Domains       = @($domains)
        Users         = @($users)
        Organizations = @($organizations)
    }
}

function New-DiagnosticsRedactionMap {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$IdentityHint,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Text = @()
    )

    $computers = New-Object System.Collections.Generic.List[string]
    $dnsDomains = New-Object System.Collections.Generic.List[string]
    $domains = New-Object System.Collections.Generic.List[string]
    $users = New-Object System.Collections.Generic.List[string]
    $organizations = New-Object System.Collections.Generic.List[string]
    if ($IdentityHint) {
        foreach ($value in @($IdentityHint.ComputerNames)) { $computers.Add([string]$value) }
        foreach ($value in @($IdentityHint.DnsDomains)) { $dnsDomains.Add([string]$value) }
        foreach ($value in @($IdentityHint.Domains)) { $domains.Add([string]$value) }
        foreach ($value in @($IdentityHint.Users)) { $users.Add([string]$value) }
        foreach ($value in @($IdentityHint.Organizations)) { $organizations.Add([string]$value) }
    }

    $accounts = New-Object System.Collections.Generic.List[string]
    $sidAuthorities = New-Object System.Collections.Generic.List[string]
    $multiline = [System.Text.RegularExpressions.RegexOptions]::Multiline -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
    foreach ($content in @($Text)) {
        if ([string]::IsNullOrEmpty($content)) {
            continue
        }
        foreach ($match in [regex]::Matches($content, '^[ \t]*(?:Username|RunAs User):[ \t]*(?<account>\S[^\r\n]*?)[ \t]*\r?$', $multiline)) {
            $accounts.Add($match.Groups['account'].Value)
        }
        foreach ($match in [regex]::Matches($content, '^[ \t]*Machine:[ \t]*(?<computer>[^\s(]+)', $multiline)) {
            $computers.Add($match.Groups['computer'].Value)
        }
        $msiPatterns = @(
            'Property\([A-Z]\):[ \t]*(?<name>LogonUser|USERNAME|COMPANYNAME|ComputerName)[ \t]*=[ \t]*(?<value>[^\r\n]*?)[ \t]*\r?$',
            'PROPERTY CHANGE: (?:Adding|Modifying) (?<name>LogonUser|USERNAME|COMPANYNAME|ComputerName) property\. Its (?:current )?value is ''(?<value>[^''\r\n]*)''',
            'PROPERTY CHANGE: Modifying (?<name>LogonUser|USERNAME|COMPANYNAME|ComputerName) property\. Its current value is ''[^''\r\n]*''\. Its new value: ''(?<value>[^''\r\n]*)'''
        )
        foreach ($pattern in $msiPatterns) {
            foreach ($match in [regex]::Matches($content, $pattern, $multiline)) {
                $value = $match.Groups['value'].Value
                switch ($match.Groups['name'].Value.ToUpperInvariant()) {
                    'COMPANYNAME' { $organizations.Add($value) }
                    'COMPUTERNAME' { $computers.Add($value) }
                    default { $accounts.Add($value) }
                }
            }
        }
        foreach ($match in [regex]::Matches($content, '\bS-1-\d+(?:-\d+)+ \[(?<account>[^\]\r\n]+)\]', $multiline)) {
            $accounts.Add($match.Groups['account'].Value)
        }
        foreach ($match in [regex]::Matches($content, '\b(?<authority>S-1-5-21-\d+-\d+-\d+|S-1-12-1-\d+-\d+-\d+-\d+)(?!\d)', $multiline)) {
            $sidAuthorities.Add($match.Groups['authority'].Value)
        }
    }
    foreach ($account in $accounts) {
        if ([string]::IsNullOrWhiteSpace($account)) {
            continue
        }
        $parts = $account.Trim().Split('\')
        if ($parts.Count -ge 2) {
            $domains.Add($parts[0])
            $users.Add($parts[$parts.Count - 1])
        }
        else {
            $users.Add($parts[0])
        }
    }
    foreach ($user in @($users)) {
        if ($user -and $user.Trim().EndsWith('$')) {
            $computers.Add($user.Trim().TrimEnd('$'))
        }
    }

    $kept = @('SYSTEM', 'LOCAL SERVICE', 'NETWORK SERVICE', 'LocalSystem', 'LocalService', 'NetworkService', 'NT AUTHORITY',
        'NT SERVICE', 'NT VIRTUAL MACHINE', 'BUILTIN', 'WORKGROUP', 'AzureAD', 'MicrosoftAccount', 'Window Manager',
        'Font Driver Host', 'IIS APPPOOL', 'Administrator', 'Administrators', 'Guest', 'DefaultAccount', 'WDAGUtilityAccount',
        'defaultuser0', 'Public', 'Default', 'Default User', 'All Users', 'Users', 'Everyone', 'Authenticated Users',
        'INTERACTIVE', 'Unknown user', 'Windows User', 'User', 'Admin', 'Owner', 'localhost')
    $seen = @{}
    $names = New-Object System.Collections.Generic.List[object]
    $categories = @(
        [pscustomobject]@{ List = $computers; Prefix = 'computer' },
        [pscustomobject]@{ List = $dnsDomains; Prefix = 'dns-domain' },
        [pscustomobject]@{ List = $domains; Prefix = 'domain' },
        [pscustomobject]@{ List = $users; Prefix = 'user' },
        [pscustomobject]@{ List = $organizations; Prefix = 'organization' }
    )
    foreach ($category in $categories) {
        $number = 0
        foreach ($rawValue in $category.List) {
            if ($null -eq $rawValue) {
                continue
            }
            $value = $rawValue.Trim().Trim('"', "'").Trim()
            if ($category.Prefix -ne 'organization' -and $category.Prefix -ne 'dns-domain') {
                $value = $value.TrimEnd('$')
            }
            if ($value.Length -lt 2 -or $value -notmatch '\p{L}' -or $value.Contains('<') -or $value.Contains('>')) {
                continue
            }
            $key = $value.ToUpperInvariant()
            if ($seen.ContainsKey($key)) {
                continue
            }
            $isKept = $false
            foreach ($keptName in $kept) {
                if ([string]::Equals($keptName, $value, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $isKept = $true
                    break
                }
            }
            if ($isKept) {
                continue
            }
            $seen[$key] = $true
            $number++
            $names.Add([pscustomobject]@{ Value = $value; Placeholder = ('<{0}{1}>' -f $category.Prefix, $number) })
        }
    }

    $sids = New-Object System.Collections.Generic.List[object]
    $seenSids = @{}
    foreach ($authority in $sidAuthorities) {
        $key = $authority.ToUpperInvariant()
        if ($seenSids.ContainsKey($key)) {
            continue
        }
        $seenSids[$key] = $true
        $prefix = 'S-1-5-21-'
        if ($key.StartsWith('S-1-12-1-')) {
            $prefix = 'S-1-12-1-'
        }
        $sids.Add([pscustomobject]@{ Value = $authority; Placeholder = ('{0}<sid{1}>' -f $prefix, ($sids.Count + 1)) })
    }

    return [pscustomobject]@{
        Names = @($names | Sort-Object -Property @{ Expression = { $_.Value.Length }; Descending = $true })
        Sids  = @($sids | Sort-Object -Property @{ Expression = { $_.Value.Length }; Descending = $true })
    }
}

function ConvertTo-RedactedDiagnosticText {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [object]$Map
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return ''
    }
    $ignoreCase = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
    $multiline = [System.Text.RegularExpressions.RegexOptions]::Multiline -bor $ignoreCase

    $result = [regex]::Replace($Text, '^(?<prefix>.*?Property\([A-Z]\):[ \t]*(?:LogonUser|USERNAME|COMPANYNAME|ComputerName|UserSID)[ \t]*=[ \t]*)\S[^\r\n]*?(?<end>\r?)$', '${prefix}<redacted>${end}', $multiline)

    $result = [regex]::Replace($result, '\b[A-Z0-9._%+-]+@[A-Z0-9-]+(?:\.[A-Z0-9-]+)*\.[A-Z]{2,}\b', '<email>', $ignoreCase)

    $nameLookup = @{}
    $alternatives = @()
    foreach ($name in @($Map.Names)) {
        $key = ([string]$name.Value).ToUpperInvariant()
        if (-not $nameLookup.ContainsKey($key)) {
            $nameLookup[$key] = [string]$name.Placeholder
            $alternatives += [regex]::Escape([string]$name.Value)
        }
    }
    if ($alternatives.Count -gt 0) {
        $nameRegex = New-Object System.Text.RegularExpressions.Regex(('(?<![\p{L}\p{N}])(?:' + ($alternatives -join '|') + ')(?![\p{L}\p{N}])'), $ignoreCase)
        $nameEvaluator = [System.Text.RegularExpressions.MatchEvaluator]({
                param ($match)
                $nameLookup[$match.Value.ToUpperInvariant()]
            }.GetNewClosure())
        $result = $nameRegex.Replace($result, $nameEvaluator)
    }

    $sidLookup = @{}
    foreach ($sid in @($Map.Sids)) {
        $sidLookup[([string]$sid.Value).ToUpperInvariant()] = [string]$sid.Placeholder
    }
    $sidRegex = New-Object System.Text.RegularExpressions.Regex('\b(?<authority>S-1-5-21-\d+-\d+-\d+|S-1-12-1-\d+-\d+-\d+-\d+)(?!\d)', $ignoreCase)
    $sidEvaluator = [System.Text.RegularExpressions.MatchEvaluator]({
            param ($match)
            $authority = $match.Groups['authority'].Value.ToUpperInvariant()
            if ($sidLookup.ContainsKey($authority)) {
                return $sidLookup[$authority]
            }
            if ($authority.StartsWith('S-1-12-1-')) {
                return 'S-1-12-1-<sid>'
            }
            return 'S-1-5-21-<sid>'
        }.GetNewClosure())
    $result = $sidRegex.Replace($result, $sidEvaluator)

    $profilePattern = '(?<prefix>\b[A-Z]:[\\/]+(?:Users|Documents and Settings)[\\/]+)(?!(?:Public|Default|Default User|All Users)(?:[\\/"''\s,;)\]]|$))[^\\/:*?"<>|\r\n]+'
    $result = [regex]::Replace($result, $profilePattern, '${prefix}<user>', $multiline)

    return $result
}

function Get-DiagnosticsSpecialFolder {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    try {
        $path = [Environment]::GetFolderPath($Name)
    }
    catch {
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($path)) {
        return $null
    }
    return $path
}

function Get-DiagnosticsBundleDirectory {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$AccountContext
    )

    $names = @()
    if (-not ($AccountContext -and ($AccountContext.IsSystem -or $AccountContext.IsCrossUserElevation))) {
        $names += 'Desktop'
    }
    $names += 'CommonDocuments'
    $folders = @()
    foreach ($name in $names) {
        $path = Get-DiagnosticsSpecialFolder -Name $name
        if ($path -and (Test-Path -LiteralPath $path -PathType Container)) {
            $folders += $path
        }
    }
    $temp = [System.IO.Path]::GetTempPath()
    if ($temp -and (Test-Path -LiteralPath $temp -PathType Container)) {
        $folders += $temp
    }
    return @($folders | Select-Object -Unique)
}

function Get-DiagnosticsElevationStyle {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$AccountContext,

        [Parameter(Mandatory = $true)]
        [bool]$IsAdmin
    )

    if ($AccountContext -and $AccountContext.IsSystem) {
        return 'SYSTEM'
    }
    if ($AccountContext -and $AccountContext.IsCrossUserElevation) {
        return 'cross-user (elevated as another account than the signed-in user)'
    }
    if ($IsAdmin) {
        return 'same-user, elevated'
    }
    return 'same-user, not elevated'
}

function Format-DiagnosticsRegistryKey {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    try {
        $values = Get-DiagnosticsRegistryValue -Path $Path
    }
    catch {
        return @("  not read: $($_.Exception.Message)")
    }
    if ($null -eq $values) {
        return @('  not configured (no such key)')
    }
    if ($values.Count -eq 0) {
        return @('  no values')
    }
    $lines = @()
    foreach ($name in $values.Keys) {
        $lines += ('  {0} = {1}' -f $name, (@($values[$name]) -join '; '))
    }
    return $lines
}

function Test-DiagnosticsWow64Process {
    return ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess)
}

function Get-DiagnosticsWow64Note {
    return 'This PowerShell is 32-bit on 64-bit Windows, so registry values under HKLM\SOFTWARE were read from its 32-bit view (WOW6432Node): in system.txt, PowerShell 7, Winget-AutoUpdate and the pending restart can read as missing when they are there. For a correct report, run the command again from 64-bit PowerShell (from a 32-bit RMM agent, %SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe).'
}

function Get-DiagnosticsPowerShellInstall {
    $root = 'HKLM:\SOFTWARE\Microsoft\PowerShellCore\InstalledVersions'
    if (-not (Test-Path -LiteralPath $root)) {
        return
    }
    foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction Stop)) {
        $entry = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
        [pscustomobject]@{
            SemanticVersion = [string]$entry.SemanticVersion
            InstallLocation = [string]$entry.InstallLocation
        }
    }
}

function Get-DiagnosticsSystemReport {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$AccountContext,

        [Parameter(Mandatory = $true)]
        [bool]$IsAdmin
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('== Collection ==')
    $lines.Add(('Collected: {0}' -f (Format-RunRecordTime -Time ([DateTime]::UtcNow))))
    $buildId = 'unknown'
    if ($script:InstallerBuildId) {
        $buildId = [string]$script:InstallerBuildId
    }
    $lines.Add("Collected by installer build: $buildId")
    $processBits = '32-bit'
    if ([Environment]::Is64BitProcess) {
        $processBits = '64-bit'
    }
    $osBits = '32-bit'
    if ([Environment]::Is64BitOperatingSystem) {
        $osBits = '64-bit'
    }
    $lines.Add(('PowerShell: {0} ({1}), {2} process on {3} Windows' -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition, $processBits, $osBits))
    if (Test-DiagnosticsWow64Process) {
        $lines.Add(('Note: ' + (Get-DiagnosticsWow64Note)))
    }

    $lines.Add('')
    $lines.Add('== Windows ==')
    try {
        $windows = Get-DiagnosticsRegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        if ($windows) {
            $build = [string]$windows['CurrentBuild']
            if ($null -ne $windows['UBR']) {
                $build = '{0}.{1}' -f $build, $windows['UBR']
            }
            $lines.Add(('Product: {0} ({1}, {2})' -f $windows['ProductName'], $windows['EditionID'], $windows['InstallationType']))
            $lines.Add(('Version: {0}' -f $windows['DisplayVersion']))
            $lines.Add("Build: $build")
        }
        else {
            $lines.Add('Version key not found')
        }
    }
    catch {
        $lines.Add("Version not read: $($_.Exception.Message)")
    }
    $lines.Add("OS version: $([Environment]::OSVersion.VersionString)")
    $architecture = $null
    try {
        $architecture = Get-OSArchitecture
    }
    catch {
        $architecture = $env:PROCESSOR_ARCHITEW6432
        if (-not $architecture) {
            $architecture = $env:PROCESSOR_ARCHITECTURE
        }
    }
    $lines.Add("OS architecture: $architecture")
    $lines.Add(('Language: {0} (display {1})' -f [System.Globalization.CultureInfo]::CurrentCulture.Name, [System.Globalization.CultureInfo]::CurrentUICulture.Name))

    $lines.Add('')
    $lines.Add('== Accounts ==')
    $processSid = $null
    try {
        $processSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    }
    catch {
        $processSid = $null
    }
    $processUser = 'unknown'
    $sessionUser = 'nobody signed in, or unknown'
    if ($AccountContext -and $AccountContext.ProcessUser) {
        $processUser = [string]$AccountContext.ProcessUser
    }
    if ($AccountContext -and $AccountContext.SessionUser) {
        $sessionUser = [string]$AccountContext.SessionUser
        $sessionSid = Get-AccountSid -AccountName $sessionUser
        if ($sessionSid) {
            $sessionUser = '{0} ({1})' -f $sessionUser, $sessionSid
        }
    }
    if ($processSid) {
        $processUser = '{0} ({1})' -f $processUser, $processSid
    }
    $elevated = 'no'
    if ($IsAdmin) {
        $elevated = 'yes'
    }
    $lines.Add("This collection ran as: $processUser, elevated: $elevated")
    $lines.Add("Signed-in user (console session): $sessionUser")
    $lines.Add("Elevation style: $(Get-DiagnosticsElevationStyle -AccountContext $AccountContext -IsAdmin $IsAdmin)")
    $lines.Add('(The transcripts'' headers show the accounts of the runs themselves: Username is the signed-in user, RunAs User the account that ran the installer.)')

    $lines.Add('')
    $lines.Add('== PowerShell ==')
    try {
        $installed = @(Get-DiagnosticsPowerShellInstall)
        foreach ($install in $installed) {
            $lines.Add(('PowerShell 7 installed: {0} at {1}' -f $install.SemanticVersion, $install.InstallLocation))
        }
        if ($installed.Count -eq 0) {
            $lines.Add('PowerShell 7 installed: none registered')
        }
    }
    catch {
        $lines.Add("PowerShell 7 installed: not read: $($_.Exception.Message)")
    }
    $lines.Add(('Execution policy, this PowerShell ({0}):' -f $PSVersionTable.PSEdition))
    try {
        foreach ($policy in @(Get-ExecutionPolicy -List)) {
            $lines.Add(('  {0} = {1}' -f $policy.Scope, $policy.ExecutionPolicy))
        }
    }
    catch {
        $lines.Add("  not read: $($_.Exception.Message)")
    }
    $lines.Add('Execution policy, Group Policy keys:')
    foreach ($key in @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell', 'HKLM:\SOFTWARE\Policies\Microsoft\PowerShellCore')) {
        $lines.Add("  $key")
        foreach ($line in @(Format-DiagnosticsRegistryKey -Path $key)) {
            $lines.Add('  ' + $line)
        }
    }

    $lines.Add('')
    $lines.Add('== App Installer Group Policy (HKLM\SOFTWARE\Policies\Microsoft\Windows\AppInstaller) ==')
    foreach ($line in @(Format-DiagnosticsRegistryKey -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppInstaller')) {
        $lines.Add($line)
    }
    $lines.Add('')
    $lines.Add('== Microsoft Store Group Policy (HKLM\SOFTWARE\Policies\Microsoft\WindowsStore) ==')
    foreach ($line in @(Format-DiagnosticsRegistryKey -Path 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore')) {
        $lines.Add($line)
    }

    $lines.Add('')
    $lines.Add('== Pending restart ==')
    try {
        $restart = Get-PendingRestartState
        $lines.Add(('Component Based Servicing RebootPending: {0}' -f [bool]$restart.ComponentServicing))
        $lines.Add(('Windows Update RebootRequired: {0}' -f [bool]$restart.WindowsUpdate))
        $renames = @($restart.FileRenames)
        $lines.Add(('File replacements queued for the next restart: {0}' -f $renames.Count))
        foreach ($rename in ($renames | Select-Object -First 50)) {
            $lines.Add("  $rename")
        }
    }
    catch {
        $lines.Add("Not read: $($_.Exception.Message)")
    }

    $lines.Add('')
    $lines.Add('== Windows App Runtime ==')
    try {
        $runtimePin = Get-WindowsAppRuntimePin
        $lines.Add(('Pinned by this installer build: Windows App Runtime {0}, {1} {2} (installed for all users when a run finds the framework missing)' -f $runtimePin.Release, $runtimePin.FrameworkName, $runtimePin.FrameworkVersion))
        $lines.Add(('Built-in requirement (used when the latest winget release''s cannot be read): {0}' -f (Format-WindowsAppRuntimeRequirement -Frameworks @((Get-DefaultWindowsAppRuntimeRequirement).Frameworks))))
    }
    catch {
        $lines.Add("Not read: $($_.Exception.Message)")
    }
    $lines.Add('Packages registered and provisioned on this PC: appx.txt. The run''s ''Windows App Runtime:'' and ''Auto-updates:'' lines: its transcript in logs\.')

    $lines.Add('')
    $lines.Add('== Winget-AutoUpdate ==')
    try {
        $wau = Get-InstalledWauInfo
        if ($wau.Version -or $wau.ProductCode) {
            $lines.Add(('Installed: version {0}, MSI product code {1}' -f $wau.Version, $wau.ProductCode))
        }
        else {
            $lines.Add('Installed: no')
        }
    }
    catch {
        $lines.Add("Installed version not read: $($_.Exception.Message)")
    }
    try {
        $health = Get-WauTaskHealth
        if ($health.Exists) {
            $lastRun = 'never'
            if ($health.LastRunTime) {
                $lastRun = '{0:yyyy-MM-dd HH:mm}' -f $health.LastRunTime
            }
            $lastResult = 'unknown'
            if ($null -ne $health.LastTaskResult) {
                $lastResult = '0x{0:X8}' -f $health.LastTaskResult
            }
            $nextRun = 'none scheduled'
            if ($health.NextRunTime) {
                $nextRun = '{0:yyyy-MM-dd HH:mm}' -f $health.NextRunTime
            }
            $triggers = 'none'
            if (@($health.Triggers).Count -gt 0) {
                $triggers = @($health.Triggers) -join '; '
            }
            $lines.Add(('Task \WAU\Winget-AutoUpdate: state {0}; triggers: {1}; last run {2}, result {3}; next run {4}' -f $health.State, $triggers, $lastRun, $lastResult, $nextRun))
        }
        if ($health.Problem) {
            $lines.Add("Task problem: $($health.Problem)")
        }
        elseif ($health.Healthy) {
            $lines.Add('Task: will run')
        }
    }
    catch {
        $lines.Add("Task not read: $($_.Exception.Message)")
    }
    return $lines.ToArray()
}

function Format-DiagnosticsProcessResult {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Label,

        [Parameter(Mandatory = $true)]
        [object]$Result
    )

    $lines = @()
    if ($Result.LaunchFailed) {
        $code = ''
        if ($null -ne $Result.LaunchErrorCode) {
            $code = ' (error {0})' -f $Result.LaunchErrorCode
        }
        $lines += ('{0}: could not be started{1}: {2}' -f $Label, $code, $Result.LaunchError)
    }
    elseif ($Result.TimedOut) {
        $lines += ('{0}: stopped at its time limit, after {1} seconds' -f $Label, $Result.DurationSeconds)
    }
    else {
        $exitText = 'unknown'
        if ($null -ne $Result.ExitCode) {
            $exitText = '{0} ({1})' -f (Format-WingetExitCode -ExitCode ([int]$Result.ExitCode)), $Result.ExitCode
        }
        $lines += ('{0}: exit {1}, {2} seconds' -f $Label, $exitText, $Result.DurationSeconds)
    }
    foreach ($line in @($Result.Output)) {
        $lines += ('  ' + $line)
    }
    return $lines
}

function Get-DiagnosticsWingetReport {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$AccountContext
    )

    $lines = @()
    $wingetPath = 'winget'
    if ($AccountContext -and $AccountContext.IsSystem) {
        $candidate = $null
        try {
            $candidate = @(Get-MachineWingetCandidate) | Select-Object -First 1
        }
        catch {
            $candidate = $null
        }
        if (-not $candidate) {
            return @('No machine-wide winget.exe was found (as SYSTEM, winget runs only by its full path from the App Installer package installed for this PC).')
        }
        $wingetPath = [string]$candidate.Path
        $lines += ('winget.exe for this PC (as SYSTEM): {0} (App Installer {1})' -f $candidate.Path, $candidate.Version)
    }
    $timeout = Get-ProcessTimeoutSeconds -Operation WingetVersion
    foreach ($argument in @('--version', '--info')) {
        $label = 'winget ' + $argument
        try {
            $result = Invoke-WingetProcess -ArgumentList @($argument) -TimeoutSeconds $timeout -WingetPath $wingetPath -Echo None -LogDirectory ''
            $lines += @(Format-DiagnosticsProcessResult -Label $label -Result $result)
        }
        catch {
            $lines += ('{0}: not run: {1}' -f $label, $_.Exception.Message)
        }
        $lines += ''
    }
    return $lines
}

function Get-DiagnosticsWindowsPowerShellPath {
    if (Test-DiagnosticsWow64Process) {
        $sysnative = (Get-WindowsDirectoryPath) + '\Sysnative\WindowsPowerShell\v1.0\powershell.exe'
        if (Test-Path -LiteralPath $sysnative -PathType Leaf) {
            return $sysnative
        }
    }
    return (Get-WindowsPowerShellPath)
}

function Invoke-DiagnosticsWindowsPowerShell {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Script,

        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 120
    )

    $prologue = '[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false); $ProgressPreference = ''SilentlyContinue''; '
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($prologue + $Script))
    return (Invoke-ExternalProcess -FilePath (Get-DiagnosticsWindowsPowerShellPath) -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded) -TimeoutSeconds $TimeoutSeconds -Echo None -RemoveEnvironmentVariable @('PSModulePath'))
}

function Get-DiagnosticsAppxReport {
    $query = @'
$names = @('Microsoft.DesktopAppInstaller', 'Microsoft.WindowsAppRuntime.*')
function Write-DiagnosticsPackage($package) {
    '{0} {1} {2} Status={3} Framework={4}' -f $package.Name, $package.Version, $package.Architecture, $package.Status, $package.IsFramework
    '  PackageFullName: {0}' -f $package.PackageFullName
    '  InstallLocation: {0}' -f $package.InstallLocation
    foreach ($user in @($package.PackageUserInformation)) {
        if ($user.UserSecurityId -and $user.UserSecurityId.Sid) {
            '  User: {0} {1}' -f $user.UserSecurityId.Sid, $user.InstallState
        }
        else {
            '  User: {0}' -f $user
        }
    }
}
'== Registered for any account (Get-AppxPackage -AllUsers) =='
try {
    $packages = @(foreach ($name in $names) { Get-AppxPackage -AllUsers -Name $name -ErrorAction Stop })
    if ($packages.Count -eq 0) { 'none' }
    foreach ($package in @($packages | Sort-Object Name, Version)) { Write-DiagnosticsPackage $package }
}
catch {
    'not read (it needs PowerShell started as administrator): ' + $_.Exception.Message
    ''
    '== Registered for this account (Get-AppxPackage) =='
    try {
        $packages = @(foreach ($name in $names) { Get-AppxPackage -Name $name -ErrorAction Stop })
        if ($packages.Count -eq 0) { 'none' }
        foreach ($package in @($packages | Sort-Object Name, Version)) { Write-DiagnosticsPackage $package }
    }
    catch {
        'not read: ' + $_.Exception.Message
    }
}
''
'== Provisioned for new accounts (Get-AppxProvisionedPackage -Online) =='
try {
    $provisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop | Where-Object { $_.DisplayName -like 'Microsoft.DesktopAppInstaller*' -or $_.DisplayName -like 'Microsoft.WindowsAppRuntime*' })
    if ($provisioned.Count -eq 0) { 'none' }
    foreach ($package in @($provisioned | Sort-Object PackageName)) { '{0} {1} ({2})' -f $package.DisplayName, $package.Version, $package.PackageName }
}
catch {
    'not read (it needs PowerShell started as administrator): ' + $_.Exception.Message
}
'@
    if ($PSVersionTable.PSEdition -eq 'Core') {
        $query += @'

''
'== Execution policy, Windows PowerShell (Get-ExecutionPolicy -List) =='
try {
    foreach ($policy in @(Get-ExecutionPolicy -List)) { '  {0} = {1}' -f $policy.Scope, $policy.ExecutionPolicy }
}
catch {
    'not read: ' + $_.Exception.Message
}
'@
    }

    $result = Invoke-DiagnosticsWindowsPowerShell -Script $query
    $lines = @()
    if ($result.LaunchFailed -or $result.TimedOut -or ($null -ne $result.ExitCode -and $result.ExitCode -ne 0)) {
        $lines += @(Format-DiagnosticsProcessResult -Label 'Windows PowerShell (AppX queries)' -Result $result)
        return $lines
    }
    return @($result.Output)
}

function Get-DiagnosticsWauLogTail {
    param (
        [Parameter(Mandatory = $false)]
        [int]$MaximumLines = 400
    )

    $candidates = @()
    $logPath = Get-WauUpdatesLogPath
    if ($logPath) {
        $candidates += $logPath
    }
    if ($env:ProgramW6432) {
        $candidates += Join-Path $env:ProgramW6432 'Winget-AutoUpdate\logs\updates.log'
    }
    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            continue
        }
        $text = Read-DiagnosticsTextFile -Path $candidate -MaxBytes 1MB
        $allLines = @($text -split '\r?\n')
        if ($allLines.Count -gt 0 -and $allLines[$allLines.Count - 1] -eq '') {
            $allLines = @($allLines | Select-Object -First ($allLines.Count - 1))
        }
        $tail = @($allLines | Select-Object -Last $MaximumLines)
        return @(('The last {0} lines of {1}:' -f $tail.Count, $candidate)) + $tail
    }
    if ($candidates.Count -eq 0) {
        return @('Winget-AutoUpdate''s updates.log was not found: no Winget-AutoUpdate folder is known on this PC.')
    }
    return @(('Winget-AutoUpdate''s updates.log was not found ({0}).' -f (@($candidates) -join '; ')))
}

function Save-DiagnosticsBundle {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Entry
    )

    Add-Type -AssemblyName System.IO.Compression
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $fileStream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    $written = $false
    try {
        $archive = New-Object System.IO.Compression.ZipArchive($fileStream, [System.IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            foreach ($name in @($Entry.Keys)) {
                $zipEntry = $archive.CreateEntry([string]$name, [System.IO.Compression.CompressionLevel]::Optimal)
                $entryStream = $zipEntry.Open()
                try {
                    $bytes = $utf8.GetBytes([string]$Entry[$name])
                    $entryStream.Write($bytes, 0, $bytes.Length)
                }
                finally {
                    $entryStream.Dispose()
                }
            }
        }
        finally {
            $archive.Dispose()
        }
        $written = $true
    }
    finally {
        $fileStream.Dispose()
        if (-not $written) {
            try {
                Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
            }
            catch {
            }
        }
    }
}

function Get-DiagnosticsUserPhaseDirectory {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        return $null
    }
    return (Join-Path $env:LOCALAPPDATA 'winget-app-setup')
}

function Add-DiagnosticsLogEntry {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Files,

        [Parameter(Mandatory = $true)]
        [string]$Prefix,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Entries,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$Sources,

        [Parameter(Mandatory = $true)]
        [long]$BudgetBytes
    )

    $skipped = @()
    foreach ($file in @($Files)) {
        if ($null -eq $file) {
            continue
        }
        if ($BudgetBytes -le 0) {
            $skipped += $file.Name
            continue
        }
        try {
            $content = Read-DiagnosticsTextFile -Path $file.FullName -MaxBytes ([Math]::Min([long]4MB, $BudgetBytes))
            $BudgetBytes -= [Math]::Min([long]$file.Length, [long]4MB)
            $Entries[$Prefix + $file.Name] = $content
        }
        catch {
            $Sources.Add(('Log {0}: not read: {1}' -f $file.Name, $_.Exception.Message))
        }
    }
    return [pscustomobject]@{ BudgetBytes = $BudgetBytes; Skipped = $skipped }
}

function Invoke-DiagnosticsCollection {
    param (
        [Parameter(Mandatory = $false)]
        [string]$LogDirectory,

        [Parameter(Mandatory = $false)]
        [string[]]$OutputDirectory
    )

    Write-Info 'Making a diagnostics bundle for a GitHub issue: the installer''s logs and the state of winget, App Installer and auto-updates on this PC. Nothing on this PC is changed.'
    if ([string]::IsNullOrWhiteSpace($LogDirectory) -and $env:ProgramData) {
        $LogDirectory = Join-Path $env:ProgramData 'winget-app-setup\logs'
    }

    $account = $null
    try {
        $account = Get-InstallAccountContext
    }
    catch {
        $account = $null
    }
    $isAdmin = [bool](Test-IsAdmin)
    $isWow64 = $false
    try {
        $isWow64 = [bool](Test-DiagnosticsWow64Process)
    }
    catch {
        $isWow64 = $false
    }

    $sources = New-Object System.Collections.Generic.List[string]
    $entries = [ordered]@{}
    $entries['README.txt'] = ''

    $budget = [long]64MB
    if ($LogDirectory -and (Test-Path -LiteralPath $LogDirectory -PathType Container)) {
        try {
            $selection = Select-DiagnosticsLogFile -LogDirectory $LogDirectory
            $files = @($selection.Transcripts) + @($selection.InstallerLogs)
            if ($selection.RunRecord) {
                $files += $selection.RunRecord
            }
            $added = Add-DiagnosticsLogEntry -Files $files -Prefix 'logs/' -Entries $entries -Sources $sources -BudgetBytes $budget
            $budget = $added.BudgetBytes
            $sources.Add(('Installer logs ({0}): {1} transcript(s), {2} installer log(s), last-run.json {3}' -f $LogDirectory, @($selection.Transcripts).Count, @($selection.InstallerLogs).Count, $(if ($selection.RunRecord) { 'included' } else { 'not found' })))
            if (@($added.Skipped).Count -gt 0) {
                $sources.Add(('Left out to keep the bundle small: {0}' -f (@($added.Skipped) -join ', ')))
            }
            $listing = @($selection.Files | Sort-Object -Property Name | ForEach-Object { '  {0}  {1} bytes  {2}' -f $_.Name, $_.Length, $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture) })
            if ($listing.Count -gt 0) {
                $sources.Add('Files in the logs folder:')
                foreach ($line in $listing) {
                    $sources.Add($line)
                }
            }
        }
        catch {
            $sources.Add(('Installer logs ({0}): not read: {1}' -f $LogDirectory, $_.Exception.Message))
        }
    }
    else {
        $sources.Add(('Installer logs ({0}): the folder does not exist or cannot be opened' -f $LogDirectory))
    }

    $userPhaseDirectory = $null
    try {
        $userPhaseDirectory = Get-DiagnosticsUserPhaseDirectory
    }
    catch {
        $userPhaseDirectory = $null
    }
    if ($userPhaseDirectory -and (Test-Path -LiteralPath $userPhaseDirectory -PathType Container)) {
        try {
            $userPhaseFiles = @()
            $statePath = Join-Path $userPhaseDirectory 'user-phase.json'
            $stateFound = Test-Path -LiteralPath $statePath -PathType Leaf
            if ($stateFound) {
                $userPhaseFiles += Get-Item -LiteralPath $statePath -Force -ErrorAction Stop
            }
            $userLogDirectory = Join-Path $userPhaseDirectory 'logs'
            $userTranscripts = @()
            $userInstallerLogs = @()
            if (Test-Path -LiteralPath $userLogDirectory -PathType Container) {
                $userSelection = Select-DiagnosticsLogFile -LogDirectory $userLogDirectory -MaximumTranscripts 2
                $userTranscripts = @($userSelection.Transcripts)
                $userInstallerLogs = @($userSelection.InstallerLogs)
            }
            $added = Add-DiagnosticsLogEntry -Files @($userPhaseFiles) -Prefix 'user-phase/' -Entries $entries -Sources $sources -BudgetBytes $budget
            $budget = $added.BudgetBytes
            $addedLogs = Add-DiagnosticsLogEntry -Files (@($userTranscripts) + @($userInstallerLogs)) -Prefix 'user-phase/logs/' -Entries $entries -Sources $sources -BudgetBytes $budget
            $budget = $addedLogs.BudgetBytes
            $sources.Add(('User phase of this account ({0}): user-phase.json {1}, {2} transcript(s), {3} installer log(s)' -f $userPhaseDirectory, $(if ($stateFound) { 'included' } else { 'not found' }), $userTranscripts.Count, $userInstallerLogs.Count))
            $userSkipped = @($added.Skipped) + @($addedLogs.Skipped)
            if ($userSkipped.Count -gt 0) {
                $sources.Add(('Left out to keep the bundle small: {0}' -f ($userSkipped -join ', ')))
            }
        }
        catch {
            $sources.Add(('User phase of this account ({0}): not read: {1}' -f $userPhaseDirectory, $_.Exception.Message))
        }
    }
    else {
        $sources.Add('User phase of this account: it has not run here (no %LOCALAPPDATA%\winget-app-setup)')
    }

    try {
        $entries['system.txt'] = (@(Get-DiagnosticsSystemReport -AccountContext $account -IsAdmin $isAdmin) -join [Environment]::NewLine)
        $sources.Add('System (system.txt): collected')
    }
    catch {
        $sources.Add("System (system.txt): not collected: $($_.Exception.Message)")
    }
    try {
        $entries['winget.txt'] = (@(Get-DiagnosticsWingetReport -AccountContext $account) -join [Environment]::NewLine)
        $sources.Add('winget --version and --info (winget.txt): collected')
    }
    catch {
        $sources.Add("winget --version and --info (winget.txt): not collected: $($_.Exception.Message)")
    }
    try {
        $entries['appx.txt'] = (@(Get-DiagnosticsAppxReport) -join [Environment]::NewLine)
        $sources.Add('AppX packages (appx.txt): collected')
    }
    catch {
        $sources.Add("AppX packages (appx.txt): not collected: $($_.Exception.Message)")
    }
    try {
        $entries['wau-updates-log-tail.txt'] = (@(Get-DiagnosticsWauLogTail) -join [Environment]::NewLine)
        $sources.Add('Winget-AutoUpdate log (wau-updates-log-tail.txt): collected')
    }
    catch {
        $sources.Add("Winget-AutoUpdate log (wau-updates-log-tail.txt): not collected: $($_.Exception.Message)")
    }

    $buildId = 'unknown'
    if ($script:InstallerBuildId) {
        $buildId = [string]$script:InstallerBuildId
    }
    $readme = @(
        'winget-app-setup diagnostics bundle',
        ('Made {0} by installer build {1}, without changing anything on the PC.' -f (Format-RunRecordTime -Time ([DateTime]::UtcNow)), $buildId),
        '',
        'Removed for the public issue: account names, the computer name, domain names, user profile folder names, the security identifiers (SIDs) of real accounts and email addresses. Each became a placeholder such as <user1>, <computer1>, <domain1> or S-1-5-21-<sid1>-1001, the same one in every file. Built-in accounts and well-known SIDs (SYSTEM, Administrators, S-1-5-18, S-1-5-32-544) were kept. Look through the files before you attach the bundle anyway.',
        '',
        'Files:',
        '  system.txt                Windows build, accounts and elevation, PowerShell and execution policy, Group Policy for App Installer and the Store, pending restart, Winget-AutoUpdate',
        '  winget.txt                winget --version and winget --info',
        '  appx.txt                  App Installer and Windows App Runtime packages, registered and provisioned',
        '  wau-updates-log-tail.txt  the end of Winget-AutoUpdate''s updates.log',
        '  logs\                     the latest run''s transcripts (the RMM wrapper''s install-<time>-rmm.log too) and installer logs, and last-run.json',
        '  user-phase\               this account''s user phase, when it has run here: user-phase.json, its latest transcripts and winget logs'
    )
    if (-not $isAdmin) {
        $readme += ''
        $readme += 'This PowerShell was not elevated, so the AppX packages of other accounts, the provisioned packages and maybe some logs could not be read. Run the command again from PowerShell started as administrator for those.'
    }
    if ($isWow64) {
        $readme += ''
        $readme += (Get-DiagnosticsWow64Note)
    }
    $readme += ''
    $readme += 'Sources:'
    foreach ($line in $sources) {
        $readme += ('  ' + $line)
    }
    $entries['README.txt'] = $readme -join [Environment]::NewLine

    $hint = $null
    try {
        $hint = Get-DiagnosticsIdentityHint -AccountContext $account
    }
    catch {
        $hint = $null
    }
    $texts = @(foreach ($name in @($entries.Keys)) { [string]$entries[$name] })
    $map = New-DiagnosticsRedactionMap -IdentityHint $hint -Text $texts
    $redacted = [ordered]@{}
    foreach ($name in @($entries.Keys)) {
        $redacted[$name] = ConvertTo-RedactedDiagnosticText -Text ([string]$entries[$name]) -Map $map
    }

    $directories = @($OutputDirectory | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($directories.Count -eq 0) {
        $directories = @(Get-DiagnosticsBundleDirectory -AccountContext $account)
    }
    $fileName = 'winget-app-setup-diagnostics-{0:yyyyMMdd-HHmmss}.zip' -f (Get-Date)
    foreach ($directory in $directories) {
        $path = Join-Path $directory $fileName
        try {
            Save-DiagnosticsBundle -Path $path -Entry $redacted
            Write-Success "Diagnostics bundle saved: $path"
            Write-Info 'Attach it to the GitHub issue: https://github.com/J-MaFf/winget-app-setup/issues/new?template=install-failure.yml. Account and computer names were removed from it; look through it before you attach it anyway.'
            if (-not $isAdmin) {
                Write-WarningMessage 'This PowerShell is not elevated, so some of the PC''s state could not be read (see README.txt in the bundle). For a complete bundle, run the same command from PowerShell started as administrator.'
            }
            if ($isWow64) {
                Write-WarningMessage (Get-DiagnosticsWow64Note)
            }
            return 0
        }
        catch {
            Write-WarningMessage ('Could not save the diagnostics bundle in {0}: {1}' -f $directory, $_.Exception.Message)
        }
    }
    Write-ErrorMessage 'The diagnostics bundle could not be saved in any folder (see above).'
    return 5
}

# --- Elevation ---
function Test-IsRunningLocally {
    if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        return $false
    }

    try {
        $null = Get-Item -LiteralPath $PSScriptRoot -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function Get-ProcessUserName {
    try {
        return [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    }
    catch {
        return $null
    }
}

function Test-IsSystemAccount {
    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        return [bool]$identity.IsSystem
    }
    catch {
        return $false
    }
}

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

function Get-InstallAccountContext {
    $isSystem = [bool](Test-IsSystemAccount)
    $processUser = Get-ProcessUserName
    $sessionUser = Get-InteractiveSessionUserName
    $isCrossUser = (-not $isSystem) -and (-not [string]::IsNullOrWhiteSpace($processUser)) -and (-not [string]::IsNullOrWhiteSpace($sessionUser)) -and ($processUser -ne $sessionUser)
    return [pscustomobject]@{
        IsSystem             = $isSystem
        ProcessUser          = $processUser
        SessionUser          = $sessionUser
        IsCrossUserElevation = [bool]$isCrossUser
    }
}

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

function Get-CurrentWindowsPrincipal {
    [Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
}

function Get-WindowsDirectoryPath {
    $windowsDirectory = $env:SystemRoot
    if (-not $windowsDirectory) {
        $windowsDirectory = $env:windir
    }
    if (-not $windowsDirectory) {
        $windowsDirectory = 'C:\Windows'
    }
    return $windowsDirectory.TrimEnd('\')
}

function Get-WindowsPowerShellPath {
    return (Get-WindowsDirectoryPath) + '\System32\WindowsPowerShell\v1.0\powershell.exe'
}

function Get-ElevatedCopyRoot {
    return (Get-WindowsDirectoryPath) + '\Temp'
}

function New-ElevationVerifierCommand {
    param (
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[0-9A-Fa-f]{64}$')]
        [string]$Sha256,

        [Parameter(Mandatory = $true)]
        [string]$PowerShellPath,

        [Parameter(Mandatory = $true)]
        [string]$CopyRoot,

        [Parameter(Mandatory = $false)]
        [ValidatePattern('^(?:-[A-Za-z][A-Za-z0-9]*|[0-9][0-9A-Za-z:.-]*)\z')]
        [string[]]$AdditionalArguments = @()
    )

    $template = @'
$ErrorActionPreference = 'Stop';
$LASTEXITCODE = 5;
$copyDirectory = $null;
try {
    $p = Get-ExecutionPolicy;
    if ($p -in 2, 3) { $LASTEXITCODE = 4; throw ('Group Policy sets the execution policy to ' + $p + ', which -ExecutionPolicy Bypass cannot override'); }
    $bytes = [IO.File]::ReadAllBytes(@SOURCE@);
    $hash = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($bytes)).Replace('-', '');
    if ($hash -ne @SHA256@) { throw 'the file changed after administrator rights were requested'; }
    $security = New-Object Security.AccessControl.DirectorySecurity;
    $security.SetAccessRuleProtection($true, $false);
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) { $security.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)), 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow'))); }
    $copyDirectory = Join-Path @COPYROOT@ ('winget-app-setup-' + [Guid]::NewGuid().ToString('N'));
    [void][IO.Directory]::CreateDirectory($copyDirectory, $security);
    $copy = Join-Path $copyDirectory @NAME@;
    [IO.File]::WriteAllBytes($copy, $bytes);
    & @POWERSHELL@ -NoProfile -ExecutionPolicy Bypass -File $copy@ARGUMENTS@;
} catch {
    Write-Host ('Did not run ' + @NAME@ + ': ' + $_) -ForegroundColor Red;
    try { [void](Read-Host 'Press Enter to close this window'); } catch { }
} finally {
    $host.SetShouldExit($LASTEXITCODE);
    if ($copyDirectory) { Remove-Item -LiteralPath $copyDirectory -Recurse -Force -ErrorAction SilentlyContinue; }
}
'@

    $quote = { param ([string]$Text) "'" + [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($Text) + "'" }
    $forwardedArguments = ''
    if ($AdditionalArguments.Count -gt 0) {
        $forwardedTokens = @($AdditionalArguments | ForEach-Object {
                if ($_.StartsWith('-')) { $_ } else { & $quote $_ }
            })
        $forwardedArguments = ' ' + ($forwardedTokens -join ' ')
    }
    $values = @{
        SOURCE     = (& $quote $ScriptPath)
        SHA256     = (& $quote $Sha256.ToUpperInvariant())
        COPYROOT   = (& $quote $CopyRoot)
        NAME       = (& $quote ($ScriptPath -split '[\\/]')[-1])
        POWERSHELL = (& $quote $PowerShellPath)
        ARGUMENTS  = $forwardedArguments
    }
    $command = (($template -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ' '
    return [regex]::Replace($command, '@(SOURCE|SHA256|COPYROOT|NAME|POWERSHELL|ARGUMENTS)@', [System.Text.RegularExpressions.MatchEvaluator] { param ($match) $values[$match.Groups[1].Value] })
}

function Start-ElevatedProcess {
    param (
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [string]$ArgumentString
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = $ArgumentString
    $startInfo.UseShellExecute = $true
    $startInfo.Verb = 'runas'
    return [System.Diagnostics.Process]::Start($startInfo)
}

# --- EnvironmentPreflight ---
function Get-PowerShellLanguageMode {
    return [string]$ExecutionContext.SessionState.LanguageMode
}

function Test-FullLanguageMode {
    $mode = Get-PowerShellLanguageMode
    if ($mode -eq 'FullLanguage') {
        return $true
    }
    Write-ErrorMessage ('PowerShell runs this installer in {0} mode on this PC, which an application control policy (App Control for Business/WDAC or AppLocker) sets for scripts it does not trust. The installer needs FullLanguage mode, so it stops here with exit code 5 and changes nothing: run it on a PC without that policy, or ask whoever manages the policy to allow it.' -f $mode)
    return $false
}

function Test-LaunchedByGroupPolicyScript {
    try {
        $gpScriptPath = [System.IO.Path]::Combine([Environment]::GetFolderPath([Environment+SpecialFolder]::System), 'gpscript.exe')
        $processId = $PID
        $childStarted = $null
        for ($depth = 0; $depth -lt 32 -and $processId; $depth++) {
            $process = Get-CimInstance -ClassName Win32_Process -Filter ('ProcessId = {0}' -f $processId) -ErrorAction Stop
            if (-not $process) {
                break
            }
            if ($null -ne $childStarted -and $null -ne $process.CreationDate -and $process.CreationDate -gt $childStarted) {
                break
            }
            if ("$($process.ExecutablePath)" -eq $gpScriptPath) {
                return $true
            }
            $childStarted = $process.CreationDate
            $processId = $process.ParentProcessId
        }
    }
    catch {
    }
    return $false
}

function Get-ScriptExecutionPolicyBlock {
    param (
        [Parameter(Mandatory = $true)]
        [ValidateSet('WindowsPowerShell', 'PowerShell7')]
        [string]$Engine
    )

    $windowsKey = 'SOFTWARE\Policies\Microsoft\Windows\PowerShell'
    $coreKey = 'SOFTWARE\Policies\Microsoft\PowerShellCore'
    $engineName = 'Windows PowerShell'
    if ($Engine -eq 'PowerShell7') {
        $engineName = 'PowerShell 7'
    }

    $scopes = @(
        @{ Name = 'MachinePolicy'; Hive = 'HKLM'; Target = 'this PC'; Node = 'Computer Configuration' },
        @{ Name = 'UserPolicy'; Hive = 'HKCU'; Target = 'this account'; Node = 'User Configuration' }
    )
    foreach ($scope in $scopes) {
        $keyPath = $windowsKey
        $templatePath = 'Windows Components > Windows PowerShell'
        $templateNote = ''
        $values = $null
        if ($Engine -eq 'PowerShell7') {
            try {
                $values = Get-ItemProperty -LiteralPath ('{0}:\{1}' -f $scope.Hive, $coreKey) -ErrorAction Stop
            }
            catch {
                continue
            }
            $keyPath = $coreKey
            $templatePath = 'PowerShell Core'
            $fallback = "$($values.UseWindowsPowerShellPolicySetting)"
            if ($fallback -and $fallback -ne '0') {
                $keyPath = $windowsKey
                $templatePath = 'Windows Components > Windows PowerShell'
                $templateNote = ', which PowerShell 7 follows through ''Use Windows PowerShell Policy setting'' under PowerShell Core'
                $values = $null
            }
        }

        if ($null -eq $values) {
            try {
                $values = Get-ItemProperty -LiteralPath ('{0}:\{1}' -f $scope.Hive, $keyPath) -ErrorAction Stop
            }
            catch {
                continue
            }
        }
        $enableScripts = "$($values.EnableScripts)"
        $policy = $null
        if ($enableScripts -eq '0') {
            $policy = 'Restricted'
        }
        elseif ($enableScripts -eq '1') {
            $policy = "$($values.ExecutionPolicy)".Trim()
        }
        if (-not $policy) {
            continue
        }

        if (@('Bypass', 'Unrestricted', 'RemoteSigned') -contains $policy) {
            return $null
        }
        if ($policy -eq 'AllSigned') {
            $policy = 'AllSigned'
        }
        else {
            $policy = 'Restricted'
        }
        if (Test-LaunchedByGroupPolicyScript) {
            return $null
        }
        $key = '{0}\{1}' -f $scope.Hive, $keyPath
        return [pscustomobject]@{
            Engine          = $Engine
            Scope           = $scope.Name
            Policy          = $policy
            Key             = $key
            GroupPolicyPath = '{0} > Administrative Templates > {1} > Turn on Script Execution{2}' -f $scope.Node, $templatePath, $templateNote
            Description     = 'Group Policy sets the {0} execution policy for {1} to {2} ({3}, {4})' -f $engineName, $scope.Target, $policy, $scope.Name, $key
        }
    }
    return $null
}

function Format-ElevationPolicyBlockMessage {
    param (
        [Parameter(Mandatory = $true)]
        [object]$Block
    )

    if ($Block.Scope -eq 'MachinePolicy') {
        return ('{0}, which -ExecutionPolicy Bypass on the command line cannot override, so an elevated Windows PowerShell cannot run this script from a file. Ask whoever manages this PC''s policies to allow scripts ({1}), or start it from an elevated PowerShell 7 (pwsh) session, where it needs no relaunch.' -f $Block.Description, $Block.GroupPolicyPath)
    }
    return ('{0}, which -ExecutionPolicy Bypass on the command line cannot override: if this account approves the UAC prompt, the elevated Windows PowerShell cannot run this script from a file. Approve it with another administrator account, or ask whoever manages the policies to allow scripts ({1}).' -f $Block.Description, $Block.GroupPolicyPath)
}

function Get-AccountSid {
    param (
        [Parameter(Mandatory = $true)]
        [string]$AccountName
    )

    try {
        $account = New-Object System.Security.Principal.NTAccount($AccountName)
        return $account.Translate([System.Security.Principal.SecurityIdentifier]).Value
    }
    catch {
        return $null
    }
}

function Get-WinInetProxySetting {
    param (
        [Parameter(Mandatory = $false)]
        [string]$UserSid
    )

    $path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    if ($UserSid) {
        $path = 'Registry::HKEY_USERS\{0}\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -f $UserSid
    }
    try {
        $values = Get-ItemProperty -LiteralPath $path -ErrorAction Stop
    }
    catch {
        return $null
    }

    $server = ''
    $override = ''
    if ("$($values.ProxyEnable)" -eq '1') {
        $server = "$($values.ProxyServer)".Trim()
        if ($server) {
            $override = "$($values.ProxyOverride)".Trim()
        }
    }
    return [pscustomobject]@{
        ProxyServer   = $server
        ProxyOverride = $override
        AutoConfigUrl = "$($values.AutoConfigURL)".Trim()
    }
}

function Test-ProxySettingsPerMachine {
    try {
        $values = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
    }
    catch {
        return $false
    }
    return ("$($values.ProxySettingsPerUser)" -eq '0')
}

function Format-WinInetProxySetting {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Setting
    )

    $parts = @()
    if ($Setting -and $Setting.ProxyServer) {
        $server = 'proxy server {0}' -f $Setting.ProxyServer
        if ($Setting.ProxyOverride) {
            $server += ' (bypass: {0})' -f $Setting.ProxyOverride
        }
        $parts += $server
    }
    if ($Setting -and $Setting.AutoConfigUrl) {
        $parts += 'automatic configuration script {0}' -f $Setting.AutoConfigUrl
    }
    if ($parts.Count -eq 0) {
        return 'no proxy'
    }
    return ($parts -join ', ')
}

function Get-ProxyInheritanceWarning {
    param (
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$AccountContext
    )

    if ($null -eq $AccountContext -or -not ($AccountContext.IsSystem -or $AccountContext.IsCrossUserElevation)) {
        return $null
    }
    $sessionUser = "$($AccountContext.SessionUser)"
    if ([string]::IsNullOrWhiteSpace($sessionUser)) {
        return $null
    }
    if (Test-ProxySettingsPerMachine) {
        return $null
    }
    $sid = Get-AccountSid -AccountName $sessionUser
    if (-not $sid) {
        return $null
    }
    $userProxy = Get-WinInetProxySetting -UserSid $sid
    if (-not $userProxy -or -not ($userProxy.ProxyServer -or $userProxy.AutoConfigUrl)) {
        return $null
    }
    $ownProxy = Get-WinInetProxySetting
    if ($ownProxy -and $ownProxy.ProxyServer -eq $userProxy.ProxyServer -and $ownProxy.AutoConfigUrl -eq $userProxy.AutoConfigUrl) {
        return $null
    }

    $who = 'SYSTEM'
    if (-not $AccountContext.IsSystem) {
        $who = "'$($AccountContext.ProcessUser)'"
    }
    return ("The signed-in user '{0}' has a proxy in their Windows Internet settings ({1}) that this run as {2} does not use ({2} has {3}). On a network that only allows traffic through that proxy, downloads fail; if they do, give {2} the same proxy settings, or set the proxy for the whole PC, and re-run the installer." -f $sessionUser, (Format-WinInetProxySetting -Setting $userProxy), $who, (Format-WinInetProxySetting -Setting $ownProxy))
}

function Invoke-EnvironmentPreflight {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$AccountContext
    )

    if ($null -eq $AccountContext) {
        $AccountContext = Get-InstallAccountContext
    }

    $proxyWarning = $null
    try {
        $proxyWarning = Get-ProxyInheritanceWarning -AccountContext $AccountContext
    }
    catch {
        $proxyWarning = $null
    }
    if ($proxyWarning) {
        Write-WarningMessage $proxyWarning
    }

    $restartState = $null
    try {
        $restartState = Get-PendingRestartState
    }
    catch {
        Write-WarningMessage "Could not check whether a restart is pending: $_"
    }
    $restartReasons = @(Get-PendingRestartReason -State $restartState)
    if ($restartReasons.Count -gt 0) {
        Write-WarningMessage ('A restart is already pending on this PC ({0}). An installer that needs a restart first fails with 0x8A15010A; if one does, restart this PC and re-run the installer.' -f ($restartReasons -join '; '))
    }

    $exitCode = 0
    $policy = Get-WingetPolicyBlock
    if ($policy) {
        Write-WingetPolicyBlockMessage -Block $policy -WhatIf:$WhatIf
        if (-not $WhatIf) {
            $exitCode = 2
        }
    }

    return [pscustomobject]@{
        ExitCode              = $exitCode
        RestartState          = $restartState
        RestartPendingReasons = $restartReasons
        WingetPolicyBlocked   = [bool]$policy
    }
}

# --- FailureReporting ---
function Exit-Installer {
    param (
        [Parameter(Mandatory = $false)]
        [int]$Code = 0,
        [Parameter(Mandatory = $false)]
        [string]$Reason,
        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive,
        [Parameter(Mandatory = $false)]
        [switch]$OutcomeShown
    )

    $noticeShown = $false
    if ($Code -ne 0 -and -not $OutcomeShown) {
        $script:InstallerPendingExitCode = $Code
        try {
            Write-InstallerExitNotice -Code $Code -Reason $Reason -NonInteractive:$NonInteractive -NoPause
            $noticeShown = $true
        }
        catch {
        }
    }
    try {
        Complete-InstallerRun -ExitCode $Code
    }
    catch {
    }
    if ($noticeShown) {
        try {
            Wait-InstallerExitKeyPress -NonInteractive:$NonInteractive
        }
        catch {
        }
    }
    $script:InstallerExitRequested = $true
    exit $Code
}

function Write-InstallerExitNotice {
    param (
        [Parameter(Mandatory = $true)]
        [int]$Code,
        [Parameter(Mandatory = $false)]
        [string]$Reason,
        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive,
        [Parameter(Mandatory = $false)]
        [switch]$NoPause
    )

    $why = $Reason
    if (-not $why) {
        switch ($Code) {
            1 { $why = 'a pre-flight check failed (see above)' }
            2 { $why = 'winget is not available, could not be started, or is turned off by Group Policy (see above)' }
            3 { $why = 'the app catalog failed validation (see above)' }
            4 { $why = 'administrator rights are required, and this run was not elevated, or Group Policy''s execution policy keeps the elevated window from running the installer (see above)' }
            5 { $why = 'the run was aborted before it finished (see above)' }
            6 { $why = 'another run of the installer is in progress on this PC' }
            7 { $why = 'PowerShell 7 could not be installed, or the installer could not be relaunched under it (see above)' }
        }
    }

    Write-Host ''
    if ($why) {
        Write-ErrorMessage ('The installer stopped early with exit code {0}: {1}.' -f $Code, $why)
    }
    else {
        Write-ErrorMessage ('The installer stopped early with exit code {0}.' -f $Code)
    }
    if ($script:InstallLogPath) {
        Write-Info "Log file: $script:InstallLogPath"
    }
    else {
        Write-WarningMessage 'Log file: none - the transcript could not be started (see the warning at the start of the run).'
    }
    if ($script:InstallerBuildId) {
        Write-Info "Installer build: $script:InstallerBuildId"
    }
    Write-InstallerReportHint

    if ($NoPause) {
        return
    }
    Wait-InstallerExitKeyPress -NonInteractive:$NonInteractive
}

function Wait-InstallerExitKeyPress {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive
    )

    if ((Test-EffectiveNonInteractive -NonInteractive:$NonInteractive) -or (Test-IsContinuousIntegration)) {
        return
    }
    Write-Prompt 'Press any key to exit...'
    try {
        [void][System.Console]::ReadKey($true)
    }
    catch {
    }
}

function Get-InstallerExitCode {
    param (
        [Parameter(Mandatory = $true)]
        [int]$FailedAppCount,

        [Parameter(Mandatory = $true)]
        [bool]$WingetUsable,

        [Parameter(Mandatory = $false)]
        [bool]$WorkNotAttempted = $false,

        [Parameter(Mandatory = $false)]
        [bool]$AutoUpdatesHealthy = $true,

        [Parameter(Mandatory = $false)]
        [bool]$RestartRequired = $false
    )

    if ($FailedAppCount -gt 0) {
        return 1
    }
    if (-not $WingetUsable) {
        return 2
    }
    if ($WorkNotAttempted) {
        return 9
    }
    if (-not $AutoUpdatesHealthy) {
        return 8
    }
    if ($RestartRequired) {
        return 3010
    }
    return 0
}

function Format-InstallFailureReason {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$FailureReason,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [hashtable]$InstallResult,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$LaunchError,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[int]]$CheckExitCode,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$PostInstallReason,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Cli', 'WinGetClient')]
        [string]$InstallEngine
    )

    if ($FailureReason -eq 'PostInstallFailed') {
        $hookReason = 'no reason given'
        if (-not [string]::IsNullOrWhiteSpace($PostInstallReason)) {
            $hookReason = $PostInstallReason.Trim()
        }
        return ('installed, but its post-install configuration failed ({0})' -f $hookReason)
    }

    if (-not $InstallEngine) {
        $InstallEngine = 'Cli'
        if ($InstallResult -and $InstallResult.ContainsKey('Engine') -and $InstallResult.Engine -eq 'WinGetClient') {
            $InstallEngine = 'WinGetClient'
        }
        elseif (-not ($InstallResult -and $InstallResult.ContainsKey('Engine')) -and (Test-WingetClientEngineActive)) {
            $InstallEngine = 'WinGetClient'
        }
    }
    $clientEngine = $InstallEngine -eq 'WinGetClient'

    $base = switch ($FailureReason) {
        { $clientEngine -and $_ -eq 'PreCheckTimeout' } { 'Get-WinGetPackage timed out during the pre-install check'; break }
        { $clientEngine -and $_ -eq 'PreCheckLaunchFailed' } { 'the WinGet client engine could not be started for the pre-install check'; break }
        { $clientEngine -and $_ -eq 'PreCheckFailed' } { 'Get-WinGetPackage failed during the pre-install check'; break }
        { $clientEngine -and $_ -eq 'InstallLaunchFailed' } { 'the WinGet client engine could not be started to install it'; break }
        { $clientEngine -and $_ -eq 'VerifyLaunchFailed' } { 'the WinGet client engine could not be started to verify the install'; break }
        { $clientEngine -and $_ -eq 'VerifyFailed' } { 'Get-WinGetPackage failed during the post-install check'; break }
        { $clientEngine -and $_ -eq 'WingetNotLaunchable' } { 'not attempted: the WinGet client engine cannot be started on this machine (see above)'; break }
        'PreCheckTimeout' { 'winget list timed out during the pre-install check' }
        'PreCheckLaunchFailed' { 'winget could not be launched for the pre-install check' }
        'PreCheckFailed' { 'winget list failed during the pre-install check' }
        'InstallLaunchFailed' { 'winget could not be launched to install it' }
        'VerifyTimeout' { 'post-install verification timed out' }
        'VerifyLaunchFailed' { 'winget could not be launched to verify the install' }
        'VerifyFailed' { 'winget list failed during the post-install check' }
        'VerifyNotFound' { 'package not found after install' }
        'CustomInstallFailed' { 'installer reported failure' }
        'WingetNotLaunchable' { 'not attempted: winget cannot be launched on this machine (see above)' }
        'MachineCheckFailed' { 'could not check whether it is provisioned for every user on this PC (see the warning above)' }
        'NoMachineScopeInstaller' { "no machine-scope installer applies to this PC, and its catalog entry allows only a machine-wide install (scope 'machine')" }
        'NoUserScopeInstaller' { 'winget found no per-user installer for it that applies to this PC (0x8A150010 NO_APPLICABLE_INSTALLER with --scope user)' }
        default { 'install failed' }
    }
    if ($null -ne $CheckExitCode -and @('PreCheckFailed', 'VerifyFailed') -contains $FailureReason) {
        $base = '{0} with exit {1}' -f $base, (Format-WingetExitCode -ExitCode $CheckExitCode)
    }

    $installExitCode = $null
    if ($InstallResult -and $InstallResult.ContainsKey('ExitCode') -and $null -ne $InstallResult.ExitCode) {
        $installExitCode = [int]$InstallResult.ExitCode
    }
    if ($null -ne $installExitCode -and $installExitCode -ne 0 -and @('VerifyNotFound', 'CustomInstallFailed') -contains $FailureReason) {
        $codeInfo = Get-WingetExitCodeInfo -ExitCode $installExitCode
        if ($codeInfo) {
            $base = $codeInfo.Meaning
        }
        elseif ($FailureReason -eq 'VerifyNotFound') {
            $base = 'winget install failed'
            if ($clientEngine) {
                $base = 'Install-WinGetPackage failed'
            }
        }
    }

    $detailParts = @()
    if ($InstallResult) {
        if ($null -ne $installExitCode -and $clientEngine) {
            $detailParts += ('WinGet client result {0}' -f (Format-WingetExitCode -ExitCode $installExitCode))
            if ($InstallResult.ContainsKey('InstallerErrorCode') -and $null -ne $InstallResult.InstallerErrorCode -and [long]$InstallResult.InstallerErrorCode -ne 0) {
                $detailParts += ('installer exit code {0}' -f $InstallResult.InstallerErrorCode)
            }
        }
        elseif ($null -ne $installExitCode) {
            $detailParts += ('winget exit {0}' -f (Format-WingetExitCode -ExitCode $installExitCode))
        }
        if ($InstallResult.ContainsKey('Attempts') -and $InstallResult.Attempts) {
            $attemptWord = if ([int]$InstallResult.Attempts -eq 1) { 'attempt' } else { 'attempts' }
            $detailParts += ('{0} {1}' -f $InstallResult.Attempts, $attemptWord)
        }
        if ($InstallResult.ContainsKey('MachineScopeFellBack')) {
            $detailParts += ('machine-scope fallback: {0}' -f $(if ($InstallResult.MachineScopeFellBack) { 'yes' } else { 'no' }))
        }
        if ($InstallResult.ContainsKey('SessionErrorExhausted') -and $InstallResult.SessionErrorExhausted) {
            $detailParts += 'session error 0x80073D19 persisted through every retry'
        }
        if ($InstallResult.ContainsKey('InstallInProgressWaitedSeconds') -and $InstallResult.InstallInProgressWaitedSeconds) {
            $detailParts += ('waited {0} seconds for another installation' -f [int]$InstallResult.InstallInProgressWaitedSeconds)
        }
        if ($InstallResult.ContainsKey('LaunchErrorExhausted') -and $InstallResult.LaunchErrorExhausted) {
            $launchAttempts = 0
            if ($InstallResult.ContainsKey('LaunchAttempts') -and $InstallResult.LaunchAttempts) {
                $launchAttempts = [int]$InstallResult.LaunchAttempts
            }
            if ($launchAttempts -gt 0) {
                $launchWord = if ($launchAttempts -eq 1) { 'failed launch' } else { 'failed launches' }
                $detailParts += ('{0} {1}' -f $launchAttempts, $launchWord)
            }
        }
        if ($InstallResult.ContainsKey('TimedOut') -and $InstallResult.TimedOut) {
            $limit = 'its time limit'
            if ($InstallResult.ContainsKey('TimeoutSeconds') -and $InstallResult.TimeoutSeconds) {
                $limit = '{0} minutes' -f [Math]::Round([int]$InstallResult.TimeoutSeconds / 60)
            }
            $stoppedWhat = 'winget install'
            if ($clientEngine) {
                $stoppedWhat = 'the WinGet client install'
            }
            $detailParts += ('{0} stopped after {1}' -f $stoppedWhat, $limit)
        }
        if ($InstallResult.ContainsKey('InstallerLogPath') -and $InstallResult.InstallerLogPath) {
            $detailParts += ('installer log: {0}' -f $InstallResult.InstallerLogPath)
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($LaunchError)) {
        $detailParts += ('launch error: {0}' -f $LaunchError.Trim().TrimEnd('.'))
    }

    if ($detailParts.Count -gt 0) {
        return ('{0}; {1}' -f $base, ($detailParts -join ', '))
    }
    return $base
}

function Write-InstalledAppNote {
    param (
        [Parameter(Mandatory = $true)]
        [string]$AppName,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$InstallResult
    )

    if ($null -eq $InstallResult) {
        return $false
    }
    $exitCode = $null
    if ($null -ne $InstallResult.ExitCode) {
        $exitCode = [int]$InstallResult.ExitCode
    }

    if ($InstallResult.MachineScopeFellBack) {
        Write-Info ('{0} has no machine-wide installer, so it was installed for this account only.' -f $AppName)
    }

    $clientEngine = $InstallResult.Engine -eq 'WinGetClient'
    if ($InstallResult.RestartRequired) {
        $why = "winget printed 'Restart your PC to finish installation.'"
        if ($null -ne $exitCode -and $exitCode -ne 0) {
            $why = 'winget exit {0}' -f (Format-WingetExitCode -ExitCode $exitCode)
            if ($clientEngine) {
                $why = 'WinGet client result {0}' -f (Format-WingetExitCode -ExitCode $exitCode)
            }
        }
        elseif ($clientEngine -and $null -ne $InstallResult.InstallerErrorCode) {
            $why = 'the installer exited {0}' -f $InstallResult.InstallerErrorCode
            if ([long]$InstallResult.InstallerErrorCode -eq 3010) {
                $why += ', ERROR_SUCCESS_REBOOT_REQUIRED'
            }
        }
        Write-WarningMessage ('{0} needs a restart to finish installing ({1}).' -f $AppName, $why)
        return $true
    }

    if ($null -ne $exitCode -and $exitCode -ne 0) {
        $logNote = ''
        if ($InstallResult.InstallerLogPath) {
            $logNote = '; installer log: {0}' -f $InstallResult.InstallerLogPath
        }
        $reporter = 'winget'
        if ($clientEngine) {
            $reporter = 'Install-WinGetPackage'
        }
        Write-WarningMessage ('{0} reported {1} for {2}, but it is installed{3}.' -f $reporter, (Format-WingetExitCode -ExitCode $exitCode), $AppName, $logNote)
    }
    return $false
}

function Get-AppDeferReasonText {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$DeferReason
    )

    switch ($DeferReason) {
        'UserScope' { return "per-user app (catalog scope 'user'): it installs only into the signed-in user's own account" }
        'UserPhase' { return "per-user setup (catalog userPhase): it needs the signed-in user's own account" }
    }
    return 'winget found no machine-wide installer for it'
}

function Write-DeferredAppsSummary {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$DeferredApps,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$PerUserApps,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$AccountContext,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Cli', 'WinGetClient')]
        [string]$InstallEngine = 'Cli'
    )

    $noInstallerApps = @($DeferredApps | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $perUserAppIds = @($PerUserApps | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($noInstallerApps.Count -eq 0 -and $perUserAppIds.Count -eq 0) {
        return
    }

    $why = 'this run installs for the whole PC only'
    $account = "the signed-in user's own account"
    $who = 'the signed-in user'
    if ($AccountContext -and $AccountContext.IsSystem) {
        $why = 'a run as SYSTEM installs for the whole PC only'
    }
    elseif ($AccountContext -and $AccountContext.IsCrossUserElevation) {
        $why = "installing per-user here would install for '$($AccountContext.ProcessUser)' instead of '$($AccountContext.SessionUser)'"
        $account = "the account '$($AccountContext.SessionUser)'"
        $who = "'$($AccountContext.SessionUser)'"
    }
    if ($noInstallerApps.Count -gt 0) {
        $pronoun = 'them'
        if ($noInstallerApps.Count -eq 1) {
            $pronoun = 'it'
        }
        $scopeOption = '--scope machine'
        if ($InstallEngine -eq 'WinGetClient') {
            $scopeOption = '-Scope System'
        }
        Write-WarningMessage ('Deferred: {0} - winget found no machine-wide installer for {1} that applies to this PC ({2} with {6}), and {3}. Not installed and not counted as failed. A per-user app can only be installed in {4}: by this installer run as {5} when that account is an administrator, otherwise by a per-user deployment: the user phase (rmm/Invoke-WingetAppSetupUserPhase.ps1, run as the user at sign-in, for example by an Endpoint Central User Configuration script) installs the apps a run deferred, or the Microsoft Store.' -f ($noInstallerApps -join ', '), $pronoun, (Format-WingetExitCode -ExitCode -1978335216), $why, $account, $who, $scopeOption)
    }
    if ($perUserAppIds.Count -gt 0) {
        $subject = 'they'
        $object = 'them'
        if ($perUserAppIds.Count -eq 1) {
            $subject = 'it'
            $object = 'it'
        }
        Write-WarningMessage ("Deferred: {0} - the catalog marks {1} per-user (scope 'user' or userPhase), so {2} can be installed or set up only in {3}, and {4}. Not installed and not counted as failed. This installer run as {5} installs {1} when that account is an administrator; otherwise a per-user deployment does: the user phase (rmm/Invoke-WingetAppSetupUserPhase.ps1, run as the user at sign-in, for example by an Endpoint Central User Configuration script) installs and sets up the apps a run deferred, or the Microsoft Store." -f ($perUserAppIds -join ', '), $object, $subject, $account, $why, $who)
    }
}

function Write-AppPostInstallResult {
    param (
        [Parameter(Mandatory = $true)]
        [string]$AppName,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Configuration
    )

    if ($null -eq $Configuration) {
        return $false
    }
    switch ([string]$Configuration.Status) {
        'Configured' {
            Write-Success "Configured: $AppName"
        }
        'NotConfigured' {
            Write-WarningMessage "Not configured: $AppName ($($Configuration.Reason))"
            return $true
        }
    }
    return $false
}

function Write-NotConfiguredAppsSummary {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [hashtable[]]$NotConfiguredApps
    )

    if (-not $NotConfiguredApps -or $NotConfiguredApps.Count -eq 0) {
        return
    }
    $entries = @($NotConfiguredApps | ForEach-Object { '{0} ({1})' -f $_.Name, $_.Reason })
    Write-WarningMessage ('Configuration: NOT DONE for {0} - installed, but the post-install configuration did not finish. Not counted as failed; re-run the installer once the reason is fixed.' -f ($entries -join '; '))
}

function Write-FailedAppsSummary {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [hashtable[]]$FailedApps,

        [Parameter(Mandatory = $false)]
        [string]$Title = 'Failed Installations'
    )

    if (-not $FailedApps -or $FailedApps.Count -eq 0) {
        return
    }

    $failedRows = @(foreach ($failedApp in $FailedApps) {
            , @([string]$failedApp.Name, [string]$failedApp.Reason)
        })
    Write-Table -Headers @('App', 'Reason') -Rows $failedRows -Title $Title
}

# --- Housekeeping ---
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

function Get-SystemProfileTempRoot {
    return (Get-WindowsDirectoryPath) + '\System32\config\systemprofile\AppData\Local\Temp'
}

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

    if (-not (Test-Path -LiteralPath $LogDirectory -PathType Container) -or (Test-FileSystemLink -Path $LogDirectory)) {
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
        }
    }
    return $removed
}

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
                [System.IO.Directory]::Delete($directory.FullName, $false)
                $removed++
            }
            catch {
            }
        }
    }
    return $removed
}

function Remove-StaleWingetClientFolder {
    [OutputType([int])]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [int]$MaxAgeHours
    )

    if (-not (Test-Path -LiteralPath $Root -PathType Container) -or (Test-FileSystemLink -Path $Root)) {
        return 0
    }
    $cutoffUtc = [DateTime]::UtcNow.AddHours(-$MaxAgeHours)
    $allowedOwnerSids = @('S-1-5-18', 'S-1-5-32-544')
    $removed = 0
    $candidates = @(Get-ChildItem -LiteralPath $Root -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -match '^wingetclient-[0-9a-fA-F]{32}$' -and $_.LastWriteTimeUtc -le $cutoffUtc -and
                -not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
            })
    if ($candidates.Count -eq 0) {
        return 0
    }
    try {
        Assert-RestrictedDirectoryAcl -Path $Root
    }
    catch {
        return 0
    }
    foreach ($directory in $candidates) {
        try {
            $ownerSid = (Get-DirectoryAccessSummary -Path $directory.FullName).OwnerSid
            if ($allowedOwnerSids -notcontains $ownerSid) {
                continue
            }
            [System.IO.Directory]::Delete($directory.FullName, $true)
            $removed++
        }
        catch {
        }
    }
    return $removed
}

# --- InstallVerification ---
function Test-AppApplicability {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$App,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Install', 'Uninstall')]
        [string]$Purpose = 'Install'
    )

    $attempt = 'attempting the install'
    if ($Purpose -eq 'Uninstall') {
        $attempt = 'attempting the uninstall'
    }
    $ErrorActionPreference = 'Stop'

    if ($App.ContainsKey('arch') -and $null -ne $App['arch']) {
        try {
            $architecture = Get-OSArchitecture
            if (@($App['arch']) -notcontains $architecture) {
                return $false
            }
        }
        catch {
            Write-WarningMessage "Architecture check for $($App.name) failed ($($_.Exception.Message)); treating its arch list as met and $attempt."
        }
    }

    if (-not $App.condition) {
        return $true
    }
    try {
        return [bool](& $App.condition)
    }
    catch {
        Write-WarningMessage "Condition for $($App.name) failed to evaluate ($($_.Exception.Message)); treating as applicable and $attempt."
        return $true
    }
}

function Install-AppWithVerification {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$App,

        [Parameter(Mandatory = $false)]
        [bool]$Applicable,

        [Parameter(Mandatory = $false)]
        [switch]$Silent,

        [Parameter(Mandatory = $false)]
        [switch]$WhatIf,

        [Parameter(Mandatory = $false)]
        [switch]$WingetNotLaunchable,

        [Parameter(Mandatory = $false)]
        [switch]$MachineWide,

        [Parameter(Mandatory = $false)]
        [switch]$TimeBudgetSpent,

        [Parameter(Mandatory = $false)]
        [int]$InstallInProgressWaitSeconds
    )

    if ($PSBoundParameters.ContainsKey('Applicable')) {
        $isApplicable = $Applicable
    }
    else {
        $isApplicable = Test-AppApplicability -App $App
    }
    if (-not $isApplicable) {
        return @{ Status = 'Skipped'; InstallResult = $null; FailureReason = $null; SkipReason = 'NotApplicable' }
    }

    $scope = Get-AppInstallScope -App $App
    if ($MachineWide) {
        $perUserReason = Get-AppPerUserDeferReason -App $App
        if ($perUserReason) {
            return @{ Status = 'Deferred'; InstallResult = $null; FailureReason = $null; DeferReason = $perUserReason }
        }
    }

    if ($TimeBudgetSpent) {
        return @{ Status = 'NotAttempted'; InstallResult = $null; FailureReason = $null }
    }

    $checkProvisioning = $MachineWide -and -not [string]::IsNullOrWhiteSpace([string]$App.msixName)
    if ($checkProvisioning) {
        $provisioned = Test-AppxPackageProvisionedForMachine -Name $App.msixName
        if ($provisioned -eq $true) {
            return (Complete-AppPostInstallStep -App $App -Outcome @{ Status = 'Skipped'; InstallResult = $null; FailureReason = $null; SkipReason = 'Provisioned' } -WhatIf:$WhatIf)
        }
        if ($null -eq $provisioned -and -not $WhatIf) {
            return @{ Status = 'Failed'; InstallResult = $null; FailureReason = 'MachineCheckFailed' }
        }
    }

    if ($WingetNotLaunchable) {
        return @{ Status = 'Failed'; InstallResult = $null; FailureReason = 'WingetNotLaunchable'; LaunchError = $null }
    }

    $checkTimeoutSeconds = Get-ProcessTimeoutSeconds -Operation WingetListCheck

    $preCheck = @{ Installed = $false; TimedOut = $false; LaunchFailed = $false; LaunchError = $null; CheckFailed = $false; ExitCode = $null }
    if (-not $checkProvisioning) {
        $preCheck = Test-WingetPackageInstalled -PackageId $App.name -TimeoutSeconds $checkTimeoutSeconds
    }
    if ($preCheck.TimedOut) {
        return @{ Status = 'Failed'; InstallResult = $null; FailureReason = 'PreCheckTimeout' }
    }
    if ($preCheck.LaunchFailed -and -not $WhatIf) {
        return @{ Status = 'Failed'; InstallResult = $null; FailureReason = 'PreCheckLaunchFailed'; LaunchError = $preCheck.LaunchError }
    }
    if ($preCheck.CheckFailed) {
        return @{ Status = 'Failed'; InstallResult = $null; FailureReason = 'PreCheckFailed'; CheckExitCode = $preCheck.ExitCode }
    }
    if ($preCheck.Installed) {
        return (Complete-AppPostInstallStep -App $App -Outcome @{ Status = 'Skipped'; InstallResult = $null; FailureReason = $null } -WhatIf:$WhatIf)
    }

    if ($WhatIf) {
        return (Complete-AppPostInstallStep -App $App -Outcome @{ Status = 'Installed'; InstallResult = $null; FailureReason = $null } -WhatIf)
    }

    Write-Info "Installing: $($App.name)"

    if ($App.install) {
        $customParameters = @{}
        $forwardedValues = @{}
        foreach ($parameterName in @('Silent', 'InstallInProgressWaitSeconds')) {
            if ($PSBoundParameters.ContainsKey($parameterName)) {
                $forwardedValues[$parameterName] = $PSBoundParameters[$parameterName]
            }
        }
        if ($MachineWide -or $scope -eq 'machine') {
            $forwardedValues['MachineScopeOnly'] = $true
        }
        if ($scope -ne 'any') {
            $forwardedValues['Scope'] = $scope
        }
        if ($forwardedValues.Count -gt 0 -and $App.install -is [string]) {
            $customCommand = Get-Command -Name $App.install -ErrorAction SilentlyContinue | Select-Object -First 1
            foreach ($parameterName in $forwardedValues.Keys) {
                if ($customCommand -and $customCommand.Parameters -and $customCommand.Parameters.ContainsKey($parameterName)) {
                    $customParameters[$parameterName] = $forwardedValues[$parameterName]
                }
            }
        }
        $customResult = & $App.install @customParameters
        if ($customResult.Installed) {
            return (Complete-AppPostInstallStep -App $App -Outcome @{ Status = 'Installed'; InstallResult = $customResult; FailureReason = $null })
        }
        if ($customResult.NoMachineScopeInstaller) {
            if ($scope -eq 'machine') {
                return @{ Status = 'Failed'; InstallResult = $customResult; FailureReason = 'NoMachineScopeInstaller' }
            }
            return @{ Status = 'Deferred'; InstallResult = $customResult; FailureReason = $null; DeferReason = 'NoMachineScopeInstaller' }
        }
        $customReason = 'CustomInstallFailed'
        $customLaunchError = $null
        $customCheckExitCode = $null
        if ($customResult.LaunchErrorExhausted) {
            $customReason = 'InstallLaunchFailed'
            $customLaunchError = $customResult.LaunchError
        }
        elseif ($customResult.VerifyLaunchFailed) {
            $customReason = 'VerifyLaunchFailed'
            $customLaunchError = $customResult.VerifyLaunchError
        }
        elseif ($customResult.VerifyTimedOut) {
            $customReason = 'VerifyTimeout'
        }
        elseif ($customResult.VerifyCheckFailed) {
            $customReason = 'VerifyFailed'
            $customCheckExitCode = $customResult.VerifyExitCode
        }
        return @{ Status = 'Failed'; InstallResult = $customResult; FailureReason = $customReason; LaunchError = $customLaunchError; CheckExitCode = $customCheckExitCode }
    }

    $installParameters = @{ PackageId = $App.name; InstallerType = $App.installerType }
    if ($PSBoundParameters.ContainsKey('Silent')) {
        $installParameters['Silent'] = $Silent
    }
    if ($PSBoundParameters.ContainsKey('InstallInProgressWaitSeconds')) {
        $installParameters['InstallInProgressWaitSeconds'] = $InstallInProgressWaitSeconds
    }
    if ($MachineWide) {
        $installParameters['MachineScopeOnly'] = $true
    }
    if ($scope -ne 'any') {
        $installParameters['Scope'] = $scope
    }
    $installResult = Install-WingetPackage @installParameters
    if ($installResult.LaunchErrorExhausted) {
        return @{ Status = 'Failed'; InstallResult = $installResult; FailureReason = 'InstallLaunchFailed'; LaunchError = $installResult.LaunchError }
    }
    if ($installResult.NoMachineScopeInstaller) {
        if ($scope -eq 'machine') {
            return @{ Status = 'Failed'; InstallResult = $installResult; FailureReason = 'NoMachineScopeInstaller' }
        }
        return @{ Status = 'Deferred'; InstallResult = $installResult; FailureReason = $null; DeferReason = 'NoMachineScopeInstaller' }
    }

    if ($checkProvisioning) {
        $provisioned = Test-AppxPackageProvisionedForMachine -Name $App.msixName
        if ($provisioned -eq $true) {
            return (Complete-AppPostInstallStep -App $App -Outcome @{ Status = 'Installed'; InstallResult = $installResult; FailureReason = $null })
        }
        if ($null -eq $provisioned) {
            return @{ Status = 'Failed'; InstallResult = $installResult; FailureReason = 'MachineCheckFailed' }
        }
        return @{ Status = 'Failed'; InstallResult = $installResult; FailureReason = 'VerifyNotFound' }
    }

    $verify = Test-WingetPackageInstalled -PackageId $App.name -TimeoutSeconds $checkTimeoutSeconds
    if ($verify.TimedOut) {
        return @{ Status = 'Failed'; InstallResult = $installResult; FailureReason = 'VerifyTimeout' }
    }
    if ($verify.LaunchFailed) {
        return @{ Status = 'Failed'; InstallResult = $installResult; FailureReason = 'VerifyLaunchFailed'; LaunchError = $verify.LaunchError }
    }
    if ($verify.CheckFailed) {
        return @{ Status = 'Failed'; InstallResult = $installResult; FailureReason = 'VerifyFailed'; CheckExitCode = $verify.ExitCode }
    }
    if ($verify.Installed) {
        return (Complete-AppPostInstallStep -App $App -Outcome @{ Status = 'Installed'; InstallResult = $installResult; FailureReason = $null })
    }
    return @{ Status = 'Failed'; InstallResult = $installResult; FailureReason = 'VerifyNotFound' }
}

function Complete-AppPostInstallStep {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$App,

        [Parameter(Mandatory = $true)]
        [hashtable]$Outcome,

        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    if ($null -eq $App['postInstall']) {
        return $Outcome
    }
    if ($WhatIf) {
        Write-Info "[DRY-RUN] Would run the post-install configuration of $($App.name)."
        return $Outcome
    }
    $configuration = Invoke-AppPostInstall -App $App
    $Outcome['Configuration'] = $configuration
    if ($configuration.Status -eq 'Failed') {
        $Outcome['StatusBeforeHook'] = $Outcome['Status']
        $Outcome['Status'] = 'Failed'
        $Outcome['FailureReason'] = 'PostInstallFailed'
        $Outcome['SkipReason'] = $null
    }
    return $Outcome
}

function Invoke-WingetLaunchCircuitBreaker {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$Outcome
    )

    if (@('PreCheckLaunchFailed', 'InstallLaunchFailed', 'VerifyLaunchFailed') -notcontains $Outcome.FailureReason) {
        return $false
    }

    if (Test-WingetClientEngineActive) {
        Write-WarningMessage 'The WinGet client engine could not be started for that app. Checking whether it can still be started...'
        $engineProbe = Test-WingetClientEngineLaunchable -Attempts 6 -RetryDelaySeconds 15
        if ($engineProbe.Launchable) {
            Write-Info "The WinGet client engine starts again ($($engineProbe.Version)); carrying on with the next app."
            return $false
        }
        Write-ErrorMessage "The WinGet client engine cannot be started on this machine ($($engineProbe.Reason)). The remaining apps are marked failed without an install attempt and are not retried. Restart the machine and re-run the installer; if it persists, attach this transcript to a GitHub issue."
        return $true
    }

    Write-WarningMessage 'winget could not be launched for that app. Checking whether winget can still be started...'
    $probe = Test-WingetLaunchable -Attempts 6 -RetryDelaySeconds 15
    if ($probe.Launchable) {
        Write-Info "winget starts again ($($probe.Version)); carrying on with the next app."
        return $false
    }

    Write-ErrorMessage "winget cannot be launched on this machine ($($probe.Reason)). The remaining apps are marked failed without an install attempt and are not retried. Restart the machine and re-run the installer; if it persists, attach this transcript to a GitHub issue."
    return $true
}

# --- Interactivity ---
function Test-EffectiveNonInteractive {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive
    )

    if (Test-NonInteractiveRequested -NonInteractive:$NonInteractive) {
        return $true
    }
    if (Test-IsSystemAccount) {
        return $true
    }
    if (-not [Environment]::UserInteractive) {
        return $true
    }
    try {
        return [System.Console]::IsInputRedirected
    }
    catch {
        return $true
    }
}

function Test-PowerShellHostNonInteractive {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$CommandLineArgs = [Environment]::GetCommandLineArgs()
    )

    foreach ($argument in @($CommandLineArgs | Select-Object -Skip 1)) {
        if ($argument -match '^(?:--?|/)(?<name>[A-Za-z]+)$') {
            $name = $Matches['name']
            if ($name.Length -ge 4 -and 'noninteractive'.StartsWith($name, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }
    }
    return $false
}

function Test-NonInteractiveRequested {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive
    )

    if ($NonInteractive) {
        return $true
    }
    $requested = ([string]$env:WINGET_APP_SETUP_NONINTERACTIVE).Trim()
    return (@('1', 'true', 'yes') -contains $requested)
}

function Test-IsContinuousIntegration {
    if ($env:CI -and $env:CI -ne 'false' -and $env:CI -ne '0') {
        return $true
    }
    if ($env:GITHUB_ACTIONS -eq 'true' -or $env:TF_BUILD -eq 'True') {
        return $true
    }
    return $false
}

# --- Jsonc ---
function Convert-JsoncToJson {
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$JsonText
    )

    $length = $JsonText.Length
    $withoutComments = [System.Text.StringBuilder]::new($length)
    $inString = $false
    $i = 0

    while ($i -lt $length) {
        $currentChar = $JsonText[$i]

        if ($inString) {
            [void]$withoutComments.Append($currentChar)
            if ($currentChar -eq '\') {
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
                $i += 2
                while ($i -lt $length -and $JsonText[$i] -ne "`r" -and $JsonText[$i] -ne "`n") {
                    $i++
                }
                continue
            }
            if ($nextChar -eq '*') {
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
                $i++
                continue
            }
        }

        [void]$sanitized.Append($currentChar)
        $i++
    }

    return $sanitized.ToString()
}

function ConvertFrom-TerminalSettingsJson {
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$JsonText
    )

    if ([string]::IsNullOrWhiteSpace($JsonText)) {
        return [pscustomobject]@{}
    }

    try {
        return $JsonText | ConvertFrom-Json
    }
    catch {
        $sanitizedJson = Convert-JsoncToJson -JsonText $JsonText

        try {
            return $sanitizedJson | ConvertFrom-Json
        }
        catch {
            return $null
        }
    }
}

function Get-JsoncToken {
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$JsonText
    )

    $tokens = New-Object System.Collections.Generic.List[object]
    $length = $JsonText.Length
    $depth = 0
    $i = 0

    while ($i -lt $length) {
        $currentChar = $JsonText[$i]

        if ([char]::IsWhiteSpace($currentChar)) {
            $i++
            continue
        }

        if ($currentChar -eq '/' -and $i + 1 -lt $length -and $JsonText[$i + 1] -eq '/') {
            $i += 2
            while ($i -lt $length -and $JsonText[$i] -ne "`r" -and $JsonText[$i] -ne "`n") {
                $i++
            }
            continue
        }

        if ($currentChar -eq '/' -and $i + 1 -lt $length -and $JsonText[$i + 1] -eq '*') {
            $i += 2
            while ($i + 1 -lt $length -and -not ($JsonText[$i] -eq '*' -and $JsonText[$i + 1] -eq '/')) {
                $i++
            }
            $i = [System.Math]::Min($i + 2, $length)
            continue
        }

        $start = $i
        $tokenDepth = $depth
        if ($currentChar -eq '"') {
            $kind = 'String'
            $i++
            while ($i -lt $length -and $JsonText[$i] -ne '"') {
                if ($JsonText[$i] -eq '\') {
                    $i++
                }
                $i++
            }
            $i = [System.Math]::Min($i + 1, $length)
        }
        elseif ('{['.IndexOf($currentChar) -ge 0) {
            $kind = [string]$currentChar
            $depth++
            $i++
        }
        elseif ('}]'.IndexOf($currentChar) -ge 0) {
            $kind = [string]$currentChar
            $depth--
            $tokenDepth = $depth
            $i++
        }
        elseif (':,'.IndexOf($currentChar) -ge 0) {
            $kind = [string]$currentChar
            $i++
        }
        else {
            $kind = 'Literal'
            while ($i -lt $length -and -not [char]::IsWhiteSpace($JsonText[$i]) -and '{}[]:,"/'.IndexOf($JsonText[$i]) -lt 0) {
                $i++
            }
            if ($i -eq $start) {
                $i++
            }
        }

        $tokens.Add([pscustomobject]@{ Kind = $kind; Start = $start; End = $i; Depth = $tokenDepth })
    }

    return , $tokens.ToArray()
}

function Set-JsoncTopLevelStringProperty {
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$JsonText,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $quotedValue = '"' + $Value.Replace('\', '\\').Replace('"', '\"') + '"'
    $member = '"' + $Name + '": ' + $quotedValue
    $newLine = if ($JsonText.Contains("`r`n")) { "`r`n" } else { "`n" }
    $tokens = Get-JsoncToken -JsonText $JsonText

    if ($tokens.Count -eq 0) {
        $separator = if ($JsonText.Length -gt 0 -and $JsonText[$JsonText.Length - 1] -ne "`n") { $newLine } else { '' }
        return $JsonText + $separator + '{' + $newLine + '    ' + $member + $newLine + '}' + $newLine
    }

    if ($tokens[0].Kind -ne '{') {
        return $null
    }

    $firstKey = $null
    $valueTokens = @()
    for ($t = 1; $t -lt $tokens.Count; $t++) {
        $token = $tokens[$t]
        if ($token.Depth -eq 0) {
            break
        }
        $isTopLevelKey = $token.Depth -eq 1 -and $token.Kind -eq 'String' -and
            $t + 1 -lt $tokens.Count -and $tokens[$t + 1].Kind -eq ':'
        if (-not $isTopLevelKey) {
            continue
        }
        if ($null -eq $firstKey) {
            $firstKey = $token
        }
        if ($JsonText.Substring($token.Start + 1, $token.End - $token.Start - 2) -cne $Name) {
            continue
        }
        if ($t + 2 -ge $tokens.Count -or ($tokens[$t + 2].Kind -ne 'String' -and $tokens[$t + 2].Kind -ne 'Literal')) {
            return $null
        }
        $valueTokens += $tokens[$t + 2]
    }

    if ($valueTokens.Count -gt 0) {
        $builder = [System.Text.StringBuilder]::new($JsonText)
        for ($v = $valueTokens.Count - 1; $v -ge 0; $v--) {
            [void]$builder.Remove($valueTokens[$v].Start, $valueTokens[$v].End - $valueTokens[$v].Start)
            [void]$builder.Insert($valueTokens[$v].Start, $quotedValue)
        }
        return $builder.ToString()
    }

    if ($null -eq $firstKey) {
        return $JsonText.Insert($tokens[0].End, ' ' + $member + ' ')
    }

    $lineStart = $JsonText.LastIndexOf([char]10, $firstKey.Start - 1) + 1
    $indent = $JsonText.Substring($lineStart, $firstKey.Start - $lineStart)
    $insertion = if ([string]::IsNullOrWhiteSpace($indent)) {
        $member + ',' + $newLine + $indent
    }
    else {
        $member + ', '
    }
    return $JsonText.Insert($firstKey.Start, $insertion)
}

# --- LoggingInternal ---
function Write-Prompt {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message
    )
    Write-Host $Message -ForegroundColor Blue
}

function Start-InstallerTranscript {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf,
        [Parameter(Mandatory = $false)]
        [switch]$Bootstrap,
        [Parameter(Mandatory = $false)]
        [switch]$UserPhase
    )

    $phaseSuffix = ''
    if ($Bootstrap) {
        $phaseSuffix = '-bootstrap'
    }
    elseif ($UserPhase) {
        $phaseSuffix = '-userphase'
    }
    $whatIfSuffix = ''
    if ($WhatIf) {
        $whatIfSuffix = '-whatif'
    }
    try {
        if (-not $UserPhase -and (Test-IsAdmin)) {
            $logDirectory = Initialize-ProgramDataFolder -ChildName 'logs' -ReadableByUsers
        }
        else {
            if ($UserPhase) {
                $logDirectory = Join-Path $env:LOCALAPPDATA 'winget-app-setup\logs'
            }
            else {
                $logDirectory = Join-Path $env:ProgramData 'winget-app-setup\logs'
            }
            if (-not (Test-Path -LiteralPath $logDirectory)) {
                [void](New-Item -Path $logDirectory -ItemType Directory -Force -ErrorAction Stop)
            }
        }
        $logPath = Join-Path $logDirectory ('install-{0:yyyyMMdd-HHmmss}{1}{2}.log' -f (Get-Date), $phaseSuffix, $whatIfSuffix)
        [void](Start-Transcript -Path $logPath -ErrorAction Stop)
    }
    catch {
        $resetHint = ''
        if ($_.FullyQualifiedErrorId -eq 'RestrictedDirectoryAclFailed' -and $_.TargetObject) {
            $resetHint = Get-RestrictedDirectoryResetHint -Path ([string]$_.TargetObject)
        }
        Write-WarningMessage "Transcript logging could not be started: $_. Continuing without a log file.$resetHint"
        return $null
    }
    return $logPath
}

# --- MachineContext ---
function Get-DesktopAppInstallerPackageInfo {
    $query = "Get-AppxPackage -AllUsers -Name 'Microsoft.DesktopAppInstaller' -ErrorAction Stop | ForEach-Object { '{0}|{1}|{2}|{3}' -f `$_.Version, `$_.Architecture, `$_.Status, `$_.InstallLocation }"
    if ($PSVersionTable.PSEdition -eq 'Core') {
        $lines = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $query)
        if ($LASTEXITCODE -ne 0) {
            throw "Get-AppxPackage -AllUsers failed in Windows PowerShell (exit code $LASTEXITCODE)."
        }
    }
    else {
        $lines = @(Get-AppxPackage -AllUsers -Name 'Microsoft.DesktopAppInstaller' -ErrorAction Stop |
                ForEach-Object { '{0}|{1}|{2}|{3}' -f $_.Version, $_.Architecture, $_.Status, $_.InstallLocation })
    }

    foreach ($line in $lines) {
        $parts = "$line".Trim() -split '\|'
        $parsedVersion = $null
        if ($parts.Count -eq 4 -and [version]::TryParse($parts[0], [ref]$parsedVersion)) {
            [pscustomobject]@{
                Version         = $parsedVersion
                Architecture    = $parts[1]
                Status          = $parts[2]
                InstallLocation = $parts[3]
            }
        }
    }
}

function Get-WindowsAppsDirectory {
    $programFiles = $env:ProgramW6432
    if ([string]::IsNullOrWhiteSpace($programFiles)) {
        $programFiles = $env:ProgramFiles
    }
    if ([string]::IsNullOrWhiteSpace($programFiles)) {
        return $null
    }
    return (Join-Path $programFiles 'WindowsApps')
}

function Get-MachineWingetCandidate {
    param (
        [Parameter(Mandatory = $false)]
        [string]$ProcessorArchitecture
    )

    if ([string]::IsNullOrWhiteSpace($ProcessorArchitecture)) {
        $ProcessorArchitecture = $env:PROCESSOR_ARCHITEW6432
        if ([string]::IsNullOrWhiteSpace($ProcessorArchitecture)) {
            $ProcessorArchitecture = $env:PROCESSOR_ARCHITECTURE
        }
    }
    $preference = @('x64', 'x86')
    if ("$ProcessorArchitecture" -eq 'ARM64') {
        $preference = @('arm64', 'x64', 'x86')
    }
    elseif ("$ProcessorArchitecture" -eq 'x86') {
        $preference = @('x86')
    }

    $found = @()
    $rejected = @()
    try {
        foreach ($package in @(Get-DesktopAppInstallerPackageInfo)) {
            if ("$($package.Status)" -ne 'Ok') {
                $rejected += ('{0}_{1}' -f $package.Version, "$($package.Architecture)".ToLowerInvariant())
                continue
            }
            if ([string]::IsNullOrWhiteSpace($package.InstallLocation)) {
                continue
            }
            $path = Join-Path $package.InstallLocation 'winget.exe'
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                $found += [pscustomobject]@{ Path = $path; Version = $package.Version; Architecture = "$($package.Architecture)".ToLowerInvariant(); Source = 'Get-AppxPackage -AllUsers' }
            }
        }
    }
    catch {
        Write-WarningMessage "Could not list App Installer for all accounts ($_); looking for winget.exe under WindowsApps instead."
    }

    if ($found.Count -eq 0) {
        $windowsApps = Get-WindowsAppsDirectory
        if ($windowsApps) {
            try {
                $folders = @(Get-ChildItem -LiteralPath $windowsApps -Directory -Filter 'Microsoft.DesktopAppInstaller_*' -ErrorAction Stop)
                foreach ($folder in $folders) {
                    if ($folder.Name -notmatch '^Microsoft\.DesktopAppInstaller_(?<version>\d+(\.\d+){1,3})_(?<architecture>x64|arm64|x86)__8wekyb3d8bbwe$') {
                        continue
                    }
                    if ($rejected -contains ('{0}_{1}' -f ([version]$Matches['version']), $Matches['architecture'].ToLowerInvariant())) {
                        continue
                    }
                    $path = Join-Path $folder.FullName 'winget.exe'
                    if (Test-Path -LiteralPath $path -PathType Leaf) {
                        $found += [pscustomobject]@{ Path = $path; Version = [version]$Matches['version']; Architecture = $Matches['architecture'].ToLowerInvariant(); Source = 'WindowsApps' }
                    }
                }
            }
            catch {
                Write-WarningMessage "Could not look for winget.exe under ${windowsApps}: $_"
            }
        }
    }

    $ranked = @(foreach ($candidate in $found) {
            $rank = [array]::IndexOf($preference, $candidate.Architecture)
            if ($rank -ge 0) {
                $candidate | Add-Member -NotePropertyName Rank -NotePropertyValue $rank -PassThru
            }
        })
    return @($ranked | Sort-Object -Property @{ Expression = 'Rank'; Ascending = $true }, @{ Expression = 'Version'; Descending = $true } |
            Select-Object -Property Path, Version, Architecture, Source)
}

function Test-MachineWingetAvailable {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf,

        [Parameter(Mandatory = $false)]
        [switch]$NotRequired
    )

    $script:MachineWingetPath = $null
    $candidates = @(Get-MachineWingetCandidate)
    if ($candidates.Count -eq 0) {
        $windowsApps = Get-WindowsAppsDirectory
        if (-not $windowsApps) {
            $windowsApps = '%ProgramFiles%\WindowsApps'
        }
        $message = "No machine-wide winget was found: as SYSTEM the installer runs the winget.exe of the App Installer package (Microsoft.DesktopAppInstaller) installed for this PC, and Get-AppxPackage -AllUsers lists none with status Ok, nor is there one under $windowsApps. SYSTEM cannot set winget up for itself, so the per-account steps (registering App Installer, Repair-WinGetPackageManager) do not apply. Install or update App Installer for this PC, then re-run the installer."
        if ($NotRequired) {
            Write-WarningMessage "No machine-wide winget was found: Get-AppxPackage -AllUsers lists no App Installer package (Microsoft.DesktopAppInstaller) for this PC with status Ok, nor is there one under $windowsApps. Winget-AutoUpdate needs that winget.exe; install or update App Installer for this PC."
        }
        elseif ($WhatIf) {
            Write-Info "[DRY-RUN] $message A real run would stop here with exit code 2."
        }
        else {
            Write-ErrorMessage $message
        }
        return $false
    }

    $probe = $null
    $tried = 0
    foreach ($candidate in $candidates) {
        $script:MachineWingetPath = $candidate.Path
        if ($tried -eq 0) {
            $probe = Test-WingetLaunchable -Attempts 6 -RetryDelaySeconds 15
        }
        else {
            $probe = Test-WingetLaunchable -Attempts 2 -RetryDelaySeconds 5
        }
        $tried++
        if ($probe.Launchable) {
            Write-Success ('Winget is available ({0}): {1} (App Installer for this PC, {2}).' -f $probe.Version, $candidate.Path, $candidate.Version)
            return $true
        }
        Write-WarningMessage ('{0} could not be used: {1}.' -f $candidate.Path, $probe.Reason)
    }

    $script:MachineWingetPath = $null
    $hint = ''
    if ("$($probe.Reason)" -match '0xC0000135') {
        $hint = ' winget.exe could not load a DLL it needs: when it runs outside its package, as it does for SYSTEM, a missing Microsoft Visual C++ 2015-2022 runtime is a reported cause.'
    }
    $wingetWord = 'winget.exe'
    if ($tried -gt 1) {
        $wingetWord = "$tried winget.exe files"
    }
    $message = "winget could not be started as SYSTEM (tried the machine-wide $wingetWord above).$hint The per-account steps a signed-in user's run would try (registering App Installer, Repair-WinGetPackageManager) do not apply to SYSTEM and were skipped."
    if ($NotRequired) {
        Write-WarningMessage "The machine-wide winget.exe could not be started as SYSTEM (tried $wingetWord above).$hint Winget-AutoUpdate needs it; repair or update App Installer for this PC."
    }
    elseif ($WhatIf) {
        Write-Info "[DRY-RUN] $message A real run would stop here with exit code 2."
    }
    else {
        Write-ErrorMessage $message
    }
    return $false
}

function Get-ProvisionedAppxPackageName {
    $query = 'Get-AppxProvisionedPackage -Online -ErrorAction Stop | ForEach-Object { $_.DisplayName }'
    if ($PSVersionTable.PSEdition -eq 'Core') {
        $lines = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $query)
        if ($LASTEXITCODE -ne 0) {
            throw "Get-AppxProvisionedPackage failed in Windows PowerShell (exit code $LASTEXITCODE)."
        }
    }
    else {
        $lines = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop | ForEach-Object { $_.DisplayName })
    }
    foreach ($line in $lines) {
        $name = "$line".Trim()
        if ($name.Length -gt 0) {
            $name
        }
    }
}

function Test-AppxPackageProvisionedForMachine {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    try {
        $names = @(Get-ProvisionedAppxPackageName)
    }
    catch {
        Write-WarningMessage "Could not read the apps provisioned for every user on this PC: $_"
        return $null
    }
    return [bool](@($names | Where-Object { $_ -eq $Name }).Count -gt 0)
}

# --- PackageIdValidation ---
$script:WingetPackageIdPattern = '^[\w][\w.\-]+\.[\w][\w.\-]+\z'

function Test-WingetPackageIdFormat {
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$PackageId
    )

    return $PackageId -match $script:WingetPackageIdPattern
}

function Test-WingetListOutputContainsPackageId {
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Output,

        [Parameter(Mandatory = $true)]
        [string]$PackageId
    )

    $escapedId = [regex]::Escape($PackageId)
    $boundaryPattern = "(?<![\w.\-])$escapedId(?![\w.\-])"
    return [regex]::IsMatch($Output, $boundaryPattern)
}

# --- PowerShell7Bootstrap ---
function Test-PowerShell7Executable {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    try {
        $majorVersion = & $Path -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.Major' 2>$null
        return ([int]($majorVersion | Select-Object -Last 1) -ge 7)
    }
    catch {
        return $false
    }
}

function Find-PowerShell7 {
    $candidatePaths = @()
    $pwshCommand = Get-Command -Name 'pwsh.exe' -CommandType Application -ErrorAction SilentlyContinue
    if ($pwshCommand) {
        $candidatePaths += ($pwshCommand | Select-Object -First 1).Source
    }
    if ($env:ProgramFiles) {
        $candidatePaths += (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe')
    }
    if ($env:ProgramW6432) {
        $candidatePaths += (Join-Path $env:ProgramW6432 'PowerShell\7\pwsh.exe')
    }
    if ($env:LOCALAPPDATA) {
        $candidatePaths += (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe')
    }
    foreach ($candidate in $candidatePaths) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            continue
        }
        if (Test-PowerShell7Executable -Path $candidate) {
            return $candidate
        }
    }
    return $null
}

function Test-GitHubRateLimitError {
    param (
        [Parameter(Mandatory = $true)]
        $ErrorRecord
    )
    return ($ErrorRecord.ToString() -match '429|Too Many Requests')
}

function Get-PowerShell7MsiInfo {
    param (
        [Parameter(Mandatory = $false)]
        [string]$MetadataUrl = 'https://raw.githubusercontent.com/PowerShell/PowerShell/master/tools/metadata.json',
        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 30
    )

    $architectureName = $env:PROCESSOR_ARCHITEW6432
    if (-not $architectureName) {
        $architectureName = $env:PROCESSOR_ARCHITECTURE
    }
    $architecture = $null
    switch ($architectureName) {
        'AMD64' { $architecture = 'x64' }
        'ARM64' { $architecture = 'arm64' }
        'x86' { $architecture = 'x86' }
    }
    if (-not $architecture) {
        Write-WarningMessage ("Unrecognized processor architecture '{0}'; cannot pick a PowerShell 7 MSI." -f $architectureName)
        return $null
    }

    $currentTag = ''
    $ltsTags = @()
    try {
        $metadata = Invoke-RestMethod -Uri $MetadataUrl -TimeoutSec $TimeoutSeconds
        if ($metadata) {
            $currentTag = [string]$metadata.ReleaseTag
            $ltsTags = @($metadata.LTSReleaseTag | Where-Object { $_ })
        }
    }
    catch {
        Write-WarningMessage "Could not read the PowerShell release metadata: $_"
        if (Test-GitHubRateLimitError -ErrorRecord $_) {
            $script:PowerShell7BootstrapGitHubThrottled = $true
        }
        return $null
    }

    $firstVersionWithoutMsi = [version]'7.7.0'
    $releaseTag = $null
    $releaseVersion = $null
    foreach ($candidateTag in (@($currentTag) + $ltsTags)) {
        if ([string]$candidateTag -match '^v?(\d+\.\d+\.\d+)$') {
            $candidateVersion = [version]$Matches[1]
            if ($candidateVersion -lt $firstVersionWithoutMsi -and (-not $releaseVersion -or $candidateVersion -gt $releaseVersion)) {
                $releaseTag = [string]$candidateTag
                $releaseVersion = $candidateVersion
            }
        }
    }
    if (-not $releaseTag) {
        Write-WarningMessage ('The PowerShell release metadata lists no release that ships an MSI installer (current release: {0}; LTS releases: {1}). PowerShell 7.7 and later ship none.' -f $currentTag, ($ltsTags -join ', '))
        return $null
    }

    $version = ($releaseTag -replace '^v', '')
    if ($currentTag -and $releaseTag -ne $currentTag) {
        Write-Info ('PowerShell {0}, the current release, ships no MSI installer, so this installs PowerShell {1} (LTS) instead. The installer runs on any PowerShell 7.' -f ($currentTag -replace '^v', ''), $version)
    }
    $fileName = 'PowerShell-' + $version + '-win-' + $architecture + '.msi'
    return @{
        Version  = $version
        FileName = $fileName
        Url      = 'https://github.com/PowerShell/PowerShell/releases/download/v' + $version + '/' + $fileName
    }
}

function Save-WebFileWithTimeout {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Uri,
        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,
        [Parameter(Mandatory = $false)]
        [int]$StallTimeoutSeconds = 60,
        [Parameter(Mandatory = $false)]
        [int]$MaximumSeconds = 900,
        [Parameter(Mandatory = $false)]
        [int]$ProgressIntervalSeconds = 10
    )

    $response = $null
    $responseStream = $null
    $fileStream = $null
    try {
        $request = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create($Uri)
        $request.Method = 'GET'
        $request.Timeout = $StallTimeoutSeconds * 1000
        $request.ReadWriteTimeout = $StallTimeoutSeconds * 1000
        $request.UserAgent = 'winget-app-setup'
        if ($request.Proxy) {
            $request.Proxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials
        }

        $response = $request.GetResponse()
        $totalBytes = $response.ContentLength
        $totalText = 'unknown size'
        if ($totalBytes -gt 0) {
            $totalText = ('{0:N1} MB' -f ($totalBytes / 1MB))
        }
        Write-Info ('  Downloading {0}...' -f $totalText)

        $responseStream = $response.GetResponseStream()
        $fileStream = New-Object System.IO.FileStream($DestinationPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
        $buffer = New-Object byte[] 131072
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $lastReportSeconds = 0
        $bytesReceived = 0

        while ($true) {
            $count = $responseStream.Read($buffer, 0, $buffer.Length)
            if ($count -le 0) {
                break
            }
            $fileStream.Write($buffer, 0, $count)
            $bytesReceived = $bytesReceived + $count

            $elapsedSeconds = $stopwatch.Elapsed.TotalSeconds
            if ($elapsedSeconds -gt $MaximumSeconds) {
                throw ('the download exceeded the {0}-second limit after {1:N1} MB' -f $MaximumSeconds, ($bytesReceived / 1MB))
            }
            if (($elapsedSeconds - $lastReportSeconds) -ge $ProgressIntervalSeconds) {
                $lastReportSeconds = $elapsedSeconds
                if ($totalBytes -gt 0) {
                    Write-Info ('  {0:N1} MB of {1:N1} MB ({2:N0}%)' -f ($bytesReceived / 1MB), ($totalBytes / 1MB), (($bytesReceived / $totalBytes) * 100))
                }
                else {
                    Write-Info ('  {0:N1} MB downloaded' -f ($bytesReceived / 1MB))
                }
            }
        }

        $fileStream.Close()
        $fileStream = $null
        if ($totalBytes -gt 0 -and $bytesReceived -ne $totalBytes) {
            Write-WarningMessage ('The download ended early: got {0:N1} MB of {1:N1} MB.' -f ($bytesReceived / 1MB), ($totalBytes / 1MB))
            return $false
        }
        Write-Info ('  Downloaded {0:N1} MB in {1:N0}s.' -f ($bytesReceived / 1MB), $stopwatch.Elapsed.TotalSeconds)
        return $true
    }
    catch {
        Write-WarningMessage "The download failed: $_"
        return $false
    }
    finally {
        if ($fileStream) { try { $fileStream.Close() } catch { } }
        if ($responseStream) { try { $responseStream.Close() } catch { } }
        if ($response) { try { $response.Close() } catch { } }
    }
}

function Test-PowerShell7MsiSignature {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    try {
        $signature = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
    }
    catch {
        Write-WarningMessage "Could not check the signature of the downloaded PowerShell MSI, so it was not installed: $_"
        return $false
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
    if ($status -eq 'Valid' -and $signer -match '(^|,\s*)CN=Microsoft Corporation(\s*,|$)') {
        Write-Info ('  Signature verified: {0}' -f $signer)
        return $true
    }
    Write-WarningMessage ('The downloaded file is not a PowerShell installer signed by Microsoft (signature status: {0}; signer: {1}), so it was not installed. A proxy or captive portal may have answered with a web page instead of the MSI, or the file was altered on the way.' -f $status, $signer)
    return $false
}

function Install-PowerShell7FromMsi {
    param (
        [Parameter(Mandatory = $false)]
        [string]$MetadataUrl = 'https://raw.githubusercontent.com/PowerShell/PowerShell/master/tools/metadata.json',
        [Parameter(Mandatory = $false)]
        [int]$DownloadTimeoutSeconds = 3600,
        [Parameter(Mandatory = $false)]
        [int]$InstallTimeoutSeconds = 900,
        [Parameter(Mandatory = $false)]
        [string]$MsiLogDirectory,
        [Parameter(Mandatory = $false)]
        [int]$BusyRetryCount = 6,
        [Parameter(Mandatory = $false)]
        [int]$BusyRetryDelaySeconds = 30
    )

    $msiInfo = Get-PowerShell7MsiInfo -MetadataUrl $MetadataUrl
    if (-not $msiInfo) {
        return $false
    }

    $downloadDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('winget-app-setup-pwsh-' + [System.Guid]::NewGuid().ToString('N'))
    $msiPath = Join-Path $downloadDirectory $msiInfo.FileName
    try {
        [void](New-Item -Path $downloadDirectory -ItemType Directory -Force -ErrorAction Stop)
    }
    catch {
        Write-WarningMessage "Could not create a temporary directory for the PowerShell 7 MSI: $_"
        return $false
    }

    try {
        Write-Info ('Downloading PowerShell {0} ({1})...' -f $msiInfo.Version, $msiInfo.FileName)
        if (-not (Save-WebFileWithTimeout -Uri $msiInfo.Url -DestinationPath $msiPath -MaximumSeconds $DownloadTimeoutSeconds)) {
            return $false
        }
        if (-not (Test-PowerShell7MsiSignature -Path $msiPath)) {
            return $false
        }

        Write-Info 'Installing PowerShell 7 (this takes about a minute)...'
        $attempt = 0
        while ($true) {
            $attempt = $attempt + 1
            $msiArguments = @('/i', ('"' + $msiPath + '"'), '/quiet', '/norestart')
            $msiLogPath = $null
            if ($MsiLogDirectory) {
                $msiLogPath = Join-Path $MsiLogDirectory ('pwsh-msi-{0:yyyyMMdd-HHmmss}-{1}.log' -f (Get-Date), $attempt)
                $msiArguments += @('/l*v', ('"' + $msiLogPath + '"'))
                Write-Info ('  msiexec log: {0}' -f $msiLogPath)
            }

            $msiProcess = $null
            try {
                $msiProcess = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArguments -PassThru -ErrorAction Stop
            }
            catch {
                Write-WarningMessage "msiexec could not be started: $_"
                return $false
            }
            if (-not $msiProcess) {
                Write-WarningMessage 'msiexec could not be started.'
                return $false
            }

            if (-not $msiProcess.WaitForExit($InstallTimeoutSeconds * 1000)) {
                try { $msiProcess.Kill() } catch { }
                Write-WarningMessage ('The PowerShell 7 MSI install did not finish within {0} seconds and was stopped.' -f $InstallTimeoutSeconds)
                return $false
            }

            $msiExitCode = $msiProcess.ExitCode
            if ($msiExitCode -eq 3010) {
                $script:PowerShell7BootstrapRestartRequired = $true
                Write-WarningMessage 'PowerShell 7 is installed, and a restart finishes the installation (msiexec exit code 3010). The run continues; restart this PC once it has finished.'
                return $true
            }
            if ($msiExitCode -eq 0) {
                return $true
            }
            if ($msiExitCode -eq 1618 -and $attempt -le $BusyRetryCount) {
                Write-WarningMessage ('Windows Installer is busy with another installation (msiexec exit code 1618). Waiting {0} seconds before trying again (retry {1} of {2})...' -f $BusyRetryDelaySeconds, $attempt, $BusyRetryCount)
                Start-Sleep -Seconds $BusyRetryDelaySeconds
                continue
            }
            if ($msiExitCode -eq 1618) {
                Write-WarningMessage ('The PowerShell 7 MSI install failed: Windows Installer was still busy with another installation after {0} retries (msiexec exit code 1618). Re-run the installer once that installation has finished.' -f $BusyRetryCount)
            }
            else {
                Write-WarningMessage ('The PowerShell 7 MSI install failed (msiexec exit code {0}).' -f $msiExitCode)
            }
            if ($msiLogPath) {
                Write-WarningMessage ('msiexec''s log of the failed attempt: {0}' -f $msiLogPath)
            }
            return $false
        }
    }
    finally {
        Remove-Item -LiteralPath $downloadDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-InstallerBuildIdFromText {
    param (
        [Parameter(Mandatory = $false)]
        [string]$Text
    )

    if (-not $Text) {
        return $null
    }
    $match = [regex]::Match($Text, '(?m)^\$script:InstallerBuildId = ''([^'']+)''')
    if ($match.Success) {
        return $match.Groups[1].Value
    }
    return $null
}

function Get-PowerShell7RelaunchInstaller {
    param (
        [Parameter(Mandatory = $true)]
        [string[]]$Url,
        [Parameter(Mandatory = $false)]
        [string]$ExpectedBuildId,
        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 60
    )

    foreach ($candidateUrl in $Url) {
        Write-Info ('Downloading the installer for the PowerShell 7 relaunch from {0}...' -f $candidateUrl)
        $installerText = $null
        try {
            $installerText = [string](Invoke-RestMethod -Uri $candidateUrl -TimeoutSec $TimeoutSeconds)
        }
        catch {
            Write-WarningMessage ('  The download failed: {0}' -f $_)
            continue
        }
        $downloadedBuildId = Get-InstallerBuildIdFromText -Text $installerText
        if (-not $downloadedBuildId) {
            Write-WarningMessage '  That download is not the installer: it carries no installer build id.'
            continue
        }
        if ($ExpectedBuildId -and $downloadedBuildId -ne $ExpectedBuildId) {
            Write-WarningMessage ('  That is installer build {0}, not build {1} that this run started with, so it is not used.' -f $downloadedBuildId, $ExpectedBuildId)
            continue
        }
        return $installerText
    }
    return $null
}

function Invoke-PowerShell7Bootstrap {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf,
        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive,
        [Parameter(Mandatory = $false)]
        [switch]$SkipSystemCheck,
        [Parameter(Mandatory = $false)]
        [string]$CommandPath,
        [Parameter(Mandatory = $false)]
        [string[]]$InstallerUrl = @(
            'https://raw.githubusercontent.com/J-MaFf/winget-app-setup/refs/heads/main/winget-app-install.ps1',
            'https://cdn.jsdelivr.net/gh/J-MaFf/winget-app-setup@main/winget-app-install.ps1'
        ),
        [Parameter(Mandatory = $false)]
        [string]$ExpectedBuildId,
        [Parameter(Mandatory = $false)]
        [string]$LogDirectory,
        [Parameter(Mandatory = $false)]
        [ValidatePattern('^(?:-[A-Za-z][A-Za-z0-9]*|[0-9][0-9A-Za-z:.-]*)\z')]
        [string[]]$AdditionalArguments = @()
    )

    $script:PowerShell7BootstrapRelaunched = $false

    Write-WarningMessage 'This installer requires PowerShell 7+ (pwsh), but this session is Windows PowerShell. Handing off...'

    if ($env:WINGET_APP_SETUP_PS7_BOOTSTRAP -eq '1') {
        Write-ErrorMessage 'The PowerShell 7 bootstrap re-entered itself after a relaunch: the relaunched PowerShell still reports a version below 7. Install PowerShell 7 manually (winget install Microsoft.PowerShell) and re-run this installer from a pwsh prompt.'
        return 7
    }

    $relaunchPolicyBlock = Get-ScriptExecutionPolicyBlock -Engine PowerShell7
    if ($relaunchPolicyBlock) {
        $policyMessage = '{0}, which -ExecutionPolicy Bypass on the command line cannot override, so PowerShell 7 cannot run this installer from a file, and the run cannot continue in PowerShell 7. Ask whoever manages this PC''s policies to allow scripts ({1}), then re-run the installer.' -f $relaunchPolicyBlock.Description, $relaunchPolicyBlock.GroupPolicyPath
        if ($WhatIf) {
            Write-Info "[DRY-RUN] $policyMessage A real run would stop here with exit code 7."
            return 0
        }
        Write-ErrorMessage "$policyMessage Nothing was installed."
        return 7
    }

    $script:PowerShell7BootstrapGitHubThrottled = $false
    $script:PowerShell7BootstrapRestartRequired = $false

    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    }
    catch {
    }

    $pwshPath = Find-PowerShell7

    if (-not $pwshPath) {
        if ($WhatIf) {
            Write-Info '[DRY-RUN] PowerShell 7 is not installed. A real run would install it (winget install Microsoft.PowerShell, with an MSI fallback) and relaunch this installer under pwsh. Run from a pwsh prompt for the full preview.'
            return 0
        }

        Write-Info 'PowerShell 7 (pwsh) is required but not installed. Installing it now...'

        $isAdmin = Test-IsAdmin
        if (-not $isAdmin) {
            Write-WarningMessage 'Not running as administrator: the PowerShell 7 install may show a UAC prompt or fail. If it fails, re-run this installer from an elevated prompt.'
        }

        $wingetCommand = Get-Command -Name 'winget' -CommandType Application -ErrorAction SilentlyContinue
        if ($wingetCommand) {
            Write-Info 'Installing PowerShell 7 via winget...'
            $wingetArguments = @('install', '--id', 'Microsoft.PowerShell', '--exact', '--source', 'winget') + (Get-WingetAgreementArgs)
            if (Test-EffectiveNonInteractive -NonInteractive:$NonInteractive) {
                $wingetArguments += '--silent'
            }
            $wingetRun = Invoke-WingetProcess -ArgumentList $wingetArguments -TimeoutSeconds (Get-ProcessTimeoutSeconds -Operation WingetInstall) -LogDirectory $LogDirectory
            if ($wingetRun.LaunchFailed) {
                Write-WarningMessage "winget could not be started: $($wingetRun.LaunchError)"
            }
            elseif ($wingetRun.TimedOut) {
                Write-WarningMessage 'winget did not finish installing PowerShell 7 in time and was stopped.'
            }
            elseif (Test-WingetRestartRequiredResult -ExitCode $wingetRun.ExitCode -Output $wingetRun.Output) {
                $script:PowerShell7BootstrapRestartRequired = $true
                $restartDetail = ''
                if ($wingetRun.ExitCode -ne 0) {
                    $restartDetail = ' (exit code {0})' -f (Format-WingetExitCode -ExitCode $wingetRun.ExitCode)
                }
                Write-WarningMessage ('winget reported that a restart finishes the PowerShell 7 installation{0}. The run continues; restart this PC once it has finished.' -f $restartDetail)
            }
            elseif ($wingetRun.ExitCode -ne 0) {
                Write-WarningMessage ('winget could not install PowerShell 7 (exit code {0}).' -f (Format-WingetExitCode -ExitCode $wingetRun.ExitCode))
                if ($wingetRun.LogPath -and (Test-Path -LiteralPath $wingetRun.LogPath)) {
                    Write-Info "Installer log: $($wingetRun.LogPath)"
                }
            }
            $pwshPath = Find-PowerShell7
        }
        elseif (Test-IsSystemAccount) {
            Write-Info 'Running as SYSTEM, which has no winget command of its own (winget is set up for each user account), so PowerShell 7 is installed without winget.'
        }
        else {
            Write-WarningMessage 'winget is not available on this machine.'
        }

        if (-not $pwshPath) {
            Write-Info 'Falling back to the official PowerShell MSI installer...'
            [void](Install-PowerShell7FromMsi -MsiLogDirectory $LogDirectory)
            $pwshPath = Find-PowerShell7
        }

        if (-not $pwshPath) {
            if ($script:PowerShell7BootstrapGitHubThrottled) {
                Write-ErrorMessage 'PowerShell 7 could not be installed automatically: GitHub is rate-limiting this network (429 Too Many Requests), and the MSI fallback reads its release list from GitHub. If winget failed above with a source error, try "winget source reset --force" and re-run - that path does not depend on GitHub. Otherwise wait a while for the throttle to clear, or install PowerShell 7 manually (winget install Microsoft.PowerShell, or see https://aka.ms/powershell) from a machine on a different network.'
            }
            else {
                Write-ErrorMessage 'PowerShell 7 could not be installed automatically. Install it manually (winget install Microsoft.PowerShell, or see https://aka.ms/powershell) and re-run this installer from a pwsh prompt.'
            }
            return 7
        }
        Write-Success 'PowerShell 7 is installed.'
    }

    $relaunchPath = $CommandPath
    $relaunchDirectory = $null
    if (-not $relaunchPath) {
        $installerContent = Get-PowerShell7RelaunchInstaller -Url $InstallerUrl -ExpectedBuildId $ExpectedBuildId
        if (-not $installerContent) {
            if ($ExpectedBuildId) {
                Write-ErrorMessage ('Could not download installer build {0}, the build this run started with, for the PowerShell 7 relaunch (see above).' -f $ExpectedBuildId)
            }
            else {
                Write-ErrorMessage 'Could not download the installer for the PowerShell 7 relaunch (see above).'
            }
            Write-ErrorMessage 'PowerShell 7 is installed on this machine. Open PowerShell 7 (pwsh) as administrator and run the same one-liner there: it needs no second download. If raw.githubusercontent.com answers 429 Too Many Requests, use the jsDelivr one-liner from the readme.'
            return 7
        }
        try {
            $relaunchDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('winget-app-setup-' + [System.Guid]::NewGuid().ToString('N'))
            [void](New-Item -Path $relaunchDirectory -ItemType Directory -Force -ErrorAction Stop)
            $relaunchPath = Join-Path $relaunchDirectory 'winget-app-install.ps1'
            Set-Content -LiteralPath $relaunchPath -Value $installerContent -Encoding UTF8 -ErrorAction Stop
        }
        catch {
            Write-ErrorMessage "Could not save the installer for the relaunch: $_"
            if ($relaunchDirectory) {
                Remove-Item -LiteralPath $relaunchDirectory -Recurse -Force -ErrorAction SilentlyContinue
            }
            return 7
        }
    }

    Write-Info ('Relaunching the installer under PowerShell 7: {0}' -f $pwshPath)
    $quotedRelaunchPath = '"' + $relaunchPath.Replace('"', '`"') + '"'
    $relaunchArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $quotedRelaunchPath)
    if ($WhatIf) {
        $relaunchArguments += '-WhatIf'
    }
    if ($NonInteractive) {
        $relaunchArguments += '-NonInteractive'
    }
    if ($SkipSystemCheck) {
        $relaunchArguments += '-SkipSystemCheck'
    }
    $relaunchArguments += @($AdditionalArguments)
    $env:WINGET_APP_SETUP_PS7_BOOTSTRAP = '1'
    $relaunchProcess = $null
    $relaunchError = $null
    try {
        $relaunchProcess = Start-Process -FilePath $pwshPath -ArgumentList $relaunchArguments -NoNewWindow -Wait -PassThru -ErrorAction Stop
    }
    catch {
        $relaunchError = $_
    }
    if ($relaunchDirectory) {
        Remove-Item -LiteralPath $relaunchDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($relaunchError) {
        Write-ErrorMessage "PowerShell 7 could not be started ($pwshPath): $relaunchError"
        return 7
    }
    if (-not $relaunchProcess) {
        Write-ErrorMessage "PowerShell 7 could not be started ($pwshPath)."
        return 7
    }
    $script:PowerShell7BootstrapRelaunched = $true
    Write-Info ('The PowerShell 7 run ended with exit code {0}.' -f $relaunchProcess.ExitCode)
    $relaunchExitCode = $relaunchProcess.ExitCode
    if ($script:PowerShell7BootstrapRestartRequired) {
        Write-WarningMessage 'Restart: REQUIRED to finish the PowerShell 7 installation - restart this PC before it is used.'
        if ($relaunchExitCode -eq 0) {
            Write-Info 'Exit code 3010: the apps installed, and the PowerShell 7 installation needs a restart to finish.'
            return 3010
        }
    }
    return $relaunchExitCode
}

# --- ProcessInvocation ---
function Get-ProcessTimeoutSeconds {
    param (
        [Parameter(Mandatory = $true)]
        [ValidateSet('WingetInstall', 'WingetDownload', 'WingetUninstall', 'WingetListCheck', 'WingetVersion', 'WingetSourceUpdate', 'WingetSourceReset', 'WingetClientProbe', 'WingetClientVersion', 'WingetClientListCheck', 'MsiExec', 'AppxProvisioning', 'WebDownload', 'WebDownloadStall', 'WebLookup')]
        [string]$Operation
    )

    switch ($Operation) {
        'WingetInstall' { return 1800 }
        'WingetDownload' { return 1800 }
        'WingetUninstall' { return 900 }
        'WingetListCheck' { return 15 }
        'WingetVersion' { return 30 }
        'WingetSourceUpdate' { return 120 }
        'WingetSourceReset' { return 300 }
        'WingetClientProbe' { return 180 }
        'WingetClientVersion' { return 60 }
        'WingetClientListCheck' { return 45 }
        'MsiExec' { return 900 }
        'AppxProvisioning' { return 600 }
        'WebDownload' { return 300 }
        'WebDownloadStall' { return 120 }
        'WebLookup' { return 30 }
    }
}

function Get-WebDownloadTimeoutParameters {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$Lookup
    )

    $timeoutOperation = 'WebDownload'
    $stallOperation = 'WebDownloadStall'
    if ($Lookup) {
        $timeoutOperation = 'WebLookup'
        $stallOperation = 'WebLookup'
    }
    $parameters = @{ TimeoutSec = (Get-ProcessTimeoutSeconds -Operation $timeoutOperation) }
    $command = Get-Command -Name 'Invoke-WebRequest' -ErrorAction SilentlyContinue
    if ($command -and $command.Parameters -and $command.Parameters.ContainsKey('OperationTimeoutSeconds')) {
        $parameters['OperationTimeoutSeconds'] = (Get-ProcessTimeoutSeconds -Operation $stallOperation)
    }
    return $parameters
}

function ConvertTo-ProcessArgumentString {
    param (
        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [AllowNull()]
        [string[]]$ArgumentList
    )

    if ($null -eq $ArgumentList) {
        return ''
    }
    $parts = foreach ($argument in $ArgumentList) {
        $text = [string]$argument
        if ($text.Length -gt 0 -and $text -notmatch '[\s"]') {
            $text
            continue
        }
        $builder = New-Object System.Text.StringBuilder
        [void]$builder.Append('"')
        $backslashes = 0
        foreach ($character in $text.ToCharArray()) {
            if ($character -eq [char]'\') {
                $backslashes++
                continue
            }
            if ($character -eq [char]'"') {
                [void]$builder.Append([char]'\', (2 * $backslashes) + 1)
            }
            elseif ($backslashes -gt 0) {
                [void]$builder.Append([char]'\', $backslashes)
            }
            [void]$builder.Append($character)
            $backslashes = 0
        }
        [void]$builder.Append([char]'\', 2 * $backslashes)
        [void]$builder.Append('"')
        $builder.ToString()
    }
    return (@($parts) -join ' ')
}

function Get-NativeErrorCode {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [System.Exception]$Exception
    )

    $current = $Exception
    while ($null -ne $current) {
        if ($current -is [System.ComponentModel.Win32Exception]) {
            return $current.NativeErrorCode
        }
        $current = $current.InnerException
    }
    return $null
}

function ConvertTo-PlainProcessLine {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Line
    )

    if ($null -eq $Line) {
        return ''
    }
    $plain = $Line -replace '\x1b\[[0-?]*[ -/]*[@-~]', '' -replace '\x1b\][^\x07\x1b]*(\x07|\x1b\\)', ''
    return $plain.TrimEnd()
}

function Get-ProcessOutputLineKind {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Line
    )

    if ([string]::IsNullOrWhiteSpace($Line)) {
        return 'Blank'
    }
    if ($Line -match '^\s*[-\\|/]\s*$') {
        return 'Spinner'
    }
    if ($Line -match '^\s*[-\\|/]\s+\S') {
        return 'Status'
    }
    if ($Line -match '[\u2588\u2591\u2592\u2593]' -or $Line -match '^\s*\d+(\.\d+)?\s*%\s*$' -or $Line -match '^\s*[\d.]+\s*[KMGT]?B(\s*/\s*[\d.]+\s*[KMGT]?B)?\s*$') {
        return 'Progress'
    }
    return 'Text'
}

function Select-ProcessOutputLine {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$State,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Line,

        [Parameter(Mandatory = $false)]
        [switch]$Flush
    )

    $show = New-Object System.Collections.Generic.List[string]
    $kind = 'Flush'
    if (-not $Flush) {
        $kind = Get-ProcessOutputLineKind -Line $Line
    }
    switch ($kind) {
        'Progress' {
            $State['PendingProgress'] = $Line
        }
        'Status' {
            $message = $Line -replace '^\s*[-\\|/]\s+', ''
            if ($message -cne $State['LastStatus']) {
                if ($null -ne $State['PendingProgress']) {
                    $show.Add($State['PendingProgress'])
                    $State['PendingProgress'] = $null
                }
                $show.Add($Line)
                $State['LastStatus'] = $message
            }
        }
        'Text' {
            if ($null -ne $State['PendingProgress']) {
                $show.Add($State['PendingProgress'])
                $State['PendingProgress'] = $null
            }
            $show.Add($Line)
            $State['LastStatus'] = $null
        }
        'Flush' {
            if ($null -ne $State['PendingProgress']) {
                $show.Add($State['PendingProgress'])
                $State['PendingProgress'] = $null
            }
        }
    }
    return $show.ToArray()
}

function Write-ProcessOutput {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Line,

        [Parameter(Mandatory = $false)]
        [int]$Tail = 0
    )

    $shown = New-Object System.Collections.Generic.List[string]
    $filterState = @{}
    foreach ($rawLine in @($Line)) {
        $plain = ConvertTo-PlainProcessLine -Line $rawLine
        foreach ($shownLine in @(Select-ProcessOutputLine -State $filterState -Line $plain)) {
            $shown.Add($shownLine)
        }
    }
    foreach ($shownLine in @(Select-ProcessOutputLine -State $filterState -Flush)) {
        $shown.Add($shownLine)
    }

    $start = 0
    if ($Tail -gt 0 -and $shown.Count -gt $Tail) {
        $start = $shown.Count - $Tail
    }
    for ($index = $start; $index -lt $shown.Count; $index++) {
        Write-Host ('    ' + $shown[$index]) -ForegroundColor DarkGray
    }
}

function Stop-ProcessTree {
    param (
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$Process
    )

    if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        try {
            $taskkillPath = Join-Path ([System.Environment]::SystemDirectory) 'taskkill.exe'
            $killerInfo = New-Object System.Diagnostics.ProcessStartInfo
            $killerInfo.FileName = $taskkillPath
            $killerInfo.Arguments = '/PID {0} /T /F' -f $Process.Id
            $killerInfo.UseShellExecute = $false
            $killerInfo.CreateNoWindow = $true
            $killerInfo.RedirectStandardOutput = $true
            $killerInfo.RedirectStandardError = $true
            $killer = [System.Diagnostics.Process]::Start($killerInfo)
            $null = $killer.StandardOutput.ReadToEndAsync()
            $null = $killer.StandardError.ReadToEndAsync()
            if ($killer.WaitForExit(30000) -and $Process.WaitForExit(10000)) {
                return
            }
        }
        catch {
        }
    }

    try {
        $Process.Kill($true)
    }
    catch {
        try {
            $Process.Kill()
        }
        catch {
        }
    }
    try {
        [void]$Process.WaitForExit(10000)
    }
    catch {
    }
}

function Invoke-ExternalProcess {
    param (
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [string[]]$ArgumentList = @(),

        [Parameter(Mandatory = $false)]
        [string]$ArgumentString,

        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Live', 'None')]
        [string]$Echo = 'Live',

        [Parameter(Mandatory = $false)]
        [System.Text.Encoding]$Encoding,

        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [string[]]$RemoveEnvironmentVariable = @()
    )

    $arguments = $ArgumentString
    if (-not $PSBoundParameters.ContainsKey('ArgumentString')) {
        $arguments = ConvertTo-ProcessArgumentString -ArgumentList $ArgumentList
    }
    $displayName = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
    $output = New-Object System.Collections.Generic.List[string]
    $standardOutput = New-Object System.Collections.Generic.List[string]
    $standardError = New-Object System.Collections.Generic.List[string]
    $result = [pscustomobject]@{
        FilePath        = $FilePath
        Arguments       = $arguments
        ExitCode        = $null
        TimedOut        = $false
        LaunchFailed    = $false
        LaunchErrorCode = $null
        LaunchError     = $null
        LaunchException = $null
        Output          = @()
        StandardOutput  = @()
        StandardError   = @()
        DurationSeconds = 0
        LogPath         = $null
    }

    $resolvedPath = $FilePath
    if (-not [System.IO.Path]::IsPathRooted($FilePath) -and $FilePath -notmatch '[\\/]') {
        $command = Get-Command -Name $FilePath -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $command) {
            $result.LaunchFailed = $true
            $result.LaunchErrorCode = 2
            $result.LaunchException = New-Object System.ComponentModel.Win32Exception(2, "'$FilePath' was not found on PATH.")
            $result.LaunchError = $result.LaunchException.Message
            return $result
        }
        $resolvedPath = $command.Source
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $resolvedPath
    $startInfo.Arguments = $arguments
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    if (-not $Encoding) {
        $Encoding = New-Object System.Text.UTF8Encoding($false)
    }
    $startInfo.StandardOutputEncoding = $Encoding
    $startInfo.StandardErrorEncoding = $Encoding
    foreach ($name in @($RemoveEnvironmentVariable)) {
        if (-not [string]::IsNullOrEmpty($name)) {
            [void]$startInfo.EnvironmentVariables.Remove($name)
        }
    }

    if ($Echo -eq 'Live') {
        Write-Host ('  > {0} {1}' -f $displayName, $arguments).TrimEnd() -ForegroundColor DarkGray
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $process = [System.Diagnostics.Process]::Start($startInfo)
    }
    catch {
        $exception = $_.Exception
        $nativeErrorCode = Get-NativeErrorCode -Exception $exception
        $message = $exception.Message
        $inner = $exception
        while ($null -ne $inner) {
            if ($inner -is [System.ComponentModel.Win32Exception]) {
                $message = $inner.Message
                $exception = $inner
                break
            }
            $inner = $inner.InnerException
        }
        $result.LaunchFailed = $true
        $result.LaunchErrorCode = $nativeErrorCode
        $result.LaunchError = $message
        $result.LaunchException = $exception
        return $result
    }

    try {
        $process.StandardInput.Close()
    }
    catch {
    }

    $echoState = @{}
    $readers = @($process.StandardOutput, $process.StandardError)
    $targets = @($standardOutput, $standardError)
    $pending = @($readers[0].ReadLineAsync(), $readers[1].ReadLineAsync())
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $exitSeenAt = $null
    $timedOut = $false
    $maximumLinesPerPass = 500

    while ($true) {
        for ($stream = 0; $stream -lt 2; $stream++) {
            $linesThisPass = 0
            while ($linesThisPass -lt $maximumLinesPerPass -and $null -ne $pending[$stream] -and $pending[$stream].IsCompleted) {
                $line = $null
                if (-not $pending[$stream].IsFaulted -and -not $pending[$stream].IsCanceled) {
                    $line = $pending[$stream].Result
                }
                if ($null -eq $line) {
                    $pending[$stream] = $null
                    break
                }
                $linesThisPass++
                $plain = ConvertTo-PlainProcessLine -Line $line
                $output.Add($plain)
                $targets[$stream].Add($plain)
                if ($Echo -eq 'Live') {
                    foreach ($shownLine in @(Select-ProcessOutputLine -State $echoState -Line $plain)) {
                        Write-Host ('    ' + $shownLine) -ForegroundColor DarkGray
                    }
                }
                $pending[$stream] = $readers[$stream].ReadLineAsync()
            }
        }

        if ($null -eq $pending[0] -and $null -eq $pending[1]) {
            break
        }
        if ($process.HasExited) {
            if ($null -eq $exitSeenAt) {
                $exitSeenAt = [DateTime]::UtcNow
            }
            elseif (([DateTime]::UtcNow - $exitSeenAt).TotalSeconds -ge 5) {
                break
            }
        }
        elseif ([DateTime]::UtcNow -ge $deadline) {
            $timedOut = $true
            break
        }

        $waitFor = @($pending | Where-Object { $null -ne $_ })
        [void][System.Threading.Tasks.Task]::WaitAny([System.Threading.Tasks.Task[]]$waitFor, 200)
    }

    if (-not $timedOut) {
        $remainingMilliseconds = [int][Math]::Max(0, [Math]::Min([int]::MaxValue, ($deadline - [DateTime]::UtcNow).TotalMilliseconds))
        if (-not $process.WaitForExit($remainingMilliseconds)) {
            $timedOut = $true
        }
    }

    if ($timedOut) {
        Stop-ProcessTree -Process $process
        for ($stream = 0; $stream -lt 2; $stream++) {
            try {
                if ($null -ne $pending[$stream] -and $pending[$stream].Wait(2000)) {
                    $line = $pending[$stream].Result
                    if ($null -ne $line) {
                        $plain = ConvertTo-PlainProcessLine -Line $line
                        $output.Add($plain)
                        $targets[$stream].Add($plain)
                    }
                }
            }
            catch {
            }
        }
    }

    if ($Echo -eq 'Live') {
        foreach ($shownLine in @(Select-ProcessOutputLine -State $echoState -Flush)) {
            Write-Host ('    ' + $shownLine) -ForegroundColor DarkGray
        }
    }

    $stopwatch.Stop()
    $result.DurationSeconds = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
    $result.Output = $output.ToArray()
    $result.StandardOutput = $standardOutput.ToArray()
    $result.StandardError = $standardError.ToArray()
    if ($timedOut) {
        $result.TimedOut = $true
    }
    else {
        $result.ExitCode = $process.ExitCode
    }
    try {
        $process.Dispose()
    }
    catch {
    }
    return $result
}

function Get-InstallerLogDirectory {
    if ($script:InstallLogPath) {
        return (Split-Path -Parent $script:InstallLogPath)
    }
    return $null
}

function New-WingetInstallerLogPath {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Subcommand,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$PackageId,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$LogDirectory
    )

    $directory = $LogDirectory
    if (-not $PSBoundParameters.ContainsKey('LogDirectory')) {
        $directory = Get-InstallerLogDirectory
    }
    if ([string]::IsNullOrWhiteSpace($directory)) {
        return $null
    }
    $label = 'winget'
    if (-not [string]::IsNullOrWhiteSpace($PackageId)) {
        $label = $PackageId -replace '[^\w.\-]', '_'
    }
    try {
        if (-not (Test-Path -LiteralPath $directory)) {
            [void](New-Item -Path $directory -ItemType Directory -Force -ErrorAction Stop)
        }
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $candidate = Join-Path $directory ('winget-{0}-{1}-{2}.log' -f $Subcommand, $label, $stamp)
        $suffix = 2
        while (Test-Path -LiteralPath $candidate) {
            $candidate = Join-Path $directory ('winget-{0}-{1}-{2}-{3}.log' -f $Subcommand, $label, $stamp, $suffix)
            $suffix++
        }
        return $candidate
    }
    catch {
        return $null
    }
}

function Invoke-WingetProcess {
    param (
        [Parameter(Mandatory = $true)]
        [string[]]$ArgumentList,

        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds,

        [Parameter(Mandatory = $false)]
        [string]$WingetPath,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Live', 'None')]
        [string]$Echo = 'Live',

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$LogDirectory
    )

    if ([string]::IsNullOrWhiteSpace($WingetPath)) {
        $WingetPath = Resolve-WingetExecutable
    }

    $arguments = @($ArgumentList)
    $logPath = $null
    $subcommand = ''
    if ($arguments.Count -gt 0) {
        $subcommand = [string]$arguments[0]
    }
    if (@('install', 'upgrade', 'uninstall', 'repair') -contains $subcommand -and -not ($arguments -contains '--log' -or $arguments -contains '-o')) {
        $logParameters = @{ Subcommand = $subcommand }
        $idIndex = [array]::IndexOf($arguments, '--id')
        if ($idIndex -ge 0 -and $idIndex + 1 -lt $arguments.Count) {
            $logParameters['PackageId'] = [string]$arguments[$idIndex + 1]
        }
        if ($PSBoundParameters.ContainsKey('LogDirectory')) {
            $logParameters['LogDirectory'] = $LogDirectory
        }
        $logPath = New-WingetInstallerLogPath @logParameters
        if ($logPath) {
            $arguments += @('--log', $logPath)
        }
    }

    $result = Invoke-ExternalProcess -FilePath $WingetPath -ArgumentList $arguments -TimeoutSeconds $TimeoutSeconds -Echo $Echo
    $result.LogPath = $logPath
    return $result
}

# --- ProgramDataFolder ---
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

function Test-FileSystemLink {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $attributes = Get-FileSystemEntryAttribute -Path $Path
    return ($null -ne $attributes -and ($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

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

function Get-RestrictedDirectoryResetHint {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $newName = '{0}-old-{1}' -f (Split-Path -Leaf $Path), (Get-Date).ToString('yyyyMMdd-HHmmss', [System.Globalization.CultureInfo]::InvariantCulture)
    return (" To start over with a new folder, rename this one in an elevated prompt: ren `"{0}`" {1} (ren renames a junction or symbolic link itself, never what it points to), then re-run this installer." -f $Path, $newName)
}

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

function Initialize-ProgramDataFolder {
    param (
        [Parameter(Mandatory = $false)]
        [ValidatePattern('^[A-Za-z0-9-]*\z')]
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

# --- RunBudget ---
function Resolve-InstallerRunBudget {
    param (
        [Parameter(Mandatory = $false)]
        [int]$MaxRuntimeMinutes = 0,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$RunDeadlineUtc,

        [Parameter(Mandatory = $false)]
        [DateTime]$StartedUtc = [DateTime]::UtcNow
    )

    $minutes = 0
    $minutesGiven = $PSBoundParameters.ContainsKey('MaxRuntimeMinutes')
    if ($minutesGiven) {
        $minutes = $MaxRuntimeMinutes
        if ($minutes -lt 0 -or $minutes -gt 1440) {
            Write-WarningMessage "Ignoring a time budget of $minutes minutes: it must be from 0 to 1440. This run has no time budget."
            $minutes = 0
        }
    }
    else {
        $environmentValue = ([string]$env:WINGET_APP_SETUP_MAX_RUNTIME_MINUTES).Trim()
        if ($environmentValue) {
            if ($environmentValue -match '^[0-9]{1,4}\z' -and [int]$environmentValue -le 1440) {
                $minutes = [int]$environmentValue
            }
            else {
                Write-WarningMessage "Ignoring WINGET_APP_SETUP_MAX_RUNTIME_MINUTES='$environmentValue': it must be a whole number of minutes from 0 to 1440. This run has no time budget."
            }
        }
    }
    if ($minutes -eq 0) {
        return [pscustomobject]@{ Minutes = 0; DeadlineUtc = $null; MinutesGiven = $minutesGiven }
    }

    $deadline = $StartedUtc.ToUniversalTime().AddMinutes($minutes)
    if (-not [string]::IsNullOrWhiteSpace($RunDeadlineUtc)) {
        $inherited = [DateTime]::MinValue
        $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
        if ([DateTime]::TryParseExact($RunDeadlineUtc.Trim(), "yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$inherited)) {
            if ($inherited -lt $deadline) {
                $deadline = $inherited
            }
        }
        else {
            Write-WarningMessage "Ignoring -RunDeadlineUtc '$RunDeadlineUtc': it is not a time in the form yyyy-MM-ddTHH:mm:ssZ. The time budget counts from the start of this part of the run."
        }
    }
    return [pscustomobject]@{ Minutes = $minutes; DeadlineUtc = $deadline; MinutesGiven = $minutesGiven }
}

function Get-InstallerRunBudgetArgument {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Budget
    )

    if ($null -eq $Budget -or $null -eq $Budget.DeadlineUtc -or [int]$Budget.Minutes -le 0) {
        if ($null -ne $Budget -and $Budget.MinutesGiven -eq $true) {
            return @('-MaxRuntimeMinutes', '0')
        }
        return @()
    }
    return @('-MaxRuntimeMinutes', ([string][int]$Budget.Minutes), '-RunDeadlineUtc', (Format-RunRecordTime -Time $Budget.DeadlineUtc))
}

function Test-InstallerRunBudgetSpent {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Budget,

        [Parameter(Mandatory = $false)]
        [DateTime]$NowUtc = [DateTime]::UtcNow
    )

    if ($null -eq $Budget -or $null -eq $Budget.DeadlineUtc) {
        return $false
    }
    return ($NowUtc.ToUniversalTime() -ge ([DateTime]$Budget.DeadlineUtc))
}

function Get-InstallerRunBudgetSecondsLeft {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Budget,

        [Parameter(Mandatory = $false)]
        [DateTime]$NowUtc = [DateTime]::UtcNow
    )

    if ($null -eq $Budget -or $null -eq $Budget.DeadlineUtc) {
        return $null
    }
    $seconds = [Math]::Floor((([DateTime]$Budget.DeadlineUtc) - $NowUtc.ToUniversalTime()).TotalSeconds)
    return [int][Math]::Max(0, $seconds)
}

function Get-InstallerRunBudgetWaitSeconds {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Budget,

        [Parameter(Mandatory = $true)]
        [int]$Seconds,

        [Parameter(Mandatory = $false)]
        [DateTime]$NowUtc = [DateTime]::UtcNow
    )

    $secondsLeft = Get-InstallerRunBudgetSecondsLeft -Budget $Budget -NowUtc $NowUtc
    if ($null -eq $secondsLeft) {
        return $Seconds
    }
    return [int][Math]::Min($Seconds, $secondsLeft)
}

# --- RunLock ---
function Get-InstallerRunLockName {
    return 'Global\winget-app-setup-run'
}

function New-InstallerRunMutex {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    return (New-Object System.Threading.Mutex($false, $Name))
}

function Lock-InstallerRun {
    [OutputType([string])]
    param (
        [Parameter(Mandatory = $false)]
        [string]$Name = (Get-InstallerRunLockName)
    )

    $mutex = $null
    try {
        $mutex = New-InstallerRunMutex -Name $Name
    }
    catch [System.UnauthorizedAccessException] {
        return 'Busy'
    }
    catch {
        Write-WarningMessage "Could not check whether another run of the installer is in progress: $($_.Exception.Message.Trim().TrimEnd('.')). Continuing without that check."
        return 'Unavailable'
    }

    $acquired = $false
    try {
        $acquired = $mutex.WaitOne(0)
    }
    catch [System.Threading.AbandonedMutexException] {
        $acquired = $true
    }
    catch {
        Write-WarningMessage "Could not check whether another run of the installer is in progress: $($_.Exception.Message.Trim().TrimEnd('.')). Continuing without that check."
        $mutex.Dispose()
        return 'Unavailable'
    }

    if (-not $acquired) {
        $mutex.Dispose()
        return 'Busy'
    }
    $script:InstallerRunLock = $mutex
    return 'Acquired'
}

function Unlock-InstallerRun {
    $mutex = $script:InstallerRunLock
    $script:InstallerRunLock = $null
    if ($null -eq $mutex) {
        return
    }
    try {
        $mutex.ReleaseMutex()
    }
    catch {
    }
    try {
        $mutex.Dispose()
    }
    catch {
    }
}

# --- RunRecord ---
function New-AppRunRecord {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Id,

        [Parameter(Mandatory = $true)]
        [string]$Status,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Reason,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$InstallResult,

        [Parameter(Mandatory = $false)]
        [bool]$RestartRequired = $false,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$PostInstall
    )

    $code = $null
    $codeHex = $null
    if ($null -ne $InstallResult -and $null -ne $InstallResult.ExitCode) {
        $code = [int]$InstallResult.ExitCode
        $codeHex = '0x{0:X8}' -f $code
    }
    $installerCode = $null
    if ($null -ne $InstallResult -and $null -ne $InstallResult.InstallerErrorCode) {
        $installerCode = [long]$InstallResult.InstallerErrorCode
    }
    $reasonText = $null
    if (-not [string]::IsNullOrWhiteSpace($Reason)) {
        $reasonText = $Reason
    }
    $postInstallStatus = $null
    $postInstallReason = $null
    if ($null -ne $PostInstall -and -not [string]::IsNullOrWhiteSpace([string]$PostInstall.Status)) {
        $postInstallStatus = [string]$PostInstall.Status
        if (-not [string]::IsNullOrWhiteSpace([string]$PostInstall.Reason)) {
            $postInstallReason = [string]$PostInstall.Reason
        }
    }
    return [ordered]@{
        id                = $Id
        status            = $Status
        reason            = $reasonText
        code              = $code
        codeHex           = $codeHex
        installerCode     = $installerCode
        restartRequired   = $RestartRequired
        postInstall       = $postInstallStatus
        postInstallReason = $postInstallReason
    }
}

function Get-AutoUpdateResultStatus {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$WauResult
    )

    if ($null -eq $WauResult -or [string]::IsNullOrWhiteSpace([string]$WauResult.Status)) {
        return 'NotRun'
    }
    switch ([string]$WauResult.Status) {
        'AlreadyPresent' {
            if ($WauResult.FrameworkMissing) {
                return 'AtRisk'
            }
            return 'AlreadyPresent'
        }
        'Unhealthy' { return 'Unhealthy' }
    }
    return [string]$WauResult.Status
}

function Format-RunRecordTime {
    param (
        [Parameter(Mandatory = $true)]
        [DateTime]$Time
    )

    return $Time.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
}

function New-InstallerRunRecord {
    param (
        [Parameter(Mandatory = $true)]
        [int]$ExitCode,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Apps = @(),

        [Parameter(Mandatory = $false)]
        [string]$AutoUpdates = 'NotRun',

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$AutoUpdatesVersion,

        [Parameter(Mandatory = $false)]
        [bool]$RestartRequired = $false,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[bool]]$WingetUsable = $null,

        [Parameter(Mandatory = $false)]
        [switch]$SummaryReached,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [System.Collections.IDictionary]$InstallEngine
    )

    if ($null -eq $InstallEngine) {
        $InstallEngine = Get-InstallEngineRecord
    }
    $appList = @($Apps | Where-Object { $null -ne $_ })
    $autoUpdatesVersionText = $null
    if ($null -ne $AutoUpdatesVersion -and -not [string]::IsNullOrWhiteSpace([string]$AutoUpdatesVersion)) {
        $autoUpdatesVersionText = [string]$AutoUpdatesVersion
    }
    $startedUtc = $null
    if ($script:InstallerRunStartedUtc -is [DateTime]) {
        $startedUtc = Format-RunRecordTime -Time $script:InstallerRunStartedUtc
    }
    $buildId = $null
    if ($script:InstallerBuildId) {
        $buildId = [string]$script:InstallerBuildId
    }
    $transcriptPath = $null
    if ($script:InstallLogPath) {
        $transcriptPath = [string]$script:InstallLogPath
    }

    return [ordered]@{
        schemaVersion   = 1
        buildId         = $buildId
        startedUtc      = $startedUtc
        endedUtc        = Format-RunRecordTime -Time ([DateTime]::UtcNow)
        exitCode        = $ExitCode
        summaryReached  = [bool]$SummaryReached
        counts          = [ordered]@{
            installed    = @($appList | Where-Object { $_.status -eq 'Installed' }).Count
            skipped      = @($appList | Where-Object { $_.status -eq 'Skipped' }).Count
            deferred     = @($appList | Where-Object { $_.status -eq 'Deferred' }).Count
            failed       = @($appList | Where-Object { $_.status -eq 'Failed' }).Count
            notAttempted = @($appList | Where-Object { $_.status -eq 'NotAttempted' }).Count
        }
        apps            = $appList
        autoUpdates     = [ordered]@{
            status  = $AutoUpdates
            version = $autoUpdatesVersionText
        }
        restartRequired = $RestartRequired
        wingetUsable    = $WingetUsable
        installEngine   = $InstallEngine
        transcriptPath  = $transcriptPath
    }
}

function Format-InstallerResultLine {
    param (
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Record
    )

    $restart = 'no'
    if ($Record.restartRequired) {
        $restart = 'yes'
    }
    $build = 'unknown'
    if ($Record.buildId) {
        $build = $Record.buildId
    }
    $log = 'none'
    if ($Record.transcriptPath) {
        $log = $Record.transcriptPath
    }
    $notAttempted = 0
    if ($null -ne $Record.counts.notAttempted) {
        $notAttempted = $Record.counts.notAttempted
    }
    return ('RESULT: exit={0} installed={1} skipped={2} deferred={3} failed={4} notattempted={5} autoupdates={6} restart={7} build={8} log={9}' -f $Record.exitCode, $Record.counts.installed, $Record.counts.skipped, $Record.counts.deferred, $Record.counts.failed, $notAttempted, $Record.autoUpdates.status, $restart, $build, $log)
}

function Save-InstallerRunRecord {
    param (
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Record,

        [Parameter(Mandatory = $true)]
        [string]$Directory
    )

    $path = Join-Path $Directory 'last-run.json'
    $temporaryPath = Join-Path $Directory ('last-run.{0}.tmp' -f [System.Guid]::NewGuid().ToString('N'))
    try {
        $json = ConvertTo-Json -InputObject $Record -Depth 6
        [System.IO.File]::WriteAllText($temporaryPath, $json, (New-Object System.Text.UTF8Encoding($false)))
        [System.IO.File]::Move($temporaryPath, $path, $true)
        return $path
    }
    catch {
        Write-WarningMessage "Could not write the run record ${path}: $($_.Exception.Message)"
        try {
            if (Test-Path -LiteralPath $temporaryPath) {
                Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction Stop
            }
        }
        catch {
        }
        return $null
    }
}

function Write-InstallerRunResult {
    param (
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Record
    )

    $savedPath = $null
    if ($script:InstallerRunRecordEnabled) {
        $directory = Get-InstallerLogDirectory
        if (-not [string]::IsNullOrWhiteSpace($directory)) {
            $savedPath = Save-InstallerRunRecord -Record $Record -Directory $directory
        }
    }
    try {
        Write-Host (Format-InstallerResultLine -Record $Record)
    }
    catch {
        Write-WarningMessage "Could not print the RESULT line: $($_.Exception.Message)"
    }
    return $savedPath
}

function Save-InstallerRunStartRecord {
    if (-not $script:InstallerRunRecordEnabled) {
        return $null
    }
    $directory = Get-InstallerLogDirectory
    if ([string]::IsNullOrWhiteSpace($directory)) {
        return $null
    }
    try {
        $record = New-InstallerRunRecord -ExitCode 0
        $record.exitCode = $null
        $record.endedUtc = $null
        return (Save-InstallerRunRecord -Record $record -Directory $directory)
    }
    catch {
        Write-WarningMessage "Could not write the run record: $($_.Exception.Message)"
        return $null
    }
}

function Complete-InstallerRun {
    param (
        [Parameter(Mandatory = $true)]
        [int]$ExitCode
    )

    if ($script:InstallerRunReportPending) {
        $script:InstallerRunReportPending = $false
        try {
            [void](Write-InstallerEarlyExitResult -ExitCode $ExitCode)
        }
        catch {
        }
    }
    Unlock-InstallerRun
}

function Write-InstallerEarlyExitResult {
    param (
        [Parameter(Mandatory = $true)]
        [int]$ExitCode
    )

    $apps = @()
    if ($script:InstallerAppRecords) {
        $apps = @($script:InstallerAppRecords.Values)
    }
    $autoUpdateResult = $script:InstallerAutoUpdateResult
    $autoUpdateVersion = $null
    if ($null -ne $autoUpdateResult) {
        $autoUpdateVersion = $autoUpdateResult.Version
    }
    $restartRequired = @($apps | Where-Object { $_.restartRequired }).Count -gt 0
    $record = New-InstallerRunRecord -ExitCode $ExitCode -Apps $apps -AutoUpdates (Get-AutoUpdateResultStatus -WauResult $autoUpdateResult) -AutoUpdatesVersion $autoUpdateVersion -RestartRequired $restartRequired
    return (Write-InstallerRunResult -Record $record)
}

function Write-InstallerNotStartedResult {
    param (
        [Parameter(Mandatory = $true)]
        [int]$ExitCode
    )

    $record = [ordered]@{
        exitCode        = $ExitCode
        counts          = [ordered]@{ installed = 0; skipped = 0; deferred = 0; failed = 0; notAttempted = 0 }
        autoUpdates     = [ordered]@{ status = 'NotRun' }
        restartRequired = $false
        buildId         = $script:InstallerBuildId
        transcriptPath  = $null
    }
    Write-Host (Format-InstallerResultLine -Record $record)
}

# --- SystemInfo ---
function Get-WindowsBuildNumber {
    return [int][System.Environment]::OSVersion.Version.Build
}

function Get-ComputerManufacturer {
    $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    $manufacturer = [string]($computerSystem | Select-Object -First 1).Manufacturer
    if ([string]::IsNullOrWhiteSpace($manufacturer)) {
        throw 'Win32_ComputerSystem reported no manufacturer.'
    }
    return $manufacturer.Trim()
}

function Get-OSArchitecture {
    $architecture = [string][System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
    if ([string]::IsNullOrWhiteSpace($architecture)) {
        throw 'The OS architecture could not be read.'
    }
    return $architecture
}

function Get-PowerShellEdition {
    return [string]$PSVersionTable.PSEdition
}

function Get-PowerShellVersion {
    $psVersion = $PSVersionTable.PSVersion
    $patch = 0
    if ($psVersion.PSObject.Properties['Patch']) {
        $patch = [int]$psVersion.Patch
    }
    elseif ($psVersion.Build -ge 0) {
        $patch = [int]$psVersion.Build
    }
    return [version]::new([int]$psVersion.Major, [int]$psVersion.Minor, $patch)
}

function Get-ProcessArchitecture {
    return [string][System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture
}

# --- TightVnc ---
function ConvertTo-TightVncPasswordBytes {
    param (
        [Parameter(Mandatory = $true)]
        [System.Security.SecureString]$Password
    )

    if ($Password.Length -lt 1) {
        throw 'The TightVNC password is empty.'
    }
    $usedLength = [Math]::Min($Password.Length, 8)
    $plain = New-Object byte[] 8
    $bstr = [IntPtr]::Zero
    $des = $null
    $encryptor = $null
    try {
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
        for ($index = 0; $index -lt $usedLength; $index++) {
            $character = [System.Runtime.InteropServices.Marshal]::ReadInt16($bstr, 2 * $index)
            if ($character -lt 0x20 -or $character -gt 0x7E) {
                throw 'The TightVNC password must use printable ASCII characters only (letters, digits, punctuation and spaces).'
            }
            $plain[$index] = [byte]$character
        }
        $des = [System.Security.Cryptography.DES]::Create()
        $des.Mode = [System.Security.Cryptography.CipherMode]::ECB
        $des.Padding = [System.Security.Cryptography.PaddingMode]::None
        $des.Key = [byte[]](0xE8, 0x4A, 0xD6, 0x60, 0xC4, 0x72, 0x1A, 0xE0)
        $encryptor = $des.CreateEncryptor()
        $encoded = $encryptor.TransformFinalBlock($plain, 0, 8)
        return , $encoded
    }
    finally {
        [Array]::Clear($plain, 0, $plain.Length)
        if ($encryptor) {
            $encryptor.Dispose()
        }
        if ($des) {
            $des.Dispose()
        }
        if ($bstr -ne [IntPtr]::Zero) {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

function Test-SecureStringEqual {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [System.Security.SecureString]$First,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [System.Security.SecureString]$Second
    )

    if ($null -eq $First -or $null -eq $Second -or $First.Length -ne $Second.Length) {
        return $false
    }
    $firstBstr = [IntPtr]::Zero
    $secondBstr = [IntPtr]::Zero
    try {
        $firstBstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($First)
        $secondBstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Second)
        $same = $true
        for ($index = 0; $index -lt $First.Length; $index++) {
            if ([System.Runtime.InteropServices.Marshal]::ReadInt16($firstBstr, 2 * $index) -ne [System.Runtime.InteropServices.Marshal]::ReadInt16($secondBstr, 2 * $index)) {
                $same = $false
            }
        }
        return $same
    }
    finally {
        if ($firstBstr -ne [IntPtr]::Zero) {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($firstBstr)
        }
        if ($secondBstr -ne [IntPtr]::Zero) {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($secondBstr)
        }
    }
}

function Test-TightVncBytesEqual {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [byte[]]$First,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [byte[]]$Second
    )

    if ($null -eq $First -or $null -eq $Second -or $First.Length -ne $Second.Length) {
        return $false
    }
    for ($index = 0; $index -lt $First.Length; $index++) {
        if ($First[$index] -ne $Second[$index]) {
            return $false
        }
    }
    return $true
}

function Import-TightVncSecretFromEnvironment {
    $secret = @{
        Password              = $null
        PasswordSource        = $null
        ControlPassword       = $null
        ControlPasswordSource = $null
        PromptDone            = $false
        PromptReason          = $null
    }
    $variables = @(
        @{ Name = 'WINGET_APP_SETUP_TIGHTVNC_PASSWORD'; Value = 'Password'; Source = 'PasswordSource' },
        @{ Name = 'WINGET_APP_SETUP_TIGHTVNC_CONTROL_PASSWORD'; Value = 'ControlPassword'; Source = 'ControlPasswordSource' }
    )
    foreach ($variable in $variables) {
        $value = [System.Environment]::GetEnvironmentVariable($variable.Name)
        if ($null -eq $value) {
            continue
        }
        Remove-Item -LiteralPath "Env:\$($variable.Name)" -ErrorAction SilentlyContinue
        if ($value.Length -gt 0) {
            $characters = $value.ToCharArray()
            $secure = New-Object System.Security.SecureString
            try {
                foreach ($character in $characters) {
                    $secure.AppendChar($character)
                }
            }
            finally {
                [Array]::Clear($characters, 0, $characters.Length)
            }
            $secure.MakeReadOnly()
            $secret[$variable.Value] = $secure
            $secret[$variable.Source] = $variable.Name
        }
        $value = $null
    }
    $script:TightVncSecret = $secret
}

function Clear-TightVncSecret {
    $secret = $script:TightVncSecret
    if ($secret) {
        foreach ($name in @('Password', 'ControlPassword')) {
            if ($secret[$name]) {
                $secret[$name].Dispose()
            }
        }
    }
    $script:TightVncSecret = $null
}

function Wait-TightVncPromptAnswer {
    param (
        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds
    )

    try {
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        while (-not [System.Console]::KeyAvailable) {
            if ([DateTime]::UtcNow -ge $deadline) {
                return $false
            }
            Start-Sleep -Milliseconds 250
        }
        return $true
    }
    catch {
        return $true
    }
}

function Read-TightVncPasswordFromHost {
    param (
        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 300
    )

    $minutes = [Math]::Max(1, [int][Math]::Round($TimeoutSeconds / 60))
    Write-Info ("TightVNC Server needs a password before viewers can connect, and a control password so that signed-in users cannot reconfigure it. Type the password viewers will use (TightVNC uses only the first 8 characters), or press Enter to skip: TightVNC is then installed but NOT configured. Nothing typed within {0} minutes counts as skipping. The same password protects the control interface unless WINGET_APP_SETUP_TIGHTVNC_CONTROL_PASSWORD is set or TightVNC Server already has a separate control password." -f $minutes)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Write-Host -NoNewline 'TightVNC server password: '
        if (-not (Wait-TightVncPromptAnswer -TimeoutSeconds $TimeoutSeconds)) {
            Write-Host ''
            return @{ Password = $null; Reason = ('nobody answered the TightVNC password prompt within {0} minutes' -f $minutes) }
        }
        $first = $null
        $second = $null
        try {
            $first = Read-Host -AsSecureString
            if ($null -eq $first -or $first.Length -eq 0) {
                return @{ Password = $null; Reason = 'no server password was entered at the prompt' }
            }
            $problem = $null
            try {
                $check = ConvertTo-TightVncPasswordBytes -Password $first
                [Array]::Clear($check, 0, $check.Length)
            }
            catch {
                $problem = $_.Exception.Message
            }
            if ($problem) {
                $first.Dispose()
                Write-WarningMessage "$problem Try again."
                continue
            }
            $second = Read-Host -Prompt 'Type the TightVNC server password again' -AsSecureString
        }
        catch [System.Management.Automation.PSInvalidOperationException] {
            if ($first) {
                $first.Dispose()
            }
            Write-Host ''
            return @{ Password = $null; Reason = "the password could not be asked for ($($_.Exception.Message.Trim()))" }
        }
        $same = Test-SecureStringEqual -First $first -Second $second
        if ($second) {
            $second.Dispose()
        }
        if ($same) {
            $first.MakeReadOnly()
            return @{ Password = $first; Reason = $null }
        }
        $first.Dispose()
        Write-WarningMessage 'The two passwords do not match. Try again.'
    }
    return @{ Password = $null; Reason = 'no usable server password was entered at the prompt (3 tries)' }
}

function Get-TightVncSecret {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive,

        [Parameter(Mandatory = $false)]
        [switch]$ServerSecured
    )

    if ($null -eq $script:TightVncSecret) {
        Import-TightVncSecretFromEnvironment
    }
    $secret = $script:TightVncSecret
    if ($null -eq $secret.Password -and -not $secret.PromptDone -and -not $ServerSecured -and -not $NonInteractive -and -not (Test-IsContinuousIntegration)) {
        $secret.PromptDone = $true
        if (Test-PowerShellHostNonInteractive) {
            $secret.PromptReason = 'no server password was supplied, and PowerShell was started with -NonInteractive, so none could be asked for'
        }
        else {
            $answer = Read-TightVncPasswordFromHost
            if ($answer.Password) {
                $secret.Password = $answer.Password
                $secret.PasswordSource = 'the password entered at the prompt'
            }
            else {
                $secret.PromptReason = $answer.Reason
            }
        }
    }
    return $secret
}

function Get-TightVncRestartMarkerName {
    return 'WingetAppSetupRestartPending'
}

function Get-TightVncServerSettings {
    param (
        [Parameter(Mandatory = $false)]
        [string]$Path = 'HKLM:\SOFTWARE\TightVNC\Server'
    )

    $settings = @{
        KeyExists                = $false
        Password                 = $null
        UseVncAuthentication     = $null
        ControlPassword          = $null
        UseControlAuthentication = $null
        RestartPending           = $false
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        return $settings
    }
    $settings.KeyExists = $true
    $values = Get-ItemProperty -LiteralPath $Path -ErrorAction Stop
    if ($null -eq $values) {
        return $settings
    }
    foreach ($name in @('Password', 'ControlPassword')) {
        $property = $values.PSObject.Properties[$name]
        if ($property -and $property.Value -is [byte[]]) {
            $settings[$name] = [byte[]]$property.Value
        }
    }
    foreach ($name in @('UseVncAuthentication', 'UseControlAuthentication')) {
        $property = $values.PSObject.Properties[$name]
        if ($property -and ($property.Value -is [int] -or $property.Value -is [uint32])) {
            $settings[$name] = [int]$property.Value
        }
    }
    $marker = $values.PSObject.Properties[(Get-TightVncRestartMarkerName)]
    if ($marker -and ($marker.Value -is [int] -or $marker.Value -is [uint32]) -and [int]$marker.Value -eq 1) {
        $settings.RestartPending = $true
    }
    return $settings
}

function Test-TightVncServerSecured {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [hashtable]$Settings
    )

    if ($null -eq $Settings) {
        return $false
    }
    foreach ($name in @('Password', 'ControlPassword')) {
        $value = $Settings[$name]
        if (-not ($value -is [byte[]]) -or $value.Length -ne 8) {
            return $false
        }
    }
    return ($Settings['UseVncAuthentication'] -eq 1 -and $Settings['UseControlAuthentication'] -eq 1)
}

function Get-TightVncServerSecurityGap {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$Settings
    )

    if (Test-TightVncServerSecured -Settings $Settings) {
        return @()
    }
    $gaps = @()
    $hasPassword = $Settings['Password'] -is [byte[]] -and $Settings['Password'].Length -eq 8
    $hasControlPassword = $Settings['ControlPassword'] -is [byte[]] -and $Settings['ControlPassword'].Length -eq 8
    if ($null -ne $Settings['UseVncAuthentication'] -and $Settings['UseVncAuthentication'] -ne 1) {
        $gaps += 'VNC authentication is turned off (UseVncAuthentication), so TightVNC Server accepts every viewer WITHOUT a password'
    }
    elseif (-not $hasPassword) {
        $gaps += 'TightVNC Server has no password, so it refuses every viewer'
    }
    if (-not $hasControlPassword -or $Settings['UseControlAuthentication'] -ne 1) {
        $gaps += 'its control interface has no password, so any signed-in user can reconfigure or stop it from the TightVNC tray icon'
    }
    if ($gaps.Count -eq 0) {
        $gaps += 'UseVncAuthentication is not set to 1'
    }
    return $gaps
}

function Get-TightVncServerKeyAclProblem {
    param (
        [Parameter(Mandatory = $false)]
        [string]$Path = 'HKLM:\SOFTWARE\TightVNC\Server'
    )

    $allowedSids = @('S-1-5-18', 'S-1-5-32-544')
    $security = Get-DirectoryAccessSummary -Path $Path
    $problems = @()
    if ($allowedSids -notcontains $security.OwnerSid) {
        $problems += "it is owned by $($security.OwnerName) ($($security.OwnerSid))"
    }
    if (-not $security.InheritanceProtected) {
        $problems += 'it inherits permissions from its parent key'
    }
    foreach ($rule in @($security.AccessRules)) {
        if ($allowedSids -notcontains $rule.Sid) {
            $problems += "$($rule.Name) ($($rule.Sid)) has an access entry ($("$($rule.AccessControlType)".ToLowerInvariant()))"
        }
    }
    return $problems
}

function Protect-TightVncServerKey {
    param (
        [Parameter(Mandatory = $false)]
        [string]$SubKey = 'SOFTWARE\TightVNC\Server',

        [Parameter(Mandatory = $false)]
        [ValidateSet('LocalMachine', 'CurrentUser')]
        [string]$Hive = 'LocalMachine'
    )

    $security = New-Object System.Security.AccessControl.RegistrySecurity
    $security.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $rule = New-Object System.Security.AccessControl.RegistryAccessRule -ArgumentList @(
            (New-Object System.Security.Principal.SecurityIdentifier -ArgumentList $sid),
            [System.Security.AccessControl.RegistryRights]::FullControl,
            [System.Security.AccessControl.InheritanceFlags]::ContainerInherit,
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        $security.AddAccessRule($rule)
    }

    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]$Hive, [Microsoft.Win32.RegistryView]::Default)
    $key = $null
    $parent = $null
    try {
        $key = $baseKey.OpenSubKey($SubKey, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, [System.Security.AccessControl.RegistryRights]'ReadKey, ChangePermissions')
        if ($null -ne $key) {
            $key.SetAccessControl($security)
            return
        }
        $separator = $SubKey.LastIndexOf('\')
        if ($separator -gt 0) {
            $parent = $baseKey.CreateSubKey($SubKey.Substring(0, $separator))
        }
        $key = $baseKey.CreateSubKey($SubKey, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, $security)
    }
    finally {
        if ($key) {
            $key.Dispose()
        }
        if ($parent) {
            $parent.Dispose()
        }
        $baseKey.Dispose()
    }
}

function Set-TightVncServerValue {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [object]$Value,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Binary', 'DWord')]
        [string]$Kind,

        [Parameter(Mandatory = $false)]
        [string]$SubKey = 'SOFTWARE\TightVNC\Server',

        [Parameter(Mandatory = $false)]
        [ValidateSet('LocalMachine', 'CurrentUser')]
        [string]$Hive = 'LocalMachine'
    )

    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]$Hive, [Microsoft.Win32.RegistryView]::Default)
    $key = $null
    try {
        $key = $baseKey.OpenSubKey($SubKey, $true)
        if ($null -eq $key) {
            throw "the key $Hive\$SubKey does not exist"
        }
        $key.SetValue($Name, $Value, [Microsoft.Win32.RegistryValueKind]$Kind)
    }
    finally {
        if ($key) {
            $key.Dispose()
        }
        $baseKey.Dispose()
    }
}

function Remove-TightVncServerValue {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $false)]
        [string]$SubKey = 'SOFTWARE\TightVNC\Server',

        [Parameter(Mandatory = $false)]
        [ValidateSet('LocalMachine', 'CurrentUser')]
        [string]$Hive = 'LocalMachine'
    )

    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]$Hive, [Microsoft.Win32.RegistryView]::Default)
    $key = $null
    try {
        $key = $baseKey.OpenSubKey($SubKey, $true)
        if ($key) {
            $key.DeleteValue($Name, $false)
        }
    }
    finally {
        if ($key) {
            $key.Dispose()
        }
        $baseKey.Dispose()
    }
}

function Set-TightVncServerKeyProtection {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [bool]$KeyExists
    )

    try {
        $aclProblems = @()
        if ($KeyExists) {
            $aclProblems = @(Get-TightVncServerKeyAclProblem -Path $Path)
        }
        if (-not $KeyExists -or $aclProblems.Count -gt 0) {
            Protect-TightVncServerKey
            $aclProblems = @(Get-TightVncServerKeyAclProblem -Path $Path)
            if ($aclProblems.Count -gt 0) {
                return ("could not limit {0} to SYSTEM and Administrators: {1}" -f $Path, ($aclProblems -join '; '))
            }
            Write-Info "TightVNC: limited $Path to SYSTEM and Administrators, so other accounts cannot read the stored passwords."
        }
    }
    catch {
        return "could not limit $Path to SYSTEM and Administrators ($($_.Exception.Message))"
    }
    return $null
}

function Initialize-TightVncSecretForRun {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [array]$Apps,

        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive,

        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    $configuresTightVnc = @($Apps | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['postInstall'] -is [string] -and $_['postInstall'] -eq 'Set-TightVncServerPassword' }).Count -gt 0
    if (-not $configuresTightVnc) {
        return
    }

    if ($WhatIf) {
        Write-TightVncSecretPreview -NonInteractive:$NonInteractive
        return
    }

    Clear-TightVncSecret
    Import-TightVncSecretFromEnvironment
    $serverSecured = $false
    if ($null -eq $script:TightVncSecret.Password -and -not $NonInteractive) {
        try {
            $serverSecured = Test-TightVncServerSecured -Settings (Get-TightVncServerSettings)
        }
        catch {
            $serverSecured = $false
        }
    }
    [void](Get-TightVncSecret -NonInteractive:$NonInteractive -ServerSecured:$serverSecured)
    $script:TightVncSecret.PromptDone = $true
}

function Write-TightVncSecretPreview {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive
    )

    foreach ($entry in @(
            @{ Name = 'WINGET_APP_SETUP_TIGHTVNC_PASSWORD'; What = 'server password' },
            @{ Name = 'WINGET_APP_SETUP_TIGHTVNC_CONTROL_PASSWORD'; What = 'control password' }
        )) {
        $value = [System.Environment]::GetEnvironmentVariable($entry.Name)
        $isSet = -not [string]::IsNullOrEmpty($value)
        $problem = $null
        $longerThanEight = $false
        if ($isSet) {
            $longerThanEight = $value.Length -gt 8
            $characters = $value.ToCharArray()
            $secure = New-Object System.Security.SecureString
            try {
                foreach ($character in $characters) {
                    $secure.AppendChar($character)
                }
                $encoded = ConvertTo-TightVncPasswordBytes -Password $secure
                [Array]::Clear($encoded, 0, $encoded.Length)
            }
            catch {
                $problem = $_.Exception.Message
            }
            finally {
                [Array]::Clear($characters, 0, $characters.Length)
                $secure.Dispose()
            }
        }
        $value = $null

        if ($isSet -and $problem) {
            Write-WarningMessage "[DRY-RUN] TightVNC: $($entry.Name) is set (value not shown), but a real run could not use it: $problem"
        }
        elseif ($isSet) {
            $note = ''
            if ($longerThanEight) {
                $note = ' It is longer than 8 characters: TightVNC uses only the first 8.'
            }
            Write-Info "[DRY-RUN] TightVNC: a real run would set the $($entry.What) from $($entry.Name) (value not shown).$note"
        }
        elseif ($entry.What -eq 'control password') {
            Write-Info "[DRY-RUN] TightVNC: $($entry.Name) is not set: a real run would protect the control interface with the server password."
        }
        elseif ($NonInteractive) {
            Write-WarningMessage "[DRY-RUN] TightVNC: $($entry.Name) is not set: unless TightVNC Server already has its passwords, a real run would report TightVNC as installed but NOT configured."
        }
        else {
            Write-Info "[DRY-RUN] TightVNC: $($entry.Name) is not set: unless TightVNC Server already has its passwords, a real run would ask for the server password at its start."
        }
    }
}

function Set-TightVncServerPassword {
    param (
        [Parameter(Mandatory = $false, Position = 0)]
        [AllowNull()]
        [object]$App
    )

    $keyPath = 'HKLM:\SOFTWARE\TightVNC\Server'
    $serviceName = 'tvnserver'
    $restartMarker = Get-TightVncRestartMarkerName
    $howToSupply = 'set WINGET_APP_SETUP_TIGHTVNC_PASSWORD (and, better, a different WINGET_APP_SETUP_TIGHTVNC_CONTROL_PASSWORD) in the environment of the run, for example in the RMM script, or run the installer interactively to be asked for it, then run the installer again'

    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if ($null -eq $service) {
        $reason = 'the TightVNC Server service (tvnserver) is not installed, so there is no server to configure'
        Write-WarningMessage "TightVNC installed but NOT configured: $reason."
        return @{ Status = 'NotConfigured'; Reason = $reason }
    }

    $settings = $null
    $after = $null
    $passwordBytes = $null
    $controlBytes = $null
    try {
        try {
            $settings = Get-TightVncServerSettings -Path $keyPath
        }
        catch {
            return @{ Status = 'Failed'; Reason = "could not read $keyPath ($($_.Exception.Message))" }
        }
        $serverSecured = Test-TightVncServerSecured -Settings $settings
        $secret = Get-TightVncSecret -NonInteractive:(Test-EffectiveNonInteractive) -ServerSecured:$serverSecured

        if ($secret.Password) {
            $source = $secret.PasswordSource
            try {
                $passwordBytes = ConvertTo-TightVncPasswordBytes -Password $secret.Password
            }
            catch {
                $reason = "the server password from $source cannot be used: $($_.Exception.Message)"
                Write-WarningMessage "TightVNC installed but NOT configured: $reason Fix it and run the installer again."
                return @{ Status = 'NotConfigured'; Reason = $reason }
            }
            if ($secret.Password.Length -gt 8) {
                Write-WarningMessage "TightVNC: the server password from $source is longer than 8 characters. TightVNC uses only the first 8: viewers must type those 8."
            }
            if ($secret.ControlPassword) {
                try {
                    $controlBytes = ConvertTo-TightVncPasswordBytes -Password $secret.ControlPassword
                }
                catch {
                    $reason = "the control password from $($secret.ControlPasswordSource) cannot be used: $($_.Exception.Message)"
                    Write-WarningMessage "TightVNC installed but NOT configured: $reason Fix it and run the installer again."
                    return @{ Status = 'NotConfigured'; Reason = $reason }
                }
                if ($secret.ControlPassword.Length -gt 8) {
                    Write-WarningMessage "TightVNC: the control password from $($secret.ControlPasswordSource) is longer than 8 characters. TightVNC uses only the first 8."
                }
                if (Test-TightVncBytesEqual -First $passwordBytes -Second $controlBytes) {
                    Write-WarningMessage 'TightVNC: the control password is the same as the server password. A different one is better: anyone who knows the server password can change the server settings from the TightVNC tray icon.'
                }
            }
            else {
                $existingControl = $settings.ControlPassword
                $keepsControl = $existingControl -is [byte[]] -and $existingControl.Length -eq 8 -and
                    $settings.UseControlAuthentication -eq 1 -and
                    -not (Test-TightVncBytesEqual -First $existingControl -Second $settings.Password)
                if ($keepsControl) {
                    $controlBytes = [byte[]]$existingControl.Clone()
                    Write-Info 'TightVNC: no control password was supplied (WINGET_APP_SETUP_TIGHTVNC_CONTROL_PASSWORD); keeping the separate control password TightVNC Server already has.'
                    if (Test-TightVncBytesEqual -First $passwordBytes -Second $controlBytes) {
                        Write-WarningMessage 'TightVNC: the control password is the same as the server password. A different one is better: anyone who knows the server password can change the server settings from the TightVNC tray icon.'
                    }
                }
                else {
                    $controlBytes = [byte[]]$passwordBytes.Clone()
                    Write-WarningMessage 'TightVNC: no separate control password was supplied (WINGET_APP_SETUP_TIGHTVNC_CONTROL_PASSWORD), so the server password also protects the control interface. A different control password is better: anyone who knows the server password can then change the server settings from the TightVNC tray icon.'
                }
            }
            Write-Info "TightVNC: setting the server password from $source (value not shown)."
        }
        elseif (-not $serverSecured) {
            $why = 'no server password was supplied'
            if ($secret.PromptReason) {
                $why = $secret.PromptReason
            }
            $gaps = @(Get-TightVncServerSecurityGap -Settings $settings)
            if ($null -ne $settings.Password -or $null -ne $settings.ControlPassword) {
                $protectionProblem = Set-TightVncServerKeyProtection -Path $keyPath -KeyExists ([bool]$settings.KeyExists)
                if ($protectionProblem) {
                    return @{ Status = 'Failed'; Reason = $protectionProblem }
                }
            }
            $sentences = @($gaps | ForEach-Object { $_.Substring(0, 1).ToUpperInvariant() + $_.Substring(1) + '.' })
            Write-WarningMessage ("TightVNC installed but NOT configured: {0}. {1} To fix it, {2}." -f $why, ($sentences -join ' '), $howToSupply)
            return @{ Status = 'NotConfigured'; Reason = ("{0}; {1}; set WINGET_APP_SETUP_TIGHTVNC_PASSWORD or run the installer interactively, then run it again" -f $why, ($gaps -join '; ')) }
        }
        else {
            Write-Info 'TightVNC: TightVNC Server already has a server password and a control password; keeping them. To change them, set WINGET_APP_SETUP_TIGHTVNC_PASSWORD (and WINGET_APP_SETUP_TIGHTVNC_CONTROL_PASSWORD) and run the installer again.'
        }

        $protectionProblem = Set-TightVncServerKeyProtection -Path $keyPath -KeyExists ([bool]$settings.KeyExists)
        if ($protectionProblem) {
            return @{ Status = 'Failed'; Reason = $protectionProblem }
        }

        $changed = @()
        if ($passwordBytes) {
            $desired = @(
                @{ Name = 'Password'; Value = $passwordBytes; Type = 'Binary' },
                @{ Name = 'UseVncAuthentication'; Value = 1; Type = 'DWord' },
                @{ Name = 'ControlPassword'; Value = $controlBytes; Type = 'Binary' },
                @{ Name = 'UseControlAuthentication'; Value = 1; Type = 'DWord' }
            )
            $toWrite = @()
            foreach ($value in $desired) {
                $current = $settings[$value.Name]
                $same = $false
                if ($value.Type -eq 'Binary') {
                    $same = Test-TightVncBytesEqual -First $current -Second $value.Value
                }
                else {
                    $same = $current -eq $value.Value
                }
                if (-not $same) {
                    $toWrite += $value
                }
            }
            try {
                if ($toWrite.Count -gt 0) {
                    Set-TightVncServerValue -Name $restartMarker -Value 1 -Kind 'DWord'
                    foreach ($value in $toWrite) {
                        Set-TightVncServerValue -Name $value.Name -Value $value.Value -Kind $value.Type
                        $changed += $value.Name
                    }
                }
                $after = Get-TightVncServerSettings -Path $keyPath
            }
            catch {
                return @{ Status = 'Failed'; Reason = "could not write the passwords to $keyPath ($($_.Exception.Message))" }
            }
            $readBackMatches = (Test-TightVncBytesEqual -First $after.Password -Second $passwordBytes) -and
                (Test-TightVncBytesEqual -First $after.ControlPassword -Second $controlBytes) -and
                $after.UseVncAuthentication -eq 1 -and $after.UseControlAuthentication -eq 1
            if (-not $readBackMatches) {
                return @{ Status = 'Failed'; Reason = "the values read back from $keyPath are not the ones written" }
            }
        }
        elseif (Test-TightVncBytesEqual -First $settings.Password -Second $settings.ControlPassword) {
            Write-WarningMessage 'TightVNC: the control password is the same as the server password. A different one (WINGET_APP_SETUP_TIGHTVNC_CONTROL_PASSWORD) is better: anyone who knows the server password can change the server settings from the TightVNC tray icon.'
        }

        $restartNeeded = $changed.Count -gt 0 -or [bool]$settings.RestartPending
        try {
            if ($restartNeeded) {
                if ("$($service.Status)" -eq 'Stopped') {
                    Start-Service -Name $serviceName -ErrorAction Stop
                }
                else {
                    Restart-Service -Name $serviceName -ErrorAction Stop
                }
                if ($changed.Count -gt 0) {
                    Write-Info ("TightVNC: wrote {0} (values not shown) and restarted the TightVNC Server service." -f ($changed -join ', '))
                }
                else {
                    Write-Info 'TightVNC: restarted the TightVNC Server service, which had not loaded the passwords written to it earlier (that restart failed or was interrupted).'
                }
            }
            else {
                if ($passwordBytes) {
                    Write-Info 'TightVNC: the server already has these passwords; nothing to change.'
                }
                if ("$($service.Status)" -ne 'Running') {
                    Start-Service -Name $serviceName -ErrorAction Stop
                    Write-Info 'TightVNC: started the TightVNC Server service, which was not running.'
                }
            }
            $status = "$((Get-Service -Name $serviceName -ErrorAction Stop).Status)"
        }
        catch {
            return @{ Status = 'Failed'; Reason = "could not restart the TightVNC Server service (tvnserver) ($($_.Exception.Message))" }
        }
        if ($status -ne 'Running') {
            return @{ Status = 'Failed'; Reason = "the TightVNC Server service (tvnserver) is $status, not Running" }
        }
        if ($restartNeeded) {
            try {
                Remove-TightVncServerValue -Name $restartMarker
            }
            catch {
                Write-WarningMessage "TightVNC: could not remove the $restartMarker marker from $keyPath ($($_.Exception.Message)); the next run restarts the TightVNC Server service once more."
            }
        }
        return 'Configured'
    }
    finally {
        foreach ($buffer in @($passwordBytes, $controlBytes)) {
            if ($buffer) {
                [Array]::Clear($buffer, 0, $buffer.Length)
            }
        }
        foreach ($read in @($settings, $after)) {
            if ($read) {
                foreach ($name in @('Password', 'ControlPassword')) {
                    if ($read[$name]) {
                        [Array]::Clear($read[$name], 0, $read[$name].Length)
                    }
                }
            }
        }
    }
}

# --- UserPhaseSupport ---
function Get-InstallerRunRecordPath {
    return (Join-Path $env:ProgramData 'winget-app-setup\logs\last-run.json')
}

function Get-UserPhaseStatePath {
    return (Join-Path $env:LOCALAPPDATA 'winget-app-setup\user-phase.json')
}

function Get-Sha256Hex {
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]]$Bytes
    )

    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-', '')
    }
    finally {
        $algorithm.Dispose()
    }
}

function Get-RunRecordTrustProblem {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $trustedSids = @('S-1-5-18', 'S-1-5-32-544')
    $changeRights = 0x2 -bor 0x4 -bor 0x10000 -bor 0x40000 -bor 0x80000 -bor 0x10000000 -bor 0x40000000
    try {
        $security = Get-DirectoryAccessSummary -Path $Path
    }
    catch {
        return "its owner and access list could not be read ($($_.Exception.Message))"
    }

    $problems = @()
    if ($trustedSids -notcontains [string]$security.OwnerSid) {
        $problems += "it is owned by $($security.OwnerName) ($($security.OwnerSid)), not by SYSTEM or Administrators"
    }
    foreach ($rule in @($security.AccessRules)) {
        if ($null -eq $rule -or [string]$rule.AccessControlType -ne 'Allow' -or $rule.InheritOnly -or $trustedSids -contains [string]$rule.Sid) {
            continue
        }
        if (([long]$rule.Rights -band $changeRights) -ne 0) {
            $problems += "$($rule.Name) ($($rule.Sid)) can change it"
        }
    }
    if ($problems.Count -eq 0) {
        return $null
    }
    return ($problems -join '; ')
}

function Read-InstallerRunRecord {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    $stream = $null
    try {
        $stream = Open-ReadLockedFile -Path $Path
        $trustProblem = Get-RunRecordTrustProblem -Path $Path
        if ($trustProblem) {
            Write-WarningMessage "Ignoring the run record ${Path}: $trustProblem. Only a record that SYSTEM or an administrator wrote is used, since the apps it defers are installed in every account that signs in. The next run of the installer for the whole PC replaces it."
            return $null
        }
        $buffer = New-Object System.IO.MemoryStream
        $stream.CopyTo($buffer)
        $bytes = $buffer.ToArray()
        $text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes).TrimStart([char]0xFEFF)
        $record = ConvertFrom-Json -InputObject $text -ErrorAction Stop
    }
    catch {
        Write-WarningMessage "Could not read the run record ${Path}: $($_.Exception.Message)"
        return $null
    }
    finally {
        if ($stream) {
            $stream.Dispose()
        }
    }
    if ($null -eq $record -or $null -eq $record.PSObject.Properties['apps']) {
        Write-WarningMessage "The run record $Path has no apps list; ignoring it."
        return $null
    }

    $deferred = @()
    $invalid = @()
    foreach ($app in @($record.apps)) {
        if ($null -eq $app -or [string]$app.status -ne 'Deferred') {
            continue
        }
        $id = [string]$app.id
        if (-not (Test-WingetPackageIdFormat -PackageId $id)) {
            $invalid += $id
        }
        elseif ($deferred -notcontains $id) {
            $deferred += $id
        }
    }

    $exitCode = $null
    if ($null -ne $record.exitCode) {
        $exitCode = [int]$record.exitCode
    }
    $startedUtc = $null
    if ($record.startedUtc -is [DateTime]) {
        $startedUtc = Format-RunRecordTime -Time $record.startedUtc
    }
    elseif ($null -ne $record.startedUtc) {
        $startedUtc = [string]$record.startedUtc
    }
    $buildId = $null
    if ($record.buildId) {
        $buildId = [string]$record.buildId
    }

    return [pscustomobject]@{
        Path               = $Path
        Sha256             = Get-Sha256Hex -Bytes $bytes
        BuildId            = $buildId
        StartedUtc         = $startedUtc
        ExitCode           = $exitCode
        DeferredApps       = [string[]]$deferred
        InvalidDeferredIds = [string[]]$invalid
    }
}

function Read-UserPhaseState {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    try {
        $state = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($Path)) -ErrorAction Stop
    }
    catch {
        Write-WarningMessage "Could not read the user-phase state ${Path}: $($_.Exception.Message)"
        return $null
    }
    if ($null -eq $state) {
        return $null
    }
    $attempts = 0
    if ($null -ne $state.attempts) {
        $attempts = [int]$state.attempts
    }
    return [pscustomobject]@{
        RecordSha256 = [string]$state.recordSha256
        Complete     = ($state.complete -eq $true)
        Attempts     = $attempts
    }
}

function Get-UserPhaseDecision {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Record,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$State,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 100)]
        [int]$MaxAttempts
    )

    if ($null -eq $Record) {
        return [pscustomobject]@{ Run = $false; Reason = 'NoRecord'; Attempt = 0 }
    }
    if ($null -eq $Record.ExitCode) {
        return [pscustomobject]@{ Run = $false; Reason = 'RunNotFinished'; Attempt = 0 }
    }
    if ($null -ne $State -and [string]::Equals([string]$State.RecordSha256, [string]$Record.Sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
        if ($State.Complete) {
            return [pscustomobject]@{ Run = $false; Reason = 'Done'; Attempt = 0 }
        }
        if ([int]$State.Attempts -ge $MaxAttempts) {
            return [pscustomobject]@{ Run = $false; Reason = 'GaveUp'; Attempt = 0 }
        }
        return [pscustomobject]@{ Run = $true; Reason = 'Pending'; Attempt = [int]$State.Attempts + 1 }
    }
    return [pscustomobject]@{ Run = $true; Reason = 'New'; Attempt = 1 }
}

function Save-UserPhaseState {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$State
    )

    $directory = Split-Path -Parent $Path
    $temporaryPath = Join-Path $directory ('user-phase.{0}.tmp' -f [System.Guid]::NewGuid().ToString('N'))
    try {
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            [void](New-Item -Path $directory -ItemType Directory -Force -ErrorAction Stop)
        }
        $json = ConvertTo-Json -InputObject $State -Depth 6
        [System.IO.File]::WriteAllText($temporaryPath, $json, (New-Object System.Text.UTF8Encoding($false)))
        [System.IO.File]::Move($temporaryPath, $Path, $true)
        return $Path
    }
    catch {
        Write-WarningMessage "Could not write the user-phase state ${Path}: $($_.Exception.Message)"
        try {
            if (Test-Path -LiteralPath $temporaryPath) {
                Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction Stop
            }
        }
        catch {
        }
        return $null
    }
}

function Install-UserPhaseApp {
    param (
        [Parameter(Mandatory = $true)]
        [string]$PackageId,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [hashtable]$App,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 86400)]
        [int]$TimeoutSeconds
    )

    $checkTimeoutSeconds = Get-ProcessTimeoutSeconds -Operation WingetListCheck
    $preCheck = Test-WingetPackageInstalled -PackageId $PackageId -TimeoutSeconds $checkTimeoutSeconds
    if ($preCheck.Installed) {
        Write-WarningMessage "Skipping: $PackageId (already installed)"
        return (Complete-UserPhaseAppConfiguration -App $App -Record (New-AppRunRecord -Id $PackageId -Status 'Skipped' -Reason 'already installed'))
    }
    $preCheckReason = $null
    if ($preCheck.TimedOut) {
        $preCheckReason = 'PreCheckTimeout'
    }
    elseif ($preCheck.LaunchFailed) {
        $preCheckReason = 'PreCheckLaunchFailed'
    }
    elseif ($preCheck.CheckFailed) {
        $preCheckReason = 'PreCheckFailed'
    }
    if ($preCheckReason) {
        $reason = Format-InstallFailureReason -FailureReason $preCheckReason -LaunchError $preCheck.LaunchError -CheckExitCode $preCheck.ExitCode
        Write-ErrorMessage "Failed to install: $PackageId ($reason)."
        return (New-AppRunRecord -Id $PackageId -Status 'Failed' -Reason $reason)
    }

    Write-Info "Installing for this account: $PackageId"
    $installParameters = @{
        PackageId                    = $PackageId
        UserScopeOnly                = $true
        Silent                       = $true
        TimeoutSeconds               = $TimeoutSeconds
        InstallInProgressRetries     = 1
        InstallInProgressWaitSeconds = [Math]::Min(120, $TimeoutSeconds)
    }
    if ($null -ne $App -and -not [string]::IsNullOrWhiteSpace([string]$App['installerType'])) {
        $installParameters['InstallerType'] = [string]$App['installerType']
    }
    $installResult = Install-WingetPackage @installParameters
    $reportedResult = $installResult.Clone()
    $reportedResult.Remove('MachineScopeFellBack')

    $failureReason = $null
    $launchError = $null
    $checkExitCode = $null
    $restartRequired = $false
    if ($installResult.LaunchErrorExhausted) {
        $failureReason = 'InstallLaunchFailed'
        $launchError = $installResult.LaunchError
    }
    elseif ($installResult.NoUserScopeInstaller) {
        $failureReason = 'NoUserScopeInstaller'
    }
    else {
        $verify = Test-WingetPackageInstalled -PackageId $PackageId -TimeoutSeconds $checkTimeoutSeconds
        if ($verify.Installed) {
            Write-Success "Successfully installed for this account: $PackageId"
            $restartRequired = [bool](Write-InstalledAppNote -AppName $PackageId -InstallResult $installResult)
            return (Complete-UserPhaseAppConfiguration -App $App -Record (New-AppRunRecord -Id $PackageId -Status 'Installed' -InstallResult $installResult -RestartRequired $restartRequired))
        }
        if ($verify.TimedOut) {
            $failureReason = 'VerifyTimeout'
        }
        elseif ($verify.LaunchFailed) {
            $failureReason = 'VerifyLaunchFailed'
            $launchError = $verify.LaunchError
        }
        elseif ($verify.CheckFailed) {
            $failureReason = 'VerifyFailed'
            $checkExitCode = $verify.ExitCode
        }
        else {
            $failureReason = 'VerifyNotFound'
        }
    }
    $reason = Format-InstallFailureReason -FailureReason $failureReason -InstallResult $reportedResult -LaunchError $launchError -CheckExitCode $checkExitCode
    Write-ErrorMessage "Failed to install: $PackageId ($reason)."
    return (New-AppRunRecord -Id $PackageId -Status 'Failed' -Reason $reason -InstallResult $installResult)
}

function Get-UserPhaseCatalogEntry {
    $entries = @{}
    try {
        foreach ($app in @(Get-DefaultAppCatalog)) {
            if ($app -is [hashtable] -and -not [string]::IsNullOrWhiteSpace([string]$app['name']) -and -not $entries.ContainsKey([string]$app['name'])) {
                $entries[[string]$app['name']] = $app
            }
        }
    }
    catch {
        Write-WarningMessage "Could not read this installer's app catalog, so the deferred apps are installed without their catalog settings (post-install configuration, installer type): $($_.Exception.Message)"
    }
    return $entries
}

function Complete-UserPhaseAppConfiguration {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [hashtable]$App,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Record
    )

    if ($null -eq $App -or $null -eq $App['postInstall']) {
        return $Record
    }
    $configuration = Invoke-AppPostInstall -App $App
    $Record['postInstall'] = [string]$configuration.Status
    $Record['postInstallReason'] = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$configuration.Reason)) {
        $Record['postInstallReason'] = [string]$configuration.Reason
    }
    if ($configuration.Status -eq 'Failed') {
        $reason = Format-InstallFailureReason -FailureReason 'PostInstallFailed' -PostInstallReason $configuration.Reason
        Write-ErrorMessage "Failed to install: $($Record['id']) ($reason)."
        $Record['status'] = 'Failed'
        $Record['reason'] = $reason
        return $Record
    }
    [void](Write-AppPostInstallResult -AppName ([string]$Record['id']) -Configuration $configuration)
    return $Record
}

function Update-UserPhaseWingetSource {
    Write-Info 'Updating the winget source for this account (this may take a moment)...'
    $source = Invoke-WingetSourceProbe
    if ($source.Succeeded) {
        Write-Success 'The winget source is up to date for this account.'
        return
    }
    if ($source.ExitCode -eq -1978335162) {
        Write-Info 'The winget source agreements are not accepted for this account yet (0x8A150046); each install accepts them.'
        return
    }
    $detail = 'it did not finish in time and was stopped'
    if ($source.LaunchError) {
        $detail = "winget could not be started: $($source.LaunchError)"
    }
    elseif (-not $source.TimedOut) {
        $detail = 'exit code {0}' -f (Format-WingetExitCode -ExitCode $source.ExitCode)
    }
    Write-WarningMessage "The winget source could not be updated for this account ($detail). The installs may fail; a later sign-in tries again."
}

function Get-UserPhaseElapsedSeconds {
    param (
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Stopwatch]$Stopwatch
    )

    return [int]$Stopwatch.Elapsed.TotalSeconds
}

# --- WauSupport ---
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

function Assert-RestrictedDirectoryAcl {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $false)]
        [switch]$ReadableByUsers
    )

    $allowedSids = @('S-1-5-18', 'S-1-5-32-544')
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
            Arguments   = "`"$Path`" /inheritance:r /grant:r $grants /L /q"
            Description = 'restrict'
        }
    )
    foreach ($step in $steps) {
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
    if (Test-FileSystemLink -Path $Path) {
        throw (New-DirectoryIsLinkError -Path $Path -Message ("'{0}' was replaced by a link (a junction or symbolic link) while its access list was being set, so it is not used." -f $Path))
    }
    if ($failure) {
        $exception = [System.InvalidOperationException]::new($failure)
        throw [System.Management.Automation.ErrorRecord]::new($exception, 'RestrictedDirectoryAclFailed', [System.Management.Automation.ErrorCategory]::SecurityError, $Path)
    }
}

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

function Open-ReadLockedFile {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
}

function New-WauStagingDirectory {
    param (
        [Parameter(Mandatory = $false)]
        [ValidatePattern('^[A-Za-z0-9-]+\z')]
        [string]$Prefix = 'wau-msi'
    )

    $baseDir = Initialize-ProgramDataFolder

    $stagingDir = Join-Path $baseDir ($Prefix + '-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -Path $stagingDir -ItemType Directory -ErrorAction Stop
    Set-RestrictedDirectoryAcl -Path $stagingDir
    return $stagingDir
}

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

function Get-DefaultWindowsAppRuntimeRequirement {
    return [pscustomobject]@{
        Frameworks = @([pscustomobject]@{ Name = 'Microsoft.WindowsAppRuntime.1.8'; MinimumVersion = [version]'8000.616.304.0' })
        Source     = 'BuiltIn'
        Detail     = 'the built-in requirement'
    }
}

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

function Get-WindowsAppRuntimeRequirement {
    $url = 'https://github.com/microsoft/winget-cli/releases/latest/download/DesktopAppInstaller_Dependencies.json'
    $fallback = Get-DefaultWindowsAppRuntimeRequirement
    $fallbackText = Format-WindowsAppRuntimeRequirement -Frameworks @($fallback.Frameworks)

    $frameworks = @()
    try {
        $architecture = $null
        try {
            $architecture = Get-OSArchitecture
        }
        catch {
            $architecture = $null
        }
        $timeouts = Get-WebDownloadTimeoutParameters -Lookup
        $response = Invoke-WebRequest @timeouts -Uri $url -UseBasicParsing -ErrorAction Stop
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
            Set-ItemProperty -LiteralPath $wauKey -Name 'WAU_UpdatesAtLogon' -Value ([int]0) -ErrorAction Stop
        }
    }
    catch {
        Write-WarningMessage "Could not remove the Winget-AutoUpdate at-logon trigger: $_"
    }
    return $removed
}

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

# --- WindowsAppRuntime ---
function Get-WindowsAppRuntimePin {
    return @{
        Release          = '1.8.12'
        NuGetVersion     = '1.8.260921001'
        FrameworkName    = 'Microsoft.WindowsAppRuntime.1.8'
        FrameworkVersion = '8000.994.2142.0'
        PackageUrl       = 'https://api.nuget.org/v3-flatcontainer/microsoft.windowsappsdk.runtime/1.8.260921001/microsoft.windowsappsdk.runtime.1.8.260921001.nupkg'
        SignerCommonName = 'Microsoft Corporation'
        Frameworks       = @{
            X64   = @{
                Entry  = 'tools/MSIX/win10-x64/Microsoft.WindowsAppRuntime.1.8.msix'
                Size   = 43025663
                Sha256 = '07AF369968CD15C56A7FC8865B7190643A7ADEF49B8191752FF17094E4EFE504'
            }
            X86   = @{
                Entry  = 'tools/MSIX/win10-x86/Microsoft.WindowsAppRuntime.1.8.msix'
                Size   = 21691200
                Sha256 = '0AF2A0E5FD6ED43D46240F930A5FDC6FCAB46DA5ACF10FA12C4A7AEE0FC9A74C'
            }
            Arm64 = @{
                Entry  = 'tools/MSIX/win10-arm64/Microsoft.WindowsAppRuntime.1.8.msix'
                Size   = 40928160
                Sha256 = '9D6FE2B8D795859D725B4E1C25A4F7646C852BECB91D9D360B82BC32589E052F'
            }
        }
    }
}

function Get-WindowsAppRuntimeProvisionedInfo {
    $query = "Get-AppxProvisionedPackage -Online -ErrorAction Stop | Where-Object { `$_.DisplayName -eq 'Microsoft.WindowsAppRuntime.1.8' } | ForEach-Object { `$_.PackageName }"
    if ($PSVersionTable.PSEdition -eq 'Core') {
        $lines = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $query)
        if ($LASTEXITCODE -ne 0) {
            throw "Get-AppxProvisionedPackage failed in Windows PowerShell (exit code $LASTEXITCODE)."
        }
    }
    else {
        $lines = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop |
                Where-Object { $_.DisplayName -eq 'Microsoft.WindowsAppRuntime.1.8' } |
                ForEach-Object { $_.PackageName })
    }

    $architectures = @{ x64 = 'X64'; x86 = 'X86'; arm64 = 'Arm64'; arm = 'Arm'; neutral = 'Neutral' }
    foreach ($line in $lines) {
        if ("$line".Trim() -match '^Microsoft\.WindowsAppRuntime\.1\.8_(?<version>\d+(\.\d+){1,3})_(?<arch>[A-Za-z0-9]+)_') {
            $architecture = $Matches.arch.ToLowerInvariant()
            if ($architectures.ContainsKey($architecture)) {
                [pscustomobject]@{ Version = [version]$Matches.version; Architecture = $architectures[$architecture] }
            }
        }
    }
}

function Expand-WindowsAppRuntimeMsix {
    param (
        [Parameter(Mandatory = $true)]
        [string]$PackagePath,

        [Parameter(Mandatory = $true)]
        [string]$EntryName,

        [Parameter(Mandatory = $true)]
        [long]$ExpectedSize,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )

    $archive = [System.IO.Compression.ZipFile]::OpenRead($PackagePath)
    try {
        $entry = $archive.GetEntry($EntryName)
        if (-not $entry) {
            throw "the package holds no $EntryName"
        }
        if ($entry.Length -ne $ExpectedSize) {
            throw ('{0} in the package is {1} bytes, not the pinned {2}' -f $EntryName, $entry.Length, $ExpectedSize)
        }
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $DestinationPath, $false)
    }
    finally {
        $archive.Dispose()
    }
}

function Test-WindowsAppRuntimeSignature {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$SignerCommonName
    )

    return (Test-AuthenticodeSigner -Path $Path -SignerCommonName $SignerCommonName)
}

function Install-WindowsAppRuntimeFramework {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Requirement,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$MissingFrameworks
    )

    $pin = Get-WindowsAppRuntimePin
    $reason = $null
    $status = $null
    $architecture = $null
    $framework = $null
    $unconfirmed = $false

    try {
        if ($null -eq $Requirement) {
            $Requirement = Get-DefaultWindowsAppRuntimeRequirement
        }
        $needed = @($Requirement.Frameworks)
        if ($MissingFrameworks) {
            $needed = @($MissingFrameworks)
        }
        $unmet = @($needed | Where-Object { $_.Name -ne $pin.FrameworkName -or [version]$pin.FrameworkVersion -lt [version]$_.MinimumVersion })
        if ($unmet.Count -gt 0) {
            $reason = ('the latest winget release needs {0}, and the framework this installer installs, {1} {2}, does not meet that; a newer version of this installer is needed' -f (Format-WindowsAppRuntimeRequirement -Frameworks $unmet), $pin.FrameworkName, $pin.FrameworkVersion)
        }

        if (-not $reason) {
            try {
                $architecture = Get-OSArchitecture
                $framework = $pin.Frameworks[$architecture]
                if (-not $framework) {
                    $reason = "Microsoft publishes no Windows App Runtime 1.8 framework for $architecture Windows"
                }
            }
            catch {
                $reason = "the OS architecture could not be read ($_)"
            }
        }

        if (-not $reason -and -not (Test-IsAdmin)) {
            $reason = 'installing it for all users needs administrator rights'
        }
        if (-not $reason) {
            $build = Get-WindowsBuildNumber
            if ($build -lt 17763) {
                $reason = "Windows build $build is older than 17763, the oldest the framework supports"
            }
        }
        if (-not $reason) {
            $provisioned = @()
            try {
                $provisioned = @(Get-WindowsAppRuntimeProvisionedInfo)
            }
            catch {
                Write-WarningMessage "Could not list the provisioned Microsoft.WindowsAppRuntime.1.8 packages: $_"
            }
            $newer = @($provisioned | Where-Object { $_.Architecture -eq $architecture -and $_.Version -ge [version]$pin.FrameworkVersion } | Sort-Object -Property Version -Descending)
            if ($newer.Count -gt 0) {
                $reason = ('Microsoft.WindowsAppRuntime.1.8 {0} ({1}) is already provisioned for this PC, at or above the pinned {2}, but no user has it; the installer does not replace it' -f $newer[0].Version, $architecture, $pin.FrameworkVersion)
            }
        }

        if (-not $reason) {
            Write-Info ('Microsoft.WindowsAppRuntime.1.8 is missing; installing the pinned Windows App Runtime {0} (framework {1}, {2}) for all users first...' -f $pin.Release, $pin.FrameworkVersion, $architecture)
            $stagingDir = $null
            $msixStream = $null
            $stage = 'setting up its download folder'
            try {
                $stagingDir = New-WauStagingDirectory -Prefix 'appruntime'

                $stage = "downloading $($pin.PackageUrl)"
                $packagePath = Join-Path $stagingDir ('microsoft.windowsappsdk.runtime.{0}.nupkg' -f $pin.NuGetVersion)
                Write-Info "Downloading Microsoft.WindowsAppSDK.Runtime $($pin.NuGetVersion) from NuGet.org (about 150 MB)..."
                $downloadTimeouts = Get-WebDownloadTimeoutParameters
                Invoke-WebRequest @downloadTimeouts -Uri $pin.PackageUrl -OutFile $packagePath -UseBasicParsing -ErrorAction Stop

                $stage = 'extracting the framework from the package'
                $msixPath = Join-Path $stagingDir 'Microsoft.WindowsAppRuntime.1.8.msix'
                Expand-WindowsAppRuntimeMsix -PackagePath $packagePath -EntryName $framework.Entry -ExpectedSize $framework.Size -DestinationPath $msixPath
                Remove-Item -LiteralPath $packagePath -Force -ErrorAction SilentlyContinue

                $stage = 'verifying the framework'
                $msixStream = Open-ReadLockedFile -Path $msixPath
                $actualHash = (Get-FileHash -InputStream $msixStream -Algorithm SHA256).Hash
                if ($actualHash -ne $framework.Sha256) {
                    $reason = "the downloaded framework's SHA256 is $actualHash, not the pinned $($framework.Sha256)"
                }
                else {
                    $signature = Test-WindowsAppRuntimeSignature -Path $msixPath -SignerCommonName $pin.SignerCommonName
                    if (-not $signature.Valid) {
                        $reason = "the downloaded framework failed its signature check: $($signature.Detail)"
                    }
                    else {
                        Write-Info "Verified its SHA256 and its signature ($($signature.Detail)); provisioning it for all users..."
                        $stage = 'provisioning the framework'
                        if (-not (Invoke-AppxProvisioning -PackagePath $msixPath -TimeoutSeconds (Get-ProcessTimeoutSeconds -Operation AppxProvisioning))) {
                            $reason = 'Add-AppxProvisionedPackage failed (its error is above); Windows Server without the Desktop Experience, or a policy that blocks app packages, cannot take it'
                        }
                    }
                }
            }
            catch {
                $reason = "$stage failed: $_"
                if ($_.FullyQualifiedErrorId -eq 'RestrictedDirectoryAclFailed') {
                    $baseDir = Join-Path $env:ProgramData 'winget-app-setup'
                    $reason += (Get-RestrictedDirectoryResetHint -Path $baseDir)
                }
            }
            finally {
                if ($msixStream) {
                    $msixStream.Dispose()
                }
                if ($stagingDir) {
                    Remove-Item -Path $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }

        if (-not $reason) {
            $status = Get-WindowsAppRuntimeStatus -Requirement $Requirement
            if ($status.Present -eq $false) {
                $reason = "Add-AppxProvisionedPackage reported success, but the framework is still not there ($($status.Detail))"
            }
            else {
                if ($status.Present -ne $true) {
                    $unconfirmed = $true
                    Write-WarningMessage "Add-AppxProvisionedPackage succeeded, but the check for Microsoft.WindowsAppRuntime.1.8 afterwards could not run ($($status.Detail)); going ahead as if it is there."
                }
                try {
                    $provisionedNow = @(Get-WindowsAppRuntimeProvisionedInfo | Where-Object { $_.Architecture -eq $architecture -and $_.Version -ge [version]$pin.FrameworkVersion })
                    if ($provisionedNow.Count -eq 0 -and $unconfirmed) {
                        Write-WarningMessage 'Get-AppxProvisionedPackage does not list Microsoft.WindowsAppRuntime.1.8 as provisioned for all users either, so nothing confirms the install; accounts that sign in for the first time may not get it.'
                    }
                    elseif ($provisionedNow.Count -eq 0) {
                        Write-WarningMessage 'Microsoft.WindowsAppRuntime.1.8 is now on this PC, but Get-AppxProvisionedPackage does not list it as provisioned for all users; accounts that sign in for the first time may not get it.'
                    }
                }
                catch {
                    Write-WarningMessage "Could not list the provisioned Microsoft.WindowsAppRuntime.1.8 packages to confirm the install: $_"
                }
            }
        }
    }
    catch {
        $reason = "unexpected error: $_"
    }

    if ($reason) {
        $reason = "$reason".Trim().TrimEnd('.')
        Write-ErrorMessage "Windows App Runtime: NOT INSTALLED - $reason."
        return [pscustomobject]@{ Installed = $false; Status = $status; Reason = $reason }
    }
    $unconfirmedNote = ''
    if ($unconfirmed) {
        $unconfirmedNote = ', not confirmed: the check afterwards could not run'
    }
    Write-Success ('Windows App Runtime: installed Microsoft.WindowsAppRuntime.1.8 {0} ({1}) for all users{2}.' -f $pin.FrameworkVersion, $architecture, $unconfirmedNote)
    return [pscustomobject]@{ Installed = $true; Status = $status; Reason = $null }
}

# --- WindowsInstallerState ---
function Test-WindowsInstallerBusy {
    param (
        [Parameter(Mandatory = $false)]
        [string]$Name = 'Global\_MSIExecute'
    )

    $mutex = $null
    $taken = $false
    try {
        if (-not [System.Threading.Mutex]::TryOpenExisting($Name, [ref]$mutex)) {
            return $false
        }
        try {
            $taken = $mutex.WaitOne(0)
        }
        catch [System.Threading.AbandonedMutexException] {
            $taken = $true
        }
        return (-not $taken)
    }
    catch [System.UnauthorizedAccessException] {
        return $true
    }
    catch {
        return $false
    }
    finally {
        if ($taken) {
            try {
                $mutex.ReleaseMutex()
            }
            catch {
            }
        }
        if ($null -ne $mutex) {
            $mutex.Dispose()
        }
    }
}

function Wait-WindowsInstallerIdle {
    param (
        [Parameter(Mandatory = $true)]
        [int]$MaximumSeconds,

        [Parameter(Mandatory = $false)]
        [int]$PollSeconds = 15,

        [Parameter(Mandatory = $false)]
        [string]$Name = 'Global\_MSIExecute'
    )

    if ($PollSeconds -lt 1) {
        $PollSeconds = 1
    }
    $waited = 0
    $busy = $true
    $nextProgressAt = 60
    while ($waited -lt $MaximumSeconds) {
        $step = [Math]::Min($PollSeconds, $MaximumSeconds - $waited)
        Start-Sleep -Seconds $step
        $waited += $step
        $busy = Test-WindowsInstallerBusy -Name $Name
        if (-not $busy) {
            break
        }
        if ($waited -ge $nextProgressAt -and $waited -lt $MaximumSeconds) {
            Write-Info ('Windows Installer is still busy with another installation ({0} of at most {1} seconds waited)...' -f $waited, $MaximumSeconds)
            $nextProgressAt += 60
        }
    }
    return [pscustomobject]@{ WaitedSeconds = $waited; Busy = $busy }
}

function Get-PendingRestartState {
    $componentServicing = $false
    try {
        $componentServicing = [bool](Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
    }
    catch {
        $componentServicing = $false
    }

    $windowsUpdate = $false
    try {
        $windowsUpdate = [bool](Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
    }
    catch {
        $windowsUpdate = $false
    }

    $fileRenames = @()
    try {
        $sessionManager = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction Stop
        $entries = @($sessionManager.PendingFileRenameOperations)
        for ($index = 0; $index -lt $entries.Count; $index += 2) {
            $source = [string]$entries[$index]
            $destination = ''
            if ($index + 1 -lt $entries.Count) {
                $destination = [string]$entries[$index + 1]
            }
            if ([string]::IsNullOrWhiteSpace($source) -or [string]::IsNullOrWhiteSpace($destination)) {
                continue
            }
            $fileRenames += ('{0} -> {1}' -f $source.Trim(), $destination.Trim())
        }
    }
    catch {
        $fileRenames = @()
    }

    return [pscustomobject]@{
        ComponentServicing = $componentServicing
        WindowsUpdate      = $windowsUpdate
        FileRenames        = @($fileRenames)
    }
}

function Get-PendingRestartReason {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$State,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Since
    )

    if ($null -eq $State) {
        return
    }

    $reasons = @()
    if ($State.ComponentServicing -and -not ($Since -and $Since.ComponentServicing)) {
        $reasons += 'Windows component servicing has a restart pending'
    }
    if ($State.WindowsUpdate -and -not ($Since -and $Since.WindowsUpdate)) {
        $reasons += 'Windows Update has a restart pending'
    }

    $known = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    if ($Since) {
        foreach ($rename in @($Since.FileRenames)) {
            [void]$known.Add([string]$rename)
        }
    }
    $newRenames = @(@($State.FileRenames) | Where-Object { $_ -and -not $known.Contains([string]$_) })
    if ($newRenames.Count -gt 0) {
        $renameWord = if ($newRenames.Count -eq 1) { 'file replacement is' } else { 'file replacements are' }
        $reasons += ('{0} {1} queued for the next restart' -f $newRenames.Count, $renameWord)
    }
    return $reasons
}

# --- WindowsTerminalHostDetection ---
function Test-WindowsTerminalHostsCurrentSession {
    [CmdletBinding()]
    param ()

    if (-not [string]::IsNullOrEmpty($env:WT_SESSION)) {
        return $true
    }

    try {
        $registryPath = 'HKCU:\Console\%%Startup'
        $delegationConsole = '{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}'
        $delegationTerminal = '{E12CFF52-A866-4C77-9A90-F570A7AA2C6B}'
        $existingValues = Get-ItemProperty -Path $registryPath -ErrorAction Stop
        if ($existingValues.DelegationConsole -eq $delegationConsole -and
            $existingValues.DelegationTerminal -eq $delegationTerminal -and
            (Test-WindowsTerminalInstalled)) {
            return $true
        }
    }
    catch {
    }

    try {
        $currentProcessId = $PID
        for ($depth = 0; $depth -lt 10 -and $currentProcessId; $depth++) {
            $process = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $currentProcessId" -ErrorAction Stop
            if (-not $process) {
                break
            }
            if ($process.Name -in @('WindowsTerminal.exe', 'OpenConsole.exe')) {
                return $true
            }
            $currentProcessId = $process.ParentProcessId
        }
    }
    catch {
    }

    return $false
}

function Test-WindowsTerminalInstalled {
    [CmdletBinding()]
    param ()

    try {
        return [bool](Get-AppxPackage -Name 'Microsoft.WindowsTerminal' -ErrorAction Stop)
    }
    catch {
    }

    return @(Get-WindowsTerminalSettingsPaths | Where-Object { $_ -match '\\Packages\\Microsoft\.WindowsTerminal_8wekyb3d8bbwe\\' }).Count -gt 0
}

function Reset-WindowsTerminalDelegation {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    $registryPath = 'HKCU:\Console\%%Startup'
    $delegationConsole = '{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}'
    $delegationTerminal = '{E12CFF52-A866-4C77-9A90-F570A7AA2C6B}'

    try {
        $values = Get-ItemProperty -Path $registryPath -ErrorAction Stop
    }
    catch {
        return $false
    }
    if ($values.DelegationConsole -ne $delegationConsole -or $values.DelegationTerminal -ne $delegationTerminal) {
        return $false
    }
    if (Test-WindowsTerminalInstalled) {
        return $false
    }

    if ($WhatIf) {
        Write-Info "[DRY-RUN] Would remove the default terminal application setting ($registryPath DelegationConsole and DelegationTerminal), which names Windows Terminal although it is not installed."
        return $true
    }
    try {
        Remove-ItemProperty -Path $registryPath -Name 'DelegationConsole', 'DelegationTerminal' -ErrorAction Stop
        Write-Success 'Removed the default terminal application setting that named Windows Terminal, which is not installed: Windows chooses the terminal again.'
        return $true
    }
    catch {
        Write-WarningMessage "Could not remove the default terminal application setting that names Windows Terminal ($registryPath): $_"
        return $false
    }
}

# --- WingetAgreementArgs ---
function Get-WingetAgreementArgs {
    [CmdletBinding()]
    param ()

    return @('--accept-source-agreements', '--accept-package-agreements', '--disable-interactivity')
}

# --- WingetBootstrap ---
function Get-WingetPolicyBlock {
    try {
        $values = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppInstaller' -ErrorAction Stop
    }
    catch {
        return $null
    }

    $policies = [ordered]@{
        EnableAppInstaller                               = 'Enable App Installer'
        EnableWindowsPackageManagerCommandLineInterfaces = 'Enable Windows Package Manager command line interfaces'
        EnableDefaultSource                              = 'Enable App Installer Default Source'
    }
    foreach ($name in $policies.Keys) {
        $value = $values.$name
        if ($null -ne $value -and "$value" -eq '0') {
            return [pscustomobject]@{ Name = $name; Policy = $policies[$name] }
        }
    }
    return $null
}

function Write-WingetPolicyBlockMessage {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Block,

        [Parameter(Mandatory = $false)]
        [string]$Detail,

        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    if ($Block) {
        $Detail = "'{0}' is Disabled ({1} = 0 under HKLM\SOFTWARE\Policies\Microsoft\Windows\AppInstaller)" -f $Block.Policy, $Block.Name
    }
    $message = "Group Policy on this PC blocks winget: $Detail. This installer cannot install apps until the policy allows it; ask whoever manages this PC's policies (Computer Configuration > Administrative Templates > Windows Components > Desktop App Installer) to allow it, then re-run the installer."
    if ($WhatIf) {
        Write-Info "[DRY-RUN] $message A real run would stop here with exit code 2."
    }
    else {
        Write-ErrorMessage $message
    }
}

function Get-AppxErrorCode {
    param (
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$ErrorRecord
    )

    $exception = $ErrorRecord
    if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) {
        $exception = $ErrorRecord.Exception
    }
    while ($exception -is [System.Exception]) {
        if (('0x{0:X8}' -f $exception.HResult).StartsWith('0x80073')) {
            return [int]$exception.HResult
        }
        $exception = $exception.InnerException
    }

    $match = [regex]::Match("$ErrorRecord", '0x80073[0-9A-F]{3}', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($match.Success) {
        return [Convert]::ToInt32($match.Value.Substring(2), 16)
    }
    return $null
}

function Test-AndInstallWingetModule {
    if (Get-Command Repair-WinGetPackageManager -ErrorAction SilentlyContinue) {
        return $true
    }

    try {
        Write-Info 'Installing the Microsoft.WinGet.Client module for all users from the PowerShell Gallery, for Repair-WinGetPackageManager...'
        if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null
        }
        Install-Module -Name Microsoft.WinGet.Client -Repository PSGallery -Scope AllUsers -Force -AllowClobber -ErrorAction Stop
        Import-Module Microsoft.WinGet.Client -ErrorAction Stop
    }
    catch {
        Write-WarningMessage "The Microsoft.WinGet.Client module could not be installed, so Repair-WinGetPackageManager cannot run: $_"
        return $false
    }
    return [bool](Get-Command Repair-WinGetPackageManager -ErrorAction SilentlyContinue)
}

function Invoke-AppxRegistration {
    [CmdletBinding(DefaultParameterSetName = 'FamilyName')]
    param (
        [Parameter(Mandatory = $true, ParameterSetName = 'FamilyName')]
        [string]$FamilyName,

        [Parameter(Mandatory = $true, ParameterSetName = 'Manifest')]
        [string]$ManifestPath
    )

    if ($PSCmdlet.ParameterSetName -eq 'FamilyName') {
        $parameters = @{ RegisterByFamilyName = $true; MainPackage = $FamilyName }
        $arguments = "-RegisterByFamilyName -MainPackage '{0}'" -f $FamilyName.Replace("'", "''")
    }
    else {
        $parameters = @{ Path = $ManifestPath; Register = $true; DisableDevelopmentMode = $true }
        $arguments = "-Path '{0}' -Register -DisableDevelopmentMode" -f $ManifestPath.Replace("'", "''")
    }

    if ($PSVersionTable.PSEdition -ne 'Core') {
        Add-AppxPackage @parameters -ErrorAction Stop
        return
    }

    $command = "`$ProgressPreference = 'SilentlyContinue'; try { Add-AppxPackage $arguments -ErrorAction Stop } catch { 'ERR|{0}|{1}' -f `$_.Exception.HResult, (`$_.Exception.Message -replace '\s+', ' '); exit 1 }"
    $lines = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $command)
    $exitCode = $LASTEXITCODE
    if ($exitCode -eq 0) {
        return
    }
    foreach ($line in $lines) {
        $parts = "$line" -split '\|', 3
        if ($parts.Count -eq 3 -and $parts[0] -eq 'ERR') {
            $hresult = 0
            if ([int]::TryParse($parts[1], [ref]$hresult) -and $hresult -ne 0) {
                throw [System.Runtime.InteropServices.COMException]::new($parts[2].Trim(), $hresult)
            }
            throw $parts[2].Trim()
        }
    }
    throw "Add-AppxPackage $arguments failed in Windows PowerShell (exit code $exitCode)."
}

function Register-WingetAppInstallerForUser {
    $codes = @()
    try {
        $candidates = @(Get-DesktopAppInstallerPackageInfo)
    }
    catch {
        Write-WarningMessage "Could not list the App Installer packages on this PC: $_"
        return [pscustomobject]@{ Registered = $false; ErrorCodes = $codes }
    }
    if ($candidates.Count -eq 0) {
        Write-Info 'App Installer is not on this PC, so there is nothing to register for this account.'
        return [pscustomobject]@{ Registered = $false; ErrorCodes = $codes }
    }

    Write-Info 'Registering the App Installer package already on this PC for this account...'
    $registrations = @(@{ Label = 'by family name'; Parameters = @{ FamilyName = 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe' } })
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate.InstallLocation)) { continue }
        $manifest = Join-Path $candidate.InstallLocation 'AppXManifest.xml'
        if (Test-Path -LiteralPath $manifest) {
            $registrations += @{ Label = "from $manifest"; Parameters = @{ ManifestPath = $manifest } }
        }
    }
    foreach ($registration in $registrations) {
        $parameters = $registration.Parameters
        try {
            Invoke-AppxRegistration @parameters -ErrorAction Stop
            Write-Success "App Installer registered for this account ($($registration.Label))."
            return [pscustomobject]@{ Registered = $true; ErrorCodes = $codes }
        }
        catch {
            $code = Get-AppxErrorCode -ErrorRecord $_
            if ($null -ne $code) { $codes += $code }
            Write-WarningMessage "Registering App Installer $($registration.Label) failed: $_"
        }
    }
    return [pscustomobject]@{ Registered = $false; ErrorCodes = $codes }
}

function Invoke-WingetPackageManagerRepair {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$AllUsersFirst,

        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [int[]]$KnownErrorCodes = @()
    )

    $finalCodes = @(-2147009293, -2147009274)
    $codes = @()
    if (-not (Test-AndInstallWingetModule)) {
        return [pscustomobject]@{ Available = $false; Succeeded = $false; ErrorCodes = $codes }
    }

    $attempts = @()
    if ($AllUsersFirst) {
        $attempts += @{ Label = '-AllUsers -Latest'; Parameters = @{ AllUsers = $true; Latest = $true } }
    }
    $attempts += @{ Label = '-Latest'; Parameters = @{ Latest = $true } }
    $attempts += @{ Label = '-Latest -Force'; Parameters = @{ Latest = $true; Force = $true } }
    foreach ($attempt in $attempts) {
        $parameters = $attempt.Parameters
        if ($parameters.Force) {
            $named = @(@($KnownErrorCodes) | Where-Object { $finalCodes -contains $_ } | Select-Object -Unique)
            $cause = $null
            if ($named.Count -gt 0) {
                $cause = 'registering App Installer failed with {0}' -f (@($named | ForEach-Object { Format-WingetExitCode -ExitCode $_ }) -join ', ')
            }
            elseif ($AllUsersFirst) {
                $cause = 'the Microsoft.WindowsAppRuntime.1.8 framework App Installer needs is missing, and the all-users repair for it failed'
            }
            if ($cause) {
                Write-Info "Not running Repair-WinGetPackageManager $($attempt.Label): $cause, which forcing cannot fix (-Force only closes running App Installer processes)."
                break
            }
        }
        Write-Info "Running Repair-WinGetPackageManager $($attempt.Label)..."
        try {
            Repair-WinGetPackageManager @parameters -ErrorAction Stop
            return [pscustomobject]@{ Available = $true; Succeeded = $true; ErrorCodes = $codes }
        }
        catch {
            Write-WarningMessage "Repair-WinGetPackageManager $($attempt.Label) failed: $_"
            $code = Get-AppxErrorCode -ErrorRecord $_
            if ($null -ne $code) {
                $codes += $code
                if ($finalCodes -contains $code) {
                    break
                }
            }
        }
    }
    return [pscustomobject]@{ Available = $true; Succeeded = $false; ErrorCodes = $codes }
}

function Invoke-NextWingetAccountFix {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$State
    )

    if (-not $State.ContainsKey('Registered')) {
        $register = Register-WingetAppInstallerForUser
        $State.Registered = [bool]$register.Registered
        $State.ErrorCodes += @($register.ErrorCodes)
        if ($State.Registered) {
            return $true
        }
    }
    if (-not $State.ContainsKey('Repair')) {
        $State.Framework = Get-WindowsAppRuntimeStatus
        $State.Repair = Invoke-WingetPackageManagerRepair -AllUsersFirst:($State.Framework.Present -eq $false) -KnownErrorCodes @($State.ErrorCodes)
        $State.ErrorCodes += @($State.Repair.ErrorCodes)
        return [bool]$State.Repair.Available
    }
    return $false
}

function Get-WingetSetupAdvice {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$State,

        [Parameter(Mandatory = $true)]
        [string]$Account,

        [Parameter(Mandatory = $false)]
        [switch]$Source,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[int]]$SourceExitCode
    )

    if ($Source) {
        if ($SourceExitCode -eq -2147009255 -and $Account -eq 'SYSTEM') {
            return 'The steps that set winget up for a signed-in account do not apply to SYSTEM; if the installs fail, run the installer once as an administrator signed in to this PC.'
        }
        if ($SourceExitCode -eq -2147009255) {
            return "Fix: sign in to Windows as '$Account' once (that sets winget up for the account), or run 'winget source update' in a session running as '$Account', then re-run the installer."
        }
        return 'Fix: check that this PC can reach https://cdn.winget.microsoft.com, then re-run the installer.'
    }
    if ($State.Framework -and $State.Framework.Present -eq $false) {
        return "Fix: install the Microsoft.WindowsAppRuntime.1.8 framework App Installer depends on, which this PC lacks ($($State.Framework.Detail)), or let the Microsoft Store update App Installer, then re-run the installer (issue #279)."
    }
    if (@($State.ErrorCodes) -contains -2147009274) {
        return 'Fix: a framework package on this PC is newer than the one the WinGet release deploys, so App Installer could not be repaired; update App Installer from the Microsoft Store on this PC, then re-run the installer.'
    }
    if ($State.Repair -and -not $State.Repair.Available) {
        return 'Fix: install App Installer from the Microsoft Store or https://aka.ms/getwinget (Repair-WinGetPackageManager could not run: its PowerShell module could not be installed), then re-run the installer.'
    }
    return 'Fix: install or update App Installer from the Microsoft Store or https://aka.ms/getwinget, then re-run the installer.'
}

function Invoke-WingetSourceProbe {
    $probe = Invoke-WingetProcess -ArgumentList @('source', 'update', '--name', 'winget', '--disable-interactivity') -TimeoutSeconds (Get-ProcessTimeoutSeconds -Operation WingetSourceUpdate) -Echo None
    if ($probe.LaunchFailed) {
        return @{ Succeeded = $false; ExitCode = $null; TimedOut = $false; LaunchError = $probe.LaunchError }
    }
    if ($probe.TimedOut -or $probe.ExitCode -ne 0) {
        Write-ProcessOutput -Line $probe.Output -Tail 20
    }
    return @{
        Succeeded   = (-not $probe.TimedOut -and $probe.ExitCode -eq 0)
        ExitCode    = $probe.ExitCode
        TimedOut    = [bool]$probe.TimedOut
        LaunchError = $null
    }
}

function Reset-WingetSource {
    Write-Info 'Resetting the winget source (winget source reset --force)...'
    $reset = Invoke-WingetProcess -ArgumentList @('source', 'reset', '--force', '--disable-interactivity') -TimeoutSeconds (Get-ProcessTimeoutSeconds -Operation WingetSourceReset)
    if ($reset.LaunchFailed) {
        Write-WarningMessage "Winget source reset failed: $($reset.LaunchError)"
    }
    elseif ($reset.TimedOut) {
        Write-WarningMessage 'Winget source reset failed: it did not finish in time and was stopped.'
    }
    elseif ($reset.ExitCode -ne 0) {
        Write-WarningMessage ('Winget source reset failed with exit code {0}.' -f (Format-WingetExitCode -ExitCode $reset.ExitCode))
    }
    else {
        Write-Info 'Source reset completed.'
        return $true
    }
    return $false
}

# --- WingetClientEngine ---
function Get-SystemInstallEngineRequest {
    $raw = [System.Environment]::GetEnvironmentVariable('WINGET_APP_SETUP_SYSTEM_ENGINE')
    $value = "$raw".Trim()
    if ($value.Length -eq 0) {
        return [pscustomobject]@{ Engine = 'Cli'; Source = 'Default'; RawValue = $raw }
    }
    if ($value -eq 'WinGetClient') {
        return [pscustomobject]@{ Engine = 'WinGetClient'; Source = 'Environment'; RawValue = $raw }
    }
    if ($value -ne 'Cli') {
        Write-WarningMessage "WINGET_APP_SETUP_SYSTEM_ENGINE='$raw' is not Cli or WinGetClient; using winget.exe."
    }
    return [pscustomobject]@{ Engine = 'Cli'; Source = 'Environment'; RawValue = $raw }
}

function New-InstallEngineRecord {
    param (
        [Parameter(Mandatory = $false)]
        [ValidateSet('Cli', 'WinGetClient')]
        [string]$Requested = 'Cli',

        [Parameter(Mandatory = $false)]
        [ValidateSet('Cli', 'WinGetClient')]
        [string]$Used = 'Cli',

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Module,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$EngineVersion,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$FallbackReason
    )

    $moduleRecord = $null
    if ($Used -eq 'WinGetClient' -and $null -ne $Module) {
        $engineVersionText = $null
        if (-not [string]::IsNullOrWhiteSpace($EngineVersion)) {
            $engineVersionText = $EngineVersion
        }
        $moduleRecord = [ordered]@{
            name          = 'Microsoft.WinGet.Client'
            version       = [string]$Module.Version
            sha256        = [string]$Module.Sha256
            engineVersion = $engineVersionText
        }
    }
    $reasonText = $null
    if (-not [string]::IsNullOrWhiteSpace($FallbackReason)) {
        $reasonText = $FallbackReason
    }
    return [ordered]@{
        requested      = $Requested
        used           = $Used
        module         = $moduleRecord
        fallbackReason = $reasonText
    }
}

function Get-InstallEngineRecord {
    if ($script:InstallEngineRecord -is [System.Collections.IDictionary]) {
        return $script:InstallEngineRecord
    }
    return (New-InstallEngineRecord)
}

function Test-WingetClientEngineActive {
    return ($null -ne $script:WingetClientEngine)
}

function Get-WingetEngineLogDirectory {
    $folders = @()
    $windowsDirectory = $env:SystemRoot
    if ([string]::IsNullOrWhiteSpace($windowsDirectory)) {
        $windowsDirectory = $env:windir
    }
    if (-not [string]::IsNullOrWhiteSpace($windowsDirectory)) {
        $systemTemp = $windowsDirectory.TrimEnd('\', '/') + '\SystemTemp'
        if (Test-Path -LiteralPath $systemTemp -PathType Container) {
            $folders += $systemTemp + '\WinGet\defaultState'
        }
    }
    $temp = $null
    foreach ($candidate in @($env:TMP, $env:TEMP)) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            $temp = $candidate
            break
        }
    }
    if (-not $temp -and -not [string]::IsNullOrWhiteSpace($windowsDirectory)) {
        $temp = $windowsDirectory.TrimEnd('\', '/') + '\Temp'
    }
    if ($temp) {
        $folder = $temp.TrimEnd('\', '/') + '\WinGet\defaultState'
        if (@($folders | Where-Object { [string]::Equals($_, $folder, [System.StringComparison]::OrdinalIgnoreCase) }).Count -eq 0) {
            $folders += $folder
        }
    }
    return [string[]]$folders
}

function Write-InstallEngineLine {
    $engine = $script:WingetClientEngine
    if ($null -ne $engine) {
        Write-Info ('Install engine: Microsoft.WinGet.Client {0} (WinGet engine {1}, PowerShell {2} {3}; engine log folder {4}).' -f $engine.Module.Version, $engine.EngineVersion, $engine.PowerShellVersion, $engine.Module.Architecture, (@(Get-WingetEngineLogDirectory) -join ' or '))
        return
    }
    $path = $script:MachineWingetPath
    if ([string]::IsNullOrWhiteSpace($path)) {
        $path = 'none found'
    }
    $record = Get-InstallEngineRecord
    if ($record.requested -eq 'WinGetClient') {
        Write-Info ('Install engine: winget.exe ({0}), not the requested Microsoft.WinGet.Client: {1}.' -f $path, "$($record.fallbackReason)".TrimEnd('.'))
        return
    }
    Write-Info ('Install engine: winget.exe ({0}).' -f $path)
}

function ConvertFrom-WingetClientResponse {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$StandardOutput,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$StandardError,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[int]]$ExitCode
    )

    $json = $null
    foreach ($line in @($StandardOutput)) {
        if ("$line" -match '^WINGET-CLIENT-RESULT (\{.*\})$') {
            $json = $Matches[1]
        }
    }
    if ($null -eq $json) {
        $codeText = 'none'
        if ($null -ne $ExitCode) {
            $codeText = [string]$ExitCode
        }
        $detail = ''
        $lastError = @($StandardError | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) | Select-Object -Last 1
        if ($lastError) {
            $detail = ': ' + "$lastError".Trim()
        }
        return [pscustomobject]@{ Response = $null; ProtocolError = "the WinGet client request ended without a result (exit code $codeText)$detail" }
    }
    try {
        $response = ConvertFrom-Json -InputObject $json -ErrorAction Stop
    }
    catch {
        return [pscustomobject]@{ Response = $null; ProtocolError = "the WinGet client request's result is not valid JSON: $($_.Exception.Message)" }
    }
    if ($null -eq $response -or "$($response.protocol)" -ne '1') {
        return [pscustomobject]@{ Response = $null; ProtocolError = "the WinGet client request answered in protocol '$($response.protocol)', not 1" }
    }
    return [pscustomobject]@{ Response = $response; ProtocolError = $null }
}

function Invoke-WingetClientRequest {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Module,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Probe', 'Version', 'Installed', 'Install')]
        [string]$Operation,

        [Parameter(Mandatory = $false)]
        [string]$PackageId,

        [Parameter(Mandatory = $false)]
        [string]$InstallerType,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Silent', 'Default')]
        [string]$Mode = 'Silent',

        [Parameter(Mandatory = $false)]
        [string]$Log,

        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds
    )

    if ($null -eq $Module -and $null -ne $script:WingetClientEngine) {
        $Module = $script:WingetClientEngine.Module
    }
    if ($null -eq $Module -or -not $Module.Ready) {
        throw [System.InvalidOperationException]::new('Invoke-WingetClientRequest: the Microsoft.WinGet.Client module is not ready.')
    }

    $arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', [string]$Module.ChildScriptPath, '-ModuleManifest', [string]$Module.ManifestPath, '-ExpectedVersion', [string]$Module.Version, '-Operation', $Operation)
    if (-not [string]::IsNullOrWhiteSpace($PackageId)) {
        $arguments += @('-PackageId', $PackageId)
    }
    if ($Operation -eq 'Install') {
        $arguments += @('-Mode', $Mode)
        if (-not [string]::IsNullOrWhiteSpace($InstallerType)) {
            $arguments += @('-InstallerType', $InstallerType)
        }
        if (-not [string]::IsNullOrWhiteSpace($Log)) {
            $arguments += @('-Log', $Log)
        }
    }

    $run = Invoke-ExternalProcess -FilePath ([string]$Module.PowerShellPath) -ArgumentList $arguments -TimeoutSeconds $TimeoutSeconds -Echo None
    $response = $null
    $protocolError = $null
    if (-not $run.LaunchFailed -and -not $run.TimedOut) {
        $parsed = ConvertFrom-WingetClientResponse -StandardOutput $run.StandardOutput -StandardError $run.StandardError -ExitCode $run.ExitCode
        $response = $parsed.Response
        $protocolError = $parsed.ProtocolError
    }
    return [pscustomobject]@{ Run = $run; Response = $response; ProtocolError = $protocolError }
}

function Get-WingetClientExceptionCode {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Exceptions
    )

    $byName = @{
        NoPackageFoundException = -1978335212
        VagueCriteriaException  = -1978335210
        InvalidSourceException  = -1978335214
        GroupPolicyException    = -1978335174
    }
    $sourceOpenFailed = -1978335163
    $commandFailed = -1978335229
    $internalError = -1978335231
    $chain = @($Exceptions | Where-Object { $null -ne $_ })
    for ($index = 0; $index -lt $chain.Count; $index++) {
        $name = [string]$chain[$index].name
        if ($byName.ContainsKey($name)) {
            return $byName[$name]
        }
        if ($name -eq 'CatalogConnectException') {
            if ($index + 1 -lt $chain.Count -and [long]$chain[$index + 1].hresult -lt 0) {
                return [int]$chain[$index + 1].hresult
            }
            return $sourceOpenFailed
        }
        if ($name -eq 'FindPackagesException') {
            $own = [int]$chain[$index].hresult
            if (('0x{0:X8}' -f $own).StartsWith('0x8A15')) {
                return $own
            }
            return $commandFailed
        }
    }
    foreach ($record in $chain) {
        if (('0x{0:X8}' -f [int]$record.hresult).StartsWith('0x8A15')) {
            return [int]$record.hresult
        }
    }
    if ($chain.Count -gt 0 -and [long]$chain[0].hresult -lt 0) {
        return [int]$chain[0].hresult
    }
    return $internalError
}

function Get-WingetClientResultCode {
    param (
        [Parameter(Mandatory = $true)]
        [object]$Request
    )

    $result = [pscustomobject]@{
        Failure            = $null
        ExitCode           = $null
        TimedOut           = $false
        LaunchFailed       = $false
        LaunchErrorCode    = $null
        LaunchError        = $null
        Status             = $null
        InstallerErrorCode = $null
        Detail             = $null
    }
    $run = $Request.Run
    if ($run -and $run.LaunchFailed) {
        $result.Failure = 'Launch'
        $result.LaunchFailed = $true
        $result.LaunchErrorCode = $run.LaunchErrorCode
        $result.LaunchError = $run.LaunchError
        return $result
    }
    if ($run -and $run.TimedOut) {
        $result.Failure = 'Timeout'
        $result.TimedOut = $true
        return $result
    }
    $response = $Request.Response
    if ($null -eq $response) {
        $protocolError = [string]$Request.ProtocolError
        if ([string]::IsNullOrWhiteSpace($protocolError)) {
            $protocolError = 'the WinGet client request returned no result'
        }
        $result.Failure = 'Protocol'
        $result.LaunchFailed = $true
        $result.LaunchError = "the WinGet client engine could not start: $protocolError"
        return $result
    }

    $exceptions = @($response.exceptions | Where-Object { $null -ne $_ })
    $formatException = {
        param ($Record)
        if ($null -eq $Record) {
            return 'no exception was reported'
        }
        return ('{0}: {1}' -f $Record.name, "$($Record.message)".Trim().TrimEnd('.'))
    }
    $loadClass = @('WindowsPowerShellNotSupported', 'WinGetIntegrityException', 'SingleThreadedApartmentException', 'TypeInitializationException', 'DllNotFoundException', 'BadImageFormatException', 'FileNotFoundException', 'FileLoadException')
    $loadRecord = $null
    if ([string]$response.stage -eq 'load') {
        if ($exceptions.Count -gt 0) {
            $loadRecord = $exceptions[0]
        }
        else {
            $loadRecord = [pscustomobject]@{ name = 'LoadFailed'; message = 'the module did not load' }
        }
    }
    elseif ($response.ok -ne $true) {
        $loadRecord = @($exceptions | Where-Object { $loadClass -contains [string]$_.name }) | Select-Object -First 1
    }
    if ($null -ne $loadRecord) {
        $result.Failure = 'Load'
        $result.LaunchFailed = $true
        $result.Detail = & $formatException $loadRecord
        $result.LaunchError = 'the WinGet client engine could not start: ' + $result.Detail
        return $result
    }
    if ($response.ok -ne $true) {
        $result.Failure = 'Call'
        $result.ExitCode = Get-WingetClientExceptionCode -Exceptions $exceptions
        if ($exceptions.Count -gt 0) {
            $result.Status = [string]$exceptions[0].name
            $result.Detail = & $formatException $exceptions[0]
        }
        else {
            $result.Status = 'Exception'
            $result.Detail = 'the call failed without an exception'
        }
        return $result
    }

    if ([string]$response.operation -ne 'Install') {
        $result.ExitCode = 0
        return $result
    }
    $status = [string]$response.status
    $result.Status = $status
    if ($null -ne $response.installerErrorCode) {
        $installerCode = [long]$response.installerErrorCode
        if ($status -eq 'Ok' -or ($status -eq 'InstallError' -and $installerCode -ne 0)) {
            $result.InstallerErrorCode = $installerCode
        }
    }
    if ($status -eq 'Ok') {
        $result.ExitCode = 0
    }
    elseif ($null -ne $response.hresult -and [long]$response.hresult -lt 0) {
        $result.ExitCode = [int]$response.hresult
    }
    else {
        $result.ExitCode = switch ($status) {
            'NoApplicableInstallers' { -1978335216 }
            'BlockedByPolicy' { -1978335174 }
            'PackageAgreementsNotAccepted' { -1978335167 }
            'NoApplicableUpgrade' { -1978335189 }
            'CatalogError' { -1978335163 }
            'InvalidOptions' { -1978335230 }
            'ManifestError' { -1978335231 }
            'InternalError' { -1978335231 }
            default { -1978335229 }
        }
    }
    return $result
}

function Invoke-WingetClientInstall {
    param (
        [Parameter(Mandatory = $true)]
        [string]$PackageId,

        [Parameter(Mandatory = $true)]
        [string]$Scope,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$InstallerType,

        [Parameter(Mandatory = $false)]
        [switch]$Silent,

        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$LogDirectory
    )

    if ($Scope -ne 'machine') {
        throw [System.ArgumentException]::new("Invoke-WingetClientInstall: the WinGet client engine installs for the whole PC only (-Scope System), so it cannot install $PackageId at scope '$Scope'.")
    }
    $mode = 'Default'
    if ($Silent) {
        $mode = 'Silent'
    }
    $logParameters = @{ Subcommand = 'install'; PackageId = $PackageId }
    if ($PSBoundParameters.ContainsKey('LogDirectory')) {
        $logParameters['LogDirectory'] = $LogDirectory
    }
    $logPath = New-WingetInstallerLogPath @logParameters

    $call = '  > Install-WinGetPackage -Id {0} -Source winget -MatchOption Equals -Scope System -Mode {1}' -f $PackageId, $mode
    if (-not [string]::IsNullOrWhiteSpace($InstallerType)) {
        $call += " -InstallerType $InstallerType"
    }
    if ($logPath) {
        $call += " -Log $logPath"
    }
    Write-Host $call -ForegroundColor DarkGray

    $requestParameters = @{ Operation = 'Install'; PackageId = $PackageId; Mode = $mode; TimeoutSeconds = $TimeoutSeconds }
    if (-not [string]::IsNullOrWhiteSpace($InstallerType)) {
        $requestParameters['InstallerType'] = $InstallerType
    }
    if ($logPath) {
        $requestParameters['Log'] = $logPath
    }
    $request = Invoke-WingetClientRequest @requestParameters
    $run = $request.Run
    $mapped = Get-WingetClientResultCode -Request $request

    $output = @($run.Output | Where-Object { "$_" -notmatch '^WINGET-CLIENT-RESULT ' })
    if ($output.Count -gt 0) {
        Write-ProcessOutput -Line $output -Tail 20
    }
    $seconds = [Math]::Round([double]$run.DurationSeconds)
    if ($mapped.TimedOut) {
        Write-Host ('    WinGet client result: no answer within {0} s; the request and its installer were stopped' -f $TimeoutSeconds) -ForegroundColor DarkGray
    }
    elseif ($mapped.LaunchFailed) {
        Write-Host ('    WinGet client result: {0} ({1} s)' -f "$($mapped.LaunchError)".TrimEnd('.'), $seconds) -ForegroundColor DarkGray
    }
    else {
        $installerText = 'no installer exit code'
        if ($null -ne $mapped.InstallerErrorCode) {
            $installerText = 'installer exit code {0}' -f $mapped.InstallerErrorCode
        }
        Write-Host ('    WinGet client result: {0}, {1}, {2} ({3} s)' -f $mapped.Status, (Format-WingetExitCode -ExitCode $mapped.ExitCode), $installerText, $seconds) -ForegroundColor DarkGray
    }

    $result = [ordered]@{}
    foreach ($property in $run.PSObject.Properties) {
        $result[$property.Name] = $property.Value
    }
    $result['ExitCode'] = $mapped.ExitCode
    $result['TimedOut'] = [bool]$mapped.TimedOut
    $result['LaunchFailed'] = [bool]$mapped.LaunchFailed
    $result['LaunchErrorCode'] = $mapped.LaunchErrorCode
    $result['LaunchError'] = $mapped.LaunchError
    $result['Output'] = $output
    $result['LogPath'] = $logPath
    $result['InstallerErrorCode'] = $mapped.InstallerErrorCode
    $result['WingetClientStatus'] = $mapped.Status
    $result['Engine'] = 'WinGetClient'
    return [pscustomobject]$result
}

function Invoke-WingetClientInstalledCheck {
    param (
        [Parameter(Mandatory = $true)]
        [string]$PackageId,

        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds
    )

    $timeout = [Math]::Max($TimeoutSeconds, (Get-ProcessTimeoutSeconds -Operation WingetClientListCheck))
    $request = Invoke-WingetClientRequest -Operation Installed -PackageId $PackageId -TimeoutSeconds $timeout
    $mapped = Get-WingetClientResultCode -Request $request
    if ($mapped.LaunchFailed) {
        return @{ Installed = $false; TimedOut = $false; LaunchFailed = $true; LaunchError = $mapped.LaunchError; CheckFailed = $false; ExitCode = $null }
    }
    if ($mapped.TimedOut) {
        return @{ Installed = $false; TimedOut = $true; LaunchFailed = $false; LaunchError = $null; CheckFailed = $false; ExitCode = $null }
    }
    if ($mapped.Failure -eq 'Call') {
        return @{ Installed = $false; TimedOut = $false; LaunchFailed = $false; LaunchError = $null; CheckFailed = $true; ExitCode = $mapped.ExitCode }
    }
    $installed = @($request.Response.packages | Where-Object { $null -ne $_ -and [string]$_.id -eq $PackageId }).Count -gt 0
    $exitCode = -1978335212
    if ($installed) {
        $exitCode = 0
    }
    return @{ Installed = $installed; TimedOut = $false; LaunchFailed = $false; LaunchError = $null; CheckFailed = $false; ExitCode = $exitCode }
}

function Test-WingetClientEngineLaunchable {
    param (
        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 100)]
        [int]$Attempts = 1,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 3600)]
        [int]$RetryDelaySeconds = 10
    )

    $timeoutSeconds = Get-ProcessTimeoutSeconds -Operation WingetClientVersion
    $policyExitCode = -1978335174
    $reason = $null
    $mapped = $null
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $request = Invoke-WingetClientRequest -Operation Version -TimeoutSeconds $timeoutSeconds
        $mapped = Get-WingetClientResultCode -Request $request
        $retryable = $true
        switch ($mapped.Failure) {
            'Launch' {
                $reason = 'pwsh could not be started: {0}' -f "$($mapped.LaunchError)".Trim().TrimEnd('.')
                $retryable = Test-TransientWingetLaunchError -NativeErrorCode $mapped.LaunchErrorCode -Message $mapped.LaunchError
            }
            'Timeout' {
                $reason = "Get-WinGetVersion did not answer within $timeoutSeconds seconds and was stopped"
            }
            'Protocol' {
                $reason = "$($mapped.LaunchError)".TrimEnd('.')
            }
            'Load' {
                $reason = "$($mapped.LaunchError)".TrimEnd('.')
                $retryable = $false
            }
            'Call' {
                $reason = 'Get-WinGetVersion failed with {0} ({1})' -f (Format-WingetExitCode -ExitCode $mapped.ExitCode), $mapped.Detail
                if ($mapped.ExitCode -eq $policyExitCode) {
                    $retryable = $false
                }
            }
            default {
                $version = "$($request.Response.version)".Trim()
                if ($version) {
                    return [pscustomobject]@{ Launchable = $true; Version = $version; Reason = $null; ExitCode = 0; Attempts = $attempt }
                }
                $reason = 'Get-WinGetVersion returned no version'
            }
        }
        if (-not $retryable -or $attempt -ge $Attempts) {
            break
        }
        Write-WarningMessage "The WinGet client engine is not usable yet ($reason). Checking again in ${RetryDelaySeconds}s (check $($attempt + 1) of $Attempts)..."
        Start-Sleep -Seconds $RetryDelaySeconds
    }
    return [pscustomobject]@{ Launchable = $false; Version = $null; Reason = $reason; ExitCode = $mapped.ExitCode; Attempts = [Math]::Min($attempt, $Attempts) }
}

function Initialize-WingetClientEngine {
    $script:WingetClientEngine = $null
    $module = Initialize-WingetClientModule
    if (-not $module.Ready) {
        $reason = "the module is not ready: $($module.Reason)"
        $script:InstallEngineRecord = New-InstallEngineRecord -Requested 'WinGetClient' -Used 'Cli' -FallbackReason $reason
        return [pscustomobject]@{ Ready = $false; Reason = $reason; Module = $module; EngineVersion = $null }
    }

    $request = Invoke-WingetClientRequest -Module $module -Operation Probe -TimeoutSeconds (Get-ProcessTimeoutSeconds -Operation WingetClientProbe)
    $mapped = Get-WingetClientResultCode -Request $request
    $response = $request.Response
    $version = $null
    $detail = $null
    switch ($mapped.Failure) {
        'Launch' { $detail = "pwsh could not be started: $($mapped.LaunchError)" }
        'Timeout' { $detail = 'it did not answer within {0} seconds and was stopped' -f (Get-ProcessTimeoutSeconds -Operation WingetClientProbe) }
        'Protocol' { $detail = $mapped.LaunchError }
        'Load' { $detail = $mapped.LaunchError }
        'Call' { $detail = '{0} ({1})' -f $mapped.Detail, (Format-WingetExitCode -ExitCode $mapped.ExitCode) }
        default {
            $version = "$($response.version)".Trim()
            if (-not $version) {
                $detail = 'Get-WinGetVersion returned no version'
            }
            elseif ($response.installedChecked -ne $true) {
                $detail = 'Get-WinGetPackage did not run'
            }
        }
    }
    if ($detail) {
        $reason = "the module's probe failed: " + "$detail".Trim().TrimEnd('.')
        Write-WarningMessage "WinGet client module: NOT READY - $reason."
        if ($module.Directory) {
            Remove-Item -LiteralPath $module.Directory -Recurse -Force -ErrorAction SilentlyContinue
        }
        $script:InstallEngineRecord = New-InstallEngineRecord -Requested 'WinGetClient' -Used 'Cli' -FallbackReason $reason
        return [pscustomobject]@{ Ready = $false; Reason = $reason; Module = $module; EngineVersion = $null }
    }

    $script:WingetClientEngine = [pscustomobject]@{
        Module            = $module
        EngineVersion     = $version
        PowerShellVersion = [string]$response.psVersion
        Architecture      = [string]$response.architecture
    }
    $script:InstallEngineRecord = New-InstallEngineRecord -Requested 'WinGetClient' -Used 'WinGetClient' -Module $module -EngineVersion $version
    return [pscustomobject]@{ Ready = $true; Reason = $null; Module = $module; EngineVersion = $version }
}

function Remove-WingetClientEngine {
    $engine = $script:WingetClientEngine
    $script:WingetClientEngine = $null
    if ($null -eq $engine -or $null -eq $engine.Module) {
        return
    }
    $directory = [string]$engine.Module.Directory
    if ([string]::IsNullOrEmpty($directory)) {
        return
    }
    try {
        if (Test-Path -LiteralPath $directory) {
            Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction Stop
        }
    }
    catch {
        Write-WarningMessage "Could not remove the Microsoft.WinGet.Client folder ${directory}: $($_.Exception.Message). A later run removes it."
    }
}

# --- WingetClientModule ---
function Get-WingetClientModulePin {
    return @{
        Name              = 'Microsoft.WinGet.Client'
        Version           = '1.29.380'
        PackageUrl        = 'https://www.powershellgallery.com/api/v2/package/Microsoft.WinGet.Client/1.29.380'
        FileName          = 'microsoft.winget.client.1.29.380.nupkg'
        Size              = 21025850
        Sha256            = '3469E5747EB6B100E51FED3F2057386B5BA60BC8955A6669B5C2EB562E316619'
        SignerCommonName  = 'Microsoft Corporation'
        Framework         = 'net8.0-windows10.0.26100.0'
        MinimumPowerShell = '7.4'
        SignedFiles       = @(
            'Microsoft.WinGet.Client.psd1',
            'Format.ps1xml',
            'net8.0-windows10.0.26100.0/Microsoft.WinGet.Client.Cmdlets.dll',
            'net8.0-windows10.0.26100.0/DirectDependencies/Microsoft.WinGet.Client.Engine.dll',
            'net8.0-windows10.0.26100.0/SharedDependencies/Microsoft.WinGet.SharedLib.dll',
            'net8.0-windows10.0.26100.0/SharedDependencies/{arch}/WindowsPackageManager.dll',
            'net8.0-windows10.0.26100.0/SharedDependencies/{arch}/Microsoft.Management.Deployment.dll',
            'net8.0-windows10.0.26100.0/SharedDependencies/{arch}/Microsoft.Management.Deployment.winmd',
            'net8.0-windows10.0.26100.0/SharedDependencies/{arch}/winrtact.dll'
        )
    }
}

function ConvertTo-WingetClientArchitecture {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Architecture
    )

    switch ("$Architecture") {
        'X64' { return 'x64' }
        'X86' { return 'x86' }
        'Arm64' { return 'arm64' }
    }
    return $null
}

function Expand-WingetClientModulePackage {
    param (
        [Parameter(Mandatory = $true)]
        [System.IO.Stream]$Stream,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,

        [Parameter(Mandatory = $true)]
        [string]$Framework,

        [Parameter(Mandatory = $true)]
        [ValidateSet('x64', 'x86', 'arm64')]
        [string]$Architecture,

        [Parameter(Mandatory = $true)]
        [hashtable]$Pin
    )

    $separator = [System.IO.Path]::DirectorySeparatorChar
    $root = [System.IO.Path]::GetFullPath($DestinationPath).TrimEnd('\', '/')
    $rootPrefix = $root + $separator
    [void](New-Item -ItemType Directory -Path $root -Force -ErrorAction Stop)
    $sharedPrefix = $Framework + '/SharedDependencies/'
    $otherArchitectures = @('x64', 'x86', 'arm64') | Where-Object { $_ -ne $Architecture }
    $nuspecChecked = $false

    $Stream.Position = 0
    $archive = New-Object System.IO.Compression.ZipArchive($Stream, [System.IO.Compression.ZipArchiveMode]::Read, $true)
    try {
        foreach ($entry in $archive.Entries) {
            $name = [Uri]::UnescapeDataString($entry.FullName).Replace('\', '/')
            if ($name.StartsWith('/') -or $name -match '^[A-Za-z]:' -or [System.IO.Path]::IsPathRooted($name)) {
                throw "the package has an entry with a rooted path: $name"
            }
            if ($name.EndsWith('/')) {
                continue
            }
            if ($name -ceq '[Content_Types].xml' -or $name -ceq '.signature.p7s' -or $name.StartsWith('_rels/') -or $name.StartsWith('package/') -or $name.StartsWith('net48/')) {
                continue
            }
            if ($name.StartsWith($sharedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                $folder = $name.Substring($sharedPrefix.Length).Split('/')[0]
                if ($name.Substring($sharedPrefix.Length).Contains('/') -and $otherArchitectures -contains $folder.ToLowerInvariant()) {
                    continue
                }
            }
            if (-not $name.Contains('/') -and $name.EndsWith('.nuspec', [System.StringComparison]::OrdinalIgnoreCase)) {
                $settings = New-Object System.Xml.XmlReaderSettings
                $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
                $settings.XmlResolver = $null
                $entryStream = $entry.Open()
                try {
                    $reader = [System.Xml.XmlReader]::Create($entryStream, $settings)
                    $nuspec = New-Object System.Xml.XmlDocument
                    $nuspec.Load($reader)
                }
                finally {
                    $entryStream.Dispose()
                }
                $id = [string]$nuspec.package.metadata.id
                $version = [string]$nuspec.package.metadata.version
                if ($id -ne $Pin.Name -or $version -ne $Pin.Version) {
                    throw ("the package's .nuspec names {0} {1}, not {2} {3}" -f $id, $version, $Pin.Name, $Pin.Version)
                }
                $nuspecChecked = $true
                continue
            }

            $target = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($root, $name.Replace('/', $separator)))
            if (-not $target.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "the package has an entry outside its folder: $name"
            }
            [void](New-Item -ItemType Directory -Path ([System.IO.Path]::GetDirectoryName($target)) -Force -ErrorAction Stop)
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $false)
        }
    }
    finally {
        $archive.Dispose()
    }

    if (-not $nuspecChecked) {
        throw 'the package has no .nuspec'
    }
    $manifestPath = Join-Path $root ($Pin.Name + '.psd1')
    foreach ($required in @(($Pin.Name + '.psd1'), ($Framework + '/Microsoft.WinGet.Client.Cmdlets.dll'))) {
        if (-not (Test-Path -LiteralPath (Join-Path $root $required.Replace('/', $separator)) -PathType Leaf)) {
            throw "the package has no $required"
        }
    }
    $enginePath = Join-Path $root ('{0}{1}{2}{1}WindowsPackageManager.dll' -f $sharedPrefix.Replace('/', $separator), $separator, $Architecture).Replace(($separator + $separator), $separator)
    return [pscustomobject]@{
        ManifestPath = $manifestPath
        EngineFound  = [bool](Test-Path -LiteralPath $enginePath -PathType Leaf)
    }
}

function Get-WingetClientChildScript {
    return @'
param (
    [Parameter(Mandatory = $true)]
    [string]$ModuleManifest,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedVersion,

    [Parameter(Mandatory = $true)]
    [ValidateSet('Probe', 'Version', 'Installed', 'Install')]
    [string]$Operation,

    [string]$PackageId,

    [string]$InstallerType,

    [ValidateSet('Silent', 'Default')]
    [string]$Mode = 'Silent',

    [string]$Log,

    [string]$ProbePackageId = 'Microsoft.PowerShell'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
# A process without a console can refuse the code page; the result line is ASCII-safe JSON anyway.
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
$script:loadedVersion = $null

function Get-ExceptionRecord {
    param ($Exception)
    $records = @()
    $current = $Exception
    while ($null -ne $current -and $records.Count -lt 6) {
        $records += @{ type = $current.GetType().FullName; name = $current.GetType().Name; hresult = [int]$current.HResult; message = [string]$current.Message }
        $current = $current.InnerException
    }
    return ,$records
}

function Send-RequestResult {
    param ([hashtable]$Result, [string]$Outcome)
    $Result['protocol'] = 1
    $Result['operation'] = $Operation
    $Result['moduleVersion'] = $script:loadedVersion
    $Result['psVersion'] = [string]$PSVersionTable.PSVersion
    $Result['architecture'] = [string][System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture
    $subject = @('Microsoft.WinGet.Client', $Operation, $PackageId) | Where-Object { -not [string]::IsNullOrEmpty($_) }
    [Console]::Out.WriteLine(($subject -join ' ') + ': ' + $Outcome)
    [Console]::Out.WriteLine('WINGET-CLIENT-RESULT ' + (ConvertTo-Json -InputObject $Result -Compress -Depth 6 -EscapeHandling EscapeNonAscii))
    [Console]::Out.Flush()
}

function Get-InstalledPackageRecord {
    param ($Command, [string]$Id)
    $records = @()
    foreach ($package in @(& $Command -Id $Id -MatchOption Equals -Source winget)) {
        if ($null -ne $package) {
            $records += @{ id = [string]$package.Id; installedVersion = [string]$package.InstalledVersion; source = [string]$package.Source }
        }
    }
    return ,$records
}

try {
    $manifestPath = [System.IO.Path]::GetFullPath($ModuleManifest)
    $module = @(Import-Module -Name $manifestPath -PassThru -Force -ErrorAction Stop) | Where-Object { $_.Name -eq 'Microsoft.WinGet.Client' } | Select-Object -First 1
    if ($null -eq $module) {
        throw (New-Object System.InvalidOperationException('Import-Module returned no Microsoft.WinGet.Client module.'))
    }
    $script:loadedVersion = [string]$module.Version
    if ($module.Version -ne [version]$ExpectedVersion) {
        throw (New-Object System.InvalidOperationException(('Microsoft.WinGet.Client {0} was loaded, not {1}.' -f $module.Version, $ExpectedVersion)))
    }
    $expectedBase = [System.IO.Path]::GetDirectoryName($manifestPath).TrimEnd('\', '/')
    $loadedBase = [System.IO.Path]::GetFullPath([string]$module.ModuleBase).TrimEnd('\', '/')
    if (-not [string]::Equals($loadedBase, $expectedBase, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw (New-Object System.InvalidOperationException(('Microsoft.WinGet.Client was loaded from {0}, not {1}.' -f $loadedBase, $expectedBase)))
    }
    $installCommand = $module.ExportedCommands['Install-WinGetPackage']
    $getCommand = $module.ExportedCommands['Get-WinGetPackage']
    $versionCommand = $module.ExportedCommands['Get-WinGetVersion']
    if ($null -eq $installCommand -or $null -eq $getCommand -or $null -eq $versionCommand) {
        throw (New-Object System.InvalidOperationException('Microsoft.WinGet.Client does not export Install-WinGetPackage, Get-WinGetPackage and Get-WinGetVersion.'))
    }
}
catch {
    $records = Get-ExceptionRecord -Exception $_.Exception
    Send-RequestResult -Result @{ stage = 'load'; ok = $false; exceptions = $records } -Outcome ('load failed: ' + $records[0].name)
    exit 3
}

$result = @{ stage = 'call'; ok = $true }
$outcome = 'ok'
try {
    switch ($Operation) {
        'Version' {
            $result['version'] = [string](& $versionCommand)
            $outcome = $result['version']
        }
        'Installed' {
            $result['packages'] = Get-InstalledPackageRecord -Command $getCommand -Id $PackageId
            $outcome = '{0} installed package(s)' -f @($result['packages']).Count
        }
        'Probe' {
            $result['version'] = [string](& $versionCommand)
            $result['probePackageId'] = $ProbePackageId
            $result['packages'] = Get-InstalledPackageRecord -Command $getCommand -Id $ProbePackageId
            $result['installedChecked'] = $true
            $outcome = '{0}, {1} installed package(s) for {2}' -f $result['version'], @($result['packages']).Count, $ProbePackageId
        }
        'Install' {
            $parameters = @{ Id = $PackageId; Source = 'winget'; MatchOption = 'Equals'; Scope = 'System'; Mode = $Mode }
            if (-not [string]::IsNullOrEmpty($InstallerType)) {
                $parameters['InstallerType'] = $InstallerType
            }
            if (-not [string]::IsNullOrEmpty($Log)) {
                $parameters['Log'] = $Log
            }
            $installResults = @(& $installCommand @parameters)
            if ($installResults.Count -ne 1) {
                $result['ok'] = $false
                $result['exceptions'] = @(@{ type = 'NoResult'; name = 'NoResult'; hresult = 0; message = ('Install-WinGetPackage returned {0} results, not 1.' -f $installResults.Count) })
                $outcome = 'NoResult'
            }
            else {
                $installResult = $installResults[0]
                $hresult = 0
                if ($null -ne $installResult.ExtendedErrorCode) {
                    $hresult = [int]$installResult.ExtendedErrorCode.HResult
                }
                $result['status'] = [string]$installResult.Status
                $result['hresult'] = $hresult
                $result['installerErrorCode'] = [long]$installResult.InstallerErrorCode
                $result['rebootRequired'] = [bool]$installResult.RebootRequired
                $result['id'] = [string]$installResult.Id
                $outcome = $result['status']
            }
        }
    }
}
catch {
    $records = Get-ExceptionRecord -Exception $_.Exception
    $result = @{ stage = 'call'; ok = $false; exceptions = $records }
    $outcome = $records[0].name
}
Send-RequestResult -Result $result -Outcome $outcome
exit 0
'@
}

function Initialize-WingetClientModule {
    $pin = $null
    $reason = $null
    $stage = 'reading its pin'
    $directory = $null
    $stream = $null
    $source = $null
    $architecture = $null
    $manifestPath = $null
    $childScriptPath = $null
    try {
        $pin = Get-WingetClientModulePin
        if (-not ([long]$pin.Size -gt 0 -and "$($pin.Sha256)" -match '^[0-9A-Fa-f]{64}$')) {
            $reason = 'its SHA256 pin is not set in this build'
        }
        if (-not $reason) {
            $stage = 'checking this PowerShell'
            $edition = Get-PowerShellEdition
            $psVersion = Get-PowerShellVersion
            if ($edition -ne 'Core' -or $psVersion -lt [version]$pin.MinimumPowerShell) {
                $reason = 'it needs PowerShell {0} or later, and this run is PowerShell {1} ({2})' -f $pin.MinimumPowerShell, $psVersion, $edition
            }
        }
        if (-not $reason -and -not (Test-IsSystemAccount)) {
            $reason = 'it is used only in a run as SYSTEM'
        }
        if (-not $reason) {
            $processArchitecture = Get-ProcessArchitecture
            $architecture = ConvertTo-WingetClientArchitecture -Architecture $processArchitecture
            if (-not $architecture) {
                $reason = "this PowerShell runs as a process of architecture $processArchitecture, and the module has engines for x64, x86 and Arm64 only"
            }
        }
        if (-not $reason) {
            $build = Get-WindowsBuildNumber
            if ($build -lt 17763) {
                $reason = "Windows build $build is older than 17763, the oldest its engine supports"
            }
        }

        if (-not $reason) {
            $stage = 'setting up its folders'
            $directory = New-WauStagingDirectory -Prefix 'wingetclient'
            $cacheDirectory = Initialize-ProgramDataFolder -ChildName 'cache'
            $cachePath = Join-Path $cacheDirectory $pin.FileName
            $expectedSha256 = "$($pin.Sha256)".ToUpperInvariant()

            $stage = 'checking the cached package'
            if (Test-Path -LiteralPath $cachePath -PathType Leaf) {
                $stream = Open-ReadLockedFile -Path $cachePath
                if ($stream.Length -eq [long]$pin.Size -and (Get-FileHash -InputStream $stream -Algorithm SHA256).Hash -eq $expectedSha256) {
                    $source = 'Cache'
                }
                else {
                    $stream.Dispose()
                    $stream = $null
                    Remove-Item -LiteralPath $cachePath -Force -ErrorAction Stop
                    Write-Info 'The cached Microsoft.WinGet.Client package did not match the pin; downloading it again.'
                }
            }

            if (-not $source) {
                $stage = "downloading $($pin.PackageUrl)"
                Write-Info "Downloading Microsoft.WinGet.Client $($pin.Version) from the PowerShell Gallery..."
                $downloadPath = Join-Path $directory $pin.FileName
                $downloadTimeouts = Get-WebDownloadTimeoutParameters
                $downloaded = $false
                $downloadError = $null
                for ($attempt = 1; $attempt -le 2 -and -not $downloaded; $attempt++) {
                    try {
                        Invoke-WebRequest @downloadTimeouts -Uri $pin.PackageUrl -OutFile $downloadPath -UseBasicParsing -ErrorAction Stop
                        $downloaded = $true
                    }
                    catch {
                        $downloadError = $_
                        if ($attempt -lt 2) {
                            Write-WarningMessage "Could not download Microsoft.WinGet.Client ($($_.Exception.Message)); trying again in 15 seconds..."
                            Start-Sleep -Seconds 15
                        }
                    }
                }
                if (-not $downloaded) {
                    throw $downloadError
                }

                $stage = 'checking the downloaded package'
                $stream = Open-ReadLockedFile -Path $downloadPath
                $downloadedSize = $stream.Length
                $downloadedSha256 = (Get-FileHash -InputStream $stream -Algorithm SHA256).Hash
                if ($downloadedSize -ne [long]$pin.Size -or $downloadedSha256 -ne $expectedSha256) {
                    $reason = 'the downloaded package is {0} bytes with SHA256 {1}, not the pinned {2} bytes with SHA256 {3}' -f $downloadedSize, $downloadedSha256, $pin.Size, $expectedSha256
                }
                $source = 'Download'
            }

            if (-not $reason) {
                $stage = 'extracting the package'
                $moduleDirectory = Join-Path $directory $pin.Name
                $expanded = Expand-WingetClientModulePackage -Stream $stream -DestinationPath $moduleDirectory -Framework $pin.Framework -Architecture $architecture -Pin $pin
                $manifestPath = $expanded.ManifestPath
                if (-not $expanded.EngineFound) {
                    $reason = "the package has no $architecture engine"
                }
            }

            if (-not $reason) {
                $stage = 'checking its signatures'
                foreach ($signedFile in @($pin.SignedFiles)) {
                    $relativePath = ([string]$signedFile).Replace('{arch}', $architecture)
                    $signedPath = Join-Path $moduleDirectory $relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
                    $signature = Test-AuthenticodeSigner -Path $signedPath -SignerCommonName $pin.SignerCommonName
                    if (-not $signature.Valid) {
                        $reason = "$relativePath failed its signature check: $($signature.Detail)"
                        break
                    }
                }
            }

            if (-not $reason) {
                $stage = 'writing its request script'
                $childScriptPath = Join-Path $directory 'Invoke-WingetClientRequest.ps1'
                [System.IO.File]::WriteAllText($childScriptPath, (Get-WingetClientChildScript), (New-Object System.Text.UTF8Encoding($false)))
            }

            if (-not $reason -and $source -eq 'Download') {
                $partialPath = Join-Path $cacheDirectory ('{0}.{1}.partial' -f $pin.FileName, [guid]::NewGuid().ToString('N'))
                try {
                    $stream.Position = 0
                    $cacheFile = [System.IO.File]::Open($partialPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                    try {
                        $stream.CopyTo($cacheFile)
                    }
                    finally {
                        $cacheFile.Dispose()
                    }
                    [System.IO.File]::Move($partialPath, $cachePath, $true)
                    foreach ($old in @(Get-ChildItem -LiteralPath $cacheDirectory -File -Force -ErrorAction SilentlyContinue)) {
                        if (($old.Name -like 'microsoft.winget.client.*.nupkg' -and $old.Name -ne $pin.FileName) -or $old.Name -like '*.partial') {
                            Remove-Item -LiteralPath $old.FullName -Force -ErrorAction SilentlyContinue
                        }
                    }
                }
                catch {
                    Remove-Item -LiteralPath $partialPath -Force -ErrorAction SilentlyContinue
                    Write-WarningMessage "Could not keep the Microsoft.WinGet.Client package in $cacheDirectory for the next run: $($_.Exception.Message)"
                }
            }
        }
    }
    catch {
        $reason = "$stage failed: $($_.Exception.Message)"
        if ($_.FullyQualifiedErrorId -eq 'RestrictedDirectoryAclFailed') {
            $baseDir = Join-Path $env:ProgramData 'winget-app-setup'
            $reason += (Get-RestrictedDirectoryResetHint -Path $baseDir)
        }
    }
    finally {
        if ($stream) {
            $stream.Dispose()
        }
        if ($reason -and $directory) {
            Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $version = $null
    $sha256 = $null
    if ($pin) {
        $version = $pin.Version
        $sha256 = "$($pin.Sha256)".ToUpperInvariant()
    }
    if ($reason) {
        $reason = "$reason".Trim().TrimEnd('.')
        Write-WarningMessage "WinGet client module: NOT READY - $reason."
        return [pscustomobject]@{ Ready = $false; Reason = $reason; Version = $version; Sha256 = $sha256; Source = $source; Directory = $null; ManifestPath = $null; ChildScriptPath = $null; PowerShellPath = $null; Architecture = $architecture }
    }
    $from = 'downloaded from the PowerShell Gallery'
    if ($source -eq 'Cache') {
        $from = 'from the cache'
    }
    Write-Success ('WinGet client module: ready - Microsoft.WinGet.Client {0}, SHA256 {1}, {2}.' -f $version, $sha256, $from)
    return [pscustomobject]@{
        Ready           = $true
        Reason          = $null
        Version         = $version
        Sha256          = $sha256
        Source          = $source
        Directory       = $directory
        ManifestPath    = $manifestPath
        ChildScriptPath = $childScriptPath
        PowerShellPath  = [Environment]::ProcessPath
        Architecture    = $architecture
    }
}

# --- WingetLaunchResilience ---
function Test-TransientWingetLaunchError {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[int]]$NativeErrorCode
    )

    $transientCodes = @(32, 1920)
    if ($null -ne $NativeErrorCode -and $transientCodes -contains $NativeErrorCode) {
        return $true
    }
    if ([string]::IsNullOrWhiteSpace($Message)) {
        return $false
    }
    if ($Message -match 'cannot be accessed by the system|being used by another process|StandardOutputEncoding is only supported when standard output is redirected') {
        return $true
    }
    foreach ($code in $transientCodes) {
        $localized = "$(Get-Win32ErrorMessage -Code $code)".Trim().TrimEnd('.')
        if ($localized.Length -gt 0 -and $Message.IndexOf($localized, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return $true
        }
    }
    return $false
}

function Get-Win32ErrorMessage {
    param (
        [Parameter(Mandatory = $true)]
        [int]$Code
    )

    if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
        return $null
    }
    return (New-Object System.ComponentModel.Win32Exception($Code)).Message
}

function Resolve-WingetExecutable {
    $machinePath = $script:MachineWingetPath
    if ([string]::IsNullOrWhiteSpace($machinePath)) {
        return 'winget'
    }
    if (-not (Test-Path -LiteralPath $machinePath -PathType Leaf)) {
        $candidate = @(Get-MachineWingetCandidate) | Select-Object -First 1
        if ($candidate) {
            $script:MachineWingetPath = $candidate.Path
            return $candidate.Path
        }
    }
    return $machinePath
}

function Test-WingetLaunchable {
    param (
        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 100)]
        [int]$Attempts = 1,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 3600)]
        [int]$RetryDelaySeconds = 10
    )

    $timeoutSeconds = Get-ProcessTimeoutSeconds -Operation WingetVersion
    $finalExitCodes = @(-1073741515, -1978335174)
    $reason = $null
    $run = $null
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $run = Invoke-WingetProcess -ArgumentList @('--version') -TimeoutSeconds $timeoutSeconds -Echo None
        $retryable = $true
        if ($run.LaunchFailed) {
            $reason = 'winget could not be started: {0}' -f "$($run.LaunchError)".Trim().TrimEnd('.')
            $retryable = Test-TransientWingetLaunchError -NativeErrorCode $run.LaunchErrorCode -Message $run.LaunchError
        }
        elseif ($run.TimedOut) {
            $reason = "'winget --version' did not answer within $timeoutSeconds seconds and was stopped"
        }
        elseif ($run.ExitCode -ne 0) {
            $reason = "'winget --version' exited with {0}" -f (Format-WingetExitCode -ExitCode $run.ExitCode)
            if ($finalExitCodes -contains $run.ExitCode) {
                $retryable = $false
            }
        }
        else {
            $versionLine = @($run.StandardOutput | ForEach-Object { "$_".Trim() } | Where-Object { $_ -match '^v\d' }) | Select-Object -First 1
            if ($versionLine) {
                return [pscustomobject]@{ Launchable = $true; Version = $versionLine; Reason = $null; ExitCode = 0; Attempts = $attempt }
            }
            $reason = "'winget --version' printed no version"
        }

        if (-not $retryable -or $attempt -ge $Attempts) {
            break
        }
        Write-WarningMessage "winget is not usable yet ($reason). Checking again in ${RetryDelaySeconds}s (check $($attempt + 1) of $Attempts)..."
        Start-Sleep -Seconds $RetryDelaySeconds
    }

    if ($run -and -not $run.LaunchFailed -and @($run.Output).Count -gt 0) {
        Write-ProcessOutput -Line $run.Output -Tail 10
    }
    return [pscustomobject]@{ Launchable = $false; Version = $null; Reason = $reason; ExitCode = $run.ExitCode; Attempts = [Math]::Min($attempt, $Attempts) }
}

# --- WingetResultCodes ---
function Get-WingetExitCodeInfo {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[int]]$ExitCode
    )

    if ($null -eq $ExitCode -or $ExitCode -eq 0) {
        return $null
    }

    $table = @{
        '0x8A150102' = @('INSTALL_INSTALL_IN_PROGRESS', 'another installation was in progress (Windows Installer was busy) - re-run the installer once it has finished', 'InstallInProgress')
        '0x8A150101' = @('INSTALL_PACKAGE_IN_USE', 'the app is running - close it, then re-run the installer', 'InUse')
        '0x8A150103' = @('INSTALL_FILE_IN_USE', 'files the installer needs are in use - close the app, then re-run the installer', 'InUse')
        '0x8A150111' = @('INSTALL_PACKAGE_IN_USE_BY_APPLICATION', 'the app is in use by another application - close it, then re-run the installer', 'InUse')
        '0x8A150109' = @('INSTALL_REBOOT_REQUIRED_TO_FINISH', 'a restart is required to finish the installation', 'RestartRequired')
        '0x8A15010A' = @('INSTALL_REBOOT_REQUIRED_FOR_INSTALL', 'a restart is required before this installer can run - restart this PC, then re-run the installer', 'RestartRequiredFirst')
        '0x8A15010B' = @('INSTALL_REBOOT_INITIATED', 'the installer started a restart of this PC - re-run the installer after the restart', 'RestartRequired')
        '0x8A15010C' = @('INSTALL_CANCELLED_BY_USER', 'the installation was cancelled', '')
        '0x8A15010D' = @('INSTALL_ALREADY_INSTALLED', 'another version of the app is already installed', '')
        '0x8A15010E' = @('INSTALL_DOWNGRADE', 'a higher version of the app is already installed', '')
        '0x8A15010F' = @('INSTALL_BLOCKED_BY_POLICY', 'organization policy blocks this installation', '')
        '0x8A150104' = @('INSTALL_MISSING_DEPENDENCY', 'a dependency of the package is missing from this system', '')
        '0x8A150105' = @('INSTALL_DISK_FULL', 'the disk is full - free some space, then re-run the installer', '')
        '0x8A150106' = @('INSTALL_INSUFFICIENT_MEMORY', 'there was not enough memory to install', '')
        '0x8A150107' = @('INSTALL_NO_NETWORK', 'the installer needs an internet connection', '')
        '0x8A150108' = @('INSTALL_CONTACT_SUPPORT', 'the installer failed (Windows Installer service error)', '')
        '0x8A150110' = @('INSTALL_DEPENDENCIES', 'a dependency of the package failed to install', '')
        '0x8A150112' = @('INSTALL_INVALID_PARAMETER', 'the installer rejected its parameters', '')
        '0x8A150113' = @('INSTALL_SYSTEM_NOT_SUPPORTED', 'the package does not support this system', '')
        '0x8A150115' = @('INSTALL_CUSTOM_ERROR', 'the installer failed with its own error', '')
        '0x8A150006' = @('SHELLEXEC_INSTALL_FAILED', 'the installer failed (its own exit code is in the log above, and in its installer log)', '')
        '0x8A150049' = @('MSI_INSTALL_FAILED', 'the MSI installer failed (its own exit code is in the log above, and in its installer log)', '')
        '0x8A150052' = @('PORTABLE_INSTALL_FAILED', 'the portable package failed to install', '')
        '0x8A150010' = @('NO_APPLICABLE_INSTALLER', 'no installer in the package applies to this system', '')
        '0x8A15002B' = @('UPDATE_NOT_APPLICABLE', 'no applicable update was found for the installed version', '')
        '0x8A150061' = @('PACKAGE_ALREADY_INSTALLED', 'a version of the package is already installed', '')
        '0x8A15008E' = @('UPDATE_INSTALL_TECHNOLOGY_MISMATCH', 'the installed version uses a different install technology', '')
        '0x8A150068' = @('PACKAGE_IS_PINNED', 'the package is pinned in winget', '')
        '0x8A150011' = @('INSTALLER_HASH_MISMATCH', 'the downloaded installer does not match the hash in its manifest', '')
        '0x8A150086' = @('INSTALLER_ZERO_BYTE_FILE', 'the installer download was empty (network or proxy problem)', '')
        '0x8A15006D' = @('SERVICE_UNAVAILABLE', 'a download server was busy or unavailable - re-run the installer later', '')
        '0x8A150041' = @('PACKAGE_AGREEMENTS_NOT_ACCEPTED', 'the package agreements were not accepted', '')
        '0x8A150046' = @('SOURCE_AGREEMENTS_NOT_ACCEPTED', 'the source agreements were not accepted', '')
        '0x8A150001' = @('INTERNAL_ERROR', 'winget hit an internal error', '')
        '0x8A150002' = @('INVALID_CL_ARGUMENTS', 'winget rejected its command line', '')
        '0x8A150003' = @('COMMAND_FAILED', 'the winget command failed', '')
        '0x8A15000B' = @('SOURCES_INVALID', 'the configured winget sources are corrupted', 'SourceBroken')
        '0x8A15000F' = @('SOURCE_DATA_MISSING', 'the winget source data is missing', 'SourceBroken')
        '0x8A150012' = @('SOURCE_NAME_DOES_NOT_EXIST', 'the winget source is not configured', 'SourceBroken')
        '0x8A150014' = @('NO_APPLICATIONS_FOUND', 'winget found no package with that id', '')
        '0x8A150016' = @('MULTIPLE_APPLICATIONS_FOUND', 'more than one package matched the id', '')
        '0x8A150015' = @('NO_SOURCES_DEFINED', 'no winget source is configured', 'SourceBroken')
        '0x8A150019' = @('COMMAND_REQUIRES_ADMIN', 'the winget command needs administrator rights', '')
        '0x8A15003A' = @('BLOCKED_BY_POLICY', 'winget is disabled by Group Policy on this PC', '')
        '0x8A15003F' = @('SOURCE_DATA_INTEGRITY_FAILURE', 'the winget source data is corrupted', 'SourceBroken')
        '0x8A150045' = @('SOURCE_OPEN_FAILED', 'the winget source could not be opened', '')
        '0x8A15004B' = @('FAILED_TO_OPEN_ALL_SOURCES', 'one or more winget sources could not be opened', '')
        '0x8A150056' = @('INSTALLER_PROHIBITS_ELEVATION', 'the installer cannot run as administrator', '')
        '0x8A15007D' = @('ADMIN_CONTEXT_ACTION_PROHIBITED', 'not permitted as administrator on a package installed for one user', '')
        '0x80073D19' = @('ERROR_DEPLOYMENT_BLOCKED_BY_USER_LOG_OFF', 'the installing account has no logon session, so Windows blocked the app package deployment', '')
        '0x80073CF3' = @('ERROR_INSTALL_RESOLVE_DEPENDENCY_FAILED', 'a package it depends on, such as a framework, is missing', '')
        '0x80073D06' = @('ERROR_INSTALL_PACKAGE_DOWNGRADE', 'a higher version of the package is already installed', '')
        '0x80073D02' = @('ERROR_PACKAGES_IN_USE', 'the app is running - close it, then re-run the installer', '')
        '0x80004004' = @('E_ABORT', 'the operation was cancelled or stopped', '')
        '0x80072EE2' = @('WININET_E_TIMEOUT', 'the download timed out', '')
        '0x80072EE7' = @('WININET_E_NAME_NOT_RESOLVED', 'the download server name could not be resolved', '')
        '0x80072EFD' = @('WININET_E_CANNOT_CONNECT', 'could not connect to the download server', '')
        '0x80190194' = @('HTTP_E_STATUS_NOT_FOUND', 'the download returned HTTP 404 (not found)', '')
        '0xC0000135' = @('STATUS_DLL_NOT_FOUND', 'winget.exe could not start because a DLL it needs was not found', '')
    }

    $hex = '0x{0:X8}' -f [int]$ExitCode
    if (-not $table.ContainsKey($hex)) {
        return $null
    }
    $row = $table[$hex]
    return [pscustomobject]@{
        ExitCode = [int]$ExitCode
        Hex      = $hex
        Name     = $row[0]
        Meaning  = $row[1]
        Class    = $row[2]
    }
}

function Format-WingetExitCode {
    param (
        [Parameter(Mandatory = $true)]
        [int]$ExitCode
    )

    $info = Get-WingetExitCodeInfo -ExitCode $ExitCode
    if ($info) {
        return ('{0} {1}' -f $info.Hex, $info.Name)
    }
    return ('0x{0:X8}' -f $ExitCode)
}

function Test-RestartRequiredFirst {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$InstallResult
    )

    if ($null -eq $InstallResult -or $null -eq $InstallResult.ExitCode) {
        return $false
    }
    $info = Get-WingetExitCodeInfo -ExitCode ([int]$InstallResult.ExitCode)
    return [bool]($info -and $info.Class -eq 'RestartRequiredFirst')
}

function Test-WingetRestartRequiredResult {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[int]]$ExitCode,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object[]]$Output,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[long]]$InstallerErrorCode
    )

    if ($null -eq $ExitCode) {
        return $false
    }
    if ($ExitCode -ne 0) {
        $info = Get-WingetExitCodeInfo -ExitCode $ExitCode
        return [bool]($info -and $info.Class -eq 'RestartRequired')
    }
    if ($null -ne $InstallerErrorCode -and $InstallerErrorCode -eq 3010) {
        return $true
    }
    foreach ($line in @($Output)) {
        if ([string]$line -match 'Restart your PC to finish installation') {
            return $true
        }
    }
    return $false
}

# --- AppCatalog ---
function Get-DefaultAppCatalog {
    return @(
        @{name = '7zip.7zip' },
        @{name = 'GlavSoft.TightVNC'; postInstall = 'Set-TightVncServerPassword' },
        @{name = 'Adobe.Acrobat.Reader.64-bit'; arch = 'X64'; conditionDescription = 'its only installer is x64, and Adobe supports only the 32-bit Reader on ARM64 Windows' },
        @{name = 'Adobe.Acrobat.Reader.32-bit'; arch = @('Arm64', 'X86'); conditionDescription = 'ARM64 and 32-bit Windows only; x64 PCs get the 64-bit Reader' },
        @{name = 'Google.Chrome' },
        @{name = 'Google.GoogleDrive'; quietUninstall = @{ productCode = '{6BBAE539-2232-434A-A4E5-9A33560C6283}'; arguments = @('--silent', '--force_stop') } },
        @{name = 'Git.Git' },
        @{name = 'Klocman.BulkCrapUninstaller' },
        @{name = 'Dell.CommandUpdate.Universal'; arch = 'X64'; condition = { (Get-ComputerManufacturer) -match 'Dell' }; conditionDescription = 'Dell hardware with x64 Windows only; winget has no ARM64 installer for it' },
        @{name = 'Microsoft.PowerShell'; install = 'Install-PowerShellLatest' },
        @{name = 'Microsoft.WindowsTerminal'; msixName = 'Microsoft.WindowsTerminal'; condition = { (Test-IsSystemAccount) -or -not (Test-WindowsTerminalHostsCurrentSession) }; conditionDescription = 'winget cannot self-update Windows Terminal from a session Windows Terminal itself is hosting (issue #271)' }
    )
}

# --- AppValidation ---
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

        if (-not (Test-WingetPackageIdFormat -PackageId $name)) {
            $errors += "App entry at index $i has an invalid package id '$name': does not match the required publisher.product shape."
            continue
        }

        $schemaIssues = Get-AppDefinitionSchemaIssue -App $app -Label "App entry at index $i ('$name')"
        $warnings += @($schemaIssues.Warnings)
        if (@($schemaIssues.Errors).Count -gt 0) {
            $errors += @($schemaIssues.Errors)
            continue
        }

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

# --- Elevation ---
function Test-IsAdmin {
    try {
        $principal = Get-CurrentWindowsPrincipal
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole] 'Administrator')
    }
    catch {
        Write-WarningMessage "Could not determine administrator status; assuming elevated: $_"
        return $true
    }
}

function Restart-WithElevation {
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [Parameter(Mandatory = $false)]
        [ValidatePattern('^(?:-[A-Za-z][A-Za-z0-9]*|[0-9][0-9A-Za-z:.-]*)\z')]
        [string[]]$AdditionalArguments = @(),

        [Parameter(Mandatory = $false)]
        [string]$ExpectedSha256,

        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive
    )

    if (Test-EffectiveNonInteractive -NonInteractive:$NonInteractive) {
        Write-ErrorMessage 'Administrator rights are required, and this run is non-interactive, so there is nobody to approve a UAC prompt and none was shown. Run it from an elevated session, or as SYSTEM.'
        return [pscustomobject]@{ Started = $false; ExitCode = 4 }
    }

    $policyBlock = Get-ScriptExecutionPolicyBlock -Engine WindowsPowerShell
    if ($policyBlock) {
        $policyMessage = Format-ElevationPolicyBlockMessage -Block $policyBlock
        if ($policyBlock.Scope -eq 'MachinePolicy') {
            Write-ErrorMessage "$policyMessage No UAC prompt was shown."
            return [pscustomobject]@{ Started = $false; ExitCode = 4 }
        }
        Write-WarningMessage $policyMessage
    }

    $powerShellPath = Get-WindowsPowerShellPath
    try {
        $bytes = [System.IO.File]::ReadAllBytes($ScriptPath)
    }
    catch {
        Write-ErrorMessage "Could not read $ScriptPath to run it elevated: $($_.Exception.Message)"
        return [pscustomobject]@{ Started = $false; ExitCode = 5 }
    }
    $sha256 = [System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)).Replace('-', '')
    if ($ExpectedSha256 -and $sha256 -ne $ExpectedSha256) {
        Write-ErrorMessage "$ScriptPath changed after this run started, so it is not run with administrator rights. Start it again."
        return [pscustomobject]@{ Started = $false; ExitCode = 5 }
    }
    $stagingDirectory = $null
    try {
        $stagingDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('winget-app-setup-elevate-' + [System.Guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $stagingDirectory -Force -ErrorAction Stop)
        $stagedPath = Join-Path $stagingDirectory (($ScriptPath -split '[\\/]')[-1])
        [System.IO.File]::WriteAllBytes($stagedPath, $bytes)
    }
    catch {
        Write-ErrorMessage "Could not copy $ScriptPath to run it elevated: $($_.Exception.Message)"
        if ($stagingDirectory) {
            Remove-Item -LiteralPath $stagingDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
        return [pscustomobject]@{ Started = $false; ExitCode = 5 }
    }
    $verifierCommand = New-ElevationVerifierCommand -ScriptPath $stagedPath -Sha256 $sha256 -PowerShellPath $powerShellPath -CopyRoot (Get-ElevatedCopyRoot) -AdditionalArguments $AdditionalArguments
    $argumentString = ConvertTo-ProcessArgumentString -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $verifierCommand)

    try {
        if ($argumentString.Length -gt 2000) {
            Write-ErrorMessage "The command that starts $ScriptPath elevated is too long, because the file name or this account's %TEMP% path ($([System.IO.Path]::GetTempPath())) is long. Give the file a shorter name, or start it from an elevated session."
            return [pscustomobject]@{ Started = $false; ExitCode = 4 }
        }

        Remove-Item -Path Env:\WINGET_APP_SETUP_PS7_BOOTSTRAP -ErrorAction SilentlyContinue

        Write-Info 'Approve the administrator (UAC) prompt. The run continues in a new, elevated Windows PowerShell window, and this window waits for it to finish.'
        $process = $null
        try {
            $process = Start-ElevatedProcess -FilePath $powerShellPath -ArgumentString $argumentString
        }
        catch {
            if ((Get-NativeErrorCode -Exception $_.Exception) -eq 1223) {
                Write-ErrorMessage 'The administrator (UAC) prompt was declined, so no elevated run was started. Run it again and approve the prompt, or start it from an elevated session.'
            }
            else {
                Write-ErrorMessage "Could not start an elevated Windows PowerShell ($powerShellPath): $($_.Exception.Message)"
            }
            return [pscustomobject]@{ Started = $false; ExitCode = 4 }
        }
        if (-not $process) {
            Write-ErrorMessage 'An elevated Windows PowerShell was requested, but Windows returned no process to wait for, so its outcome is unknown. Check the elevated window and its log.'
            return [pscustomobject]@{ Started = $true; ExitCode = 5 }
        }

        while (-not $process.WaitForExit(1000)) {
        }
        $exitCode = [int]$process.ExitCode
        Write-Info "The elevated run ended with exit code $exitCode."
        return [pscustomobject]@{ Started = $true; ExitCode = $exitCode }
    }
    finally {
        if ($stagingDirectory) {
            Remove-Item -LiteralPath $stagingDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# --- Install ---
function Invoke-WingetInstall {
    [OutputType([int])]
    param (
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf,
        [Parameter(Mandatory = $false)]
        [switch]$NonInteractive,

        [Parameter(Mandatory = $false)]
        [switch]$SkipSystemCheck,

        [Parameter(Mandatory = $false)]
        [array]$Apps = (Get-DefaultAppCatalog),

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 1440)]
        [int]$MaxRuntimeMinutes = 0,

        [Parameter(Mandatory = $false)]
        [string]$RunDeadlineUtc
    )

    $effectiveNonInteractive = Test-EffectiveNonInteractive -NonInteractive:$NonInteractive

    $runStartedUtc = [DateTime]::UtcNow
    if ($script:InstallerRunStartedUtc -is [DateTime]) {
        $runStartedUtc = $script:InstallerRunStartedUtc
    }
    $budgetParameters = @{ RunDeadlineUtc = $RunDeadlineUtc; StartedUtc = $runStartedUtc }
    if ($PSBoundParameters.ContainsKey('MaxRuntimeMinutes')) {
        $budgetParameters['MaxRuntimeMinutes'] = $MaxRuntimeMinutes
    }
    $runBudget = Resolve-InstallerRunBudget @budgetParameters
    $runBudgetSpent = $false
    $runBudgetReason = $null
    if ($runBudget.DeadlineUtc) {
        $runBudgetReason = "the run's $($runBudget.Minutes)-minute time budget was used up"
    }

    if ($WhatIf) {
        Write-Info '=== DRY-RUN MODE ENABLED ==='
        Write-Info 'No system changes will be made. This is a simulation of what would happen.'
        Write-Host ''
    }

    $isAdmin = Test-IsAdmin

    If (-NOT $isAdmin) {
        if ($WhatIf) {
            if (-not (Test-IsRunningLocally)) {
                Write-Info '[DRY-RUN] Would require administrator privileges for a real run (auto-elevation is unavailable when running through IEX/remote execution). Continuing the preview in the current (non-elevated) session; no system changes will be made.'
            }
            elseif ($effectiveNonInteractive) {
                Write-Info '[DRY-RUN] A real run would stop here with exit code 4: it needs administrator privileges, and a non-interactive run shows no UAC prompt. Continuing the preview in the current (non-elevated) session; no system changes will be made.'
            }
            else {
                $elevationPolicyBlock = Get-ScriptExecutionPolicyBlock -Engine WindowsPowerShell
                if ($elevationPolicyBlock -and $elevationPolicyBlock.Scope -eq 'MachinePolicy') {
                    Write-Info ('[DRY-RUN] A real run would stop here with exit code 4, without a UAC prompt: {0} Continuing the preview in the current (non-elevated) session; no system changes will be made.' -f (Format-ElevationPolicyBlockMessage -Block $elevationPolicyBlock))
                }
                else {
                    Write-Info '[DRY-RUN] Would relaunch with administrator privileges. Continuing the preview in the current (non-elevated) session; no system changes will be made.'
                    if ($elevationPolicyBlock) {
                        Write-Info ('[DRY-RUN] {0}' -f (Format-ElevationPolicyBlockMessage -Block $elevationPolicyBlock))
                    }
                }
            }
        }
        elseif (-not (Test-IsRunningLocally)) {
            Write-ErrorMessage 'This script requires administrator privileges.'
            Write-ErrorMessage 'Auto-elevation is unavailable when running through IEX/remote execution.'
            Write-Info 'Open an elevated PowerShell or Windows Terminal session and run the IEX command again.'
            return 4
        }
        elseif (Test-InvokedFromModuleContext -InvocationModule $MyInvocation.MyCommand.Module -CommandPath $PSCommandPath) {
            Write-ErrorMessage 'Invoke-WingetInstall was invoked from the imported module without elevation; auto-elevation cannot relaunch a module function. Run winget-app-install.ps1, or start from an already-elevated session.'
            return 4
        }
        elseif ($effectiveNonInteractive) {
            Write-ErrorMessage 'This script requires administrator privileges, and this run is non-interactive, so there is nobody to approve a UAC prompt and none was shown. Run it from an elevated session, or as SYSTEM (for example from an RMM tool).'
            return 4
        }
        else {
            Write-ErrorMessage 'This script requires administrator privileges. Restarting with elevated privileges...'
            $elevationArgs = @()
            if ($WhatIf) { $elevationArgs += '-WhatIf' }
            if ($SkipSystemCheck) { $elevationArgs += '-SkipSystemCheck' }
            $elevationArgs += @(Get-InstallerRunBudgetArgument -Budget $runBudget)
            $elevation = Restart-WithElevation -ScriptPath $PSCommandPath -AdditionalArguments $elevationArgs -ExpectedSha256 $script:InstallerScriptSha256
            if (-not $elevation.Started) {
                Write-ErrorMessage 'No elevated run was started, so nothing was installed.'
                return [int]$elevation.ExitCode
            }
            $script:InstallerPendingExitCode = [int]$elevation.ExitCode
            $script:InstallerRunReportPending = $false
            return [int]$elevation.ExitCode
        }
    }
    else {
        Write-Success 'Starting...'
    }

    if ($runBudget.DeadlineUtc) {
        $deadlineText = Format-RunRecordTime -Time $runBudget.DeadlineUtc
        if ($WhatIf) {
            Write-Info "[DRY-RUN] Time budget: $($runBudget.Minutes) minutes, until $deadlineText. A real run starts no app install and no Winget-AutoUpdate setup after that, and exits 9; this preview is not cut short."
        }
        else {
            Write-Info "Time budget: $($runBudget.Minutes) minutes, until $deadlineText. No app install, retry or Winget-AutoUpdate setup starts after that (one already running finishes); what is left is reported as not attempted, and the run exits 9 so that it can be run again."
        }
    }

    $script:MachineWingetPath = $null
    $script:WingetClientEngine = $null
    $account = Get-InstallAccountContext
    $machineWide = [bool]($account.IsSystem -or $account.IsCrossUserElevation)
    $engineRequest = Get-SystemInstallEngineRequest
    $requestedEngine = 'Cli'
    if ($account.IsSystem) {
        $requestedEngine = $engineRequest.Engine
    }
    $script:InstallEngineRecord = New-InstallEngineRecord -Requested $requestedEngine -Used 'Cli'
    if (-not $account.IsSystem -and $engineRequest.Engine -eq 'WinGetClient') {
        Write-Info 'WINGET_APP_SETUP_SYSTEM_ENGINE=WinGetClient applies only to runs as SYSTEM; this run uses winget.'
    }
    if ($account.IsSystem -and $requestedEngine -eq 'WinGetClient') {
        Write-Info 'Running as SYSTEM (for example from an RMM agent): installing for the whole PC only, with the Microsoft.WinGet.Client module (requested by WINGET_APP_SETUP_SYSTEM_ENGINE), or the machine-wide winget.exe if the module is not ready. An app with no machine-wide installer is not installed: it is reported as Deferred, with how it can still be installed for the user.'
    }
    elseif ($account.IsSystem) {
        Write-Info 'Running as SYSTEM (for example from an RMM agent): installing for the whole PC only, with the winget.exe that App Installer installed for this PC. An app with no machine-wide installer is not installed: it is reported as Deferred, with how it can still be installed for the user. Microsoft does not support the winget command line as SYSTEM, so a SYSTEM run can fail where a run as a user would not.'
    }

    $preflight = Invoke-EnvironmentPreflight -WhatIf:$WhatIf -AccountContext $account
    if ($preflight.ExitCode -ne 0) {
        return [int]$preflight.ExitCode
    }
    $restartStateBefore = $preflight.RestartState
    $restartPendingBefore = @($preflight.RestartPendingReasons)

    try {
        Initialize-TightVncSecretForRun -Apps $Apps -NonInteractive:$effectiveNonInteractive -WhatIf:$WhatIf
    }
    catch {
        Write-WarningMessage "Could not read the TightVNC password for this run: $($_.Exception.Message)"
    }

    if (-not $WhatIf) {
        $budgetSecondsLeft = Get-InstallerRunBudgetSecondsLeft -Budget $runBudget
        if ($null -eq $budgetSecondsLeft) {
            [void](Wait-WauIdle)
        }
        elseif ($budgetSecondsLeft -gt 0) {
            [void](Wait-WauIdle -TimeoutSeconds ([Math]::Min(900, $budgetSecondsLeft)))
        }
    }

    if ($preflight.WingetPolicyBlocked) {
        $winget = [pscustomobject]@{ Ready = $false; Diagnosis = 'PolicyBlocked' }
    }
    else {
        $engineParameters = @{}
        if ($account.IsSystem) {
            $engineParameters['SystemInstallEngine'] = $requestedEngine
        }
        $winget = Initialize-Winget -WhatIf:$WhatIf -AccountContext $account @engineParameters
    }
    $wingetAvailable = [bool]$winget.Ready
    if (-not $wingetAvailable -and -not $WhatIf) {
        Write-ErrorMessage 'Winget is required for this script. Exiting.'
        Clear-TightVncSecret
        return 2
    }

    [void](Remove-LegacyScheduledUpdates -WhatIf:$WhatIf)

    $apps = $Apps

    $validationResult = Test-AppDefinitions -Apps $apps

    foreach ($validationWarning in $validationResult.Warnings) {
        Write-Warning $validationWarning
    }

    if ($validationResult.Errors.Count -gt 0) {
        foreach ($validationError in $validationResult.Errors) {
            Write-ErrorMessage $validationError
        }
        Write-ErrorMessage 'No valid application definitions found. Resolve the errors and re-run the script.'
        Clear-TightVncSecret
        return 3
    }

    $apps = $validationResult.ValidApps

    if ($apps.Count -eq 0) {
        Write-ErrorMessage 'No application definitions remain after validation. Add at least one valid entry and re-run the script.'
        Clear-TightVncSecret
        return 3
    }

    Write-Info 'Installing the following Apps:'
    ForEach ($app in $apps) {
        Write-Info $app.name
    }

    if (-not $wingetAvailable) {
        $wingetScope = 'for this account'
        if ($account.IsSystem) {
            $wingetScope = 'machine-wide'
        }
        Write-Info "[DRY-RUN] winget is not available $wingetScope, so this preview cannot tell which apps are already installed: every app that applies to this machine is listed as one a real run would install."
    }

    $installedApps = @()
    $skippedApps = @()
    $failedApps = @()
    $deferredApps = @()
    $noInstallerDeferredApps = @()
    $perUserDeferredApps = @()
    $notConfiguredApps = @()
    $notAttemptedApps = @()

    $wingetNotLaunchable = $false

    $installerBusyWaitSecondsLeft = 600

    $restartRequiredApps = @()

    $applicableByName = @{}
    foreach ($app in $apps) {
        $applicableByName[$app.name] = Test-AppApplicability -App $app
    }

    $appRecords = [ordered]@{}
    $script:InstallerAppRecords = $appRecords

    Foreach ($app in $apps) {
        $outcome = $null
        if (-not $WhatIf -and -not $runBudgetSpent -and (Test-InstallerRunBudgetSpent -Budget $runBudget)) {
            $runBudgetSpent = $true
            Write-WarningMessage "Time budget: $runBudgetReason, so no further app install starts. The apps left are reported as not attempted; run the installer again to install them."
        }
        try {
            $outcome = Install-AppWithVerification -App $app -Applicable $applicableByName[$app.name] -Silent:$effectiveNonInteractive -WhatIf:$WhatIf -WingetNotLaunchable:$wingetNotLaunchable -MachineWide:$machineWide -TimeBudgetSpent:$runBudgetSpent -InstallInProgressWaitSeconds (Get-InstallerRunBudgetWaitSeconds -Budget $runBudget -Seconds $installerBusyWaitSecondsLeft)
            if ($outcome.InstallResult -and $outcome.InstallResult.InstallInProgressWaitedSeconds) {
                $installerBusyWaitSecondsLeft = [Math]::Max(0, $installerBusyWaitSecondsLeft - [int]$outcome.InstallResult.InstallInProgressWaitedSeconds)
            }

            switch ($outcome.Status) {
                'Skipped' {
                    if ($outcome.SkipReason -eq 'NotApplicable') {
                        $conditionText = Get-AppNotApplicableReason -App $app
                        Write-WarningMessage "Skipping: $($app.name) (not applicable: $conditionText)"
                        $skipReason = "not applicable: $conditionText"
                    }
                    elseif ($outcome.SkipReason -eq 'Provisioned') {
                        Write-WarningMessage "Skipping: $($app.name) (already provisioned for every user on this PC)"
                        $skipReason = 'already provisioned for every user on this PC'
                    }
                    else {
                        Write-WarningMessage "Skipping: $($app.name) (already installed)"
                        $skipReason = 'already installed'
                    }
                    $skippedApps += $app.name
                    if (Write-AppPostInstallResult -AppName $app.name -Configuration $outcome.Configuration) {
                        $notConfiguredApps += @{ Name = $app.name; Reason = [string]$outcome.Configuration.Reason }
                    }
                    $appRecords[$app.name] = New-AppRunRecord -Id $app.name -Status 'Skipped' -Reason $skipReason -PostInstall $outcome.Configuration
                }
                'Deferred' {
                    $deferText = Get-AppDeferReasonText -DeferReason $outcome.DeferReason
                    Write-WarningMessage "Deferred: $($app.name) ($deferText)"
                    $deferredApps += $app.name
                    if (@('UserScope', 'UserPhase') -contains $outcome.DeferReason) {
                        $perUserDeferredApps += $app.name
                    }
                    else {
                        $noInstallerDeferredApps += $app.name
                    }
                    $appRecords[$app.name] = New-AppRunRecord -Id $app.name -Status 'Deferred' -Reason $deferText -InstallResult $outcome.InstallResult
                }
                'NotAttempted' {
                    Write-WarningMessage "Not attempted: $($app.name) ($runBudgetReason)"
                    $notAttemptedApps += $app.name
                    $appRecords[$app.name] = New-AppRunRecord -Id $app.name -Status 'NotAttempted' -Reason $runBudgetReason
                }
                'Installed' {
                    if ($WhatIf) {
                        Write-Info "[DRY-RUN] Would install: $($app.name)"
                    }
                    else {
                        Write-Success "Successfully installed: $($app.name)"
                        if (Write-InstalledAppNote -AppName $app.name -InstallResult $outcome.InstallResult) {
                            $restartRequiredApps += $app.name
                        }
                        if (Write-AppPostInstallResult -AppName $app.name -Configuration $outcome.Configuration) {
                            $notConfiguredApps += @{ Name = $app.name; Reason = [string]$outcome.Configuration.Reason }
                        }
                    }
                    $installedApps += $app.name
                    $appRecords[$app.name] = New-AppRunRecord -Id $app.name -Status 'Installed' -InstallResult $outcome.InstallResult -RestartRequired ($restartRequiredApps -contains $app.name) -PostInstall $outcome.Configuration
                }
                default {
                    $failureReason = Format-InstallFailureReason -FailureReason $outcome.FailureReason -InstallResult $outcome.InstallResult -LaunchError $outcome.LaunchError -CheckExitCode $outcome.CheckExitCode -PostInstallReason $outcome.Configuration.Reason
                    switch ($outcome.FailureReason) {
                        'PreCheckTimeout' {
                            Write-WarningMessage "Winget list timed out for $($app.name). Marking as failed; it will be retried."
                        }
                        'VerifyTimeout' {
                            Write-WarningMessage "Verification timed out for: $($app.name). Assuming installation failed."
                        }
                        default {
                            Write-ErrorMessage "Failed to install: $($app.name) ($failureReason)."
                        }
                    }
                    if ($outcome.FailureReason -eq 'PostInstallFailed' -and $outcome.StatusBeforeHook -eq 'Installed' -and (Write-InstalledAppNote -AppName $app.name -InstallResult $outcome.InstallResult)) {
                        $restartRequiredApps += $app.name
                    }
                    $failedApps += @{
                        Name             = $app.name
                        Reason           = $failureReason
                        RestartFirst     = (Test-RestartRequiredFirst -InstallResult $outcome.InstallResult)
                        FailureReason    = $outcome.FailureReason
                        StatusBeforeHook = $outcome.StatusBeforeHook
                        InstallResult    = $outcome.InstallResult
                    }
                    $appRecords[$app.name] = New-AppRunRecord -Id $app.name -Status 'Failed' -Reason $failureReason -InstallResult $outcome.InstallResult -RestartRequired ($restartRequiredApps -contains $app.name) -PostInstall $outcome.Configuration
                }
            }
        }
        catch {
            Write-ErrorMessage "Failed to install: $($app.name). Error: $_"
            $failedApps += @{ Name = $app.name; Reason = "Unexpected error: $_" }
            $appRecords[$app.name] = New-AppRunRecord -Id $app.name -Status 'Failed' -Reason "Unexpected error: $_"
        }

        if (-not $WhatIf -and -not $wingetNotLaunchable -and $outcome -and (Invoke-WingetLaunchCircuitBreaker -Outcome $outcome)) {
            $wingetNotLaunchable = $true
        }
    }

    try {
        Set-WindowsTerminalDefaults -WhatIf:$WhatIf
    }
    catch {
        Write-WarningMessage "Windows Terminal configuration failed unexpectedly: $_. Continuing; app installs are not affected."
    }

    if ($failedApps.Count -gt 0) {
        if ($wingetNotLaunchable) {
            $notLaunchable = 'winget cannot be launched on this machine'
            if (Test-WingetClientEngineActive) {
                $notLaunchable = 'the WinGet client engine cannot be started on this machine'
            }
            Write-WarningMessage "Skipping the retry pass: $notLaunchable (see above); retrying would not help."
        }
        elseif (-not $WhatIf) {
            Write-Host ''
            Write-Info 'Retrying failed installations (1 final attempt)...'

            $appsToRetry = $failedApps
            $failedApps = @()

            foreach ($failedApp in $appsToRetry) {
                $appName = $failedApp.Name
                if ($failedApp.RestartFirst) {
                    Write-WarningMessage "Not retrying ${appName}: its installer cannot run until this PC restarts."
                    $failedApps += $failedApp
                    continue
                }
                if ($failedApp.FailureReason -eq 'NoMachineScopeInstaller') {
                    Write-WarningMessage "Not retrying ${appName}: no machine-scope installer applies to this PC, and its catalog entry allows only a machine-wide install (scope 'machine')."
                    $failedApps += $failedApp
                    continue
                }
                if (-not $runBudgetSpent -and (Test-InstallerRunBudgetSpent -Budget $runBudget)) {
                    $runBudgetSpent = $true
                    Write-WarningMessage "Time budget: $runBudgetReason, so no further retry starts."
                }
                if ($runBudgetSpent) {
                    Write-WarningMessage "Not retrying ${appName}: $runBudgetReason."
                    $failedApps += $failedApp
                    continue
                }
                $outcome = $null
                try {
                    Write-Info "Retrying: $appName"
                    $appDef = $apps | Where-Object { $_.name -eq $appName } | Select-Object -First 1

                    $outcome = Install-AppWithVerification -App $appDef -Applicable $applicableByName[$appName] -Silent:$effectiveNonInteractive -WingetNotLaunchable:$wingetNotLaunchable -MachineWide:$machineWide -InstallInProgressWaitSeconds (Get-InstallerRunBudgetWaitSeconds -Budget $runBudget -Seconds $installerBusyWaitSecondsLeft)
                    if ($outcome.InstallResult -and $outcome.InstallResult.InstallInProgressWaitedSeconds) {
                        $installerBusyWaitSecondsLeft = [Math]::Max(0, $installerBusyWaitSecondsLeft - [int]$outcome.InstallResult.InstallInProgressWaitedSeconds)
                    }

                    $hookRetry = $failedApp.FailureReason -eq 'PostInstallFailed'
                    $recordInstallResult = $outcome.InstallResult
                    if ($hookRetry -and $null -eq $recordInstallResult) {
                        $recordInstallResult = $failedApp.InstallResult
                    }

                    if ($outcome.Status -eq 'Failed') {
                        $failureReason = Format-InstallFailureReason -FailureReason $outcome.FailureReason -InstallResult $outcome.InstallResult -LaunchError $outcome.LaunchError -CheckExitCode $outcome.CheckExitCode -PostInstallReason $outcome.Configuration.Reason
                        switch ($outcome.FailureReason) {
                            'PreCheckTimeout' {
                                Write-WarningMessage "Winget list timed out for retry: $appName. Assuming installation failed."
                            }
                            'VerifyTimeout' {
                                Write-WarningMessage "Verification timed out for retry: $appName. Assuming installation failed."
                            }
                            default {
                                Write-ErrorMessage "Retry failed: $appName ($failureReason)."
                            }
                        }
                        $failedApps += @{ Name = $appName; Reason = $failureReason; RestartFirst = (Test-RestartRequiredFirst -InstallResult $outcome.InstallResult); FailureReason = $outcome.FailureReason }
                        $appRecords[$appName] = New-AppRunRecord -Id $appName -Status 'Failed' -Reason $failureReason -InstallResult $recordInstallResult -RestartRequired ($restartRequiredApps -contains $appName) -PostInstall $outcome.Configuration
                    }
                    elseif ($outcome.Status -eq 'Deferred') {
                        $deferText = Get-AppDeferReasonText -DeferReason $outcome.DeferReason
                        Write-WarningMessage "Deferred: $appName ($deferText)"
                        $deferredApps += $appName
                        if (@('UserScope', 'UserPhase') -contains $outcome.DeferReason) {
                            $perUserDeferredApps += $appName
                        }
                        else {
                            $noInstallerDeferredApps += $appName
                        }
                        $appRecords[$appName] = New-AppRunRecord -Id $appName -Status 'Deferred' -Reason $deferText -InstallResult $outcome.InstallResult
                    }
                    elseif ($outcome.SkipReason -eq 'NotApplicable') {
                        $conditionText = Get-AppNotApplicableReason -App $appDef
                        Write-WarningMessage "Skipping: $appName (not applicable: $conditionText)"
                        $skippedApps += $appName
                        $appRecords[$appName] = New-AppRunRecord -Id $appName -Status 'Skipped' -Reason "not applicable: $conditionText"
                    }
                    else {
                        Write-Success "Retry succeeded: $appName"
                        if ($outcome.Status -eq 'Installed' -and (Write-InstalledAppNote -AppName $appName -InstallResult $outcome.InstallResult) -and $restartRequiredApps -notcontains $appName) {
                            $restartRequiredApps += $appName
                        }
                        if (Write-AppPostInstallResult -AppName $appName -Configuration $outcome.Configuration) {
                            $notConfiguredApps += @{ Name = $appName; Reason = [string]$outcome.Configuration.Reason }
                        }
                        if ($hookRetry -and $outcome.Status -eq 'Skipped' -and $failedApp.StatusBeforeHook -ne 'Installed') {
                            $skipReason = 'already installed'
                            if ($outcome.SkipReason -eq 'Provisioned') {
                                $skipReason = 'already provisioned for every user on this PC'
                            }
                            $skippedApps += $appName
                            $appRecords[$appName] = New-AppRunRecord -Id $appName -Status 'Skipped' -Reason $skipReason -PostInstall $outcome.Configuration
                        }
                        else {
                            $installedApps += $appName
                            $appRecords[$appName] = New-AppRunRecord -Id $appName -Status 'Installed' -InstallResult $recordInstallResult -RestartRequired ($restartRequiredApps -contains $appName) -PostInstall $outcome.Configuration
                        }
                    }
                }
                catch {
                    Write-ErrorMessage "Retry failed: $appName. Error: $_"
                    $failedApps += @{ Name = $appName; Reason = "Unexpected error: $_" }
                    $appRecords[$appName] = New-AppRunRecord -Id $appName -Status 'Failed' -Reason "Unexpected error: $_"
                }

                if (-not $wingetNotLaunchable -and $outcome -and (Invoke-WingetLaunchCircuitBreaker -Outcome $outcome)) {
                    $wingetNotLaunchable = $true
                }
            }
        }
        else {
            Write-Host ''
            Write-Info '[DRY-RUN] Would retry the following failed installations:'
            foreach ($failedApp in $failedApps) {
                Write-Info "[DRY-RUN] Would retry: $($failedApp.Name)"
            }
        }
    }

    Remove-WingetClientEngine

    Clear-TightVncSecret

    if (-not $WhatIf -and -not $runBudgetSpent -and (Test-InstallerRunBudgetSpent -Budget $runBudget)) {
        $runBudgetSpent = $true
    }
    if ($runBudgetSpent) {
        Write-WarningMessage "Not setting up Winget-AutoUpdate (or the Windows App Runtime it needs): $runBudgetReason. The next run sets it up."
        $wauResult = [pscustomobject]@{ Status = 'NotAttempted'; Version = $null; FrameworkMissing = $false; RestartRequired = $false }
    }
    else {
        try {
            $wauResult = Install-WingetAutoUpdate -WhatIf:$WhatIf -InstallInProgressWaitSeconds (Get-InstallerRunBudgetWaitSeconds -Budget $runBudget -Seconds $installerBusyWaitSecondsLeft)
        }
        catch {
            Write-ErrorMessage "Winget-AutoUpdate setup failed unexpectedly: $_"
            $wauResult = [pscustomobject]@{ Status = 'Failed'; Version = $null }
        }
    }
    $script:InstallerAutoUpdateResult = $wauResult

    $wingetUsableAtEnd = $true
    $wingetUsableForRecord = $null
    $endCheckReason = $null
    if (-not $WhatIf) {
        try {
            $endCheckAttempts = 5
            if ($wingetNotLaunchable) {
                $endCheckAttempts = 1
            }
            $endCheck = Test-WingetLaunchable -Attempts $endCheckAttempts -RetryDelaySeconds 15
            $wingetUsableAtEnd = [bool]$endCheck.Launchable
            $wingetUsableForRecord = $wingetUsableAtEnd
            $endCheckReason = $endCheck.Reason
        }
        catch {
            Write-WarningMessage "Could not run the end-of-run winget check: $_"
        }
    }

    $restartReasons = @()
    if ($restartRequiredApps.Count -gt 0) {
        $restartReasons += ('{0} reported that a restart finishes the installation' -f ($restartRequiredApps -join ', '))
    }
    if ($wauResult -and $wauResult.RestartRequired) {
        $restartReasons += 'the Winget-AutoUpdate installer reported that a restart finishes the installation'
    }
    if (-not $WhatIf -and $null -ne $restartStateBefore) {
        try {
            $restartReasons += @(Get-PendingRestartReason -State (Get-PendingRestartState) -Since $restartStateBefore)
        }
        catch {
            Write-WarningMessage "Could not check whether a restart is pending after the run: $_"
        }
    }
    $restartRequired = $restartReasons.Count -gt 0
    $restartFirstApps = @($failedApps | Where-Object { $_.RestartFirst } | ForEach-Object { $_.Name })

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

    $appList = Format-AppList -AppArray $deferredApps
    if ($appList) {
        $rows += , @('Deferred', $appList)
    }

    $failedAppNames = @($failedApps | ForEach-Object { $_.Name })
    $appList = Format-AppList -AppArray $failedAppNames
    if ($appList) {
        $rows += , @('Failed', $appList)
    }

    $appList = Format-AppList -AppArray $notAttemptedApps
    if ($appList) {
        $rows += , @('Not attempted', $appList)
    }

    Write-Table -Headers $headers -Rows $rows -Title 'Installation Summary'

    Write-FailedAppsSummary -FailedApps $failedApps

    $installEngineRecord = Get-InstallEngineRecord
    Write-DeferredAppsSummary -DeferredApps $noInstallerDeferredApps -PerUserApps $perUserDeferredApps -AccountContext $account -InstallEngine $installEngineRecord.used

    Write-NotConfiguredAppsSummary -NotConfiguredApps $notConfiguredApps

    if ($installEngineRecord.requested -eq 'WinGetClient' -and $installEngineRecord.used -eq 'Cli' -and -not $WhatIf) {
        Write-WarningMessage ('Install engine: Microsoft.WinGet.Client was requested but not used ({0}); this run installed with winget.exe.' -f "$($installEngineRecord.fallbackReason)".TrimEnd('.'))
    }

    $autoUpdatesHealthy = $true
    $wauFrameworkName = 'Microsoft.WindowsAppRuntime.1.8'
    if ($wauResult -and $wauResult.FrameworkName) {
        $wauFrameworkName = [string]$wauResult.FrameworkName
    }
    switch ($wauResult.Status) {
        'Configured' { Write-Success "Auto-updates: Configured (Winget-AutoUpdate v$($wauResult.Version))." }
        'AlreadyPresent' {
            if ($wauResult.FrameworkMissing) {
                Write-ErrorMessage "Auto-updates: AT RISK - Winget-AutoUpdate is installed but $wauFrameworkName is missing; its next run may leave winget unusable (see above)."
                if ($wauResult.FrameworkInstallError) {
                    Write-ErrorMessage "  The installer could not install it: $($wauResult.FrameworkInstallError)."
                }
                $autoUpdatesHealthy = $false
            }
            elseif ($wauResult.Version) {
                Write-Success "Auto-updates: Already present (v$($wauResult.Version))."
            }
            else {
                Write-WarningMessage 'Auto-updates: Already present (installed version could not be determined).'
            }
        }
        'Unhealthy' {
            $autoUpdatesConsequence = 'apps will not update automatically'
            if ($wauResult.CheckFailed) {
                $autoUpdatesConsequence = 'it is not known whether apps will update automatically'
            }
            Write-ErrorMessage "Auto-updates: UNHEALTHY - Winget-AutoUpdate is installed, but $($wauResult.Problem); $autoUpdatesConsequence (see above)."
            $autoUpdatesHealthy = $false
        }
        'DryRun' { Write-Info "[DRY-RUN] Auto-updates: Would configure Winget-AutoUpdate v$($wauResult.Version)." }
        'NotAttempted' { Write-WarningMessage "Auto-updates: NOT ATTEMPTED - $runBudgetReason before Winget-AutoUpdate was set up; run the installer again to set it up." }
        'FrameworkMissing' {
            $wauFrameworkRelease = $wauFrameworkName -replace 'Microsoft\.WindowsAppRuntime\.', ''
            Write-ErrorMessage "Auto-updates: NOT CONFIGURED - $wauFrameworkName is missing, and Winget-AutoUpdate would leave winget unusable without it. Install the Windows App Runtime $wauFrameworkRelease (or let the Microsoft Store update App Installer), then re-run the installer."
            if ($wauResult.FrameworkInstallError) {
                Write-ErrorMessage "  The installer could not install it: $($wauResult.FrameworkInstallError)."
            }
            $autoUpdatesHealthy = $false
        }
        default {
            Write-ErrorMessage 'Auto-updates: FAILED - Winget-AutoUpdate could not be installed; apps will not update automatically. Re-run the installer to retry.'
            $autoUpdatesHealthy = $false
        }
    }

    if (-not $wingetUsableAtEnd) {
        $endCheckDetail = ''
        if (-not [string]::IsNullOrWhiteSpace($endCheckReason)) {
            $endCheckDetail = " ($endCheckReason)"
        }
        Write-ErrorMessage "winget: NOT USABLE - winget did not work at the end of this run$endCheckDetail, so automatic updates and the next run of this installer will fail on this machine. Restart the machine and re-run the installer; if it persists, attach this transcript to a GitHub issue."
    }

    if ($restartFirstApps.Count -gt 0) {
        Write-ErrorMessage ('Restart: REQUIRED before {0} can install - restart this PC, then re-run the installer.' -f ($restartFirstApps -join ', '))
    }
    if ($restartRequired) {
        Write-WarningMessage ('Restart: REQUIRED to finish this run - restart this PC before it is used ({0}).' -f ($restartReasons -join '; '))
    }
    elseif ($restartPendingBefore.Count -gt 0 -and $restartFirstApps.Count -eq 0) {
        Write-WarningMessage ('Restart: already pending before this run ({0}) - restart this PC when you can.' -f ($restartPendingBefore -join '; '))
    }

    $notAttemptedSteps = @($notAttemptedApps)
    if ($wauResult.Status -eq 'NotAttempted') {
        $notAttemptedSteps += 'the Winget-AutoUpdate setup'
    }
    if ($notAttemptedSteps.Count -gt 0) {
        Write-WarningMessage ("Time budget: USED UP - the run's {0}-minute budget ran out at {1}, so these were not attempted: {2}. Run the installer again to finish." -f $runBudget.Minutes, (Format-RunRecordTime -Time $runBudget.DeadlineUtc), ($notAttemptedSteps -join ', '))
    }

    if ($script:InstallLogPath) {
        Write-Info "Full transcript of this run: $script:InstallLogPath"
    }

    $exitCode = Get-InstallerExitCode -FailedAppCount $failedApps.Count -WingetUsable $wingetUsableAtEnd -WorkNotAttempted ($notAttemptedSteps.Count -gt 0) -AutoUpdatesHealthy $autoUpdatesHealthy -RestartRequired $restartRequired
    $script:InstallerPendingExitCode = $exitCode

    if (-not $WhatIf -and @(1, 2, 8) -contains $exitCode) {
        Write-InstallerReportHint
    }

    if (-not $WhatIf) {
        try {
            $runRecord = New-InstallerRunRecord -ExitCode $exitCode -Apps @($appRecords.Values) -AutoUpdates (Get-AutoUpdateResultStatus -WauResult $wauResult) -AutoUpdatesVersion $wauResult.Version -RestartRequired $restartRequired -WingetUsable $wingetUsableForRecord -InstallEngine $installEngineRecord -SummaryReached
            [void](Write-InstallerRunResult -Record $runRecord)
        }
        catch {
            Write-WarningMessage "Could not report this run's result: $_"
        }
        $script:InstallerRunReportPending = $false
        Unlock-InstallerRun
    }

    if (-not $effectiveNonInteractive) {
        Write-Prompt 'Press any key to exit...'
        [void][System.Console]::ReadKey($true)
    }

    return $exitCode
}

# --- Logging ---
function Write-Info {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message
    )
    Write-Host $Message -ForegroundColor Blue
}

function Write-Success {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message
    )
    Write-Host $Message -ForegroundColor Green
}

function Write-WarningMessage {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message
    )
    Write-Host $Message -ForegroundColor Yellow
}

function Write-ErrorMessage {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message
    )
    Write-Host $Message -ForegroundColor Red
}

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

function Write-Table {
    param (
        [Parameter(Mandatory = $true)]
        [string[]]$Headers,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[][]]$Rows,
        [Parameter(Mandatory = $false)]
        [string]$Title = 'Summary'
    )

    $tableData = @()
    foreach ($row in $Rows) {
        $obj = New-Object PSObject
        for ($i = 0; $i -lt $Headers.Count; $i++) {
            $obj | Add-Member -MemberType NoteProperty -Name $Headers[$i] -Value $row[$i]
        }
        $tableData += $obj
    }

    $output = $tableData | Format-Table -AutoSize -Wrap | Out-String -Width 4096
    Write-Host $output.TrimEnd()
}

# --- SystemChecks ---
function Test-SystemRequirements {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    $results = @()
    $proceed = $true

    try {
        $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        $osName = $cv.ProductName
        $build = if ($cv.CurrentBuildNumber) { [int]$cv.CurrentBuildNumber } else { [System.Environment]::OSVersion.Version.Build }
        if ($build -ge 22000 -and $osName -match 'Windows 10') {
            $osName = $osName -replace 'Windows 10', 'Windows 11'
        }
        if ($build -ge 19044) {
            $results += [PSCustomObject]@{ Check = 'OS Version'; Status = 'OK'; Detail = $osName }
        }
        else {
            $results += [PSCustomObject]@{ Check = 'OS Version'; Status = 'WARN'; Detail = "$osName (build $build - Windows 10 21H2 or later recommended)" }
        }
    }
    catch {
        $results += [PSCustomObject]@{ Check = 'OS Version'; Status = 'WARN'; Detail = "Could not determine OS version: $_" }
    }

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
        $results += [PSCustomObject]@{ Check = 'Disk Space'; Status = 'UNKNOWN'; Detail = "Could not read C: drive: $_" }
    }

    try {
        $null = Invoke-WebRequest -Uri 'https://cdn.winget.microsoft.com/cache' -Method Head -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
        $results += [PSCustomObject]@{ Check = 'Network'; Status = 'OK'; Detail = 'HTTPS probe of cdn.winget.microsoft.com succeeded' }
    }
    catch {
        $response = $_.Exception.Response
        if ($null -ne $response) {
            $results += [PSCustomObject]@{ Check = 'Network'; Status = 'OK'; Detail = "cdn.winget.microsoft.com reachable (HTTP $([int]$response.StatusCode))" }
        }
        else {
            $results += [PSCustomObject]@{ Check = 'Network'; Status = 'FAIL'; Detail = "Cannot reach cdn.winget.microsoft.com over HTTPS - network is required: $($_.Exception.Message)" }
            $proceed = $false
            if (-not $WhatIf) {
                $proxyWarning = $null
                try {
                    $proxyWarning = Get-ProxyInheritanceWarning -AccountContext (Get-InstallAccountContext)
                }
                catch {
                    $proxyWarning = $null
                }
                if ($proxyWarning) {
                    $results += [PSCustomObject]@{ Check = 'Proxy'; Status = 'WARN'; Detail = $proxyWarning }
                }
            }
        }
    }

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

    if ($null -ne $freeGB -and $freeGB -lt 50 -and -not $WhatIf) {
        Write-WarningMessage 'Disk space is below the 50 GB recommendation. Continuing anyway.'
    }

    return $true
}

# --- Uninstall ---
function Invoke-WingetUninstall {
    [OutputType([int])]
    param (
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf,

        [Parameter(Mandatory = $false)]
        [array]$Apps = (Get-DefaultAppCatalog)
    )

    if ($WhatIf) {
        Write-Info '=== DRY-RUN MODE ENABLED ==='
        Write-Info 'Nothing will be uninstalled or changed. This is a preview of what a real run would do.'
        Write-Host ''
    }

    if (@($Apps).Count -eq 0) {
        Write-ErrorMessage 'The app list is empty, so there is nothing to uninstall.'
        return 3
    }
    $validationResult = Test-AppDefinitions -Apps $Apps
    foreach ($validationWarning in $validationResult.Warnings) {
        Write-WarningMessage $validationWarning
    }
    if ($validationResult.Errors.Count -gt 0) {
        foreach ($validationError in $validationResult.Errors) {
            Write-ErrorMessage $validationError
        }
        Write-ErrorMessage 'The app list has invalid entries, so nothing was uninstalled. Fix them and run the uninstaller again.'
        return 3
    }
    $apps = @($validationResult.ValidApps)

    $script:MachineWingetPath = $null
    $account = Get-InstallAccountContext
    $winget = Initialize-Winget -WhatIf:$WhatIf -AccountContext $account
    $wingetAvailable = [bool]$winget.Ready
    if (-not $wingetAvailable) {
        $policyBlocked = $winget.Diagnosis -eq 'PolicyBlocked'
        if ($WhatIf) {
            if ($policyBlocked) {
                Write-Info '[DRY-RUN] Group Policy on this PC blocks winget (see above). A real run would stop with exit code 2 before removing anything. Without winget this preview cannot tell which apps are installed, so it stops here.'
            }
            else {
                Write-Info '[DRY-RUN] winget cannot be started for this account yet. A real run would try to set it up (see above) and, if winget still could not start, stop with exit code 2 before removing anything. Without winget this preview cannot tell which apps are installed, so it stops here.'
            }
            return 0
        }
        if ($policyBlocked) {
            $message = 'Group Policy on this PC blocks winget (see above), so nothing was uninstalled: without winget the uninstaller cannot tell which apps are installed.'
        }
        else {
            $message = 'winget cannot be started for this account, so nothing was uninstalled: without winget the uninstaller cannot tell which apps are installed.'
        }
        if (Test-WauInstalled) {
            $message += ' Winget-AutoUpdate was left in place, so the apps keep getting updates.'
        }
        if ($policyBlocked) {
            $message += ' Run the uninstaller again once the policy allows winget.'
        }
        else {
            $message += ' Run the uninstaller from an account where winget works (for example the signed-in user, elevated), or install App Installer from https://aka.ms/getwinget, then run it again.'
        }
        Write-ErrorMessage $message
        return 2
    }

    Write-Info 'Uninstalling the following apps:'
    foreach ($app in $apps) {
        Write-Info $app.name
    }

    $uninstalledApps = @()
    $skippedApps = @()
    $failedApps = @()
    $restartRequiredApps = @()
    $terminalGone = $false
    foreach ($app in $apps) {
        try {
            $outcome = Uninstall-CatalogApp -App $app -WhatIf:$WhatIf
            if ($app.name -eq 'Microsoft.WindowsTerminal') {
                $terminalGone = ($outcome.Status -eq 'Uninstalled' -and -not $WhatIf) -or ($outcome.SkipReason -eq 'NotInstalled')
            }
            switch ($outcome.Status) {
                'Uninstalled' {
                    if ($WhatIf -and $outcome.Command) {
                        Write-Info "[DRY-RUN] Would uninstall: $($app.name) (its own uninstaller: $($outcome.Command))"
                    }
                    elseif ($WhatIf) {
                        Write-Info "[DRY-RUN] Would uninstall: $($app.name)"
                    }
                    elseif ($outcome.RestartRequired) {
                        Write-Success "Successfully uninstalled: $($app.name) (a restart finishes removing it)"
                        $restartRequiredApps += $app.name
                    }
                    else {
                        Write-Success "Successfully uninstalled: $($app.name)"
                    }
                    $uninstalledApps += $app.name
                }
                'Skipped' {
                    Write-WarningMessage "Skipping: $($app.name) ($($outcome.Reason))"
                    $skippedApps += $app.name
                }
                default {
                    Write-ErrorMessage "Failed to uninstall: $($app.name) ($($outcome.Reason))."
                    $failedApps += @{ Name = $app.name; Reason = [string]$outcome.Reason }
                }
            }
        }
        catch {
            Write-ErrorMessage "Failed to uninstall: $($app.name). Error: $_"
            $failedApps += @{ Name = $app.name; Reason = "Unexpected error: $_" }
        }
    }

    if ($terminalGone) {
        try {
            [void](Reset-WindowsTerminalDelegation -WhatIf:$WhatIf)
        }
        catch {
            Write-WarningMessage "Could not check the default terminal application setting: $_"
        }
    }

    $autoUpdatesKept = $false
    $autoUpdatesRemovalFailed = $false
    if ($failedApps.Count -gt 0) {
        $autoUpdatesKept = Test-WauInstalled
        if ($autoUpdatesKept) {
            $dryRunPrefix = ''
            if ($WhatIf) {
                $dryRunPrefix = '[DRY-RUN] '
            }
            Write-WarningMessage ('{0}Winget-AutoUpdate is kept: {1} app(s) could not be uninstalled, and it keeps them updated. Fix the failures above and run the uninstaller again to remove it.' -f $dryRunPrefix, $failedApps.Count)
        }
    }
    else {
        Write-Info 'Removing automatic-update components...'
        try {
            [void](Remove-LegacyScheduledUpdates -WhatIf:$WhatIf)
            $autoUpdateRemoval = Uninstall-WingetAutoUpdate -WhatIf:$WhatIf
            if (-not ($autoUpdateRemoval -and $autoUpdateRemoval.Succeeded)) {
                $autoUpdatesRemovalFailed = $true
            }
            elseif ($autoUpdateRemoval.RestartRequired) {
                $restartRequiredApps += 'Winget-AutoUpdate'
            }
        }
        catch {
            Write-ErrorMessage "Removing automatic updates failed unexpectedly: $_"
            $autoUpdatesRemovalFailed = $true
        }
    }

    if ($WhatIf) {
        Write-Host ''
        Write-Info '=== DRY-RUN SUMMARY ==='
        Write-Info 'A real run would do the following:'
    }
    else {
        Write-Info 'Summary:'
    }

    $headers = @('Status', 'Apps')
    $rows = @()
    $appList = Format-AppList -AppArray $uninstalledApps
    if ($appList) {
        $rows += , @('Uninstalled', $appList)
    }
    $appList = Format-AppList -AppArray $skippedApps
    if ($appList) {
        $rows += , @('Skipped', $appList)
    }
    $appList = Format-AppList -AppArray @($failedApps | ForEach-Object { $_.Name })
    if ($appList) {
        $rows += , @('Failed', $appList)
    }
    Write-Table -Headers $headers -Rows $rows -Title 'Uninstallation Summary'
    Write-FailedAppsSummary -FailedApps $failedApps -Title 'Failed Uninstalls'

    if ($autoUpdatesKept) {
        Write-WarningMessage 'Auto-updates: KEPT - Winget-AutoUpdate stays until every app is removed (see above).'
    }
    elseif ($autoUpdatesRemovalFailed) {
        Write-ErrorMessage 'Auto-updates: FAILED - Winget-AutoUpdate could not be removed (see above). Run the uninstaller again.'
    }
    if ($restartRequiredApps.Count -gt 0) {
        Write-WarningMessage ('Restart: REQUIRED to finish removing {0}.' -f ($restartRequiredApps -join ', '))
    }

    if ($failedApps.Count -gt 0 -or $autoUpdatesRemovalFailed) {
        return 1
    }
    if ($restartRequiredApps.Count -gt 0) {
        return 3010
    }
    return 0
}

# --- UserPhase ---
function Invoke-WingetUserPhase {
    [OutputType([int])]
    param (
        [Parameter(Mandatory = $false)]
        [string]$RunRecordPath = (Get-InstallerRunRecordPath),

        [Parameter(Mandatory = $false)]
        [string]$StatePath = (Get-UserPhaseStatePath),

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 240)]
        [int]$MaxMinutes = 15,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 100)]
        [int]$MaxAttempts = 3
    )

    if (Test-IsSystemAccount) {
        Write-Info 'The user phase installs for the signed-in user, so it has nothing to do as SYSTEM: run it as the user (for example as an Endpoint Central User Configuration script).'
        return 0
    }

    $record = Read-InstallerRunRecord -Path $RunRecordPath
    $state = Read-UserPhaseState -Path $StatePath
    $decision = Get-UserPhaseDecision -Record $record -State $state -MaxAttempts $MaxAttempts
    if (-not $decision.Run) {
        return 0
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $budgetSeconds = $MaxMinutes * 60
    $appRecords = [ordered]@{}
    $terminalStatus = 'NotRun'
    $exitCode = 5
    $newState = [ordered]@{
        schemaVersion        = 1
        recordSha256         = $record.Sha256
        machineRunStartedUtc = $record.StartedUtc
        machineRunBuildId    = $record.BuildId
        attempts             = $decision.Attempt
        complete             = $false
        exitCode             = $null
        updatedUtc           = Format-RunRecordTime -Time ([DateTime]::UtcNow)
        apps                 = @()
        terminalDefaults     = $terminalStatus
        transcriptPath       = $null
    }
    [void](Save-UserPhaseState -Path $StatePath -State $newState)

    $previousLogPath = $script:InstallLogPath
    $script:InstallLogPath = Start-InstallerTranscript -UserPhase
    $transcriptStarted = [bool]$script:InstallLogPath
    try {
        if ($script:InstallLogPath) {
            Write-Info "Logging the user phase to: $script:InstallLogPath"
            try {
                [void](Remove-OldInstallerLog -LogDirectory (Split-Path -Parent $script:InstallLogPath) -KeepTranscripts 10 -CurrentTranscriptPath $script:InstallLogPath)
            }
            catch {
                Write-WarningMessage "Could not remove old user-phase logs: $($_.Exception.Message)"
            }
        }
        if ($script:InstallerBuildId) {
            Write-Info "Installer build: $script:InstallerBuildId"
        }
        $buildText = 'unknown build'
        if ($record.BuildId) {
            $buildText = "build $($record.BuildId)"
        }
        Write-Info ('User phase for {0}, attempt {1} of {2}: following up the run for the whole PC that started {3} ({4}, exit code {5}).' -f (Get-ProcessUserName), $decision.Attempt, $MaxAttempts, $record.StartedUtc, $buildText, $record.ExitCode)
        foreach ($invalidId in $record.InvalidDeferredIds) {
            Write-WarningMessage "Ignoring a deferred entry in $($record.Path) that is not a winget package id: '$invalidId'."
        }

        $deferredApps = @($record.DeferredApps)
        $wingetUsable = $true
        if ($deferredApps.Count -eq 0) {
            Write-Info 'The run for the whole PC deferred no apps to this account.'
        }
        else {
            Write-Info ('Apps the run for the whole PC left for each account (installed per-user, with --scope user): {0}' -f ($deferredApps -join ', '))
            $probe = Test-WingetLaunchable -Attempts 4 -RetryDelaySeconds 15
            if (-not $probe.Launchable) {
                $wingetUsable = $false
                $reason = "winget could not be started for this account: $($probe.Reason)"
                Write-ErrorMessage "$reason. Windows sets winget up for an account shortly after its first sign-in; the user phase tries again at the next sign-in."
                foreach ($id in $deferredApps) {
                    $appRecords[$id] = New-AppRunRecord -Id $id -Status 'NotAttempted' -Reason $reason
                }
            }
            else {
                Update-UserPhaseWingetSource
                $catalogEntries = Get-UserPhaseCatalogEntry
                foreach ($id in $deferredApps) {
                    $remainingSeconds = $budgetSeconds - (Get-UserPhaseElapsedSeconds -Stopwatch $stopwatch)
                    if ($remainingSeconds -lt 60) {
                        Write-WarningMessage "Not installing $id now: the user phase's $MaxMinutes-minute time budget is spent. The next sign-in tries again."
                        $appRecords[$id] = New-AppRunRecord -Id $id -Status 'NotAttempted' -Reason "the user phase's $MaxMinutes-minute time budget was spent"
                        continue
                    }
                    try {
                        $appRecords[$id] = Install-UserPhaseApp -PackageId $id -App $catalogEntries[$id] -TimeoutSeconds ([Math]::Min(1800, $remainingSeconds))
                    }
                    catch {
                        Write-ErrorMessage "Failed to install: $id. Error: $_"
                        $appRecords[$id] = New-AppRunRecord -Id $id -Status 'Failed' -Reason "Unexpected error: $_"
                    }
                }
            }
        }

        try {
            $terminalStatus = [string](@(Set-WindowsTerminalDefaults -PassThru)[-1])
            if (@('Applied', 'SettingsNotFound', 'Failed', 'Skipped') -notcontains $terminalStatus) {
                $terminalStatus = 'Failed'
            }
            switch ($terminalStatus) {
                'SettingsNotFound' { Write-Info 'Windows Terminal has no settings.json for this account yet (it creates one when it is first opened); the next sign-in sets its default profile.' }
                'Failed' { Write-WarningMessage 'The Windows Terminal defaults could not all be set (see above); the next sign-in tries again.' }
                'Skipped' { Write-WarningMessage 'The Windows Terminal defaults were not set for this account (see above); the next sign-in tries again.' }
            }
        }
        catch {
            $terminalStatus = 'Failed'
            Write-WarningMessage "Windows Terminal configuration failed unexpectedly: $_"
        }

        $records = @($appRecords.Values)
        $unfinished = @($records | Where-Object { @('Installed', 'Skipped') -notcontains $_.status })
        $restartApps = @($records | Where-Object { $_.restartRequired } | ForEach-Object { $_.id })
        if (-not $wingetUsable) {
            $exitCode = 2
        }
        elseif ($unfinished.Count -gt 0) {
            $exitCode = 1
        }
        elseif ($restartApps.Count -gt 0) {
            $exitCode = 3010
            Write-WarningMessage ('Restart: REQUIRED to finish installing {0}.' -f ($restartApps -join ', '))
        }
        else {
            $exitCode = 0
        }
        $notConfigured = @($records | Where-Object { $_.postInstall -eq 'NotConfigured' })
        if ($notConfigured.Count -gt 0) {
            Write-WarningMessage ('Configuration: NOT DONE for {0} - installed for this account, but the post-install configuration did not finish. Not counted as failed; the next sign-in tries again.' -f (@($notConfigured | ForEach-Object { '{0} ({1})' -f $_.id, $_.postInstallReason }) -join '; '))
        }
        $newState.complete = ($unfinished.Count -eq 0) -and ($notConfigured.Count -eq 0) -and ($terminalStatus -eq 'Applied')
        if (-not $newState.complete -and $decision.Attempt -ge $MaxAttempts) {
            Write-WarningMessage "This was the last of $MaxAttempts attempts for this run for the whole PC; the user phase does not try again until the next one."
        }
    }
    catch {
        Write-ErrorMessage "UNEXPECTED ERROR - the user phase stopped before it finished: $($_.Exception.Message)"
        if ($_.ScriptStackTrace) {
            Write-ErrorMessage "Stack trace:`n$($_.ScriptStackTrace)"
        }
        $exitCode = 5
    }
    finally {
        $records = @($appRecords.Values)
        $newState.exitCode = $exitCode
        $newState.updatedUtc = Format-RunRecordTime -Time ([DateTime]::UtcNow)
        $newState.apps = $records
        $newState.terminalDefaults = $terminalStatus
        $newState.transcriptPath = $script:InstallLogPath
        [void](Save-UserPhaseState -Path $StatePath -State $newState)
        $log = 'none'
        if ($script:InstallLogPath) {
            $log = $script:InstallLogPath
        }
        Write-Host ('USER PHASE RESULT: exit={0} installed={1} skipped={2} failed={3} terminal={4} attempt={5}/{6} complete={7} log={8}' -f $exitCode, @($records | Where-Object { $_.status -eq 'Installed' }).Count, @($records | Where-Object { $_.status -eq 'Skipped' }).Count, @($records | Where-Object { @('Installed', 'Skipped') -notcontains $_.status }).Count, $terminalStatus, $decision.Attempt, $MaxAttempts, ([string]$newState.complete).ToLowerInvariant(), $log)
        if ($transcriptStarted) {
            try {
                [void](Stop-Transcript)
            }
            catch {
            }
        }
        $script:InstallLogPath = $previousLogPath
    }
    return $exitCode
}

# --- WindowsTerminal ---
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

function Set-WindowsTerminalDefaultProfile {
    param (
        [Parameter(Mandatory = $true)]
        [string]$SettingsPath,

        [Parameter(Mandatory = $true)]
        [string]$ProfileGuid
    )

    if (-not (Test-Path -LiteralPath $SettingsPath -PathType Leaf)) {
        Write-WarningMessage "Windows Terminal settings file not found at '$SettingsPath'."
        return $false
    }

    $normalizedGuid = if ($ProfileGuid.StartsWith('{') -and $ProfileGuid.EndsWith('}')) {
        $ProfileGuid
    }
    else {
        "{$ProfileGuid}"
    }

    $fullPath = Convert-Path -LiteralPath $SettingsPath

    try {
        $originalBytes = [System.IO.File]::ReadAllBytes($fullPath)
        $hasBom = $originalBytes.Length -ge 3 -and $originalBytes[0] -eq 0xEF -and $originalBytes[1] -eq 0xBB -and $originalBytes[2] -eq 0xBF
        $encoding = [System.Text.UTF8Encoding]::new($hasBom, $true)
        $bomLength = if ($hasBom) { 3 } else { 0 }
        $settingsContent = $encoding.GetString($originalBytes, $bomLength, $originalBytes.Length - $bomLength)
    }
    catch {
        Write-WarningMessage "Unable to read Windows Terminal settings '$fullPath' as UTF-8: $_"
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

    $updatedContent = Set-JsoncTopLevelStringProperty -JsonText $settingsContent -Name 'defaultProfile' -Value $normalizedGuid
    $updatedObject = if ($null -ne $updatedContent) { ConvertFrom-TerminalSettingsJson -JsonText $updatedContent }
    $isValidEdit = [bool]$updatedObject -and $updatedObject.defaultProfile -eq $normalizedGuid
    if ($isValidEdit) {
        $otherSettingsBefore = $settingsObject | Select-Object -Property * -ExcludeProperty 'defaultProfile' | ConvertTo-Json -Depth 100 -Compress
        $otherSettingsAfter = $updatedObject | Select-Object -Property * -ExcludeProperty 'defaultProfile' | ConvertTo-Json -Depth 100 -Compress
        $isValidEdit = $otherSettingsAfter -ceq $otherSettingsBefore
    }
    if (-not $isValidEdit) {
        Write-WarningMessage "Could not change only defaultProfile in '$fullPath'; the file was left unchanged."
        return $false
    }

    $backupPath = "$fullPath.winget-app-setup.bak"
    $tempPath = "$fullPath.winget-app-setup.tmp"
    try {
        Copy-Item -LiteralPath $fullPath -Destination $backupPath -Force -ErrorAction Stop
        $settingsItem = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
        $isLinked = [bool]$settingsItem.LinkType -or
            (($settingsItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
        if ($isLinked) {
            [System.IO.File]::WriteAllText($fullPath, $updatedContent, $encoding)
        }
        else {
            [System.IO.File]::WriteAllText($tempPath, $updatedContent, $encoding)
            [System.IO.File]::Replace($tempPath, $fullPath, [NullString]::Value)
        }
    }
    catch {
        if (-not (Test-Path -LiteralPath $fullPath) -and (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
            Copy-Item -LiteralPath $backupPath -Destination $fullPath -ErrorAction SilentlyContinue
        }
        Write-WarningMessage "Failed to update Windows Terminal settings.json: $_"
        return $false
    }
    finally {
        if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Success "Configured Windows Terminal default profile to PowerShell 7 (previous file saved as '$backupPath')."
    return $true
}

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

function Set-WindowsTerminalDefaults {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf,

        [Parameter(Mandatory = $false)]
        [switch]$PassThru
    )

    if (Test-IsSystemAccount) {
        Write-Info 'Skipping Windows Terminal defaults: they are per-user settings, and this run is SYSTEM, not a logged-on user.'
        if ($PassThru) {
            return 'Skipped'
        }
        return
    }
    $processUser = Get-ProcessUserName
    $sessionUser = Get-InteractiveSessionUserName
    if ($processUser -and $sessionUser -and ($processUser -ne $sessionUser)) {
        Write-Info "Skipping Windows Terminal defaults: they are per-user settings, and this run is elevated as '$processUser' while '$sessionUser' is logged on."
        if ($PassThru) {
            return 'Skipped'
        }
        return
    }

    $powerShell7ProfileGuid = '{574e775e-4f2a-5b96-ac1e-a2962a402336}'
    $settingsPaths = @(Get-WindowsTerminalSettingsPaths)

    if ($WhatIf) {
        if ($settingsPaths.Count -gt 0) {
            Write-Info "[DRY-RUN] Would set defaultProfile to $powerShell7ProfileGuid in $($settingsPaths.Count) Windows Terminal settings file(s)"
        }
        else {
            Write-Info '[DRY-RUN] Would set Windows Terminal defaultProfile to PowerShell 7 when settings.json is available'
        }
        if (Test-WindowsTerminalInstalled) {
            Write-Info '[DRY-RUN] Would set HKCU:\Console\%%Startup DelegationConsole and DelegationTerminal to Windows Terminal values'
        }
        else {
            Write-Info '[DRY-RUN] Windows Terminal is not installed; would skip default terminal application configuration'
        }
        if ($PassThru) {
            return 'WhatIf'
        }
        return
    }

    $status = 'Applied'
    if ($settingsPaths.Count -gt 0) {
        foreach ($settingsPath in $settingsPaths) {
            if (-not (Set-WindowsTerminalDefaultProfile -SettingsPath $settingsPath -ProfileGuid $powerShell7ProfileGuid)) {
                $status = 'Failed'
            }
        }
    }
    else {
        Write-WarningMessage 'Windows Terminal settings.json was not found. Skipping default profile configuration.'
        $status = 'SettingsNotFound'
    }

    if (Test-WindowsTerminalInstalled) {
        if (-not (Set-WindowsTerminalAsDefaultTerminalApplication)) {
            $status = 'Failed'
        }
    }
    else {
        Write-WarningMessage 'Windows Terminal is not installed. Skipping default terminal application configuration.'
    }
    if ($PassThru) {
        return $status
    }
}

# --- WingetAutoUpdate ---
function Get-WauPin {
    return @{
        Version     = '2.12.0'
        MsiUrl      = 'https://github.com/Romanitho/Winget-AutoUpdate/releases/download/v2.12.0/WAU.msi'
        Sha256      = 'F5AB2303FDF82FBFCB2248CCA4F96479FE17D74584A528B0F86B3DBE9F9E9718'
        ProductCode = '{FB0EB14E-95AC-45D7-A951-432316FFCBD4}'
    }
}

function Test-WauInstalled {
    if (Test-Path 'HKLM:\SOFTWARE\Romanitho\Winget-AutoUpdate') {
        return $true
    }
    try {
        if (Get-ScheduledTask -TaskName 'Winget-AutoUpdate' -TaskPath '\WAU\' -ErrorAction SilentlyContinue) {
            return $true
        }
    }
    catch {
    }
    return $false
}

function Install-WingetAutoUpdate {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf,

        [Parameter(Mandatory = $false)]
        [int]$InstallInProgressWaitSeconds = 600
    )

    $pin = Get-WauPin

    if ($WhatIf) {
        $runtimePin = Get-WindowsAppRuntimePin
        $runtimePreview = "If Microsoft.WindowsAppRuntime.1.8 is missing, would first install the pinned Windows App Runtime $($runtimePin.Release) (framework $($runtimePin.FrameworkVersion)) for all users from NuGet.org."
        if (Test-WauInstalled) {
            Write-Info "[DRY-RUN] Winget-AutoUpdate is already installed: would leave it in place and remove its at-logon trigger if it has one (WAU_UpdatesAtLogon = 0). $runtimePreview"
        }
        else {
            Write-Info "[DRY-RUN] Would install Winget-AutoUpdate $($pin.Version) (weekly updates on Tuesdays at 02:00, not at logon, Full notifications, self-update disabled). $runtimePreview"
        }
        return [pscustomobject]@{ Status = 'DryRun'; Version = $pin.Version; FrameworkMissing = $false; RestartRequired = $false }
    }

    $requirement = Get-WindowsAppRuntimeRequirement
    $frameworkName = (@($requirement.Frameworks) | ForEach-Object { $_.Name }) -join ' and '
    $frameworkRelease = $frameworkName -replace 'Microsoft\.WindowsAppRuntime\.', ''
    $framework = Get-WindowsAppRuntimeStatus -Requirement $requirement
    $frameworkInstallError = $null
    if ($null -eq $framework.Present) {
        Write-WarningMessage "Could not check for $frameworkName ($($framework.Detail)); continuing with Winget-AutoUpdate."
    }
    elseif (-not $framework.Present) {
        $missingFrameworks = @($requirement.Frameworks)
        if ($framework.Missing) {
            $missingFrameworks = @($framework.Missing)
        }
        $frameworkInstall = Install-WindowsAppRuntimeFramework -Requirement $requirement -MissingFrameworks $missingFrameworks
        if ($frameworkInstall.Installed) {
            $framework = $frameworkInstall.Status
        }
        else {
            $frameworkInstallError = $frameworkInstall.Reason
        }
    }
    $frameworkMissing = $framework.Present -eq $false
    if ($frameworkMissing -and $framework.Missing) {
        $frameworkName = (@($framework.Missing) | ForEach-Object { $_.Name }) -join ' and '
        $frameworkRelease = $frameworkName -replace 'Microsoft\.WindowsAppRuntime\.', ''
    }
    $frameworkInstallNote = ''
    if ($frameworkInstallError) {
        $frameworkInstallNote = " The installer could not install it (see 'Windows App Runtime: NOT INSTALLED' above)."
    }

    if (Test-WauInstalled) {
        $installed = Get-InstalledWauInfo
        if ($installed.Version -and $installed.Version -lt [version]$pin.Version -and -not $frameworkMissing) {
            Write-Info "Winget-AutoUpdate v$($installed.Version) is older than the pinned v$($pin.Version); upgrading in place..."
        }
        else {
            $versionLabel = if ($installed.Version) { "v$($installed.Version)" } else { 'version unknown' }
            Write-Success "Winget-AutoUpdate is already installed ($versionLabel); leaving its configuration unchanged apart from the at-logon trigger."
            [void](Disable-WauLogonTrigger)
            if ($frameworkMissing) {
                Write-ErrorMessage "Winget-AutoUpdate is installed, but $frameworkName is missing ($($framework.Detail)).$frameworkInstallNote Its next update run may install a winget that cannot start and leave winget unusable. Install the Windows App Runtime $frameworkRelease (update App Installer from the Microsoft Store, or install Microsoft's Windows App SDK $frameworkRelease runtime), or uninstall Winget-AutoUpdate on this machine."
            }
            $health = Get-WauTaskHealth
            Write-WauTaskHealth -Health $health
            if (-not $health.Healthy) {
                if ($health.CheckFailed) {
                    Write-ErrorMessage "Winget-AutoUpdate is installed, but $($health.Problem), so it is not known whether apps will update automatically. Check the task \WAU\Winget-AutoUpdate in Task Scheduler; if it is missing, disabled or has no enabled trigger, uninstall Winget-AutoUpdate (Settings > Apps) and re-run this installer."
                }
                else {
                    Write-ErrorMessage "Winget-AutoUpdate is installed, but $($health.Problem), so apps will not update automatically. To set it up again, uninstall Winget-AutoUpdate (Settings > Apps) and re-run this installer."
                }
                return [pscustomobject]@{ Status = 'Unhealthy'; Version = $installed.Version; FrameworkMissing = $frameworkMissing; FrameworkInstallError = $frameworkInstallError; FrameworkName = $frameworkName; RestartRequired = $false; Problem = $health.Problem; CheckFailed = [bool]$health.CheckFailed }
            }
            return [pscustomobject]@{ Status = 'AlreadyPresent'; Version = $installed.Version; FrameworkMissing = $frameworkMissing; FrameworkInstallError = $frameworkInstallError; FrameworkName = $frameworkName; RestartRequired = $false }
        }
    }
    elseif (-not $frameworkMissing) {
        Write-Info "Setting up automatic app updates via Winget-AutoUpdate $($pin.Version)..."
    }

    if ($frameworkMissing) {
        Write-ErrorMessage "Winget-AutoUpdate was NOT installed: $frameworkName is missing ($($framework.Detail)).$frameworkInstallNote Every WAU update run installs the newest winget, which needs that framework, so WAU would leave winget unusable here. Install the Windows App Runtime $frameworkRelease (update App Installer from the Microsoft Store, or install Microsoft's Windows App SDK $frameworkRelease runtime), then re-run this installer."
        return [pscustomobject]@{ Status = 'FrameworkMissing'; Version = $pin.Version; FrameworkMissing = $true; FrameworkInstallError = $frameworkInstallError; FrameworkName = $frameworkName; RestartRequired = $false }
    }

    $stagingDir = $null
    $msiStream = $null
    try {
        try {
            $stagingDir = New-WauStagingDirectory
        }
        catch {
            $baseDir = Join-Path $env:ProgramData 'winget-app-setup'
            if ($_.FullyQualifiedErrorId -eq 'RestrictedDirectoryAclFailed') {
                Write-ErrorMessage "Winget-AutoUpdate was NOT installed: its download folder could not be limited to SYSTEM and Administrators, so its installer could have been swapped before it ran. $_$(Get-RestrictedDirectoryResetHint -Path $baseDir)"
            }
            else {
                Write-ErrorMessage "Winget-AutoUpdate was NOT installed: its download folder in '$baseDir' could not be set up: $_"
            }
            return [pscustomobject]@{ Status = 'Failed'; Version = $pin.Version; FrameworkMissing = $false; RestartRequired = $false }
        }
        $msiPath = Join-Path $stagingDir "WAU-$($pin.Version).msi"
        $downloadTimeouts = Get-WebDownloadTimeoutParameters
        Invoke-WebRequest @downloadTimeouts -Uri $pin.MsiUrl -OutFile $msiPath -UseBasicParsing -ErrorAction Stop

        $msiStream = Open-ReadLockedFile -Path $msiPath
        $actualHash = (Get-FileHash -InputStream $msiStream -Algorithm SHA256).Hash
        if ($actualHash -ne $pin.Sha256) {
            Write-ErrorMessage "Winget-AutoUpdate MSI hash mismatch (expected $($pin.Sha256), got $actualHash). Skipping installation."
            return [pscustomobject]@{ Status = 'Failed'; Version = $pin.Version; FrameworkMissing = $false; RestartRequired = $false }
        }

        $msiArgs = "/i `"$msiPath`" /qn /norestart UPDATESATLOGON=0 USERCONTEXT=1 DISABLEWAUAUTOUPDATE=1 UPDATESINTERVAL=Weekly UPDATESATTIME=02:00:00 NOTIFICATIONLEVEL=Full DONOTRUNONMETERED=1"
        $msiexec = Invoke-WauMsiexec -ArgumentString $msiArgs -Action install -InstallInProgressWaitSeconds $InstallInProgressWaitSeconds
        if ($msiexec.LaunchFailed) {
            Write-ErrorMessage "Failed to install Winget-AutoUpdate: msiexec could not be started ($($msiexec.LaunchError))."
            return [pscustomobject]@{ Status = 'Failed'; Version = $pin.Version; FrameworkMissing = $false; RestartRequired = $false }
        }
        $msiLogNote = ''
        if ($msiexec.LogPath) {
            $msiLogNote = " msiexec log: $($msiexec.LogPath)"
        }
        if ($msiexec.TimedOut) {
            Write-ErrorMessage (('Winget-AutoUpdate install failed: msiexec did not finish within {0} minutes and was stopped.' -f [Math]::Round((Get-ProcessTimeoutSeconds -Operation MsiExec) / 60)) + $msiLogNote)
            return [pscustomobject]@{ Status = 'Failed'; Version = $pin.Version; FrameworkMissing = $false; RestartRequired = $false }
        }

        if ($msiexec.ExitCode -eq 0 -or $msiexec.ExitCode -eq 3010) {
            $restartRequired = $msiexec.ExitCode -eq 3010
            $health = Get-WauTaskHealth
            if ($health.Healthy) {
                Write-Success "Winget-AutoUpdate $($pin.Version) installed. Apps will update weekly, on Tuesdays at 02:00 (or soon after the next start if the machine was off)."
            }
            elseif ($health.CheckFailed) {
                Write-ErrorMessage ("Winget-AutoUpdate $($pin.Version) was installed, but $($health.Problem), so it is not known whether apps will update automatically. Check the task \WAU\Winget-AutoUpdate in Task Scheduler; if it is missing, disabled or has no enabled trigger, uninstall Winget-AutoUpdate (Settings > Apps) and re-run this installer." + $msiLogNote)
            }
            else {
                Write-ErrorMessage ("Winget-AutoUpdate $($pin.Version) was installed, but $($health.Problem), so apps will not update automatically. Uninstall Winget-AutoUpdate (Settings > Apps) and re-run this installer; if this happens again, attach the msiexec log and this transcript to a GitHub issue." + $msiLogNote)
            }
            Write-WauTaskHealth -Health $health
            if ($restartRequired) {
                Write-WarningMessage 'The Winget-AutoUpdate installer reported that a restart finishes the installation (msiexec exit code 3010).'
            }
            if (-not $health.Healthy) {
                return [pscustomobject]@{ Status = 'Unhealthy'; Version = $pin.Version; FrameworkMissing = $false; RestartRequired = $restartRequired; Problem = $health.Problem; CheckFailed = [bool]$health.CheckFailed }
            }
            return [pscustomobject]@{ Status = 'Configured'; Version = $pin.Version; FrameworkMissing = $false; RestartRequired = $restartRequired }
        }

        if ($msiexec.ExitCode -eq 1618) {
            Write-ErrorMessage (('Winget-AutoUpdate install failed: Windows Installer was still busy with another installation after {0} retries and {1} seconds of waiting (msiexec exit code 1618). Re-run the installer once that installation has finished.' -f $msiexec.BusyRetries, $msiexec.BusyWaitedSeconds) + $msiLogNote)
            return [pscustomobject]@{ Status = 'Failed'; Version = $pin.Version; FrameworkMissing = $false; RestartRequired = $false }
        }

        Write-ErrorMessage ("Winget-AutoUpdate install failed (msiexec exit code $($msiexec.ExitCode))." + $msiLogNote)
        return [pscustomobject]@{ Status = 'Failed'; Version = $pin.Version; FrameworkMissing = $false; RestartRequired = $false }
    }
    catch {
        Write-ErrorMessage "Failed to install Winget-AutoUpdate: $_"
        return [pscustomobject]@{ Status = 'Failed'; Version = $pin.Version; FrameworkMissing = $false; RestartRequired = $false }
    }
    finally {
        if ($msiStream) {
            $msiStream.Dispose()
        }
        if ($stagingDir) {
            Remove-Item -Path $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Uninstall-WingetAutoUpdate {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf,

        [Parameter(Mandatory = $false)]
        [int]$InstallInProgressWaitSeconds = 600
    )

    $result = @{ Succeeded = $false; RestartRequired = $false }
    if (-not (Test-WauInstalled)) {
        Write-WarningMessage 'Winget-AutoUpdate is not installed; nothing to remove.'
        $result.Succeeded = $true
        return $result
    }

    if ($WhatIf) {
        Write-Info '[DRY-RUN] Would uninstall Winget-AutoUpdate.'
        $result.Succeeded = $true
        return $result
    }

    $productCode = (Get-InstalledWauInfo).ProductCode
    if (-not $productCode) {
        $productCode = (Get-WauPin).ProductCode
    }
    Write-Info 'Uninstalling Winget-AutoUpdate...'
    $msiexec = Invoke-WauMsiexec -ArgumentString "/x $productCode /qn /norestart" -Action uninstall -InstallInProgressWaitSeconds $InstallInProgressWaitSeconds
    if ($msiexec.LaunchFailed) {
        Write-ErrorMessage "Winget-AutoUpdate uninstall failed: msiexec could not be started ($($msiexec.LaunchError))."
        return $result
    }
    $msiLogNote = ''
    if ($msiexec.LogPath) {
        $msiLogNote = " msiexec log: $($msiexec.LogPath)"
    }
    if ($msiexec.TimedOut) {
        Write-ErrorMessage ('Winget-AutoUpdate uninstall failed: msiexec did not finish in time and was stopped.' + $msiLogNote)
        return $result
    }

    if ($msiexec.ExitCode -eq 0) {
        Write-Success 'Winget-AutoUpdate uninstalled.'
        $result.Succeeded = $true
        return $result
    }
    if ($msiexec.ExitCode -eq 3010) {
        Write-Success 'Winget-AutoUpdate uninstalled (a restart finishes removing it: msiexec exit code 3010).'
        $result.Succeeded = $true
        $result.RestartRequired = $true
        return $result
    }

    if ($msiexec.ExitCode -eq 1618) {
        Write-ErrorMessage (('Winget-AutoUpdate uninstall failed: Windows Installer was still busy with another installation after {0} retries and {1} seconds of waiting (msiexec exit code 1618). Run the uninstaller again once that installation has finished.' -f $msiexec.BusyRetries, $msiexec.BusyWaitedSeconds) + $msiLogNote)
        return $result
    }

    Write-ErrorMessage ("Winget-AutoUpdate uninstall failed (msiexec exit code $($msiexec.ExitCode))." + $msiLogNote)
    return $result
}

function Remove-LegacyScheduledUpdates {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    $taskName = 'WingetAppSetup-ScheduledUpdates'
    $taskPath = '\winget-app-setup\'
    $appDataDir = Join-Path $env:APPDATA 'winget-app-setup'
    $removed = $false

    $task = $null
    try {
        $task = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue
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
function Initialize-Winget {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$AccountContext,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Cli', 'WinGetClient')]
        [string]$SystemInstallEngine = 'Cli'
    )

    if ($null -eq $AccountContext) {
        $AccountContext = Get-InstallAccountContext
    }
    $isSystem = [bool]$AccountContext.IsSystem
    $account = 'SYSTEM'
    $who = 'SYSTEM'
    if (-not $isSystem) {
        $account = "$($AccountContext.ProcessUser)"
        $who = "'$account'"
    }
    $policyExitCode = -1978335174
    $sessionBlockedExitCode = -2147009255
    $agreementsExitCode = -1978335162
    $state = @{ ErrorCodes = @() }

    $policyBlocked = {
        param ([string]$Detail)
        Write-WingetPolicyBlockMessage -Detail $Detail -WhatIf:$WhatIf
        [pscustomobject]@{ Ready = $false; Diagnosis = 'PolicyBlocked' }
    }

    $policy = Get-WingetPolicyBlock
    if ($policy) {
        Write-WingetPolicyBlockMessage -Block $policy -WhatIf:$WhatIf
        return [pscustomobject]@{ Ready = $false; Diagnosis = 'PolicyBlocked' }
    }

    if ($AccountContext.IsCrossUserElevation) {
        Write-WarningMessage "Cross-user elevation detected: running as '$account' while '$($AccountContext.SessionUser)' owns the interactive session."
        Write-WarningMessage "winget is set up per account; setting it up for '$account'."
    }

    if ($isSystem -and $SystemInstallEngine -eq 'WinGetClient' -and -not $WhatIf) {
        $engine = Initialize-WingetClientEngine
        $machineWingetOk = Test-MachineWingetAvailable -NotRequired:([bool]$engine.Ready)
        if ($engine.Ready) {
            if (-not $machineWingetOk) {
                Write-WarningMessage 'No machine-wide winget.exe starts on this PC. This run installs with Microsoft.WinGet.Client, but Winget-AutoUpdate runs winget.exe, so automatic updates will not work until App Installer is repaired; the end-of-run check reports it.'
            }
            Write-InstallEngineLine
            return [pscustomobject]@{ Ready = $true; Diagnosis = 'Ok' }
        }
        if (-not $machineWingetOk) {
            return [pscustomobject]@{ Ready = $false; Diagnosis = 'NotLaunchable' }
        }
        Write-InstallEngineLine
    }
    elseif ($isSystem) {
        if ($SystemInstallEngine -eq 'WinGetClient') {
            $modulePin = Get-WingetClientModulePin
            Write-Info "[DRY-RUN] A real run would install the apps with Microsoft.WinGet.Client $($modulePin.Version) (pinned), downloading it from the PowerShell Gallery unless it is cached, and would use winget.exe if it is not ready."
        }
        if (-not (Test-MachineWingetAvailable -WhatIf:$WhatIf)) {
            return [pscustomobject]@{ Ready = $false; Diagnosis = 'NotLaunchable' }
        }
        if ($SystemInstallEngine -ne 'WinGetClient') {
            Write-InstallEngineLine
        }
    }
    else {
        $probe = Test-WingetLaunchable -Attempts 6 -RetryDelaySeconds 15
        if (-not $probe.Launchable -and -not $WhatIf) {
            Write-WarningMessage "Winget is not available: $($probe.Reason)."
            while (-not $probe.Launchable -and $probe.ExitCode -ne $policyExitCode -and (Invoke-NextWingetAccountFix -State $state)) {
                $probe = Test-WingetLaunchable -Attempts 2 -RetryDelaySeconds 5
            }
        }
        if ($probe.ExitCode -eq $policyExitCode) {
            return (& $policyBlocked ("'winget --version' answered {0}" -f (Format-WingetExitCode -ExitCode $probe.ExitCode)))
        }
        if (-not $probe.Launchable) {
            if ($WhatIf) {
                Write-Info "[DRY-RUN] Winget is not available for this account ($($probe.Reason)). A real run would set it up: register the App Installer package already on this PC for this account, then run Repair-WinGetPackageManager (installing its Microsoft.WinGet.Client module from the PowerShell Gallery first if it is missing), and stop with exit code 2 if winget still cannot be started."
                return [pscustomobject]@{ Ready = $false; Diagnosis = 'NotLaunchable' }
            }
            $seen = ''
            $codes = @($state.ErrorCodes | Select-Object -Unique)
            if ($codes.Count -gt 0) {
                $seen = ' App Installer could not be registered or repaired ({0}).' -f (@($codes | ForEach-Object { Format-WingetExitCode -ExitCode $_ }) -join ', ')
            }
            Write-ErrorMessage ("Winget cannot be started for {0}: {1}.{2} {3}" -f $who, $probe.Reason, $seen, (Get-WingetSetupAdvice -State $state -Account $account))
            return [pscustomobject]@{ Ready = $false; Diagnosis = 'NotLaunchable' }
        }
        Write-Success "Winget is available ($($probe.Version))."
    }

    if ($WhatIf) {
        Write-Info "[DRY-RUN] Would update the winget source for $who (winget source update --name winget), and fix it if that fails: winget source reset --force for a missing or corrupted source, which also removes any source added beyond the defaults."
        return [pscustomobject]@{ Ready = $true; Diagnosis = 'Ok' }
    }

    Write-Info "Updating the winget source for $who (this may take a moment)..."
    $source = Invoke-WingetSourceProbe
    while (-not $source.Succeeded) {
        $fixed = $false
        $codeInfo = Get-WingetExitCodeInfo -ExitCode $source.ExitCode
        if ($source.ExitCode -eq $sessionBlockedExitCode -and -not $isSystem) {
            $fixed = Invoke-NextWingetAccountFix -State $state
        }
        elseif ($codeInfo -and $codeInfo.Class -eq 'SourceBroken' -and -not $state.ContainsKey('SourceReset')) {
            $state.SourceReset = Reset-WingetSource
            $fixed = $true
        }
        if (-not $fixed) {
            break
        }
        $source = Invoke-WingetSourceProbe
    }

    if ($source.Succeeded) {
        Write-Success "The winget source is up to date for $who."
        return [pscustomobject]@{ Ready = $true; Diagnosis = 'Ok' }
    }
    if ($source.ExitCode -eq $policyExitCode) {
        return (& $policyBlocked ("'winget source update' answered {0}" -f (Format-WingetExitCode -ExitCode $source.ExitCode)))
    }
    if ($source.ExitCode -eq $agreementsExitCode) {
        Write-Info 'The winget source agreements are not accepted for this account yet (0x8A150046); each install accepts them.'
        return [pscustomobject]@{ Ready = $true; Diagnosis = 'Ok' }
    }

    $detail = 'it did not finish in time and was stopped'
    if ($source.LaunchError) {
        $detail = "winget could not be started: $($source.LaunchError)"
    }
    elseif (-not $source.TimedOut) {
        $detail = 'exit code {0}' -f (Format-WingetExitCode -ExitCode $source.ExitCode)
    }
    Write-WarningMessage ('The winget source could not be set up for {0} ({1}). {2} Installations may fail.' -f $who, $detail, (Get-WingetSetupAdvice -State $state -Account $account -Source -SourceExitCode $source.ExitCode))
    return [pscustomobject]@{ Ready = $true; Diagnosis = 'SourceFailed' }
}

function Install-WingetPackage {
    param (
        [Parameter(Mandatory = $true)]
        [string]$PackageId,

        [Parameter(Mandatory = $false)]
        [string]$InstallerType,

        [Parameter(Mandatory = $false)]
        [int]$MaxAttempts = 3,

        [Parameter(Mandatory = $false)]
        [int]$InitialDelaySeconds = 5,

        [Parameter(Mandatory = $false)]
        [int]$MaxLaunchAttempts = 5,

        [Parameter(Mandatory = $false)]
        [switch]$Silent,

        [Parameter(Mandatory = $false)]
        [int]$InstallInProgressRetries = 3,

        [Parameter(Mandatory = $false)]
        [int]$InstallInProgressWaitSeconds = 600,

        [Parameter(Mandatory = $false)]
        [int]$InUseRetryDelaySeconds = 60,

        [Parameter(Mandatory = $false)]
        [switch]$MachineScopeOnly,

        [Parameter(Mandatory = $false)]
        [ValidateSet('any', 'machine', 'user')]
        [string]$Scope = 'any',

        [Parameter(Mandatory = $false)]
        [switch]$UserScopeOnly,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 86400)]
        [int]$TimeoutSeconds = 0
    )

    if ($Scope -eq 'user' -and $MachineScopeOnly) {
        throw [System.ArgumentException]::new("Install-WingetPackage: -Scope user installs $PackageId for the account running this, which -MachineScopeOnly rules out.")
    }
    if ($MachineScopeOnly -and $UserScopeOnly) {
        throw 'Install-WingetPackage: -MachineScopeOnly and -UserScopeOnly cannot be used together.'
    }
    if ($UserScopeOnly -and $Scope -eq 'machine') {
        throw [System.ArgumentException]::new("Install-WingetPackage: -UserScopeOnly installs $PackageId for the account running this only, which -Scope machine rules out.")
    }

    $sessionLogoffExitCode = -2147009255
    $noApplicableInstallerExitCode = -1978335216

    $useSilent = [bool]$Silent
    if (-not $PSBoundParameters.ContainsKey('Silent')) {
        $useSilent = [bool](Test-EffectiveNonInteractive)
    }
    $timeoutSeconds = $TimeoutSeconds
    if ($timeoutSeconds -le 0) {
        $timeoutSeconds = Get-ProcessTimeoutSeconds -Operation WingetInstall
    }

    $attempt = 0
    $sessionErrors = 0
    $delay = $InitialDelaySeconds
    $exitCode = 0
    $installInProgressRetried = 0
    $installInProgressWaited = 0
    $inUseRetried = $false
    $restartRequired = $false
    $useMachineScope = $Scope -ne 'user'
    $machineScopeFellBack = $false
    $noMachineScopeInstaller = $false
    $noUserScopeInstaller = $false
    $launchErrorExhausted = $false
    $launchAttempt = 0
    $launchDelay = $InitialDelaySeconds
    $launchError = $null
    $timedOut = $false
    $installerLogPath = $null
    $installerErrorCode = $null
    $engine = 'Cli'
    if (Test-WingetClientEngineActive) {
        $engine = 'WinGetClient'
    }

    while ($true) {
        $attempt++
        $restartRequired = $false

        $installArgs = @(
            'install', '-e'
        ) + (Get-WingetAgreementArgs) + @(
            '--source', 'winget',
            '--id', $PackageId
        )
        if ($UserScopeOnly) {
            $installArgs += @('--scope', 'user')
        }
        elseif ($useMachineScope) {
            $installArgs += @('--scope', 'machine')
        }
        elseif ($Scope -eq 'user') {
            $installArgs += @('--scope', 'user')
        }
        if (-not [string]::IsNullOrWhiteSpace($InstallerType)) {
            $installArgs += @('--installer-type', $InstallerType)
        }
        if ($useSilent) {
            $installArgs += '--silent'
        }

        if ($engine -eq 'WinGetClient') {
            $clientScope = 'default'
            if ($UserScopeOnly -or $Scope -eq 'user') {
                $clientScope = 'user'
            }
            elseif ($useMachineScope) {
                $clientScope = 'machine'
            }
            $run = Invoke-WingetClientInstall -PackageId $PackageId -Scope $clientScope -InstallerType $InstallerType -Silent:$useSilent -TimeoutSeconds $timeoutSeconds
        }
        else {
            $run = Invoke-WingetProcess -ArgumentList $installArgs -TimeoutSeconds $timeoutSeconds
        }
        $installerErrorCode = $null
        if ($null -ne $run.InstallerErrorCode) {
            $installerErrorCode = [long]$run.InstallerErrorCode
        }
        $installerLogPath = $null
        if ($run.LogPath -and (Test-Path -LiteralPath $run.LogPath)) {
            $installerLogPath = $run.LogPath
        }
        if ($run.LaunchFailed) {
            $attempt--
            $launchAttempt++
            $launchError = $run.LaunchError
            $transient = Test-TransientWingetLaunchError -NativeErrorCode $run.LaunchErrorCode -Message $run.LaunchError
            $launchVerb = 'launch winget'
            if ($engine -eq 'WinGetClient') {
                $launchVerb = 'start the WinGet client engine'
            }
            if ($transient -and $launchAttempt -lt $MaxLaunchAttempts) {
                Write-WarningMessage "Could not $launchVerb for $PackageId - its executable appears transiently locked ($($run.LaunchError)). Waiting ${launchDelay}s before launch retry $($launchAttempt + 1) of ${MaxLaunchAttempts}..."
                Start-Sleep -Seconds $launchDelay
                $launchDelay = $launchDelay * 2
                continue
            }

            if ($transient) {
                Write-WarningMessage "Still unable to $launchVerb for $PackageId after ${MaxLaunchAttempts} launch attempts ($($run.LaunchError))."
            }
            else {
                Write-WarningMessage "Could not $launchVerb for ${PackageId}: $($run.LaunchError)"
            }
            $launchErrorExhausted = $true
            $exitCode = $null
            break
        }

        if ($run.TimedOut) {
            Write-ErrorMessage ("Install of {0} did not finish within {1} minutes and was stopped." -f $PackageId, [Math]::Round($timeoutSeconds / 60))
            $timedOut = $true
            $exitCode = $null
            break
        }

        $exitCode = $run.ExitCode
        if ($exitCode -ne 0 -and $installerLogPath) {
            Write-Info "Installer log for ${PackageId}: $installerLogPath"
        }

        if ($UserScopeOnly -and $exitCode -eq $noApplicableInstallerExitCode) {
            Write-Info "winget found no per-user installer for $PackageId that applies to this PC, so it is not installed for this account."
            $noUserScopeInstaller = $true
            break
        }

        if (-not $UserScopeOnly -and $useMachineScope -and $exitCode -eq $noApplicableInstallerExitCode) {
            if ($MachineScopeOnly) {
                Write-Info "winget found no machine-scope installer for $PackageId that applies to this PC, and this run installs for the whole PC only, so it is not installed at winget's default (per-user) scope."
                $noMachineScopeInstaller = $true
                break
            }
            if ($Scope -eq 'machine') {
                Write-Info "winget found no machine-scope installer for $PackageId that applies to this PC, and its catalog entry allows only a machine-wide install (scope 'machine'), so it is not installed at winget's default (per-user) scope."
                $noMachineScopeInstaller = $true
                break
            }
            Write-Info "$PackageId has no machine-scope installer. Retrying with winget's default scope..."
            $useMachineScope = $false
            $machineScopeFellBack = $true
            $attempt--
            continue
        }

        if ($exitCode -eq $sessionLogoffExitCode) {
            $sessionErrors++
            if ($sessionErrors -lt $MaxAttempts) {
                Write-WarningMessage "Install of $PackageId hit transient session error 0x80073D19 (a user was logged off). Waiting ${delay}s before retry $($sessionErrors + 1) of ${MaxAttempts}..."
                Start-Sleep -Seconds $delay
                $delay = $delay * 2
                continue
            }
            Write-WarningMessage "Install of $PackageId still failing with session error 0x80073D19 after ${MaxAttempts} attempts."
            break
        }

        $codeClass = ''
        $codeInfo = Get-WingetExitCodeInfo -ExitCode $exitCode
        if ($codeInfo) {
            $codeClass = $codeInfo.Class
        }

        if ($codeClass -eq 'InstallInProgress') {
            $waitLeft = $InstallInProgressWaitSeconds - $installInProgressWaited
            if ($installInProgressRetried -lt $InstallInProgressRetries -and $waitLeft -gt 0) {
                $installInProgressRetried++
                Write-WarningMessage ("Windows Installer is busy with another installation ({0}). Waiting for it to finish (at most {1} seconds) before retry {2} of {3} for {4}..." -f (Format-WingetExitCode -ExitCode $exitCode), $waitLeft, $installInProgressRetried, $InstallInProgressRetries, $PackageId)
                $wait = Wait-WindowsInstallerIdle -MaximumSeconds $waitLeft
                $installInProgressWaited += [int]$wait.WaitedSeconds
                continue
            }
            Write-WarningMessage ("Windows Installer was still busy with another installation after {0} retries and {1} seconds of waiting; {2} was not installed." -f $installInProgressRetried, $installInProgressWaited, $PackageId)
            break
        }

        if ($codeClass -eq 'InUse' -and -not $inUseRetried) {
            $inUseRetried = $true
            Write-WarningMessage ("{0} could not be installed because it or its files are in use ({1}). Waiting {2}s before one more try..." -f $PackageId, (Format-WingetExitCode -ExitCode $exitCode), $InUseRetryDelaySeconds)
            Start-Sleep -Seconds $InUseRetryDelaySeconds
            continue
        }

        $restartRequired = Test-WingetRestartRequiredResult -ExitCode $exitCode -Output $run.Output -InstallerErrorCode $installerErrorCode
        break
    }

    return @{
        ExitCode                       = $exitCode
        Attempts                       = $attempt
        SessionErrorExhausted          = ($exitCode -eq $sessionLogoffExitCode)
        MachineScopeFellBack           = $machineScopeFellBack
        NoMachineScopeInstaller        = $noMachineScopeInstaller
        NoUserScopeInstaller           = $noUserScopeInstaller
        LaunchErrorExhausted           = $launchErrorExhausted
        LaunchAttempts                 = $launchAttempt
        LaunchError                    = $(if ($launchErrorExhausted) { $launchError } else { $null })
        TimedOut                       = $timedOut
        TimeoutSeconds                 = $timeoutSeconds
        InstallerLogPath               = $installerLogPath
        InstallInProgressWaitedSeconds = $installInProgressWaited
        RestartRequired                = $restartRequired
        InstallerErrorCode             = $installerErrorCode
        Engine                         = $engine
    }
}

function Test-WingetPackageInstalled {
    param (
        [Parameter(Mandatory = $true)]
        [string]$PackageId,

        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds
    )

    if (Test-WingetClientEngineActive) {
        return (Invoke-WingetClientInstalledCheck -PackageId $PackageId -TimeoutSeconds $TimeoutSeconds)
    }

    $listArgs = @('list', '--exact', '--id', $PackageId, '--accept-source-agreements', '--disable-interactivity')
    $run = Invoke-WingetProcess -ArgumentList $listArgs -TimeoutSeconds $TimeoutSeconds -Echo None
    if ($run.LaunchFailed) {
        return @{ Installed = $false; TimedOut = $false; LaunchFailed = $true; LaunchError = $run.LaunchError; CheckFailed = $false; ExitCode = $null }
    }

    if ($run.TimedOut) {
        return @{ Installed = $false; TimedOut = $true; LaunchFailed = $false; LaunchError = $null; CheckFailed = $false; ExitCode = $null }
    }

    $installed = Test-WingetListOutputContainsPackageId -Output ([String]::Join("`n", @($run.StandardOutput))) -PackageId $PackageId

    $noApplicationsFoundExitCode = -1978335212
    $checkFailed = (-not $installed) -and ($null -ne $run.ExitCode) -and (@(0, $noApplicationsFoundExitCode) -notcontains [int]$run.ExitCode)

    return @{
        Installed    = $installed
        TimedOut     = $false
        LaunchFailed = $false
        LaunchError  = $null
        CheckFailed  = $checkFailed
        ExitCode     = $run.ExitCode
    }
}

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

function Invoke-AppxProvisioning {
    param (
        [Parameter(Mandatory = $true)]
        [string]$PackagePath,

        [Parameter(Mandatory = $false)]
        [string[]]$DependencyPackagePath = @(),

        [Parameter(Mandatory = $false)]
        [string]$LicensePath,

        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 0
    )

    $hasLicense = $LicensePath -and (Test-Path $LicensePath)

    try {
        if ($PSVersionTable.PSEdition -eq 'Core') {
            $escapedPackagePath = $PackagePath.Replace("'", "''")
            $depClause = if ($DependencyPackagePath.Count -gt 0) {
                $escapedDependencyPaths = @($DependencyPackagePath | ForEach-Object { $_.Replace("'", "''") })
                "-DependencyPackagePath @('" + ($escapedDependencyPaths -join "','") + "')"
            }
            else { '' }
            $licClause = if ($hasLicense) { "-LicensePath '$($LicensePath.Replace("'", "''"))'" } else { '-SkipLicense' }
            $command = "Add-AppxProvisionedPackage -Online -PackagePath '$escapedPackagePath' $depClause $licClause -ErrorAction Stop | Out-Null"
            if ($TimeoutSeconds -gt 0) {
                $run = Invoke-ExternalProcess -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', "`$ProgressPreference = 'SilentlyContinue'; $command") -TimeoutSeconds $TimeoutSeconds -Encoding ([Console]::OutputEncoding) -RemoveEnvironmentVariable @('PSModulePath')
                if ($run.LaunchFailed) {
                    Write-ErrorMessage "Add-AppxProvisionedPackage failed for '$PackagePath': Windows PowerShell could not be started ($($run.LaunchError))."
                    return $false
                }
                if ($run.TimedOut) {
                    Write-ErrorMessage ("Add-AppxProvisionedPackage did not finish within {0} minutes for '{1}' and was stopped." -f [Math]::Round($TimeoutSeconds / 60), $PackagePath)
                    return $false
                }
                return ($run.ExitCode -eq 0)
            }
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
            'download', '-e', '--id', $PackageId, '--source', 'winget', '--installer-type', 'msix'
        ) + (Get-WingetAgreementArgs) + @(
            '--download-directory', $downloadDir
        )
        $download = Invoke-WingetProcess -ArgumentList $downloadArgs -TimeoutSeconds (Get-ProcessTimeoutSeconds -Operation WingetDownload)
        if ($download.LaunchFailed) {
            throw $download.LaunchException
        }
        if ($download.TimedOut) {
            Write-ErrorMessage "winget download for $PackageId did not finish in time and was stopped."
            return @{ ExitCode = $null; Installed = $false }
        }
        if ($download.ExitCode -ne 0) {
            Write-ErrorMessage ('winget download failed for {0} (exit code {1}).' -f $PackageId, (Format-WingetExitCode -ExitCode $download.ExitCode))
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

function Install-PowerShellLatest {
    param (
        [Parameter(Mandatory = $false)]
        [string]$PackageId = 'Microsoft.PowerShell',

        [Parameter(Mandatory = $false)]
        [switch]$Silent,

        [Parameter(Mandatory = $false)]
        [int]$InstallInProgressWaitSeconds,

        [Parameter(Mandatory = $false)]
        [switch]$MachineScopeOnly
    )

    $noApplicableInstallerExitCode = -1978335216

    $checkTimeoutSeconds = Get-ProcessTimeoutSeconds -Operation WingetListCheck

    $installParameters = @{ PackageId = $PackageId }
    if ($PSBoundParameters.ContainsKey('Silent')) {
        $installParameters['Silent'] = $Silent
    }
    if ($MachineScopeOnly) {
        $installParameters['MachineScopeOnly'] = $true
    }

    if ($PSBoundParameters.ContainsKey('InstallInProgressWaitSeconds')) {
        $installParameters['InstallInProgressWaitSeconds'] = $InstallInProgressWaitSeconds
    }

    $method = 'msi'
    $result = Install-WingetPackage @installParameters -InstallerType 'wix'
    $installInProgressWaited = [int]$result.InstallInProgressWaitedSeconds
    if ($result.ExitCode -eq $noApplicableInstallerExitCode) {
        Write-Info "No MSI is available for the latest $PackageId; installing the MSIX package instead."
        if ((Get-WindowsBuildNumber) -lt 26100) {
            $provision = Install-MsixProvisionedPackage -PackageId $PackageId
            return @{ ExitCode = $provision.ExitCode; Installed = $provision.Installed; Method = 'msix-provisioned'; InstallInProgressWaitedSeconds = $installInProgressWaited }
        }
        $method = 'msix-native'
        if ($installParameters.ContainsKey('InstallInProgressWaitSeconds')) {
            $installParameters['InstallInProgressWaitSeconds'] = [Math]::Max(0, $InstallInProgressWaitSeconds - $installInProgressWaited)
        }
        $result = Install-WingetPackage @installParameters
        $installInProgressWaited += [int]$result.InstallInProgressWaitedSeconds
    }

    $outcome = @{}
    if ($result -is [hashtable]) {
        foreach ($key in $result.Keys) {
            $outcome[$key] = $result[$key]
        }
    }
    else {
        $outcome['ExitCode'] = $result.ExitCode
    }
    $outcome['Method'] = $method
    $outcome['InstallInProgressWaitedSeconds'] = $installInProgressWaited
    $outcome['VerifyTimedOut'] = $false
    $outcome['VerifyLaunchFailed'] = $false
    $outcome['VerifyLaunchError'] = $null
    $outcome['VerifyCheckFailed'] = $false
    $outcome['VerifyExitCode'] = $null

    if ($outcome['LaunchErrorExhausted'] -or $outcome['NoMachineScopeInstaller']) {
        $outcome['Installed'] = $false
        return $outcome
    }

    $verify = Test-WingetPackageInstalled -PackageId $PackageId -TimeoutSeconds $checkTimeoutSeconds
    $outcome['Installed'] = [bool]$verify.Installed
    $outcome['VerifyTimedOut'] = [bool]$verify.TimedOut
    $outcome['VerifyLaunchFailed'] = [bool]$verify.LaunchFailed
    $outcome['VerifyLaunchError'] = $verify.LaunchError
    $outcome['VerifyCheckFailed'] = [bool]$verify.CheckFailed
    $outcome['VerifyExitCode'] = $verify.ExitCode
    return $outcome
}

# ------------------------------------------------Main Script------------------------------------------------

if ($MyInvocation.InvocationName -ne '.') {
    if (-not (Test-FullLanguageMode)) {
        $global:LASTEXITCODE = 5
        if (-not $WhatIf) {
            try {
                Write-InstallerNotStartedResult -ExitCode 5
            }
            catch {
            }
        }
        $exitForLanguageMode = [bool]$PSCommandPath
        if (-not $exitForLanguageMode) {
            try {
                $exitForLanguageMode = [bool](Test-EffectiveNonInteractive -NonInteractive:$NonInteractive)
            }
            catch {
                $exitForLanguageMode = $false
            }
        }
        if ($exitForLanguageMode) {
            exit 5
        }
        return
    }

    if ($CollectDiagnostics) {
        $diagnosticsExitCode = 5
        try {
            $diagnosticsExitCode = [int](@(Invoke-DiagnosticsCollection)[-1])
        }
        catch {
            Write-ErrorMessage "The diagnostics bundle could not be made: $_"
            $diagnosticsExitCode = 5
        }
        $global:LASTEXITCODE = $diagnosticsExitCode
        $exitForDiagnostics = [bool]$PSCommandPath
        if (-not $exitForDiagnostics) {
            try {
                $exitForDiagnostics = [bool](Test-EffectiveNonInteractive -NonInteractive:$NonInteractive)
            }
            catch {
                $exitForDiagnostics = $false
            }
        }
        if ($exitForDiagnostics) {
            exit $diagnosticsExitCode
        }
        return
    }

    $launchedForScript = $false
    if ($PSCommandPath) {
        foreach ($commandLineArgument in [Environment]::GetCommandLineArgs()) {
            try {
                if ([System.IO.Path]::GetFullPath($commandLineArgument) -eq $PSCommandPath) {
                    $launchedForScript = $true
                    break
                }
            }
            catch {
            }
        }
    }
    $forceExitCodeOnAbort = $launchedForScript -or (Test-EffectiveNonInteractive -NonInteractive:$NonInteractive)

    $script:InstallerExitRequested = $false
    $script:InstallerPendingExitCode = $null
    $script:InstallLogPath = $null
    $script:InstallerScriptSha256 = $null
    $installerRunCompleted = $false
    $script:InstallerRunStartedUtc = [DateTime]::UtcNow
    $script:InstallerRunRecordEnabled = $false
    $script:InstallerRunReportPending = $false
    $script:InstallerAppRecords = $null
    $script:InstallerAutoUpdateResult = $null
    $script:WingetClientEngine = $null
    $script:InstallEngineRecord = $null

    if ($PSVersionTable.PSVersion.Major -lt 7) {
        $script:PowerShell7BootstrapRelaunched = $false
        $script:InstallLogPath = Start-InstallerTranscript -Bootstrap -WhatIf:$WhatIf
        $bootstrapLogDirectory = ''
        if ($script:InstallLogPath) {
            $bootstrapLogDirectory = Split-Path -Parent $script:InstallLogPath
        }
        $bootstrapExitCode = 7
        try {
            if ($script:InstallLogPath) {
                Write-Info "Logging the PowerShell 7 bootstrap to: $script:InstallLogPath"
            }
            Write-Info "Installer build: $script:InstallerBuildId"
            try {
                $bootstrapParameters = @{}
                $bootstrapBudgetParameters = @{ RunDeadlineUtc = $RunDeadlineUtc; StartedUtc = $script:InstallerRunStartedUtc }
                if ($null -ne $PSBoundParameters -and $PSBoundParameters.ContainsKey('MaxRuntimeMinutes')) {
                    $bootstrapBudgetParameters['MaxRuntimeMinutes'] = $MaxRuntimeMinutes
                }
                $budgetArguments = @(Get-InstallerRunBudgetArgument -Budget (Resolve-InstallerRunBudget @bootstrapBudgetParameters))
                if ($budgetArguments.Count -gt 0) {
                    $bootstrapParameters['AdditionalArguments'] = $budgetArguments
                }
                $bootstrapExitCode = Invoke-PowerShell7Bootstrap -WhatIf:$WhatIf -NonInteractive:$NonInteractive -SkipSystemCheck:$SkipSystemCheck -CommandPath $PSCommandPath -ExpectedBuildId $script:InstallerBuildId -LogDirectory $bootstrapLogDirectory @bootstrapParameters
            }
            catch {
                Write-ErrorMessage "The PowerShell 7 bootstrap failed unexpectedly: $_"
                $bootstrapExitCode = 7
            }
            Exit-Installer -Code $bootstrapExitCode -NonInteractive:$NonInteractive -OutcomeShown:$script:PowerShell7BootstrapRelaunched
        }
        finally {
            if (-not $script:InstallerExitRequested -and $forceExitCodeOnAbort) {
                if ($null -ne $script:InstallerPendingExitCode) {
                    $host.SetShouldExit([int]$script:InstallerPendingExitCode)
                }
                else {
                    $host.SetShouldExit(5)
                }
            }
            if ($script:InstallLogPath) {
                try {
                    [void](Stop-Transcript)
                }
                catch {
                }
            }
        }
        exit $bootstrapExitCode
    }

    if ($PSCommandPath) {
        try {
            $script:InstallerScriptSha256 = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256 -ErrorAction Stop).Hash
        }
        catch {
        }
    }

    $script:InstallLogPath = Start-InstallerTranscript -WhatIf:$WhatIf
    $transcriptStarted = [bool]$script:InstallLogPath
    $script:InstallerRunReportPending = -not $WhatIf

    try {
        if ($script:InstallLogPath) {
            Write-Info "Logging this run to: $script:InstallLogPath"
        }
        Write-Info "Installer build: $script:InstallerBuildId"

        if (-not $WhatIf -and (Test-IsAdmin)) {
            if ((Lock-InstallerRun) -eq 'Busy') {
                Write-ErrorMessage 'Another run of this installer is in progress on this PC (started by an RMM tool, a scheduled task or someone else). This run stops without changing anything: let that run finish, then run the installer again if needed.'
                Exit-Installer -Code 6 -Reason 'another run of the installer is in progress on this PC' -NonInteractive:$NonInteractive
            }
            $script:InstallerRunRecordEnabled = $true
            [void](Save-InstallerRunStartRecord)
            [void](Invoke-InstallerHousekeeping -CurrentScriptPath $PSCommandPath)
        }

        if (-not $SkipSystemCheck) {
            if ($WhatIf) {
                Write-Info '[DRY-RUN] Running pre-flight system checks (OS version, disk space, network).'
                if (-not (Test-SystemRequirements -WhatIf:$WhatIf)) {
                    Write-WarningMessage '[DRY-RUN] A blocking pre-flight check failed - a real run would abort here.'
                }
            }
            elseif (-not (Test-SystemRequirements -WhatIf:$WhatIf)) {
                Exit-Installer -Code 1 -Reason 'a blocking pre-flight system check failed (see above)' -NonInteractive:$NonInteractive
            }
        }

        $budgetParameters = @{}
        if ($null -ne $PSBoundParameters -and $PSBoundParameters.ContainsKey('MaxRuntimeMinutes')) {
            $budgetParameters['MaxRuntimeMinutes'] = $MaxRuntimeMinutes
        }
        if (-not [string]::IsNullOrWhiteSpace($RunDeadlineUtc)) {
            $budgetParameters['RunDeadlineUtc'] = $RunDeadlineUtc
        }
        $installerExitCode = [int](@(Invoke-WingetInstall -WhatIf:$WhatIf -NonInteractive:$NonInteractive -SkipSystemCheck:$SkipSystemCheck @budgetParameters)[-1])
        if ($installerExitCode -ne 0) {
            Exit-Installer -Code $installerExitCode -NonInteractive:$NonInteractive -OutcomeShown:($null -ne $script:InstallerPendingExitCode)
        }
        $installerRunCompleted = $true
    }
    catch {
        Write-ErrorMessage 'UNEXPECTED ERROR - the run was aborted before it finished. No summary was produced, and apps may be only partly installed.'
        Write-ErrorMessage "Error: $($_.Exception.Message)"
        if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
            Write-ErrorMessage $_.InvocationInfo.PositionMessage
        }
        if ($_.ScriptStackTrace) {
            Write-ErrorMessage "Stack trace:`n$($_.ScriptStackTrace)"
        }
        if ($forceExitCodeOnAbort) {
            Exit-Installer -Code 5 -NonInteractive:$NonInteractive
        }
        Write-InstallerExitNotice -Code 5 -NoPause
        $script:InstallerExitRequested = $true
        $global:LASTEXITCODE = 5
    }
    finally {
        if (-not $installerRunCompleted -and -not $script:InstallerExitRequested -and $forceExitCodeOnAbort) {
            if ($null -ne $script:InstallerPendingExitCode) {
                $host.SetShouldExit([int]$script:InstallerPendingExitCode)
            }
            else {
                $abortMessage = 'The run was stopped before it finished (exit code 5).'
                try {
                    Write-ErrorMessage $abortMessage
                }
                catch {
                    [Console]::Error.WriteLine($abortMessage)
                }
                $host.SetShouldExit(5)
            }
        }
        $finalExitCode = 0
        if ($null -ne $script:InstallerPendingExitCode) {
            $finalExitCode = [int]$script:InstallerPendingExitCode
        }
        elseif (-not $installerRunCompleted) {
            $finalExitCode = 5
        }
        try {
            Complete-InstallerRun -ExitCode $finalExitCode
        }
        catch {
        }
        try {
            Clear-TightVncSecret
        }
        catch {
        }
        try {
            if (Get-Command -Name 'Remove-WingetClientEngine' -CommandType Function -ErrorAction SilentlyContinue) {
                Remove-WingetClientEngine
            }
        }
        catch {
        }
        if ($transcriptStarted) {
            try {
                [void](Stop-Transcript)
            }
            catch {
            }
        }
    }
}
