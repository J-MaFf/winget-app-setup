# TestHelpers.ps1
# Shared bootstrap for the per-area Pester files in this directory (issue #192).
#
# Dot-source this from each test file's top-level BeforeAll:
#
#     BeforeAll {
#         . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
#     }
#
# It resolves the repo paths and dot-sources the WingetAppSetup module's function files
# (WingetAppSetup/Private + WingetAppSetup/Public — the single source of truth; the
# distributable winget-app-install.ps1 is generated from it by
# build/Build-WingetInstallScript.ps1). Each Pester test file is its own session scope,
# so loading here preserves the old suite's load-once semantics per file: every Describe
# in a file shares one set of definitions, with no bleed between files.
#
# This file deliberately has no .Tests.ps1 suffix so `Invoke-Pester ./tests` never
# discovers it as a test container.

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:WingetAppSetupRoot = Join-Path $script:RepoRoot 'WingetAppSetup'
$script:ModuleManifestPath = Join-Path $script:WingetAppSetupRoot 'WingetAppSetup.psd1'
$script:InstallerScriptPath = Join-Path $script:RepoRoot 'winget-app-install.ps1'
$script:UninstallerScriptPath = Join-Path $script:RepoRoot 'winget-app-uninstall.ps1'

Get-ChildItem -Path (Join-Path $script:WingetAppSetupRoot 'Private'), (Join-Path $script:WingetAppSetupRoot 'Public') -Filter '*.ps1' |
    ForEach-Object { . $_.FullName }

# Force PowerShellGet/PackageManagement autoload while the real Get-Command is still in
# effect. Pester resolves every Mock target through command discovery, and a test that
# mocks Get-Command first (e.g. the grid-view tests) breaks autoload for later mock
# targets like Install-Module. The old single-file suite got this resolution for free
# from Describe ordering; the split files must not depend on run order.
$null = Get-Command Install-Module, Install-PackageProvider, Get-PackageProvider -ErrorAction SilentlyContinue
