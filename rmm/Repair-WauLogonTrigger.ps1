<#
.SYNOPSIS
    Removes Winget-AutoUpdate's at-logon trigger and sets WAU_UpdatesAtLogon to 0 on a PC that
    already has WAU: a one-off fix to push from an RMM (Endpoint Central, run as SYSTEM).
.DESCRIPTION
    Installer versions before the WAU fixes did not pass UPDATESATLOGON, so WAU 2.12.0 defaulted it
    to 1 and its SYSTEM task \WAU\Winget-AutoUpdate also runs at every sign-in. That run
    re-provisions App Installer and resets winget's sources exactly when a technician signs in to
    re-run the installer. New installs pass UPDATESATLOGON=0, and the installer removes the trigger
    when it runs (Disable-WauLogonTrigger, WingetAppSetup/Private/WauSupport.ps1); this script does
    the same on PCs deployed earlier, without a full installer run. Deploy it from ManageEngine
    Endpoint Central as a Computer Configuration custom script run as the System user, frequency
    Once, success exit code 0. rmm/Get-WingetFleetHealth.ps1 finds the PCs that need it (problem
    wau-logon-trigger).

    It changes two things, each only when needed, and nothing else:
      1. the task's triggers: every at-logon trigger is removed and the others (WAU's schedule) are
         kept. A task whose only trigger is the at-logon one is left alone (WAU would never run
         again), and so is a task without one.
      2. WAU_UpdatesAtLogon = 0 (REG_DWORD) under HKLM:\SOFTWARE\Romanitho\Winget-AutoUpdate,
         which WAU's MSI reads back when WAU is upgraded or repaired, so the trigger does not come
         back with it. Written only when that key exists.
    Each change is read back. -WhatIf shows what would change and changes nothing.

    It writes one line per step and ends with one machine-parsable line:

      REPAIR: status=<fixed|unchanged|whatif|failed> problems=<codes|none> computer=<name>
              logontrigger=<removed|absent|no-task|only-trigger|would-remove|still-present|failed|unknown>
              updatesatlogon=<set-0|already-0|would-set-0|no-key|failed|unknown> policy=<value|none>

    (all on one line). Failed (exit code 1) when the PC still runs WAU at sign-in afterwards, or
    may again:
      not-elevated           not run as SYSTEM or elevated: nothing was read or changed.
      task-unknown           the task could not be read.
      logon-only-trigger     the at-logon trigger is the task's only one: reinstall WAU with
                             UPDATESATLOGON=0 (re-running winget-app-install.ps1 does that only
                             when it installs or upgrades WAU).
      trigger-not-removed    Set-ScheduledTask failed, or the trigger was still there afterwards.
      setting-not-written    WAU_UpdatesAtLogon could not be set to 0.
      policy-logon           Group Policy sets WAU_UpdatesAtLogon = 1
                             (HKLM:\SOFTWARE\Policies\Romanitho\Winget-AutoUpdate): WAU's daily
                             Winget-AutoUpdate-Policies task puts the trigger back. Change the
                             policy.
      repair-error           the script itself could not run.

    Run by a 32-bit PowerShell on 64-bit Windows (Endpoint Central's agent is 32-bit), or by
    PowerShell 7, it runs itself again in 64-bit Windows PowerShell (through
    %SystemRoot%\Sysnative from a 32-bit process), where HKLM:\SOFTWARE is the registry WAU reads.
.PARAMETER Relaunched
    Set by the script itself when it runs itself again in 64-bit Windows PowerShell.
.NOTES
    Exit codes: 0 when no at-logon trigger is left and none will come back (also when WAU is not
    installed, and for -WhatIf), 1 otherwise (the REPAIR line's problems say why).
    Runs under Windows PowerShell 5.1: ASCII only, no PowerShell-7-only syntax.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param (
    [Parameter(Mandatory = $false)]
    [switch]$Relaunched
)

# ---- Shared with rmm/Get-WingetFleetHealth.ps1 (tests keep the two copies identical) -------------

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

# ---- The repair -----------------------------------------------------------------------------------

<#
.SYNOPSIS
    Reads Winget-AutoUpdate's scheduled task, \WAU\Winget-AutoUpdate, as Get-ScheduledTask returns
    it (its triggers are what Set-ScheduledTask takes back).
.DESCRIPTION
    Queried with -ErrorAction SilentlyContinue and the error read from -ErrorVariable, as the
    installer's Get-WauTaskHealth does: 'not found' (CmdletizationQuery_NotFound) means there is no
    task, any other error that it could not be read.
.RETURNS
    [pscustomobject] with Task (or $null) and Error ($null, or why it could not be read).
#>
function Get-RmmWauScheduledTask {
    $task = $null
    $taskErrors = @()
    try {
        $task = @(Get-ScheduledTask -TaskPath '\WAU\' -TaskName 'Winget-AutoUpdate' -ErrorAction SilentlyContinue -ErrorVariable taskErrors) | Select-Object -First 1
    }
    catch {
        $taskErrors = @($_)
    }
    $failure = $null
    if (-not $task) {
        $failure = @($taskErrors | Where-Object { "$($_.FullyQualifiedErrorId)" -notlike 'CmdletizationQuery_NotFound*' }) | Select-Object -First 1
    }
    $message = $null
    if ($failure) {
        $message = $failure.Exception.Message
    }
    return [pscustomobject]@{ Task = $task; Error = $message }
}

<#
.SYNOPSIS
    Returns whether a scheduled-task trigger is an at-logon trigger.
#>
function Test-RmmLogonTrigger {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        $Trigger
    )

    return ($null -ne $Trigger -and "$($Trigger.CimClass.CimClassName)" -eq 'MSFT_TaskLogonTrigger')
}

<#
.SYNOPSIS
    Describes a trigger in a word or two: its kind, from its CIM class ('Weekly', 'Logon').
#>
function Get-RmmTriggerKind {
    param (
        [Parameter(Mandatory = $true)]
        $Trigger
    )

    $kind = "$($Trigger.CimClass.CimClassName)" -replace '^MSFT_Task', '' -replace 'Trigger$', ''
    if (-not $kind) {
        $kind = 'Unknown'
    }
    return $kind
}

<#
.SYNOPSIS
    The repair: removes the at-logon trigger and sets WAU_UpdatesAtLogon to 0 where needed, and
    returns the report.
.DESCRIPTION
    See the script's description. Supports -WhatIf: what would change is reported and nothing is.
.PARAMETER Note
    A line to put after the first one (how the script was started), or $null.
.RETURNS
    [pscustomobject] with Lines ([string[]], the REPAIR line last), Problems ([string[]]) and
    ExitCode (0 or 1).
#>
function Invoke-RmmWauLogonTriggerRepair {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Note
    )

    $taskLabel = '\WAU\Winget-AutoUpdate'
    $settingsKey = 'HKLM:\SOFTWARE\Romanitho\Winget-AutoUpdate'
    $policyKey = 'HKLM:\SOFTWARE\Policies\Romanitho\Winget-AutoUpdate'
    $lines = New-Object System.Collections.Generic.List[string]
    $problems = New-Object System.Collections.Generic.List[string]
    $computer = Get-RmmComputerName
    $bits = '32-bit'
    if ([Environment]::Is64BitProcess) {
        $bits = '64-bit'
    }
    $lines.Add(('Winget-AutoUpdate at-logon trigger repair on {0}: run as {1}, PowerShell {2} ({3}), {4} process.' -f $computer, (Get-RmmAccountName), $PSVersionTable.PSVersion, $PSVersionTable.PSEdition, $bits))
    if ($Note) {
        $lines.Add($Note)
    }

    $triggerValue = 'unknown'
    $settingValue = 'unknown'
    $policyValue = 'none'
    if (-not (Test-RmmElevated)) {
        $problems.Add('not-elevated')
        $lines.Add('Not elevated: run this script as SYSTEM (Endpoint Central: Computer Configuration, run as the System user) or from an elevated PowerShell. Nothing was read or changed.')
    }
    else {
        # 1. The task's at-logon trigger.
        $read = Get-RmmWauScheduledTask
        if ($read.Error) {
            $problems.Add('task-unknown')
            $lines.Add("The task $taskLabel could not be read: $($read.Error). Nothing was changed on it.")
        }
        elseif (-not $read.Task) {
            $triggerValue = 'no-task'
            $lines.Add("The task $taskLabel does not exist: there is no at-logon trigger to remove.")
        }
        else {
            $triggers = @($read.Task.Triggers | Where-Object { $null -ne $_ })
            $logonTriggers = @($triggers | Where-Object { Test-RmmLogonTrigger -Trigger $_ })
            $otherTriggers = @($triggers | Where-Object { -not (Test-RmmLogonTrigger -Trigger $_) })
            $keptText = (@($otherTriggers | ForEach-Object { Get-RmmTriggerKind -Trigger $_ }) -join ', ')
            if ($logonTriggers.Count -eq 0) {
                $triggerValue = 'absent'
                $lines.Add("The task $taskLabel has no at-logon trigger: nothing to remove.")
            }
            elseif ($otherTriggers.Count -eq 0) {
                $triggerValue = 'only-trigger'
                $problems.Add('logon-only-trigger')
                $lines.Add("The task $taskLabel has only its at-logon trigger, so it was left alone: without it Winget-AutoUpdate would never run. Reinstall Winget-AutoUpdate with UPDATESATLOGON=0 and a schedule (UPDATESINTERVAL), as winget-app-install.ps1 installs it.")
            }
            elseif ($PSCmdlet.ShouldProcess("scheduled task $taskLabel", "Remove its at-logon trigger and keep its other triggers ($keptText)")) {
                try {
                    Set-ScheduledTask -TaskPath '\WAU\' -TaskName 'Winget-AutoUpdate' -Trigger $otherTriggers -ErrorAction Stop | Out-Null
                    $after = Get-RmmWauScheduledTask
                    if ($after.Task -and @($after.Task.Triggers | Where-Object { Test-RmmLogonTrigger -Trigger $_ }).Count -eq 0) {
                        $triggerValue = 'removed'
                        $lines.Add("Removed the at-logon trigger from the task $taskLabel; it keeps its other triggers ($keptText).")
                    }
                    else {
                        $triggerValue = 'still-present'
                        $problems.Add('trigger-not-removed')
                        $lines.Add("Set-ScheduledTask reported no error, but reading the task $taskLabel back does not show it without its at-logon trigger.")
                    }
                }
                catch {
                    $triggerValue = 'failed'
                    $problems.Add('trigger-not-removed')
                    $lines.Add("Could not remove the at-logon trigger from the task ${taskLabel}: $($_.Exception.Message)")
                }
            }
            else {
                $triggerValue = 'would-remove'
                $lines.Add("What if: would remove the at-logon trigger from the task $taskLabel and keep its other triggers ($keptText).")
            }
        }

        # 2. WAU_UpdatesAtLogon, which WAU's MSI reads back on an upgrade or repair.
        try {
            if (-not (Test-Path -LiteralPath $settingsKey)) {
                $settingValue = 'no-key'
                $lines.Add("Winget-AutoUpdate's settings key $settingsKey does not exist: WAU_UpdatesAtLogon was not written.")
            }
            else {
                $current = (Get-ItemProperty -LiteralPath $settingsKey -ErrorAction Stop).WAU_UpdatesAtLogon
                if ($null -ne $current -and "$current" -eq '0') {
                    $settingValue = 'already-0'
                    $lines.Add("WAU_UpdatesAtLogon is already 0 in $settingsKey.")
                }
                elseif ($PSCmdlet.ShouldProcess($settingsKey, 'Set WAU_UpdatesAtLogon to 0')) {
                    # An [int] value is written as REG_DWORD, the type WAU's MSI writes and reads.
                    Set-ItemProperty -LiteralPath $settingsKey -Name 'WAU_UpdatesAtLogon' -Value ([int]0) -ErrorAction Stop
                    $written = (Get-ItemProperty -LiteralPath $settingsKey -ErrorAction Stop).WAU_UpdatesAtLogon
                    if ($null -ne $written -and "$written" -eq '0') {
                        $settingValue = 'set-0'
                        $was = 'not set'
                        if ($null -ne $current) {
                            $was = "$current"
                        }
                        $lines.Add("Set WAU_UpdatesAtLogon to 0 in $settingsKey (it was $was), so a Winget-AutoUpdate upgrade or repair does not bring the trigger back.")
                    }
                    else {
                        $settingValue = 'failed'
                        $problems.Add('setting-not-written')
                        $lines.Add("WAU_UpdatesAtLogon in $settingsKey reads '$written' after it was set to 0.")
                    }
                }
                else {
                    $settingValue = 'would-set-0'
                    $lines.Add("What if: would set WAU_UpdatesAtLogon to 0 in $settingsKey (it is '$current').")
                }
            }
        }
        catch {
            $settingValue = 'failed'
            $problems.Add('setting-not-written')
            $lines.Add("Could not set WAU_UpdatesAtLogon to 0 in ${settingsKey}: $($_.Exception.Message)")
        }

        # 3. Group Policy, which WAU's daily Winget-AutoUpdate-Policies task applies to the task.
        try {
            if (Test-Path -LiteralPath $policyKey) {
                $policy = (Get-ItemProperty -LiteralPath $policyKey -ErrorAction Stop).WAU_UpdatesAtLogon
                if ($null -ne $policy) {
                    $policyValue = "$policy"
                }
                if ("$policy" -eq '1') {
                    $problems.Add('policy-logon')
                    $lines.Add("Group Policy sets WAU_UpdatesAtLogon = 1 in ${policyKey}: Winget-AutoUpdate's daily Winget-AutoUpdate-Policies task puts the at-logon trigger back. Set that policy to 0.")
                }
            }
        }
        catch {
            $lines.Add("Could not read Winget-AutoUpdate's Group Policy key ${policyKey}: $($_.Exception.Message)")
        }
    }

    $status = 'unchanged'
    $exitCode = 0
    if ($problems.Count -gt 0) {
        $status = 'failed'
        $exitCode = 1
    }
    elseif ($triggerValue -eq 'removed' -or $settingValue -eq 'set-0') {
        $status = 'fixed'
    }
    elseif ($triggerValue -eq 'would-remove' -or $settingValue -eq 'would-set-0') {
        $status = 'whatif'
    }
    $problemValue = 'none'
    if ($problems.Count -gt 0) {
        $problemValue = ($problems -join ',')
    }
    $lines.Add(('REPAIR: status={0} problems={1} computer={2} logontrigger={3} updatesatlogon={4} policy={5}' -f $status, $problemValue, (ConvertTo-RmmResultValue -Value $computer), $triggerValue, $settingValue, (ConvertTo-RmmResultValue -Value $policyValue)))

    return [pscustomobject]@{
        # One line per step: an error message's own line breaks are joined.
        Lines    = @($lines.ToArray() | ForEach-Object { $_ -replace '\s*[\r\n]+\s*', ' ' })
        Problems = $problems.ToArray()
        ExitCode = $exitCode
    }
}

<#
.SYNOPSIS
    Runs the repair in the right PowerShell and returns its report and exit code.
.DESCRIPTION
    In a 32-bit PowerShell on 64-bit Windows, or in PowerShell 7, runs this script again in 64-bit
    Windows PowerShell (Invoke-RmmRelaunchWhenNeeded) and passes its lines and exit code on.
    Otherwise runs the repair here. Whatever goes wrong, the result ends with a REPAIR line.
.PARAMETER ScriptPath
    This script's path, for the relaunch.
.PARAMETER ForwardedArguments
    The arguments the relaunch passes on (ConvertTo-RmmForwardedArgument), -WhatIf among them.
.PARAMETER Relaunched
    This is the relaunched run: never relaunch again.
.RETURNS
    [pscustomobject] with Lines and ExitCode.
#>
function Invoke-RmmWauRepairMain {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ScriptPath,

        [Parameter(Mandatory = $false)]
        [string[]]$ForwardedArguments = @(),

        [Parameter(Mandatory = $false)]
        [switch]$Relaunched
    )

    $note = $null
    if ($Relaunched) {
        $note = 'Run again in 64-bit Windows PowerShell by the script itself.'
    }
    else {
        $relaunch = Invoke-RmmRelaunchWhenNeeded -ScriptPath $ScriptPath -ForwardedArguments $ForwardedArguments -ResultPrefix 'REPAIR' -FailureStatus 'failed' -FailureProblem 'repair-error'
        if ($relaunch) {
            return $relaunch
        }
    }
    try {
        return (Invoke-RmmWauLogonTriggerRepair -Note $note)
    }
    catch {
        return (New-RmmFailureResult -Message "The repair stopped on an unexpected error: $($_.Exception.Message)" -ResultPrefix 'REPAIR' -FailureStatus 'failed' -FailureProblem 'repair-error')
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $wauRepair = Invoke-RmmWauRepairMain -ScriptPath $PSCommandPath -ForwardedArguments (ConvertTo-RmmForwardedArgument -BoundParameters $PSBoundParameters) -Relaunched:$Relaunched
    foreach ($wauRepairLine in @($wauRepair.Lines)) {
        Write-Output $wauRepairLine
    }
    exit ([int]$wauRepair.ExitCode)
}
