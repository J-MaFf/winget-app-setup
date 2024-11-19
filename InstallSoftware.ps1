
<#PSScriptInfo

.VERSION 1.0.1

.GUID 85a6c4a7-2ff2-4426-bd0d-593a33c919c9

.AUTHOR jmaffiola

.COMPANYNAME

.COPYRIGHT

.TAGS

.LICENSEURI

.PROJECTURI

.ICONURI

.EXTERNALMODULEDEPENDENCIES 

.REQUIREDSCRIPTS

.EXTERNALSCRIPTDEPENDENCIES

.RELEASENOTES Initial version

.PRIVATEDATA

.DESCRIPTION 
 This script installs the following programs from winget:

 7-zip
 TightVNC
 Adobe Acrobat Reader 64 Bit
 Google Chrome
 Google Drive
 Dell Command Update (Universal)
 PowerShell
 Windows Terminal 
 
#>

Param()


# 1. Make sure the Microsoft App Installer is installed:
#    https://www.microsoft.com/en-us/p/app-installer/9nblggh4nns1
# 2. Edit the list of apps to install.
# 3. Run this script as administrator.

# Check if the script is run as administrator
If (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "You need to run this script as an administrator!" -ForegroundColor Red
    # Keep the console window open until the user presses a key
    Write-Host "Press any key to exit..." -ForegroundColor Blue
    [System.Console]::ReadKey($true) > $null
    Exit 1
} else {
    Write-Host "Running as administrator..." -ForegroundColor Green
}

$apps = @(
    @{name = "7zip.7zip" },
    @{name = "GlavSoft.TightVNC" },
    @{name = "Adobe.Acrobat.Reader.64-bit" },
    @{name = "Google.Chrome" },
    @{name = "Google.GoogleDrive" },
    @{name = "Dell.CommandUpdate.Universal" },
    @{name = "Microsoft.PowerShell" },
    @{name = "Microsoft.WindowsTerminal" }
);

Write-Host "Installing the following Apps:" -ForegroundColor Blue
ForEach ($app in $apps) {
    Write-Host $app.name -ForegroundColor Blue
}

$installedApps = @()
$skippedApps = @()
$failedApps = @()

Foreach ($app in $apps) {
    try {
        $listApp = winget list --exact -q $app.name
        if (![String]::Join("", $listApp).Contains($app.name)) {
            Write-Host "Installing: " $app.name -ForegroundColor Blue
            Start-Process winget -ArgumentList "install -e --accept-source-agreements --accept-package-agreements --id $($app.name)" -NoNewWindow -Wait
            $installResult = winget list --exact -q $app.name
            if (![String]::Join("", $installResult).Contains($app.name)) {
                Write-Host "Failed to install: $($app.name). No package found matching input criteria." -ForegroundColor Red
                $failedApps += $app.name
            } else {
                Write-Host "Successfully installed: " $app.name -ForegroundColor Green
                $installedApps += $app.name
            }
        }
        else {
            Write-Host "Skipping: " $app.name " (already installed)" -ForegroundColor Yellow
            $skippedApps += $app.name
        }
    }
    catch {
        Write-Host "Failed to install: $($app.name). Error: $_" -ForegroundColor Red
        $failedApps += $app.name
    }
}

Write-Host "Summary:" -ForegroundColor Blue
Write-Host "Installed Apps: $($installedApps -join ', ')" -ForegroundColor Green
Write-Host "Skipped Apps: $($skippedApps -join ', ')" -ForegroundColor Yellow
Write-Host "Failed Apps: $($failedApps -join ', ')" -ForegroundColor Red

# Keep the console window open until the user presses a key
Write-Host "Press any key to exit..." -ForegroundColor Blue
[System.Console]::ReadKey($true) > $null
