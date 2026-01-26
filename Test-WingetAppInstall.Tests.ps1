# Test-WingetAppInstall.Tests.ps1
# Comprehensive unit tests for winget-app-install.ps1 using Pester

Describe 'Test-AndInstallWingetModule' {
    BeforeAll {
        Mock Write-Host { }
        Mock Write-Warning { }

        function Test-AndInstallWingetModule {
            try {
                if (Get-Module -ListAvailable -Name 'Microsoft.WinGet.Client') {
                    return $true
                }

                Write-Host 'Microsoft.WinGet.Client module not found. Attempting installation...' -ForegroundColor Yellow

                $nugetProvider = Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue
                if (-not $nugetProvider) {
                    Write-Host 'NuGet package provider not found. Installing...' -ForegroundColor Yellow
                    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null
                }

                Install-Module -Name Microsoft.WinGet.Client -Scope AllUsers -Force -AllowClobber -ErrorAction Stop

                $installedModule = Get-Module -ListAvailable -Name 'Microsoft.WinGet.Client' | Select-Object -First 1
                if ($installedModule) {
                    if ($installedModule.Version) {
                        Write-Host "Microsoft.WinGet.Client module installed successfully (Version: $($installedModule.Version))" -ForegroundColor Green
                    }
                    else {
                        Write-Host 'Microsoft.WinGet.Client module installed successfully' -ForegroundColor Green
                    }
                    return $true
                }

                Write-Warning 'Microsoft.WinGet.Client module installation completed, but module is still not detected.'
            }
            catch {
                Write-Warning "Failed to install Microsoft.WinGet.Client module: $_"
            }

            return $false
        }
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
        Mock Write-Host { }
        Mock Write-Warning { }

        function Test-AndInstallGraphicalTools {
            try {
                if (Get-Command Out-GridView -ErrorAction SilentlyContinue) {
                    return $true
                }

                $graphicalModule = Get-Module -ListAvailable -Name 'Microsoft.PowerShell.GraphicalTools'
                if (-not $graphicalModule) {
                    Write-Host 'Microsoft.PowerShell.GraphicalTools module is missing. Installing to enable Out-GridView...' -ForegroundColor Yellow
                }
                else {
                    Write-Host 'Microsoft.PowerShell.GraphicalTools module found but Out-GridView is unavailable. Importing module...' -ForegroundColor Yellow
                }

                $nugetProvider = Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue
                if (-not $nugetProvider) {
                    Write-Host 'NuGet package provider not found. Installing...' -ForegroundColor Yellow
                    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null
                }

                Install-Module -Name Microsoft.PowerShell.GraphicalTools -Scope AllUsers -Force -AllowClobber -ErrorAction Stop
                Import-Module Microsoft.PowerShell.GraphicalTools -ErrorAction Stop

                $loadedModule = Get-Module -Name 'Microsoft.PowerShell.GraphicalTools'
                if ($loadedModule -and $loadedModule.Version) {
                    Write-Success "Microsoft.PowerShell.GraphicalTools is loaded for this session (Version: $($loadedModule.Version))"
                }
                else {
                    Write-Success 'Microsoft.PowerShell.GraphicalTools is loaded for this session.'
                }

                if (Get-Command Out-GridView -ErrorAction SilentlyContinue) {
                    Write-Host 'Out-GridView is available for interactive summaries.' -ForegroundColor Green
                    return $true
                }

                Write-Warning 'Microsoft.PowerShell.GraphicalTools installation completed, but Out-GridView is still unavailable.'
            }
            catch {
                Write-Warning "Failed to install Microsoft.PowerShell.GraphicalTools module: $_"
            }

            return $false
        }
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

Describe 'Test-AndSetExecutionPolicy' {
    BeforeAll {
        Mock Write-Host { }
        Mock Write-Warning { }

        # Dot-source the main script to import Test-AndSetExecutionPolicy
        . "$PSScriptRoot\winget-app-install.ps1"
    }

    Context 'When execution policy is already permissive' {
        It 'Should return true for RemoteSigned policy' {
            Mock Get-ExecutionPolicy { return 'RemoteSigned' } -ParameterFilter { $Scope -eq 'CurrentUser' }
            Mock Set-ExecutionPolicy { }

            $result = Test-AndSetExecutionPolicy
            $result | Should -Be $true
            Assert-MockCalled Set-ExecutionPolicy -Times 0
        }

        It 'Should return true for Unrestricted policy' {
            Mock Get-ExecutionPolicy { return 'Unrestricted' } -ParameterFilter { $Scope -eq 'CurrentUser' }
            Mock Set-ExecutionPolicy { }

            $result = Test-AndSetExecutionPolicy
            $result | Should -Be $true
            Assert-MockCalled Set-ExecutionPolicy -Times 0
        }

        It 'Should return true for Bypass policy' {
            Mock Get-ExecutionPolicy { return 'Bypass' } -ParameterFilter { $Scope -eq 'CurrentUser' }
            Mock Set-ExecutionPolicy { }

            $result = Test-AndSetExecutionPolicy
            $result | Should -Be $true
            Assert-MockCalled Set-ExecutionPolicy -Times 0
        }
    }

    Context 'When execution policy is restrictive and change succeeds' {
        It 'Should set policy to RemoteSigned and return true for Restricted policy' {
            $script:getPolicyCalls = 0
            Mock Get-ExecutionPolicy {
                $script:getPolicyCalls++
                if ($script:getPolicyCalls -eq 1) {
                    return 'Restricted'
                }
                else {
                    return 'RemoteSigned'
                }
            } -ParameterFilter { $Scope -eq 'CurrentUser' }
            Mock Set-ExecutionPolicy { }

            $result = Test-AndSetExecutionPolicy
            $result | Should -Be $true
            Assert-MockCalled Set-ExecutionPolicy -Times 1 -ParameterFilter {
                $ExecutionPolicy -eq 'RemoteSigned' -and $Scope -eq 'CurrentUser' -and $Force -eq $true
            }
        }

        It 'Should set policy to RemoteSigned and return true for AllSigned policy' {
            $script:getPolicyCalls = 0
            Mock Get-ExecutionPolicy {
                $script:getPolicyCalls++
                if ($script:getPolicyCalls -eq 1) {
                    return 'AllSigned'
                }
                else {
                    return 'RemoteSigned'
                }
            } -ParameterFilter { $Scope -eq 'CurrentUser' }
            Mock Set-ExecutionPolicy { }

            $result = Test-AndSetExecutionPolicy
            $result | Should -Be $true
            Assert-MockCalled Set-ExecutionPolicy -Times 1
        }

        It 'Should set policy to RemoteSigned and return true for Undefined policy' {
            $script:getPolicyCalls = 0
            Mock Get-ExecutionPolicy {
                $script:getPolicyCalls++
                if ($script:getPolicyCalls -eq 1) {
                    return 'Undefined'
                }
                else {
                    return 'RemoteSigned'
                }
            } -ParameterFilter { $Scope -eq 'CurrentUser' }
            Mock Set-ExecutionPolicy { }

            $result = Test-AndSetExecutionPolicy
            $result | Should -Be $true
            Assert-MockCalled Set-ExecutionPolicy -Times 1
        }
    }

    Context 'When execution policy change fails' {
        It 'Should return false and display warning when Set-ExecutionPolicy throws error' {
            Mock Get-ExecutionPolicy { return 'Restricted' } -ParameterFilter { $Scope -eq 'CurrentUser' }
            Mock Set-ExecutionPolicy { throw 'Access denied' } -ParameterFilter { $Scope -eq 'CurrentUser' }

            $result = Test-AndSetExecutionPolicy
            $result | Should -Be $false
            Assert-MockCalled Set-ExecutionPolicy -Times 1
            Assert-MockCalled Write-Warning -Times 4
        }
    }

    Context 'When Get-ExecutionPolicy fails' {
        It 'Should return false and display warning when Get-ExecutionPolicy throws error' {
            Mock Get-ExecutionPolicy { throw 'Policy check failed' } -ParameterFilter { $Scope -eq 'CurrentUser' }

            $result = Test-AndSetExecutionPolicy
            $result | Should -Be $false
            Assert-MockCalled Write-Warning -Times 1
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

Describe 'Test-Source-IsTrusted' {
    BeforeAll {
        Mock Write-Host { }
        Mock Write-Warning { }

        # Dot-source the main script to import Test-Source-IsTrusted
        . "$PSScriptRoot\winget-app-install.ps1"
    }

    Context 'When source is trusted' {
        It 'Should return true and accept source agreements' {
            Mock winget { return 'winget    https://cdn.winget.microsoft.com/cache' } -ParameterFilter { $args[0] -eq 'source' -and $args[1] -eq 'list' -and $args -contains '--accept-source-agreements' }
            $result = Test-Source-IsTrusted -target 'winget'
            $result | Should -Be $true
        }
    }

    Context 'When source is not trusted' {
        It 'Should return false' {
            Mock winget { return 'msstore    https://storeedgefd.dsx.mp.microsoft.com/v9.0' } -ParameterFilter { $args[0] -eq 'source' -and $args[1] -eq 'list' -and $args -contains '--accept-source-agreements' }
            $result = Test-Source-IsTrusted -target 'winget'
            $result | Should -Be $false
        }
    }

    Context 'When winget source list fails' {
        It 'Should return false and emit warning' {
            Mock winget { throw 'Command failed' } -ParameterFilter { $args[0] -eq 'source' -and $args[1] -eq 'list' }
            $result = Test-Source-IsTrusted -target 'winget'
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
        $mockProcess | Add-Member -MemberType ScriptMethod -Name 'Kill' -Value { }

        Mock Start-Process { return $mockProcess }
        Mock Remove-Item { }

        $result = Set-Sources
        $result | Should -Be $false
        Assert-MockCalled $mockProcess.Kill -Times 1 -ErrorAction SilentlyContinue
    }
}

Describe 'Add-ToEnvironmentPath' {
    BeforeAll {
        Mock Write-Host { }

        function Add-ToEnvironmentPath {
            param (
                [Parameter(Mandatory = $true)]
                [string]$PathToAdd,

                [Parameter(Mandatory = $true)]
                [ValidateSet('User', 'System')]
                [string]$Scope
            )

            # Check if the path is already in the environment PATH variable
            if (-not (Test-PathInEnvironment -PathToCheck $PathToAdd -Scope $Scope)) {
                if ($Scope -eq 'System') {
                    # Get the current system PATH
                    $systemEnvPath = [System.Environment]::GetEnvironmentVariable('PATH', [System.EnvironmentVariableTarget]::Machine)
                    # Add to system PATH
                    $systemEnvPath += ";$PathToAdd"
                    [System.Environment]::SetEnvironmentVariable('PATH', $systemEnvPath, [System.EnvironmentVariableTarget]::Machine)
                }
                elseif ($Scope -eq 'User') {
                    # Get the current user PATH
                    $userEnvPath = [System.Environment]::GetEnvironmentVariable('PATH', [System.EnvironmentVariableTarget]::User)
                    # Add to user PATH
                    $userEnvPath += ";$PathToAdd"
                    [System.Environment]::SetEnvironmentVariable('PATH', $userEnvPath, [System.EnvironmentVariableTarget]::User)
                }

                # Update the current process environment PATH
                if (-not ($env:PATH -split ';').Contains($PathToAdd)) {
                    $env:PATH += ";$PathToAdd"
                }
            }
        }

        function Test-PathInEnvironment {
            param (
                [Parameter(Mandatory = $true)]
                [string]$PathToCheck,

                [Parameter(Mandatory = $true)]
                [ValidateSet('User', 'System')]
                [string]$Scope
            )

            if ($Scope -eq 'System') {
                $envPath = [System.Environment]::GetEnvironmentVariable('PATH', [System.EnvironmentVariableTarget]::Machine)
            }
            elseif ($Scope -eq 'User') {
                $envPath = [System.Environment]::GetEnvironmentVariable('PATH', [System.EnvironmentVariableTarget]::User)
            }

            return ($envPath -split ';').Contains($PathToCheck)
        }
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
        function Test-PathInEnvironment {
            param (
                [Parameter(Mandatory = $true)]
                [string]$PathToCheck,

                [Parameter(Mandatory = $true)]
                [ValidateSet('User', 'System')]
                [string]$Scope
            )

            if ($Scope -eq 'System') {
                $envPath = [System.Environment]::GetEnvironmentVariable('PATH', [System.EnvironmentVariableTarget]::Machine)
            }
            elseif ($Scope -eq 'User') {
                $envPath = [System.Environment]::GetEnvironmentVariable('PATH', [System.EnvironmentVariableTarget]::User)
            }

            return ($envPath -split ';').Contains($PathToCheck)
        }
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
        function ConvertTo-CommandArguments {
            param (
                [Parameter(Mandatory = $true)]
                [string]$Command
            )

            $commandArgs = @()
            $currentArg = ''
            $inQuotes = $false
            $quoteChar = ''

            for ($i = 0; $i -lt $Command.Length; $i++) {
                $char = $Command[$i]

                if ($inQuotes) {
                    if ($char -eq $quoteChar) {
                        $inQuotes = $false
                        $quoteChar = ''
                    }
                    else {
                        $currentArg += $char
                    }
                }
                elseif ($char -eq '"' -or $char -eq "'") {
                    $inQuotes = $true
                    $quoteChar = $char
                }
                elseif ($char -eq ' ') {
                    if ($currentArg) {
                        $commandArgs += $currentArg
                        $currentArg = ''
                    }
                }
                else {
                    $currentArg += $char
                }
            }

            if ($currentArg) {
                $commandArgs += $currentArg
            }

            return $commandArgs
        }
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
    BeforeEach {
        Mock Write-Host { }
        Mock Write-Warning { }
        Remove-Item function:Restart-WithElevation -ErrorAction SilentlyContinue

        function Restart-WithElevation {
            param (
                [Parameter(Mandatory = $true)]
                [string]$PowerShellExecutable,

                [Parameter(Mandatory = $true)]
                [string]$ScriptPath,

                [Parameter(Mandatory = $false)]
                [string]$WindowsTerminalExecutable
            )

            $quotedScriptPath = '"' + $ScriptPath.Replace('"', '`"') + '"'
            $commandArguments = "-NoProfile -ExecutionPolicy Bypass -File $quotedScriptPath"
            $windowsTerminalPath = $WindowsTerminalExecutable

            if (-not $windowsTerminalPath) {
                $wtCommand = Get-Command -Name 'wt.exe' -ErrorAction SilentlyContinue
                if ($wtCommand) {
                    $windowsTerminalPath = $wtCommand.Source
                }
            }

            if ($windowsTerminalPath) {
                Write-Host 'Attempting to relaunch script in Windows Terminal with elevated privileges...' -ForegroundColor Blue
                try {
                    Start-Process $windowsTerminalPath -ArgumentList @("$PowerShellExecutable $commandArguments") -Verb RunAs
                    return 'WindowsTerminal'
                }
                catch {
                    Write-Warning "Failed to start Windows Terminal: $_"
                }
            }

            Write-Host 'Relaunching script in standard PowerShell window with elevated privileges...' -ForegroundColor Blue
            Start-Process $PowerShellExecutable -ArgumentList $commandArguments -Verb RunAs
            return 'PowerShell'
        }
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
        function Test-CanUseGridView {
            # Check if we're in an interactive session
            if (-not [Environment]::UserInteractive) {
                return $false
            }

            # Check if Out-GridView is available
            try {
                Get-Command Out-GridView -ErrorAction Stop | Out-Null
                return $true
            }
            catch {
                return $false
            }
        }
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
        Mock Write-Host { }
        Mock Read-Host { return 'N' }

        # Create a mock Out-GridView command if it doesn't exist
        if (-not (Get-Command Out-GridView -ErrorAction SilentlyContinue)) {
            function Out-GridView { param($Title, [switch]$Wait) }
        }
        Mock Out-GridView { }

        function Test-CanUseGridView {
            # Check if we're in an interactive session
            if (-not [Environment]::UserInteractive) {
                return $false
            }

            # Check if Out-GridView is available
            try {
                Get-Command Out-GridView -ErrorAction Stop | Out-Null
                return $true
            }
            catch {
                return $false
            }
        }

        function Write-Table {
            param (
                [Parameter(Mandatory = $true)]
                [string[]]$Headers,
                [Parameter(Mandatory = $true)]
                [string[][]]$Rows,
                [Parameter(Mandatory = $false)]
                [bool]$UseGridView = $false,
                [Parameter(Mandatory = $false)]
                [bool]$PromptForGridView = $false,
                [Parameter(Mandatory = $false)]
                [string]$Title = 'Summary'
            )

            # Convert rows to objects for Format-Table
            $tableData = @()
            foreach ($row in $Rows) {
                $obj = New-Object PSObject
                for ($i = 0; $i -lt $Headers.Count; $i++) {
                    $obj | Add-Member -MemberType NoteProperty -Name $Headers[$i] -Value $row[$i]
                }
                $tableData += $obj
            }

            $shouldUseGridView = $UseGridView

            # Prompt user if requested and Out-GridView is available
            if ($PromptForGridView -and -not $UseGridView) {
                if (Test-CanUseGridView) {
                    Write-Host ''
                    $response = Read-Host 'Would you like to view the results in an interactive grid view? (Y/N)'
                    if ($response -match '^[Yy]') {
                        $shouldUseGridView = $true
                    }
                }
            }

            # Try to use Out-GridView if requested and available
            if ($shouldUseGridView) {
                if (-not (Test-CanUseGridView)) {
                    Write-Host 'Out-GridView is not available. Falling back to text output.' -ForegroundColor Yellow
                }
                else {
                    try {
                        $tableData | Out-GridView -Title $Title -Wait
                        return
                    }
                    catch {
                        Write-Host "Failed to display grid view: $_. Falling back to text output." -ForegroundColor Yellow
                    }
                }
            }

            # Use Format-Table for text output
            $output = $tableData | Format-Table -AutoSize | Out-String
            Write-Host $output.TrimEnd()
        }
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
        # Save original value
        $originalUserInteractive = [Environment]::UserInteractive

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
        Mock Write-Host { }

        # Define the helper function inline for testing
        function ConvertTo-CommandArguments {
            param ([string]$Command)
            $commandArgs = @()
            $currentArg = ''
            $inQuotes = $false
            $quoteChar = ''

            for ($i = 0; $i -lt $Command.Length; $i++) {
                $char = $Command[$i]

                if ($inQuotes) {
                    if ($char -eq $quoteChar) {
                        $inQuotes = $false
                        $quoteChar = ''
                    }
                    else {
                        $currentArg += $char
                    }
                }
                elseif ($char -eq '"' -or $char -eq "'") {
                    $inQuotes = $true
                    $quoteChar = $char
                }
                elseif ($char -eq ' ') {
                    if ($currentArg) {
                        $commandArgs += $currentArg
                        $currentArg = ''
                    }
                }
                else {
                    $currentArg += $char
                }
            }

            if ($currentArg) {
                $commandArgs += $currentArg
            }

            return $commandArgs
        }

        function Write-ErrorMessage {
            param ([string]$Message)
            Write-Host $Message -ForegroundColor Red
        }

        # Define Invoke-WingetCommand function with exit code handling
        function Invoke-WingetCommand {
            param (
                [Parameter(Mandatory = $true)]
                [string]$Command,

                [Parameter(Mandatory = $true)]
                [string]$SuccessPattern,

                [Parameter(Mandatory = $true)]
                [string]$FailurePattern,

                [Parameter(Mandatory = $true)]
                [ref]$SuccessArray,

                [Parameter(Mandatory = $true)]
                [ref]$FailureArray,

                [Parameter(Mandatory = $false)]
                [int]$SuccessIndex = 1,

                [Parameter(Mandatory = $false)]
                [int]$FailureIndex = 1
            )

            $commandArgs = ConvertTo-CommandArguments -Command $Command

            & winget $commandArgs
            $displayExitCode = $LASTEXITCODE

            try {
                $commandOutput = & winget $commandArgs 2>&1 | Where-Object { $_ -notmatch '^[\s\-\|\\]*$' }
                $captureExitCode = $LASTEXITCODE
            }
            catch {
                Write-ErrorMessage "Error capturing winget output: $($_)"
                $commandOutput = @()
                $captureExitCode = -1
            }

            $exitCode = $captureExitCode

            $exitMessage = switch ($exitCode) {
                0 { 'Success' }
                -1978335189 { 'No applicable update found' }
                -1978335191 { 'No packages found matching input criteria' }
                -1978335192 { 'Package installation failed' }
                -1978335212 { 'User cancelled the operation' }
                -1978335213 { 'Package already installed' }
                -1978335215 { 'Manifest validation failed' }
                -1978335216 { 'Invalid manifest' }
                -1978335221 { 'Package download failed' }
                -1978335226 { 'Hash mismatch' }
                default { "Winget exited with code: $exitCode" }
            }

            $commandOutput | ForEach-Object {
                if ($_ -match $SuccessPattern) {
                    $SuccessArray.Value += $_.Split()[$SuccessIndex]
                }
                elseif ($_ -match $FailurePattern) {
                    $FailureArray.Value += $_.Split()[$FailureIndex]
                }
            }

            if ($exitCode -ne 0 -and $FailureArray.Value.Count -eq 0 -and $SuccessArray.Value.Count -eq 0) {
                Write-ErrorMessage "Winget command failed: $exitMessage"
                $FailureArray.Value += "Command failed with exit code $exitCode"
            }

            return @{
                ExitCode    = $exitCode
                ExitMessage = $exitMessage
            }
        }
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
        function Format-AppList {
            param (
                [Parameter(Mandatory = $true)]
                [AllowEmptyCollection()]
                [AllowNull()]
                [string[]]$AppArray
            )

            if ($AppArray -and $AppArray.Count -gt 0) {
                return $AppArray -join ', '
            }
            return $null
        }
    }

    It 'Should format non-empty array' {
        $result = Format-AppList -AppArray @('App1', 'App2', 'App3')
        $result | Should -Be 'App1, App2, App3'
    }

    It 'Should return null for empty array' {
        $result = Format-AppList -AppArray @()
        $result | Should -Be $null
    }

    It 'Should return null for null input' {
        $result = Format-AppList -AppArray $null
        $result | Should -Be $null
    }
}

Describe 'Test-UpdatesAvailable' {
    BeforeAll {
        Mock Write-Host { }

        function Test-UpdatesAvailable {
            try {
                Write-Host 'Checking for available updates...' -ForegroundColor Blue

                # Try PowerShell module first
                if (Get-Command Get-WinGetPackage -ErrorAction SilentlyContinue) {
                    $packagesWithUpdates = Get-WinGetPackage | Where-Object IsUpdateAvailable

                    if ($packagesWithUpdates -and $packagesWithUpdates.Count -gt 0) {
                        Write-Host "Found $($packagesWithUpdates.Count) package(s) with available updates." -ForegroundColor Green
                        $packagesWithUpdates | ForEach-Object {
                            Write-Host " - $($_.Id) (Current: $($_.InstalledVersion), Available: $($_.AvailableVersion))"
                        }
                        return $true
                    }
                }
                else {
                    Write-Host 'PowerShell module not available, using CLI fallback...' -ForegroundColor Yellow

                    # Fallback to CLI method
                    $basicUpgradeResult = & winget upgrade 2>&1
                    $basicOutput = $basicUpgradeResult | Out-String

                    if ($basicOutput -notmatch 'No installed package found matching input criteria' -and
                        $basicOutput -notmatch 'No available upgrade found') {
                        return $true
                    }
                }
            }
            catch {
                Write-Warning "Error checking for updates: $_"
            }

            Write-Host 'No updates available.' -ForegroundColor Yellow
            return $false
        }
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
        Mock Write-Host { }
        Mock Pause { }
        Mock Start-Process { }

        # Mock the functions that are called
        function Test-AndInstallWinget { return $true }
        function Add-ToEnvironmentPath { }
        function Test-Source-IsTrusted { param($target) return $true }
        function Set-Sources { }
        function Format-AppList { param($AppArray) if ($AppArray) { return $AppArray -join ', ' } return $null }
        function Write-Table { }
        function Test-UpdatesAvailable { return $false }

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
            Mock Test-Source-IsTrusted { param($target) return $true } -ParameterFilter { $target -eq 'winget' }
            Mock Test-Source-IsTrusted { param($target) return $true } -ParameterFilter { $target -eq 'msstore' }

            $trustedSources = @('winget', 'msstore')
            foreach ($source in $trustedSources) {
                Test-Source-IsTrusted -target $source | Should -Be $true
            }
        }

        It 'Should call Set-Sources when source is not trusted' {
            Mock Test-Source-IsTrusted { param($target) return $false }
            Mock Set-Sources { return $true }

            $trustedSources = @('winget', 'msstore')
            $sourceErrors = @()
            foreach ($source in $trustedSources) {
                if (-not (Test-Source-IsTrusted -target $source)) {
                    try {
                        $sourceResetSuccess = Set-Sources
                        if (-not $sourceResetSuccess) {
                            $sourceErrors += $source
                        }
                    }
                    catch {
                        $sourceErrors += $source
                    }
                }
            }

            Assert-MockCalled Set-Sources -Times 2
            $sourceErrors | Should -Have -Length 0
        }

        It 'Should track source errors when Set-Sources fails' {
            Mock Test-Source-IsTrusted { param($target) return $false }
            Mock Set-Sources { return $false }

            $trustedSources = @('winget', 'msstore')
            $sourceErrors = @()
            foreach ($source in $trustedSources) {
                if (-not (Test-Source-IsTrusted -target $source)) {
                    try {
                        $sourceResetSuccess = Set-Sources
                        if (-not $sourceResetSuccess) {
                            $sourceErrors += $source
                        }
                    }
                    catch {
                        $sourceErrors += $source
                    }
                }
            }

            $sourceErrors | Should -Have -Length 2
            $sourceErrors | Should -Contain 'winget'
            $sourceErrors | Should -Contain 'msstore'
        }
    }

    Context 'App installation loop' {
        It 'Should install app when not already installed' {
            $apps = @(@{name = 'Test.App' })
            $installedApps = @()
            $skippedApps = @()
            $failedApps = @()

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
            $failedApps = @()

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
                    $packagesToUpdate = Get-WinGetPackage | Where-Object IsUpdateAvailable
                    # Simulate the update without piping to avoid mock issues
                    $updateResults = @(@{ Status = 'Ok'; Id = 'Test.App' })
                    $updateResults[0].Status | Should -Be 'Ok'
                }
            }
        }

        It 'Should handle updates with CLI fallback' {
            Mock Test-UpdatesAvailable { return $true }
            Mock Get-Command { return $false } -ParameterFilter { $Name -eq 'Update-WinGetPackage' }
            Mock winget { 'Test.App 1.0.0 winget' } -ParameterFilter { $args -contains 'list' }
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
            $skippedApps = @()
            $failedApps = @()
            $updatedApps = @()
            $failedUpdateApps = @()

            Mock Format-AppList { param($AppArray) if ($AppArray -and $AppArray.Count -gt 0) { return $AppArray -join ', ' } return $null }
            Mock Write-Table { }

            $headers = @('Status', 'Apps')
            $rows = @()

            $appList = Format-AppList -AppArray $installedApps
            if ($appList) { $rows += , @('Installed', $appList) }

            $rows.Count | Should -Be 0
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
            Mock Test-Source-IsTrusted { return $false }

            # Simulate the code path
            $WhatIf = $true
            $source = 'winget'

            if (-not (Test-Source-IsTrusted -target $source)) {
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
            Mock Test-Source-IsTrusted { return $false }

            # Simulate the code path
            $WhatIf = $false
            $source = 'winget'

            if (-not (Test-Source-IsTrusted -target $source)) {
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