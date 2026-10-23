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
            [void][System.IO.Directory]::CreateDirectory($logDirectory)
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
            # A folder of its own: the earlier tests' logs, made in the same second, would take the name.
            $logDirectory = Join-Path $TestDrive 'logs-failed-attempt'
            [void][System.IO.Directory]::CreateDirectory($logDirectory)

            Install-PowerShell7FromMsi -MsiLogDirectory $logDirectory | Should -Be $false

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
        # No Group Policy execution policy for PowerShell 7 (wgt-gq8.39) unless a context sets one;
        # never the runner's real registry.
        Mock Get-ScriptExecutionPolicyBlock { $null }
        # Elevated unless a context says otherwise (wgt-gq8.75): never the runner's real token, and
        # never a real UAC prompt.
        Mock Test-IsAdmin { $true }
        Mock Restart-WithElevation { [pscustomobject]@{ Started = $false; ExitCode = 4 } }
    }
    AfterEach {
        $env:WINGET_APP_SETUP_PS7_BOOTSTRAP = ''
    }

    Context 'Not elevated and PowerShell 7 missing: elevation comes first (wgt-gq8.75)' {
        # On the owner's PC the one-liner, started from a standard user's window over Remote
        # Desktop, installed PowerShell 7 before asking for elevation; the MSI's own UAC prompt
        # never appeared and winget waited for it with no end.
        BeforeEach {
            Mock Test-IsAdmin { $false }
            Mock Find-PowerShell7 { $null }
            Mock Test-EffectiveNonInteractive { $false }
            Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }
            Mock Restart-WithElevation {
                $script:ElevatedPath = $ScriptPath
                $script:ElevatedFileThere = Test-Path -LiteralPath $ScriptPath
                [pscustomobject]@{ Started = $true; ExitCode = 0 }
            }
            $script:ElevatedPath = $null
            $script:ElevatedFileThere = $null
            $script:errors = @()
            Mock Write-ErrorMessage { $script:errors += $Message }
        }

        It 'Relaunches the caller''s file elevated, forwards its switches, and installs nothing itself' {
            $file = Join-Path $TestDrive 'winget-app-install.ps1'
            Set-Content -LiteralPath $file -Value '# installer'
            $script:PowerShell7BootstrapRelaunched = $false

            $result = Invoke-PowerShell7Bootstrap -CommandPath $file -SkipSystemCheck -AdditionalArguments @('-MaxRuntimeMinutes', '60')

            $result | Should -Be 0
            Should -Invoke Restart-WithElevation -Times 1 -Exactly -ParameterFilter {
                $ScriptPath -eq $file -and ($AdditionalArguments -join ' ') -eq '-SkipSystemCheck -MaxRuntimeMinutes 60'
            }
            Should -Invoke Invoke-WingetProcess -Times 0 -Exactly
            Should -Invoke Install-PowerShell7FromMsi -Times 0 -Exactly
            Should -Invoke Start-Process -Times 0 -Exactly
            # The elevated window showed the outcome.
            $script:PowerShell7BootstrapRelaunched | Should -BeTrue
            Test-Path -LiteralPath $file | Should -BeTrue
        }

        It 'Under irm | iex downloads the same build, relaunches that copy elevated, then removes it' {
            Mock Invoke-RestMethod { "`$script:InstallerBuildId = '1.0.0+abc12345'`n# installer" }

            $result = Invoke-PowerShell7Bootstrap -CommandPath '' -ExpectedBuildId '1.0.0+abc12345' -InstallerUrl @('https://example.invalid/winget-app-install.ps1')

            $result | Should -Be 0
            Should -Invoke Restart-WithElevation -Times 1 -Exactly
            (Split-Path -Leaf $script:ElevatedPath) | Should -Be 'winget-app-install.ps1'
            $script:ElevatedFileThere | Should -BeTrue
            Test-Path -LiteralPath (Split-Path -Parent $script:ElevatedPath) | Should -BeFalse
            Should -Invoke Invoke-WingetProcess -Times 0 -Exactly
        }

        It 'Returns the elevated run''s exit code' {
            Mock Restart-WithElevation { [pscustomobject]@{ Started = $true; ExitCode = 3010 } }
            $file = Join-Path $TestDrive 'winget-app-install.ps1'
            Set-Content -LiteralPath $file -Value '# installer'
            Invoke-PowerShell7Bootstrap -CommandPath $file | Should -Be 3010
        }

        It 'Returns 4 and says nothing was installed when the prompt is declined' {
            Mock Restart-WithElevation { [pscustomobject]@{ Started = $false; ExitCode = 4 } }
            $file = Join-Path $TestDrive 'winget-app-install.ps1'
            Set-Content -LiteralPath $file -Value '# installer'
            $script:PowerShell7BootstrapRelaunched = $true

            Invoke-PowerShell7Bootstrap -CommandPath $file | Should -Be 4

            $script:PowerShell7BootstrapRelaunched | Should -BeFalse
            ($script:errors -join "`n") | Should -Match 'neither PowerShell 7 nor the apps were installed'
            Should -Invoke Invoke-WingetProcess -Times 0 -Exactly
        }

        It 'Returns 4 without a prompt, a download or an install in a non-interactive run' {
            Mock Test-EffectiveNonInteractive { $true }

            Invoke-PowerShell7Bootstrap -CommandPath '' -NonInteractive | Should -Be 4

            Should -Invoke Restart-WithElevation -Times 0 -Exactly
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly
            Should -Invoke Invoke-WingetProcess -Times 0 -Exactly
            ($script:errors -join "`n") | Should -Match 'non-interactive'
        }

        It 'Returns 7 when the same build cannot be downloaded for the elevated run' {
            Mock Invoke-RestMethod { "`$script:InstallerBuildId = '1.0.0+other'`n# installer" }

            Invoke-PowerShell7Bootstrap -CommandPath '' -ExpectedBuildId '1.0.0+abc12345' -InstallerUrl @('https://example.invalid/winget-app-install.ps1') | Should -Be 7

            Should -Invoke Restart-WithElevation -Times 0 -Exactly
            ($script:errors -join "`n") | Should -Match 'Windows PowerShell as administrator'
        }

        It 'Still relaunches unelevated when PowerShell 7 is already installed (the PowerShell 7 run elevates)' {
            Mock Find-PowerShell7 { 'C:\Program Files\PowerShell\7\pwsh.exe' }
            $file = Join-Path $TestDrive 'winget-app-install.ps1'
            Set-Content -LiteralPath $file -Value '# installer'

            Invoke-PowerShell7Bootstrap -CommandPath $file | Should -Be 0

            Should -Invoke Restart-WithElevation -Times 0 -Exactly
            Should -Invoke Start-Process -Times 1 -Exactly
        }
    }

    Context 'Group Policy refuses scripts for PowerShell 7 (wgt-gq8.39)' {
        BeforeEach {
            Mock Get-ScriptExecutionPolicyBlock { [pscustomobject]@{ Engine = 'PowerShell7'; Scope = 'MachinePolicy'; Policy = 'AllSigned'; Key = 'HKLM\SOFTWARE\Policies\Microsoft\PowerShellCore'; GroupPolicyPath = 'Computer Configuration > Administrative Templates > PowerShell Core > Turn on Script Execution'; Description = 'Group Policy sets the PowerShell 7 execution policy for this PC to AllSigned (MachinePolicy, HKLM\SOFTWARE\Policies\Microsoft\PowerShellCore)' } }
            Mock Find-PowerShell7 { $null }
            Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }
            $script:errors = @()
            Mock Write-ErrorMessage { $script:errors += $Message }
            $script:infos = @()
            Mock Write-Info { $script:infos += $Message }
        }

        It 'Returns 7 before looking for, installing or relaunching PowerShell 7, and says why in one line' {
            $result = Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1'

            $result | Should -Be 7
            Should -Invoke Get-ScriptExecutionPolicyBlock -Times 1 -Exactly -ParameterFilter { $Engine -eq 'PowerShell7' }
            Should -Invoke Find-PowerShell7 -Times 0 -Exactly
            Should -Invoke Invoke-WingetProcess -Times 0 -Exactly
            Should -Invoke Install-PowerShell7FromMsi -Times 0 -Exactly
            Should -Invoke Start-Process -Times 0 -Exactly
            $script:PowerShell7BootstrapRelaunched | Should -BeFalse
            $script:errors | Should -Be @('Group Policy sets the PowerShell 7 execution policy for this PC to AllSigned (MachinePolicy, HKLM\SOFTWARE\Policies\Microsoft\PowerShellCore), which -ExecutionPolicy Bypass on the command line cannot override, so PowerShell 7 cannot run this installer from a file, and the run cannot continue in PowerShell 7. Ask whoever manages this PC''s policies to allow scripts (Computer Configuration > Administrative Templates > PowerShell Core > Turn on Script Execution), then re-run the installer. Nothing was installed.')
        }

        It 'A dry run says a real run would stop with exit code 7, and returns 0 without relaunching' {
            $result = Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1' -WhatIf

            $result | Should -Be 0
            Should -Invoke Start-Process -Times 0 -Exactly
            Should -Invoke Find-PowerShell7 -Times 0 -Exactly
            $script:errors | Should -HaveCount 0
            @($script:infos | Where-Object { $_ -like '`[DRY-RUN`] Group Policy sets the PowerShell 7 execution policy*A real run would stop here with exit code 7.' }) | Should -HaveCount 1
        }
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

        # wgt-gq8.41: the time budget's deadline, counted from the start of the 5.1 phase, so the
        # PowerShell 7 run does not start the clock again.
        It 'Forwards the time budget''s arguments after the switches, as they are' {
            Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1' -NonInteractive -AdditionalArguments '-MaxRuntimeMinutes', '60', '-RunDeadlineUtc', '2026-10-05T12:00:00Z' | Out-Null

            Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter {
                ($ArgumentList -join ' ') -match '-File "C:\\repo\\winget-app-install\.ps1" -NonInteractive -MaxRuntimeMinutes 60 -RunDeadlineUtc 2026-10-05T12:00:00Z$'
            }
        }

        It 'Refuses an argument that is not a parameter name or a plain value, relaunching nothing: <_>' -ForEach @('60; Remove-Item C:\', '"60"', 'x y', 'Bypass') {
            { Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1' -AdditionalArguments '-MaxRuntimeMinutes', $_ } | Should -Throw -ErrorId 'ParameterArgumentValidationError,Invoke-PowerShell7Bootstrap'

            Should -Invoke Start-Process -Times 0 -Exactly
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

        It 'Never removes the file it was started from (review finding P3-42)' {
            Mock Remove-Item { }

            Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1' | Out-Null

            Should -Invoke Remove-Item -Times 0
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

        It 'Asks winget for the machine-wide installer, never the per-user MSIX it lists first (wgt-gq8.76)' {
            Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1' | Out-Null

            Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter {
                $scopeAt = [array]::IndexOf([string[]]$ArgumentList, '--scope')
                $scopeAt -ge 0 -and $ArgumentList[$scopeAt + 1] -eq 'machine'
            }
        }

        It 'Asks winget for the MSI, the installer the catalog step uses, before anything else (wgt-9j1)' {
            # Without a type, winget's pick was refused on Windows Server (0x8A150113), and the MSI
            # fallback then installed a release newer than winget's catalog.
            Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1' | Out-Null

            Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter {
                $typeAt = [array]::IndexOf([string[]]$ArgumentList, '--installer-type')
                $typeAt -ge 0 -and $ArgumentList[$typeAt + 1] -eq 'wix'
            }
        }

        It 'Asks for winget''s machine-wide package when it has no MSI for the latest PowerShell (0x8A150010)' {
            $script:wingetCalls = 0
            Mock Invoke-WingetProcess {
                $script:wingetCalls++
                if ($script:wingetCalls -eq 1) {
                    return (New-TestProcessResult -ExitCode -1978335216)
                }
                New-TestProcessResult -ExitCode 0
            }

            Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1' | Should -Be 0

            Should -Invoke Invoke-WingetProcess -Times 2 -Exactly
            Should -Invoke Invoke-WingetProcess -Times 1 -Exactly -ParameterFilter {
                $scopeAt = [array]::IndexOf([string[]]$ArgumentList, '--scope')
                $ArgumentList -notcontains '--installer-type' -and $scopeAt -ge 0 -and $ArgumentList[$scopeAt + 1] -eq 'machine' -and
                $ArgumentList -contains '--disable-interactivity' -and $ArgumentList -contains '--silent'
            }
            Should -Invoke Write-Info -Times 1 -Exactly -ParameterFilter { $Message -eq 'winget has no MSI for the latest PowerShell 7; installing its machine-wide package instead...' }
            Should -Invoke Install-PowerShell7FromMsi -Times 0
        }

        It 'Goes to the MSI download when winget refuses its MSI for another reason, without a second winget install' {
            Mock Invoke-WingetProcess { New-TestProcessResult -ExitCode -1978334957 }
            Mock Find-PowerShell7 { $null }

            Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1' | Out-Null

            Should -Invoke Invoke-WingetProcess -Times 1 -Exactly
            Should -Invoke Write-WarningMessage -Times 1 -Exactly -ParameterFilter { $Message -eq 'winget could not install PowerShell 7 (exit code 0x8A150113 INSTALL_SYSTEM_NOT_SUPPORTED).' }
            Should -Invoke Install-PowerShell7FromMsi -Times 1 -Exactly
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

        It 'Says that SYSTEM has no winget command, not that winget is missing from the PC (review of finding P2-24)' {
            # An RMM agent runs the installer as SYSTEM from Windows PowerShell 5.1. App Installer can
            # be installed for the PC, and the main run then finds its winget.exe, but SYSTEM has no
            # `winget` command.
            Mock Test-IsSystemAccount { $true }
            Mock Install-PowerShell7FromMsi { $true }

            Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1' | Should -Be 0

            Should -Invoke Write-Info -Times 1 -Exactly -ParameterFilter { $Message -match '^Running as SYSTEM, which has no winget command of its own' }
            Should -Invoke Write-WarningMessage -Times 0 -Exactly -ParameterFilter { $Message -match 'winget is not available' }
            Should -Invoke Install-PowerShell7FromMsi -Times 1 -Exactly
            Should -Invoke Invoke-WingetProcess -Times 0 -Exactly
        }

        It 'Still says winget is not available for any other account' {
            Mock Test-IsSystemAccount { $false }
            Mock Install-PowerShell7FromMsi { $true }

            Invoke-PowerShell7Bootstrap -CommandPath 'C:\repo\winget-app-install.ps1' | Should -Be 0

            Should -Invoke Write-WarningMessage -Times 1 -Exactly -ParameterFilter { $Message -eq 'winget is not available on this machine.' }
            Should -Invoke Write-Info -Times 0 -Exactly -ParameterFilter { $Message -match 'Running as SYSTEM' }
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
            $script:releaseUrl = 'https://github.com/J-MaFf/winget-app-setup/releases/download/v1.0.0/winget-app-install.ps1'
            $script:releaseMirrorUrl = 'https://cdn.jsdelivr.net/gh/J-MaFf/winget-app-setup@v1.0.0/winget-app-install.ps1'
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

        It 'Removes its downloaded copy once the PowerShell 7 run has ended (review finding P3-42)' {
            # It used to stay in the temp folder for good: one 240 KB copy per run, which an RMM
            # schedule turned into thousands.
            $script:bootstrapEvents = [System.Collections.Generic.List[string]]::new()
            Mock Start-Process { $script:bootstrapEvents.Add('relaunch'); [pscustomobject]@{ ExitCode = 42 } } -ParameterFilter { $FilePath -eq 'C:\pf7\pwsh.exe' }
            Mock Remove-Item { $script:bootstrapEvents.Add("remove:$LiteralPath") }

            Invoke-PowerShell7Bootstrap -ExpectedBuildId $script:runningBuildId | Should -Be 42

            $script:bootstrapEvents.Count | Should -Be 2
            $script:bootstrapEvents[0] | Should -Be 'relaunch'
            $script:bootstrapEvents[1] | Should -Match 'remove:.*winget-app-setup-[0-9a-f]{32}$'
            Should -Invoke Remove-Item -Times 1 -Exactly -ParameterFilter { $Recurse -and $Force }
        }

        It 'Removes its downloaded copy when PowerShell 7 cannot be started either' {
            Mock Start-Process { throw 'broken alias' } -ParameterFilter { $FilePath -eq 'C:\pf7\pwsh.exe' }
            Mock Remove-Item { }

            Invoke-PowerShell7Bootstrap -ExpectedBuildId $script:runningBuildId | Should -Be 7

            Should -Invoke Remove-Item -Times 1 -Exactly -ParameterFilter { $LiteralPath -match 'winget-app-setup-[0-9a-f]{32}$' }
            Should -Invoke Write-ErrorMessage -Times 1 -Exactly -ParameterFilter { $Message -match 'PowerShell 7 could not be started \(C:\\pf7\\pwsh\.exe\): broken alias' }
        }

        It 'Removes its temp folder when the downloaded copy cannot be saved' {
            Mock Set-Content { throw 'Access to the path is denied.' }
            Mock Remove-Item { }

            Invoke-PowerShell7Bootstrap -ExpectedBuildId $script:runningBuildId | Should -Be 7

            Should -Invoke Remove-Item -Times 1 -Exactly -ParameterFilter { $LiteralPath -match 'winget-app-setup-[0-9a-f]{32}$' }
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

        Context 'Same build, from its release, raw main or their jsDelivr mirrors (review finding P2-18, #289)' {
            It 'Tries the release of the build''s version and its jsDelivr copy, then raw main and its jsDelivr mirror' {
                $script:triedUrls = [System.Collections.Generic.List[string]]::new()
                Mock Invoke-RestMethod { $script:triedUrls.Add($Uri); throw '429: Too Many Requests' }

                Invoke-PowerShell7Bootstrap -ExpectedBuildId $script:runningBuildId | Out-Null

                Should -Invoke Invoke-RestMethod -Times 4 -Exactly
                $script:triedUrls | Should -Be @($script:releaseUrl, $script:releaseMirrorUrl, $script:rawUrl, $script:jsDelivrUrl)
            }

            It 'Relaunches the release''s copy for a run started from the release, whatever main serves now' {
                Mock Invoke-RestMethod { New-TestInstallerText -BuildId $script:otherBuildId }
                Mock Invoke-RestMethod { New-TestInstallerText -BuildId $script:runningBuildId } -ParameterFilter { $Uri -eq $script:releaseUrl }

                $result = Invoke-PowerShell7Bootstrap -ExpectedBuildId $script:runningBuildId

                $result | Should -Be 42
                Should -Invoke Invoke-RestMethod -Times 1 -Exactly
                Should -Invoke Set-Content -Times 1 -Exactly -ParameterFilter { $Value -match [regex]::Escape("'$($script:runningBuildId)'") }
            }

            It 'Takes the release''s jsDelivr copy when GitHub is rate-limiting the network' {
                Mock Invoke-RestMethod { New-TestInstallerText -BuildId $script:otherBuildId }
                Mock Invoke-RestMethod { throw 'The remote server returned an error: (429) Too Many Requests.' } -ParameterFilter { $Uri -eq $script:releaseUrl }
                Mock Invoke-RestMethod { New-TestInstallerText -BuildId $script:runningBuildId } -ParameterFilter { $Uri -eq $script:releaseMirrorUrl }

                Invoke-PowerShell7Bootstrap -ExpectedBuildId $script:runningBuildId | Should -Be 42

                Should -Invoke Invoke-RestMethod -Times 2 -Exactly
                Should -Invoke Set-Content -Times 1 -Exactly -ParameterFilter { $Value -match [regex]::Escape("'$($script:runningBuildId)'") }
            }

            It 'Passes over the release''s copy for a run started from main, and says so as information' {
                # Every run started from main does this, so it must not read as a problem.
                Mock Invoke-RestMethod { throw 'The remote server returned an error: (404) Not Found.' } -ParameterFilter { $Uri -eq $script:releaseUrl }
                Mock Invoke-RestMethod { New-TestInstallerText -BuildId $script:otherBuildId } -ParameterFilter { $Uri -eq $script:releaseMirrorUrl }
                Mock Invoke-RestMethod { New-TestInstallerText -BuildId $script:runningBuildId } -ParameterFilter { $Uri -eq $script:rawUrl }

                Invoke-PowerShell7Bootstrap -ExpectedBuildId $script:runningBuildId | Should -Be 42

                Should -Invoke Invoke-RestMethod -Times 0 -ParameterFilter { $Uri -eq $script:jsDelivrUrl }
                Should -Invoke Write-Info -Times 1 -Exactly -ParameterFilter { $Message -match 'The download failed: .*404' }
                Should -Invoke Write-Info -Times 1 -Exactly -ParameterFilter { $Message -match 'installer build 1\.0\.0\+bbbbbbbb, not build 1\.0\.0\+aaaaaaaa' }
                Should -Invoke Write-WarningMessage -Times 0 -ParameterFilter { $Message -match 'download|installer build' }
                Should -Invoke Set-Content -Times 1 -Exactly -ParameterFilter { $Value -match [regex]::Escape("'$($script:runningBuildId)'") }
            }

            It 'Tries only main''s URLs when the running build carries no version' {
                $script:triedUrls = [System.Collections.Generic.List[string]]::new()
                Mock Invoke-RestMethod { $script:triedUrls.Add($Uri); throw 'network unreachable' }

                Invoke-PowerShell7Bootstrap -ExpectedBuildId '' | Should -Be 7

                $script:triedUrls | Should -Be @($script:rawUrl, $script:jsDelivrUrl)
            }

            It 'Relaunches a release asset GitHub served as bytes (application/octet-stream)' {
                Mock Invoke-RestMethod { , [System.Text.Encoding]::UTF8.GetBytes((New-TestInstallerText -BuildId $script:runningBuildId)) }

                Invoke-PowerShell7Bootstrap -ExpectedBuildId $script:runningBuildId | Should -Be 42

                Should -Invoke Set-Content -Times 1 -Exactly -ParameterFilter {
                    # Set-Content's -Value is an array: one string, not the bytes or their numbers.
                    @($Value).Count -eq 1 -and $Value[0] -is [string] -and $Value[0].StartsWith('<#PSScriptInfo') -and $Value[0] -match [regex]::Escape("'$($script:runningBuildId)'")
                }
            }

            It 'Relaunches from the jsDelivr mirror when raw.githubusercontent.com is rate-limiting the network' {
                # An office behind one NAT IP throttled by raw: the jsDelivr one-liner got the first
                # copy, and the relaunch used to go straight back to raw and fail with exit 1.
                Mock Invoke-RestMethod { throw 'The remote server returned an error: (404) Not Found.' } -ParameterFilter { $Uri -eq $script:releaseUrl -or $Uri -eq $script:releaseMirrorUrl }
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
                Should -Invoke Write-Info -Times 4 -Exactly -ParameterFilter {
                    $Message -match 'installer build 1\.0\.0\+bbbbbbbb, not build 1\.0\.0\+aaaaaaaa that this run started with'
                }
            }

            It 'Takes the mirror''s copy when raw already serves a newer build of main' {
                Mock Invoke-RestMethod { New-TestInstallerText -BuildId $script:otherBuildId } -ParameterFilter { $Uri -eq $script:releaseUrl -or $Uri -eq $script:releaseMirrorUrl -or $Uri -eq $script:rawUrl }
                Mock Invoke-RestMethod { New-TestInstallerText -BuildId $script:runningBuildId } -ParameterFilter { $Uri -eq $script:jsDelivrUrl }

                $result = Invoke-PowerShell7Bootstrap -ExpectedBuildId $script:runningBuildId

                $result | Should -Be 42
                Should -Invoke Set-Content -Times 1 -Exactly -ParameterFilter {
                    $Value -match [regex]::Escape("'$($script:runningBuildId)'") -and $Value -notmatch [regex]::Escape($script:otherBuildId)
                }
            }

            It 'Rejects a download that is not the installer, such as an error page' {
                Mock Invoke-RestMethod { '<html><body>Sign in to continue</body></html>' } -ParameterFilter { $Uri -eq $script:releaseUrl }
                Mock Invoke-RestMethod { New-TestInstallerText -BuildId $script:runningBuildId } -ParameterFilter { $Uri -eq $script:releaseMirrorUrl }

                $result = Invoke-PowerShell7Bootstrap -ExpectedBuildId $script:runningBuildId

                $result | Should -Be 42
                Should -Invoke Write-Info -Times 1 -Exactly -ParameterFilter { $Message -match 'not the installer: it carries no installer build id' }
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

Describe 'Get-InstallerDownloadUrl (#289)' {
    It 'Puts the release of the build''s version and its jsDelivr copy before main and its mirror' {
        Get-InstallerDownloadUrl -BuildId '2.0.0+1a2b3c4d' | Should -Be @(
            'https://github.com/J-MaFf/winget-app-setup/releases/download/v2.0.0/winget-app-install.ps1',
            'https://cdn.jsdelivr.net/gh/J-MaFf/winget-app-setup@v2.0.0/winget-app-install.ps1',
            'https://raw.githubusercontent.com/J-MaFf/winget-app-setup/refs/heads/main/winget-app-install.ps1',
            'https://cdn.jsdelivr.net/gh/J-MaFf/winget-app-setup@main/winget-app-install.ps1'
        )
    }

    It 'Names the release tag the release workflow accepts for the version the build stamps' {
        # The tag is v<ModuleVersion> (.github/workflows/release.yml), and the build id starts with
        # ModuleVersion (build/Build-WingetInstallScript.ps1).
        $manifestVersion = (Import-PowerShellDataFile -LiteralPath (Join-Path $script:RepoRoot 'WingetAppSetup/WingetAppSetup.psd1')).ModuleVersion
        $installerText = Get-Content -Raw -Encoding UTF8 -LiteralPath $script:InstallerScriptPath
        $stampedBuildId = Get-InstallerBuildIdFromText -Text $installerText

        $stampedBuildId | Should -BeLike "$manifestVersion+*"
        (Get-InstallerDownloadUrl -BuildId $stampedBuildId)[0] | Should -Be "https://github.com/J-MaFf/winget-app-setup/releases/download/v$manifestVersion/winget-app-install.ps1"
    }

    It 'Gives main''s URLs only for a build id without a version: <BuildId>' -ForEach @(
        @{ BuildId = '' }
        @{ BuildId = 'dev' }
        @{ BuildId = '1.0+abc' }
        @{ BuildId = '01.0.0+abc' }
        @{ BuildId = '1.0.0' }
    ) {
        Get-InstallerDownloadUrl -BuildId $BuildId | Should -Be @(
            'https://raw.githubusercontent.com/J-MaFf/winget-app-setup/refs/heads/main/winget-app-install.ps1',
            'https://cdn.jsdelivr.net/gh/J-MaFf/winget-app-setup@main/winget-app-install.ps1'
        )
    }
}

Describe 'ConvertTo-DownloadedText (#289)' {
    It 'Keeps a download that came back as text' {
        ConvertTo-DownloadedText -Content "line 1`nline 2" | Should -BeExactly "line 1`nline 2"
    }

    It 'Reads a download that came back as bytes as UTF-8' {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes("Write-Output 'caf$([char]0xE9)'")

        ConvertTo-DownloadedText -Content $bytes | Should -BeExactly "Write-Output 'caf$([char]0xE9)'"
    }

    It 'Reads bytes that the pipeline unrolled into an object array' {
        $bytes = [object[]][System.Text.Encoding]::UTF8.GetBytes('abc')

        ConvertTo-DownloadedText -Content $bytes | Should -BeExactly 'abc'
    }

    It 'Drops a leading byte order mark, which iex would take as part of the first command' {
        $withMark = [byte[]](0xEF, 0xBB, 0xBF) + [System.Text.Encoding]::UTF8.GetBytes('Write-Output 1')

        ConvertTo-DownloadedText -Content $withMark | Should -BeExactly 'Write-Output 1'
        ConvertTo-DownloadedText -Content "$([char]0xFEFF)Write-Output 1" | Should -BeExactly 'Write-Output 1'
    }

    It 'Returns an empty string for no content' {
        ConvertTo-DownloadedText -Content $null | Should -BeExactly ''
    }
}

Describe 'A release asset served as application/octet-stream, read by a real PowerShell (#289)' {
    # GitHub serves release assets as application/octet-stream with no charset. Each child process
    # downloads from a loopback server that answers the same way: pwsh here, and on Windows the
    # Windows PowerShell 5.1 whose bootstrap downloads the installer for its PowerShell 7 relaunch.
    BeforeAll {
        function Invoke-OctetStreamDownload {
            param (
                [string]$Executable,
                [byte[]]$Body,
                [int]$RequestCount,
                [string]$Script
            )

            $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
            $listener.Start()
            $process = $null
            try {
                $url = 'http://127.0.0.1:{0}/winget-app-install.ps1' -f $listener.LocalEndpoint.Port
                $command = $Script.Replace('{URL}', $url)
                $startInfo = [System.Diagnostics.ProcessStartInfo]::new($Executable)
                $startInfo.Arguments = '-NoProfile -NonInteractive -OutputFormat Text -EncodedCommand ' + [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($command))
                $startInfo.UseShellExecute = $false
                $startInfo.RedirectStandardOutput = $true
                $startInfo.RedirectStandardError = $true
                $process = [System.Diagnostics.Process]::Start($startInfo)
                $outputTask = $process.StandardOutput.ReadToEndAsync()
                $errorTask = $process.StandardError.ReadToEndAsync()
                $deadline = [DateTime]::UtcNow.AddSeconds(90)
                $header = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: application/octet-stream`r`nContent-Length: $($Body.Length)`r`nConnection: close`r`n`r`n")
                for ($served = 0; $served -lt $RequestCount; $served++) {
                    $acceptTask = $listener.AcceptTcpClientAsync()
                    while (-not $acceptTask.Wait(250)) {
                        if ($process.HasExited -or [DateTime]::UtcNow -gt $deadline) {
                            break
                        }
                    }
                    if (-not $acceptTask.IsCompleted) {
                        break
                    }
                    $client = $acceptTask.Result
                    try {
                        $stream = $client.GetStream()
                        $buffer = New-Object byte[] 4096
                        $request = ''
                        while ($request -notmatch "`r`n`r`n") {
                            $read = $stream.Read($buffer, 0, $buffer.Length)
                            if ($read -le 0) {
                                break
                            }
                            $request += [System.Text.Encoding]::ASCII.GetString($buffer, 0, $read)
                        }
                        $stream.Write($header, 0, $header.Length)
                        $stream.Write($Body, 0, $Body.Length)
                        $stream.Flush()
                    }
                    finally {
                        $client.Close()
                    }
                }
                if (-not $process.WaitForExit(60000)) {
                    $process.Kill()
                    throw "$Executable did not finish within 60 seconds."
                }
                return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $outputTask.Result; Error = $errorTask.Result; Served = $served }
            }
            finally {
                $listener.Stop()
                if ($process) {
                    $process.Dispose()
                }
            }
        }

        $script:installerBytes = [System.IO.File]::ReadAllBytes($script:InstallerScriptPath)
        $script:installerBuildId = Get-InstallerBuildIdFromText -Text ([System.Text.Encoding]::UTF8.GetString($script:installerBytes))
        $installerHash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($script:installerBytes)
        $script:installerSha256 = ([System.BitConverter]::ToString($installerHash)).Replace('-', '')
        $bootstrapPath = (Join-Path $script:RepoRoot 'WingetAppSetup/Private/PowerShell7Bootstrap.ps1').Replace("'", "''")
        # The relaunch download as the bootstrap does it, with the message helpers stubbed: the SHA256
        # of the UTF-8 text it returns, which is the file's when the text is the file's.
        $script:relaunchScript = @"
`$ErrorActionPreference = 'Stop'
. '$bootstrapPath'
function Write-Info { param (`$Message) }
function Write-WarningMessage { param (`$Message) }
`$text = Get-PowerShell7RelaunchInstaller -Url '{URL}' -ExpectedBuildId '$($script:installerBuildId)'
if (-not `$text) { 'relaunch-download: none'; exit 3 }
`$hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes(`$text))
'relaunch-download: ' + ([System.BitConverter]::ToString(`$hash)).Replace('-', '')
"@
        # The one-liner as it will read once it points at a release: irm piped to iex.
        $script:oneLinerScript = "Set-ExecutionPolicy Bypass -Scope Process -Force; irm '{URL}' | iex"
        $script:oneLinerBody = [System.Text.Encoding]::UTF8.GetBytes("Write-Output ('one-liner ran in PowerShell ' + `$PSVersionTable.PSVersion.Major)`n")
        $script:windowsPowerShell = $null
        if ($IsWindows) {
            $script:windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        }
    }

    It 'pwsh: the relaunch download returns the installer''s own text' {
        $result = Invoke-OctetStreamDownload -Executable ([System.Environment]::ProcessPath) -Body $script:installerBytes -RequestCount 1 -Script $script:relaunchScript

        $result.Served | Should -Be 1
        $result.Output | Should -Match "relaunch-download: $($script:installerSha256)" -Because "the child said: $($result.Output) $($result.Error)"
    }

    It 'pwsh: irm | iex runs a script served that way' {
        $result = Invoke-OctetStreamDownload -Executable ([System.Environment]::ProcessPath) -Body $script:oneLinerBody -RequestCount 1 -Script $script:oneLinerScript

        $result.Output | Should -Match 'one-liner ran in PowerShell 7' -Because "the child said: $($result.Output) $($result.Error)"
    }

    It 'Windows PowerShell 5.1: the relaunch download returns the installer''s own text' -Skip:(-not $IsWindows) {
        $result = Invoke-OctetStreamDownload -Executable $script:windowsPowerShell -Body $script:installerBytes -RequestCount 1 -Script $script:relaunchScript

        $result.Served | Should -Be 1
        $result.Output | Should -Match "relaunch-download: $($script:installerSha256)" -Because "the child said: $($result.Output) $($result.Error)"
    }

    It 'Windows PowerShell 5.1: irm | iex runs a script served that way' -Skip:(-not $IsWindows) {
        $result = Invoke-OctetStreamDownload -Executable $script:windowsPowerShell -Body $script:oneLinerBody -RequestCount 1 -Script $script:oneLinerScript

        $result.Output | Should -Match 'one-liner ran in PowerShell 5' -Because "the child said: $($result.Output) $($result.Error)"
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
