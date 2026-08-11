<#
.SYNOPSIS
    Updates the winget source for the current account to force its per-user first-use bootstrap.
.DESCRIPTION
    Runs `winget source update --name winget --disable-interactivity` under a timeout guard. This is
    the lightest command that forces winget's per-user first-use bootstrap: it registers the
    Microsoft.Winget.Source package for the invoking account. Exit code 0 therefore means the account
    can reach the winget source — the only source the install phase uses (`--source winget`).

    Do NOT pass `--accept-source-agreements` here: it is not a valid argument for `winget source
    update` and makes winget reject the whole command with 0x8A150002 (INVALID_CL_ARGUMENTS,
    -1978335230), which false-failed this probe on every machine (issue #172-followup). Source
    agreements are accepted where the flag is valid — the install commands all pass
    `--accept-source-agreements` (Install-WingetPackage), and the caller handles a genuine
    0x8A150046 (agreements-not-accepted) result explicitly.

    The probe is deliberately scoped to the winget source: msstore can fail for an account that
    has never logged on interactively even when the winget source is healthy
    (microsoft/winget-cli#5398/#6334), and probing it would report a false failure for the only
    source that matters here.
.PARAMETER TimeoutSeconds
    Maximum seconds to wait for winget before killing the process. Default 120.
.RETURNS
    [hashtable] @{ Succeeded = <bool>; ExitCode = <int or $null>; TimedOut = <bool> }
    ExitCode is $null when the process timed out or failed to start.
#>
function Invoke-WingetSourceProbe {
    param (
        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 120
    )

    # Unique per-run temp files: fixed names made concurrent runs (or a stale locked file from a
    # killed run) fail Start-Process, which read as a false probe failure (issue #177).
    $tempSuffix = [System.IO.Path]::GetRandomFileName()
    $stdoutFile = Join-Path $env:TEMP "winget_source_probe_output_$tempSuffix.txt"
    $stderrFile = Join-Path $env:TEMP "winget_source_probe_error_$tempSuffix.txt"

    try {
        $probeProcess = Start-Process -FilePath 'winget' `
            -ArgumentList 'source', 'update', '--name', 'winget', '--disable-interactivity' `
            -NoNewWindow `
            -PassThru `
            -RedirectStandardOutput $stdoutFile `
            -RedirectStandardError $stderrFile

        if (-not $probeProcess.WaitForExit($TimeoutSeconds * 1000)) {
            Write-WarningMessage "Winget source update timed out after $TimeoutSeconds seconds. Terminating process..."
            try { $probeProcess.Kill() } catch { }
            return @{ Succeeded = $false; ExitCode = $null; TimedOut = $true }
        }

        return @{
            Succeeded = ($probeProcess.ExitCode -eq 0)
            ExitCode  = $probeProcess.ExitCode
            TimedOut  = $false
        }
    }
    catch {
        Write-WarningMessage "Winget source update failed to run: $_"
        return @{ Succeeded = $false; ExitCode = $null; TimedOut = $false }
    }
    finally {
        Remove-Item $stdoutFile -ErrorAction SilentlyContinue
        Remove-Item $stderrFile -ErrorAction SilentlyContinue
    }
}

<#
.SYNOPSIS
    Checks that the winget source is both listed and functional for the current account.
.DESCRIPTION
    Two-step health probe used by Test-WingetSources before and after its repair attempt (one
    shared implementation so the two probes cannot diverge — issue #177):

      1. Listed: `winget source list` output mentions the winget source.
      2. Functional: a real `winget search 7zip --source winget` succeeds (exit code 0 and no
         corruption markers such as 0x8a15000f in the output).

    The search passes `--accept-source-agreements` — valid for `winget search`, unlike
    `winget source update` (issues #174/#175) — so a fresh account's unaccepted source agreements
    (0x8A150046) are accepted inline instead of being misdiagnosed as source corruption and
    triggering a pointless `winget source reset --force` + repair cycle.
.PARAMETER Quiet
    Suppresses the per-step success/corruption messages; used for the post-repair re-probe where
    the caller reports the overall outcome itself.
.RETURNS
    [hashtable] @{ Listed = <bool>; Functional = <bool>; Healthy = <bool> }
    Healthy is True only when the source is listed AND functional.
#>
function Test-WingetSourceHealth {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$Quiet
    )

    # First check: verify source is listed
    try {
        $output = winget source list --disable-interactivity --accept-source-agreements 2>&1
        $sourceIsListed = [bool]($output -match 'winget')
    }
    catch {
        Write-WarningMessage "Winget source list failed: $_"
        $sourceIsListed = $false
    }

    # Second check: verify source is functional (not corrupted) by attempting a search
    $sourceIsFunctional = $false
    if ($sourceIsListed) {
        try {
            # Actually test if the source works by attempting a search.
            # Use '7zip' as a known package that always exists.
            $searchOutput = winget search 7zip --source winget --disable-interactivity --accept-source-agreements 2>&1
            $searchExitCode = $LASTEXITCODE

            # Any nonzero exit code fails the check — that includes the known 0x8A15000F
            # corruption signature (APPINSTALLER_CLI_ERROR_SOURCE_DATA_MISSING, -1978335217 as a
            # signed Int32 — "Failed when opening source(s)... Data required by the source is
            # missing"), which needs no runtime branch of its own.
            #
            # The output match is the fallback for the one scenario the exit code cannot catch:
            # per the codebase's hard-won history with flaky winget exit codes (issues
            # #150/#172/#174/#175/#177), winget has reportedly emitted this exact corruption text
            # while still returning exit code 0. The '0x8a150' token is the load-bearing part —
            # winget prints the hex HRESULT regardless of display language, so it survives locale
            # and wording changes. The two English phrases are extra coverage only and, like the
            # locale-dependency note in winget-app-uninstall.ps1 (issue #180), may stop matching
            # if winget's output wording or locale changes.
            if ($searchExitCode -ne 0 -or $searchOutput -match '0x8a150|failed when opening|data required') {
                if (-not $Quiet) {
                    Write-WarningMessage 'Winget source is listed but contains corrupted or missing data.'
                }
                $sourceIsFunctional = $false
            }
            else {
                if (-not $Quiet) {
                    Write-Success 'Winget sources are accessible and functional.'
                }
                $sourceIsFunctional = $true
            }
        }
        catch {
            if (-not $Quiet) {
                Write-WarningMessage "Winget source functionality test failed: $_"
            }
            $sourceIsFunctional = $false
        }
    }

    return @{
        Listed     = $sourceIsListed
        Functional = $sourceIsFunctional
        Healthy    = ($sourceIsListed -and $sourceIsFunctional)
    }
}

<#
.SYNOPSIS
    Tests whether an AppX/MSIX deployment error is the "a newer version is already installed"
    downgrade rejection (0x80073D06).
.DESCRIPTION
    Repair-WinGetPackageManager deploys the framework dependencies pinned to the WinGet release it
    installs (Microsoft.WindowsAppRuntime, VCLibs, UI.Xaml). When the machine already carries a
    NEWER build of one of them - routine on managed fleets, where Teams / Phone Link / an MDM push
    updates WindowsAppRuntime independently - AppX rejects the downgrade with 0x80073D06
    (ERROR_INSTALL_PACKAGE_DOWNGRADE) and the cmdlet aborts BEFORE it ever registers App Installer,
    on a machine with nothing actually wrong with it. Callers still recover further down their
    ladder, but only by paying for the heaviest rung they have (issue #265).

    That failure is not retryable: -Force only makes the cmdlet more insistent about deploying the
    older pinned build. Callers use this classifier to stop escalating and move to their next
    fallback instead.

    The '0x80073d06' token is the load-bearing part of the match - winget and AppX print the hex
    HRESULT regardless of display language, so it survives locale and wording changes. The English
    phrase is extra coverage only and, like the locale-dependency notes elsewhere in this module
    (issues #177/#180), may stop matching if the wording changes.
.PARAMETER Message
    The exception or error text to classify.
.RETURNS
    [bool] True when the text carries the downgrade-rejection signature.
#>
function Test-AppxDowngradeRejection {
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Message
    )

    if ([string]::IsNullOrWhiteSpace($Message)) {
        return $false
    }

    return [bool]($Message -match '0x80073d06|higher version of this package is already installed')
}

<#
.SYNOPSIS
    Registers the App Installer (winget) MSIX already staged on this machine for the current account.
.DESCRIPTION
    The winget CLI is delivered by the Microsoft.DesktopAppInstaller MSIX package, which is
    registered PER USER. When the installer runs elevated as a different admin account than the
    logged-on user - the cross-user elevation this module already handles for sources and agreements
    (issues #104/#150/#159) - that account has no registration and therefore no
    %LOCALAPPDATA%\Microsoft\WindowsApps\winget.exe alias, even though the machine plainly has a
    working winget for the interactive user.

    Registering the payload that is ALREADY on disk is the cheapest fix for that case: no download,
    no framework dependency deployment, and therefore none of the 0x80073D06 downgrade rejections
    that abort Repair-WinGetPackageManager on a machine carrying a newer WindowsAppRuntime
    (issue #265). That is why callers try this BEFORE the repair cmdlet, not after it.

    Two registration forms are attempted, in order:
      1. -RegisterByFamilyName, which needs only the package family name.
      2. -Register against the AppXManifest.xml under each candidate's InstallLocation, which also
         covers a package staged on the machine but never registered for this account.

    Get-AppxPackage/Add-AppxPackage are used from pwsh here, as they already are elsewhere in this
    module (Resolve-WingetExecutable, Test-AndInstallWinget). The Appx cmdlet known to be unreliable
    under PowerShell 7 is the DISM-backed Add-AppxProvisionedPackage, which Invoke-AppxProvisioning
    delegates to Windows PowerShell 5.1 for that reason; the per-user registration cmdlets used here
    are not affected.
.RETURNS
    [bool] True when a registration call completed without error, otherwise False. Callers re-check
    winget availability themselves - a successful registration is not proof the alias resolved.
#>
function Register-WingetAppInstallerForUser {
    $familyName = 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe'

    # -AllUsers requires elevation (which the installer already has) and is what surfaces a package
    # staged on the machine but not registered for THIS account - precisely the case this helper
    # exists for. Fall back to the current-user view if it is refused, so a non-elevated or
    # policy-restricted run degrades instead of erroring out.
    $candidates = @()
    try {
        $candidates = @(Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -AllUsers -ErrorAction Stop)
    }
    catch {
        try {
            $candidates = @(Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -ErrorAction Stop)
        }
        catch {
            Write-WarningMessage "Could not enumerate the App Installer package: $_"
            return $false
        }
    }

    if ($candidates.Count -eq 0) {
        Write-Info 'App Installer is not staged on this machine; there is nothing to register for this account.'
        return $false
    }

    Write-Info 'Registering the App Installer package already on this machine for the current account...'
    try {
        Add-AppxPackage -RegisterByFamilyName -MainPackage $familyName -ErrorAction Stop
        Write-Success 'App Installer registered for this account.'
        return $true
    }
    catch {
        Write-WarningMessage "Registering App Installer by family name failed: $_"
    }

    foreach ($candidate in $candidates) {
        if (-not $candidate.InstallLocation) { continue }
        $manifest = Join-Path $candidate.InstallLocation 'AppXManifest.xml'
        if (-not (Test-Path $manifest)) { continue }

        try {
            # -Path is passed by name: -Register is a switch, so `-Register $manifest` would bind
            # the manifest positionally and read as though it were the switch's argument.
            Add-AppxPackage -Path $manifest -Register -DisableDevelopmentMode -ErrorAction Stop
            Write-Success "App Installer registered for this account from $($candidate.InstallLocation)."
            return $true
        }
        catch {
            Write-WarningMessage "Registering App Installer from '$manifest' failed: $_"
        }
    }

    return $false
}

<#
.SYNOPSIS
    Runs Repair-WinGetPackageManager, unforced first, and reports a 0x80073D06 rejection distinctly.
.DESCRIPTION
    Shared wrapper for the two places that bootstrap winget through the WinGet PowerShell module
    (Test-AndInstallWinget and Initialize-WingetSourcesForUser), so the retry and error-classification
    policy cannot diverge between them - the same reasoning that made Test-WingetSourceHealth shared
    in issue #177.

    The unforced attempt runs first so the cmdlet can skip framework dependencies that are already
    present at an equal or newer version. -Force is still attempted afterwards, because it remains
    the documented remedy for a genuinely broken or partial App Installer registration
    (learn.microsoft.com/windows/package-manager/winget/troubleshooting) - but only when the unforced
    pass failed for some OTHER reason. A 0x80073D06 downgrade rejection short-circuits immediately:
    -Force cannot help, and retrying would burn a second multi-hundred-megabyte download before
    failing the same way (issue #265).
.RETURNS
    [hashtable] @{ Available = <bool>; Succeeded = <bool>; DowngradeRejected = <bool>; Message = <string> }
    Available is False when the Microsoft.WinGet.Client module is missing, in which case no repair
    was attempted. Succeeded means a repair call completed without throwing - callers still verify
    the outcome themselves (winget on PATH, or a source probe).
#>
function Invoke-WingetPackageManagerRepair {
    if (-not (Get-Command Repair-WinGetPackageManager -ErrorAction SilentlyContinue)) {
        return @{ Available = $false; Succeeded = $false; DowngradeRejected = $false; Message = '' }
    }

    $lastMessage = ''
    foreach ($useForce in @($false, $true)) {
        try {
            if ($useForce) {
                Repair-WinGetPackageManager -Latest -Force -ErrorAction Stop
            }
            else {
                Repair-WinGetPackageManager -Latest -ErrorAction Stop
            }

            return @{ Available = $true; Succeeded = $true; DowngradeRejected = $false; Message = '' }
        }
        catch {
            $lastMessage = "$_"

            if (Test-AppxDowngradeRejection -Message $lastMessage) {
                Write-WarningMessage 'Repair-WinGetPackageManager was rejected (0x80073D06): this machine already has a newer framework dependency than the WinGet release pins. That is a WinGet packaging conflict, not a fault on this machine.'
                return @{ Available = $true; Succeeded = $false; DowngradeRejected = $true; Message = $lastMessage }
            }

            Write-WarningMessage "Repair-WinGetPackageManager failed: $lastMessage"
        }
    }

    return @{ Available = $true; Succeeded = $false; DowngradeRejected = $false; Message = $lastMessage }
}
