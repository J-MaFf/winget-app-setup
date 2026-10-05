<#
.SYNOPSIS
    Reports whether winget, App Installer and Winget-AutoUpdate work on this PC: a read-only fleet
    health probe to push from an RMM (Endpoint Central, run as SYSTEM).
.DESCRIPTION
    A machine where Winget-AutoUpdate (WAU) has left winget unusable reads green everywhere: WAU
    logs 'No update found' and its task reports success, and the next helpdesk run of the installer
    fails every app. This probe finds such machines without waiting for that run. Deploy it from
    ManageEngine Endpoint Central as a Computer Configuration custom script run as the System user
    (success exit code 0, 'Enable logging for troubleshooting' on, so the output lands in the
    configuration's Remarks). It changes nothing.

    It writes one line per check and ends with one machine-parsable line:

      HEALTH: status=<healthy|unhealthy> problems=<codes|none> computer=<name> appinstaller=<version>
              runtime=<present|missing|unknown> winget=<ok|fallback|failed|timedout|notfound>
              wingetversion=<version> wau=<version|installed|none> wautask=<state|missing|unknown|->
              wauresult=<0xHEX|-> logontrigger=<yes|no|-> wauwingetinstalls=<count|->

    (all on one line; '-' when there is nothing to report). The checks:

      - App Installer (Microsoft.DesktopAppInstaller): each installed version, its status, and each
        account's install state (Get-AppxPackage -AllUsers, PackageUserInformation).
      - Windows App Runtime: whether Microsoft.WindowsAppRuntime.1.8 8000.616.304.0 or newer is
        installed for this PC's architecture. Every winget release from 1.12 on needs it, and WAU
        installs the newest winget without it.
      - winget: whether the machine-wide winget.exe (the newest App Installer with status Ok, for
        this PC's architecture first, else the newest under %ProgramFiles%\WindowsApps) prints its
        version within a time limit. When it does not, the next ones are tried too, so the output
        says whether an older one still runs. As SYSTEM winget runs only by this full path, and
        WAU's SYSTEM run uses the newest one.
      - Winget-AutoUpdate: whether it is installed (its MSI's uninstall entry or its settings key),
        its WAU_UpdatesAtLogon setting and Group Policy, and its \WAU\Winget-AutoUpdate task: state,
        triggers, last run and result, next run.
      - WAU's log (updates.log): the last lines that tell what its runs did: each run's header,
        the WinGet MSIXBundle install WAU's prerequisite step does, 'No update found' with the
        winget output that follows it, and errors and failures.

    Unhealthy (exit code 1) when any of these holds:
      not-elevated         the probe could not read the machine: run it as SYSTEM or elevated.
      winget-notfound      no machine-wide winget.exe exists.
      winget-launch        the newest machine-wide winget.exe did not print its version in time
                           (status 'fallback' when an older one still did).
      runtime-missing      WAU is installed and the Windows App Runtime above is not: WAU's next run
      runtime-unknown      can install a winget that cannot start (or that could not be read).
      wau-task-missing     WAU is installed and its task does not exist,
      wau-task-unknown     could not be read,
      wau-task-disabled    is disabled,
      wau-task-no-trigger  or has no enabled trigger: auto-updates never run.
      wau-logon-trigger    WAU's task still has its at-logon trigger, so WAU runs at every sign-in,
                           exactly when a technician signs in to re-run the installer. Fix it with
                           rmm/Repair-WauLogonTrigger.ps1.
      probe-error          the probe itself could not run.
    A PC without WAU is not unhealthy for that alone: the installer leaves WAU off a PC that lacks
    the Windows App Runtime.

    Run by a 32-bit PowerShell on 64-bit Windows (Endpoint Central's agent is 32-bit), or by
    PowerShell 7, it runs itself again in 64-bit Windows PowerShell
    (%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe from a 32-bit process): only
    there do the registry, Program Files and the Appx cmdlets read the machine as it is.
.PARAMETER WingetTimeoutSeconds
    The time limit for each `winget.exe --version`. Default 30 seconds, the installer's own.
.PARAMETER LogMatchCount
    How many of the last matching updates.log entries to show. Default 20; 0 shows none.
.PARAMETER Relaunched
    Set by the probe itself when it runs itself again in 64-bit Windows PowerShell.
.PARAMETER WhatIf
    Accepted, and changes nothing: the probe never changes anything.
.NOTES
    Exit codes: 0 healthy, 1 unhealthy (the HEALTH line's problems say why).
    Runs under Windows PowerShell 5.1: ASCII only, no PowerShell-7-only syntax.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param (
    [Parameter(Mandatory = $false)]
    [ValidateRange(5, 600)]
    [int]$WingetTimeoutSeconds = 30,

    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 500)]
    [int]$LogMatchCount = 20,

    [Parameter(Mandatory = $false)]
    [switch]$Relaunched
)

# What winget 1.12 and later need; the installer's built-in requirement
# (Get-WindowsAppRuntimeStatus / Get-DefaultWindowsAppRuntimeRequirement in WauSupport.ps1).
$script:RmmRuntimeName = 'Microsoft.WindowsAppRuntime.1.8'
$script:RmmRuntimeMinimumVersion = [version]'8000.616.304.0'

# ---- Shared with rmm/Repair-WauLogonTrigger.ps1 (tests keep the two copies identical) -----------

<#
.SYNOPSIS
    Returns the Windows directory, without a trailing backslash.
#>
function Get-RmmWindowsDirectory {
    $windowsDirectory = $env:SystemRoot
    if (-not $windowsDirectory) {
        $windowsDirectory = $env:windir
    }
    if (-not $windowsDirectory) {
        $windowsDirectory = 'C:\Windows'
    }
    return $windowsDirectory.TrimEnd('\')
}

<#
.SYNOPSIS
    Returns the 64-bit Windows PowerShell as a 32-bit process reaches it: through Sysnative, which
    exists only for 32-bit processes.
#>
function Get-RmmSysnativePowerShellPath {
    return (Get-RmmWindowsDirectory) + '\Sysnative\WindowsPowerShell\v1.0\powershell.exe'
}

<#
.SYNOPSIS
    Returns Windows PowerShell's path in this process's own System32.
#>
function Get-RmmWindowsPowerShellPath {
    return (Get-RmmWindowsDirectory) + '\System32\WindowsPowerShell\v1.0\powershell.exe'
}

<#
.SYNOPSIS
    Returns the account this process runs as, or 'unknown'.
#>
function Get-RmmAccountName {
    try {
        return [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    }
    catch {
        return 'unknown'
    }
}

<#
.SYNOPSIS
    Turns the wrapper's bound parameters back into arguments, for the 64-bit relaunch.
.PARAMETER BoundParameters
    The script's $PSBoundParameters.
.RETURNS
    [string[]]
#>
function ConvertTo-RmmForwardedArgument {
    param (
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$BoundParameters
    )

    $arguments = @()
    foreach ($name in @($BoundParameters.Keys | Sort-Object)) {
        $value = $BoundParameters[$name]
        if ($value -is [System.Management.Automation.SwitchParameter]) {
            if ($value.IsPresent) {
                $arguments += "-$name"
            }
        }
        elseif ($null -ne $value -and "$value" -ne '') {
            $arguments += @("-$name", "$value")
        }
    }
    return $arguments
}

<#
.SYNOPSIS
    Returns the Windows PowerShell this script must run itself again in, or $null when it already
    runs in the right one.
.DESCRIPTION
    A 32-bit process on 64-bit Windows (Endpoint Central's agent is 32-bit) reads the 32-bit
    registry (WOW6432Node) and the 32-bit Program Files, so it is run again in the 64-bit Windows
    PowerShell, which it reaches through Sysnative. PowerShell 7 is run again in Windows
    PowerShell, where the Appx and ScheduledTasks cmdlets always load.
.PARAMETER Is64BitOperatingSystem
    Default: this PC's.
.PARAMETER Is64BitProcess
    Default: this process's.
.PARAMETER Edition
    Default: this PowerShell's ('Desktop' or 'Core').
.RETURNS
    [string] or $null.
#>
function Get-RmmNativePowerShellRelaunchPath {
    param (
        [Parameter(Mandatory = $false)]
        [bool]$Is64BitOperatingSystem = [Environment]::Is64BitOperatingSystem,

        [Parameter(Mandatory = $false)]
        [bool]$Is64BitProcess = [Environment]::Is64BitProcess,

        [Parameter(Mandatory = $false)]
        [string]$Edition = $PSVersionTable.PSEdition
    )

    if ($Is64BitOperatingSystem -and -not $Is64BitProcess) {
        return (Get-RmmSysnativePowerShellPath)
    }
    if ($Edition -eq 'Core') {
        return (Get-RmmWindowsPowerShellPath)
    }
    return $null
}

<#
.SYNOPSIS
    Runs this script again in another PowerShell and returns what it printed and its exit code.
.PARAMETER FilePath
    The PowerShell to run (Get-RmmNativePowerShellRelaunchPath).
.PARAMETER ArgumentList
    Its arguments.
.RETURNS
    [pscustomobject] with Lines ([string[]]), ExitCode ([int] or $null) and LaunchError ($null, or
    why it could not be started).
#>
function Invoke-RmmNativeRelaunch {
    param (
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $false)]
        [string[]]$ArgumentList = @()
    )

    $result = [pscustomobject]@{ Lines = @(); ExitCode = $null; LaunchError = $null }
    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        $result.LaunchError = "$FilePath does not exist"
        return $result
    }
    $global:LASTEXITCODE = $null
    try {
        $result.Lines = @(& $FilePath @ArgumentList 2>&1 | ForEach-Object { "$_" })
        $result.ExitCode = $global:LASTEXITCODE
    }
    catch {
        $result.LaunchError = $_.Exception.Message
    }
    return $result
}

<#
.SYNOPSIS
    Returns whether this process can read and change the whole machine: SYSTEM, or an elevated
    administrator.
#>
function Test-RmmElevated {
    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        if ($identity.IsSystem) {
            return $true
        }
        $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
        return [bool]$principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

<#
.SYNOPSIS
    Returns a value for a key=value result line: no spaces or '=', '-' when empty.
#>
function ConvertTo-RmmResultValue {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Value
    )

    $text = "$Value".Trim()
    if ($text.Length -eq 0) {
        return '-'
    }
    return ($text -replace '[\s=]+', '_')
}

<#
.SYNOPSIS
    Returns this PC's name.
#>
function Get-RmmComputerName {
    $name = $env:COMPUTERNAME
    if (-not $name) {
        $name = [Environment]::MachineName
    }
    return $name
}

<#
.SYNOPSIS
    Returns a failed run's result: its message and the result line, exit code 1.
.PARAMETER Message
    What went wrong.
.PARAMETER ResultPrefix
    The result line's name ('HEALTH' or 'REPAIR').
.PARAMETER FailureStatus
    The result line's status for a failed run.
.PARAMETER FailureProblem
    The result line's problem code.
.RETURNS
    [pscustomobject] with Lines and ExitCode.
#>
function New-RmmFailureResult {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $true)]
        [string]$ResultPrefix,

        [Parameter(Mandatory = $true)]
        [string]$FailureStatus,

        [Parameter(Mandatory = $true)]
        [string]$FailureProblem
    )

    return [pscustomobject]@{
        Lines    = @(($Message -replace '\s*[\r\n]+\s*', ' '), ('{0}: status={1} problems={2} computer={3}' -f $ResultPrefix, $FailureStatus, $FailureProblem, (ConvertTo-RmmResultValue -Value (Get-RmmComputerName))))
        ExitCode = 1
    }
}

<#
.SYNOPSIS
    Runs this script again in 64-bit Windows PowerShell when it runs in the wrong PowerShell, and
    returns that run's lines and exit code; $null when it already runs in the right one.
.DESCRIPTION
    Get-RmmNativePowerShellRelaunchPath decides. The relaunched run gets the same arguments plus
    -Relaunched, so it never relaunches again. When it cannot be started, or prints no result line,
    the result is a failure (New-RmmFailureResult).
.PARAMETER ScriptPath
    This script's path ($PSCommandPath).
.PARAMETER ForwardedArguments
    ConvertTo-RmmForwardedArgument's result.
.PARAMETER ResultPrefix
    The result line's name ('HEALTH' or 'REPAIR'), which the relaunched run's output must have.
.PARAMETER FailureStatus
    The result line's status for a failed run.
.PARAMETER FailureProblem
    The result line's problem code for a failed run.
.RETURNS
    [pscustomobject] with Lines and ExitCode, or $null.
#>
function Invoke-RmmRelaunchWhenNeeded {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ScriptPath,

        [Parameter(Mandatory = $false)]
        [string[]]$ForwardedArguments = @(),

        [Parameter(Mandatory = $true)]
        [string]$ResultPrefix,

        [Parameter(Mandatory = $true)]
        [string]$FailureStatus,

        [Parameter(Mandatory = $true)]
        [string]$FailureProblem
    )

    $relaunchPath = Get-RmmNativePowerShellRelaunchPath
    if (-not $relaunchPath) {
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($ScriptPath)) {
        return (New-RmmFailureResult -Message 'This is a 32-bit PowerShell on 64-bit Windows, or PowerShell 7, and the script cannot run itself again in 64-bit Windows PowerShell because it was not started from a file: run it with -File.' -ResultPrefix $ResultPrefix -FailureStatus $FailureStatus -FailureProblem $FailureProblem)
    }
    $arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + @($ForwardedArguments) + @('-Relaunched')
    $relaunch = Invoke-RmmNativeRelaunch -FilePath $relaunchPath -ArgumentList $arguments
    if ($relaunch.LaunchError) {
        return (New-RmmFailureResult -Message "Could not run this script again in 64-bit Windows PowerShell ($relaunchPath): $($relaunch.LaunchError)" -ResultPrefix $ResultPrefix -FailureStatus $FailureStatus -FailureProblem $FailureProblem)
    }
    $lines = @($relaunch.Lines)
    if ($null -eq $relaunch.ExitCode -or @($lines | Where-Object { $_ -like "${ResultPrefix}: *" }).Count -eq 0) {
        $failure = New-RmmFailureResult -Message ("This script's run in 64-bit Windows PowerShell ($relaunchPath) ended without a $ResultPrefix line (exit code {0})." -f $relaunch.ExitCode) -ResultPrefix $ResultPrefix -FailureStatus $FailureStatus -FailureProblem $FailureProblem
        return [pscustomobject]@{ Lines = @($lines) + @($failure.Lines); ExitCode = 1 }
    }
    return [pscustomobject]@{
        Lines    = @("Started in a 32-bit PowerShell or PowerShell 7: ran again in $relaunchPath.") + $lines
        ExitCode = [int]$relaunch.ExitCode
    }
}

# ---- The probe ------------------------------------------------------------------------------------

<#
.SYNOPSIS
    Returns this PC's architecture as the Appx cmdlets name it: 'X64', 'Arm64' or 'X86'.
#>
function Get-RmmOSArchitecture {
    try {
        $architecture = [string][System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
        if ($architecture) {
            return $architecture
        }
    }
    catch {
        # .NET Framework before 4.7.1 has no RuntimeInformation: read the environment instead.
    }
    $processor = $env:PROCESSOR_ARCHITEW6432
    if (-not $processor) {
        $processor = $env:PROCESSOR_ARCHITECTURE
    }
    switch ("$processor") {
        'AMD64' { return 'X64' }
        'ARM64' { return 'Arm64' }
        'x86' { return 'X86' }
    }
    return "$processor"
}

<#
.SYNOPSIS
    Lists the packages of one name installed for any account, with each account's install state.
.DESCRIPTION
    Get-AppxPackage -AllUsers, which needs SYSTEM or an elevated administrator. A package staged on
    the machine and registered for nobody is listed too. Each account comes from the package's
    PackageUserInformation: its account name (or SID) and install state (Installed, Staged, ...).
.PARAMETER Name
    The package name.
.RETURNS
    [pscustomobject] with Packages (Name, Version ([version] or $null), VersionText, Architecture,
    Status, InstallLocation, Users (Account, Sid, InstallState)) and Error ($null, or why the
    query failed).
#>
function Get-RmmAppxPackage {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $result = [pscustomobject]@{ Packages = @(); Error = $null }
    try {
        $found = @(Get-AppxPackage -AllUsers -Name $Name -ErrorAction Stop)
    }
    catch {
        $result.Error = $_.Exception.Message
        return $result
    }

    $result.Packages = @(foreach ($package in $found) {
            if ($null -eq $package) {
                continue
            }
            $version = $null
            $parsedVersion = $null
            if ([version]::TryParse("$($package.Version)", [ref]$parsedVersion)) {
                $version = $parsedVersion
            }
            $users = @(foreach ($user in @($package.PackageUserInformation)) {
                    if ($null -eq $user) {
                        continue
                    }
                    $sid = $null
                    $account = $null
                    $state = $null
                    if ($null -ne $user.UserSecurityId) {
                        $sid = [string]$user.UserSecurityId.Sid
                        $account = [string]$user.UserSecurityId.Username
                    }
                    if ($null -ne $user.InstallState) {
                        $state = [string]$user.InstallState
                    }
                    if (-not $sid -and -not $state -and "$user" -match '^\s*(?<sid>S-[0-9-]+)\s*(\[(?<account>[^\]]*)\])?\s*:\s*(?<state>\S+)\s*$') {
                        # Its text instead, as in 'S-1-5-18 [S-1-5-18]: Staged'.
                        $sid = $Matches['sid']
                        $account = $Matches['account']
                        $state = $Matches['state']
                    }
                    [pscustomobject]@{ Account = $account; Sid = $sid; InstallState = $state }
                })
            [pscustomobject]@{
                Name            = [string]$package.Name
                Version         = $version
                VersionText     = [string]$package.Version
                Architecture    = [string]$package.Architecture
                Status          = [string]$package.Status
                InstallLocation = [string]$package.InstallLocation
                Users           = $users
            }
        })
    return $result
}

<#
.SYNOPSIS
    Describes one package for the report: its version, architecture, status and accounts.
.RETURNS
    [string] For example '1.29.380.0 X64, status Ok: CONTOSO\jdoe Installed; S-1-5-18 Staged'.
#>
function Format-RmmAppxPackage {
    param (
        [Parameter(Mandatory = $true)]
        [object]$Package
    )

    $users = @(foreach ($user in @($Package.Users)) {
            $label = $user.Account
            if ([string]::IsNullOrWhiteSpace($label)) {
                $label = $user.Sid
            }
            if ([string]::IsNullOrWhiteSpace($label)) {
                $label = 'an unknown account'
            }
            $state = $user.InstallState
            if ([string]::IsNullOrWhiteSpace($state)) {
                $state = 'state unknown'
            }
            '{0} {1}' -f $label, $state
        })
    $accounts = 'no account'
    if ($users.Count -gt 0) {
        $accounts = $users -join '; '
    }
    $status = $Package.Status
    if ([string]::IsNullOrWhiteSpace($status)) {
        $status = 'unknown'
    }
    return ('{0} {1}, status {2}: {3}' -f $Package.VersionText, $Package.Architecture, $status, $accounts)
}

<#
.SYNOPSIS
    Returns the folder MSIX packages are installed to for the machine, or $null.
.DESCRIPTION
    %ProgramFiles%\WindowsApps. ProgramW6432 comes first: in a 32-bit process ProgramFiles is
    'Program Files (x86)', which holds no WindowsApps folder.
#>
function Get-RmmWindowsAppsDirectory {
    $programFiles = $env:ProgramW6432
    if ([string]::IsNullOrWhiteSpace($programFiles)) {
        $programFiles = $env:ProgramFiles
    }
    if ([string]::IsNullOrWhiteSpace($programFiles)) {
        return $null
    }
    return (Join-Path $programFiles 'WindowsApps')
}

<#
.SYNOPSIS
    Lists the machine-wide winget.exe files, the one to check first at the top.
.DESCRIPTION
    The installer's own choice for a run as SYSTEM (Get-MachineWingetCandidate in
    WingetAppSetup/Private/MachineContext.ps1): App Installer packages with status Ok and a
    winget.exe in their folder; when the package query failed or found none, the
    Microsoft.DesktopAppInstaller_<version>_<architecture>__8wekyb3d8bbwe folders under
    %ProgramFiles%\WindowsApps that hold one, except a version the query listed with another status.
    This PC's architecture comes first (x64, then x86 on an x64 PC; arm64, x64, x86 on an ARM64 PC),
    and within one the newest version, compared as a version and never as text.
.PARAMETER AppInstaller
    Get-RmmAppxPackage's result for Microsoft.DesktopAppInstaller.
.PARAMETER OSArchitecture
    Get-RmmOSArchitecture's result.
.RETURNS
    [pscustomobject[]] with Path, Version ([version]), Architecture and Source.
#>
function Get-RmmWingetCandidate {
    param (
        [Parameter(Mandatory = $true)]
        [object]$AppInstaller,

        [Parameter(Mandatory = $true)]
        [string]$OSArchitecture
    )

    $preference = @('x64', 'x86')
    if ($OSArchitecture -eq 'Arm64') {
        $preference = @('arm64', 'x64', 'x86')
    }
    elseif ($OSArchitecture -eq 'X86') {
        $preference = @('x86')
    }

    $found = @()
    $rejected = @()
    foreach ($package in @($AppInstaller.Packages)) {
        $architecture = "$($package.Architecture)".ToLowerInvariant()
        if ($package.Status -ne 'Ok') {
            $rejected += ('{0}_{1}' -f $package.Version, $architecture)
            continue
        }
        if ([string]::IsNullOrWhiteSpace($package.InstallLocation) -or $null -eq $package.Version) {
            continue
        }
        $path = Join-Path $package.InstallLocation 'winget.exe'
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $found += [pscustomobject]@{ Path = $path; Version = $package.Version; Architecture = $architecture; Source = 'Get-AppxPackage -AllUsers' }
        }
    }

    if ($found.Count -eq 0) {
        $windowsApps = Get-RmmWindowsAppsDirectory
        if ($windowsApps) {
            foreach ($folder in @(Get-ChildItem -LiteralPath $windowsApps -Directory -Filter 'Microsoft.DesktopAppInstaller_*' -ErrorAction SilentlyContinue)) {
                if ($folder.Name -notmatch '^Microsoft\.DesktopAppInstaller_(?<version>\d+(\.\d+){1,3})_(?<architecture>x64|arm64|x86)__8wekyb3d8bbwe$') {
                    continue
                }
                $version = [version]$Matches['version']
                $architecture = $Matches['architecture'].ToLowerInvariant()
                if ($rejected -contains ('{0}_{1}' -f $version, $architecture)) {
                    continue
                }
                $path = Join-Path $folder.FullName 'winget.exe'
                if (Test-Path -LiteralPath $path -PathType Leaf) {
                    $found += [pscustomobject]@{ Path = $path; Version = $version; Architecture = $architecture; Source = 'WindowsApps folder' }
                }
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

<#
.SYNOPSIS
    Runs a program with a time limit and returns its exit code and output.
.DESCRIPTION
    Standard input is closed at once, so a program that asks for input cannot wait for it. At the
    time limit the program is stopped.
.PARAMETER FilePath
    The program.
.PARAMETER ArgumentList
    Its arguments (none may contain spaces or quotes).
.PARAMETER TimeoutSeconds
    The time limit.
.RETURNS
    [pscustomobject] with ExitCode ([int], $null when it did not finish), TimedOut, LaunchError
    ($null, or why it could not be started), LaunchErrorCode, Output ([string[]], standard output
    then standard error, without empty lines) and DurationSeconds.
#>
function Invoke-RmmTimedProcess {
    param (
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $false)]
        [string[]]$ArgumentList = @(),

        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds
    )

    $result = [pscustomobject]@{ ExitCode = $null; TimedOut = $false; LaunchError = $null; LaunchErrorCode = $null; Output = @(); DurationSeconds = 0 }
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = (@($ArgumentList) -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $startInfo.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $process = [System.Diagnostics.Process]::Start($startInfo)
    }
    catch {
        $exception = $_.Exception
        while ($null -ne $exception -and $exception -isnot [System.ComponentModel.Win32Exception]) {
            $exception = $exception.InnerException
        }
        if ($null -eq $exception) {
            $exception = $_.Exception
        }
        else {
            $result.LaunchErrorCode = $exception.NativeErrorCode
        }
        $result.LaunchError = $exception.Message
        return $result
    }
    try {
        $process.StandardInput.Close()
    }
    catch {
        # It has already exited.
    }
    $standardOutput = $process.StandardOutput.ReadToEndAsync()
    $standardError = $process.StandardError.ReadToEndAsync()
    if ($process.WaitForExit($TimeoutSeconds * 1000)) {
        $result.ExitCode = $process.ExitCode
    }
    else {
        $result.TimedOut = $true
        try {
            $process.Kill()
        }
        catch {
            # It exited in between.
        }
        [void]$process.WaitForExit(5000)
    }
    $text = ''
    foreach ($reader in @($standardOutput, $standardError)) {
        try {
            if ($reader.Wait(5000)) {
                $text += [string]$reader.Result + "`n"
            }
        }
        catch {
            # The pipe broke when the program was stopped.
        }
    }
    $stopwatch.Stop()
    $result.DurationSeconds = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
    $result.Output = @($text -split '\r?\n' | Where-Object { $_.Trim().Length -gt 0 } | ForEach-Object { $_.Trim() })
    try {
        $process.Dispose()
    }
    catch {
    }
    return $result
}

<#
.SYNOPSIS
    Describes a process exit code in hex, with its name when it is one winget's launch often ends
    with.
#>
function Format-RmmExitCode {
    param (
        [Parameter(Mandatory = $true)]
        [int]$ExitCode
    )

    $text = '0x{0:X8} ({1})' -f $ExitCode, $ExitCode
    switch ($ExitCode) {
        -1073741515 { $text += ', STATUS_DLL_NOT_FOUND: a DLL it needs is missing; outside its package, as SYSTEM, a missing Microsoft Visual C++ 2015-2022 runtime is a reported cause' }
        -1073741502 { $text += ', STATUS_DLL_INIT_FAILED' }
        -1073741819 { $text += ', STATUS_ACCESS_VIOLATION' }
    }
    return $text
}

<#
.SYNOPSIS
    Checks that the machine-wide winget.exe prints its version.
.DESCRIPTION
    Runs `winget.exe --version` for each of Get-RmmWingetCandidate's files, best first, each with
    the time limit, and stops at the first that prints a version and exits 0.
.PARAMETER Candidate
    Get-RmmWingetCandidate's result.
.PARAMETER TimeoutSeconds
    The time limit for each.
.RETURNS
    [pscustomobject] with State ('ok' when the first runs, 'fallback' when a later one does,
    'timedout' when none does and the first reached the time limit, 'failed' when none does,
    'notfound' when there is no winget.exe), Version (what the one that ran printed, or $null),
    Path (the one that ran, or the first) and Lines (one per file tried).
#>
function Test-RmmWingetLaunch {
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Candidate,

        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds
    )

    $result = [pscustomobject]@{ State = 'notfound'; Version = $null; Path = $null; Lines = @() }
    if ($Candidate.Count -eq 0) {
        $result.Lines = @('winget: no machine-wide winget.exe was found (no App Installer with status Ok for this PC''s architecture, and none under %ProgramFiles%\WindowsApps).')
        return $result
    }

    $lines = @()
    $firstState = $null
    $index = 0
    foreach ($entry in $Candidate) {
        $index++
        $run = Invoke-RmmTimedProcess -FilePath $entry.Path -ArgumentList @('--version') -TimeoutSeconds $TimeoutSeconds
        $printed = @($run.Output | Where-Object { $_ -match '^v?\d+(\.\d+)+' }) | Select-Object -First 1
        $state = 'failed'
        if ($run.LaunchError) {
            $code = ''
            if ($null -ne $run.LaunchErrorCode) {
                $code = " (error $($run.LaunchErrorCode))"
            }
            $outcome = "could not be started{0}: {1}" -f $code, $run.LaunchError
        }
        elseif ($run.TimedOut) {
            $state = 'timedout'
            $outcome = "did not finish within {0} seconds and was stopped" -f $TimeoutSeconds
        }
        elseif ($run.ExitCode -eq 0 -and $printed) {
            $state = 'ok'
            $outcome = "printed {0} (exit 0, {1} s)" -f $printed, $run.DurationSeconds
        }
        else {
            $said = ''
            $firstLine = @($run.Output) | Select-Object -First 1
            if ($firstLine) {
                $said = ": $firstLine"
            }
            $outcome = "exited with {0} after {1} s{2}" -f (Format-RmmExitCode -ExitCode ([int]$run.ExitCode)), $run.DurationSeconds, $said
        }
        $lines += ('winget: {0} (App Installer {1}, {2}) --version {3}' -f $entry.Path, $entry.Version, $entry.Architecture, $outcome)
        if ($null -eq $firstState) {
            $firstState = $state
            $result.Path = $entry.Path
        }
        if ($state -eq 'ok') {
            $result.Version = $printed
            $result.Path = $entry.Path
            if ($index -eq 1) {
                $result.State = 'ok'
            }
            else {
                $result.State = 'fallback'
            }
            $result.Lines = $lines
            return $result
        }
    }
    if ($firstState -eq 'timedout') {
        $result.State = 'timedout'
    }
    else {
        $result.State = 'failed'
    }
    $result.Lines = $lines
    return $result
}

<#
.SYNOPSIS
    Reads whether Winget-AutoUpdate is installed, and its at-logon settings, from the registry.
.DESCRIPTION
    Installed when its MSI's uninstall entry (DisplayName Winget-AutoUpdate, in either uninstall
    hive) or its settings key HKLM:\SOFTWARE\Romanitho\Winget-AutoUpdate exists. From the settings
    key: InstallLocation (where its logs are) and WAU_UpdatesAtLogon, which WAU's MSI reads back on
    an upgrade. From HKLM:\SOFTWARE\Policies\Romanitho\Winget-AutoUpdate: the Group Policy
    WAU_UpdatesAtLogon, which WAU's daily Winget-AutoUpdate-Policies task applies to the task's
    triggers.
.RETURNS
    [pscustomobject] with Installed, Version, InstallLocation, UpdatesAtLogon, PolicyUpdatesAtLogon
    and Error ($null, or why the registry could not be read).
#>
function Get-RmmWauInstall {
    $result = [pscustomobject]@{ Installed = $false; Version = $null; InstallLocation = $null; UpdatesAtLogon = $null; PolicyUpdatesAtLogon = $null; Error = $null }
    try {
        foreach ($root in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
            if ($result.Installed) {
                break
            }
            if (-not (Test-Path -LiteralPath $root)) {
                continue
            }
            foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
                $entry = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
                if ($entry -and "$($entry.DisplayName)" -like 'Winget-AutoUpdate*') {
                    $result.Installed = $true
                    if ($entry.DisplayVersion) {
                        $result.Version = [string]$entry.DisplayVersion
                    }
                    break
                }
            }
        }
        $settingsKey = 'HKLM:\SOFTWARE\Romanitho\Winget-AutoUpdate'
        if (Test-Path -LiteralPath $settingsKey) {
            $result.Installed = $true
            $settings = Get-ItemProperty -LiteralPath $settingsKey -ErrorAction SilentlyContinue
            if ($settings) {
                $result.InstallLocation = [string]$settings.InstallLocation
                $result.UpdatesAtLogon = $settings.WAU_UpdatesAtLogon
                if (-not $result.Version -and $settings.ProductVersion) {
                    $result.Version = [string]$settings.ProductVersion
                }
            }
        }
        $policyKey = 'HKLM:\SOFTWARE\Policies\Romanitho\Winget-AutoUpdate'
        if (Test-Path -LiteralPath $policyKey) {
            $policy = Get-ItemProperty -LiteralPath $policyKey -ErrorAction SilentlyContinue
            if ($policy) {
                $result.PolicyUpdatesAtLogon = $policy.WAU_UpdatesAtLogon
            }
        }
    }
    catch {
        $result.Error = $_.Exception.Message
    }
    return $result
}

<#
.SYNOPSIS
    Describes one scheduled-task trigger in a few words.
.DESCRIPTION
    The trigger's kind from its CIM class (MSFT_TaskWeeklyTrigger reads 'Weekly',
    MSFT_TaskLogonTrigger 'Logon'), the days of a weekly trigger (its DaysOfWeek bit mask: 1 Sunday,
    2 Monday, 4 Tuesday ... 64 Saturday), when it starts, and '(disabled)' for a disabled trigger;
    as Format-ScheduledTaskTrigger in WingetAppSetup/Private/WauSupport.ps1 writes it.
#>
function Format-RmmTaskTrigger {
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
    Reads Winget-AutoUpdate's scheduled task, \WAU\Winget-AutoUpdate.
.DESCRIPTION
    Queried with -ErrorAction SilentlyContinue and the error read from -ErrorVariable, as the
    installer's Get-WauTaskHealth does: 'not found' (CmdletizationQuery_NotFound) means there is no
    task, any other error that it could not be read.
.RETURNS
    [pscustomobject] with Exists, CheckFailed, Error, State, Triggers (Text, IsLogon, Enabled),
    LastRunTime, LastTaskResult and NextRunTime.
#>
function Get-RmmWauTask {
    $result = [pscustomobject]@{ Exists = $false; CheckFailed = $false; Error = $null; State = $null; Triggers = @(); LastRunTime = $null; LastTaskResult = $null; NextRunTime = $null }
    $task = $null
    $taskErrors = @()
    try {
        $task = @(Get-ScheduledTask -TaskPath '\WAU\' -TaskName 'Winget-AutoUpdate' -ErrorAction SilentlyContinue -ErrorVariable taskErrors) | Select-Object -First 1
    }
    catch {
        $taskErrors = @($_)
    }
    if (-not $task) {
        $failure = @($taskErrors | Where-Object { "$($_.FullyQualifiedErrorId)" -notlike 'CmdletizationQuery_NotFound*' }) | Select-Object -First 1
        if ($failure) {
            $result.CheckFailed = $true
            $result.Error = $failure.Exception.Message
        }
        return $result
    }

    $result.Exists = $true
    $result.State = "$($task.State)"
    $result.Triggers = @(foreach ($trigger in @($task.Triggers)) {
            if ($null -eq $trigger) {
                continue
            }
            [pscustomobject]@{
                Text    = (Format-RmmTaskTrigger -Trigger $trigger)
                IsLogon = ("$($trigger.CimClass.CimClassName)" -eq 'MSFT_TaskLogonTrigger')
                Enabled = ($trigger.Enabled -ne $false)
            }
        })
    $info = $null
    try {
        $info = Get-ScheduledTaskInfo -TaskPath '\WAU\' -TaskName 'Winget-AutoUpdate' -ErrorAction SilentlyContinue
    }
    catch {
        $info = $null
    }
    if ($info) {
        # The task scheduler gives 1999-11-30 as the last run time of a task that has never run.
        if ($info.LastRunTime -and ([datetime]$info.LastRunTime).Year -ge 2000) {
            $result.LastRunTime = [datetime]$info.LastRunTime
        }
        if ($null -ne $info.LastTaskResult) {
            $result.LastTaskResult = [int64]$info.LastTaskResult
        }
        if ($info.NextRunTime) {
            $result.NextRunTime = [datetime]$info.NextRunTime
        }
    }
    return $result
}

<#
.SYNOPSIS
    Formats a task's last result in hex, with the task scheduler's own codes named.
#>
function Format-RmmTaskResult {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $Result
    )

    if ($null -eq $Result) {
        return 'unknown'
    }
    $text = '0x{0:X8}' -f ([int64]$Result -band 4294967295)
    switch ([int64]$Result) {
        0 { $text += ' (success)' }
        267009 { $text += ' (running now)' }
        267011 { $text += ' (has not run yet)' }
        267014 { $text += ' (stopped before it finished)' }
    }
    return $text
}

<#
.SYNOPSIS
    Returns the path of Winget-AutoUpdate's log, updates.log.
.DESCRIPTION
    <InstallLocation>\logs\updates.log, where InstallLocation is what WAU's MSI recorded; by default
    %ProgramFiles%\Winget-AutoUpdate (from ProgramW6432 first, the real Program Files also in a
    32-bit process).
.PARAMETER InstallLocation
    Get-RmmWauInstall's InstallLocation, or $null.
.RETURNS
    [string] or $null.
#>
function Get-RmmWauLogPath {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$InstallLocation
    )

    $folder = "$InstallLocation".Trim()
    if (-not $folder) {
        $programFiles = $env:ProgramW6432
        if ([string]::IsNullOrWhiteSpace($programFiles)) {
            $programFiles = $env:ProgramFiles
        }
        if ([string]::IsNullOrWhiteSpace($programFiles)) {
            return $null
        }
        $folder = Join-Path $programFiles 'Winget-AutoUpdate'
    }
    return (Join-Path (Join-Path $folder 'logs') 'updates.log')
}

<#
.SYNOPSIS
    Reads a text file another process may be writing, at most its last MaxBytes.
.DESCRIPTION
    Opened with read, write and delete sharing, so a log WAU holds open can still be read. The
    encoding comes from the byte order mark (UTF-8, UTF-16 LE or BE), else UTF-16 LE when the first
    characters have zero high bytes (Windows PowerShell's Out-File, which WAU writes its log with,
    writes UTF-16), else UTF-8.
#>
function Read-RmmTextFile {
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
        if ($length - $preamble -gt $MaxBytes) {
            $start = $length - $MaxBytes
            if ($twoByte -and (($start - $preamble) % 2) -ne 0) {
                $start++
            }
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
        return $encoding.GetString($buffer, 0, $offset)
    }
    finally {
        $stream.Dispose()
    }
}

<#
.SYNOPSIS
    Picks the lines of WAU's updates.log that tell what its runs did.
.DESCRIPTION
    Each run's header ('CHECK FOR APP UPDATES', with its date), the WinGet MSIXBundle lines of WAU's
    prerequisite step (which installs the newest winget for the machine), 'WinGet installed
    version', 'No update found' (logged also when `winget upgrade` failed, so the up to 2 lines
    of winget output that follow it are kept with it), source resets, and lines that say error,
    fail, critical or timeout.
.PARAMETER Path
    The log (Get-RmmWauLogPath).
.PARAMETER MaximumMatches
    How many of the last matching entries to return.
.RETURNS
    [pscustomobject] with Exists, Error, MatchCount (entries that match), Entries (the last
    MaximumMatches, each a [string[]] of its line and the lines kept with it) and
    WingetInstallCount (how many 'Installing WinGet MSIXBundle' lines the log has).
#>
function Read-RmmWauLogMatch {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Path,

        [Parameter(Mandatory = $false)]
        [int]$MaximumMatches = 20
    )

    $result = [pscustomobject]@{ Exists = $false; Error = $null; MatchCount = 0; Entries = @(); WingetInstallCount = 0 }
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $result
    }
    $result.Exists = $true
    try {
        $text = Read-RmmTextFile -Path $Path
    }
    catch {
        $result.Error = $_.Exception.Message
        return $result
    }

    $pattern = 'CHECK FOR APP UPDATES|WinGet MSIXBundle|WinGet installed version|WinGet is not installed|No update found|sources? reset|Critical|\berror\b|\bfail(s|ed|ure)?\b|Timeout'
    $entryStart = '^\s*(\d{1,2}:\d{2}:\d{2}\s+-\s|#)'
    $lines = @($text -split '\r?\n')
    $entries = New-Object System.Collections.Generic.List[object]
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $line = $lines[$index].TrimEnd()
        if ($line -match 'Installing WinGet MSIXBundle') {
            $result.WingetInstallCount++
        }
        if ($line -notmatch $pattern) {
            continue
        }
        $entry = @($line.Trim())
        if ($line -match 'No update found') {
            # The winget output WAU logs after it, up to the next entry; those lines are this
            # entry's, not entries of their own.
            $kept = 0
            $next = $index + 1
            while ($next -lt $lines.Count -and $kept -lt 2) {
                $following = $lines[$next].Trim()
                if ($following -match $entryStart) {
                    break
                }
                if ($following.Length -gt 0) {
                    $entry += $following
                    $kept++
                }
                $next++
            }
            $index = $next - 1
        }
        $entries.Add($entry)
    }
    $result.MatchCount = $entries.Count
    if ($MaximumMatches -gt 0 -and $entries.Count -gt 0) {
        $first = [Math]::Max(0, $entries.Count - $MaximumMatches)
        $result.Entries = @(for ($index = $first; $index -lt $entries.Count; $index++) {
                , $entries[$index]
            })
    }
    return $result
}

<#
.SYNOPSIS
    The probe: reads everything, decides whether this PC is healthy, and returns the report.
.PARAMETER WingetTimeoutSeconds
    The time limit for each `winget.exe --version`.
.PARAMETER LogMatchCount
    How many of the last matching updates.log entries to show.
.PARAMETER Note
    A line to put after the first one (how the probe was started), or $null.
.RETURNS
    [pscustomobject] with Lines ([string[]], the HEALTH line last), Problems ([string[]]) and
    ExitCode (0 healthy, 1 unhealthy).
#>
function Invoke-RmmFleetHealthProbe {
    param (
        [Parameter(Mandatory = $false)]
        [int]$WingetTimeoutSeconds = 30,

        [Parameter(Mandatory = $false)]
        [int]$LogMatchCount = 20,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Note
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $problems = New-Object System.Collections.Generic.List[string]
    $reasons = New-Object System.Collections.Generic.List[string]
    $computer = Get-RmmComputerName
    $bits = '32-bit'
    if ([Environment]::Is64BitProcess) {
        $bits = '64-bit'
    }
    $lines.Add(('winget fleet health on {0}: run as {1}, PowerShell {2} ({3}), {4} process.' -f $computer, (Get-RmmAccountName), $PSVersionTable.PSVersion, $PSVersionTable.PSEdition, $bits))
    if ($Note) {
        $lines.Add($Note)
    }

    if (-not (Test-RmmElevated)) {
        $problems.Add('not-elevated')
        $reasons.Add('the probe did not run as SYSTEM or as an elevated administrator, so it could not read every account''s packages or the scheduled task: deploy it as the System user')
        $lines.Add('Not elevated: run this probe as SYSTEM (Endpoint Central: Computer Configuration, run as the System user) or from an elevated PowerShell.')
    }

    $osArchitecture = Get-RmmOSArchitecture

    # App Installer.
    $appInstaller = Get-RmmAppxPackage -Name 'Microsoft.DesktopAppInstaller'
    $appInstallerValue = 'none'
    if ($appInstaller.Error) {
        $appInstallerValue = 'unknown'
        $lines.Add("App Installer (Microsoft.DesktopAppInstaller): could not be listed for all accounts: $($appInstaller.Error)")
    }
    elseif (@($appInstaller.Packages).Count -eq 0) {
        $lines.Add('App Installer (Microsoft.DesktopAppInstaller): not installed for any account.')
    }
    else {
        $sorted = @($appInstaller.Packages | Sort-Object -Property @{ Expression = { $_.Version }; Descending = $true })
        $appInstallerValue = $sorted[0].VersionText
        foreach ($package in $sorted) {
            $lines.Add(('App Installer {0}' -f (Format-RmmAppxPackage -Package $package)))
        }
    }

    # Windows App Runtime.
    $runtime = Get-RmmAppxPackage -Name $script:RmmRuntimeName
    $requirement = '{0} >= {1} for {2}' -f $script:RmmRuntimeName, $script:RmmRuntimeMinimumVersion, $osArchitecture
    $runtimeValue = 'missing'
    if ($runtime.Error) {
        $runtimeValue = 'unknown'
        $lines.Add("Windows App Runtime: could not be listed for all accounts ($($runtime.Error)); winget 1.12 and later need $requirement.")
    }
    else {
        $found = 'none installed'
        if (@($runtime.Packages).Count -gt 0) {
            $found = (@($runtime.Packages | Sort-Object -Property @{ Expression = { $_.Version }; Descending = $true } | ForEach-Object { '{0} {1}' -f $_.Architecture, $_.VersionText }) -join ', ')
        }
        $suitable = @($runtime.Packages | Where-Object { $_.Architecture -eq $osArchitecture -and $null -ne $_.Version -and $_.Version -ge $script:RmmRuntimeMinimumVersion })
        if ($suitable.Count -gt 0) {
            $runtimeValue = 'present'
            $lines.Add("Windows App Runtime: present ($requirement; found $found).")
        }
        else {
            $lines.Add("Windows App Runtime: missing (winget 1.12 and later need $requirement; found $found).")
        }
    }

    # winget.
    $candidates = @(Get-RmmWingetCandidate -AppInstaller $appInstaller -OSArchitecture $osArchitecture)
    $winget = Test-RmmWingetLaunch -Candidate $candidates -TimeoutSeconds $WingetTimeoutSeconds
    foreach ($line in @($winget.Lines)) {
        $lines.Add($line)
    }
    if ($winget.State -eq 'notfound') {
        $problems.Add('winget-notfound')
        $reasons.Add('no machine-wide winget.exe was found')
    }
    elseif ($winget.State -ne 'ok') {
        $problems.Add('winget-launch')
        if ($winget.State -eq 'fallback') {
            $reasons.Add("the newest machine-wide winget.exe does not run; an older one does ($($winget.Path)), which the installer as SYSTEM falls back to and Winget-AutoUpdate does not")
        }
        else {
            $reasons.Add('winget.exe does not run, so neither the installer as SYSTEM nor Winget-AutoUpdate can install or update anything')
        }
    }

    # Winget-AutoUpdate.
    $wau = Get-RmmWauInstall
    $task = Get-RmmWauTask
    $wauInstalled = ($wau.Installed -or $task.Exists)
    $wauValue = 'none'
    if ($wau.Error) {
        $lines.Add("Winget-AutoUpdate: its registry entries could not be read: $($wau.Error)")
    }
    if ($wauInstalled) {
        $wauValue = 'installed'
        if ($wau.Version) {
            $wauValue = $wau.Version
        }
        $details = @()
        if ($wau.Version) {
            $details += "version $($wau.Version)"
        }
        if ($null -ne $wau.UpdatesAtLogon) {
            $details += "WAU_UpdatesAtLogon = $($wau.UpdatesAtLogon)"
        }
        if ($null -ne $wau.PolicyUpdatesAtLogon) {
            $policyText = "Group Policy WAU_UpdatesAtLogon = $($wau.PolicyUpdatesAtLogon)"
            if ("$($wau.PolicyUpdatesAtLogon)" -eq '1') {
                $policyText += ' (WAU''s Winget-AutoUpdate-Policies task puts the at-logon trigger back every day)'
            }
            $details += $policyText
        }
        if (-not $wau.Installed) {
            $details += 'no uninstall entry or settings key, only its task'
        }
        $detailText = ''
        if ($details.Count -gt 0) {
            $detailText = ': ' + ($details -join '; ')
        }
        $lines.Add("Winget-AutoUpdate: installed$detailText.")
    }
    elseif (-not $wau.Error) {
        $lines.Add('Winget-AutoUpdate: not installed.')
    }

    $taskValue = '-'
    $resultValue = '-'
    $logonValue = '-'
    if ($task.CheckFailed) {
        $taskValue = 'unknown'
        $lines.Add("WAU task \WAU\Winget-AutoUpdate: could not be read: $($task.Error)")
    }
    elseif (-not $task.Exists) {
        if ($wauInstalled) {
            $taskValue = 'missing'
            $lines.Add('WAU task \WAU\Winget-AutoUpdate: does not exist.')
        }
    }
    else {
        $taskValue = $task.State
        $triggers = 'none'
        if (@($task.Triggers).Count -gt 0) {
            $triggers = (@($task.Triggers | ForEach-Object { $_.Text }) -join '; ')
        }
        $lastRun = 'never'
        if ($task.LastRunTime) {
            $lastRun = '{0:yyyy-MM-dd HH:mm}' -f $task.LastRunTime
        }
        $nextRun = 'none scheduled'
        if ($task.NextRunTime) {
            $nextRun = '{0:yyyy-MM-dd HH:mm}' -f $task.NextRunTime
        }
        if ($null -ne $task.LastTaskResult) {
            $resultValue = '0x{0:X8}' -f ([int64]$task.LastTaskResult -band 4294967295)
        }
        $logonValue = 'no'
        if (@($task.Triggers | Where-Object { $_.IsLogon }).Count -gt 0) {
            $logonValue = 'yes'
        }
        $lines.Add(('WAU task \WAU\Winget-AutoUpdate: state {0}; triggers: {1}; at-logon trigger: {2}; last run {3}, result {4}; next run {5}.' -f $task.State, $triggers, $logonValue, $lastRun, (Format-RmmTaskResult -Result $task.LastTaskResult), $nextRun))
    }

    if ($wauInstalled) {
        if ($runtimeValue -eq 'missing') {
            $problems.Add('runtime-missing')
            $reasons.Add("Winget-AutoUpdate is installed and $requirement is not, so its next run can install a winget that cannot start")
        }
        elseif ($runtimeValue -eq 'unknown') {
            $problems.Add('runtime-unknown')
            $reasons.Add('Winget-AutoUpdate is installed and whether the Windows App Runtime it needs is installed could not be read')
        }
        if ($task.CheckFailed) {
            $problems.Add('wau-task-unknown')
            $reasons.Add('Winget-AutoUpdate''s task could not be read')
        }
        elseif (-not $task.Exists) {
            $problems.Add('wau-task-missing')
            $reasons.Add('Winget-AutoUpdate is installed but its task does not exist, so it never runs')
        }
        elseif ($task.State -eq 'Disabled') {
            $problems.Add('wau-task-disabled')
            $reasons.Add('Winget-AutoUpdate''s task is disabled, so it never runs')
        }
        elseif (@($task.Triggers | Where-Object { $_.Enabled }).Count -eq 0) {
            $problems.Add('wau-task-no-trigger')
            $reasons.Add('Winget-AutoUpdate''s task has no enabled trigger, so it never runs on its own')
        }
    }
    if ($logonValue -eq 'yes') {
        $problems.Add('wau-logon-trigger')
        $reasons.Add('Winget-AutoUpdate''s task still runs at every sign-in, when a technician signs in to re-run the installer (fix: rmm/Repair-WauLogonTrigger.ps1)')
    }

    # WAU's log.
    $installsValue = '-'
    if ($wauInstalled) {
        $logPath = Get-RmmWauLogPath -InstallLocation $wau.InstallLocation
        $log = Read-RmmWauLogMatch -Path $logPath -MaximumMatches $LogMatchCount
        if (-not $log.Exists) {
            $lines.Add("WAU log: $logPath does not exist (WAU creates it on its first run).")
        }
        elseif ($log.Error) {
            $lines.Add("WAU log: $logPath could not be read: $($log.Error)")
        }
        else {
            $installsValue = [string]$log.WingetInstallCount
            $shown = @($log.Entries).Count
            $lines.Add(("WAU log: {0}: {1} matching entries, the last {2} below; 'Installing WinGet MSIXBundle' {3} times." -f $logPath, $log.MatchCount, $shown, $log.WingetInstallCount))
            foreach ($entry in @($log.Entries)) {
                $first = $true
                foreach ($line in @($entry)) {
                    if ($first) {
                        $lines.Add("WAU log | $line")
                        $first = $false
                    }
                    else {
                        $lines.Add("WAU log |     $line")
                    }
                }
            }
        }
    }

    $status = 'healthy'
    $exitCode = 0
    $problemValue = 'none'
    if ($problems.Count -gt 0) {
        $status = 'unhealthy'
        $exitCode = 1
        $problemValue = ($problems -join ',')
        $lines.Add('Unhealthy: ' + ($reasons -join '; ') + '.')
    }
    else {
        $lines.Add('Healthy.')
    }

    $health = @(
        ('status=' + $status),
        ('problems=' + $problemValue),
        ('computer=' + (ConvertTo-RmmResultValue -Value $computer)),
        ('appinstaller=' + (ConvertTo-RmmResultValue -Value $appInstallerValue)),
        ('runtime=' + $runtimeValue),
        ('winget=' + $winget.State),
        ('wingetversion=' + (ConvertTo-RmmResultValue -Value ("$($winget.Version)" -replace '^v', ''))),
        ('wau=' + (ConvertTo-RmmResultValue -Value $wauValue)),
        ('wautask=' + (ConvertTo-RmmResultValue -Value $taskValue)),
        ('wauresult=' + $resultValue),
        ('logontrigger=' + $logonValue),
        ('wauwingetinstalls=' + $installsValue)
    )
    $lines.Add('HEALTH: ' + ($health -join ' '))

    return [pscustomobject]@{
        # One line per check: an error message's own line breaks are joined.
        Lines    = @($lines.ToArray() | ForEach-Object { $_ -replace '\s*[\r\n]+\s*', ' ' })
        Problems = $problems.ToArray()
        ExitCode = $exitCode
    }
}

<#
.SYNOPSIS
    Runs the probe in the right PowerShell and returns its report and exit code.
.DESCRIPTION
    In a 32-bit PowerShell on 64-bit Windows, or in PowerShell 7, runs this script again in 64-bit
    Windows PowerShell (Invoke-RmmRelaunchWhenNeeded) and passes its lines and exit code on.
    Otherwise runs the probe here. Whatever goes wrong, the result ends with a HEALTH line.
.PARAMETER ScriptPath
    This script's path, for the relaunch.
.PARAMETER ForwardedArguments
    The arguments the relaunch passes on (ConvertTo-RmmForwardedArgument).
.PARAMETER Relaunched
    This is the relaunched run: never relaunch again.
.RETURNS
    [pscustomobject] with Lines and ExitCode.
#>
function Invoke-RmmFleetHealthMain {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ScriptPath,

        [Parameter(Mandatory = $false)]
        [string[]]$ForwardedArguments = @(),

        [Parameter(Mandatory = $false)]
        [switch]$Relaunched,

        [Parameter(Mandatory = $false)]
        [int]$WingetTimeoutSeconds = 30,

        [Parameter(Mandatory = $false)]
        [int]$LogMatchCount = 20
    )

    $note = $null
    if ($Relaunched) {
        $note = 'Run again in 64-bit Windows PowerShell by the probe itself.'
    }
    else {
        $relaunch = Invoke-RmmRelaunchWhenNeeded -ScriptPath $ScriptPath -ForwardedArguments $ForwardedArguments -ResultPrefix 'HEALTH' -FailureStatus 'unhealthy' -FailureProblem 'probe-error'
        if ($relaunch) {
            return $relaunch
        }
    }
    try {
        return (Invoke-RmmFleetHealthProbe -WingetTimeoutSeconds $WingetTimeoutSeconds -LogMatchCount $LogMatchCount -Note $note)
    }
    catch {
        return (New-RmmFailureResult -Message "The probe stopped on an unexpected error: $($_.Exception.Message)" -ResultPrefix 'HEALTH' -FailureStatus 'unhealthy' -FailureProblem 'probe-error')
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $fleetHealth = Invoke-RmmFleetHealthMain -ScriptPath $PSCommandPath -ForwardedArguments (ConvertTo-RmmForwardedArgument -BoundParameters $PSBoundParameters) -Relaunched:$Relaunched -WingetTimeoutSeconds $WingetTimeoutSeconds -LogMatchCount $LogMatchCount
    foreach ($fleetHealthLine in @($fleetHealth.Lines)) {
        Write-Output $fleetHealthLine
    }
    exit ([int]$fleetHealth.ExitCode)
}
