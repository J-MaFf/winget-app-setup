# 1. Make sure the Microsoft App Installer is installed:
#    https://www.microsoft.com/en-us/p/app-installer/9nblggh4nns1
# 2. Edit the list of apps to uninstall.
# 3. Run this script as administrator.

# Check if the script is run as administrator
If (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] 'Administrator')) {
    Write-Host 'This script requires administrator privileges. Press Enter to restart script with elevated privileges.' -ForegroundColor Red
    Pause
    # Relaunch the script with administrator privileges
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    Exit
}
else {
    Write-Host 'Starting...' -ForegroundColor Green
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

Write-Host 'Uninstalling the following Apps:' -ForegroundColor Blue
ForEach ($app in $apps) {
    Write-Host $app.name -ForegroundColor Blue
}

$uninstalledApps = @()
$skippedApps = @()
$failedApps = @()

Foreach ($app in $apps) {
    try {
        $listApp = winget list --exact -q $app.name
        if ([String]::Join('', $listApp).Contains($app.name)) {
            Write-Host 'Uninstalling: ' $app.name -ForegroundColor Blue
            $uninstallResult = winget uninstall -e --id $app.name
            if ($uninstallResult -match 'No installed package found matching input criteria.') {
                Write-Host "Failed to uninstall: $($app.name). No installed package found matching input criteria." -ForegroundColor Red
                $failedApps += $app.name
            }
            elseif ($uninstallResult -match 'Successfully uninstalled') {
                Write-Host 'Successfully uninstalled: ' $app.name -ForegroundColor Green
                $uninstalledApps += $app.name
            }
            else {
                throw "Failed to uninstall: $($app.name). Error: $uninstallResult"
            }
        }
        else {
            Write-Host 'Skipping: ' $app.name ' (not installed)' -ForegroundColor Yellow
            $skippedApps += $app.name
        }
    }
    catch {
        Write-Host "Failed to uninstall: $($app.name). Error: $_" -ForegroundColor Red
        $failedApps += $app.name
    }
}

Write-Host 'Summary:' -ForegroundColor Blue
Write-Host "Uninstalled Apps: $($uninstalledApps -join ', ')" -ForegroundColor Green
Write-Host "Skipped Apps: $($skippedApps -join ', ')" -ForegroundColor Yellow
Write-Host "Failed Apps: $($failedApps -join ', ')" -ForegroundColor Red