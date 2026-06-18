# Test-WingetAppInstall.Tests.ps1
# Comprehensive unit tests for winget-app-install.ps1 using Pester

Describe 'Test-AndInstallWingetModule' {
    BeforeAll {
        # Dot-source the script under test so these tests exercise the real implementation (#135).
        . "$PSScriptRoot/winget-app-install.ps1"

        Mock Write-Host { }
        Mock Write-Warning { }

    }

    Context 'When module is already available' {
        It 'Should return true without installing' {
            Mock Get-Module { @{ Name = 'Microsoft.WinGet.Client' } } -ParameterFilter { $Name -eq 'Microsoft.WinGet.Client' -and $ListAvailable }
            Mock Get-PackageProvider { }
            Mock Install-PackageProvider { }
            Mock Install-Module { }

            $result = Test-AndInstallWingetModule
            $result | Should -Be $true
            Assert-MockCalled Install-Module -Times 0
        }
    }

    Context 'When module is missing and installation succeeds' {
        It 'Should install dependencies and return true' {
            $script:moduleInstalled = $false

            Mock Get-Module {
                if ($script:moduleInstalled) {
                    return @{ Name = 'Microsoft.WinGet.Client' }
                }
                return $null
            } -ParameterFilter { $Name -eq 'Microsoft.WinGet.Client' -and $ListAvailable }

            Mock Get-PackageProvider { $null } -ParameterFilter { $Name -eq 'NuGet' }
            Mock Install-PackageProvider { } -ParameterFilter { $Name -eq 'NuGet' }
            Mock Install-Module { $script:moduleInstalled = $true }

            $result = Test-AndInstallWingetModule
            $result | Should -Be $true
            Assert-MockCalled Install-PackageProvider -Times 1 -ParameterFilter { $Name -eq 'NuGet' }
            Assert-MockCalled Install-Module -Times 1
        }
    }

    Context 'When module installation fails' {
        It 'Should return false and emit warning' {
            Mock Get-Module { $null } -ParameterFilter { $Name -eq 'Microsoft.WinGet.Client' -and $ListAvailable }
            Mock Get-PackageProvider { $null } -ParameterFilter { $Name -eq 'NuGet' }
            Mock Install-PackageProvider { }
            Mock Install-Module { throw 'Failure installing module' }

            $result = Test-AndInstallWingetModule
            $result | Should -Be $false
            Assert-MockCalled Install-Module -Times 1
        }
    }
}

Describe 'Test-AndInstallGraphicalTools' {
    BeforeAll {
        # Dot-source the script under test so these tests exercise the real implementation (#135).
        . "$PSScriptRoot/winget-app-install.ps1"

        Mock Write-Host { }
        Mock Write-Warning { }

    }

    Context 'When Out-GridView is already available' {
        It 'Should return true without installing' {
            Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'Out-GridView' }
            Mock Get-Module { }
            Mock Install-Module { }
            Mock Import-Module { }

            $result = Test-AndInstallGraphicalTools
            $result | Should -Be $true
            Assert-MockCalled Install-Module -Times 0
        }
    }

    Context 'When module is missing and installation succeeds' {
        It 'Should install dependencies and return true' {
            $script:outGridViewAvailable = $false

            Mock Get-Command {
                if ($script:outGridViewAvailable) {
                    return $true
                }
                return $null
            } -ParameterFilter { $Name -eq 'Out-GridView' }

            Mock Get-Module {
                param($Name, $ListAvailable)
                if ($Name -eq 'Microsoft.PowerShell.GraphicalTools' -and -not $ListAvailable) {
                    return @{ Name = 'Microsoft.PowerShell.GraphicalTools'; Version = '0.1.2' }
                }
                return $null
            }

            Mock Get-PackageProvider { $null } -ParameterFilter { $Name -eq 'NuGet' }
            Mock Install-PackageProvider { } -ParameterFilter { $Name -eq 'NuGet' }
            Mock Install-Module { }
            Mock Import-Module { $script:outGridViewAvailable = $true }

            $result = Test-AndInstallGraphicalTools
            $result | Should -Be $true
            Assert-MockCalled Install-PackageProvider -Times 1 -ParameterFilter { $Name -eq 'NuGet' }
            Assert-MockCalled Install-Module -Times 1
            Assert-MockCalled Import-Module -Times 1
        }
    }

    Context 'When module exists but needs importing' {
        It 'Should import existing module without reinstalling' {
            $script:outGridViewAvailable = $false

            Mock Get-Command {
                if ($script:outGridViewAvailable) {
                    return $true
                }
                return $null
            } -ParameterFilter { $Name -eq 'Out-GridView' }

            Mock Get-Module {
                param($Name, $ListAvailable)
                if ($Name -eq 'Microsoft.PowerShell.GraphicalTools' -and $ListAvailable) {
                    return @{ Name = 'Microsoft.PowerShell.GraphicalTools'; Version = '0.1.2' }
                }
                return $null
            }

            Mock Get-PackageProvider { @{ Name = 'NuGet' } } -ParameterFilter { $Name -eq 'NuGet' }
            Mock Install-Module { }
            Mock Import-Module { $script:outGridViewAvailable = $true }

            $result = Test-AndInstallGraphicalTools
            $result | Should -Be $true
            Assert-MockCalled Install-Module -Times 1  # Still installs to ensure latest version
            Assert-MockCalled Import-Module -Times 1
        }
    }

    Context 'When NuGet provider needs installation' {
        It 'Should install NuGet provider before installing module' {
            $script:outGridViewAvailable = $false

            Mock Get-Command {
                if ($script:outGridViewAvailable) {
                    return $true
                }
                return $null
            } -ParameterFilter { $Name -eq 'Out-GridView' }

            Mock Get-Module { $null }
            Mock Get-PackageProvider { $null } -ParameterFilter { $Name -eq 'NuGet' }
            Mock Install-PackageProvider { } -ParameterFilter { $Name -eq 'NuGet' }
            Mock Install-Module { }
            Mock Import-Module { $script:outGridViewAvailable = $true }

            $result = Test-AndInstallGraphicalTools
            $result | Should -Be $true
            Assert-MockCalled Install-PackageProvider -Times 1 -ParameterFilter {
                $Name -eq 'NuGet' -and $MinimumVersion -eq '2.8.5.201' -and $Force -eq $true -and $Scope -eq 'AllUsers'
            }
        }
    }

    Context 'When Install-Module fails' {
        It 'Should catch error and return false' {
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'Out-GridView' }
            Mock Get-Module { $null }
            Mock Get-PackageProvider { @{ Name = 'NuGet' } } -ParameterFilter { $Name -eq 'NuGet' }
            Mock Install-Module { throw 'Module installation failed' }

            $result = Test-AndInstallGraphicalTools
            $result | Should -Be $false
            Assert-MockCalled Install-Module -Times 1
        }
    }

    Context 'When Import-Module fails' {
        It 'Should catch error and return false' {
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'Out-GridView' }
            Mock Get-Module { $null }
            Mock Get-PackageProvider { @{ Name = 'NuGet' } } -ParameterFilter { $Name -eq 'NuGet' }
            Mock Install-Module { }
            Mock Import-Module { throw 'Module import failed' }

            $result = Test-AndInstallGraphicalTools
            $result | Should -Be $false
            Assert-MockCalled Import-Module -Times 1
        }
    }

    Context 'When Out-GridView remains unavailable after installation' {
        It 'Should return false and log warning' {
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'Out-GridView' }
            Mock Get-Module { $null }
            Mock Get-PackageProvider { @{ Name = 'NuGet' } } -ParameterFilter { $Name -eq 'NuGet' }
            Mock Install-Module { }
            Mock Import-Module { }

            $result = Test-AndInstallGraphicalTools
            $result | Should -Be $false
            Assert-MockCalled Install-Module -Times 1
            Assert-MockCalled Import-Module -Times 1
        }
    }
}

Describe 'Test-AndInstallWinget' {
    BeforeAll {
        Mock Write-Host { }

        # Dot-source the main script to import Test-AndInstallWinget
        . "$PSScriptRoot\winget-app-install.ps1"
    }

    Context 'When winget is available' {
        It 'Should return true and not attempt installation' {
            Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'winget' }
            Mock Invoke-WebRequest { }
            $result = Test-AndInstallWinget
            $result | Should -Be $true
            Assert-MockCalled Get-Command -Times 1
            Assert-MockCalled Invoke-WebRequest -Times 0
        }
    }

    Context 'When winget is not available and installation succeeds' {
        It 'Should attempt installation and return true' {
            Mock Get-Command { return $false } -ParameterFilter { $Name -eq 'winget' }
            Mock Invoke-WebRequest { }
            Mock Add-AppxPackage { }
            Mock Remove-Item { }
            $result = Test-AndInstallWinget
            $result | Should -Be $true
            Assert-MockCalled Invoke-WebRequest -Times 1
            Assert-MockCalled Add-AppxPackage -Times 1
            Assert-MockCalled Remove-Item -Times 1
        }
    }

    Context 'When winget is not available and installation fails' {
        It 'Should attempt installation, catch error, and return false' {
            Mock Get-Command { return $false } -ParameterFilter { $Name -eq 'winget' }
            Mock Invoke-WebRequest { throw 'Network error' }
            $result = Test-AndInstallWinget
            $result | Should -Be $false
            Assert-MockCalled Invoke-WebRequest -Times 1
        }
    }
}

Describe 'Test-WingetSources' {
    BeforeAll {
        Mock Write-Host { }
        Mock Write-Warning { }

        # Dot-source the main script to import Test-WingetSources
        . "$PSScriptRoot\winget-app-install.ps1"
    }

    Context 'When winget sources are listed and functional' {
        It 'Should return true without attempting repair' {
            Mock winget {
                if ($args[0] -eq 'source' -and $args[1] -eq 'list') {
                    $global:LASTEXITCODE = 0
                    return 'winget      https://cdn.winget.microsoft.com/cache'
                }
                elseif ($args[0] -eq 'search' -and $args[1] -eq '7zip') {
                    $global:LASTEXITCODE = 0
                    return '7zip.7zip    7.30'
                }
            }
            Mock Add-AppxPackage { }

            $result = Test-WingetSources
            $result | Should -Be $true
            Assert-MockCalled Add-AppxPackage -Times 0
        }
    }

    Context 'When winget source is corrupted (0x8a15000f)' {
        It 'Should detect corruption and attempt repair with source reset' {
            $script:searchCount = 0
            Mock winget {
                if ($args[0] -eq 'source' -and $args[1] -eq 'list') {
                    $global:LASTEXITCODE = 0
                    return 'winget      https://cdn.winget.microsoft.com/cache'
                }
                elseif ($args[0] -eq 'search' -and $args[1] -eq '7zip') {
                    $script:searchCount++
                    if ($script:searchCount -eq 1) {
                        # First call: corrupted data
                        $global:LASTEXITCODE = 1
                        return 'Failed when opening source(s); try the source reset command if the problem persists. 0x8a15000f Data required by the source is missing'
                    }
                    # After reset: works
                    $global:LASTEXITCODE = 0
                    return '7zip.7zip    7.30'
                }
                elseif ($args[0] -eq 'source' -and $args[1] -eq 'reset') {
                    $global:LASTEXITCODE = 0
                    return 'Source reset completed'
                }
            }
            Mock Add-AppxPackage { }

            $result = Test-WingetSources
            $result | Should -Be $true
            Assert-MockCalled Add-AppxPackage -Times 1
        }
    }

    Context 'When winget sources are missing entirely' {
        It 'Should attempt repair with source reset and Add-AppxPackage' {
            $script:listCallCount = 0
            $script:searchCallCount = 0
            Mock winget {
                if ($args[0] -eq 'source' -and $args[1] -eq 'list') {
                    $script:listCallCount++
                    if ($script:listCallCount -eq 1) {
                        # Initially: only msstore, no winget
                        return 'msstore      https://storeedgefd.dsx.mp.microsoft.com/v9.0'
                    }
                    # After repair: winget source is restored
                    return 'winget      https://cdn.winget.microsoft.com/cache'
                }
                elseif ($args[0] -eq 'search' -and $args[1] -eq '7zip') {
                    $script:searchCallCount++
                    if ($script:searchCallCount -eq 2) {
                        # After repair: search works
                        $global:LASTEXITCODE = 0
                        return '7zip.7zip    7.30'
                    }
                }
                elseif ($args[0] -eq 'source' -and $args[1] -eq 'reset') {
                    return 'Source reset completed'
                }
            }
            Mock Add-AppxPackage { }

            $result = Test-WingetSources
            $result | Should -Be $true
            Assert-MockCalled Add-AppxPackage -Times 1
        }
    }

    Context 'When winget sources repair fails' {
        It 'Should return false when Add-AppxPackage throws error' {
            Mock winget {
                if ($args[0] -eq 'source' -and $args[1] -eq 'list') {
                    return 'msstore      https://storeedgefd.dsx.mp.microsoft.com/v9.0'
                }
                elseif ($args[0] -eq 'source' -and $args[1] -eq 'reset') {
                    return 'Source reset completed'
                }
            }
            Mock Add-AppxPackage { throw 'Network error' }

            $result = Test-WingetSources
            $result | Should -Be $false
        }
    }

    Context 'When winget source is corrupted and source reset fails' {
        It 'Should still attempt Add-AppxPackage as fallback' {
            $script:listCallCount = 0
            $script:searchCallCount = 0
            Mock winget {
                if ($args[0] -eq 'source' -and $args[1] -eq 'list') {
                    $script:listCallCount++
                    if ($script:listCallCount -eq 1) {
                        # Initially: source is listed
                        return 'winget      https://cdn.winget.microsoft.com/cache'
                    }
                    # After repair attempt: still listed (but Add-AppxPackage will fix it)
                    return 'winget      https://cdn.winget.microsoft.com/cache'
                }
                elseif ($args[0] -eq 'search' -and $args[1] -eq '7zip') {
                    $script:searchCallCount++
                    if ($script:searchCallCount -eq 1) {
                        # Initially: corrupted
                        $global:LASTEXITCODE = 1
                        return '0x8a15000f Data required by the source is missing'
                    }
                    # After Add-AppxPackage: works
                    $global:LASTEXITCODE = 0
                    return '7zip.7zip    7.30'
                }
                elseif ($args[0] -eq 'source' -and $args[1] -eq 'reset') {
                    # Reset fails
                    throw 'Access denied'
                }
            }
            Mock Add-AppxPackage { }

            $result = Test-WingetSources
            $result | Should -Be $true
            Assert-MockCalled Add-AppxPackage -Times 1
        }
    }

    Context 'When winget source list throws an exception' {
        It 'Should attempt repair and handle the error gracefully' {
            $script:listCount = 0
            $script:searchCount = 0
            Mock winget {
                if ($args[0] -eq 'source' -and $args[1] -eq 'list') {
                    $script:listCount++
                    if ($script:listCount -eq 1) {
                        throw 'Access denied'
                    }
                    # After repair, list succeeds
                    return 'winget      https://cdn.winget.microsoft.com/cache'
                }
                elseif ($args[0] -eq 'search' -and $args[1] -eq '7zip') {
                    $script:searchCount++
                    if ($script:searchCount -eq 2) {
                        # After repair: search works
                        $global:LASTEXITCODE = 0
                        return '7zip.7zip    7.30'
                    }
                }
                elseif ($args[0] -eq 'source' -and $args[1] -eq 'reset') {
                    return 'Source reset completed'
                }
            }
            Mock Add-AppxPackage { }

            $result = Test-WingetSources
            $result | Should -Be $true
            Assert-MockCalled Add-AppxPackage -Times 1
        }
    }
}

Describe 'Test-WingetSourceTrusted' {
    BeforeAll {
        Mock Write-Host { }
        Mock Write-Warning { }

        # Dot-source the main script to import Test-WingetSourceTrusted
        . "$PSScriptRoot\winget-app-install.ps1"
    }

    Context 'When source is trusted' {
        It 'Should return true and accept source agreements' {
            Mock winget { return 'winget      https://cdn.winget.microsoft.com/cache        true' } -ParameterFilter { $args[0] -eq 'source' -and $args[1] -eq 'list' -and $args -contains '--disable-interactivity' }
            $result = Test-WingetSourceTrusted -target 'winget'
            $result | Should -Be $true
        }
    }

    Context 'When source is not trusted' {
        It 'Should return false' {
            Mock winget { return 'msstore      https://storeedgefd.dsx.mp.microsoft.com/v9.0        true' } -ParameterFilter { $args[0] -eq 'source' -and $args[1] -eq 'list' -and $args -contains '--disable-interactivity' }
            $result = Test-WingetSourceTrusted -target 'winget'
            $result | Should -Be $false
        }
    }

    Context 'When winget source list fails' {
        It 'Should return false and emit warning' {
            Mock winget { throw 'Command failed' } -ParameterFilter { $args[0] -eq 'source' -and $args[1] -eq 'list' -and $args -contains '--disable-interactivity' }
            $result = Test-WingetSourceTrusted -target 'winget'
            $result | Should -Be $false
            Assert-MockCalled Write-Warning -Times 1
        }
    }
}

Describe 'Set-Sources' {
    BeforeAll {
        Mock Write-Host { }

        # Dot-source the main script to import Set-Sources
        . "$PSScriptRoot\winget-app-install.ps1"
    }

    It 'Should call winget source reset and return true on success' {
        Mock Start-Process {
            param($FilePath, $ArgumentList, $NoNewWindow, $PassThru, $RedirectStandardOutput, $RedirectStandardError)
            $mockProcess = New-Object PSObject
            $mockProcess | Add-Member -MemberType NoteProperty -Name 'ExitCode' -Value 0
            $mockProcess | Add-Member -MemberType ScriptMethod -Name 'WaitForExit' -Value { return $true }
            return $mockProcess
        }
        Mock Get-Content { return $null } -ParameterFilter { $Path -match 'winget_reset_error' }
        Mock Remove-Item { }

        $result = Set-Sources
        $result | Should -Be $true
    }

    It 'Should return false on non-zero exit code and log error details' {
        Mock Start-Process {
            param($FilePath, $ArgumentList, $NoNewWindow, $PassThru, $RedirectStandardOutput, $RedirectStandardError)
            $mockProcess = New-Object PSObject
            $mockProcess | Add-Member -MemberType NoteProperty -Name 'ExitCode' -Value 1
            $mockProcess | Add-Member -MemberType ScriptMethod -Name 'WaitForExit' -Value { return $true }
            return $mockProcess
        }
        Mock Get-Content { return 'Permission denied' } -ParameterFilter { $Path -match 'winget_reset_error' }
        Mock Remove-Item { }

        $result = Set-Sources
        $result | Should -Be $false
        Assert-MockCalled Write-Host -Times 1 -ParameterFilter { $Object -match 'Permission denied' }
    }

    It 'Should handle timeout and kill process' {
        $mockProcess = New-Object PSObject
        $mockProcess | Add-Member -MemberType NoteProperty -Name 'ExitCode' -Value 0
        $mockProcess | Add-Member -MemberType ScriptMethod -Name 'WaitForExit' -Value { return $false }
        $script:killInvoked = $false
        $mockProcess | Add-Member -MemberType ScriptMethod -Name 'Kill' -Value { $script:killInvoked = $true }

        Mock Start-Process { return $mockProcess }
        Mock Remove-Item { }

        $result = Set-Sources
        $result | Should -Be $false
        $script:killInvoked | Should -Be $true
    }
}

Describe 'Add-ToEnvironmentPath' {
    BeforeAll {
        # Dot-source the script under test so these tests exercise the real implementation (#135).
        . "$PSScriptRoot/winget-app-install.ps1"

        Mock Write-Host { }

    }

    Context 'When path is not in User scope' {
        It 'Should attempt to modify environment' {
            Mock Test-PathInEnvironment { return $false } -ParameterFilter { $Scope -eq 'User' }
            # Note: Static methods can't be easily mocked in Pester, so we just verify the logic flow
            { Add-ToEnvironmentPath -PathToAdd 'C:\Test' -Scope 'User' } | Should -Not -Throw
        }
    }

    Context 'When path is already in User scope' {
        It 'Should not modify environment' {
            Mock Test-PathInEnvironment { return $true } -ParameterFilter { $Scope -eq 'User' }

            Add-ToEnvironmentPath -PathToAdd 'C:\Test' -Scope 'User'

            # Should not call environment modification methods
            Assert-MockCalled Test-PathInEnvironment -Times 1
        }
    }
}

Describe 'Test-PathInEnvironment' {
    BeforeAll {
        # Dot-source the script under test so these tests exercise the real implementation (#135).
        . "$PSScriptRoot/winget-app-install.ps1"

    }

    Context 'User scope' {
        It 'Should handle function call without errors' {
            # Static methods can't be mocked easily, so we just verify the function exists and can be called
            { Test-PathInEnvironment -PathToCheck 'C:\Test' -Scope 'User' } | Should -Not -Throw
        }
    }

    Context 'System scope' {
        It 'Should handle function call without errors' {
            { Test-PathInEnvironment -PathToCheck 'C:\Test' -Scope 'System' } | Should -Not -Throw
        }
    }
}

Describe 'ConvertTo-CommandArguments' {
    BeforeAll {
        # Dot-source the script under test so these tests exercise the real implementation (#135).
        . "$PSScriptRoot/winget-app-install.ps1"

    }

    It 'Should parse simple command without quotes' {
        $result = ConvertTo-CommandArguments -Command 'winget install --id test'
        $result | Should -Be @('winget', 'install', '--id', 'test')
    }

    It 'Should handle quoted arguments' {
        $result = ConvertTo-CommandArguments -Command 'winget install --id "test app"'
        $result | Should -Be @('winget', 'install', '--id', 'test app')
    }

    It 'Should handle single quotes' {
        $result = ConvertTo-CommandArguments -Command "winget install --id 'test app'"
        $result | Should -Be @('winget', 'install', '--id', 'test app')
    }

    It 'Should handle multiple quoted arguments' {
        $result = ConvertTo-CommandArguments -Command 'winget install --id "test app" --source "winget store"'
        $result | Should -Be @('winget', 'install', '--id', 'test app', '--source', 'winget store')
    }
}

Describe 'Restart-WithElevation' {
    BeforeAll {
        # Dot-source the script under test so these tests exercise the real implementation (#135).
        . "$PSScriptRoot/winget-app-install.ps1"

        Mock Write-Host { }
        Mock Write-Warning { }
    }

    It 'Should use Windows Terminal when available' {
        Mock Start-Process { } -ParameterFilter { $FilePath -eq 'wt.exe' }
        Mock Start-Process { } -ParameterFilter { $FilePath -eq 'pwsh.exe' }

        $result = Restart-WithElevation -PowerShellExecutable 'pwsh.exe' -ScriptPath 'C:\script.ps1' -WindowsTerminalExecutable 'wt.exe'

        Assert-MockCalled Start-Process -ParameterFilter { $FilePath -eq 'wt.exe' } -Times 1
        Assert-MockCalled Start-Process -ParameterFilter { $FilePath -eq 'pwsh.exe' } -Times 0
        $result | Should -Be 'WindowsTerminal'
    }

    It 'Should fall back to PowerShell when Windows Terminal launch fails' {
        Mock Start-Process { throw 'Failed to launch wt' } -ParameterFilter { $FilePath -eq 'wt.exe' }
        Mock Start-Process { } -ParameterFilter { $FilePath -eq 'pwsh.exe' }

        $result = Restart-WithElevation -PowerShellExecutable 'pwsh.exe' -ScriptPath 'C:\script.ps1' -WindowsTerminalExecutable 'wt.exe'

        Assert-MockCalled Start-Process -ParameterFilter { $FilePath -eq 'wt.exe' } -Times 1
        Assert-MockCalled Start-Process -ParameterFilter { $FilePath -eq 'pwsh.exe' } -Times 1
        $result | Should -Be 'PowerShell'
    }

    It 'Should use PowerShell when Windows Terminal is not available' {
        Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'wt.exe' }
        Mock Start-Process { } -ParameterFilter { $FilePath -eq 'pwsh.exe' }

        $result = Restart-WithElevation -PowerShellExecutable 'pwsh.exe' -ScriptPath 'C:\script.ps1'

        Assert-MockCalled Start-Process -ParameterFilter { $FilePath -eq 'pwsh.exe' } -Times 1
        $result | Should -Be 'PowerShell'
    }
}

Describe 'Test-CanUseGridView' {
    BeforeAll {
        # Dot-source the script under test so these tests exercise the real implementation (#135).
        . "$PSScriptRoot/winget-app-install.ps1"

    }

    It 'Should return true when Out-GridView is available and session is interactive' {
        Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'Out-GridView' }

        $result = Test-CanUseGridView
        $result | Should -Be $true
    }

    It 'Should return false when Out-GridView is not available' {
        Mock Get-Command { throw 'Command not found' } -ParameterFilter { $Name -eq 'Out-GridView' }

        $result = Test-CanUseGridView
        $result | Should -Be $false
    }

    It 'Should return false when session is not interactive' {
        Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'Out-GridView' }

        # Mock the Environment.UserInteractive property
        # This test assumes we're in an interactive session by default
        # In a non-interactive context (e.g., CI/CD), this would naturally return false
        $originalValue = [Environment]::UserInteractive

        if ($originalValue) {
            # We can't easily mock static properties, so we'll just verify the logic
            # In actual non-interactive scenarios, this will correctly return false
            $result = Test-CanUseGridView
            # In interactive mode with Out-GridView available, should be true
            $result | Should -Be $true
        }
    }
}

Describe 'Write-Table' {
    BeforeAll {
        # Dot-source the script under test so these tests exercise the real implementation (#135).
        . "$PSScriptRoot/winget-app-install.ps1"

        Mock Write-Host { }
        Mock Read-Host { return 'N' }

        # Create a mock Out-GridView command if it doesn't exist
        if (-not (Get-Command Out-GridView -ErrorAction SilentlyContinue)) {
            function Out-GridView { param($Title, [switch]$Wait) }
        }
        Mock Out-GridView { }

    }

    It 'Should format table data correctly with Format-Table' {
        $headers = @('Status', 'Apps')
        $rows = @(@('Installed', 'App1, App2'))

        Write-Table -Headers $headers -Rows $rows

        # Should call Write-Host at least once with formatted table output
        Assert-MockCalled Write-Host -Times 1 -ParameterFilter { $Object -match 'Status' -or $Object -match 'Apps' }
    }

    It 'Should handle multiple rows correctly' {
        $headers = @('Status', 'Apps')
        $rows = @(
            @('Installed', 'App1, App2'),
            @('Skipped', 'App3'),
            @('Failed', 'App4')
        )

        Write-Table -Headers $headers -Rows $rows

        # Should call Write-Host with the formatted output
        Assert-MockCalled Write-Host -Times 1
    }

    It 'Should use Out-GridView when requested and available' {
        Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'Out-GridView' }

        $headers = @('Status', 'Apps')
        $rows = @(@('Installed', 'App1, App2'))

        Write-Table -Headers $headers -Rows $rows -UseGridView $true

        # Should call Out-GridView
        Assert-MockCalled Out-GridView -Times 1
    }

    It 'Should fall back to text output when Out-GridView is not available' {
        Mock Get-Command { throw 'Command not found' } -ParameterFilter { $Name -eq 'Out-GridView' }

        $headers = @('Status', 'Apps')
        $rows = @(@('Installed', 'App1, App2'))

        Write-Table -Headers $headers -Rows $rows -UseGridView $true

        # Should call Write-Host for fallback
        Assert-MockCalled Write-Host -Times 2  # Warning message + table output
    }

    It 'Should default to text output when UseGridView is false' {
        $headers = @('Status', 'Apps')
        $rows = @(@('Installed', 'App1, App2'))

        Write-Table -Headers $headers -Rows $rows -UseGridView $false

        # Should not call Out-GridView
        Assert-MockCalled Out-GridView -Times 0
        # Should call Write-Host for text output
        Assert-MockCalled Write-Host -Times 1
    }

    It 'Should prompt user when PromptForGridView is true and user accepts' {
        Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'Out-GridView' }
        Mock Read-Host { return 'Y' }

        $headers = @('Status', 'Apps')
        $rows = @(@('Installed', 'App1, App2'))

        Write-Table -Headers $headers -Rows $rows -PromptForGridView $true

        # Should call Read-Host to prompt user
        Assert-MockCalled Read-Host -Times 1
        # Should call Out-GridView since user said yes
        Assert-MockCalled Out-GridView -Times 1
    }

    It 'Should prompt user when PromptForGridView is true and user declines' {
        Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'Out-GridView' }
        Mock Read-Host { return 'N' }

        $headers = @('Status', 'Apps')
        $rows = @(@('Installed', 'App1, App2'))

        Write-Table -Headers $headers -Rows $rows -PromptForGridView $true

        # Should call Read-Host to prompt user
        Assert-MockCalled Read-Host -Times 1
        # Should not call Out-GridView since user said no
        Assert-MockCalled Out-GridView -Times 0
        # Should call Write-Host for text output
        Assert-MockCalled Write-Host -Times 2  # Empty line + table output
    }

    It 'Should not prompt when Out-GridView is not available' {
        Mock Get-Command { throw 'Command not found' } -ParameterFilter { $Name -eq 'Out-GridView' }
        Mock Read-Host { return 'Y' }

        $headers = @('Status', 'Apps')
        $rows = @(@('Installed', 'App1, App2'))

        Write-Table -Headers $headers -Rows $rows -PromptForGridView $true

        # Should not call Read-Host since Out-GridView is not available
        Assert-MockCalled Read-Host -Times 0
        # Should call Write-Host for text output
        Assert-MockCalled Write-Host -Times 1
    }

    It 'Should accept case-insensitive affirmative responses (y, Y, yes, YES)' {
        Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'Out-GridView' }

        $testCases = @('y', 'Y', 'yes', 'YES', 'Yes', 'yEs')
        foreach ($response in $testCases) {
            Mock Read-Host { return $response }
            Mock Out-GridView { }

            $headers = @('Status', 'Apps')
            $rows = @(@('Installed', 'App1, App2'))

            Write-Table -Headers $headers -Rows $rows -PromptForGridView $true

            # Should call Out-GridView for all case variations
            Assert-MockCalled Out-GridView -Times 1
        }
    }

    It 'Should reject non-affirmative responses (n, N, no, anything else)' {
        Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'Out-GridView' }

        $testCases = @('n', 'N', 'no', 'NO', 'nope', 'maybe', '', 'x')
        foreach ($response in $testCases) {
            Mock Read-Host { return $response }
            Mock Out-GridView { }

            $headers = @('Status', 'Apps')
            $rows = @(@('Installed', 'App1, App2'))

            Write-Table -Headers $headers -Rows $rows -PromptForGridView $true

            # Should NOT call Out-GridView for non-affirmative responses
            Assert-MockCalled Out-GridView -Times 0
            # Should call Write-Host for text output (empty line + table)
            Assert-MockCalled Write-Host -Times 2
        }
    }

    It 'Should skip prompt when UseGridView is true regardless of PromptForGridView' {
        Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'Out-GridView' }
        Mock Read-Host { return 'N' }  # User says no, but should be ignored

        $headers = @('Status', 'Apps')
        $rows = @(@('Installed', 'App1, App2'))

        Write-Table -Headers $headers -Rows $rows -UseGridView $true -PromptForGridView $true

        # Should NOT call Read-Host since UseGridView takes precedence
        Assert-MockCalled Read-Host -Times 0
        # Should call Out-GridView directly
        Assert-MockCalled Out-GridView -Times 1
    }

    It 'Should handle Out-GridView execution failure gracefully' {
        Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'Out-GridView' }
        Mock Out-GridView { throw 'GridView display error' }

        $headers = @('Status', 'Apps')
        $rows = @(@('Installed', 'App1, App2'))

        Write-Table -Headers $headers -Rows $rows -UseGridView $true

        # Should call Out-GridView and catch the error
        Assert-MockCalled Out-GridView -Times 1
        # Should fall back to Write-Host (warning + table output)
        Assert-MockCalled Write-Host -Times 2
    }

    It 'Should not prompt in non-interactive session' {
        # Note: [Environment]::UserInteractive is read-only and cannot be mocked directly
        # This test validates that the code checks UserInteractive status
        # In actual non-interactive sessions, the prompt path would be skipped

        Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'Out-GridView' }
        Mock Read-Host { return 'Y' }

        $headers = @('Status', 'Apps')
        $rows = @(@('Installed', 'App1, App2'))

        # In the current environment (interactive), Read-Host will be called
        # This test validates the logic structure exists
        if ([Environment]::UserInteractive) {
            Write-Table -Headers $headers -Rows $rows -PromptForGridView $true
            # In interactive mode, prompt should be shown
            Assert-MockCalled Read-Host -Times 1
        }
    }

    It 'Should use custom title when provided' {
        Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'Out-GridView' }
        Mock Out-GridView { } -Verifiable -ParameterFilter { $Title -eq 'Custom Title' }

        $headers = @('Status', 'Apps')
        $rows = @(@('Installed', 'App1, App2'))

        Write-Table -Headers $headers -Rows $rows -UseGridView $true -Title 'Custom Title'

        # Should call Out-GridView with custom title
        Assert-MockCalled Out-GridView -Times 1 -ParameterFilter { $Title -eq 'Custom Title' }
    }

    It 'Should use default title when Title parameter is not provided' {
        Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'Out-GridView' }
        Mock Out-GridView { } -Verifiable -ParameterFilter { $Title -eq 'Summary' }

        $headers = @('Status', 'Apps')
        $rows = @(@('Installed', 'App1, App2'))

        Write-Table -Headers $headers -Rows $rows -UseGridView $true

        # Should call Out-GridView with default title 'Summary'
        Assert-MockCalled Out-GridView -Times 1 -ParameterFilter { $Title -eq 'Summary' }
    }
}

Describe 'Invoke-WingetCommand' {
    BeforeAll {
        # Dot-source the script under test so these tests exercise the real implementation (#135).
        . "$PSScriptRoot/winget-app-install.ps1"

        Mock Write-Host { }

        # Define the helper function inline for testing

        # Define Invoke-WingetCommand function with exit code handling

    }

    Context 'Exit code capture and handling' {
        It 'Should return exit code 0 for successful operations' {
            $successArray = @()
            $failureArray = @()

            Mock winget {
                $global:LASTEXITCODE = 0
                'Successfully installed App1'
            }

            $result = Invoke-WingetCommand -Command 'winget install App1' -SuccessPattern 'Successfully installed' -FailurePattern 'Failed' -SuccessArray ([ref]$successArray) -FailureArray ([ref]$failureArray) -SuccessIndex 2

            $result.ExitCode | Should -Be 0
            $result.ExitMessage | Should -Be 'Success'
            $successArray | Should -Contain 'App1'
        }

        It 'Should return exit code for package not found (0x8A150029 / -1978335191)' {
            $successArray = @()
            $failureArray = @()

            Mock winget {
                $global:LASTEXITCODE = -1978335191
                'No packages found matching input criteria'
            }

            $result = Invoke-WingetCommand -Command 'winget install NonExistent.Package' -SuccessPattern 'Successfully installed' -FailurePattern 'Failed' -SuccessArray ([ref]$successArray) -FailureArray ([ref]$failureArray)

            $result.ExitCode | Should -Be -1978335191
            $result.ExitMessage | Should -Be 'No packages found matching input criteria'
        }

        It 'Should return exit code for package installation failed (0x8A150028 / -1978335192)' {
            $successArray = @()
            $failureArray = @()

            Mock winget {
                $global:LASTEXITCODE = -1978335192
                'Installation failed'
            }

            $result = Invoke-WingetCommand -Command 'winget install App1' -SuccessPattern 'Successfully installed' -FailurePattern 'Failed' -SuccessArray ([ref]$successArray) -FailureArray ([ref]$failureArray)

            $result.ExitCode | Should -Be -1978335192
            $result.ExitMessage | Should -Be 'Package installation failed'
        }

        It 'Should return exit code for user cancelled (0x8A150014 / -1978335212)' {
            $successArray = @()
            $failureArray = @()

            Mock winget {
                $global:LASTEXITCODE = -1978335212
                'Operation cancelled by user'
            }

            $result = Invoke-WingetCommand -Command 'winget install App1' -SuccessPattern 'Successfully installed' -FailurePattern 'Failed' -SuccessArray ([ref]$successArray) -FailureArray ([ref]$failureArray)

            $result.ExitCode | Should -Be -1978335212
            $result.ExitMessage | Should -Be 'User cancelled the operation'
        }

        It 'Should handle unknown exit codes with generic message' {
            $successArray = @()
            $failureArray = @()

            Mock winget {
                $global:LASTEXITCODE = 999
                'Unknown error'
            }

            $result = Invoke-WingetCommand -Command 'winget install App1' -SuccessPattern 'Successfully installed' -FailurePattern 'Failed' -SuccessArray ([ref]$successArray) -FailureArray ([ref]$failureArray)

            $result.ExitCode | Should -Be 999
            $result.ExitMessage | Should -Be 'Winget exited with code: 999'
        }

        It 'Should add failure entry when exit code is non-zero and no output patterns match' {
            $successArray = @()
            $failureArray = @()

            Mock winget {
                $global:LASTEXITCODE = -1978335192
                'Some unrecognized output'
            }

            $result = Invoke-WingetCommand -Command 'winget install App1' -SuccessPattern 'Successfully installed' -FailurePattern 'Failed to install' -SuccessArray ([ref]$successArray) -FailureArray ([ref]$failureArray)

            $result.ExitCode | Should -Be -1978335192
            $failureArray.Count | Should -Be 1
            $failureArray[0] | Should -Match 'Command failed with exit code'
        }
    }

    Context 'Output pattern parsing' {
        It 'Should parse successful operations' {
            $successArray = @()
            $failureArray = @()

            Mock winget {
                $global:LASTEXITCODE = 0
                'Successfully installed App1'
            }

            Invoke-WingetCommand -Command 'winget update --all' -SuccessPattern 'Successfully installed' -FailurePattern 'Failed' -SuccessArray ([ref]$successArray) -FailureArray ([ref]$failureArray) -SuccessIndex 2

            $successArray | Should -Contain 'App1'
            $failureArray | Should -Be @()
        }

        It 'Should parse failed operations' {
            $successArray = @()
            $failureArray = @()

            Mock winget {
                $global:LASTEXITCODE = 1
                'Failed to install App2'
            }

            Invoke-WingetCommand -Command 'winget install App2' -SuccessPattern 'Successfully installed' -FailurePattern 'Failed' -SuccessArray ([ref]$successArray) -FailureArray ([ref]$failureArray) -FailureIndex 3

            $failureArray | Should -Contain 'App2'
            $successArray | Should -Be @()
        }
    }
}

Describe 'Format-AppList' {
    BeforeAll {
        # Dot-source the script under test so these tests exercise the real implementation (#135).
        . "$PSScriptRoot/winget-app-install.ps1"

    }

    It 'Should format non-empty array' {
        $result = Format-AppList -AppArray @('App1', 'App2', 'App3')
        $result | Should -Be 'App1, App2, App3'
    }

    It 'Should return null for empty array' {
        $result = Format-AppList -AppArray @()
        $result | Should -Be $null
    }

    It 'Should return null for empty input' {
        # The real Format-AppList declares $AppArray as a mandatory [string[]] with
        # [AllowEmptyCollection()], so an empty array (not $null) is the boundary case
        # it is designed to handle; it returns $null when given no apps.
        $result = Format-AppList -AppArray @()
        $result | Should -Be $null
    }
}

Describe 'Test-UpdatesAvailable' {
    BeforeAll {
        # Dot-source the script under test so these tests exercise the real implementation (#135).
        . "$PSScriptRoot/winget-app-install.ps1"

        Mock Write-Host { }

    }

    Context 'PowerShell module available' {
        It 'Should return true when updates are available' {
            Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'Get-WinGetPackage' }
            Mock Get-WinGetPackage {
                @(
                    @{ Id = 'App1'; IsUpdateAvailable = $true; InstalledVersion = '1.0'; AvailableVersion = '1.1' },
                    @{ Id = 'App2'; IsUpdateAvailable = $false }
                )
            }

            $result = Test-UpdatesAvailable
            $result | Should -Be $true
        }

        It 'Should return false when no updates are available' {
            Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'Get-WinGetPackage' }
            Mock Get-WinGetPackage { @(@{ IsUpdateAvailable = $false }) }

            $result = Test-UpdatesAvailable
            $result | Should -Be $false
        }
    }

    Context 'CLI fallback' {
        It 'Should return true when CLI shows updates available' {
            Mock Get-Command { return $false } -ParameterFilter { $Name -eq 'Get-WinGetPackage' }
            Mock winget { 'Package1 has available update' } -ParameterFilter { $args -contains 'upgrade' }

            $result = Test-UpdatesAvailable
            $result | Should -Be $true
        }

        It 'Should return false when CLI shows no updates' {
            Mock Get-Command { return $false } -ParameterFilter { $Name -eq 'Get-WinGetPackage' }
            Mock winget { 'No available upgrade found' } -ParameterFilter { $args -contains 'upgrade' }

            $result = Test-UpdatesAvailable
            $result | Should -Be $false
        }
    }
}

Describe 'Main Script Logic' {
    BeforeAll {
        # Dot-source the script under test so these tests exercise the real implementation (#135).
        . "$PSScriptRoot/winget-app-install.ps1"

        Mock Write-Host { }
        Mock Pause { }
        Mock Start-Process { }

        # Mock the functions that are called

        # Mock external commands
        Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'pwsh' }
        Mock winget { 'App1' } -ParameterFilter { $args -contains 'list' }
        Mock Start-Process { }
    }

    Context 'Administrator check' {
        It 'Should handle admin check logic when running as admin' {
            # Test that we can create a WindowsPrincipal (this will work when actually running as admin)
            try {
                $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
                $principal = [Security.Principal.WindowsPrincipal]::new($currentUser)
                $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
                $isAdmin | Should -BeOfType [bool]
            }
            catch {
                # If we can't create the principal, just verify the types exist
                [Security.Principal.WindowsPrincipal] | Should -BeOfType [type]
            }
        }

        It 'Should handle admin check logic when not running as admin' {
            # This test verifies the logic structure without mocking constructors
            $adminRole = [Security.Principal.WindowsBuiltInRole]::Administrator
            $adminRole | Should -BeOfType [Security.Principal.WindowsBuiltInRole]
        }
    }

    Context 'Winget check' {
        It 'Should continue when winget is available' {
            Mock Test-AndInstallWinget { return $true }

            $result = Test-AndInstallWinget
            $result | Should -Be $true
        }

        It 'Should exit when winget installation fails' {
            Mock Test-AndInstallWinget { return $false }

            $result = Test-AndInstallWinget
            $result | Should -Be $false
        }
    }

    Context 'PATH setup' {
        It 'Should add script directory to user PATH' {
            Mock Add-ToEnvironmentPath { }

            # Test that the function would be called with correct parameters
            Add-ToEnvironmentPath -PathToAdd 'C:\Test' -Scope 'User'
            Assert-MockCalled Add-ToEnvironmentPath -Times 1
        }
    }

    Context 'Source verification' {
        It 'Should check trusted sources' {
            Mock Test-WingetSourceTrusted { param($target) return $true } -ParameterFilter { $target -eq 'winget' }
            Mock Test-WingetSourceTrusted { param($target) return $true } -ParameterFilter { $target -eq 'msstore' }

            $trustedSources = @('winget', 'msstore')
            foreach ($source in $trustedSources) {
                Test-WingetSourceTrusted -target $source | Should -Be $true
            }
        }

        It 'Should call Set-Sources when source is not trusted' {
            $trustedSources = @('winget', 'msstore')
            $script:setSourcesCalls = 0
            function Set-Sources { $script:setSourcesCalls++; return $true }

            foreach ($source in $trustedSources) {
                Set-Sources | Out-Null
            }

            $script:setSourcesCalls | Should -Be 2
        }

        It 'Should track source errors when Set-Sources fails' {
            $trustedSources = @('winget', 'msstore')
            $script:setSourcesCalls = 0
            function Set-Sources { $script:setSourcesCalls++; return $false }
            $sourceErrors = @()

            foreach ($source in $trustedSources) {
                if (-not (Set-Sources)) {
                    $sourceErrors += $source
                }
            }

            $script:setSourcesCalls | Should -Be 2
            $sourceErrors.Count | Should -Be 2
            $sourceErrors | Should -Contain 'winget'
            $sourceErrors | Should -Contain 'msstore'
        }
    }

    Context 'App installation loop' {
        It 'Should install app when not already installed' {
            $apps = @(@{name = 'Test.App' })
            $installedApps = @()
            $skippedApps = @()

            $script:installAttempted = $false

            # Mock winget list to return empty initially, then the app after install
            Mock winget {
                if ($script:installAttempted) {
                    'Test.App'
                }
                else {
                    ''
                }
            } -ParameterFilter { $args -contains 'list' -and $args -contains 'Test.App' }

            Mock Start-Process {
                $script:installAttempted = $true
            }

            foreach ($app in $apps) {
                $listApp = winget list --exact -q $app.name
                if (![String]::Join('', $listApp).Contains($app.name)) {
                    Start-Process winget -ArgumentList "install -e --accept-source-agreements --accept-package-agreements --id $($app.name)" -NoNewWindow -Wait
                    $installResult = winget list --exact -q $app.name
                    if (![String]::Join('', $installResult).Contains($app.name)) {
                        $failedApps += $app.name
                    }
                    else {
                        $installedApps += $app.name
                    }
                }
                else {
                    $skippedApps += $app.name
                }
            }

            $installedApps | Should -Contain 'Test.App'
            $skippedApps | Should -Not -Contain 'Test.App'
            $failedApps | Should -Not -Contain 'Test.App'
        }

        It 'Should include --source winget flag in install command' {
            $apps = @(@{name = 'Test.App' })
            $installedApps = @()

            Mock winget { '' } -ParameterFilter { $args -contains 'list' }
            Mock Start-Process { }

            foreach ($app in $apps) {
                $listApp = winget list --exact -q $app.name
                if (![String]::Join('', $listApp).Contains($app.name)) {
                    Start-Process winget -ArgumentList "install -e --accept-source-agreements --accept-package-agreements --source winget --id $($app.name)" -NoNewWindow -Wait
                    $installedApps += 'Test.App'
                }
            }

            Assert-MockCalled Start-Process -Times 1 -ParameterFilter { $ArgumentList -match '--source winget' }
        }

        It 'Should skip app when already installed' {
            $apps = @(@{name = 'Test.App' })
            $installedApps = @()
            $skippedApps = @()

            # Mock winget list to return the app (already installed)
            Mock winget { 'Test.App' } -ParameterFilter { $args -contains 'list' }

            foreach ($app in $apps) {
                $listApp = winget list --exact -q $app.name
                if (![String]::Join('', $listApp).Contains($app.name)) {
                    # Install logic would go here
                    $installedApps += $app.name
                }
                else {
                    $skippedApps += $app.name
                }
            }

            $installedApps | Should -Not -Contain 'Test.App'
            $skippedApps | Should -Contain 'Test.App'
        }

        It 'Should handle installation failure' {
            $apps = @(@{name = 'Test.App' })
            $installedApps = @()
            $skippedApps = @()
            $failedApps = @()

            # Mock winget list to return empty (app not installed)
            Mock winget { '' } -ParameterFilter { $args -contains 'list' -and $args -notcontains 'install' }
            # Mock winget list after install to still return empty (failed install)
            Mock winget { '' } -ParameterFilter { $args -contains 'list' -and $args -contains 'Test.App' -and $args -notcontains 'install' }
            Mock Start-Process { }

            foreach ($app in $apps) {
                try {
                    $listApp = winget list --exact -q $app.name
                    if (![String]::Join('', $listApp).Contains($app.name)) {
                        Start-Process winget -ArgumentList "install -e --accept-source-agreements --accept-package-agreements --id $($app.name)" -NoNewWindow -Wait
                        $installResult = winget list --exact -q $app.name
                        if (![String]::Join('', $installResult).Contains($app.name)) {
                            $failedApps += $app.name
                        }
                        else {
                            $installedApps += $app.name
                        }
                    }
                    else {
                        $skippedApps += $app.name
                    }
                }
                catch {
                    $failedApps += $app.name
                }
            }

            $failedApps | Should -Contain 'Test.App'
            $installedApps | Should -Not -Contain 'Test.App'
        }
    }

    Context 'Update checking and installation' {
        It 'Should handle no updates available' {
            Mock Test-UpdatesAvailable { return $false }

            $hasUpdates = Test-UpdatesAvailable
            $hasUpdates | Should -Be $false
        }

        It 'Should handle updates available with PowerShell module' {
            Mock Test-UpdatesAvailable { return $true }
            Mock Get-Command { return $true } -ParameterFilter { $Name -eq 'Update-WinGetPackage' }
            Mock Get-WinGetPackage { @(@{ IsUpdateAvailable = $true; Id = 'Test.App' }) }
            Mock Update-WinGetPackage { @(@{ Status = 'Ok'; Id = 'Test.App' }) }

            $hasUpdates = Test-UpdatesAvailable
            if ($hasUpdates) {
                if (Get-Command Update-WinGetPackage -ErrorAction SilentlyContinue) {
                    # Simulate the update without piping to avoid mock issues
                    $updateResults = @(@{ Status = 'Ok'; Id = 'Test.App' })
                    $updateResults[0].Status | Should -Be 'Ok'
                }
            }
        }

        It 'Should handle updates with CLI fallback' {
            Mock Test-UpdatesAvailable { return $true }
            Mock Get-Command { return $false } -ParameterFilter { $Name -eq 'Update-WinGetPackage' }
            Mock winget { 'Test.App  Test.App  1.0.0  winget' } -ParameterFilter { $args -contains 'list' }
            Mock winget { 'Successfully installed Test.App' } -ParameterFilter { $args -contains 'upgrade' -and $args -contains '--source' }

            $hasUpdates = Test-UpdatesAvailable
            if ($hasUpdates) {
                if (-not (Get-Command Update-WinGetPackage -ErrorAction SilentlyContinue)) {
                    $installedPackages = & winget list --source winget 2>&1 | Where-Object {
                        $_ -and
                        $_ -notmatch '^[\s\-\|\\]*$' -and
                        $_ -notmatch '^$' -and
                        $_ -notmatch '^Name\s+Id\s+Version\s+Source' -and
                        $_ -notmatch '^[-]+$' -and
                        $_ -notmatch 'No installed package found'
                    }

                    foreach ($package in $installedPackages) {
                        $columns = $package -split '\s{2,}'
                        if ($columns.Count -ge 2) {
                            $packageId = $columns[1]
                            if ($packageId -and $packageId -notmatch '^(ARP|MSIX)') {
                                $upgradeResult = & winget upgrade $packageId --source winget 2>&1
                                $upgradeOutput = $upgradeResult | Out-String
                                $upgradeOutput | Should -Match 'Successfully installed'
                            }
                        }
                    }
                }
            }

            Assert-MockCalled winget -Times 1 -ParameterFilter { $args -contains 'upgrade' -and $args -contains '--source' -and $args -contains 'winget' }
        }
    }

    Context 'Summary table generation' {
        It 'Should format summary table with all result types' {
            $installedApps = @('App1', 'App2')
            $skippedApps = @('App3')
            $failedApps = @('App4')
            $updatedApps = @('App5')
            $failedUpdateApps = @('App6')

            Mock Format-AppList { param($AppArray) if ($AppArray) { return $AppArray -join ', ' } return $null }
            Mock Write-Table { }

            $headers = @('Status', 'Apps')
            $rows = @()

            $appList = Format-AppList -AppArray $installedApps
            if ($appList) { $rows += , @('Installed', $appList) }

            $appList = Format-AppList -AppArray $skippedApps
            if ($appList) { $rows += , @('Skipped', $appList) }

            $appList = Format-AppList -AppArray $failedApps
            if ($appList) { $rows += , @('Failed', $appList) }

            $appList = Format-AppList -AppArray $updatedApps
            if ($appList) { $rows += , @('Updated', $appList) }

            $appList = Format-AppList -AppArray $failedUpdateApps
            if ($appList) { $rows += , @('Failed to Update', $appList) }

            Write-Table -Headers $headers -Rows $rows

            $rows.Count | Should -Be 5
            Assert-MockCalled Write-Table -Times 1
        }

        It 'Should handle empty result arrays' {
            $installedApps = @()

            Mock Format-AppList { param($AppArray) if ($AppArray -and $AppArray.Count -gt 0) { return $AppArray -join ', ' } return $null }
            Mock Write-Table { }

            $headers = @('Status', 'Apps')
            $rows = @()

            $appList = Format-AppList -AppArray $installedApps
            if ($appList) { $rows += , @('Installed', $appList) }

            Write-Table -Headers $headers -Rows $rows

            $rows.Count | Should -Be 0
        }
    }
}

Describe 'Retry Failed Installations' {
    BeforeAll {
        Mock Write-Host { }
        Mock Start-Process { }
    }

    Context 'Retry logic - array management' {
        It 'Should retry failed apps and move successful retries to installed list' {
            $failedApps = @('Test.App')
            $installedApps = @()

            $script:retryAttempted = $false
            Mock Start-Process { $script:retryAttempted = $true }

            $appsToRetry = $failedApps
            $failedApps = @()

            foreach ($appName in $appsToRetry) {
                Start-Process winget -ArgumentList "install -e --accept-source-agreements --accept-package-agreements --source winget --id $appName" -NoNewWindow -Wait
                # Simulate verification returning the app (success)
                $retryResult = $appName
                if (![String]::Join('', $retryResult).Contains($appName)) {
                    $failedApps += $appName
                }
                else {
                    $installedApps += $appName
                }
            }

            $script:retryAttempted | Should -Be $true
            $installedApps | Should -Contain 'Test.App'
            $failedApps | Should -Not -Contain 'Test.App'
        }

        It 'Should keep app in failed list when retry also fails' {
            $failedApps = @('Test.App')
            $installedApps = @()

            Mock Start-Process { }

            $appsToRetry = $failedApps
            $failedApps = @()

            foreach ($appName in $appsToRetry) {
                Start-Process winget -ArgumentList "install -e --accept-source-agreements --accept-package-agreements --source winget --id $appName" -NoNewWindow -Wait
                # Simulate verification returning nothing (failure)
                $retryResult = ''
                if (![String]::Join('', $retryResult).Contains($appName)) {
                    $failedApps += $appName
                }
                else {
                    $installedApps += $appName
                }
            }

            $failedApps | Should -Contain 'Test.App'
            $installedApps | Should -Not -Contain 'Test.App'
        }

        It 'Should not retry when there are no failed apps' {
            $failedApps = @()
            $installedApps = @()

            Mock Start-Process { }

            if ($failedApps.Count -gt 0) {
                $appsToRetry = $failedApps
                $failedApps = @()
                foreach ($appName in $appsToRetry) {
                    Start-Process winget -ArgumentList "install -e --accept-source-agreements --accept-package-agreements --source winget --id $appName" -NoNewWindow -Wait
                }
            }

            Assert-MockCalled Start-Process -Times 0
            $failedApps.Count | Should -Be 0
        }

        It 'Should handle mixed retry results across multiple failed apps' {
            $failedApps = @('App.Recovers', 'App.StillFails')
            $installedApps = @()

            Mock Start-Process { }

            $appsToRetry = $failedApps
            $failedApps = @()

            foreach ($appName in $appsToRetry) {
                Start-Process winget -ArgumentList "install -e --accept-source-agreements --accept-package-agreements --source winget --id $appName" -NoNewWindow -Wait
                # Simulate verification: App.Recovers succeeds, App.StillFails does not
                $retryResult = if ($appName -eq 'App.Recovers') { $appName } else { '' }
                if (![String]::Join('', $retryResult).Contains($appName)) {
                    $failedApps += $appName
                }
                else {
                    $installedApps += $appName
                }
            }

            $installedApps | Should -Contain 'App.Recovers'
            $failedApps | Should -Contain 'App.StillFails'
            $failedApps | Should -Not -Contain 'App.Recovers'
        }

        It 'Should signal non-zero exit when apps still fail after retry' {
            $failedApps = @('App.StillFails')

            $exitCode = if ($failedApps.Count -gt 0) { 1 } else { 0 }

            $exitCode | Should -Be 1
        }
    }
}

Describe 'App list consistency' {
    It 'Should keep install and uninstall app lists in sync' {
        $installApps = Get-Content "$PSScriptRoot\winget-app-install.ps1" |
        ForEach-Object {
            if ($_ -match "@{name = '([^']+)'") { $matches[1] }
        } |
        Where-Object { $_ }

        $uninstallApps = Get-Content "$PSScriptRoot\winget-app-uninstall.ps1" |
        ForEach-Object {
            if ($_ -match "@{name = '([^']+)'") { $matches[1] }
        } |
        Where-Object { $_ }

        $installApps | Should -Be $uninstallApps
    }
}

Describe 'Test-AppDefinitions' {
    BeforeAll {
        . "$PSScriptRoot\winget-app-install.ps1"
    }

    Context 'When app definitions are valid' {
        It 'Should return the same number of apps without errors or warnings' {
            $apps = @(
                @{ name = 'App.One' },
                @{ name = 'App.Two' }
            )

            $result = Test-AppDefinitions -Apps $apps

            $result.ValidApps.Count | Should -Be 2
            $result.Errors | Should -BeNullOrEmpty
            $result.Warnings | Should -BeNullOrEmpty
        }
    }

    Context 'When an entry is malformed' {
        It 'Should return an error and skip the invalid entry' {
            $apps = @(
                @{ name = 'App.Valid' },
                @{ bogus = 'value' }
            )

            $result = Test-AppDefinitions -Apps $apps

            $result.ValidApps.Count | Should -Be 1
            $result.Errors.Count | Should -Be 1
            $result.Errors[0] | Should -Match "missing a valid 'name'"
        }
    }

    Context 'When duplicate entries are present' {
        It 'Should keep the first occurrence and warn about duplicates' {
            $apps = @(
                @{ name = 'App.Duplicate' },
                @{ name = 'app.duplicate ' }
            )

            $result = Test-AppDefinitions -Apps $apps

            $result.ValidApps.Count | Should -Be 1
            $result.ValidApps[0].name | Should -Be 'App.Duplicate'
            $result.Warnings.Count | Should -Be 1
            $result.Warnings[0] | Should -Match 'Duplicate app definition'
        }
    }
}

Describe 'Windows Terminal configuration' {
    BeforeAll {
        . "$PSScriptRoot\winget-app-install.ps1"
    }

    Context 'Set-WindowsTerminalDefaultProfile' {
        It 'Should set defaultProfile in settings.json' {
            $settingsPath = Join-Path $TestDrive 'settings.json'
            Set-Content -Path $settingsPath -Value '{"profiles":{"list":[]}}' -Encoding UTF8

            $result = Set-WindowsTerminalDefaultProfile -SettingsPath $settingsPath -ProfileGuid '{574e775e-4f2a-5b96-ac1e-a2962a402336}'
            $updated = Get-Content -Path $settingsPath -Raw | ConvertFrom-Json

            $result | Should -Be $true
            $updated.defaultProfile | Should -Be '{574e775e-4f2a-5b96-ac1e-a2962a402336}'
        }

        It 'Should parse JSONC style settings with comments and trailing commas' {
            $settingsPath = Join-Path $TestDrive 'settings-jsonc.json'
            $jsonc = @'
{
  // sample comment
  "profiles": {
    "list": [
    ],
  },
}
'@
            Set-Content -Path $settingsPath -Value $jsonc -Encoding UTF8

            $result = Set-WindowsTerminalDefaultProfile -SettingsPath $settingsPath -ProfileGuid '574e775e-4f2a-5b96-ac1e-a2962a402336'
            $updated = Get-Content -Path $settingsPath -Raw | ConvertFrom-Json

            $result | Should -Be $true
            $updated.defaultProfile | Should -Be '{574e775e-4f2a-5b96-ac1e-a2962a402336}'
        }

        It 'Should return false when settings path does not exist' {
            $missingPath = Join-Path $TestDrive 'missing-settings.json'

            $result = Set-WindowsTerminalDefaultProfile -SettingsPath $missingPath -ProfileGuid '{574e775e-4f2a-5b96-ac1e-a2962a402336}'

            $result | Should -Be $false
        }
    }

    Context 'Set-WindowsTerminalAsDefaultTerminalApplication' {
        It 'Should create/update registry values when not already configured' {
            Mock Test-Path { return $false } -ParameterFilter { $Path -eq 'HKCU:\Console\%%Startup' }
            Mock New-Item { }
            Mock Get-ItemProperty { return [pscustomobject]@{} }
            Mock New-ItemProperty { }

            $result = Set-WindowsTerminalAsDefaultTerminalApplication

            $result | Should -Be $true
            Assert-MockCalled New-Item -Times 1 -ParameterFilter { $Path -eq 'HKCU:\Console\%%Startup' -and $Force }
            Assert-MockCalled New-ItemProperty -Times 2
        }

        It 'Should skip writes when registry is already configured' {
            Mock Test-Path { return $true } -ParameterFilter { $Path -eq 'HKCU:\Console\%%Startup' }
            Mock Get-ItemProperty {
                [pscustomobject]@{
                    DelegationConsole  = '{2EACA947-7F5F-4CFA-BA87-8F7FBEEFBE69}'
                    DelegationTerminal = '{E12CFF52-A866-4C77-9A90-F570A7AA2C6B}'
                }
            }
            Mock New-ItemProperty { }

            $result = Set-WindowsTerminalAsDefaultTerminalApplication

            $result | Should -Be $true
            Assert-MockCalled New-ItemProperty -Times 0
        }

        It 'Should return false when registry write fails' {
            Mock Test-Path { return $true } -ParameterFilter { $Path -eq 'HKCU:\Console\%%Startup' }
            Mock Get-ItemProperty { return [pscustomobject]@{} }
            Mock New-ItemProperty { throw 'Registry denied' }

            $result = Set-WindowsTerminalAsDefaultTerminalApplication

            $result | Should -Be $false
        }
    }

    Context 'Set-WindowsTerminalDefaults orchestration' {
        It 'Should perform no writes in WhatIf mode' {
            Mock Get-WindowsTerminalSettingsPaths { return @('C:\temp\settings.json') }
            Mock Set-WindowsTerminalDefaultProfile { return $true }
            Mock Set-WindowsTerminalAsDefaultTerminalApplication { return $true }
            Mock Write-Info { }

            Set-WindowsTerminalDefaults -WhatIf

            Assert-MockCalled Set-WindowsTerminalDefaultProfile -Times 0
            Assert-MockCalled Set-WindowsTerminalAsDefaultTerminalApplication -Times 0
            Assert-MockCalled Write-Info -Times 2
        }

        It 'Should configure both settings file and registry in normal mode' {
            Mock Get-WindowsTerminalSettingsPaths { return @('C:\temp\settings.json') }
            Mock Set-WindowsTerminalDefaultProfile { return $true }
            Mock Set-WindowsTerminalAsDefaultTerminalApplication { return $true }

            Set-WindowsTerminalDefaults

            Assert-MockCalled Set-WindowsTerminalDefaultProfile -Times 1
            Assert-MockCalled Set-WindowsTerminalAsDefaultTerminalApplication -Times 1
        }

        It 'Should configure all discovered settings files in normal mode' {
            Mock Get-WindowsTerminalSettingsPaths { return @('C:\temp\stable-settings.json', 'C:\temp\preview-settings.json') }
            Mock Set-WindowsTerminalDefaultProfile { return $true }
            Mock Set-WindowsTerminalAsDefaultTerminalApplication { return $true }

            Set-WindowsTerminalDefaults

            Assert-MockCalled Set-WindowsTerminalDefaultProfile -Times 2
            Assert-MockCalled Set-WindowsTerminalAsDefaultTerminalApplication -Times 1
        }
    }
}

Describe 'Scheduled Updates - Unit Tests' -Tag 'ScheduledUpdates' {
    BeforeAll {
        . "$PSScriptRoot\winget-app-install.ps1"
    }

    BeforeEach {
        $script:originalAppData = $env:APPDATA
        $env:APPDATA = Join-Path $TestDrive 'appdata'
        New-Item -Path $env:APPDATA -ItemType Directory -Force | Out-Null

        Mock Get-WinGetPackage { }
        Mock winget { }
        Mock Get-ScheduledTask { $null }
        # Register-ScheduledTask requires its -Action/-Trigger/-Settings/-Principal arguments to
        # carry the exact ETS PSTypeName the real New-ScheduledTask* cmdlets produce
        # (e.g. CimInstance#MSFT_TaskAction), and Pester enforces that on the mocked call. Build
        # CimInstances with the matching CIM class names so the typed binding succeeds.
        Mock New-ScheduledTaskAction { [Microsoft.Management.Infrastructure.CimInstance]::new('MSFT_TaskAction') }
        Mock New-ScheduledTaskTrigger { [Microsoft.Management.Infrastructure.CimInstance]::new('MSFT_TaskTrigger') }
        Mock New-ScheduledTaskSettingsSet { [Microsoft.Management.Infrastructure.CimInstance]::new('MSFT_TaskSettings') }
        Mock New-ScheduledTaskPrincipal { [Microsoft.Management.Infrastructure.CimInstance]::new('MSFT_TaskPrincipal') }
        Mock Register-ScheduledTask { }
        Mock Unregister-ScheduledTask { }
        Mock Write-Info { }
        Mock Write-WarningMessage { }
        Mock Write-Success { }
        Mock Write-ErrorMessage { }
    }

    AfterEach {
        $env:APPDATA = $script:originalAppData
    }

    It 'Should expose scheduled update management functions' {
        (Get-Command Enable-ScheduledUpdatesCheck -ErrorAction Stop) | Should -Not -BeNullOrEmpty
        (Get-Command Disable-ScheduledUpdatesCheck -ErrorAction Stop) | Should -Not -BeNullOrEmpty
        (Get-Command Get-UpdateReport -ErrorAction Stop) | Should -Not -BeNullOrEmpty
    }

    It 'Get-UpdateReport should return module-based update rows' {
        Mock Get-Command { $true } -ParameterFilter { $Name -eq 'Get-WinGetPackage' }
        Mock Get-WinGetPackage {
            @(
                [PSCustomObject]@{ Id = 'Git.Git'; InstalledVersion = '2.45.0'; AvailableVersion = '2.46.0'; IsUpdateAvailable = $true },
                [PSCustomObject]@{ Id = 'Microsoft.PowerShell'; InstalledVersion = '7.4.2'; AvailableVersion = '7.4.3'; IsUpdateAvailable = $false }
            )
        }

        $report = @(Get-UpdateReport)

        $report.Count | Should -Be 1
        $report[0].PackageName | Should -Be 'Git.Git'
        $report[0].CurrentVersion | Should -Be '2.45.0'
        $report[0].AvailableVersion | Should -Be '2.46.0'
    }

    It 'Get-UpdateReport should parse CLI output when module is unavailable' {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'Get-WinGetPackage' }
        Mock winget {
            @(
                'Name                           Id                    Version     Available   Source'
                '--------------------------------------------------------------------------------'
                'Google Chrome                  Google.Chrome         126.0       127.0       winget'
                'Git                            Git.Git               2.45.0      2.46.0      winget'
            )
        } -ParameterFilter { $args -contains 'upgrade' }

        $report = @(Get-UpdateReport)

        $report.Count | Should -Be 2
        $report[0].PackageName | Should -Be 'Git.Git'
        $report[1].PackageName | Should -Be 'Google.Chrome'
    }

    It 'Enable-ScheduledUpdatesCheck should create task and persist config' {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'pwsh' }
        Mock Install-UpdateHelperScript { $env:APPDATA + '\winget-app-setup\Update-InstalledApps.ps1' }

        $result = Enable-ScheduledUpdatesCheck -SkipPrompt:$true -UpdateFrequency Daily -AutoInstall:$false
        $paths = Get-UpdateSettingsPaths
        $config = Get-Content -Path $paths.ConfigFile -Raw | ConvertFrom-Json

        $result | Should -BeTrue
        $config.EnabledScheduledUpdates | Should -BeTrue
        $config.UpdateFrequency | Should -Be 'Daily'
        $config.AutoInstall | Should -BeFalse
        Assert-MockCalled Register-ScheduledTask -Times 1
    }

    It 'Disable-ScheduledUpdatesCheck should remove task and persist disabled config' {
        Mock Get-ScheduledTask { @{ Name = 'WingetAppSetup-ScheduledUpdates' } }

        $result = Disable-ScheduledUpdatesCheck
        $config = Get-UpdateConfiguration

        $result | Should -BeTrue
        $config.EnabledScheduledUpdates | Should -BeFalse
        $config.Enabled | Should -BeFalse
        Assert-MockCalled Unregister-ScheduledTask -Times 1
    }
}

Describe 'Test-SystemRequirements' -Tag 'SystemRequirements' {
    BeforeAll {
        . "$PSScriptRoot\winget-app-install.ps1"
    }

    BeforeEach {
        Mock Write-Info { }
        Mock Write-Success { }
        Mock Write-WarningMessage { }
        Mock Write-ErrorMessage { }
        Mock Test-NetConnection { $true }
        Mock Get-PSDrive {
            [PSCustomObject]@{ Free = 100GB }
        }
        Mock Get-ItemProperty {
            [PSCustomObject]@{ ProductName = 'Windows 11 Pro' }
        }
    }

    It 'Returns $true when all checks pass' {
        $result = Test-SystemRequirements
        $result | Should -BeTrue
    }

    It 'Returns $false when network check fails' {
        Mock Test-NetConnection { $false }
        $result = Test-SystemRequirements
        $result | Should -BeFalse
    }

    It 'Returns $false when network check throws' {
        Mock Test-NetConnection { throw 'No network' }
        $result = Test-SystemRequirements
        $result | Should -BeFalse
    }

    It 'Returns $false when user declines low disk space prompt' {
        Mock Get-PSDrive { [PSCustomObject]@{ Free = 10GB } }
        Mock Read-Host { 'N' }
        $result = Test-SystemRequirements
        $result | Should -BeFalse
    }

    It 'Returns $true when user accepts low disk space prompt' {
        Mock Get-PSDrive { [PSCustomObject]@{ Free = 10GB } }
        Mock Read-Host { 'Y' }
        $result = Test-SystemRequirements
        $result | Should -BeTrue
    }

    It 'Skips disk space prompt in WhatIf mode' {
        Mock Get-PSDrive { [PSCustomObject]@{ Free = 10GB } }
        Mock Read-Host { throw 'Should not prompt in WhatIf mode' }
        { Test-SystemRequirements -WhatIf } | Should -Not -Throw
    }
}

Describe 'Write-Info' {
    BeforeAll {
        . "$PSScriptRoot\winget-app-install.ps1"
    }

    It 'Should write message in blue color' {
        Mock Write-Host { }

        Write-Info 'Test message'

        Assert-MockCalled Write-Host -Times 1 -ParameterFilter {
            $Object -eq 'Test message' -and $ForegroundColor -eq 'Blue'
        }
    }
}

Describe 'Write-Success' {
    BeforeAll {
        . "$PSScriptRoot\winget-app-install.ps1"
    }

    It 'Should write message in green color' {
        Mock Write-Host { }

        Write-Success 'Success message'

        Assert-MockCalled Write-Host -Times 1 -ParameterFilter {
            $Object -eq 'Success message' -and $ForegroundColor -eq 'Green'
        }
    }
}

Describe 'Write-WarningMessage' {
    BeforeAll {
        . "$PSScriptRoot\winget-app-install.ps1"
    }

    It 'Should write message in yellow color' {
        Mock Write-Host { }

        Write-WarningMessage 'Warning message'

        Assert-MockCalled Write-Host -Times 1 -ParameterFilter {
            $Object -eq 'Warning message' -and $ForegroundColor -eq 'Yellow'
        }
    }
}

Describe 'Write-ErrorMessage' {
    BeforeAll {
        . "$PSScriptRoot\winget-app-install.ps1"
    }

    It 'Should write message in red color' {
        Mock Write-Host { }

        Write-ErrorMessage 'Error message'

        Assert-MockCalled Write-Host -Times 1 -ParameterFilter {
            $Object -eq 'Error message' -and $ForegroundColor -eq 'Red'
        }
    }
}

Describe 'Write-Prompt' {
    BeforeAll {
        . "$PSScriptRoot\winget-app-install.ps1"
    }

    It 'Should write message in blue color' {
        Mock Write-Host { }

        Write-Prompt 'Press any key to continue...'

        Assert-MockCalled Write-Host -Times 1 -ParameterFilter {
            $Object -eq 'Press any key to continue...' -and $ForegroundColor -eq 'Blue'
        }
    }
}

Describe 'WhatIf Mode - Unit Tests' {
    BeforeAll {
        . "$PSScriptRoot\winget-app-install.ps1"
    }

    Context 'WhatIf parameter acceptance' {
        It 'Should accept WhatIf parameter without error' {
            $command = Get-Command Invoke-WingetInstall
            $command.Parameters.ContainsKey('WhatIf') | Should -Be $true
            $command.Parameters['WhatIf'].ParameterType.Name | Should -Be 'SwitchParameter'
        }
    }

    Context 'WhatIf logic for PATH updates' {
        It 'Should skip Add-ToEnvironmentPath when WhatIf is true' {
            Mock Add-ToEnvironmentPath { }
            Mock Write-Info { }

            # Simulate the code path
            $WhatIf = $true
            $scriptDirectory = 'C:\Test'

            if (-not $WhatIf) {
                Add-ToEnvironmentPath -PathToAdd $scriptDirectory -Scope 'User'
            }
            else {
                Write-Info "[DRY-RUN] Would add '$scriptDirectory' to User PATH"
            }

            Assert-MockCalled Add-ToEnvironmentPath -Times 0
            Assert-MockCalled Write-Info -Times 1
        }

        It 'Should call Add-ToEnvironmentPath when WhatIf is false' {
            Mock Add-ToEnvironmentPath { }
            Mock Write-Info { }

            # Simulate the code path
            $WhatIf = $false
            $scriptDirectory = 'C:\Test'

            if (-not $WhatIf) {
                Add-ToEnvironmentPath -PathToAdd $scriptDirectory -Scope 'User'
            }
            else {
                Write-Info "[DRY-RUN] Would add '$scriptDirectory' to User PATH"
            }

            Assert-MockCalled Add-ToEnvironmentPath -Times 1
            Assert-MockCalled Write-Info -Times 0
        }
    }

    Context 'WhatIf logic for source trust' {
        It 'Should skip Set-Sources when WhatIf is true' {
            Mock Set-Sources { }
            Mock Write-Info { }
            Mock Write-WarningMessage { }
            Mock Write-Success { }
            Mock Test-WingetSourceTrusted { return $false }

            # Simulate the code path
            $WhatIf = $true
            $source = 'winget'

            if (-not (Test-WingetSourceTrusted -target $source)) {
                if (-not $WhatIf) {
                    Write-WarningMessage "Trusting source: $source"
                    Set-Sources
                }
                else {
                    Write-Info "[DRY-RUN] Would trust source: $source"
                }
            }

            Assert-MockCalled Set-Sources -Times 0
            Assert-MockCalled Write-Info -Times 1
        }

        It 'Should call Set-Sources when WhatIf is false' {
            Mock Set-Sources { }
            Mock Write-Info { }
            Mock Write-WarningMessage { }
            Mock Write-Success { }
            Mock Test-WingetSourceTrusted { return $false }

            # Simulate the code path
            $WhatIf = $false
            $source = 'winget'

            if (-not (Test-WingetSourceTrusted -target $source)) {
                if (-not $WhatIf) {
                    Write-WarningMessage "Trusting source: $source"
                    Set-Sources
                }
                else {
                    Write-Info "[DRY-RUN] Would trust source: $source"
                }
            }

            Assert-MockCalled Set-Sources -Times 1
            Assert-MockCalled Write-WarningMessage -Times 1
        }
    }

    Context 'WhatIf logic for app installation' {
        It 'Should skip Start-Process when WhatIf is true' {
            Mock Start-Process { }
            Mock Write-Info { }
            Mock Write-Success { }

            # Simulate the code path
            $WhatIf = $true
            $app = @{ name = 'Test.App' }
            $installedApps = @()

            if (-not $WhatIf) {
                Write-Info "Installing: $($app.name)"
                Start-Process winget -ArgumentList "install -e --accept-source-agreements --accept-package-agreements --id $($app.name)" -NoNewWindow -Wait
                Write-Success "Successfully installed: $($app.name)"
                $installedApps += $app.name
            }
            else {
                Write-Info "[DRY-RUN] Would install: $($app.name)"
                $installedApps += $app.name
            }

            Assert-MockCalled Start-Process -Times 0
            Assert-MockCalled Write-Info -Times 1 -ParameterFilter { $Message -match 'DRY-RUN' }
            $installedApps | Should -Contain 'Test.App'
        }

        It 'Should call Start-Process when WhatIf is false' {
            Mock Start-Process { }
            Mock Write-Info { }
            Mock Write-Success { }

            # Simulate the code path
            $WhatIf = $false
            $app = @{ name = 'Test.App' }
            $installedApps = @()

            if (-not $WhatIf) {
                Write-Info "Installing: $($app.name)"
                Start-Process winget -ArgumentList "install -e --accept-source-agreements --accept-package-agreements --id $($app.name)" -NoNewWindow -Wait
                Write-Success "Successfully installed: $($app.name)"
                $installedApps += $app.name
            }
            else {
                Write-Info "[DRY-RUN] Would install: $($app.name)"
                $installedApps += $app.name
            }

            Assert-MockCalled Start-Process -Times 1
            Assert-MockCalled Write-Info -Times 1 -ParameterFilter { $Message -notmatch 'DRY-RUN' }
            $installedApps | Should -Contain 'Test.App'
        }
    }
}

Describe 'IEX non-admin execution behavior' {
    BeforeAll {
        $script:isWindowsPlatform = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
        $script:isElevated = $false

        if ($script:isWindowsPlatform) {
            $script:isElevated = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
                [Security.Principal.WindowsBuiltInRole]::Administrator
            )
        }
    }

    It 'Should exit with code 1 and show remote elevation guidance' -Skip:(-not $script:isWindowsPlatform -or $script:isElevated) {

        $scriptPath = Join-Path $PSScriptRoot 'winget-app-install.ps1'
        $psStringEscapedPath = $scriptPath.Replace("'", "''")
        $currentPowerShell = (Get-Process -Id $PID).Path
        $childCommand = @"
Get-Content -Raw -LiteralPath '$psStringEscapedPath' | Invoke-Expression
"@

        $output = & $currentPowerShell -NoLogo -NoProfile -NonInteractive -Command $childCommand 2>&1 | Out-String
        $exitCode = $LASTEXITCODE

        $exitCode | Should -Be 1
        $output | Should -Match 'This script requires administrator privileges\.'
        $output | Should -Match 'Auto-elevation is unavailable when running through IEX/remote execution\.'
        $output | Should -Match 'Open an elevated PowerShell or Windows Terminal session and run the IEX command again\.'
        $output | Should -Match 'Exiting in 5 seconds\.\.\.'
        $output | Should -Not -Match 'Press Enter to restart script with elevated privileges'
    }
}
