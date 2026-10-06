# AppUninstall.Tests.ps1
# Tests for the quietUninstall path of WingetAppSetup/Private/AppUninstall.ps1 (wgt-gq8.61): a
# catalog entry with quietUninstall (Google Drive) is removed by running the uninstaller its HKLM
# uninstall entry names, with the catalog's switches, never through `winget uninstall`, which runs
# that entry's bare UninstallString and waits for a click. The rest of the uninstall step, and
# Invoke-WingetUninstall, are tested in Uninstall.Tests.ps1.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')

    $script:driveProductCode = '{6BBAE539-2232-434A-A4E5-9A33560C6283}'
    $script:savedEnvironment = @{}
    foreach ($name in @('ProgramW6432', 'ProgramFiles', 'ProgramFiles(x86)')) {
        $script:savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
    }

    # Points ProgramW6432 and ProgramFiles(x86) at folders in TestDrive and puts an uninstall.exe
    # where Drive keeps its own. Returns that file's full path.
    function Initialize-TestProgramFiles {
        $script:programFiles = [System.IO.Path]::GetFullPath((Join-Path $TestDrive 'Program Files'))
        $script:programFilesX86 = [System.IO.Path]::GetFullPath((Join-Path $TestDrive 'Program Files (x86)'))
        $folder = Join-Path (Join-Path (Join-Path $script:programFiles 'Google') 'Drive File Stream') '131.0.2.0'
        [void](New-Item -ItemType Directory -Path $folder -Force)
        [void](New-Item -ItemType Directory -Path $script:programFilesX86 -Force)
        $exe = [System.IO.Path]::GetFullPath((Join-Path $folder 'uninstall.exe'))
        Set-Content -LiteralPath $exe -Value 'not a real program'
        [Environment]::SetEnvironmentVariable('ProgramW6432', $script:programFiles)
        [Environment]::SetEnvironmentVariable('ProgramFiles(x86)', $script:programFilesX86)
        return $exe
    }

    function Restore-TestEnvironment {
        foreach ($name in @($script:savedEnvironment.Keys)) {
            [Environment]::SetEnvironmentVariable($name, $script:savedEnvironment[$name])
        }
    }

    # A file in TestDrive, outside both Program Files folders, by its path segments.
    function New-TestFileElsewhere {
        param ([string[]]$Segment)
        $path = $TestDrive
        foreach ($part in $Segment) {
            $path = Join-Path $path $part
        }
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force)
        Set-Content -LiteralPath $path -Value 'not a real program'
        return [System.IO.Path]::GetFullPath($path)
    }

    function New-TestUninstallEntry {
        param (
            [string]$View = 'Registry64',
            [AllowNull()][string]$UninstallString
        )
        [pscustomobject]@{ View = $View; UninstallString = $UninstallString }
    }

    # A Test-WingetPackageInstalled answer.
    function New-TestCheckResult {
        param ([bool]$Installed)
        $exitCode = -1978335212
        if ($Installed) {
            $exitCode = 0
        }
        @{ Installed = $Installed; TimedOut = $false; LaunchFailed = $false; LaunchError = $null; CheckFailed = $false; ExitCode = $exitCode }
    }
}

Describe 'Get-UninstallStringProgramPath (wgt-gq8.61)' {
    It 'Returns the program of <Case>' -ForEach @(
        @{ Case = 'a quoted path with spaces'; Value = '"C:\Program Files\Google\Drive File Stream\131.0.2.0\uninstall.exe"'; Expected = 'C:\Program Files\Google\Drive File Stream\131.0.2.0\uninstall.exe' }
        @{ Case = 'a quoted path followed by arguments'; Value = '  "C:\Program Files\Contoso\uninstall.exe" --uninstall --quiet '; Expected = 'C:\Program Files\Contoso\uninstall.exe' }
        @{ Case = 'an unquoted string, taken whole'; Value = 'C:\Program Files\Contoso\uninstall.exe --uninstall'; Expected = 'C:\Program Files\Contoso\uninstall.exe --uninstall' }
    ) {
        Get-UninstallStringProgramPath -UninstallString $Value | Should -Be $Expected
    }

    It 'Returns nothing for <Case>' -ForEach @(
        @{ Case = 'no string'; Value = $null }
        @{ Case = 'an empty string'; Value = '' }
        @{ Case = 'white space'; Value = '   ' }
        @{ Case = 'a quote that is not closed'; Value = '"C:\Program Files\Contoso\uninstall.exe' }
        @{ Case = 'empty quotes'; Value = '"" --uninstall' }
    ) {
        Get-UninstallStringProgramPath -UninstallString $Value | Should -BeNullOrEmpty
    }
}

Describe 'Get-AppQuietUninstallCommand (wgt-gq8.61)' {
    BeforeEach {
        $script:exe = Initialize-TestProgramFiles
        $script:app = @{ name = 'Google.GoogleDrive'; quietUninstall = @{ productCode = $script:driveProductCode; arguments = @('--silent', '--force_stop') } }
        $script:entries = @{ Registry64 = (New-TestUninstallEntry -UninstallString ('"{0}"' -f $script:exe)); Registry32 = $null }
        Mock Get-AppUninstallEntry { $script:entries[$View] }
    }

    AfterEach {
        Restore-TestEnvironment
    }

    It 'Finds the program the 64-bit uninstall entry names, and runs it with the catalog''s switches instead of the entry''s' {
        $script:entries.Registry64 = New-TestUninstallEntry -UninstallString ('"{0}" --uninstall' -f $script:exe)

        $command = Get-AppQuietUninstallCommand -App $script:app

        $command.Problem | Should -BeNullOrEmpty
        $command.FilePath | Should -Be $script:exe
        $command.Arguments | Should -Be @('--silent', '--force_stop')
        $command.CommandLine | Should -Be ('"{0}" --silent --force_stop' -f $script:exe)
        Should -Invoke Get-AppUninstallEntry -Times 1 -Exactly -ParameterFilter { $ProductCode -eq $script:driveProductCode -and $View -eq 'Registry64' }
        Should -Invoke Get-AppUninstallEntry -Times 0 -Exactly -ParameterFilter { $View -eq 'Registry32' }
    }

    It 'Reads the 32-bit (WOW6432Node) entry when the 64-bit view has none' {
        $x86Folder = Join-Path (Join-Path $script:programFilesX86 'Contoso') 'App'
        [void](New-Item -ItemType Directory -Path $x86Folder -Force)
        $x86Exe = [System.IO.Path]::GetFullPath((Join-Path $x86Folder 'uninstall.exe'))
        Set-Content -LiteralPath $x86Exe -Value 'not a real program'
        $script:entries = @{ Registry64 = $null; Registry32 = (New-TestUninstallEntry -View Registry32 -UninstallString ('"{0}" /uninstall' -f $x86Exe)) }

        $command = Get-AppQuietUninstallCommand -App $script:app

        $command.Problem | Should -BeNullOrEmpty
        $command.FilePath | Should -Be $x86Exe
        $command.CommandLine | Should -Be ('"{0}" --silent --force_stop' -f $x86Exe)
    }

    It 'Takes ProgramFiles when there is no ProgramW6432 (32-bit Windows)' {
        [Environment]::SetEnvironmentVariable('ProgramW6432', $null)
        [Environment]::SetEnvironmentVariable('ProgramFiles', $script:programFiles)
        [Environment]::SetEnvironmentVariable('ProgramFiles(x86)', $null)

        $command = Get-AppQuietUninstallCommand -App $script:app

        $command.Problem | Should -BeNullOrEmpty
        $command.FilePath | Should -Be $script:exe
    }

    It 'Trusts ProgramW6432 over ProgramFiles, which names the x86 folder in a 32-bit process' {
        $elsewhere = New-TestFileElsewhere -Segment @('Elsewhere', 'Google', 'uninstall.exe')
        [Environment]::SetEnvironmentVariable('ProgramFiles', (Join-Path $TestDrive 'Elsewhere'))
        $script:entries.Registry64 = New-TestUninstallEntry -UninstallString ('"{0}"' -f $elsewhere)

        $command = Get-AppQuietUninstallCommand -App $script:app

        $command.FilePath | Should -BeNullOrEmpty
        $command.Problem | Should -Match 'which is not under Program Files or Program Files \(x86\)$'
    }

    It 'Refuses an entry that is not there in either view' {
        $script:entries = @{ Registry64 = $null; Registry32 = $null }

        $command = Get-AppQuietUninstallCommand -App $script:app

        $command.FilePath | Should -BeNullOrEmpty
        $command.CommandLine | Should -BeNullOrEmpty
        $command.Problem | Should -Be 'its own uninstaller was not found: there is no uninstall entry {6BBAE539-2232-434A-A4E5-9A33560C6283} under HKLM'
        Should -Invoke Get-AppUninstallEntry -Times 2 -Exactly
    }

    It 'Refuses an entry without an UninstallString' {
        $script:entries.Registry64 = New-TestUninstallEntry -UninstallString $null

        $command = Get-AppQuietUninstallCommand -App $script:app

        $command.FilePath | Should -BeNullOrEmpty
        $command.Problem | Should -Be 'its own uninstaller was not found: its uninstall entry {6BBAE539-2232-434A-A4E5-9A33560C6283} has no UninstallString'
    }

    It 'Refuses an entry it cannot read, and says why' {
        Mock Get-AppUninstallEntry { throw [System.UnauthorizedAccessException]::new('Access to the registry key is denied.') }

        $command = Get-AppQuietUninstallCommand -App $script:app

        $command.FilePath | Should -BeNullOrEmpty
        $command.Problem | Should -Be 'its own uninstaller was not found: its uninstall entry {6BBAE539-2232-434A-A4E5-9A33560C6283} could not be read (Access to the registry key is denied)'
    }

    It 'Refuses a program outside Program Files, even when it exists' {
        $outside = New-TestFileElsewhere -Segment @('Users', 'Public', 'uninstall.exe')
        $script:entries.Registry64 = New-TestUninstallEntry -UninstallString ('"{0}"' -f $outside)

        $command = Get-AppQuietUninstallCommand -App $script:app

        $command.FilePath | Should -BeNullOrEmpty
        $command.Problem | Should -Be ("its own uninstaller was not found: its uninstall entry {6BBAE539-2232-434A-A4E5-9A33560C6283} names '`"$outside`"', which is not under Program Files or Program Files (x86)")
    }

    It 'Refuses a path that climbs out of Program Files with ..' {
        $outside = New-TestFileElsewhere -Segment @('Users', 'Public', 'uninstall.exe')
        $separator = [System.IO.Path]::DirectorySeparatorChar
        $climbing = $script:programFiles + $separator + '..' + $separator + 'Users' + $separator + 'Public' + $separator + 'uninstall.exe'
        $script:entries.Registry64 = New-TestUninstallEntry -UninstallString ('"{0}"' -f $climbing)

        $command = Get-AppQuietUninstallCommand -App $script:app

        Test-Path -LiteralPath $outside | Should -BeTrue
        $command.FilePath | Should -BeNullOrEmpty
        $command.Problem | Should -Match 'which is not a full path to a program$'
    }

    It 'Refuses <Case>' -ForEach @(
        @{ Case = 'a relative path'; Kind = 'relative'; Pattern = 'which is not a full path to a program$' }
        @{ Case = 'a quote that is not closed'; Kind = 'unclosed'; Pattern = 'which is not a full path to a program$' }
        @{ Case = 'an unquoted path with arguments, which names no file'; Kind = 'unquoted'; Pattern = 'which is not an \.exe file$' }
        @{ Case = 'a program that is not an .exe'; Kind = 'script'; Pattern = 'which is not an \.exe file$' }
        @{ Case = 'an .exe that does not exist'; Kind = 'missing'; Pattern = 'which does not exist$' }
    ) {
        switch ($Kind) {
            'relative' { $value = 'uninstall.exe' }
            'unclosed' { $value = '"' + $script:exe }
            'unquoted' { $value = $script:exe + ' --uninstall' }
            'script' {
                $batchFile = [System.IO.Path]::GetFullPath((Join-Path $script:programFiles 'uninstall.cmd'))
                Set-Content -LiteralPath $batchFile -Value '@echo off'
                $value = '"{0}"' -f $batchFile
            }
            'missing' { $value = '"{0}"' -f [System.IO.Path]::GetFullPath((Join-Path $script:programFiles 'gone.exe')) }
        }
        $script:entries.Registry64 = New-TestUninstallEntry -UninstallString $value

        $command = Get-AppQuietUninstallCommand -App $script:app

        $command.FilePath | Should -BeNullOrEmpty
        $command.CommandLine | Should -BeNullOrEmpty
        $command.Problem | Should -Match '^its own uninstaller was not found: its uninstall entry \{6BBAE539-2232-434A-A4E5-9A33560C6283\} names '
        $command.Problem | Should -Match $Pattern
    }
}

Describe 'Wait-AppUninstallEntryRemoved (wgt-gq8.61)' {
    BeforeEach {
        Mock Start-Sleep { }
        # How many more checks still find the 64-bit entry.
        $script:checksLeft = 0
        Mock Get-AppUninstallEntry {
            if ($View -eq 'Registry64' -and $script:checksLeft -gt 0) {
                $script:checksLeft--
                return (New-TestUninstallEntry -UninstallString 'x')
            }
            return $null
        }
    }

    It 'Returns at once, without waiting, when the entry is already gone' {
        Wait-AppUninstallEntryRemoved -ProductCode $script:driveProductCode -TimeoutSeconds 900 | Should -BeTrue

        Should -Invoke Start-Sleep -Times 0 -Exactly
        Should -Invoke Get-AppUninstallEntry -Times 1 -Exactly -ParameterFilter { $View -eq 'Registry64' -and $ProductCode -eq $script:driveProductCode }
        Should -Invoke Get-AppUninstallEntry -Times 1 -Exactly -ParameterFilter { $View -eq 'Registry32' }
    }

    It 'Checks every 5 seconds until the entry is gone' {
        $script:checksLeft = 3

        Wait-AppUninstallEntryRemoved -ProductCode $script:driveProductCode -TimeoutSeconds 900 | Should -BeTrue

        Should -Invoke Start-Sleep -Times 3 -Exactly -ParameterFilter { $Seconds -eq 5 }
        Should -Invoke Get-AppUninstallEntry -Times 4 -Exactly -ParameterFilter { $View -eq 'Registry64' }
    }

    It 'Gives up once the time is up' {
        $script:checksLeft = 1000

        Wait-AppUninstallEntryRemoved -ProductCode $script:driveProductCode -TimeoutSeconds 12 | Should -BeFalse

        Should -Invoke Start-Sleep -Times 2 -Exactly
        Should -Invoke Get-AppUninstallEntry -Times 3 -Exactly -ParameterFilter { $View -eq 'Registry64' }
    }

    It 'Checks once when no time is left' {
        $script:checksLeft = 1000

        Wait-AppUninstallEntryRemoved -ProductCode $script:driveProductCode -TimeoutSeconds -3 | Should -BeFalse

        Should -Invoke Start-Sleep -Times 0 -Exactly
        Should -Invoke Get-AppUninstallEntry -Times 1 -Exactly -ParameterFilter { $View -eq 'Registry64' }
    }

    It 'Counts a 32-bit entry as still there' {
        Mock Get-AppUninstallEntry { if ($View -eq 'Registry32') { New-TestUninstallEntry -View Registry32 -UninstallString 'x' } }

        Wait-AppUninstallEntryRemoved -ProductCode $script:driveProductCode -TimeoutSeconds 5 | Should -BeFalse

        Should -Invoke Start-Sleep -Times 1 -Exactly
    }

    It 'Counts an entry it cannot read as still there' {
        Mock Get-AppUninstallEntry { throw 'Access to the registry key is denied.' }

        Wait-AppUninstallEntryRemoved -ProductCode $script:driveProductCode -TimeoutSeconds 5 | Should -BeFalse
    }
}

Describe 'Uninstall-CatalogApp for an entry with quietUninstall (wgt-gq8.61)' {
    BeforeEach {
        $script:exe = Initialize-TestProgramFiles
        $script:drive = @{ name = 'Google.GoogleDrive'; quietUninstall = @{ productCode = $script:driveProductCode; arguments = @('--silent', '--force_stop') } }
        $script:expectedCommand = '"{0}" --silent --force_stop' -f $script:exe
        Mock Write-Info { }
        Mock Start-Sleep { }

        # The machine: the entry is there until the uninstaller has run, then for
        # $script:checksAfterExit more checks; winget lists the app until the uninstaller has run.
        $script:removed = $false
        $script:checksAfterExit = 0
        Mock Get-AppUninstallEntry {
            if ($View -ne 'Registry64') {
                return $null
            }
            if ($script:removed) {
                if ($script:checksAfterExit -le 0) {
                    return $null
                }
                $script:checksAfterExit--
            }
            New-TestUninstallEntry -UninstallString ('"{0}"' -f $script:exe)
        }
        Mock Test-WingetPackageInstalled { New-TestCheckResult -Installed (-not $script:removed) }
        $script:exitCode = 0
        Mock Invoke-ExternalProcess { $script:removed = $true; New-TestProcessResult -ExitCode $script:exitCode }
        Mock Invoke-WingetProcess { New-TestProcessResult -ExitCode 0 }
    }

    AfterEach {
        Restore-TestEnvironment
    }

    It 'Runs the uninstaller its entry names with exactly the catalog''s switches, under the uninstall limit, and never winget uninstall' {
        $result = Uninstall-CatalogApp -App $script:drive

        $result.Status | Should -Be 'Uninstalled'
        $result.RestartRequired | Should -BeFalse
        $result.Command | Should -Be $script:expectedCommand
        Should -Invoke Invoke-ExternalProcess -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq $script:exe -and @($ArgumentList).Count -eq 2 -and $ArgumentList[0] -ceq '--silent' -and $ArgumentList[1] -ceq '--force_stop' -and
            $TimeoutSeconds -eq (Get-ProcessTimeoutSeconds -Operation WingetUninstall)
        }
        Should -Invoke Invoke-ExternalProcess -Times 1 -Exactly
        Should -Invoke Invoke-WingetProcess -Times 0 -Exactly
        # Installed before, and no longer listed after.
        Should -Invoke Test-WingetPackageInstalled -Times 2 -Exactly -ParameterFilter { $PackageId -eq 'Google.GoogleDrive' }
    }

    It 'Waits for the uninstall entry to go: the uninstaller can hand its work to a copy of itself and exit' {
        $script:checksAfterExit = 2

        $result = Uninstall-CatalogApp -App $script:drive

        $result.Status | Should -Be 'Uninstalled'
        Should -Invoke Start-Sleep -Times 2 -Exactly -ParameterFilter { $Seconds -eq 5 }
    }

    It 'Fails, UninstallVerifyFailed, when the entry is still there once the rest of the limit has run out' {
        Mock Wait-AppUninstallEntryRemoved { $false }
        Mock Invoke-ExternalProcess {
            $script:removed = $true
            $run = New-TestProcessResult -ExitCode 0
            $run.DurationSeconds = 40.2
            $run
        }

        $result = Uninstall-CatalogApp -App $script:drive

        $result.Status | Should -Be 'Failed'
        $result.FailureReason | Should -Be 'UninstallVerifyFailed'
        $result.Reason | Should -Be "its uninstaller 'uninstall.exe' exited with 0, but its uninstall entry {6BBAE539-2232-434A-A4E5-9A33560C6283} was still there when the 15-minute limit ran out"
        # What is left of the 15 minutes after the uninstaller's 41 seconds.
        Should -Invoke Wait-AppUninstallEntryRemoved -Times 1 -Exactly -ParameterFilter { $ProductCode -eq $script:driveProductCode -and $TimeoutSeconds -eq 859 }
        Should -Invoke Test-WingetPackageInstalled -Times 1 -Exactly
    }

    It 'Fails, UninstallVerifyFailed, when the entry is gone but winget still lists the app' {
        Mock Test-WingetPackageInstalled { New-TestCheckResult -Installed $true }

        $result = Uninstall-CatalogApp -App $script:drive

        $result.Status | Should -Be 'Failed'
        $result.FailureReason | Should -Be 'UninstallVerifyFailed'
        $result.Reason | Should -Be "its uninstaller 'uninstall.exe' exited with 0 and its uninstall entry is gone, but winget still lists it"
    }

    It 'Fails, UninstallVerifyFailed, when winget cannot say afterwards whether it still lists the app' {
        Mock Test-WingetPackageInstalled {
            if ($script:removed) {
                return @{ Installed = $false; TimedOut = $true; LaunchFailed = $false; LaunchError = $null; CheckFailed = $false; ExitCode = $null }
            }
            New-TestCheckResult -Installed $true
        }

        $result = Uninstall-CatalogApp -App $script:drive

        $result.FailureReason | Should -Be 'UninstallVerifyFailed'
        $result.Reason | Should -Be "its uninstaller 'uninstall.exe' exited with 0 and its uninstall entry is gone, but whether winget still lists it could not be checked: 'winget list' did not answer within 15 seconds"
    }

    It 'Counts exit code <Code> as removed, with a restart to finish it' -ForEach @(
        @{ Code = 3010 }
        @{ Code = 1641 }
    ) {
        $script:exitCode = $Code

        $result = Uninstall-CatalogApp -App $script:drive

        $result.Status | Should -Be 'Uninstalled'
        $result.RestartRequired | Should -BeTrue
    }

    It 'Fails, UninstallFailed, on any other exit code, without waiting' {
        $script:exitCode = 1603

        $result = Uninstall-CatalogApp -App $script:drive

        $result.Status | Should -Be 'Failed'
        $result.FailureReason | Should -Be 'UninstallFailed'
        $result.ExitCode | Should -Be 1603
        $result.Reason | Should -Be "its uninstaller 'uninstall.exe' exited with 1603 (0x00000643)"
        Should -Invoke Start-Sleep -Times 0 -Exactly
        Should -Invoke Test-WingetPackageInstalled -Times 1 -Exactly
    }

    It 'Fails, <FailureReason>, naming uninstall.exe, when <Case>' -ForEach @(
        @{ Case = 'it runs out of time'; Result = { New-TestProcessResult -TimedOut }; FailureReason = 'UninstallTimeout'; Text = "its uninstaller 'uninstall.exe' did not finish within 15 minutes and was stopped" }
        @{ Case = 'it cannot be started'; Result = { New-TestProcessResult -LaunchFailed -LaunchErrorCode 5 -LaunchError 'Access is denied.' }; FailureReason = 'UninstallLaunchFailed'; Text = "its uninstaller 'uninstall.exe' could not be started (Access is denied)" }
    ) {
        $script:processResult = $Result
        Mock Invoke-ExternalProcess { & $script:processResult }

        $result = Uninstall-CatalogApp -App $script:drive

        $result.Status | Should -Be 'Failed'
        $result.FailureReason | Should -Be $FailureReason
        $result.Reason | Should -Be $Text
        Should -Invoke Invoke-WingetProcess -Times 0 -Exactly
    }

    It 'Fails, UninstallerNotFound, and runs nothing, winget uninstall included, when <Case>' -ForEach @(
        @{ Case = 'there is no uninstall entry'; Outside = $false; Reason = 'its own uninstaller was not found: there is no uninstall entry {6BBAE539-2232-434A-A4E5-9A33560C6283} under HKLM' }
        @{ Case = 'the entry names a program outside Program Files'; Outside = $true; Reason = $null }
    ) {
        if ($Outside) {
            $script:outsideString = '"{0}"' -f (New-TestFileElsewhere -Segment @('Users', 'Public', 'uninstall.exe'))
            Mock Get-AppUninstallEntry { if ($View -eq 'Registry64') { New-TestUninstallEntry -UninstallString $script:outsideString } }
        }
        else {
            Mock Get-AppUninstallEntry { $null }
        }

        $result = Uninstall-CatalogApp -App $script:drive

        $result.Status | Should -Be 'Failed'
        $result.FailureReason | Should -Be 'UninstallerNotFound'
        $result.Reason | Should -Match '^its own uninstaller was not found: '
        if ($Reason) {
            $result.Reason | Should -Be $Reason
        }
        Should -Invoke Invoke-ExternalProcess -Times 0 -Exactly
        Should -Invoke Invoke-WingetProcess -Times 0 -Exactly
    }

    It 'Previews the exact command line it would run, and runs nothing (-WhatIf)' {
        $result = Uninstall-CatalogApp -App $script:drive -WhatIf

        $result.Status | Should -Be 'Uninstalled'
        $result.Command | Should -Be $script:expectedCommand
        Should -Invoke Invoke-ExternalProcess -Times 0 -Exactly
        Should -Invoke Invoke-WingetProcess -Times 0 -Exactly
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'Previews the failure a real run would have when the uninstaller cannot be found (-WhatIf)' {
        Mock Get-AppUninstallEntry { $null }

        $result = Uninstall-CatalogApp -App $script:drive -WhatIf

        $result.Status | Should -Be 'Failed'
        $result.FailureReason | Should -Be 'UninstallerNotFound'
        Should -Invoke Invoke-ExternalProcess -Times 0 -Exactly
    }

    It 'Does not read the uninstall entry of an app that is not installed' {
        Mock Test-WingetPackageInstalled { New-TestCheckResult -Installed $false }

        $result = Uninstall-CatalogApp -App $script:drive

        $result.Status | Should -Be 'Skipped'
        $result.SkipReason | Should -Be 'NotInstalled'
        Should -Invoke Get-AppUninstallEntry -Times 0 -Exactly
        Should -Invoke Invoke-ExternalProcess -Times 0 -Exactly
    }

    It 'Keeps winget uninstall for an entry without quietUninstall' {
        $result = Uninstall-CatalogApp -App @{ name = 'Contoso.App' }

        $result.Status | Should -Be 'Uninstalled'
        $result.Command | Should -BeNullOrEmpty
        Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'uninstall' -and $ArgumentList -contains 'Contoso.App' }
        Should -Invoke Invoke-ExternalProcess -Times 0 -Exactly
        Should -Invoke Get-AppUninstallEntry -Times 0 -Exactly
    }
}

# The CI hang end to end through Invoke-WingetUninstall, with the catalog's own Google Drive entry:
# `winget uninstall` ran Drive's bare uninstall.exe, which asked 'Uninstall Google Drive?' until the
# 15-minute limit stopped it, so Drive stayed, Winget-AutoUpdate was kept and the run exited 1.
Describe 'Invoke-WingetUninstall with the catalog''s Google Drive entry (wgt-gq8.61)' {
    BeforeEach {
        $script:exe = Initialize-TestProgramFiles
        $script:drive = @(Get-DefaultAppCatalog) | Where-Object { $_.name -eq 'Google.GoogleDrive' }
        Mock Write-Host { }
        Mock Start-Sleep { }
        Mock Initialize-Winget { [pscustomobject]@{ Ready = $true; Diagnosis = 'Ok' } }
        Mock Remove-LegacyScheduledUpdates { $false }
        Mock Uninstall-WingetAutoUpdate { @{ Succeeded = $true; RestartRequired = $false } }
        Mock Test-WauInstalled { $true }
        Mock Reset-WindowsTerminalDelegation { $false }
        Mock Test-WindowsTerminalHostsCurrentSession { $false }
        Mock Get-PowerShellEdition { 'Desktop' }
        Mock Get-InstallAccountContext { New-TestAccountContext }
        Mock Write-Table { }
        $script:errorMessages = @()
        Mock Write-ErrorMessage { $script:errorMessages += $Message }
        $script:warningMessages = @()
        Mock Write-WarningMessage { $script:warningMessages += $Message }
        $script:infoMessages = @()
        Mock Write-Info { $script:infoMessages += $Message }
        $script:successMessages = @()
        Mock Write-Success { $script:successMessages += $Message }

        # winget lists Drive until its uninstaller has run ($script:stillListed: for good). Its own
        # uninstall is what it did in CI: it waited on uninstall.exe until the limit stopped it.
        $script:removed = $false
        $script:stillListed = $false
        Mock Invoke-WingetProcess {
            $arguments = @($ArgumentList)
            $id = $arguments[[array]::IndexOf($arguments, '--id') + 1]
            if ($arguments[0] -eq 'list') {
                if ($script:stillListed -or -not $script:removed) {
                    return New-TestProcessResult -ExitCode 0 -Output @("$id  131.0.2.0  winget")
                }
                return New-TestProcessResult -ExitCode -1978335212 -Output @('No installed package found matching input criteria.')
            }
            return New-TestProcessResult -TimedOut
        }
        Mock Get-AppUninstallEntry {
            if ($View -eq 'Registry64' -and -not $script:removed) {
                New-TestUninstallEntry -UninstallString ('"{0}"' -f $script:exe)
            }
        }
        $script:exitCode = 0
        Mock Invoke-ExternalProcess { $script:removed = $true; New-TestProcessResult -ExitCode $script:exitCode }
    }

    AfterEach {
        Restore-TestEnvironment
    }

    It 'Removes Google Drive with its own uninstaller and Google''s --silent --force_stop, never with winget uninstall, then removes Winget-AutoUpdate' {
        $result = Invoke-WingetUninstall -Apps @($script:drive)

        $result | Should -Be 0
        Should -Invoke Invoke-ExternalProcess -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq $script:exe -and (@($ArgumentList) -join ' ') -ceq '--silent --force_stop' -and $TimeoutSeconds -eq 900
        }
        Should -Invoke Invoke-WingetProcess -Times 0 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'uninstall' }
        $script:successMessages | Should -Contain 'Successfully uninstalled: Google.GoogleDrive'
        $script:infoMessages | Should -Contain ('Uninstalling: Google.GoogleDrive (its own uninstaller: "{0}" --silent --force_stop)' -f $script:exe)
        Should -Invoke Uninstall-WingetAutoUpdate -Times 1 -Exactly
        $script:errorMessages | Should -BeNullOrEmpty
    }

    It 'Previews the exact command line in a dry run, and runs nothing' {
        $result = Invoke-WingetUninstall -Apps @($script:drive) -WhatIf

        $result | Should -Be 0
        $script:infoMessages | Should -Contain ('[DRY-RUN] Would uninstall: Google.GoogleDrive (its own uninstaller: "{0}" --silent --force_stop)' -f $script:exe)
        Should -Invoke Invoke-ExternalProcess -Times 0 -Exactly
        Should -Invoke Invoke-WingetProcess -Times 0 -Exactly -ParameterFilter { $ArgumentList[0] -ne 'list' }
    }

    It 'Fails Google Drive and keeps Winget-AutoUpdate when winget still lists it after its uninstaller ran' {
        $script:stillListed = $true

        $result = Invoke-WingetUninstall -Apps @($script:drive)

        $result | Should -Be 1
        $script:errorMessages | Should -Contain "Failed to uninstall: Google.GoogleDrive (its uninstaller 'uninstall.exe' exited with 0 and its uninstall entry is gone, but winget still lists it)."
        Should -Invoke Uninstall-WingetAutoUpdate -Times 0 -Exactly
        Should -Invoke Invoke-WingetProcess -Times 0 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'uninstall' }
    }

    It 'Returns 3010 when Google Drive''s uninstaller says a restart finishes the removal' {
        $script:exitCode = 3010

        $result = Invoke-WingetUninstall -Apps @($script:drive)

        $result | Should -Be 3010
        $script:successMessages | Should -Contain 'Successfully uninstalled: Google.GoogleDrive (a restart finishes removing it)'
        $script:warningMessages | Should -Contain 'Restart: REQUIRED to finish removing Google.GoogleDrive.'
    }

    It 'Fails Google Drive at once, runs nothing and keeps Winget-AutoUpdate when its uninstall entry is missing' {
        Mock Get-AppUninstallEntry { $null }

        $result = Invoke-WingetUninstall -Apps @($script:drive)

        $result | Should -Be 1
        $script:errorMessages | Should -Contain 'Failed to uninstall: Google.GoogleDrive (its own uninstaller was not found: there is no uninstall entry {6BBAE539-2232-434A-A4E5-9A33560C6283} under HKLM).'
        Should -Invoke Invoke-ExternalProcess -Times 0 -Exactly
        Should -Invoke Invoke-WingetProcess -Times 0 -Exactly -ParameterFilter { $ArgumentList[0] -eq 'uninstall' }
        Should -Invoke Uninstall-WingetAutoUpdate -Times 0 -Exactly
    }
}
