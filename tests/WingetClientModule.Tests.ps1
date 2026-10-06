# WingetClientModule.Tests.ps1
# Tests for WingetAppSetup/Private/WingetClientModule.ps1 (wgt-gq8.42): the Microsoft.WinGet.Client
# pin, the package's extraction, the module's acquisition as SYSTEM and the script a child pwsh
# runs for each request. Packages are built in TestDrive; the download, the signature check and the
# folder access lists are mocked at their seams.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    $script:Framework = 'net8.0-windows10.0.26100.0'

    # A package laid out like the Gallery's Microsoft.WinGet.Client .nupkg, written to -Path. Entry
    # names are used as given (percent-escapes included); each file holds its own name.
    function New-TestWingetClientPackage {
        param (
            [Parameter(Mandatory = $true)][string]$Path,
            [string]$Id = 'Microsoft.WinGet.Client',
            [string]$Version = '1.29.380',
            [string[]]$Architectures = @('x64', 'x86', 'arm64'),
            [string[]]$ExtraEntries = @(),
            [switch]$NoNuspec
        )
        $entries = @('[Content_Types].xml', '_rels/.rels', 'package/services/metadata/core-properties/1cf9.psmdcp',
            'Microsoft.WinGet.Client.psd1', 'Format.ps1xml', 'NOTICE.txt',
            'net48/Microsoft.WinGet.Client.Cmdlets.dll', 'net48/SharedDependencies/x64/WindowsPackageManager.dll',
            "$script:Framework/Microsoft.WinGet.Client.Cmdlets.dll",
            "$script:Framework/DirectDependencies/Microsoft.WinGet.Client.Engine.dll",
            "$script:Framework/SharedDependencies/Microsoft.WinGet.SharedLib.dll",
            "$script:Framework/SharedDependencies/Newtonsoft.Json.dll")
        foreach ($architecture in $Architectures) {
            foreach ($file in 'WindowsPackageManager.dll', 'Microsoft.Management.Deployment.dll', 'Microsoft.Management.Deployment.winmd', 'winrtact.dll') {
                $entries += "$script:Framework/SharedDependencies/$architecture/$file"
            }
        }
        $entries += $ExtraEntries
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force)
        $stream = [System.IO.File]::Create($Path)
        $archive = [System.IO.Compression.ZipArchive]::new($stream, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            if (-not $NoNuspec) {
                $writer = [System.IO.StreamWriter]::new($archive.CreateEntry('Microsoft.WinGet.Client.nuspec').Open())
                $writer.Write("<?xml version=`"1.0`" encoding=`"utf-8`"?><package xmlns=`"http://schemas.microsoft.com/packaging/2011/08/nuspec.xsd`"><metadata><id>$Id</id><version>$Version</version></metadata></package>")
                $writer.Dispose()
            }
            foreach ($name in $entries) {
                $writer = [System.IO.StreamWriter]::new($archive.CreateEntry($name).Open())
                $writer.Write($name)
                $writer.Dispose()
            }
        }
        finally {
            $archive.Dispose()
            $stream.Dispose()
        }
        return $Path
    }

    # The real pin with Size and Sha256 of the package at -Path.
    function New-TestPin {
        param ([Parameter(Mandatory = $true)][string]$Path)
        $pin = Get-WingetClientModulePin
        $pin.Size = (Get-Item -LiteralPath $Path).Length
        $pin.Sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        $pin.PackageUrl = 'https://www.powershellgallery.test/api/v2/package/Microsoft.WinGet.Client/1.29.380'
        return $pin
    }

    function Expand-TestPackage {
        param ([string]$PackagePath, [string]$Destination, [string]$Architecture = 'x64', [hashtable]$Pin = (Get-WingetClientModulePin))
        $stream = Open-ReadLockedFile -Path $PackagePath
        try {
            return (Expand-WingetClientModulePackage -Stream $stream -DestinationPath $Destination -Framework $script:Framework -Architecture $Architecture -Pin $Pin)
        }
        finally {
            $stream.Dispose()
        }
    }

    function Get-RelativeFile {
        param ([string]$Root)
        $prefix = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/').Length + 1
        @(Get-ChildItem -LiteralPath $Root -Recurse -File | ForEach-Object { $_.FullName.Substring($prefix).Replace('\', '/') } | Sort-Object)
    }

    function New-TestSignature {
        param ([string]$Status = 'Valid', [string]$Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US')
        [pscustomobject]@{ Status = $Status; SignerCertificate = [pscustomobject]@{ Subject = $Subject } }
    }
}

Describe 'Get-WingetClientModulePin' {
    It 'Pins an exact version of the PowerShell Gallery package, with a well-formed size and SHA256 when they are set' {
        $pin = Get-WingetClientModulePin

        $pin.Name | Should -Be 'Microsoft.WinGet.Client'
        $pin.Version | Should -Match '^\d+\.\d+\.\d+$'
        $pin.PackageUrl | Should -Be "https://www.powershellgallery.com/api/v2/package/Microsoft.WinGet.Client/$($pin.Version)"
        $pin.FileName | Should -Be "microsoft.winget.client.$($pin.Version).nupkg"
        # An empty pin is allowed (the engine is then NOT READY and winget.exe installs); a set one
        # has both values.
        [long]$pin.Size | Should -BeGreaterOrEqual 0
        "$($pin.Sha256)" | Should -Match '^([0-9A-F]{64})?$'
        ([long]$pin.Size -gt 0) | Should -Be ("$($pin.Sha256)".Length -gt 0)
        $pin.SignerCommonName | Should -Be 'Microsoft Corporation'
        [version]$pin.MinimumPowerShell | Should -BeGreaterOrEqual ([version]'7.4')
    }

    It 'Lists the signed files as relative paths, with {arch} only in the native folders' {
        $pin = Get-WingetClientModulePin

        @($pin.SignedFiles).Count | Should -BeGreaterThan 0
        foreach ($file in $pin.SignedFiles) {
            $file | Should -Not -Match '^(/|\\|[A-Za-z]:)'
            $file | Should -Not -Match '\.\.'
            if ($file -match '\{arch\}') {
                $file | Should -BeLike "$($pin.Framework)/SharedDependencies/{arch}/*"
            }
        }
        $pin.SignedFiles | Should -Contain 'Microsoft.WinGet.Client.psd1'
        $pin.SignedFiles | Should -Contain "$($pin.Framework)/SharedDependencies/{arch}/WindowsPackageManager.dll"
        # Third-party DLLs have other signers; the package SHA256 covers them.
        @($pin.SignedFiles | Where-Object { $_ -match 'Newtonsoft|Octokit|Semver' }) | Should -BeNullOrEmpty
    }

    It 'Maps the process architectures the module has engines for: <Name>' -ForEach @(
        @{ Name = 'X64'; Folder = 'x64' }
        @{ Name = 'X86'; Folder = 'x86' }
        @{ Name = 'Arm64'; Folder = 'arm64' }
        @{ Name = 'Arm'; Folder = $null }
        @{ Name = ''; Folder = $null }
    ) {
        ConvertTo-WingetClientArchitecture -Architecture $Name | Should -Be $Folder
    }
}

Describe 'Expand-WingetClientModulePackage' {
    BeforeEach {
        $script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:destination = Join-Path $script:root 'Microsoft.WinGet.Client'
    }

    It 'Keeps only the PowerShell 7 build and this architecture, without the NuGet metadata, the net48 build or the .nuspec' {
        $package = New-TestWingetClientPackage -Path (Join-Path $script:root 'p.nupkg')

        $result = Expand-TestPackage -PackagePath $package -Destination $script:destination

        $result.EngineFound | Should -BeTrue
        $result.ManifestPath | Should -Be (Join-Path ([System.IO.Path]::GetFullPath($script:destination)) 'Microsoft.WinGet.Client.psd1')
        Get-RelativeFile -Root $script:destination | Should -Be (@(
            'Format.ps1xml', 'Microsoft.WinGet.Client.psd1',
            "$script:Framework/DirectDependencies/Microsoft.WinGet.Client.Engine.dll",
            "$script:Framework/Microsoft.WinGet.Client.Cmdlets.dll",
            "$script:Framework/SharedDependencies/Microsoft.WinGet.SharedLib.dll",
            "$script:Framework/SharedDependencies/Newtonsoft.Json.dll",
            "$script:Framework/SharedDependencies/x64/Microsoft.Management.Deployment.dll",
            "$script:Framework/SharedDependencies/x64/Microsoft.Management.Deployment.winmd",
            "$script:Framework/SharedDependencies/x64/winrtact.dll",
            "$script:Framework/SharedDependencies/x64/WindowsPackageManager.dll",
            'NOTICE.txt'
        ) | Sort-Object)
    }

    It 'Keeps the arm64 engine on ARM64' {
        $package = New-TestWingetClientPackage -Path (Join-Path $script:root 'p.nupkg')

        [void](Expand-TestPackage -PackagePath $package -Destination $script:destination -Architecture 'arm64')

        @(Get-RelativeFile -Root $script:destination | Where-Object { $_ -match '/SharedDependencies/(x64|x86|arm64)/' } | ForEach-Object { ($_ -split '/')[2] } | Sort-Object -Unique) | Should -Be @('arm64')
    }

    It 'Decodes percent-escaped entry names' {
        $package = New-TestWingetClientPackage -Path (Join-Path $script:root 'p.nupkg') -ExtraEntries @("$script:Framework/Read%20Me.txt")

        [void](Expand-TestPackage -PackagePath $package -Destination $script:destination)

        Test-Path -LiteralPath (Join-Path $script:destination "$script:Framework/Read Me.txt") | Should -BeTrue
    }

    It 'Refuses an entry that leads outside its folder or names a root or a drive: <Entry>' -ForEach @(
        @{ Entry = '../outside.txt' }
        @{ Entry = 'net8.0-windows10.0.26100.0/../../outside.txt' }
        @{ Entry = '%2E%2E/outside.txt' }
        @{ Entry = 'C:/Windows/outside.txt' }
        @{ Entry = '/etc/outside.txt' }
    ) {
        $package = New-TestWingetClientPackage -Path (Join-Path $script:root 'p.nupkg') -ExtraEntries @($Entry)

        { Expand-TestPackage -PackagePath $package -Destination $script:destination } | Should -Throw '*the package has an entry*'
        Test-Path -LiteralPath (Join-Path $script:root 'outside.txt') | Should -BeFalse
    }

    It 'Refuses a package whose .nuspec names <Case>' -ForEach @(
        @{ Case = 'another package'; Id = 'Contoso.Client'; Version = '1.29.380' }
        @{ Case = 'another version'; Id = 'Microsoft.WinGet.Client'; Version = '1.29.381' }
    ) {
        $package = New-TestWingetClientPackage -Path (Join-Path $script:root 'p.nupkg') -Id $Id -Version $Version

        { Expand-TestPackage -PackagePath $package -Destination $script:destination } | Should -Throw "*names $Id $Version, not Microsoft.WinGet.Client 1.29.380*"
    }

    It 'Refuses a package without a .nuspec' {
        $package = New-TestWingetClientPackage -Path (Join-Path $script:root 'p.nupkg') -NoNuspec

        { Expand-TestPackage -PackagePath $package -Destination $script:destination } | Should -Throw '*has no .nuspec*'
    }

    It 'Reports a package without this architecture''s engine' {
        $package = New-TestWingetClientPackage -Path (Join-Path $script:root 'p.nupkg') -Architectures @('x86')

        (Expand-TestPackage -PackagePath $package -Destination $script:destination -Architecture 'x64').EngineFound | Should -BeFalse
    }

    It 'Leaves the stream open for the caller' {
        $package = New-TestWingetClientPackage -Path (Join-Path $script:root 'p.nupkg')
        $stream = Open-ReadLockedFile -Path $package
        try {
            [void](Expand-WingetClientModulePackage -Stream $stream -DestinationPath $script:destination -Framework $script:Framework -Architecture 'x64' -Pin (Get-WingetClientModulePin))

            $stream.CanRead | Should -BeTrue
        }
        finally {
            $stream.Dispose()
        }
    }
}

Describe 'Initialize-WingetClientModule' {
    BeforeEach {
        $script:savedProgramData = $env:ProgramData
        $env:ProgramData = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:cacheDirectory = Join-Path $env:ProgramData 'winget-app-setup/cache'
        $script:package = New-TestWingetClientPackage -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '/gallery.nupkg'))
        $script:pin = New-TestPin -Path $script:package
        $script:served = $script:package
        $script:stagingDirectories = @()

        Mock Get-WingetClientModulePin { $script:pin }
        Mock Get-PowerShellEdition { 'Core' }
        Mock Get-PowerShellVersion { [version]'7.6.6' }
        Mock Test-IsSystemAccount { $true }
        Mock Get-ProcessArchitecture { 'X64' }
        Mock Get-WindowsBuildNumber { 26100 }
        Mock New-WauStagingDirectory {
            $path = Join-Path $env:ProgramData ('winget-app-setup/{0}-{1}' -f $Prefix, [guid]::NewGuid().ToString('N'))
            [void](New-Item -ItemType Directory -Path $path -Force)
            $script:stagingDirectories += $path
            $path
        }
        Mock Set-RestrictedDirectoryAcl { }
        Mock Invoke-WebRequest { Copy-Item -LiteralPath $script:served -Destination $OutFile }
        Mock Get-AuthenticodeSignature { New-TestSignature }
        Mock Start-Sleep { }
        $script:lines = @()
        Mock Write-Info { $script:lines += "INFO: $Message" }
        Mock Write-Success { $script:lines += "OK: $Message" }
        Mock Write-WarningMessage { $script:lines += "WARN: $Message" }
        Mock Write-ErrorMessage { $script:lines += "ERROR: $Message" }
    }

    AfterEach {
        $env:ProgramData = $script:savedProgramData
    }

    It 'Downloads, checks and extracts the pinned package, writes the request script, and keeps the package in the cache' {
        $oldCached = Join-Path $script:cacheDirectory 'microsoft.winget.client.1.28.240.nupkg'
        [void](New-Item -ItemType Directory -Path $script:cacheDirectory -Force)
        Set-Content -LiteralPath $oldCached -Value 'old'

        $result = Initialize-WingetClientModule

        $result.Ready | Should -BeTrue
        $result.Source | Should -Be 'Download'
        $result.Version | Should -Be '1.29.380'
        $result.Sha256 | Should -Be $script:pin.Sha256
        $result.Architecture | Should -Be 'x64'
        $result.Directory | Should -Be $script:stagingDirectories[0]
        $result.PowerShellPath | Should -Be ([Environment]::ProcessPath)
        Test-Path -LiteralPath $result.ManifestPath -PathType Leaf | Should -BeTrue
        $result.ChildScriptPath | Should -Be (Join-Path $result.Directory 'Invoke-WingetClientRequest.ps1')
        Get-Content -Raw -LiteralPath $result.ChildScriptPath | Should -Be (Get-WingetClientChildScript)
        (Get-FileHash -LiteralPath (Join-Path $script:cacheDirectory $script:pin.FileName) -Algorithm SHA256).Hash | Should -Be $script:pin.Sha256
        Test-Path -LiteralPath $oldCached | Should -BeFalse
        @(Get-ChildItem -LiteralPath $script:cacheDirectory -Filter '*.partial').Count | Should -Be 0
        Should -Invoke New-WauStagingDirectory -Times 1 -Exactly -ParameterFilter { $Prefix -eq 'wingetclient' }
        Should -Invoke Set-RestrictedDirectoryAcl -Times 1 -Exactly -ParameterFilter { $Path -eq $script:cacheDirectory }
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Uri -eq $script:pin.PackageUrl -and $UseBasicParsing -and $TimeoutSec -gt 0 }
        # Each pinned signed file, with this architecture's native files.
        Should -Invoke Get-AuthenticodeSignature -Times @($script:pin.SignedFiles).Count -Exactly
        Should -Invoke Get-AuthenticodeSignature -Times 1 -Exactly -ParameterFilter { "$LiteralPath".Replace('\', '/') -like '*/SharedDependencies/x64/WindowsPackageManager.dll' }
        @($script:lines | Where-Object { $_ -match 'WinGet client module:' }) | Should -Be @("OK: WinGet client module: ready - Microsoft.WinGet.Client 1.29.380, SHA256 $($script:pin.Sha256), downloaded from the PowerShell Gallery.")
        $script:lines | Should -Contain 'INFO: Downloading Microsoft.WinGet.Client 1.29.380 from the PowerShell Gallery...'
    }

    It 'Uses a cached package that matches the pin, without downloading' {
        [void](New-Item -ItemType Directory -Path $script:cacheDirectory -Force)
        Copy-Item -LiteralPath $script:package -Destination (Join-Path $script:cacheDirectory $script:pin.FileName)

        $result = Initialize-WingetClientModule

        $result.Ready | Should -BeTrue
        $result.Source | Should -Be 'Cache'
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        @($script:lines | Where-Object { $_ -match 'WinGet client module:' }) | Should -Be @("OK: WinGet client module: ready - Microsoft.WinGet.Client 1.29.380, SHA256 $($script:pin.Sha256), from the cache.")
    }

    It 'Removes a link planted as the cache folder, without touching or locking its target, and caches in a real folder' {
        $target = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $target -Force)
        Set-Content -LiteralPath (Join-Path $target 'keep.txt') -Value 'not the cache'
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $script:cacheDirectory) -Force)
        # A junction needs no privilege on Windows; elsewhere a symbolic link is the same kind of link.
        $linkType = 'SymbolicLink'
        if ($IsWindows) {
            $linkType = 'Junction'
        }
        [void](New-Item -ItemType $linkType -Path $script:cacheDirectory -Target $target)
        $script:lockedLinks = @()
        Mock Set-RestrictedDirectoryAcl {
            $item = Get-Item -LiteralPath $Path -Force
            if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                $script:lockedLinks += $Path
            }
        }

        $result = Initialize-WingetClientModule

        $result.Ready | Should -BeTrue
        $script:lockedLinks | Should -BeNullOrEmpty
        Should -Invoke Set-RestrictedDirectoryAcl -Times 1 -Exactly -ParameterFilter { $Path -eq $script:cacheDirectory }
        ((Get-Item -LiteralPath $script:cacheDirectory -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) | Should -Be 0
        (Get-FileHash -LiteralPath (Join-Path $script:cacheDirectory $script:pin.FileName) -Algorithm SHA256).Hash | Should -Be $script:pin.Sha256
        @(Get-ChildItem -LiteralPath $target -Force | ForEach-Object { $_.Name }) | Should -Be @('keep.txt')
        @($script:lines | Where-Object { $_ -like 'WARN: *cache was a link, not a folder; it was removed and the cache folder is created again.' }).Count | Should -Be 1
    }

    It 'Deletes a cached package that does not match the pin and downloads it again' {
        [void](New-Item -ItemType Directory -Path $script:cacheDirectory -Force)
        Set-Content -LiteralPath (Join-Path $script:cacheDirectory $script:pin.FileName) -Value 'tampered'

        $result = Initialize-WingetClientModule

        $result.Ready | Should -BeTrue
        $result.Source | Should -Be 'Download'
        $script:lines | Should -Contain 'INFO: The cached Microsoft.WinGet.Client package did not match the pin; downloading it again.'
        (Get-FileHash -LiteralPath (Join-Path $script:cacheDirectory $script:pin.FileName) -Algorithm SHA256).Hash | Should -Be $script:pin.Sha256
    }

    It 'Is not ready, naming what it received, when the download is not the pinned package' {
        $script:served = New-TestWingetClientPackage -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '/other.nupkg')) -ExtraEntries @('extra.txt')
        $servedSize = (Get-Item -LiteralPath $script:served).Length
        $servedHash = (Get-FileHash -LiteralPath $script:served -Algorithm SHA256).Hash

        $result = Initialize-WingetClientModule

        $result.Ready | Should -BeFalse
        $result.Reason | Should -Be ('the downloaded package is {0} bytes with SHA256 {1}, not the pinned {2} bytes with SHA256 {3}' -f $servedSize, $servedHash, $script:pin.Size, $script:pin.Sha256)
        Test-Path -LiteralPath (Join-Path $script:cacheDirectory $script:pin.FileName) | Should -BeFalse
        Test-Path -LiteralPath $script:stagingDirectories[0] | Should -BeFalse
        @($script:lines | Where-Object { $_ -match 'WinGet client module:' }) | Should -Be @("WARN: WinGet client module: NOT READY - $($result.Reason).")
    }

    It 'Is not ready, naming the file, when a signed file fails its signature check, and removes its folder' {
        Mock Get-AuthenticodeSignature { New-TestSignature -Status 'HashMismatch' } -ParameterFilter { "$LiteralPath".Replace('\', '/') -like '*/x64/WindowsPackageManager.dll' }

        $result = Initialize-WingetClientModule

        $result.Ready | Should -BeFalse
        $result.Reason | Should -Match "^$([regex]::Escape("$script:Framework/SharedDependencies/x64/WindowsPackageManager.dll")) failed its signature check: it is not signed by Microsoft Corporation \(signature status: HashMismatch"
        $result.Directory | Should -BeNullOrEmpty
        Test-Path -LiteralPath $script:stagingDirectories[0] | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:cacheDirectory $script:pin.FileName) | Should -BeFalse
    }

    It 'Downloads nothing when the pin has no SHA256' {
        $script:pin.Size = 0
        $script:pin.Sha256 = ''

        $result = Initialize-WingetClientModule

        $result.Ready | Should -BeFalse
        $result.Reason | Should -Be 'its SHA256 pin is not set in this build'
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        Should -Invoke New-WauStagingDirectory -Times 0 -Exactly
    }

    It 'Is not ready, downloading nothing, when <Case>' -ForEach @(
        @{ Case = 'PowerShell is older than 7.4'; TestEdition = 'Core'; TestVersion = '7.3.12'; TestSystem = $true; TestArch = 'X64'; TestBuild = 26100; Reason = 'it needs PowerShell 7.4 or later, and this run is PowerShell 7.3.12 (Core)' }
        @{ Case = 'it runs in Windows PowerShell'; TestEdition = 'Desktop'; TestVersion = '5.1.26100'; TestSystem = $true; TestArch = 'X64'; TestBuild = 26100; Reason = 'it needs PowerShell 7.4 or later, and this run is PowerShell 5.1.26100 (Desktop)' }
        @{ Case = 'the run is not SYSTEM'; TestEdition = 'Core'; TestVersion = '7.6.6'; TestSystem = $false; TestArch = 'X64'; TestBuild = 26100; Reason = 'it is used only in a run as SYSTEM' }
        @{ Case = 'the process architecture has no engine'; TestEdition = 'Core'; TestVersion = '7.6.6'; TestSystem = $true; TestArch = 'Arm'; TestBuild = 26100; Reason = 'this PowerShell runs as a process of architecture Arm, and the module has engines for x64, x86 and Arm64 only' }
        @{ Case = 'Windows is older than build 17763'; TestEdition = 'Core'; TestVersion = '7.6.6'; TestSystem = $true; TestArch = 'X64'; TestBuild = 17134; Reason = 'Windows build 17134 is older than 17763, the oldest its engine supports' }
    ) {
        Mock Get-PowerShellEdition { $TestEdition }
        Mock Get-PowerShellVersion { [version]$TestVersion }
        Mock Test-IsSystemAccount { $TestSystem }
        Mock Get-ProcessArchitecture { $TestArch }
        Mock Get-WindowsBuildNumber { $TestBuild }

        $result = Initialize-WingetClientModule

        $result.Ready | Should -BeFalse
        $result.Reason | Should -Be $Reason
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        Should -Invoke New-WauStagingDirectory -Times 0 -Exactly
        @($script:lines | Where-Object { $_ -match 'WinGet client module:' }) | Should -Be @("WARN: WinGet client module: NOT READY - $Reason.")
    }

    It 'Tries the download twice, 15 seconds apart, and is not ready when both fail' {
        Mock Invoke-WebRequest { throw [System.Net.Http.HttpRequestException]::new('No such host is known. (www.powershellgallery.com:443)') }

        $result = Initialize-WingetClientModule

        $result.Ready | Should -BeFalse
        $result.Reason | Should -Be "downloading $($script:pin.PackageUrl) failed: No such host is known. (www.powershellgallery.com:443)"
        Should -Invoke Invoke-WebRequest -Times 2 -Exactly
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 15 }
        Test-Path -LiteralPath $script:stagingDirectories[0] | Should -BeFalse
    }

    It 'Recovers when the second download works' {
        $script:downloads = 0
        Mock Invoke-WebRequest { $script:downloads++; if ($script:downloads -eq 1) { throw 'The operation was canceled.' } Copy-Item -LiteralPath $script:served -Destination $OutFile }

        (Initialize-WingetClientModule).Ready | Should -BeTrue

        Should -Invoke Invoke-WebRequest -Times 2 -Exactly
    }

    It 'Never throws and writes one result line when its folder cannot be locked down, with how to reset it' {
        Mock New-WauStagingDirectory {
            throw [System.Management.Automation.ErrorRecord]::new([System.InvalidOperationException]::new('icacls failed.'), 'RestrictedDirectoryAclFailed', [System.Management.Automation.ErrorCategory]::SecurityError, $null)
        }

        { $script:result = Initialize-WingetClientModule } | Should -Not -Throw

        $script:result.Ready | Should -BeFalse
        $script:result.Reason | Should -Match '^setting up its folders failed: icacls failed\. To reset the folder, run in an elevated prompt: takeown /f '
        @($script:lines | Where-Object { $_ -match 'WinGet client module:' }).Count | Should -Be 1
    }

    It 'Is not ready when the package has no engine for this architecture' {
        $script:package = New-TestWingetClientPackage -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '/x86only.nupkg')) -Architectures @('x86')
        $script:pin = New-TestPin -Path $script:package
        $script:served = $script:package

        $result = Initialize-WingetClientModule

        $result.Ready | Should -BeFalse
        $result.Reason | Should -Be 'the package has no x64 engine'
    }
}

Describe 'Get-WingetClientChildScript' {
    BeforeAll {
        $script:childScript = Get-WingetClientChildScript
    }

    It 'Parses and is ASCII only' {
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($script:childScript, [ref]$null, [ref]$parseErrors)

        $parseErrors | Should -BeNullOrEmpty
        @([System.Text.Encoding]::UTF8.GetBytes($script:childScript) | Where-Object { $_ -gt 0x7F }).Count | Should -Be 0
    }

    It 'Never passes -Debug, SystemOrUnknown or Any, and never calls ErrorMessage()' {
        $script:childScript | Should -Not -Match '-Debug'
        $script:childScript | Should -Not -Match 'SystemOrUnknown'
        $script:childScript | Should -Not -MatchExactly '\bAny\b'
        $script:childScript | Should -Not -Match 'ErrorMessage\('
    }

    It 'Installs from the winget source, by exact id, for the whole PC, and lists by exact id' {
        $script:childScript | Should -Match "Source = 'winget'; MatchOption = 'Equals'; Scope = 'System'"
        $script:childScript | Should -Match '& \$Command -Id \$Id -MatchOption Equals -Source winget'
    }

    It 'Runs the module''s own commands, from the manifest it was given, at the version it expects' {
        $script:childScript | Should -Match "ExportedCommands\['Install-WinGetPackage'\]"
        $script:childScript | Should -Match "ExportedCommands\['Get-WinGetPackage'\]"
        $script:childScript | Should -Match "ExportedCommands\['Get-WinGetVersion'\]"
        $script:childScript | Should -Match 'Import-Module -Name \$manifestPath -PassThru -Force'
        $script:childScript | Should -Match '\$module\.Version -ne \[version\]\$ExpectedVersion'
        # No call by name, which would find the installer's own Install-WingetPackage function first.
        $script:childScript | Should -Not -Match '(?m)^\s*Install-WinGetPackage\b'
    }

    It 'Prints the result as one WINGET-CLIENT-RESULT line of protocol 1' {
        $script:childScript | Should -Match "'WINGET-CLIENT-RESULT ' \+ \(ConvertTo-Json -InputObject \`$Result -Compress -Depth 6 -EscapeHandling EscapeNonAscii\)"
        $script:childScript | Should -Match "\`$Result\['protocol'\] = 1"
    }
}

Describe 'Test-AuthenticodeSigner' {
    It 'Accepts a valid signature from the signer' {
        Mock Get-AuthenticodeSignature { New-TestSignature }

        $result = Test-AuthenticodeSigner -Path 'x.dll' -SignerCommonName 'Microsoft Corporation'

        $result.Valid | Should -BeTrue
        $result.Detail | Should -Match '^CN=Microsoft Corporation,'
    }

    It 'Refuses <Case>' -ForEach @(
        @{ Case = 'another signer'; Status = 'Valid'; Subject = 'CN=Json.NET (.NET Foundation), O=.NET Foundation'; Expected = '*not signed by Microsoft Corporation (signature status: Valid; signer: CN=Json.NET*' }
        @{ Case = 'a signer whose name only contains it'; Status = 'Valid'; Subject = 'CN=Microsoft Corporation Third Party, O=Contoso'; Expected = '*signature status: Valid; signer: CN=Microsoft Corporation Third Party*' }
        @{ Case = 'a signature that does not match the file'; Status = 'HashMismatch'; Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation'; Expected = '*signature status: HashMismatch*' }
        @{ Case = 'an unsigned file'; Status = 'NotSigned'; Subject = ''; Expected = '*signature status: NotSigned; signer: none*' }
    ) {
        Mock Get-AuthenticodeSignature { New-TestSignature -Status $Status -Subject $Subject }

        $result = Test-AuthenticodeSigner -Path 'x.dll' -SignerCommonName 'Microsoft Corporation'

        $result.Valid | Should -BeFalse
        $result.Detail | Should -BeLike $Expected
    }

    It 'Refuses a file whose signature cannot be read' {
        Mock Get-AuthenticodeSignature { throw 'Cannot find path' }

        (Test-AuthenticodeSigner -Path 'x.dll' -SignerCommonName 'Microsoft Corporation').Detail | Should -Be 'its signature could not be checked: Cannot find path'
    }

    It 'Is what Test-WindowsAppRuntimeSignature checks' {
        Mock Test-AuthenticodeSigner { [pscustomobject]@{ Valid = $true; Detail = 'CN=Microsoft Corporation' } }

        (Test-WindowsAppRuntimeSignature -Path 'fw.msix' -SignerCommonName 'Microsoft Corporation').Valid | Should -BeTrue

        Should -Invoke Test-AuthenticodeSigner -Times 1 -Exactly -ParameterFilter { $Path -eq 'fw.msix' -and $SignerCommonName -eq 'Microsoft Corporation' }
    }
}

# build/Set-WingetClientModulePin.ps1 moves the pin (wgt-gq8.42); its downloads need the Gallery,
# so only its rewrite of the pin is tested here.
Describe 'build/Set-WingetClientModulePin.ps1' {
    BeforeAll {
        . (Join-Path $script:RepoRoot 'build/Set-WingetClientModulePin.ps1')
    }

    It 'Rewrites the version, URL, file name, size and SHA256 of the pin, and nothing else' {
        $copy = Join-Path $TestDrive 'WingetClientModule.ps1'
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'WingetAppSetup/Private/WingetClientModule.ps1') -Destination $copy
        $before = Get-Content -LiteralPath $copy

        Set-WingetClientModulePinValue -Path $copy -Version '1.30.120' -Size 123 -Sha256 ('ab' * 32)

        . $copy
        $pin = Get-WingetClientModulePin
        $pin.Version | Should -Be '1.30.120'
        $pin.PackageUrl | Should -Be 'https://www.powershellgallery.com/api/v2/package/Microsoft.WinGet.Client/1.30.120'
        $pin.FileName | Should -Be 'microsoft.winget.client.1.30.120.nupkg'
        $pin.Size | Should -Be 123
        $pin.Sha256 | Should -Be ('AB' * 32)
        $after = Get-Content -LiteralPath $copy
        @(Compare-Object -ReferenceObject $before -DifferenceObject $after).Count | Should -Be 10
        . (Join-Path $script:RepoRoot 'WingetAppSetup/Private/WingetClientModule.ps1')
    }

    It 'Writes nothing when a pin line is missing or repeated' {
        $copy = Join-Path $TestDrive 'WingetClientModule-twice.ps1'
        $text = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'WingetAppSetup/Private/WingetClientModule.ps1'))
        $text = $text.Replace("        Size              = 21025850", "        Size              = 21025850`n        Size              = 1")
        [System.IO.File]::WriteAllText($copy, $text)

        { Set-WingetClientModulePinValue -Path $copy -Version '1.30.120' -Size 123 -Sha256 ('ab' * 32) } | Should -Throw "*has 2 'Size = ...' lines, not 1; nothing was written*"

        [System.IO.File]::ReadAllText($copy) | Should -BeExactly $text
    }

    It 'Holds the cross-check of nuget.org''s build of the same engine' {
        $script:InProcComEngineHashes['x64'].Sha256 | Should -Be '0FB0F8EEE1214AE3C17ABE740EA32964A7DA8B01F829FFA66DEC241B9FB3B384'
        $script:InProcComEngineHashes['arm64'].Size | Should -Be 8628064
        $script:InProcComEngineHashes['x86'].Size | Should -Be 6932280
    }
}
