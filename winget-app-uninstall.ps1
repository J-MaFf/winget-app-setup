# 1. Make sure the Microsoft App Installer is installed:
#    https://www.microsoft.com/en-us/p/app-installer/9nblggh4nns1
# 2. Edit the list of apps to uninstall.
# 3. Run this script as administrator.

# Shared helpers (Write-Info/Success/WarningMessage/ErrorMessage, Write-Table, Format-AppList)
# come from the WingetAppSetup module — the single source of truth (see issue #106).
Import-Module (Join-Path $PSScriptRoot 'WingetAppSetup\WingetAppSetup.psd1') -Force

#------------------------------------------------Main Script------------------------------------------------

# Check if the script is run as administrator
If (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] 'Administrator')) {
    Write-ErrorMessage 'This script requires administrator privileges. Press Enter to restart script with elevated privileges.'
    Pause
    # Relaunch the script with administrator privileges
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    Exit
}
else {
    Write-Success 'Starting...'
}

$apps = @(
    @{name = '7zip.7zip' },
    @{name = 'GlavSoft.TightVNC' },
    @{name = 'Adobe.Acrobat.Reader.64-bit' },
    @{name = 'Google.Chrome' },
    @{name = 'Google.GoogleDrive' },
    @{name = 'Git.Git' },
    @{name = 'Klocman.BulkCrapUninstaller' },
    @{name = 'Dell.CommandUpdate.Universal' },
    @{name = 'Microsoft.PowerShell' },
    @{name = 'Microsoft.WindowsTerminal' }
);

Write-Info 'Uninstalling the following Apps:'
ForEach ($app in $apps) {
    Write-Info $app.name
}

$uninstalledApps = @()
$skippedApps = @()
$failedApps = @()

Foreach ($app in $apps) {
    try {
        $listApp = winget list --exact --id $app.name
        if ([String]::Join('', $listApp).Contains($app.name)) {
            Write-Info "Uninstalling: $($app.name)"
            $uninstallResult = winget uninstall -e --id $app.name
            if ($uninstallResult -match 'No installed package found matching input criteria.') {
                Write-ErrorMessage "Failed to uninstall: $($app.name). No installed package found matching input criteria."
                $failedApps += $app.name
            }
            elseif ($uninstallResult -match 'Successfully uninstalled') {
                Write-Success "Successfully uninstalled: $($app.name)"
                $uninstalledApps += $app.name
            }
            else {
                throw "Failed to uninstall: $($app.name). Error: $uninstallResult"
            }
        }
        else {
            Write-WarningMessage "Skipping: $($app.name) (not installed)"
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

Write-Table -Headers $headers -Rows $rows -PromptForGridView $true -Title 'Uninstallation Summary'
