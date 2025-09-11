<#PSScriptInfo

.VERSION 1.0.0

.GUID b5b5f614-90c3-42a9-94e3-b7dd6e6de262

.AUTHOR Joey Maffiola

.EXTERNALMODULEDEPENDENCIES winget

.TAGS winget, installation, automation

.PROJECTURI https://github.com/J-MaFf/winget-app-setup

.RELEASENOTES Initial version

.Changelog
    1.0.0 - This is the initial version of the script. It installs a list of programs using winget.
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

# ------------------------------------------------Functions------------------------------------------------

<#
.SYNOPSIS
    Checks if a specific winget source is trusted.
.DESCRIPTION
    This function checks if a specific winget source is trusted by listing all sources and checking if the target source is in the list.
.PARAMETER target
    The name of the source to check.
.RETURNS
    [bool] True if the source is trusted, otherwise False.
#>
function Test-Source-IsTrusted($target) {
    $sources = winget source list
    return $sources -match [regex]::Escape($target)
}

<#
.SYNOPSIS
    Adds and trusts the winget source.
.DESCRIPTION
    This function adds and trusts the winget source by adding it to the list of sources.
#>
function Set-Sources {
    winget source add -n "winget" -s "https://cdn.winget.microsoft.com/cache"
    winget source add -n "msstore" -s " https://storeedgefd.dsx.mp.microsoft.com/v9.0"
}

<#
.SYNOPSIS
    Adds a specified path to the environment PATH variable.
.DESCRIPTION
    This function adds a specified path to the environment PATH variable for either the user or the system scope.
.PARAMETER PathToAdd
    The path to add to the environment PATH variable.
.PARAMETER Scope
    The scope to which the path should be added. Valid values are 'User' and 'System'.
#>
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

<#
.SYNOPSIS
    Checks if a specified path is in the environment PATH variable.
.DESCRIPTION
    This function checks if a specified path is in the environment PATH variable for either the user or the system scope.
.PARAMETER PathToCheck
    The path to check in the environment PATH variable.
.PARAMETER Scope
    The scope in which to check the path. Valid values are 'User' and 'System'.
.RETURNS
    [bool] True if the path is in the environment PATH variable, otherwise False.
#>
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


#------------------------------------------------Main Script------------------------------------------------

# Check if the script is run as administrator
If (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "This script requires administrator privileges. Press Enter to restart script with elevated privileges." -ForegroundColor Red
    Pause
    # Relaunch the script with administrator privileges
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    Exit
} else {
    Write-Host "Starting..." -ForegroundColor Green
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

# Verify sources are trusted
$trustedSources = @("winget", "msstore")
ForEach ($source in $trustedSources) {
    if (-not (Test-Source-IsTrusted -target $source)) {
        Write-Host "Trusting source: $source" -ForegroundColor Yellow
        Set-Sources
    } else {
        Write-Host "Source is already trusted: $source" -ForegroundColor Green
    }
}


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

# Check if any apps need to be updated. If so, update them.
Write-Host "Checking if any apps need to be updated..." -ForegroundColor Blue
winget update --all --include-unknown
Write-Host "Finished checking for & installing updates." -ForegroundColor Green

# Keep the console window open until the user presses a key
Write-Host "Press any key to exit..." -ForegroundColor Blue
[System.Console]::ReadKey($true) > $null
