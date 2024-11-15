# 1. Make sure the Microsoft App Installer is installed:
#    https://www.microsoft.com/en-us/p/app-installer/9nblggh4nns1
# 2. Edit the list of apps to install.
# 3. Run this script as administrator.

# Check if the script is run as administrator
If (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Error "You need to run this script as an administrator!"
    # Keep the console window open until the user presses a key
    Write-Output "Press any key to exit..."
    [System.Console]::ReadKey($true) > $null
    Exit 1
} else {
    Write-Output "Running as administrator..."
}

$apps = @(
    @{name = "7zip.7zip" },
    @{name = "GlavSoft.TightVNC" },
    @{name = "Adobe.Acrobat.Reader.64-bit" },
    @{name = "Google.Chrome" },
    @{name = "Google.Drive" },
    @{name = "Dell.CommandUpdate.Universal" },
    @{name = "Microsoft.PowerShell" },
    @{name = "Microsoft.WindowsTerminal" }
);

Write-Output "Installing the following Apps:"
ForEach ($app in $apps) {
    Write-Output $app.name
}

$installedApps = @()
$skippedApps = @()
$failedApps = @()

Foreach ($app in $apps) {
    try {
        $listApp = winget list --exact -q $app.name
        if (![String]::Join("", $listApp).Contains($app.name)) {
            Write-host "Installing: " $app.name
            $installResult = winget install -e -h --accept-source-agreements --accept-package-agreements --id $app.name 
            if ($installResult -match "No package found matching input criteria.") {
                Write-Error "Failed to install: $($app.name). No package found matching input criteria."
                $failedApps += $app.name
            } else {
                Write-host "Successfully installed: " $app.name
                $installedApps += $app.name
            }
        }
        else {
            Write-host "Skipping: " $app.name " (already installed)"
            $skippedApps += $app.name
        }
    }
    catch {
        Write-Error "Failed to install: $($app.name). Error: $_"
        $failedApps += $app.name
    }
}

Write-Output "Summary:"
Write-Output "Installed Apps: $($installedApps -join ', ')"
Write-Output "Skipped Apps: $($skippedApps -join ', ')"
Write-Output "Failed Apps: $($failedApps -join ', ')"

# Keep the console window open until the user presses a key
Write-Output "Press any key to exit..."
[System.Console]::ReadKey($true) > $null