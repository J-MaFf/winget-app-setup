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

        Throws when it has no answer (review finding P3-33): a CIM failure (access denied, RPC
        unavailable, a corrupt WMI repository) and an empty or missing Manufacturer. CIM reports
        those as non-terminating errors, so without -ErrorAction Stop this returned '' and the Dell
        condition read "not Dell": Dell Command Update was skipped as not applicable on a Dell PC
        and the run exited 0. A condition that throws fails open instead (Test-AppApplicability):
        the installer warns and attempts the install.
    .RETURNS
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
        Returns the operating system's processor architecture: 'X64', 'Arm64', 'X86' or 'Arm'.
    .DESCRIPTION
        Mockable seam for catalog applicability conditions (review finding P3-32): for example,
        Adobe.Acrobat.Reader.64-bit ships only an x64 installer, which Adobe does not support on
        ARM64 Windows, so the catalog keeps it off ARM64 PCs.

        Answers for the OS, not for this process. RuntimeInformation.OSArchitecture asks Windows'
        IsWow64Process2 for the native machine (.NET 7 and later, so PowerShell 7.3 and later;
        the bootstrap installs 7.6), which reads Arm64 on an ARM64 PC even from an x64 PowerShell
        running under emulation, and X64 from a 32-bit PowerShell on x64 Windows. The environment
        variables do not: an x64 process under emulation on ARM64 sees PROCESSOR_ARCHITECTURE=AMD64
        and no PROCESSOR_ARCHITEW6432 (Microsoft Learn, "How emulation works on Arm": emulated
        apps are told about the emulated processor). Older .NET reads GetNativeSystemInfo instead,
        which is still right for a 32-bit process but says X64 for an x64 one under emulation.

        Throws when the architecture cannot be read, so a condition built on it fails open
        (Test-AppApplicability): the installer warns and attempts the install.
    .RETURNS
        [string] A System.Runtime.InteropServices.Architecture name, e.g. 'X64' or 'Arm64'.
    #>
    $architecture = [string][System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
    if ([string]::IsNullOrWhiteSpace($architecture)) {
        throw 'The OS architecture could not be read.'
    }
    return $architecture
}
