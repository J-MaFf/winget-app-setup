# WindowsAppRuntime.Tests.ps1
# Tests for WingetAppSetup/Private/WindowsAppRuntime.ps1 (work-order item 31, finding R13-3): the
# pinned Microsoft.WindowsAppRuntime.1.8 framework that Install-WingetAutoUpdate installs for all
# users when it is missing. The download, Windows PowerShell, the signature check and
# Add-AppxProvisionedPackage are mocked; the package is a real zip file built in TestDrive, so the
# extraction, the held-open file and its hash run for real.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    # A zip file at $Path holding one file, $EntryName, with $Content (ASCII).
    function New-TestPackage {
        param (
            [Parameter(Mandatory = $true)][string]$Path,
            [Parameter(Mandatory = $true)][string]$EntryName,
            [Parameter(Mandatory = $true)][string]$Content
        )
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew)
        try {
            $archive = [System.IO.Compression.ZipArchive]::new($stream, [System.IO.Compression.ZipArchiveMode]::Create)
            try {
                $writer = [System.IO.StreamWriter]::new($archive.CreateEntry($EntryName).Open(), [System.Text.Encoding]::ASCII)
                try {
                    $writer.Write($Content)
                }
                finally {
                    $writer.Dispose()
                }
            }
            finally {
                $archive.Dispose()
            }
        }
        finally {
            $stream.Dispose()
        }
    }

    function Get-TestSha256 {
        param ([Parameter(Mandatory = $true)][string]$Content)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            return ([System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::ASCII.GetBytes($Content))) -replace '-', '')
        }
        finally {
            $sha.Dispose()
        }
    }

    function New-TestSignature {
        param ([string]$Status = 'Valid', [string]$Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US')
        [pscustomobject]@{ Status = $Status; SignerCertificate = [pscustomobject]@{ Subject = $Subject } }
    }

    $script:msixContent = 'pretend framework msix'
}

Describe 'Get-WindowsAppRuntimePin' {
    It 'pins one release, its NuGet package and a framework file for each architecture winget ships for' {
        $pin = Get-WindowsAppRuntimePin

        $pin.FrameworkVersion | Should -Be '8000.994.2142.0'
        # At or above what winget 1.12 and later need (Get-WindowsAppRuntimeStatus's minimum).
        [version]$pin.FrameworkVersion | Should -BeGreaterOrEqual ([version]'8000.616.304.0')
        $pin.PackageUrl | Should -Be ('https://api.nuget.org/v3-flatcontainer/microsoft.windowsappsdk.runtime/{0}/microsoft.windowsappsdk.runtime.{0}.nupkg' -f $pin.NuGetVersion)
        $pin.SignerCommonName | Should -Be 'Microsoft Corporation'
        @($pin.Frameworks.Keys | Sort-Object) | Should -Be @('Arm64', 'X64', 'X86')
        foreach ($architecture in $pin.Frameworks.Keys) {
            $framework = $pin.Frameworks[$architecture]
            $framework.Entry | Should -Be ('tools/MSIX/win10-{0}/Microsoft.WindowsAppRuntime.1.8.msix' -f $architecture.ToLowerInvariant())
            $framework.Sha256 | Should -Match '^[0-9A-F]{64}$'
            $framework.Size | Should -BeGreaterThan 0
        }
    }

    It 'names its architectures the way Get-OSArchitecture does, whatever their case' {
        $pin = Get-WindowsAppRuntimePin
        $pin.Frameworks['X64'] | Should -Not -BeNullOrEmpty
        $pin.Frameworks['Arm64'] | Should -Not -BeNullOrEmpty
        $pin.Frameworks['Arm'] | Should -BeNullOrEmpty
    }
}

Describe 'Get-WindowsAppRuntimeProvisionedInfo' {
    It 'reads the version and architecture from each provisioned package name and skips anything else' -Skip:($PSVersionTable.PSEdition -ne 'Core') {
        Mock powershell.exe {
            $global:LASTEXITCODE = 0
            'Microsoft.WindowsAppRuntime.1.8_8000.994.2142.0_x64__8wekyb3d8bbwe'
            'Microsoft.WindowsAppRuntime.1.8_8000.616.304.0_arm64__8wekyb3d8bbwe'
            'WARNING: noise'
            ''
        }

        $packages = @(Get-WindowsAppRuntimeProvisionedInfo)

        $packages.Count | Should -Be 2
        $packages[0].Version | Should -Be ([version]'8000.994.2142.0')
        $packages[0].Architecture | Should -Be 'X64'
        $packages[1].Architecture | Should -Be 'Arm64'
        Should -Invoke powershell.exe -Times 1 -Exactly -ParameterFilter { "$($args[-1])" -match "Get-AppxProvisionedPackage -Online" -and "$($args[-1])" -match "DisplayName -eq 'Microsoft\.WindowsAppRuntime\.1\.8'" }
    }

    It 'throws when the Windows PowerShell query fails' -Skip:($PSVersionTable.PSEdition -ne 'Core') {
        Mock powershell.exe { $global:LASTEXITCODE = 1 }

        { Get-WindowsAppRuntimeProvisionedInfo } | Should -Throw '*Get-AppxProvisionedPackage failed*'
    }
}

Describe 'Expand-WindowsAppRuntimeMsix' {
    BeforeEach {
        $script:package = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.nupkg')
        New-TestPackage -Path $script:package -EntryName 'tools/MSIX/win10-x64/Microsoft.WindowsAppRuntime.1.8.msix' -Content $script:msixContent
        $script:destination = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.msix')
    }

    It 'writes the pinned file out of the package' {
        Expand-WindowsAppRuntimeMsix -PackagePath $script:package -EntryName 'tools/MSIX/win10-x64/Microsoft.WindowsAppRuntime.1.8.msix' -ExpectedSize $script:msixContent.Length -DestinationPath $script:destination

        Get-Content -Raw -LiteralPath $script:destination | Should -Be $script:msixContent
    }

    It 'throws, and writes nothing, when the file in the package is not the pinned size' {
        { Expand-WindowsAppRuntimeMsix -PackagePath $script:package -EntryName 'tools/MSIX/win10-x64/Microsoft.WindowsAppRuntime.1.8.msix' -ExpectedSize 43025663 -DestinationPath $script:destination } |
            Should -Throw "*is $($script:msixContent.Length) bytes, not the pinned 43025663*"
        Test-Path -LiteralPath $script:destination | Should -BeFalse
    }

    It 'throws when the package does not hold the file' {
        { Expand-WindowsAppRuntimeMsix -PackagePath $script:package -EntryName 'tools/MSIX/win10-arm64/Microsoft.WindowsAppRuntime.1.8.msix' -ExpectedSize 1 -DestinationPath $script:destination } |
            Should -Throw '*the package holds no tools/MSIX/win10-arm64/Microsoft.WindowsAppRuntime.1.8.msix*'
    }

    It 'throws when the download is not a zip file at all' {
        Set-Content -LiteralPath $script:package -Value '<html>a proxy sign-in page</html>'

        { Expand-WindowsAppRuntimeMsix -PackagePath $script:package -EntryName 'tools/MSIX/win10-x64/Microsoft.WindowsAppRuntime.1.8.msix' -ExpectedSize 1 -DestinationPath $script:destination } | Should -Throw
    }
}

Describe 'Test-WindowsAppRuntimeSignature' {
    It 'accepts a valid signature from Microsoft Corporation' {
        Mock Get-AuthenticodeSignature { New-TestSignature }

        $result = Test-WindowsAppRuntimeSignature -Path 'fw.msix' -SignerCommonName 'Microsoft Corporation'

        $result.Valid | Should -BeTrue
        $result.Detail | Should -Match '^CN=Microsoft Corporation,'
        Should -Invoke Get-AuthenticodeSignature -Times 1 -Exactly -ParameterFilter { $LiteralPath -eq 'fw.msix' }
    }

    It 'rejects <Case>' -ForEach @(
        @{ Case = 'an unsigned file'; Status = 'NotSigned'; Subject = $null; Detail = 'signature status: NotSigned; signer: none' }
        @{ Case = 'a signature that does not match the file'; Status = 'HashMismatch'; Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation'; Detail = 'signature status: HashMismatch' }
        @{ Case = 'a valid signature from someone else'; Status = 'Valid'; Subject = 'CN=Contoso, O=Microsoft Corporation'; Detail = 'signer: CN=Contoso' }
        @{ Case = 'a signer whose name only starts with Microsoft Corporation'; Status = 'Valid'; Subject = 'CN=Microsoft Corporation Fake, O=Contoso'; Detail = 'signer: CN=Microsoft Corporation Fake' }
    ) {
        $script:status = $Status
        $script:subject = $Subject
        Mock Get-AuthenticodeSignature { [pscustomobject]@{ Status = $script:status; SignerCertificate = $(if ($script:subject) { [pscustomobject]@{ Subject = $script:subject } } else { $null }) } }

        $result = Test-WindowsAppRuntimeSignature -Path 'fw.msix' -SignerCommonName 'Microsoft Corporation'

        $result.Valid | Should -BeFalse
        $result.Detail | Should -Match ([regex]::Escape($Detail))
    }

    It 'reports a signature that could not be checked' {
        Mock Get-AuthenticodeSignature { throw 'The file is being used by another process.' }

        $result = Test-WindowsAppRuntimeSignature -Path 'fw.msix' -SignerCommonName 'Microsoft Corporation'

        $result.Valid | Should -BeFalse
        $result.Detail | Should -Match 'could not be checked: The file is being used by another process'
    }
}

Describe 'Install-WindowsAppRuntimeFramework (work-order item 31)' {
    BeforeAll {
        # The pin as shipped, read before any test mocks it.
        $script:realPin = Get-WindowsAppRuntimePin
    }

    BeforeEach {
        Mock Write-Host { }
        $script:infos = @()
        $script:warnings = @()
        $script:errors = @()
        $script:successes = @()
        Mock Write-Info { $script:infos += $Message }
        Mock Write-WarningMessage { $script:warnings += $Message }
        Mock Write-ErrorMessage { $script:errors += $Message }
        Mock Write-Success { $script:successes += $Message }

        # The real pin, with the X64 file replaced by the test package's, so the extraction, the
        # size check and the hash run for real.
        $script:pin = Get-WindowsAppRuntimePin
        $script:pin.Frameworks['X64'] = @{
            Entry  = 'tools/MSIX/win10-x64/Microsoft.WindowsAppRuntime.1.8.msix'
            Size   = $script:msixContent.Length
            Sha256 = (Get-TestSha256 -Content $script:msixContent)
        }
        Mock Get-WindowsAppRuntimePin { $script:pin }

        Mock Get-OSArchitecture { 'X64' }
        Mock Test-IsAdmin { $true }
        Mock Get-WindowsBuildNumber { 26100 }
        # Nothing provisioned before the install; the pinned build afterwards.
        $script:provisioned = $false
        Mock Get-WindowsAppRuntimeProvisionedInfo {
            if ($script:provisioned) {
                [pscustomobject]@{ Version = [version]'8000.994.2142.0'; Architecture = 'X64' }
            }
        }
        $script:stagingDir = Join-Path $TestDrive ('appruntime-' + [guid]::NewGuid().ToString('N'))
        Mock New-WauStagingDirectory { $null = New-Item -ItemType Directory -Path $script:stagingDir; $script:stagingDir }
        Mock Get-WebDownloadTimeoutParameters { @{ TimeoutSec = 7 } }
        Mock Invoke-WebRequest { New-TestPackage -Path $OutFile -EntryName 'tools/MSIX/win10-x64/Microsoft.WindowsAppRuntime.1.8.msix' -Content $script:msixContent }
        Mock Get-AuthenticodeSignature { New-TestSignature }
        # Records whether the hashed file is still held open while it is provisioned.
        $script:heldStream = $null
        Mock Open-ReadLockedFile { $script:heldStream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read); $script:heldStream }
        $script:heldDuringProvisioning = $null
        Mock Invoke-AppxProvisioning {
            $script:heldDuringProvisioning = ($null -ne $script:heldStream) -and $script:heldStream.CanRead
            $script:provisioned = $true
            $true
        }
        Mock Get-WindowsAppRuntimeStatus {
            [pscustomobject]@{ Present = $script:provisioned; Detail = 'checked after provisioning' }
        }
    }

    It 'downloads the pinned package, verifies the framework, provisions it for all users and checks again' {
        $result = Install-WindowsAppRuntimeFramework

        $result.Installed | Should -BeTrue
        $result.Reason | Should -BeNullOrEmpty
        $result.Status.Present | Should -BeTrue
        Should -Invoke New-WauStagingDirectory -Times 1 -Exactly -ParameterFilter { $Prefix -eq 'appruntime' }
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $Uri -eq $script:pin.PackageUrl -and $OutFile -like "$script:stagingDir*" -and (($ConnectionTimeoutSeconds -eq 7) -or ($TimeoutSec -eq 7))
        }
        Should -Invoke Get-AuthenticodeSignature -Times 1 -Exactly -ParameterFilter { $LiteralPath -eq (Join-Path $script:stagingDir 'Microsoft.WindowsAppRuntime.1.8.msix') }
        Should -Invoke Invoke-AppxProvisioning -Times 1 -Exactly -ParameterFilter {
            $PackagePath -eq (Join-Path $script:stagingDir 'Microsoft.WindowsAppRuntime.1.8.msix') -and
            -not $DependencyPackagePath -and -not $LicensePath -and
            $TimeoutSeconds -eq (Get-ProcessTimeoutSeconds -Operation AppxProvisioning)
        }
        Should -Invoke Get-WindowsAppRuntimeStatus -Times 1 -Exactly
        # Held open from the hash until provisioning had finished, then closed before the cleanup.
        $script:heldDuringProvisioning | Should -BeTrue
        $script:heldStream.CanRead | Should -BeFalse
        Test-Path -LiteralPath $script:stagingDir | Should -BeFalse
        $script:successes | Should -Be @('Windows App Runtime: installed Microsoft.WindowsAppRuntime.1.8 8000.994.2142.0 (X64) for all users.')
        $script:errors | Should -BeNullOrEmpty
        $script:warnings | Should -BeNullOrEmpty
    }

    It 'picks the framework file for the OS architecture: <Architecture>' -ForEach @(
        @{ Architecture = 'X64'; Folder = 'win10-x64' }
        @{ Architecture = 'X86'; Folder = 'win10-x86' }
        @{ Architecture = 'Arm64'; Folder = 'win10-arm64' }
    ) {
        $script:architecture = $Architecture
        Mock Get-WindowsAppRuntimePin { $script:realPin }
        Mock Get-OSArchitecture { $script:architecture }
        Mock Get-WindowsAppRuntimeProvisionedInfo { if ($script:provisioned) { [pscustomobject]@{ Version = [version]'8000.994.2142.0'; Architecture = $script:architecture } } }
        Mock Expand-WindowsAppRuntimeMsix { Set-Content -LiteralPath $DestinationPath -Value 'msix' }
        Mock Get-FileHash { @{ Hash = $script:realPin.Frameworks[$script:architecture].Sha256 } }

        $result = Install-WindowsAppRuntimeFramework

        $result.Installed | Should -BeTrue
        Should -Invoke Expand-WindowsAppRuntimeMsix -Times 1 -Exactly -ParameterFilter {
            $EntryName -eq "tools/MSIX/$Folder/Microsoft.WindowsAppRuntime.1.8.msix" -and $ExpectedSize -eq $script:realPin.Frameworks[$script:architecture].Size
        }
        $script:successes | Should -Be @("Windows App Runtime: installed Microsoft.WindowsAppRuntime.1.8 8000.994.2142.0 ($Architecture) for all users.")
    }

    It 'refuses a framework whose SHA256 is not the pinned one, and provisions nothing' {
        $script:pin.Frameworks['X64'].Sha256 = '0' * 64

        $result = Install-WindowsAppRuntimeFramework

        $result.Installed | Should -BeFalse
        $result.Reason | Should -Match "the downloaded framework's SHA256 is [0-9A-F]{64}, not the pinned 0{64}$"
        Should -Invoke Invoke-AppxProvisioning -Times 0 -Exactly
        $script:heldStream.CanRead | Should -BeFalse
        Test-Path -LiteralPath $script:stagingDir | Should -BeFalse
        $script:errors | Should -Be @("Windows App Runtime: NOT INSTALLED - $($result.Reason).")
    }

    It 'refuses a framework that is not validly signed by Microsoft, and provisions nothing' {
        Mock Get-AuthenticodeSignature { New-TestSignature -Status 'NotSigned' }

        $result = Install-WindowsAppRuntimeFramework

        $result.Installed | Should -BeFalse
        $result.Reason | Should -Match '^the downloaded framework failed its signature check: it is not signed by Microsoft Corporation \(signature status: NotSigned'
        Should -Invoke Invoke-AppxProvisioning -Times 0 -Exactly
    }

    It 'refuses a package whose framework file is not the pinned size, and provisions nothing' {
        $script:pin.Frameworks['X64'].Size = 43025663

        $result = Install-WindowsAppRuntimeFramework

        $result.Installed | Should -BeFalse
        $result.Reason | Should -Match '^extracting the framework from the package failed: .* bytes, not the pinned 43025663'
        Should -Invoke Invoke-AppxProvisioning -Times 0 -Exactly
        Test-Path -LiteralPath $script:stagingDir | Should -BeFalse
    }

    It 'does not download anything when <Case>' -ForEach @(
        @{ Case = 'the OS architecture has no pinned framework (32-bit Arm)'; Setup = { Mock Get-OSArchitecture { 'Arm' } }; Reason = 'Microsoft publishes no Windows App Runtime 1.8 framework for Arm Windows' }
        @{ Case = 'the OS architecture cannot be read'; Setup = { Mock Get-OSArchitecture { throw 'The OS architecture could not be read.' } }; Reason = 'the OS architecture could not be read (The OS architecture could not be read.)' }
        @{ Case = 'the run is not elevated'; Setup = { Mock Test-IsAdmin { $false } }; Reason = 'installing it for all users needs administrator rights' }
        @{ Case = 'Windows is older than the framework supports'; Setup = { Mock Get-WindowsBuildNumber { 17134 } }; Reason = 'Windows build 17134 is older than 17763, the oldest the framework supports' }
        @{ Case = 'a newer framework is already provisioned (never downgraded)'; Setup = { Mock Get-WindowsAppRuntimeProvisionedInfo { [pscustomobject]@{ Version = [version]'8000.1001.5.0'; Architecture = 'X64' } } }; Reason = 'Microsoft.WindowsAppRuntime.1.8 8000.1001.5.0 (X64) is already provisioned for this PC, at or above the pinned 8000.994.2142.0, but no user has it; the installer does not replace it' }
    ) {
        . $Setup

        $result = Install-WindowsAppRuntimeFramework

        $result.Installed | Should -BeFalse
        $result.Reason | Should -Be $Reason
        Should -Invoke New-WauStagingDirectory -Times 0 -Exactly
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        Should -Invoke Invoke-AppxProvisioning -Times 0 -Exactly
        $script:errors | Should -Be @("Windows App Runtime: NOT INSTALLED - $Reason.")
    }

    It 'installs over an older provisioned build, or one for another architecture' {
        Mock Get-WindowsAppRuntimeProvisionedInfo {
            if ($script:provisioned) {
                [pscustomobject]@{ Version = [version]'8000.994.2142.0'; Architecture = 'X64' }
            }
            [pscustomobject]@{ Version = [version]'8000.616.304.0'; Architecture = 'X64' }
            [pscustomobject]@{ Version = [version]'8000.1001.5.0'; Architecture = 'Arm64' }
        }

        (Install-WindowsAppRuntimeFramework).Installed | Should -BeTrue
        Should -Invoke Invoke-AppxProvisioning -Times 1 -Exactly
    }

    It 'goes ahead, with a warning, when the provisioned packages cannot be listed' {
        Mock Get-WindowsAppRuntimeProvisionedInfo { throw 'DISM failed' }

        $result = Install-WindowsAppRuntimeFramework

        $result.Installed | Should -BeTrue
        $script:warnings | Should -Contain 'Could not list the provisioned Microsoft.WindowsAppRuntime.1.8 packages: DISM failed'
        $script:warnings | Should -Contain 'Could not list the provisioned Microsoft.WindowsAppRuntime.1.8 packages to confirm the install: DISM failed'
    }

    It 'reports a download that fails, names the URL, and cleans up' {
        Mock Invoke-WebRequest { throw 'Response status code does not indicate success: 407 (Proxy Authentication Required).' }

        $result = Install-WindowsAppRuntimeFramework

        $result.Installed | Should -BeFalse
        $result.Reason | Should -Be "downloading $($script:pin.PackageUrl) failed: Response status code does not indicate success: 407 (Proxy Authentication Required)"
        Test-Path -LiteralPath $script:stagingDir | Should -BeFalse
        Should -Invoke Invoke-AppxProvisioning -Times 0 -Exactly
    }

    It 'says how to reset a download folder that cannot be limited to SYSTEM and Administrators' {
        Mock New-WauStagingDirectory {
            $exception = [System.InvalidOperationException]::new("'C:\ProgramData\winget-app-setup' is not limited to SYSTEM and Administrators: it is owned by PC\User (S-1-5-21-1).")
            throw [System.Management.Automation.ErrorRecord]::new($exception, 'RestrictedDirectoryAclFailed', [System.Management.Automation.ErrorCategory]::SecurityError, 'C:\ProgramData\winget-app-setup')
        }

        $result = Install-WindowsAppRuntimeFramework

        $result.Installed | Should -BeFalse
        $result.Reason | Should -Match '^setting up its download folder failed: .*is owned by PC\\User.* To reset the folder, run in an elevated prompt: takeown /f '
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    It 'reports a failed Add-AppxProvisionedPackage' {
        Mock Invoke-AppxProvisioning { $false }

        $result = Install-WindowsAppRuntimeFramework

        $result.Installed | Should -BeFalse
        $result.Reason | Should -Match '^Add-AppxProvisionedPackage failed \(its error is above\)'
        Should -Invoke Get-WindowsAppRuntimeStatus -Times 0 -Exactly
        Test-Path -LiteralPath $script:stagingDir | Should -BeFalse
    }

    It 'trusts the check afterwards, not Add-AppxProvisionedPackage: still missing means not installed' {
        Mock Get-WindowsAppRuntimeStatus { [pscustomobject]@{ Present = $false; Detail = 'Microsoft.WindowsAppRuntime.1.8 >= 8000.616.304.0 for X64 required; found: none registered' } }

        $result = Install-WindowsAppRuntimeFramework

        $result.Installed | Should -BeFalse
        $result.Reason | Should -Be 'Add-AppxProvisionedPackage reported success, but the framework is still not there (Microsoft.WindowsAppRuntime.1.8 >= 8000.616.304.0 for X64 required; found: none registered)'
    }

    # Review of item 31: an unknown answer after a successful provisioning used to read as 'still
    # not there', so WAU was skipped with exit 8, while the WAU gate goes ahead on an unknown answer.
    It 'counts the install as done, with a warning, when the check afterwards cannot run' {
        Mock Get-WindowsAppRuntimeStatus { [pscustomobject]@{ Present = $null; Detail = 'could not query installed packages: Access is denied' } }

        $result = Install-WindowsAppRuntimeFramework

        $result.Installed | Should -BeTrue
        $result.Reason | Should -BeNullOrEmpty
        $result.Status.Present | Should -BeNullOrEmpty
        $script:errors | Should -BeNullOrEmpty
        $script:warnings | Should -Be @('Add-AppxProvisionedPackage succeeded, but the check for Microsoft.WindowsAppRuntime.1.8 afterwards could not run (could not query installed packages: Access is denied); going ahead as if it is there.')
        $script:successes | Should -Be @('Windows App Runtime: installed Microsoft.WindowsAppRuntime.1.8 8000.994.2142.0 (X64) for all users, not confirmed: the check afterwards could not run.')
    }

    It 'says that nothing confirms the install when neither check finds it' {
        Mock Get-WindowsAppRuntimeStatus { [pscustomobject]@{ Present = $null; Detail = 'could not query installed packages: Access is denied' } }
        Mock Get-WindowsAppRuntimeProvisionedInfo { }

        $result = Install-WindowsAppRuntimeFramework

        $result.Installed | Should -BeTrue
        $script:warnings | Should -Contain 'Get-AppxProvisionedPackage does not list Microsoft.WindowsAppRuntime.1.8 as provisioned for all users either, so nothing confirms the install; accounts that sign in for the first time may not get it.'
        $script:warnings | Should -Not -Contain 'Microsoft.WindowsAppRuntime.1.8 is now on this PC, but Get-AppxProvisionedPackage does not list it as provisioned for all users; accounts that sign in for the first time may not get it.'
    }

    It 'counts a framework that is there but not provisioned for all users as installed, with a warning' {
        Mock Get-WindowsAppRuntimeStatus { [pscustomobject]@{ Present = $true; Detail = 'X64 8000.994.2142.0' } }
        Mock Get-WindowsAppRuntimeProvisionedInfo { }

        $result = Install-WindowsAppRuntimeFramework

        $result.Installed | Should -BeTrue
        $script:warnings | Should -Contain 'Microsoft.WindowsAppRuntime.1.8 is now on this PC, but Get-AppxProvisionedPackage does not list it as provisioned for all users; accounts that sign in for the first time may not get it.'
    }

    It 'never throws: an unexpected error becomes the reason' {
        Mock Get-WindowsBuildNumber { throw 'boom' }

        $result = Install-WindowsAppRuntimeFramework

        $result.Installed | Should -BeFalse
        $result.Reason | Should -Be 'unexpected error: boom'
    }

    It 'never uses Repair-WinGetPackageManager -AllUsers (issue #265)' {
        $body = (Get-Command Install-WindowsAppRuntimeFramework).Definition
        $body | Should -Not -Match 'Repair-WinGetPackageManager'
    }
}
