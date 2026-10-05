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
 Suppresses the interactive extra for unattended runs (RMM, CI, scheduled tasks): the "press any
 key to exit" that holds the window at the end of a run or after an early failure. Also turned on
 by the environment variable WINGET_APP_SETUP_NONINTERACTIVE=1 (or true, or yes), for the
 irm | iex one-liner, which cannot pass a switch, and auto-detected when the session is
 non-interactive or stdin is redirected; under CI the early-failure key press is skipped too. The
 installer asks no yes/no questions on any path (issue #230). It asks one question: TightVNC's
 server password, at the start of an interactive run when WINGET_APP_SETUP_TIGHTVNC_PASSWORD is not
 set and TightVNC Server has no password yet (skipped when nobody starts typing within 5 minutes).
 This switch suppresses that question too: TightVNC is then reported as installed but not
 configured.

.PARAMETER CollectDiagnostics
 Installs nothing: makes a diagnostics bundle to attach to a GitHub issue after a failed run, and
 prints where it saved it. The .zip holds the latest run's transcripts (the RMM wrapper's log
 too), installer logs and last-run.json, this account's user-phase state and logs when the user
 phase ran in it, the end of Winget-AutoUpdate's updates.log, the App Installer and Windows App
 Runtime packages for every account and provisioned for new ones (and the framework this build
 pins), the execution policy, the App Installer and Store Group Policy, the pending-restart state,
 the Winget-AutoUpdate task, winget --version and --info, and the Windows build and architecture. Account and computer names, user
 profile folders, the SIDs of real accounts and email addresses are replaced with placeholders,
 because the repository's issues are public. It changes nothing on the PC (no log, no run lock, no
 PowerShell 7 install, no elevation) and works without winget; run it from PowerShell started as
 administrator to include everything. The irm | iex one-liner cannot pass a switch, so a failed run
 prints this command instead:
     & ([scriptblock]::Create((irm "https://raw.githubusercontent.com/J-MaFf/winget-app-setup/refs/heads/main/winget-app-install.ps1"))) -CollectDiagnostics
 Exit code 0 when the bundle was saved, 5 when it could not be.

.PARAMETER MaxRuntimeMinutes
 A time budget for the whole run, in minutes (1 to 1440), for an RMM job that is stopped after a
 fixed time: once it is used up, the run starts no further app install, retry or Winget-AutoUpdate
 setup, reports what it did not reach as not attempted (in the summary, the RESULT line and
 last-run.json), and exits 9 so that the next run finishes the job. An install already running is
 not stopped: it ends within its own time limit, so set the budget well below the RMM's limit. The
 clock starts when this script starts, before the PowerShell 7 relaunch. Not given (or 0), the
 environment variable WINGET_APP_SETUP_MAX_RUNTIME_MINUTES decides, for the irm | iex one-liner,
 which cannot pass a parameter: unset, empty or 0 means no budget, and a value that is not a whole
 number from 0 to 1440 is ignored with a warning. A value given here wins over the variable. A dry
 run (-WhatIf) shows the budget but is not cut short.

.PARAMETER RunDeadlineUtc
 Internal: the deadline of the time budget (yyyy-MM-ddTHH:mm:ssZ), passed on by the installer's own
 relaunches (to PowerShell 7, and elevated) and by rmm/Invoke-WingetAppSetup.ps1, so the budget
 counts from the first start of the run. It never extends the budget -MaxRuntimeMinutes sets.
#>

param (
    [Parameter(Mandatory = $false)]
    [switch]$WhatIf,
    [Parameter(Mandatory = $false)]
    [switch]$SkipSystemCheck,
    [Parameter(Mandatory = $false)]
    [switch]$NonInteractive,
    [Parameter(Mandatory = $false)]
    [switch]$CollectDiagnostics,
    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 1440)]
    [int]$MaxRuntimeMinutes = 0,
    [Parameter(Mandatory = $false)]
    [string]$RunDeadlineUtc
)
