<#PSScriptInfo

.VERSION 1.0.0

.GUID b5b5f614-90c3-42a9-94e3-b7dd6e6de262

.AUTHOR Joey Maffiola

.EXTERNALMODULEDEPENDENCIES winget, Microsoft.WinGet.Client

.TAGS winget, installation, automation

.PROJECTURI https://github.com/J-MaFf/winget-app-setup

.RELEASENOTES Initial version

.Changelog
    1.0.0 - This is the initial version of the script. It installs a list of programs using winget.
#>


<#
.SYNOPSIS
 Installs a list of programs using winget.

.DESCRIPTION
 This script installs a curated list of programs from winget. The authoritative
 list is returned by Get-DefaultAppCatalog (WingetAppSetup/Public/AppCatalog.ps1,
 inlined below in this generated file) and shared with winget-app-uninstall.ps1.
 Run the script with -WhatIf to preview the exact set of planned installs without
 making any system changes.

.PARAMETER WhatIf
 When specified, performs all pre-flight checks and displays planned actions without making any system changes.

.PARAMETER SkipSystemCheck
 Bypasses the pre-flight system checks (OS version, disk space, network) for headless or automated use.

.PARAMETER NonInteractive
 Suppresses the interactive extras for unattended runs (RMM, CI, scheduled tasks): the summary
 grid-view window and the "press any key to exit" that holds the window at the end of a run or
 after an early failure. Also turned on by the environment variable
 WINGET_APP_SETUP_NONINTERACTIVE=1 (or true, or yes), for the irm | iex one-liner, which cannot pass
 a switch, and auto-detected when the session is non-interactive or stdin is redirected; under CI
 the early-failure key press is skipped too. The installer asks no yes/no
 questions on any path (issue #230). It asks one question: TightVNC's server password, at the
 start of an interactive run when WINGET_APP_SETUP_TIGHTVNC_PASSWORD is not set and TightVNC Server
 has no password yet (skipped when nobody starts typing within 5 minutes). This switch suppresses
 that question too: TightVNC is then reported as installed but not configured.
#>

param (
    [Parameter(Mandatory = $false)]
    [switch]$WhatIf,
    [Parameter(Mandatory = $false)]
    [switch]$SkipSystemCheck,
    [Parameter(Mandatory = $false)]
    [switch]$NonInteractive
)
