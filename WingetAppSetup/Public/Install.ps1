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

    # Accept the winget source agreement in the user context before elevating. Agreements are
    # per-user and won't carry into the elevated process; running the update here surfaces any
    # interactive prompt while we still have the normal user's identity. Scoped to --name winget —
    # the only source this tool installs from — so it never triggers msstore's agreement/first-use
    # handshake, which fails in non-interactive/cross-user contexts (issue #172).
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] 'Administrator')
    if (-not $isAdmin -and (Test-IsRunningLocally)) {
        if ($WhatIf) {
            Write-Info '[DRY-RUN] Would run winget source update --name winget to prompt for source agreement acceptance in user context'
        }
        else {
            Write-Info 'Updating the winget source — accept any prompts that appear to continue...'
            Start-Process -FilePath 'winget' -ArgumentList 'source', 'update', '--name', 'winget' -Wait -NoNewWindow
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

    # Ensure the WinGet PowerShell module is available before touching winget itself:
    # Test-AndInstallWinget and Initialize-WingetSourcesForUser use Repair-WinGetPackageManager
    # to bootstrap winget for accounts that have no interactive logon session (issue #159).
    if (-not (Test-AndInstallWingetModule)) {
        Write-Warning 'Microsoft.WinGet.Client module is not available. Update functionality will use fallback CLI methods.'
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

    # Initialize winget sources and agreements for the account performing the installs. This is
    # what prevents 0x80073d19 when the script is elevated as a different account than the
    # logged-on user (issues #104/#150, #159).
    [void](Initialize-WingetSourcesForUser -WhatIf:$WhatIf)

    if (-not (Test-AndInstallGraphicalTools)) {
        Write-Warning 'Out-GridView will be unavailable; results will be displayed in text mode only.'
    }

    # Verify winget sources are accessible and auto-repair if broken
    if (-not (Test-WingetSources)) {
        Write-WarningMessage 'Winget sources could not be repaired. Some installations may fail.'
    }

    # Migrate away from the old homegrown scheduled-update task if a prior version installed one;
    # ongoing updates are now handled by Winget-AutoUpdate, set up after the app installs (issue #168).
    [void](Remove-LegacyScheduledUpdates -WhatIf:$WhatIf)

    # Note: earlier versions added the script's own directory (often Downloads/) to the persistent
    # User PATH here for the homegrown updater. The updater is gone (#168) and a user-writable
    # directory on the PATH of an elevating account is a hijack surface, so no PATH changes are
    # made anymore (issue #179).

    $apps = @(
        @{name = '7zip.7zip' },
        @{name = 'GlavSoft.TightVNC' },
        @{name = 'Adobe.Acrobat.Reader.64-bit' },
        @{name = 'Google.Chrome' },
        @{name = 'Google.GoogleDrive' },
        @{name = 'Git.Git' },
        @{name = 'Klocman.BulkCrapUninstaller' },
        @{name = 'Dell.CommandUpdate.Universal' },
        # PowerShell needs a version-agnostic install strategy (no pinning — always the latest):
        # winget installs PowerShell 7.6+ as an MSIX by default, which registers per-user and fails
        # to deploy in an elevated cross-user / machine-scope context ("The current system
        # configuration does not support the installation of this package"). Install-PowerShellLatest
        # prefers the MSI while it exists (<= 7.6), and once the MSI is gone (7.7+) installs the latest
        # MSIX machine-wide — natively on Windows 24H2+, or via DISM provisioning on older Windows
        # (issues #163/#166). It self-verifies, so the loop must not re-check it with `winget list`.
        @{name = 'Microsoft.PowerShell'; install = 'Install-PowerShellLatest' },
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

    # Verify sources are trusted. Only the winget community source is used — every install forces
    # --source winget — so msstore is intentionally excluded: it is never installed from, and
    # trusting it here ran a global `winget source reset --force` that wiped/re-prompted source
    # agreements and failed noisily on msstore's cert/agreement/licensing handshake in elevated or
    # cross-user contexts (issue #172).
    $trustedSources = @('winget')
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
                    if ($app.install) {
                        # Package-specific installer that performs its own verification (e.g.
                        # PowerShell, whose DISM-provisioned MSIX path never shows up under
                        # `winget list` for the elevating account). Trust its Installed result.
                        $installOutcome = & $app.install
                        if ($installOutcome.Installed) {
                            Write-Success "Successfully installed: $($app.name)"
                            $installedApps += $app.name
                        }
                        else {
                            Write-ErrorMessage "Failed to install: $($app.name)."
                            $failedApps += $app.name
                        }
                    }
                    else {
                        # Install through the helper so the transient 0x80073d19 session error is
                        # retried with backoff (issue #150) instead of failing on the first hit.
                        [void](Install-WingetPackage -PackageId $app.name -InstallerType $app.installerType)

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

    # Ongoing app updates are handled by Winget-AutoUpdate (set up below), which runs as SYSTEM on a
    # schedule — not an install-time pass that upgrades every installed app synchronously as the
    # elevating admin (that was slow, silent, and largely failed under cross-user elevation; issue #170).

    # Configure Windows Terminal defaults(issue #74): default profile and default terminal app.
    Set-WindowsTerminalDefaults -WhatIf:$WhatIf

    # Set up ongoing automatic updates via Winget-AutoUpdate (issue #168). Best-effort: a failure
    # here warns but does not fail the install.
    [void](Install-WingetAutoUpdate -WhatIf:$WhatIf)

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
                    $appDef = $apps | Where-Object { $_.name -eq $appName } | Select-Object -First 1
                    if ($appDef.install) {
                        # Package-specific self-verifying installer (e.g. PowerShell). Trust its result.
                        $retryOutcome = & $appDef.install
                        if ($retryOutcome.Installed) {
                            Write-Success "Retry succeeded: $appName"
                            $installedApps += $appName
                        }
                        else {
                            Write-ErrorMessage "Retry failed: $appName"
                            $failedApps += $appName
                        }
                    }
                    else {
                        # Route the final retry through the same helper so a lingering 0x80073d19
                        # session error gets its backoff retries here too (issue #150).
                        [void](Install-WingetPackage -PackageId $appName -InstallerType $appDef.installerType)

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

    Write-Table -Headers $headers -Rows $rows -PromptForGridView $true -Title 'Installation Summary'

    # Keep the console window open until the user presses a key
    Write-Prompt 'Press any key to exit...'
    [void][System.Console]::ReadKey($true)

    if ($failedApps.Count -gt 0) {
        Exit 1
    }
}

