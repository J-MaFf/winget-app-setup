# Installs the Microsoft.WindowsAppRuntime.1.8 framework, pinned and verified, for every user of the
# PC (work-order item 31, finding R13-3). Every winget release since 1.12 needs that framework, and
# every Winget-AutoUpdate run provisions the newest winget, so WAU is only set up where the
# framework is present (Get-WindowsAppRuntimeStatus, WauSupport.ps1). A freshly imaged PC, a PC
# whose Microsoft Store updates are blocked and Windows Server lack it until something installs it,
# and the run then ended with 'Auto-updates: NOT CONFIGURED' and exit code 8. Install-WingetAutoUpdate
# now installs it first. Runs under PowerShell 7 only (Invoke-WingetInstall's WAU step).

<#
.SYNOPSIS
    Returns the pinned Windows App Runtime 1.8 framework release.
.DESCRIPTION
    The single place the pin lives. The framework files come from the NuGet package
    Microsoft.WindowsAppSDK.Runtime, where Microsoft publishes them from 1.8 on (the
    Microsoft.WindowsAppSDK package itself no longer holds them). A NuGet version cannot be
    overwritten once published.

    The SHA256 of each framework .msix is the pin that matters. The .nupkg itself is not pinned:
    NuGet re-signs a package when a signing certificate is revoked, which changes the .nupkg's bytes
    but not the files inside it. Each file is also checked for a valid Authenticode signature by
    SignerCommonName before it is provisioned.

    Microsoft's WindowsAppRuntimeInstall-<arch>.exe is not used: it never provisions the framework
    for all users (it registers it for the elevating account only, or, as SYSTEM, only stages it),
    and it also deploys packages winget does not need, which can fail after the framework itself is
    in place.

    To move to a newer 1.8 servicing release, change every field together: the version numbers, the
    URL, and each architecture's Entry, Size and Sha256, read from the new .nupkg
    (tools/MSIX/win10-<arch>/Microsoft.WindowsAppRuntime.1.8.msix). The framework version of a
    release is the Identity Version in that file's AppxManifest.xml. Moving to a newer framework
    family (Microsoft.WindowsAppRuntime.2) is a different change: winget's dependency names 1.8.
    When the latest winget release needs a newer 1.8 build than FrameworkVersion, or another
    family, Install-WindowsAppRuntimeFramework installs nothing and says so
    (Get-WindowsAppRuntimeRequirement, work-order item 32): that is the sign to move the pin.
.RETURNS
    [hashtable] with Release, NuGetVersion, FrameworkName (the framework's package name),
    FrameworkVersion, PackageUrl, SignerCommonName and Frameworks: one entry per OS architecture,
    keyed as Get-OSArchitecture names it (X64, X86, Arm64), each with Entry (the file's path inside
    the package), Size (bytes) and Sha256.
#>
function Get-WindowsAppRuntimePin {
    return @{
        Release          = '1.8.12'
        NuGetVersion     = '1.8.260921001'
        FrameworkName    = 'Microsoft.WindowsAppRuntime.1.8'
        FrameworkVersion = '8000.994.2142.0'
        PackageUrl       = 'https://api.nuget.org/v3-flatcontainer/microsoft.windowsappsdk.runtime/1.8.260921001/microsoft.windowsappsdk.runtime.1.8.260921001.nupkg'
        SignerCommonName = 'Microsoft Corporation'
        Frameworks       = @{
            X64   = @{
                Entry  = 'tools/MSIX/win10-x64/Microsoft.WindowsAppRuntime.1.8.msix'
                Size   = 43025663
                Sha256 = '07AF369968CD15C56A7FC8865B7190643A7ADEF49B8191752FF17094E4EFE504'
            }
            X86   = @{
                Entry  = 'tools/MSIX/win10-x86/Microsoft.WindowsAppRuntime.1.8.msix'
                Size   = 21691200
                Sha256 = '0AF2A0E5FD6ED43D46240F930A5FDC6FCAB46DA5ACF10FA12C4A7AEE0FC9A74C'
            }
            Arm64 = @{
                Entry  = 'tools/MSIX/win10-arm64/Microsoft.WindowsAppRuntime.1.8.msix'
                Size   = 40928160
                Sha256 = '9D6FE2B8D795859D725B4E1C25A4F7646C852BECB91D9D360B82BC32589E052F'
            }
        }
    }
}

<#
.SYNOPSIS
    Lists the Microsoft.WindowsAppRuntime.1.8 framework packages provisioned for every user.
.DESCRIPTION
    Thin query seam (mocked in tests), the provisioned-package counterpart of
    Get-WindowsAppRuntimePackageInfo. The version and architecture come from each package's
    PackageName, for example Microsoft.WindowsAppRuntime.1.8_8000.994.2142.0_x64__8wekyb3d8bbwe.
    `Get-AppxProvisionedPackage -Online` needs administrator rights; under PowerShell 7 it runs in
    Windows PowerShell 5.1, where the DISM module always loads (as Get-ProvisionedAppxPackageName
    does). Throws when the query fails.
.RETURNS
    [pscustomobject[]] with Version ([version]) and Architecture ('X64', 'X86', 'Arm64', 'Arm' or
    'Neutral').
#>
function Get-WindowsAppRuntimeProvisionedInfo {
    $query = "Get-AppxProvisionedPackage -Online -ErrorAction Stop | Where-Object { `$_.DisplayName -eq 'Microsoft.WindowsAppRuntime.1.8' } | ForEach-Object { `$_.PackageName }"
    if ($PSVersionTable.PSEdition -eq 'Core') {
        $lines = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $query)
        if ($LASTEXITCODE -ne 0) {
            throw "Get-AppxProvisionedPackage failed in Windows PowerShell (exit code $LASTEXITCODE)."
        }
    }
    else {
        $lines = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop |
                Where-Object { $_.DisplayName -eq 'Microsoft.WindowsAppRuntime.1.8' } |
                ForEach-Object { $_.PackageName })
    }

    $architectures = @{ x64 = 'X64'; x86 = 'X86'; arm64 = 'Arm64'; arm = 'Arm'; neutral = 'Neutral' }
    foreach ($line in $lines) {
        if ("$line".Trim() -match '^Microsoft\.WindowsAppRuntime\.1\.8_(?<version>\d+(\.\d+){1,3})_(?<arch>[A-Za-z0-9]+)_') {
            $architecture = $Matches.arch.ToLowerInvariant()
            if ($architectures.ContainsKey($architecture)) {
                [pscustomobject]@{ Version = [version]$Matches.version; Architecture = $architectures[$architecture] }
            }
        }
    }
}

<#
.SYNOPSIS
    Writes one framework .msix out of the downloaded Microsoft.WindowsAppSDK.Runtime package.
.DESCRIPTION
    A .nupkg is a zip file. The file's size inside the package is compared with the pin before
    anything is written, so another package can neither be extracted under the pinned name nor fill
    the disk; the caller checks the hash. Throws when the package cannot be read, has no such file,
    or the file's size differs.
.PARAMETER PackagePath
    The downloaded .nupkg.
.PARAMETER EntryName
    The file's path inside the package (forward slashes).
.PARAMETER ExpectedSize
    The file's pinned size in bytes.
.PARAMETER DestinationPath
    Where to write it. Must not exist yet.
#>
function Expand-WindowsAppRuntimeMsix {
    param (
        [Parameter(Mandatory = $true)]
        [string]$PackagePath,

        [Parameter(Mandatory = $true)]
        [string]$EntryName,

        [Parameter(Mandatory = $true)]
        [long]$ExpectedSize,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )

    $archive = [System.IO.Compression.ZipFile]::OpenRead($PackagePath)
    try {
        $entry = $archive.GetEntry($EntryName)
        if (-not $entry) {
            throw "the package holds no $EntryName"
        }
        if ($entry.Length -ne $ExpectedSize) {
            throw ('{0} in the package is {1} bytes, not the pinned {2}' -f $EntryName, $entry.Length, $ExpectedSize)
        }
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $DestinationPath, $false)
    }
    finally {
        $archive.Dispose()
    }
}

<#
.SYNOPSIS
    Checks that a file carries a valid Authenticode signature from the given signer.
.DESCRIPTION
    Status 'Valid' means Windows checked the signature against the file's content and chained the
    signing certificate to a trusted root (an .msix is checked through Windows' own package
    signature provider). The certificate subject's common name must also be exactly
    SignerCommonName. The same rule Test-PowerShell7MsiSignature applies to the PowerShell MSI.
.PARAMETER Path
    The file to check.
.PARAMETER SignerCommonName
    The common name (CN) the signing certificate must have.
.RETURNS
    [pscustomobject] with Valid ([bool]) and Detail (the signer, or why the check failed).
#>
function Test-WindowsAppRuntimeSignature {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$SignerCommonName
    )

    try {
        $signature = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
    }
    catch {
        return [pscustomobject]@{ Valid = $false; Detail = "its signature could not be checked: $_" }
    }

    $status = 'unknown'
    $signer = 'none'
    if ($signature) {
        if ("$($signature.Status)") {
            $status = "$($signature.Status)"
        }
        if ($signature.SignerCertificate -and $signature.SignerCertificate.Subject) {
            $signer = [string]$signature.SignerCertificate.Subject
        }
    }
    $signerPattern = '(^|,\s*)CN=' + [regex]::Escape($SignerCommonName) + '(\s*,|$)'
    if ($status -eq 'Valid' -and $signer -match $signerPattern) {
        return [pscustomobject]@{ Valid = $true; Detail = $signer }
    }
    return [pscustomobject]@{ Valid = $false; Detail = ('it is not signed by {0} (signature status: {1}; signer: {2})' -f $SignerCommonName, $status, $signer) }
}

<#
.SYNOPSIS
    Installs the pinned Microsoft.WindowsAppRuntime.1.8 framework for every user of this PC.
.DESCRIPTION
    Called by Install-WingetAutoUpdate when Get-WindowsAppRuntimeStatus finds no suitable
    framework (never when that check itself failed). Steps:
      1. Preconditions: the pinned framework meets every framework of the requirement this PC
         lacks (what the latest winget release needs, Get-WindowsAppRuntimeRequirement: the same
         family, at a version no higher than the pinned one; a newer family does not stand in for
         an older one, nor the other way round; one the PC already has does not matter), an
         elevated run (SYSTEM included), an OS architecture the pin has a file for
         (X64, X86, Arm64), Windows build 17763 or later (the framework's minimum), and no
         provisioned framework for this architecture at or above the pinned version: a newer build
         is never replaced or downgraded.
      2. Download Microsoft.WindowsAppSDK.Runtime (about 150 MB) from NuGet.org into a new folder
         limited to SYSTEM and Administrators (New-WauStagingDirectory, checked before anything is
         downloaded), with the download time limits Get-WebDownloadTimeoutParameters gives. The
         whole package rather than a byte range of it: the file's offset inside the package moves
         when NuGet re-signs it, and a proxy may ignore a range request, so a ranged read would
         need this path as its fallback anyway. Only a PC without the framework downloads it, but
         nothing remembers a failed attempt: until an install succeeds, every run there downloads
         the package again.
      3. Extract this architecture's framework .msix (size checked against the pin first), open it
         with read-only sharing (Open-ReadLockedFile), hash it from that handle, check its
         Authenticode signature, and provision it with Add-AppxProvisionedPackage -Online
         -SkipLicense (Invoke-AppxProvisioning, run in Windows PowerShell with a time limit). The
         handle stays open until provisioning has finished, so what is provisioned is what was
         hashed.
      4. Check again: Get-WindowsAppRuntimeStatus must now find what the requirement names; when
         it reports it missing,
         the install failed. When that check cannot run, the install counts as done, with a
         warning: Add-AppxProvisionedPackage succeeded, and an unknown answer is not evidence that
         the framework is missing (Install-WingetAutoUpdate goes ahead with WAU on one too). The
         provisioned packages are read too, and a framework that is not listed as provisioned for
         all users gets a warning.
    Writes one 'Windows App Runtime: installed ...' or 'Windows App Runtime: NOT INSTALLED - <reason>'
    line, which e2e/TranscriptAssertions.ps1 reads. Never uses Repair-WinGetPackageManager -AllUsers
    (issue #265). Never throws.
.PARAMETER Requirement
    What winget needs (Get-WindowsAppRuntimeRequirement). Default: the built-in requirement
    (Get-DefaultWindowsAppRuntimeRequirement), which the pin meets.
.PARAMETER MissingFrameworks
    The frameworks of the requirement this PC lacks (Get-WindowsAppRuntimeStatus's Missing); only
    these must be ones the pin meets. Default (or empty): every framework of the requirement.
.RETURNS
    [pscustomobject] with Installed ([bool]: Add-AppxProvisionedPackage succeeded and the check
    afterwards found the framework, or could not run), Status (Get-WindowsAppRuntimeStatus's result
    after provisioning, Present $null when that check could not run, or $null when nothing was
    provisioned) and Reason (why it was not installed, or $null).
#>
function Install-WindowsAppRuntimeFramework {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$Requirement,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$MissingFrameworks
    )

    $pin = Get-WindowsAppRuntimePin
    $reason = $null
    $status = $null
    $architecture = $null
    $framework = $null
    $unconfirmed = $false

    try {
        if ($null -eq $Requirement) {
            $Requirement = Get-DefaultWindowsAppRuntimeRequirement
        }
        # Work-order item 32: the pinned 1.8 framework does not help a winget that needs a newer
        # 1.8 build or another family, so it is not installed for one (and WAU stays off). Only
        # what this PC lacks counts: another family it already has is no reason to refuse.
        $needed = @($Requirement.Frameworks)
        if ($MissingFrameworks) {
            $needed = @($MissingFrameworks)
        }
        $unmet = @($needed | Where-Object { $_.Name -ne $pin.FrameworkName -or [version]$pin.FrameworkVersion -lt [version]$_.MinimumVersion })
        if ($unmet.Count -gt 0) {
            $reason = ('the latest winget release needs {0}, and the framework this installer installs, {1} {2}, does not meet that; a newer version of this installer is needed' -f (Format-WindowsAppRuntimeRequirement -Frameworks $unmet), $pin.FrameworkName, $pin.FrameworkVersion)
        }

        if (-not $reason) {
            try {
                $architecture = Get-OSArchitecture
                $framework = $pin.Frameworks[$architecture]
                if (-not $framework) {
                    $reason = "Microsoft publishes no Windows App Runtime 1.8 framework for $architecture Windows"
                }
            }
            catch {
                $reason = "the OS architecture could not be read ($_)"
            }
        }

        if (-not $reason -and -not (Test-IsAdmin)) {
            $reason = 'installing it for all users needs administrator rights'
        }
        if (-not $reason) {
            $build = Get-WindowsBuildNumber
            if ($build -lt 17763) {
                $reason = "Windows build $build is older than 17763, the oldest the framework supports"
            }
        }
        if (-not $reason) {
            # A newer (or the same) build already provisioned is left alone: never downgraded, never
            # replaced. A failed query does not stop the install; the status check already found no
            # suitable framework for any user.
            $provisioned = @()
            try {
                $provisioned = @(Get-WindowsAppRuntimeProvisionedInfo)
            }
            catch {
                Write-WarningMessage "Could not list the provisioned Microsoft.WindowsAppRuntime.1.8 packages: $_"
            }
            $newer = @($provisioned | Where-Object { $_.Architecture -eq $architecture -and $_.Version -ge [version]$pin.FrameworkVersion } | Sort-Object -Property Version -Descending)
            if ($newer.Count -gt 0) {
                $reason = ('Microsoft.WindowsAppRuntime.1.8 {0} ({1}) is already provisioned for this PC, at or above the pinned {2}, but no user has it; the installer does not replace it' -f $newer[0].Version, $architecture, $pin.FrameworkVersion)
            }
        }

        if (-not $reason) {
            Write-Info ('Microsoft.WindowsAppRuntime.1.8 is missing; installing the pinned Windows App Runtime {0} (framework {1}, {2}) for all users first...' -f $pin.Release, $pin.FrameworkVersion, $architecture)
            $stagingDir = $null
            $msixStream = $null
            $stage = 'setting up its download folder'
            try {
                $stagingDir = New-WauStagingDirectory -Prefix 'appruntime'

                $stage = "downloading $($pin.PackageUrl)"
                $packagePath = Join-Path $stagingDir ('microsoft.windowsappsdk.runtime.{0}.nupkg' -f $pin.NuGetVersion)
                Write-Info "Downloading Microsoft.WindowsAppSDK.Runtime $($pin.NuGetVersion) from NuGet.org (about 150 MB)..."
                $downloadTimeouts = Get-WebDownloadTimeoutParameters
                Invoke-WebRequest @downloadTimeouts -Uri $pin.PackageUrl -OutFile $packagePath -UseBasicParsing -ErrorAction Stop

                $stage = 'extracting the framework from the package'
                $msixPath = Join-Path $stagingDir 'Microsoft.WindowsAppRuntime.1.8.msix'
                Expand-WindowsAppRuntimeMsix -PackagePath $packagePath -EntryName $framework.Entry -ExpectedSize $framework.Size -DestinationPath $msixPath
                Remove-Item -LiteralPath $packagePath -Force -ErrorAction SilentlyContinue

                # Held open, with read-only sharing, from the hash until provisioning has finished
                # (as the WAU MSI is, review finding P2-21). Disposed in finally, before the cleanup.
                $stage = 'verifying the framework'
                $msixStream = Open-ReadLockedFile -Path $msixPath
                $actualHash = (Get-FileHash -InputStream $msixStream -Algorithm SHA256).Hash
                if ($actualHash -ne $framework.Sha256) {
                    $reason = "the downloaded framework's SHA256 is $actualHash, not the pinned $($framework.Sha256)"
                }
                else {
                    $signature = Test-WindowsAppRuntimeSignature -Path $msixPath -SignerCommonName $pin.SignerCommonName
                    if (-not $signature.Valid) {
                        $reason = "the downloaded framework failed its signature check: $($signature.Detail)"
                    }
                    else {
                        Write-Info "Verified its SHA256 and its signature ($($signature.Detail)); provisioning it for all users..."
                        $stage = 'provisioning the framework'
                        if (-not (Invoke-AppxProvisioning -PackagePath $msixPath -TimeoutSeconds (Get-ProcessTimeoutSeconds -Operation AppxProvisioning))) {
                            $reason = 'Add-AppxProvisionedPackage failed (its error is above); Windows Server without the Desktop Experience, or a policy that blocks app packages, cannot take it'
                        }
                    }
                }
            }
            catch {
                $reason = "$stage failed: $_"
                if ($_.FullyQualifiedErrorId -eq 'RestrictedDirectoryAclFailed') {
                    $baseDir = Join-Path $env:ProgramData 'winget-app-setup'
                    $reason += " To reset the folder, run in an elevated prompt: takeown /f `"$baseDir`" /a, then icacls `"$baseDir`" /reset, and re-run this installer."
                }
            }
            finally {
                # Close the file first: the open handle refuses deletion, so the cleanup would fail.
                if ($msixStream) {
                    $msixStream.Dispose()
                }
                if ($stagingDir) {
                    Remove-Item -Path $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }

        if (-not $reason) {
            # Add-AppxProvisionedPackage's success is not the answer: the check the WAU gate uses is.
            $status = Get-WindowsAppRuntimeStatus -Requirement $Requirement
            if ($status.Present -eq $false) {
                $reason = "Add-AppxProvisionedPackage reported success, but the framework is still not there ($($status.Detail))"
            }
            else {
                if ($status.Present -ne $true) {
                    # The check could not run. Not evidence that the framework is missing: the WAU
                    # gate goes ahead on an unknown answer, and provisioning has just succeeded.
                    $unconfirmed = $true
                    Write-WarningMessage "Add-AppxProvisionedPackage succeeded, but the check for Microsoft.WindowsAppRuntime.1.8 afterwards could not run ($($status.Detail)); going ahead as if it is there."
                }
                try {
                    $provisionedNow = @(Get-WindowsAppRuntimeProvisionedInfo | Where-Object { $_.Architecture -eq $architecture -and $_.Version -ge [version]$pin.FrameworkVersion })
                    if ($provisionedNow.Count -eq 0 -and $unconfirmed) {
                        Write-WarningMessage 'Get-AppxProvisionedPackage does not list Microsoft.WindowsAppRuntime.1.8 as provisioned for all users either, so nothing confirms the install; accounts that sign in for the first time may not get it.'
                    }
                    elseif ($provisionedNow.Count -eq 0) {
                        Write-WarningMessage 'Microsoft.WindowsAppRuntime.1.8 is now on this PC, but Get-AppxProvisionedPackage does not list it as provisioned for all users; accounts that sign in for the first time may not get it.'
                    }
                }
                catch {
                    Write-WarningMessage "Could not list the provisioned Microsoft.WindowsAppRuntime.1.8 packages to confirm the install: $_"
                }
            }
        }
    }
    catch {
        $reason = "unexpected error: $_"
    }

    if ($reason) {
        # Callers put the reason inside their own sentences.
        $reason = "$reason".Trim().TrimEnd('.')
        Write-ErrorMessage "Windows App Runtime: NOT INSTALLED - $reason."
        return [pscustomobject]@{ Installed = $false; Status = $status; Reason = $reason }
    }
    $unconfirmedNote = ''
    if ($unconfirmed) {
        $unconfirmedNote = ', not confirmed: the check afterwards could not run'
    }
    Write-Success ('Windows App Runtime: installed Microsoft.WindowsAppRuntime.1.8 {0} ({1}) for all users{2}.' -f $pin.FrameworkVersion, $architecture, $unconfirmedNote)
    return [pscustomobject]@{ Installed = $true; Status = $status; Reason = $null }
}
