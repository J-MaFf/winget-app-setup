# The pinned Microsoft.WinGet.Client module for the opt-in install engine of SYSTEM runs
# (WingetClientEngine.ps1): its pin, its download and checks, and the script a child pwsh runs.
# The module is never installed and never loaded into the installer's own process.

<#
.SYNOPSIS
    Returns the pinned Microsoft.WinGet.Client release: the one place the pin lives.
.DESCRIPTION
    The PowerShell Gallery package (.nupkg) at an exact version, with its size and SHA256; a Gallery
    version cannot be changed or deleted. SignedFiles are the module's own files that must carry a
    valid Microsoft Corporation signature ({arch} is x64, x86 or arm64); the third-party DLLs it
    ships have other signers, and the package SHA256 covers them.

    To move to a newer version, run build/Set-WingetClientModulePin.ps1 on Windows: it downloads
    the package, checks it against the Gallery's own hash, lists every file's signature, and
    rewrites Version, PackageUrl, FileName, Size and Sha256 here.
.OUTPUTS
    [hashtable] Name, Version, PackageUrl, FileName (the name in the cache), Size, Sha256,
    SignerCommonName, Framework (the PowerShell 7 build's folder), MinimumPowerShell and
    SignedFiles (paths inside the package, '/'-separated).
#>
function Get-WingetClientModulePin {
    return @{
        Name              = 'Microsoft.WinGet.Client'
        Version           = '1.29.380'
        PackageUrl        = 'https://www.powershellgallery.com/api/v2/package/Microsoft.WinGet.Client/1.29.380'
        FileName          = 'microsoft.winget.client.1.29.380.nupkg'
        Size              = 21025850
        Sha256            = '3469E5747EB6B100E51FED3F2057386B5BA60BC8955A6669B5C2EB562E316619'
        SignerCommonName  = 'Microsoft Corporation'
        Framework         = 'net8.0-windows10.0.26100.0'
        MinimumPowerShell = '7.4'
        SignedFiles       = @(
            'Microsoft.WinGet.Client.psd1',
            'Format.ps1xml',
            'net8.0-windows10.0.26100.0/Microsoft.WinGet.Client.Cmdlets.dll',
            'net8.0-windows10.0.26100.0/DirectDependencies/Microsoft.WinGet.Client.Engine.dll',
            'net8.0-windows10.0.26100.0/SharedDependencies/Microsoft.WinGet.SharedLib.dll',
            'net8.0-windows10.0.26100.0/SharedDependencies/{arch}/WindowsPackageManager.dll',
            'net8.0-windows10.0.26100.0/SharedDependencies/{arch}/Microsoft.Management.Deployment.dll',
            'net8.0-windows10.0.26100.0/SharedDependencies/{arch}/Microsoft.Management.Deployment.winmd',
            'net8.0-windows10.0.26100.0/SharedDependencies/{arch}/winrtact.dll'
        )
    }
}

<#
.SYNOPSIS
    Maps a process architecture to the module's native folder name: x64, x86 or arm64.
.PARAMETER Architecture
    A System.Runtime.InteropServices.Architecture name (Get-ProcessArchitecture).
.OUTPUTS
    [string] 'x64', 'x86' or 'arm64', or $null for any other architecture.
#>
function ConvertTo-WingetClientArchitecture {
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Architecture
    )

    switch ("$Architecture") {
        'X64' { return 'x64' }
        'X86' { return 'x86' }
        'Arm64' { return 'arm64' }
    }
    return $null
}

<#
.SYNOPSIS
    Extracts the parts of the Microsoft.WinGet.Client package this process loads.
.DESCRIPTION
    Reads the package from an open stream (left open), so what is extracted is what was hashed.
    Entry names are percent-decoded and '/'-separated. Left out: the NuGet metadata
    ([Content_Types].xml, _rels/, package/, .signature.p7s), the Windows PowerShell build (net48/)
    and the other architectures' native folders. The .nuspec is read, not extracted: its id and
    version must be the pin's.

    Throws for a rooted or drive-qualified entry name, an entry whose path leads outside
    DestinationPath, a .nuspec that is missing or names another package, and a package without the
    module manifest or the PowerShell 7 cmdlets.
.PARAMETER Stream
    The package, open for reading.
.PARAMETER DestinationPath
    The folder to extract into (created).
.PARAMETER Framework
    The PowerShell 7 build's folder (the pin's Framework).
.PARAMETER Architecture
    The native folder to keep: x64, x86 or arm64.
.PARAMETER Pin
    Get-WingetClientModulePin's result, for the name and version.
.OUTPUTS
    [pscustomobject] with ManifestPath and EngineFound ([bool]: the architecture's
    WindowsPackageManager.dll was there).
#>
function Expand-WingetClientModulePackage {
    param (
        [Parameter(Mandatory = $true)]
        [System.IO.Stream]$Stream,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,

        [Parameter(Mandatory = $true)]
        [string]$Framework,

        [Parameter(Mandatory = $true)]
        [ValidateSet('x64', 'x86', 'arm64')]
        [string]$Architecture,

        [Parameter(Mandatory = $true)]
        [hashtable]$Pin
    )

    $separator = [System.IO.Path]::DirectorySeparatorChar
    $root = [System.IO.Path]::GetFullPath($DestinationPath).TrimEnd('\', '/')
    $rootPrefix = $root + $separator
    [void](New-Item -ItemType Directory -Path $root -Force -ErrorAction Stop)
    $sharedPrefix = $Framework + '/SharedDependencies/'
    $otherArchitectures = @('x64', 'x86', 'arm64') | Where-Object { $_ -ne $Architecture }
    $nuspecChecked = $false

    $Stream.Position = 0
    $archive = New-Object System.IO.Compression.ZipArchive($Stream, [System.IO.Compression.ZipArchiveMode]::Read, $true)
    try {
        foreach ($entry in $archive.Entries) {
            $name = [Uri]::UnescapeDataString($entry.FullName).Replace('\', '/')
            if ($name.StartsWith('/') -or $name -match '^[A-Za-z]:' -or [System.IO.Path]::IsPathRooted($name)) {
                throw "the package has an entry with a rooted path: $name"
            }
            if ($name.EndsWith('/')) {
                continue
            }
            if ($name -ceq '[Content_Types].xml' -or $name -ceq '.signature.p7s' -or $name.StartsWith('_rels/') -or $name.StartsWith('package/') -or $name.StartsWith('net48/')) {
                continue
            }
            if ($name.StartsWith($sharedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                $folder = $name.Substring($sharedPrefix.Length).Split('/')[0]
                if ($name.Substring($sharedPrefix.Length).Contains('/') -and $otherArchitectures -contains $folder.ToLowerInvariant()) {
                    continue
                }
            }
            if (-not $name.Contains('/') -and $name.EndsWith('.nuspec', [System.StringComparison]::OrdinalIgnoreCase)) {
                # No DTD and no external resources: only the id and version are read.
                $settings = New-Object System.Xml.XmlReaderSettings
                $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
                $settings.XmlResolver = $null
                $entryStream = $entry.Open()
                try {
                    $reader = [System.Xml.XmlReader]::Create($entryStream, $settings)
                    $nuspec = New-Object System.Xml.XmlDocument
                    $nuspec.Load($reader)
                }
                finally {
                    $entryStream.Dispose()
                }
                $id = [string]$nuspec.package.metadata.id
                $version = [string]$nuspec.package.metadata.version
                if ($id -ne $Pin.Name -or $version -ne $Pin.Version) {
                    throw ("the package's .nuspec names {0} {1}, not {2} {3}" -f $id, $version, $Pin.Name, $Pin.Version)
                }
                $nuspecChecked = $true
                continue
            }

            $target = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($root, $name.Replace('/', $separator)))
            if (-not $target.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "the package has an entry outside its folder: $name"
            }
            [void](New-Item -ItemType Directory -Path ([System.IO.Path]::GetDirectoryName($target)) -Force -ErrorAction Stop)
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $false)
        }
    }
    finally {
        $archive.Dispose()
    }

    if (-not $nuspecChecked) {
        throw 'the package has no .nuspec'
    }
    $manifestPath = Join-Path $root ($Pin.Name + '.psd1')
    foreach ($required in @(($Pin.Name + '.psd1'), ($Framework + '/Microsoft.WinGet.Client.Cmdlets.dll'))) {
        if (-not (Test-Path -LiteralPath (Join-Path $root $required.Replace('/', $separator)) -PathType Leaf)) {
            throw "the package has no $required"
        }
    }
    $enginePath = Join-Path $root ('{0}{1}{2}{1}WindowsPackageManager.dll' -f $sharedPrefix.Replace('/', $separator), $separator, $Architecture).Replace(($separator + $separator), $separator)
    return [pscustomobject]@{
        ManifestPath = $manifestPath
        EngineFound  = [bool](Test-Path -LiteralPath $enginePath -PathType Leaf)
    }
}

<#
.SYNOPSIS
    Returns the script a child pwsh runs for one Microsoft.WinGet.Client request.
.DESCRIPTION
    It imports the module by the full path of its manifest, checks the version and folder it loaded
    from, and runs one operation through the module's own exported commands (no name lookup, so no
    other copy and no function of the same name can answer):
      Version    Get-WinGetVersion.
      Installed  Get-WinGetPackage -Id <id> -MatchOption Equals -Source winget.
      Install    Install-WinGetPackage -Id <id> -Source winget -MatchOption Equals -Scope System
                 -Mode <mode> [-InstallerType <type>] [-Log <path>].
      Probe      Version, then Installed for -ProbePackageId, in one process.
    It prints one plain line, then the result as one line 'WINGET-CLIENT-RESULT <json>' (protocol
    1: operation, stage 'load' or 'call', ok, moduleVersion, psVersion, architecture, and version,
    packages, or the install result's status, hresult, installerErrorCode, rebootRequired and id,
    or the exception chain). A failed load exits 3; anything else exits 0. Never passes -Debug,
    which the module refuses, and never calls a result's ErrorMessage(), which throws on success.
.OUTPUTS
    [string] ASCII script text.
#>
function Get-WingetClientChildScript {
    return @'
param (
    [Parameter(Mandatory = $true)]
    [string]$ModuleManifest,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedVersion,

    [Parameter(Mandatory = $true)]
    [ValidateSet('Probe', 'Version', 'Installed', 'Install')]
    [string]$Operation,

    [string]$PackageId,

    [string]$InstallerType,

    [ValidateSet('Silent', 'Default')]
    [string]$Mode = 'Silent',

    [string]$Log,

    [string]$ProbePackageId = 'Microsoft.PowerShell'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
# A process without a console can refuse the code page; the result line is ASCII-safe JSON anyway.
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
$script:loadedVersion = $null

function Get-ExceptionRecord {
    param ($Exception)
    $records = @()
    $current = $Exception
    while ($null -ne $current -and $records.Count -lt 6) {
        $records += @{ type = $current.GetType().FullName; name = $current.GetType().Name; hresult = [int]$current.HResult; message = [string]$current.Message }
        $current = $current.InnerException
    }
    return ,$records
}

function Send-RequestResult {
    param ([hashtable]$Result, [string]$Outcome)
    $Result['protocol'] = 1
    $Result['operation'] = $Operation
    $Result['moduleVersion'] = $script:loadedVersion
    $Result['psVersion'] = [string]$PSVersionTable.PSVersion
    $Result['architecture'] = [string][System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture
    $subject = @('Microsoft.WinGet.Client', $Operation, $PackageId) | Where-Object { -not [string]::IsNullOrEmpty($_) }
    [Console]::Out.WriteLine(($subject -join ' ') + ': ' + $Outcome)
    [Console]::Out.WriteLine('WINGET-CLIENT-RESULT ' + (ConvertTo-Json -InputObject $Result -Compress -Depth 6 -EscapeHandling EscapeNonAscii))
    [Console]::Out.Flush()
}

function Get-InstalledPackageRecord {
    param ($Command, [string]$Id)
    $records = @()
    foreach ($package in @(& $Command -Id $Id -MatchOption Equals -Source winget)) {
        if ($null -ne $package) {
            $records += @{ id = [string]$package.Id; installedVersion = [string]$package.InstalledVersion; source = [string]$package.Source }
        }
    }
    return ,$records
}

try {
    $manifestPath = [System.IO.Path]::GetFullPath($ModuleManifest)
    $module = @(Import-Module -Name $manifestPath -PassThru -Force -ErrorAction Stop) | Where-Object { $_.Name -eq 'Microsoft.WinGet.Client' } | Select-Object -First 1
    if ($null -eq $module) {
        throw (New-Object System.InvalidOperationException('Import-Module returned no Microsoft.WinGet.Client module.'))
    }
    $script:loadedVersion = [string]$module.Version
    if ($module.Version -ne [version]$ExpectedVersion) {
        throw (New-Object System.InvalidOperationException(('Microsoft.WinGet.Client {0} was loaded, not {1}.' -f $module.Version, $ExpectedVersion)))
    }
    $expectedBase = [System.IO.Path]::GetDirectoryName($manifestPath).TrimEnd('\', '/')
    $loadedBase = [System.IO.Path]::GetFullPath([string]$module.ModuleBase).TrimEnd('\', '/')
    if (-not [string]::Equals($loadedBase, $expectedBase, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw (New-Object System.InvalidOperationException(('Microsoft.WinGet.Client was loaded from {0}, not {1}.' -f $loadedBase, $expectedBase)))
    }
    $installCommand = $module.ExportedCommands['Install-WinGetPackage']
    $getCommand = $module.ExportedCommands['Get-WinGetPackage']
    $versionCommand = $module.ExportedCommands['Get-WinGetVersion']
    if ($null -eq $installCommand -or $null -eq $getCommand -or $null -eq $versionCommand) {
        throw (New-Object System.InvalidOperationException('Microsoft.WinGet.Client does not export Install-WinGetPackage, Get-WinGetPackage and Get-WinGetVersion.'))
    }
}
catch {
    $records = Get-ExceptionRecord -Exception $_.Exception
    Send-RequestResult -Result @{ stage = 'load'; ok = $false; exceptions = $records } -Outcome ('load failed: ' + $records[0].name)
    exit 3
}

$result = @{ stage = 'call'; ok = $true }
$outcome = 'ok'
try {
    switch ($Operation) {
        'Version' {
            $result['version'] = [string](& $versionCommand)
            $outcome = $result['version']
        }
        'Installed' {
            $result['packages'] = Get-InstalledPackageRecord -Command $getCommand -Id $PackageId
            $outcome = '{0} installed package(s)' -f @($result['packages']).Count
        }
        'Probe' {
            $result['version'] = [string](& $versionCommand)
            $result['probePackageId'] = $ProbePackageId
            $result['packages'] = Get-InstalledPackageRecord -Command $getCommand -Id $ProbePackageId
            $result['installedChecked'] = $true
            $outcome = '{0}, {1} installed package(s) for {2}' -f $result['version'], @($result['packages']).Count, $ProbePackageId
        }
        'Install' {
            $parameters = @{ Id = $PackageId; Source = 'winget'; MatchOption = 'Equals'; Scope = 'System'; Mode = $Mode }
            if (-not [string]::IsNullOrEmpty($InstallerType)) {
                $parameters['InstallerType'] = $InstallerType
            }
            if (-not [string]::IsNullOrEmpty($Log)) {
                $parameters['Log'] = $Log
            }
            $installResults = @(& $installCommand @parameters)
            if ($installResults.Count -ne 1) {
                $result['ok'] = $false
                $result['exceptions'] = @(@{ type = 'NoResult'; name = 'NoResult'; hresult = 0; message = ('Install-WinGetPackage returned {0} results, not 1.' -f $installResults.Count) })
                $outcome = 'NoResult'
            }
            else {
                $installResult = $installResults[0]
                $hresult = 0
                if ($null -ne $installResult.ExtendedErrorCode) {
                    $hresult = [int]$installResult.ExtendedErrorCode.HResult
                }
                $result['status'] = [string]$installResult.Status
                $result['hresult'] = $hresult
                $result['installerErrorCode'] = [long]$installResult.InstallerErrorCode
                $result['rebootRequired'] = [bool]$installResult.RebootRequired
                $result['id'] = [string]$installResult.Id
                $outcome = $result['status']
            }
        }
    }
}
catch {
    $records = Get-ExceptionRecord -Exception $_.Exception
    $result = @{ stage = 'call'; ok = $false; exceptions = $records }
    $outcome = $records[0].name
}
Send-RequestResult -Result $result -Outcome $outcome
exit 0
'@
}

<#
.SYNOPSIS
    Gets the pinned Microsoft.WinGet.Client module ready for a run as SYSTEM: from the cache or the
    PowerShell Gallery, checked, and extracted into a folder only SYSTEM and Administrators can
    change.
.DESCRIPTION
    Steps, each failure a NOT READY reason:
      1. Preconditions: a pin with a size and SHA256, PowerShell (Core) at the pin's
         MinimumPowerShell or later, a run as SYSTEM, a process architecture the module has an
         engine for, and Windows build 17763 or later.
      2. A new folder (New-WauStagingDirectory -Prefix wingetclient) and the cache folder
         %ProgramData%\winget-app-setup\cache, both limited to SYSTEM and Administrators.
      3. The cached package is used when its size and SHA256 are the pin's, read from a handle
         that keeps it from changing; otherwise it is deleted and downloaded again (twice at most,
         15 seconds apart, with Get-WebDownloadTimeoutParameters' limits) and checked the same way.
      4. Extraction from that same handle (Expand-WingetClientModulePackage), then each of the
         pin's SignedFiles must be signed by its SignerCommonName (Test-AuthenticodeSigner).
      5. The child script (Get-WingetClientChildScript) is written next to the module, and a
         downloaded package is copied into the cache for the next run.
    Writes one 'WinGet client module: ready - ...' or 'WinGet client module: NOT READY - <reason>.'
    line; the folder is removed when it is not ready. Never throws.
.OUTPUTS
    [pscustomobject] with Ready, Reason, Version, Sha256, Source ('Cache' or 'Download'),
    Directory, ManifestPath, ChildScriptPath, PowerShellPath (this pwsh) and Architecture.
#>
function Initialize-WingetClientModule {
    $pin = $null
    $reason = $null
    $stage = 'reading its pin'
    $directory = $null
    $stream = $null
    $source = $null
    $architecture = $null
    $manifestPath = $null
    $childScriptPath = $null
    try {
        $pin = Get-WingetClientModulePin
        if (-not ([long]$pin.Size -gt 0 -and "$($pin.Sha256)" -match '^[0-9A-Fa-f]{64}$')) {
            $reason = 'its SHA256 pin is not set in this build'
        }
        if (-not $reason) {
            $stage = 'checking this PowerShell'
            $edition = Get-PowerShellEdition
            $psVersion = Get-PowerShellVersion
            if ($edition -ne 'Core' -or $psVersion -lt [version]$pin.MinimumPowerShell) {
                $reason = 'it needs PowerShell {0} or later, and this run is PowerShell {1} ({2})' -f $pin.MinimumPowerShell, $psVersion, $edition
            }
        }
        if (-not $reason -and -not (Test-IsSystemAccount)) {
            $reason = 'it is used only in a run as SYSTEM'
        }
        if (-not $reason) {
            $processArchitecture = Get-ProcessArchitecture
            $architecture = ConvertTo-WingetClientArchitecture -Architecture $processArchitecture
            if (-not $architecture) {
                $reason = "this PowerShell runs as a process of architecture $processArchitecture, and the module has engines for x64, x86 and Arm64 only"
            }
        }
        if (-not $reason) {
            $build = Get-WindowsBuildNumber
            if ($build -lt 17763) {
                $reason = "Windows build $build is older than 17763, the oldest its engine supports"
            }
        }

        if (-not $reason) {
            $stage = 'setting up its folders'
            $directory = New-WauStagingDirectory -Prefix 'wingetclient'
            $cacheDirectory = Join-Path $env:ProgramData 'winget-app-setup\cache'
            [void](New-Item -ItemType Directory -Path $cacheDirectory -Force -ErrorAction Stop)
            Set-RestrictedDirectoryAcl -Path $cacheDirectory
            $cachePath = Join-Path $cacheDirectory $pin.FileName
            $expectedSha256 = "$($pin.Sha256)".ToUpperInvariant()

            $stage = 'checking the cached package'
            if (Test-Path -LiteralPath $cachePath -PathType Leaf) {
                $stream = Open-ReadLockedFile -Path $cachePath
                if ($stream.Length -eq [long]$pin.Size -and (Get-FileHash -InputStream $stream -Algorithm SHA256).Hash -eq $expectedSha256) {
                    $source = 'Cache'
                }
                else {
                    $stream.Dispose()
                    $stream = $null
                    Remove-Item -LiteralPath $cachePath -Force -ErrorAction Stop
                    Write-Info 'The cached Microsoft.WinGet.Client package did not match the pin; downloading it again.'
                }
            }

            if (-not $source) {
                $stage = "downloading $($pin.PackageUrl)"
                Write-Info "Downloading Microsoft.WinGet.Client $($pin.Version) from the PowerShell Gallery..."
                $downloadPath = Join-Path $directory $pin.FileName
                $downloadTimeouts = Get-WebDownloadTimeoutParameters
                $downloaded = $false
                $downloadError = $null
                for ($attempt = 1; $attempt -le 2 -and -not $downloaded; $attempt++) {
                    try {
                        Invoke-WebRequest @downloadTimeouts -Uri $pin.PackageUrl -OutFile $downloadPath -UseBasicParsing -ErrorAction Stop
                        $downloaded = $true
                    }
                    catch {
                        $downloadError = $_
                        if ($attempt -lt 2) {
                            Write-WarningMessage "Could not download Microsoft.WinGet.Client ($($_.Exception.Message)); trying again in 15 seconds..."
                            Start-Sleep -Seconds 15
                        }
                    }
                }
                if (-not $downloaded) {
                    throw $downloadError
                }

                # Held open from the hash through extraction, so what is extracted is what was hashed.
                $stage = 'checking the downloaded package'
                $stream = Open-ReadLockedFile -Path $downloadPath
                $downloadedSize = $stream.Length
                $downloadedSha256 = (Get-FileHash -InputStream $stream -Algorithm SHA256).Hash
                if ($downloadedSize -ne [long]$pin.Size -or $downloadedSha256 -ne $expectedSha256) {
                    $reason = 'the downloaded package is {0} bytes with SHA256 {1}, not the pinned {2} bytes with SHA256 {3}' -f $downloadedSize, $downloadedSha256, $pin.Size, $expectedSha256
                }
                $source = 'Download'
            }

            if (-not $reason) {
                $stage = 'extracting the package'
                $moduleDirectory = Join-Path $directory $pin.Name
                $expanded = Expand-WingetClientModulePackage -Stream $stream -DestinationPath $moduleDirectory -Framework $pin.Framework -Architecture $architecture -Pin $pin
                $manifestPath = $expanded.ManifestPath
                if (-not $expanded.EngineFound) {
                    $reason = "the package has no $architecture engine"
                }
            }

            if (-not $reason) {
                $stage = 'checking its signatures'
                foreach ($signedFile in @($pin.SignedFiles)) {
                    $relativePath = ([string]$signedFile).Replace('{arch}', $architecture)
                    $signedPath = Join-Path $moduleDirectory $relativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
                    $signature = Test-AuthenticodeSigner -Path $signedPath -SignerCommonName $pin.SignerCommonName
                    if (-not $signature.Valid) {
                        $reason = "$relativePath failed its signature check: $($signature.Detail)"
                        break
                    }
                }
            }

            if (-not $reason) {
                $stage = 'writing its request script'
                $childScriptPath = Join-Path $directory 'Invoke-WingetClientRequest.ps1'
                [System.IO.File]::WriteAllText($childScriptPath, (Get-WingetClientChildScript), (New-Object System.Text.UTF8Encoding($false)))
            }

            # The next run then needs no download. Not keeping it costs only that.
            if (-not $reason -and $source -eq 'Download') {
                $partialPath = $cachePath + '.partial'
                try {
                    $stream.Position = 0
                    $cacheFile = [System.IO.File]::Create($partialPath)
                    try {
                        $stream.CopyTo($cacheFile)
                    }
                    finally {
                        $cacheFile.Dispose()
                    }
                    [System.IO.File]::Move($partialPath, $cachePath, $true)
                    foreach ($old in @(Get-ChildItem -LiteralPath $cacheDirectory -Filter 'microsoft.winget.client.*.nupkg' -File -ErrorAction SilentlyContinue)) {
                        if ($old.Name -ne $pin.FileName) {
                            Remove-Item -LiteralPath $old.FullName -Force -ErrorAction SilentlyContinue
                        }
                    }
                }
                catch {
                    Remove-Item -LiteralPath $partialPath -Force -ErrorAction SilentlyContinue
                    Write-WarningMessage "Could not keep the Microsoft.WinGet.Client package in $cacheDirectory for the next run: $($_.Exception.Message)"
                }
            }
        }
    }
    catch {
        $reason = "$stage failed: $($_.Exception.Message)"
        if ($_.FullyQualifiedErrorId -eq 'RestrictedDirectoryAclFailed') {
            $baseDir = Join-Path $env:ProgramData 'winget-app-setup'
            $reason += " To reset the folder, run in an elevated prompt: takeown /f `"$baseDir`" /a, then icacls `"$baseDir`" /reset, and re-run this installer."
        }
    }
    finally {
        # Closed before the folder is removed: the open handle refuses deletion.
        if ($stream) {
            $stream.Dispose()
        }
        if ($reason -and $directory) {
            Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $version = $null
    $sha256 = $null
    if ($pin) {
        $version = $pin.Version
        $sha256 = "$($pin.Sha256)".ToUpperInvariant()
    }
    if ($reason) {
        $reason = "$reason".Trim().TrimEnd('.')
        Write-WarningMessage "WinGet client module: NOT READY - $reason."
        return [pscustomobject]@{ Ready = $false; Reason = $reason; Version = $version; Sha256 = $sha256; Source = $source; Directory = $null; ManifestPath = $null; ChildScriptPath = $null; PowerShellPath = $null; Architecture = $architecture }
    }
    $from = 'downloaded from the PowerShell Gallery'
    if ($source -eq 'Cache') {
        $from = 'from the cache'
    }
    Write-Success ('WinGet client module: ready - Microsoft.WinGet.Client {0}, SHA256 {1}, {2}.' -f $version, $sha256, $from)
    return [pscustomobject]@{
        Ready           = $true
        Reason          = $null
        Version         = $version
        Sha256          = $sha256
        Source          = $source
        Directory       = $directory
        ManifestPath    = $manifestPath
        ChildScriptPath = $childScriptPath
        PowerShellPath  = [Environment]::ProcessPath
        Architecture    = $architecture
    }
}
