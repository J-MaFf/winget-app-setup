# ProgramDataFolder.Tests.ps1
# Tests for WingetAppSetup/Private/ProgramDataFolder.ps1 (wgt-gq8.46): an elevated or SYSTEM run
# never locks, writes into or deletes from %ProgramData%\winget-app-setup, or a fixed-name folder in
# it, through a junction or symbolic link a standard user planted. Real links in TestDrive (a
# junction on Windows, which needs no privilege; a symbolic link elsewhere) stand in for the planted
# ones, with ProgramData pointed into TestDrive. icacls cannot run off Windows, so
# Set-RestrictedDirectoryAcl and New-RestrictedDirectory are mocked there and run for real only in
# the Windows-only tests at the end.

BeforeDiscovery {
    # icacls /setowner needs an elevated administrator token.
    $script:IsWindowsAdmin = $false
    if ($IsWindows) {
        $script:IsWindowsAdmin = ([System.Security.Principal.WindowsPrincipal][System.Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    }
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    # A link to Target at Path: a junction on Windows, as a standard user plants one; a symbolic
    # link elsewhere, the same kind of link to .NET.
    function New-TestDirectoryLink {
        param ([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Target)
        $linkType = 'SymbolicLink'
        if ($IsWindows) {
            $linkType = 'Junction'
        }
        [void](New-Item -ItemType $linkType -Path $Path -Target $Target -ErrorAction Stop)
    }

    # A folder another account owns, with one file in it, standing in for System32 or another
    # user's profile: what a planted link points at.
    function New-TestVictimFolder {
        $path = Join-Path $TestDrive ('victim-' + [guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $path)
        Set-Content -LiteralPath (Join-Path $path 'keep.txt') -Value 'not the installer''s'
        return $path
    }

    # What a test can compare before and after: the names of the files, and the access list where
    # one can be read.
    function Get-TestFolderState {
        param ([Parameter(Mandatory = $true)][string]$Path)
        $sddl = $null
        if ($IsWindows) {
            $sddl = (Get-Acl -LiteralPath $Path).Sddl
        }
        return [pscustomobject]@{
            Files = (@(Get-ChildItem -LiteralPath $Path -Force | ForEach-Object { $_.Name } | Sort-Object) -join ',')
            Sddl  = $sddl
        }
    }

    function Test-TestIsLink {
        param ([Parameter(Mandatory = $true)][string]$Path)
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        return ($null -ne $item -and ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
    }

}

Describe 'Get-FileSystemEntryAttribute and Test-FileSystemLink' {
    It 'Reads the entry itself: a folder, nothing, a link and a link whose target is gone' {
        $folder = New-TestVictimFolder
        $link = Join-Path $TestDrive ('link-' + [guid]::NewGuid().ToString('N'))
        New-TestDirectoryLink -Path $link -Target $folder
        $danglingTarget = New-TestVictimFolder
        $dangling = Join-Path $TestDrive ('dangling-' + [guid]::NewGuid().ToString('N'))
        New-TestDirectoryLink -Path $dangling -Target $danglingTarget
        Remove-Item -LiteralPath $danglingTarget -Recurse -Force

        (Get-FileSystemEntryAttribute -Path $folder) -band [System.IO.FileAttributes]::Directory | Should -Not -Be 0
        Get-FileSystemEntryAttribute -Path (Join-Path $TestDrive 'missing') | Should -BeNullOrEmpty
        Get-FileSystemEntryAttribute -Path (Join-Path $TestDrive 'missing/below') | Should -BeNullOrEmpty
        Test-FileSystemLink -Path $folder | Should -BeFalse
        Test-FileSystemLink -Path (Join-Path $TestDrive 'missing') | Should -BeFalse
        Test-FileSystemLink -Path $link | Should -BeTrue
        Test-FileSystemLink -Path $dangling | Should -BeTrue
    }
}

Describe 'Remove-FileSystemLink' {
    It 'Removes a link and leaves what it points to as it was' {
        $victim = New-TestVictimFolder
        $before = Get-TestFolderState -Path $victim
        $link = Join-Path $TestDrive ('link-' + [guid]::NewGuid().ToString('N'))
        New-TestDirectoryLink -Path $link -Target $victim

        Remove-FileSystemLink -Path $link

        Get-FileSystemEntryAttribute -Path $link | Should -BeNullOrEmpty
        $after = Get-TestFolderState -Path $victim
        $after.Files | Should -Be $before.Files
        $after.Sddl | Should -Be $before.Sddl
    }

    It 'Removes a link whose target is gone' {
        $target = New-TestVictimFolder
        $link = Join-Path $TestDrive ('dangling-' + [guid]::NewGuid().ToString('N'))
        New-TestDirectoryLink -Path $link -Target $target
        Remove-Item -LiteralPath $target -Recurse -Force

        Remove-FileSystemLink -Path $link

        Get-FileSystemEntryAttribute -Path $link | Should -BeNullOrEmpty
    }

    It 'Refuses a real folder and leaves it and its files alone' {
        $folder = New-TestVictimFolder

        { Remove-FileSystemLink -Path $folder } | Should -Throw "*'$folder' is not a link.*"

        Test-Path -LiteralPath (Join-Path $folder 'keep.txt') | Should -BeTrue
    }
}

Describe 'Initialize-ProgramDataFolder (wgt-gq8.46)' {
    BeforeEach {
        $script:savedProgramData = $env:ProgramData
        $env:ProgramData = Join-Path $TestDrive ('ProgramData-' + [guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $env:ProgramData)
        $script:baseDirectory = Join-Path $env:ProgramData 'winget-app-setup'
        $script:logsDirectory = Join-Path $script:baseDirectory 'logs'

        # Every folder icacls would be pointed at, and whether it was a link then.
        $script:locked = [System.Collections.Generic.List[object]]::new()
        Mock Set-RestrictedDirectoryAcl {
            $script:locked.Add([pscustomobject]@{ Path = $Path; IsLink = (Test-TestIsLink -Path $Path); ReadableByUsers = [bool]$ReadableByUsers })
        }
        Mock New-RestrictedDirectory { [void](New-Item -ItemType Directory -Path $Path) }
        $script:warnings = @()
        Mock Write-WarningMessage { $script:warnings += $Message }
    }

    AfterEach {
        $env:ProgramData = $script:savedProgramData
    }

    It 'Creates a missing base folder locked from the start and the logs folder inside it, locks both in that order, and returns the logs folder' {
        $result = Initialize-ProgramDataFolder -ChildName 'logs' -ReadableByUsers

        $result | Should -Be $script:logsDirectory
        Test-Path -LiteralPath $script:logsDirectory -PathType Container | Should -BeTrue
        Should -Invoke New-RestrictedDirectory -Times 1 -Exactly -ParameterFilter { $Path -eq $script:baseDirectory }
        @($script:locked | ForEach-Object { $_.Path }) | Should -Be @($script:baseDirectory, $script:logsDirectory)
        @($script:locked | ForEach-Object { $_.ReadableByUsers }) | Should -Be @($false, $true)
        $script:warnings | Should -BeNullOrEmpty
    }

    It 'Locks only the base folder without a child name, and locks folders that are already there' {
        [void](New-Item -ItemType Directory -Path $script:baseDirectory)

        Initialize-ProgramDataFolder | Should -Be $script:baseDirectory

        Should -Invoke New-RestrictedDirectory -Times 0 -Exactly
        @($script:locked | ForEach-Object { $_.Path }) | Should -Be @($script:baseDirectory)
    }

    It 'Removes a link planted as the base folder without touching its target, and locks a real folder in its place' {
        $victim = New-TestVictimFolder
        $before = Get-TestFolderState -Path $victim
        New-TestDirectoryLink -Path $script:baseDirectory -Target $victim

        $result = Initialize-ProgramDataFolder -ChildName 'logs' -ReadableByUsers

        $result | Should -Be $script:logsDirectory
        Test-TestIsLink -Path $script:baseDirectory | Should -BeFalse
        Test-Path -LiteralPath $script:logsDirectory -PathType Container | Should -BeTrue
        @($script:locked | Where-Object { $_.IsLink }) | Should -BeNullOrEmpty
        @($script:locked | ForEach-Object { $_.Path }) | Should -Be @($script:baseDirectory, $script:logsDirectory)
        $after = Get-TestFolderState -Path $victim
        $after.Files | Should -Be $before.Files
        $after.Sddl | Should -Be $before.Sddl
        @($script:warnings | Where-Object { $_ -like "'$($script:baseDirectory)' was a link (a junction or symbolic link), not a folder.*" }).Count | Should -Be 1
    }

    It 'Removes a link planted as the logs folder inside a real base folder, and leaves its target alone' {
        [void](New-Item -ItemType Directory -Path $script:baseDirectory)
        $victim = New-TestVictimFolder
        $before = Get-TestFolderState -Path $victim
        New-TestDirectoryLink -Path $script:logsDirectory -Target $victim

        Initialize-ProgramDataFolder -ChildName 'logs' -ReadableByUsers | Should -Be $script:logsDirectory

        Test-TestIsLink -Path $script:logsDirectory | Should -BeFalse
        @(Get-ChildItem -LiteralPath $script:logsDirectory -Force) | Should -BeNullOrEmpty
        @($script:locked | Where-Object { $_.IsLink }) | Should -BeNullOrEmpty
        (Get-TestFolderState -Path $victim).Files | Should -Be $before.Files
        @($script:warnings | Where-Object { $_ -like "'$($script:logsDirectory)' was a link*" }).Count | Should -Be 1
    }

    It 'Stops with the error id DirectoryIsLink, locking and creating nothing, when a planted link cannot be removed' {
        $victim = New-TestVictimFolder
        New-TestDirectoryLink -Path $script:baseDirectory -Target $victim
        Mock Remove-FileSystemLink { throw 'Access is denied.' }

        { Initialize-ProgramDataFolder -ChildName 'logs' -ReadableByUsers } |
            Should -Throw -ErrorId 'DirectoryIsLink' -ExpectedMessage "*'$($script:baseDirectory)' is a link (a junction or symbolic link), not a folder, and the link could not be removed: Access is denied. Nothing was written through it.*"

        $script:locked | Should -BeNullOrEmpty
        Should -Invoke New-RestrictedDirectory -Times 0 -Exactly
        Test-Path -LiteralPath (Join-Path $victim 'logs') | Should -BeFalse
    }

    It 'Refuses a file in the folder''s place, without locking anything' {
        Set-Content -LiteralPath $script:baseDirectory -Value 'a file'

        { Initialize-ProgramDataFolder -ChildName 'logs' } | Should -Throw "*'$($script:baseDirectory)' is a file, not a folder.*"

        $script:locked | Should -BeNullOrEmpty
    }

    It 'Passes on a failure to lock a folder with its error id, and goes no further' {
        Mock Set-RestrictedDirectoryAcl {
            throw [System.Management.Automation.ErrorRecord]::new([System.InvalidOperationException]::new('icacls failed.'), 'RestrictedDirectoryAclFailed', [System.Management.Automation.ErrorCategory]::SecurityError, $Path)
        }

        { Initialize-ProgramDataFolder -ChildName 'logs' } | Should -Throw -ErrorId 'RestrictedDirectoryAclFailed'

        Test-Path -LiteralPath $script:logsDirectory | Should -BeFalse
    }

    It 'Throws when ProgramData is not set' {
        $env:ProgramData = ''

        { Initialize-ProgramDataFolder -ChildName 'logs' } | Should -Throw '*ProgramData environment variable is not set*'
    }

    It 'Accepts only a plain folder name as the child' {
        { Initialize-ProgramDataFolder -ChildName '..\Windows' } | Should -Throw '*ChildName*'
    }
}

# Real icacls and access lists, on Windows as an administrator (icacls /setowner needs one). These
# check what the mocks above cannot: that icacls /L leaves a junction's target alone, and that a
# planted junction's target keeps its access list through the whole sequence.
Describe 'ProgramData folders on real Windows (wgt-gq8.46)' -Skip:(-not $script:IsWindowsAdmin) {
    BeforeEach {
        Mock Write-WarningMessage { }
    }

    It 'Changes neither the owner nor the access list of a junction''s target when the folder is swapped for a junction after the check (icacls /L), and refuses it' {
        $victim = New-TestVictimFolder
        $before = Get-TestFolderState -Path $victim
        $link = Join-Path $TestDrive ('swapped-' + [guid]::NewGuid().ToString('N'))
        New-TestDirectoryLink -Path $link -Target $victim
        # The check before icacls saw a real folder; the junction appeared before icacls ran.
        $script:linkChecks = 0
        Mock Test-FileSystemLink {
            $script:linkChecks++
            return ($script:linkChecks -gt 1)
        }

        { Set-RestrictedDirectoryAcl -Path $link } | Should -Throw -ErrorId 'DirectoryIsLink'

        $after = Get-TestFolderState -Path $victim
        $after.Sddl | Should -Be $before.Sddl
        $after.Files | Should -Be $before.Files
    }

    It 'Leaves the logs folder owned by Administrators, protected, changeable by SYSTEM and Administrators only and readable by Users, down to a file already in it (icacls /L still passes the grant on)' {
        $folder = Join-Path $TestDrive ('logs-' + [guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $folder)
        $file = Join-Path $folder 'install-20261006-120000.log'
        Set-Content -LiteralPath $file -Value 'a transcript'

        { Set-RestrictedDirectoryAcl -Path $folder -ReadableByUsers } | Should -Not -Throw

        $summary = Get-DirectoryAccessSummary -Path $folder
        $summary.OwnerSid | Should -Be 'S-1-5-32-544'
        $summary.InheritanceProtected | Should -BeTrue
        @($summary.AccessRules | ForEach-Object { $_.Sid } | Sort-Object -Unique) | Should -Be @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-32-545')
        $fileUsers = @((Get-DirectoryAccessSummary -Path $file).AccessRules | Where-Object { $_.Sid -eq 'S-1-5-32-545' })
        $fileUsers.Count | Should -BeGreaterThan 0
        @($fileUsers | Where-Object { -not $_.IsInherited }).Count | Should -Be 0
    }

    It 'Removes a junction planted as the base folder, keeps its target''s access list, and locks a real folder in its place' {
        $savedProgramData = $env:ProgramData
        $env:ProgramData = Join-Path $TestDrive ('ProgramData-' + [guid]::NewGuid().ToString('N'))
        try {
            [void](New-Item -ItemType Directory -Path $env:ProgramData)
            $victim = New-TestVictimFolder
            $before = Get-TestFolderState -Path $victim
            $baseDirectory = Join-Path $env:ProgramData 'winget-app-setup'
            New-TestDirectoryLink -Path $baseDirectory -Target $victim

            $logs = Initialize-ProgramDataFolder -ChildName 'logs' -ReadableByUsers

            Test-TestIsLink -Path $baseDirectory | Should -BeFalse
            $after = Get-TestFolderState -Path $victim
            $after.Sddl | Should -Be $before.Sddl
            $after.Files | Should -Be $before.Files
            (Get-DirectoryAccessSummary -Path $baseDirectory).OwnerSid | Should -Be 'S-1-5-32-544'
            @((Get-DirectoryAccessSummary -Path $baseDirectory).AccessRules | Where-Object { $_.Sid -notin @('S-1-5-18', 'S-1-5-32-544') }) | Should -BeNullOrEmpty
            @((Get-DirectoryAccessSummary -Path $logs).AccessRules | Where-Object { $_.Sid -eq 'S-1-5-32-545' }).Count | Should -BeGreaterThan 0
        }
        finally {
            $env:ProgramData = $savedProgramData
        }
    }
}
