<#
.SYNOPSIS
    Uninstalls the curated apps and the automatic updates (Winget-AutoUpdate) that
    winget-app-install.ps1 set up.
.DESCRIPTION
    One self-contained file, like the installer: build/Build-WingetInstallScript.ps1 generates it
    from the WingetAppSetup module, the single source of truth the two share (issues #106, #190),
    so it needs nothing next to it. The work is Invoke-WingetUninstall
    (WingetAppSetup/Public/Uninstall.ps1): it sets up winget the way the installer does and removes
    nothing when winget cannot be started; it keeps the PowerShell 7 and Windows Terminal this run
    depends on, and the apps whose catalog condition does not hold here; and it removes
    Winget-AutoUpdate last, only when every app is gone. The app list is the module's catalog
    (Get-DefaultAppCatalog in WingetAppSetup/Public/AppCatalog.ps1): edit it there, never here.

    Run it from a file. Started without one (irm | iex), it changes nothing and stops with exit
    code 5.

    Needs administrator rights. Started without them, it asks (the UAC prompt), runs again in an
    elevated Windows PowerShell window and exits with that run's exit code. As for the installer,
    that window does not run this file: it runs a copy it has checked against the SHA256 this file
    had when the run started, in a new folder under %SystemRoot%\Temp that only SYSTEM and
    Administrators can change, so a file rewritten while the UAC prompt is up is not run.

    When someone is at the console, the run ends with 'Press any key to exit...', as the installer
    does, so the summary stays on screen: the elevated window closes as soon as the run ends, and
    the uninstaller keeps no transcript. A non-interactive run, a run as SYSTEM and a run under CI
    do not wait.
.PARAMETER WhatIf
    Preview: shows what a real run would remove and changes nothing. Needs no administrator rights.
.PARAMETER NonInteractive
    For unattended runs: never asks for elevation (exits 4 when not elevated) and does not wait for
    a key press at the end.
.NOTES
    Exit codes: 0 = done (every app removed, not installed, or kept on purpose, and Winget-AutoUpdate
    removed or not installed); 3010 = done, and a restart finishes removing an app or
    Winget-AutoUpdate; 1 = an app could not be removed or checked (Winget-AutoUpdate is then kept),
    or Winget-AutoUpdate could not be removed; 2 = winget cannot be started for this account,
    cannot open its source, or Group Policy turns it off, so nothing was removed (Winget-AutoUpdate
    included); 3 = the app list
    has invalid entries; 4 = not elevated, and the UAC prompt was declined or could not be shown (a
    non-interactive run shows none), or the execution policy Group Policy sets would refuse the
    elevated run; 5 = stopped by an unexpected error, started without a script file (irm | iex), or
    the file changed or could not be copied before its elevated run.
#>
param (
    [switch]$WhatIf,
    [switch]$NonInteractive
)
