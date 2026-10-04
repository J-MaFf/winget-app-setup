# PowerShell7Bootstrap.Tests.ps1
# Unit tests for the Windows PowerShell 5.1 bootstrap (issue #225): Find-PowerShell7 discovery
# order and Invoke-PowerShell7Bootstrap's find/consent/install/fallback/relaunch paths. All
# externals are mocked; the real-execution 5.1 integration tests live in EntryPoint.Tests.ps1.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'Test-PowerShell7Executable' {
    BeforeDiscovery {
        $script:realPwshAvailable = [bool](Get-Command -Name 'pwsh.exe' -CommandType Application -ErrorAction SilentlyContinue)
        $script:realWinPowerShellAvailable = [bool](Get-Command -Name 'powershell.exe' -CommandType Application -ErrorAction SilentlyContinue)
    }

    It 'Returns $false for a path that does not exist or cannot launch' {
        Test-PowerShell7Executable -Path 'C:\__no_such_dir__\pwsh.exe' | Should -Be $false
    }

    It 'Accepts a real PowerShell 7 executable' -Skip:(-not $script:realPwshAvailable) {
        $realPwsh = (Get-Command -Name 'pwsh.exe' -CommandType Application | Select-Object -First 1).Source

        Test-PowerShell7Executable -Path $realPwsh | Should -Be $true
    }

    It 'Rejects a real pre-7 engine (powershell.exe reports major version 5)' -Skip:(-not $script:realWinPowerShellAvailable) {
        # The exact defect this validation exists for: an engine that launches fine but is < 7
        # must not be treated as a relaunch target, or the version dispatch would loop.
        $winPowerShell = (Get-Command -Name 'powershell.exe' -CommandType Application | Select-Object -First 1).Source

        Test-PowerShell7Executable -Path $winPowerShell | Should -Be $false
    }
}

Describe 'Find-PowerShell7' {
    BeforeEach {
        # Candidates are validated by execution in production; stub the validator so these
        # discovery-order tests stay hermetic. Validation behavior has its own tests above/below.
        Mock Test-PowerShell7Executable { $true }
    }

    Context 'pwsh.exe resolves on PATH' {
        BeforeEach {
            Mock Test-Path { $true } -ParameterFilter { $LiteralPath -like '*pwsh.exe' }
        }

        It 'Returns the Get-Command source' {
            Mock Get-Command { [pscustomobject]@{ Source = 'C:\somewhere\pwsh.exe' } } -ParameterFilter { $Name -eq 'pwsh.exe' }

            Find-PowerShell7 | Should -Be 'C:\somewhere\pwsh.exe'
        }

        It 'Returns the first hit when PATH resolves multiple pwsh entries' {
            Mock Get-Command {
                @(
                    [pscustomobject]@{ Source = 'C:\first\pwsh.exe' },
                    [pscustomobject]@{ Source = 'C:\second\pwsh.exe' }
                )
            } -ParameterFilter { $Name -eq 'pwsh.exe' }

            Find-PowerShell7 | Should -Be 'C:\first\pwsh.exe'
        }
    }

    Context 'pwsh.exe not on PATH (stale PATH, 32-bit host, or MSIX install)' {
        BeforeEach {
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'pwsh.exe' }
            # Pin the candidate roots so assertions are deterministic on any host. TestDrive roots,
            # not 'C:\...' literals: Join-Path checks the drive exists, so off Windows a C: root
            # turned every candidate and every expected path into $null and these tests passed
            # without checking anything (Test-Path is mocked, so nothing touches the disk).
            $script:savedProgramFiles = $env:ProgramFiles
            $script:savedProgramW6432 = $env:ProgramW6432
            $script:savedLocalAppData = $env:LOCALAPPDATA
            $script:testProgramFiles = Join-Path $TestDrive 'TestProgramFiles'
            $script:testProgramW6432 = Join-Path $TestDrive 'TestProgramW6432'
            $script:testLocalAppData = Join-Path $TestDrive 'TestLocalAppData'
            $env:ProgramFiles = $script:testProgramFiles
            $env:ProgramW6432 = $script:testProgramW6432
            $env:LOCALAPPDATA = $script:testLocalAppData
        }
        AfterEach {
            $env:ProgramFiles = $script:savedProgramFiles
            $env:ProgramW6432 = $script:savedProgramW6432
            $env:LOCALAPPDATA = $script:savedLocalAppData
        }

        It 'Falls back to the Program Files install location' {
            Mock Test-Path { $LiteralPath -like "$script:testProgramFiles*" } -ParameterFilter { $LiteralPath -like '*pwsh.exe' }

            Find-PowerShell7 | Should -Be (Join-Path $script:testProgramFiles 'PowerShell\7\pwsh.exe')
        }

        It 'Probes the 64-bit Program Files from a 32-bit host (ProgramW6432)' {
            Mock Test-Path { $LiteralPath -like "$script:testProgramW6432*" } -ParameterFilter { $LiteralPath -like '*pwsh.exe' }

            Find-PowerShell7 | Should -Be (Join-Path $script:testProgramW6432 'PowerShell\7\pwsh.exe')
        }

        It 'Probes the WindowsApps execution alias (MSIX install on Windows 11 24H2+)' {
            Mock Test-Path { $LiteralPath -like "$script:testLocalAppData*" } -ParameterFilter { $LiteralPath -like '*pwsh.exe' }

            Find-PowerShell7 | Should -Be (Join-Path $script:testLocalAppData 'Microsoft\WindowsApps\pwsh.exe')
        }

        It 'Prefers the Program Files install over the WindowsApps alias when both exist' {
            Mock Test-Path { $true } -ParameterFilter { $LiteralPath -like '*pwsh.exe' }

            Find-PowerShell7 | Should -Be (Join-Path $script:testProgramFiles 'PowerShell\7\pwsh.exe')
        }

        It 'Returns $null when no candidate exists' {
            Mock Test-Path { $false } -ParameterFilter { $LiteralPath -like '*pwsh.exe' }

            Find-PowerShell7 | Should -BeNullOrEmpty
        }

        It 'Skips a candidate that exists but fails validation (pre-7 engine or broken alias)' {
            # PATH-less; ProgramFiles and WindowsApps candidates both exist on disk, but the
            # ProgramFiles one fails the execution probe - the WindowsApps one must win.
            Mock Test-Path { $true } -ParameterFilter { $LiteralPath -like '*pwsh.exe' }
            Mock Test-PowerShell7Executable { $Path -like "$script:testLocalAppData*" }

            Find-PowerShell7 | Should -Be (Join-Path $script:testLocalAppData 'Microsoft\WindowsApps\pwsh.exe')
        }

        It 'Returns $null when every existing candidate fails validation' {
            Mock Test-Path { $true } -ParameterFilter { $LiteralPath -like '*pwsh.exe' }
            Mock Test-PowerShell7Executable { $false }

            Find-PowerShell7 | Should -BeNullOrEmpty
        }

        It 'Skips candidates whose environment root is unset' {
            $env:ProgramFiles = ''
            $env:ProgramW6432 = ''
            $env:LOCALAPPDATA = ''
            # Even an always-true Test-Path cannot produce a hit with no candidates to probe.
            Mock Test-Path { $true } -ParameterFilter { $LiteralPath -like '*pwsh.exe' }

            Find-PowerShell7 | Should -BeNullOrEmpty
        }
    }
}

Describe 'Test-GitHubRateLimitError' {
    It 'Matches the literal text GitHub returns for a throttled raw.githubusercontent.com request' {
        Test-GitHubRateLimitError -ErrorRecord '429: Too Many Requests' | Should -Be $true
    }

    It 'Matches the WebException phrasing PowerShell formats for a 429 response' {
        Test-GitHubRateLimitError -ErrorRecord 'The remote server returned an error: (429) Too Many Requests.' | Should -Be $true
    }

    It 'Does not match an unrelated network failure' {
        Test-GitHubRateLimitError -ErrorRecord 'network unreachable' | Should -Be $false
    }
}

Describe 'Get-PowerShell7MsiInfo' {
    BeforeEach {
        Mock Write-Info { }
        Mock Write-WarningMessage { }
        Mock Invoke-RestMethod { [pscustomobject]@{ ReleaseTag = 'v7.6.4' } }
        $script:savedArchitecture = $env:PROCESSOR_ARCHITECTURE
        $script:savedArchitectureW6432 = $env:PROCESSOR_ARCHITEW6432
        $env:PROCESSOR_ARCHITECTURE = 'AMD64'
        $env:PROCESSOR_ARCHITEW6432 = ''
        # Isolate from any other test/call that set this (issue #274) - only the throttle test
        # below should ever see it $true.
        $script:PowerShell7BootstrapGitHubThrottled = $false
    }
    AfterEach {
        $env:PROCESSOR_ARCHITECTURE = $script:savedArchitecture
        $env:PROCESSOR_ARCHITEW6432 = $script:savedArchitectureW6432
    }

    It 'Builds the x64 MSI url from the release metadata' {
        $info = Get-PowerShell7MsiInfo

        $info.Version | Should -Be '7.6.4'
        $info.FileName | Should -Be 'PowerShell-7.6.4-win-x64.msi'
        $info.Url | Should -Be 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.4/PowerShell-7.6.4-win-x64.msi'
    }

    It 'Bounds the metadata request with a timeout' {
        # The whole point of issue #263: no request on this path may be able to block forever.
        Get-PowerShell7MsiInfo | Out-Null

        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $TimeoutSec -gt 0
        }
    }

    It 'Honors a custom MetadataUrl' {
        Get-PowerShell7MsiInfo -MetadataUrl 'https://example.test/metadata.json' | Out-Null

        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Uri -eq 'https://example.test/metadata.json' }
    }

    It 'Resolves arm64' {
        $env:PROCESSOR_ARCHITECTURE = 'ARM64'

        (Get-PowerShell7MsiInfo).FileName | Should -Be 'PowerShell-7.6.4-win-arm64.msi'
    }

    It 'Prefers PROCESSOR_ARCHITEW6432 so a 32-bit host does not pick the x86 MSI' {
        # A 32-bit host process (some RMM agents) reports x86 on a 64-bit OS - the same stale-view
        # problem Find-PowerShell7 handles with ProgramW6432.
        $env:PROCESSOR_ARCHITECTURE = 'x86'
        $env:PROCESSOR_ARCHITEW6432 = 'AMD64'

        (Get-PowerShell7MsiInfo).FileName | Should -Be 'PowerShell-7.6.4-win-x64.msi'
    }

    It 'Uses the x86 MSI on a genuinely 32-bit OS' {
        $env:PROCESSOR_ARCHITECTURE = 'x86'
        $env:PROCESSOR_ARCHITEW6432 = ''

        (Get-PowerShell7MsiInfo).FileName | Should -Be 'PowerShell-7.6.4-win-x86.msi'
    }

    It 'Returns $null for an unrecognized architecture without calling the network' {
        $env:PROCESSOR_ARCHITECTURE = 'IA64'

        Get-PowerShell7MsiInfo | Should -BeNullOrEmpty
        Should -Invoke Invoke-RestMethod -Times 0
    }

    It 'Returns $null when the metadata request fails' {
        Mock Invoke-RestMethod { throw 'network unreachable' }

        Get-PowerShell7MsiInfo | Should -BeNullOrEmpty
    }

    It 'Flags a 429 metadata failure for the top-level bootstrap to explain (issue #274)' {
        Mock Invoke-RestMethod { throw '429: Too Many Requests' }

        Get-PowerShell7MsiInfo | Out-Null

        $script:PowerShell7BootstrapGitHubThrottled | Should -Be $true
    }

    It 'Does not flag an unrelated metadata failure' {
        Mock Invoke-RestMethod { throw 'network unreachable' }

        Get-PowerShell7MsiInfo | Out-Null

        $script:PowerShell7BootstrapGitHubThrottled | Should -Be $false
    }

    It 'Returns $null when the metadata carries no ReleaseTag' {
        Mock Invoke-RestMethod { [pscustomobject]@{ PreviewReleaseTag = 'v7.7.0-preview.1' } }

        Get-PowerShell7MsiInfo | Should -BeNullOrEmpty
    }

    Context 'PowerShell 7.7 and later ship no MSI (review finding P2-17)' {
        # The PowerShell team stopped shipping the MSI with 7.7 (7.7.0-preview.5 has none); 7.6, an
        # LTS release, keeps it. A URL built from ReleaseTag alone 404s once ReleaseTag is 7.7, and
        # an elevating admin account with no winget has no other way to get PowerShell 7.

        It 'Uses the newest LTS release once the current release ships no MSI' {
            Mock Invoke-RestMethod { [pscustomobject]@{ ReleaseTag = 'v7.7.0'; LTSReleaseTag = @('v7.6.6') } }

            $info = Get-PowerShell7MsiInfo

            $info.Version | Should -Be '7.6.6'
            $info.FileName | Should -Be 'PowerShell-7.6.6-win-x64.msi'
            $info.Url | Should -Be 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.6/PowerShell-7.6.6-win-x64.msi'
            Should -Invoke Write-Info -Times 1 -Exactly -ParameterFilter { $Message -match 'PowerShell 7\.7\.0, the current release, ships no MSI installer, so this installs PowerShell 7\.6\.6 \(LTS\) instead' }
        }

        It 'Picks the newest LTS release by version, not by its place in the list: <_>' -ForEach @('v7.4.20,v7.6.6', 'v7.6.6,v7.4.20') {
            # metadata.json lists LTSReleaseTag as ["v7.4.20", "v7.6.6"] (October 2026), oldest first.
            $script:ltsTags = $_ -split ','
            Mock Invoke-RestMethod { [pscustomobject]@{ ReleaseTag = 'v7.7.1'; LTSReleaseTag = $script:ltsTags } }

            (Get-PowerShell7MsiInfo).Version | Should -Be '7.6.6'
        }

        It 'Reads a single LTS tag as well as a list' {
            Mock Invoke-RestMethod { [pscustomobject]@{ ReleaseTag = 'v7.7.0'; LTSReleaseTag = 'v7.6.7' } }

            (Get-PowerShell7MsiInfo).Version | Should -Be '7.6.7'
        }

        It 'Skips LTS entries that are not plain release tags' {
            Mock Invoke-RestMethod { [pscustomobject]@{ ReleaseTag = 'v7.7.0'; LTSReleaseTag = @('v7.6.6', 'v7.6.9-rc.1', '', 'garbage') } }

            (Get-PowerShell7MsiInfo).Version | Should -Be '7.6.6'
        }

        It 'Keeps the current release while it still ships an MSI, as metadata.json reads today' {
            Mock Invoke-RestMethod { [pscustomobject]@{ ReleaseTag = 'v7.6.6'; LTSReleaseTag = @('v7.4.20', 'v7.6.6') } }

            (Get-PowerShell7MsiInfo).Version | Should -Be '7.6.6'
            Should -Invoke Write-Info -Times 0 -ParameterFilter { $Message -match 'ships no MSI' }
        }

        It 'Returns $null and says why when no listed release ships an MSI' {
            Mock Invoke-RestMethod { [pscustomobject]@{ ReleaseTag = 'v7.8.0'; LTSReleaseTag = @('v7.8.0') } }

            Get-PowerShell7MsiInfo | Should -BeNullOrEmpty
            Should -Invoke Write-WarningMessage -Times 1 -Exactly -ParameterFilter {
                $Message -match 'lists no release that ships an MSI installer \(current release: v7\.8\.0; LTS releases: v7\.8\.0\)'
            }
        }
    }
}

Describe 'Save-WebFileWithTimeout' {
    BeforeEach {
        Mock Write-Info { }
        Mock Write-WarningMessage { }
    }

    It 'Returns $false instead of throwing when the request cannot even be created' {
        Save-WebFileWithTimeout -Uri 'not-a-url' -DestinationPath (Join-Path $TestDrive 'out.bin') | Should -Be $false
        Should -Invoke Write-WarningMessage -Times 1 -ParameterFilter { $Message -match 'download failed' }
    }

    It 'Returns $false when the host cannot be resolved' {
        # Bounded by the request timeout rather than hanging - the defect issue #263 exists for.
        Save-WebFileWithTimeout -Uri 'https://no-such-host.invalid/file.msi' -DestinationPath (Join-Path $TestDrive 'out.bin') -StallTimeoutSeconds 5 -MaximumSeconds 15 |
            Should -Be $false
    }
}

Describe 'Test-PowerShell7MsiSignature (review finding P3-17)' {
    # msiexec installs an unsigned or altered MSI without complaint, so the bootstrap checks the
    # download's Authenticode signature first. Get-AuthenticodeSignature is the Windows seam here.
    BeforeAll {
        $script:microsoftSubject = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
        function New-TestSignature {
            param ([string]$Status, [string]$Subject)
            $certificate = $null
            if ($Subject) {
                $certificate = [pscustomobject]@{ Subject = $Subject }
            }
            [pscustomobject]@{ Status = $Status; SignerCertificate = $certificate }
        }
    }

    BeforeEach {
        Mock Write-Info { }
        Mock Write-WarningMessage { }
        $script:msiPath = Join-Path $TestDrive 'PowerShell-7.6.6-win-x64.msi'
    }

    It 'Accepts a valid signature from Microsoft Corporation' {
        Mock Get-AuthenticodeSignature { New-TestSignature -Status 'Valid' -Subject $script:microsoftSubject }

        Test-PowerShell7MsiSignature -Path $script:msiPath | Should -BeTrue

        Should -Invoke Get-AuthenticodeSignature -Times 1 -Exactly -ParameterFilter { $LiteralPath -eq $script:msiPath }
        Should -Invoke Write-WarningMessage -Times 0
    }

    It 'Rejects a download that is not signed at all, such as a proxy''s web page, and says so' {
        Mock Get-AuthenticodeSignature { New-TestSignature -Status 'NotSigned' }

        Test-PowerShell7MsiSignature -Path $script:msiPath | Should -BeFalse

        Should -Invoke Write-WarningMessage -Times 1 -Exactly -ParameterFilter {
            $Message -match 'not a PowerShell installer signed by Microsoft \(signature status: NotSigned; signer: none\), so it was not installed' -and
            $Message -match 'web page instead of the MSI'
        }
    }

    It 'Rejects a file whose content no longer matches its signature (status <_>)' -ForEach @('HashMismatch', 'NotTrusted', 'UnknownError') {
        $script:status = $_
        Mock Get-AuthenticodeSignature { New-TestSignature -Status $script:status -Subject $script:microsoftSubject }

        Test-PowerShell7MsiSignature -Path $script:msiPath | Should -BeFalse
    }

    It 'Rejects a valid signature from anyone but Microsoft: <_>' -ForEach @(
        'CN=Contoso Ltd, O=Contoso Ltd, C=US'
        'CN=Microsoft Corporation Lookalike, O=Lookalike, C=US'
        'CN=Not Microsoft Corporation, O=Lookalike, C=US'
        'O=Microsoft Corporation, C=US'
    ) {
        $script:subject = $_
        Mock Get-AuthenticodeSignature { New-TestSignature -Status 'Valid' -Subject $script:subject }

        Test-PowerShell7MsiSignature -Path $script:msiPath | Should -BeFalse
        Should -Invoke Write-WarningMessage -Times 1 -Exactly -ParameterFilter { $Message -match 'signature status: Valid; signer: ' }
    }

    It 'Rejects the file when the signature cannot be read' {
        Mock Get-AuthenticodeSignature { throw 'Cannot find path because it does not exist.' }

        Test-PowerShell7MsiSignature -Path $script:msiPath | Should -BeFalse
        Should -Invoke Write-WarningMessage -Times 1 -Exactly -ParameterFilter { $Message -match 'Could not check the signature of the downloaded PowerShell MSI, so it was not installed' }
    }

    It 'Rejects the file when no signature information comes back' {
        Mock Get-AuthenticodeSignature { $null }

        Test-PowerShell7MsiSignature -Path $script:msiPath | Should -BeFalse
        Should -Invoke Write-WarningMessage -Times 1 -Exactly -ParameterFilter { $Message -match 'signature status: unknown; signer: none' }
    }
}

Describe 'Install-PowerShell7FromMsi' {
    BeforeEach {
        Mock Write-Info { }
        Mock Write-WarningMessage { }
        Mock New-Item { }
        Mock Remove-Item { }
        # The download is Microsoft's signed MSI unless a test says otherwise (review finding P3-17).
        Mock Get-AuthenticodeSignature {
            [pscustomobject]@{
                Status            = 'Valid'
                SignerCertificate = [pscustomobject]@{ Subject = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US' }
            }
        }
        Mock Get-PowerShell7MsiInfo {
            @{
                Version  = '7.6.4'
                FileName = 'PowerShell-7.6.4-win-x64.msi'
                Url      = 'https://example.test/PowerShell-7.6.4-win-x64.msi'
            }
        }
        Mock Save-WebFileWithTimeout { $true }

        # msiexec stand-in. Start-Process -PassThru returns a real Process, so the double needs the
        # two members production reads (WaitForExit/ExitCode) plus Kill for the timeout path.
        $script:msiExited = $true
        $script:msiExitCode = 0
        $script:msiKilled = $false
        $script:msiProcess = [pscustomobject]@{}
        $script:msiProcess | Add-Member -MemberType ScriptProperty -Name ExitCode -Value { $script:msiExitCode }
        $script:msiProcess | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($Milliseconds) return $script:msiExited }
        $script:msiProcess | Add-Member -MemberType ScriptMethod -Name Kill -Value { $script:msiKilled = $true }
        Mock Start-Process { $script:msiProcess } -ParameterFilter { $FilePath -eq 'msiexec.exe' }
    }

    It 'Downloads the resolved MSI and installs it quietly' {
        Install-PowerShell7FromMsi | Should -Be $true

        Should -Invoke Save-WebFileWithTimeout -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://example.test/PowerShell-7.6.4-win-x64.msi' -and
            $DestinationPath -like '*winget-app-setup-pwsh-*PowerShell-7.6.4-win-x64.msi'
        }
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'msiexec.exe' -and
            $ArgumentList -contains '/i' -and
            $ArgumentList -contains '/quiet' -and
            $ArgumentList -contains '/norestart'
        }
    }

    It 'Checks the downloaded MSI''s signature before msiexec sees it (review finding P3-17)' {
        Install-PowerShell7FromMsi | Should -Be $true

        Should -Invoke Get-AuthenticodeSignature -Times 1 -Exactly -ParameterFilter {
            $LiteralPath -like '*winget-app-setup-pwsh-*PowerShell-7.6.4-win-x64.msi'
        }
    }

    It 'Never runs msiexec on a download that is not Microsoft''s signed MSI (review finding P3-17)' {
        # A proxy that answers with an HTML page leaves an unsigned file behind; msiexec used to get
        # it anyway and fail with an opaque 1620, or install a substituted package without a word.
        Mock Get-AuthenticodeSignature { [pscustomobject]@{ Status = 'NotSigned'; SignerCertificate = $null } }

        Install-PowerShell7FromMsi | Should -Be $false

        Should -Invoke Start-Process -Times 0 -ParameterFilter { $FilePath -eq 'msiexec.exe' }
        Should -Invoke Write-WarningMessage -Times 1 -Exactly -ParameterFilter { $Message -match 'not a PowerShell installer signed by Microsoft' }
        Should -Invoke Remove-Item -Times 1 -Exactly -ParameterFilter { $LiteralPath -like '*winget-app-setup-pwsh-*' }
    }

    It 'Downloads into a unique per-run directory, then removes it' {
        Install-PowerShell7FromMsi | Out-Null

        Should -Invoke New-Item -Times 1 -Exactly -ParameterFilter { $Path -like '*winget-app-setup-pwsh-*' }
        Should -Invoke Remove-Item -Times 1 -Exactly -ParameterFilter { $LiteralPath -like '*winget-app-setup-pwsh-*' }
    }

    It 'Treats msiexec 3010 (reboot required) as success' {
        # pwsh.exe is on disk and launchable at that point; the relaunch does not need the reboot.
        $script:msiExitCode = 3010

        Install-PowerShell7FromMsi | Should -Be $true
    }

    It 'Records that msiexec 3010 needs a restart, so the run can end with 3010 (review finding P3-16)' {
        $script:PowerShell7BootstrapRestartRequired = $false
        $script:msiExitCode = 3010

        Install-PowerShell7FromMsi | Out-Null

        $script:PowerShell7BootstrapRestartRequired | Should -BeTrue
        Should -Invoke Write-WarningMessage -Times 1 -Exactly -ParameterFilter { $Message -match 'restart finishes the installation \(msiexec exit code 3010\)' }
    }

    It 'Records no restart for msiexec 0' {
        $script:PowerShell7BootstrapRestartRequired = $false
        $script:msiExitCode = 0

        Install-PowerShell7FromMsi | Should -Be $true

        $script:PowerShell7BootstrapRestartRequired | Should -BeFalse
    }

    It 'Returns $false on a nonzero msiexec exit code' {
        $script:msiExitCode = 1603

        Install-PowerShell7FromMsi | Should -Be $false
        Should -Invoke Write-WarningMessage -Times 1 -ParameterFilter { $Message -match 'exit code 1603' }
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'msiexec.exe' }
    }

    Context 'Another installation in progress: msiexec 1618 (review finding P2-13)' {
        BeforeEach {
            Mock Start-Sleep { }
        }

        It 'Waits and retries while Windows Installer is busy, then succeeds' {
            # msiexec returns 1618 at once when another installation holds Windows Installer, as on
            # a freshly enrolled machine whose agents are still installing. One busy moment used to
            # fail the bootstrap outright.
            $script:msiExitCodes = [System.Collections.Generic.Queue[int]]::new([int[]]@(1618, 1618, 0))
            $script:msiProcess | Add-Member -MemberType ScriptProperty -Name ExitCode -Force -Value { $script:msiExitCodes.Dequeue() }

            Install-PowerShell7FromMsi -BusyRetryCount 6 -BusyRetryDelaySeconds 30 | Should -Be $true

            Should -Invoke Start-Process -Times 3 -Exactly -ParameterFilter { $FilePath -eq 'msiexec.exe' }
            Should -Invoke Start-Sleep -Times 2 -Exactly -ParameterFilter { $Seconds -eq 30 }
            Should -Invoke Write-WarningMessage -Times 2 -Exactly -ParameterFilter { $Message -match 'busy with another installation \(msiexec exit code 1618\)' }
        }

        It 'Gives up after the retry budget and says why' {
            $script:msiExitCode = 1618

            Install-PowerShell7FromMsi -BusyRetryCount 2 -BusyRetryDelaySeconds 1 | Should -Be $false

            Should -Invoke Start-Process -Times 3 -Exactly -ParameterFilter { $FilePath -eq 'msiexec.exe' }
            Should -Invoke Start-Sleep -Times 2 -Exactly
            Should -Invoke Write-WarningMessage -Times 1 -Exactly -ParameterFilter { $Message -match 'still busy with another installation after 2 retries' }
        }

        It 'Does not retry any other failure' {
            $script:msiExitCode = 1603

            Install-PowerShell7FromMsi | Should -Be $false

            Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'msiexec.exe' }
            Should -Invoke Start-Sleep -Times 0 -Exactly
        }
    }

    Context 'msiexec log (review finding P2-13)' {
        It 'Writes a verbose msiexec log, one file per attempt, into the given folder' {
            Mock Start-Sleep { }
            $logDirectory = Join-Path $TestDrive 'logs'
            $script:msiExitCodes = [System.Collections.Generic.Queue[int]]::new([int[]]@(1618, 0))
            $script:msiProcess | Add-Member -MemberType ScriptProperty -Name ExitCode -Force -Value { $script:msiExitCodes.Dequeue() }
            $script:msiLogArguments = @()
            Mock Start-Process {
                $logIndex = [array]::IndexOf([string[]]$ArgumentList, '/l*v')
                $script:msiLogArguments += $(if ($logIndex -ge 0) { $ArgumentList[$logIndex + 1] } else { '<none>' })
                $script:msiProcess
            } -ParameterFilter { $FilePath -eq 'msiexec.exe' }

            Install-PowerShell7FromMsi -MsiLogDirectory $logDirectory | Should -Be $true

            $script:msiLogArguments.Count | Should -Be 2
            $script:msiLogArguments[0] | Should -BeLike ('"' + (Join-Path $logDirectory 'pwsh-msi-*-1.log') + '"')
            $script:msiLogArguments[1] | Should -BeLike ('"' + (Join-Path $logDirectory 'pwsh-msi-*-2.log') + '"')
        }

        It 'Names the log of a failed attempt' {
            $script:msiExitCode = 1603

            Install-PowerShell7FromMsi -MsiLogDirectory (Join-Path $TestDrive 'logs') | Should -Be $false

            Should -Invoke Write-WarningMessage -Times 1 -Exactly -ParameterFilter { $Message -match 'log of the failed attempt: .*pwsh-msi-.*-1\.log' }
        }

        It 'Asks msiexec for no log without a folder (it fails the install when it cannot write one)' {
            Install-PowerShell7FromMsi | Should -Be $true

            Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq 'msiexec.exe' -and -not ($ArgumentList -contains '/l*v')
            }
        }
    }

    It 'Kills msiexec and returns $false when the install outruns the timeout' {
        $script:msiExited = $false

        Install-PowerShell7FromMsi -InstallTimeoutSeconds 5 | Should -Be $false
        $script:msiKilled | Should -Be $true
        Should -Invoke Write-WarningMessage -Times 1 -ParameterFilter { $Message -match 'did not finish within 5 seconds' }
    }

    It 'Passes the install timeout to WaitForExit in milliseconds' {
        $script:waitMilliseconds = $null
        $script:msiProcess | Add-Member -MemberType ScriptMethod -Name WaitForExit -Force -Value {
            param($Milliseconds)
            $script:waitMilliseconds = $Milliseconds
            return $true
        }

        Install-PowerShell7FromMsi -InstallTimeoutSeconds 42 | Out-Null

        $script:waitMilliseconds | Should -Be 42000
    }

    It 'Gives the MSI download 60 minutes by default, since no fallback runs after it' {
        # The aka.ms/install-powershell.ps1 tier that used to follow a failed MSI path had no time
        # limit, so a slow but working link (110 MB at under ~120 KB/s) still got PowerShell 7.
        # With that tier gone, Save-WebFileWithTimeout's 15-minute default would fail that link.
        Install-PowerShell7FromMsi | Should -Be $true

        Should -Invoke Save-WebFileWithTimeout -Times 1 -Exactly -ParameterFilter { $MaximumSeconds -eq 3600 }
    }

    It 'Forwards -DownloadTimeoutSeconds to the download as its overall limit' {
        Install-PowerShell7FromMsi -DownloadTimeoutSeconds 120 | Should -Be $true

        Should -Invoke Save-WebFileWithTimeout -Times 1 -Exactly -ParameterFilter { $MaximumSeconds -eq 120 }
    }

    It 'Never runs msiexec when the download fails' {
        Mock Save-WebFileWithTimeout { $false }

        Install-PowerShell7FromMsi | Should -Be $false
        Should -Invoke Start-Process -Times 0
        Should -Invoke Remove-Item -Times 1 -Exactly -ParameterFilter { $LiteralPath -like '*winget-app-setup-pwsh-*' }
    }

    It 'Never downloads when the temp directory cannot be created' {
        Mock New-Item { throw 'Access to the path is denied.' }

        Install-PowerShell7FromMsi | Should -Be $false
        Should -Invoke Save-WebFileWithTimeout -Times 0
        Should -Invoke Start-Process -Times 0
        Should -Invoke Write-WarningMessage -Times 1 -ParameterFilter { $Message -match 'temporary directory' }
    }

    It 'Never downloads when the release cannot be resolved' {
        Mock Get-PowerShell7MsiInfo { $null }

        Install-PowerShell7FromMsi | Should -Be $false
        Should -Invoke Save-WebFileWithTimeout -Times 0
        Should -Invoke Start-Process -Times 0
    }

    It 'Returns $false when msiexec cannot be started' {
        # Under 5.1 a Start-Process failure is non-terminating, so without production's try/catch
        # $msiProcess would stay $null and the ExitCode read would blow up mid-bootstrap.
        Mock Start-Process { throw 'The system cannot find the file specified.' } -ParameterFilter { $FilePath -eq 'msiexec.exe' }

        Install-PowerShell7FromMsi | Should -Be $false
        Should -Invoke Write-WarningMessage -Times 1 -ParameterFilter { $Message -match 'msiexec could not be started' }
    }
}

Describe 'Invoke-PowerShell7Bootstrap' {
    BeforeEach {
        # Quiet the console helpers; every path is asserted through mocks, not output.
        Mock Write-Info { }
        Mock Write-WarningMessage { }
        Mock Write-ErrorMessage { }
        Mock Write-Success { }
        Mock Invoke-RestMethod { '# stub' }
        # Default the direct-MSI path to "did not work", so no test reaches the real network. The
        # MSI path has its own contexts further down.
        Mock Install-PowerShell7FromMsi { $false }
        # The winget install runs through Invoke-WingetProcess (review findings P2-5, P2-6): no test
        # starts a real winget. The winget-path contexts below override this.
        Mock Invoke-WingetProcess { New-TestProcessResult -ExitCode 0 }
        # The function sets this relaunch-loop sentinel before relaunching; clear it so no test
        # inherits another test's (or an outer process's) bootstrap state.
        $env:WINGET_APP_SETUP_PS7_BOOTSTRAP = ''
    }
    AfterEach {
        $env:WINGET_APP_SETUP_PS7_BOOTSTRAP = ''
    }

    Context 'PowerShell 7 already installed' {
        BeforeEach {
            Mock Find-PowerShell7 { 'C:\pf7\pwsh.exe' }
            Mock Start-Process { [pscustomobject]@{ ExitCode = 42 } } -ParameterFilter { $FilePath -eq 'C:\pf7\pwsh.exe' }
        }

        It 'Relaunches the caller script under pwsh and returns the child exit code' {
            $result = Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1'

            $result | Should -Be 42
            Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
                $FilePath -eq 'C:\pf7\pwsh.exe' -and
                ($ArgumentList -join ' ') -match '-NoProfile -ExecutionPolicy Bypass -File "C:\\repo\\winget-app-install\.ps1"'
            }
        }

        It 'Returns a single integer (the exit code), not an array' {
            $result = Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1'

            @($result).Count | Should -Be 1
            $result | Should -BeOfType [int]
        }

        It 'Forwards -WhatIf, -NonInteractive, and -SkipSystemCheck to the relaunch' {
            Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1' -WhatIf -NonInteractive -SkipSystemCheck | Out-Null

            Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
                $ArgumentList -contains '-WhatIf' -and
                $ArgumentList -contains '-NonInteractive' -and
                $ArgumentList -contains '-SkipSystemCheck'
            }
        }

        It 'Omits switches the caller did not pass' {
            Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1' | Out-Null

            Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
                -not ($ArgumentList -contains '-WhatIf') -and
                -not ($ArgumentList -contains '-NonInteractive') -and
                -not ($ArgumentList -contains '-SkipSystemCheck')
            }
        }

        It 'Never attempts an install or a download' {
            Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1' | Out-Null

            Should -Invoke Invoke-WingetProcess -Times 0
            Should -Invoke Invoke-RestMethod -Times 0
        }

        It 'Sets the relaunch-loop sentinel before relaunching' {
            Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1' | Out-Null

            $env:WINGET_APP_SETUP_PS7_BOOTSTRAP | Should -Be '1'
        }

        It 'Fails fast (exit 7) when the sentinel says a relaunched child re-entered the dispatch' {
            $env:WINGET_APP_SETUP_PS7_BOOTSTRAP = '1'

            $result = Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1'

            $result | Should -Be 7
            Should -Invoke Start-Process -Times 0
            Should -Invoke Write-ErrorMessage -Times 1 -ParameterFilter { $Message -match 're-entered' }
        }

        It 'Records that the relaunched run reported its own outcome, and logs its exit code (review finding P2-14)' {
            $script:PowerShell7BootstrapRelaunched = $false

            Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1' | Out-Null

            $script:PowerShell7BootstrapRelaunched | Should -BeTrue
            Should -Invoke Write-Info -Times 1 -Exactly -ParameterFilter { $Message -eq 'The PowerShell 7 run ended with exit code 42.' }
        }

        It 'Does not carry a restart over from an earlier call (review finding P3-16)' {
            # Nothing was installed by this call, so a flag left over from an earlier one in the
            # same process must not turn a clean run into 3010.
            Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } } -ParameterFilter { $FilePath -eq 'C:\pf7\pwsh.exe' }
            $script:PowerShell7BootstrapRestartRequired = $true

            $result = Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1'

            $result | Should -Be 0
            Should -Invoke Write-WarningMessage -Times 0 -ParameterFilter { $Message -like 'Restart: REQUIRED*' }
        }

        It 'Returns 7 instead of a false success when the pwsh launch itself fails' {
            # Under 5.1 a Start-Process failure is non-terminating: without the production
            # try/catch the result would be $null and the tail's exit ($null) would report 0.
            Mock Start-Process { throw 'This command cannot be run due to the error: broken alias.' } -ParameterFilter { $FilePath -eq 'C:\pf7\pwsh.exe' }

            $result = Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1'

            $result | Should -Be 7
            Should -Invoke Write-ErrorMessage -Times 1 -ParameterFilter { $Message -match 'could not be started' }
            # Nothing ran, so the tail must report this failure itself.
            $script:PowerShell7BootstrapRelaunched | Should -BeFalse
        }
    }

    Context 'PowerShell 7 missing, -WhatIf run' {
        BeforeEach {
            Mock Find-PowerShell7 { $null }
            Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }
            Mock Read-Host { '' }
        }

        It 'Previews the would-be install, returns 0, and touches nothing' {
            $result = Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1' -WhatIf

            $result | Should -Be 0
            Should -Invoke Start-Process -Times 0
            Should -Invoke Invoke-WingetProcess -Times 0
            Should -Invoke Read-Host -Times 0
            Should -Invoke Write-Info -Times 1 -ParameterFilter { $Message -match '\[DRY-RUN\] PowerShell 7 is not installed' }
        }
    }

    Context 'PowerShell 7 missing, interactive session (issue #230)' {
        # There is no consent prompt anymore. PowerShell 7 is a hard requirement of everything the
        # installer does, so the question only ever had one useful answer - and it fired on exactly
        # the run that must not stop: `irm | iex` reads as INTERACTIVE, because the iex pipe is an
        # in-process pipeline and leaves stdin alone.
        BeforeEach {
            Mock Find-PowerShell7 { $null }
            Mock Test-EffectiveNonInteractive { $false }
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'winget' }
            Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }
            Mock Read-Host { throw 'The bootstrap must never prompt (issue #230)' }
        }

        It 'Installs without asking, even though the session is interactive' {
            Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1' | Out-Null

            Should -Invoke Read-Host -Times 0 -Exactly
            # winget is mocked away, so the flow reaches the MSI fallback.
            Should -Invoke Install-PowerShell7FromMsi -Times 1 -Exactly
        }

        It 'Announces the install rather than asking about it' {
            Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1' | Out-Null

            Should -Invoke Write-Info -Times 1 -ParameterFilter { $Message -match 'Installing it now' }
        }
    }

    Context 'PowerShell 7 missing, winget install path (non-interactive)' {
        BeforeEach {
            # Find-PowerShell7 misses before the install and resolves after it.
            $script:findCallCount = 0
            Mock Find-PowerShell7 {
                $script:findCallCount++
                if ($script:findCallCount -ge 2) {
                    return 'C:\pf7\pwsh.exe'
                }
                return $null
            }
            Mock Test-EffectiveNonInteractive { $true }
            Mock Read-Host { '' }
            Mock Get-Command { [pscustomobject]@{ Source = 'C:\winget.exe' } } -ParameterFilter { $Name -eq 'winget' }
            Mock Invoke-WingetProcess { New-TestProcessResult -ExitCode 0 }
            Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } } -ParameterFilter { $FilePath -eq 'C:\pf7\pwsh.exe' }
        }

        It 'Installs via winget with the agreement flags, then relaunches' {
            $result = Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1'

            $result | Should -Be 0
            Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter {
                $ArgumentList[0] -eq 'install' -and
                $ArgumentList -contains 'Microsoft.PowerShell' -and
                $ArgumentList -contains '--accept-source-agreements' -and
                $ArgumentList -contains '--accept-package-agreements' -and
                $ArgumentList -contains '--exact'
            }
            Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'C:\pf7\pwsh.exe' }
        }

        It 'Passes --disable-interactivity and never prompts' {
            Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1' | Out-Null

            Should -Invoke Read-Host -Times 0
            Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter {
                $ArgumentList -contains '--disable-interactivity'
            }
        }

        It 'Runs the winget install under the install time limit, logging the installer next to the bootstrap transcript (review findings P2-5, P2-6)' {
            Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1' -LogDirectory 'C:\ProgramData\winget-app-setup\logs' | Out-Null

            Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter {
                $TimeoutSeconds -eq (Get-ProcessTimeoutSeconds -Operation WingetInstall) -and
                $LogDirectory -eq 'C:\ProgramData\winget-app-setup\logs'
            }
        }

        It 'Passes --silent when the run is unattended, so the MSI installs with /quiet' {
            Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1' | Out-Null

            Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter { $ArgumentList -contains '--silent' }
        }

        It 'Falls back to the MSI when the winget install runs past its time limit' {
            Mock Invoke-WingetProcess { New-TestProcessResult -TimedOut }
            Mock Find-PowerShell7 { $null }

            Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1' | Out-Null

            Should -Invoke Write-WarningMessage -Times 1 -Exactly -ParameterFilter { $Message -match 'did not finish installing PowerShell 7 in time' }
            Should -Invoke Install-PowerShell7FromMsi -Times 1 -Exactly
        }

        It 'Falls back to the MSI when winget cannot be started' {
            Mock Invoke-WingetProcess { New-TestProcessResult -LaunchFailed -LaunchErrorCode 1920 -LaunchError 'The file cannot be accessed by the system.' }
            Mock Find-PowerShell7 { $null }

            Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1' | Out-Null

            Should -Invoke Write-WarningMessage -Times 1 -Exactly -ParameterFilter { $Message -match 'winget could not be started: The file cannot be accessed by the system' }
            Should -Invoke Install-PowerShell7FromMsi -Times 1 -Exactly
        }

        It 'Does not reach the MSI fallback when winget succeeds' {
            Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1' | Out-Null

            Should -Invoke Install-PowerShell7FromMsi -Times 0
            Should -Invoke Invoke-RestMethod -Times 0
        }
    }

    Context 'The winget install is never interactive (issue #230)' {
        It 'Passes --disable-interactivity even when the session is interactive' {
            # Inverted from its original form, which asserted the flag was OMITTED for interactive
            # sessions. That was exactly backwards for the case that matters: the documented
            # one-liner reports interactive, so the run most likely to be walked away from was the
            # one run that let winget stop and ask. Nothing here needs winget's UI - the agreements
            # go in by flag, and a failure falls through to the MSI fallback.
            Mock Find-PowerShell7 { $null }
            Mock Test-EffectiveNonInteractive { $false }
            Mock Get-Command { [pscustomobject]@{ Source = 'C:\winget.exe' } } -ParameterFilter { $Name -eq 'winget' }
            Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }

            Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1' | Out-Null

            Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter {
                $ArgumentList -contains '--disable-interactivity'
            }
            # Someone is at the console: the MSI may show its progress window (/passive).
            Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter { $ArgumentList -notcontains '--silent' }
        }
    }

    Context 'PowerShell 7 missing, direct MSI download (issue #263)' {
        BeforeEach {
            $script:findCallCount = 0
            Mock Find-PowerShell7 {
                $script:findCallCount++
                if ($script:findCallCount -ge 2) {
                    return 'C:\pf7\pwsh.exe'
                }
                return $null
            }
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'winget' }
            Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } } -ParameterFilter { $FilePath -eq 'C:\pf7\pwsh.exe' }
        }

        It 'Installs via the bounded direct MSI path and never touches the upstream script' {
            # The regression this guards: the upstream script suppresses all download progress and
            # downloads with an untimed Invoke-WebRequest, so reaching it is the slow, silent,
            # unbounded path. Since review findings P2-17 and P3-17 it never runs (next context).
            Mock Install-PowerShell7FromMsi { $true }

            $result = Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1'

            $result | Should -Be 0
            Should -Invoke Install-PowerShell7FromMsi -Times 1 -Exactly
            Should -Invoke Invoke-RestMethod -Times 0 -ParameterFilter { $Uri -like '*install-powershell*' }
        }

        It 'Hands the bootstrap log folder to the MSI install for msiexec''s log (review finding P2-13)' {
            Mock Install-PowerShell7FromMsi { $true }

            Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1' -LogDirectory 'C:\ProgramData\winget-app-setup\logs' | Out-Null

            Should -Invoke Install-PowerShell7FromMsi -Times 1 -Exactly -ParameterFilter { $MsiLogDirectory -eq 'C:\ProgramData\winget-app-setup\logs' }
        }

        It 'Never falls back to the aka.ms install script when the MSI path fails (review findings P2-17 and P3-17)' {
            # That script reads the same metadata.json and downloads the same MSI, so it could only
            # fail where the MSI path just failed - or install the MSI the signature check just
            # rejected, and it 404s once the current release is 7.7.
            Mock Find-PowerShell7 { $null }
            Mock Install-PowerShell7FromMsi { $false }

            $result = Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1'

            $result | Should -Be 7
            Should -Invoke Install-PowerShell7FromMsi -Times 1 -Exactly
            Should -Invoke Invoke-RestMethod -Times 0
        }
    }

    Context 'PowerShell 7 missing, MSI fallback' {
        BeforeEach {
            Mock Test-EffectiveNonInteractive { $true }
            Mock Read-Host { '' }
            Mock Invoke-WingetProcess { New-TestProcessResult -ExitCode 1 }
            Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } } -ParameterFilter { $FilePath -eq 'C:\pf7\pwsh.exe' }
        }

        It 'Uses the MSI when the winget install fails' {
            # Misses on the initial probe AND after the failed winget install; resolves after MSI.
            $script:findCallCount = 0
            Mock Find-PowerShell7 {
                $script:findCallCount++
                if ($script:findCallCount -ge 3) {
                    return 'C:\pf7\pwsh.exe'
                }
                return $null
            }
            Mock Get-Command { [pscustomobject]@{ Source = 'C:\winget.exe' } } -ParameterFilter { $Name -eq 'winget' }
            Mock Install-PowerShell7FromMsi { $true }

            $result = Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1'

            $result | Should -Be 0
            Should -Invoke Invoke-WingetProcess -Times 1 -Exactly
            # Printed in hex like every winget exit code (Format-WingetExitCode, review finding P2-15).
            Should -Invoke Write-WarningMessage -Times 1 -Exactly -ParameterFilter { $Message -eq 'winget could not install PowerShell 7 (exit code 0x00000001).' }
            Should -Invoke Install-PowerShell7FromMsi -Times 1 -Exactly
            Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'C:\pf7\pwsh.exe' }
            Should -Invoke Invoke-RestMethod -Times 0 -ParameterFilter { $Uri -like '*install-powershell*' }
        }

        It 'Returns 7 with manual guidance when nothing can provision PowerShell 7' {
            Mock Find-PowerShell7 { $null }
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'winget' }

            $result = Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1'

            $result | Should -Be 7
            Should -Invoke Write-ErrorMessage -Times 1 -ParameterFilter { $Message -match 'could not be installed automatically' }
            Should -Invoke Start-Process -Times 0 -ParameterFilter { $FilePath -eq 'C:\pf7\pwsh.exe' }
        }

        It 'Points at "winget source reset" when the MSI path''s release list hits a GitHub 429 (issue #274)' {
            # A machine already throttled on raw.githubusercontent.com cannot read metadata.json, so
            # the generic manual-install message is not the most useful thing to print - see issue
            # #274 for the real-world failure this reproduces. The real Get-PowerShell7MsiInfo runs.
            Mock Find-PowerShell7 { $null }
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'winget' }
            Mock Invoke-RestMethod { throw '429: Too Many Requests' } -ParameterFilter { $Uri -like '*metadata.json' }
            Mock Install-PowerShell7FromMsi { [void](Get-PowerShell7MsiInfo); $false }
            $savedArchitecture = $env:PROCESSOR_ARCHITECTURE
            $savedArchitectureW6432 = $env:PROCESSOR_ARCHITEW6432
            $env:PROCESSOR_ARCHITECTURE = 'AMD64'
            $env:PROCESSOR_ARCHITEW6432 = ''
            try {
                $result = Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1'
            }
            finally {
                $env:PROCESSOR_ARCHITECTURE = $savedArchitecture
                $env:PROCESSOR_ARCHITEW6432 = $savedArchitectureW6432
            }

            $result | Should -Be 7
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Uri -like '*metadata.json' }
            Should -Invoke Write-ErrorMessage -Times 1 -ParameterFilter {
                $Message -match 'rate-limiting' -and $Message -match 'winget source reset --force'
            }
        }
    }

    Context 'Installing PowerShell 7 needs a restart to finish (review finding P3-16)' {
        # The relaunched run reads Windows' pending-restart state only after the PowerShell 7
        # install, so it cannot see the restart that install needs: the bootstrap reports it.
        BeforeEach {
            $script:findCallCount = 0
            Mock Find-PowerShell7 {
                $script:findCallCount++
                if ($script:findCallCount -ge 2) {
                    return 'C:\pf7\pwsh.exe'
                }
                return $null
            }
            Mock Test-EffectiveNonInteractive { $true }
            Mock Get-Command { [pscustomobject]@{ Source = 'C:\winget.exe' } } -ParameterFilter { $Name -eq 'winget' }
            $script:childExitCode = 0
            Mock Start-Process { [pscustomobject]@{ ExitCode = $script:childExitCode } } -ParameterFilter { $FilePath -eq 'C:\pf7\pwsh.exe' }
        }

        It 'Ends with 3010 when <Case> and the relaunched run succeeded' -ForEach @(
            @{ Case = 'winget printed its restart warning (exit 0)'; Run = @{ ExitCode = 0; Output = @('Successfully installed', 'Restart your PC to finish installation.') } }
            @{ Case = 'winget exited 0x8A150109 (winget 1.6 and older)'; Run = @{ ExitCode = -1978334967; Output = @() } }
        ) {
            $wingetRun = $Run
            Mock Invoke-WingetProcess { New-TestProcessResult -ExitCode $wingetRun.ExitCode -Output $wingetRun.Output }

            $result = Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1'

            $result | Should -Be 3010
            $script:PowerShell7BootstrapRestartRequired | Should -BeTrue
            Should -Invoke Write-WarningMessage -Times 1 -Exactly -ParameterFilter { $Message -like 'winget reported that a restart finishes the PowerShell 7 installation*' }
            Should -Invoke Write-WarningMessage -Times 1 -Exactly -ParameterFilter { $Message -eq 'Restart: REQUIRED to finish the PowerShell 7 installation - restart this PC before it is used.' }
            # Installed: no failure message, and no MSI fallback.
            Should -Invoke Write-WarningMessage -Times 0 -ParameterFilter { $Message -like 'winget could not install PowerShell 7*' }
            Should -Invoke Install-PowerShell7FromMsi -Times 0
        }

        It 'Ends with 3010 when the MSI fallback returned 3010 and the relaunched run succeeded' {
            Mock Invoke-WingetProcess { New-TestProcessResult -ExitCode 1 }
            $script:findCallCount = -1
            Mock Install-PowerShell7FromMsi {
                $script:PowerShell7BootstrapRestartRequired = $true
                $true
            }

            $result = Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1'

            $result | Should -Be 3010
            Should -Invoke Install-PowerShell7FromMsi -Times 1 -Exactly
            Should -Invoke Write-WarningMessage -Times 1 -Exactly -ParameterFilter { $Message -eq 'Restart: REQUIRED to finish the PowerShell 7 installation - restart this PC before it is used.' }
        }

        It 'Keeps the relaunched run''s exit code <Code>, which ranks above or ends before 3010' -ForEach @(
            @{ Code = 1 }
            @{ Code = 2 }
            @{ Code = 3010 }
            @{ Code = 5 }
        ) {
            Mock Invoke-WingetProcess { New-TestProcessResult -ExitCode 0 -Output @('Restart your PC to finish installation.') }
            $script:childExitCode = $Code

            $result = Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1'

            $result | Should -Be $Code
            Should -Invoke Write-WarningMessage -Times 1 -Exactly -ParameterFilter { $Message -eq 'Restart: REQUIRED to finish the PowerShell 7 installation - restart this PC before it is used.' }
        }

        It 'Keeps 0 when installing PowerShell 7 needed no restart' {
            Mock Invoke-WingetProcess { New-TestProcessResult -ExitCode 0 -Output @('Successfully installed') }

            $result = Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1'

            $result | Should -Be 0
            $script:PowerShell7BootstrapRestartRequired | Should -BeFalse
            Should -Invoke Write-WarningMessage -Times 0 -ParameterFilter { $Message -like 'Restart: REQUIRED*' }
        }
    }

    Context 'iex mode: no script file on disk' {
        BeforeAll {
            # A downloaded installer, stamped the way build/Build-WingetInstallScript.ps1 does it.
            function New-TestInstallerText {
                param ([string]$BuildId)
                "<#PSScriptInfo #>`n`$script:InstallerBuildId = '$BuildId'`nfunction Invoke-WingetInstall { }`n"
            }
            $script:runningBuildId = '1.0.0+aaaaaaaa'
            $script:otherBuildId = '1.0.0+bbbbbbbb'
            $script:rawUrl = 'https://raw.githubusercontent.com/J-MaFf/winget-app-setup/refs/heads/main/winget-app-install.ps1'
            $script:jsDelivrUrl = 'https://cdn.jsdelivr.net/gh/J-MaFf/winget-app-setup@main/winget-app-install.ps1'
        }

        BeforeEach {
            Mock Find-PowerShell7 { 'C:\pf7\pwsh.exe' }
            Mock Set-Content { }
            Mock New-Item { } -ParameterFilter { $Path -like '*winget-app-setup-*' }
            Mock Start-Process { [pscustomobject]@{ ExitCode = 42 } } -ParameterFilter { $FilePath -eq 'C:\pf7\pwsh.exe' }
            Mock Invoke-RestMethod { New-TestInstallerText -BuildId $script:runningBuildId }
        }

        It 'Re-downloads the installer to a unique per-run temp directory and relaunches it' {
            $result = Invoke-PowerShell7Bootstrap -ExpectedBuildId $script:runningBuildId

            $result | Should -Be 42
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Uri -like '*winget-app-install.ps1' }
            # The relaunch file must live inside the fresh GUID-named directory, not at a fixed
            # predictable temp path (pre-planting / concurrent-run collision hazard).
            Should -Invoke New-Item -Times 1 -Exactly -ParameterFilter { $Path -like '*winget-app-setup-*' }
            Should -Invoke Set-Content -Times 1 -Exactly -ParameterFilter { $LiteralPath -like '*winget-app-setup-*winget-app-install.ps1' }
            Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
                ($ArgumentList -join ' ') -match 'winget-app-setup-.*winget-app-install\.ps1'
            }
        }

        It 'Honors a custom InstallerUrl' {
            Invoke-PowerShell7Bootstrap -InstallerUrl 'https://example.test/custom.ps1' -ExpectedBuildId $script:runningBuildId | Out-Null

            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Uri -eq 'https://example.test/custom.ps1' }
        }

        It 'Bounds the re-download with a timeout (issue #263)' {
            Invoke-PowerShell7Bootstrap -ExpectedBuildId $script:runningBuildId | Out-Null

            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $TimeoutSec -gt 0 }
        }

        It 'Returns 7 when the re-download fails everywhere, and says PowerShell 7 is installed' {
            Mock Invoke-RestMethod { throw 'network unreachable' }

            $result = Invoke-PowerShell7Bootstrap -ExpectedBuildId $script:runningBuildId

            $result | Should -Be 7
            Should -Invoke Start-Process -Times 0
            Should -Invoke Write-ErrorMessage -Times 1 -Exactly -ParameterFilter { $Message -match 'Could not download installer build 1\.0\.0\+aaaaaaaa' }
            Should -Invoke Write-ErrorMessage -Times 1 -Exactly -ParameterFilter { $Message -match 'PowerShell 7 is installed on this machine\. Open PowerShell 7 \(pwsh\) as administrator and run the same one-liner there' }
        }

        Context 'Same build, from raw or its jsDelivr mirror (review finding P2-18)' {
            It 'Tries raw.githubusercontent.com first, then the jsDelivr mirror the readme offers' {
                Mock Invoke-RestMethod { throw '429: Too Many Requests' }

                Invoke-PowerShell7Bootstrap -ExpectedBuildId $script:runningBuildId | Out-Null

                Should -Invoke Invoke-RestMethod -Times 2 -Exactly
                Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Uri -eq $script:rawUrl }
                Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Uri -eq $script:jsDelivrUrl }
            }

            It 'Relaunches from the jsDelivr mirror when raw.githubusercontent.com is rate-limiting the network' {
                # An office behind one NAT IP throttled by raw: the jsDelivr one-liner got the first
                # copy, and the relaunch used to go straight back to raw and fail with exit 1.
                Mock Invoke-RestMethod { throw 'The remote server returned an error: (429) Too Many Requests.' } -ParameterFilter { $Uri -eq $script:rawUrl }
                Mock Invoke-RestMethod { New-TestInstallerText -BuildId $script:runningBuildId } -ParameterFilter { $Uri -eq $script:jsDelivrUrl }

                $result = Invoke-PowerShell7Bootstrap -ExpectedBuildId $script:runningBuildId

                $result | Should -Be 42
                Should -Invoke Set-Content -Times 1 -Exactly -ParameterFilter { $Value -match [regex]::Escape("'$($script:runningBuildId)'") }
                Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'C:\pf7\pwsh.exe' }
            }

            It 'Never relaunches another build: a run started from a branch URL does not silently run main' {
                Mock Invoke-RestMethod { New-TestInstallerText -BuildId $script:otherBuildId }

                $result = Invoke-PowerShell7Bootstrap -ExpectedBuildId $script:runningBuildId

                $result | Should -Be 7
                Should -Invoke Set-Content -Times 0
                Should -Invoke Start-Process -Times 0
                Should -Invoke Write-WarningMessage -Times 2 -Exactly -ParameterFilter {
                    $Message -match 'installer build 1\.0\.0\+bbbbbbbb, not build 1\.0\.0\+aaaaaaaa that this run started with'
                }
            }

            It 'Takes the mirror''s copy when raw already serves a newer build of main' {
                Mock Invoke-RestMethod { New-TestInstallerText -BuildId $script:otherBuildId } -ParameterFilter { $Uri -eq $script:rawUrl }
                Mock Invoke-RestMethod { New-TestInstallerText -BuildId $script:runningBuildId } -ParameterFilter { $Uri -eq $script:jsDelivrUrl }

                $result = Invoke-PowerShell7Bootstrap -ExpectedBuildId $script:runningBuildId

                $result | Should -Be 42
                Should -Invoke Set-Content -Times 1 -Exactly -ParameterFilter {
                    $Value -match [regex]::Escape("'$($script:runningBuildId)'") -and $Value -notmatch [regex]::Escape($script:otherBuildId)
                }
            }

            It 'Rejects a download that is not the installer, such as an error page' {
                Mock Invoke-RestMethod { '<html><body>Sign in to continue</body></html>' } -ParameterFilter { $Uri -eq $script:rawUrl }
                Mock Invoke-RestMethod { New-TestInstallerText -BuildId $script:runningBuildId } -ParameterFilter { $Uri -eq $script:jsDelivrUrl }

                $result = Invoke-PowerShell7Bootstrap -ExpectedBuildId $script:runningBuildId

                $result | Should -Be 42
                Should -Invoke Write-WarningMessage -Times 1 -Exactly -ParameterFilter { $Message -match 'not the installer: it carries no installer build id' }
                Should -Invoke Set-Content -Times 1 -Exactly -ParameterFilter { $Value -notmatch '<html>' }
            }

            It 'Returns 7 when the downloaded copy cannot be saved' {
                Mock Set-Content { throw 'Access to the path is denied.' }

                $result = Invoke-PowerShell7Bootstrap -ExpectedBuildId $script:runningBuildId

                $result | Should -Be 7
                Should -Invoke Start-Process -Times 0
                Should -Invoke Write-ErrorMessage -Times 1 -Exactly -ParameterFilter { $Message -match 'Could not save the installer for the relaunch' }
            }
        }
    }
}

Describe 'Get-InstallerBuildIdFromText (review finding P2-18)' {
    It 'Reads the build id the build stamped into the generated installer' {
        $installerText = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:InstallerScriptPath
        $installerText -match "(?m)^\`$script:InstallerBuildId = '([^']+)'" | Should -BeTrue
        $stampedBuildId = $Matches[1]

        Get-InstallerBuildIdFromText -Text $installerText | Should -Be $stampedBuildId
    }

    It 'Returns $null for text that is not the installer' {
        Get-InstallerBuildIdFromText -Text '<html><body>Too Many Requests</body></html>' | Should -BeNullOrEmpty
        Get-InstallerBuildIdFromText -Text '' | Should -BeNullOrEmpty
    }

    It 'Counts only the stamped line, not code that mentions the variable' {
        $text = "function Show-Build {`n    `$script:InstallerBuildId = '9.9.9+deadbeef'`n}`n"

        Get-InstallerBuildIdFromText -Text $text | Should -BeNullOrEmpty
    }
}
