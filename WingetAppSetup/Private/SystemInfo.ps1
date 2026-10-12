function Get-WindowsBuildNumber {
    <#
    .SYNOPSIS
        Returns the Windows build number (e.g. 19045, 26100): a seam for the 24H2 (26100) gate on
        winget's machine-scope MSIX provisioning (issue #166).
    #>
    return [int][System.Environment]::OSVersion.Version.Build
}

function Get-ComputerManufacturer {
    <#
    .SYNOPSIS
        Returns the PC's manufacturer (e.g. 'Dell Inc.'): a mockable seam for catalog conditions.
    .DESCRIPTION
        Throws when CIM fails or the manufacturer is empty, so a condition built on it fails open
        (Test-AppApplicability) instead of reading "not Dell" (review finding P3-33).
    .OUTPUTS
        [string] The manufacturer, never empty.
    #>
    $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    $manufacturer = [string]($computerSystem | Select-Object -First 1).Manufacturer
    if ([string]::IsNullOrWhiteSpace($manufacturer)) {
        throw 'Win32_ComputerSystem reported no manufacturer.'
    }
    return $manufacturer.Trim()
}

function Get-OSArchitecture {
    <#
    .SYNOPSIS
        Returns the operating system's processor architecture, 'X64', 'Arm64', 'X86' or 'Arm': a
        mockable seam for the catalog's arch lists (Test-AppApplicability: the Adobe Reader split,
        Dell Command Update's x64-only gate), the Windows App Runtime framework's per-architecture
        choice and the diagnostics report.
    .DESCRIPTION
        RuntimeInformation.OSArchitecture answers for the OS, not for this process, from .NET 7
        (PowerShell 7.3): Arm64 even in an emulated x64 PowerShell, whose PROCESSOR_ARCHITECTURE says
        AMD64. PowerShell 7.0-7.2 under emulation reads X64. Throws when the architecture cannot be
        read, so an arch list counts as met (fail open).
    .OUTPUTS
        [string] A System.Runtime.InteropServices.Architecture name.
    #>
    $architecture = [string][System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
    if ([string]::IsNullOrWhiteSpace($architecture)) {
        throw 'The OS architecture could not be read.'
    }
    return $architecture
}

function Write-OSArchitectureLine {
    <#
    .SYNOPSIS
        Prints 'OS architecture: <arch>' (Get-OSArchitecture), the architecture the catalog's arch
        lists are decided on, near the top of a transcript (wgt-gq8.52).
    .DESCRIPTION
        Never throws: when the architecture cannot be read, it prints 'unknown' with the reason, and
        the arch lists count as met (Get-OSArchitecture).
    #>
    try {
        $architecture = Get-OSArchitecture
    }
    catch {
        $architecture = "unknown ($($_.Exception.Message))"
    }
    Write-Info "OS architecture: $architecture"
}

function Get-UnsupportedWindowsWarning {
    <#
    .SYNOPSIS
        The warning for a Windows this installer does not support (wgt-gq8.51): 32-bit Windows, or
        Windows 10 on ARM64. $null on a supported Windows (10/11 x64, Windows 11 ARM64).
    .DESCRIPTION
        Fails open: when the architecture or the build cannot be read, there is no warning.
    .OUTPUTS
        [string] The warning, or $null.
    #>
    try {
        $architecture = Get-OSArchitecture
        if ($architecture -eq 'X86') {
            return 'This PC runs 32-bit Windows, which this installer does not support. The run goes on, but some apps may fail: Google Drive and Git, for example, have no 32-bit installer. Supported: Windows 10 and 11 x64, and Windows 11 on ARM64.'
        }
        if ($architecture -eq 'Arm64' -and (Get-WindowsBuildNumber) -lt 22000) {
            return 'This PC runs Windows 10 on ARM64, which this installer does not support. The run goes on, but some apps may fail: Windows 10 on ARM cannot run x64-only installers such as Google Drive''s. Supported: Windows 10 and 11 x64, and Windows 11 on ARM64.'
        }
    }
    catch {
        return $null
    }
    return $null
}

function Get-PowerShellEdition {
    <#
    .SYNOPSIS
        Returns the running PowerShell's edition, 'Core' or 'Desktop': a mockable seam for
        $PSVersionTable.PSEdition (the uninstaller keeps the PowerShell 7 it runs in).
    #>
    return [string]$PSVersionTable.PSEdition
}

function Get-PowerShellVersion {
    <#
    .SYNOPSIS
        Returns the running PowerShell's version as major.minor.build: a mockable seam for
        $PSVersionTable.PSVersion (the Microsoft.WinGet.Client engine needs 7.4 or later).
    .OUTPUTS
        [version]
    #>
    $psVersion = $PSVersionTable.PSVersion
    $patch = 0
    if ($psVersion.PSObject.Properties['Patch']) {
        $patch = [int]$psVersion.Patch
    }
    elseif ($psVersion.Build -ge 0) {
        $patch = [int]$psVersion.Build
    }
    return [version]::new([int]$psVersion.Major, [int]$psVersion.Minor, $patch)
}

function Get-ProcessArchitecture {
    <#
    .SYNOPSIS
        Returns this process's architecture, e.g. 'X64', 'X86' or 'Arm64': a mockable seam for
        RuntimeInformation.ProcessArchitecture. An x64 PowerShell emulated on ARM64 Windows says X64,
        the native DLLs it can load.
    .OUTPUTS
        [string] A System.Runtime.InteropServices.Architecture name.
    #>
    return [string][System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture
}
