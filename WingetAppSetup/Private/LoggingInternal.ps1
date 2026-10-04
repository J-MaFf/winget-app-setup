# Logging helpers used only by module functions and the generated entry script (issue #191). The
# externally consumed logging primitives (Write-Info/Success/WarningMessage/ErrorMessage,
# Format-AppList, Write-Table) live in Public/Logging.ps1 because winget-app-uninstall.ps1 imports
# them through the manifest.

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
    Persistent transcript (issue #189): a failed install on a remote user's machine used to leave
    zero artifacts. The log lands under ProgramData - not the elevating account's TEMP - so it
    survives cross-user elevation and stays findable afterwards. Logging must never block an
    install: any failure here downgrades to a warning and the run continues untranscribed.

    Called by the generated entry script for both phases of a run: the Windows PowerShell 5.1
    bootstrap (-Bootstrap, review finding P2-13), whose PowerShell 7 install used to leave no log
    at all, and the PowerShell 7 run itself. Runs under Windows PowerShell 5.1, so it must stay
    5.1-runtime compatible (see WingetAppSetup/Private/PowerShell7Bootstrap.ps1).

    Once the transcript is running, the log folder is made readable for standard users
    (Grant-InstallLogReadAccess, review finding P3-14), so the log can be opened from the end
    user's own session after a cross-user elevated run.
.PARAMETER WhatIf
    A dry run: the file name gets a -whatif suffix, so dry-run transcripts are never mistaken for
    real install logs.
.PARAMETER Bootstrap
    The Windows PowerShell 5.1 bootstrap phase: the file name gets a -bootstrap suffix. The
    PowerShell 7 run it relaunches writes its own transcript next to it.
.PARAMETER UserPhase
    The user phase (Invoke-WingetUserPhase), which runs as the signed-in user, not elevated: the
    transcript goes to that user's %LOCALAPPDATA%\winget-app-setup\logs, since a standard user
    cannot write to the machine's logs folder, and the file name gets a -userphase suffix. The
    folder's access list is left as it is.
.RETURNS
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
    Lets standard users read the installer's log folder (and the logs inside it).
.DESCRIPTION
    Review finding P3-14. Installing Winget-AutoUpdate restricts %ProgramData%\winget-app-setup to
    SYSTEM and Administrators (New-WauStagingDirectory, issue #186), and that inheritance-removing
    ACL reaches the logs folder beneath it. From then on the teammate who elevated as an admin on
    the end user's machine got Access Denied opening the log from the end user's own session, which
    is where they file the GitHub issue from.

    This adds an explicit, inheritable read-and-execute grant for BUILTIN\Users (well-known SID
    S-1-5-32-545, so it works on non-English Windows) on the logs folder only. Explicit entries are
    kept when the parent's inheritable entries change, so the grant survives that restriction, and
    every elevated run re-applies it, which also repairs machines restricted by an earlier run. The
    WAU staging directory's lockdown is untouched: it is a sibling folder with its own ACL, and the
    grant gives no write access. The parent stays unlistable for standard users, so they open the
    log by its full path, which the installer prints.

    Only an elevated process changes the ACL: a non-elevated first launch could not change an admin-
    created folder, and the elevated run it starts does it instead. Best-effort: a failure warns and
    the run continues. Runs under Windows PowerShell 5.1 too (the bootstrap transcript).
.PARAMETER Path
    The log folder.
.RETURNS
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
