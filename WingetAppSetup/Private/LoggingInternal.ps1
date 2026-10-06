# The run's own logging: the key-press prompt and the transcript. The message primitives live in
# Public/Logging.ps1; the module exports both folders' functions, so the split is for readers only.

<#
.SYNOPSIS
    Writes a prompt message in blue color.
.DESCRIPTION
    Helper function for consistent user prompt messages throughout the script.
.PARAMETER Message
    The message to display
#>
function Write-Prompt {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message
    )
    Write-Host $Message -ForegroundColor Blue
}

<#
.SYNOPSIS
    Starts the run's transcript under %ProgramData%\winget-app-setup\logs and returns its path.
.DESCRIPTION
    ProgramData, not the elevating account's TEMP, so the log survives cross-user elevation. Never
    blocks an install: a failure warns and the run goes on without a transcript. An elevated or
    SYSTEM run first makes the logs folder safe (Initialize-ProgramDataFolder -ReadableByUsers): a
    link a standard user planted there is removed, never written through (wgt-gq8.46), and the
    folder is left for SYSTEM and Administrators to change and for standard users to read (review
    finding P3-14). When that fails, there is no transcript. Runs under Windows PowerShell 5.1 too
    (the bootstrap phase), so it must stay 5.1-compatible.
.PARAMETER WhatIf
    A dry run: the file name gets a -whatif suffix.
.PARAMETER Bootstrap
    The Windows PowerShell 5.1 bootstrap phase: the file name gets a -bootstrap suffix.
.PARAMETER UserPhase
    The user phase (Invoke-WingetUserPhase), run as the signed-in user: the transcript goes to that
    user's %LOCALAPPDATA%\winget-app-setup\logs with a -userphase suffix, because a standard user
    often cannot write to the machine's logs folder. That folder's access list is left alone.
.OUTPUTS
    [string] The transcript path, or $null when the transcript could not be started.
#>
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
            # This account's own rights only: nothing written here is more privileged than the
            # account that could have planted a link.
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
            $resetHint = " To reset the folder, run in an elevated prompt: takeown /f `"$($_.TargetObject)`" /a, then icacls `"$($_.TargetObject)`" /reset, and re-run this installer."
        }
        Write-WarningMessage "Transcript logging could not be started: $_. Continuing without a log file.$resetHint"
        return $null
    }
    return $logPath
}
