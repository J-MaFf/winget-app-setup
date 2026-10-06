# WingetAutoUpdate.Tests.ps1
# Tests for WingetAppSetup/Public/WingetAutoUpdate.ps1 and Private/WauSupport.ps1:
# the pinned Winget-AutoUpdate install/upgrade/uninstall flow and its staging helpers.
# Split from the old single-file suite Test-WingetAppInstall.Tests.ps1 (issue #192).

# Load the module's functions once for this file. TestHelpers.ps1 resolves the repo paths
# and dot-sources WingetAppSetup/Private + Public (the single source of truth; the
# distributable winget-app-install.ps1 is generated from it by build/Build-WingetInstallScript.ps1).
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    # A Get-WauTaskHealth result (review finding P3-36): a task ready to run, or with -Problem one
    # that will not run.
    function New-TestWauTaskHealth {
        param ([string]$Problem)
        [pscustomobject]@{
            Healthy        = -not $Problem
            Exists         = $Problem -notmatch 'does not exist|could not be checked'
            CheckFailed    = $Problem -match 'could not be checked'
            State          = 'Ready'
            Triggers       = @('Weekly on Tuesday from 2026-10-06T02:00:00')
            LastRunTime    = $null
            LastTaskResult = 267011
            NextRunTime    = [datetime]'2026-10-06T02:00:00'
            Problem        = $(if ($Problem) { $Problem } else { $null })
        }
    }

    # A trigger as Get-ScheduledTask returns it, with the properties the code reads.
    function New-TestTaskTrigger {
        param (
            [string]$ClassName = 'MSFT_TaskWeeklyTrigger',
            $DaysOfWeek = $null,
            [string]$StartBoundary = $null,
            $Enabled = $true
        )
        [pscustomobject]@{ CimClass = [pscustomobject]@{ CimClassName = $ClassName }; DaysOfWeek = $DaysOfWeek; StartBoundary = $StartBoundary; Enabled = $Enabled }
    }

    # Runs a script block under a transcript and returns the transcript's text (review finding
    # P3-38: a caught -ErrorAction Stop error is still written there as 'PS>TerminatingError').
    function Get-TranscriptText {
        param ([Parameter(Mandatory = $true)][scriptblock]$ScriptBlock)
        $path = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '-transcript.txt')
        $null = Start-Transcript -Path $path
        try {
            $null = & $ScriptBlock
        }
        finally {
            $null = Stop-Transcript
        }
        return [string](Get-Content -Raw -LiteralPath $path)
    }
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

        It 'creates a unique directory under ProgramData\winget-app-setup once the base folder is made safe, and restricts its ACL' {
            $baseDir = Join-Path $env:ProgramData 'winget-app-setup'
            Mock Initialize-ProgramDataFolder { $baseDir }
            Mock New-Item { }
            Mock Set-RestrictedDirectoryAcl { }

            $dir = New-WauStagingDirectory

            $dir | Should -BeLike (Join-Path $baseDir 'wau-msi-*')
            # The base folder: a planted link removed and the folder locked (wgt-gq8.46).
            Should -Invoke Initialize-ProgramDataFolder -Times 1 -Exactly -ParameterFilter { -not $ChildName -and -not $ReadableByUsers }
            Should -Invoke New-Item -Times 1 -Exactly -ParameterFilter { $Path -eq $dir }
            Should -Invoke Set-RestrictedDirectoryAcl -Times 1 -Exactly -ParameterFilter { $Path -eq $dir }
        }

        It 'generates a different staging directory name on every run' {
            Mock Initialize-ProgramDataFolder { Join-Path $env:ProgramData 'winget-app-setup' }
            Mock New-Item { }
            Mock Set-RestrictedDirectoryAcl { }

            (New-WauStagingDirectory) | Should -Not -Be (New-WauStagingDirectory)
        }

        # wgt-gq8.46: a standard user can create %ProgramData%\winget-app-setup as a junction before the
        # first elevated run; icacls follows it by default, and the staged downloads would land in its
        # target. A junction on Windows (no privilege needed), a symbolic link elsewhere.
        It 'removes a link planted as the base folder instead of locking or staging through it, and leaves its target alone' {
            $savedProgramData = $env:ProgramData
            $env:ProgramData = Join-Path $TestDrive ('ProgramData-' + [guid]::NewGuid().ToString('N'))
            try {
                [void](New-Item -ItemType Directory -Path $env:ProgramData)
                $baseDir = Join-Path $env:ProgramData 'winget-app-setup'
                $victim = Join-Path $TestDrive ('victim-' + [guid]::NewGuid().ToString('N'))
                [void](New-Item -ItemType Directory -Path $victim)
                Set-Content -LiteralPath (Join-Path $victim 'keep.txt') -Value 'not the installer''s'
                $victimSddl = $null
                $linkType = 'SymbolicLink'
                if ($IsWindows) {
                    $linkType = 'Junction'
                    $victimSddl = (Get-Acl -LiteralPath $victim).Sddl
                }
                [void](New-Item -ItemType $linkType -Path $baseDir -Target $victim)
                $script:lockedLinks = @()
                $script:lockedPaths = @()
                Mock Set-RestrictedDirectoryAcl {
                    $script:lockedPaths += $Path
                    $item = Get-Item -LiteralPath $Path -Force
                    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                        $script:lockedLinks += $Path
                    }
                }
                Mock New-RestrictedDirectory { [void](New-Item -ItemType Directory -Path $Path) }
                Mock Write-WarningMessage { }

                $dir = New-WauStagingDirectory

                $script:lockedLinks | Should -BeNullOrEmpty
                $script:lockedPaths | Should -Be @($baseDir, $dir)
                ((Get-Item -LiteralPath $baseDir -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) | Should -Be 0
                Split-Path -Parent $dir | Should -Be $baseDir
                Test-Path -LiteralPath $dir -PathType Container | Should -BeTrue
                @(Get-ChildItem -LiteralPath $victim -Force | ForEach-Object { $_.Name }) | Should -Be @('keep.txt')
                if ($IsWindows) {
                    (Get-Acl -LiteralPath $victim).Sddl | Should -Be $victimSddl
                }
                Should -Invoke Write-WarningMessage -Times 1 -Exactly -ParameterFilter { $Message -like "'$baseDir' was a link (a junction or symbolic link), not a folder.*" }
            }
            finally {
                $env:ProgramData = $savedProgramData
            }
        }

        It 'makes Administrators the owner first, then removes inherited entries and replaces the SYSTEM and Administrators grants (review finding P2-21)' {
            $script:icaclsCalls = @()
            Mock Start-Process { $script:icaclsCalls += $ArgumentList; [pscustomobject]@{ ExitCode = 0 } } -ParameterFilter { $FilePath -eq 'icacls.exe' }
            Mock Assert-RestrictedDirectoryAcl { }

            Set-RestrictedDirectoryAcl -Path 'C:\ProgramData\winget-app-setup\wau-msi-test'

            $script:icaclsCalls.Count | Should -Be 2
            # The installer's non-elevated first launch creates the folder, owned by the signed-in
            # user, and an owner can always rewrite the access list: ownership has to change first.
            # /L: a folder swapped for a link has the link changed, never its target (wgt-gq8.46).
            $script:icaclsCalls[0] | Should -Be '"C:\ProgramData\winget-app-setup\wau-msi-test" /setowner *S-1-5-32-544 /L /q'
            # /grant:r replaces explicit SYSTEM and Administrators entries instead of adding to them.
            $script:icaclsCalls[1] | Should -Be '"C:\ProgramData\winget-app-setup\wau-msi-test" /inheritance:r /grant:r *S-1-5-18:(OI)(CI)F *S-1-5-32-544:(OI)(CI)F /L /q'
            Should -Invoke Assert-RestrictedDirectoryAcl -Times 1 -Exactly -ParameterFilter { $Path -eq 'C:\ProgramData\winget-app-setup\wau-msi-test' -and -not $ReadableByUsers }
        }

        It 'lets BUILTIN\Users read the folder with -ReadableByUsers, by SID, in the same /grant:r (the logs folder, review finding P3-14)' {
            $script:icaclsCalls = @()
            Mock Start-Process { $script:icaclsCalls += $ArgumentList; [pscustomobject]@{ ExitCode = 0 } } -ParameterFilter { $FilePath -eq 'icacls.exe' }
            Mock Assert-RestrictedDirectoryAcl { }

            Set-RestrictedDirectoryAcl -Path 'C:\ProgramData\winget-app-setup\logs' -ReadableByUsers

            $script:icaclsCalls[1] | Should -Be '"C:\ProgramData\winget-app-setup\logs" /inheritance:r /grant:r *S-1-5-18:(OI)(CI)F *S-1-5-32-544:(OI)(CI)F *S-1-5-32-545:(OI)(CI)RX /L /q'
            Should -Invoke Assert-RestrictedDirectoryAcl -Times 1 -Exactly -ParameterFilter { $ReadableByUsers }
        }

        # wgt-gq8.46: icacls follows a junction by default, so a planted one would have the owner and
        # access list of its target rewritten (System32, another user's profile).
        It 'refuses a link before icacls runs, with the error id DirectoryIsLink' {
            $victim = Join-Path $TestDrive ('victim-' + [guid]::NewGuid().ToString('N'))
            [void](New-Item -ItemType Directory -Path $victim)
            $link = Join-Path $TestDrive ('link-' + [guid]::NewGuid().ToString('N'))
            $linkType = 'SymbolicLink'
            if ($IsWindows) {
                $linkType = 'Junction'
            }
            [void](New-Item -ItemType $linkType -Path $link -Target $victim)
            Mock Start-Process { throw 'icacls must not run on a link' } -ParameterFilter { $FilePath -eq 'icacls.exe' }

            { Set-RestrictedDirectoryAcl -Path $link } | Should -Throw -ErrorId 'DirectoryIsLink' -ExpectedMessage "'$link' is a link (a junction or symbolic link), not a folder, so its access list was not changed."

            Should -Invoke Start-Process -Times 0 -Exactly -ParameterFilter { $FilePath -eq 'icacls.exe' }
        }

        It 'refuses a folder that became a link while icacls ran, with the error id DirectoryIsLink rather than the reset advice, even when the check of the result failed' {
            $victim = Join-Path $TestDrive ('victim-' + [guid]::NewGuid().ToString('N'))
            [void](New-Item -ItemType Directory -Path $victim)
            $folder = Join-Path $TestDrive ('swapped-' + [guid]::NewGuid().ToString('N'))
            [void](New-Item -ItemType Directory -Path $folder)
            $script:linkTarget = $victim
            # The first icacls call swaps the folder for a link, as a racing user would.
            Mock Start-Process {
                $path = ($ArgumentList -split '"')[1]
                if (-not ((Get-Item -LiteralPath $path -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                    Remove-Item -LiteralPath $path -Force
                    $linkType = 'SymbolicLink'
                    if ($IsWindows) {
                        $linkType = 'Junction'
                    }
                    [void](New-Item -ItemType $linkType -Path $path -Target $script:linkTarget)
                }
                [pscustomobject]@{ ExitCode = 0 }
            } -ParameterFilter { $FilePath -eq 'icacls.exe' }
            Mock Assert-RestrictedDirectoryAcl { throw "'$Path' is not limited to SYSTEM and Administrators: it is owned by PC01\enduser (S-1-5-21-1-2-3-1001)." }

            { Set-RestrictedDirectoryAcl -Path $folder } | Should -Throw -ErrorId 'DirectoryIsLink' -ExpectedMessage "'$folder' was replaced by a link (a junction or symbolic link) while its access list was being set, so it is not used."
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
                param ([string]$Sid, [string]$Name = $Sid, [string]$Type = 'Allow', [switch]$Inherited, [long]$Rights = 0x1F01FF)
                [pscustomobject]@{ Sid = $Sid; Name = $Name; AccessControlType = $Type; IsInherited = [bool]$Inherited; Rights = $Rights }
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

        # The logs folder (review finding P3-14, wgt-gq8.46): read and execute (0x1200A9) only.
        It 'accepts a read-only BUILTIN\Users entry with -ReadableByUsers, and only then' {
            Mock Get-DirectoryAccessSummary { New-TestAccessSummary -ExtraRules @(New-TestAccessRule -Sid 'S-1-5-32-545' -Name 'BUILTIN\Users' -Rights 0x1200A9) }

            { Assert-RestrictedDirectoryAcl -Path 'C:\ProgramData\winget-app-setup\logs' -ReadableByUsers } | Should -Not -Throw
            { Assert-RestrictedDirectoryAcl -Path 'C:\ProgramData\winget-app-setup\logs' } | Should -Throw '*BUILTIN\Users (S-1-5-32-545) has an access entry (allow)*'
        }

        It 'rejects a BUILTIN\Users entry that lets them change the folder (<Name>), even with -ReadableByUsers' -ForEach @(
            @{ Name = 'add a file'; Rights = 0x1200AB }
            @{ Name = 'add a folder'; Rights = 0x1200AD }
            @{ Name = 'write attributes, which turns an empty folder into a junction'; Rights = 0x1201A9 }
            @{ Name = 'delete what is in it'; Rights = 0x1200E9 }
            @{ Name = 'modify'; Rights = 0x1301BF }
            @{ Name = 'generic write'; Rights = 0x40000000 }
        ) {
            Mock Get-DirectoryAccessSummary { New-TestAccessSummary -ExtraRules @(New-TestAccessRule -Sid 'S-1-5-32-545' -Name 'BUILTIN\Users' -Rights $Rights) }

            { Assert-RestrictedDirectoryAcl -Path 'C:\ProgramData\winget-app-setup\logs' -ReadableByUsers } | Should -Throw '*BUILTIN\Users (S-1-5-32-545) has an access entry (allow)*'
        }

        It 'rejects another account''s read-only entry and a BUILTIN\Users deny entry with -ReadableByUsers' {
            Mock Get-DirectoryAccessSummary {
                New-TestAccessSummary -ExtraRules @(
                    (New-TestAccessRule -Sid 'S-1-5-21-1-2-3-1001' -Name 'PC01\enduser' -Rights 0x1200A9),
                    (New-TestAccessRule -Sid 'S-1-5-32-545' -Name 'BUILTIN\Users' -Type 'Deny' -Rights 0x1200A9)
                )
            }

            { Assert-RestrictedDirectoryAcl -Path 'C:\ProgramData\winget-app-setup\logs' -ReadableByUsers } |
                Should -Throw '*PC01\enduser (S-1-5-21-1-2-3-1001) has an access entry (allow); BUILTIN\Users (S-1-5-32-545) has an access entry (deny)*'
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

    # Real icacls, Get-Acl and msiexec, on Windows only. The unit tests above mock all three. The
    # E2E run now installs WAU too (the installer installs Microsoft.WindowsAppRuntime.1.8, which
    # its runner lacks, first: work-order item 31), but these check the calls on their own, before
    # a PC runs them.
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
            # What the latest winget release needs (work-order item 32) is read from GitHub; here it
            # is the built-in requirement, and nothing is downloaded for it.
            Mock Get-WindowsAppRuntimeRequirement { Get-DefaultWindowsAppRuntimeRequirement }
            # Installing the framework (work-order item 31) has its own Describe below. Here it
            # fails by default, so the framework-missing tests keep their WAU skip and nothing is
            # downloaded or provisioned on the machine running the tests.
            Mock Install-WindowsAppRuntimeFramework { [pscustomobject]@{ Installed = $false; Status = $null; Reason = 'the test does not install it' } }
            Mock Disable-WauLogonTrigger { $false }
            # The mocked downloads below write no file; the held-open MSI tests (next Context) use
            # the real Open-ReadLockedFile on a real file.
            Mock Open-ReadLockedFile { [System.IO.MemoryStream]::new() }
            # The WAU task is ready to run by default (review finding P3-36); its log output and the
            # msiexec log (P3-37) never touch the machine.
            Mock Get-WauTaskHealth { New-TestWauTaskHealth }
            Mock Write-WauTaskHealth { }
            Mock New-WauMsiLogPath { Join-Path $TestDrive "wau-msi-$Action-$Attempt.log" }
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
                Mock New-RestrictedDirectory { [void](New-Item -ItemType Directory -Path $Path) }
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
            # A folder of its own: an earlier test's base folder would already be there.
            $env:ProgramData = Join-Path $TestDrive ('ProgramData-' + [guid]::NewGuid().ToString('N'))
            try {
                Mock Test-WauInstalled { $false }
                Mock New-Item { throw 'There is not enough space on the disk.' }
                Mock New-RestrictedDirectory { throw 'There is not enough space on the disk.' }
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
                Mock New-RestrictedDirectory { [void](New-Item -ItemType Directory -Path $Path) }
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

        # wgt-gq8.46: takeown and icacls /reset, the advice for an access-list failure, would follow
        # the link and change what it points to.
        It 'does not download when a link planted as the base folder cannot be removed, and gives no reset advice' {
            $savedProgramData = $env:ProgramData
            $env:ProgramData = Join-Path $TestDrive ('ProgramData-' + [guid]::NewGuid().ToString('N'))
            try {
                [void](New-Item -ItemType Directory -Path $env:ProgramData)
                $victim = Join-Path $TestDrive ('victim-' + [guid]::NewGuid().ToString('N'))
                [void](New-Item -ItemType Directory -Path $victim)
                $baseDir = Join-Path $env:ProgramData 'winget-app-setup'
                $linkType = 'SymbolicLink'
                if ($IsWindows) {
                    $linkType = 'Junction'
                }
                [void](New-Item -ItemType $linkType -Path $baseDir -Target $victim)
                Mock Test-WauInstalled { $false }
                Mock Remove-FileSystemLink { throw 'Access is denied.' }
                Mock Start-Process { throw 'must not run icacls on a link' } -ParameterFilter { $FilePath -eq 'icacls.exe' }
                Mock Invoke-WebRequest { throw 'must not download through a link' }
                $script:errors = @()
                Mock Write-ErrorMessage { $script:errors += $Message }

                $result = Install-WingetAutoUpdate

                $result.Status | Should -Be 'Failed'
                Should -Invoke Invoke-WebRequest -Times 0 -Exactly
                Should -Invoke Start-Process -Times 0 -Exactly -ParameterFilter { $FilePath -eq 'icacls.exe' }
                @(Get-ChildItem -LiteralPath $victim -Force) | Should -BeNullOrEmpty
                $message = $script:errors -join "`n"
                $message | Should -BeLike "Winget-AutoUpdate was NOT installed: its download folder in '$baseDir' could not be set up: '$baseDir' is a link (a junction or symbolic link), not a folder, and the link could not be removed: Access is denied.*"
                $message | Should -Not -BeLike '*takeown*'
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

        # Work-order item 31 (R13-3): a fresh PC lacks the framework until something installs it,
        # so the run used to end with 'Auto-updates: NOT CONFIGURED' and exit 8.
        It 'installs the pinned framework first when it is missing, then installs WAU (work-order item 31)' {
            Mock Get-WindowsAppRuntimeStatus { [pscustomobject]@{ Present = $false; Detail = 'none registered' } }
            $script:callOrder = [System.Collections.Generic.List[string]]::new()
            Mock Install-WindowsAppRuntimeFramework {
                $script:callOrder.Add('framework')
                [pscustomobject]@{ Installed = $true; Status = [pscustomobject]@{ Present = $true; Detail = 'X64 8000.994.2142.0' }; Reason = $null }
            }
            Mock Test-WauInstalled { $false }
            Mock New-WauStagingDirectory { Join-Path $TestDrive 'wau-msi-test' }
            Mock Invoke-WebRequest { $script:callOrder.Add('wau download') }
            Mock Get-FileHash { @{ Hash = (Get-WauPin).Sha256 } }
            Mock Invoke-ExternalProcess { $script:callOrder.Add('msiexec'); New-TestProcessResult -ExitCode 0 }
            Mock Remove-Item { }

            $result = Install-WingetAutoUpdate

            $result.Status | Should -Be 'Configured'
            $result.FrameworkMissing | Should -BeFalse
            @($script:callOrder) | Should -Be @('framework', 'wau download', 'msiexec')
            Should -Invoke Install-WindowsAppRuntimeFramework -Times 1 -Exactly
            Should -Invoke Write-ErrorMessage -Times 0 -Exactly
        }

        It 'no longer reports an already-installed WAU at risk once the framework is installed' {
            Mock Get-WindowsAppRuntimeStatus { [pscustomobject]@{ Present = $false; Detail = 'none registered' } }
            Mock Install-WindowsAppRuntimeFramework { [pscustomobject]@{ Installed = $true; Status = [pscustomobject]@{ Present = $true; Detail = 'X64 8000.994.2142.0' }; Reason = $null } }
            Mock Test-WauInstalled { $true }
            Mock Get-InstalledWauInfo { [pscustomobject]@{ Version = [version](Get-WauPin).Version; ProductCode = (Get-WauPin).ProductCode } }
            Mock Invoke-ExternalProcess { throw 'should not run msiexec for a current WAU' }

            $result = Install-WingetAutoUpdate

            $result.Status | Should -Be 'AlreadyPresent'
            $result.FrameworkMissing | Should -BeFalse
            Should -Invoke Write-ErrorMessage -Times 0 -Exactly
        }

        It 'skips WAU and says why when the framework cannot be installed' {
            Mock Get-WindowsAppRuntimeStatus { [pscustomobject]@{ Present = $false; Detail = 'none registered' } }
            Mock Install-WindowsAppRuntimeFramework { [pscustomobject]@{ Installed = $false; Status = $null; Reason = 'Add-AppxProvisionedPackage failed (its error is above)' } }
            Mock Test-WauInstalled { $false }
            Mock Invoke-WebRequest { throw 'should not download WAU without the framework' }
            $script:errors = @()
            Mock Write-ErrorMessage { $script:errors += $Message }

            $result = Install-WingetAutoUpdate

            $result.Status | Should -Be 'FrameworkMissing'
            $result.FrameworkMissing | Should -BeTrue
            $result.FrameworkInstallError | Should -Be 'Add-AppxProvisionedPackage failed (its error is above)'
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
            ($script:errors -join "`n") | Should -Match 'NOT installed: Microsoft\.WindowsAppRuntime\.1\.8 is missing \(none registered\)\. The installer could not install it \(see ''Windows App Runtime: NOT INSTALLED'' above\)\.'
        }

        It 'reports an already-installed WAU at risk, with the reason, when the framework cannot be installed' {
            Mock Get-WindowsAppRuntimeStatus { [pscustomobject]@{ Present = $false; Detail = 'none registered' } }
            Mock Install-WindowsAppRuntimeFramework { [pscustomobject]@{ Installed = $false; Status = $null; Reason = 'installing it for all users needs administrator rights' } }
            Mock Test-WauInstalled { $true }
            Mock Get-InstalledWauInfo { [pscustomobject]@{ Version = [version](Get-WauPin).Version; ProductCode = (Get-WauPin).ProductCode } }
            $script:errors = @()
            Mock Write-ErrorMessage { $script:errors += $Message }

            $result = Install-WingetAutoUpdate

            $result.Status | Should -Be 'AlreadyPresent'
            $result.FrameworkMissing | Should -BeTrue
            $result.FrameworkInstallError | Should -Be 'installing it for all users needs administrator rights'
            ($script:errors -join "`n") | Should -Match 'The installer could not install it \(see ''Windows App Runtime: NOT INSTALLED'' above\)\. Its next update run may install a winget that cannot start'
        }

        It 'does not try to install the framework when it is present, or when the check itself could not run' -ForEach @(
            @{ Present = $true }
            @{ Present = $null }
        ) {
            $script:present = $Present
            Mock Get-WindowsAppRuntimeStatus { [pscustomobject]@{ Present = $script:present; Detail = 'checked' } }
            Mock Test-WauInstalled { $true }
            Mock Get-InstalledWauInfo { [pscustomobject]@{ Version = [version](Get-WauPin).Version; ProductCode = (Get-WauPin).ProductCode } }

            $result = Install-WingetAutoUpdate

            $result.Status | Should -Be 'AlreadyPresent'
            Should -Invoke Install-WindowsAppRuntimeFramework -Times 0 -Exactly
        }

        It 'previews installing the framework under -WhatIf without installing it' -ForEach @(
            @{ WauInstalled = $false }
            @{ WauInstalled = $true }
        ) {
            $script:wauInstalled = $WauInstalled
            Mock Test-WauInstalled { $script:wauInstalled }
            $script:infos = @()
            Mock Write-Info { $script:infos += $Message }

            $result = Install-WingetAutoUpdate -WhatIf

            $result.Status | Should -Be 'DryRun'
            ($script:infos -join "`n") | Should -Match 'If Microsoft\.WindowsAppRuntime\.1\.8 is missing, would first install the pinned Windows App Runtime 1\.8\.12 \(framework 8000\.994\.2142\.0\) for all users'
            Should -Invoke Install-WindowsAppRuntimeFramework -Times 0 -Exactly
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

        # Review finding P3-36: WAU's registry key alone used to make it 'AlreadyPresent' (a green
        # 'Auto-updates: Already present') on a machine whose WAU task was gone.
        It 'reports Unhealthy, not AlreadyPresent, when WAU is installed but its scheduled task does not exist (review finding P3-36)' {
            Mock Test-WauInstalled { $true }
            Mock Get-InstalledWauInfo { [pscustomobject]@{ Version = [version](Get-WauPin).Version; ProductCode = (Get-WauPin).ProductCode } }
            Mock Get-WauTaskHealth { New-TestWauTaskHealth -Problem 'its scheduled task \WAU\Winget-AutoUpdate does not exist' }
            Mock Invoke-ExternalProcess { throw 'should not run msiexec for an installed WAU' }
            $script:errors = @()
            Mock Write-ErrorMessage { $script:errors += $Message }

            $result = Install-WingetAutoUpdate

            $result.Status | Should -Be 'Unhealthy'
            $result.Problem | Should -Be 'its scheduled task \WAU\Winget-AutoUpdate does not exist'
            $result.CheckFailed | Should -BeFalse
            $result.Version | Should -Be ([version](Get-WauPin).Version)
            $script:errors | Should -Contain 'Winget-AutoUpdate is installed, but its scheduled task \WAU\Winget-AutoUpdate does not exist, so apps will not update automatically. To set it up again, uninstall Winget-AutoUpdate (Settings > Apps) and re-run this installer.'
            # Its state and WAU's own log go to the transcript either way.
            Should -Invoke Write-WauTaskHealth -Times 1 -Exactly
            Should -Invoke Disable-WauLogonTrigger -Times 1 -Exactly
        }

        It 'reports Unhealthy for an installed WAU whose task is disabled, and keeps the missing framework flag' {
            Mock Get-WindowsAppRuntimeStatus { [pscustomobject]@{ Present = $false; Detail = 'none registered' } }
            Mock Test-WauInstalled { $true }
            Mock Get-InstalledWauInfo { [pscustomobject]@{ Version = [version](Get-WauPin).Version; ProductCode = (Get-WauPin).ProductCode } }
            Mock Get-WauTaskHealth { New-TestWauTaskHealth -Problem 'its scheduled task \WAU\Winget-AutoUpdate is disabled' }

            $result = Install-WingetAutoUpdate

            $result.Status | Should -Be 'Unhealthy'
            $result.FrameworkMissing | Should -BeTrue
        }

        # Review of item 23: a task scheduler that could not be queried says nothing about the task,
        # so the run must not claim apps will not update, nor send the user to reinstall WAU.
        It 'reports Unhealthy with CheckFailed for an installed WAU whose task could not be checked, and sends the user to Task Scheduler instead of a reinstall' {
            Mock Test-WauInstalled { $true }
            Mock Get-InstalledWauInfo { [pscustomobject]@{ Version = [version](Get-WauPin).Version; ProductCode = (Get-WauPin).ProductCode } }
            Mock Get-WauTaskHealth { New-TestWauTaskHealth -Problem 'its scheduled task \WAU\Winget-AutoUpdate could not be checked (Access is denied.)' }
            Mock Invoke-ExternalProcess { throw 'should not run msiexec for an installed WAU' }
            $script:errors = @()
            Mock Write-ErrorMessage { $script:errors += $Message }

            $result = Install-WingetAutoUpdate

            $result.Status | Should -Be 'Unhealthy'
            $result.CheckFailed | Should -BeTrue
            $result.Problem | Should -Be 'its scheduled task \WAU\Winget-AutoUpdate could not be checked (Access is denied.)'
            $script:errors | Should -Contain 'Winget-AutoUpdate is installed, but its scheduled task \WAU\Winget-AutoUpdate could not be checked (Access is denied.), so it is not known whether apps will update automatically. Check the task \WAU\Winget-AutoUpdate in Task Scheduler; if it is missing, disabled or has no enabled trigger, uninstall Winget-AutoUpdate (Settings > Apps) and re-run this installer.'
            ($script:errors -join "`n") | Should -Not -Match 'apps will not update automatically|To set it up again'
        }

        It 'checks the task and logs its state before reporting AlreadyPresent' {
            Mock Test-WauInstalled { $true }
            Mock Get-InstalledWauInfo { [pscustomobject]@{ Version = [version](Get-WauPin).Version; ProductCode = (Get-WauPin).ProductCode } }
            $script:healthLogged = $null
            Mock Write-WauTaskHealth { $script:healthLogged = $Health }

            (Install-WingetAutoUpdate).Status | Should -Be 'AlreadyPresent'

            Should -Invoke Get-WauTaskHealth -Times 1 -Exactly
            $script:healthLogged.Healthy | Should -BeTrue
        }

        It 'reports Unhealthy, not Configured, when msiexec succeeded but the task will not run, and names the msiexec log (review finding P3-36)' {
            Mock Test-WauInstalled { $false }
            Mock New-WauStagingDirectory { Join-Path $TestDrive 'wau-msi-test' }
            Mock Invoke-WebRequest { }
            Mock Get-FileHash { @{ Hash = (Get-WauPin).Sha256 } }
            Mock Invoke-ExternalProcess { New-TestProcessResult -ExitCode 3010 }
            Mock Remove-Item { }
            Mock Get-WauTaskHealth { New-TestWauTaskHealth -Problem 'its scheduled task \WAU\Winget-AutoUpdate does not exist' }
            $script:errors = @()
            Mock Write-ErrorMessage { $script:errors += $Message }

            $result = Install-WingetAutoUpdate

            $result.Status | Should -Be 'Unhealthy'
            $result.Version | Should -Be (Get-WauPin).Version
            # Still installed: the restart msiexec asked for is not lost.
            $result.RestartRequired | Should -BeTrue
            ($script:errors -join "`n") | Should -Match ('^Winget-AutoUpdate {0} was installed, but its scheduled task \\WAU\\Winget-AutoUpdate does not exist, so apps will not update automatically\..* msiexec log: {1}$' -f [regex]::Escape((Get-WauPin).Version), [regex]::Escape((Join-Path $TestDrive 'wau-msi-install-1.log')))
            Should -Invoke Write-Success -Times 0 -Exactly -ParameterFilter { $Message -match 'installed\. Apps will update weekly' }
            Should -Invoke Write-WauTaskHealth -Times 1 -Exactly
        }

        It 'reports Unhealthy with CheckFailed when msiexec succeeded but the task could not be checked, and sends the user to Task Scheduler instead of a reinstall' {
            Mock Test-WauInstalled { $false }
            Mock New-WauStagingDirectory { Join-Path $TestDrive 'wau-msi-test' }
            Mock Invoke-WebRequest { }
            Mock Get-FileHash { @{ Hash = (Get-WauPin).Sha256 } }
            Mock Invoke-ExternalProcess { New-TestProcessResult -ExitCode 0 }
            Mock Remove-Item { }
            Mock Get-WauTaskHealth { New-TestWauTaskHealth -Problem 'its scheduled task \WAU\Winget-AutoUpdate could not be checked (Access is denied.)' }
            $script:errors = @()
            Mock Write-ErrorMessage { $script:errors += $Message }

            $result = Install-WingetAutoUpdate

            $result.Status | Should -Be 'Unhealthy'
            $result.CheckFailed | Should -BeTrue
            $result.RestartRequired | Should -BeFalse
            ($script:errors -join "`n") | Should -Match ('^Winget-AutoUpdate {0} was installed, but its scheduled task \\WAU\\Winget-AutoUpdate could not be checked \(Access is denied\.\), so it is not known whether apps will update automatically\. Check the task \\WAU\\Winget-AutoUpdate in Task Scheduler; if it is missing, disabled or has no enabled trigger, uninstall Winget-AutoUpdate \(Settings > Apps\) and re-run this installer\. msiexec log: {1}$' -f [regex]::Escape((Get-WauPin).Version), [regex]::Escape((Join-Path $TestDrive 'wau-msi-install-1.log')))
            ($script:errors -join "`n") | Should -Not -Match 'apps will not update automatically'
            Should -Invoke Write-Success -Times 0 -Exactly -ParameterFilter { $Message -match 'installed\. Apps will update weekly' }
        }

        It 'checks the task after a successful install and only then says apps will update weekly' {
            Mock Test-WauInstalled { $false }
            Mock New-WauStagingDirectory { Join-Path $TestDrive 'wau-msi-test' }
            Mock Invoke-WebRequest { }
            Mock Get-FileHash { @{ Hash = (Get-WauPin).Sha256 } }
            Mock Invoke-ExternalProcess { New-TestProcessResult -ExitCode 0 }
            Mock Remove-Item { }

            (Install-WingetAutoUpdate).Status | Should -Be 'Configured'

            Should -Invoke Get-WauTaskHealth -Times 1 -Exactly
            Should -Invoke Write-WauTaskHealth -Times 1 -Exactly
            Should -Invoke Write-Success -Times 1 -Exactly -ParameterFilter { $Message -match 'installed\. Apps will update weekly' }
        }

        # Review finding P3-37: a failed WAU msiexec used to leave only its exit code.
        It 'gives msiexec a verbose log in the logs folder and names it when the install fails (review finding P3-37)' {
            Mock Test-WauInstalled { $false }
            Mock New-WauStagingDirectory { Join-Path $TestDrive 'wau-msi-test' }
            Mock Invoke-WebRequest { }
            Mock Get-FileHash { @{ Hash = (Get-WauPin).Sha256 } }
            Mock Invoke-ExternalProcess { New-TestProcessResult -ExitCode 1603 }
            Mock Remove-Item { }
            $script:errors = @()
            Mock Write-ErrorMessage { $script:errors += $Message }
            $logPath = Join-Path $TestDrive 'wau-msi-install-1.log'

            (Install-WingetAutoUpdate).Status | Should -Be 'Failed'

            Should -Invoke New-WauMsiLogPath -Times 1 -Exactly -ParameterFilter { $Action -eq 'install' -and $Attempt -eq 1 }
            Should -Invoke Invoke-ExternalProcess -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'msiexec.exe' -and $ArgumentString.EndsWith(" /l*v `"$logPath`"") }
            $script:errors | Should -Contain "Winget-AutoUpdate install failed (msiexec exit code 1603). msiexec log: $logPath"
        }

        It 'names the msiexec log when msiexec runs past its time limit' {
            Mock Test-WauInstalled { $false }
            Mock New-WauStagingDirectory { Join-Path $TestDrive 'wau-msi-test' }
            Mock Invoke-WebRequest { }
            Mock Get-FileHash { @{ Hash = (Get-WauPin).Sha256 } }
            Mock Invoke-ExternalProcess { New-TestProcessResult -TimedOut }
            Mock Remove-Item { }
            $script:errors = @()
            Mock Write-ErrorMessage { $script:errors += $Message }

            (Install-WingetAutoUpdate).Status | Should -Be 'Failed'

            $script:errors | Should -Contain "Winget-AutoUpdate install failed: msiexec did not finish within 15 minutes and was stopped. msiexec log: $(Join-Path $TestDrive 'wau-msi-install-1.log')"
        }

        It 'gives each attempt after msiexec exit code 1618 its own log' {
            Mock Test-WauInstalled { $false }
            Mock New-WauStagingDirectory { Join-Path $TestDrive 'wau-msi-test' }
            Mock Invoke-WebRequest { }
            Mock Get-FileHash { @{ Hash = (Get-WauPin).Sha256 } }
            Mock Remove-Item { }
            $script:msiexecArguments = [System.Collections.Generic.List[string]]::new()
            Mock Invoke-ExternalProcess {
                $script:msiexecArguments.Add($ArgumentString)
                if ($script:msiexecArguments.Count -eq 1) {
                    return New-TestProcessResult -ExitCode 1618
                }
                New-TestProcessResult -ExitCode 0
            }
            Mock Wait-WindowsInstallerIdle { [pscustomobject]@{ WaitedSeconds = 30; Busy = $false } }

            (Install-WingetAutoUpdate).Status | Should -Be 'Configured'

            $script:msiexecArguments.Count | Should -Be 2
            $script:msiexecArguments[0] | Should -BeLike "* /l*v `"$(Join-Path $TestDrive 'wau-msi-install-1.log')`""
            $script:msiexecArguments[1] | Should -BeLike "* /l*v `"$(Join-Path $TestDrive 'wau-msi-install-2.log')`""
        }

        It 'runs msiexec without a log when no logs folder can be used' {
            Mock Test-WauInstalled { $false }
            Mock New-WauStagingDirectory { Join-Path $TestDrive 'wau-msi-test' }
            Mock Invoke-WebRequest { }
            Mock Get-FileHash { @{ Hash = (Get-WauPin).Sha256 } }
            Mock Invoke-ExternalProcess { New-TestProcessResult -ExitCode 1603 }
            Mock Remove-Item { }
            Mock New-WauMsiLogPath { $null }
            $script:errors = @()
            Mock Write-ErrorMessage { $script:errors += $Message }

            (Install-WingetAutoUpdate).Status | Should -Be 'Failed'

            Should -Invoke Invoke-ExternalProcess -Times 1 -Exactly -ParameterFilter { $ArgumentString -notmatch '/l\*v' }
            $script:errors | Should -Contain 'Winget-AutoUpdate install failed (msiexec exit code 1603).'
        }
    }

    Context 'Install-WingetAutoUpdate holds the MSI open from the hash until msiexec has finished (review finding P2-21)' {
        BeforeEach {
            Mock Get-WindowsAppRuntimeStatus { [pscustomobject]@{ Present = $true; Detail = 'X64 8000.921.1539.0' } }
            Mock Get-WindowsAppRuntimeRequirement { Get-DefaultWindowsAppRuntimeRequirement }
            Mock Disable-WauLogonTrigger { $false }
            Mock Test-WauInstalled { $false }
            Mock Get-WauTaskHealth { New-TestWauTaskHealth }
            Mock Write-WauTaskHealth { }
            Mock New-WauMsiLogPath { Join-Path $TestDrive "wau-msi-$Action-$Attempt.log" }
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
            # msiexec's verbose log (review finding P3-37) goes after the MSI's own arguments.
            $script:msiexecArguments | Should -BeLike "* /l*v `"$(Join-Path $TestDrive 'wau-msi-install-1.log')`""
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
        BeforeEach {
            Mock New-WauMsiLogPath { Join-Path $TestDrive "wau-msi-$Action-$Attempt.log" }
        }

        It 'uninstalls via the ProductCode of the actually-installed WAU (issue #186)' {
            Mock Test-WauInstalled { $true }
            Mock Get-InstalledWauInfo { [pscustomobject]@{ Version = [version]'2.9.0'; ProductCode = '{11111111-2222-3333-4444-555555555555}' } }
            Mock Invoke-ExternalProcess { New-TestProcessResult -ExitCode 0 }

            $result = Uninstall-WingetAutoUpdate

            $result.Succeeded | Should -BeTrue
            $result.RestartRequired | Should -BeFalse
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

            $result.Succeeded | Should -BeTrue
            Should -Invoke Invoke-ExternalProcess -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq 'msiexec.exe' -and $ArgumentString -match '/x' -and
                $ArgumentString -match ([regex]::Escape((Get-WauPin).ProductCode))
            }
        }

        It 'returns false when msiexec runs past its time limit (review finding P2-5)' {
            Mock Test-WauInstalled { $true }
            Mock Get-InstalledWauInfo { [pscustomobject]@{ Version = [version]'2.9.0'; ProductCode = '{11111111-2222-3333-4444-555555555555}' } }
            Mock Invoke-ExternalProcess { New-TestProcessResult -TimedOut }

            (Uninstall-WingetAutoUpdate).Succeeded | Should -BeFalse
            Should -Invoke Write-ErrorMessage -Times 1 -Exactly -ParameterFilter { $Message -match 'did not finish in time' }
        }

        It 'reports a removal msiexec finishes at the next restart (3010) as removed, restart required' {
            Mock Test-WauInstalled { $true }
            Mock Get-InstalledWauInfo { [pscustomobject]@{ Version = [version]'2.9.0'; ProductCode = '{11111111-2222-3333-4444-555555555555}' } }
            Mock Invoke-ExternalProcess { New-TestProcessResult -ExitCode 3010 }

            $result = Uninstall-WingetAutoUpdate

            $result.Succeeded | Should -BeTrue
            $result.RestartRequired | Should -BeTrue
            Should -Invoke Write-Success -Times 1 -Exactly -ParameterFilter { $Message -match 'a restart finishes removing it: msiexec exit code 3010' }
        }

        It 'reports any other msiexec exit code as a failure' {
            Mock Test-WauInstalled { $true }
            Mock Get-InstalledWauInfo { [pscustomobject]@{ Version = [version]'2.9.0'; ProductCode = '{11111111-2222-3333-4444-555555555555}' } }
            Mock Invoke-ExternalProcess { New-TestProcessResult -ExitCode 1603 }

            $result = Uninstall-WingetAutoUpdate

            $result.Succeeded | Should -BeFalse
            $result.RestartRequired | Should -BeFalse
            Should -Invoke Write-ErrorMessage -Times 1 -Exactly -ParameterFilter { $Message -match 'msiexec exit code 1603' }
        }

        It 'is a no-op when WAU is not installed' {
            Mock Test-WauInstalled { $false }
            Mock Invoke-ExternalProcess { throw 'should not run msiexec when WAU is absent' }

            (Uninstall-WingetAutoUpdate).Succeeded | Should -BeTrue
            Should -Invoke Invoke-ExternalProcess -Times 0 -Exactly
        }

        It 'gives the uninstall a verbose msiexec log and names it when the uninstall fails (review finding P3-37)' {
            Mock Test-WauInstalled { $true }
            Mock Get-InstalledWauInfo { [pscustomobject]@{ Version = [version]'2.12.0'; ProductCode = '{11111111-2222-3333-4444-555555555555}' } }
            Mock Invoke-ExternalProcess { New-TestProcessResult -ExitCode 1603 }
            $logPath = Join-Path $TestDrive 'wau-msi-uninstall-1.log'

            $result = Uninstall-WingetAutoUpdate

            $result.Succeeded | Should -BeFalse
            $result.RestartRequired | Should -BeFalse
            Should -Invoke Invoke-ExternalProcess -Times 1 -Exactly -ParameterFilter { $ArgumentString -eq "/x {11111111-2222-3333-4444-555555555555} /qn /norestart /l*v `"$logPath`"" }
            Should -Invoke Write-ErrorMessage -Times 1 -Exactly -ParameterFilter { $Message -eq "Winget-AutoUpdate uninstall failed (msiexec exit code 1603). msiexec log: $logPath" }
        }

        It 'waits for another installation to finish when the uninstall gets msiexec exit code 1618' {
            Mock Test-WauInstalled { $true }
            Mock Get-InstalledWauInfo { [pscustomobject]@{ Version = [version]'2.12.0'; ProductCode = '{11111111-2222-3333-4444-555555555555}' } }
            $script:msiexecRuns = 0
            Mock Invoke-ExternalProcess {
                $script:msiexecRuns++
                if ($script:msiexecRuns -eq 1) {
                    return New-TestProcessResult -ExitCode 1618
                }
                New-TestProcessResult -ExitCode 0
            }
            Mock Wait-WindowsInstallerIdle { [pscustomobject]@{ WaitedSeconds = 20; Busy = $false } }

            $result = Uninstall-WingetAutoUpdate

            $result.Succeeded | Should -BeTrue
            $result.RestartRequired | Should -BeFalse
            $script:msiexecRuns | Should -Be 2
            Should -Invoke Wait-WindowsInstallerIdle -Times 1 -Exactly -ParameterFilter { $MaximumSeconds -eq 600 }
        }

        It 'reports the uninstall as failed, with the reason and the log, when Windows Installer stays busy past the wait budget' {
            # The uninstaller keeps reading Succeeded (review finding P3-18): a removal msiexec never
            # ran must not count as done.
            Mock Test-WauInstalled { $true }
            Mock Get-InstalledWauInfo { [pscustomobject]@{ Version = [version]'2.12.0'; ProductCode = '{11111111-2222-3333-4444-555555555555}' } }
            Mock Invoke-ExternalProcess { New-TestProcessResult -ExitCode 1618 }
            Mock Wait-WindowsInstallerIdle { [pscustomobject]@{ WaitedSeconds = $MaximumSeconds; Busy = $true } }
            $logPath = Join-Path $TestDrive 'wau-msi-uninstall-2.log'

            $result = Uninstall-WingetAutoUpdate -InstallInProgressWaitSeconds 120

            $result.Succeeded | Should -BeFalse
            $result.RestartRequired | Should -BeFalse
            Should -Invoke Write-ErrorMessage -Times 1 -Exactly -ParameterFilter {
                $Message -eq "Winget-AutoUpdate uninstall failed: Windows Installer was still busy with another installation after 1 retries and 120 seconds of waiting (msiexec exit code 1618). Run the uninstaller again once that installation has finished. msiexec log: $logPath"
            }
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
            $installBody | Should -Match 'Auto-updates: UNHEALTHY'
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

# Work-order item 32 (product-F4): every WAU run installs the newest winget release, so the gate
# checks for what that release needs, read from its DesktopAppInstaller_Dependencies.json, instead
# of only the Microsoft.WindowsAppRuntime.1.8 >= 8000.616.304.0 constant. tests/fixtures/
# winget-dependencies holds the files of real releases (v1.29.380, the latest on 2026-10-04,
# v1.12.350 and v1.11.510, byte for byte) and per-architecture.json, a made-up file with a list per
# architecture (no release has one; it shows that such a file is read for this PC's architecture).
Describe 'Windows App Runtime requirement from the latest winget release (work-order item 32)' {
    BeforeAll {
        $script:fixtureDir = Join-Path $PSScriptRoot 'fixtures/winget-dependencies'
        $script:latestUrl = 'https://github.com/microsoft/winget-cli/releases/latest/download/DesktopAppInstaller_Dependencies.json'
        function Get-DependenciesFixture {
            param ([Parameter(Mandatory = $true)][string]$Name)
            Get-Content -Raw -LiteralPath (Join-Path $script:fixtureDir $Name)
        }
        # Invoke-WebRequest's answer for a GitHub release asset: application/octet-stream, which
        # PowerShell 7 returns as bytes.
        function New-TestAssetResponse {
            param ([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
            [pscustomobject]@{ StatusCode = 200; Content = [System.Text.Encoding]::UTF8.GetBytes($Text) }
        }
        # What PowerShell 7's Invoke-WebRequest throws for an HTTP error that has a body: the
        # status line in the exception, the body (a proxy's block page, GitHub's error page) in
        # ErrorDetails, which is what "$_" prints.
        function New-TestHttpErrorRecord {
            param ([Parameter(Mandatory = $true)][int]$StatusCode, [Parameter(Mandatory = $true)][string]$Body)
            $response = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]$StatusCode)
            $exception = [Microsoft.PowerShell.Commands.HttpResponseException]::new(('Response status code does not indicate success: {0} ({1}).' -f $StatusCode, $response.ReasonPhrase), $response)
            $record = [System.Management.Automation.ErrorRecord]::new($exception, 'WebCmdletWebResponseException,Microsoft.PowerShell.Commands.InvokeWebRequestCommand', [System.Management.Automation.ErrorCategory]::InvalidOperation, $null)
            $record.ErrorDetails = [System.Management.Automation.ErrorDetails]::new($Body)
            $record
        }
    }

    Context 'ConvertFrom-WingetDependenciesJson' {
        It 'reads Microsoft.WindowsAppRuntime.1.8 >= 8000.616.304.0 from the current release (<File>), and nothing else' -ForEach @(
            @{ File = 'v1.29.380.json' }
            @{ File = 'v1.12.350.json' }
        ) {
            $frameworks = @(ConvertFrom-WingetDependenciesJson -Json (Get-DependenciesFixture -Name $File) -Architecture 'X64')

            $frameworks.Count | Should -Be 1
            $frameworks[0].Name | Should -Be 'Microsoft.WindowsAppRuntime.1.8'
            $frameworks[0].MinimumVersion | Should -Be ([version]'8000.616.304.0')
        }

        It 'returns nothing for a release that needs no Windows App Runtime (v1.11.510: UI.Xaml and VCLibs)' {
            @(ConvertFrom-WingetDependenciesJson -Json (Get-DependenciesFixture -Name 'v1.11.510.json') -Architecture 'X64').Count | Should -Be 0
        }

        It 'reads a list per architecture for this PC''s architecture: <Architecture>' -ForEach @(
            @{ Architecture = 'X64'; Name = 'Microsoft.WindowsAppRuntime.2'; Version = '2000.120.5.0' }
            @{ Architecture = 'X86'; Name = 'Microsoft.WindowsAppRuntime.2'; Version = '2000.120.5.0' }
            @{ Architecture = 'Arm64'; Name = 'Microsoft.WindowsAppRuntime.1.8'; Version = '8000.1001.5.0' }
        ) {
            $frameworks = @(ConvertFrom-WingetDependenciesJson -Json (Get-DependenciesFixture -Name 'per-architecture.json') -Architecture $Architecture)

            $frameworks.Count | Should -Be 1
            $frameworks[0].Name | Should -Be $Name
            $frameworks[0].MinimumVersion | Should -Be ([version]$Version)
        }

        It 'reads a list per architecture under Dependencies too' {
            $json = '{"Dependencies":{"arm64":[{"Name":"Microsoft.WindowsAppRuntime.1.8","Version":"8000.700.0.0"}],"x64":[{"Name":"Microsoft.WindowsAppRuntime.1.8","Version":"8000.616.304.0"}]}}'

            $frameworks = @(ConvertFrom-WingetDependenciesJson -Json $json -Architecture 'Arm64')

            $frameworks.Count | Should -Be 1
            $frameworks[0].MinimumVersion | Should -Be ([version]'8000.700.0.0')
        }

        It 'keeps the highest version of a framework listed twice, and every family listed' {
            $json = '{"Dependencies":[{"Name":"Microsoft.WindowsAppRuntime.1.8","Version":"8000.616.304.0"},{"Name":"Microsoft.WindowsAppRuntime.1.8","Version":"8000.700.1.0"},{"Name":"Microsoft.WindowsAppRuntime.2","Version":"2000.1.0.0"}]}'

            $frameworks = @(ConvertFrom-WingetDependenciesJson -Json $json)

            $frameworks.Count | Should -Be 2
            ($frameworks | Where-Object Name -EQ 'Microsoft.WindowsAppRuntime.1.8').MinimumVersion | Should -Be ([version]'8000.700.1.0')
            ($frameworks | Where-Object Name -EQ 'Microsoft.WindowsAppRuntime.2').MinimumVersion | Should -Be ([version]'2000.1.0.0')
        }

        It 'reads a file that starts with a byte order mark' {
            $json = [string][char]0xFEFF + (Get-DependenciesFixture -Name 'v1.29.380.json')

            @(ConvertFrom-WingetDependenciesJson -Json $json).Count | Should -Be 1
        }

        It 'throws for <Case>' -ForEach @(
            @{ Case = 'text that is not JSON (an HTML error page)'; Json = '<html><body>Not Found</body></html>'; Message = 'it is not valid JSON*' }
            @{ Case = 'an empty file'; Json = ''; Message = 'it is not a JSON object' }
            @{ Case = 'a JSON array'; Json = '[]'; Message = 'it is not a JSON object' }
            @{ Case = 'no Dependencies list'; Json = '{"Packages":[]}'; Message = 'it holds no Dependencies list*' }
            @{ Case = 'a list per architecture without this one'; Json = '{"x64":{"Dependencies":[]}}'; Message = 'it holds no Dependencies list, for all architectures or for Arm64' }
            @{ Case = 'an entry with no Version'; Json = '{"Dependencies":[{"Name":"Microsoft.VCLibs.140.00"}]}'; Message = 'one of its entries has no Name or no Version' }
            @{ Case = 'an entry that is not an object'; Json = '{"Dependencies":["Microsoft.WindowsAppRuntime.1.8"]}'; Message = 'one of its entries has no Name or no Version' }
            @{ Case = 'a version that is not one'; Json = '{"Dependencies":[{"Name":"Microsoft.WindowsAppRuntime.1.8","Version":"latest"}]}'; Message = "'latest' (Microsoft.WindowsAppRuntime.1.8) is not a version" }
            @{ Case = 'a name that is not a package name (it goes into a Windows PowerShell command)'; Json = '{"Dependencies":[{"Name":"Microsoft.WindowsAppRuntime.1.8''; Remove-Item C:\\x; ''","Version":"8000.616.304.0"}]}'; Message = '*is not a package name' }
        ) {
            { ConvertFrom-WingetDependenciesJson -Json $Json -Architecture 'Arm64' } | Should -Throw $Message
        }
    }

    Context 'Get-WindowsAppRuntimeRequirement' {
        BeforeEach {
            $script:warnings = @()
            $script:infos = @()
            Mock Write-WarningMessage { $script:warnings += $Message }
            Mock Write-Info { $script:infos += $Message }
            Mock Get-OSArchitecture { 'X64' }
            $script:responseText = Get-DependenciesFixture -Name 'v1.29.380.json'
            Mock Invoke-WebRequest { New-TestAssetResponse -Text $script:responseText }
        }

        It 'reads the latest winget release''s DesktopAppInstaller_Dependencies.json, with the 30-second lookup limit' {
            $requirement = Get-WindowsAppRuntimeRequirement

            $requirement.Source | Should -Be 'LatestRelease'
            @($requirement.Frameworks).Count | Should -Be 1
            $requirement.Frameworks[0].Name | Should -Be 'Microsoft.WindowsAppRuntime.1.8'
            $requirement.Frameworks[0].MinimumVersion | Should -Be ([version]'8000.616.304.0')
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
                $Uri -eq $script:latestUrl -and $TimeoutSec -eq 30 -and $UseBasicParsing -and -not $OutFile
            }
            $script:infos | Should -Be @('The latest winget release needs Microsoft.WindowsAppRuntime.1.8 >= 8000.616.304.0 (its DesktopAppInstaller_Dependencies.json).')
            $script:warnings | Should -BeNullOrEmpty
        }

        It 'bounds a stall while the file arrives too, where Invoke-WebRequest can (PowerShell 7.4 and newer)' -Skip:(-not (Get-Command Invoke-WebRequest).Parameters.ContainsKey('OperationTimeoutSeconds')) {
            $null = Get-WindowsAppRuntimeRequirement

            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $OperationTimeoutSeconds -eq 30 }
        }

        It 'reads a text answer as well as bytes' {
            Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = 200; Content = $script:responseText } }

            (Get-WindowsAppRuntimeRequirement).Source | Should -Be 'LatestRelease'
        }

        It 'finds a newer framework family the latest release needs' {
            $script:responseText = '{"Dependencies":[{"Name":"Microsoft.VCLibs.140.00.UWPDesktop","Version":"14.0.33728.0"},{"Name":"Microsoft.WindowsAppRuntime.2","Version":"2000.120.5.0"}]}'

            $requirement = Get-WindowsAppRuntimeRequirement

            $requirement.Source | Should -Be 'LatestRelease'
            $requirement.Frameworks[0].Name | Should -Be 'Microsoft.WindowsAppRuntime.2'
            $requirement.Frameworks[0].MinimumVersion | Should -Be ([version]'2000.120.5.0')
        }

        It 'reads a list per architecture for the OS architecture' {
            $script:responseText = Get-DependenciesFixture -Name 'per-architecture.json'
            Mock Get-OSArchitecture { 'Arm64' }

            $requirement = Get-WindowsAppRuntimeRequirement

            $requirement.Frameworks[0].Name | Should -Be 'Microsoft.WindowsAppRuntime.1.8'
            $requirement.Frameworks[0].MinimumVersion | Should -Be ([version]'8000.1001.5.0')
        }

        It 'falls back to the built-in requirement, with a warning and without throwing, when <Case>' -ForEach @(
            @{ Case = 'there is no network'; Setup = { Mock Invoke-WebRequest { throw 'No such host is known. (github.com:443)' } }; Problem = 'No such host is known. (github.com:443)' }
            @{ Case = 'the request times out'; Setup = { Mock Invoke-WebRequest { throw 'The request was canceled due to the configured HttpClient.Timeout of 30 seconds elapsing.' } }; Problem = 'The request was canceled due to the configured HttpClient.Timeout of 30 seconds elapsing' }
            # Review of item 32: the status line, not the block page the proxy sent with it.
            @{ Case = 'a proxy refuses it with a block page'; Setup = { Mock Invoke-WebRequest { throw (New-TestHttpErrorRecord -StatusCode 403 -Body "<html><head><style>body{font-family:x}</style></head>`n<body>Access Denied`nYour organization's policy blocks github.com</body></html>") } }; Problem = 'Response status code does not indicate success: 403 (Forbidden)' }
            @{ Case = 'GitHub refuses it (rate limit)'; Setup = { Mock Invoke-WebRequest { throw (New-TestHttpErrorRecord -StatusCode 429 -Body '{"message":"API rate limit exceeded"}') } }; Problem = 'Response status code does not indicate success: 429 (Too Many Requests)' }
            @{ Case = 'the error is long and spans lines'; Setup = { Mock Invoke-WebRequest { throw ("first line`r`n   second line`n" + ('x' * 400)) } }; Problem = ('first line second line ' + ('x' * 274) + '...') }
            @{ Case = 'the file is not JSON (a captive portal page)'; Setup = { $script:responseText = '<html>Sign in to the network</html>' }; Problem = 'it is not valid JSON*' }
            @{ Case = 'the file has a shape this does not know'; Setup = { $script:responseText = '{"Packages":[]}' }; Problem = 'it holds no Dependencies list*' }
            @{ Case = 'the answer is far too large to be the file'; Setup = { $script:responseText = '{"Dependencies":[]}' + (' ' * 70000) }; Problem = 'it is 70019 characters long, not a list of dependencies' }
            @{ Case = 'the answer is empty'; Setup = { Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = 200; Content = $null } } }; Problem = 'it is not a JSON object' }
        ) {
            . $Setup

            $requirement = Get-WindowsAppRuntimeRequirement

            $requirement.Source | Should -Be 'BuiltIn'
            @($requirement.Frameworks).Count | Should -Be 1
            $requirement.Frameworks[0].Name | Should -Be 'Microsoft.WindowsAppRuntime.1.8'
            $requirement.Frameworks[0].MinimumVersion | Should -Be ([version]'8000.616.304.0')
            $requirement.Detail | Should -BeLike "the built-in requirement (the latest winget release's DesktopAppInstaller_Dependencies.json could not be read: $Problem)"
            $script:warnings.Count | Should -Be 1
            $script:warnings[0] | Should -BeLike "Could not read which Windows App Runtime the latest winget release needs ($script:latestUrl`: $Problem); checking for the built-in requirement, Microsoft.WindowsAppRuntime.1.8 >= 8000.616.304.0."
            $script:warnings[0] | Should -Not -Match '[\r\n]'
        }

        It 'falls back to the built-in requirement, with a warning, when the latest release lists no Windows App Runtime' {
            $script:responseText = Get-DependenciesFixture -Name 'v1.11.510.json'

            $requirement = Get-WindowsAppRuntimeRequirement

            $requirement.Source | Should -Be 'BuiltIn'
            $requirement.Frameworks[0].Name | Should -Be 'Microsoft.WindowsAppRuntime.1.8'
            $script:warnings | Should -Be @('The latest winget release lists no Microsoft.WindowsAppRuntime dependency in its DesktopAppInstaller_Dependencies.json; checking for the built-in requirement, Microsoft.WindowsAppRuntime.1.8 >= 8000.616.304.0, anyway.')
        }

        It 'still reads a file with one list for all architectures when the OS architecture cannot be read' {
            Mock Get-OSArchitecture { throw 'The OS architecture could not be read.' }

            (Get-WindowsAppRuntimeRequirement).Source | Should -Be 'LatestRelease'
        }
    }

    Context 'Get-WindowsAppRuntimeStatus checks for what the requirement names' {
        BeforeAll {
            $script:osArch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
            function New-TestRequirement {
                param ([string]$Name, [string]$MinimumVersion)
                [pscustomobject]@{ Frameworks = @([pscustomobject]@{ Name = $Name; MinimumVersion = [version]$MinimumVersion }); Source = 'LatestRelease'; Detail = 'test' }
            }
        }

        BeforeEach {
            # This PC has the 1.8 framework the installer pins, and no other family.
            Mock Get-WindowsAppRuntimePackageInfo { }
            Mock Get-WindowsAppRuntimePackageInfo { [pscustomobject]@{ Version = [version]'8000.994.2142.0'; Architecture = $script:osArch } } -ParameterFilter { $Name -eq 'Microsoft.WindowsAppRuntime.1.8' }
        }

        It 'checks for Microsoft.WindowsAppRuntime.1.8 >= 8000.616.304.0 when given no requirement' {
            $status = Get-WindowsAppRuntimeStatus

            $status.Present | Should -BeTrue
            Should -Invoke Get-WindowsAppRuntimePackageInfo -Times 1 -Exactly -ParameterFilter { $Name -eq 'Microsoft.WindowsAppRuntime.1.8' }
        }

        It 'is not satisfied by Microsoft.WindowsAppRuntime.1.8 when the latest winget needs another family' {
            $status = Get-WindowsAppRuntimeStatus -Requirement (New-TestRequirement -Name 'Microsoft.WindowsAppRuntime.2' -MinimumVersion '2000.120.5.0')

            $status.Present | Should -BeFalse
            $status.Detail | Should -Be "Microsoft.WindowsAppRuntime.2 >= 2000.120.5.0 for $script:osArch required; found: none registered"
            Should -Invoke Get-WindowsAppRuntimePackageInfo -Times 1 -Exactly -ParameterFilter { $Name -eq 'Microsoft.WindowsAppRuntime.2' }
        }

        It 'does not take a newer family for a dependency on Microsoft.WindowsAppRuntime.1.8' {
            # This PC has only Microsoft.WindowsAppRuntime.2.
            Mock Get-WindowsAppRuntimePackageInfo { } -ParameterFilter { $Name -eq 'Microsoft.WindowsAppRuntime.1.8' }
            Mock Get-WindowsAppRuntimePackageInfo { [pscustomobject]@{ Version = [version]'2000.120.5.0'; Architecture = $script:osArch } } -ParameterFilter { $Name -eq 'Microsoft.WindowsAppRuntime.2' }

            (Get-WindowsAppRuntimeStatus -Requirement (New-TestRequirement -Name 'Microsoft.WindowsAppRuntime.1.8' -MinimumVersion '8000.616.304.0')).Present | Should -BeFalse
        }

        It 'is not satisfied by a 1.8 build older than the latest winget needs' {
            $status = Get-WindowsAppRuntimeStatus -Requirement (New-TestRequirement -Name 'Microsoft.WindowsAppRuntime.1.8' -MinimumVersion '8000.1200.0.0')

            $status.Present | Should -BeFalse
            $status.Detail | Should -Be "Microsoft.WindowsAppRuntime.1.8 >= 8000.1200.0.0 for $script:osArch required; found: $script:osArch 8000.994.2142.0"
        }

        It 'is satisfied by the other family when this PC has it' {
            Mock Get-WindowsAppRuntimePackageInfo { [pscustomobject]@{ Version = [version]'2000.130.0.0'; Architecture = $script:osArch } } -ParameterFilter { $Name -eq 'Microsoft.WindowsAppRuntime.2' }

            (Get-WindowsAppRuntimeStatus -Requirement (New-TestRequirement -Name 'Microsoft.WindowsAppRuntime.2' -MinimumVersion '2000.120.5.0')).Present | Should -BeTrue
        }

        It 'needs every framework the requirement names' {
            $requirement = [pscustomobject]@{
                Frameworks = @(
                    [pscustomobject]@{ Name = 'Microsoft.WindowsAppRuntime.1.8'; MinimumVersion = [version]'8000.616.304.0' }
                    [pscustomobject]@{ Name = 'Microsoft.WindowsAppRuntime.2'; MinimumVersion = [version]'2000.1.0.0' }
                )
                Source     = 'LatestRelease'
                Detail     = 'test'
            }

            $status = Get-WindowsAppRuntimeStatus -Requirement $requirement

            $status.Present | Should -BeFalse
            $status.Detail | Should -Match '^Microsoft\.WindowsAppRuntime\.1\.8 >= 8000\.616\.304\.0 for \w+ required; found: \w+ 8000\.994\.2142\.0; Microsoft\.WindowsAppRuntime\.2 >= 2000\.1\.0\.0 for \w+ required; found: none registered$'
        }

        # Review of item 32: Install-WingetAutoUpdate passes these to the framework install and
        # names only them.
        It 'lists only the frameworks this PC lacks as Missing' {
            $requirement = [pscustomobject]@{
                Frameworks = @(
                    [pscustomobject]@{ Name = 'Microsoft.WindowsAppRuntime.1.8'; MinimumVersion = [version]'8000.616.304.0' }
                    [pscustomobject]@{ Name = 'Microsoft.WindowsAppRuntime.2'; MinimumVersion = [version]'2000.1.0.0' }
                )
                Source     = 'LatestRelease'
                Detail     = 'test'
            }

            $missing = @((Get-WindowsAppRuntimeStatus -Requirement $requirement).Missing)

            $missing.Count | Should -Be 1
            $missing[0].Name | Should -Be 'Microsoft.WindowsAppRuntime.2'
            $missing[0].MinimumVersion | Should -Be ([version]'2000.1.0.0')
            @((Get-WindowsAppRuntimeStatus).Missing).Count | Should -Be 0
        }
    }

    # The finding itself: Install-WingetAutoUpdate with the real gate and the real framework
    # install, and only Windows (the AppX query, msiexec, the downloads) mocked. Before item 32 the
    # gate checked for Microsoft.WindowsAppRuntime.1.8 >= 8000.616.304.0 whatever winget needed, so
    # a PC with the 1.8 framework got WAU, whose next run installs a winget that cannot start there.
    Context 'Install-WingetAutoUpdate checks for what the latest winget release needs' {
        BeforeAll {
            $script:osArch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        }

        BeforeEach {
            Mock Write-Host { }
            Mock Write-Success { }
            $script:infos = @()
            $script:warnings = @()
            $script:errors = @()
            Mock Write-Info { $script:infos += $Message }
            Mock Write-WarningMessage { $script:warnings += $Message }
            Mock Write-ErrorMessage { $script:errors += $Message }

            # This PC: the 1.8 framework the installer pins, registered; no other family.
            Mock Get-WindowsAppRuntimePackageInfo { }
            Mock Get-WindowsAppRuntimePackageInfo { [pscustomobject]@{ Version = [version]'8000.994.2142.0'; Architecture = $script:osArch } } -ParameterFilter { $Name -eq 'Microsoft.WindowsAppRuntime.1.8' }
            Mock Get-WindowsAppRuntimeProvisionedInfo { }
            Mock Get-OSArchitecture { $script:osArch }
            Mock Test-IsAdmin { $true }
            Mock Get-WindowsBuildNumber { 26100 }
            Mock Invoke-AppxProvisioning { throw 'must not provision a framework in this test' }

            # The latest winget release's DesktopAppInstaller_Dependencies.json; the WAU MSI.
            $script:dependenciesJson = Get-DependenciesFixture -Name 'v1.29.380.json'
            Mock Invoke-WebRequest { New-TestAssetResponse -Text $script:dependenciesJson } -ParameterFilter { $Uri -eq $script:latestUrl }
            Mock Invoke-WebRequest { throw "unexpected download: $Uri" }
            Mock Invoke-WebRequest { } -ParameterFilter { $Uri -eq (Get-WauPin).MsiUrl }

            Mock Test-WauInstalled { $false }
            Mock Disable-WauLogonTrigger { $false }
            Mock New-WauStagingDirectory { Join-Path $TestDrive 'wau-msi-item32' }
            Mock Open-ReadLockedFile { [System.IO.MemoryStream]::new() }
            Mock Get-FileHash { @{ Hash = (Get-WauPin).Sha256 } }
            Mock Invoke-ExternalProcess { New-TestProcessResult -ExitCode 0 }
            Mock New-WauMsiLogPath { Join-Path $TestDrive "wau-msi-$Action-$Attempt.log" }
            Mock Get-WauTaskHealth { New-TestWauTaskHealth }
            Mock Write-WauTaskHealth { }
            Mock Remove-Item { }
        }

        It 'installs WAU when the PC has what the latest release needs (today: Microsoft.WindowsAppRuntime.1.8 >= 8000.616.304.0)' {
            $result = Install-WingetAutoUpdate

            $result.Status | Should -Be 'Configured'
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Uri -eq $script:latestUrl }
            Should -Invoke Invoke-ExternalProcess -Times 1 -Exactly
            $script:errors | Should -BeNullOrEmpty
        }

        It 'skips WAU, without installing the pinned 1.8 framework, when the latest release needs another family' {
            $script:dependenciesJson = '{"Dependencies":[{"Name":"Microsoft.VCLibs.140.00.UWPDesktop","Version":"14.0.33728.0"},{"Name":"Microsoft.WindowsAppRuntime.2","Version":"2000.120.5.0"}]}'

            $result = Install-WingetAutoUpdate

            $result.Status | Should -Be 'FrameworkMissing'
            $result.FrameworkMissing | Should -BeTrue
            $result.FrameworkName | Should -Be 'Microsoft.WindowsAppRuntime.2'
            $result.FrameworkInstallError | Should -Be 'the latest winget release needs Microsoft.WindowsAppRuntime.2 >= 2000.120.5.0, and the framework this installer installs, Microsoft.WindowsAppRuntime.1.8 8000.994.2142.0, does not meet that; a newer version of this installer is needed'
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly -ParameterFilter { $Uri -eq (Get-WauPin).MsiUrl }
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly -ParameterFilter { $Uri -eq (Get-WindowsAppRuntimePin).PackageUrl }
            Should -Invoke Invoke-ExternalProcess -Times 0 -Exactly
            Should -Invoke New-WauStagingDirectory -Times 0 -Exactly
            $script:errors | Should -Contain "Windows App Runtime: NOT INSTALLED - $($result.FrameworkInstallError)."
            ($script:errors -join "`n") | Should -Match ([regex]::Escape("Winget-AutoUpdate was NOT installed: Microsoft.WindowsAppRuntime.2 is missing (Microsoft.WindowsAppRuntime.2 >= 2000.120.5.0 for $script:osArch required; found: none registered).") + '.* Install the Windows App Runtime 2 \(update App Installer from the Microsoft Store, or install Microsoft''s Windows App SDK 2 runtime\), then re-run this installer\.')
        }

        It 'skips WAU, without installing the pinned framework, when the latest release needs a newer 1.8 build than the pin' {
            $script:dependenciesJson = '{"Dependencies":[{"Name":"Microsoft.WindowsAppRuntime.1.8","Version":"8000.1200.0.0"}]}'

            $result = Install-WingetAutoUpdate

            $result.Status | Should -Be 'FrameworkMissing'
            $result.FrameworkName | Should -Be 'Microsoft.WindowsAppRuntime.1.8'
            $result.FrameworkInstallError | Should -Be 'the latest winget release needs Microsoft.WindowsAppRuntime.1.8 >= 8000.1200.0.0, and the framework this installer installs, Microsoft.WindowsAppRuntime.1.8 8000.994.2142.0, does not meet that; a newer version of this installer is needed'
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly -ParameterFilter { $Uri -eq (Get-WindowsAppRuntimePin).PackageUrl }
            Should -Invoke Invoke-ExternalProcess -Times 0 -Exactly
        }

        It 'reports an installed WAU at risk when the latest release needs a framework the PC lacks and the installer cannot install' {
            $script:dependenciesJson = '{"Dependencies":[{"Name":"Microsoft.WindowsAppRuntime.2","Version":"2000.120.5.0"}]}'
            Mock Test-WauInstalled { $true }
            Mock Get-InstalledWauInfo { [pscustomobject]@{ Version = [version](Get-WauPin).Version; ProductCode = (Get-WauPin).ProductCode } }

            $result = Install-WingetAutoUpdate

            $result.Status | Should -Be 'AlreadyPresent'
            $result.FrameworkMissing | Should -BeTrue
            $result.FrameworkName | Should -Be 'Microsoft.WindowsAppRuntime.2'
            ($script:errors -join "`n") | Should -Match 'Winget-AutoUpdate is installed, but Microsoft\.WindowsAppRuntime\.2 is missing'
        }

        It 'installs WAU when the PC already has the other family the latest release needs' {
            $script:dependenciesJson = '{"Dependencies":[{"Name":"Microsoft.WindowsAppRuntime.2","Version":"2000.120.5.0"}]}'
            Mock Get-WindowsAppRuntimePackageInfo { [pscustomobject]@{ Version = [version]'2000.130.0.0'; Architecture = $script:osArch } } -ParameterFilter { $Name -eq 'Microsoft.WindowsAppRuntime.2' }

            $result = Install-WingetAutoUpdate

            $result.Status | Should -Be 'Configured'
            $script:errors | Should -BeNullOrEmpty
        }

        # Review of item 32: the pinned 1.8 framework is what this PC lacks, so it is installed,
        # and only it is named as missing.
        It 'installs the pinned 1.8 framework, not refuses it, when the latest release also needs another family this PC has' {
            $script:dependenciesJson = '{"Dependencies":[{"Name":"Microsoft.WindowsAppRuntime.1.8","Version":"8000.616.304.0"},{"Name":"Microsoft.WindowsAppRuntime.2","Version":"2000.120.5.0"}]}'
            Mock Get-WindowsAppRuntimePackageInfo { } -ParameterFilter { $Name -eq 'Microsoft.WindowsAppRuntime.1.8' }
            Mock Get-WindowsAppRuntimePackageInfo { [pscustomobject]@{ Version = [version]'2000.130.0.0'; Architecture = $script:osArch } } -ParameterFilter { $Name -eq 'Microsoft.WindowsAppRuntime.2' }
            # The install starts, then stops at its download folder: what matters is that it started.
            Mock New-WauStagingDirectory { throw 'the disk is full' } -ParameterFilter { $Prefix -eq 'appruntime' }

            $result = Install-WingetAutoUpdate

            ($script:infos -join "`n") | Should -Match 'Microsoft\.WindowsAppRuntime\.1\.8 is missing; installing the pinned Windows App Runtime '
            Should -Invoke New-WauStagingDirectory -Times 1 -Exactly -ParameterFilter { $Prefix -eq 'appruntime' }
            $result.Status | Should -Be 'FrameworkMissing'
            $result.FrameworkName | Should -Be 'Microsoft.WindowsAppRuntime.1.8'
            $result.FrameworkInstallError | Should -Be 'setting up its download folder failed: the disk is full'
            ($script:errors -join "`n") | Should -Match 'Winget-AutoUpdate was NOT installed: Microsoft\.WindowsAppRuntime\.1\.8 is missing \('
            ($script:errors -join "`n") | Should -Not -Match 'Microsoft\.WindowsAppRuntime\.1\.8 and Microsoft\.WindowsAppRuntime\.2'
            ($script:errors -join "`n") | Should -Not -Match 'does not meet that'
        }

        It 'passes only the frameworks this PC lacks to the framework install' {
            $script:dependenciesJson = '{"Dependencies":[{"Name":"Microsoft.WindowsAppRuntime.1.8","Version":"8000.616.304.0"},{"Name":"Microsoft.WindowsAppRuntime.2","Version":"2000.120.5.0"}]}'
            Mock Get-WindowsAppRuntimePackageInfo { } -ParameterFilter { $Name -eq 'Microsoft.WindowsAppRuntime.1.8' }
            Mock Get-WindowsAppRuntimePackageInfo { [pscustomobject]@{ Version = [version]'2000.130.0.0'; Architecture = $script:osArch } } -ParameterFilter { $Name -eq 'Microsoft.WindowsAppRuntime.2' }
            Mock Install-WindowsAppRuntimeFramework { [pscustomobject]@{ Installed = $true; Status = [pscustomobject]@{ Present = $true; Detail = 'installed'; Missing = @() }; Reason = $null } }

            $result = Install-WingetAutoUpdate

            $result.Status | Should -Be 'Configured'
            Should -Invoke Install-WindowsAppRuntimeFramework -Times 1 -Exactly -ParameterFilter {
                @($MissingFrameworks).Count -eq 1 -and $MissingFrameworks[0].Name -eq 'Microsoft.WindowsAppRuntime.1.8' -and @($Requirement.Frameworks).Count -eq 2
            }
        }

        It 'passes the requirement it read to the check and to the framework install' {
            Mock Get-WindowsAppRuntimeStatus { [pscustomobject]@{ Present = $false; Detail = 'none registered' } }
            Mock Install-WindowsAppRuntimeFramework { [pscustomobject]@{ Installed = $true; Status = [pscustomobject]@{ Present = $true; Detail = 'installed' }; Reason = $null } }

            $result = Install-WingetAutoUpdate

            $result.Status | Should -Be 'Configured'
            Should -Invoke Get-WindowsAppRuntimeStatus -Times 1 -Exactly -ParameterFilter { $Requirement.Source -eq 'LatestRelease' -and $Requirement.Frameworks[0].Name -eq 'Microsoft.WindowsAppRuntime.1.8' }
            Should -Invoke Install-WindowsAppRuntimeFramework -Times 1 -Exactly -ParameterFilter { $Requirement.Source -eq 'LatestRelease' }
        }

        It 'never stops on the lookup: when GitHub cannot be reached it checks for the built-in requirement and goes on' {
            Mock Invoke-WebRequest { throw 'No such host is known. (github.com:443)' } -ParameterFilter { $Uri -eq $script:latestUrl }

            $result = Install-WingetAutoUpdate

            $result.Status | Should -Be 'Configured'
            Should -Invoke Get-WindowsAppRuntimePackageInfo -Times 1 -Exactly -ParameterFilter { $Name -eq 'Microsoft.WindowsAppRuntime.1.8' }
            $script:warnings | Should -Contain "Could not read which Windows App Runtime the latest winget release needs ($script:latestUrl`: No such host is known. (github.com:443)); checking for the built-in requirement, Microsoft.WindowsAppRuntime.1.8 >= 8000.616.304.0."
        }

        It 'does not look anything up under -WhatIf' {
            $result = Install-WingetAutoUpdate -WhatIf

            $result.Status | Should -Be 'DryRun'
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        }
    }

    Context 'Get-WindowsAppRuntimePackageInfo queries the framework it is given' {
        It 'puts the name into the Windows PowerShell query' -Skip:($PSVersionTable.PSEdition -ne 'Core') {
            Mock powershell.exe { $global:LASTEXITCODE = 0; '2000.120.5.0|X64' }

            $packages = @(Get-WindowsAppRuntimePackageInfo -Name 'Microsoft.WindowsAppRuntime.2')

            $packages[0].Version | Should -Be ([version]'2000.120.5.0')
            Should -Invoke powershell.exe -Times 1 -Exactly -ParameterFilter { "$($args[-1])" -match "Get-AppxPackage -AllUsers -Name 'Microsoft\.WindowsAppRuntime\.2' " }
        }

        It 'refuses a name that is not a package name, before anything runs' {
            Mock powershell.exe { $global:LASTEXITCODE = 0 }

            { Get-WindowsAppRuntimePackageInfo -Name "Microsoft.WindowsAppRuntime.1.8'; Remove-Item C:\x; '" } | Should -Throw
            Should -Invoke powershell.exe -Times 0 -Exactly
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

# Review finding P3-38: Test-WauInstalled and Remove-LegacyScheduledUpdates probed with
# -ErrorAction Stop inside try/catch, and a transcript records a caught Stop error as
# 'PS>TerminatingError(Get-ScheduledTask)'. Every fresh install, and every run without the legacy
# task, logged one; #283's was read as part of the crash. The mocks below answer like the real
# cmdlet for a task that does not exist: a non-terminating 'not found' error that -ErrorAction Stop
# turns into a terminating one.
Describe 'Scheduled-task probes stay out of the transcript (review finding P3-38)' {
    BeforeEach {
        Mock Get-ScheduledTask {
            Write-Error -Exception ([System.Exception]::new("No MSFT_ScheduledTask objects found with property 'TaskName' equal to '$TaskName'.")) -ErrorId 'CmdletizationQuery_NotFound_TaskName' -Category ObjectNotFound
        }
        Mock Test-Path { $false }
        Mock Write-Info { }
    }

    It 'Test-WauInstalled finds no WAU without writing an error into the transcript' {
        $script:installed = $null

        $transcript = Get-TranscriptText { $script:installed = Test-WauInstalled }

        $script:installed | Should -BeFalse
        $transcript | Should -Not -Match 'TerminatingError'
        $transcript | Should -Not -Match 'MSFT_ScheduledTask'
        Should -Invoke Get-ScheduledTask -Times 1 -Exactly
    }

    It 'Remove-LegacyScheduledUpdates finds no legacy task without writing an error into the transcript' {
        $script:removed = $null

        $transcript = Get-TranscriptText { $script:removed = Remove-LegacyScheduledUpdates }

        $script:removed | Should -BeFalse
        $transcript | Should -Not -Match 'TerminatingError'
        $transcript | Should -Not -Match 'MSFT_ScheduledTask'
    }

    It 'Get-WauTaskHealth reports a missing task without writing an error into the transcript' {
        Mock Get-ScheduledTaskInfo { throw 'should not read run info for a missing task' }
        $script:health = $null

        $transcript = Get-TranscriptText { $script:health = Get-WauTaskHealth }

        $script:health.Exists | Should -BeFalse
        $script:health.Healthy | Should -BeFalse
        # Known to be missing, not unknown: the uninstall-and-re-run advice applies.
        $script:health.CheckFailed | Should -BeFalse
        $script:health.Problem | Should -Be 'its scheduled task \WAU\Winget-AutoUpdate does not exist'
        $transcript | Should -Not -Match 'TerminatingError'
    }
}

Describe 'Get-WauTaskHealth (review finding P3-36)' {
    BeforeEach {
        $script:weekly = New-TestTaskTrigger -ClassName 'MSFT_TaskWeeklyTrigger' -DaysOfWeek 4 -StartBoundary '2026-10-06T02:00:00'
        Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = 'Winget-AutoUpdate'; TaskPath = '\WAU\'; State = 'Ready'; Triggers = @($script:weekly) } }
        Mock Get-ScheduledTaskInfo { [pscustomobject]@{ LastRunTime = [datetime]'2026-09-29T02:00:05'; LastTaskResult = 0; NextRunTime = [datetime]'2026-10-06T02:00:00' } }
    }

    It 'is healthy when the task exists, is enabled and has an enabled trigger, and reports its last and next run' {
        $health = Get-WauTaskHealth

        $health.Healthy | Should -BeTrue
        $health.Exists | Should -BeTrue
        $health.CheckFailed | Should -BeFalse
        $health.Problem | Should -BeNullOrEmpty
        $health.State | Should -Be 'Ready'
        $health.Triggers | Should -Be @('Weekly on Tuesday from 2026-10-06T02:00:00')
        $health.LastRunTime | Should -Be ([datetime]'2026-09-29T02:00:05')
        $health.LastTaskResult | Should -Be 0
        $health.NextRunTime | Should -Be ([datetime]'2026-10-06T02:00:00')
        Should -Invoke Get-ScheduledTask -Times 1 -Exactly -ParameterFilter { $TaskPath -eq '\WAU\' -and $TaskName -eq 'Winget-AutoUpdate' }
    }

    It 'reads the task scheduler''s 1999-11-30 as never run, and stays healthy' {
        Mock Get-ScheduledTaskInfo { [pscustomobject]@{ LastRunTime = [datetime]'1999-11-30T00:00:00'; LastTaskResult = 267011; NextRunTime = [datetime]'2026-10-06T02:00:00' } }

        $health = Get-WauTaskHealth

        $health.Healthy | Should -BeTrue
        $health.LastRunTime | Should -BeNullOrEmpty
        $health.LastTaskResult | Should -Be 267011
    }

    It 'judges the task, not its last result: a failed last run stays healthy' {
        Mock Get-ScheduledTaskInfo { [pscustomobject]@{ LastRunTime = [datetime]'2026-09-29T02:00:05'; LastTaskResult = 1; NextRunTime = $null } }

        (Get-WauTaskHealth).Healthy | Should -BeTrue
    }

    It 'is not healthy when the task is disabled' {
        Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = 'Winget-AutoUpdate'; State = 'Disabled'; Triggers = @($script:weekly) } }

        $health = Get-WauTaskHealth

        $health.Healthy | Should -BeFalse
        $health.Exists | Should -BeTrue
        $health.CheckFailed | Should -BeFalse
        $health.Problem | Should -Be 'its scheduled task \WAU\Winget-AutoUpdate is disabled'
    }

    It 'is not healthy when the task has no enabled trigger (<Case>)' -ForEach @(
        @{ Case = 'no trigger at all'; WithDisabledTrigger = $false }
        @{ Case = 'only a disabled one'; WithDisabledTrigger = $true }
    ) {
        $script:triggers = @()
        if ($WithDisabledTrigger) {
            $script:triggers = @(New-TestTaskTrigger -ClassName 'MSFT_TaskWeeklyTrigger' -DaysOfWeek 4 -Enabled $false)
        }
        Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = 'Winget-AutoUpdate'; State = 'Ready'; Triggers = $script:triggers } }

        $health = Get-WauTaskHealth

        $health.Healthy | Should -BeFalse
        $health.CheckFailed | Should -BeFalse
        $health.Problem | Should -Be 'its scheduled task \WAU\Winget-AutoUpdate has no enabled trigger, so it never runs on its own'
    }

    It 'is not healthy, and says why, when the task scheduler cannot be queried (<Case>)' -ForEach @(
        @{ Case = 'a terminating error'; Terminating = $true }
        @{ Case = 'an error other than not found'; Terminating = $false }
    ) {
        $script:terminating = $Terminating
        Mock Get-ScheduledTask {
            if ($script:terminating) {
                throw 'Access is denied.'
            }
            Write-Error -Exception ([System.UnauthorizedAccessException]::new('Access is denied.')) -ErrorId 'HRESULT 0x80070005' -Category PermissionDenied
        }

        $health = Get-WauTaskHealth

        $health.Healthy | Should -BeFalse
        $health.Exists | Should -BeFalse
        # Unknown, not known to be broken: the callers word their advice differently.
        $health.CheckFailed | Should -BeTrue
        $health.Problem | Should -Be 'its scheduled task \WAU\Winget-AutoUpdate could not be checked (Access is denied.)'
    }

    It 'still judges the task when its run information cannot be read' {
        Mock Get-ScheduledTaskInfo { throw 'The system cannot find the file specified.' }

        $health = Get-WauTaskHealth

        $health.Healthy | Should -BeTrue
        $health.LastRunTime | Should -BeNullOrEmpty
        $health.LastTaskResult | Should -BeNullOrEmpty
    }
}

Describe 'Format-ScheduledTaskTrigger' {
    It 'Describes <Case>' -ForEach @(
        @{ Case = 'a weekly trigger with its days and start'; ClassName = 'MSFT_TaskWeeklyTrigger'; DaysOfWeek = 4; StartBoundary = '2026-10-06T02:00:00'; Enabled = $true; Expected = 'Weekly on Tuesday from 2026-10-06T02:00:00' }
        @{ Case = 'a weekly trigger on several days'; ClassName = 'MSFT_TaskWeeklyTrigger'; DaysOfWeek = 65; StartBoundary = $null; Enabled = $true; Expected = 'Weekly on Sunday, Saturday' }
        @{ Case = 'a disabled logon trigger'; ClassName = 'MSFT_TaskLogonTrigger'; DaysOfWeek = $null; StartBoundary = $null; Enabled = $false; Expected = 'Logon (disabled)' }
        @{ Case = 'a daily trigger'; ClassName = 'MSFT_TaskDailyTrigger'; DaysOfWeek = $null; StartBoundary = '2026-10-05T02:00:00'; Enabled = $true; Expected = 'Daily from 2026-10-05T02:00:00' }
    ) {
        $trigger = New-TestTaskTrigger -ClassName $ClassName -DaysOfWeek $DaysOfWeek -StartBoundary $StartBoundary -Enabled $Enabled
        Format-ScheduledTaskTrigger -Trigger $trigger | Should -Be $Expected
    }
}

Describe 'Write-WauTaskHealth (review finding P3-36)' {
    BeforeEach {
        $script:infos = @()
        Mock Write-Info { $script:infos += $Message }
        Mock Write-WarningMessage { }
        $script:hostLines = @()
        Mock Write-Host { $script:hostLines += "$Object" }
        $script:logPath = Join-Path $TestDrive 'updates.log'
        Mock Get-WauUpdatesLogPath { $script:logPath }
        Remove-Item -LiteralPath $script:logPath -ErrorAction SilentlyContinue
    }

    It 'Logs the task''s state, triggers, last run and result, and next run on one line' {
        $health = New-TestWauTaskHealth
        $health.LastRunTime = [datetime]'2026-09-29T02:00:05'
        $health.LastTaskResult = 0

        Write-WauTaskHealth -Health $health

        $script:infos | Should -Contain 'Winget-AutoUpdate task \WAU\Winget-AutoUpdate: state Ready; triggers: Weekly on Tuesday from 2026-10-06T02:00:00; last run: 2026-09-29 02:00, result 0x00000000 (success); next run: 2026-10-06 02:00.'
    }

    It 'Says when the task has not run yet' {
        Write-WauTaskHealth -Health (New-TestWauTaskHealth)

        $script:infos | Should -Contain 'Winget-AutoUpdate task \WAU\Winget-AutoUpdate: state Ready; triggers: Weekly on Tuesday from 2026-10-06T02:00:00; last run: never, result 0x00041303 (has not run yet); next run: 2026-10-06 02:00.'
    }

    It 'Prints the last 20 lines of WAU''s updates.log, each set off so the transcript parser never reads them as the installer''s' {
        Set-Content -LiteralPath $script:logPath -Value @(1..30 | ForEach-Object { "02:00:{0:D2} - line $_" -f $_ })

        Write-WauTaskHealth -Health (New-TestWauTaskHealth)

        ($script:infos -join "`n") | Should -Match ([regex]::Escape("The last 20 lines of Winget-AutoUpdate's log ($script:logPath):"))
        $script:hostLines.Count | Should -Be 20
        $script:hostLines[0] | Should -Be '    | 02:00:11 - line 11'
        $script:hostLines[-1] | Should -Be '    | 02:00:30 - line 30'
    }

    It 'Prints the log for a task that does not exist, without a task line' {
        Set-Content -LiteralPath $script:logPath -Value 'Summary:'

        Write-WauTaskHealth -Health (New-TestWauTaskHealth -Problem 'its scheduled task \WAU\Winget-AutoUpdate does not exist')

        ($script:infos -join "`n") | Should -Not -Match 'Winget-AutoUpdate task'
        $script:hostLines | Should -Be @('    | Summary:')
    }

    It 'Prints nothing more when WAU has no log yet' {
        Write-WauTaskHealth -Health (New-TestWauTaskHealth)

        $script:hostLines.Count | Should -Be 0
        @($script:infos).Count | Should -Be 1
    }
}

Describe 'Get-WauUpdatesLogPath' {
    It 'Uses the InstallLocation WAU''s MSI recorded' {
        # Through a script variable: the mock body would otherwise see the function's own local.
        $script:installLocation = Join-Path $TestDrive 'Winget-AutoUpdate'
        Mock Get-ItemProperty { [pscustomobject]@{ InstallLocation = "$script:installLocation " } }

        Get-WauUpdatesLogPath | Should -Be (Join-Path $script:installLocation 'logs\updates.log')
        Should -Invoke Get-ItemProperty -Times 1 -Exactly -ParameterFilter { $LiteralPath -eq 'HKLM:\SOFTWARE\Romanitho\Winget-AutoUpdate' }
    }

    It 'Falls back to the default folder under Program Files when the value cannot be read' {
        Mock Get-ItemProperty { }
        $savedProgramFiles = $env:ProgramFiles
        $env:ProgramFiles = Join-Path $TestDrive 'Program Files'
        try {
            Get-WauUpdatesLogPath | Should -Be (Join-Path (Join-Path $env:ProgramFiles 'Winget-AutoUpdate') 'logs\updates.log')
        }
        finally {
            $env:ProgramFiles = $savedProgramFiles
        }
    }
}

Describe 'New-WauMsiLogPath (review finding P3-37)' {
    It 'Names a log for each action and attempt in the run''s logs folder, creating it when missing' {
        $directory = Join-Path $TestDrive 'run-logs'
        Mock Get-InstallerLogDirectory { $directory }

        $path = New-WauMsiLogPath -Action uninstall -Attempt 2

        Split-Path -Parent $path | Should -Be $directory
        Split-Path -Leaf $path | Should -Match '^wau-msi-uninstall-\d{8}-\d{6}-2\.log$'
        Test-Path -LiteralPath $directory -PathType Container | Should -BeTrue
    }

    It 'Uses the installer''s logs folder under ProgramData, made safe first, when the run has no transcript (winget-app-uninstall.ps1)' {
        Mock Get-InstallerLogDirectory { $null }
        $logs = Join-Path $TestDrive 'ProgramData/winget-app-setup/logs'
        Mock Initialize-ProgramDataFolder { [void](New-Item -ItemType Directory -Path $logs -Force); $logs }

        $path = New-WauMsiLogPath -Action install

        Split-Path -Parent $path | Should -Be $logs
        Split-Path -Leaf $path | Should -Match '^wau-msi-install-\d{8}-\d{6}-1\.log$'
        Should -Invoke Initialize-ProgramDataFolder -Times 1 -Exactly -ParameterFilter { $ChildName -eq 'logs' -and $ReadableByUsers }
    }

    # wgt-gq8.46: msiexec writes the log with the run's elevated rights, so a link planted as the
    # logs folder would have it write into whatever the link points to.
    It 'Never names a log inside a link planted as the logs folder when the run has no transcript' {
        Mock Get-InstallerLogDirectory { $null }
        $savedProgramData = $env:ProgramData
        $env:ProgramData = Join-Path $TestDrive ('ProgramData-' + [guid]::NewGuid().ToString('N'))
        try {
            $baseDir = Join-Path $env:ProgramData 'winget-app-setup'
            [void](New-Item -ItemType Directory -Path $baseDir -Force)
            $victim = Join-Path $TestDrive ('victim-' + [guid]::NewGuid().ToString('N'))
            [void](New-Item -ItemType Directory -Path $victim)
            $linkType = 'SymbolicLink'
            if ($IsWindows) {
                $linkType = 'Junction'
            }
            [void](New-Item -ItemType $linkType -Path (Join-Path $baseDir 'logs') -Target $victim)
            Mock Set-RestrictedDirectoryAcl { }
            Mock Write-WarningMessage { }

            $path = New-WauMsiLogPath -Action uninstall

            $directory = Split-Path -Parent $path
            $directory | Should -Be (Join-Path $baseDir 'logs')
            ((Get-Item -LiteralPath $directory -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) | Should -Be 0
            Should -Invoke Set-RestrictedDirectoryAcl -Times 1 -Exactly -ParameterFilter { $Path -eq $directory -and $ReadableByUsers }
        }
        finally {
            $env:ProgramData = $savedProgramData
        }
    }

    It 'Returns no path when the logs folder cannot be made safe, so msiexec writes nothing there' {
        Mock Get-InstallerLogDirectory { $null }
        Mock Initialize-ProgramDataFolder { throw "'C:\ProgramData\winget-app-setup\logs' is a link (a junction or symbolic link), not a folder, and the link could not be removed: Access is denied." }

        New-WauMsiLogPath -Action uninstall | Should -BeNullOrEmpty
    }

    It 'Returns no path when the folder cannot be created, so msiexec is not given a log it cannot open' {
        Mock Get-InstallerLogDirectory { Join-Path $TestDrive 'not-creatable' }
        Mock New-Item { throw 'Access is denied.' }

        New-WauMsiLogPath -Action install | Should -BeNullOrEmpty
    }
}
