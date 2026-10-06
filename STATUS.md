# STATUS

## What This Is

`winget-app-setup` is a Windows-only PowerShell toolkit that installs a curated list of
applications via winget, configures Windows Terminal, and bootstraps
[Winget-AutoUpdate (WAU)](https://github.com/Romanitho/Winget-AutoUpdate), which owns all ongoing
app updates. End users run a single self-contained `winget-app-install.ps1`, either locally or via a
remote `irm | iex` one-liner. Internally, the installer's logic now lives in the reusable
`WingetAppSetup` module, and the single-file installer and uninstaller are generated from it by a
build step. For
ManageEngine Endpoint Central, `rmm/` holds a machine phase that runs the installer as SYSTEM, a
user phase that finishes the per-user work at each sign-in, a fleet health probe and a one-off
Winget-AutoUpdate fix. The scripts target **Windows PowerShell / PowerShell 7 on Windows**; they
cannot run end-to-end on Linux or macOS because they depend on `winget`, the
`Microsoft.WinGet.Client` module, and Windows-only cmdlets.

## Current State — 2026-10-06

In review: PR [#285](https://github.com/J-MaFf/winget-app-setup/pull/285) (branch
`claude/trusting-dirac-foyiaa`) carries the work order from the 2026-10-04 whole-repo review. It is
not merged, so `main`, which the one-liner downloads, has none of what follows.

**The red E2E was the installer's own doing (#279, #283, #284).** The installer set up
Winget-AutoUpdate (WAU) with `RUN_WAU=YES`, which started WAU's first run in the middle of the
installer's own run. Every WAU 2.12.0 run calls `Install-Prerequisites`. That provisions the newest
winget from GitHub with `-SkipLicense` but without the `Microsoft.WindowsAppRuntime.1.8` framework
that winget 1.12 and later need, then runs `winget source reset --force` and upgrades apps,
PowerShell included. The Server 2025 runner has neither the Microsoft Store nor that framework, so
the WAU run left winget unable to start: the #279 and #284 wedge. A PowerShell upgrade under the
running installer is the most likely cause of #283's console stop. The earlier explanations (a
runner-image defect, Store servicing) were wrong. Work-order items 1 to 3 fix it: no `RUN_WAU=YES`,
so WAU never runs during an install; WAU is set up last, only when the framework the newest winget
needs is present, and without its at-logon run; the installer waits for a WAU run that is already
in progress; and a run that leaves winget unusable exits 2 instead of 0. Item 31 then installs a
pinned, verified copy of the framework for every user when it is missing, so the runner gets WAU
too. Every E2E run of the branch that ran to the end has passed, the first on 2026-10-04. Run
[37268347522](https://github.com/J-MaFf/winget-app-setup/actions/runs/37268347522) on 2026-10-05
passed all three legs (PowerShell 7, Windows PowerShell 5.1, and SYSTEM through the Endpoint
Central machine phase): the framework was installed, WAU was set up, and the installer exited 0.
#283 has not come back since `RUN_WAU=YES` went. Close #279, #283 and #284 when #285 merges.

The rest of the branch, in short. An aborted run exits 5 instead of 0. `Invoke-WingetInstall` now
returns its exit code instead of calling `exit`, so the tests run every exit path and assert the
code instead of matching regexes over the source, and no test depends on whether the runner is
elevated (they mock `Test-IsAdmin`;
the #232 regression tests had never run on the elevated CI runner). The Pester suite now also runs
on Linux with no known failures (there were 113; the last one, the `Write-Table` console test, went
with the full-width table fix), and no test dot-sources a generated script any more, so the unit
tests exercise the module source being edited (the EntryPoint, AppCatalog, Interactivity,
Uninstall, PowerShell7Bootstrap, RmmWrapper and BuildGuards tests still read, run or build the
generated files themselves, on purpose). The build's `-Check` now also rejects syntax that only
PowerShell 7 parses and runs the undefined-reference guards on Linux and macOS, the pre-commit hook checks the staged files instead of the working tree, and a catalog name
must match the whole package-id pattern, so trailing text such as `--override` can no longer reach
winget. A `-WhatIf` dry run no longer changes the machine: its module, winget
and source setup steps only check and print what a real run would fix, where they used
to install modules for all users, set up App Installer and reset winget's sources. A failed run is
now debuggable from what the teammate attaches: an early exit prints the exit code and why, the log
path and the build id, and waits for a key press when someone is at the console instead of closing
the `irm | iex` window at once; the Windows PowerShell 5.1 bootstrap writes its own
`-bootstrap.log` (plus an `msiexec` log, with a retry when another installation holds Windows
Installer); the `logs` folder stays readable for standard users after the WAU install; tables are
no longer cut off at 120 columns; the build id covers the whole script; and an issue form asks for
the exit code, the build and a diagnostics bundle or the log, with a privacy note because the
repository is public. Every winget call, and the Winget-AutoUpdate `msiexec`, now goes through one
helper (`Invoke-ExternalProcess` / `Invoke-WingetProcess`; the PowerShell 7 bootstrap's `msiexec`
keeps `Start-Process` with its own time limit): each has a time limit (30 minutes per install),
after which the process and everything it started are stopped, so a stuck installer can no longer
hang an unattended run (the cmdlets that set up winget itself, such as `Install-Module` and
`Repair-WinGetPackageManager`, still have no limit of their own); winget's own output goes into
the transcript and the installer's log into the logs folder; a failed launch is classified by its
Win32 error code, so the launch retries also work on a
non-English Windows; unattended runs pass `--silent`; and `winget source list` and
`winget source reset` no longer pass `--accept-source-agreements`, which winget rejects and which
had kept the source reset from ever running. A winget that cannot be started now fails the run
fast: winget counts as usable only when `winget --version` runs and prints a version (being on PATH
is not enough, so a failed repair no longer reports success), a `winget list` that could not start
winget, or that ran and failed, is no longer read as "not installed" (which had every installed app
reported as `package not found after install`), and after the first app that could not launch
winget, one check (up to 75 seconds, for an App Installer update in progress) decides whether to
carry on or to fail the remaining apps at once and skip the retry pass. A wedged winget used to cost
about 24 minutes; it now costs about 2.5 minutes. The `winget: NOT USABLE` line at the end of a run
says why. PowerShell's failure reason names its exit code and launch errors like every other app's.
The deadlock detector (`Get-ConflictingDesktopAppInstallerVersions`, which never fired on the real
wedge), the `-BypassAlias` launch path and `Wait-WingetLaunchable` are gone. An install that finds
Windows Installer busy with another installation (`0x8A150102`, common on a freshly enrolled PC)
now waits until no installation owns the Windows Installer mutex and retries, within one 10-minute
budget per run, and an app that is in use gets one delayed retry; `0x8A15010A` (restart first) is
no longer retried. A run that needs a restart to finish (winget's restart warning, the WAU MSI's
3010, a pending restart that appeared during the run, or the PowerShell 7 install of a run started
from Windows PowerShell) says `Restart: REQUIRED` and exits 3010; a restart already pending before
the run is only reported. Every printed winget exit code carries its name (`0x8A150102
INSTALL_INSTALL_IN_PROGRESS`), and a failure reason says what the code means instead of `package
not found after install`. A run that is not elevated now relaunches itself in System32's Windows
PowerShell (which every account has, unlike the signed-in user's per-user `pwsh.exe` and `wt.exe`
aliases), waits for the elevated run and exits with its code, where it used to exit 0 as soon as it
had asked; the elevated window runs a copy of the installer that it checks against the SHA256 taken
at startup and keeps in a folder only administrators can change; a declined UAC prompt exits 4 after
one prompt, and a non-interactive run that is not elevated exits 4 without showing one. The
uninstaller relaunches the same way, checked copy included: it is generated as one file too
(wgt-gq8.43). The Winget-AutoUpdate download folder under
`%ProgramData%\winget-app-setup`, which the installer's first, non-elevated launch creates and the
signed-in user therefore owned, is now taken over by Administrators before it is locked to SYSTEM
and Administrators, and the result is read back with `Get-Acl`; when it is not as expected, WAU is
not downloaded. The MSI is hashed from a handle that stays open, with read-only sharing, until
`msiexec` has finished, so it cannot be swapped in between. `Install-Module` now passes
`-Repository PSGallery`, so another repository registered on the machine cannot serve the
`Microsoft.WinGet.Client` module the installer adds for all users. The Windows PowerShell 5.1
bootstrap now checks what it downloads: its MSI fallback installs the newest release that still
ships an MSI (7.6 LTS once 7.7,
which ships none, is current) and refuses an MSI without a valid Microsoft Authenticode signature,
the unchecked `aka.ms/install-powershell.ps1` fallback behind it is gone, an `irm | iex` relaunch
downloads the installer from raw or jsDelivr and runs only a copy of the same build, and a failed
bootstrap exits 7 instead of 1. The Windows Terminal step now changes only `defaultProfile` in
`settings.json` (comments and formatting are kept, and a `.bak` copy is saved first), and it is
skipped for SYSTEM and under cross-user elevation, where it used to configure the admin account
instead of the user. A run as SYSTEM, as an RMM agent such as Endpoint Central runs it, now installs
the apps that install for the whole PC instead of stopping with exit code 2 after minutes of
per-account downloads: it runs the `winget.exe` that App Installer installed for the PC, by its full path
(found with `Get-AppxPackage -AllUsers`, or under `WindowsApps`, and checked with `winget --version`),
skips every step that sets winget up for one account, is always non-interactive, and its messages no
longer call it a cross-user elevation or advise signing in as SYSTEM. It exits 2, saying why, when
no machine-wide `winget.exe` starts. As SYSTEM and under cross-user elevation, every install is
`--scope machine` only: an app with no machine-wide installer is reported as `Deferred` (its own
summary row, neither installed nor failed, exit code unchanged) instead of being installed into
SYSTEM's or the admin's profile and reported as installed, and Windows Terminal is decided from
whether it is provisioned for every user, which Windows 11 does. Microsoft does not support the
winget command line as SYSTEM; its `Microsoft.WinGet.Client` module on PowerShell 7 is the supported
route, which a run as SYSTEM can now opt in to (wgt-gq8.42, below).

Setting winget up is now one step, `Initialize-Winget`, in place of three ladders that ran back to
back and gave one cause three diagnoses. It stops with exit code 2 and names the policy when App
Installer's Group Policy turns winget or its source off (or winget answers `0x8A15003A`); reads the
`0x80073CF3`/`0x80073D06` failures of the App Installer registration and repair from their HRESULT,
not from text, and forces no repair those codes say cannot help; repairs for all users
(`Repair-WinGetPackageManager -AllUsers`) only when the all-users check finds
`Microsoft.WindowsAppRuntime.1.8` missing; registers App Installer in Windows PowerShell under
PowerShell 7, where the Appx module cannot load on Windows 10 and Server 2022; resets the source
only when it is missing or corrupted, and repairs nothing for a timeout or a network error; runs
each fix once a run; installs `Microsoft.WinGet.Client` only when it has to repair; and prints one
line with the cause and the fix. The aka.ms/getwinget download, the source.msix registration and
the source update before elevation are gone. The policy detection, the `-AllUsers` repair and the
registration through Windows PowerShell are not yet checked on a real Windows PC.

Catalog conditions are now decided once per run, before anything is installed, and both passes use
that answer, so the retry pass can no longer count an app it found not applicable as installed. A
condition that cannot answer (a failed CIM query, for example) fails open and the install is
attempted. x64 PCs get the 64-bit Adobe Reader, and ARM64 and 32-bit PCs the 32-bit one (`arch`
lists read through `Get-OSArchitecture`). Dell Command Update is limited to x64 Windows. Google
Drive stays on ARM64, where Google serves the same installer and it runs natively on Windows 11; on
Windows 10 ARM64 (x86 emulation only) it still fails with `0x8A150010`. Stale default-terminal
values no longer make the installer skip a removed Windows Terminal. Winget-AutoUpdate counts as
set up only when its `\WAU\Winget-AutoUpdate` task exists, is enabled and has an enabled trigger;
otherwise the summary says `Auto-updates: UNHEALTHY`, and the transcript shows the task's state and
the end of WAU's `updates.log`. New exit code 8: the apps are fine, but auto-updates are `FAILED`,
`NOT CONFIGURED`, `AT RISK` or `UNHEALTHY` (precedence 1 > 2 > 9 > 8 > 3010 > 0; 9 is the
whole-run time budget's, `-MaxRuntimeMinutes`). When `Microsoft.WindowsAppRuntime.1.8` is
missing, the WAU step now first installs a pinned copy for every user (Windows App Runtime 1.8.12,
framework 8000.994.2142.0, the framework `.msix` from Microsoft's `Microsoft.WindowsAppSDK.Runtime`
package on NuGet.org, size, SHA256 and Microsoft signature checked, provisioned with
`Add-AppxProvisionedPackage -SkipLicense`, then checked again), so a freshly imaged PC, a
Store-blocked PC or Windows Server gets WAU on the first run instead of `NOT CONFIGURED` and exit 8;
it never replaces a newer framework and never uses `Repair-WinGetPackageManager -AllUsers`. Which
framework the gate checks for is read from the latest winget release's
`DesktopAppInstaller_Dependencies.json` (the release WAU installs, 30-second limit, falling back to
`Microsoft.WindowsAppRuntime.1.8 >= 8000.616.304.0` with a warning when it cannot be read); when a
future winget needs a newer 1.8 build or another family than the pin, a PC without it gets no
framework install and no WAU, `NOT CONFIGURED` or `AT RISK` with the reason, and exit 8 - the sign
to move the pin; only the frameworks a PC lacks count, and only they are named. The Server 2025
runner, which ships without the framework, gets it and WAU on the first pass and exits 0 (verified
2026-10-05, see above). `e2e/Invoke-InstallPass.ps1` still accepts exit 8 when the pass's transcript
gives the missing framework as the reason and the installer could not try to install it (and quotes
why), but fails a pass whose framework install started and failed, and one whose pinned framework no
longer meets what the latest winget release needs, so the weekly run goes red when the pin has to
move. The package is Microsoft's developer NuGet package (Windows App SDK license terms for
developers), not one of its end-user runtime installers, and a failed install is not remembered, so
a PC where it keeps failing downloads the 150 MB again on every run. For RMM runs:
`WINGET_APP_SETUP_NONINTERACTIVE=1` makes the one-liner non-interactive; one elevated run at a time
holds the `Global\winget-app-setup-run` mutex, and a second one exits 6; every real run prints a
`RESULT:` line, and the run that holds the lock writes `logs\last-run.json` (schema version 1); the
logs folder keeps the newest 30 transcripts, and leftover temporary copies of the installer are
removed after a day. The uninstaller's logic moved into the module (`Invoke-WingetUninstall`): it
sets winget up first and removes nothing (exit 2) when winget cannot be used, fails an app whose
check winget could not answer, honours catalog conditions, keeps the PowerShell 7 and Windows
Terminal it runs in, removes Winget-AutoUpdate last and only when no app failed, and exits 0, 3010,
1, 2, 3, 4 or 5 instead of always 0. None of this is checked on a real Windows PC yet.

Catalog entries can now say declaratively what used to need code (work-order item 38): `scope`
(`machine`, `user` or the default `any`; `machine` never falls back to a per-user install and fails
instead, without a retry, `user` installs with `--scope user`), `arch` (the OS architectures the app
is for, part of the once-per-run applicability decision, fail open), `userPhase` (per-user work),
and `postInstall` (an idempotent hook that configures the app once it is installed, on every run).
As SYSTEM and under cross-user elevation, `scope = 'user'` and `userPhase` apps are `Deferred`
before any winget call, with their own reason in the summary and in `last-run.json`, for a later run
as the user. A hook's result is printed per app and recorded in `last-run.json` (`postInstall`,
`postInstallReason`): a failed hook makes the app failed (exit 1, retried once), `NotConfigured`
gets a `Configuration: NOT DONE` line under the summary and leaves the exit code alone. A wrong
value in any of these fields stops the run with exit 3, and the build guard checks a hook named by a
string like an `install` function. `e2e/Assert-Install.ps1` now decides applicability with the
module's `Test-AppApplicability` (through `Get-CatalogAppApplicability`), and checks independently
that every entry with neither an `arch` list nor a condition applies, so the Reader entries use
`arch` lists, and `Dell.CommandUpdate.Universal` has `arch = 'X64'`.

TightVNC is no longer reported as installed while its server refuses every viewer (review finding
P2-22, work-order item 18). Its catalog entry is the first with a `postInstall` hook,
`Set-TightVncServerPassword` (`WingetAppSetup/Private/TightVnc.ps1`): the server and control
passwords come from `WINGET_APP_SETUP_TIGHTVNC_PASSWORD` and
`WINGET_APP_SETUP_TIGHTVNC_CONTROL_PASSWORD` (taken out of the environment at the start of the run,
before winget starts), or from a prompt at the start of an interactive run when TightVNC Server has
none yet (it waits at most 5 minutes, since the run holds the run lock), never from the repository.
They are written straight to `HKLM\SOFTWARE\TightVNC\Server` through the .NET registry API (not a
cmdlet, which module logging would record) after that key is limited to SYSTEM and Administrators,
read back, and the service is restarted; the same password again changes nothing, and a restart
that failed or never happened is made up by the retry pass or the next run (a
`WingetAppSetupRestartPending` marker in the key). Without one, TightVNC is `Not configured` with a
loud line that says what the server lets through, and the exit code does not change. The encoding
is checked against published TightVNC values; the registry, ACL and service steps are tested at
their seams on Linux, the ACL and value seams also against throwaway HKCU keys on the elevated
Windows CI runners, and the whole hook needs a real Windows check (below).

Endpoint Central gets two phases (work-order item 34). `rmm/Invoke-WingetAppSetup.ps1` is the
machine phase, a Computer Configuration script run as SYSTEM: it relaunches itself in 64-bit Windows
PowerShell when the 32-bit agent starts it, runs `winget-app-install.ps1` from a pinned commit after
a SHA256 check, logs to `install-<time>-rmm.log`, and exits with the installer's code (5 when it
could not run it). `rmm/Invoke-WingetAppSetupUserPhase.ps1` is the user phase, a User Configuration
script run at every sign-in as the user: once per machine run it installs the apps `last-run.json`
lists as `Deferred` with `--scope user` only (`Invoke-WingetUserPhase`), runs their post-install
hooks and sets the Windows Terminal defaults, within a 15-minute budget and up to 3 sign-ins. It
trusts only a `last-run.json` that SYSTEM or Administrators own and nobody else can change. The
pins of both phases ship empty, so both exit 5 until `build/Set-RmmInstallerPin.ps1` sets them
from a commit on `main` after the merge. The E2E run's third leg runs the machine phase as SYSTEM
from a 32-bit `powershell.exe` scheduled task. Two more standalone scripts (item 36):
`rmm/Get-WingetFleetHealth.ps1`, a read-only probe of App Installer, the Windows App Runtime, the
machine-wide `winget.exe` and WAU's task and log that ends with a `HEALTH:` line and exits 1 on an
unhealthy PC, and `rmm/Repair-WauLogonTrigger.ps1`, which removes WAU's at-logon trigger from PCs
set up before the installer stopped adding it. `-CollectDiagnostics` (item 35) makes a redacted
.zip of the latest run's logs and the state of winget, App Installer and WAU for an issue report,
and every failed run prints the command that makes it. Environment checks (item 39) stop a run
legibly before it changes anything: Constrained Language Mode exits 5, a Group Policy execution
policy that would refuse the relaunched installer exits 7 (PowerShell 7) or 4 (the elevated
window), App Installer's Group Policy exits 2 before the WAU wait, and a proxy the run's account
does not have gets a warning. None of this has run on a real PC or from Endpoint Central yet.

Dead and dormant code is gone (work-order item 26, review findings P3-43 to P3-45). The summary is a
text table only: an interactive run no longer opens it in an `Out-GridView` window as well (the
window repeated the table, never reached the log and held the run until it was closed), and no run
installs `Microsoft.PowerShell.GraphicalTools` or the NuGet provider to provide one. The unused
`Get-WindowsTerminalSettingsPath`, `Test-WingetPackageInstalled`'s `[bool]` mode without a time
limit, the uninstall function's `-NonInteractive` (it only gated the grid view; the script keeps
its own) and the tests that only checked that removed functions stayed removed are gone too. The
module manifest exports every function (`FunctionsToExport = '*'`), so the build no longer checks an
export list against `Public/`. `Convert-JsoncToJson` and the MSIX/DISM provisioning path stay. The
grid view was what kept the uninstaller's elevated window open, so the uninstaller now ends with
"press any key to exit" when someone is at the console, as the installer does; without it the
window closed with the summary as soon as the run ended.

The generated installer leaves out the module's comments (work-order item 30, review finding
P3-53), so it is about half the size it was (439 KB instead of 867 KB, which every `irm | iex` run
downloads). The build removes only comments that end their line, from the module and from
`build/fragments/tail.ps1`, keeps `build/fragments/head.ps1` (the script's help) as it is, checks
that the code of each module file and of `tail.ps1` is unchanged token for token, and names the
source file and line behind every line its guards report. Every function in the new installer has
the same syntax tree as before. A change to a comment in the module or `tail.ps1` alone no longer
changes the installer or its build id. The module's own comments are shorter too: incident narratives became a
few lines on what the code does and why, and every function's help uses `.OUTPUTS`, so `Get-Help`
reads all of it (the `.RETURNS` keyword had made it ignore 202 of the 258 help blocks).

Four follow-ups from the review landed too. The uninstaller is now generated from the module as one
self-contained file, like the installer (wgt-gq8.43): it needs nothing next to it, its elevated
window runs a copy checked against the file's SHA256 instead of the files in place, and started
through `irm | iex` it changes nothing and stops with exit code 5 (`$LASTEXITCODE` 5 in an
interactive console, which stays open). The build makes both scripts through one code path, every
guard and `-Check` cover both, and `-Check` now compares ordinally. A whole-run time budget
(`-MaxRuntimeMinutes`, `WINGET_APP_SETUP_MAX_RUNTIME_MINUTES`, and the machine phase's own
`-MaxRuntimeMinutes`; wgt-gq8.41) lets an RMM job end with a report instead of being killed: once
it is used up, no app install, retry or Winget-AutoUpdate setup starts, the apps left are
`NotAttempted` (summary, `RESULT` line, `last-run.json`), and the run exits with the new code 9.
The catalog's architecture gates use `arch` lists (wgt-gq8.44): Dell Command Update is x64 only,
the Reader split moved from conditions to `arch` lists, and Google Drive stays ungated. The SYSTEM
E2E leg now checks each catalog app's entry in `last-run.json` against the checkout's catalog
(wgt-gq8.45), and fails when the job could not remove Chrome, 7-Zip or Git first. None of this has
run on a real PC yet, and no E2E leg runs the uninstaller, a budget that runs out or an ARM64 PC.

A fifth follow-up, wgt-gq8.42, lets a run as SYSTEM install the apps with the
`Microsoft.WinGet.Client` module, which Microsoft documents as the supported route as SYSTEM,
instead of `winget.exe`, which it documents as unsupported there. It is opt-in only
(`WINGET_APP_SETUP_SYSTEM_ENGINE=WinGetClient`, or the machine phase's
`-SystemInstallEngine WinGetClient`), for runs as SYSTEM only, and falls back to `winget.exe`
whenever the module is not ready. `winget.exe` stays the default. The installer downloads
Microsoft.WinGet.Client 1.29.380 from the PowerShell Gallery, pinned by size and SHA256
(`Get-WingetClientModulePin`) and checked for Microsoft signatures, stages it in a folder only
SYSTEM and Administrators can change, caches the package, and runs each module call in a child
`pwsh` under a time limit. Results map onto winget's result codes, so deferral, retries, restarts
and failure reporting are unchanged, and `last-run.json` gains `installEngine` and a per-app
`installerCode`. It needs PowerShell 7.4 or later, Windows build 17763 or later, and
`www.powershellgallery.com` and `cdn.powershellgallery.com` on port 443. Winget-AutoUpdate, the
uninstaller and the `winget download` path of `Install-PowerShellLatest` still use `winget.exe`.
`build/Set-WingetClientModulePin.ps1` checks the pin against the Gallery or moves it. A probe on the
hosted runner on 2026-10-06 (Windows Server 2025, PowerShell 7.6, as SYSTEM) loaded the pinned
module, found each file the pin requires to be signed valid from Microsoft Corporation, listed
installed packages and installed one with `-Scope System`. So winget-cli bug 5991
(`Get-WinGetPackage` failing as SYSTEM) did not reproduce there. The module's native engine
imports no Visual C++ runtime DLL, so it does not need that runtime. A fourth E2E leg,
`e2e-install-system-winget-client`, runs the SYSTEM pass twice with the engine. It has not run
yet, and no real PC has used the engine.

The same branch changes CI. Fork pull requests that leave `windows-tests.yml` alone no longer run
on the self-hosted win-test runner, and `claude.yml` calls the shared Claude workflow at a pinned
commit SHA instead of `@main`. The E2E workflow files its failure issue from a separate ubuntu job,
so a run that lost PowerShell 7, timed out or was cancelled is still reported, and it uploads
diagnostics snapshots next to the transcripts. It now also runs on pull requests that touch the
product, and pull-request and dispatched runs install the checkout instead of raw `main`, so this
branch's own E2E run tests its changes before they merge. A second E2E leg,
`e2e-install-windows-powershell`, starts every pass from Windows PowerShell 5.1 with PowerShell 7
removed first, so the bootstrap's install and relaunch get a real run, a third,
`e2e-install-system`, runs one pass as SYSTEM through the Endpoint Central machine phase, and a
fourth, `e2e-install-system-winget-client`, runs that SYSTEM pass twice with the
`Microsoft.WinGet.Client` engine. Every leg
first uninstalls the Chrome, 7-Zip and Git the runner image ships with, so those installs run too.
The transcript
checks moved into `e2e/TranscriptAssertions.ps1`, which is tested against sample transcripts and
now also catches timed-out apps and runs that ended without a summary.

### History before the 2026-10 review

The entries below were written when each change landed. Where the branch above changed or
replaced something, the entry says so.

**E2E: the App Installer 1.29.290.0 vs 1.26.510.0 wedge**
([#279](https://github.com/J-MaFf/winget-app-setup/issues/279), September 2026). Two
`windows-latest` (Windows Server 2025) E2E runs hit the same wedge in the idempotence pass:
App Installer `1.29.290.0` was staged next to the registered `1.26.510.0` and could not register
without `Microsoft.WindowsAppRuntime.1.8`. It was read at the time as a runner-image defect. That
was wrong: the installer's own `RUN_WAU=YES` started WAU, whose `Install-Prerequisites` provisioned
that App Installer (see the top of this section). Pinning `e2e-install` to `windows-2022` was tried
and reverted: every install there failed at once with "No applicable app licenses found", which is
[#282](https://github.com/J-MaFf/winget-app-setup/issues/282) and still open. #280's fail-fast,
`Get-ConflictingDesktopAppInstallerVersions`, read the current user's AppX view and never fired on
the real wedge; the branch replaced it with a circuit breaker that stops once winget cannot be
started. A third failure, [#283](https://github.com/J-MaFf/winget-app-setup/issues/283), stopped
the console with an uncaught `Start-Process` error ("The file cannot be accessed by the system")
right after the WAU install, then blamed on `Wait-WingetLaunchable`, which the branch has removed;
it has not come back since `RUN_WAU=YES` went.

Landed: **cheapest-first winget bootstrap ladder**
([#265](https://github.com/J-MaFf/winget-app-setup/issues/265)) — on a real cross-user elevation run
on 2026-08-11, `Repair-WinGetPackageManager -Latest -Force` was rejected with `0x80073D06` because
the machine's `Microsoft.WindowsAppRuntime.1.8` (8000.921.1539.0) is newer than the version the
WinGet release pins (8000.616.304.0), so the cmdlet aborted before registering App Installer. The run
did finish, but only after falling all the way through to the ~200 MB `aka.ms/getwinget` download and
printing a wall of AppX errors that reads like a broken machine. The fix registers the already-staged
`Microsoft.DesktopAppInstaller` package for the elevating account first (no download at all), only
then falls back to the repair cmdlet — unforced before forced — and treats `0x80073D06` as
non-retryable rather than escalating into a second large download. (The review branch removed the
aka.ms/getwinget download itself: registering the App Installer already on the PC covers that run.)

Landed: **the PowerShell 7 MSI fallback can no longer read as a hang**
([#263](https://github.com/J-MaFf/winget-app-setup/issues/263)) — on a machine whose invoking
account has no winget (a secondary admin account, since winget is a per-user MSIX), the bootstrap
used to hand the whole install to `aka.ms/install-powershell.ps1 -UseMSI -Quiet`, which suppresses
progress on Windows PowerShell, downloads 110 MB with an untimed `Invoke-WebRequest`, and waits on
`msiexec` forever — 3.5 minutes of measured silence on a healthy link and unbounded on a stalled
one, with nothing to tell them apart. `Invoke-PowerShell7Bootstrap` now resolves, downloads, and
installs the MSI itself with a stall timeout, an overall time limit, and periodic progress lines.
It kept the upstream script as a last resort; that script is no longer run (review findings
P2-17, P3-17).

Landed: **winget launch resilience while the app-execution alias is broken**
([#258](https://github.com/J-MaFf/winget-app-setup/issues/258)) — the 2026-07-27 scheduled E2E
run failed its idempotence pass because a background Winget-AutoUpdate run (kicked off by the
installer itself via `RUN_WAU=YES`) invalidated the per-user `winget.exe` alias for longer than
the 15s launch-retry window from #253, and the pre-check then misreported the already-installed
Windows Terminal as missing. `Install-WingetPackage` now gives launch failures their own
doubling-backoff budget (default 75s) and re-resolves the executable through the registered
`Microsoft.DesktopAppInstaller` package location (bypassing the alias) on every launch retry;
`Test-WingetPackageInstalled` retries once through the same bypass. (Removed on the review branch:
the bypass failed with `Access is denied` in every E2E run and never recovered a launch, and the
WAU run that broke the alias no longer happens during an install.)

Healthy. **The 2026-07-08 whole-repo multi-agent code-review wave is fully resolved**: all 17
issues it filed ([#176](https://github.com/J-MaFf/winget-app-setup/issues/176)–[#192](https://github.com/J-MaFf/winget-app-setup/issues/192))
have landed via PRs #193–#209 — see the Resolved Issues table below. Windows PowerShell 5.1
parse safety ([#210](https://github.com/J-MaFf/winget-app-setup/issues/210)) and the local
pre-commit drift check + guard-stack documentation
([#211](https://github.com/J-MaFf/winget-app-setup/issues/211)) have landed too; the full
guard stack that keeps `winget-app-install.ps1` from drifting from the module is documented
in readme.md ("Why `winget-app-install.ps1` cannot drift from the module").

Landed: **the installer bootstraps PowerShell 7 from Windows PowerShell 5.1**
([#225](https://github.com/J-MaFf/winget-app-setup/issues/225)) — instead of the #210
fail-fast, the 5.1 branch finds or installs `pwsh` (winget first, then the MSI) and relaunches
the installer in the same console with switches forwarded, so the documented one-liner works on
fresh shop machines that ship with only Windows PowerShell. The install-consent prompt that
shipped with it was removed by #230, and the MSI path was made time-bounded by #263.

Earlier, **fixed the winget source probe false-failing every run** ([#174](https://github.com/J-MaFf/winget-app-setup/issues/174)):
the `Invoke-WingetSourceProbe` command passed `--accept-source-agreements`, which is invalid for
`winget source update` (0x8A150002 / -1978335230), so the probe always failed and always printed
"could not be initialized … may fail with 0x80073D19" on healthy machines. Dropped the invalid flag.

**Dropped the unused msstore source** ([#172](https://github.com/J-MaFf/winget-app-setup/issues/172)):
the trusted-sources loop no longer trusts/resets msstore (the tool only installs from `--source winget`),
eliminating the frequent `Failed to reset sources for msstore` noise; the pre-elevation source update is
scoped to `--name winget` too.

**Removed the install-time inline update pass** ([#170](https://github.com/J-MaFf/winget-app-setup/issues/170)):
it upgraded every installed app synchronously as the elevating admin (slow, silent, mostly failing
under cross-user elevation) and is redundant now that WAU handles updates. The installer just installs
the curated apps and sets up WAU (which runs once immediately via `RUN_WAU=YES`, then weekly as SYSTEM).
(`RUN_WAU=YES` was removed on the review branch: that immediate run was the #279 wedge.)

**Auto-updates outsourced to Winget-AutoUpdate (WAU)** ([#168](https://github.com/J-MaFf/winget-app-setup/issues/168)):
the homegrown scheduled/on-demand updater (which ran non-elevated as the elevating admin and couldn't
do machine-scope updates) is removed — ~700 lines across `ScheduledUpdates.ps1`, `Update-InstalledApps.ps1`,
`Get-UpdateReport`, five one-liner switches, and ~10 tests. The installer now bootstraps a pinned,
SHA256-verified WAU 2.12.0 (weekly, SYSTEM + user-context, self-update disabled), and installer/uninstaller
run `Remove-LegacyScheduledUpdates` to migrate machines that already had the old task. The curated
cross-user install flow and install-time inline update pass are untouched.

**PowerShell now installs the latest version, version-agnostically** ([#166](https://github.com/J-MaFf/winget-app-setup/issues/166)):
`Install-PowerShellLatest` prefers the MSI while the current line ships one (≤ 7.6), and once the MSI
is gone (7.7+) installs the latest MSIX machine-wide — natively on Windows 24H2+ (build ≥ 26100) or via
`Add-AppxProvisionedPackage` DISM provisioning on older Windows (a non-packaged process, so it dodges
winget's packaged-context provisioning bug). No version is ever pinned. The scheduled-update task now
runs under Windows PowerShell 5.1 so an MSIX-only pwsh can't break it (that task went with the
homegrown updater, #168). The DISM path is dormant until 7.7 GA and needs validation on a real
Windows 10 machine before it is relied upon.

**Cross-user PowerShell install fixed** ([#163](https://github.com/J-MaFf/winget-app-setup/issues/163)):
on an elevated session whose interactive desktop belongs to a different user, `Microsoft.PowerShell`
still failed with "The current system configuration does not support the installation of this package"
even after #159. winget installs PowerShell 7.6+ as an MSIX by default, and — even with `--scope machine`
— winget's installer-type precedence still selects the MSIX, whose machine-scope provisioning fails as a
packaged app on Windows < build 26100. The PowerShell entry now forces `--installer-type wix` (the
machine-wide MSI) via a new `-InstallerType` parameter on `Install-WingetPackage`. Also fixed the
scheduled-update setup erroring under `irm | iex` (empty `$PSScriptRoot`) and registering a weekly task
whose helper was never deployed ([#164](https://github.com/J-MaFf/winget-app-setup/issues/164)): the
remote path now downloads the helper plus the self-contained script, and deployment is best-effort.

Earlier, the **cross-user `0x80073d19` root cause was fixed** ([#159](https://github.com/J-MaFf/winget-app-setup/issues/159)):
the error that persisted through #81/#104/#107/#150 is `ERROR_DEPLOYMENT_BLOCKED_BY_USER_LOG_OFF` —
when the script is elevated as a different account than the logged-on user, winget's per-user MSIX
bootstrap is blocked because that account has no interactive logon session. The installer now
bootstraps the account via `Repair-WinGetPackageManager`, persists source agreements with a proper
probe, detects cross-user elevation, and installs with `--scope machine` (auto-fallback for
MSIX-only packages such as Windows Terminal; on the review branch a run as SYSTEM or under
cross-user elevation reports such an app `Deferred` instead).

**One-liner install fixed** ([#154](https://github.com/J-MaFf/winget-app-setup/issues/154)):
the `#106` module extraction had dropped `Test-SystemRequirements` without carrying it into the
module, so the default `irm | iex` path threw `CommandNotFoundException`. The function is restored as
`WingetAppSetup/Public/SystemChecks.ps1`, and the build now fails when the generated installer calls
a hyphenated command that resolves to neither a module function nor an external cmdlet, closing the
drift class that let this ship.

**Beads (`bd`) adopted** as the dependency-graph task/memory layer beneath GitHub
Issues ([#147](https://github.com/J-MaFf/winget-app-setup/issues/147), PR merged) — `.beads/`
holds the issue graph, a Dolt remote is wired to `origin` for cross-machine sync, and the
CLAUDE.md beads section is reconciled with `git-policies` (merges stay human-gated).

The install logic has been refactored from a 2,100-line monolith into a module
([#106](https://github.com/J-MaFf/winget-app-setup/issues/106)), and the distributable script is a
generated build artifact that remains byte-for-byte behaviour-equivalent to the previous monolith.
The 2026 code-review batch (#134–#137) has also been applied: all changed scripts parse clean under
the PowerShell AST parser on pwsh 7, and the Pester suite's pass/fail set is unchanged from
baseline on Linux (the only failures are pre-existing Windows-only environment limitations).

CI now runs `build/Build-WingetInstallScript.ps1 -Check` on every push and pull request, so the
generated `winget-app-install.ps1` can no longer drift from the module (and the installer's
undefined-reference guard runs automatically) ([#156](https://github.com/J-MaFf/winget-app-setup/issues/156)).
The Windows CI workflow (job `pester`, the required check on `main`) runs trusted runs on the
self-hosted **win-test** runner (Windows Server 2025, pwsh 7.6.3). Trusted runs are pushes to
`main`, manual dispatch, and pull requests from a branch of this repository. The guarded
Microsoft.WinGet.Client and Pester installs persist across runs there
([#161](https://github.com/J-MaFf/winget-app-setup/issues/161)). win-test is a persistent machine
that runs jobs elevated, so pull requests from forks, and any run not listed as trusted, go to
GitHub-hosted `windows-latest` instead. To run that leg on demand, dispatch the workflow with
`hosted` ticked. A fork PR that edits `windows-tests.yml` can still pick its own runner, because a
`pull_request` run uses the PR's copy of the workflow. Closing that gap needs the "Require approval
for all external contributors" setting (check `.github/` changes before approving a fork run) and a
job-started hook on the runner that refuses fork PR jobs (see Natural Next Steps). `claude.yml`
calls the shared Claude workflow in J-MaFf/.github at a pinned commit SHA. The actions and the
git-policies text that workflow pulls in are not pinned yet, and `secrets: inherit` still passes it
every repository secret.

### Components

| Path | Description |
|------|-------------|
| `WingetAppSetup/` | Source-of-truth PowerShell module (`.psd1` manifest + `.psm1` loader) |
| `WingetAppSetup/Public/` | Entry points and main steps (the module exports every function, `Public/` and `Private/` alike): logging, winget core, app validation, Windows Terminal config, install orchestration (updates are outsourced to WAU), uninstall orchestration (`Invoke-WingetUninstall`), the Endpoint Central user phase (`Invoke-WingetUserPhase`) |
| `WingetAppSetup/Private/` | Helpers: system info, elevation, the Windows PowerShell 5.1 → PowerShell 7 bootstrap, the environment checks (`EnvironmentPreflight.ps1`), the machine-wide winget and provisioning lookups a run as SYSTEM uses (`MachineContext.ps1`), the run lock (`RunLock.ps1`), the `RESULT` line and `last-run.json` (`RunRecord.ps1`), the catalog entry fields and post-install hooks (`CatalogSchema.ps1`), TightVNC's password hook (`TightVnc.ps1`), log retention (`Housekeeping.ps1`), the diagnostics bundle (`Diagnostics.ps1`), the user phase's helpers (`UserPhaseSupport.ps1`), the uninstaller's per-app step (`AppUninstall.ps1`), Winget-AutoUpdate's checks (`WauSupport.ps1`), the pinned `Microsoft.WindowsAppRuntime.1.8` install before Winget-AutoUpdate (`WindowsAppRuntime.ps1`), and the opt-in Microsoft.WinGet.Client engine of runs as SYSTEM: its pin, download, checks and child script (`WingetClientModule.ps1`) and its requests and result mapping (`WingetClientEngine.ps1`) |
| `build/Build-WingetInstallScript.ps1` | Assembles the module, without its comments, and the entry fragments into `winget-app-install.ps1` and `winget-app-uninstall.ps1`; every guard runs on both, and `-Check` verifies both |
| `build/Set-RmmInstallerPin.ps1` | Sets the pinned installer commit and SHA256 in both Endpoint Central phases |
| `build/Set-WingetClientModulePin.ps1` | Checks the Microsoft.WinGet.Client pin in `Get-WingetClientModulePin` against the PowerShell Gallery (`-Check`, exit 1 on a mismatch) or moves it (`-Write`); run the `e2e-install-system-winget-client` job after moving it |
| `rmm/` | Standalone Endpoint Central scripts, not generated: the machine phase (`Invoke-WingetAppSetup.ps1`, as SYSTEM, with an optional `-MaxRuntimeMinutes` time budget and an optional `-SystemInstallEngine WinGetClient`), the user phase (`Invoke-WingetAppSetupUserPhase.ps1`, at each sign-in), the fleet health probe (`Get-WingetFleetHealth.ps1`) and the WAU at-logon fix (`Repair-WauLogonTrigger.ps1`); see readme "Endpoint Central and other RMM tools" |
| `build/fragments/` | `head.ps1` (PSScriptInfo, help, `param`) and `tail.ps1` (entry-point dispatch) for the installer; `uninstall-head.ps1` and `uninstall-tail.ps1` for the uninstaller |
| `winget-app-install.ps1` | **Generated** single-file installer for local and `irm \| iex` use — do not edit by hand |
| `winget-app-uninstall.ps1` | **Generated** single-file uninstaller; runs `Invoke-WingetUninstall` and relaunches elevated as a checked copy (exit codes in readme "Uninstall") — do not edit by hand |
| `tests/` | Pester suite, one `<Area>.Tests.ps1` per module file plus `EntryPoint.Tests.ps1`, `TestHarness.Tests.ps1`, `BuildGuards.Tests.ps1` (the build guards and the pre-commit hook), the `Rmm*.Tests.ps1` files (the `rmm/` scripts and the pin helper) and the `E2E*.Tests.ps1` files (for the `e2e/` scripts, with sample transcripts and a sample SYSTEM-run `last-run.json`, `system-last-run.json`, in `tests/fixtures/e2e`; `Diagnostics.Tests.ps1` has sample logs in `tests/fixtures/diagnostics`, and `WingetClientEngine.Tests.ps1` sample child `pwsh` results in `tests/fixtures/winget-client`); `TestHelpers.ps1` loads the module once per file and stands in for Windows-only commands, so the suite also runs on Linux/macOS |
| `e2e/Assert-Install.ps1` | Shared post-install assertions for end-to-end runs (tier 1 workflow below; tier 2 [#215](https://github.com/J-MaFf/winget-app-setup/issues/215) reuses it); decides which apps apply with the module's `Test-AppApplicability`; the transcript checks are in `e2e/TranscriptAssertions.ps1` and fixture-tested; `-InstallerPath` checks that every pass ran the checkout's build |
| `e2e/Invoke-InstallPass.ps1` | Starts each E2E install pass (one-liner or `-File`, from PowerShell 7 or Windows PowerShell 5.1) and applies the exit-code policy: 0 and 3010 pass, 8 only when the pass's transcript says WAU was skipped for the missing `Microsoft.WindowsAppRuntime.1.8`, the installer could not try to install it (quoting its `Windows App Runtime:` line) and its pinned framework still meets what the latest winget release needs, 1 only while `KNOWN_PLATFORM_INCOMPATIBLE` is non-empty |
| `e2e/Invoke-SystemInstallPass.ps1` | The SYSTEM leg's pass: a one-shot SYSTEM scheduled task starts `rmm/Invoke-WingetAppSetup.ps1` with the 32-bit `powershell.exe` and the checkout's installer, then checks the exit code, the machine phase's log, `last-run.json` (its Deferred entries and each catalog app's entry, against the checkout's catalog decided as SYSTEM), WAU and the framework, and that nothing was installed into SYSTEM's own profile; with `-SystemInstallEngine WinGetClient -PassCount 2`, two passes and the Microsoft.WinGet.Client engine's checks (module ready at its pin, every install through `Install-WinGetPackage`, the removed apps in `winget list` as the runner account, the module from the cache on the second pass) |
| `e2e/Remove-PreinstalledApps.ps1` | Uninstalls the catalog apps the runner image ships with (Chrome, 7-Zip, Git; with `-IncludePowerShell7`, PowerShell 7 too) before the first E2E pass; every call time-limited, failures become warnings |
| `e2e/Collect-Diagnostics.ps1` | Windows PowerShell 5.1 snapshots for the E2E run: pwsh versions, App Installer / WindowsAppRuntime AppX state, WAU tasks; at the end MsiInstaller and RestartManager events, AppX deployment errors and warnings, WAU logs and the newest 10 `WinGetCOM-*.log` files of the WinGet engine that Microsoft.WinGet.Client runs as SYSTEM (`e2e-diagnostics` artifact); always exits 0 |
| `.github/workflows/e2e-install.yml` | E2E tier 1: real install runs on GitHub-hosted `windows-latest` in four legs, `e2e-install` from PowerShell 7, `e2e-install-windows-powershell` from Windows PowerShell 5.1 through the PowerShell 7 bootstrap, `e2e-install-system` as SYSTEM through the Endpoint Central machine phase, and `e2e-install-system-winget-client` as SYSTEM with the Microsoft.WinGet.Client engine (two passes, after an informational pin check), after removing the preinstalled Chrome, 7-Zip and Git (weekly against raw `main`, the SYSTEM legs against the checkout; dispatches and PRs that touch the product, `rmm/` or e2e files against the checkout; uploads transcripts and diagnostics; a failed, timed-out or cancelled weekly or `main`-dispatched run files an issue from the ubuntu `report-failure` job) |
| `.github/workflows/windows-tests.yml` | Pester suite and build `-Check` (job `pester`, the required check on `main`): self-hosted win-test for pushes, dispatch and same-repo PRs; GitHub-hosted `windows-latest` for fork PRs and `hosted` dispatches |
| `readme.md` | How to run the installer, what it does, its exit codes and logs, Endpoint Central deployment, and the E2E monitoring |
| `CHANGELOG.md` | Keep a Changelog history. |

### Resolved Issues

| Issue | Description | PR |
|-------|-------------|----|
| [#265](https://github.com/J-MaFf/winget-app-setup/issues/265) | `Repair-WinGetPackageManager` aborts with 0x80073D06 when the machine has a newer WindowsAppRuntime, forcing a 200 MB fallback download | [#266](https://github.com/J-MaFf/winget-app-setup/pull/266) |
| [#263](https://github.com/J-MaFf/winget-app-setup/issues/263) | PowerShell 7 MSI fallback blocks forever with no output (reads as a hang) | [#264](https://github.com/J-MaFf/winget-app-setup/pull/264) |
| [#260](https://github.com/J-MaFf/winget-app-setup/issues/260) | Adopt shared reusable claude.yml workflow from J-MaFf/.github | [#261](https://github.com/J-MaFf/winget-app-setup/pull/261) |
| [#258](https://github.com/J-MaFf/winget-app-setup/issues/258) | E2E install run failed: winget alias inaccessible through every launch retry (WAU/App Installer upgrade race) | [#259](https://github.com/J-MaFf/winget-app-setup/pull/259) |
| [#225](https://github.com/J-MaFf/winget-app-setup/issues/225) | Bootstrap PowerShell 7 from Windows PowerShell 5.1 instead of failing fast | [#228](https://github.com/J-MaFf/winget-app-setup/pull/228) |
| [#226](https://github.com/J-MaFf/winget-app-setup/issues/226) | IEX non-admin guidance test silently always skipped (`-Skip` bound at discovery time reads `BeforeAll` variables as `$null`) | [#227](https://github.com/J-MaFf/winget-app-setup/pull/227) |
| [#217](https://github.com/J-MaFf/winget-app-setup/issues/217) | Dell Command Update cannot install on GitHub-hosted runners — manufacturer-aware catalog gating | [#220](https://github.com/J-MaFf/winget-app-setup/pull/220) |
| [#221](https://github.com/J-MaFf/winget-app-setup/issues/221) | Pre-flight OS check misidentifies Windows 11 | [#222](https://github.com/J-MaFf/winget-app-setup/pull/222) |
| [#211](https://github.com/J-MaFf/winget-app-setup/issues/211) | Local pre-commit drift check + document the generated-script guard stack | [#213](https://github.com/J-MaFf/winget-app-setup/pull/213) |
| [#210](https://github.com/J-MaFf/winget-app-setup/issues/210) | Generated installer fails to parse under Windows PowerShell 5.1 (BOM-less UTF-8 decoded as ANSI) | [#212](https://github.com/J-MaFf/winget-app-setup/pull/212) |
| [#192](https://github.com/J-MaFf/winget-app-setup/issues/192) | Split `Test-WingetAppInstall.Tests.ps1` into per-area files and remove tautological/drifted tests | [#209](https://github.com/J-MaFf/winget-app-setup/pull/209) |
| [#191](https://github.com/J-MaFf/winget-app-setup/issues/191) | Module surface: reconcile psd1/psm1 export lists, remove dead `ConvertTo-CommandArguments`, move logging primitives to Private | [#205](https://github.com/J-MaFf/winget-app-setup/pull/205) |
| [#190](https://github.com/J-MaFf/winget-app-setup/issues/190) | Single-source the app catalog and make the uninstaller consume the module | [#208](https://github.com/J-MaFf/winget-app-setup/pull/208) |
| [#189](https://github.com/J-MaFf/winget-app-setup/issues/189) | Persistent transcript logging, build-stamped version, and surfacing winget exit codes in failures | [#207](https://github.com/J-MaFf/winget-app-setup/pull/207) |
| [#188](https://github.com/J-MaFf/winget-app-setup/issues/188) | Extract a shared install-and-verify helper so `Invoke-WingetInstall` becomes testable | [#206](https://github.com/J-MaFf/winget-app-setup/pull/206) |
| [#187](https://github.com/J-MaFf/winget-app-setup/issues/187) | Windows Terminal configuration targets the admin's profile under cross-user elevation; JSONC sanitizer misses inline comments; `-AsJson` output is polluted | [#204](https://github.com/J-MaFf/winget-app-setup/pull/204) |
| [#186](https://github.com/J-MaFf/winget-app-setup/issues/186) | WAU operability: surface install result in summary, version-aware upgrades, uninstall the actual product code, harden the MSI temp path | [#203](https://github.com/J-MaFf/winget-app-setup/pull/203) |
| [#185](https://github.com/J-MaFf/winget-app-setup/issues/185) | `-SkipSystemCheck` is dropped on elevated relaunch; `Invoke-WingetInstall` breaks when invoked from the imported module | [#198](https://github.com/J-MaFf/winget-app-setup/pull/198) |
| [#184](https://github.com/J-MaFf/winget-app-setup/issues/184) | SystemChecks: proxy-only networks false-FAIL the blocking network check; disk-space prompt fires on drive-read failure; `-WhatIf` skips checks it promises to run | [#195](https://github.com/J-MaFf/winget-app-setup/pull/195) |
| [#183](https://github.com/J-MaFf/winget-app-setup/issues/183) | Build script robustness: parse errors discarded, PS 5.1 encoding corruption, BOM-blind `-Check`, culture-sensitive sort | [#201](https://github.com/J-MaFf/winget-app-setup/pull/201) |
| [#182](https://github.com/J-MaFf/winget-app-setup/issues/182) | Docs truth pass: stale updater references, wrong probe-flag description, dead links, conflicting agent instructions | [#199](https://github.com/J-MaFf/winget-app-setup/pull/199) |
| [#181](https://github.com/J-MaFf/winget-app-setup/issues/181) | Pester suite executes the real `Repair-WinGetPackageManager` and has order-dependent tests via stale `LASTEXITCODE` | [#197](https://github.com/J-MaFf/winget-app-setup/pull/197) |
| [#180](https://github.com/J-MaFf/winget-app-setup/issues/180) | `winget-app-uninstall.ps1`: locale-dependent success detection, no exit-code capture, hangs on first-run source agreements | [#193](https://github.com/J-MaFf/winget-app-setup/pull/193) |
| [#179](https://github.com/J-MaFf/winget-app-setup/issues/179) | PATH handling: installer permanently adds its own directory to User PATH; duplicate detection is case-sensitive; 2048-char guard is wrong | [#196](https://github.com/J-MaFf/winget-app-setup/pull/196) |
| [#178](https://github.com/J-MaFf/winget-app-setup/issues/178) | `Invoke-AppxProvisioning` interpolates paths into an elevated command with no escaping | [#194](https://github.com/J-MaFf/winget-app-setup/pull/194) |
| [#177](https://github.com/J-MaFf/winget-app-setup/issues/177) | Winget source/bootstrap verification trusts error output and duplicates probes | [#202](https://github.com/J-MaFf/winget-app-setup/pull/202) |
| [#176](https://github.com/J-MaFf/winget-app-setup/issues/176) | Orchestrator reports success on failure and blocks unattended runs | [#200](https://github.com/J-MaFf/winget-app-setup/pull/200) |
| [#174](https://github.com/J-MaFf/winget-app-setup/issues/174) | Winget source probe false-fails (invalid `--accept-source-agreements` on `source update`) | [#175](https://github.com/J-MaFf/winget-app-setup/pull/175) |
| [#172](https://github.com/J-MaFf/winget-app-setup/issues/172) | Stop trusting/resetting the unused msstore source (noisy reset failures) | [#173](https://github.com/J-MaFf/winget-app-setup/pull/173) |
| [#170](https://github.com/J-MaFf/winget-app-setup/issues/170) | Remove the install-time inline update pass (redundant with WAU) | [#171](https://github.com/J-MaFf/winget-app-setup/pull/171) |
| [#168](https://github.com/J-MaFf/winget-app-setup/issues/168) | Outsource auto-updates to Winget-AutoUpdate (WAU); remove homegrown updater | [#169](https://github.com/J-MaFf/winget-app-setup/pull/169) |
| [#166](https://github.com/J-MaFf/winget-app-setup/issues/166) | Always-latest PowerShell install strategy for the MSIX-only (7.7+) future; harden scheduled task for MSIX | [#167](https://github.com/J-MaFf/winget-app-setup/pull/167) |
| [#163](https://github.com/J-MaFf/winget-app-setup/issues/163) | PowerShell fails to install on elevated cross-user sessions (winget picks MSIX over MSI for 7.6+) | [#165](https://github.com/J-MaFf/winget-app-setup/pull/165) |
| [#164](https://github.com/J-MaFf/winget-app-setup/issues/164) | Scheduled-update setup errors under `irm \| iex` (empty `$PSScriptRoot`); weekly task registered but never deployed | [#165](https://github.com/J-MaFf/winget-app-setup/pull/165) |
| [#106](https://github.com/J-MaFf/winget-app-setup/issues/106) | Split `winget-app-install.ps1` into a module with a generated bundle | [#109](https://github.com/J-MaFf/winget-app-setup/pull/109) |
| [#110](https://github.com/J-MaFf/winget-app-setup/issues/110) | Migrate uninstall + update-helper scripts to consume the module | [#109](https://github.com/J-MaFf/winget-app-setup/pull/109) |
| [#111](https://github.com/J-MaFf/winget-app-setup/issues/111) | Remove orphaned tests for functions that no longer exist | [#109](https://github.com/J-MaFf/winget-app-setup/pull/109) |
| [#117](https://github.com/J-MaFf/winget-app-setup/issues/117) | `-WhatIf` dropped the flag on elevation and ran a real install | [#116](https://github.com/J-MaFf/winget-app-setup/pull/116) |
| [#120](https://github.com/J-MaFf/winget-app-setup/issues/120) | Post-install update phase could hang indefinitely on one package | [#121](https://github.com/J-MaFf/winget-app-setup/pull/121) |
| [#134](https://github.com/J-MaFf/winget-app-setup/issues/134) | Double winget command execution in `Invoke-WingetCommand` | [#138](https://github.com/J-MaFf/winget-app-setup/pull/138) |
| [#135](https://github.com/J-MaFf/winget-app-setup/issues/135) | Pester tests copied function bodies instead of dot-sourcing the script | [#139](https://github.com/J-MaFf/winget-app-setup/pull/139) |
| [#136](https://github.com/J-MaFf/winget-app-setup/issues/136) | Missing `STATUS.md` and README/CHANGELOG execution-policy mismatch | [#140](https://github.com/J-MaFf/winget-app-setup/pull/140) |
| [#137](https://github.com/J-MaFf/winget-app-setup/issues/137) | Renamed `Test-Source-IsTrusted` to `Test-WingetSourceTrusted` for verb-noun compliance | [#142](https://github.com/J-MaFf/winget-app-setup/pull/142) |
| [#154](https://github.com/J-MaFf/winget-app-setup/issues/154) | One-liner install failed: `Test-SystemRequirements` undefined on the default path; build now guards undefined references | [#155](https://github.com/J-MaFf/winget-app-setup/pull/155) |
| [#156](https://github.com/J-MaFf/winget-app-setup/issues/156) | Wire build-script `-Check` into CI so the installer can't drift | [#157](https://github.com/J-MaFf/winget-app-setup/pull/157) |
| [#161](https://github.com/J-MaFf/winget-app-setup/issues/161) | Run Windows CI on the self-hosted win-test runner instead of `windows-latest` | [#162](https://github.com/J-MaFf/winget-app-setup/pull/162) |

### Open Issues

| Issue | Description | Status |
|-------|-------------|--------|
| [#279](https://github.com/J-MaFf/winget-app-setup/issues/279) | E2E: App Installer 1.29.290.0 vs 1.26.510.0 AppX wedge, missing WindowsAppRuntime.1.8 | Fixed on PR #285: the installer's own `RUN_WAU=YES` caused it (see Current State). E2E green on all legs; close when #285 merges |
| [#282](https://github.com/J-MaFf/winget-app-setup/issues/282) | E2E: `windows-2022` runner fails every install immediately with "No applicable app licenses found" | Open; E2E stays on `windows-latest`, which is green on #285 |
| [#283](https://github.com/J-MaFf/winget-app-setup/issues/283) | E2E: uncaught `Start-Process` error crashes first install pass right after WAU install on `windows-latest` | Not seen since PR #285 dropped `RUN_WAU=YES` (most likely WAU's PowerShell upgrade under the running installer); close when #285 merges unless it comes back |
| [#284](https://github.com/J-MaFf/winget-app-setup/issues/284) | E2E install run failed (filed by the weekly run on `main` of 2026-09-28, run 36384683838: the #279 wedge, with winget failing to launch with `Access is denied`) | Fixed on PR #285 with #279; close when #285 merges |
| [#215](https://github.com/J-MaFf/winget-app-setup/issues/215) | E2E tier 2: cross-user elevation end-to-end run on a snapshot-rollback Proxmox VM | Open |

## Natural Next Steps

- After #285 merges: close #279, #283 and #284, and watch the next weekly E2E run against raw `main` (Mondays 06:00 UTC). A failed, timed-out or cancelled run creates or comments on the `E2E install run failed` issue.
- After #285 merges and that E2E run passes: pin the Endpoint Central phases with `pwsh -File build/Set-RmmInstallerPin.ps1 -Commit <commit on main>`, commit the two `rmm/` scripts, upload them to the Script Repository, and try both phases, the health probe and the at-logon fix on a pilot PC (readme "Endpoint Central and other RMM tools"). Until the pins are set, both phases exit 5 and run nothing. Check that Endpoint Central's Remarks show the output; its script time limit and the time budget are the `-MaxRuntimeMinutes` item below. The Microsoft.WinGet.Client engine is the pilot item below.
- Make `e2e-install` a required status check for `main` (next to `pester`); it is green on #285. Every PR now gets an `e2e-install` status, and a skip counts as passed, so requiring it does not block docs-only PRs. Keep the job id `e2e-install` and give it no `name:`, or the required check stops matching. The Windows PowerShell 5.1 leg, `e2e-install-windows-powershell`, and the SYSTEM legs, `e2e-install-system` and `e2e-install-system-winget-client`, are separate checks with the same `if:`; decide whether to require them too (each adds hosted-runner minutes per run, not wall-clock time, since the legs run in parallel).
- Dispatch Windows Tests once with `hosted` ticked (`gh workflow run windows-tests.yml -f hosted=true`) to confirm the suite passes on GitHub-hosted `windows-latest`, the runner fork pull requests now use.
- Before the first fork PR, turn on "Require approval for all external contributors" (Settings > Actions > General) and add a job-started hook on win-test (`ACTIONS_RUNNER_HOOK_JOB_STARTED`) that refuses fork pull request jobs, since a fork PR can rewrite `runs-on` in its copy of `windows-tests.yml`.
- In [J-MaFf/.github](https://github.com/J-MaFf/.github): pin `anthropics/claude-code-action` and `actions/checkout` in the shared `claude.yml` to commit SHAs, fetch git-policies at a pinned ref, and declare `CLAUDE_CODE_OAUTH_TOKEN` under `on.workflow_call.secrets`. Then move this repository's `claude.yml` pin to that SHA and replace `secrets: inherit` with that one secret.
- **E2E tier 2** ([#215](https://github.com/J-MaFf/winget-app-setup/issues/215)): cross-user elevation end-to-end run on a snapshot-rollback Proxmox VM, reusing `e2e/Assert-Install.ps1` (the shared assertion script from tier 1).
- Watch the first Windows CI runs on the self-hosted win-test runner for environment drift — module versions now persist across runs instead of starting from a fresh `windows-latest` image (as of [#161](https://github.com/J-MaFf/winget-app-setup/issues/161)).
- Run the installer as SYSTEM on real Windows 11 and Windows 10 PCs (from Endpoint Central, or
  `psexec -s` from a 32-bit PowerShell) before relying on it from the RMM: the machine-wide
  `winget.exe` lookup and launch, `--scope machine` installs of the catalog, the `Deferred` report,
  the Windows Terminal provisioning check, and whether a clean PC without the Visual C++ runtime
  fails with `0xC0000135`. Then decide whether to make the `Microsoft.WinGet.Client` engine the
  default for SYSTEM runs (the owner decision below), and whether the Windows PowerShell 5.1
  bootstrap should install PowerShell 7 as SYSTEM with the
  machine-wide `winget.exe` instead of the MSI download (whose GitHub release list can answer 429
  when many PCs ask at once). On a standard user's PC, check that the user phase installs the
  deferred apps at the next sign-in without a UAC prompt.
- Check the RMM and auto-update changes on real Windows: two runs at once (the second exits 6), a
  run killed mid-way (`last-run.json` keeps `exitCode` null), the `RESULT` line from Endpoint
  Central, a deleted or disabled `\WAU\Winget-AutoUpdate` task (`UNHEALTHY`, exit 8, and whether the
  real "not found" error id matches `CmdletizationQuery_NotFound*`), and WAU's `updates.log` tail
  (WAU writes it from Windows PowerShell 5.1). Treat exit code 8 in the RMM policies as "apps OK,
  auto-updates need attention", not as a failed install, and exit code 9 as "not finished, run it
  again", not as a success.
- Check the pinned Windows App Runtime install on real Windows: a fresh Windows 11 and Windows 10
  PC without `Microsoft.WindowsAppRuntime.1.8`, cross-user elevated and as SYSTEM. (On the Server
  2025 runner the E2E runs of this branch install it and set up WAU, as SYSTEM too.) Confirm that
  provisioning the framework `.msix` on its own makes it show for every user
  (`Get-AppxPackage -AllUsers`) and for an account that signs in for the first time, and then that
  WAU's own run keeps winget working; no E2E step starts WAU's task yet. Owner: confirm that
  deploying the framework from the developer NuGet package (Windows App SDK license terms) is
  acceptable for the fleet. Also
  check on Windows that the transcript shows `The latest winget release needs ...` (the
  `DesktopAppInstaller_Dependencies.json` download through GitHub's redirect works from the PCs and
  as SYSTEM, behind the fleet's proxy) and, with GitHub blocked, the warning and the built-in
  requirement.
- On a real Windows 11 ARM64 PC, check: the 32-bit Reader is installed and the 64-bit one skipped;
  Google Drive (deliberately ungated) installs through winget, `GoogleDriveFS.exe` is an ARM64
  binary and its `googledrivefs` driver runs (gate it with `arch = 'X64'` if not); on an ARM64 Dell,
  Dell Command Update is skipped as `Dell hardware with x64 Windows only; ...`. Also smoke-test
  TightVNC (x64) and Bulk Crap Uninstaller (x86) under emulation. GitHub's `windows-11-arm` runner
  could cover all but Dell once it has a working winget (none is preinstalled); that leg should
  also add an independent `-ExpectOSArchitecture` check (from `RUNNER_ARCH`) and per-leg Reader
  expectations to `e2e/Assert-Install.ps1`.
- Owner: decide whether Windows 10 ARM64 (end of servicing) and 32-bit Windows matter to the fleet.
  On Windows 10 ARM64, which emulates only x86, `Google.GoogleDrive` fails on every run with
  `0x8A150010` (or is `Deferred` as SYSTEM), and on 32-bit Windows `Google.GoogleDrive` and
  `Git.Git` have no installer. Either gate them, treat `0x8A150010` as "no installer for this PC"
  at every scope, or state that those editions are unsupported. Widen Dell Command Update's `arch`
  to `'X64', 'Arm64'` once winget-pkgs carries Dell's ARM64 installer.
- Check the TightVNC password hook on real Windows with TightVNC 2.8.89, as SYSTEM from Endpoint
  Central and interactively: a viewer can connect with the password, a standard user cannot change
  the server from the tray icon without the control password, `Get-Acl
  'HKLM:\SOFTWARE\TightVNC\Server'` lists only SYSTEM and Administrators (inheritance off) and the
  tray icon still works with that, the service restarts cleanly, a second run changes nothing, the
  transcript holds neither the password nor what was typed at the prompt, and whether an upgrade
  (WAU) or an uninstall keeps or removes the key. Owner: decide how Endpoint Central delivers
  `WINGET_APP_SETUP_TIGHTVNC_PASSWORD` (the readme suggests setting it in the uploaded copy of the
  machine phase, never as a script argument), whether a run without it should stay `Not configured` with exit code 0 (today) or fail (exit 1)
  or add a count to the `RESULT` line, and whether to drop TightVNC once Endpoint Central's remote
  control is rolled out. The E2E run does not set a TightVNC password, so it never takes the
  configured path.
- Run the single-file uninstaller on real Windows, cross-user elevated and as SYSTEM, where
  `winget list` does not see per-user MSIX apps such as Windows Terminal, under Windows PowerShell
  5.1 and under `pwsh` (which must keep PowerShell 7). Started from a user-writable folder in a
  window that is not elevated, its elevated Windows PowerShell window should run the checked copy
  under `%SystemRoot%\Temp\winget-app-setup-<id>`, stay open at `Press any key to exit...` with the
  summary on screen, delete its copy and staging folders afterwards, and hand the run's exit code
  back to the window that asked, after Ctrl+C at that prompt too. Approved by another admin under a
  Group Policy `AllSigned`, it should print `Did not run winget-app-uninstall.ps1: ...` and exit 4.
  `irm <raw>/winget-app-uninstall.ps1 | iex` in an interactive console should print one line, keep
  the console open and leave `$LASTEXITCODE` 5. No E2E leg runs the uninstaller yet; consider an
  uninstall pass (at least `-WhatIf`) and adding `winget-app-uninstall.ps1` to the E2E `changes`
  job's product paths.
- Measure Endpoint Central's script time limit, set the machine phase's `-MaxRuntimeMinutes` about
  45 minutes below it, and run it on a real PC as SYSTEM from Endpoint Central (its 32-bit agent, so
  the deadline crosses the Sysnative relaunch). Check that a run whose budget runs out exits 9, that
  deploying the configuration again runs it again, and that the next run finishes the apps it did
  not attempt. Also check an interactive run with `WINGET_APP_SETUP_MAX_RUNTIME_MINUTES` set: its
  elevated window should print the same deadline. Exit 9 is covered only by the Pester suite today
  (mocked and child-process tests, on Linux and in Windows CI), not by an E2E or real-PC run; an
  E2E dispatch input that runs one SYSTEM pass with a small budget would cover it. With a budget,
  the elevated relaunch's command line fits only when `%TEMP%` is about 145 characters or shorter
  (a longer one exits 4).
- Microsoft.WinGet.Client engine (wgt-gq8.42): the first run of `e2e-install-system-winget-client`
  has not happened yet, and it must pass both passes before the engine is used anywhere. Still to
  check on Windows:
  - `pwsh -File build/Set-WingetClientModulePin.ps1 -Check` on a Windows PC of your own, and that its
    list of signed files matches the pin's `SignedFiles` (the session that wrote the engine could
    not reach the Gallery, and signatures read `n/a` off Windows);
  - the Windows CI Pester run (`windows-tests.yml`) with the real cmdlets: `Test-AuthenticodeSigner`
    against the real `Get-AuthenticodeSignature`, `Set-RestrictedDirectoryAcl` on the cache and
    staging folders, and the link and owner checks of `Remove-StaleWingetClientFolder`;
  - under the Endpoint Central agent, which has no console, that the child `pwsh`'s
    `WINGET-CLIENT-RESULT` line arrives;
  - where the engine writes `WinGetCOM-*.log` as SYSTEM (`WinGet\defaultState` under
    `%SystemRoot%\SystemTemp` or `%SystemRoot%\Temp`), and that `e2e/Collect-Diagnostics.ps1` finds
    them;
  - a Group Policy `AllSigned` execution policy that the run itself gets past (a run a Group Policy
    script started): expect `WinGet client module: NOT READY` and a fallback to `winget.exe`;
  - an ARM64 PC, an x86 PowerShell process, and Windows 10 1809 (build 17763) or later;
  - the generated installer under Windows PowerShell 5.1 (the 5.1 E2E leg runs it; the parse and
    ASCII guards pass on Linux);
  - an Endpoint Central pilot with `-SystemInstallEngine WinGetClient` behind the fleet's proxy or
    allowlist (`www.powershellgallery.com` and `cdn.powershellgallery.com` on port 443). It needs
    an installer pin from a commit on `main` that has the engine; an older pinned installer ignores
    the switch.
- Owner: decide whether `WinGetClient` becomes the default for SYSTEM runs (an unset variable would
  then mean the module, and `Cli` would be the opt-out). Decide only after
  `e2e-install-system-winget-client` has been green on `main` for several weekly runs in a row (at
  least four, next to a green `e2e-install-system`), and after the Endpoint Central
  pilot (10 to 20 PCs with Windows 10 22H2 and Windows 11, for 2 to 4 weeks) shows no app failing
  that `winget.exe` installs, the same Deferred apps, restarts where expected, and fallbacks
  (`installEngine.fallbackReason`) only where explained. The run time must fit Endpoint Central's
  limit, and the Gallery hosts must be allowed on the fleet. Decide at the same time: the PowerShell
  7.4 floor (a PC with 7.2 or 7.3 falls back, and 7.4 reaches end of support on 2026-11-10; should
  the bootstrap install the current LTS on such PCs?), and whether a module run whose `winget.exe`
  does not start at the end should exit 8 ("apps OK, auto-updates at risk") instead of 2.
- Engine follow-ups: `rmm/Get-WingetFleetHealth.ps1` does not report `last-run.json`'s
  `installEngine` in its `HEALTH:` line yet, so a fleet-wide fallback is not visible. Nothing tells
  the team when the Gallery or the engine moves past 1.29.380 (the E2E pin check is informational).
  Winget-AutoUpdate, the uninstaller (`Uninstall-WinGetPackage` would be the module's form) and the
  `winget download` path of `Install-PowerShellLatest` still use `winget.exe` as SYSTEM. The child
  script cannot run under a Group Policy `AllSigned` execution policy; running it through
  `-Command`, or signing it, would avoid that fallback. A link at `%ProgramData%\winget-app-setup`
  itself is not refused yet: `New-WauStagingDirectory`, which the Winget-AutoUpdate MSI staging
  shares, should refuse or replace one, with a test (the part of review finding F6 left out of
  wgt-gq8.42). Restart codes other than 3010 stay undetected under the engine, since the module
  does not expose a manifest's expected return codes (review finding F4); only the pending-restart
  check catches them.
- Validate the dormant DISM MSIX-provisioning path in `Install-PowerShellLatest` end-to-end on a real Windows 10 machine before PowerShell 7.7 GA makes it load-bearing (as of [#166](https://github.com/J-MaFf/winget-app-setup/issues/166)).
- Cut a tagged release and move the `[Unreleased]` CHANGELOG entries under a versioned heading.

## Prerequisites to Run

- **Windows 10/11** with [App Installer / winget](https://www.microsoft.com/p/app-installer/9nblggh4nns1) available.
- **PowerShell 7+** (`pwsh`) is the installer's runtime — but starting it from Windows
  PowerShell 5.1 works too: the entry dispatch bootstraps PowerShell 7 and relaunches itself
  ([#225](https://github.com/J-MaFf/winget-app-setup/issues/225)).
- Permission to temporarily relax the execution policy for the current process, e.g.:
  ```powershell
  Set-ExecutionPolicy Unrestricted -Scope Process -Force
  ```
- Run the installer: `pwsh -ExecutionPolicy Unrestricted -File .\winget-app-install.ps1` (or the same via `powershell`, which self-bootstraps).
- Run tests: `Invoke-Pester ./tests`.
- Regenerate the installer and the uninstaller after editing the module: `pwsh -File ./build/Build-WingetInstallScript.ps1`.
