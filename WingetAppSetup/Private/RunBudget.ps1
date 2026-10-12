# The whole run's time budget (-MaxRuntimeMinutes, WINGET_APP_SETUP_MAX_RUNTIME_MINUTES; wgt-gq8.41),
# so an RMM job with a hard time limit ends with a report instead of being killed mid-run. These run
# under Windows PowerShell 5.1 too: the bootstrap passes the deadline on to the PowerShell 7 run.

<#
.SYNOPSIS
    Decides the run's time budget: how many minutes, and the deadline they set.
.DESCRIPTION
    The minutes come from -MaxRuntimeMinutes when it is given, where 0 means no budget whatever the
    variable says. Otherwise they come from WINGET_APP_SETUP_MAX_RUNTIME_MINUTES: whole minutes from
    0 to 1440, where unset, empty or 0 means no budget. A variable that holds anything else is warned
    about and ignored, so the run has no budget (fail open, like the other environment switches).
    Callers pass -MaxRuntimeMinutes only when their own caller gave it ($PSBoundParameters).

    The deadline is StartedUtc plus the minutes, or the earlier RunDeadlineUtc that an earlier phase
    of the same run passed on (the Windows PowerShell 5.1 bootstrap, the elevated window, the RMM
    wrapper), so the clock runs from the first start of the run. A RunDeadlineUtc that is not in
    the form Get-InstallerRunBudgetArgument writes is warned about and ignored. Never throws.
.PARAMETER MaxRuntimeMinutes
    The caller's -MaxRuntimeMinutes. Leave it out when it was not given.
.PARAMETER RunDeadlineUtc
    The deadline an earlier phase of this run passed on (yyyy-MM-ddTHH:mm:ssZ), or empty.
.PARAMETER StartedUtc
    When this process's part of the run started. Default: now.
.OUTPUTS
    [pscustomobject] Minutes ([int], 0 = no budget), DeadlineUtc ([DateTime] in UTC, or $null when
    there is no budget) and MinutesGiven ([bool]: -MaxRuntimeMinutes was given, so a relaunch passes
    on even its 0).
#>
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
        # Only a caller that skipped the parameter's own range check gets here with another value.
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
            # Never later than this phase's own start plus the minutes.
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

<#
.SYNOPSIS
    The arguments that pass the run's time budget on to a relaunch of the installer.
.DESCRIPTION
    For the PowerShell 7 relaunch of the 5.1 bootstrap and the elevated relaunch: an elevated or
    other-account process does not reliably inherit environment variables, so the budget goes on the
    command line. Without a budget, nothing, so such a relaunch keeps today's command line; but a
    -MaxRuntimeMinutes 0 that was given goes on as it is, so that a relaunch that inherits
    WINGET_APP_SETUP_MAX_RUNTIME_MINUTES does not take its budget. Runs under 5.1 too.
.PARAMETER Budget
    Resolve-InstallerRunBudget's result, or $null.
.OUTPUTS
    [string[]] '-MaxRuntimeMinutes', the minutes, '-RunDeadlineUtc' and the deadline
    (yyyy-MM-ddTHH:mm:ssZ): tokens without spaces or quotes. '-MaxRuntimeMinutes', '0' for a 0 that
    was given; otherwise empty without a budget.
#>
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

<#
.SYNOPSIS
    Returns whether the run's time budget is used up.
.PARAMETER Budget
    Resolve-InstallerRunBudget's result, or $null.
.PARAMETER NowUtc
    The time to compare with. Default: now.
.OUTPUTS
    [bool] False when the run has no budget.
#>
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

<#
.SYNOPSIS
    Returns how many whole seconds of the run's time budget are left.
.PARAMETER Budget
    Resolve-InstallerRunBudget's result, or $null.
.PARAMETER NowUtc
    The time to count from. Default: now.
.OUTPUTS
    [int] 0 or more, or $null when the run has no budget.
#>
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

<#
.SYNOPSIS
    Caps a wait at what is left of the run's time budget.
.DESCRIPTION
    For the run's wait on a busy Windows Installer: an install that starts just before the deadline
    must not then wait past it for another installation to finish.
.PARAMETER Budget
    Resolve-InstallerRunBudget's result, or $null.
.PARAMETER Seconds
    The longest wait without a budget.
.PARAMETER NowUtc
    The time to count from. Default: now.
.OUTPUTS
    [int] The smaller of Seconds and the budget's seconds left; Seconds when the run has no budget.
#>
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
