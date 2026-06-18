<#
.SYNOPSIS
    Executes the winget installation workflow when the script runs directly.
.DESCRIPTION
    Performs prerequisite checks, validates application definitions, installs requested apps, processes updates, and displays a summary when invoked.
.PARAMETER WhatIf
    When specified, the script performs all pre-flight checks and displays planned actions without making any system changes.
#>
function Invoke-WingetInstall {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    if ($WhatIf) {
        Write-Info '=== DRY-RUN MODE ENABLED ==='
        Write-Info 'No system changes will be made. This is a simulation of what would happen.'
        Write-Host ''
    }

    # Determine which PowerShell executable to use
    $psExecutable = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh.exe' } else { 'powershell.exe' }

    # Accept msstore source agreements in the user context before elevating.
    # Agreements are per-user — they won't carry over into the elevated process.
    # Running winget source update here surfaces the interactive prompt while we
    # still have the normal user's identity.
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] 'Administrator')
    if (-not $isAdmin -and (Test-IsRunningLocally)) {
        if ($WhatIf) {
            Write-Info '[DRY-RUN] Would run winget source update to prompt for source agreement acceptance in user context'
        }
        else {
            Write-Info 'Updating winget sources — accept any prompts that appear to continue...'
            Start-Process -FilePath 'winget' -ArgumentList 'source', 'update' -Wait -NoNewWindow
        }
    }

    # Check if the script is run as administrator
    If (-NOT $isAdmin) {
        if (Test-IsRunningLocally) {
            # A dry run makes no system changes, so it never needs elevation. Relaunching
            # elevated here would (a) be a surprising side effect for a preview and (b) — if
            # the flag were ever dropped across the elevation boundary — silently turn a
            # dry run into a real install. Stay in the current session and continue the preview.
            if ($WhatIf) {
                Write-Info '[DRY-RUN] Would relaunch with administrator privileges. Continuing the preview in the current (non-elevated) session; no system changes will be made.'
            }
            else {
                Write-ErrorMessage 'This script requires administrator privileges. Press Enter to restart script with elevated privileges.'
                Pause
                # Relaunch the script with administrator privileges, forwarding -WhatIf as a
                # safety net so the elevated session can never escalate a dry run into changes.
                $elevationArgs = if ($WhatIf) { @('-WhatIf') } else { @() }
                Restart-WithElevation -PowerShellExecutable $psExecutable -ScriptPath $PSCommandPath -AdditionalArguments $elevationArgs | Out-Null
                Exit
            }
        }
        else {
            # IEX/remote execution has no local script path to relaunch from.
            Write-ErrorMessage 'This script requires administrator privileges.'
            Write-ErrorMessage 'Auto-elevation is unavailable when running through IEX/remote execution.'
            Write-Info 'Open an elevated PowerShell or Windows Terminal session and run the IEX command again.'
            Write-Info 'Exiting in 5 seconds...'
            Start-Sleep -Seconds 5
            Exit 1
        }
    }
    else {
        Write-Success 'Starting...'
    }

    # Initialize winget sources in user context to prevent session errors (issue #104)
    [void](Initialize-WingetSourcesForUser -WhatIf:$WhatIf)

    # Ensure required modules are available
    if (-not (Test-AndInstallWingetModule)) {
        Write-Warning 'Microsoft.WinGet.Client module is not available. Update functionality will use fallback CLI methods.'
    }

    if (-not (Test-AndInstallGraphicalTools)) {
        Write-Warning 'Out-GridView will be unavailable; results will be displayed in text mode only.'
    }

    # Import required modules
    try {
        Import-Module Microsoft.WinGet.Client -ErrorAction Stop
        Write-Success 'Successfully imported Microsoft.WinGet.Client module'
    }
    catch {
        Write-Warning "Failed to import Microsoft.WinGet.Client module: $_"
        Write-Warning 'Update functionality will use fallback CLI methods'
    }

    # Check if winget is available and install if necessary
    if (-not (Test-AndInstallWinget)) {
        Write-ErrorMessage 'Winget is required for this script. Exiting.'
        Exit
    }

    # Verify winget sources are accessible and auto-repair if broken
    if (-not (Test-WingetSources)) {
        Write-WarningMessage 'Winget sources could not be repaired. Some installations may fail.'
    }

    $scheduledTaskExists = Test-ScheduledUpdatesTaskExists
    $updateConfig = Get-UpdateConfiguration
    if (-not $WhatIf -and -not $scheduledTaskExists -and -not $updateConfig.InitialPromptCompleted) {
        [void](Enable-ScheduledUpdatesCheck -UpdateFrequency $updateConfig.UpdateFrequency -AutoInstall $updateConfig.AutoInstall -WhatIf:$WhatIf)
    }

    # Add the script directory to the PATH (only if running locally)
    # Use $PSScriptRoot for reliable script directory detection (works with launcher)
    if (Test-IsRunningLocally) {
        $scriptDirectory = $PSScriptRoot
        if (-not $WhatIf) {
            Add-ToEnvironmentPath -PathToAdd $scriptDirectory -Scope 'User'
        }
        else {
            Write-Info "[DRY-RUN] Would add '$scriptDirectory' to User PATH"
        }
    }
    else {
        Write-Info 'Skipping PATH update (remote execution detected)'
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

    $validationResult = Test-AppDefinitions -Apps $apps

    foreach ($validationWarning in $validationResult.Warnings) {
        Write-Warning $validationWarning
    }

    if ($validationResult.Errors.Count -gt 0) {
        foreach ($validationError in $validationResult.Errors) {
            Write-ErrorMessage $validationError
        }
        Write-ErrorMessage 'No valid application definitions found. Resolve the errors and re-run the script.'
        Exit
    }

    $apps = $validationResult.ValidApps

    if ($apps.Count -eq 0) {
        Write-ErrorMessage 'No application definitions remain after validation. Add at least one valid entry and re-run the script.'
        Exit
    }

    Write-Info 'Installing the following Apps:'
    ForEach ($app in $apps) {
        Write-Info $app.name
    }

    $installedApps = @()
    $skippedApps = @()
    $failedApps = @()

    # Verify sources are trusted
    $trustedSources = @('winget', 'msstore')
    $sourceErrors = @()
    ForEach ($source in $trustedSources) {
        if (-not (Test-WingetSourceTrusted -target $source)) {
            if (-not $WhatIf) {
                Write-WarningMessage "Trusting source: $source"
                try {
                    $sourceResetSuccess = Set-Sources
                    if (-not $sourceResetSuccess) {
                        $sourceErrors += $source
                        Write-WarningMessage "Failed to reset sources for $source. Continuing with installation..."
                    }
                }
                catch {
                    $sourceErrors += $source
                    Write-WarningMessage "Error resetting sources for ${source}: ${_}. Continuing with installation..."
                }
            }
            else {
                Write-Info "[DRY-RUN] Would trust source: $source"
            }
        }
        else {
            Write-Success "Source is already trusted: $source"
        }
    }

    Foreach ($app in $apps) {
        try {
            # Run winget list with timeout to prevent hanging
            $listProcess = Start-Process -FilePath 'winget' `
                -ArgumentList 'list', '--exact', '--id', $app.name, '--accept-source-agreements' `
                -NoNewWindow `
                -PassThru `
                -RedirectStandardOutput "$env:TEMP\winget_list_output.txt" `
                -RedirectStandardError "$env:TEMP\winget_list_error.txt"

            # Wait up to 15 seconds for the list command
            if (-not $listProcess.WaitForExit(15000)) {
                Write-WarningMessage "Winget list timed out for $($app.name). Skipping..."
                $listProcess.Kill()
                Remove-Item "$env:TEMP\winget_list_output.txt" -ErrorAction SilentlyContinue
                Remove-Item "$env:TEMP\winget_list_error.txt" -ErrorAction SilentlyContinue
                continue
            }

            $listApp = Get-Content "$env:TEMP\winget_list_output.txt" -ErrorAction SilentlyContinue

            # Cleanup temp files
            Remove-Item "$env:TEMP\winget_list_output.txt" -ErrorAction SilentlyContinue
            Remove-Item "$env:TEMP\winget_list_error.txt" -ErrorAction SilentlyContinue

            if (![String]::Join('', $listApp).Contains($app.name)) {
                if (-not $WhatIf) {
                    Write-Info "Installing: $($app.name)"
                    Start-Process winget -ArgumentList "install -e --accept-source-agreements --accept-package-agreements --source winget --id $($app.name)" -NoNewWindow -Wait

                    # Verify installation with timeout
                    $verifyProcess = Start-Process -FilePath 'winget' `
                        -ArgumentList 'list', '--exact', '--id', $app.name, '--accept-source-agreements' `
                        -NoNewWindow `
                        -PassThru `
                        -RedirectStandardOutput "$env:TEMP\winget_verify_output.txt" `
                        -RedirectStandardError "$env:TEMP\winget_verify_error.txt"

                    if ($verifyProcess.WaitForExit(15000)) {
                        $installResult = Get-Content "$env:TEMP\winget_verify_output.txt" -ErrorAction SilentlyContinue
                        if (![String]::Join('', $installResult).Contains($app.name)) {
                            Write-ErrorMessage "Failed to install: $($app.name). No package found matching input criteria."
                            $failedApps += $app.name
                        }
                        else {
                            Write-Success "Successfully installed: $($app.name)"
                            $installedApps += $app.name
                        }
                    }
                    else {
                        Write-WarningMessage "Verification timed out for: $($app.name). Assuming installation failed."
                        $verifyProcess.Kill()
                        $failedApps += $app.name
                    }

                    # Cleanup temp files
                    Remove-Item "$env:TEMP\winget_verify_output.txt" -ErrorAction SilentlyContinue
                    Remove-Item "$env:TEMP\winget_verify_error.txt" -ErrorAction SilentlyContinue
                }
                else {
                    Write-Info "[DRY-RUN] Would install: $($app.name)"
                    $installedApps += $app.name
                }
            }
            else {
                Write-WarningMessage "Skipping: $($app.name) (already installed)"
                $skippedApps += $app.name
            }
        }
        catch {
            Write-ErrorMessage "Failed to install: $($app.name). Error: $_"
            $failedApps += $app.name
        }
    }

    $updatedApps = @()
    $failedUpdateApps = @()

    # Check for updates and perform them in one step
    $hasUpdates = Test-UpdatesAvailable

    if ($hasUpdates) {
        if (-not $WhatIf) {
            Write-Success 'Updates found. Installing updates...'

            # Enumerate the package ids that have updates, preferring the PowerShell module.
            $updateIds = @()
            if (Get-Command Get-WinGetPackage -ErrorAction SilentlyContinue) {
                $updateIds = @(Get-WinGetPackage | Where-Object IsUpdateAvailable | ForEach-Object { $_.Id })
            }
            else {
                Write-WarningMessage 'PowerShell module not available, using CLI fallback...'

                # Fallback to CLI method - get list of packages that have updates available
                $installedPackages = & winget list --source winget 2>&1 | Where-Object {
                    $_ -and
                    $_ -notmatch '^[\s\-\|\\]*$' -and
                    $_ -notmatch '^$' -and
                    $_ -notmatch '^Name\s+Id\s+Version\s+Source' -and
                    $_ -notmatch '^[-]+$' -and
                    $_ -notmatch 'No installed package found'
                }

                foreach ($package in $installedPackages) {
                    $package = $package.Trim()
                    # Split the line by multiple spaces to get columns
                    # Format: Name | Id | Version | Source
                    $columns = $package -split '\s{2,}'
                    if ($columns.Count -ge 2) {
                        $packageId = $columns[1]  # Second column is the ID

                        # Skip if it's not a winget package or if it's a system component
                        if ($packageId -and $packageId -notmatch '^(ARP|MSIX)') {
                            $updateIds += $packageId
                        }
                    }
                }
            }

            # Upgrade each package through a timeout-guarded helper so a single stalled
            # upgrade can no longer hang the entire run (issue #120).
            foreach ($packageId in $updateIds) {
                $result = Invoke-WingetPackageUpgrade -PackageId $packageId
                switch ($result.Status) {
                    'Ok' {
                        $updatedApps += $packageId
                        Write-Success "Successfully updated: $packageId"
                    }
                    'NoUpgrade' {
                        # Nothing to do; the package was already current by the time we upgraded.
                    }
                    'TimedOut' {
                        $failedUpdateApps += $packageId
                        Write-ErrorMessage "Timed out updating: $packageId (skipped to continue)"
                    }
                    default {
                        $failedUpdateApps += $packageId
                        Write-ErrorMessage "Failed to update: $packageId"
                    }
                }
            }
        }
        else {
            Write-Info '[DRY-RUN] Updates are available. Would install the following updates:'
            # Try PowerShell module first for listing
            if (Get-Command Get-WinGetPackage -ErrorAction SilentlyContinue) {
                $packagesWithUpdates = Get-WinGetPackage | Where-Object IsUpdateAvailable
                foreach ($pkg in $packagesWithUpdates) {
                    Write-Info "[DRY-RUN] Would update: $($pkg.Id) (Current: $($pkg.InstalledVersion), Available: $($pkg.AvailableVersion))"
                    $updatedApps += $pkg.Id
                }
            }
            else {
                Write-Info '[DRY-RUN] Would update available packages (using CLI fallback)'
            }
        }
    }

    # Configure Windows Terminal defaults(issue #74): default profile and default terminal app.
    Set-WindowsTerminalDefaults -WhatIf:$WhatIf

    # Retry any failed installations once before producing the final summary
    if ($failedApps.Count -gt 0) {
        if (-not $WhatIf) {
            Write-Host ''
            Write-Info 'Retrying failed installations (1 final attempt)...'

            $appsToRetry = $failedApps
            $failedApps = @()

            foreach ($appName in $appsToRetry) {
                try {
                    Write-Info "Retrying: $appName"
                    Start-Process winget -ArgumentList "install -e --accept-source-agreements --accept-package-agreements --source winget --id $appName" -NoNewWindow -Wait

                    # Verify installation with timeout
                    $verifyProcess = Start-Process -FilePath 'winget' `
                        -ArgumentList 'list', '--exact', '--id', $appName, '--accept-source-agreements' `
                        -NoNewWindow `
                        -PassThru `
                        -RedirectStandardOutput "$env:TEMP\winget_retry_verify_output.txt" `
                        -RedirectStandardError "$env:TEMP\winget_retry_verify_error.txt"

                    if ($verifyProcess.WaitForExit(15000)) {
                        $retryResult = Get-Content "$env:TEMP\winget_retry_verify_output.txt" -ErrorAction SilentlyContinue
                        if (![String]::Join('', $retryResult).Contains($appName)) {
                            Write-ErrorMessage "Retry failed: $appName"
                            $failedApps += $appName
                        }
                        else {
                            Write-Success "Retry succeeded: $appName"
                            $installedApps += $appName
                        }
                    }
                    else {
                        Write-WarningMessage "Verification timed out for retry: $appName. Assuming installation failed."
                        try { $verifyProcess.Kill() } catch { }
                        $failedApps += $appName
                    }

                    # Cleanup temp files
                    Remove-Item "$env:TEMP\winget_retry_verify_output.txt" -ErrorAction SilentlyContinue
                    Remove-Item "$env:TEMP\winget_retry_verify_error.txt" -ErrorAction SilentlyContinue
                }
                catch {
                    Write-ErrorMessage "Retry failed: $appName. Error: $_"
                    $failedApps += $appName
                }
            }
        }
        else {
            Write-Host ''
            Write-Info '[DRY-RUN] Would retry the following failed installations:'
            foreach ($appName in $failedApps) {
                Write-Info "[DRY-RUN] Would retry: $appName"
            }
        }
    }

    # Display the summary of the installation
    if ($WhatIf) {
        Write-Host ''
        Write-Info '=== DRY-RUN SUMMARY ==='
        Write-Info 'The following actions would have been performed:'
    }
    else {
        Write-Info 'Summary:'
    }

    $headers = @('Status', 'Apps')
    $rows = @()

    $appList = Format-AppList -AppArray $installedApps
    if ($appList) {
        $rows += , @('Installed', $appList)
    }

    $appList = Format-AppList -AppArray $skippedApps
    if ($appList) {
        $rows += , @('Skipped', $appList)
    }

    $appList = Format-AppList -AppArray $failedApps
    if ($appList) {
        $rows += , @('Failed', $appList)
    }

    $appList = Format-AppList -AppArray $updatedApps
    if ($appList) {
        $rows += , @('Updated', $appList)
    }

    $appList = Format-AppList -AppArray $failedUpdateApps
    if ($appList) {
        $rows += , @('Failed to Update', $appList)
    }

    Write-Table -Headers $headers -Rows $rows -PromptForGridView $true -Title 'Installation Summary'

    # Keep the console window open until the user presses a key
    Write-Prompt 'Press any key to exit...'
    [void][System.Console]::ReadKey($true)

    if ($failedApps.Count -gt 0) {
        Exit 1
    }
}

