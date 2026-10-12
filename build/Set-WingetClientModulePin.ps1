<#
.SYNOPSIS
    Checks, or moves, the Microsoft.WinGet.Client pin of the opt-in install engine of runs as SYSTEM.
.DESCRIPTION
    Get-WingetClientModulePin (WingetAppSetup/Private/WingetClientModule.ps1) pins the PowerShell
    Gallery package by version, size and SHA256. This:

      1. downloads the package twice, and once more with Save-PSResource -AsNupkg where that exists,
         and requires the two direct downloads to have the same SHA256 (the Save-PSResource copy is
         compared too; a difference there is a warning, since that client may store the package
         its own way);
      2. requires the Gallery's own PackageHash (base64 SHA512) to be the downloaded bytes' (a
         missing value is a warning);
      3. extracts the package, checks its .nuspec, and lists every file with its size, SHA256 and
         Authenticode status and signer ('n/a' off Windows), and the native architecture folders;
      4. flags each of the pin's SignedFiles that is not Valid and signed by Microsoft Corporation
         (on Windows), and lists the other files Microsoft Corporation signed;
      5. compares each WindowsPackageManager.dll with the same engine's build on nuget.org
         (Microsoft.WindowsPackageManager.InProcCom 1.29.380);
      6. prints 'Size = <n>' and "Sha256 = '<HEX>'".

    -Check exits 1 when the pin is not set, or differs from what the Gallery serves, or a signed
    file fails. -Write rewrites the pin's Version, PackageUrl, FileName, Size and Sha256 lines, and
    stops without writing when the file does not have exactly one of each. Rebuild the installer
    afterwards (build/Build-WingetInstallScript.ps1) and run the e2e-install-system-winget-client
    job. PowerShell 7; the signature checks need Windows.
.PARAMETER Version
    The module version. Default: the pinned one.
.PARAMETER Check
    Exit 1 unless the pin matches the Gallery's package.
.PARAMETER Write
    Write the measured values into the pin.
.PARAMETER OutputDirectory
    Where the downloads, the extracted files and pin-report.txt go. Default: a new temp folder.
.PARAMETER ModuleFile
    The file that holds the pin. Default: WingetAppSetup/Private/WingetClientModule.ps1.
.EXAMPLE
    pwsh -File build/Set-WingetClientModulePin.ps1 -Check
.NOTES
    Exit codes: 0 = done (with -Check: the pin matches); 1 = a download, hash, signature or pin
    check failed, or -Write could not rewrite the pin.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version,

    [Parameter(Mandatory = $false)]
    [switch]$Check,

    [Parameter(Mandatory = $false)]
    [switch]$Write,

    [Parameter(Mandatory = $false)]
    [string]$OutputDirectory,

    [Parameter(Mandatory = $false)]
    [string]$ModuleFile = (Join-Path (Split-Path -Parent $PSScriptRoot) 'WingetAppSetup/Private/WingetClientModule.ps1')
)

# The x64, arm64 and x86 WindowsPackageManager.dll of Microsoft.WindowsPackageManager.InProcCom
# 1.29.380 on nuget.org (101,581,201 bytes, SHA256 DA707D28...C2450E): the same engine build.
$script:InProcComEngineHashes = @{
    x64   = @{ Size = 7642976; Sha256 = '0FB0F8EEE1214AE3C17ABE740EA32964A7DA8B01F829FFA66DEC241B9FB3B384' }
    arm64 = @{ Size = 8628064; Sha256 = '03490F00437F024AFD762DF1EB91CE4CE05AD1480EA537AB52A1554103193051' }
    x86   = @{ Size = 6932280; Sha256 = '4769115A6D282E4C2E7F9D6E679ED207948472DC5DFE61F002636CF79B44C157' }
}

<#
.SYNOPSIS
    Replaces the value of one pin line ('<Name> = <value>' inside Get-WingetClientModulePin) and
    fails unless there is exactly one.
.PARAMETER Text
    The file's text.
.PARAMETER Name
    The key: Version, PackageUrl, FileName, Size or Sha256.
.PARAMETER Value
    The new value, already quoted for a string ('...').
.OUTPUTS
    [string] The new text.
#>
function Set-WingetClientPinLine {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $pattern = '(?m)^(?<lead>\s+' + [regex]::Escape($Name) + '\s+=\s+)(?<value>\S.*?)\s*$'
    $found = [regex]::Matches($Text, $pattern)
    if ($found.Count -ne 1) {
        throw "The pin file has $($found.Count) '$Name = ...' lines, not 1; nothing was written."
    }
    $match = $found[0]
    return $Text.Substring(0, $match.Index) + $match.Groups['lead'].Value + $Value + $Text.Substring($match.Index + $match.Length)
}

<#
.SYNOPSIS
    Returns where Get-WingetClientModulePin's body starts and ends in the pin file's text, so the
    pin lines are looked for there only.
.OUTPUTS
    [int[]] The start index and the length.
#>
function Get-WingetClientPinRange {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $match = [regex]::Match($Text, '(?ms)^function Get-WingetClientModulePin \{.*?^\}')
    if (-not $match.Success) {
        throw 'The pin file has no Get-WingetClientModulePin function; nothing was written.'
    }
    return @($match.Index, $match.Length)
}

<#
.SYNOPSIS
    Writes measured values into the pin: all five lines, or none.
.PARAMETER Path
    The pin file.
.PARAMETER Version
    The version.
.PARAMETER Size
    The package size.
.PARAMETER Sha256
    The package SHA256.
#>
function Set-WingetClientModulePinValue {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Version,

        [Parameter(Mandatory = $true)]
        [long]$Size,

        [Parameter(Mandatory = $true)]
        [string]$Sha256
    )

    $text = [System.IO.File]::ReadAllText($Path)
    $range = Get-WingetClientPinRange -Text $text
    $body = $text.Substring($range[0], $range[1])
    $body = Set-WingetClientPinLine -Text $body -Name 'Version' -Value "'$Version'"
    $body = Set-WingetClientPinLine -Text $body -Name 'PackageUrl' -Value "'https://www.powershellgallery.com/api/v2/package/Microsoft.WinGet.Client/$Version'"
    $body = Set-WingetClientPinLine -Text $body -Name 'FileName' -Value "'microsoft.winget.client.$Version.nupkg'"
    $body = Set-WingetClientPinLine -Text $body -Name 'Size' -Value ([string]$Size)
    $body = Set-WingetClientPinLine -Text $body -Name 'Sha256' -Value ("'{0}'" -f $Sha256.ToUpperInvariant())
    $text = $text.Substring(0, $range[0]) + $body + $text.Substring($range[0] + $range[1])
    [System.IO.File]::WriteAllText($Path, $text, [System.Text.UTF8Encoding]::new($false))
}

<#
.SYNOPSIS
    Reads the Gallery's own hash of one package version.
.OUTPUTS
    [pscustomobject] with PackageHash, PackageHashAlgorithm and PackageSize ($null when missing).
#>
function Get-GalleryPackageHash {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Version
    )

    $uri = "https://www.powershellgallery.com/api/v2/Packages(Id='Microsoft.WinGet.Client',Version='$Version')"
    $response = Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
    $document = [System.Xml.XmlDocument]::new()
    $document.XmlResolver = $null
    $document.LoadXml([string]$response.Content)
    $read = {
        param ($Name)
        $node = $document.SelectSingleNode("//*[local-name()='$Name']")
        if ($node) { return [string]$node.InnerText }
        return $null
    }
    return [pscustomobject]@{
        PackageHash          = & $read 'PackageHash'
        PackageHashAlgorithm = & $read 'PackageHashAlgorithm'
        PackageSize          = & $read 'PackageSize'
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    $failures = [System.Collections.Generic.List[string]]::new()
    $report = [System.Collections.Generic.List[string]]::new()
    function Add-ReportLine {
        param ([string]$Line)
        $report.Add($Line)
        Write-Host $Line
    }

    . $ModuleFile
    $pin = Get-WingetClientModulePin
    if (-not $Version) {
        $Version = $pin.Version
    }
    if (-not $OutputDirectory) {
        $OutputDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('wingetclient-pin-' + [guid]::NewGuid().ToString('N'))
    }
    [void](New-Item -ItemType Directory -Path $OutputDirectory -Force)
    $packageUrl = "https://www.powershellgallery.com/api/v2/package/Microsoft.WinGet.Client/$Version"
    Add-ReportLine "Microsoft.WinGet.Client $Version from $packageUrl (pinned: $($pin.Version), Size $($pin.Size), Sha256 '$($pin.Sha256)')"

    # 1. The bytes, twice, and through PSResourceGet when it is there.
    $hashes = @()
    $packagePath = $null
    foreach ($attempt in 1, 2) {
        $path = Join-Path $OutputDirectory ("download-$attempt.nupkg")
        Invoke-WebRequest -Uri $packageUrl -OutFile $path -UseBasicParsing -TimeoutSec 300 -ErrorAction Stop
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        $hashes += $hash
        Add-ReportLine ("Download {0}: {1} bytes, SHA256 {2}" -f $attempt, (Get-Item -LiteralPath $path).Length, $hash)
        if (-not $packagePath) {
            $packagePath = $path
        }
    }
    if ($hashes[0] -ne $hashes[1]) {
        $failures.Add('the two downloads differ')
    }
    if (Get-Command -Name 'Save-PSResource' -ErrorAction SilentlyContinue) {
        try {
            $psResourceDirectory = Join-Path $OutputDirectory 'save-psresource'
            [void](New-Item -ItemType Directory -Path $psResourceDirectory -Force)
            Save-PSResource -Name 'Microsoft.WinGet.Client' -Version $Version -Repository PSGallery -TrustRepository -AsNupkg -Path $psResourceDirectory -ErrorAction Stop
            $saved = Get-ChildItem -LiteralPath $psResourceDirectory -Filter '*.nupkg' -File | Select-Object -First 1
            $savedHash = (Get-FileHash -LiteralPath $saved.FullName -Algorithm SHA256).Hash
            Add-ReportLine ("Save-PSResource -AsNupkg: {0} bytes, SHA256 {1}" -f $saved.Length, $savedHash)
            if ($savedHash -ne $hashes[0]) {
                Write-Warning 'Save-PSResource stored a package with another SHA256 than the direct download.'
            }
        }
        catch {
            Write-Warning "Save-PSResource could not be compared: $($_.Exception.Message)"
        }
    }
    $bytes = [System.IO.File]::ReadAllBytes($packagePath)
    $size = $bytes.LongLength
    $sha256 = $hashes[0]

    # 2. The Gallery's own hash.
    try {
        $gallery = Get-GalleryPackageHash -Version $Version
        $localSha512 = [Convert]::ToBase64String([System.Security.Cryptography.SHA512]::HashData($bytes))
        if (-not $gallery.PackageHash) {
            Write-Warning 'The Gallery reported no PackageHash for this version.'
        }
        elseif ($gallery.PackageHashAlgorithm -and $gallery.PackageHashAlgorithm -ne 'SHA512') {
            Write-Warning "The Gallery's PackageHash is $($gallery.PackageHashAlgorithm), not SHA512; not compared."
        }
        elseif ($gallery.PackageHash -ne $localSha512) {
            $failures.Add("the Gallery's PackageHash $($gallery.PackageHash) is not the download's SHA512 $localSha512")
        }
        else {
            Add-ReportLine "The Gallery's SHA512 PackageHash matches the download."
        }
    }
    catch {
        Write-Warning "The Gallery's PackageHash could not be read: $($_.Exception.Message)"
    }

    # 3. Every file, with its signature.
    $extracted = Join-Path $OutputDirectory 'extracted'
    [void](New-Item -ItemType Directory -Path $extracted -Force)
    $rootPrefix = [System.IO.Path]::GetFullPath($extracted).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    $archive = [System.IO.Compression.ZipFile]::OpenRead($packagePath)
    try {
        foreach ($entry in $archive.Entries) {
            $name = [Uri]::UnescapeDataString($entry.FullName).Replace('\', '/')
            if ($name.EndsWith('/') -or $name -match '^(\[Content_Types\]\.xml|_rels/|package/)') {
                continue
            }
            $target = [System.IO.Path]::GetFullPath((Join-Path $extracted $name))
            if (-not $target.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "the package has an entry outside its folder: $name"
            }
            [void](New-Item -ItemType Directory -Path ([System.IO.Path]::GetDirectoryName($target)) -Force)
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        }
    }
    finally {
        $archive.Dispose()
    }
    $nuspec = Get-ChildItem -LiteralPath $extracted -Filter '*.nuspec' -File | Select-Object -First 1
    if (-not $nuspec) {
        $failures.Add('the package has no .nuspec')
    }
    else {
        $nuspecXml = [System.Xml.XmlDocument]::new()
        $nuspecXml.XmlResolver = $null
        $nuspecXml.Load($nuspec.FullName)
        Add-ReportLine ("nuspec: {0} {1}" -f $nuspecXml.package.metadata.id, $nuspecXml.package.metadata.version)
        if ([string]$nuspecXml.package.metadata.id -ne 'Microsoft.WinGet.Client' -or [string]$nuspecXml.package.metadata.version -ne $Version) {
            $failures.Add('the .nuspec names another package or version')
        }
    }
    $onWindows = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
    $signatures = @{}
    foreach ($file in @(Get-ChildItem -LiteralPath $extracted -Recurse -File | Sort-Object -Property FullName)) {
        $relative = $file.FullName.Substring($rootPrefix.Length).Replace('\', '/')
        $status = 'n/a'
        $signer = 'n/a'
        if ($onWindows) {
            $signature = Get-AuthenticodeSignature -LiteralPath $file.FullName
            $status = [string]$signature.Status
            $signer = 'none'
            if ($signature.SignerCertificate) {
                $signer = $signature.SignerCertificate.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
            }
        }
        $signatures[$relative] = [pscustomobject]@{ Status = $status; Signer = $signer }
        Add-ReportLine ("FILE {0} {1} {2} [{3}] {4}" -f $file.Length, (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash, $status, $signer, $relative)
    }
    $architectureFolders = @(Get-ChildItem -LiteralPath (Join-Path $extracted $pin.Framework) -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Directory } | ForEach-Object { $_.FullName.Substring($rootPrefix.Length).Replace('\', '/') })
    Add-ReportLine ('Architecture folders: ' + ($architectureFolders -join ', '))
    if (-not (Test-Path -LiteralPath (Join-Path $extracted $pin.Framework) -PathType Container)) {
        $failures.Add("the package has no $($pin.Framework) folder: the pin's Framework and SignedFiles need updating")
    }

    # 4. The pin's signed files, for each architecture.
    $signedPaths = @()
    foreach ($architecture in 'x64', 'x86', 'arm64') {
        $signedPaths += @($pin.SignedFiles | ForEach-Object { ([string]$_).Replace('{arch}', $architecture) })
    }
    foreach ($signedPath in @($signedPaths | Select-Object -Unique)) {
        $entry = $signatures[$signedPath]
        if (-not $entry) {
            $failures.Add("SignedFiles names $signedPath, which the package does not have")
        }
        elseif ($onWindows -and ($entry.Status -ne 'Valid' -or $entry.Signer -ne $pin.SignerCommonName)) {
            $failures.Add("$signedPath is $($entry.Status), signed by '$($entry.Signer)', not Valid from $($pin.SignerCommonName)")
        }
    }
    if ($onWindows) {
        $others = @($signatures.Keys | Where-Object { $signedPaths -notcontains $_ -and $signatures[$_].Status -eq 'Valid' -and $signatures[$_].Signer -eq $pin.SignerCommonName } | Sort-Object)
        Add-ReportLine ('Also signed by {0}, not in SignedFiles: {1}' -f $pin.SignerCommonName, ($others -join ', '))
    }

    # 5. The engine against nuget.org's build of it.
    foreach ($architecture in 'x64', 'x86', 'arm64') {
        $engine = Join-Path $extracted ('{0}/SharedDependencies/{1}/WindowsPackageManager.dll' -f $pin.Framework, $architecture)
        if (-not (Test-Path -LiteralPath $engine -PathType Leaf)) {
            Add-ReportLine "WindowsPackageManager.dll ${architecture}: not in the package"
            continue
        }
        $engineHash = (Get-FileHash -LiteralPath $engine -Algorithm SHA256).Hash
        $same = $engineHash -eq $script:InProcComEngineHashes[$architecture].Sha256 -and (Get-Item -LiteralPath $engine).Length -eq $script:InProcComEngineHashes[$architecture].Size
        Add-ReportLine ("WindowsPackageManager.dll {0}: SHA256 {1}, {2} nuget.org's InProcCom 1.29.380 build" -f $architecture, $engineHash, $(if ($same) { 'the same as' } else { 'not' }))
    }

    # 6. The values.
    Add-ReportLine "Size = $size"
    Add-ReportLine "Sha256 = '$sha256'"
    [System.IO.File]::WriteAllLines((Join-Path $OutputDirectory 'pin-report.txt'), $report)

    if ($Check) {
        if (-not ([long]$pin.Size -gt 0 -and "$($pin.Sha256)" -match '^[0-9A-Fa-f]{64}$')) {
            $failures.Add('the pin is not set: run this with -Write')
        }
        elseif ($pin.Version -ne $Version -or [long]$pin.Size -ne $size -or "$($pin.Sha256)".ToUpperInvariant() -ne $sha256) {
            $failures.Add(("the pin says {0}, {1} bytes, SHA256 {2}; the Gallery serves {3}, {4} bytes, SHA256 {5}" -f $pin.Version, $pin.Size, $pin.Sha256, $Version, $size, $sha256))
        }
    }
    if ($Write) {
        if ($failures.Count -gt 0) {
            $failures.Add('the pin was not written')
        }
        else {
            try {
                Set-WingetClientModulePinValue -Path $ModuleFile -Version $Version -Size $size -Sha256 $sha256
                Add-ReportLine "Wrote the pin into $ModuleFile; rebuild the installer (build/Build-WingetInstallScript.ps1)."
            }
            catch {
                $failures.Add($_.Exception.Message)
            }
        }
    }

    if ($failures.Count -gt 0) {
        foreach ($failure in $failures) {
            Write-Host "FAILED: $failure" -ForegroundColor Red
        }
        exit 1
    }
    Write-Host 'OK' -ForegroundColor Green
    exit 0
}
