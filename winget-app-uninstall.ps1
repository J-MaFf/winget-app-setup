# 1. Make sure the Microsoft App Installer is installed:
#    https://www.microsoft.com/en-us/p/app-installer/9nblggh4nns1
# 2. The list of apps to uninstall is the module's curated catalog (Get-DefaultAppCatalog in
#    WingetAppSetup/Public/AppCatalog.ps1) — edit it there, never here (issue #190).
# 3. Run this script as administrator.

# Shared helpers (Write-Info/Success/WarningMessage/ErrorMessage, Write-Table, Format-AppList,
# Get-DefaultAppCatalog, Test-WingetPackageInstalled, Restart-WithElevation) come from the
# WingetAppSetup module — the single source of truth (see issues #106, #190).
Import-Module (Join-Path $PSScriptRoot 'WingetAppSetup\WingetAppSetup.psd1') -Force

#------------------------------------------------Main Script------------------------------------------------

# Check if the script is run as administrator
If (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] 'Administrator')) {
    # No "press Enter" pause before elevating (issue #230), matching the installer: the relaunch is
    # unconditional, and the UAC dialog it raises is the real consent gate.
    Write-ErrorMessage 'This script requires administrator privileges. Restarting with elevated privileges...'
    # Relaunch with administrator privileges via the module's shared helper (issue #190):
    # prefers an elevated Windows Terminal tab and falls back to a plain PowerShell window.
    $psExecutable = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }
    Restart-WithElevation -PowerShellExecutable $psExecutable -ScriptPath $PSCommandPath | Out-Null
    Exit
}
else {
    Write-Success 'Starting...'
}

# The same curated catalog the installer uses (issue #190). Uninstall only consumes the package
# ids; custom install strategies (e.g. Microsoft.PowerShell's) are irrelevant for removal.
$apps = Get-DefaultAppCatalog

Write-Info 'Uninstalling the following Apps:'
ForEach ($app in $apps) {
    Write-Info $app.name
}

$uninstalledApps = @()
$skippedApps = @()
$failedApps = @()

Foreach ($app in $apps) {
    try {
        # Installed-check via the module's Test-WingetPackageInstalled (issue #190) — same
        # agreement flags as the old inline call (--accept-source-agreements
        # --disable-interactivity), plus a timeout guard so a hung `winget list` cannot stall the
        # loop. Classification stays exit-code-based, never English output-string matching —
        # winget output is locale-dependent (issue #180).
        $listResult = Test-WingetPackageInstalled -PackageId $app.name -TimeoutSeconds 15
        if ($listResult.TimedOut) {
            throw "Timed out checking whether $($app.name) is installed."
        }
        if ($listResult.ExitCode -eq 0) {
            Write-Info "Uninstalling: $($app.name)"
            $uninstallOutput = winget uninstall -e --id $app.name --disable-interactivity
            $uninstallExitCode = $LASTEXITCODE
            if ($uninstallExitCode -eq 0) {
                Write-Success "Successfully uninstalled: $($app.name)"
                $uninstalledApps += $app.name
            }
            else {
                throw "Failed to uninstall: $($app.name). Exit code: 0x$('{0:X8}' -f $uninstallExitCode). Output: $uninstallOutput"
            }
        }
        else {
            # Nonzero exit (e.g. 0x8A150014 APPINSTALLER_CLI_ERROR_NO_APPLICATIONS_FOUND) => not
            # installed. A $null exit code means `winget list` could not be started at all.
            $listExitCodeText = if ($null -ne $listResult.ExitCode) { '0x{0:X8}' -f $listResult.ExitCode } else { 'unavailable' }
            Write-WarningMessage "Skipping: $($app.name) (not installed; winget list exit code $listExitCodeText)"
            $skippedApps += $app.name
        }
    }
    catch {
        Write-ErrorMessage "Failed to uninstall: $($app.name). Error: $_"
        $failedApps += $app.name
    }
}

# Remove the automatic-update tooling this installer set up: any legacy homegrown scheduled task and
# its %APPDATA% data, plus Winget-AutoUpdate (issue #168).
Write-Info 'Removing automatic-update components...'
[void](Remove-LegacyScheduledUpdates)
[void](Uninstall-WingetAutoUpdate)

Write-Info 'Summary:'

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

$appList = Format-AppList -AppArray $failedApps
if ($appList) {
    $rows += , @('Failed', $appList)
}

# -AutoGridView opens the grid view without asking (issue #230; formerly -PromptForGridView, which
# Read-Host'd first). Hardcoded $true because this script has no non-interactive mode to consult —
# Test-EffectiveNonInteractive is private to the module and not exported. That is safe: Write-Table
# checks Test-CanUseGridView itself, so a session that cannot show a window simply gets the text
# table, which now always prints regardless.
Write-Table -Headers $headers -Rows $rows -AutoGridView $true -Title 'Uninstallation Summary'
