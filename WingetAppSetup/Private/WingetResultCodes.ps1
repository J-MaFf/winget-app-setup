# winget result codes (review findings P2-15 and P3-16). winget reports its result as a signed Int32
# HRESULT, and every place that printed one showed only the hex value, so a failure such as
# 0x8A150102 (another installation in progress) read as 'package not found after install' plus a
# number. This file is the one table of the codes the installer knows: their winget symbol, what
# they mean in a sentence the summary can show, and how the install should treat them. Every place
# that prints a winget exit code goes through Format-WingetExitCode, and Install-WingetPackage
# decides its retries from the class below, so the name, the message and the behaviour cannot drift
# apart. Values come from winget's own table (doc/windows/package-manager/winget/returnCodes.md,
# "winget error --output"); the classes from how winget maps installer exit codes
# (AppInstallerCLICore Workflows/InstallFlow.cpp ReportInstallerResult and Manifest/ManifestCommon.cpp
# GetDefaultKnownReturnCodes). Runs under Windows PowerShell 5.1 too (the PowerShell 7 bootstrap
# prints the exit code of winget's PowerShell install), so it uses nothing newer than .NET 4.5.

<#
.SYNOPSIS
    Returns what the installer knows about a winget exit code, or $null for an unknown code.
.DESCRIPTION
    Keys are the hex form winget's documentation and issues use (0x8A150102). Classes:

      InstallInProgress     Windows Installer was busy with another installation (msiexec 1618).
                            Wait for it and retry (Install-WingetPackage).
      InUse                 The app or its files were in use. One delayed retry.
      RestartRequiredFirst  The installer cannot run until Windows restarts (Inno exit 8). Never
                            retried: only a restart changes it.
      RestartRequired       The package installed, and a restart finishes it (MSI 3010 on winget
                            1.6 and older, which newer winget reports as exit 0 with a warning), or
                            the installer started a restart itself (MSI 1641).
      (empty)               Named for the reader only; no special handling.
.PARAMETER ExitCode
    The exit code as winget reports it (a signed Int32), or $null.
.RETURNS
    [pscustomobject] @{ ExitCode; Hex; Name; Meaning; Class }, or $null when the code is $null, 0 or
    not in the table.
#>
function Get-WingetExitCodeInfo {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[int]]$ExitCode
    )

    if ($null -eq $ExitCode -or $ExitCode -eq 0) {
        return $null
    }

    # Name: the winget symbol without its APPINSTALLER_CLI_ERROR_ prefix (or the Windows symbol),
    # searchable in winget's returnCodes.md. Meaning: a clause that completes "Failed to install: X
    # (...)" and says what to do where there is something to do.
    $table = @{
        # Installer results (winget's installer-exit-code mapping).
        '0x8A150102' = @('INSTALL_INSTALL_IN_PROGRESS', 'another installation was in progress (Windows Installer was busy) - re-run the installer once it has finished', 'InstallInProgress')
        '0x8A150101' = @('INSTALL_PACKAGE_IN_USE', 'the app is running - close it, then re-run the installer', 'InUse')
        '0x8A150103' = @('INSTALL_FILE_IN_USE', 'files the installer needs are in use - close the app, then re-run the installer', 'InUse')
        '0x8A150111' = @('INSTALL_PACKAGE_IN_USE_BY_APPLICATION', 'the app is in use by another application - close it, then re-run the installer', 'InUse')
        '0x8A150109' = @('INSTALL_REBOOT_REQUIRED_TO_FINISH', 'a restart is required to finish the installation', 'RestartRequired')
        '0x8A15010A' = @('INSTALL_REBOOT_REQUIRED_FOR_INSTALL', 'a restart is required before this installer can run - restart this PC, then re-run the installer', 'RestartRequiredFirst')
        '0x8A15010B' = @('INSTALL_REBOOT_INITIATED', 'the installer started a restart of this PC - re-run the installer after the restart', 'RestartRequired')
        '0x8A15010C' = @('INSTALL_CANCELLED_BY_USER', 'the installation was cancelled', '')
        '0x8A15010D' = @('INSTALL_ALREADY_INSTALLED', 'another version of the app is already installed', '')
        '0x8A15010E' = @('INSTALL_DOWNGRADE', 'a higher version of the app is already installed', '')
        '0x8A15010F' = @('INSTALL_BLOCKED_BY_POLICY', 'organization policy blocks this installation', '')
        '0x8A150104' = @('INSTALL_MISSING_DEPENDENCY', 'a dependency of the package is missing from this system', '')
        '0x8A150105' = @('INSTALL_DISK_FULL', 'the disk is full - free some space, then re-run the installer', '')
        '0x8A150106' = @('INSTALL_INSUFFICIENT_MEMORY', 'there was not enough memory to install', '')
        '0x8A150107' = @('INSTALL_NO_NETWORK', 'the installer needs an internet connection', '')
        '0x8A150108' = @('INSTALL_CONTACT_SUPPORT', 'the installer failed (Windows Installer service error)', '')
        '0x8A150110' = @('INSTALL_DEPENDENCIES', 'a dependency of the package failed to install', '')
        '0x8A150112' = @('INSTALL_INVALID_PARAMETER', 'the installer rejected its parameters', '')
        '0x8A150113' = @('INSTALL_SYSTEM_NOT_SUPPORTED', 'the package does not support this system', '')
        '0x8A150115' = @('INSTALL_CUSTOM_ERROR', 'the installer failed with its own error', '')
        '0x8A150006' = @('SHELLEXEC_INSTALL_FAILED', 'the installer failed (its own exit code is in the log above, and in its installer log)', '')
        '0x8A150049' = @('MSI_INSTALL_FAILED', 'the MSI installer failed (its own exit code is in the log above, and in its installer log)', '')
        '0x8A150052' = @('PORTABLE_INSTALL_FAILED', 'the portable package failed to install', '')
        # Package selection, download and agreements.
        '0x8A150010' = @('NO_APPLICABLE_INSTALLER', 'no installer in the package applies to this system', '')
        '0x8A15002B' = @('UPDATE_NOT_APPLICABLE', 'no applicable update was found for the installed version', '')
        '0x8A150061' = @('PACKAGE_ALREADY_INSTALLED', 'a version of the package is already installed', '')
        '0x8A15008E' = @('UPDATE_INSTALL_TECHNOLOGY_MISMATCH', 'the installed version uses a different install technology', '')
        '0x8A150068' = @('PACKAGE_IS_PINNED', 'the package is pinned in winget', '')
        '0x8A150011' = @('INSTALLER_HASH_MISMATCH', 'the downloaded installer does not match the hash in its manifest', '')
        '0x8A150086' = @('INSTALLER_ZERO_BYTE_FILE', 'the installer download was empty (network or proxy problem)', '')
        '0x8A15006D' = @('SERVICE_UNAVAILABLE', 'a download server was busy or unavailable - re-run the installer later', '')
        '0x8A150041' = @('PACKAGE_AGREEMENTS_NOT_ACCEPTED', 'the package agreements were not accepted', '')
        '0x8A150046' = @('SOURCE_AGREEMENTS_NOT_ACCEPTED', 'the source agreements were not accepted', '')
        # winget itself and its sources.
        '0x8A150001' = @('INTERNAL_ERROR', 'winget hit an internal error', '')
        '0x8A150002' = @('INVALID_CL_ARGUMENTS', 'winget rejected its command line', '')
        '0x8A150003' = @('COMMAND_FAILED', 'the winget command failed', '')
        '0x8A15000F' = @('SOURCE_DATA_MISSING', 'the winget source data is missing', '')
        '0x8A150014' = @('NO_APPLICATIONS_FOUND', 'winget found no package with that id', '')
        '0x8A150019' = @('COMMAND_REQUIRES_ADMIN', 'the winget command needs administrator rights', '')
        '0x8A15003A' = @('BLOCKED_BY_POLICY', 'winget is disabled by Group Policy on this PC', '')
        '0x8A15003F' = @('SOURCE_DATA_INTEGRITY_FAILURE', 'the winget source data is corrupted', '')
        '0x8A150045' = @('SOURCE_OPEN_FAILED', 'the winget source could not be opened', '')
        '0x8A15004B' = @('FAILED_TO_OPEN_ALL_SOURCES', 'one or more winget sources could not be opened', '')
        '0x8A150056' = @('INSTALLER_PROHIBITS_ELEVATION', 'the installer cannot run as administrator', '')
        '0x8A15007D' = @('ADMIN_CONTEXT_ACTION_PROHIBITED', 'not permitted as administrator on a package installed for one user', '')
        # Windows HRESULTs winget passes through as its exit code.
        '0x80073D19' = @('ERROR_DEPLOYMENT_BLOCKED_BY_USER_LOG_OFF', 'the installing account has no logon session, so Windows blocked the app package deployment', '')
        # winget maps this to 0x8A150101 for MSIX installs, so it is named here but not retried.
        '0x80073D02' = @('ERROR_PACKAGES_IN_USE', 'the app is running - close it, then re-run the installer', '')
        '0x80004004' = @('E_ABORT', 'the operation was cancelled or stopped', '')
        '0x80072EE2' = @('WININET_E_TIMEOUT', 'the download timed out', '')
        '0x80072EE7' = @('WININET_E_NAME_NOT_RESOLVED', 'the download server name could not be resolved', '')
        '0x80072EFD' = @('WININET_E_CANNOT_CONNECT', 'could not connect to the download server', '')
        '0x80190194' = @('HTTP_E_STATUS_NOT_FOUND', 'the download returned HTTP 404 (not found)', '')
        # The Windows loader's code when winget.exe cannot even start (review finding P2-24), reported
        # where winget.exe runs outside its package, as it does for SYSTEM.
        '0xC0000135' = @('STATUS_DLL_NOT_FOUND', 'winget.exe could not start because a DLL it needs was not found', '')
    }

    $hex = '0x{0:X8}' -f [int]$ExitCode
    if (-not $table.ContainsKey($hex)) {
        return $null
    }
    $row = $table[$hex]
    return [pscustomobject]@{
        ExitCode = [int]$ExitCode
        Hex      = $hex
        Name     = $row[0]
        Meaning  = $row[1]
        Class    = $row[2]
    }
}

<#
.SYNOPSIS
    Formats a winget exit code for a message: its hex form, followed by its name when known.
.DESCRIPTION
    The one way a winget exit code is printed (review findings P2-15, P3-16), for example
    '0x8A150102 INSTALL_INSTALL_IN_PROGRESS', or '0x00000001' for a code the table does not name.
    Winget reports HRESULT-style codes as signed Int32 (e.g. -2147009255); the X8 format renders the
    familiar hex form (0x80073D19) winget's documentation and issues use.
.PARAMETER ExitCode
    The exit code as winget reports it.
.RETURNS
    [string]
#>
function Format-WingetExitCode {
    param (
        [Parameter(Mandatory = $true)]
        [int]$ExitCode
    )

    $info = Get-WingetExitCodeInfo -ExitCode $ExitCode
    if ($info) {
        return ('{0} {1}' -f $info.Hex, $info.Name)
    }
    return ('0x{0:X8}' -f $ExitCode)
}

<#
.SYNOPSIS
    Returns whether an install result says the installer cannot run until Windows restarts.
.DESCRIPTION
    True for 0x8A15010A (INSTALL_REBOOT_REQUIRED_FOR_INSTALL; Inno setup exit 8, for example Git's
    installer while a Windows Update restart is pending). Invoke-WingetInstall's retry pass leaves
    such an app alone, because retrying before a restart fails the same way (review finding P3-16).
.PARAMETER InstallResult
    An Install-AppWithVerification InstallResult (Install-WingetPackage's result, or a package-specific
    installer's), or $null.
.RETURNS
    [bool]
#>
function Test-RestartRequiredFirst {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$InstallResult
    )

    if ($null -eq $InstallResult -or $null -eq $InstallResult.ExitCode) {
        return $false
    }
    $info = Get-WingetExitCodeInfo -ExitCode ([int]$InstallResult.ExitCode)
    return [bool]($info -and $info.Class -eq 'RestartRequiredFirst')
}

<#
.SYNOPSIS
    Returns whether a winget install says the package installed and a restart finishes it.
.DESCRIPTION
    winget 1.7 and later report an MSI, WiX or Burn installer's 3010 as exit 0 and print 'Restart
    your PC to finish installation.'; winget 1.6 and older exit 0x8A150109, and an installer that
    started a restart itself (MSI 1641) gives 0x8A15010B (review finding P3-16). True for any of the
    three. The printed warning is matched in English only; on other display languages
    Invoke-WingetInstall's pending-restart registry check is what notices it. Used by
    Install-WingetPackage for every app and by the PowerShell 7 bootstrap for its winget install of
    PowerShell, so both read winget's result the same way. Runs under Windows PowerShell 5.1 too.
.PARAMETER ExitCode
    winget's exit code, or $null when it did not run to the end.
.PARAMETER Output
    What winget printed (Invoke-WingetProcess's Output).
.RETURNS
    [bool]
#>
function Test-WingetRestartRequiredResult {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[int]]$ExitCode,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object[]]$Output
    )

    if ($null -eq $ExitCode) {
        return $false
    }
    if ($ExitCode -ne 0) {
        $info = Get-WingetExitCodeInfo -ExitCode $ExitCode
        return [bool]($info -and $info.Class -eq 'RestartRequired')
    }
    foreach ($line in @($Output)) {
        if ([string]$line -match 'Restart your PC to finish installation') {
            return $true
        }
    }
    return $false
}
