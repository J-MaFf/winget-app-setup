<#
.SYNOPSIS
    Uninstalls the curated apps and the automatic updates (Winget-AutoUpdate) that
    winget-app-install.ps1 set up.
.DESCRIPTION
    Run it from this repository's folder: it imports the WingetAppSetup module next to it, the
    single source of truth it shares with the installer (issues #106, #190). The work is
    Invoke-WingetUninstall (WingetAppSetup/Public/Uninstall.ps1): it sets up winget the way the
    installer does and removes nothing when winget cannot be started; it keeps the PowerShell 7 and
    Windows Terminal this run depends on, and the apps whose catalog condition does not hold here;
    and it removes Winget-AutoUpdate last, only when every app is gone. The app list is the module's
    catalog (Get-DefaultAppCatalog in WingetAppSetup/Public/AppCatalog.ps1): edit it there, never
    here.

    Needs administrator rights. Started without them, it asks (the UAC prompt), runs again in an
    elevated Windows PowerShell window and exits with that run's exit code. It runs its own files in
    place there, unchecked, because it imports the module from its folder: when another account
    approves the prompt, run it from a folder only administrators can change, or from an elevated
    session.

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
    or Winget-AutoUpdate could not be removed; 2 = winget cannot be started for this account, or
    Group Policy turns it off, so nothing was removed (Winget-AutoUpdate included); 3 = the app list
    has invalid entries; 4 = not elevated, and the UAC prompt was declined or could not be shown (a
    non-interactive run shows none); 5 = stopped by an unexpected error, or the WingetAppSetup
    module folder next to this script could not be loaded.
#>
param (
    [switch]$WhatIf,
    [switch]$NonInteractive
)

# Any way out of this script that is not a deliberate exit is 5: set before anything can fail, so
# an error that escapes the catch at the end cannot turn into `exit $null`, which is 0.
$exitCode = 5

# Without its module the script can do nothing, and every command after this would fail one by one
# while the script still exited 0. Only Write-Host here: the module's message helpers are missing.
try {
    Import-Module (Join-Path $PSScriptRoot 'WingetAppSetup\WingetAppSetup.psd1') -Force -ErrorAction Stop
}
catch {
    Write-Host "The uninstaller cannot run: the WingetAppSetup module folder next to it could not be loaded ($($_.Exception.Message)). Run winget-app-uninstall.ps1 from a full copy of the repository, with its WingetAppSetup folder." -ForegroundColor Red
    exit 5
}

#------------------------------------------------Main Script------------------------------------------------

if ($WhatIf) {
    # A preview changes nothing, so it runs as whoever started it (as the installer's does).
    if (-not (Test-IsAdmin)) {
        Write-Info '[DRY-RUN] A real run needs administrator rights and would ask for them. Continuing the preview in this session; nothing will be changed.'
    }
}
elseif (-not (Test-IsAdmin)) {
    # No "press Enter" pause before elevating (issue #230), matching the installer: the UAC dialog
    # the relaunch raises is the real consent gate.
    Write-ErrorMessage 'This script requires administrator privileges. Restarting with elevated privileges...'
    # The module's shared helper (issue #190; review findings P2-11, P2-12), as in the installer: it
    # runs this script in an elevated Windows PowerShell window (System32's powershell.exe, which
    # every account has, never a per-user pwsh.exe or wt.exe alias), waits for it and returns its
    # exit code. A declined UAC prompt, or a non-interactive run (no prompt is shown), returns 4.
    # -InPlace: this script imports the module from its own folder, so the elevated window runs
    # this file where it is rather than a checked copy elsewhere. Nothing checks these files then
    # (readme, "Administrator rights"): run from a folder the signed-in user can write to, they can
    # be rewritten while the UAC prompt is up.
    $elevation = Restart-WithElevation -ScriptPath $PSCommandPath -InPlace -NonInteractive:$NonInteractive
    exit $elevation.ExitCode
}
else {
    Write-Success 'Starting...'
}

# Invoke-WingetUninstall returns the exit code (review findings P2-19, P3-18); it used to be 0 for
# every run. An unexpected error is 5, as in the installer, rather than the 1 PowerShell would exit
# with, which means an app could not be removed.
try {
    $exitCode = Invoke-WingetUninstall -WhatIf:$WhatIf
}
catch {
    $exitCode = 5
    Write-ErrorMessage "The uninstaller stopped on an unexpected error before it finished: $_"
}

# Hold the window until a key is pressed when someone is at the console, as the installer does. The
# elevated window Restart-WithElevation opens runs this script with -File and closes as soon as it
# exits, and the uninstaller keeps no transcript, so the summary and the failure reasons above
# would be gone before anyone read them (the Out-GridView window the summary used to open held it;
# review of work-order item 26). Wait-InstallerExitKeyPress never waits in a non-interactive run,
# as SYSTEM or under CI.
$stoppedAtPrompt = $true
try {
    Wait-InstallerExitKeyPress -NonInteractive:$NonInteractive
    $stoppedAtPrompt = $false
}
catch {
    # The key press is a courtesy: nothing here may change the exit code.
    $stoppedAtPrompt = $false
}
finally {
    # Ctrl+C at the prompt stops the script here, past the catch (a PipelineStoppedException cannot
    # be caught), and a script stopped that way exits 0: report the run's own code instead, as the
    # installer's entry script does.
    if ($stoppedAtPrompt) {
        $host.SetShouldExit($exitCode)
    }
}
exit $exitCode
