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
    blocks an install: a failure warns and the run goes on without a transcript. Once it runs, the
    log folder is made readable for standard users (Grant-InstallLogReadAccess). Runs under Windows
    PowerShell 5.1 too (the bootstrap phase), so it must stay 5.1-compatible.
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
        if ($UserPhase) {
            $logDirectory = Join-Path $env:LOCALAPPDATA 'winget-app-setup\logs'
        }
        else {
            $logDirectory = Join-Path $env:ProgramData 'winget-app-setup\logs'
        }
        if (-not (Test-Path -LiteralPath $logDirectory)) {
            [void](New-Item -Path $logDirectory -ItemType Directory -Force -ErrorAction Stop)
        }
        $logPath = Join-Path $logDirectory ('install-{0:yyyyMMdd-HHmmss}{1}{2}.log' -f (Get-Date), $phaseSuffix, $whatIfSuffix)
        [void](Start-Transcript -Path $logPath -ErrorAction Stop)
    }
    catch {
        Write-WarningMessage "Transcript logging could not be started: $_. Continuing without a log file."
        return $null
    }

    # After Start-Transcript, so a failure to change the folder's ACL is in the log too; the grant
    # is inheritable, so the transcript file already created inside the folder picks it up. A user's
    # own folder needs none.
    if (-not $UserPhase) {
        [void](Grant-InstallLogReadAccess -Path $logDirectory)
    }
    return $logPath
}

<#
.SYNOPSIS
    Lets standard users read the installer's log folder and the logs in it.
.DESCRIPTION
    Installing Winget-AutoUpdate limits %ProgramData%\winget-app-setup to SYSTEM and Administrators,
    and that reaches the logs folder, so a user could not open the log from their own session after
    a cross-user elevated run (review finding P3-14). This adds an explicit, inheritable
    read-and-execute entry for BUILTIN\Users (by SID S-1-5-32-545, for non-English Windows) on the
    logs folder only; explicit entries survive the parent's change, and every elevated run applies
    it again. No write access, and the parent stays unlistable, so users open the log by its full
    path. Only an elevated process changes the ACL. Best-effort: a failure warns. Runs under Windows
    PowerShell 5.1 too.
.PARAMETER Path
    The log folder.
.OUTPUTS
    [bool] True when the grant was applied.
#>
function Grant-InstallLogReadAccess {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-IsAdmin)) {
        return $false
    }
    try {
        # -WindowStyle Hidden, not -NoNewWindow: icacls prints a 'processed file' line per folder,
        # which would otherwise land on the console of every run.
        $icaclsArgs = '"{0}" /grant *S-1-5-32-545:(OI)(CI)RX' -f $Path
        $proc = Start-Process -FilePath 'icacls.exe' -ArgumentList $icaclsArgs -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
        if ($proc.ExitCode -eq 0) {
            return $true
        }
        Write-WarningMessage ("Could not make the log folder readable for standard users (icacls exit code {0}). Open the log from an elevated session." -f $proc.ExitCode)
    }
    catch {
        Write-WarningMessage "Could not make the log folder readable for standard users: $_. Open the log from an elevated session."
    }
    return $false
}
