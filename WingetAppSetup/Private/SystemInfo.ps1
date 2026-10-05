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
        mockable seam for catalog conditions (ARM64 PCs get the 32-bit Adobe Reader, P3-32).
    .DESCRIPTION
        RuntimeInformation.OSArchitecture answers for the OS, not for this process, from .NET 7
        (PowerShell 7.3): Arm64 even in an emulated x64 PowerShell, whose PROCESSOR_ARCHITECTURE says
        AMD64. PowerShell 7.0-7.2 under emulation reads X64. Throws when the architecture cannot be
        read, so a condition built on it fails open.
    .OUTPUTS
        [string] A System.Runtime.InteropServices.Architecture name.
    #>
    $architecture = [string][System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
    if ([string]::IsNullOrWhiteSpace($architecture)) {
        throw 'The OS architecture could not be read.'
    }
    return $architecture
}

function Get-PowerShellEdition {
    <#
    .SYNOPSIS
        Returns the running PowerShell's edition, 'Core' or 'Desktop': a mockable seam for
        $PSVersionTable.PSEdition (the uninstaller keeps the PowerShell 7 it runs in).
    #>
    return [string]$PSVersionTable.PSEdition
}
