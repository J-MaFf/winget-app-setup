# E2EAssertions.Tests.ps1
# Tests for e2e/TranscriptAssertions.ps1, the transcript half of e2e/Assert-Install.ps1, against the
# sample transcripts in tests/fixtures/e2e (review finding P3-39). The fixtures follow what the
# installer writes: a first and a second pass, a run with timeouts in both passes, a run whose
# circuit breaker found that winget cannot be launched, an aborted run, and the two Windows
# PowerShell 5.1 bootstrap transcripts of a 5.1 leg. first-pass-runtime-installed and
# second-pass-runtime-present are the passes expected on windows-latest since work-order item 31:
# the first installs the pinned Windows App Runtime framework and Winget-AutoUpdate, the second
# finds both.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . (Join-Path $script:RepoRoot 'e2e/TranscriptAssertions.ps1')
    # .txt, not .log: the repository ignores *.log files.
    $script:FixtureDirectory = Join-Path $PSScriptRoot 'fixtures/e2e'
    $script:AssertInstallPath = Join-Path $script:RepoRoot 'e2e/Assert-Install.ps1'

    function Get-Fixture {
        param ([Parameter(Mandatory = $true)][string]$Name)
        return [string](Get-Content -Raw -LiteralPath (Join-Path $script:FixtureDirectory "$Name.txt"))
    }

    # A log folder in TestDrive holding the given fixtures under installer-style names, written in
    # the given order (LastWriteTime one minute apart).
    function New-TestLogDirectory {
        param (
            [Parameter(Mandatory = $true)][string[]]$Fixture,
            [Parameter(Mandatory = $false)][string[]]$Name
        )
        $directory = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $directory -Force
        $time = [datetime]'2026-10-05T06:00:00'
        for ($i = 0; $i -lt $Fixture.Count; $i++) {
            $fileName = if ($Name) { $Name[$i] } else { 'install-20261005-06{0:D2}00.log' -f $i }
            $path = Join-Path $directory $fileName
            Set-Content -LiteralPath $path -Value (Get-Fixture -Name $Fixture[$i]) -NoNewline
            (Get-Item -LiteralPath $path).LastWriteTime = $time.AddMinutes($i)
        }
        return $directory
    }

    function New-TestInstaller {
        param ([Parameter(Mandatory = $true)][string]$BuildId)
        $path = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '-winget-app-install.ps1')
        Set-Content -LiteralPath $path -Value @("# generated", "`$script:InstallerBuildId = '$BuildId'", 'Write-Host hi')
        return $path
    }

    $script:CatalogIds = @('7zip.7zip', 'GlavSoft.TightVNC', 'Adobe.Acrobat.Reader.64-bit', 'Google.Chrome', 'Google.GoogleDrive', 'Git.Git', 'Klocman.BulkCrapUninstaller', 'Microsoft.PowerShell', 'Microsoft.WindowsTerminal')
    $script:NotApplicable = [ordered]@{ 'Dell.CommandUpdate.Universal' = 'Dell hardware only' }
}

# Work-order item 34: the RMM wrapper's log (install-<time>-rmm.log) repeats the run's output and
# brackets it in time, so it must never be read as the run's own transcript, which would make the
# latest real run one with no summary.
Describe 'Get-InstallTranscriptFile' {
    It 'Keeps the bootstrap and RMM wrapper logs apart from the real-run transcripts, and leaves dry runs out' {
        $logs = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $logs
        $time = [datetime]'2026-10-05T06:00:00'
        $names = @('install-20261005-060000-rmm.log', 'install-20261005-060005-bootstrap.log', 'install-20261005-060010.log', 'install-20261005-060500-whatif.log')
        for ($i = 0; $i -lt $names.Count; $i++) {
            $path = Join-Path $logs $names[$i]
            Set-Content -LiteralPath $path -Value 'Summary:'
            (Get-Item -LiteralPath $path).LastWriteTime = $time.AddMinutes($i)
        }
        # The wrapper's log is written last: it ends after the run it started.
        (Get-Item -LiteralPath (Join-Path $logs 'install-20261005-060000-rmm.log')).LastWriteTime = $time.AddMinutes(10)

        $files = Get-InstallTranscriptFile -LogDirectory $logs

        @($files.RealRun | ForEach-Object Name) | Should -Be @('install-20261005-060010.log')
        @($files.Bootstrap | ForEach-Object Name) | Should -Be @('install-20261005-060005-bootstrap.log')
        @($files.Rmm | ForEach-Object Name) | Should -Be @('install-20261005-060000-rmm.log')
    }
}

Describe 'ConvertFrom-InstallTranscript' {
    It 'Reads the installs, skips, not-applicable apps, build id and auto-update status of a first pass' {
        $transcript = ConvertFrom-InstallTranscript -Content (Get-Fixture -Name 'first-pass')

        $transcript.BuildId | Should -Be '1.0.0+5ea1f00d'
        $transcript.Installed | Should -Be @('7zip.7zip', 'Adobe.Acrobat.Reader.64-bit', 'Git.Git', 'GlavSoft.TightVNC', 'Google.Chrome', 'Google.GoogleDrive', 'Klocman.BulkCrapUninstaller')
        $transcript.AlreadyInstalled | Should -Be @('Microsoft.PowerShell', 'Microsoft.WindowsTerminal')
        $transcript.NotApplicable['Dell.CommandUpdate.Universal'] | Should -Be 'Dell hardware only'
        $transcript.HasSummary | Should -BeTrue
        $transcript.SummaryInstalled.Count | Should -Be 7
        $transcript.SummarySkipped | Should -Be @('Dell.CommandUpdate.Universal', 'Microsoft.PowerShell', 'Microsoft.WindowsTerminal')
        $transcript.FinalFailed | Should -BeNullOrEmpty
        $transcript.AutoUpdatesStatus | Should -Be 'NOT CONFIGURED'
        $transcript.AutoUpdatesFrameworkMissing | Should -BeTrue
        $transcript.WingetNotUsable | Should -BeFalse
        $transcript.Aborted | Should -BeFalse
    }

    # Review finding P3-36: these runs exit 8, and e2e/Invoke-InstallPass.ps1 accepts 8 only for the
    # missing framework.
    It 'Tells the missing-framework NOT CONFIGURED from every other auto-update outcome: <Line>' -ForEach @(
        @{ Line = 'NOT CONFIGURED - Microsoft.WindowsAppRuntime.1.8 is missing, and Winget-AutoUpdate would leave winget unusable without it.'; Status = 'NOT CONFIGURED'; FrameworkMissing = $true }
        @{ Line = 'NOT CONFIGURED - some other reason.'; Status = 'NOT CONFIGURED'; FrameworkMissing = $false }
        @{ Line = 'UNHEALTHY - Winget-AutoUpdate is installed, but its scheduled task \WAU\Winget-AutoUpdate does not exist; apps will not update automatically (see above).'; Status = 'UNHEALTHY'; FrameworkMissing = $false }
        @{ Line = 'AT RISK - Winget-AutoUpdate is installed but Microsoft.WindowsAppRuntime.1.8 is missing; its next run may leave winget unusable (see above).'; Status = 'AT RISK'; FrameworkMissing = $false }
        @{ Line = 'FAILED - Winget-AutoUpdate could not be installed; apps will not update automatically. Re-run the installer to retry.'; Status = 'FAILED'; FrameworkMissing = $false }
        @{ Line = 'Configured (Winget-AutoUpdate v2.12.0).'; Status = 'Configured'; FrameworkMissing = $false }
    ) {
        $transcript = ConvertFrom-InstallTranscript -Content "Summary:`nAuto-updates: $Line"

        $transcript.AutoUpdatesStatus | Should -Be $Status
        $transcript.AutoUpdatesFrameworkMissing | Should -Be $FrameworkMissing
    }

    It 'Reads the installer''s own install of the Windows App Runtime and the Configured outcome that follows (work-order item 31)' {
        $first = ConvertFrom-InstallTranscript -Content (Get-Fixture -Name 'first-pass-runtime-installed')

        $first.WindowsAppRuntimeInstalled | Should -BeTrue
        $first.WindowsAppRuntimeLine | Should -Be 'installed Microsoft.WindowsAppRuntime.1.8 8000.994.2142.0 (X64) for all users.'
        $first.AutoUpdatesStatus | Should -Be 'Configured'
        $first.AutoUpdatesFrameworkMissing | Should -BeFalse
        $first.FinalFailed | Should -BeNullOrEmpty

        $second = ConvertFrom-InstallTranscript -Content (Get-Fixture -Name 'second-pass-runtime-present')

        $second.WindowsAppRuntimeInstalled | Should -BeFalse
        $second.WindowsAppRuntimeLine | Should -BeNullOrEmpty
        $second.AutoUpdatesStatus | Should -Be 'Already present'
    }

    It 'Reads a Windows App Runtime install that failed' {
        $transcript = ConvertFrom-InstallTranscript -Content "Windows App Runtime: NOT INSTALLED - Add-AppxProvisionedPackage failed (its error is above).`nSummary:`nAuto-updates: NOT CONFIGURED - Microsoft.WindowsAppRuntime.1.8 is missing, and Winget-AutoUpdate would leave winget unusable without it."

        $transcript.WindowsAppRuntimeInstalled | Should -BeFalse
        $transcript.WindowsAppRuntimeLine | Should -Be 'NOT INSTALLED - Add-AppxProvisionedPackage failed (its error is above).'
        $transcript.AutoUpdatesFrameworkMissing | Should -BeTrue
    }

    # Review of item 31: e2e/Invoke-InstallPass.ps1 fails an exit 8 whose transcript shows the
    # install started and failed, and accepts one where a precondition kept it from starting.
    It 'Reads whether the installer started its install of the Windows App Runtime: <Fixture> -> <Attempted>' -ForEach @(
        @{ Fixture = 'first-pass-runtime-installed'; Attempted = $true }
        @{ Fixture = 'second-pass-runtime-present'; Attempted = $false }
        @{ Fixture = 'first-pass'; Attempted = $false }
    ) {
        $transcript = ConvertFrom-InstallTranscript -Content (Get-Fixture -Name $Fixture)

        $transcript.WindowsAppRuntimeAttempted | Should -Be $Attempted
    }

    # The SYSTEM leg (work-order item 34) checks that one run installs the framework at most once.
    It 'Counts the Windows App Runtime installs of a run: <Fixture> -> <Count>' -ForEach @(
        @{ Fixture = 'first-pass-runtime-installed'; Count = 1 }
        @{ Fixture = 'second-pass-runtime-present'; Count = 0 }
        @{ Fixture = 'first-pass'; Count = 0 }
    ) {
        (ConvertFrom-InstallTranscript -Content (Get-Fixture -Name $Fixture)).WindowsAppRuntimeInstallCount | Should -Be $Count
    }

    # Review of item 32: the refusal that means the pinned framework has to move, for a newer 1.8
    # build and for another family alike. e2e/Invoke-InstallPass.ps1 fails a pass that shows it.
    It 'Reads a refusal because the pinned framework does not meet what the latest winget release needs: <Needs>' -ForEach @(
        @{ Needs = 'Microsoft.WindowsAppRuntime.1.8 >= 8000.1200.0.0'; Missing = 'Microsoft.WindowsAppRuntime.1.8' }
        @{ Needs = 'Microsoft.WindowsAppRuntime.2 >= 2000.120.5.0'; Missing = 'Microsoft.WindowsAppRuntime.2' }
    ) {
        $content = @(
            "Windows App Runtime: NOT INSTALLED - the latest winget release needs $Needs, and the framework this installer installs, Microsoft.WindowsAppRuntime.1.8 8000.994.2142.0, does not meet that; a newer version of this installer is needed."
            'Summary:'
            "Auto-updates: NOT CONFIGURED - $Missing is missing, and Winget-AutoUpdate would leave winget unusable without it."
        ) -join "`n"

        $transcript = ConvertFrom-InstallTranscript -Content $content

        $transcript.WindowsAppRuntimePinStale | Should -BeTrue
        $transcript.WindowsAppRuntimeAttempted | Should -BeFalse
        $transcript.WindowsAppRuntimeInstalled | Should -BeFalse
    }

    It 'Does not read another Windows App Runtime outcome as a stale pin: <Line>' -ForEach @(
        @{ Line = 'NOT INSTALLED - installing it for all users needs administrator rights.' }
        @{ Line = 'NOT INSTALLED - Add-AppxProvisionedPackage failed (its error is above).' }
        @{ Line = 'installed Microsoft.WindowsAppRuntime.1.8 8000.994.2142.0 (X64) for all users.' }
    ) {
        (ConvertFrom-InstallTranscript -Content "Windows App Runtime: $Line`nSummary:").WindowsAppRuntimePinStale | Should -BeFalse
        (ConvertFrom-InstallTranscript -Content (Get-Fixture -Name 'first-pass')).WindowsAppRuntimePinStale | Should -BeFalse
    }

    It 'Reads the timeout failures of both passes, which the old failure regex missed, and what the retry recovered' {
        $content = Get-Fixture -Name 'timeouts'
        # The regex Assert-Install.ps1 used before (P3-39) finds only the first-pass failure that
        # the retry then recovered, and none of the two apps that are still failed.
        $oldMatches = @(($content -split '\r?\n') | Where-Object { $_ -match '^(Failed to install|Retry failed):\s+' })
        $oldMatches.Count | Should -Be 1

        $transcript = ConvertFrom-InstallTranscript -Content $content

        $transcript.FirstPassFailed | Should -Be @('Adobe.Acrobat.Reader.64-bit', 'Google.GoogleDrive', 'Klocman.BulkCrapUninstaller')
        $transcript.RetryFailed | Should -Be @('Google.GoogleDrive', 'Klocman.BulkCrapUninstaller')
        $transcript.RetrySucceeded | Should -Be @('Adobe.Acrobat.Reader.64-bit')
        $transcript.RecoveredOnRetry | Should -Be @('Adobe.Acrobat.Reader.64-bit')
        $transcript.SummaryFailed | Should -Be @('Google.GoogleDrive', 'Klocman.BulkCrapUninstaller')
        $transcript.FinalFailed | Should -Be @('Google.GoogleDrive', 'Klocman.BulkCrapUninstaller')
    }

    It 'Finds the timeout failures from the per-app lines alone when the summary has no Failed row' {
        $content = (Get-Fixture -Name 'timeouts') -replace '(?m)^Failed\s+Google\.GoogleDrive.*\r?\n', ''

        $transcript = ConvertFrom-InstallTranscript -Content $content

        $transcript.SummaryFailed | Should -BeNullOrEmpty
        $transcript.FinalFailed | Should -Be @('Google.GoogleDrive', 'Klocman.BulkCrapUninstaller')
    }

    It 'Never reads a retry-pass timeout as a first-pass failure of an app called retry:' {
        $transcript = ConvertFrom-InstallTranscript -Content "Winget list timed out for retry: Git.Git. Assuming installation failed.`nVerification timed out for retry: 7zip.7zip. Assuming installation failed."

        $transcript.FirstPassFailed | Should -BeNullOrEmpty
        $transcript.RetryFailed | Should -Be @('7zip.7zip', 'Git.Git')
    }

    It 'Reads a run whose circuit breaker found that winget cannot be launched' {
        $transcript = ConvertFrom-InstallTranscript -Content (Get-Fixture -Name 'winget-not-launchable')

        $transcript.WingetNotLaunchable | Should -BeTrue
        $transcript.FirstPassFailed.Count | Should -Be 9
        $transcript.RetryFailed | Should -BeNullOrEmpty
        $transcript.FinalFailed.Count | Should -Be 9
        $transcript.FinalFailed | Should -Not -Contain 'Dell.CommandUpdate.Universal'
        $transcript.NotApplicable.Keys | Should -Contain 'Dell.CommandUpdate.Universal'
        $transcript.WingetNotUsable | Should -BeTrue
    }

    It 'Marks a run that was aborted before its summary' {
        $transcript = ConvertFrom-InstallTranscript -Content (Get-Fixture -Name 'aborted')

        $transcript.HasSummary | Should -BeFalse
        $transcript.Aborted | Should -BeTrue
        $transcript.EarlyExitCode | Should -Be 5
        $transcript.FinalFailed | Should -Be @('GlavSoft.TightVNC')
        $transcript.AutoUpdatesStatus | Should -BeNullOrEmpty
    }

    It 'Reads a CRLF transcript the same as an LF one' {
        $lf = Get-Fixture -Name 'timeouts'
        $crlf = ($lf -replace '\r?\n', "`r`n")

        $fromLf = ConvertFrom-InstallTranscript -Content $lf
        $fromCrlf = ConvertFrom-InstallTranscript -Content $crlf

        $fromCrlf.FinalFailed | Should -Be $fromLf.FinalFailed
        $fromCrlf.AlreadyInstalled | Should -Be $fromLf.AlreadyInstalled
        $fromCrlf.BuildId | Should -Be $fromLf.BuildId
        $fromCrlf.NotApplicable['Dell.CommandUpdate.Universal'] | Should -Be 'Dell hardware only'
    }

    It 'Drops an id that an older, console-width summary cut off, and says so' {
        $ellipsis = [string][char]0x2026
        $content = "Failed to install: Klocman.BulkCrapUninstaller (install failed).`nSummary:`n`nStatus  Apps`n------  ----`nFailed  7zip.7zip, Git.Git, Klocman.$ellipsis`nAuto-updates: FAILED - Winget-AutoUpdate could not be installed."

        $transcript = ConvertFrom-InstallTranscript -Content $content

        $transcript.SummaryTruncated | Should -BeTrue
        $transcript.SummaryFailed | Should -Be @('7zip.7zip', 'Git.Git')
        $transcript.FinalFailed | Should -Be @('7zip.7zip', 'Git.Git', 'Klocman.BulkCrapUninstaller')
        $transcript.AutoUpdatesStatus | Should -Be 'FAILED'
    }

    It 'Still reads the line after Summary: when no table was printed' {
        $transcript = ConvertFrom-InstallTranscript -Content "Summary:`nAuto-updates: Configured (Winget-AutoUpdate v2.12.0)."

        $transcript.HasSummary | Should -BeTrue
        $transcript.AutoUpdatesStatus | Should -Be 'Configured'
    }

    It 'Reads the summary table the way Write-Table renders it' {
        $rows = @(@('Installed', '7zip.7zip, Git.Git'), @('Failed', 'Google.Chrome, Google.GoogleDrive'))
        $table = Write-Table -Headers @('Status', 'Apps') -Rows $rows 6>&1 | Out-String

        $transcript = ConvertFrom-InstallTranscript -Content ("Summary:`n" + $table + "`nAuto-updates: NOT CONFIGURED - missing.")

        $transcript.SummaryInstalled | Should -Be @('7zip.7zip', 'Git.Git')
        $transcript.SummaryFailed | Should -Be @('Google.Chrome', 'Google.GoogleDrive')
        $transcript.AutoUpdatesStatus | Should -Be 'NOT CONFIGURED'
    }

    It 'Reads a Deferred row, and the Failed row after it, then ignores the RESULT line (review findings P3-22, P3-41)' {
        # A run as SYSTEM or under cross-user elevation prints a Deferred row between Skipped and
        # Failed; it used to end the table there, so the Failed row was never read. The RESULT line
        # after the summary is for RMM tools, not for this parser.
        $rows = @(@('Installed', '7zip.7zip'), @('Skipped', 'Git.Git'), @('Deferred', 'Microsoft.WindowsTerminal, Zoom.Zoom'), @('Failed', 'Google.Chrome'))
        $table = Write-Table -Headers @('Status', 'Apps') -Rows $rows 6>&1 | Out-String
        $result = 'RESULT: exit=1 installed=1 skipped=1 deferred=2 failed=1 autoupdates=Configured restart=no build=1.0.0+5ea1f00d log=C:\ProgramData\winget-app-setup\logs\install-20261005-060000.log'

        $transcript = ConvertFrom-InstallTranscript -Content ("Summary:`n" + $table + "`nAuto-updates: Configured (Winget-AutoUpdate v2.12.0).`n" + $result)

        $transcript.SummaryInstalled | Should -Be @('7zip.7zip')
        $transcript.SummarySkipped | Should -Be @('Git.Git')
        $transcript.SummaryDeferred | Should -Be @('Microsoft.WindowsTerminal', 'Zoom.Zoom')
        $transcript.SummaryFailed | Should -Be @('Google.Chrome')
        $transcript.FinalFailed | Should -Be @('Google.Chrome')
        $transcript.AutoUpdatesStatus | Should -Be 'Configured'
        $transcript.AutoUpdatesLine | Should -Be 'Configured (Winget-AutoUpdate v2.12.0).'
    }

    # Work-order item 34: the SYSTEM leg checks that the run really ran as SYSTEM.
    # wgt-gq8.42: which engine installed, the module's own line, and how each app was installed.
    It 'Reads a SYSTEM run that installed with Microsoft.WinGet.Client' {
        $parsed = ConvertFrom-InstallTranscript -Content (Get-Fixture -Name 'system-winget-client-transcript')

        $parsed.RanAsSystem | Should -BeTrue
        $parsed.InstallEngine | Should -Be 'WinGetClient'
        $parsed.InstallEngineVersion | Should -Be '1.29.380'
        $parsed.InstallEngineLine | Should -BeLike 'Microsoft.WinGet.Client 1.29.380 (WinGet engine v1.29.380, PowerShell 7.6.6 x64; engine log folder *'
        $parsed.WingetClientModuleReady | Should -BeTrue
        $parsed.WingetClientModuleVersion | Should -Be '1.29.380'
        $parsed.WingetClientModuleSha256 | Should -Be '3469E5747EB6B100E51FED3F2057386B5BA60BC8955A6669B5C2EB562E316619'
        $parsed.WingetClientModuleFromCache | Should -BeFalse
        $parsed.WingetClientModuleNotReadyReason | Should -BeNullOrEmpty
        $parsed.WingetClientInstallIds | Should -Be @('7zip.7zip', 'Adobe.Acrobat.Reader.64-bit', 'Git.Git', 'GlavSoft.TightVNC', 'Google.Chrome', 'Google.GoogleDrive', 'Klocman.BulkCrapUninstaller')
        $parsed.WingetExeInstallCount | Should -Be 0
        $parsed.WingetClientEngineNotStartable | Should -BeFalse
        $parsed.SummaryInstalled.Count | Should -Be 7
    }

    It 'Reads a second run that took the module from the cache and installed nothing' {
        $parsed = ConvertFrom-InstallTranscript -Content (Get-Fixture -Name 'system-winget-client-second-pass')

        $parsed.InstallEngine | Should -Be 'WinGetClient'
        $parsed.WingetClientModuleFromCache | Should -BeTrue
        $parsed.WingetClientInstallIds | Should -BeNullOrEmpty
        $parsed.WingetExeInstallCount | Should -Be 0
        $parsed.SummarySkipped.Count | Should -Be 11
        $parsed.WindowsAppRuntimeInstallCount | Should -Be 0
    }

    It 'Reads a run that fell back to winget.exe: the first Install engine line, the reason, and the winget.exe installs' {
        $parsed = ConvertFrom-InstallTranscript -Content (Get-Fixture -Name 'system-winget-client-fallback-transcript')

        $parsed.InstallEngine | Should -Be 'Cli'
        $parsed.InstallEngineVersion | Should -BeNullOrEmpty
        $parsed.InstallEngineLine | Should -BeLike 'winget.exe (*), not the requested Microsoft.WinGet.Client: the module is not ready: *'
        $parsed.WingetClientModuleReady | Should -BeFalse
        $parsed.WingetClientModuleNotReadyReason | Should -Be 'downloading https://www.powershellgallery.com/api/v2/package/Microsoft.WinGet.Client/1.29.380 failed: No such host is known. (www.powershellgallery.com:443)'
        $parsed.WingetClientInstallIds | Should -BeNullOrEmpty
        $parsed.WingetExeInstallCount | Should -Be 7
    }

    It 'Reads the module''s last line, so a probe that failed after the module was ready counts' {
        $text = @(
            'WinGet client module: ready - Microsoft.WinGet.Client 1.29.380, SHA256 3469E5747EB6B100E51FED3F2057386B5BA60BC8955A6669B5C2EB562E316619, downloaded from the PowerShell Gallery.',
            'WinGet client module: NOT READY - the module''s probe failed: Get-WinGetVersion returned no version.'
        ) -join "`n"

        $parsed = ConvertFrom-InstallTranscript -Content $text

        $parsed.WingetClientModuleReady | Should -BeFalse
        $parsed.WingetClientModuleNotReadyReason | Should -Be 'the module''s probe failed: Get-WinGetVersion returned no version'
    }

    It 'Reads the engine''s circuit breaker' {
        $parsed = ConvertFrom-InstallTranscript -Content 'The WinGet client engine cannot be started on this machine (the WinGet client engine could not start: FileLoadException: x). The remaining apps are marked failed without an install attempt and are not retried.'

        $parsed.WingetClientEngineNotStartable | Should -BeTrue
        $parsed.WingetNotLaunchable | Should -BeFalse
    }

    It 'Leaves the engine fields empty for a run that is not SYSTEM' {
        $parsed = ConvertFrom-InstallTranscript -Content (Get-Fixture -Name 'first-pass')

        $parsed.InstallEngineLine | Should -BeNullOrEmpty
        $parsed.InstallEngine | Should -BeNullOrEmpty
        $parsed.WingetClientModuleLine | Should -BeNullOrEmpty
        $parsed.WingetExeInstallCount | Should -Be 0
    }

    It 'Says whether the run ran as SYSTEM' {
        $system = ConvertFrom-InstallTranscript -Content "Installer build: 1.0.0+5ea1f00d`nRunning as SYSTEM (for example from an RMM agent): installing for the whole PC only.`nSummary:"
        $user = Get-Fixture -Name 'first-pass'

        $system.RanAsSystem | Should -BeTrue
        (ConvertFrom-InstallTranscript -Content $user).RanAsSystem | Should -BeFalse
    }
}

Describe 'ConvertFrom-BootstrapTranscript' {
    It 'Reads a bootstrap that installed PowerShell 7 and relaunched' {
        $bootstrap = ConvertFrom-BootstrapTranscript -Content (Get-Fixture -Name 'bootstrap-installed')

        $bootstrap.BuildId | Should -Be '1.0.0+5ea1f00d'
        $bootstrap.InstalledPowerShell7 | Should -BeTrue
        $bootstrap.RelaunchPath | Should -Be 'C:\Users\runneradmin\AppData\Local\Microsoft\WindowsApps\pwsh.exe'
        $bootstrap.ChildExitCode | Should -Be 0
    }

    It 'Reads a bootstrap that found PowerShell 7, and one that never relaunched' {
        (ConvertFrom-BootstrapTranscript -Content (Get-Fixture -Name 'bootstrap-found')).InstalledPowerShell7 | Should -BeFalse

        $failed = ConvertFrom-BootstrapTranscript -Content "Installer build: 1.0.0+5ea1f00d`nPowerShell 7 could not be installed automatically. Install it manually."
        $failed.RelaunchPath | Should -BeNullOrEmpty
        $failed.ChildExitCode | Should -BeNullOrEmpty
    }
}

Describe 'Test-InstallFailureContainment' {
    It 'Fails the timeout failures unless both apps are skip-listed, and names what the retry recovered' {
        $transcript = ConvertFrom-InstallTranscript -Content (Get-Fixture -Name 'timeouts')

        $strict = Test-InstallFailureContainment -Transcript $transcript -SkipApps @()
        $strict.Passed | Should -BeFalse
        $strict.Detail | Should -Be 'apps outside -SkipApps failed: Google.GoogleDrive, Klocman.BulkCrapUninstaller'

        (Test-InstallFailureContainment -Transcript $transcript -SkipApps @('Google.GoogleDrive')).Passed | Should -BeFalse

        $contained = Test-InstallFailureContainment -Transcript $transcript -SkipApps @('Google.GoogleDrive', 'Klocman.BulkCrapUninstaller')
        $contained.Passed | Should -BeTrue
        $contained.Detail | Should -Be 'failed apps all skip-listed: Google.GoogleDrive, Klocman.BulkCrapUninstaller; recovered on retry: Adobe.Acrobat.Reader.64-bit'
    }

    It 'Fails a run where winget could not be launched with an unrelated skip list, and says why every app failed' {
        $transcript = ConvertFrom-InstallTranscript -Content (Get-Fixture -Name 'winget-not-launchable')

        $verdict = Test-InstallFailureContainment -Transcript $transcript -SkipApps @('Google.GoogleDrive')

        $verdict.Passed | Should -BeFalse
        $verdict.Detail | Should -Match '^apps outside -SkipApps failed: 7zip\.7zip, '
        $verdict.Detail | Should -Not -Match 'Google\.GoogleDrive,'
        $verdict.Detail | Should -Match 'winget could not be launched, so the remaining apps failed without an install attempt'
    }

    It 'Fails a transcript without a summary, whatever the skip list' {
        $transcript = ConvertFrom-InstallTranscript -Content (Get-Fixture -Name 'aborted')

        $verdict = Test-InstallFailureContainment -Transcript $transcript -SkipApps @('GlavSoft.TightVNC')

        $verdict.Passed | Should -BeFalse
        $verdict.Detail | Should -Be 'the run was aborted before its summary, so its failures cannot be checked; failed before that: GlavSoft.TightVNC'
    }

    It 'Passes a clean run' {
        $verdict = Test-InstallFailureContainment -Transcript (ConvertFrom-InstallTranscript -Content (Get-Fixture -Name 'first-pass'))

        $verdict.Passed | Should -BeTrue
        $verdict.Detail | Should -Be 'no failed apps'
    }
}

Describe 'Get-TranscriptAssertionResult' {
    It 'Passes a clean PowerShell 7 leg and leaves the dry-run transcript out' {
        $logs = New-TestLogDirectory -Fixture @('first-pass', 'second-pass', 'timeouts') -Name @('install-20261005-060449.log', 'install-20261005-061511.log', 'install-20261005-061700-whatif.log')
        $installer = New-TestInstaller -BuildId '1.0.0+5ea1f00d'

        $rows = @(Get-TranscriptAssertionResult -LogDirectory $logs -ExpectedAppIds $script:CatalogIds -NotApplicableApps $script:NotApplicable -ExpectAllSkippedOnSecondRun -InstallerPath $installer -ExpectedAutoUpdatesStatus 'NOT CONFIGURED')

        @($rows | Where-Object { $_.Result -ne 'PASS' } | ForEach-Object { "$($_.Assertion): $($_.Detail)" }) | Should -BeNullOrEmpty
        ($rows | Where-Object Assertion -EQ 'Transcript exists').Detail | Should -Be '2 transcript(s); latest: install-20261005-061511.log'
        @($rows | Where-Object Assertion -Like 'Failures contained*').Count | Should -Be 2
        @($rows | Where-Object Assertion -Like 'Second run skipped:*').Count | Should -Be 9
        @($rows | Where-Object Assertion -Like 'Ran the installer under test*').Count | Should -Be 2
        ($rows | Where-Object Assertion -EQ "Transcript reports 'Auto-updates: NOT CONFIGURED'") | Should -Not -BeNullOrEmpty
        ($rows | Where-Object Assertion -EQ 'Not-applicable skip logged: Dell.CommandUpdate.Universal').Detail | Should -Be 'Skipping: Dell.CommandUpdate.Universal (not applicable: Dell hardware only)'
    }

    It 'Passes the leg expected on windows-latest: the first pass installs the Windows App Runtime and Winget-AutoUpdate, the second finds both (work-order item 31)' {
        $logs = New-TestLogDirectory -Fixture @('first-pass-runtime-installed', 'second-pass-runtime-present') -Name @('install-20261005-060449.log', 'install-20261005-061511.log')
        $installer = New-TestInstaller -BuildId '1.0.0+5ea1f00d'

        $rows = @(Get-TranscriptAssertionResult -LogDirectory $logs -ExpectedAppIds $script:CatalogIds -NotApplicableApps $script:NotApplicable -ExpectAllSkippedOnSecondRun -InstallerPath $installer)

        @($rows | Where-Object { $_.Result -ne 'PASS' } | ForEach-Object { "$($_.Assertion): $($_.Detail)" }) | Should -BeNullOrEmpty
        ($rows | Where-Object Assertion -EQ 'Second run did not install the Windows App Runtime again').Result | Should -Be 'PASS'
        @($rows | Where-Object Assertion -Like 'Second run skipped:*').Count | Should -Be 9
    }

    It 'Fails a second pass that installed the Windows App Runtime again' {
        $logs = New-TestLogDirectory -Fixture @('first-pass-runtime-installed', 'second-pass-runtime-present')
        $second = Get-ChildItem -LiteralPath $logs -Filter '*.log' | Sort-Object Name | Select-Object -Last 1
        $content = (Get-Content -Raw -LiteralPath $second.FullName) -replace 'Summary:', "Windows App Runtime: installed Microsoft.WindowsAppRuntime.1.8 8000.994.2142.0 (X64) for all users.`nSummary:"
        $writtenAt = $second.LastWriteTime
        Set-Content -LiteralPath $second.FullName -Value $content -NoNewline
        # Still the latest transcript: the rewrite must not reorder the passes.
        (Get-Item -LiteralPath $second.FullName).LastWriteTime = $writtenAt

        $rows = @(Get-TranscriptAssertionResult -LogDirectory $logs -ExpectedAppIds $script:CatalogIds -NotApplicableApps $script:NotApplicable -ExpectAllSkippedOnSecondRun)

        $row = $rows | Where-Object Assertion -EQ 'Second run did not install the Windows App Runtime again'
        ($rows | Where-Object Assertion -EQ 'Transcript exists').Detail | Should -Match "latest: $([regex]::Escape($second.Name))$"
        $row.Result | Should -Be 'FAIL'
        $row.Detail | Should -Be "$($second.Name): Windows App Runtime: installed Microsoft.WindowsAppRuntime.1.8 8000.994.2142.0 (X64) for all users."
    }

    It 'Quotes why the installer could not install the Windows App Runtime next to the expected NOT CONFIGURED' {
        $logs = New-TestLogDirectory -Fixture @('second-pass')
        $log = Get-ChildItem -LiteralPath $logs -Filter '*.log' | Select-Object -First 1
        $content = (Get-Content -Raw -LiteralPath $log.FullName) -replace 'Summary:', "Windows App Runtime: NOT INSTALLED - Add-AppxProvisionedPackage failed (its error is above).`nSummary:"
        Set-Content -LiteralPath $log.FullName -Value $content -NoNewline

        $rows = @(Get-TranscriptAssertionResult -LogDirectory $logs -ExpectedAutoUpdatesStatus 'NOT CONFIGURED')

        $row = $rows | Where-Object Assertion -EQ "Transcript reports 'Auto-updates: NOT CONFIGURED'"
        $row.Result | Should -Be 'PASS'
        $row.Detail | Should -Match '\(Windows App Runtime: NOT INSTALLED - Add-AppxProvisionedPackage failed \(its error is above\)\.\)$'
    }

    It 'Keeps the 5.1 bootstrap transcripts apart, although each is written after the run it started' {
        # The order the 5.1 leg writes them in: each bootstrap transcript closes after its
        # PowerShell 7 run. Before this change the second bootstrap transcript counted as the
        # latest run, so every idempotence assertion failed on the 5.1 leg.
        $logs = New-TestLogDirectory -Fixture @('first-pass', 'bootstrap-installed', 'second-pass', 'bootstrap-found') -Name @('install-20261005-060449.log', 'install-20261005-060431-bootstrap.log', 'install-20261005-061511.log', 'install-20261005-061510-bootstrap.log')
        $installer = New-TestInstaller -BuildId '1.0.0+5ea1f00d'

        $rows = @(Get-TranscriptAssertionResult -LogDirectory $logs -ExpectedAppIds $script:CatalogIds -NotApplicableApps $script:NotApplicable -ExpectAllSkippedOnSecondRun -InstallerPath $installer -ExpectedAutoUpdatesStatus 'NOT CONFIGURED' -ExpectPowerShell7Bootstrap -ExpectPowerShell7Installed)

        @($rows | Where-Object { $_.Result -ne 'PASS' } | ForEach-Object { "$($_.Assertion): $($_.Detail)" }) | Should -BeNullOrEmpty
        ($rows | Where-Object Assertion -EQ 'First pass installed PowerShell 7').Detail | Should -Be 'install-20261005-060431-bootstrap.log: PowerShell 7 is installed.'
        ($rows | Where-Object Assertion -EQ 'Transcript exists').Detail | Should -Be '2 transcript(s) and 2 bootstrap transcript(s); latest: install-20261005-061511.log'
        @($rows | Where-Object Assertion -Like 'Failures contained*').Count | Should -Be 2
        @($rows | Where-Object Assertion -Like 'Ran the installer under test*').Count | Should -Be 4
        ($rows | Where-Object Assertion -EQ 'Every pass went through the PowerShell 7 bootstrap').Detail | Should -Be '2 bootstrap transcript(s), 2 PowerShell 7 run transcript(s)'
        ($rows | Where-Object Assertion -EQ 'Bootstrap relaunched under PowerShell 7 (install-20261005-060431-bootstrap.log)').Detail | Should -Be 'installed PowerShell 7, relaunched under C:\Users\runneradmin\AppData\Local\Microsoft\WindowsApps\pwsh.exe, that run ended with exit code 0'
        ($rows | Where-Object Assertion -EQ 'Bootstrap relaunched under PowerShell 7 (install-20261005-061510-bootstrap.log)').Detail | Should -Match '^found PowerShell 7, '
    }

    It 'Fails the bootstrap assertions when a pass never reached PowerShell 7' {
        $logs = New-TestLogDirectory -Fixture @('first-pass', 'bootstrap-installed', 'bootstrap-found') -Name @('install-20261005-060449.log', 'install-20261005-060431-bootstrap.log', 'install-20261005-061510-bootstrap.log')
        Set-Content -LiteralPath (Join-Path $logs 'install-20261005-061510-bootstrap.log') -Value "Installer build: 1.0.0+5ea1f00d`nPowerShell 7 could not be installed automatically."

        $rows = @(Get-TranscriptAssertionResult -LogDirectory $logs -ExpectPowerShell7Bootstrap)

        ($rows | Where-Object Assertion -EQ 'Every pass went through the PowerShell 7 bootstrap').Result | Should -Be 'FAIL'
        $neverRelaunched = $rows | Where-Object Assertion -EQ 'Bootstrap relaunched under PowerShell 7 (install-20261005-061510-bootstrap.log)'
        $neverRelaunched.Result | Should -Be 'FAIL'
        $neverRelaunched.Detail | Should -Be 'never relaunched the installer under PowerShell 7 (see the bootstrap transcript)'
    }

    It 'Fails -ExpectPowerShell7Installed when the first pass''s bootstrap found PowerShell 7 instead of installing it' {
        # Runner preparation left PowerShell 7 in place: both passes find it, everything else
        # passes, and the bootstrap's install path never ran.
        $logs = New-TestLogDirectory -Fixture @('first-pass', 'bootstrap-found', 'second-pass', 'bootstrap-found') -Name @('install-20261005-060449.log', 'install-20261005-060431-bootstrap.log', 'install-20261005-061511.log', 'install-20261005-061510-bootstrap.log')

        $rows = @(Get-TranscriptAssertionResult -LogDirectory $logs -ExpectPowerShell7Bootstrap -ExpectPowerShell7Installed)

        @($rows | Where-Object { $_.Result -ne 'PASS' } | ForEach-Object Assertion) | Should -Be @('First pass installed PowerShell 7')
        ($rows | Where-Object Assertion -EQ 'First pass installed PowerShell 7').Detail | Should -Be 'install-20261005-060431-bootstrap.log found C:\Users\runneradmin\AppData\Local\Microsoft\WindowsApps\pwsh.exe instead of installing it; runner preparation did not remove PowerShell 7 (see its warning), or the bootstrap found another pwsh'
    }

    It 'Fails -ExpectPowerShell7Installed without a bootstrap transcript, and adds nothing without the switch' {
        $logs = New-TestLogDirectory -Fixture @('first-pass')

        (@(Get-TranscriptAssertionResult -LogDirectory $logs -ExpectPowerShell7Installed) | Where-Object Assertion -EQ 'First pass installed PowerShell 7').Detail | Should -Be 'no bootstrap transcript'
        @(Get-TranscriptAssertionResult -LogDirectory $logs -ExpectPowerShell7Bootstrap | Where-Object Assertion -EQ 'First pass installed PowerShell 7') | Should -BeNullOrEmpty
    }

    It 'Fails every transcript, bootstrap ones included, that logged another build than the installer under test' {
        $logs = New-TestLogDirectory -Fixture @('bootstrap-installed', 'first-pass') -Name @('install-20261005-060431-bootstrap.log', 'install-20261005-060449.log')
        $installer = New-TestInstaller -BuildId '1.0.0+0ddba11e'

        $rows = @(Get-TranscriptAssertionResult -LogDirectory $logs -InstallerPath $installer)

        $buildRows = @($rows | Where-Object Assertion -Like 'Ran the installer under test*')
        $buildRows.Count | Should -Be 2
        $buildRows | ForEach-Object { $_.Result | Should -Be 'FAIL' }
        $buildRows[0].Detail | Should -Be "expected 'Installer build: 1.0.0+0ddba11e' from $installer, logged 'Installer build: 1.0.0+5ea1f00d'"
    }

    It 'Fails a second pass that hit timeouts on the idempotence and containment assertions' {
        $logs = New-TestLogDirectory -Fixture @('first-pass', 'timeouts')

        $rows = @(Get-TranscriptAssertionResult -LogDirectory $logs -ExpectedAppIds $script:CatalogIds -NotApplicableApps $script:NotApplicable -ExpectAllSkippedOnSecondRun)

        ($rows | Where-Object Assertion -EQ 'Second run failed nothing (non-skip-listed)').Detail | Should -Be 'failed on second run: Adobe.Acrobat.Reader.64-bit, Google.GoogleDrive, Klocman.BulkCrapUninstaller'
        ($rows | Where-Object Assertion -EQ 'Second run installed nothing (non-skip-listed)').Detail | Should -Be 'installed on second run: 7zip.7zip, GlavSoft.TightVNC, Adobe.Acrobat.Reader.64-bit, Google.Chrome, Git.Git'
        ($rows | Where-Object Assertion -EQ 'Second run skipped: Google.GoogleDrive').Result | Should -Be 'FAIL'
        ($rows | Where-Object Assertion -EQ 'Failures contained (install-20261005-060100.log)').Result | Should -Be 'FAIL'
        ($rows | Where-Object Assertion -EQ 'Failures contained (install-20261005-060000.log)').Result | Should -Be 'PASS'
    }

    It 'Fails the transcript assertions when there is no real-run transcript' {
        $logs = New-TestLogDirectory -Fixture @('first-pass') -Name @('install-20261005-060000-whatif.log')

        $rows = @(Get-TranscriptAssertionResult -LogDirectory $logs -NotApplicableApps $script:NotApplicable -ExpectedAutoUpdatesStatus 'NOT CONFIGURED')

        @($rows | ForEach-Object Assertion) | Should -Be @('Transcript exists', "Transcript contains 'Installer build'", "Transcript reports 'Auto-updates: NOT CONFIGURED'", 'Not-applicable skip logged: Dell.CommandUpdate.Universal')
        @($rows | Where-Object Result -EQ 'PASS') | Should -BeNullOrEmpty
    }

    It 'Fails a missing not-applicable skip line and an unexpected auto-update status' {
        $logs = New-TestLogDirectory -Fixture @('winget-not-launchable')
        # The same run without its not-applicable skip line.
        $log = Get-ChildItem -LiteralPath $logs -Filter '*.log' | Select-Object -First 1
        $kept = @(Get-Content -LiteralPath $log.FullName | Where-Object { $_ -notmatch '^Skipping: Dell\.CommandUpdate\.Universal ' })
        Set-Content -LiteralPath $log.FullName -Value $kept

        $rows = @(Get-TranscriptAssertionResult -LogDirectory $logs -NotApplicableApps $script:NotApplicable -ExpectedAutoUpdatesStatus 'Configured')

        ($rows | Where-Object Assertion -EQ 'Not-applicable skip logged: Dell.CommandUpdate.Universal').Detail | Should -Be "transcript install-20261005-060000.log has no 'Skipping: Dell.CommandUpdate.Universal (not applicable: Dell hardware only)'"
        ($rows | Where-Object Assertion -EQ "Transcript reports 'Auto-updates: Configured'").Result | Should -Be 'FAIL'
    }
}

# Assert-Install.ps1 used to decide applicability from 'condition' alone, so an app gated only by
# its arch list was expected installed where the run skipped it as not applicable.
Describe 'Get-CatalogAppApplicability' {
    BeforeEach {
        $script:warnings = @()
        Mock Write-WarningMessage { $script:warnings += $Message }
        Mock Get-ComputerManufacturer { 'Microsoft Corporation' }
        Mock Test-IsSystemAccount { $false }
        Mock Test-WindowsTerminalHostsCurrentSession { $false }
    }

    It 'Leaves out an app whose arch list rules this PC out, with the reason the run printed' {
        Mock Get-OSArchitecture { 'Arm64' }

        $split = Get-CatalogAppApplicability -Apps @(@{ name = 'Contoso.X64Only'; arch = 'X64' }, @{ name = 'Contoso.Anywhere' })

        @($split.Applicable | ForEach-Object { $_.name }) | Should -Be @('Contoso.Anywhere')
        @($split.NotApplicable.Keys) | Should -Be @('Contoso.X64Only')
        $split.NotApplicable['Contoso.X64Only'] | Should -Be 'for X64 Windows only; this PC is Arm64'
    }

    It 'Leaves out an app whose condition is false, with its description or condition not met' {
        Mock Get-OSArchitecture { 'X64' }

        $split = Get-CatalogAppApplicability -Apps @(
            @{ name = 'Contoso.Described'; condition = { $false }; conditionDescription = 'Contoso hardware only' },
            @{ name = 'Contoso.Bare'; condition = { $false } },
            @{ name = 'Contoso.Yes'; condition = { $true } }
        )

        @($split.Applicable | ForEach-Object { $_.name }) | Should -Be @('Contoso.Yes')
        $split.NotApplicable['Contoso.Described'] | Should -Be 'Contoso hardware only'
        $split.NotApplicable['Contoso.Bare'] | Should -Be 'condition not met'
    }

    It 'Expects an app installed when its gate cannot answer (fail open, as in the run)' {
        Mock Get-OSArchitecture { throw 'The OS architecture could not be read.' }

        $split = Get-CatalogAppApplicability -Apps @(@{ name = 'Contoso.X64Only'; arch = 'X64' }, @{ name = 'Contoso.Throws'; condition = { throw 'CIM unavailable' } })

        @($split.Applicable | ForEach-Object { $_.name }) | Should -Be @('Contoso.X64Only', 'Contoso.Throws')
        $split.NotApplicable.Count | Should -Be 0
        @($script:warnings).Count | Should -Be 2
    }

    It 'Keeps expecting an app with no arch list and no condition installed when the module says it does not apply' {
        # The e2e's one check that does not come from the code under test: such an app applies
        # everywhere, so a module that skipped it must not be matched by the run's skip line.
        Mock Get-OSArchitecture { 'X64' }
        Mock Test-AppApplicability { $false }

        $split = Get-CatalogAppApplicability -Apps @(
            @{ name = 'Contoso.Anywhere' },
            @{ name = 'Contoso.Arm64Only'; arch = 'Arm64' },
            @{ name = 'Contoso.Conditioned'; condition = { $true }; conditionDescription = 'Contoso hardware only' },
            @{ name = 'Contoso.NullArch'; arch = $null }
        )

        @($split.Applicable | ForEach-Object { $_.name }) | Should -Be @('Contoso.Anywhere', 'Contoso.NullArch')
        @($split.UngatedNotApplicable) | Should -Be @('Contoso.Anywhere', 'Contoso.NullArch')
        @($split.NotApplicable.Keys) | Should -Be @('Contoso.Arm64Only', 'Contoso.Conditioned')
        $split.NotApplicable['Contoso.Arm64Only'] | Should -Be 'for Arm64 Windows only; this PC is X64'
        $split.NotApplicable['Contoso.Conditioned'] | Should -Be 'Contoso hardware only'
    }

    It 'Lists no ungated app when the module agrees' {
        Mock Get-OSArchitecture { 'Arm64' }

        $split = Get-CatalogAppApplicability -Apps @(@{ name = 'Contoso.X64Only'; arch = 'X64' }, @{ name = 'Contoso.Anywhere' })

        @($split.Applicable | ForEach-Object { $_.name }) | Should -Be @('Contoso.Anywhere')
        $split.PSObject.Properties.Name | Should -Contain 'UngatedNotApplicable'
        @($split.UngatedNotApplicable).Count | Should -Be 0
    }

    It 'Splits the real catalog on <Architecture>: expects <Installed>, skip lines for <Skipped>' -ForEach @(
        @{ Architecture = 'X64'; Installed = 'Adobe.Acrobat.Reader.64-bit'; Skipped = @('Adobe.Acrobat.Reader.32-bit', 'Dell.CommandUpdate.Universal') }
        @{ Architecture = 'Arm64'; Installed = 'Adobe.Acrobat.Reader.32-bit'; Skipped = @('Adobe.Acrobat.Reader.64-bit', 'Dell.CommandUpdate.Universal') }
    ) {
        $script:mockedArchitecture = $Architecture
        Mock Get-OSArchitecture { $script:mockedArchitecture }
        $catalog = @(Get-DefaultAppCatalog)

        $split = Get-CatalogAppApplicability -Apps $catalog

        $applicableIds = @($split.Applicable | ForEach-Object { $_.name })
        $applicableIds | Should -Contain $Installed
        $applicableIds | Should -Contain 'Google.GoogleDrive'
        @($split.NotApplicable.Keys) | Should -Be $Skipped
        foreach ($id in $Skipped) {
            $app = $catalog | Where-Object { $_.name -eq $id }
            $split.NotApplicable[$id] | Should -Be $app.conditionDescription
        }
        ($applicableIds.Count + $split.NotApplicable.Count) | Should -Be $catalog.Count
        @($split.UngatedNotApplicable).Count | Should -Be 0
        $script:warnings | Should -BeNullOrEmpty
    }

    It 'Takes an empty list (every app skip-listed)' {
        $split = Get-CatalogAppApplicability -Apps @()

        @($split.Applicable).Count | Should -Be 0
        $split.NotApplicable.Count | Should -Be 0
        @($split.UngatedNotApplicable).Count | Should -Be 0
    }
}

Describe 'Installer messages the transcript parser keys on' {
    # A reworded message would make the parser match nothing, and the e2e assertions would then
    # pass a failed run (for containment) or fail a good one. Each line below is copied from what
    # e2e/TranscriptAssertions.ps1 matches; this checks the installer source still writes it.
    It 'Is still written by <File>: <Text>' -ForEach @(
        @{ File = 'WingetAppSetup/Public/Install.ps1'; Text = 'Write-Success "Successfully installed: $($app.name)"' }
        @{ File = 'WingetAppSetup/Public/Install.ps1'; Text = 'Write-WarningMessage "Skipping: $($app.name) (already installed)"' }
        @{ File = 'WingetAppSetup/Public/Install.ps1'; Text = 'Write-WarningMessage "Skipping: $($app.name) (not applicable: $conditionText)"' }
        @{ File = 'WingetAppSetup/Public/Install.ps1'; Text = 'Write-ErrorMessage "Failed to install: $($app.name) ($failureReason)."' }
        @{ File = 'WingetAppSetup/Public/Install.ps1'; Text = 'Write-ErrorMessage "Failed to install: $($app.name). Error: $_"' }
        @{ File = 'WingetAppSetup/Public/Install.ps1'; Text = 'Write-WarningMessage "Winget list timed out for $($app.name). Marking as failed; it will be retried."' }
        @{ File = 'WingetAppSetup/Public/Install.ps1'; Text = 'Write-WarningMessage "Verification timed out for: $($app.name). Assuming installation failed."' }
        @{ File = 'WingetAppSetup/Public/Install.ps1'; Text = 'Write-WarningMessage "Winget list timed out for retry: $appName. Assuming installation failed."' }
        @{ File = 'WingetAppSetup/Public/Install.ps1'; Text = 'Write-WarningMessage "Verification timed out for retry: $appName. Assuming installation failed."' }
        @{ File = 'WingetAppSetup/Public/Install.ps1'; Text = 'Write-ErrorMessage "Retry failed: $appName ($failureReason)."' }
        @{ File = 'WingetAppSetup/Public/Install.ps1'; Text = 'Write-ErrorMessage "Retry failed: $appName. Error: $_"' }
        @{ File = 'WingetAppSetup/Public/Install.ps1'; Text = 'Write-Success "Retry succeeded: $appName"' }
        @{ File = 'WingetAppSetup/Private/InstallVerification.ps1'; Text = 'Write-ErrorMessage "winget cannot be launched on this machine (' }
        @{ File = 'WingetAppSetup/Public/Install.ps1'; Text = "Write-Info 'Summary:'" }
        @{ File = 'WingetAppSetup/Public/Install.ps1'; Text = "`$headers = @('Status', 'Apps')" }
        @{ File = 'WingetAppSetup/Public/Install.ps1'; Text = "`$rows += , @('Installed', `$appList)" }
        @{ File = 'WingetAppSetup/Public/Install.ps1'; Text = "`$rows += , @('Skipped', `$appList)" }
        @{ File = 'WingetAppSetup/Public/Install.ps1'; Text = "`$rows += , @('Deferred', `$appList)" }
        @{ File = 'WingetAppSetup/Public/Install.ps1'; Text = "`$rows += , @('Failed', `$appList)" }
        # The framework comes from Install-WingetAutoUpdate (work-order item 32) and is 1.8 unless
        # the latest winget release needs another; Install.Tests.ps1 checks the line it prints.
        @{ File = 'WingetAppSetup/Public/Install.ps1'; Text = "`$wauFrameworkName = 'Microsoft.WindowsAppRuntime.1.8'" }
        @{ File = 'WingetAppSetup/Public/Install.ps1'; Text = 'Write-ErrorMessage "Auto-updates: NOT CONFIGURED - $wauFrameworkName is missing, ' }
        @{ File = 'WingetAppSetup/Public/Install.ps1'; Text = 'Write-ErrorMessage "Auto-updates: UNHEALTHY - ' }
        @{ File = 'WingetAppSetup/Public/Install.ps1'; Text = 'Write-ErrorMessage "winget: NOT USABLE - ' }
        @{ File = 'WingetAppSetup/Private/WindowsAppRuntime.ps1'; Text = 'Write-ErrorMessage "Windows App Runtime: NOT INSTALLED - $reason."' }
        @{ File = 'WingetAppSetup/Private/WindowsAppRuntime.ps1'; Text = "Write-Success ('Windows App Runtime: installed Microsoft.WindowsAppRuntime.1.8 {0} ({1}) for all users{2}.'" }
        @{ File = 'WingetAppSetup/Private/WindowsAppRuntime.ps1'; Text = "Write-Info ('Microsoft.WindowsAppRuntime.1.8 is missing; installing the pinned Windows App Runtime {0} (framework {1}, {2}) for all users first...'" }
        @{ File = 'WingetAppSetup/Private/WindowsAppRuntime.ps1'; Text = "`$reason = ('the latest winget release needs {0}, and the framework this installer installs, {1} {2}, does not meet that; a newer version of this installer is needed'" }
        @{ File = 'build/fragments/tail.ps1'; Text = 'Write-Info "Installer build: $script:InstallerBuildId"' }
        @{ File = 'build/fragments/tail.ps1'; Text = "Write-ErrorMessage 'UNEXPECTED ERROR - the run was aborted before it finished." }
        @{ File = 'build/fragments/tail.ps1'; Text = "`$abortMessage = 'The run was stopped before it finished (exit code 5).'" }
        @{ File = 'WingetAppSetup/Private/FailureReporting.ps1'; Text = "'The installer stopped early with exit code {0}: {1}.'" }
        @{ File = 'WingetAppSetup/Private/PowerShell7Bootstrap.ps1'; Text = "Write-Success 'PowerShell 7 is installed.'" }
        @{ File = 'WingetAppSetup/Private/PowerShell7Bootstrap.ps1'; Text = "Write-Info ('Relaunching the installer under PowerShell 7: {0}' -f `$pwshPath)" }
        @{ File = 'WingetAppSetup/Private/PowerShell7Bootstrap.ps1'; Text = "Write-Info ('The PowerShell 7 run ended with exit code {0}.' -f `$relaunchProcess.ExitCode)" }
        @{ File = 'WingetAppSetup/Private/LoggingInternal.ps1'; Text = "`$phaseSuffix = '-bootstrap'" }
        @{ File = 'WingetAppSetup/Private/LoggingInternal.ps1'; Text = "`$whatIfSuffix = '-whatif'" }
        @{ File = 'WingetAppSetup/Private/LoggingInternal.ps1'; Text = "'install-{0:yyyyMMdd-HHmmss}{1}{2}.log'" }
        @{ File = 'WingetAppSetup/Public/Install.ps1'; Text = "Write-Info 'Running as SYSTEM (for example from an RMM agent): " }
        @{ File = 'rmm/Invoke-WingetAppSetup.ps1'; Text = "'install-{0:yyyyMMdd-HHmmss}-rmm.log'" }
        # wgt-gq8.42: the Microsoft.WinGet.Client engine.
        @{ File = 'WingetAppSetup/Private/WingetClientEngine.ps1'; Text = "Write-Info ('Install engine: Microsoft.WinGet.Client {0} (WinGet engine {1}, PowerShell {2} {3}; engine log folder {4}).'" }
        @{ File = 'WingetAppSetup/Private/WingetClientEngine.ps1'; Text = "Write-Info ('Install engine: winget.exe ({0}), not the requested Microsoft.WinGet.Client: {1}.'" }
        @{ File = 'WingetAppSetup/Private/WingetClientEngine.ps1'; Text = "Write-Info ('Install engine: winget.exe ({0}).'" }
        @{ File = 'WingetAppSetup/Private/WingetClientModule.ps1'; Text = "Write-Success ('WinGet client module: ready - Microsoft.WinGet.Client {0}, SHA256 {1}, {2}.'" }
        @{ File = 'WingetAppSetup/Private/WingetClientModule.ps1'; Text = "`$from = 'from the cache'" }
        @{ File = 'WingetAppSetup/Private/WingetClientModule.ps1'; Text = 'Write-WarningMessage "WinGet client module: NOT READY - $reason."' }
        @{ File = 'WingetAppSetup/Private/WingetClientEngine.ps1'; Text = 'Write-WarningMessage "WinGet client module: NOT READY - $reason."' }
        @{ File = 'WingetAppSetup/Private/WingetClientEngine.ps1'; Text = "`$call = '  > Install-WinGetPackage -Id {0} -Source winget -MatchOption Equals -Scope System -Mode {1}'" }
        @{ File = 'WingetAppSetup/Private/InstallVerification.ps1'; Text = 'Write-ErrorMessage "The WinGet client engine cannot be started on this machine (' }
        @{ File = 'WingetAppSetup/Private/ProcessInvocation.ps1'; Text = "Write-Host ('  > {0} {1}' -f `$displayName, `$arguments)" }
        @{ File = 'WingetAppSetup/Public/Install.ps1'; Text = "Write-WarningMessage ('Install engine: Microsoft.WinGet.Client was requested but not used ({0}); this run installed with winget.exe.'" }
    ) {
        $source = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot $File)
        $source.Contains($Text) | Should -BeTrue -Because "e2e/TranscriptAssertions.ps1 matches this line; update both together"
    }
}

Describe 'e2e/Assert-Install.ps1 wiring' {
    BeforeAll {
        $tokens = $null
        $parseErrors = $null
        $script:AssertInstallAst = [System.Management.Automation.Language.Parser]::ParseFile($script:AssertInstallPath, [ref]$tokens, [ref]$parseErrors)
        $script:AssertInstallParseErrors = $parseErrors
    }

    It 'Parses' {
        $script:AssertInstallParseErrors | Should -BeNullOrEmpty
    }

    It 'Calls only commands that the module, e2e/TranscriptAssertions.ps1, the script itself or PowerShell define' {
        # Assert-Install.ps1 only runs on a real install; a renamed helper would otherwise surface
        # there first (P3-39: the rewritten script had never completed a CI run).
        $definedHere = @($script:AssertInstallAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object Name)
        $called = @($script:AssertInstallAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) |
                ForEach-Object { $_.GetCommandName() } | Where-Object { $_ } | Sort-Object -Unique)

        $unresolved = @($called | Where-Object { $definedHere -notcontains $_ -and -not (Get-Command -Name $_ -ErrorAction SilentlyContinue) })

        $called | Should -Contain 'Get-TranscriptAssertionResult'
        $unresolved | Should -BeNullOrEmpty
    }

    It 'Decides applicability with the module''s rule, not a copy that reads only the condition' {
        $definedHere = @($script:AssertInstallAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object Name)
        $called = @($script:AssertInstallAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) |
                ForEach-Object { $_.GetCommandName() } | Where-Object { $_ } | Sort-Object -Unique)
        $conditionCalls = @($script:AssertInstallAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.MemberExpressionAst] -and $node.Member.Extent.Text -eq 'condition' }, $true))

        $called | Should -Contain 'Get-CatalogAppApplicability'
        $definedHere | Should -Not -Contain 'Test-AppApplicable'
        $conditionCalls | Should -BeNullOrEmpty
    }

    It 'Fails an assertion when the module finds an app with no arch list or condition not applicable' {
        # The ungated check is only worth something if the script reports it.
        $ungatedReads = @($script:AssertInstallAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.MemberExpressionAst] -and $node.Member.Extent.Text -eq 'UngatedNotApplicable' }, $true))
        $ungatedRows = @($script:AssertInstallAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Add-AssertionResult' -and $node.Extent.Text -match 'no arch list or condition' }, $true))

        $ungatedReads | Should -Not -BeNullOrEmpty
        @($ungatedRows | Where-Object { $_.Extent.Text -match '-Passed \$false' }) | Should -Not -BeNullOrEmpty
    }

    It 'Passes Get-TranscriptAssertionResult only parameters it declares' {
        $keys = @()
        $assignments = $script:AssertInstallAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)
        foreach ($assignment in $assignments) {
            $left = $assignment.Left
            if ($left -is [System.Management.Automation.Language.VariableExpressionAst] -and $left.VariablePath.UserPath -eq 'transcriptAssertionArgs') {
                $hashtable = $assignment.Right.Find({ param($node) $node -is [System.Management.Automation.Language.HashtableAst] }, $true)
                $keys += @($hashtable.KeyValuePairs | ForEach-Object { $_.Item1.Value })
            }
            elseif ($left -is [System.Management.Automation.Language.MemberExpressionAst] -and $left.Expression.Extent.Text -eq '$transcriptAssertionArgs') {
                $keys += $left.Member.Value
            }
        }
        $declared = @((Get-Command -Name Get-TranscriptAssertionResult).Parameters.Keys)

        $keys | Should -Contain 'ExpectPowerShell7Bootstrap'
        $keys | Should -Contain 'ExpectPowerShell7Installed'
        $keys | Should -Contain 'ExpectedAutoUpdatesStatus'
        @($keys | Where-Object { $declared -notcontains $_ }) | Should -BeNullOrEmpty
    }

    It 'Declares the switches the workflow passes' {
        $parameters = @($script:AssertInstallAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        $parameters | Should -Contain 'ExpectPowerShell7Bootstrap'
        $parameters | Should -Contain 'ExpectPowerShell7Installed'
        $parameters | Should -Contain 'ExpectAllSkippedOnSecondRun'
        $parameters | Should -Contain 'InstallerPath'
        $parameters | Should -Contain 'SkipApps'
    }

    It 'Stays ASCII, like the other e2e scripts: <Name>' -ForEach @(
        @{ Name = 'e2e/Assert-Install.ps1' }
        @{ Name = 'e2e/TranscriptAssertions.ps1' }
    ) {
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $script:RepoRoot $Name))
        @($bytes | Where-Object { $_ -gt 0x7F }).Count | Should -Be 0
    }
}
