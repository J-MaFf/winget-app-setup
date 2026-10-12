# Machine-wide helpers for runs whose account is not the signed-in user. SYSTEM has no winget of its
# own: winget cannot be registered for it, and `winget list` as SYSTEM sees none of the users' MSIX
# apps. These find the winget.exe App Installer installed for the machine, which a SYSTEM run starts
# by its full path as Winget-AutoUpdate does, and read whether an MSIX app is provisioned for every
# user. Microsoft supports only the Microsoft.WinGet.Client module on PowerShell 7 as SYSTEM: a run
# can opt in to it (WingetClientEngine.ps1), and Winget-AutoUpdate still needs this winget.exe.
# Windows PowerShell 5.1-compatible (.NET Framework 4.5 APIs, 5.1 syntax).

<#
.SYNOPSIS
    Lists the packages of one name installed for any account, or only staged on the machine.
.DESCRIPTION
    `Get-AppxPackage -AllUsers` needs administrator rights and also lists a package only staged on
    the machine. Under PowerShell 7 it runs in Windows PowerShell 5.1, where the Appx module always
    loads (Invoke-WindowsPowerShellScript, within the AppxQuery limit). Throws when the query fails
    or is stopped at its limit.
.PARAMETER Name
    The package name, e.g. Microsoft.DesktopAppInstaller. It goes into a command, so only
    package-name characters are accepted.
.OUTPUTS
    [pscustomobject[]] with Version ([version]), Architecture ([string], e.g. 'X64'), Status
    ([string], e.g. 'Ok') and InstallLocation ([string]).
#>
function Get-AllUsersAppxPackageInfo {
    param (
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Za-z0-9.-]+\z')]
        [string]$Name
    )

    $query = "Get-AppxPackage -AllUsers -Name '$Name' -ErrorAction Stop | ForEach-Object { '{0}|{1}|{2}|{3}' -f `$_.Version, `$_.Architecture, `$_.Status, `$_.InstallLocation }"
    if ($PSVersionTable.PSEdition -eq 'Core') {
        $timeout = Get-ProcessTimeoutSeconds -Operation AppxQuery
        $run = Invoke-WindowsPowerShellScript -Script $query -TimeoutSeconds $timeout
        if ($run.LaunchFailed) {
            throw "Get-AppxPackage -AllUsers could not run: Windows PowerShell could not be started ($($run.LaunchError))."
        }
        if ($run.TimedOut) {
            throw "Get-AppxPackage -AllUsers did not finish within $timeout seconds and was stopped."
        }
        if ($run.ExitCode -ne 0) {
            throw "Get-AppxPackage -AllUsers failed in Windows PowerShell (exit code $($run.ExitCode))."
        }
        $lines = @($run.StandardOutput)
    }
    else {
        $lines = @(Get-AppxPackage -AllUsers -Name $Name -ErrorAction Stop |
                ForEach-Object { '{0}|{1}|{2}|{3}' -f $_.Version, $_.Architecture, $_.Status, $_.InstallLocation })
    }

    foreach ($line in $lines) {
        $parts = "$line".Trim() -split '\|'
        $parsedVersion = $null
        if ($parts.Count -eq 4 -and [version]::TryParse($parts[0], [ref]$parsedVersion)) {
            [pscustomobject]@{
                Version         = $parsedVersion
                Architecture    = $parts[1]
                Status          = $parts[2]
                InstallLocation = $parts[3]
            }
        }
    }
}

<#
.SYNOPSIS
    Lists the App Installer (Microsoft.DesktopAppInstaller) packages installed for any account.
.DESCRIPTION
    A query seam for Get-MachineWingetCandidate and the App Installer registration
    (Get-AllUsersAppxPackageInfo). Throws when the query fails.
.OUTPUTS
    [pscustomobject[]] as Get-AllUsersAppxPackageInfo.
#>
function Get-DesktopAppInstallerPackageInfo {
    Get-AllUsersAppxPackageInfo -Name 'Microsoft.DesktopAppInstaller'
}

<#
.SYNOPSIS
    Lists the winget source packages (Microsoft.Winget.Source) installed for any account, or only
    staged on the machine.
.DESCRIPTION
    A query seam for Register-WingetSourcePackage: one listed here can be registered for another
    account by family name, with no download (Get-AllUsersAppxPackageInfo). Throws when the query
    fails.
.OUTPUTS
    [pscustomobject[]] as Get-AllUsersAppxPackageInfo.
#>
function Get-WingetSourcePackageInfo {
    Get-AllUsersAppxPackageInfo -Name 'Microsoft.Winget.Source'
}

<#
.SYNOPSIS
    Returns the folder MSIX packages are installed to for the machine, or $null.
.DESCRIPTION
    %ProgramFiles%\WindowsApps. ProgramW6432 comes first: in a 32-bit process ProgramFiles is
    'Program Files (x86)', which holds no WindowsApps folder.
.OUTPUTS
    [string] or $null.
#>
function Get-WindowsAppsDirectory {
    $programFiles = $env:ProgramW6432
    if ([string]::IsNullOrWhiteSpace($programFiles)) {
        $programFiles = $env:ProgramFiles
    }
    if ([string]::IsNullOrWhiteSpace($programFiles)) {
        return $null
    }
    return (Join-Path $programFiles 'WindowsApps')
}

<#
.SYNOPSIS
    Finds the winget.exe files App Installer installed for the machine, best first.
.DESCRIPTION
    From the first source that yields one:
      1. Get-DesktopAppInstallerPackageInfo: packages with Status Ok and a winget.exe under their
         InstallLocation.
      2. Otherwise the Microsoft.DesktopAppInstaller_*__8wekyb3d8bbwe folders with a winget.exe
         under Get-WindowsAppsDirectory, which SYSTEM can list, leaving out any package the query
         listed with another Status (Tampered, NeedsRemediation, ...).
    This PC's architecture first (x64 on x64; arm64, x64, then x86 on ARM64), then the highest
    version, compared as [version] (as text, 1.9.25200.0 sorts after 1.27.460.0).
.PARAMETER ProcessorArchitecture
    The PC's architecture as Windows names it (AMD64, ARM64, x86). Default: PROCESSOR_ARCHITEW6432,
    which a 32-bit process on 64-bit Windows has, else PROCESSOR_ARCHITECTURE.
.OUTPUTS
    [pscustomobject[]] with Path, Version ([version]), Architecture ('x64', 'arm64', 'x86') and
    Source; empty when there is none.
#>
function Get-MachineWingetCandidate {
    param (
        [Parameter(Mandatory = $false)]
        [string]$ProcessorArchitecture
    )

    if ([string]::IsNullOrWhiteSpace($ProcessorArchitecture)) {
        $ProcessorArchitecture = $env:PROCESSOR_ARCHITEW6432
        if ([string]::IsNullOrWhiteSpace($ProcessorArchitecture)) {
            $ProcessorArchitecture = $env:PROCESSOR_ARCHITECTURE
        }
    }
    $preference = @('x64', 'x86')
    if ("$ProcessorArchitecture" -eq 'ARM64') {
        $preference = @('arm64', 'x64', 'x86')
    }
    elseif ("$ProcessorArchitecture" -eq 'x86') {
        $preference = @('x86')
    }

    $found = @()
    # Version_architecture of every package the query listed with a status other than Ok.
    $rejected = @()
    try {
        foreach ($package in @(Get-DesktopAppInstallerPackageInfo)) {
            if ("$($package.Status)" -ne 'Ok') {
                $rejected += ('{0}_{1}' -f $package.Version, "$($package.Architecture)".ToLowerInvariant())
                continue
            }
            if ([string]::IsNullOrWhiteSpace($package.InstallLocation)) {
                continue
            }
            $path = Join-Path $package.InstallLocation 'winget.exe'
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                $found += [pscustomobject]@{ Path = $path; Version = $package.Version; Architecture = "$($package.Architecture)".ToLowerInvariant(); Source = 'Get-AppxPackage -AllUsers' }
            }
        }
    }
    catch {
        Write-WarningMessage "Could not list App Installer for all accounts ($_); looking for winget.exe under WindowsApps instead."
    }

    if ($found.Count -eq 0) {
        $windowsApps = Get-WindowsAppsDirectory
        if ($windowsApps) {
            try {
                $folders = @(Get-ChildItem -LiteralPath $windowsApps -Directory -Filter 'Microsoft.DesktopAppInstaller_*' -ErrorAction Stop)
                foreach ($folder in $folders) {
                    if ($folder.Name -notmatch '^Microsoft\.DesktopAppInstaller_(?<version>\d+(\.\d+){1,3})_(?<architecture>x64|arm64|x86)__8wekyb3d8bbwe$') {
                        continue
                    }
                    if ($rejected -contains ('{0}_{1}' -f ([version]$Matches['version']), $Matches['architecture'].ToLowerInvariant())) {
                        continue
                    }
                    $path = Join-Path $folder.FullName 'winget.exe'
                    if (Test-Path -LiteralPath $path -PathType Leaf) {
                        $found += [pscustomobject]@{ Path = $path; Version = [version]$Matches['version']; Architecture = $Matches['architecture'].ToLowerInvariant(); Source = 'WindowsApps' }
                    }
                }
            }
            catch {
                Write-WarningMessage "Could not look for winget.exe under ${windowsApps}: $_"
            }
        }
    }

    $ranked = @(foreach ($candidate in $found) {
            $rank = [array]::IndexOf($preference, $candidate.Architecture)
            if ($rank -ge 0) {
                $candidate | Add-Member -NotePropertyName Rank -NotePropertyValue $rank -PassThru
            }
        })
    return @($ranked | Sort-Object -Property @{ Expression = 'Rank'; Ascending = $true }, @{ Expression = 'Version'; Descending = $true } |
            Select-Object -Property Path, Version, Architecture, Source)
}

<#
.SYNOPSIS
    The SYSTEM form of Initialize-Winget's launch check: finds the machine-wide winget.exe and
    checks it starts.
.DESCRIPTION
    As SYSTEM the per-account setup steps cannot help (no alias, no registration, and
    Repair-WinGetPackageManager does nothing; P2-24). Instead each candidate from
    Get-MachineWingetCandidate is checked with Test-WingetLaunchable: the first for up to 75 seconds
    (for a lock or an App Installer update), the others twice, and one missing a DLL (0xC0000135)
    once. The first that prints a version is kept for the run ($script:MachineWingetPath, which
    Resolve-WingetExecutable returns). When none starts, the message says why. Read-only, so a dry
    run runs it too.
.PARAMETER WhatIf
    Dry run: a failure is reported as what a real run would do (stop with exit code 2).
.PARAMETER NotRequired
    The run installs with Microsoft.WinGet.Client, so it does not stop without winget.exe: the same
    checks, and a failure is a warning that Winget-AutoUpdate needs winget.exe.
.OUTPUTS
    [bool] True when a machine-wide winget.exe starts.
#>
function Test-MachineWingetAvailable {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf,

        [Parameter(Mandatory = $false)]
        [switch]$NotRequired
    )

    $script:MachineWingetPath = $null
    $candidates = @(Get-MachineWingetCandidate)
    if ($candidates.Count -eq 0) {
        $windowsApps = Get-WindowsAppsDirectory
        if (-not $windowsApps) {
            $windowsApps = '%ProgramFiles%\WindowsApps'
        }
        $message = "No machine-wide winget was found: as SYSTEM the installer runs the winget.exe of the App Installer package (Microsoft.DesktopAppInstaller) installed for this PC, and Get-AppxPackage -AllUsers lists none with status Ok, nor is there one under $windowsApps. SYSTEM cannot set winget up for itself, so the per-account steps (registering App Installer, Repair-WinGetPackageManager) do not apply. Install or update App Installer for this PC, then re-run the installer."
        if ($NotRequired) {
            Write-WarningMessage "No machine-wide winget was found: Get-AppxPackage -AllUsers lists no App Installer package (Microsoft.DesktopAppInstaller) for this PC with status Ok, nor is there one under $windowsApps. Winget-AutoUpdate needs that winget.exe; install or update App Installer for this PC."
        }
        elseif ($WhatIf) {
            Write-Info "[DRY-RUN] $message A real run would stop here with exit code 2."
        }
        else {
            Write-ErrorMessage $message
        }
        return $false
    }

    $probe = $null
    $tried = 0
    foreach ($candidate in $candidates) {
        $script:MachineWingetPath = $candidate.Path
        if ($tried -eq 0) {
            $probe = Test-WingetLaunchable -Attempts 6 -RetryDelaySeconds 15
        }
        else {
            $probe = Test-WingetLaunchable -Attempts 2 -RetryDelaySeconds 5
        }
        $tried++
        if ($probe.Launchable) {
            Write-Success ('Winget is available ({0}): {1} (App Installer for this PC, {2}).' -f $probe.Version, $candidate.Path, $candidate.Version)
            return $true
        }
        Write-WarningMessage ('{0} could not be used: {1}.' -f $candidate.Path, $probe.Reason)
    }

    $script:MachineWingetPath = $null
    $hint = ''
    if ("$($probe.Reason)" -match '0xC0000135') {
        $hint = ' winget.exe could not load a DLL it needs: when it runs outside its package, as it does for SYSTEM, a missing Microsoft Visual C++ 2015-2022 runtime is a reported cause.'
    }
    $wingetWord = 'winget.exe'
    if ($tried -gt 1) {
        $wingetWord = "$tried winget.exe files"
    }
    $message = "winget could not be started as SYSTEM (tried the machine-wide $wingetWord above).$hint The per-account steps a signed-in user's run would try (registering App Installer, Repair-WinGetPackageManager) do not apply to SYSTEM and were skipped."
    if ($NotRequired) {
        Write-WarningMessage "The machine-wide winget.exe could not be started as SYSTEM (tried $wingetWord above).$hint Winget-AutoUpdate needs it; repair or update App Installer for this PC."
    }
    elseif ($WhatIf) {
        Write-Info "[DRY-RUN] $message A real run would stop here with exit code 2."
    }
    else {
        Write-ErrorMessage $message
    }
    return $false
}

<#
.SYNOPSIS
    Lists the display names of the app packages provisioned for every user on this PC.
.DESCRIPTION
    A query seam for Test-AppxPackageProvisionedForMachine. A provisioned package is registered for
    each account at its next sign-in, as Windows 11 does with Windows Terminal. Needs administrator
    rights. Under PowerShell 7 it runs in Windows PowerShell 5.1, where the DISM module always loads.
    Throws when the query fails.
.OUTPUTS
    [string[]]
#>
function Get-ProvisionedAppxPackageName {
    $query = 'Get-AppxProvisionedPackage -Online -ErrorAction Stop | ForEach-Object { $_.DisplayName }'
    if ($PSVersionTable.PSEdition -eq 'Core') {
        $lines = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $query)
        if ($LASTEXITCODE -ne 0) {
            throw "Get-AppxProvisionedPackage failed in Windows PowerShell (exit code $LASTEXITCODE)."
        }
    }
    else {
        $lines = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop | ForEach-Object { $_.DisplayName })
    }
    foreach ($line in $lines) {
        $name = "$line".Trim()
        if ($name.Length -gt 0) {
            $name
        }
    }
}

<#
.SYNOPSIS
    Returns whether an app package is provisioned for every user on this PC: $true, $false, or $null
    when that could not be read.
.DESCRIPTION
    A run for the whole PC cannot ask `winget list`, which sees only the running account's packages
    (none for SYSTEM), so Windows Terminal read as missing on every run (P3-24).
.PARAMETER Name
    The package name (the provisioned package's DisplayName), e.g. 'Microsoft.WindowsTerminal'.
.OUTPUTS
    [bool] or $null.
#>
function Test-AppxPackageProvisionedForMachine {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    try {
        $names = @(Get-ProvisionedAppxPackageName)
    }
    catch {
        Write-WarningMessage "Could not read the apps provisioned for every user on this PC: $_"
        return $null
    }
    return [bool](@($names | Where-Object { $_ -eq $Name }).Count -gt 0)
}
