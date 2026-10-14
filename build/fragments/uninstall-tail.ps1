# Any way out of this script that is not a deliberate exit is 5: set before anything can fail, so
# an error that escapes the catch at the end cannot turn into `exit $null`, which is 0.
$exitCode = 5

# Started without a file (irm | iex), there is nothing to relaunch elevated or to check, so the run
# stops before it changes anything. An unattended run exits 5; an interactive console keeps its
# window open, and the message with it, and gets $LASTEXITCODE 5, as the installer's early stops do.
if (-not $PSCommandPath) {
    Write-ErrorMessage 'The uninstaller runs only from a file, and this run has none (irm | iex). Nothing was changed. Save winget-app-uninstall.ps1 and run it: powershell -ExecutionPolicy Bypass -File .\winget-app-uninstall.ps1'
    $global:LASTEXITCODE = 5
    $exitWithoutFile = $false
    try {
        $exitWithoutFile = [bool](Test-EffectiveNonInteractive -NonInteractive:$NonInteractive)
    }
    catch {
        # Cannot tell: keep the window, and the message, open.
        $exitWithoutFile = $false
    }
    if ($exitWithoutFile) {
        exit 5
    }
    return
}

# The SHA256 of this file as this run read it, taken before anything else runs, as the installer
# does (review finding P3-11): the elevated relaunch runs only a copy with this hash.
$uninstallerSha256 = $null
try {
    $uninstallerSha256 = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256 -ErrorAction Stop).Hash
}
catch {
    # Restart-WithElevation then hashes the file when it relaunches.
}

if ($WhatIf) {
    # A preview changes nothing, so it runs as whoever started it (as the installer's does).
    if (-not (Test-IsAdmin)) {
        Write-Info '[DRY-RUN] A real run needs administrator rights and would ask for them. Continuing the preview in this session; nothing will be changed. If the prompt elevates as another account than the signed-in user, the real run keeps the per-user apps (Windows Terminal) this preview may list.'
    }
}
elseif (-not (Test-IsAdmin)) {
    # No "press Enter" pause before elevating (issue #230), matching the installer: the UAC dialog
    # the relaunch raises is the real consent gate.
    Write-ErrorMessage 'This script requires administrator privileges. Restarting with elevated privileges...'
    # As in the installer (issue #190; review findings P2-11, P2-12, P3-11): an elevated Windows
    # PowerShell window (System32's powershell.exe, which every account has) runs a copy of this
    # file checked against the hash above, and this run waits for it and returns its exit code. A
    # declined UAC prompt, or a non-interactive run (no prompt is shown), returns 4; a changed file 5.
    $elevation = Restart-WithElevation -ScriptPath $PSCommandPath -ExpectedSha256 $uninstallerSha256 -NonInteractive:$NonInteractive
    exit $elevation.ExitCode
}
else {
    Write-Success 'Starting...'
}

# Invoke-WingetUninstall returns the exit code (review findings P2-19, P3-18). An unexpected error is
# 5, as in the installer, rather than the 1 PowerShell would exit with, which means an app could not
# be removed.
try {
    # The installer's run lock (wgt-gq8.47): an install and an uninstall side by side would fail
    # each other's winget and msiexec calls, so a real run started while either holds it exits 6
    # at once. A preview changes nothing and takes none.
    if (-not $WhatIf -and (Lock-InstallerRun) -eq 'Busy') {
        Write-ErrorMessage 'Another run of the installer or the uninstaller is in progress on this PC (started by an RMM tool, a scheduled task or someone else). This run stops without changing anything: let that run finish, then run the uninstaller again if needed.'
        $exitCode = 6
    }
    else {
        if (-not $WhatIf) {
            # The run that holds the lock removes the leftover elevated copies a stopped run of
            # either script left behind, as the installer does; this file's own folder is kept.
            [void](Invoke-InstallerHousekeeping -CurrentScriptPath $PSCommandPath)
        }
        $exitCode = Invoke-WingetUninstall -WhatIf:$WhatIf
    }
}
catch {
    $exitCode = 5
    Write-ErrorMessage "The uninstaller stopped on an unexpected error before it finished: $_"
}
finally {
    # Released before the key press, as the installer does, so a window left open blocks no run.
    Unlock-InstallerRun
}

# Hold the window until a key is pressed when someone is at the console, as the installer does: the
# elevated window closes as soon as this script exits, and the uninstaller keeps no transcript, so
# the summary would be gone before anyone read it (review of work-order item 26).
# Wait-InstallerExitKeyPress never waits in a non-interactive run, as SYSTEM or under CI.
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
