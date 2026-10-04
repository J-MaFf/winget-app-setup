# Machine-wide helpers for runs whose account is not the signed-in user (review findings P2-24,
# P3-22, P3-24). A run as SYSTEM, which is how an RMM agent such as ManageEngine Endpoint Central
# runs a script, has no winget of its own: winget is a packaged app registered per user, and
# Microsoft documents that packages "can be registered for any user except NT AUTHORITY\SYSTEM",
# so "the WinGet CLI is not supported in the system context"
# (learn.microsoft.com/windows/package-manager/winget/troubleshooting#system-context). There is no
# `winget` on SYSTEM's PATH, and `winget list` run as SYSTEM cannot see the MSIX apps registered for
# the users. These helpers find the winget.exe that App Installer installed for the machine, so a
# SYSTEM run can start it by its full path (as Winget-AutoUpdate's own SYSTEM runs do), and read
# whether an MSIX app is provisioned for every user. Microsoft's supported way to use winget as
# SYSTEM is the Microsoft.WinGet.Client module on PowerShell 7; moving to it is a follow-up.
# Written for Windows PowerShell 5.1 too (.NET Framework 4.5 APIs and 5.1 syntax only), like the
# other helpers Resolve-WingetExecutable leads to.

<#
.SYNOPSIS
    Lists the App Installer (Microsoft.DesktopAppInstaller) packages installed for any account.
.DESCRIPTION
    Thin query seam for Get-MachineWingetCandidate (mocked in tests). `Get-AppxPackage -AllUsers`
    needs administrator rights, which SYSTEM has, and lists a package staged on the machine even
    when no account has it registered. Under PowerShell 7 the query runs in Windows PowerShell 5.1,
    where the Appx module always loads, the same delegation Get-WindowsAppRuntimePackageInfo uses.
    Throws when the query fails.
.RETURNS
    [pscustomobject[]] with Version ([version]), Architecture ([string], e.g. 'X64'), Status
    ([string], e.g. 'Ok') and InstallLocation ([string]).
#>
function Get-DesktopAppInstallerPackageInfo {
    $query = "Get-AppxPackage -AllUsers -Name 'Microsoft.DesktopAppInstaller' -ErrorAction Stop | ForEach-Object { '{0}|{1}|{2}|{3}' -f `$_.Version, `$_.Architecture, `$_.Status, `$_.InstallLocation }"
    if ($PSVersionTable.PSEdition -eq 'Core') {
        $lines = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $query)
        if ($LASTEXITCODE -ne 0) {
            throw "Get-AppxPackage -AllUsers failed in Windows PowerShell (exit code $LASTEXITCODE)."
        }
    }
    else {
        $lines = @(Get-AppxPackage -AllUsers -Name 'Microsoft.DesktopAppInstaller' -ErrorAction Stop |
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
    Returns the folder MSIX packages are installed to for the machine, or $null.
.DESCRIPTION
    %ProgramFiles%\WindowsApps. ProgramW6432 comes first: in a 32-bit process ProgramFiles is
    'Program Files (x86)', which holds no WindowsApps folder.
.RETURNS
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
    Two sources, the first that yields a winget.exe wins:
      1. Get-DesktopAppInstallerPackageInfo (`Get-AppxPackage -AllUsers`): packages whose Status
         is Ok, with winget.exe under their InstallLocation.
      2. When that query fails or finds none: the
         Microsoft.DesktopAppInstaller_<version>_<architecture>__8wekyb3d8bbwe folders under
         Get-WindowsAppsDirectory that hold a winget.exe. SYSTEM can list that folder; an
         administrator account normally cannot. A folder whose package the query listed with a
         Status other than Ok (Tampered, Modified, NeedsRemediation, ...) is left out here too, so
         the folder scan never brings back a package the query turned down.
    Candidates for this PC's architecture come first (x64 on an x64 PC; arm64, then x64, then x86
    on an ARM64 PC), and within an architecture the highest version first. Versions are compared as
    [version], never as text: as text, 1.9.25200.0 sorts after 1.27.460.0.
.PARAMETER ProcessorArchitecture
    The PC's architecture as Windows names it (AMD64, ARM64, x86). Default: PROCESSOR_ARCHITEW6432,
    which a 32-bit process on 64-bit Windows has, else PROCESSOR_ARCHITECTURE.
.RETURNS
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
    Review finding P2-24. As SYSTEM the per-account steps Initialize-Winget otherwise works through
    cannot help: SYSTEM has no `winget` alias, App Installer cannot be registered for it, and
    Repair-WinGetPackageManager does nothing for it (and throws with -AllUsers). They used to run
    anyway, with minutes of downloads, before the run stopped with exit code 2.

    Instead, each winget.exe from Get-MachineWingetCandidate is tried, best first, with
    Test-WingetLaunchable: the first is checked for up to 75 seconds (for a lock or an App Installer
    update that clears on its own), the others twice, and a winget.exe that cannot load a DLL it
    needs (0xC0000135) only once, since that does not clear on its own. The first that starts and
    prints a version is kept for the rest of the run ($script:MachineWingetPath, which
    Resolve-WingetExecutable returns to every winget call). When none starts, the run cannot install anything, and the message says
    why: no App Installer for the machine, or the winget.exe found could not be started.

    Read-only, so a dry run runs it too.
.PARAMETER WhatIf
    Dry run: a failure is reported as what a real run would do (stop with exit code 2).
.RETURNS
    [bool] True when a machine-wide winget.exe starts.
#>
function Test-MachineWingetAvailable {
    param (
        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    $script:MachineWingetPath = $null
    $candidates = @(Get-MachineWingetCandidate)
    if ($candidates.Count -eq 0) {
        $windowsApps = Get-WindowsAppsDirectory
        if (-not $windowsApps) {
            $windowsApps = '%ProgramFiles%\WindowsApps'
        }
        $message = "No machine-wide winget was found: as SYSTEM the installer runs the winget.exe of the App Installer package (Microsoft.DesktopAppInstaller) installed for this PC, and Get-AppxPackage -AllUsers lists none with status Ok, nor is there one under $windowsApps. SYSTEM cannot set winget up for itself, so the per-account steps (registering App Installer, Repair-WinGetPackageManager) do not apply. Install or update App Installer for this PC, then re-run the installer."
        if ($WhatIf) {
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
    if ($WhatIf) {
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
    Thin query seam for Test-AppxPackageProvisionedForMachine (mocked in tests). A provisioned
    package is registered for each account at its next sign-in, so it is installed for the PC as a
    whole: Windows 11 provisions Windows Terminal this way. `Get-AppxProvisionedPackage -Online`
    needs administrator rights. Under PowerShell 7 it runs in Windows PowerShell 5.1, where the DISM
    module always loads (the same delegation Invoke-AppxProvisioning uses). Throws when the query
    fails.
.RETURNS
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
    Review finding P3-24. A run as SYSTEM, or as an admin elevating on a user's PC, cannot decide
    whether an MSIX app such as Windows Terminal is installed with `winget list`: that only sees the
    packages registered for the account running it, which for SYSTEM is none. Windows Terminal,
    built into Windows 11, then read as missing on every run, and its install was then verified the
    same way and failed. Whether the package is provisioned for every user is the machine-wide
    answer.
.PARAMETER Name
    The package name (the provisioned package's DisplayName), e.g. 'Microsoft.WindowsTerminal'.
.RETURNS
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
