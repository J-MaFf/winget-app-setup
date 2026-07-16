function Get-WindowsBuildNumber {
    <#
    .SYNOPSIS
        Returns the current Windows OS build number as an integer (e.g. 19045, 26100).
    .DESCRIPTION
        Wrapped in a function so callers (and tests) can reason about the build gate used to decide
        how to install the latest PowerShell: winget's machine-scope MSIX provisioning only works on
        build 26100 (Windows 11 24H2) and later (issue #166).
    #>
    return [int][System.Environment]::OSVersion.Version.Build
}

function Get-ComputerManufacturer {
    <#
    .SYNOPSIS
        Returns the machine's manufacturer string (e.g. 'Dell Inc.', 'Microsoft Corporation').
    .DESCRIPTION
        Thin, mockable wrapper around the Win32_ComputerSystem CIM class so catalog applicability
        conditions (issue #217) — e.g. gating Dell Command Update on Dell hardware — can be unit
        tested without touching real system state. Private on purpose: it is a seam for the
        catalog's condition scriptblocks, not part of the module's public surface.
    #>
    return [string](Get-CimInstance -ClassName Win32_ComputerSystem).Manufacturer
}
