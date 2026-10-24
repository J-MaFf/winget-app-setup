# E2EReleaseInstaller.Tests.ps1
# Tests for e2e/Save-ReleaseInstaller.ps1, which saves the installer of the release a dispatched
# e2e run tests (#289), and for the release helpers it shares with e2e/Invoke-InstallPass.ps1 in
# e2e/TranscriptAssertions.ps1. Invoke-WebRequest is always mocked: nothing is downloaded.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:SaveReleaseScript = Join-Path $script:RepoRoot 'e2e/Save-ReleaseInstaller.ps1'
    . $script:SaveReleaseScript

    # A function, not a $script: variable: a mock that runs inside the script started with &
    # reads $script: in that script's scope.
    function Get-TestInstallerText {
        "<#PSScriptInfo #>`n`$script:InstallerBuildId = '2.0.0+1a2b3c4d'`nfunction Invoke-WingetInstall { }`n"
    }
    $script:InstallerText = Get-TestInstallerText
}

Describe 'Test-ReleaseTag' {
    It 'Accepts <Tag>, a tag the release workflow publishes' -ForEach @(
        @{ Tag = 'v2.0.0' }
        @{ Tag = 'v10.20.30' }
    ) {
        Test-ReleaseTag -Tag $Tag | Should -BeTrue
    }

    It 'Refuses ''<Tag>''' -ForEach @(
        @{ Tag = '' }
        # A prerelease: the 5.1 bootstrap looks for the release of the build's version, v2.1.0.
        @{ Tag = 'v2.1.0-rc.1' }
        @{ Tag = 'latest' }
        @{ Tag = '2.0.0' }
        @{ Tag = 'v2.0' }
        @{ Tag = 'v02.0.0' }
        @{ Tag = "v2.0.0`n" }
        @{ Tag = 'v2.0.0/../main' }
    ) {
        Test-ReleaseTag -Tag $Tag | Should -BeFalse
    }

    It 'Accepts only tags the release workflow publishes, and no prerelease: ''<Tag>''' -ForEach @(
        @{ Tag = 'v2.0.0' }
        @{ Tag = 'v2.1.0-rc.1' }
        @{ Tag = 'v0.0.0' }
        @{ Tag = 'latest' }
        @{ Tag = 'v2.0' }
        @{ Tag = 'v02.0.0' }
        @{ Tag = 'v2.0.0-' }
        @{ Tag = "v2.0.0`n" }
    ) {
        $release = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot '.github/workflows/release.yml')
        $workflowRule = [regex]::Match($release, "-notmatch '(?<rule>[^']+)'").Groups['rule'].Value

        $workflowRule | Should -Not -BeNullOrEmpty
        Test-ReleaseTag -Tag $Tag | Should -Be (($Tag -match $workflowRule) -and $Tag -notmatch '-')
    }
}

Describe 'Get-ReleaseInstallerUrl' {
    It 'Names the latest release''s installer without a tag' {
        Get-ReleaseInstallerUrl -Tag '' | Should -Be 'https://github.com/J-MaFf/winget-app-setup/releases/latest/download/winget-app-install.ps1'
    }

    It 'Names the tag''s installer with one' {
        Get-ReleaseInstallerUrl -Tag 'v2.0.0' | Should -Be 'https://github.com/J-MaFf/winget-app-setup/releases/download/v2.0.0/winget-app-install.ps1'
    }

    It 'Names the release the bootstrap''s relaunch downloads for the same version' {
        # A release run's 5.1 bootstrap must find the release the one-liner came from.
        (Get-InstallerDownloadUrl -BuildId '2.0.0+1a2b3c4d')[0] | Should -Be (Get-ReleaseInstallerUrl -Tag 'v2.0.0')
    }
}

Describe 'Get-ReleaseInstallerDownload' {
    It 'Takes the bytes GitHub serves for an application/octet-stream asset' {
        Mock Invoke-WebRequest { [pscustomobject]@{ Content = [System.Text.Encoding]::UTF8.GetBytes((Get-TestInstallerText)) } }

        $download = Get-ReleaseInstallerDownload -Url 'https://example.test/winget-app-install.ps1'

        $download.Error | Should -BeNullOrEmpty
        $download.BuildId | Should -Be '2.0.0+1a2b3c4d'
        [System.Text.Encoding]::UTF8.GetString($download.Bytes) | Should -BeExactly $script:InstallerText
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Uri -eq 'https://example.test/winget-app-install.ps1' -and $UseBasicParsing -and $TimeoutSec -gt 0 }
    }

    It 'Takes text too, as a text content type returns it' {
        Mock Invoke-WebRequest { [pscustomobject]@{ Content = (Get-TestInstallerText) } }

        $download = Get-ReleaseInstallerDownload -Url 'https://example.test/winget-app-install.ps1'

        $download.BuildId | Should -Be '2.0.0+1a2b3c4d'
        [System.Text.Encoding]::UTF8.GetString($download.Bytes) | Should -BeExactly $script:InstallerText
    }

    It 'Says why when the download fails' {
        Mock Invoke-WebRequest { throw 'Response status code does not indicate success: 404 (Not Found).' }

        $download = Get-ReleaseInstallerDownload -Url 'https://example.test/winget-app-install.ps1'

        $download.Bytes | Should -BeNullOrEmpty
        $download.Error | Should -Match '^the download failed: .*404'
    }

    It 'Refuses a download that is not the installer' {
        Mock Invoke-WebRequest { [pscustomobject]@{ Content = [System.Text.Encoding]::UTF8.GetBytes('<html>Not Found</html>') } }

        $download = Get-ReleaseInstallerDownload -Url 'https://example.test/winget-app-install.ps1'

        $download.Bytes | Should -BeNullOrEmpty
        $download.Error | Should -Be 'it is not the installer: it carries no installer build id'
    }
}

Describe 'e2e/Save-ReleaseInstaller.ps1 run as a step' {
    BeforeEach {
        $script:OutputPath = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '/winget-app-install.ps1')
    }

    It 'Saves the latest release''s installer, byte for byte, and exits 0' {
        Mock Invoke-WebRequest { [pscustomobject]@{ Content = [System.Text.Encoding]::UTF8.GetBytes((Get-TestInstallerText)) } }

        & $script:SaveReleaseScript -Tag '' -OutputPath $script:OutputPath *> $null

        $LASTEXITCODE | Should -Be 0
        [System.IO.File]::ReadAllText($script:OutputPath) | Should -BeExactly $script:InstallerText
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Uri -eq 'https://github.com/J-MaFf/winget-app-setup/releases/latest/download/winget-app-install.ps1' }
    }

    It 'Downloads the tag''s installer with -Tag' {
        Mock Invoke-WebRequest { [pscustomobject]@{ Content = [System.Text.Encoding]::UTF8.GetBytes((Get-TestInstallerText)) } }

        & $script:SaveReleaseScript -Tag 'v2.0.0' -OutputPath $script:OutputPath *> $null

        $LASTEXITCODE | Should -Be 0
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Uri -eq 'https://github.com/J-MaFf/winget-app-setup/releases/download/v2.0.0/winget-app-install.ps1' }
    }

    It 'Exits 1 and saves nothing for a release without the installer' {
        Mock Invoke-WebRequest { throw 'Response status code does not indicate success: 404 (Not Found).' }

        $output = & $script:SaveReleaseScript -Tag 'v1.0.0' -OutputPath $script:OutputPath 6>&1

        $LASTEXITCODE | Should -Be 1
        Test-Path -LiteralPath $script:OutputPath | Should -BeFalse
        ($output -join "`n") | Should -Match 'Could not take winget-app-install\.ps1 of release v1\.0\.0 from https://github\.com/.*/releases/download/v1\.0\.0/winget-app-install\.ps1: the download failed'
    }

    It 'Exits 64 for <Case>, before any download' -ForEach @(
        @{ Case = 'no -OutputPath'; Tag = 'v2.0.0'; NoOutput = $true }
        @{ Case = 'a tag the release workflow does not publish'; Tag = 'latest'; NoOutput = $false }
    ) {
        Mock Invoke-WebRequest { throw 'not expected' }
        $arguments = @{ Tag = $Tag }
        if (-not $NoOutput) {
            $arguments.OutputPath = $script:OutputPath
        }

        & $script:SaveReleaseScript @arguments *> $null

        $LASTEXITCODE | Should -Be 64
        Should -Invoke Invoke-WebRequest -Times 0
    }
}
