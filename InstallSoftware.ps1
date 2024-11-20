<#PSScriptInfo

.VERSION 1.0.3

.GUID 85a6c4a7-2ff2-4426-bd0d-593a33c919c9

.AUTHOR jmaffiola

.COMPANYNAME

.TAGS

.PROJECTURI https://github.com/J-MaFf/winget-app-setup

.RELEASENOTES Initial version

.Changelog
    1.0.0 - Initial version
    1.0.1 - Added comments
    1.0.2 - Fixed comments
    1.0.3 - Added functions to add to the PATH environment variable so the script can be run from any directory, along with updating the readme.md file.

#>


<#
.SYNOPSIS
 Installs a list of programs using winget.

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

function Add-ToEnvironmentPath {
    param (
        [Parameter(Mandatory = $true)]
        [string]$PathToAdd,

        [Parameter(Mandatory = $true)]
        [ValidateSet('User', 'System')]
        [string]$Scope
    )

    # Check if the path is already in the environment PATH variable
    if (-not (Test-PathInEnvironment -PathToCheck $PathToAdd -Scope $Scope)) {
        if ($Scope -eq 'System') {
            # Get the current system PATH
            $systemEnvPath = [System.Environment]::GetEnvironmentVariable('PATH', [System.EnvironmentVariableTarget]::Machine)
            # Add to system PATH
            $systemEnvPath += ";$PathToAdd"
            [System.Environment]::SetEnvironmentVariable('PATH', $systemEnvPath, [System.EnvironmentVariableTarget]::Machine)
        } elseif ($Scope -eq 'User') {
            # Get the current user PATH
            $userEnvPath = [System.Environment]::GetEnvironmentVariable('PATH', [System.EnvironmentVariableTarget]::User)
            # Add to user PATH
            $userEnvPath += ";$PathToAdd"
            [System.Environment]::SetEnvironmentVariable('PATH', $userEnvPath, [System.EnvironmentVariableTarget]::User)
        }

        # Update the current process environment PATH
        if (-not ($env:PATH -split ';').Contains($PathToAdd)) {
            $env:PATH += ";$PathToAdd"
        }
    }
}

function Test-PathInEnvironment {
    param (
        [Parameter(Mandatory = $true)]
        [string]$PathToCheck,

        [Parameter(Mandatory = $true)]
        [ValidateSet('User', 'System')]
        [string]$Scope
    )

    if ($Scope -eq 'System') {
        $envPath = [System.Environment]::GetEnvironmentVariable('PATH', [System.EnvironmentVariableTarget]::Machine)
    } elseif ($Scope -eq 'User') {
        $envPath = [System.Environment]::GetEnvironmentVariable('PATH', [System.EnvironmentVariableTarget]::User)
    }

    return ($envPath -split ';').Contains($PathToCheck)
}

# Add the script directory to the PATH
$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Definition
Add-ToEnvironmentPath -PathToAdd $scriptDirectory -Scope 'User'

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
