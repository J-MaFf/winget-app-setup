# WingetAutoUpdate.Tests.ps1
# Tests for WingetAppSetup/Public/WingetAutoUpdate.ps1 and Private/WauSupport.ps1:
# the pinned Winget-AutoUpdate install/upgrade/uninstall flow and its staging helpers.
# Split from the old single-file suite Test-WingetAppInstall.Tests.ps1 (issue #192).

# Load the module's functions once for this file. TestHelpers.ps1 resolves the repo paths
# and dot-sources WingetAppSetup/Private + Public (the single source of truth; the
# distributable winget-app-install.ps1 is generated from it by build/Build-WingetInstallScript.ps1).
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'Winget-AutoUpdate integration (issue #168)' {
    BeforeEach {
        Mock Write-Host { }
        Mock Write-Info { }
        Mock Write-Success { }
        Mock Write-WarningMessage { }
        Mock Write-ErrorMessage { }
    }

    Context 'Get-WauPin' {
        It 'returns the pinned version, MSI url, sha256, and product code' {
            $pin = Get-WauPin
            $pin.Version | Should -Be '2.12.0'
            $pin.MsiUrl | Should -Match 'v2\.12\.0/WAU\.msi$'
            $pin.Sha256 | Should -Match '^[0-9A-Fa-f]{64}$'
            $pin.ProductCode | Should -Match '^\{[0-9A-Fa-f-]+\}$'
        }
    }

    Context 'Get-InstalledWauInfo (issue #186)' {
        It 'resolves the ProductCode and version from the matching MSI uninstall entry' {
            Mock Test-Path { $true }
            Mock Get-ChildItem {
                [pscustomobject]@{ PSPath = 'HKLM:\...\Uninstall\{11111111-2222-3333-4444-555555555555}'; PSChildName = '{11111111-2222-3333-4444-555555555555}' }
            }
            Mock Get-ItemProperty { [pscustomobject]@{ DisplayName = 'Winget-AutoUpdate'; DisplayVersion = '2.9.0' } }

            $info = Get-InstalledWauInfo

            $info.ProductCode | Should -Be '{11111111-2222-3333-4444-555555555555}'
            $info.Version | Should -Be ([version]'2.9.0')
        }

        It 'skips uninstall entries whose DisplayName does not match WAU' {
            Mock Test-Path { $true }
            Mock Get-ChildItem {
                @(
                    [pscustomobject]@{ PSPath = 'HKLM:\...\Uninstall\{99999999-0000-0000-0000-000000000000}'; PSChildName = '{99999999-0000-0000-0000-000000000000}' },
                    [pscustomobject]@{ PSPath = 'HKLM:\...\Uninstall\{11111111-2222-3333-4444-555555555555}'; PSChildName = '{11111111-2222-3333-4444-555555555555}' }
                )
            }
            Mock Get-ItemProperty { [pscustomobject]@{ DisplayName = 'Some Other App'; DisplayVersion = '9.9.9' } } -ParameterFilter { $Path -like '*99999999*' }
            Mock Get-ItemProperty { [pscustomobject]@{ DisplayName = 'Winget-AutoUpdate'; DisplayVersion = '2.10.1' } } -ParameterFilter { $Path -like '*11111111*' }

            $info = Get-InstalledWauInfo

            $info.ProductCode | Should -Be '{11111111-2222-3333-4444-555555555555}'
            $info.Version | Should -Be ([version]'2.10.1')
        }

        It 'falls back to the Romanitho registry key for the version when no uninstall entry matches' {
            Mock Test-Path { $true }
            Mock Get-ChildItem { @() }
            Mock Get-ItemProperty { [pscustomobject]@{ DisplayVersion = $null; ProductVersion = 'v2.8.0' } } -ParameterFilter { $Path -like '*Romanitho*' }

            $info = Get-InstalledWauInfo

            $info.ProductCode | Should -BeNullOrEmpty
            $info.Version | Should -Be ([version]'2.8.0')
        }

        It 'returns nulls when WAU is nowhere in the registry' {
            Mock Test-Path { $false }
            Mock Get-ChildItem { throw 'should not enumerate when the roots are absent' }
            Mock Get-ItemProperty { throw 'should not read properties when the roots are absent' }

            $info = Get-InstalledWauInfo

            $info.ProductCode | Should -BeNullOrEmpty
            $info.Version | Should -BeNullOrEmpty
        }
    }

    Context 'New-WauStagingDirectory / Set-RestrictedDirectoryAcl (issue #186)' {
        BeforeEach {
            $script:origProgramData = $env:ProgramData
            if (-not $env:ProgramData) {
                $env:ProgramData = Join-Path ([System.IO.Path]::GetTempPath()) 'programdata-test'
            }
        }

        AfterEach {
            $env:ProgramData = $script:origProgramData
        }

        It 'creates a unique directory under ProgramData\winget-app-setup and restricts base and staging ACLs' {
            Mock New-Item { }
            Mock Set-RestrictedDirectoryAcl { }

            $dir = New-WauStagingDirectory

            $baseDir = Join-Path $env:ProgramData 'winget-app-setup'
            $dir | Should -BeLike (Join-Path $baseDir 'wau-msi-*')
            Should -Invoke New-Item -Times 2 -Exactly
            Should -Invoke Set-RestrictedDirectoryAcl -Times 1 -Exactly -ParameterFilter { $Path -eq $baseDir }
            Should -Invoke Set-RestrictedDirectoryAcl -Times 1 -Exactly -ParameterFilter { $Path -eq $dir }
        }

        It 'generates a different staging directory name on every run' {
            Mock New-Item { }
            Mock Set-RestrictedDirectoryAcl { }

            (New-WauStagingDirectory) | Should -Not -Be (New-WauStagingDirectory)
        }

        It 'makes Administrators the owner first, then removes inherited entries and replaces the SYSTEM and Administrators grants (review finding P2-21)' {
            $script:icaclsCalls = @()
            Mock Start-Process { $script:icaclsCalls += $ArgumentList; [pscustomobject]@{ ExitCode = 0 } } -ParameterFilter { $FilePath -eq 'icacls.exe' }
            Mock Assert-RestrictedDirectoryAcl { }

            Set-RestrictedDirectoryAcl -Path 'C:\ProgramData\winget-app-setup\wau-msi-test'

            $script:icaclsCalls.Count | Should -Be 2
            # The installer's non-elevated first launch creates the folder, owned by the signed-in
            # user, and an owner can always rewrite the access list: ownership has to change first.
            $script:icaclsCalls[0] | Should -Be '"C:\ProgramData\winget-app-setup\wau-msi-test" /setowner *S-1-5-32-544 /q'
            # /grant:r replaces explicit SYSTEM and Administrators entries instead of adding to them.
            $script:icaclsCalls[1] | Should -Be '"C:\ProgramData\winget-app-setup\wau-msi-test" /inheritance:r /grant:r *S-1-5-18:(OI)(CI)F *S-1-5-32-544:(OI)(CI)F /q'
            Should -Invoke Assert-RestrictedDirectoryAcl -Times 1 -Exactly -ParameterFilter { $Path -eq 'C:\ProgramData\winget-app-setup\wau-msi-test' }
        }

        It 'changes only the folder itself, so the read grant on the logs folder inside it survives' {
            $script:icaclsCalls = @()
            Mock Start-Process { $script:icaclsCalls += $ArgumentList; [pscustomobject]@{ ExitCode = 0 } } -ParameterFilter { $FilePath -eq 'icacls.exe' }
            Mock Assert-RestrictedDirectoryAcl { }

            Set-RestrictedDirectoryAcl -Path 'C:\ProgramData\winget-app-setup'

            # /T would replace the logs folder's explicit BUILTIN\Users read grant
            # (Grant-InstallLogReadAccess, review finding P3-14), and so would /reset.
            foreach ($arguments in $script:icaclsCalls) {
                $arguments | Should -Not -Match '(^|\s)/[tT](\s|$)'
                $arguments | Should -Not -Match '/reset'
            }
        }

        It 'throws when icacls fails so callers never use an unsecured directory' {
            Mock Start-Process { [pscustomobject]@{ ExitCode = 5 } }
            Mock Assert-RestrictedDirectoryAcl { }

            { Set-RestrictedDirectoryAcl -Path 'C:\ProgramData\winget-app-setup\wau-msi-test' } | Should -Throw '*exit code 5*'
            Should -Invoke Start-Process -Times 1 -Exactly
            Should -Invoke Assert-RestrictedDirectoryAcl -Times 0 -Exactly
        }

        It 'throws when the folder is still owned by the user who created it, although icacls reported success (review finding P2-21)' {
            Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } } -ParameterFilter { $FilePath -eq 'icacls.exe' }
            Mock Get-DirectoryAccessSummary {
                [pscustomobject]@{
                    OwnerSid             = 'S-1-5-21-1111111111-2222222222-3333333333-1001'
                    OwnerName            = 'PC01\enduser'
                    InheritanceProtected = $true
                    AccessRules          = @(
                        [pscustomobject]@{ Sid = 'S-1-5-18'; Name = 'NT AUTHORITY\SYSTEM'; AccessControlType = 'Allow'; IsInherited = $false },
                        [pscustomobject]@{ Sid = 'S-1-5-32-544'; Name = 'BUILTIN\Administrators'; AccessControlType = 'Allow'; IsInherited = $false }
                    )
                }
            }

            { Set-RestrictedDirectoryAcl -Path 'C:\ProgramData\winget-app-setup' } |
                Should -Throw "*'C:\ProgramData\winget-app-setup' is not limited to SYSTEM and Administrators: it is owned by PC01\enduser (S-1-5-21-1111111111-2222222222-3333333333-1001).*"
        }

        # The caller suggests resetting the folder's owner and access list only for these failures,
        # so they carry an error id it can tell apart from any other.
        It 'tags an icacls failure with the error id RestrictedDirectoryAclFailed' {
            Mock Start-Process { [pscustomobject]@{ ExitCode = 5 } } -ParameterFilter { $FilePath -eq 'icacls.exe' }

            { Set-RestrictedDirectoryAcl -Path 'C:\ProgramData\winget-app-setup' } |
                Should -Throw -ErrorId 'RestrictedDirectoryAclFailed' -ExpectedMessage "icacls failed to make Administrators the owner of 'C:\ProgramData\winget-app-setup' (exit code 5)."
        }

        It 'tags a failed check of the result with the error id RestrictedDirectoryAclFailed' {
            Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } } -ParameterFilter { $FilePath -eq 'icacls.exe' }
            Mock Assert-RestrictedDirectoryAcl { throw "'C:\ProgramData\winget-app-setup' is not limited to SYSTEM and Administrators: it is owned by PC01\enduser (S-1-5-21-1-2-3-1001)." }

            { Set-RestrictedDirectoryAcl -Path 'C:\ProgramData\winget-app-setup' } |
                Should -Throw -ErrorId 'RestrictedDirectoryAclFailed' -ExpectedMessage "'C:\ProgramData\winget-app-setup' is not limited to SYSTEM and Administrators: it is owned by PC01\enduser (S-1-5-21-1-2-3-1001)."
        }

        It 'tags an access list that cannot be read with the error id RestrictedDirectoryAclFailed' {
            Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } } -ParameterFilter { $FilePath -eq 'icacls.exe' }
            Mock Get-DirectoryAccessSummary { throw 'Attempted to perform an unauthorized operation.' }

            { Set-RestrictedDirectoryAcl -Path 'C:\ProgramData\winget-app-setup' } |
                Should -Throw -ErrorId 'RestrictedDirectoryAclFailed' -ExpectedMessage '*unauthorized operation*'
        }
    }

    Context 'Assert-RestrictedDirectoryAcl (review finding P2-21)' {
        BeforeAll {
            function New-TestAccessRule {
                param ([string]$Sid, [string]$Name = $Sid, [string]$Type = 'Allow', [switch]$Inherited)
                [pscustomobject]@{ Sid = $Sid; Name = $Name; AccessControlType = $Type; IsInherited = [bool]$Inherited }
            }
            function New-TestAccessSummary {
                param ([string]$OwnerSid = 'S-1-5-32-544', [string]$OwnerName = 'BUILTIN\Administrators', [switch]$Unprotected, [object[]]$ExtraRules = @())
                [pscustomobject]@{
                    OwnerSid             = $OwnerSid
                    OwnerName            = $OwnerName
                    InheritanceProtected = -not $Unprotected
                    AccessRules          = @(
                        (New-TestAccessRule -Sid 'S-1-5-18' -Name 'NT AUTHORITY\SYSTEM'),
                        (New-TestAccessRule -Sid 'S-1-5-32-544' -Name 'BUILTIN\Administrators')
                    ) + @($ExtraRules)
                }
            }
        }

        It 'accepts a folder owned by Administrators with only SYSTEM and Administrators entries' {
            Mock Get-DirectoryAccessSummary { New-TestAccessSummary }

            { Assert-RestrictedDirectoryAcl -Path 'C:\ProgramData\winget-app-setup' } | Should -Not -Throw
            Should -Invoke Get-DirectoryAccessSummary -Times 1 -Exactly -ParameterFilter { $Path -eq 'C:\ProgramData\winget-app-setup' }
        }

        It 'accepts a folder owned by SYSTEM (a run as SYSTEM)' {
            Mock Get-DirectoryAccessSummary { New-TestAccessSummary -OwnerSid 'S-1-5-18' -OwnerName 'NT AUTHORITY\SYSTEM' }

            { Assert-RestrictedDirectoryAcl -Path 'C:\ProgramData\winget-app-setup' } | Should -Not -Throw
        }

        It 'rejects any other owner: an owner can always rewrite the access list' {
            Mock Get-DirectoryAccessSummary { New-TestAccessSummary -OwnerSid 'S-1-5-21-1-2-3-1001' -OwnerName 'PC01\enduser' }

            { Assert-RestrictedDirectoryAcl -Path 'C:\ProgramData\winget-app-setup' } | Should -Throw '*it is owned by PC01\enduser (S-1-5-21-1-2-3-1001)*'
        }

        It 'rejects an explicit entry for another account, which /grant:r leaves in place' {
            Mock Get-DirectoryAccessSummary { New-TestAccessSummary -ExtraRules @(New-TestAccessRule -Sid 'S-1-5-21-1-2-3-1001' -Name 'PC01\enduser') }

            { Assert-RestrictedDirectoryAcl -Path 'C:\ProgramData\winget-app-setup' } | Should -Throw '*PC01\enduser (S-1-5-21-1-2-3-1001) has an access entry (allow)*'
        }

        It 'rejects a deny entry for another account too' {
            Mock Get-DirectoryAccessSummary { New-TestAccessSummary -ExtraRules @(New-TestAccessRule -Sid 'S-1-5-32-545' -Name 'BUILTIN\Users' -Type 'Deny') }

            { Assert-RestrictedDirectoryAcl -Path 'C:\ProgramData\winget-app-setup' } | Should -Throw '*BUILTIN\Users (S-1-5-32-545) has an access entry (deny)*'
        }

        It 'rejects entries inherited from the parent folder' {
            Mock Get-DirectoryAccessSummary { New-TestAccessSummary -Unprotected -ExtraRules @(New-TestAccessRule -Sid 'S-1-5-32-545' -Name 'BUILTIN\Users' -Inherited) }

            { Assert-RestrictedDirectoryAcl -Path 'C:\ProgramData\winget-app-setup' } |
                Should -Throw '*it still inherits permissions from its parent folder; BUILTIN\Users (S-1-5-32-545) has an access entry (allow)*'
        }

        It 'fails when the access list cannot be read' {
            Mock Get-DirectoryAccessSummary { throw 'Attempted to perform an unauthorized operation.' }

            { Assert-RestrictedDirectoryAcl -Path 'C:\ProgramData\winget-app-setup' } | Should -Throw '*unauthorized operation*'
        }
    }

    Context 'Get-DirectoryAccessSummary' {
        It 'reads the owner and every access entry by SID from Get-Acl' {
            Mock Get-Acl {
                $acl = [pscustomobject]@{
                    AreAccessRulesProtected = $true
                    TestOwner               = [pscustomobject]@{ Value = 'S-1-5-32-544' }
                    TestRules               = @(
                        [pscustomobject]@{ IdentityReference = [pscustomobject]@{ Value = 'S-1-5-18' }; AccessControlType = 'Allow'; IsInherited = $false },
                        [pscustomobject]@{ IdentityReference = [pscustomobject]@{ Value = 'S-1-5-21-1-2-3-1001' }; AccessControlType = 'Deny'; IsInherited = $true }
                    )
                }
                $acl | Add-Member -MemberType ScriptMethod -Name GetOwner -Value { param ($Type) $this.TestOwner }
                $acl | Add-Member -MemberType ScriptMethod -Name GetAccessRules -Value { param ($Explicit, $Inherited, $Type) $this.TestRules }
                $acl
            }

            $summary = Get-DirectoryAccessSummary -Path 'C:\ProgramData\winget-app-setup'

            Should -Invoke Get-Acl -Times 1 -Exactly -ParameterFilter { $LiteralPath -eq 'C:\ProgramData\winget-app-setup' }
            $summary.OwnerSid | Should -Be 'S-1-5-32-544'
            $summary.InheritanceProtected | Should -BeTrue
            @($summary.AccessRules).Count | Should -Be 2
            $summary.AccessRules[1].Sid | Should -Be 'S-1-5-21-1-2-3-1001'
            $summary.AccessRules[1].AccessControlType | Should -Be 'Deny'
            $summary.AccessRules[1].IsInherited | Should -BeTrue
            # A SID that does not resolve to a name is shown as the SID.
            $summary.AccessRules[1].Name | Should -Be 'S-1-5-21-1-2-3-1001'
        }
    }

    Context 'Open-ReadLockedFile (review finding P2-21)' {
        It 'opens the file for reading only' {
            $path = Join-Path $TestDrive 'locked.msi'
            Set-Content -LiteralPath $path -Value 'msi'
            $stream = Open-ReadLockedFile -Path $path
            try {
                $stream.CanRead | Should -BeTrue
                $stream.CanWrite | Should -BeFalse
            }
            finally {
                $stream.Dispose()
            }
        }

        # Windows enforces the sharing mode; Linux does not, so this runs on Windows CI only. NTFS
        # refuses to rename a folder with an open file beneath it ([MS-FSA] 2.1.5.15.12, note 186).
        It 'keeps the file from being overwritten, deleted or moved, and its folder from being renamed, while it is open' -Skip:(-not $IsWindows) {
            $folder = Join-Path $TestDrive 'wau-msi-locked'
            $null = New-Item -ItemType Directory -Path $folder
            $path = Join-Path $folder 'WAU.msi'
            Set-Content -LiteralPath $path -Value 'genuine'
            $stream = Open-ReadLockedFile -Path $path
            try {
                { [System.IO.File]::Open($path, 'Open', 'ReadWrite', 'ReadWrite').Dispose() } | Should -Throw
                { [System.IO.File]::Delete($path) } | Should -Throw
                { [System.IO.File]::Move($path, (Join-Path $TestDrive 'moved.msi')) } | Should -Throw
                { [System.IO.Directory]::Move($folder, (Join-Path $TestDrive 'wau-msi-moved')) } | Should -Throw
                # Reading, as msiexec does, still works.
                $reader = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
                $reader.Dispose()
            }
            finally {
                $stream.Dispose()
            }
            # Once closed, the cleanup can delete it.
            { Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction Stop } | Should -Not -Throw
        }
    }

    # Real icacls, Get-Acl and msiexec, on Windows only. The unit tests above mock all three; the
    # E2E run does not install WAU (its runner lacks Microsoft.WindowsAppRuntime.1.8), so these are
    # the only checks of the real calls before a PC runs them.
    Context 'Staging-folder lockdown and the held-open MSI on real Windows (review finding P2-21)' {
        # icacls /setowner needs an elevated administrator token.
        It 'leaves a real folder owned by Administrators with only SYSTEM and Administrators entries' -Skip:(-not ($IsWindows -and ([System.Security.Principal.WindowsPrincipal][System.Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator))) {
            $folder = Join-Path $TestDrive ('acl-' + [guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Path $folder

            { Set-RestrictedDirectoryAcl -Path $folder } | Should -Not -Throw

            $summary = Get-DirectoryAccessSummary -Path $folder
            $summary.OwnerSid | Should -Be 'S-1-5-32-544'
            $summary.InheritanceProtected | Should -BeTrue
            @($summary.AccessRules).Count | Should -BeGreaterThan 0
            @($summary.AccessRules | Where-Object { $_.Sid -notin @('S-1-5-18', 'S-1-5-32-544') }).Count | Should -Be 0
        }

        It 'fails on a real folder that keeps an explicit entry for another account, which /grant:r does not remove' -Skip:(-not ($IsWindows -and ([System.Security.Principal.WindowsPrincipal][System.Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator))) {
            $folder = Join-Path $TestDrive ('acl-' + [guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Path $folder
            $grant = Start-Process -FilePath 'icacls.exe' -ArgumentList "`"$folder`" /grant *S-1-5-32-545:(OI)(CI)M /q" -Wait -PassThru -WindowStyle Hidden
            $grant.ExitCode | Should -Be 0

            { Set-RestrictedDirectoryAcl -Path $folder } | Should -Throw '*(S-1-5-32-545) has an access entry (allow)*'
        }

        # msiexec opens the package for reading; a sharing violation would make every WAU install
        # fail with 1619 (ERROR_INSTALL_PACKAGE_OPEN_FAILED). A file that is not an MSI fails the
        # same way whether or not the installer holds it open, as long as msiexec can open it.
        It 'lets msiexec open the MSI while it is held open' -Skip:(-not $IsWindows) {
            $path = Join-Path $TestDrive 'not-an-msi.msi'
            [System.IO.File]::WriteAllBytes($path, [byte[]](1..64))
            $runMsiexec = {
                $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList "/i `"$path`" /qn" -PassThru -WindowStyle Hidden
                $null = $process.Handle
                if (-not $process.WaitForExit(120000)) {
                    $process.Kill()
                    throw 'msiexec did not exit within 2 minutes'
                }
                $process.ExitCode
            }

            $exitCodeUnheld = & $runMsiexec
            $stream = Open-ReadLockedFile -Path $path
            try {
                $exitCodeHeld = & $runMsiexec
            }
            finally {
                $stream.Dispose()
            }

            $exitCodeHeld | Should -Be $exitCodeUnheld
        }
    }

    Context 'Install-WingetAutoUpdate' {
        BeforeEach {
            # Framework present by default; the framework-gate tests below override it. Without
            # this mock the real query would run on the CI runner, which lacks the framework.
            Mock Get-WindowsAppRuntimeStatus { [pscustomobject]@{ Present = $true; Detail = 'X64 8000.921.1539.0' } }
            Mock Disable-WauLogonTrigger { $false }
            # The mocked downloads below write no file; the held-open MSI tests (next Context) use
            # the real Open-ReadLockedFile on a real file.
            Mock Open-ReadLockedFile { [System.IO.MemoryStream]::new() }
        }

        It 'downloads into the ACL-restricted staging directory, verifies the hash, and installs silently with the pinned config' {
            Mock Test-WauInstalled { $false }
            Mock New-WauStagingDirectory { Join-Path $TestDrive 'wau-msi-test' }
            Mock Invoke-WebRequest { }
            Mock Get-FileHash { @{ Hash = (Get-WauPin).Sha256 } }
            Mock Invoke-ExternalProcess { New-TestProcessResult -ExitCode 0 }
            Mock Remove-Item { }

            $result = Install-WingetAutoUpdate

            $result.Status | Should -Be 'Configured'
            $result.Version | Should -Be (Get-WauPin).Version
            Should -Invoke New-WauStagingDirectory -Times 1 -Exactly
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $OutFile -like '*wau-msi-test*' }
            Should -Invoke Invoke-ExternalProcess -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq 'msiexec.exe' -and
                # No RUN_WAU=YES: an immediate WAU run re-provisions App Installer while the
                # installer is still running (issues #279/#283/#284).
                $ArgumentString -notmatch 'RUN_WAU' -and $ArgumentString -match 'UPDATESATLOGON=0' -and $ArgumentString -match 'USERCONTEXT=1' -and
                $ArgumentString -match 'DISABLEWAUAUTOUPDATE=1' -and $ArgumentString -match 'UPDATESINTERVAL=Weekly' -and
                $ArgumentString -match 'NOTIFICATIONLEVEL=Full' -and
                # Time-limited (review finding P2-5): Start-Process -Wait used to wait for ever.
                $TimeoutSeconds -eq (Get-ProcessTimeoutSeconds -Operation MsiExec)
            }
            Should -Invoke Remove-Item -Times 1 -Exactly -ParameterFilter {
                $Path -eq (Join-Path $TestDrive 'wau-msi-test') -and $Recurse
            }
            # A fresh install gets UPDATESATLOGON=0 from the MSI; no task edit needed.
            Should -Invoke Disable-WauLogonTrigger -Times 0 -Exactly
        }

        It 'downloads the MSI with a time limit (review finding P2-5)' {
            Mock Test-WauInstalled { $false }
            Mock New-WauStagingDirectory { Join-Path $TestDrive 'wau-msi-test' }
            Mock Get-WebDownloadTimeoutParameters { @{ TimeoutSec = 7 } }
            Mock Invoke-WebRequest { }
            Mock Get-FileHash { @{ Hash = (Get-WauPin).Sha256 } }
            Mock Invoke-ExternalProcess { New-TestProcessResult -ExitCode 0 }
            Mock Remove-Item { }

            (Install-WingetAutoUpdate).Status | Should -Be 'Configured'

            # -TimeoutSec is an alias of -ConnectionTimeoutSeconds on PowerShell 7.4 and newer.
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { ($ConnectionTimeoutSeconds -eq 7) -or ($TimeoutSec -eq 7) }
        }

        It 'reports Failed, and cleans up, when msiexec runs past its time limit' {
            Mock Test-WauInstalled { $false }
            Mock New-WauStagingDirectory { Join-Path $TestDrive 'wau-msi-test' }
            Mock Invoke-WebRequest { }
            Mock Get-FileHash { @{ Hash = (Get-WauPin).Sha256 } }
            Mock Invoke-ExternalProcess { New-TestProcessResult -TimedOut }
            Mock Remove-Item { }

            $result = Install-WingetAutoUpdate

            $result.Status | Should -Be 'Failed'
            Should -Invoke Write-ErrorMessage -Times 1 -Exactly -ParameterFilter { $Message -match 'msiexec did not finish within 15 minutes' }
            Should -Invoke Remove-Item -Times 1 -Exactly -ParameterFilter { $Path -eq (Join-Path $TestDrive 'wau-msi-test') -and $Recurse }
        }

        It 'reports Failed when msiexec cannot be started' {
            Mock Test-WauInstalled { $false }
            Mock New-WauStagingDirectory { Join-Path $TestDrive 'wau-msi-test' }
            Mock Invoke-WebRequest { }
            Mock Get-FileHash { @{ Hash = (Get-WauPin).Sha256 } }
            Mock Invoke-ExternalProcess { New-TestProcessResult -LaunchFailed -LaunchErrorCode 2 -LaunchError 'The system cannot find the file specified.' }
            Mock Remove-Item { }

            (Install-WingetAutoUpdate).Status | Should -Be 'Failed'
            Should -Invoke Write-ErrorMessage -Times 1 -Exactly -ParameterFilter { $Message -match 'msiexec could not be started' }
        }

        It 'reports AlreadyPresent (with the installed version) when WAU is at the pinned version' {
            Mock Test-WauInstalled { $true }
            Mock Get-InstalledWauInfo { [pscustomobject]@{ Version = [version](Get-WauPin).Version; ProductCode = (Get-WauPin).ProductCode } }
            Mock Invoke-WebRequest { throw 'should not download when WAU is current' }
            Mock Invoke-ExternalProcess { throw 'should not run msiexec when WAU is current' }

            $result = Install-WingetAutoUpdate

            $result.Status | Should -Be 'AlreadyPresent'
            $result.Version | Should -Be ([version](Get-WauPin).Version)
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
            Should -Invoke Invoke-ExternalProcess -Times 0 -Exactly
            Should -Invoke Disable-WauLogonTrigger -Times 1 -Exactly
        }

        It 'upgrades in place when the installed version is older than the pin (issue #186)' {
            Mock Test-WauInstalled { $true }
            Mock Get-InstalledWauInfo { [pscustomobject]@{ Version = [version]'2.11.0'; ProductCode = '{11111111-2222-3333-4444-555555555555}' } }
            Mock New-WauStagingDirectory { Join-Path $TestDrive 'wau-msi-test' }
            Mock Invoke-WebRequest { }
            Mock Get-FileHash { @{ Hash = (Get-WauPin).Sha256 } }
            Mock Invoke-ExternalProcess { New-TestProcessResult -ExitCode 0 }
            Mock Remove-Item { }

            $result = Install-WingetAutoUpdate

            $result.Status | Should -Be 'Configured'
            Should -Invoke Invoke-ExternalProcess -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq 'msiexec.exe' -and $ArgumentString -match '/i'
            }
        }

        It 'does not downgrade when the installed version is newer than the pin' {
            Mock Test-WauInstalled { $true }
            Mock Get-InstalledWauInfo { [pscustomobject]@{ Version = [version]'99.0.0'; ProductCode = '{11111111-2222-3333-4444-555555555555}' } }
            Mock Invoke-WebRequest { throw 'should not download for a newer install' }
            Mock Invoke-ExternalProcess { throw 'should not run msiexec for a newer install' }

            $result = Install-WingetAutoUpdate

            $result.Status | Should -Be 'AlreadyPresent'
            $result.Version | Should -Be ([version]'99.0.0')
            Should -Invoke Invoke-ExternalProcess -Times 0 -Exactly
        }

        It 'leaves an installed WAU with an unreadable version untouched' {
            Mock Test-WauInstalled { $true }
            Mock Get-InstalledWauInfo { [pscustomobject]@{ Version = $null; ProductCode = $null } }
            Mock Invoke-WebRequest { throw 'should not download when the version is unknown' }
            Mock Invoke-ExternalProcess { throw 'should not run msiexec when the version is unknown' }

            $result = Install-WingetAutoUpdate

            $result.Status | Should -Be 'AlreadyPresent'
            $result.Version | Should -BeNullOrEmpty
            Should -Invoke Invoke-ExternalProcess -Times 0 -Exactly
            Should -Invoke Disable-WauLogonTrigger -Times 1 -Exactly
        }

        It 'aborts without installing when the MSI hash does not match, and still cleans the staging directory' {
            Mock Test-WauInstalled { $false }
            Mock New-WauStagingDirectory { Join-Path $TestDrive 'wau-msi-test' }
            Mock Invoke-WebRequest { }
            Mock Get-FileHash { @{ Hash = 'DEADBEEF' } }
            Mock Invoke-ExternalProcess { throw 'must not run msiexec on a hash mismatch' }
            Mock Remove-Item { }

            $result = Install-WingetAutoUpdate

            $result.Status | Should -Be 'Failed'
            Should -Invoke Invoke-ExternalProcess -Times 0 -Exactly
            Should -Invoke Remove-Item -Times 1 -Exactly -ParameterFilter {
                $Path -eq (Join-Path $TestDrive 'wau-msi-test') -and $Recurse
            }
        }

        It 'returns Failed without downloading when the staging directory cannot be secured' {
            Mock Test-WauInstalled { $false }
            Mock New-WauStagingDirectory { throw 'icacls failed to restrict' }
            Mock Invoke-WebRequest { throw 'should not download without a secured staging directory' }
            Mock Remove-Item { }

            $result = Install-WingetAutoUpdate

            $result.Status | Should -Be 'Failed'
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
            Should -Invoke Remove-Item -Times 0 -Exactly
        }

        # Review finding P2-21: the non-elevated first launch creates %ProgramData%\winget-app-setup
        # for its log, so the signed-in user owns it and could give themselves full control again
        # after the old inheritance-only lockdown. Real New-WauStagingDirectory and
        # Set-RestrictedDirectoryAcl here; only icacls and the access-list read are mocked.
        It 'does not download when the staging folder is still owned by the user who created it, and says how to reset it' {
            $savedProgramData = $env:ProgramData
            $env:ProgramData = Join-Path $TestDrive 'ProgramData'
            try {
                Mock Test-WauInstalled { $false }
                Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } } -ParameterFilter { $FilePath -eq 'icacls.exe' }
                Mock Get-DirectoryAccessSummary {
                    [pscustomobject]@{
                        OwnerSid             = 'S-1-5-21-1-2-3-1001'
                        OwnerName            = 'PC01\enduser'
                        InheritanceProtected = $true
                        AccessRules          = @([pscustomobject]@{ Sid = 'S-1-5-32-544'; Name = 'BUILTIN\Administrators'; AccessControlType = 'Allow'; IsInherited = $false })
                    }
                }
                Mock Invoke-WebRequest { throw 'must not download into a folder another account controls' }
                Mock Invoke-ExternalProcess { throw 'must not run msiexec' }
                $script:errors = @()
                Mock Write-ErrorMessage { $script:errors += $Message }

                $result = Install-WingetAutoUpdate

                $result.Status | Should -Be 'Failed'
                Should -Invoke Invoke-WebRequest -Times 0 -Exactly
                Should -Invoke Invoke-ExternalProcess -Times 0 -Exactly
                $baseDir = Join-Path $env:ProgramData 'winget-app-setup'
                $message = $script:errors -join "`n"
                $message | Should -BeLike '*Winget-AutoUpdate was NOT installed: its download folder could not be limited to SYSTEM and Administrators*'
                $message | Should -BeLike "*it is owned by PC01\enduser (S-1-5-21-1-2-3-1001)*"
                $message | Should -BeLike "*takeown /f `"$baseDir`" /a, then icacls `"$baseDir`" /reset*"
            }
            finally {
                $env:ProgramData = $savedProgramData
            }
        }

        # Review of item 17: taking ownership and resetting the access list fixes only an
        # access-list failure. For anything else that stops the folder being set up, that advice
        # and the 'could have been swapped' wording would send the teammate the wrong way.
        It 'reports a download folder that cannot be created without the ownership wording or the reset hint' {
            $savedProgramData = $env:ProgramData
            $env:ProgramData = Join-Path $TestDrive 'ProgramData'
            try {
                Mock Test-WauInstalled { $false }
                Mock New-Item { throw 'There is not enough space on the disk.' }
                Mock Start-Process { throw 'must not run icacls on a folder that was not created' } -ParameterFilter { $FilePath -eq 'icacls.exe' }
                Mock Invoke-WebRequest { throw 'must not download without a download folder' }
                $script:errors = @()
                Mock Write-ErrorMessage { $script:errors += $Message }

                $result = Install-WingetAutoUpdate

                $result.Status | Should -Be 'Failed'
                Should -Invoke Invoke-WebRequest -Times 0 -Exactly
                Should -Invoke Start-Process -Times 0 -Exactly -ParameterFilter { $FilePath -eq 'icacls.exe' }
                $baseDir = Join-Path $env:ProgramData 'winget-app-setup'
                $message = $script:errors -join "`n"
                $message | Should -Be "Winget-AutoUpdate was NOT installed: its download folder in '$baseDir' could not be set up: There is not enough space on the disk."
            }
            finally {
                $env:ProgramData = $savedProgramData
            }
        }

        It 'reports icacls.exe failing to start without the ownership wording or the reset hint' {
            $savedProgramData = $env:ProgramData
            $env:ProgramData = Join-Path $TestDrive 'ProgramData'
            try {
                Mock Test-WauInstalled { $false }
                Mock Start-Process { throw "An error occurred trying to start process 'icacls.exe'." } -ParameterFilter { $FilePath -eq 'icacls.exe' }
                Mock Invoke-WebRequest { throw 'must not download without a secured download folder' }
                $script:errors = @()
                Mock Write-ErrorMessage { $script:errors += $Message }

                $result = Install-WingetAutoUpdate

                $result.Status | Should -Be 'Failed'
                Should -Invoke Invoke-WebRequest -Times 0 -Exactly
                $message = $script:errors -join "`n"
                $message | Should -BeLike "*could not be set up: An error occurred trying to start process 'icacls.exe'.*"
                $message | Should -Not -BeLike '*takeown*'
                $message | Should -Not -BeLike '*limited to SYSTEM and Administrators*'
            }
            finally {
                $env:ProgramData = $savedProgramData
            }
        }

        It 'treats msiexec exit code 3010 (reboot required) as success, and says a restart finishes it (review finding P3-16)' {
            Mock Test-WauInstalled { $false }
            Mock New-WauStagingDirectory { Join-Path $TestDrive 'wau-msi-test' }
            Mock Invoke-WebRequest { }
            Mock Get-FileHash { @{ Hash = (Get-WauPin).Sha256 } }
            Mock Invoke-ExternalProcess { New-TestProcessResult -ExitCode 3010 }
            Mock Remove-Item { }

            $result = Install-WingetAutoUpdate

            $result.Status | Should -Be 'Configured'
            $result.RestartRequired | Should -BeTrue
        }

        It 'does not say a restart is needed after a plain msiexec success' {
            Mock Test-WauInstalled { $false }
            Mock New-WauStagingDirectory { Join-Path $TestDrive 'wau-msi-test' }
            Mock Invoke-WebRequest { }
            Mock Get-FileHash { @{ Hash = (Get-WauPin).Sha256 } }
            Mock Invoke-ExternalProcess { New-TestProcessResult -ExitCode 0 }
            Mock Remove-Item { }

            (Install-WingetAutoUpdate).RestartRequired | Should -BeFalse
        }

        # Review finding P2-15: msiexec returns 1618 at once while another installation holds
        # Windows Installer, which used to fail the WAU install ('Auto-updates: FAILED') on the spot.
        It 'waits for another installation to finish when msiexec returns 1618, then installs' {
            Mock Test-WauInstalled { $false }
            Mock New-WauStagingDirectory { Join-Path $TestDrive 'wau-msi-test' }
            Mock Invoke-WebRequest { }
            Mock Get-FileHash { @{ Hash = (Get-WauPin).Sha256 } }
            Mock Remove-Item { }
            $script:msiexecRuns = 0
            Mock Invoke-ExternalProcess {
                $script:msiexecRuns++
                if ($script:msiexecRuns -eq 1) {
                    return New-TestProcessResult -ExitCode 1618
                }
                New-TestProcessResult -ExitCode 0
            }
            Mock Wait-WindowsInstallerIdle { [pscustomobject]@{ WaitedSeconds = 45; Busy = $false } }

            $result = Install-WingetAutoUpdate -InstallInProgressWaitSeconds 300

            $result.Status | Should -Be 'Configured'
            $script:msiexecRuns | Should -Be 2
            Should -Invoke Wait-WindowsInstallerIdle -Times 1 -Exactly -ParameterFilter { $MaximumSeconds -eq 300 }
        }

        It 'fails with the reason when Windows Installer stays busy past the wait budget' {
            Mock Test-WauInstalled { $false }
            Mock New-WauStagingDirectory { Join-Path $TestDrive 'wau-msi-test' }
            Mock Invoke-WebRequest { }
            Mock Get-FileHash { @{ Hash = (Get-WauPin).Sha256 } }
            Mock Remove-Item { }
            Mock Invoke-ExternalProcess { New-TestProcessResult -ExitCode 1618 }
            Mock Wait-WindowsInstallerIdle { [pscustomobject]@{ WaitedSeconds = $MaximumSeconds; Busy = $true } }
            $script:errors = @()
            Mock Write-ErrorMessage { $script:errors += $Message }

            $result = Install-WingetAutoUpdate -InstallInProgressWaitSeconds 120

            $result.Status | Should -Be 'Failed'
            Should -Invoke Invoke-ExternalProcess -Times 2 -Exactly
            Should -Invoke Wait-WindowsInstallerIdle -Times 1 -Exactly
            ($script:errors -join "`n") | Should -Match 'Windows Installer was still busy with another installation after 1 retries and 120 seconds of waiting \(msiexec exit code 1618\)'
        }

        It 'does not install WAU when Microsoft.WindowsAppRuntime.1.8 is missing (it would leave winget unusable)' {
            Mock Get-WindowsAppRuntimeStatus { [pscustomobject]@{ Present = $false; Detail = 'none registered' } }
            Mock Test-WauInstalled { $false }
            Mock Invoke-WebRequest { throw 'should not download WAU without the framework' }
            Mock Invoke-ExternalProcess { throw 'should not run msiexec without the framework' }

            $result = Install-WingetAutoUpdate

            $result.Status | Should -Be 'FrameworkMissing'
            $result.FrameworkMissing | Should -BeTrue
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
            Should -Invoke Write-ErrorMessage -Times 1 -Exactly -ParameterFilter { $Message -match 'NOT installed: Microsoft\.WindowsAppRuntime\.1\.8 is missing' }
        }

        It 'still installs WAU when the framework check itself cannot run' {
            Mock Get-WindowsAppRuntimeStatus { [pscustomobject]@{ Present = $null; Detail = 'could not query installed packages: boom' } }
            Mock Test-WauInstalled { $false }
            Mock New-WauStagingDirectory { Join-Path $TestDrive 'wau-msi-unknown' }
            Mock Invoke-WebRequest { }
            Mock Get-FileHash { @{ Hash = (Get-WauPin).Sha256 } }
            Mock Invoke-ExternalProcess { New-TestProcessResult -ExitCode 0 }
            Mock Remove-Item { }

            $result = Install-WingetAutoUpdate

            $result.Status | Should -Be 'Configured'
            Should -Invoke Write-WarningMessage -Times 1 -Exactly -ParameterFilter { $Message -match 'Could not check for Microsoft\.WindowsAppRuntime\.1\.8' }
        }

        It 'removes the at-logon trigger from an already-installed WAU and reports a missing framework' {
            Mock Get-WindowsAppRuntimeStatus { [pscustomobject]@{ Present = $false; Detail = 'none registered' } }
            Mock Test-WauInstalled { $true }
            Mock Get-InstalledWauInfo { [pscustomobject]@{ Version = [version](Get-WauPin).Version; ProductCode = (Get-WauPin).ProductCode } }
            Mock Invoke-WebRequest { throw 'should not download when WAU is current' }

            $result = Install-WingetAutoUpdate

            $result.Status | Should -Be 'AlreadyPresent'
            $result.FrameworkMissing | Should -BeTrue
            Should -Invoke Disable-WauLogonTrigger -Times 1 -Exactly
            Should -Invoke Write-ErrorMessage -Times 1 -Exactly -ParameterFilter { $Message -match 'its next update run may install a winget that cannot start' }
        }

        It 'does not upgrade an older WAU on a machine without the framework' {
            Mock Get-WindowsAppRuntimeStatus { [pscustomobject]@{ Present = $false; Detail = 'none registered' } }
            Mock Test-WauInstalled { $true }
            Mock Get-InstalledWauInfo { [pscustomobject]@{ Version = [version]'2.11.0'; ProductCode = '{00000000-0000-0000-0000-000000000000}' } }
            Mock Invoke-WebRequest { throw 'should not upgrade WAU without the framework' }

            $result = Install-WingetAutoUpdate

            $result.Status | Should -Be 'AlreadyPresent'
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        }

        It 'previews leaving an existing WAU in place and removing its logon trigger under -WhatIf' {
            Mock Test-WauInstalled { $true }
            Mock Invoke-WebRequest { throw 'should not download under WhatIf' }
            $script:infos = @()
            Mock Write-Info { $script:infos += $Message }

            $result = Install-WingetAutoUpdate -WhatIf

            $result.Status | Should -Be 'DryRun'
            ($script:infos -join "`n") | Should -Match 'already installed: would leave it in place and remove its at-logon trigger'
            Should -Invoke Disable-WauLogonTrigger -Times 0 -Exactly
            Should -Invoke Get-WindowsAppRuntimeStatus -Times 0 -Exactly
        }

        It 'returns dry-run without side effects under -WhatIf' {
            Mock Test-WauInstalled { $false }
            Mock Invoke-WebRequest { throw 'should not download under WhatIf' }

            $result = Install-WingetAutoUpdate -WhatIf

            $result.Status | Should -Be 'DryRun'
            $result.Version | Should -Be (Get-WauPin).Version
        }
    }

    Context 'Install-WingetAutoUpdate holds the MSI open from the hash until msiexec has finished (review finding P2-21)' {
        BeforeEach {
            Mock Get-WindowsAppRuntimeStatus { [pscustomobject]@{ Present = $true; Detail = 'X64 8000.921.1539.0' } }
            Mock Disable-WauLogonTrigger { $false }
            Mock Test-WauInstalled { $false }
            $script:stagingDir = Join-Path $TestDrive ('wau-msi-' + [guid]::NewGuid().ToString('N'))
            Mock New-WauStagingDirectory { $null = New-Item -ItemType Directory -Path $script:stagingDir; $script:stagingDir }
            Mock Invoke-WebRequest { Set-Content -LiteralPath $OutFile -Value 'genuine WAU msi' }
            $script:hashedStream = $null
            Mock Get-FileHash { $script:hashedStream = $InputStream; @{ Hash = (Get-WauPin).Sha256 } }
            $script:streamOpenDuringMsiexec = $null
            $script:msiexecArguments = $null
            Mock Invoke-ExternalProcess {
                $script:streamOpenDuringMsiexec = ($null -ne $script:hashedStream) -and $script:hashedStream.CanRead
                $script:msiexecArguments = $ArgumentString
                New-TestProcessResult -ExitCode 0
            }
        }

        It 'hashes the downloaded MSI from an open read-only handle, keeps it open while msiexec runs, and closes it before the cleanup' {
            $result = Install-WingetAutoUpdate

            $result.Status | Should -Be 'Configured'
            $msiPath = Join-Path $script:stagingDir "WAU-$((Get-WauPin).Version).msi"
            # The hash comes from the open stream, not from a second open by path.
            Should -Invoke Get-FileHash -Times 1 -Exactly -ParameterFilter { $null -ne $InputStream -and -not $Path -and -not $LiteralPath }
            $script:hashedStream | Should -BeOfType [System.IO.FileStream]
            $script:hashedStream.Name | Should -Be $msiPath
            $script:streamOpenDuringMsiexec | Should -BeTrue
            $script:msiexecArguments | Should -BeLike "/i `"$msiPath`" *"
            # Closed afterwards, so the staging folder could be removed.
            $script:hashedStream.CanRead | Should -BeFalse
            Test-Path -LiteralPath $script:stagingDir | Should -BeFalse
        }

        It 'closes the MSI when the hash does not match, without running msiexec' {
            Mock Get-FileHash { $script:hashedStream = $InputStream; @{ Hash = 'DEADBEEF' } }

            (Install-WingetAutoUpdate).Status | Should -Be 'Failed'

            Should -Invoke Invoke-ExternalProcess -Times 0 -Exactly
            $script:hashedStream | Should -BeOfType [System.IO.FileStream]
            $script:hashedStream.CanRead | Should -BeFalse
            Test-Path -LiteralPath $script:stagingDir | Should -BeFalse
        }

        It 'closes the MSI when msiexec times out' {
            Mock Invoke-ExternalProcess {
                $script:streamOpenDuringMsiexec = $script:hashedStream.CanRead
                New-TestProcessResult -TimedOut
            }

            (Install-WingetAutoUpdate).Status | Should -Be 'Failed'

            $script:streamOpenDuringMsiexec | Should -BeTrue
            $script:hashedStream.CanRead | Should -BeFalse
            Test-Path -LiteralPath $script:stagingDir | Should -BeFalse
        }
    }

    Context 'Uninstall-WingetAutoUpdate' {
        It 'uninstalls via the ProductCode of the actually-installed WAU (issue #186)' {
            Mock Test-WauInstalled { $true }
            Mock Get-InstalledWauInfo { [pscustomobject]@{ Version = [version]'2.9.0'; ProductCode = '{11111111-2222-3333-4444-555555555555}' } }
            Mock Invoke-ExternalProcess { New-TestProcessResult -ExitCode 0 }

            $result = Uninstall-WingetAutoUpdate

            $result | Should -Be $true
            Should -Invoke Invoke-ExternalProcess -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq 'msiexec.exe' -and $ArgumentString -match '/x' -and
                $ArgumentString -match ([regex]::Escape('{11111111-2222-3333-4444-555555555555}')) -and
                $TimeoutSeconds -eq (Get-ProcessTimeoutSeconds -Operation MsiExec)
            }
        }

        It 'falls back to the pinned ProductCode when the registry lookup finds none' {
            Mock Test-WauInstalled { $true }
            Mock Get-InstalledWauInfo { [pscustomobject]@{ Version = $null; ProductCode = $null } }
            Mock Invoke-ExternalProcess { New-TestProcessResult -ExitCode 0 }

            $result = Uninstall-WingetAutoUpdate

            $result | Should -Be $true
            Should -Invoke Invoke-ExternalProcess -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq 'msiexec.exe' -and $ArgumentString -match '/x' -and
                $ArgumentString -match ([regex]::Escape((Get-WauPin).ProductCode))
            }
        }

        It 'returns false when msiexec runs past its time limit (review finding P2-5)' {
            Mock Test-WauInstalled { $true }
            Mock Get-InstalledWauInfo { [pscustomobject]@{ Version = [version]'2.9.0'; ProductCode = '{11111111-2222-3333-4444-555555555555}' } }
            Mock Invoke-ExternalProcess { New-TestProcessResult -TimedOut }

            Uninstall-WingetAutoUpdate | Should -Be $false
            Should -Invoke Write-ErrorMessage -Times 1 -Exactly -ParameterFilter { $Message -match 'did not finish in time' }
        }

        It 'is a no-op when WAU is not installed' {
            Mock Test-WauInstalled { $false }
            Mock Invoke-ExternalProcess { throw 'should not run msiexec when WAU is absent' }

            (Uninstall-WingetAutoUpdate) | Should -Be $true
            Should -Invoke Invoke-ExternalProcess -Times 0 -Exactly
        }
    }

    Context 'Invoke-WingetInstall surfaces the WAU outcome (issue #186)' {
        It 'captures the Install-WingetAutoUpdate result and prints an Auto-updates summary line' {
            $installBody = (Get-Command Invoke-WingetInstall).Definition
            $installBody | Should -Match '\$wauResult\s*=\s*Install-WingetAutoUpdate'
            $installBody | Should -Not -Match '\[void\]\(Install-WingetAutoUpdate'
            $installBody | Should -Match 'Auto-updates: Configured'
            $installBody | Should -Match 'Auto-updates: Already present'
            $installBody | Should -Match 'Auto-updates: FAILED'
            $installBody | Should -Match 'Auto-updates: NOT CONFIGURED'
            $installBody | Should -Match 'Auto-updates: AT RISK'
        }
    }

    Context 'Remove-LegacyScheduledUpdates' {
        It 'unregisters the legacy task and removes the data directory when present' {
            Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = 'WingetAppSetup-ScheduledUpdates' } }
            Mock Unregister-ScheduledTask { }
            Mock Test-Path { $true }
            Mock Remove-Item { }

            $result = Remove-LegacyScheduledUpdates

            $result | Should -Be $true
            Should -Invoke Unregister-ScheduledTask -Times 1 -Exactly -ParameterFilter { $TaskName -eq 'WingetAppSetup-ScheduledUpdates' }
            Should -Invoke Remove-Item -Times 1 -Exactly
        }

        It 'is a no-op when there is nothing to clean up' {
            Mock Get-ScheduledTask { throw 'task not found' }
            Mock Test-Path { $false }
            Mock Unregister-ScheduledTask { throw 'should not unregister' }
            Mock Remove-Item { throw 'should not remove' }

            (Remove-LegacyScheduledUpdates) | Should -Be $false
            Should -Invoke Unregister-ScheduledTask -Times 0 -Exactly
        }
    }
}

Describe 'WindowsAppRuntime framework gate for Winget-AutoUpdate (issues #279/#284)' {
    BeforeAll {
        $script:osArch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        $script:otherArch = if ($script:osArch -eq 'X64') { 'Arm64' } else { 'X64' }
    }

    Context 'Get-WindowsAppRuntimeStatus' {
        It 'is satisfied by a framework for this OS architecture at or above 8000.616.304.0' {
            Mock Get-WindowsAppRuntimePackageInfo { [pscustomobject]@{ Version = [version]'8000.921.1539.0'; Architecture = $script:osArch } }

            (Get-WindowsAppRuntimeStatus).Present | Should -BeTrue
        }

        It 'is not satisfied by an older framework only' {
            Mock Get-WindowsAppRuntimePackageInfo { [pscustomobject]@{ Version = [version]'8000.500.0.0'; Architecture = $script:osArch } }

            (Get-WindowsAppRuntimeStatus).Present | Should -BeFalse
        }

        It 'is not satisfied by a framework for another architecture only' {
            Mock Get-WindowsAppRuntimePackageInfo { [pscustomobject]@{ Version = [version]'8000.921.1539.0'; Architecture = $script:otherArch } }

            (Get-WindowsAppRuntimeStatus).Present | Should -BeFalse
        }

        It 'reports none registered when no framework package exists' {
            Mock Get-WindowsAppRuntimePackageInfo { }

            $status = Get-WindowsAppRuntimeStatus
            $status.Present | Should -BeFalse
            $status.Detail | Should -Match 'none registered'
        }

        It 'returns an unknown result ($null), not "missing", when the query fails' {
            Mock Get-WindowsAppRuntimePackageInfo { throw 'Appx module unavailable' }

            $status = Get-WindowsAppRuntimeStatus
            $status.Present | Should -BeNullOrEmpty
            $status.Detail | Should -Match 'Appx module unavailable'
        }
    }

    Context 'Get-WindowsAppRuntimePackageInfo' {
        It 'parses Version|Architecture lines from the Windows PowerShell query and skips anything else' -Skip:($PSVersionTable.PSEdition -ne 'Core') {
            Mock powershell.exe { $global:LASTEXITCODE = 0; '8000.921.1539.0|X64'; 'WARNING: noise'; '' }

            $packages = @(Get-WindowsAppRuntimePackageInfo)

            $packages.Count | Should -Be 1
            $packages[0].Version | Should -Be ([version]'8000.921.1539.0')
            $packages[0].Architecture | Should -Be 'X64'
        }

        It 'throws when the Windows PowerShell query fails' -Skip:($PSVersionTable.PSEdition -ne 'Core') {
            Mock powershell.exe { $global:LASTEXITCODE = 1 }

            { Get-WindowsAppRuntimePackageInfo } | Should -Throw '*Get-AppxPackage -AllUsers failed*'
        }
    }
}

Describe 'Disable-WauLogonTrigger' {
    BeforeAll {
        function New-FakeTrigger {
            param ([string]$ClassName)
            [pscustomobject]@{ CimClass = [pscustomobject]@{ CimClassName = $ClassName } }
        }
    }

    BeforeEach {
        Mock Write-Info { }
        Mock Write-WarningMessage { }
        Mock Test-Path { $false }
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -eq 'HKLM:\SOFTWARE\Romanitho\Winget-AutoUpdate' }
        Mock Set-ItemProperty { }
        # -RemoveParameterType: on Windows the real Set-ScheduledTask types -Trigger as
        # CimInstance[], which would reject these fake triggers before the mock body runs.
        Mock Set-ScheduledTask { } -RemoveParameterType Trigger
    }

    It 'removes the logon trigger, keeps the weekly one, and records WAU_UpdatesAtLogon = 0' {
        Mock Get-ScheduledTask { [pscustomobject]@{ Triggers = @((New-FakeTrigger 'MSFT_TaskLogonTrigger'), (New-FakeTrigger 'MSFT_TaskWeeklyTrigger')) } }

        Disable-WauLogonTrigger | Should -BeTrue

        Should -Invoke Set-ScheduledTask -Times 1 -Exactly -ParameterFilter {
            @($Trigger).Count -eq 1 -and @($Trigger)[0].CimClass.CimClassName -eq 'MSFT_TaskWeeklyTrigger'
        }
        Should -Invoke Set-ItemProperty -Times 1 -Exactly -ParameterFilter { $Name -eq 'WAU_UpdatesAtLogon' -and $Value -eq 0 }
    }

    It 'leaves a task alone when the logon trigger is its only trigger (WAU would otherwise never run)' {
        Mock Get-ScheduledTask { [pscustomobject]@{ Triggers = @((New-FakeTrigger 'MSFT_TaskLogonTrigger')) } }

        Disable-WauLogonTrigger | Should -BeFalse

        Should -Invoke Set-ScheduledTask -Times 0 -Exactly
    }

    It 'does nothing to the task when it has no logon trigger' {
        Mock Get-ScheduledTask { [pscustomobject]@{ Triggers = @((New-FakeTrigger 'MSFT_TaskWeeklyTrigger')) } }

        Disable-WauLogonTrigger | Should -BeFalse

        Should -Invoke Set-ScheduledTask -Times 0 -Exactly
    }

    It 'warns instead of throwing when the task cannot be changed' {
        Mock Get-ScheduledTask { [pscustomobject]@{ Triggers = @((New-FakeTrigger 'MSFT_TaskLogonTrigger'), (New-FakeTrigger 'MSFT_TaskWeeklyTrigger')) } }
        Mock Set-ScheduledTask { throw 'Access is denied.' } -RemoveParameterType Trigger

        { Disable-WauLogonTrigger } | Should -Not -Throw

        Should -Invoke Write-WarningMessage -Times 1 -Exactly -ParameterFilter { $Message -match 'Could not remove the Winget-AutoUpdate at-logon trigger: Access is denied' }
    }
}

Describe 'Wait-WauIdle' {
    BeforeEach {
        Mock Write-Info { }
        Mock Write-Success { }
        Mock Write-WarningMessage { }
        Mock Start-Sleep { }
    }

    It 'returns immediately when no WAU task is running' {
        Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = 'Winget-AutoUpdate'; State = 'Ready' } }

        Wait-WauIdle | Should -BeTrue

        Should -Invoke Start-Sleep -Times 0 -Exactly
        Should -Invoke Write-Info -Times 0 -Exactly
    }

    It 'returns immediately when WAU is not installed' {
        Mock Get-ScheduledTask { }

        Wait-WauIdle | Should -BeTrue
    }

    It 'waits while a WAU task is running and continues once it finishes' {
        $script:polls = 0
        Mock Get-ScheduledTask {
            $script:polls++
            $state = if ($script:polls -lt 3) { 'Running' } else { 'Ready' }
            [pscustomobject]@{ TaskName = 'Winget-AutoUpdate'; State = $state }
        }

        Wait-WauIdle -PollIntervalSeconds 1 | Should -BeTrue

        Should -Invoke Start-Sleep -Times 2 -Exactly
        Should -Invoke Write-Info -Times 1 -Exactly -ParameterFilter { $Message -match 'Winget-AutoUpdate is running \(Winget-AutoUpdate\)' }
        Should -Invoke Write-Success -Times 1 -Exactly
    }

    It 'gives up with a warning at the time limit' {
        Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = 'Winget-AutoUpdate'; State = 'Running' } }

        Wait-WauIdle -TimeoutSeconds 0 -PollIntervalSeconds 1 | Should -BeFalse

        Should -Invoke Write-WarningMessage -Times 1 -Exactly -ParameterFilter { $Message -match 'still running' }
    }
}
