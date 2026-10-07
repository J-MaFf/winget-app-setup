# Helpers for Initialize-Winget (Public/WingetCore.ps1): probe, classify the failure, apply that
# class's fix. Each fix runs at most once a run, and the class comes from exit codes and HRESULTs,
# never from English text.

<#
.SYNOPSIS
    Returns the App Installer Group Policy value that turns off what this installer needs, or $null.
.DESCRIPTION
    Under these policies every winget command ends with 0x8A15003A BLOCKED_BY_POLICY (or finds no
    source), and no repair changes that (P3-30). The values live under
    HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppInstaller; 0 means Disabled:
      EnableAppInstaller                                'Enable App Installer'
      EnableWindowsPackageManagerCommandLineInterfaces  'Enable Windows Package Manager command line
                                                        interfaces' (Windows 11 24H2 and later)
      EnableDefaultSource                               'Enable App Installer Default Source'
    EnableAllowedSources governs only sources added beyond the defaults, so it is not checked.
.OUTPUTS
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
    Prints the one line that says Group Policy blocks winget and what to do about it.
.DESCRIPTION
    Shared by Invoke-EnvironmentPreflight and Initialize-Winget (which also recognizes winget's own
    0x8A15003A answer); a run prints it once.
.PARAMETER Block
    Get-WingetPolicyBlock's result: the line names the policy and its registry value.
.PARAMETER Detail
    What showed the block instead, for example "'winget --version' answered 0x8A15003A ...".
.PARAMETER WhatIf
    Dry run: an informational [DRY-RUN] line that says a real run would stop with exit code 2.
#>
function Write-WingetPolicyBlockMessage {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Block,

        [Parameter(Mandatory = $false)]
        [string]$Detail,

        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    if ($Block) {
        $Detail = "'{0}' is Disabled ({1} = 0 under HKLM\SOFTWARE\Policies\Microsoft\Windows\AppInstaller)" -f $Block.Policy, $Block.Name
    }
    $message = "Group Policy on this PC blocks winget: $Detail. This installer cannot install apps until the policy allows it; ask whoever manages this PC's policies (Computer Configuration > Administrative Templates > Windows Components > Desktop App Installer) to allow it, then re-run the installer."
    if ($WhatIf) {
        Write-Info "[DRY-RUN] $message A real run would stop here with exit code 2."
    }
    else {
        Write-ErrorMessage $message
    }
}

<#
.SYNOPSIS
    Returns the AppX deployment HRESULT (0x80073xxx) an Appx or WinGet cmdlet failed with, or $null.
.DESCRIPTION
    The HResult of the exception or an inner one first, then the hex form in the message, which
    Windows prints the same in every display language (P3-27). The codes that matter:
      0x80073CF3 ERROR_INSTALL_RESOLVE_DEPENDENCY_FAILED  a framework App Installer needs is missing
                                                          (issue #279)
      0x80073D06 ERROR_INSTALL_PACKAGE_DOWNGRADE          a newer version is already installed
                                                          (issue #265)
.PARAMETER ErrorRecord
    The ErrorRecord (or exception) the cmdlet failed with.
.OUTPUTS
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
    Only the repair step calls it, so a run whose winget works never installs the module (P3-26).
    Installed for all users from the PowerShell Gallery only (-Repository PSGallery, P3-20): this
    runs elevated, so no other registered repository may serve it.
.OUTPUTS
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
    Registers an app package for the current account with Add-AppxPackage, by family name, from
    its AppXManifest.xml or from a package file; throws when the registration fails.
.DESCRIPTION
    A seam for Register-WingetAppInstallerForUser and Register-WingetSourcePackage. Under
    PowerShell 7 it runs in Windows PowerShell 5.1 as the same account: the Appx module cannot load
    under PowerShell 7 before Windows build 10.0.22453 (0x80131539, PowerShell issue #13138), and
    always loads in 5.1. The HRESULT the child caught is rethrown as a COMException carrying it, so
    Get-AppxErrorCode reads it as it would from Add-AppxPackage itself.
.PARAMETER FamilyName
    Add-AppxPackage -RegisterByFamilyName -MainPackage <FamilyName>.
.PARAMETER ManifestPath
    Add-AppxPackage -Register <ManifestPath> -DisableDevelopmentMode.
.PARAMETER PackagePath
    Add-AppxPackage -Path <PackagePath>: installs the .msix file for this account.
#>
function Invoke-AppxRegistration {
    [CmdletBinding(DefaultParameterSetName = 'FamilyName')]
    param (
        [Parameter(Mandatory = $true, ParameterSetName = 'FamilyName')]
        [string]$FamilyName,

        [Parameter(Mandatory = $true, ParameterSetName = 'Manifest')]
        [string]$ManifestPath,

        [Parameter(Mandatory = $true, ParameterSetName = 'Package')]
        [string]$PackagePath
    )

    if ($PSCmdlet.ParameterSetName -eq 'FamilyName') {
        $parameters = @{ RegisterByFamilyName = $true; MainPackage = $FamilyName }
        # Each value goes into a single-quoted literal of the child's -Command string, so embedded
        # single quotes are doubled (issue #178).
        $arguments = "-RegisterByFamilyName -MainPackage '{0}'" -f $FamilyName.Replace("'", "''")
    }
    elseif ($PSCmdlet.ParameterSetName -eq 'Package') {
        $parameters = @{ Path = $PackagePath }
        $arguments = "-Path '{0}'" -f $PackagePath.Replace("'", "''")
    }
    else {
        $parameters = @{ Path = $ManifestPath; Register = $true; DisableDevelopmentMode = $true }
        $arguments = "-Path '{0}' -Register -DisableDevelopmentMode" -f $ManifestPath.Replace("'", "''")
    }

    if ($PSVersionTable.PSEdition -ne 'Core') {
        Add-AppxPackage @parameters -ErrorAction Stop
        return
    }

    $command = "`$ProgressPreference = 'SilentlyContinue'; try { Add-AppxPackage $arguments -ErrorAction Stop } catch { 'ERR|{0}|{1}' -f `$_.Exception.HResult, (`$_.Exception.Message -replace '\s+', ' '); exit 1 }"
    $lines = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $command)
    $exitCode = $LASTEXITCODE
    if ($exitCode -eq 0) {
        return
    }
    foreach ($line in $lines) {
        $parts = "$line" -split '\|', 3
        if ($parts.Count -eq 3 -and $parts[0] -eq 'ERR') {
            $hresult = 0
            if ([int]::TryParse($parts[1], [ref]$hresult) -and $hresult -ne 0) {
                throw [System.Runtime.InteropServices.COMException]::new($parts[2].Trim(), $hresult)
            }
            throw $parts[2].Trim()
        }
    }
    throw "Add-AppxPackage $arguments failed in Windows PowerShell (exit code $exitCode)."
}

<#
.SYNOPSIS
    Registers the App Installer (winget) package already on this PC for the current account.
.DESCRIPTION
    App Installer is registered per account, so an admin account elevating on a user's PC has none
    although the package is on disk. Registering it downloads nothing and deploys no framework, so
    it cannot hit the 0x80073D06 rejection the repair can (issue #265). Tries -RegisterByFamilyName,
    then -Register against each package's AppXManifest.xml. The listing and the registrations run in
    Windows PowerShell under PowerShell 7 (P3-29). The AppX codes they fail with are returned, so
    the caller can tell a missing framework (0x80073CF3) or a downgrade (0x80073D06) from the rest.
.OUTPUTS
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
    $registrations = @(@{ Label = 'by family name'; Parameters = @{ FamilyName = 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe' } })
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate.InstallLocation)) { continue }
        $manifest = Join-Path $candidate.InstallLocation 'AppXManifest.xml'
        if (Test-Path -LiteralPath $manifest) {
            $registrations += @{ Label = "from $manifest"; Parameters = @{ ManifestPath = $manifest } }
        }
    }
    foreach ($registration in $registrations) {
        $parameters = $registration.Parameters
        try {
            Invoke-AppxRegistration @parameters -ErrorAction Stop
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
    missing, then for this account, unforced and then, unless the cause is known, forced.
.DESCRIPTION
    -AllUsers installs App Installer for the whole PC with its frameworks, as the cmdlet asks for
    when Microsoft.WindowsAppRuntime.1.8 is missing (P3-28); only then, because with a newer
    framework than the release pins it aborts with 0x80073D06 (issue #265). -Force only closes
    running App Installer processes and downloads it again, so it is tried only after a failure
    nothing has named: not after a missing framework (0x80073CF3) or a downgrade (0x80073D06), seen
    here or by the registration before it (KnownErrorCodes), nor when the all-users repair for a
    missing framework failed (P3-27). The module is installed here, when first needed.
.PARAMETER AllUsersFirst
    Microsoft.WindowsAppRuntime.1.8 is missing for this PC (Get-WindowsAppRuntimeStatus).
.PARAMETER KnownErrorCodes
    The AppX codes this run has already seen, from the App Installer registration.
.OUTPUTS
    [pscustomobject] Available ([bool]: the cmdlet could be called), Succeeded ([bool]: an attempt
    completed; the caller checks winget itself) and ErrorCodes ([int[]], the AppX codes this repair
    saw).
#>
function Invoke-WingetPackageManagerRepair {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$AllUsersFirst,

        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [int[]]$KnownErrorCodes = @()
    )

    # 0x80073CF3 and 0x80073D06: retrying, forced or not, fails the same way.
    $finalCodes = @(-2147009293, -2147009274)
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
        if ($parameters.Force) {
            $named = @(@($KnownErrorCodes) | Where-Object { $finalCodes -contains $_ } | Select-Object -Unique)
            $cause = $null
            if ($named.Count -gt 0) {
                $cause = 'registering App Installer failed with {0}' -f (@($named | ForEach-Object { Format-WingetExitCode -ExitCode $_ }) -join ', ')
            }
            elseif ($AllUsersFirst) {
                $cause = 'the Microsoft.WindowsAppRuntime.1.8 framework App Installer needs is missing, and the all-users repair for it failed'
            }
            if ($cause) {
                Write-Info "Not running Repair-WinGetPackageManager $($attempt.Label): $cause, which forcing cannot fix (-Force only closes running App Installer processes)."
                break
            }
        }
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
                if ($finalCodes -contains $code) {
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
    Cheapest first: Register-WingetAppInstallerForUser, then Invoke-WingetPackageManagerRepair,
    which is told the AppX codes the registration saw. Initialize-Winget calls this in a loop and
    checks winget after each fix that ran.
.PARAMETER State
    The run's ladder state, which this updates: Registered, Repair, Framework and ErrorCodes.
.OUTPUTS
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
        $State.Repair = Invoke-WingetPackageManagerRepair -AllUsersFirst:($State.Framework.Present -eq $false) -KnownErrorCodes @($State.ErrorCodes)
        $State.ErrorCodes += @($State.Repair.ErrorCodes)
        return [bool]$State.Repair.Available
    }
    return $false
}

<#
.SYNOPSIS
    Returns where to get the winget source package and how to check it: its family name, the
    addresses winget itself downloads it from, in winget's order, and its signer.
.OUTPUTS
    [pscustomobject] Name, FamilyName, Urls ([string[]]) and SignerCommonName.
#>
function Get-WingetSourcePackageDefinition {
    [pscustomobject]@{
        Name             = 'Microsoft.Winget.Source'
        FamilyName       = 'Microsoft.Winget.Source_8wekyb3d8bbwe'
        Urls             = @('https://cdn.winget.microsoft.com/cache/source2.msix', 'https://cdn.winget.microsoft.com/cache/source.msix')
        SignerCommonName = 'Microsoft Corporation'
    }
}

<#
.SYNOPSIS
    Downloads a file into a new file that this call creates, never into one that is already there.
.DESCRIPTION
    The response is read whole (Invoke-WebRequest, with Get-WebDownloadTimeoutParameters' limits),
    then written to a file opened with CreateNew, so no entry someone else left at the path is
    opened for writing. Throws when the download or the write fails.
.PARAMETER Uri
    What to download.
.PARAMETER Path
    The new file.
#>
function Save-WebFileAsNew {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    # Windows PowerShell's progress bar slows a download down many times over.
    $ProgressPreference = 'SilentlyContinue'
    if ($PSVersionTable.PSEdition -ne 'Core') {
        # 5.1 (the uninstaller) may default to a protocol set without TLS 1.2; added, never removed.
        try {
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
        }
        catch {
            # Best-effort: on anything modern the default already includes TLS 1.2.
        }
    }
    $timeouts = Get-WebDownloadTimeoutParameters
    $response = Invoke-WebRequest @timeouts -Uri $Uri -UseBasicParsing -ErrorAction Stop
    $content = $response.RawContentStream
    if ($null -eq $content) {
        throw "the response from $Uri has no content"
    }
    $file = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $content.Position = 0
        $content.CopyTo($file)
    }
    finally {
        $file.Dispose()
    }
}

<#
.SYNOPSIS
    Registers the winget source package (Microsoft.Winget.Source) for the account this run installs
    as, the fix for 0x8A15000F SOURCE_DATA_MISSING.
.DESCRIPTION
    winget deploys its source package for each account itself, and that deployment fails without a
    word under cross-user elevation (0x80073D19), while Add-AppxPackage from this process succeeds
    there (wgt-gq8.63). Cheapest first:
      1. A copy already on this PC (Get-WingetSourcePackageInfo): -RegisterByFamilyName, no download.
      2. Otherwise source2.msix, then source.msix if that download fails (winget's own order), into
         a new file in a new folder only SYSTEM and Administrators can change
         (New-WauStagingDirectory, Save-WebFileAsNew). It is held open read-only from its signature
         check (Microsoft Corporation, Test-AuthenticodeSigner) until Add-AppxPackage -Path has
         installed it, then deleted.
    Both run through Invoke-AppxRegistration, in Windows PowerShell under PowerShell 7. Not for
    SYSTEM, whose winget.exe keeps its source in a file and has no packages of its own.
.OUTPUTS
    [pscustomobject] Registered ([bool]: Add-AppxPackage completed; the caller opens the source
    again), ErrorCodes ([int[]], the AppX codes seen) and Reason (why it is not registered, or $null).
#>
function Register-WingetSourcePackage {
    $definition = Get-WingetSourcePackageDefinition
    $codes = @()
    $reason = $null

    $staged = @()
    try {
        $staged = @(Get-WingetSourcePackageInfo)
    }
    catch {
        Write-WarningMessage "Could not list the winget source packages on this PC: $_"
    }
    if ($staged.Count -gt 0) {
        Write-Info "Registering the winget source package already on this PC ($($definition.Name)) for this account..."
        try {
            Invoke-AppxRegistration -FamilyName $definition.FamilyName -ErrorAction Stop
            Write-Success 'The winget source package is registered for this account (by family name).'
            return [pscustomobject]@{ Registered = $true; ErrorCodes = $codes; Reason = $null }
        }
        catch {
            $code = Get-AppxErrorCode -ErrorRecord $_
            if ($null -ne $code) { $codes += $code }
            Write-WarningMessage "Registering the winget source package by family name failed: $_"
        }
    }

    $stagingDir = $null
    $stream = $null
    $registered = $false
    $stage = 'setting up its download folder'
    try {
        $stagingDir = New-WauStagingDirectory -Prefix 'wingetsource'
        $packagePath = Join-Path $stagingDir ('source-{0}.msix' -f [guid]::NewGuid().ToString('N'))
        $downloadedFrom = $null
        foreach ($url in @($definition.Urls)) {
            $stage = "downloading $url"
            Write-Info "Downloading the winget source package from $url..."
            try {
                Save-WebFileAsNew -Uri $url -Path $packagePath
                $downloadedFrom = $url
                break
            }
            catch {
                Write-WarningMessage "Could not download $url ($($_.Exception.Message))."
                Remove-Item -LiteralPath $packagePath -Force -ErrorAction SilentlyContinue
            }
        }
        if (-not $downloadedFrom) {
            $reason = 'it could not be downloaded from https://cdn.winget.microsoft.com/cache'
        }
        else {
            # Held open, read-only for others too, from the check until Add-AppxPackage has finished,
            # as winget holds its own download while it deploys it.
            $stage = 'checking its signature'
            $stream = Open-ReadLockedFile -Path $packagePath
            $signature = Test-AuthenticodeSigner -Path $packagePath -SignerCommonName $definition.SignerCommonName
            if (-not $signature.Valid) {
                $reason = "the package downloaded from $downloadedFrom failed its signature check: $($signature.Detail)"
            }
            else {
                $stage = 'registering it'
                Write-Info "Verified its signature ($($signature.Detail)); registering it for this account..."
                Invoke-AppxRegistration -PackagePath $packagePath -ErrorAction Stop
                Write-Success "The winget source package is registered for this account (from $downloadedFrom)."
                $registered = $true
            }
        }
    }
    catch {
        $code = Get-AppxErrorCode -ErrorRecord $_
        if ($null -ne $code) { $codes += $code }
        $reason = "$stage failed: $("$($_.Exception.Message)".Trim().TrimEnd('.'))"
        if ($_.FullyQualifiedErrorId -eq 'RestrictedDirectoryAclFailed') {
            $reason += (Get-RestrictedDirectoryResetHint -Path (Join-Path $env:ProgramData 'winget-app-setup'))
        }
    }
    finally {
        # Closed first: the open handle refuses deletion.
        if ($stream) {
            $stream.Dispose()
        }
        if ($stagingDir) {
            Remove-Item -LiteralPath $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if (-not $registered -and $reason) {
        # The reset hint ends with a full stop of its own.
        $reason = "$reason".Trim().TrimEnd('.')
        Write-WarningMessage "The winget source package could not be registered for this account: $reason."
    }
    return [pscustomobject]@{ Registered = $registered; ErrorCodes = $codes; Reason = $reason }
}

<#
.SYNOPSIS
    Returns the version of the Microsoft.WinGet.Client module Repair-WinGetPackageManager would run
    from, or $null when there is none.
.OUTPUTS
    [version] or $null.
#>
function Get-WingetClientRepairVersion {
    $command = Get-Command -Name 'Repair-WinGetPackageManager' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) {
        return $null
    }
    $version = $command.Version
    if (-not $version -and $command.Module) {
        $version = $command.Module.Version
    }
    if (-not $version) {
        return $null
    }
    return [version]$version
}

<#
.SYNOPSIS
    Runs the next fix for a winget source that cannot be opened, if one is left; each runs once a
    run.
.DESCRIPTION
    By the code the source check answered (Get-WingetExitCodeInfo class SourceBroken):
      - 0x8A15000F SOURCE_DATA_MISSING, for an account other than SYSTEM: Register-WingetSourcePackage,
        then Invoke-WingetPackageManagerRepair, but only with Microsoft.WinGet.Client 1.28.190 or
        later already installed: older ones never check the source, and it adds the package the
        same way. Never a reset: `winget source reset` deploys nothing. SYSTEM gets no fix.
      - Any other SourceBroken code (corrupted or unconfigured source): `winget source reset --force`.
    Initialize-Winget calls this in a loop and checks the source after each fix that ran.
.PARAMETER State
    The run's ladder state, which this updates: SourcePackage, Repair, SourceReset and ErrorCodes.
.PARAMETER ExitCode
    The source check's exit code.
.PARAMETER IsSystem
    The run is SYSTEM.
.OUTPUTS
    [bool] True when a fix ran and the source should be checked again; False when none is left.
#>
function Invoke-NextWingetSourceFix {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$State,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[int]]$ExitCode,

        [Parameter(Mandatory = $false)]
        [switch]$IsSystem
    )

    # 0x8A15000F APPINSTALLER_CLI_ERROR_SOURCE_DATA_MISSING as a signed Int32.
    if ($ExitCode -eq -1978335217) {
        if ($IsSystem) {
            return $false
        }
        if (-not $State.ContainsKey('SourcePackage')) {
            $State.SourcePackage = Register-WingetSourcePackage
            $State.ErrorCodes += @($State.SourcePackage.ErrorCodes)
            if ($State.SourcePackage.Registered) {
                return $true
            }
        }
        if (-not $State.ContainsKey('Repair')) {
            $moduleVersion = Get-WingetClientRepairVersion
            if ($moduleVersion -and $moduleVersion -ge [version]'1.28.190') {
                $State.Repair = Invoke-WingetPackageManagerRepair -KnownErrorCodes @($State.ErrorCodes)
                $State.ErrorCodes += @($State.Repair.ErrorCodes)
                return [bool]$State.Repair.Available
            }
        }
        return $false
    }
    if (-not $State.ContainsKey('SourceReset')) {
        $State.SourceReset = Reset-WingetSource
        return $true
    }
    return $false
}

<#
.SYNOPSIS
    Returns the folder winget writes its logs to for the account this run installs as.
.PARAMETER System
    The run is SYSTEM: its winget.exe runs outside its package and logs under the temporary folder.
.OUTPUTS
    [string]
#>
function Get-WingetLogDirectory {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$System
    )

    if ($System) {
        return ('{0}\Temp\WinGet\defaultState (or {0}\SystemTemp\WinGet\defaultState)' -f $env:SystemRoot)
    }
    return ('{0}\Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState\DiagOutputDir' -f $env:LOCALAPPDATA)
}

<#
.SYNOPSIS
    Returns the one line that says the winget source cannot be opened, why, where winget's log is
    and what to do.
.PARAMETER State
    The ladder state (Invoke-NextWingetSourceFix).
.PARAMETER AccountContext
    Get-InstallAccountContext's result: SYSTEM and cross-user elevation get their own advice.
.PARAMETER ExitCode
    The exit code the source check answered: 0x8A15000F gets advice on the source package, any
    other code advice on winget's source settings.
.OUTPUTS
    [string]
#>
function Get-WingetSourceUnusableMessage {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$State,

        [Parameter(Mandatory = $true)]
        [object]$AccountContext,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[int]]$ExitCode
    )

    $isSystem = [bool]$AccountContext.IsSystem
    $account = 'SYSTEM'
    $who = 'SYSTEM'
    if (-not $isSystem) {
        $account = "$($AccountContext.ProcessUser)"
        $who = "'$account'"
    }
    $codeText = 'no exit code'
    if ($null -ne $ExitCode) {
        $codeText = Format-WingetExitCode -ExitCode $ExitCode
    }
    $message = "The winget source cannot be opened for ${who}: 'winget search --source winget' answered $codeText, so winget can neither install the apps nor tell which are installed."
    if ($State.SourcePackage -and -not $State.SourcePackage.Registered) {
        $packageCodes = @(@($State.SourcePackage.ErrorCodes) | Select-Object -Unique)
        if ($packageCodes.Count -gt 0) {
            $message += ' Registering the winget source package (Microsoft.Winget.Source) for the account failed ({0}).' -f (@($packageCodes | ForEach-Object { Format-WingetExitCode -ExitCode $_ }) -join ', ')
        }
        elseif ($State.SourcePackage.Reason) {
            $message += " Registering the winget source package (Microsoft.Winget.Source) for the account failed: $($State.SourcePackage.Reason)."
        }
    }
    $message += " winget's log: $(Get-WingetLogDirectory -System:$isSystem)."
    # 0x8A15000F APPINSTALLER_CLI_ERROR_SOURCE_DATA_MISSING as a signed Int32: only that code is a
    # source package Windows did not deploy; the others are winget's own source settings.
    $dataMissing = $ExitCode -eq -1978335217
    if ($isSystem) {
        $message += ' Fix: check that this PC can reach https://cdn.winget.microsoft.com, where winget downloads its source from, then re-run the installer.'
    }
    elseif (-not $dataMissing) {
        $resetNote = ''
        if ($State.ContainsKey('SourceReset')) {
            $resetNote = " 'winget source reset --force' did not fix it."
        }
        $message += "$resetNote Fix: read winget's log for why it cannot read its source settings, check 'winget source list' in a window running as '$account' and that this PC can reach https://cdn.winget.microsoft.com, then re-run the installer."
    }
    elseif ($AccountContext.IsCrossUserElevation) {
        $message += " Fix: '$account' is elevated in the session of '$($AccountContext.SessionUser)' and has no logon session of its own, which Windows needs to deploy winget's source package for it: sign in to Windows once as '$account', or run the machine phase as SYSTEM with rmm/Invoke-WingetAppSetup.ps1, then re-run the installer."
    }
    else {
        $message += " Fix: look in the Microsoft-Windows-AppXDeploymentServer/Operational event log for why Windows could not deploy the Microsoft.Winget.Source package for '$account', and check that this PC can reach https://cdn.winget.microsoft.com, then re-run the installer."
    }
    return $message
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
.OUTPUTS
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
            # Not 'winget source update' as that account: it exits 0 when its update fails.
            return "Fix: sign in to Windows as '$Account' once (that sets winget up for the account), or run the machine phase as SYSTEM with rmm/Invoke-WingetAppSetup.ps1, then re-run the installer."
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
    `winget source update --name winget --disable-interactivity`. Only the winget source, the one
    the installs use. No --accept-source-agreements: `source update` rejects it with 0x8A150002
    (issues #174/#175). Exit 0 does not mean the update worked: winget prints 'Cancelled' and exits
    0 when it fails, so Test-WingetSourceOpen checks the source after it. winget's output is echoed
    into the transcript only when the exit code is not 0.
.OUTPUTS
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
    Returns the arguments of the winget call that opens the winget source: a search for one package
    in it.
.OUTPUTS
    [string[]]
#>
function Get-WingetSourceOpenArgument {
    return @('search', '--exact', '--id', 'Microsoft.PowerShell', '--source', 'winget', '--accept-source-agreements', '--disable-interactivity')
}

<#
.SYNOPSIS
    Returns whether a source-open exit code means winget opened the winget source.
.DESCRIPTION
    0 (found) and 0x8A150014 NO_APPLICATIONS_FOUND (opened, nothing matched) mean it opened. With
    --source winget, a source that cannot be opened fails the command with its own code, such as
    0x8A15000F SOURCE_DATA_MISSING.
.PARAMETER ExitCode
    The exit code, or $null.
.OUTPUTS
    [bool]
#>
function Test-WingetSourceOpenExitCode {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Nullable[int]]$ExitCode
    )

    return ($null -ne $ExitCode -and @(0, -1978335212) -contains [int]$ExitCode)
}

<#
.SYNOPSIS
    Checks that winget can open the winget source for the account running it, the one every install
    uses.
.DESCRIPTION
    `winget search --exact --id Microsoft.PowerShell --source winget --accept-source-agreements
    --disable-interactivity` (Get-WingetSourceOpenArgument) under the WingetSourceOpen limit. It
    opens the source the way `winget install --source winget` does, so it fails where the installs
    would, unlike `winget source update`, which exits 0 when its update fails. winget's output is
    echoed into the transcript when it does not open.
.OUTPUTS
    [hashtable] @{ Opened = $true, $false, or $null for no answer (timeout or launch failure);
    ExitCode (or $null); TimedOut; LaunchError (or $null) }
#>
function Test-WingetSourceOpen {
    $run = Invoke-WingetProcess -ArgumentList (Get-WingetSourceOpenArgument) -TimeoutSeconds (Get-ProcessTimeoutSeconds -Operation WingetSourceOpen) -Echo None
    if ($run.LaunchFailed) {
        return @{ Opened = $null; ExitCode = $null; TimedOut = $false; LaunchError = $run.LaunchError }
    }
    if ($run.TimedOut) {
        Write-ProcessOutput -Line $run.Output -Tail 20
        return @{ Opened = $null; ExitCode = $null; TimedOut = $true; LaunchError = $null }
    }
    $opened = Test-WingetSourceOpenExitCode -ExitCode $run.ExitCode
    if (-not $opened) {
        Write-ProcessOutput -Line $run.Output -Tail 20
    }
    return @{ Opened = $opened; ExitCode = $run.ExitCode; TimedOut = $false; LaunchError = $null }
}

<#
.SYNOPSIS
    Updates the winget source, then checks that winget can open it.
.DESCRIPTION
    Invoke-WingetSourceProbe, then Test-WingetSourceOpen, whose answer decides: an update that
    failed matters only if the source then does not open. An update that timed out, could not
    start or answered 0x8A15003A (Group Policy) is the answer itself.
.OUTPUTS
    [hashtable] @{ Succeeded (the source opened); ExitCode (or $null); TimedOut; LaunchError (or
    $null); Step ('update' or 'open', the call the other values come from) }
#>
function Invoke-WingetSourceCheck {
    $update = Invoke-WingetSourceProbe
    # 0x8A15003A BLOCKED_BY_POLICY as a signed Int32.
    if ($update.LaunchError -or $update.TimedOut -or $update.ExitCode -eq -1978335174) {
        return @{ Succeeded = $false; ExitCode = $update.ExitCode; TimedOut = [bool]$update.TimedOut; LaunchError = $update.LaunchError; Step = 'update' }
    }
    $open = Test-WingetSourceOpen
    return @{ Succeeded = ($open.Opened -eq $true); ExitCode = $open.ExitCode; TimedOut = [bool]$open.TimedOut; LaunchError = $open.LaunchError; Step = 'open' }
}

<#
.SYNOPSIS
    Runs `winget source reset --force`, the fix for a corrupted or unconfigured winget source (it
    also removes any source added beyond the defaults), and says whether it worked.
.DESCRIPTION
    It only drops winget's source settings; it deploys no source package, so it cannot fix
    0x8A15000F SOURCE_DATA_MISSING (Register-WingetSourcePackage does). No
    --accept-source-agreements: `source reset` rejects it with 0x8A150002.
.OUTPUTS
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
