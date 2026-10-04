# Helpers for Initialize-Winget (Public/WingetCore.ps1), the one ladder that makes winget usable
# for a run: probe, classify the failure, apply the fix for that class (review findings P3-25 to
# P3-31). Each fix runs at most once per run, and the classification comes from exit codes and
# HRESULTs, never from English text.

<#
.SYNOPSIS
    Returns the App Installer Group Policy value that turns off what this installer needs, or $null.
.DESCRIPTION
    Review finding P3-30. Under these policies the winget alias still runs, but every command it
    is given ends with 0x8A15003A BLOCKED_BY_POLICY (or, for the source, finds no winget source),
    and no repair can change that. The values live under
    HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppInstaller (Policy CSP DesktopAppInstaller,
    Computer Configuration > Administrative Templates > Windows Components > Desktop App
    Installer); 0 means Disabled:
      EnableAppInstaller                                'Enable App Installer'
      EnableWindowsPackageManagerCommandLineInterfaces  'Enable Windows Package Manager command line
                                                        interfaces' (Windows 11 24H2 and later)
      EnableDefaultSource                               'Enable App Installer Default Source': the
                                                        winget source every install uses.
    EnableAllowedSources is not checked: it governs only sources added beyond the defaults.
.RETURNS
    [pscustomobject] with Name (the value name) and Policy (its Group Policy name), or $null.
#>
function Get-WingetPolicyBlock {
    try {
        $values = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppInstaller' -ErrorAction Stop
    }
    catch {
        # No such key: nothing is configured.
        return $null
    }

    $policies = [ordered]@{
        EnableAppInstaller                               = 'Enable App Installer'
        EnableWindowsPackageManagerCommandLineInterfaces = 'Enable Windows Package Manager command line interfaces'
        EnableDefaultSource                              = 'Enable App Installer Default Source'
    }
    foreach ($name in $policies.Keys) {
        $value = $values.$name
        if ($null -ne $value -and "$value" -eq '0') {
            return [pscustomobject]@{ Name = $name; Policy = $policies[$name] }
        }
    }
    return $null
}

<#
.SYNOPSIS
    Returns the AppX deployment HRESULT (0x80073xxx) an Appx or WinGet cmdlet failed with, or $null.
.DESCRIPTION
    Review finding P3-27. Reads the HResult of the exception and of each inner exception first. When
    none is an AppX deployment code, the hex form in the message ('HRESULT: 0x80073CF3', which
    Windows prints the same in every display language) is used. The codes that matter here:
      0x80073CF3 ERROR_INSTALL_RESOLVE_DEPENDENCY_FAILED  a framework App Installer needs is missing
                                                          (issue #279: Microsoft.WindowsAppRuntime.1.8)
      0x80073D06 ERROR_INSTALL_PACKAGE_DOWNGRADE          a newer version of a package is already
                                                          installed (issue #265)
.PARAMETER ErrorRecord
    The ErrorRecord (or exception) the cmdlet failed with.
.RETURNS
    [int] or $null.
#>
function Get-AppxErrorCode {
    param (
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$ErrorRecord
    )

    $exception = $ErrorRecord
    if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) {
        $exception = $ErrorRecord.Exception
    }
    while ($exception -is [System.Exception]) {
        if (('0x{0:X8}' -f $exception.HResult).StartsWith('0x80073')) {
            return [int]$exception.HResult
        }
        $exception = $exception.InnerException
    }

    $match = [regex]::Match("$ErrorRecord", '0x80073[0-9A-F]{3}', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($match.Success) {
        return [Convert]::ToInt32($match.Value.Substring(2), 16)
    }
    return $null
}

<#
.SYNOPSIS
    Makes Repair-WinGetPackageManager available, installing the Microsoft.WinGet.Client module when
    it is missing.
.DESCRIPTION
    Called only by the repair rung, so a run whose winget works never installs the module (review
    finding P3-26: every fresh PC used to install the NuGet provider and the module from the
    PowerShell Gallery for a repair that rarely runs, and warned about an update feature that no
    longer exists when the Gallery was blocked). The module is installed for all users from the
    PowerShell Gallery only (review finding P3-20): this runs elevated, so no other repository
    registered on the PC may serve it.
.RETURNS
    [bool] True when Repair-WinGetPackageManager can be called.
#>
function Test-AndInstallWingetModule {
    if (Get-Command Repair-WinGetPackageManager -ErrorAction SilentlyContinue) {
        return $true
    }

    try {
        Write-Info 'Installing the Microsoft.WinGet.Client module for all users from the PowerShell Gallery, for Repair-WinGetPackageManager...'
        if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null
        }
        Install-Module -Name Microsoft.WinGet.Client -Repository PSGallery -Scope AllUsers -Force -AllowClobber -ErrorAction Stop
        Import-Module Microsoft.WinGet.Client -ErrorAction Stop
    }
    catch {
        Write-WarningMessage "The Microsoft.WinGet.Client module could not be installed, so Repair-WinGetPackageManager cannot run: $_"
        return $false
    }
    return [bool](Get-Command Repair-WinGetPackageManager -ErrorAction SilentlyContinue)
}

<#
.SYNOPSIS
    Registers the App Installer (winget) package already on this PC for the current account.
.DESCRIPTION
    winget comes with the Microsoft.DesktopAppInstaller package, which is registered per account. An
    admin account elevating on a signed-in user's PC has none, although the PC has the package on
    disk. Registering it needs no download and deploys no framework, so it cannot hit the 0x80073D06
    rejection the repair cmdlet can (issue #265). Two forms are tried: -RegisterByFamilyName, then
    -Register against each package's AppXManifest.xml.

    The packages are listed with Get-DesktopAppInstallerPackageInfo (`Get-AppxPackage -AllUsers`),
    which under PowerShell 7 runs in Windows PowerShell: there the Appx module always loads, while
    under PowerShell 7 on Windows Server 2022 and older Windows 10 builds it fails with 0x80131539,
    which used to end this step before it registered anything (review finding P3-29).

    The AppX codes the registrations fail with (Get-AppxErrorCode) are returned, so the caller can
    tell a missing framework (0x80073CF3) or a downgrade rejection (0x80073D06) from other failures
    (review finding P3-27: these codes appear here, not in Repair-WinGetPackageManager's error).
.RETURNS
    [pscustomobject] Registered ([bool]: a registration call completed; winget is checked by the
    caller) and ErrorCodes ([int[]]).
#>
function Register-WingetAppInstallerForUser {
    $codes = @()
    try {
        $candidates = @(Get-DesktopAppInstallerPackageInfo)
    }
    catch {
        Write-WarningMessage "Could not list the App Installer packages on this PC: $_"
        return [pscustomobject]@{ Registered = $false; ErrorCodes = $codes }
    }
    if ($candidates.Count -eq 0) {
        Write-Info 'App Installer is not on this PC, so there is nothing to register for this account.'
        return [pscustomobject]@{ Registered = $false; ErrorCodes = $codes }
    }

    Write-Info 'Registering the App Installer package already on this PC for this account...'
    $registrations = @(@{ Label = 'by family name'; Parameters = @{ RegisterByFamilyName = $true; MainPackage = 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe' } })
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate.InstallLocation)) { continue }
        $manifest = Join-Path $candidate.InstallLocation 'AppXManifest.xml'
        if (Test-Path -LiteralPath $manifest) {
            $registrations += @{ Label = "from $manifest"; Parameters = @{ Path = $manifest; Register = $true; DisableDevelopmentMode = $true } }
        }
    }
    foreach ($registration in $registrations) {
        $parameters = $registration.Parameters
        try {
            Add-AppxPackage @parameters -ErrorAction Stop
            Write-Success "App Installer registered for this account ($($registration.Label))."
            return [pscustomobject]@{ Registered = $true; ErrorCodes = $codes }
        }
        catch {
            $code = Get-AppxErrorCode -ErrorRecord $_
            if ($null -ne $code) { $codes += $code }
            Write-WarningMessage "Registering App Installer $($registration.Label) failed: $_"
        }
    }
    return [pscustomobject]@{ Registered = $false; ErrorCodes = $codes }
}

<#
.SYNOPSIS
    Runs Repair-WinGetPackageManager: for all users first when the framework App Installer needs is
    missing, then for this account, unforced and then forced.
.DESCRIPTION
    -AllUsers (review finding P3-28) installs App Installer for the whole PC with the frameworks it
    depends on, which is what the cmdlet itself asks for when Microsoft.WindowsAppRuntime.1.8 is
    missing ('Try running with -AllUsers in administrator mode'). It runs only then: on a PC whose
    framework is newer than the one the WinGet release pins, it aborts with 0x80073D06 (issue #265).
    -Force is tried only after an unforced failure the classifier cannot name: a missing framework
    (0x80073CF3) or a downgrade rejection (0x80073D06) fails the same way however hard it is
    pushed, and each attempt downloads App Installer again. The module is installed here, when it is
    first needed (Test-AndInstallWingetModule).
.PARAMETER AllUsersFirst
    Microsoft.WindowsAppRuntime.1.8 is missing for this PC (Get-WindowsAppRuntimeStatus).
.RETURNS
    [pscustomobject] Available ([bool]: the cmdlet could be called), Succeeded ([bool]: an attempt
    completed; the caller checks winget itself) and ErrorCodes ([int[]], the AppX codes seen).
#>
function Invoke-WingetPackageManagerRepair {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$AllUsersFirst
    )

    $codes = @()
    if (-not (Test-AndInstallWingetModule)) {
        return [pscustomobject]@{ Available = $false; Succeeded = $false; ErrorCodes = $codes }
    }

    $attempts = @()
    if ($AllUsersFirst) {
        $attempts += @{ Label = '-AllUsers -Latest'; Parameters = @{ AllUsers = $true; Latest = $true } }
    }
    $attempts += @{ Label = '-Latest'; Parameters = @{ Latest = $true } }
    $attempts += @{ Label = '-Latest -Force'; Parameters = @{ Latest = $true; Force = $true } }
    foreach ($attempt in $attempts) {
        $parameters = $attempt.Parameters
        Write-Info "Running Repair-WinGetPackageManager $($attempt.Label)..."
        try {
            Repair-WinGetPackageManager @parameters -ErrorAction Stop
            return [pscustomobject]@{ Available = $true; Succeeded = $true; ErrorCodes = $codes }
        }
        catch {
            Write-WarningMessage "Repair-WinGetPackageManager $($attempt.Label) failed: $_"
            $code = Get-AppxErrorCode -ErrorRecord $_
            if ($null -ne $code) {
                $codes += $code
                # 0x80073CF3 and 0x80073D06: retrying, forced or not, fails the same way.
                if (@(-2147009293, -2147009274) -contains $code) {
                    break
                }
            }
        }
    }
    return [pscustomobject]@{ Available = $true; Succeeded = $false; ErrorCodes = $codes }
}

<#
.SYNOPSIS
    Runs the next fix that sets winget up for this account, if one is left; each runs once a run.
.DESCRIPTION
    Cheapest first: register the App Installer already on this PC (Register-WingetAppInstallerForUser),
    then Repair-WinGetPackageManager (for all users first when the all-users check finds
    Microsoft.WindowsAppRuntime.1.8 missing). A registration that fails moves straight on to the
    repair. Initialize-Winget calls this in a loop, checking winget after each fix that ran.
.PARAMETER State
    The run's ladder state, which this updates: Registered, Repair, Framework and ErrorCodes.
.RETURNS
    [bool] True when a fix ran and winget should be checked again; False when none is left.
#>
function Invoke-NextWingetAccountFix {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$State
    )

    if (-not $State.ContainsKey('Registered')) {
        $register = Register-WingetAppInstallerForUser
        $State.Registered = [bool]$register.Registered
        $State.ErrorCodes += @($register.ErrorCodes)
        if ($State.Registered) {
            return $true
        }
    }
    if (-not $State.ContainsKey('Repair')) {
        $State.Framework = Get-WindowsAppRuntimeStatus
        $State.Repair = Invoke-WingetPackageManagerRepair -AllUsersFirst:($State.Framework.Present -eq $false)
        $State.ErrorCodes += @($State.Repair.ErrorCodes)
        return [bool]$State.Repair.Available
    }
    return $false
}

<#
.SYNOPSIS
    Returns the one line that says how to fix what the ladder could not, from what it saw.
.PARAMETER State
    The ladder state (Invoke-NextWingetAccountFix).
.PARAMETER Account
    Who the run installs as: the account name, or 'SYSTEM'.
.PARAMETER Source
    The winget source could not be set up. Without it, the advice is for a winget that cannot be
    started.
.PARAMETER SourceExitCode
    The source check's exit code, if it ran to the end.
.RETURNS
    [string]
#>
function Get-WingetSetupAdvice {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$State,

        [Parameter(Mandatory = $true)]
        [string]$Account,

        [Parameter(Mandatory = $false)]
        [switch]$Source,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[int]]$SourceExitCode
    )

    if ($Source) {
        if ($SourceExitCode -eq -2147009255 -and $Account -eq 'SYSTEM') {
            return 'The steps that set winget up for a signed-in account do not apply to SYSTEM; if the installs fail, run the installer once as an administrator signed in to this PC.'
        }
        if ($SourceExitCode -eq -2147009255) {
            return "Fix: sign in to Windows as '$Account' once (that sets winget up for the account), or run 'winget source update' in a session running as '$Account', then re-run the installer."
        }
        return 'Fix: check that this PC can reach https://cdn.winget.microsoft.com, then re-run the installer.'
    }
    if ($State.Framework -and $State.Framework.Present -eq $false) {
        return "Fix: install the Microsoft.WindowsAppRuntime.1.8 framework App Installer depends on, which this PC lacks ($($State.Framework.Detail)), or let the Microsoft Store update App Installer, then re-run the installer (issue #279)."
    }
    if (@($State.ErrorCodes) -contains -2147009274) {
        return 'Fix: a framework package on this PC is newer than the one the WinGet release deploys, so App Installer could not be repaired; update App Installer from the Microsoft Store on this PC, then re-run the installer.'
    }
    if ($State.Repair -and -not $State.Repair.Available) {
        return 'Fix: install App Installer from the Microsoft Store or https://aka.ms/getwinget (Repair-WinGetPackageManager could not run: its PowerShell module could not be installed), then re-run the installer.'
    }
    return 'Fix: install or update App Installer from the Microsoft Store or https://aka.ms/getwinget, then re-run the installer.'
}

<#
.SYNOPSIS
    Updates the winget source for the account running winget, which also registers it on first use.
.DESCRIPTION
    `winget source update --name winget --disable-interactivity`, the lightest command that makes
    winget register its source package for an account that has never used it (on a cross-user
    elevation that registration is what fails with 0x80073D19). Only the winget source: the
    installs use no other, and msstore can fail for an account that never signed in while the winget
    source is fine. No --accept-source-agreements: `source update` rejects it with 0x8A150002
    (issues #174/#175); the installs accept the agreements. winget's output is echoed into the
    transcript only when the update fails.
.RETURNS
    [hashtable] @{ Succeeded; ExitCode (or $null); TimedOut; LaunchError (or $null) }
#>
function Invoke-WingetSourceProbe {
    $probe = Invoke-WingetProcess -ArgumentList @('source', 'update', '--name', 'winget', '--disable-interactivity') -TimeoutSeconds (Get-ProcessTimeoutSeconds -Operation WingetSourceUpdate) -Echo None
    if ($probe.LaunchFailed) {
        return @{ Succeeded = $false; ExitCode = $null; TimedOut = $false; LaunchError = $probe.LaunchError }
    }
    if ($probe.TimedOut -or $probe.ExitCode -ne 0) {
        Write-ProcessOutput -Line $probe.Output -Tail 20
    }
    return @{
        Succeeded   = (-not $probe.TimedOut -and $probe.ExitCode -eq 0)
        ExitCode    = $probe.ExitCode
        TimedOut    = [bool]$probe.TimedOut
        LaunchError = $null
    }
}

<#
.SYNOPSIS
    Runs `winget source reset --force` and says whether it worked, with its exit code when not.
.DESCRIPTION
    The fix for a missing or corrupted winget source. It also removes any source added beyond the
    defaults. No --accept-source-agreements: `source reset` rejects it with 0x8A150002, so the reset
    used to never run.
.RETURNS
    [bool]
#>
function Reset-WingetSource {
    Write-Info 'Resetting the winget source (winget source reset --force)...'
    $reset = Invoke-WingetProcess -ArgumentList @('source', 'reset', '--force', '--disable-interactivity') -TimeoutSeconds (Get-ProcessTimeoutSeconds -Operation WingetSourceReset)
    if ($reset.LaunchFailed) {
        Write-WarningMessage "Winget source reset failed: $($reset.LaunchError)"
    }
    elseif ($reset.TimedOut) {
        Write-WarningMessage 'Winget source reset failed: it did not finish in time and was stopped.'
    }
    elseif ($reset.ExitCode -ne 0) {
        Write-WarningMessage ('Winget source reset failed with exit code {0}.' -f (Format-WingetExitCode -ExitCode $reset.ExitCode))
    }
    else {
        Write-Info 'Source reset completed.'
        return $true
    }
    return $false
}
