# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Real-PC owner-test-plan harness (bead wgt-gq8.60): `e2e/Invoke-RealPcTestPlan.ps1`, one command an
  owner runs as an administrator on a disposable Windows 10 22H2+ or Windows 11 test machine to run
  every automatable item of PR #285's owner test plan and get one PASS/FAIL report plus one zip to
  send back. It starts under Windows PowerShell 5.1, refuses unless elevated and confirmed disposable
  (`-ConfirmDisposableMachine` for unattended use), and `-WhatIf`/`-Plan` prints the plan and changes
  nothing. Stages: preflight; the ProgramData link guard; a first unattended install and its re-run;
  a SYSTEM run through the Endpoint Central machine-phase wrapper (and, with `-IncludeWinGetClient`,
  the Microsoft.WinGet.Client engine); a time-budget run that exits 9 then finishes; the
  `-CollectDiagnostics` bundle (checked for secret leaks); and the uninstaller (preview then real).
  A temporary standard user (random name and password, neither printed) plants the junction from a
  one-shot S4U task. A throwaway TightVNC test password is written only to `manual-steps.txt` in
  `<report folder>-local`, which is never zipped; the harness checks the diagnostics bundle, every
  file going into the zip and the zip itself for it. The installer prints its `was a link` warning
  before its transcript starts, so each run's console output is kept and searched.
  `tests/E2ERealPcTestPlan.Tests.ps1` tests the pure parts (stage/dependency logic, the change plan,
  the gate decision, each stage's check evaluation, the ACL/SDDL comparison, the secret scan, and
  the report and exit-code logic), and `.github/workflows/real-pc-test-plan.yml` self-tests the
  harness end to end on a `windows-latest` runner.
- Endpoint Central deployment in two phases (work-order item 34), in `rmm/`. Both are standalone
  Windows PowerShell 5.1 scripts that need nothing beside them.
  - **Machine phase.** `rmm/Invoke-WingetAppSetup.ps1` is a Computer Configuration script run as
    SYSTEM (success codes 0,3010). It relaunches itself in 64-bit Windows PowerShell through
    Sysnative when the 32-bit agent starts it, downloads `winget-app-install.ps1` from a pinned
    commit into a folder only SYSTEM and Administrators can change, and runs it only when it
    matches a pinned SHA256. It logs to `install-<time>-rmm.log`, runs the installer with
    `-NonInteractive`, and exits with its code unchanged, or 5 when it cannot run it.
  - **User phase.** `rmm/Invoke-WingetAppSetupUserPhase.ps1` is a User Configuration script run at
    every sign-in as the user, never elevated. It ends at once, silently, when there is nothing to
    do. Otherwise, once per machine run, the new `Invoke-WingetUserPhase` installs the apps
    `last-run.json` lists as Deferred with `winget install --scope user` only (the new
    `Install-WingetPackage -UserScopeOnly`) and the catalog entry's `installerType`, runs the entry's
    `postInstall` hook in the user's account, and sets the per-user Windows Terminal defaults
    (`Set-WindowsTerminalDefaults -PassThru`). It updates the winget source for the account first,
    works within a 15-minute budget, tries again at later sign-ins up to 3 times per machine run,
    and logs to `%LOCALAPPDATA%\winget-app-setup\logs`. It uses only a `last-run.json` that SYSTEM
    or Administrators own and no other account can change (`Get-RunRecordTrustProblem`, checked on
    the open file). The summary's Deferred line for per-user catalog apps names the user phase.
  - **Pins.** `build/Set-RmmInstallerPin.ps1 -Commit <commit>` sets the pinned commit and SHA256 of
    both phases, and refuses an installer older than the user phase. The pins ship empty, and both
    phases exit 5 until they are set from a commit on `main`.
  - **E2E.** A third leg, `e2e-install-system`, runs the machine phase as SYSTEM from a 32-bit
    (SysWOW64) `powershell.exe` scheduled task, with the checkout's installer
    (`e2e/Invoke-SystemInstallPass.ps1`). It checks the exit code; the 64-bit relaunch, the SHA256
    check and the exit-code pass-through in the `-rmm.log`; `Auto-updates: Configured` and the
    framework installed once; `last-run.json` and its Deferred entries (each with a package id and
    a reason, matching the summary); and that nothing was installed into SYSTEM's own profile. It
    also checks each catalog app's entry in `last-run.json` against the checkout's catalog, decided
    as SYSTEM (wgt-gq8.45): Installed or already there (Installed for Chrome, 7-Zip and Git, which
    the job removes first, so a removal that failed fails this leg), Skipped with its reason where
    the app does not apply, and Deferred only for per-user work. A missing entry, an entry for an
    app the catalog lacks, or a record that is not schema 1 fails it too. The per-app checks are
    tested against `tests/fixtures/e2e/system-last-run.json`, which follows the catalog. The
    workflow's product paths now include `rmm/**`.
  - Not yet run on a real PC from Endpoint Central.
- `rmm/Get-WingetFleetHealth.ps1` and `rmm/Repair-WauLogonTrigger.ps1`, to push from Endpoint
  Central as SYSTEM (work-order item 36). The probe changes nothing. It reports App Installer
  versions with each account's install state, whether `Microsoft.WindowsAppRuntime.1.8`
  8000.616.304.0 or newer is installed, whether the machine-wide `winget.exe` starts (time-limited,
  and only as SYSTEM: an administrator's run reports `winget=skipped`), Winget-AutoUpdate's task
  (state, triggers, last result) and the telling lines of its `updates.log`. It ends with a
  machine-readable `HEALTH:` line and exits 1 on an unhealthy PC. The fix is for PCs set up before
  the installer stopped adding Winget-AutoUpdate's at-logon trigger: it removes the trigger while
  keeping WAU's schedule, sets `WAU_UpdatesAtLogon` to 0, and reads both back. It supports
  `-WhatIf`, ends with a `REPAIR:` line, and exits 1 when the trigger stays or Group Policy would
  put it back. Both relaunch themselves in 64-bit Windows PowerShell from a 32-bit PowerShell or
  PowerShell 7, and `tests/RmmFleetHealth.Tests.ps1` checks the logic they repeat against the
  module's own functions.
- A diagnostics bundle for failed-run reports (work-order item 35). `-CollectDiagnostics` installs
  nothing and needs neither winget nor elevation. It runs before the PowerShell 7 bootstrap, so it
  works under Windows PowerShell 5.1 too. It writes one .zip (`Invoke-DiagnosticsCollection`,
  `WingetAppSetup/Private/Diagnostics.ps1`) with the latest run's transcripts (the machine phase's
  `-rmm.log` included), installer logs and `last-run.json`; this account's user-phase state and
  logs; the Windows build and architecture, the accounts and elevation style, the execution policy
  and the App Installer, Store and PowerShell Group Policy keys, the pending-restart state, the
  Windows App Runtime this build pins, and Winget-AutoUpdate's install and task; the end of WAU's
  `updates.log`; `winget --version` and `--info` (time-limited); and the App Installer and Windows
  App Runtime packages for every account and provisioned for new ones. Those run in Windows
  PowerShell, started without PowerShell 7's `PSModulePath` (the new
  `Invoke-ExternalProcess -RemoveEnvironmentVariable`). Account, computer and domain names,
  profile folders, the SIDs of real accounts and email addresses are replaced by placeholders, the
  same in every file and whatever the culture, because the issues are public. A bundle made from a
  32-bit PowerShell says that its registry values come from the 32-bit view. It saves to the
  Desktop, or to Public Documents for SYSTEM and cross-user runs. Every failed run (early exits,
  and summaries that exit 1, 2 or 8) prints the command that makes it:
  `& ([scriptblock]::Create((irm "https://raw.githubusercontent.com/J-MaFf/winget-app-setup/refs/heads/main/winget-app-install.ps1"))) -CollectDiagnostics`.
  The install-failure issue form asks for the bundle, the elevation style and the Windows build.
- Environment checks that stop a run legibly before it changes anything (work-order item 39,
  `WingetAppSetup/Private/EnvironmentPreflight.ps1`). No new exit codes.
  - Constrained Language Mode (an App Control for Business or AppLocker policy) stops the run at
    once with exit code 5 and one line, before the PowerShell 7 bootstrap, and still prints the
    `RESULT: exit=5 ... log=none` line, from Windows PowerShell 5.1 too. The run used to die later
    with PowerShell's own errors and an `UNEXPECTED ERROR`.
  - A Group Policy execution policy of `AllSigned` or `Restricted` overrides the
    `-ExecutionPolicy Bypass` the installer relaunches itself with. It now stops the PowerShell 7
    relaunch with exit code 7, before PowerShell 7 is installed, and the elevated relaunch with
    exit code 4 and no UAC prompt when it is set for the PC. The elevated window checks the policy
    of the account that approved the prompt: under `AllSigned` or `Restricted` it says so, waits
    for Enter and exits 4, instead of closing at once with exit code 1. As in PowerShell, a run
    that a Group Policy startup or logon script (`gpscript.exe`) started is not stopped for it.
  - `Invoke-EnvironmentPreflight` runs after the elevation gate and before the Winget-AutoUpdate
    wait. It warns about a proxy the signed-in user has and the run's account (SYSTEM, or another
    admin) does not, reports a restart that is already pending (the warning moved here), and stops
    with exit code 2 when App Installer's Group Policy turns winget off
    (`Write-WingetPolicyBlockMessage`), now before the Winget-AutoUpdate wait.
  - `-WhatIf` runs every check and says what a real run would do. Exit codes 2, 4, 5 and 7 read the
    same in the early-exit notice, the issue form and the readme.
- Declarative catalog entry fields (work-order item 38), checked by `Test-AppDefinitions` before a
  run uses them (a wrong value stops the run with exit code 3 and names the entry; a field the
  schema does not know is a warning), in `WingetAppSetup/Private/CatalogSchema.ps1`:
  - `scope`: `any` (default, the behaviour so far), `machine` (machine scope only, in every run: a
    package with no machine-wide installer fails with `no machine-scope installer applies to this
    PC, and its catalog entry allows only a machine-wide install (scope 'machine')` instead of
    being installed per-user or deferred, and the retry pass does not try it again) or `user`
    (`--scope user`; `Install-WingetPackage -Scope`). The scope is how the installer installs an
    app: an app `winget list` already shows, at either scope, is skipped as already installed.
  - `arch`: the OS architectures the app is for (`X86`, `X64`, `Arm`, `Arm64`), decided by
    `Test-AppApplicability` with `Get-OSArchitecture` together with the condition, once per run and
    fail open (`Architecture check for <id> failed (...); treating its arch list as met ...`). The
    skip line uses `conditionDescription`, or says `for <list> Windows only; this PC is <arch>`
    (`Get-AppNotApplicableReason`, now also used for condition skips and by the uninstaller).
  - `userPhase`: per-user apps and settings. As SYSTEM and under cross-user elevation, `userPhase`
    and `scope = 'user'` apps are `Deferred` before any winget call, with
    `per-user setup (catalog userPhase): ...` or `per-user app (catalog scope 'user'): ...` as the
    reason on the app's line and in `last-run.json`, and their own explanation under the summary
    (`Write-DeferredAppsSummary -PerUserApps`); any other run installs them as usual.
  - `postInstall`: a scriptblock or function name that configures the app once it is installed
    (after the install is verified, and on every run that finds it installed; never in a dry run).
    It returns `Configured`, or `NotConfigured` or `Failed` with a reason (`Invoke-AppPostInstall`,
    `ConvertTo-AppPostInstallResult`). The run prints `Configured: <id>` or
    `Not configured: <id> (<reason>)`; a failed or throwing hook makes the app `Failed`
    (`installed, but its post-install configuration failed (<reason>)`, exit code 1, retried once;
    the install's restart and exit code stay with the app, and an app that was already installed
    stays `Skipped` when the retry pass configures it), while `NotConfigured` leaves the exit code
    alone and adds a `Configuration: NOT DONE for <id> (<reason>) - ...` line under the summary.
    Each app's entry in `last-run.json` gains `postInstall` and `postInstallReason`. The build's
    catalog reference guard (`Get-UndefinedCatalogInstallReference`) now checks a `postInstall`
    function name as it checks `install`. The first catalog app with a hook is `GlavSoft.TightVNC`
    (see Fixed).
- The Winget-AutoUpdate gate now checks for the Windows App Runtime the winget release WAU installs
  actually needs, instead of only the constant `Microsoft.WindowsAppRuntime.1.8 >= 8000.616.304.0`
  (work-order item 32, product-F4). WAU's `Install-Prerequisites` installs the latest winget-cli
  release, so a winget that moved to a newer build or another framework family would have passed
  the gate on a PC with the 1.8 framework and then left winget unusable after WAU's next run.
  `Get-WindowsAppRuntimeRequirement` (`WingetAppSetup/Private/WauSupport.ps1`) reads the latest
  release's `DesktopAppInstaller_Dependencies.json` through
  `https://github.com/microsoft/winget-cli/releases/latest/download/DesktopAppInstaller_Dependencies.json`
  (the release WAU's `api.github.com` query names, without the API's 60-calls-an-hour limit) with a
  30-second limit (new operation `WebLookup` in `Get-ProcessTimeoutSeconds`,
  `Get-WebDownloadTimeoutParameters -Lookup`), and `ConvertFrom-WingetDependenciesJson` takes its
  `Microsoft.WindowsAppRuntime*` entries (a list per architecture is read too, for the PC's). When
  the file cannot be read or lists no Windows App Runtime, the run warns and checks for the
  built-in requirement (`Get-DefaultWindowsAppRuntimeRequirement`); the lookup never stops a run.
  The warning gives the error's message on one line of at most 300 characters (for an HTTP error,
  its status line, not the page a proxy or GitHub sent with it). `Get-WindowsAppRuntimeStatus
  -Requirement` checks every framework the requirement names, by
  package name (`Get-WindowsAppRuntimePackageInfo -Name`, which accepts only package-name
  characters because the name goes into the Windows PowerShell query), so a newer family never
  satisfies a dependency on 1.8, and returns the ones this PC lacks as `Missing`.
  `Install-WindowsAppRuntimeFramework -Requirement -MissingFrameworks` installs nothing
  when the pinned framework (`Get-WindowsAppRuntimePin`, now with `FrameworkName`) does not meet
  every framework the PC lacks (one it already has does not count), with
  `Windows App Runtime: NOT INSTALLED - the latest winget release needs ...,
  and the framework this installer installs, ..., does not meet that; a newer version of this
  installer is needed`; WAU is then skipped (`NOT CONFIGURED`) or reported `AT RISK`, and the run
  exits 8, unless the PC already has what winget needs. `Install-WingetAutoUpdate` returns the
  missing framework as `FrameworkName`, and the summary's `NOT CONFIGURED` and `AT RISK` lines name
  it (unchanged text for 1.8). `-WhatIf` does not look anything up. `e2e/Invoke-InstallPass.ps1`
  fails an exit 8 whose transcript shows that refusal, for a newer 1.8 build or another family
  alike (`e2e/TranscriptAssertions.ps1` reads it as `WindowsAppRuntimePinStale`), so the weekly run
  goes red when the pin has to move. Fixtures:
  `tests/fixtures/winget-dependencies` (the files of v1.29.380, v1.12.350 and v1.11.510, and a
  made-up file with a list per architecture).
- When `Microsoft.WindowsAppRuntime.1.8` is missing, the installer now installs a pinned, verified
  copy for every user of the PC before it sets up Winget-AutoUpdate (work-order item 31, finding
  R13-3). A freshly imaged PC, one whose Microsoft Store updates are blocked, and Windows Server lack
  the framework until something installs it, so such a run used to end with
  `Auto-updates: NOT CONFIGURED` and exit code 8 and needed a re-run once the Store had updated App
  Installer. `Install-WindowsAppRuntimeFramework` (`WingetAppSetup/Private/WindowsAppRuntime.ps1`)
  downloads `Microsoft.WindowsAppSDK.Runtime` 1.8.260921001 (Windows App Runtime 1.8.12, framework
  8000.994.2142.0) from NuGet.org into a folder limited to SYSTEM and Administrators, takes the
  framework `.msix` for the PC's architecture (x64, x86 or ARM64) out of it, checks its pinned size
  and SHA256 (`Get-WindowsAppRuntimePin`) and its Authenticode signature (`Microsoft Corporation`),
  keeps it open from the hash until it is provisioned, provisions it with
  `Add-AppxProvisionedPackage -Online -SkipLicense` in Windows PowerShell with a 10-minute limit
  (`Invoke-AppxProvisioning -TimeoutSeconds`, new operation `AppxProvisioning` in
  `Get-ProcessTimeoutSeconds`), and then checks again with `Get-WindowsAppRuntimeStatus` (and
  `Get-AppxProvisionedPackage`, which only warns). It runs on a first install and on a re-run that
  finds WAU already installed, which is then no longer `AT RISK`. It installs nothing when the run
  is not elevated, on 32-bit Arm or a Windows build older than 17763, over a provisioned framework
  of the same or a newer version, or when the all-users check could not run, and it never uses
  `Repair-WinGetPackageManager -AllUsers` (#265). The whole 150 MB package is downloaded rather than
  a byte range of it: the framework's offset moves when NuGet re-signs the package, and a proxy can
  ignore a range request. A failed install is not remembered, so until one succeeds every run on
  that PC downloads the package again. `Microsoft.WindowsAppSDK.Runtime` is the developer package,
  published under the Windows App SDK license terms for developers, not one of the end-user runtime
  installers Microsoft documents for redistribution. When the check after provisioning cannot run,
  the install counts as done, with a warning, and WAU is set up, as on any run where that check
  cannot run. The transcript gets a `Windows App Runtime: installed ...` or
  `Windows App Runtime: NOT INSTALLED - <reason>` line; when the install fails, WAU is skipped as
  before, exit code 8, and the summary's `Auto-updates:` line is followed by the reason. `-WhatIf`
  previews it. `New-WauStagingDirectory` takes a `-Prefix` for the folder name.
  `Invoke-ExternalProcess` takes an `-Encoding` for the program's output (default UTF-8, which
  winget writes); the time-limited Windows PowerShell child of `Invoke-AppxProvisioning` is read in
  `[Console]::OutputEncoding`, the console code page Windows PowerShell writes redirected output in,
  so a localized DISM error keeps its non-ASCII letters in the transcript. That child starts without
  PowerShell 7's `PSModulePath` (`-RemoveEnvironmentVariable`), so Windows PowerShell loads its own
  modules.
  - **E2E.** `windows-latest` ships without the framework, so both passes there are now expected to
    install it (first pass) and set up Winget-AutoUpdate, and to exit 0. `e2e/Invoke-InstallPass.ps1`
    accepts exit 8 for the missing framework only when the installer could not try to install it
    (not elevated, an unsupported Windows build or architecture, or a framework already
    provisioned), and its message then quotes the transcript's `Windows App Runtime:` line. An
    install that started and failed (download, checks or provisioning) fails the pass, so a broken
    framework install turns the run red instead of passing as a skipped WAU.
    `e2e/TranscriptAssertions.ps1` reads that line (`WindowsAppRuntimeLine`,
    `WindowsAppRuntimeInstalled`) and whether the install started (`WindowsAppRuntimeAttempted`),
    quotes the line in the `NOT CONFIGURED` detail, and `-ExpectAllSkippedOnSecondRun` adds the
    check that the second pass did not install the framework again. New fixtures
    `first-pass-runtime-installed` and `second-pass-runtime-present`.
  - The bead's first idea, starting the Store's App Installer update and waiting for it, is not
    done: the pinned install covers Store-blocked PCs and Windows Server too, and the Store update
    can take hours.
  - Checked by the E2E runs on the Windows Server 2025 runner, in all three legs: the signature
    check passes under PowerShell 7, `Add-AppxProvisionedPackage` reads the file the installer holds
    open, and the framework and WAU are installed. Not yet checked on a real PC: whether
    provisioning the framework on its own registers it for accounts that sign in later, and on
    Windows 10 and Windows 11.

- A whole-run time budget for RMM jobs (wgt-gq8.41, deferred from review finding P3-42), so a job
  with a hard time limit ends with a report instead of being killed mid-run. `-MaxRuntimeMinutes`
  (1 to 1440) sets it, or `WINGET_APP_SETUP_MAX_RUNTIME_MINUTES` for the one-liner
  (`Resolve-InstallerRunBudget`, `WingetAppSetup/Private/RunBudget.ps1`); a `-MaxRuntimeMinutes 0`
  that is given turns off the variable's budget. The clock starts with the script, before the
  PowerShell 7 bootstrap, and the deadline goes on the command line to the PowerShell 7 run and the
  elevated window (`-RunDeadlineUtc`, internal). `rmm/Invoke-WingetAppSetup.ps1` takes
  `-MaxRuntimeMinutes` too and counts from its own start, before its 64-bit relaunch; with 0, its
  default, it passes nothing on. Once the budget is used up, the run starts no app install, retry or
  Winget-AutoUpdate setup (the Windows App Runtime install included). It reports the apps left as
  `NotAttempted` (a `Not attempted` summary row, `notattempted=` in the `RESULT` line,
  `counts.notAttempted` in `last-run.json`) and the WAU setup as `Auto-updates: NOT ATTEMPTED`,
  prints `Time budget: USED UP ...`, and exits with the new code 9 (precedence
  1 > 2 > 9 > 8 > 3010 > 0). A retry it does not start leaves its app failed. Apps that do not
  apply are still skipped, and per-user apps in a run for the whole PC still deferred. The waits for
  a busy Windows Installer last no longer than the budget had left when the step started, the wait
  for a Winget-AutoUpdate run in progress never lasts past the deadline, and a dry run shows the
  budget without being cut short. The issue form and the readme explain exit code 9, which is not a
  success code: the readme says to set the budget about 45 minutes below the RMM tool's limit.

- RMM runs get a non-interactive switch for the one-liner, one run at a time, a machine-readable
  result and log retention (review findings P3-41, P3-42).
  - **`WINGET_APP_SETUP_NONINTERACTIVE`.** `1`, `true` or `yes` turns on non-interactive mode, for
    the `irm | iex` one-liner, which cannot pass `-NonInteractive` (`Test-NonInteractiveRequested`).
    The PowerShell 7 run the 5.1 bootstrap starts inherits it, and the uninstaller reads it too.
  - **Exit code 6.** A real, elevated run takes the machine-wide `Global\winget-app-setup-run`
    mutex (`Lock-InstallerRun`) before its pre-flight checks. A run started while another one
    holds it exits 6 at once, without waiting for that run or stopping it. The lock is released
    before any key-press prompt, so a window left open does not block the next scheduled run.
  - **`RESULT` line and `last-run.json`.** Every real run prints
    `RESULT: exit=... installed=... skipped=... deferred=... failed=... notattempted=... autoupdates=... restart=... build=... log=...`
    after its summary or early-exit notice (`Format-InstallerResultLine`). The run that holds the
    lock writes `%ProgramData%\winget-app-setup\logs\last-run.json` (`schemaVersion` 1: build id,
    start and end UTC, exit code, counts with `deferred` and `notAttempted`, per-app status, reason
    and exit code, auto-update status, restart flag, end-of-run winget check, transcript path),
    through a temporary file and a replacing move. It writes the file once when it takes the lock,
    with `exitCode` null, so a killed run no longer leaves the previous run's record, and again
    however it ends. `wingetUsable` is null when the end-of-run check did not run or could not
    complete.
  - **Retention.** The run that holds the lock keeps the newest 30 transcripts and the `winget-*`
    and `pwsh-msi-*` logs of their runs (`Invoke-InstallerHousekeeping`), and removes the
    installer's temporary copy folders once they are a day old, only from `%SystemRoot%\Temp` (and
    SYSTEM's temp folders for a SYSTEM run) and only when SYSTEM or Administrators owns them. The
    5.1 bootstrap now deletes its `irm | iex` relaunch copy when the PowerShell 7 run ends.
  - The whole-run time budget came later (`-MaxRuntimeMinutes`, above).

- Runs as SYSTEM are supported for the apps that install for the whole PC (review findings P2-24,
  P3-23, P3-24). An RMM agent such as ManageEngine Endpoint Central runs scripts as SYSTEM, which
  has no winget of its own (winget is a per-user packaged app that cannot be registered for
  SYSTEM), so such a run registered, repaired and downloaded App Installer for minutes and then
  stopped with exit code 2. `Invoke-WingetInstall` now reads once who it installs as
  (`Get-InstallAccountContext`, built on `Test-IsSystemAccount`), and as SYSTEM:
  `Test-AndInstallWinget` finds the `winget.exe` that App Installer installed for the PC
  (`Get-AppxPackage -AllUsers`, status `Ok`, newest version as a version, the PC's architecture
  first; the `WindowsApps` folder when that query fails or finds none, leaving out any package the
  query listed with another status) and checks that it starts, trying the next one if not (at once
  after `0xC0000135`, which `Test-WingetLaunchable` no longer checks again), and
  `Resolve-WingetExecutable` hands its full path to every winget call; every step that sets winget
  up for one account is skipped (registering App Installer, `Repair-WinGetPackageManager` and the
  `Microsoft.WinGet.Client` install, the aka.ms/getwinget download, registering the winget source
  package); the run is always non-interactive
  (`Test-EffectiveNonInteractive`); Windows Terminal's #271 console check does not apply, and
  Terminal counts as installed when it is provisioned for every user (`msixName` in the catalog,
  `Test-AppxPackageProvisionedForMachine`), where `winget list`, which sees no user's MSIX apps as
  SYSTEM, made it fail on every run; and the messages no longer call SYSTEM a cross-user elevation
  or advise signing in to Windows as `NT AUTHORITY\SYSTEM`, and the Windows PowerShell 5.1
  bootstrap says SYSTEM has no winget command instead of that winget is not on the PC. When no
  machine-wide `winget.exe` starts, the run exits 2 and says why. `0xC0000135 STATUS_DLL_NOT_FOUND`
  now has a name in the exit-code table, with a hint about the Visual C++ runtime for SYSTEM. Microsoft does not support
  the winget command line as SYSTEM; moving SYSTEM runs to its `Microsoft.WinGet.Client` module is
  a follow-up. Checked as SYSTEM only by the E2E run's SYSTEM leg on Windows Server 2025 (see the
  Endpoint Central entry), not yet on a Windows 10 or Windows 11 PC. (Since changed: a run as
  SYSTEM can opt in to the module; see the next entry. `winget.exe` stays the default.)

- An opt-in `Microsoft.WinGet.Client` install engine for runs as SYSTEM (wgt-gq8.42). Microsoft
  documents the winget command line as unsupported in the system context, and this module as the
  supported route there. Set `WINGET_APP_SETUP_SYSTEM_ENGINE=WinGetClient`, or run
  `rmm/Invoke-WingetAppSetup.ps1 -SystemInstallEngine WinGetClient`, which sets the variable for the
  installer and restores it afterwards. `Cli`, unset or empty keeps `winget.exe`, the default. Any
  other value is warned about and means `Cli`, and a run that is not SYSTEM ignores the variable
  and says so.
  - **The module.** `Initialize-WingetClientModule` (`WingetAppSetup/Private/WingetClientModule.ps1`)
    downloads Microsoft.WinGet.Client 1.29.380 as its `.nupkg` straight from the PowerShell Gallery,
    never through `Install-Module`. It checks the size and SHA256 pinned in
    `Get-WingetClientModulePin`, the package's own id and version, and a valid Microsoft Corporation
    signature on the module's manifest, cmdlet and engine files. It extracts only the PowerShell 7
    build and this process's engine, from the same locked handle it hashed, into a new
    `%ProgramData%\winget-app-setup\wingetclient-<id>` folder that only SYSTEM and Administrators
    can change, and removes the folder when the run ends; housekeeping removes one a killed run
    left once it is a day old. The checked package is cached in
    `%ProgramData%\winget-app-setup\cache` and hashed again on every use. It needs PowerShell 7.4
    or later, an x64, x86 or Arm64 process, Windows build 17763 or later, and
    `www.powershellgallery.com` and `cdn.powershellgallery.com` on port 443.
  - **The engine.** `WingetAppSetup/Private/WingetClientEngine.ps1` runs every module call in a
    child `pwsh` under `Invoke-ExternalProcess`, so each has a time limit and a hung call is stopped
    with what it started (new `Get-ProcessTimeoutSeconds` operations: `WingetClientProbe` 3
    minutes, `WingetClientVersion` 60 seconds, `WingetClientListCheck` 45 seconds; installs keep 30
    minutes). A probe (`Get-WinGetVersion` and one `Get-WinGetPackage`) must answer first. The
    installed checks are `Get-WinGetPackage`, and installs are
    `Install-WinGetPackage -Source winget -MatchOption Equals -Scope System -Mode Silent` with an
    installer log. `Get-WingetClientResultCode` maps every result onto the winget result code
    `winget.exe` would have returned, so deferral, retries, the circuit breaker, restarts and
    failure reasons work as before. The module prints no restart message, so a restart is the
    installer's own exit code 3010.
  - **Fallback.** When the module is not ready (no Gallery, a size, hash or signature mismatch,
    PowerShell older than 7.4, a failed probe), the run prints
    `WinGet client module: NOT READY - <reason>.`, installs with `winget.exe` as before, and says
    why next to the summary and in `last-run.json`. The exit code does not change. With the module
    ready, a machine-wide `winget.exe` that does not start is a warning instead of exit code 2,
    because the installs no longer need it (Winget-AutoUpdate still does); the end-of-run check is
    unchanged. The winget
    source update and reset are skipped then. Winget-AutoUpdate, the uninstaller and the
    `winget download` path of `Install-PowerShellLatest` keep using `winget.exe`.
  - **Pin and E2E.** `build/Set-WingetClientModulePin.ps1` checks the pin against the Gallery
    (`-Check`, exit 1 on a mismatch) or moves it (`-Write`). A fourth E2E leg,
    `e2e-install-system-winget-client`, runs the SYSTEM pass twice through the machine phase with
    the engine. It fails unless the module was ready at its pin and installed every app the job
    removed, `winget list` as the runner account finds those apps, and the second pass takes the
    module from the cache and finds every app present. It runs the pin check first, without
    failing on it, and collects the engine's `WinGetCOM-*.log` files with the diagnostics. A probe
    on the hosted runner (Windows Server 2025, PowerShell 7.6) loaded the module as SYSTEM, listed
    and installed a package with it; the new leg passed on its first run.

- The E2E install also runs from Windows PowerShell 5.1, in a second job,
  `e2e-install-windows-powershell` (review finding P3-40). Every step there uses
  `shell: powershell`, and PowerShell 7 is removed first, so the first pass goes through the
  bootstrap that installs PowerShell 7 and relaunches the installer, as on a fresh PC, and the
  second pass finds PowerShell 7 and relaunches.
  `e2e/Assert-Install.ps1 -ExpectPowerShell7Bootstrap -ExpectPowerShell7Installed` checks that
  every pass went through the bootstrap and that the first one installed PowerShell 7. On checkout
  runs, the bootstrap's download of raw `main` for the relaunch is answered with the checkout by an
  `Invoke-RestMethod` shim that lives only in the Windows PowerShell process, and the build-id
  check covers the `-bootstrap` transcripts too. Both legs first uninstall the Chrome, 7-Zip and
  Git that the runner image ships with (`e2e/Remove-PreinstalledApps.ps1`), so the first pass
  really installs them; every call there has a time limit, and an app that cannot be removed only
  gets a warning. The new `e2e/Invoke-InstallPass.ps1` starts every pass in both legs and holds the
  exit-code policy the step scripts used to repeat: 0 and 3010 (OK, restart required) pass, and 1
  passes only while `KNOWN_PLATFORM_INCOMPATIBLE` is non-empty. The weekly run now runs the
  readme's one-liner verbatim (`Set-ExecutionPolicy` and the `refs/heads/main` URL), and a test
  fails if the two drift apart. `report-failure` covers both legs, one section each, and shows the
  latest 5.1 bootstrap transcript in a section of its own. A Winget-AutoUpdate leg (starting
  WAU's task and checking that winget still starts) is not added yet; `windows-latest` lacks
  `Microsoft.WindowsAppRuntime.1.8`, which the installer now installs itself (see above).
- Diagnosed the 0x80073CF3 "depends on a framework that could not be found" AppX rejection distinctly (issue #279): `Test-AppxMissingFrameworkDependency` (`WingetAppSetup/Private/WingetBootstrap.ps1`) mirrors the existing `Test-AppxDowngradeRejection` (0x80073D06) classifier — it requires the 0x80073CF3 HRESULT together with the missing-framework phrasing or the specific `Microsoft.WindowsAppRuntime.1.8` name, so it stays narrow to the signature two independent GitHub-hosted E2E runs actually reproduced rather than over-matching every 0x80073CF3 (a broad "dependency or conflict validation" code reused for unrelated conflicts). `Invoke-WingetPackageManagerRepair` now returns a parallel `MissingFrameworkDependency` flag in its result hashtable and short-circuits its `-Force` retry the same way it already does for `DowngradeRejected` — retrying cannot conjure a framework that genuinely is not on the machine. `Initialize-WingetSourcesForUser` (`WingetAppSetup/Public/WingetCore.ps1`) surfaces a dedicated remediation warning naming the missing framework and linking to issue #279. This is purely diagnostic/fail-fast — it does not attempt to install the missing framework itself, since there is no verified redistributable for it to deploy safely. Pinning `e2e-install`'s runner off `windows-latest` to `windows-2022` was tried as a workaround for #279 and reverted in the same PR: that pin's own self-validating run failed every catalog app immediately with "No applicable app licenses found" — a distinct, total failure worse than #279's slow partial one, filed separately as issue #282. `e2e-install` stays on `windows-latest`; both issues remain open pending a viable runner target. A third distinct `e2e-install` failure surfaced on this PR's own re-validation run: the first install pass completed cleanly and then an uncaught `Start-Process` error ("The file cannot be accessed by the system") crashed the whole script under 5 minutes later, most likely inside `Wait-WingetLaunchable`'s post-WAU-install probe even though its try/catch appears to cover that call — filed as issue #283 rather than patched blind, since `e2e-install` isn't a required merge check and the root cause needs a real Windows repro to confirm. (Superseded on this branch: the wedge came from the Winget-AutoUpdate run that the installer's own `RUN_WAU=YES` started, and #283 most likely from that run upgrading PowerShell under the running installer; see the `RUN_WAU=YES` entry under Fixed. `Test-AppxMissingFrameworkDependency` and `Wait-WingetLaunchable` are removed (see Removed), and the installer now installs a pinned, verified `Microsoft.WindowsAppRuntime.1.8` when it is missing (see Added). #282 is still open.)
- The PS7 bootstrap's terminal failure message now recognizes a GitHub-wide 429 throttle (issue #274): `Test-GitHubRateLimitError` (`WingetAppSetup/Private/PowerShell7Bootstrap.ps1`) matches "429"/"Too Many Requests" in the caught error text from the `raw.githubusercontent.com` metadata read and the `aka.ms/install-powershell.ps1` fallback — both of which independently depend on GitHub, so a machine already throttled loses them together. When either sets the flag, the final "PowerShell 7 could not be installed automatically" message explains the shared-throttle cause and suggests `winget source reset --force` (which does not depend on GitHub) instead of just repeating the generic manual-install instructions.
- Documented a jsDelivr CDN mirror fallback in readme.md for the one-line bootstrap, for when `raw.githubusercontent.com` throttles a shared/corporate NAT egress IP with `429: Too Many Requests` (issue #272).
- The installer now bootstraps PowerShell 7 when started from Windows PowerShell 5.1 (issue #225) instead of failing fast with manual instructions (#210 behavior): the new 5.1-runtime-safe `Invoke-PowerShell7Bootstrap` (`WingetAppSetup/Private/PowerShell7Bootstrap.ps1`) finds an existing `pwsh` (PATH, then `%ProgramFiles%`/`%ProgramW6432%`/WindowsApps for stale-PATH, 32-bit-host, and MSIX cases) or installs it — winget with agreement flags first, the official `aka.ms/install-powershell.ps1` MSI script as fallback, with interactive consent and a non-admin UAC warning — then relaunches the installer under `pwsh -NoProfile -ExecutionPolicy Bypass` in the same console, forwarding `-WhatIf`/`-NonInteractive`/`-SkipSystemCheck` and propagating the child's exit code. File-based runs relaunch `$PSCommandPath`; `irm | iex` runs re-download the installer into a unique GUID-named temp directory (the in-memory text is unrecoverable under `iex`; the unique directory prevents pre-planting and concurrent-run collisions), which also makes the previously dead-end "iex + non-admin" case self-elevatable. `-WhatIf` without PowerShell 7 present previews the bootstrap and exits 0 without installing anything. Hardened per the adversarial review: every discovered candidate is validated by execution (`Test-PowerShell7Executable` requires `PSVersion.Major >= 7`, rejecting EOL PowerShell 6.x and the 0-byte WindowsApps alias of a broken MSIX — either would otherwise relaunch-loop or false-succeed), a `WINGET_APP_SETUP_PS7_BOOTSTRAP` sentinel fails a re-entered dispatch fast, and a failed `pwsh` launch returns exit 1 instead of the `exit ($null)` = 0 false success 5.1's non-terminating `Start-Process` errors would produce. Covered by a mocked unit suite (`tests/PowerShell7Bootstrap.Tests.ps1`) plus real `powershell.exe` 5.1 integration tests: a poisoned-env `-WhatIf` preview that runs everywhere, and an opt-in live relaunch (`$env:WINGET_APP_SETUP_RUN_51_RELAUNCH_TEST = '1'`) that drives the machine's real pwsh end-to-end.
- Added manufacturer-aware applicability gating to the app catalog (issue #217): `Get-DefaultAppCatalog` entries can declare an optional `condition` scriptblock plus a human-readable `conditionDescription`, evaluated by `Install-AppWithVerification` before any winget probe on both install passes (including `-WhatIf`). A falsy condition reports the app as `Skipping: <id> (not applicable: <reason>)` in the existing Skipped summary bucket; a throwing condition fails open (warns and installs) so a broken probe can never silently drop an app. `Dell.CommandUpdate.Universal` is gated on `(Get-ComputerManufacturer) -match 'Dell'` (`Dell hardware only`) via the new private CIM seam `Get-ComputerManufacturer`, so non-Dell machines skip it instead of failing its Server-incompatible .NET Desktop Runtime dependency ([#220](https://github.com/J-MaFf/winget-app-setup/pull/220)). (Since changed: it is also limited to x64 Windows, with the reason `Dell hardware with x64 Windows only; winget has no ARM64 installer for it`; see the `arch` entry under Changed.)
- Retired the e2e workflow's `KNOWN_PLATFORM_INCOMPATIBLE` skip-list entry for Dell Command Update and restored strict exit-0 install passes (an empty list makes the tolerate-exit-1 branches inert; the containment machinery stays for future runner-only incompatibilities), and made `e2e/Assert-Install.ps1` condition-aware: it evaluates each catalog condition on the machine under test (same fail-open rule), asserts applicable apps as before, and asserts not-applicable apps show their `not applicable` skip line in the latest transcript instead of being expected as installed ([#220](https://github.com/J-MaFf/winget-app-setup/pull/220)). (Since changed: it decides applicability with the module's own `Test-AppApplicability`, `arch` lists included; see Changed.)
- Added a scheduled end-to-end install run on GitHub-hosted `windows-latest` runners (e2e tier 1, issue #214): `.github/workflows/e2e-install.yml` installs the curated catalog for real twice — weekly (Mondays 06:00 UTC) and on manual dispatch via the production `irm <raw main> | iex` path, on e2e-machinery pull requests via the checkout's installer so those changes validate themselves pre-merge — asserting exit 0 both times (the second pass proves idempotence), always uploading the `%ProgramData%` transcripts as an artifact, and, for scheduled/dispatched failures, creating-or-commenting a deduplicated `E2E install run failed` issue with the run URL and transcript tail ([#216](https://github.com/J-MaFf/winget-app-setup/pull/216)).
- Added the shared post-install assertion script `e2e/Assert-Install.ps1` (reused by e2e tier 2, issue #215): verifies every `Get-DefaultAppCatalog` app via `winget list --exact --id` classified by immediately-captured `$LASTEXITCODE`, the `\WAU\Winget-AutoUpdate` scheduled task, the installed WAU version against `Get-WauPin` at the pin's precision (the WAU MSI registers a DisplayVersion with an extra build segment), and the transcript's presence plus `Installer build` stamp; `-ExpectAllSkippedOnSecondRun` adds the idempotence assertions and `-SkipApps` is a documented, issue-referenced escape hatch for runner-platform incompatibilities. Prints a per-assertion PASS/FAIL table and exits nonzero listing failures ([#216](https://github.com/J-MaFf/winget-app-setup/pull/216)).
- Added a local pre-commit drift check (`.githooks/pre-commit`, one-time `git config core.hooksPath .githooks` setup) that runs the build's `-Check` when module/build files are staged, and documented the full 8-guard stack behind the generated-installer drift guarantee in readme.md ([#213](https://github.com/J-MaFf/winget-app-setup/pull/213)).
- Persistent transcript logging (issue #189): the generated installer's dispatch is wrapped in `Start-Transcript`/`Stop-Transcript` (try/finally) writing to `%ProgramData%\winget-app-setup\logs\install-<yyyyMMdd-HHmmss>.log` (`-whatif` suffix for dry runs), so a failed install on a remote user's machine finally leaves an artifact; ProgramData — not the elevating account's `%TEMP%` — so the log survives cross-user elevation. The path prints at startup and again next to the final summary, and any transcript failure downgrades to a warning — logging never blocks an install ([#207](https://github.com/J-MaFf/winget-app-setup/pull/207)).
- Content-derived installer build id (issue #189): `build/Build-WingetInstallScript.ps1` stamps `<psd1 ModuleVersion>+<first 8 hex chars of the SHA256 of the LF-normalized assembled functions section>` into the generated banner and a `$script:InstallerBuildId` variable logged at startup, so a transcript identifies exactly which installer build produced it. Derived from content only — never git metadata or build time — so rebuilding the same tree stays byte-identical and the CI `-Check` byte-compare keeps passing (guarded by a new build-twice determinism test) ([#207](https://github.com/J-MaFf/winget-app-setup/pull/207)).
- Surfaced winget exit codes in install failures (issue #189): both `Invoke-WingetInstall` call sites now consume the `Install-AppWithVerification` result they previously discarded with `[void](...)` — failure messages read `Failed to install: X (package not found after install; winget exit 0x80073D19, 3 attempts, machine-scope fallback: no).` via the new private `Format-InstallFailureReason`, failed apps are tracked as `@{ Name; Reason }` objects, and `Write-FailedAppsSummary` renders a per-app App/Reason table under the installation summary. Bucket counting and the documented 0/1/2/3 exit-code contract are unchanged ([#207](https://github.com/J-MaFf/winget-app-setup/pull/207)).
- Surfaced the Winget-AutoUpdate outcome in the installer's final output (issue #186): `Install-WingetAutoUpdate` now returns a structured result (`Status` = `Configured` / `AlreadyPresent` / `Failed` / `DryRun`, plus `Version`) instead of a bool that `Invoke-WingetInstall` discarded with `[void]`, and an `Auto-updates: Configured (vX) / Already present (vX) / FAILED` line prints right after the summary table — so a machine that finishes with no update mechanism is no longer visible only as a scrolled-past warning. The documented 0/1/2/3 exit-code contract is deliberately unchanged ([#203](https://github.com/J-MaFf/winget-app-setup/pull/203)).
- Made installer re-runs the WAU upgrade vehicle (issue #186): because `DISABLEWAUAUTOUPDATE=1` pins deployed machines, a bumped `Get-WauPin` previously only ever reached brand-new installs (`Install-WingetAutoUpdate` short-circuited on `Test-WauInstalled` with no version comparison). The installed WAU version is now read from the registry and, when older than the pin, the pinned MSI runs anyway (msiexec upgrades in place and re-applies the standard configuration); equal, newer, or unreadable versions leave the existing install untouched — no downgrades ([#203](https://github.com/J-MaFf/winget-app-setup/pull/203)).
- Wired `build/Build-WingetInstallScript.ps1 -Check` into the Windows CI workflow (`.github/workflows/windows-tests.yml`) so every push and pull request verifies the generated `winget-app-install.ps1` is byte-for-byte in sync with the `WingetAppSetup` module and passes the undefined-reference guard; drift now fails CI instead of shipping silently ([#156](https://github.com/J-MaFf/winget-app-setup/issues/156), [#157](https://github.com/J-MaFf/winget-app-setup/pull/157)).
- Added `STATUS.md` describing the project's purpose, components, resolved/open issues, next steps, and prerequisites, per repository conventions (#136).
- Refactored the 2,100-line `winget-app-install.ps1` into a reusable `WingetAppSetup` PowerShell module (`WingetAppSetup/Public` + `WingetAppSetup/Private`, with a `.psd1` manifest). The distributable single-file `winget-app-install.ps1` is now generated from the module by `build/Build-WingetInstallScript.ps1`, preserving the `irm | iex` one-liner workflow ([#106](https://github.com/J-MaFf/winget-app-setup/issues/106)).
- `winget-app-uninstall.ps1` and `Update-InstalledApps.ps1` now consume the `WingetAppSetup` module instead of carrying their own copies of the logging, table, config, and update-report functions. `Install-UpdateHelperScript` deploys a copy of the module into `%APPDATA%` next to the scheduled-update helper so it remains importable when the task runs without the repository present ([#110](https://github.com/J-MaFf/winget-app-setup/issues/110)).
- Documented the repository's commit, PR, and metadata rules plus working GitHub CLI commands for labels and assignees inside `.github/copilot-instructions.md`.
- Added automatic detection and repair of broken or missing winget package sources (#66).
- Added automated Windows Terminal post-install configuration to set PowerShell 7 as the default profile and register Windows Terminal as the default terminal application via `HKCU:\Console\%%Startup` delegation values (#74).
- Added Claude Code GitHub automation (`.github/workflows/claude.yml`): mention `@claude` on an issue or PR to trigger AI assistance, authenticated with a Claude Max subscription OAuth token (#125).
- Added a `windows-latest` Pester CI workflow (`.github/workflows/windows-tests.yml`) that runs the `Test-WingetAppInstall.Tests.ps1` suite on every push to `main` and on pull requests (#130).
- Restored the pre-flight system checks (OS version, disk space, network) and the `-SkipSystemCheck` switch, whose implementation was lost after #101 (#132). **Note:** the `#106` module extraction (above) subsequently dropped the `Test-SystemRequirements` function again without carrying it into `WingetAppSetup/`; it was re-restored as a module function in [#154](https://github.com/J-MaFf/winget-app-setup/issues/154).
- Adopted **beads** (`bd`) as a dependency-graph task/memory layer beneath GitHub Issues for AI-driven work. `bd init` (embedded Dolt) scaffolds `.beads/` with the issue graph; a Dolt remote is wired to `origin` for cross-machine sync via `refs/dolt/data`; Claude Code hooks run `bd prime` on SessionStart/PreCompact; and an `AGENTS.md` is generated. The CLAUDE.md beads section is reconciled with the `git-policies` skill so durability/sync stay automatic while merges to `main` remain human-gated via PR ([#147](https://github.com/J-MaFf/winget-app-setup/issues/147), [#148](https://github.com/J-MaFf/winget-app-setup/pull/148)).

### Changed

- `winget-app-uninstall.ps1` is now generated from the `WingetAppSetup` module as a single file,
  like the installer (wgt-gq8.43, work-order items 10 and 15, review finding P3-11). It needs
  nothing next to it, and its elevated run is a copy checked against the SHA256 the file had when it
  started, in a folder only SYSTEM and Administrators can change. Before, it imported the module
  folder next to it and ran its files in place, unchecked (`Restart-WithElevation -InPlace`, now
  removed), so files in a user-writable folder could be rewritten while the UAC prompt was up. It
  still runs under Windows PowerShell 5.1 in the elevated window, with the same parameters and exit
  codes. Exit 5 now also covers a file that changed before its elevated run, and 4 an execution
  policy Group Policy sets for the approving account, which the checked copy's window now checks
  too. Started through `irm | iex` it says it runs only from a file and changes nothing (exit 5, or
  `$LASTEXITCODE` 5 in an interactive console that stays open).
  `build/Build-WingetInstallScript.ps1` builds both scripts through one code path
  (`build/fragments/uninstall-head.ps1` and `uninstall-tail.ps1` around the module); every guard and
  `-Check` (byte compare, BOM, parse, comment removal, references, 5.1 parse safety) covers both,
  each guard's report names its script (the comment check names the source file), and nothing is
  written unless both pass. The uninstaller has no build id. The pre-commit hook checks both staged
  files, and `.gitattributes` marks the uninstaller `linguist-generated`. New
  `-UninstallerOutputPath`, defaulting to the folder of `-OutputPath`. The module's only manifest consumers are now the `e2e/` scripts. Tests run the
  uninstaller's real entry block in a child process (`New-TestUninstallerScript`,
  `Invoke-TestUninstallerScript`), and `tests/TestHarness.Tests.ps1` refuses a dot-sourced
  uninstaller as it does the installer. The Windows CI job's timeout goes from 15 to 25 minutes,
  since every build-guard fixture now builds both scripts.
- The catalog's architecture gates use the `arch` field (wgt-gq8.44). `Dell.CommandUpdate.Universal`
  is limited to x64 Windows (`arch = 'X64'`, plus its Dell condition): winget has only Dell's x64
  build, and on ARM64 it would pair it with the Arm64 .NET runtime. Its skip reason is now
  `Dell hardware with x64 Windows only; winget has no ARM64 installer for it`. The Adobe Reader
  split moves from conditions to `arch` lists: `Adobe.Acrobat.Reader.64-bit` for X64,
  `Adobe.Acrobat.Reader.32-bit` for Arm64 and X86. 32-bit Windows therefore now gets the 32-bit
  Reader instead of failing the x64-only one. `Google.GoogleDrive` stays ungated: Google serves the
  same installer to ARM64 PCs, and Drive runs natively on Windows 11 ARM64. On Windows 10 ARM64
  (end of servicing), which emulates only x86, winget still has no applicable Drive installer
  (`0x8A150010`); an `arch` list cannot tell it from Windows 11. `e2e/Assert-Install.ps1` decides
  which apps it expects installed with the installer's own `Test-AppApplicability`, through
  `Get-CatalogAppApplicability` in `e2e/TranscriptAssertions.ps1`, instead of a copy that read only
  `condition`. It still expects every app with neither an `arch` list nor a condition installed,
  whatever the module says, and fails a new `Apps with no arch list or condition apply` assertion
  when the module skips one. (Since changed: it reads a record taken before each pass; see Fixed.)
- A run as SYSTEM now prints an `Install engine:` line near its start once `winget.exe` or the
  module is ready, with or without the opt-in `Microsoft.WinGet.Client` engine (see Added): by
  default `Install engine: winget.exe (<path>).` (wgt-gq8.42). A run that stops with exit code 2
  before that prints none, and a dry run that asked for the module prints a `[DRY-RUN]` line
  instead. `last-run.json` gains `installEngine` (`requested`, `used`, `module`,
  `fallbackReason`; `requested` and `used` are `Cli` in a run that did not ask for the engine)
  and, for each app, `installerCode` (the installer's own exit code when the engine ran an
  installer, otherwise `null`). Both are additions, so `schemaVersion` stays 1.
- The generated `winget-app-install.ps1` leaves out the comments of the module and of the entry
  block, `build/fragments/tail.ps1` (work-order item 30, review finding P3-53): 439 KB and 11,111
  lines instead of 867 KB and 17,766, so every `irm | iex` run downloads about half as much.
  `build/Build-WingetInstallScript.ps1` removes the comments with the PowerShell tokenizer
  (`Remove-PowerShellComment`), and only those that end their line, so a `#` inside a string,
  here-string or regex stays, as would a `#Requires`; `build/fragments/head.ps1` (the script's
  help) is kept as it is. A new build check fails the build when removing the comments changed the
  code tokens of a module file or of `tail.ps1` (compared case-sensitively), and the parse, ASCII
  and PowerShell-7-syntax guards now name the source file and line behind each line they report.
  Every function in the installer has the same syntax tree as before. A change to a comment in the
  module or `tail.ps1` alone no longer changes the installer or its build id.
- The module's comments are shorter (work-order item 30, review finding P3-53): the incident
  narratives in its help and inline comments now say what the code does and why in a few lines,
  with the history left to the commit messages and this changelog (6,508 comment lines and 408 KB
  down to 4,763 and 264 KB). The comment-based help of every module function uses `.OUTPUTS`
  instead of `.RETURNS`, an unknown keyword that made `Get-Help` ignore the whole help block, so
  `Get-Help` now reads the help of all 258 functions instead of 56; a test keeps it that way. No
  code changed: the generated installer is byte-identical.
- Auto-updates now count as set up only when Winget-AutoUpdate's `\WAU\Winget-AutoUpdate` task
  exists, is enabled and has an enabled trigger (`Get-WauTaskHealth`), checked after installing WAU
  and on every run that finds it already installed (review finding P3-36). WAU's registry key, or
  `msiexec` exit 0, used to be enough, so a machine whose task was missing or disabled showed a
  green `Auto-updates:` line and never updated. Otherwise the summary shows
  `Auto-updates: UNHEALTHY - <reason>`, and `Install-WingetAutoUpdate` returns the new status
  `Unhealthy`. A task the Task Scheduler query cannot read is reported as unknown ("it is not known
  whether apps will update automatically") with a pointer to Task Scheduler, not as broken with
  advice to reinstall WAU. The task's state, triggers, last run and result, and the last 20 lines
  of WAU's `updates.log`, go to the transcript (`Write-WauTaskHealth`). The installer does not
  repair the task.
  - **Exit code 8.** The apps installed but auto-updates are not configured or will not run: the
    `Auto-updates:` line is `FAILED`, `NOT CONFIGURED`, `AT RISK` or `UNHEALTHY`.
    `Get-InstallerExitCode` now ranks 1 > 2 > 8 > 3010 > 0, and 1 > 2 > 9 > 8 > 3010 > 0 with the
    time budget's exit code 9 (see Added). A machine without
    `Microsoft.WindowsAppRuntime.1.8` that the installer could not install it on (see Added)
    therefore exits 8 even when every app installed.
  - **`msiexec` logs** (P3-37). WAU's install and uninstall run through `Invoke-WauMsiexec`, which
    writes a verbose log (`wau-msi-<install|uninstall>-<time>-<attempt>.log`) to the logs folder,
    names it on failure, and gives the uninstall the same time limit and 1618 wait as the install.
  - **Quieter transcripts** (P3-38). The 'task not found' probes no longer write
    `PS>TerminatingError(Get-ScheduledTask)` into every transcript, which #283's was misread as.
  - **E2E.** `e2e/Invoke-InstallPass.ps1` accepts exit 8 only when the pass's own transcript says
    WAU was skipped because `Microsoft.WindowsAppRuntime.1.8` is missing. Before the installer
    installed the framework itself (see Added), that was every pass on `windows-latest`.

- A run as SYSTEM or under cross-user elevation no longer installs an app at winget's default
  (per-user) scope (review finding P3-22). An app with no machine-scope installer used to be
  retried at the default scope, which put it into SYSTEM's own profile or the elevating admin's
  instead of the signed-in user's, and the check, run as that same account, reported it installed.
  `Install-WingetPackage -MachineScopeOnly` now stops there, and the app is reported as `Deferred`:
  a new summary row, a line saying what can still install it (only the signed-in user's own
  account: this installer run as that user when the account is an administrator, otherwise a
  per-user deployment), and no effect on the exit code (it counts neither as installed nor as
  failed). Under cross-user elevation, Windows Terminal is decided from whether it is provisioned
  for every user too, not from the admin's `winget list`. In a signed-in user's own run the
  fallback stays, and a successful one now says the app was installed for that account only.

- The Windows Terminal step no longer configures the elevating admin account (review finding
  P3-21). Under cross-user elevation it wrote the admin's `settings.json` and
  `HKCU:\Console\%%Startup` delegation values, behind a 6-line warning banner and a closing
  warning. Both settings are per-user, so the step is now skipped, with one line, when the process
  account is not the logged-on user and when the run is SYSTEM (as under an RMM agent; the new
  private `Test-IsSystemAccount` in `WingetAppSetup/Private/Elevation.ps1` detects it). When no
  console user is reported, the step runs as before. It never writes to another user's profile or
  registry hive.
- `e2e/Assert-Install.ps1` reads the transcripts through functions in the new
  `e2e/TranscriptAssertions.ps1`, which `tests/E2EAssertions.Tests.ps1` tests against sample
  transcripts in `tests/fixtures/e2e` (saved as `.txt`, because the repository ignores `*.log`)
  (review finding P3-39). The containment check now reads each run's final outcome: the summary's
  `Failed` row plus every failure line the retry pass did not recover, including the
  `Winget list timed out` and `Verification timed out` lines it used to miss. A first-pass failure
  that the retry pass recovered no longer fails it (the detail names it), and a transcript without
  a summary (an aborted run or an early exit) now fails instead of passing with no failed apps. The
  Windows PowerShell 5.1 `-bootstrap` transcripts are kept apart, so they are no longer taken for
  the latest run. A test checks that the installer still writes every message the parser keys on.
- The end-to-end install run (`.github/workflows/e2e-install.yml`) now also runs on pull requests
  that change the product (`WingetAppSetup/**`, `build/**`, `winget-app-install.ps1`), not only on
  changes to the workflow or `e2e/**`, so a module change gets a real install before it reaches the
  one-liner on `main` (review finding P2-7). Every pull request starts the workflow, and a `changes`
  job decides whether to install; if that job does not succeed, the install runs anyway. The filter
  is a job rather than a `paths:` filter so that `e2e-install` can become a required check: a job
  skipped by its `if:` reports success, while a workflow skipped by `paths:` reports no status.
  Dispatched runs now install the checkout instead of raw `main`, so
  `gh workflow run e2e-install.yml --ref <branch>` tests that branch. Pull-request and dispatched
  runs pipe the checkout to `iex` in the first pass, like the one-liner, and run it with `pwsh -File`
  in the second, like a clone or RMM run; before this change, pull-request runs used `-File` for both
  passes. Only the weekly run still fetches raw `main`. On checkout runs,
  `e2e/Assert-Install.ps1 -InstallerPath` checks that every pass's transcript logged the checkout's
  build id. Runs are grouped per ref: a pull-request push can no longer cancel a pending weekly run,
  and each pull request's run is cancelled by the run for its next push. The `E2E install run failed`
  issue is filed only for scheduled runs and runs dispatched on `main`.
- Kept fork pull requests off the self-hosted win-test runner (review finding P2-20).
  `windows-tests.yml` ran every pull request on that persistent runner, forks included, and the
  runner runs jobs elevated. The `pester` job now picks its runner on each run. Pushes to `main`,
  manual dispatch and pull requests from a branch of this repository stay on
  `[self-hosted, windows]`. Fork pull requests, including those whose fork has been deleted, and any
  other run go to GitHub-hosted `windows-latest`. The job id is unchanged, so `pester` is still the
  required check on `main`. A new `hosted` dispatch input runs the `windows-latest` leg on demand. A
  fork pull request that edits the workflow can still choose its own runner, because a
  `pull_request` run uses the PR's copy of the file. Closing that gap needs the "Require approval
  for all external contributors" setting and a job-started hook on the runner that refuses fork
  pull request jobs.
- Pinned `claude.yml`'s call to the shared Claude workflow in
  [J-MaFf/.github](https://github.com/J-MaFf/.github) to a commit SHA (`e5f8b3f4`, `main` as of
  2026-09-15) instead of `@main` (review finding P3-19). An edit to that workflow file now reaches
  this repository's write token only after someone reads it and moves the pin. The pin does not
  cover what that workflow pulls in when it runs: `anthropics/claude-code-action@v1`,
  `actions/checkout@v7` and the git-policies text it fetches from `J-MaFf/J-MaFf.github.io` at
  `main` still follow their tags or branch until J-MaFf/.github pins them. `secrets: inherit` also
  stays, so every repository secret still reaches the shared workflow: that workflow declares no
  `workflow_call` secrets, and a caller can pass a secret by name only when the callee declares it.
- `Invoke-WingetInstall` now returns its exit code as an `[int]` instead of calling `exit` itself,
  and the generated entry script exits with the returned code (review finding P3-4 and the exit part
  of P3-5, wgt-gq8.6; P3-5's other part, one helper for the near-duplicate first-pass and retry-pass
  loops, is still open). The codes do not change, and neither do the abort guard's cases: an aborted
  run still exits 5, Ctrl+C at the final prompt keeps the run's code, and an interactive `irm | iex`
  console stays open after a success or an unexpected error. An `exit` inside the function used to
  end the Pester process, so its exit paths were pinned only by regexes over its source, which broke
  on any rewording yet let a real regression through. The tests now run those paths and assert the
  returned code: failed and recovered apps, winget unusable at the end of the run, winget
  unavailable, a bad catalog, a declined or impossible elevation, the winget deadlock, the
  retry-pass messages (#237) and the summary rows. The summary tests used to check their own inline
  copy of the summary code. One AST check remains, guarding that the function never calls `exit`
  again. Tests no longer depend on whether the runner is elevated: they mock `Test-IsAdmin`. Before,
  the #232 IEX dry-run tests skipped on elevated runners and the retry-pass tests on non-elevated
  ones, so the #232 regression tests never ran in CI. The #226/#229 IEX test now overrides
  `Test-IsAdmin` in its child process and runs on every runner. New child-process tests check that
  the entry script exits with the returned code under `-File` and `irm | iex`, ignores values leaked
  into the output stream before it, does not exit after a successful `irm | iex` run (so the
  caller's console stays open), and still exits 1 when a pre-flight check fails. Code that imports
  the module and calls `Invoke-WingetInstall`
  itself now gets the code back as the return value: a failed run (1, 2 or 3) no longer ends the
  calling script, so a wrapper run with `pwsh -File` exits 0 unless it passes the code on
  (`exit (Invoke-WingetInstall -NonInteractive)`), and at an interactive prompt the code is printed.
  Called from the imported module without elevation, the function now returns a code instead of
  nothing (4: see the elevation entry under Fixed).
- The build guards now catch three more mistakes locally instead of leaving them to Windows CI
  (review findings P3-46, P3-47, P3-48). `build/Build-WingetInstallScript.ps1` (build and `-Check`)
  rejects syntax that only PowerShell 7 parses: `??`, `??=`, `?.`, `?[`, the ternary `?:`, `&&` /
  `||`, the background operator `&` (`Get-Process &`) and `clean { }` blocks. Windows PowerShell
  5.1 parses the whole installer before it runs any of it, so one such token anywhere broke the
  one-liner before the PowerShell 7 bootstrap, and only Windows CI's real 5.1 parse test noticed.
  The guard reads token kinds and the AST, so the same characters inside strings, comments and
  regexes still pass, and so does the call operator `& $cmd`. The undefined-reference guards
  (#154, and the catalog `install` names) now also run on Linux and macOS instead of being skipped:
  the Windows-only cmdlets the installer calls are listed in the new
  `build/windows-only-commands.txt` and count as resolvable there, every entry must resolve on
  Windows, and an entry the installer no longer calls draws a warning. The pre-commit hook runs
  `-Check` against the staged files (exported with `git checkout-index`) instead of the working
  tree, so a module change committed without its regenerated installer is blocked even when the
  working tree was rebuilt. Covered by the new `tests/BuildGuards.Tests.ps1`.
- The Pester suite now runs on Linux and macOS, so a local run there shows a new failure instead of
  hiding it among about 100 environment failures (wgt-gq8.5). `tests/TestHelpers.ps1` defines a
  stand-in for each Windows-only command the tests mock (`Get-AppxPackage`, `Add-AppxPackage`,
  `Get-CimInstance`, `Get-/Set-/Unregister-ScheduledTask`, `Repair-WinGetPackageManager`, `winget`,
  `powershell.exe`), only where the command is missing, so Windows still mocks the real cmdlets.
  Each stand-in declares the real parameter names that `-ParameterFilter` blocks read (and the real
  `CimInstance` types for the scheduled-task objects) and throws like a missing command when called
  without a `Mock`. TestHelpers also sets the Windows folder
  variables when they are unset. Tests whose `C:\` paths reached `Join-Path` now use `TestDrive`;
  off Windows those paths had become `$null`, so several `Find-PowerShell7`,
  `Resolve-WingetExecutable` and Winget-AutoUpdate tests failed or passed without checking
  anything. `Elevation`, `GraphicalTools`, `Install`, `Logging` and `WingetCore` tests no longer
  dot-source the generated `winget-app-install.ps1` over the module source, which made them test the
  last build instead of the code being edited. The new `tests/TestHarness.Tests.ps1` enforces all of
  this. A Linux run went from 113 failures to 2: `Write-Table` printed nothing without a console
  (wgt-gq8.11) and the IEX dry-run test depended on real elevation (wgt-gq8.6). Both are fixed, so
  the whole suite passes on Linux.
- `claude.yml` now calls the shared reusable Claude workflow in [J-MaFf/.github](https://github.com/J-MaFf/.github) instead of carrying its own copy ([#261](https://github.com/J-MaFf/winget-app-setup/pull/261))
- Follow-up hardening from the 2026-07-17 integration mega-review (issue #255): the pre-elevation `Invoke-WingetSourceProbe` call in `Invoke-WingetInstall` now passes `-TimeoutSeconds 30` instead of the function's 120s default, since its result is discarded and `Initialize-WingetSourcesForUser` re-probes for real after elevation anyway; the `-WhatIf`-never-elevates invariant is checked once at the top of `Invoke-WingetInstall`'s non-admin block instead of once per execution-context branch, so a future branch cannot forget it; `Test-WingetPackageInstalled` now joins `winget list` output lines with a newline instead of an empty string before boundary-matching a package id, closing an artificial-seam false-negative the empty join could theoretically create; `Test-IsAdmin`'s docstring now explains why fail-open (assume elevated on an unexpected exception) is the right direction at its two elevation-gating call sites rather than just describing the mechanism; the build's two AST-walking reference guards (`Get-UndefinedCommandReference`, `Get-UndefinedCatalogInstallReference`) now share one `Get-UndefinedName` resolution loop instead of each carrying its own copy; `AppCatalog.ps1`'s schema docs and `InstallVerification.ps1`'s `& $App.install` dispatch site now cross-reference the build guard that validates catalog-carried function names, so a future string-carried field (e.g. `uninstall`, `verify`) doesn't reopen the issue-#236 blind spot silently; `PowerShell7Bootstrap.ps1`'s 5.1-safety header now lists `Test-IsAdmin`/`Get-CurrentWindowsPrincipal`/`Get-WingetAgreementArgs` among the helpers it depends on; repo CLAUDE.md documents the discovery-time `TestHelpers.ps1` dot-source pattern `EntryPoint.Tests.ps1`/`Install.Tests.ps1` use; two `Test-WingetPackageInstalled` timeout assertions in `tests/WingetCore.Tests.ps1` that were strictly subsumed by more specific tests added later in the same file were removed; and `Invoke-WingetInstall`'s merged pre-elevation comment block was split back into its two separate narratives (the source-update probe and the admin check) instead of reading as one glued paragraph.
- Consolidated the `IsInRole('Administrator')` check — copy-pasted across `WingetAppSetup/Public/Install.ps1`, `winget-app-uninstall.ps1`, and `WingetAppSetup/Private/PowerShell7Bootstrap.ps1`, with already-diverged failure behavior on an unexpected exception (full-repo review finding, 2026-07-16) — into one shared, exported `Test-IsAdmin` (`WingetAppSetup/Public/Elevation.ps1`), backed by the new private `Get-CurrentWindowsPrincipal` (`WingetAppSetup/Private/Elevation.ps1`) so the underlying static .NET call can be mocked in tests. All three call sites now use `Test-IsAdmin`, which fails safe (warns and returns `$true`) if the identity/role check throws — previously only the PowerShell 7 bootstrap had that protection; the installer and uninstaller would have let the exception propagate. Non-exception behavior is unchanged at every call site.
- Consolidated the duplicated winget agreement/interactivity flag triple (`--accept-source-agreements --accept-package-agreements --disable-interactivity`) into a single shared helper, `Get-WingetAgreementArgs` (`WingetAppSetup/Private/WingetAgreementArgs.ps1`), rather than continuing to hand-duplicate it as a literal array at each call site. `Install-WingetPackage`, `Install-MsixProvisionedPackage`, and the PowerShell 7 bootstrap's winget install call (`Invoke-PowerShell7Bootstrap`) now all splice in the helper's output alongside their own subcommand-specific arguments; each call site's own flags (`--source winget --id <id>`, `--installer-type msix --download-directory <dir>`, `--exact`, etc.) are unchanged. This is the exact flag combination that shipped one of the three call sites missing `--disable-interactivity` (issue #230) until it was caught after the fact — deduplicating the base flag set makes that class of drift structurally impossible instead of relying on manual re-auditing. Covered by a new `tests/WingetAgreementArgs.Tests.ps1` unit test asserting the helper's exact return value; existing argument-shape assertions in `tests/WingetCore.Tests.ps1` and `tests/PowerShell7Bootstrap.Tests.ps1` continue to pass unchanged.
- The installer no longer asks a yes/no question on any path, so the documented one-liner can be run from an ordinary interactive console and left alone (issue #230). An interactive `irm | iex` is **not** detected as non-interactive — the pipe is an in-process pipeline, not redirected stdin — so `Test-EffectiveNonInteractive` reported "interactive" for exactly the run the prompts were meant to protect, and every one of them fired. Removed: the PowerShell 7 install-consent prompt (`Invoke-PowerShell7Bootstrap`, previously `[Y/n]`), the elevation "press Enter to restart" pause (`Invoke-WingetInstall` and `winget-app-uninstall.ps1`), and the low-disk-space "Continue anyway? (Y/N)" prompt (`Test-SystemRequirements`) — each now proceeds unconditionally with a warning where relevant. `Write-Table`'s grid-view prompt is replaced by `-AutoGridView`, which opens the summary grid automatically when the session can show one instead of asking first (`-PromptForGridView` is renamed and its semantics changed accordingly; `winget-app-uninstall.ps1` updated to match); the text summary now always prints as well, so the transcript log no longer loses the summary when the grid view opens. `Test-SystemRequirements` drops its now-unused `-NonInteractive` parameter — its only prompt is gone, so there is nothing left for the switch to gate. Every winget subprocess invocation now passes `--disable-interactivity` (`Install-WingetPackage`, `Install-MsixProvisionedPackage`, the PowerShell 7 bootstrap's winget install, and the user-context source-update call in `Invoke-WingetInstall`), so winget itself cannot stop and ask either. `-NonInteractive` still exists, but now only controls the two extras a human isn't needed for: the auto-opened grid view and the final "press any key to exit" pause. Deliberately unchanged: that final pause (not a yes/no question) and the OS's own UAC elevation dialog, which is a security boundary outside this script's control.
- Split the 3,400-line single-file Pester suite `Test-WingetAppInstall.Tests.ps1` into per-area files under `tests/` — one `<Area>.Tests.ps1` per module file (WingetCore, WingetBootstrap, Install, Logging, Elevation, Environment, GraphicalTools, SystemChecks, WindowsTerminal, WingetAutoUpdate, AppCatalog, AppValidation) plus `EntryPoint.Tests.ps1` for the generated installer's head/tail/IEX behavior, build stamp, and psd1 export surface (issue #192). Shared module dot-sourcing moved to `tests/TestHelpers.ps1`, called from each file's top-level `BeforeAll`, preserving the load-once semantics per Pester file; the helper also pre-resolves the PowerShellGet mock targets so no file depends on Describe run order. CI (`windows-tests.yml` `Run.Path`) and the doc test commands now point at `./tests` ([#209](https://github.com/J-MaFf/winget-app-setup/pull/209)).
- Single-sourced the curated app catalog (issue #190): the list previously lived in three places — inlined in `Invoke-WingetInstall`, duplicated (and already metadata-drifted) in `winget-app-uninstall.ps1`, and enumerated as prose in the generated installer's help. The new exported `Get-DefaultAppCatalog` (`WingetAppSetup/Public/AppCatalog.ps1`) is now the single authority: `Invoke-WingetInstall` consumes it via a new `-Apps` parameter (defaulting to the catalog, so tests can inject a one-app list), the uninstaller iterates the same catalog from the imported module, and the installer help points at the function plus `-WhatIf` to preview. The uninstaller also stops re-implementing module logic: its inline `winget list` probe is replaced by `Test-WingetPackageInstalled -TimeoutSeconds 15` (same agreement flags, still exit-code-classified per #180, now hang-guarded) and its hand-rolled `Start-Process` relaunch by `Restart-WithElevation` (moved to `Public/Elevation.ps1` and exported, since the psd1 gates manifest imports) ([#208](https://github.com/J-MaFf/winget-app-setup/pull/208)).
- Extracted the copy-pasted (and already drifted) Start-Process `winget list` verify block — inlined three times in `Invoke-WingetInstall` (pre-check, first-pass verify, retry verify) — into a single shared pipeline (issue #188): `Test-WingetPackageInstalled` gained an optional `-TimeoutSeconds` mode that runs the check under a kill-on-timeout guard with unique per-run temp files and returns `@{ Installed; TimedOut; ExitCode }` so a hung check stays distinguishable from "not installed" (timeouts still count as Failed per #176; the parameterless `[bool]` contract is unchanged), and a new private `Install-AppWithVerification` performs pre-check → dispatch (`$app.install` self-verifying installer vs `Install-WingetPackage`) → post-verify with no prompts/`Exit`/`ReadKey`, returning the `Install-WingetPackage` result intact for #189. Both install passes now call the helper, keeping summary buckets and message texts identical, and the drifted "simulate the code path" Pester blocks that re-inlined obsolete copies of the loop were replaced with behavioral tests of the helper plus wiring tests that execute the real `Invoke-WingetInstall -WhatIf -NonInteractive` end-to-end with mocked boundaries ([#206](https://github.com/J-MaFf/winget-app-setup/pull/206)).
- Made the module manifest the single export authority (issue #191): `WingetAppSetup.psm1` no longer AST-derives its own export list from `Public/*.ps1` (a second authority under which a new Public function passed the psm1's export while being silently filtered on manifest imports — how `winget-app-uninstall.ps1` loads the module) and instead reads `FunctionsToExport` from the psd1; `build/Build-WingetInstallScript.ps1` now asserts in both build and `-Check` modes that the psd1 list exactly matches the functions defined under `WingetAppSetup/Public/*.ps1`, failing with the difference listed. Also trimmed the public surface by moving the module-internal `Write-Prompt` (to `Private/LoggingInternal.ps1`) and `ConvertFrom-TerminalSettingsJson` (to `Private/Jsonc.ps1`, beside the `Convert-JsoncToJson` scanner it wraps) out of the exported set; `Write-Info`/`Write-Success`/`Write-WarningMessage`/`Write-ErrorMessage`/`Format-AppList`/`Write-Table` stay exported because `winget-app-uninstall.ps1` consumes them ([#205](https://github.com/J-MaFf/winget-app-setup/pull/205)).
- Reconciled the agent-instruction files with CLAUDE.md as the single source of truth: AGENTS.md's beads block no longer mandates unconditional `git push` at session end (it now points at CLAUDE.md's Session Completion — push feature branches + `bd dolt push`; merges stay human-gated), and `.github/copilot-instructions.md` dropped the foreign-project examples and emoji PR-title scheme in favor of repo-specific guidance ([#199](https://github.com/J-MaFf/winget-app-setup/pull/199)).
- Marked `winget-app-install.ps1` as `linguist-generated` in `.gitattributes` so the generated single-file installer's diff collapses by default in PR review ([#199](https://github.com/J-MaFf/winget-app-setup/pull/199)).
- Extracted the duplicated source health probe in `Test-WingetSources` (the pre-repair and post-repair copies had already diverged in logging) into a single private helper, `Test-WingetSourceHealth` (`WingetAppSetup/Private/WingetBootstrap.ps1`), called twice with a `-Quiet` switch controlling per-step log verbosity (issue #177, [#202](https://github.com/J-MaFf/winget-app-setup/pull/202)).
- Removed the install-time inline update pass now that WAU owns updates (issue #170). After installing the curated apps, `Invoke-WingetInstall` used to run `winget upgrade` synchronously on **every** installed app (not just the curated set) as the elevating admin, with output redirected and a 5-minute timeout each — slow, silent (looked frozen), and largely failing under cross-user elevation. WAU (installed with `RUN_WAU=YES`) runs once immediately and then weekly as SYSTEM, which is the correct mechanism. Deleted the update block and the `Updated`/`Failed to Update` summary rows, plus the now-orphaned `Test-UpdatesAvailable`, `Invoke-WingetPackageUpgrade` (`Private/WingetUpgrade.ps1`), and the already-dead `Invoke-WingetCommand`, with their exports and tests ([#170](https://github.com/J-MaFf/winget-app-setup/issues/170)).
- Outsourced ongoing app updates to [Winget-AutoUpdate (WAU)](https://github.com/Romanitho/Winget-AutoUpdate) and removed the homegrown scheduled/on-demand updater (issue #168). The installer now bootstraps a pinned, SHA256-verified **WAU 2.12.0** via its MSI (`Install-WingetAutoUpdate`) configured for weekly updates at 02:00, `USERCONTEXT=1`, Full notifications, and `DISABLEWAUAUTOUPDATE=1` (WAU stays on the pinned version). WAU runs as SYSTEM for machine-scope packages plus a user-context pass in the logged-on session, which structurally avoids the cross-user `0x80073d19` / MSIX-provisioning failures a per-user S4U task hits (the old task also ran non-elevated as the *elevating admin*, so it couldn't update machine-scope apps at all). **Removed** `ScheduledUpdates.ps1`, `Update-InstalledApps.ps1`, and `Get-UpdateReport`, the five `-EnableScheduledUpdates`/`-DisableScheduledUpdates`/`-CheckForUpdates`/`-AutoInstallUpdates`/`-UpdateFrequency` one-liner switches, and ~10 associated tests (~700 lines). The installer and uninstaller call `Remove-LegacyScheduledUpdates` to unregister the old `\winget-app-setup\WingetAppSetup-ScheduledUpdates` task and clean `%APPDATA%\winget-app-setup` so already-deployed machines migrate cleanly; the uninstaller also removes WAU. The install-time inline update pass and the curated cross-user install flow are unchanged ([#168](https://github.com/J-MaFf/winget-app-setup/issues/168)).
- Replaced PowerShell's unconditional `--installer-type wix` (from #163) with a version-agnostic, always-latest install strategy so no PowerShell version is ever pinned (`Install-PowerShellLatest`, issue #166). It prefers the MSI while the current line still ships one (≤ 7.6 — machine-wide and Task-Scheduler-friendly), and once the MSI is gone (7.7+) installs the latest MSIX machine-wide: natively via winget on Windows 24H2+ (build ≥ 26100, where winget can machine-scope-provision an MSIX), or via `Add-AppxProvisionedPackage` DISM provisioning on older Windows (run from a non-packaged process, which isn't subject to winget's packaged-context provisioning bug). The scheduled-update task now runs under `powershell.exe` (Windows PowerShell 5.1) rather than `pwsh`, because an MSIX-only PowerShell 7.7+ isn't reliably launchable by Task Scheduler. **The DISM-provisioning path is dormant until the winget default becomes MSIX-only (7.7 GA) and needs end-to-end validation on a real Windows 10 machine before it is relied upon.** ([#166](https://github.com/J-MaFf/winget-app-setup/issues/166))
- Moved the Windows CI workflow (`.github/workflows/windows-tests.yml`) from GitHub-hosted `windows-latest` to the self-hosted win-test runner (`runs-on: [self-hosted, windows]`, Windows Server 2025, pwsh 7.6.3), keeping the existing steps and concurrency group. Added a `workflow_dispatch` trigger and a 15-minute job timeout so a hung job cannot block the shared runner. The guarded Microsoft.WinGet.Client and Pester installs persist across runs on the runner, so they are no-ops after the first run ([#161](https://github.com/J-MaFf/winget-app-setup/issues/161), [#162](https://github.com/J-MaFf/winget-app-setup/pull/162)).
- Renamed the `Test-Source-IsTrusted` function to `Test-WingetSourceTrusted` so it follows the PowerShell verb-noun convention (the old name embedded a hyphen in the noun segment and tripped a PSScriptAnalyzer warning); updated the call site and all test references (#137).
- Refactored `Test-WingetAppInstall.Tests.ps1` to dot-source the real `winget-app-install.ps1` instead of copying function bodies verbatim into `BeforeAll`/`BeforeEach` blocks, so the suite now exercises the actual implementation and no longer drifts silently when the script changes. Removed 24 inline function copies across 12 `Describe` blocks and corrected the `Format-AppList` empty-input test to match the real function's mandatory `[string[]]` contract (#135).
- `Test-WingetAppInstall.Tests.ps1` now loads the module's functions once for the whole suite instead of dot-sourcing the full script in 16 places and re-declaring 17 functions inline, eliminating copy-paste drift between tests and production code ([#106](https://github.com/J-MaFf/winget-app-setup/issues/106)).
- `Format-AppList` now accepts `$null` (returning `$null`) in addition to empty collections, matching its documented contract and reconciling drift surfaced by the test consolidation ([#106](https://github.com/J-MaFf/winget-app-setup/issues/106)).
- The module's `Get-UpdateReport` now validates the winget Id column against a package-id regex before parsing a row, adopting the stricter behavior that had drifted into `Update-InstalledApps.ps1` ([#110](https://github.com/J-MaFf/winget-app-setup/issues/110)).
- Simplified the README to a two-step guide that starts with `Set-ExecutionPolicy Unrestricted -Scope Process -Force` followed by running `powershell -ExecutionPolicy Unrestricted -File .\winget-app-install.ps1`.
- Configured the workspace's local Memory MCP storage plus `.gitignore` and `.vscode` settings so auto-generated knowledge graph data stays in the repo scope.
- `Invoke-WingetInstall` now verifies and auto-repairs the winget package source before beginning app installations.
- Claude Code automation runs on `ubuntu-latest`; Windows-native test execution moved to the dedicated Pester workflow, since the action cannot install the Claude CLI on Windows runners (#130).

### Removed

- Removed `specs/` and `Test-WindowsTerminalConfiguration.ps1` (work-order item 29, review finding
  P3-52). The ten specs were the one-shot inputs for the fixes of issues #232 to #241, all shipped
  in #254. They had no status line and cited line numbers that have long moved, so an agent could
  take them for open requirements. They stay in git history (`git show 673a09c`) and in those
  issues. The Windows Terminal smoke script at the repository root kept its own list of
  `settings.json` paths and parsed the file with plain `ConvertFrom-Json` instead of the module's
  JSONC helper; it had no tests, and nothing referenced it.
- Removed the summary grid view and the module that provided it (work-order item 26, review
  findings P3-43, P3-45). An interactive run opened the installation and uninstall summaries in an
  `Out-GridView` window as well as the text table, and the window held the run until it was closed;
  it only repeated the table, which is in the console and the transcript either way, and never
  reached the log. To provide it, `Test-AndInstallGraphicalTools` (`WingetAppSetup/Private/GraphicalTools.ps1`)
  installed the NuGet provider and `Microsoft.PowerShell.GraphicalTools` for all users from the
  PowerShell Gallery wherever `Out-GridView` was missing (in-box in PowerShell 7 on Windows, so on
  the target PCs that branch never ran). Gone with it: `Test-CanUseGridView`, `Write-Table`'s
  `-UseGridView` and `-AutoGridView`, `Invoke-WingetUninstall`'s `-NonInteractive` (it gated only
  the grid view; `winget-app-uninstall.ps1 -NonInteractive` still keeps the UAC prompt away), the
  dry run's `Out-GridView is not available` line, and `Out-GridView` in
  `build/windows-only-commands.txt`. The installer's `-NonInteractive` still skips the final key
  press, the TightVNC question and the UAC prompt, and still adds `--silent`. The grid view was
  what held the uninstaller's elevated window open, so `winget-app-uninstall.ps1` now ends with
  `Press any key to exit...` when someone is at the console, as the installer does: that window
  closes as soon as the run ends, and the uninstaller keeps no transcript, so the summary used to
  vanish with it. Its `-NonInteractive`, a run as SYSTEM and a CI run do not wait, and Ctrl+C at the
  prompt keeps the run's exit code instead of exiting 0.
- Removed dead helpers and modes (review finding P3-43): `Get-WindowsTerminalSettingsPath`, which
  nothing called, and `Test-WingetPackageInstalled`'s mode without `-TimeoutSeconds`, which returned
  a plain `[bool]` under a 2-minute limit and read a winget that could not start, or that ran out
  of time, as "not installed". No caller used it; `-TimeoutSeconds` is now required, the result is
  always the hashtable, and the `WingetList` time limit went with it (the readme's time-limit table
  no longer lists "other `winget list` calls"). Also removed the Pester tests that only asserted
  that already-removed functions stayed removed (the old winget-setup ladders, the msstore-era
  source-trust helpers, `ConvertTo-CommandArguments`). `Write-Prompt` stays: it is the seam the tests
  use to stop a run at its final key press. `Convert-JsoncToJson` stays (PowerShell 7.6's
  `ConvertFrom-Json` rejects a comment between a key and its colon), and so does the dormant
  MSIX/DISM provisioning path.
- Removed the module's export list and its build check (review finding P3-44).
  `WingetAppSetup.psd1` exports every function (`FunctionsToExport = '*'`, and the psm1 exports
  `'*'` instead of reading the manifest), so `winget-app-uninstall.ps1` and `e2e/Assert-Install.ps1`
  get every function, `Private/` ones included, and moving a function between `Public/` and
  `Private/` changes nothing else. (The uninstaller has since become a generated single file that
  imports nothing; see Changed.) The explicit list had to match `Public/*.ps1` exactly, which
  `build/Build-WingetInstallScript.ps1` asserted in build and `-Check` modes (#191: a function
  missing from it failed only at the uninstaller's prompt); with `'*'` there is nothing to drift,
  and `tests/EntryPoint.Tests.ps1` checks that a manifest import exports every function the module
  defines.
- Removed the aka.ms/getwinget download rung and the source.msix registration rung (review findings
  P3-25, P3-31), with `Test-AndInstallWinget`, `Initialize-WingetSourcesForUser`,
  `Test-WingetSources`, `Test-WingetSourceHealth` (the `winget source list` and `winget search 7zip`
  checks), and the text classifiers `Test-AppxDowngradeRejection` and
  `Test-AppxMissingFrameworkDependency`. The download saved App Installer to a fixed file name in
  `%TEMP%` and registered it with `Add-AppxPackage`, without the frameworks it needs and through the
  per-account deployment that 0x80073D19 blocks under cross-user elevation;
  `Repair-WinGetPackageManager -Latest` installs the same bundle with its frameworks, and the run it
  once rescued (#265) is now rescued by registering the App Installer already on the PC. The
  source.msix registration was the same per-account deployment, which `winget source update` and
  `winget source reset` make themselves. `Test-AndInstallWingetModule` is private now and installs
  the module only for the repair. The `WingetSourceList` and `WingetSearch` time limits went with
  their checks (`WingetSourceUpdate` is the source update's).
- Removed the launch-resilience code that existed to survive the Winget-AutoUpdate run the
  installer used to start mid-run (`RUN_WAU=YES`, removed earlier on this branch), now replaced by
  the run-level circuit breaker under Fixed (review findings P2-10, P3-7, P3-10):
  `Get-ConflictingDesktopAppInstallerVersions` and the #279 deadlock gate in `Invoke-WingetInstall`
  (it read the current user's AppX view and never fired on the real wedge; counting versions with
  `-AllUsers` instead would fail every app on multi-user desktops where users have different App
  Installer versions), `Wait-WingetLaunchable`, and the `-BypassAlias` path of
  `Resolve-WingetExecutable` with its three call sites (launching `winget.exe` from the App
  Installer package folder failed with `Access is denied` in every E2E run and never recovered a
  launch). `Resolve-WingetExecutable` now returns `winget`. Their tests went with them.
- Removed the orphaned PATH-mutation helpers in `WingetAppSetup/Private/Environment.ps1` — `Add-ToEnvironmentPath`, `Test-PathInEnvironment`, `Test-PathListContainsEntry`, `Get-PersistedEnvironmentPath`, and `Set-PersistedEnvironmentPath` — dead since the homegrown updater that used them was removed (#168) and PATH mutation was deliberately dropped from the install path (issue #179); a repo-wide grep found zero remaining callers outside their own dedicated tests. The file's two still-live functions, `Get-WindowsBuildNumber` and `Get-ComputerManufacturer`, move to the renamed `WingetAppSetup/Private/SystemInfo.ps1`; their tests move from `tests/Environment.Tests.ps1` to `tests/SystemInfo.Tests.ps1` alongside the deletion of the five orphaned functions' tests.
- Removed five tautological tests found by the 2026-07-08 review (issue #192): two `Should -BeOfType` assertions on framework constants in the 'Administrator check' context, two mock-then-assert-the-mock 'Winget check' tests, and a `Test-CanUseGridView` test whose only assertion was wrapped in `if ([Environment]::UserInteractive)` and asserted the opposite of its name. Each behavior they named is now pinned by a falsifiable replacement (the `Invoke-WingetInstall` admin gate and `Exit 2` winget gate structurally; the grid-view interactivity guard via its definition), the unfalsifiable `Write-Table` non-interactive prompt test was rewritten against the real `Test-CanUseGridView` seam, and the forbidden conditional `if (-not (Get-Command Out-GridView...))` stub was replaced with an unconditional test double plus `Mock` in `BeforeEach` ([#209](https://github.com/J-MaFf/winget-app-setup/pull/209)).
- Removed the dead `ConvertTo-CommandArguments` helper (`WingetAppSetup/Private/Environment.ps1`, ~45 lines) and its 4 Pester tests — a remnant of the removed homegrown updater with zero production callers that still shipped in every generated installer ([#205](https://github.com/J-MaFf/winget-app-setup/pull/205)).
- Removed orphaned Pester `Describe` blocks that tested functions which no longer ship: `Test-AndSetExecutionPolicy` (its `launch.ps1` was already dropped), `Invoke-WingetInstallWithRetry`, and `Test-SystemRequirements` ([#111](https://github.com/J-MaFf/winget-app-setup/issues/111)).
- Dropped `launch.ps1`; the installer now runs directly when the required execution policy is temporarily relaxed.

### Fixed

- The uninstaller no longer hangs for 15 minutes on Google Drive and then fails it (wgt-gq8.61).
  Drive is an exe app, so `winget uninstall` ran the `UninstallString` Drive registers, a bare
  `uninstall.exe` with no switches, exactly as written, and waited on it with no limit of its own:
  `--silent` only makes an MSI quiet, and `winget uninstall` has no `--override`
  (winget-cli#4700). That `uninstall.exe` asks "Uninstall Google Drive?" and waits for a click,
  which nobody can give in an unattended or SYSTEM run. The 15-minute `WingetUninstall` limit then
  stopped it, Drive stayed, Winget-AutoUpdate was kept and the run exited 1 (seen in the real-PC
  test plan's self-test on `windows-latest`). Before this PR the uninstaller had no limit and
  would have waited for ever.
  - **New catalog field `quietUninstall`.** `@{ productCode = '{<GUID>}'; arguments = @(...) }`,
    set for `Google.GoogleDrive` to `{6BBAE539-2232-434A-A4E5-9A33560C6283}` and Google's
    documented `--silent --force_stop` (`--force_stop` closes a running Drive). The schema refuses
    a value without a braced-GUID product code or with no arguments, an argument with a double
    quote, or an unknown key (exit code 3).
  - **Its own uninstaller, never `winget uninstall`.** For such an entry the uninstaller reads the
    entry's `UninstallString` from HKLM (the 64-bit view, then `WOW6432Node`, also from a 32-bit
    PowerShell), takes the quoted program (the entry's own arguments are dropped) and runs it with
    the catalog's switches through `Invoke-ExternalProcess`, under the same 15-minute limit and tree
    kill. It runs it only when the path is a full, normalised path to an existing `.exe` under
    Program Files (`ProgramW6432`, or `ProgramFiles` on 32-bit Windows) or Program Files (x86).
    Otherwise the app fails at once (`UninstallerNotFound`), with nothing run: falling back to
    `winget uninstall` would hang again.
  - **Then it checks.** Drive's `uninstall.exe` hands its work to a copy of itself and exits, so
    the uninstaller waits, for what is left of the 15 minutes, until the uninstall entry is gone,
    then asks `winget list`. Gone and not listed is `Uninstalled` (with a restart for 3010 or 1641);
    anything else is the new `UninstallVerifyFailed`. Another exit code is `UninstallFailed`, and a
    timeout or a failed start names `uninstall.exe`. A preview (`-WhatIf`) prints the exact command
    line it would run.
  - The help of `Uninstall-CatalogApp`, which said `--silent` keeps an interactive uninstaller from
    waiting, and the `WingetUninstall` time-limit description are corrected. Entries without the
    field keep `winget uninstall` as before. `winget uninstall` still gets no `--log`: the
    uninstaller keeps no transcript, so it has no logs folder for one (`Invoke-WingetProcess` adds
    `--log` whenever there is one).
- The E2E assertions now check which apps apply as it stood just before the pass whose transcript
  they read: `e2e/Invoke-InstallPass.ps1 -ApplicabilityPath` records it before each pass, and
  `e2e/Assert-Install.ps1 -ApplicabilityPath` reads it. The installer decides applicability before
  it changes the machine, and its Windows Terminal step then makes Terminal the default terminal,
  which Terminal's condition reads. Deciding after the install expected Terminal's `not applicable`
  skip line from a first pass that had found Terminal applicable, so every run whose second pass
  was skipped also failed that assertion. A record that is missing or cannot be read fails the new
  `Applicability recorded before the latest pass` assertion.
- **Security fix:** an elevated run, or a run as SYSTEM, no longer follows a junction or symbolic
  link planted at `%ProgramData%\winget-app-setup` or at its `logs` or `cache` folder
  (wgt-gq8.46). Any standard user can create these folders before the first elevated run, and can
  turn an empty folder there into a junction. The installer's own first, non-elevated launch also
  creates the base and `logs` folders, owned by the signed-in user. An elevated or SYSTEM run then
  followed such a link: `icacls` changed the owner and access list of the folder it pointed to
  (System32, for example), the `logs` folder's read grant let every user read it, and the run
  wrote its transcripts, `last-run.json` and installer logs into it and deleted old logs and
  engine folders there. Only the `cache` folder had a link check (wgt-gq8.42).
  - **One way in.** `Initialize-ProgramDataFolder` (in the new
    `WingetAppSetup/Private/ProgramDataFolder.ps1`) makes the base folder, then `logs` or `cache`,
    safe before use. A link in a folder's place is removed without being followed, and the run
    warns about it. A missing base folder is created with its access list already set, so it is
    never an empty folder another account can turn into a junction; `logs` and `cache` are created
    inside it. Each folder is then locked. A link that cannot be removed stops that use (error id
    `DirectoryIsLink`), and the message says how to remove it with `rmdir`.
  - **The lock.** `Set-RestrictedDirectoryAcl` refuses a link, runs `icacls` with `/L`, so a folder
    swapped for a link in the meantime has the link changed and not its target, and refuses the
    folder if it is a link afterwards. `icacls` runs in a hidden window. A folder that existed
    already is locked in place: what is in it stays.
  - **Logs.** Every elevated or SYSTEM run, a `-WhatIf` dry run and the Windows PowerShell 5.1
    bootstrap included, now locks the base and `logs` folders before its transcript starts, not
    only when it downloads Winget-AutoUpdate, the Windows App Runtime or the Microsoft.WinGet.Client
    module. The `logs` folder is owned by Administrators, only SYSTEM and Administrators can change
    it, and standard users can read it (`Set-RestrictedDirectoryAcl -ReadableByUsers`, which
    replaces `Grant-InstallLogReadAccess`). When it cannot be made safe, the run continues without a
    transcript and without `last-run.json`, and says why. Once an elevated run has locked the
    folder, a window that is not elevated cannot write its transcript there, as after any
    Winget-AutoUpdate install before. The `wau-msi-*` log of a run without a transcript (the
    uninstaller's) goes through the same check, and `msiexec` runs without a log when the folder
    cannot be made safe.
  - **Reset advice.** When a folder's access list cannot be set, the run now says to rename the
    folder aside with `ren` (`Get-RestrictedDirectoryResetHint`); the next run then creates a new,
    locked folder. It no longer suggests `takeown` and `icacls /reset`: another account may still
    change the folder, and both commands would follow a link put in its place.
  - **Housekeeping** deletes nothing through a link at the base or `logs` folder. It removes old
    `wingetclient-<id>` folders only from a base folder that passes the access-list check, so
    another account cannot swap a folder before it is removed.
  - **WinGet client cache.** A new download is written under a new random name, created only when
    nothing is there yet, and then moved over the cached package. Before, it was written to
    `<package>.partial`, a name known from the public pin, which followed a file link a standard
    user could leave in the cache folder before an elevated run first locked it.
  - **Endpoint Central machine phase.** `rmm/Invoke-WingetAppSetup.ps1` writes its log as SYSTEM
    before the installer runs. It now removes a link at the base or `logs` folder, creates a missing
    one with its access list already set, and logs only into folders that no account other than
    SYSTEM and Administrators can change (`Initialize-RmmLogDirectory`). Otherwise it continues
    without its log, and the installer locks the folders for the next run.
  - Not changed: a base or `logs` folder that a standard user created before the first elevated
    run is locked in place, not replaced, so the files other accounts left in it stay.
    `-CollectDiagnostics`, the fleet health probe and the user phase only read these folders and
    do not check them for links yet.
- Ctrl+C at the final `Press any key to exit...` prompt of an elevated run keeps the run's exit
  code again (review of wgt-gq8.43). The elevated window runs a command that checks the file and
  runs its copy in the same console, and Ctrl+C reaches both: the copy kept its code, but the
  command was stopped after the copy ended and exited 1, which the window that asked for elevation
  reported as an app that could not be installed or removed. The command now passes the copy's exit
  code on with `$host.SetShouldExit` (exit 5 when it is stopped before the copy starts). The
  installer had this since its checked copy (work-order item 10); the uninstaller since it runs one.
- `build/Build-WingetInstallScript.ps1 -Check`, and so the pre-commit hook, compares each generated
  script with the build ordinally (review of wgt-gq8.43). It used `-ne`, which ignores letter case,
  and culture comparison also ignores characters such as U+00AD (soft hyphen) and U+200B, so a hand
  edit that only changed case, or typed a soft hyphen into a command name, which breaks that
  command, passed both.
- The documentation matches the code again (work-order item 29, review findings P3-51, P3-52). The
  readme no longer says the installer "trusts the required Winget sources" and "installs or
  updates" the apps: there is no source-trust step, and an installed app is skipped. It documents
  the Endpoint Central scripts (setup, the pins, the user phase, the TightVNC variables, the health
  probe and the at-logon fix), the environment checks, `-CollectDiagnostics` and the SYSTEM E2E
  leg. STATUS.md tells #279, #283 and #284 as they were: the installer's own `RUN_WAU=YES`, fixed
  on this branch and verified by the E2E run of 2026-10-05, not a runner-image defect.
  `Install-WingetPackage`'s help and a test comment now call 0x80073D19
  `ERROR_DEPLOYMENT_BLOCKED_BY_USER_LOG_OFF`, and a new test in `tests/WingetResultCodes.Tests.ps1`
  fails when a file in the repository writes a known code next to a symbol other than the one
  `Get-WingetExitCodeInfo` gives it. CLAUDE.md lists `rmm/`, the third E2E leg and the current test
  stand-ins, and the E2E workflow's header no longer cites a 259-test suite.
- TightVNC is no longer reported as installed while its server refuses every viewer (review finding
  P2-22, work-order item 18). winget installs `GlavSoft.TightVNC` with no password, so the server
  answered every viewer with "Server is not configured properly", and with no control password any
  signed-in user could reconfigure or stop it from its tray icon; the run said `Successfully
  installed` and exited 0, and later runs skipped it as already installed. The catalog entry now has
  a `postInstall` hook, `Set-TightVncServerPassword` (`WingetAppSetup/Private/TightVnc.ps1`):
  - The password comes from `WINGET_APP_SETUP_TIGHTVNC_PASSWORD` (and the control password from
    `WINGET_APP_SETUP_TIGHTVNC_CONTROL_PASSWORD`, optional) in the run's environment, read at the
    start of the PowerShell 7 run and removed from its environment before it starts winget or any
    installer (`Initialize-TightVncSecretForRun`, `Import-TightVncSecretFromEnvironment`); processes
    started before that, such as the Windows PowerShell 5.1 bootstrap and its PowerShell 7 install,
    keep a copy. Without it, an interactive run asks for it at its start, before anything is
    installed (`Read-Host -AsSecureString`, twice, Enter to skip), and only when TightVNC Server has
    no password yet; the prompt waits at most 5 minutes for someone to start typing
    (`Wait-TightVncPromptAnswer`), since the run holds the run lock meanwhile, and is not shown when
    PowerShell was started with `-NonInteractive` (`Test-PowerShellHostNonInteractive`), where
    `Read-Host` throws. A non-interactive run never asks. It is never taken from the repository.
    The passwords are dropped on every way out of the run, early exits (2, 3) and aborts included,
    so an `irm | iex` console does not keep them.
  - It is written straight to `HKLM\SOFTWARE\TightVNC\Server` (`Password` and `ControlPassword` as
    8-byte `REG_BINARY` values in VNC's DES encoding, `ConvertTo-TightVncPasswordBytes`;
    `UseVncAuthentication` and `UseControlAuthentication` set to 1), never through MSI properties or
    `tvnserver -setservicevncpass`, whose command lines winget and MSI logs record, and through the
    .NET registry API (`Set-TightVncServerValue`), not `New-ItemProperty`, whose parameter values
    PowerShell module logging records. Without a control password, a separate control password the
    server already has is kept; otherwise the server password protects the control interface too,
    with a warning. A password longer than 8 characters is used with a warning that TightVNC reads
    only the first 8; one with a character that is not printable ASCII is refused.
  - Before a password goes in, and whenever the key already holds one, the key is limited to
    SYSTEM and Administrators with no inherited permissions (`Protect-TightVncServerKey`, checked by
    `Get-TightVncServerKeyAclProblem`), since the stored value is reversible. The values are read
    back, then the `tvnserver` service is restarted (`Restart-Service`, or started when it was
    stopped) and must be running. A `WingetAppSetupRestartPending` value written before the first
    change and removed after the restart makes the retry pass, or the next run, restart a service
    whose restart failed or never happened, instead of reporting the unchanged values as
    configured.
  - Idempotent: a run with the same password changes nothing and does not restart the service, one
    with a different password updates it, and a run without one keeps the passwords a configured
    server already has (and still locks the key).
  - Without a password TightVNC is `Not configured` (`TightVNC installed but NOT configured: no
    server password was supplied. ...`, saying what the server lets through: it refuses every
    viewer, it accepts viewers without a password, or its control interface is unprotected; and the
    summary's `Configuration: NOT DONE` line); the exit code does not change. A step that fails (the
    key cannot be locked, the values do not read back, the service does not restart) makes the app
    `Failed` (exit code 1).
  - The password, its encoded bytes and the bytes already stored are never printed, written to the
    transcript, passed to a cmdlet or put on a command line, and the buffers holding them are
    cleared. A dry run says only whether each variable is set and whether a real run could use it
    (`[DRY-RUN] TightVNC: ... (value not shown)`) and leaves the variables in place.
  - The module now calls `Get-Service`, `Restart-Service` and `Start-Service`, which are listed in
    `build/windows-only-commands.txt` and have stand-ins in `tests/TestHelpers.ps1`.
- The uninstaller no longer reports every app as not installed, removes Winget-AutoUpdate and exits
  0 when winget cannot be started (review findings P2-19, P3-18). `winget-app-uninstall.ps1` is now
  a thin entry script that runs `Invoke-WingetUninstall` (`WingetAppSetup/Public/Uninstall.ps1`),
  with one app at a time in `Uninstall-CatalogApp` (`WingetAppSetup/Private/AppUninstall.ps1`).
  - It sets winget up as the installer does (`Initialize-Winget`) and, when winget still cannot be
    used, removes nothing and exits 2.
  - A check winget could not answer fails the app instead of skipping it as not installed.
  - `winget uninstall` runs with `--silent` through `Invoke-WingetProcess`, under a new 15-minute
    `WingetUninstall` limit. An uninstaller that returns 3010 or 1641, which winget reports as
    `0x8A150030`, counts as removed (`Test-WingetUninstallRestartRequiredResult`).
  - Catalog conditions are honoured (`Test-AppApplicability`), and PowerShell 7 and Windows
    Terminal are kept when the run depends on them (`Get-HostingShellSkipReason`).
  - Once Windows Terminal is gone, the default-terminal setting that still names it is removed
    (`Reset-WindowsTerminalDelegation`).
  - Winget-AutoUpdate is removed last, and only when no app failed; the messages saying it was kept
    appear only when it is installed.
  - New `-WhatIf` and `-NonInteractive`. Exit codes: 0 done, 3010 done with a restart to finish,
    1 an app or Winget-AutoUpdate failure, 2 winget unusable, 3 invalid or empty app list, 4 not
    elevated, 5 an unexpected error or a module that could not be loaded. It used to exit 0
    always.
  - Since changed: the uninstaller is now a generated single file (see Changed), so it loads no
    module, and exit 5 covers a run without a script file and a file that changed before its
    elevated run instead.
- Catalog applicability is decided once per run, fails open, and no longer reports a missing app
  as installed (review findings P3-32 to P3-35).
  - Each condition is evaluated once, before anything is installed and before the Windows Terminal
    step writes HKCU, by the new private `Test-AppApplicability`, and both passes use that verdict
    (`Install-AppWithVerification -Applicable`). The retry pass used to evaluate it again and
    report a `not applicable` answer as `Retry succeeded` and Installed (exit 0, app missing); it
    now counts such a result as Skipped.
  - A condition that throws or writes an error is treated as applicable, so the install is
    attempted. `Get-ComputerManufacturer` now uses `-ErrorAction Stop` and throws on an empty
    manufacturer, so a CIM error no longer skips Dell Command Update on a Dell PC with exit 0.
  - Windows Terminal's default-terminal values count as "Windows Terminal hosts this session" only
    while Windows Terminal is installed, and `Test-WindowsTerminalInstalled` now asks for exactly
    `Microsoft.WindowsTerminal`, so a removed Windows Terminal is installed again instead of being
    skipped on every run.
  - ARM64 PCs no longer fail Adobe Acrobat Reader on every run. The catalog installs
    `Adobe.Acrobat.Reader.32-bit` (x86, the build Adobe supports on Windows on ARM) on ARM64 and
    `Adobe.Acrobat.Reader.64-bit` everywhere else, and reports the other one as not applicable. The
    new private `Get-OSArchitecture` reads `RuntimeInformation.OSArchitecture`. (Since changed: the
    split uses `arch` lists, and 32-bit Windows gets the 32-bit Reader; see Changed.)
- Setting winget up is one step that diagnoses a failure once, instead of three ladders that ran
  back to back and gave one cause three diagnoses (review findings P3-25 to P3-31). On the #279
  wedge (E2E run 36384683838) the run used to say 'Installations may fail with 0x80073D19', then
  'source "winget" appears to be missing', then print a source.msix rejection and manual steps,
  after running `Repair-WinGetPackageManager` up to four times and downloading App Installer from
  aka.ms/getwinget. `Initialize-Winget` (`WingetAppSetup/Public/WingetCore.ps1`) replaces
  `Test-AndInstallWinget`, `Initialize-WingetSourcesForUser` and `Test-WingetSources`: it checks
  App Installer's Group Policy, then `winget --version`, then `winget source update --name winget`,
  picks the fix from the exit code, runs each fix at most once a run, and prints one line with the
  cause and what to do when it cannot fix it.
  - **Group Policy** (P3-30). When `EnableAppInstaller`,
    `EnableWindowsPackageManagerCommandLineInterfaces` or `EnableDefaultSource` is 0 under
    `HKLM\SOFTWARE\Policies\Microsoft\Windows\AppInstaller`, or winget answers
    `0x8A15003A BLOCKED_BY_POLICY` (no longer checked again for 75 seconds), the run stops with
    exit code 2 and names the policy, instead of repairing App Installer, resetting the source,
    installing Winget-AutoUpdate and blaming 0x80073D19 or a corrupted source.
  - **Codes, not text** (P3-27). The 0x80073CF3 (missing framework) and 0x80073D06 (newer
    framework) classifiers only read `Repair-WinGetPackageManager`'s message, which never holds
    those codes ('Failed to repair winget. Try running with -AllUsers in administrator mode.'), so
    the framework advice never printed. The codes are now read from the HRESULT of what the App
    Installer registration and the repair throw (`Get-AppxErrorCode`), and whether the framework
    is missing comes from the all-users check `Get-WindowsAppRuntimeStatus` already makes. The
    forced repair (`-Force`, which only closes running App Installer processes) no longer runs
    when those codes, from the registration or the repair, or a missing framework the all-users
    repair could not install, already explain the failure: on the wedge it ran anyway, and
    downloaded App Installer once more.
  - **`-AllUsers`** (P3-28). When that check finds `Microsoft.WindowsAppRuntime.1.8` missing, the
    repair runs `Repair-WinGetPackageManager -AllUsers -Latest` first, as the cmdlet asks; never
    otherwise, since it aborts with 0x80073D06 on a PC with a newer framework (#265). A source
    update that times out or fails for any reason other than 0x80073D19 or a missing or corrupted
    source no longer gets App Installer registered or repaired.
  - **Microsoft.WinGet.Client only when needed** (P3-26). The module (and the NuGet provider) was
    installed from the PowerShell Gallery on every first run, for a repair that rarely runs, with
    two warnings about an 'Update functionality' that no longer exists when the Gallery was
    blocked. It is now installed inside the repair step, the first time a run needs it.
  - **App Installer listed and registered through Windows PowerShell** (P3-29). Under PowerShell 7
    the registration step lists the App Installer packages (`Get-DesktopAppInstallerPackageInfo`,
    `Get-AppxPackage -AllUsers`) and registers them (`Invoke-AppxRegistration`,
    `Add-AppxPackage`) in Windows PowerShell. The Appx module both cmdlets come from cannot load
    in PowerShell 7 on Windows 10 and Windows Server 2022 (0x80131539, seen on Server 2022), so the
    step failed there at the listing and would have failed at the registration; it only worked
    once `Repair-WinGetPackageManager` had loaded Appx into the session.
  - The source is reset (`winget source reset --force`, its exit code reported) only for a missing
    or corrupted source (`0x8A15000B`, `0x8A15000F`, `0x8A150012`, `0x8A150015`, `0x8A15003F`),
    which the exit-code table now marks as `SourceBroken`. `0x8A150046` (agreements not accepted)
    is no fault: every install accepts them.
  - No winget call before elevating: the source update the non-elevated window made set up the
    signed-in user's source, not the account the elevated run installs as.

- The Winget-AutoUpdate MSI can no longer be swapped between its hash check and `msiexec`, and the
  modules the installer adds for all users now come only from the PowerShell Gallery (review
  findings P2-21, P3-20).
  - **Folder owner.** The installer's first, non-elevated launch creates
    `%ProgramData%\winget-app-setup` for its log, so the signed-in user owned it. The #186 lockdown
    (`icacls /inheritance:r /grant`) removed only inherited entries, and a folder's owner can always
    change its access list, so that user (or malware running as them) could give themselves full
    control again, replace the per-run `wau-msi-<guid>` folder and swap the MSI before `msiexec`
    ran it elevated. `Set-RestrictedDirectoryAcl` now makes Administrators the owner first
    (`/setowner *S-1-5-32-544`), then removes the inherited entries and replaces the SYSTEM and
    Administrators grants (`/grant:r`), with `/q`. `Assert-RestrictedDirectoryAcl` then reads the
    result back with `Get-Acl` and fails unless the owner is Administrators or SYSTEM, inheritance
    is off and every entry belongs to SYSTEM or Administrators (an explicit entry another account
    added survives `/grant:r`). When it fails nothing is downloaded: the run says `Winget-AutoUpdate
    was NOT installed`, names the owner or entry at fault and how to reset the folder (`takeown /f
    ... /a`, then `icacls ... /reset`; since replaced by renaming the folder aside with `ren`,
    which follows no link, wgt-gq8.46), and the summary shows `Auto-updates: FAILED`. Only these
    failures carry that advice (`Set-RestrictedDirectoryAcl` tags them with the error id
    `RestrictedDirectoryAclFailed`); when the folder cannot be created or `icacls` does not start,
    the run gives that reason without it.
  - **MSI held open.** After the download the MSI is opened once with read-only sharing
    (`Open-ReadLockedFile`), hashed from that open stream and kept open until `msiexec` has
    finished, so it cannot be overwritten, renamed or deleted in between. It is closed before the
    staging folder is removed.
  - **Logs.** Only the folders themselves are changed (no `/T`, no `/reset`), so the read grant for
    standard users on the `logs` folder inside `%ProgramData%\winget-app-setup` stays, and the
    logs still open by their full path. (Since wgt-gq8.46 that grant is part of the `logs`
    folder's own lock.)
  - **PowerShell Gallery only.** `Install-Module` for Microsoft.WinGet.Client and
    Microsoft.PowerShell.GraphicalTools passes `-Repository PSGallery`: both run elevated and
    install for all users, so another repository registered on the machine can no longer serve
    them. `Install-PackageProvider` has no `-Repository` parameter and is unchanged. The module
    versions are still not pinned.
  - `Get-Acl` is added to `build/windows-only-commands.txt`, and `tests/TestHelpers.ps1` gets a
    stand-in for it.
- A run that is not elevated now waits for the elevated run it starts and exits with its exit code,
  never shows a UAC prompt when nobody is at the console, and has the elevated window run a checked
  copy of the installer (review findings P2-11, P2-12, P3-11). New exit code 4: administrator rights
  are required and the run was not elevated.
  - **Exit code.** `Invoke-WingetInstall` returned 0 as soon as it had asked for elevation, before
    anything was installed, so a script or RMM tool saw success whatever the elevated window did.
    `Restart-WithElevation` now starts the elevated process with `Process.Start` (ShellExecuteEx,
    `runas`), waits for it and returns `@{ Started; ExitCode }`, and the run that asked exits with
    the elevated run's code. The elevated window has already shown its summary (or why it stopped)
    and waited for a key press, so the first window adds no second notice.
  - **No unattended prompt.** A non-interactive run (`-NonInteractive`, a non-interactive session,
    or redirected input) that is not elevated now exits 4 without a UAC prompt; it used to leave a
    prompt on the signed-in user's desktop and exit 0 within seconds. `Restart-WithElevation` itself
    refuses to prompt in a non-interactive session too, for its other caller.
  - **Declined prompt.** A declined UAC prompt (Win32 error 1223, `ERROR_CANCELLED`, read from the
    exception rather than its translated message) now exits 4 after one prompt; the Windows
    Terminal branch used to retry with a second prompt. The irm | iex and imported-module cases,
    which cannot relaunch, also exit 4 instead of 1.
  - **Relaunch host.** The elevated window is always System32's `powershell.exe`, which every
    account has. It used to be `wt.exe` (resolved through the signed-in user's app aliases) running
    a bare `pwsh.exe`, or a bare `pwsh.exe` as the fallback: with cross-user elevation and
    PowerShell 7 installed as the signed-in user's per-user MSIX, the admin account resolves
    neither, so the elevated window failed to start while the first window had already exited 0.
    The installer's Windows PowerShell 5.1 dispatch now finds or installs PowerShell 7 as the
    elevating account and runs under it in the same elevated window. The Windows Terminal relaunch
    is gone.
  - **Checked copy.** The elevated process used to run `-File <path>` on the first window's file,
    which on the Windows PowerShell 5.1 one-liner is a copy in the signed-in user's `%TEMP%`: that
    user, or malware running as them, could rewrite it while the UAC prompt was up. The entry
    script now takes the file's SHA256 at startup. Before elevating, `Restart-WithElevation` reads
    the file once, checks it against that hash and stages those bytes in the account's own
    `%TEMP%`, which administrators can read even when the elevating account cannot see the original
    (drive mappings belong to the signed-in session; a share may be out of its reach), and removes
    them once the elevated run has ended. The elevated process runs a short command given on its own
    command line (`New-ElevationVerifierCommand`) that reads the staged file once, compares its
    SHA256, writes those bytes into a new folder under `%SystemRoot%\Temp` with its own access list
    (SYSTEM and Administrators only, nothing inherited) and runs that copy. A file that changed
    since startup is not run (exit code 5). The check cannot live in the file itself, since a
    replaced file would not contain it, and the copy has to be made by the elevated process: a
    non-elevated process cannot create a folder that it cannot change itself. The access list
    leaves out the elevating account's own entry, which in same-account elevation (Admin Approval
    Mode) would let that account's non-elevated processes rewrite the copy until the elevated
    PowerShell 7 reads it. Same-account elevation is not a security boundary all the same (the
    non-elevated processes build the elevated command line), so this protects the cross-user case.
    The paths in that command are quoted with `CodeGeneration.EscapeSingleQuotedStringContent`, so
    a typographic apostrophe in a profile folder name (U+2019, as in a curly `O'Brien`) cannot
    break it.
  - **Uninstaller.** `winget-app-uninstall.ps1` gets the same relaunch (System32 Windows PowerShell,
    waits, exits with the elevated run's code, 4 when declined or non-interactive). It runs its own
    file in place (`Restart-WithElevation -InPlace`), because it imports the module from its folder,
    so it gets no checked copy: the elevated window runs whatever the script and the
    `WingetAppSetup` folder next to it hold when it starts. Run it from a folder only
    administrators can change, or from an elevated session, when another account approves the
    prompt. (Superseded: the uninstaller is now generated as one file and runs a checked copy too,
    and `-InPlace` is gone; see Changed.)
  - The readme's exit-code table also gains code 7 (the PowerShell 7 bootstrap failed), which the
    installer has returned since the bootstrap hardening but the table still listed under 1.

- An install that hits another installation in progress now waits for it instead of failing at
  once, a run that needs a restart to finish says so and exits 3010, and winget's exit codes are
  named everywhere they are printed (review findings P2-15, P3-16):
  - **Another installation in progress.** Windows Installer refuses a second installation at once
    with `msiexec` 1618, which winget reports as `0x8A150102`. On a freshly enrolled PC that made
    an app fail after one launch with no wait, reported as
    `package not found after install; winget exit 0x8A150102`. `Install-WingetPackage` now waits
    until Windows Installer is idle (`Wait-WindowsInstallerIdle`, which checks every 15 seconds
    whether an installation owns the `Global\_MSIExecute` mutex) and retries, up to 3 times. The
    check (`Test-WindowsInstallerBusy`) tries to take the mutex without waiting and releases it at
    once when it can, the test PSAppDeployToolkit makes: the mutex lives as long as any process
    holds a handle to it, so a check for its existence alone could read busy with no installation
    running and spend the whole wait. An abandoned mutex counts as idle. All of a run's waits, the
    Winget-AutoUpdate `msiexec` included (which now also waits out 1618 instead of reporting
    `Auto-updates: FAILED`), share one 10-minute budget that `Invoke-WingetInstall` passes down
    through `Install-AppWithVerification` and `Install-PowerShellLatest`, so a machine that stays
    busy costs a run 10 minutes at most.
  - **In use.** `0x8A150101`, `0x8A150103` and `0x8A150111` (the app or its files are in use) get
    one retry after 60 seconds.
  - **Restart before installing.** `0x8A15010A` (for example Inno setup exit 8 while a Windows
    Update restart is pending) is no longer retried in the retry pass, where it could only fail
    again; the summary says
    `Restart: REQUIRED before <app> can install - restart this PC, then re-run the installer.`
  - **Restart to finish.** winget reports an MSI's 3010 as exit 0 plus a console warning, and the
    run used to report a plain success with no notice. `Install-WingetPackage` returns
    `RestartRequired` for winget's `Restart your PC to finish installation.` warning (English
    display language only), `0x8A150109` (winget 1.6 and older) and `0x8A15010B` (MSI 1641), all
    read by `Test-WingetRestartRequiredResult`, and `Install-WingetAutoUpdate` for its `msiexec`
    3010. On a run started from Windows PowerShell, the PowerShell 7 bootstrap reads its own
    install the same way (the MSI's 3010, or winget's restart result): it says
    `Restart: REQUIRED to finish the PowerShell 7 installation - restart this PC before it is used.`
    after the PowerShell 7 run and turns that run's 0 into 3010, because the PowerShell 7 run checks
    the pending-restart state only after that install. `Invoke-WingetInstall` also reads Windows'
    pending-restart state (`Get-PendingRestartState`: component servicing, Windows Update, and the
    file replacements queued in `PendingFileRenameOperations`, leaving out queued deletes) before
    and after the run. A run that needs a restart prints
    `Restart: REQUIRED to finish this run - restart this PC before it is used (...)` and returns
    exit code 3010 when nothing failed and winget still works (`Get-InstallerExitCode`: 1 > 2 >
    3010 > 0, with room for code 8 between 2 and 3010; codes 8 and 9 came later, so the order is now
    1 > 2 > 9 > 8 > 3010 > 0). A restart that was already pending before
    the run is reported at the start and next to the summary, without making the run 3010. An
    installed app whose winget exit code was not 0 now says so instead of the code being dropped.
  - **Named codes.** `Get-WingetExitCodeInfo` (`WingetAppSetup/Private/WingetResultCodes.ps1`) is
    one table of the winget exit codes the installer knows, with winget's symbol, a meaning and a
    class that drives the retries above. `Format-WingetExitCode` prints `0x8A150102
    INSTALL_INSTALL_IN_PROGRESS` wherever a winget exit code is printed (failure reasons, the
    `winget list` check, `winget --version`, the source update and reset, `winget download`, the
    PowerShell 7 bootstrap's winget install). When winget reported why an install failed, the
    failure reason now starts with what the code means, for example
    `another installation was in progress (Windows Installer was busy) - re-run the installer once it has finished`,
    or `winget install failed` for a code the table does not know, instead of
    `package not found after install`, which is kept for an install winget reported as successful.
- A run on a machine where winget cannot be started now stops trying after one app, instead of
  spending about 24 minutes on retries and then reporting every app as
  `package not found after install` (review findings P2-8, P2-9, P2-10, P3-7, P3-8, P3-9, P3-10):
  - **Launch check.** The new private `Test-WingetLaunchable`
    (`WingetAppSetup/Private/WingetLaunchResilience.ps1`) runs `winget --version` under a
    30-second limit and counts winget as usable only when it exits 0 and prints a version (a line
    starting `v` and a digit). It can check again after a delay for a failure that may clear on
    its own (a locked `winget.exe`, a timeout, a non-zero exit); winget missing or `Access is
    denied` is final at once. `Test-AndInstallWinget` uses it instead of `Get-Command winget`,
    which only proved that the app-execution alias is on PATH: a run on E2E run 35406706712 printed
    `Winget bootstrapped successfully` after both repair attempts had failed, and every winget call
    after it failed. A winget that is on PATH but cannot run now goes down the same bootstrap
    ladder, and the run exits 2 when nothing makes it start. Before the first rung, a failure that
    may clear on its own gets up to six tries 15 seconds apart (the 75 seconds the install's launch
    retries cover), so App Installer is not re-registered or repaired while a Store update of it
    is still deploying.
  - **"Could not check" is no longer "not installed".** `Test-WingetPackageInstalled -TimeoutSeconds`
    returns `LaunchFailed` and `LaunchError` when winget could not be started. The per-app
    pipeline no longer installs an app whose pre-check could not run (`PreCheckLaunchFailed`),
    skips the post-install check when winget could not be launched for the install
    (`InstallLaunchFailed`), and says that the post-install check could not launch winget
    (`VerifyLaunchFailed`) instead of `package not found after install`. Each reason ends with the
    launch error, for example
    `winget could not be launched for the pre-install check; launch error: Access is denied`.
    A `winget list` that ran but failed is not "not installed" either: it exits 0 when it lists
    the package and `0x8A150014` when nothing matches, so any other exit code without a match
    returns `CheckFailed`, and the app fails as `PreCheckFailed` (without an install attempt) or
    `VerifyFailed`, for example
    `winget list failed during the pre-install check with exit 0x8A15004B`.
    `Install-WingetPackage` reports any launch failure in its result (`LaunchErrorExhausted`,
    `LaunchError`) instead of throwing for one it does not retry, so it no longer shows up as an
    `Unexpected error`.
  - **Run-level circuit breaker.** After an app could not launch winget, `Invoke-WingetInstall`
    checks once whether winget can still be started (`Invoke-WingetLaunchCircuitBreaker`: up to
    six tries 15 seconds apart, the 75 seconds the install's own launch retries cover, because the
    pre-check and the post-install check do not retry a failed launch and an App Installer update
    in progress outlasts a short check; `Access is denied` or a missing winget after one try). If
    it can, the run carries on and the app gets its retry. If it cannot, the run prints one
    `winget cannot be launched on this machine (...)` line, marks every remaining applicable app
    failed with `not attempted: winget cannot be launched on this machine (see above)` without
    running winget, and skips the retry pass. Not-applicable apps are still skipped. The breaker
    also works inside the retry pass. The worst case on a wedged winget drops from about 24 minutes
    (each app: 9 launches and 75 seconds of backoff, twice) to about 2.5 minutes: at most 75
    seconds of launch backoff for the one app whose install hit the failure, then 75 seconds of
    the breaker's checks; the end-of-run check makes a single try once the breaker has tripped.
    Every check has a 30-second limit, so even checks that hang until their limit keep it to about
    6 minutes. When the pre-check is what fails, the run stops after about 75 seconds. The exit
    code stays 1.
  - **PowerShell's failure reason.** `Install-PowerShellLatest` returns `Install-WingetPackage`'s
    whole result (exit code, attempts, scope fallback, session and launch errors) plus the outcome
    of its own `winget list` check (`VerifyTimedOut`, `VerifyLaunchFailed`, `VerifyCheckFailed`),
    so the summary says why PowerShell failed like it does for every other app instead of
    `installer reported failure`.
    A check that timed out reads `post-install verification timed out`.
  - **End-of-run check.** The check that keeps a run from exiting 0 with winget unusable (exit 2)
    now uses `Test-WingetLaunchable`: up to five tries 15 seconds apart, about the minute
    `Wait-WingetLaunchable` allowed, and it also requires the version output. The
    `winget: NOT USABLE` line now says why, for example
    `(winget could not be started: Access is denied)`.
  - `e2e/Assert-Install.ps1` uses `Test-WingetLaunchable` before its per-app checks (up to seven
    tries 30 seconds apart, about the 6.5 minutes `Wait-WingetLaunchable` allowed, which the
    assertions step's time limit is sized for) and names a launch failure in a failed check's
    detail, and `e2e/TranscriptAssertions.ps1` reads the breaker's line (`WingetNotLaunchable`)
    instead of the removed deadlock line.
- The Windows PowerShell 5.1 bootstrap checks what it downloads, keeps working once PowerShell 7.7
  is the current release, and exits 7 when it fails (review findings P2-17, P2-18, P3-17):
  - **MSI version.** The MSI fallback built its URL from `metadata.json`'s `ReleaseTag`, which
    404s once that is 7.7: PowerShell 7.7 and later ship no MSI. `Get-PowerShell7MsiInfo` now
    picks the newest release below 7.7 from `ReleaseTag` and `LTSReleaseTag` (a list, so it picks
    by version, not position), which is the 7.6 LTS release once 7.7 is current. The installer
    runs on any PowerShell 7.
  - **Signature check.** Before `msiexec` runs, the downloaded MSI must carry a valid Authenticode
    signature whose signer is `CN=Microsoft Corporation` (`Test-PowerShell7MsiSignature`). A web
    page a proxy answered with now gets a clear message instead of `msiexec` exit code 1620.
  - **No `aka.ms` tier.** The `aka.ms/install-powershell.ps1` tier behind the MSI path is gone. It
    reads the same `metadata.json` and downloads the same MSI with no signature check, runs a
    downloaded script with no check, and 404s once `ReleaseTag` is 7.7. It also had no time
    limits, which let it finish a download on a slow link after the MSI path had given up. So the
    MSI download's overall limit is now 60 minutes instead of 15
    (`Install-PowerShell7FromMsi -DownloadTimeoutSeconds`, default 3600). The 60-second stall
    timeout still fails a dead link quickly, and the 15-minute `msiexec` limit is unchanged. The
    #274 throttle message now covers only the `metadata.json` read.
  - **Relaunch download.** An `irm | iex` run has no file to relaunch under `pwsh`, so the
    bootstrap downloads the installer again. It used to fetch raw `main` only and run whatever came
    back: a run started from a branch URL relaunched `main`, and a run started from the jsDelivr
    mirror went back to the throttled raw host. `Get-PowerShell7RelaunchInstaller` now tries
    `raw.githubusercontent.com`, then the jsDelivr mirror, and uses a copy only when its stamped
    build id matches the running build (the entry script passes `$script:InstallerBuildId`). When
    no copy matches, the run says that PowerShell 7 is installed and to run the same one-liner from
    an elevated `pwsh`, which needs no second download.
  - **Exit 7.** Every bootstrap failure, an unexpected error in the bootstrap included, now exits 7
    instead of 1. The early-exit notice explains code 7, and the install-failure issue form lists
    it.
- Setting the Windows Terminal default profile no longer rewrites `settings.json` (review finding
  P2-23). It parsed the file and wrote it back with `ConvertTo-Json`, which deleted every comment
  (including commented-out profiles and admin notes), reindented the file and moved keys, with no
  backup and a success message. Now only the value of the top-level `defaultProfile` changes, or
  the key is inserted before the first top-level key when it is missing
  (`Set-JsoncTopLevelStringProperty`, `WingetAppSetup/Private/Jsonc.ps1`). The edited text must
  parse with every other setting unchanged, or the file is left alone. The original is saved next
  to it as `settings.json.winget-app-setup.bak`. The new content replaces the file from a temp
  file in the same folder, so it is never left half-written. A `settings.json` that is a symbolic
  or hard link (a dotfiles setup) is instead written in place through the link, so the link is
  kept and the linked file gets the change. A UTF-8 byte-order mark and the file's line endings are
  kept, and a file that is not valid UTF-8 is left alone.
- winget and `msiexec` now run through one helper, `Invoke-ExternalProcess` with
  `Invoke-WingetProcess` on top (`WingetAppSetup/Private/ProcessInvocation.ps1`), so every winget
  and `msiexec` call has a time limit, its output reaches the log, and a failed launch is recognized
  in any display language (review findings P2-5, P2-6 and P3-6):
  - **Time limits.** The app installs (`Start-Process -Wait`), `winget download`,
    `winget source list`, `winget search`, `winget source reset`, the `winget list` check called
    without a timeout, and the Winget-AutoUpdate `msiexec` install and uninstall had no time limit,
    so one stuck installer hung an unattended run with no summary and no exit code. Each call now
    has a limit, set in one place (`Get-ProcessTimeoutSeconds`: 30 minutes per install or
    download, 2 minutes for queries, 5 for `source reset`, 15 for `msiexec`). When it runs out, the
    process and every process it started are stopped (`taskkill /T /F`), and an install that did
    not land is reported as failed with `winget install stopped after 30 minutes`. The limit also
    holds for a program that writes output faster than it is read. The WAU MSI download gets
    `-TimeoutSec`, which bounds the connection and the response headers, plus
    `-OperationTimeoutSeconds`, which bounds a stall while the file arrives, on PowerShell 7.4 and
    newer. The per-app 15-second `winget list` check is unchanged. Still without a time limit of
    their own: the cmdlets that set up winget and the summary grid (`Install-Module`,
    `Repair-WinGetPackageManager`, `Add-AppxPackage`, the App Installer download) and, on
    PowerShell 7.3 and older, the rest of the WAU MSI download once the file has started to arrive.
  - **winget's output in the transcript.** winget wrote straight to the console, which
    Start-Transcript does not record, so the log a teammate attached never showed lines such as
    `Installer failed with exit code: 1603`. Output is now captured and echoed into the transcript
    as it arrives, under a `> winget ...` line with the full command line, without the spinner and
    with only the last line of each progress bar. A message winget shows next to its spinner, such
    as `Waiting for another install/uninstall to complete...`, is logged once, not at each of its
    four redraws a second. Each `winget install` also passes `--log`, so the installer's own log
    is written to the logs folder as `winget-install-<package id>-<timestamp>.log`, and a failed
    app's reason names it. The source
    probes print winget's output when they fail. Exit codes come from the process object, never
    from `$LASTEXITCODE`.
  - **Launch failures in any language.** The transient "file cannot be accessed by the system" and
    "being used by another process" launch failures were recognized by their English text, so on a
    German or French Windows every launch retry gave up on the first failure. The helper reports
    the Win32 error code of a failed launch (32 and 1920 for these two, 2 not found, 5 access
    denied), `Test-TransientWingetLaunchError` classifies by that code, and a message without a
    code is also matched against the texts Windows gives those codes in its own display language.
  - **Unattended installs pass `--silent`.** In a non-interactive run (`-NonInteractive`, a
    service, a scheduled task, redirected stdin) winget gets `--silent`, so MSI and WiX packages
    install with `/quiet` instead of `/passive` and Inno installers run `/VERYSILENT`. The same
    applies to the PowerShell 7 bootstrap's winget install and to the catalog's PowerShell install
    (`Install-PowerShellLatest`), whose failure reason also names a stopped install and its
    installer log.
  - **`winget source list` and `winget source reset` no longer pass `--accept-source-agreements`.**
    Neither subcommand accepts it, so winget rejected both with 0x8A150002: the reset never ran,
    and the usage text the rejected `source list` printed contains the word winget, so a missing
    source still read as listed. A failed reset is now reported with its exit code instead of
    `Source reset completed.`

  Covered by `tests/ProcessInvocation.Tests.ps1`, which runs the helper against real programs on
  Linux and Windows (time limit, stopping a process tree, a child that keeps the output pipe open,
  closed stdin, transcript capture), and by seam tests that every winget and `msiexec` call site
  goes through it. Still to confirm on real Windows: that the winget app-execution alias launches
  this way with redirected output, and how winget's output reads when it is piped.
- The E2E install workflow now reports every failed scheduled run and every failed run dispatched
  on `main`, with the evidence needed to diagnose it (review findings P2-4, P3-1). The failure issue
  used to be filed by a step inside the Windows job that ran under PowerShell 7 with
  `if: failure()`. Run 35566866223 removed PowerShell 7, so that step died with
  `pwsh: command not found` and the failure was never reported. A job that hits its time limit is
  cancelled, which `failure()` does not match, so a hung run never filed one either. A separate
  `report-failure` job on `ubuntu-latest` now works from the uploaded artifacts and creates or
  comments on `E2E install run failed` when the run fails, times out or is cancelled. The issue
  lists which installer ran, the steps that did not succeed and how long each ran, the assertion
  PASS/FAIL table, the last 50 lines of the earliest and latest transcripts, and the diagnostics
  snapshots; the same text goes to the run's summary page. `issues: write` moved from the whole
  workflow to that job, so the Windows job that runs the installer no longer holds it. The
  assertions also run after a failed install pass. The install passes, the assertions and the job
  have time limits (35, 35, 40 and 130 minutes), so a hung step fails at its own limit and the
  diagnostics and uploads still run. The new `e2e/Collect-Diagnostics.ps1` runs in Windows
  PowerShell 5.1 before the first pass, after it and at the end of the job. It records the pwsh
  versions, the App Installer and `Microsoft.WindowsAppRuntime*` AppX packages registered for any
  user or provisioned, and the `\WAU\` tasks with their last run; at the end it adds MsiInstaller
  and RestartManager events, AppX deployment errors and warnings, and Winget-AutoUpdate's logs. It
  always exits 0, so it never fails the job. The snapshots and the assertion output are uploaded as
  the `e2e-diagnostics` artifact. Red runs that kept only transcripts were misdiagnosed twice
  (#279, #283). Covered by `tests/E2EDiagnostics.Tests.ps1`.
- Failed runs can now be debugged from what the teammate attaches (review findings P2-13, P2-14,
  P3-12, P3-13, P3-14 and P3-15):
  - **Early exits explain themselves.** Every early exit (a failed pre-flight check, winget
    missing, a declined elevation, a bad catalog, a failed PowerShell 7 bootstrap, an aborted run)
    goes through `Exit-Installer`, which prints one block: the exit code and why, the log file
    path, the installer build and where to report it, with a privacy note. When someone is at the
    console it then waits for a key press; under `irm | iex` the exit ends the PowerShell window,
    which used to close before anyone could read the error. Non-interactive and CI runs never wait
    (`Test-IsContinuousIntegration` checks `CI`, `GITHUB_ACTIONS` and `TF_BUILD`), and a run that
    reached its summary adds nothing after its own final prompt. The irm | iex non-admin path no
    longer sleeps 5 seconds before exiting. Exit codes are unchanged.
  - **The Windows PowerShell 5.1 bootstrap is logged.** It writes its own transcript,
    `install-<timestamp>-bootstrap.log`, next to the PowerShell 7 run's, ending with the exit code
    the relaunched run returned; the PowerShell 7 install (winget, MSI, aka.ms fallback), GitHub
    throttling and relaunch errors used to leave no log at all. The PowerShell 7 MSI install
    writes a verbose `msiexec` log (`pwsh-msi-<timestamp>-<attempt>.log`) there too, and waits 30
    seconds and retries, up to 6 times, when `msiexec` returns 1618 (another installation in
    progress), which it does at once on a freshly enrolled machine still installing its agents.
  - **Logs stay readable from the end user's session.** Installing Winget-AutoUpdate makes
    `%ProgramData%\winget-app-setup` admin-only, and that reached the `logs` folder, so a teammate
    who elevated as an admin got Access Denied opening the log from the end user's session. Every
    elevated run now grants `BUILTIN\Users` read access to the `logs` folder only
    (`Grant-InstallLogReadAccess`, since replaced by the `logs` folder's own lock,
    `Set-RestrictedDirectoryAcl -ReadableByUsers`, wgt-gq8.46); the WAU staging folder's lockdown
    is unchanged.
  - **Tables are written at full width.** `Write-Table` renders with `Out-String -Width 4096`, so
    the summary and failed-apps tables are no longer cut off at 120 columns in transcripts and
    captured output (issue #284's failed list dropped `Microsoft.PowerShell` that way) or empty
    without a console. This also fixes the known Linux test failure in `Logging.Tests.ps1`.
  - **The build id covers the whole installer.** It is now the SHA256 of the whole generated
    script with the id slots blanked, not only of the functions, so a change to
    `build/fragments/head.ps1` or to the code of `tail.ps1` gets a new `Installer build:` id.
  - **An issue form for install failures** (`.github/ISSUE_TEMPLATE/install-failure.yml`) asks for
    the exit code, the installer build, the target (cross-user, fresh 5.1 machine, SYSTEM) and the
    log file, and tells the reporter to remove the transcript header (it names the computer and
    the accounts) because the repository is public; readme.md's new "When a run fails" section
    says the same.
- A `-WhatIf` dry run no longer changes the machine (review finding P2-16). It printed "No system
  changes will be made", but its setup steps ran their real fixes: on a machine missing them it
  installed the NuGet provider, `Microsoft.WinGet.Client` and `Microsoft.PowerShell.GraphicalTools`
  for all users, registered, repaired or downloaded App Installer for the account, and ran
  `winget source reset --force` on an unhealthy source, which also removes any source added beyond
  the defaults. `Test-AndInstallWingetModule`, `Test-AndInstallWinget`,
  `Test-AndInstallGraphicalTools` and `Test-WingetSources` now take `-WhatIf`: they only check, and
  print a `[DRY-RUN]` line naming the fix a real run would make. A dry run on an account without
  winget (the cross-user elevation case) carries on with the preview, since a real run would set
  winget up first; it skips the source check and says that it cannot tell which apps are already
  installed. The existing dry-run tests mocked all four helpers, which is how this went unnoticed;
  a new test runs the whole dry run with them unmocked and asserts that no install, AppX,
  download, registry, scheduled-task, `winget` or installer-process command runs.
- `Test-AppDefinitions` now rejects a catalog name that has text after a valid package id, such as
  `Google.Chrome --override "/S"` (review finding P3-49). The package-id pattern had no end anchor,
  so any valid prefix passed, and `Start-Process -ArgumentList` would have handed the rest to
  winget as extra switches. The pattern in `WingetAppSetup/Private/PackageIdValidation.ps1` and
  CLAUDE.md is now `^[\w][\w.\-]+\.[\w][\w.\-]+\z`, anchored with `\z` because .NET's `$` also
  matches before a final newline. Surrounding whitespace is still trimmed first, and the curated
  catalog is unaffected.
- Kept Winget-AutoUpdate from breaking winget after the installer has finished. Dropping
  `RUN_WAU=YES` only moved WAU's `Install-Prerequisites` (newest winget, provisioned without
  `Microsoft.WindowsAppRuntime.1.8`) to WAU's own runs, and WAU 2.12.0 also defaulted to a run at
  every user logon, so a technician signing in to re-run the installer collided with it. WAU is now
  installed (or upgraded) only when that framework is present for this OS architecture
  (`Get-WindowsAppRuntimeStatus`); otherwise the summary shows `Auto-updates: NOT CONFIGURED`, and an
  existing WAU on such a machine is reported as `Auto-updates: AT RISK`. New installs pass
  `UPDATESATLOGON=0`, machines deployed earlier have the at-logon trigger removed and
  `WAU_UpdatesAtLogon` set to 0 on the next run (`Disable-WauLogonTrigger`), and a run that starts
  while a WAU task is running waits up to 15 minutes for it (`Wait-WauIdle`). The schedule is
  described correctly now: weekly on Tuesdays at 02:00, not "weekly at 2 AM". `-WhatIf` previews
  the logon-trigger change on machines that already have WAU, and `e2e/Assert-Install.ps1` expects
  no WAU plus `Auto-updates: NOT CONFIGURED` on runners without the framework (windows-latest,
  until the installer installed the framework itself: see Added).
- An aborted run no longer exits 0. The entry script's top-level `try/finally` (`build/fragments/tail.ps1`)
  had no catch, so inside it a .NET exception, a method call on `$null` or a parameter-binding
  error anywhere in the run aborted everything - no retry pass, no summary - and the process exited
  0; an outside stop (Ctrl+C, or an MSI upgrade of PowerShell sending a console stop, as in #283)
  did the same under `-File`. The entry script now catches unexpected errors, writes the message,
  position and stack trace into the transcript and exits 5; a completion marker in its `finally`
  turns an uncaught stop into exit 5. Both force the exit only when the process was started to run
  the script or the session is non-interactive: in a console where someone typed `irm | iex` or
  `.\winget-app-install.ps1`, the error stays on screen with `$LASTEXITCODE` = 5 instead of the
  window closing. Ctrl+C at the final "Press any key" prompt keeps the run's own exit code, the 5.1
  bootstrap parent no longer exits 0 when stopped, and a declined UAC prompt no longer throws out of
  the run (it exits 4: see the elevation entry above). Every intended exit goes through the new
  `Exit-Installer`, so the guard
  can tell the two apart. Windows Terminal setup, Winget-AutoUpdate setup and the end-of-run winget
  check are each isolated, so one failing helper can no longer skip the summary or the exit-code
  decision, and the 5.1 bootstrap dispatch is wrapped so an error there cannot fall through into
  the PowerShell 7 body.
- Stopped the installer from starting Winget-AutoUpdate's first update pass in the middle of its
  own run, the root cause of the red E2E runs (issues #279, #283, #284). The WAU MSI was installed
  with `RUN_WAU=YES`, so WAU 2.12.0's SYSTEM run began immediately; every such run calls WAU's
  `Install-Prerequisites`, which provisions the newest winget release from GitHub with
  `-SkipLicense` but without the `Microsoft.WindowsAppRuntime.1.8` framework it needs, then runs
  `winget source reset --force` and upgrades apps (PowerShell included). On the Server 2025 runner
  that wedged App Installer for the rest of the job (#279, #284), and the PowerShell upgrade stopped
  the running console (#283); the "Store servicing" and "runner image" explanations were wrong.
  `RUN_WAU=YES` is gone, WAU is now set up after the retry pass so nothing else in the run touches
  winget afterwards, and the up-to-6-minute post-WAU wait is removed. A run also can no longer exit
  0 while leaving winget broken: a single bounded `winget --version` probe at the end reports
  `winget: NOT USABLE` and exits 2 when no app failed (1 still takes precedence), via the new
  `Get-InstallerExitCode`.
- Fixed the installer hanging for 30+ minutes instead of failing fast when winget is deadlocked
  between two conflicting `Microsoft.DesktopAppInstaller` versions (issue #279) — observed twice,
  reproducibly, on independently-provisioned GitHub-hosted E2E runners: a second App Installer
  version appears mid-job alongside the already-working one, and neither can finish registering (the
  newer one depends on a framework, `Microsoft.WindowsAppRuntime.1.8` as of this writing, that isn't
  present; the older one is then rejected by AppX because the newer one is "already installed").
  Unlike the transient alias-lock issue #277/#278 fixed, this is a structural conflict external to
  this installer that no amount of waiting or per-app retrying resolves — previously every catalog
  app independently burned its own retry budget against the same wall, turning a diagnosable dead
  end into a very long hang. A new private `Get-ConflictingDesktopAppInstallerVersions`
  (`WingetAppSetup/Private/WingetLaunchResilience.ps1`) detects the condition via `Get-AppxPackage`;
  `Wait-WingetLaunchable` now gives up immediately instead of polling into it, and
  `Invoke-WingetInstall` checks once before its per-app loop (and again after a failed
  `Wait-WingetLaunchable`, in case the conflict appears partway through) to skip straight to a clear,
  all-apps-failed diagnostic and skip the retry pass, instead of driving every app through the same
  dead end. Best-effort and narrowly scoped: it only short-circuits on a positively-detected version
  conflict, never on ordinary or ambiguous failures. (Superseded on this branch: the second App
  Installer version came from the Winget-AutoUpdate run that the installer's own `RUN_WAU=YES`
  started, not from outside the installer; see the `RUN_WAU=YES` entry above.
  `Get-ConflictingDesktopAppInstallerVersions`, the deadlock gate and `Wait-WingetLaunchable` are
  removed, replaced by the run-level circuit breaker under Fixed; see Removed.)
- Fixed the scheduled end-to-end install workflow failing 3 of its last 4 runs (issue #277). Root
  cause: `Install-WingetAutoUpdate`'s `RUN_WAU=YES` triggers an immediate background WAU update run
  right after WAU installs, and that run's own winget invocations were observed holding the
  app-execution alias unlaunchable for up to ~5.5 minutes — far longer than the existing 75s launch-retry
  budget (issue #258) covers, so the E2E workflow's retry pass, second install run, and
  `e2e/Assert-Install.ps1` post-install checks raced that window on nearly every attempt. Separately,
  `e2e/Assert-Install.ps1`'s `winget list` probe had no exception handling at all around the call
  itself (only around its exit code), so hitting the same broken-alias condition there crashed the
  whole assertion script before any assertion ran — the actual cause of the Aug 24 2026 failure,
  which surfaced as a different-looking message ("StandardOutputEncoding is only supported when
  standard output is redirected") because that call captures output natively instead of going
  through `Start-Process`. Fixed with: a new private `Wait-WingetLaunchable`
  (`WingetAppSetup/Private/WingetLaunchResilience.ps1`) that polls a cheap `winget --version` launch
  until it succeeds instead of guessing a fixed sleep, called once right after
  `Install-WingetAutoUpdate` returns `Configured` so later winget calls in the same run no longer
  race the window at all; `Test-TransientWingetLaunchError`'s classifier now also matches the
  `StandardOutputEncoding` message; and `e2e/Assert-Install.ps1`'s probe loop now waits for winget to
  become launchable before starting and tolerates (instead of crashing on) a launch exception during
  its own per-app retries.
- Fixed winget bootstrap aborting outright when the machine carries a newer framework package than
  the WinGet release pins (issue #265). `Repair-WinGetPackageManager -Latest -Force` deploys the
  dependencies pinned to the release it installs, so on a machine whose
  `Microsoft.WindowsAppRuntime` is already newer — routine wherever Teams / Phone Link / an MDM push
  updates it independently — AppX rejects the downgrade with `0x80073D06`
  (`ERROR_INSTALL_PACKAGE_DOWNGRADE`) and the cmdlet gives up *before* registering App Installer.
  The run still recovers, but only on the last resort: a ~200 MB `aka.ms/getwinget` download, after
  printing a wall of AppX deployment errors that reads like a broken machine. Both
  `Repair-WinGetPackageManager` call sites (`Test-AndInstallWinget`,
  `Initialize-WingetSourcesForUser`) now work through a cheapest-first ladder: the new private
  `Register-WingetAppInstallerForUser` first registers the `Microsoft.DesktopAppInstaller` package
  already staged on the machine for the current account (`Add-AppxPackage -RegisterByFamilyName`,
  falling back to `-Register` against each candidate's `AppXManifest.xml`) — no download, no
  dependency deployment, and the direct fix for the cross-user elevation case where the interactive
  user has a working winget but the elevating admin account has no per-user registration and hence
  no `winget.exe` alias. Only if that fails does the shared `Invoke-WingetPackageManagerRepair` run
  the repair cmdlet unforced-then-forced, and a `0x80073D06` rejection (classified by
  `Test-AppxDowngradeRejection` on the locale-independent hex HRESULT) short-circuits instead of
  retrying with `-Force`, which cannot help and would burn a second multi-hundred-megabyte download.
  `Initialize-WingetSourcesForUser` additionally names the dependency conflict in its remediation
  advice. The `aka.ms/getwinget` download remains the unchanged last resort. This is the same
  per-user-MSIX root cause as issue #263 below, one layer further into the run.
- Fixed the PowerShell 7 MSI fallback blocking indefinitely with no output, which reads as a hang
  (issue #263). On a machine where the invoking account has no winget — the classic case being a
  secondary admin account, since winget is a per-user MSIX — `Invoke-PowerShell7Bootstrap` handed
  the whole install to `aka.ms/install-powershell.ps1 -UseMSI -Quiet` and went silent. That script
  sets `$ProgressPreference = 'SilentlyContinue'` on Windows PowerShell, downloads the 110 MB MSI
  with a bare `Invoke-WebRequest -OutFile` (which has **no read timeout** under 5.1), logs its
  install step through a `Write-Verbose` that never prints, and waits on `msiexec` forever — so
  between `About to download package from...` and the next visible line there was a 110 MB download
  plus a full MSI install with zero output. Measured on a real link that is 3.5 minutes of silence
  on a *healthy* run, and unbounded on a stalled one, with nothing to tell the two apart. The
  bootstrap now downloads and installs the MSI itself first (`Install-PowerShell7FromMsi`), falling
  back to the upstream script only if that fails (a later change removed that fallback; see the
  P2-17 entry above): the release is resolved from the same
  `tools/metadata.json` the upstream script reads (not the rate-limited GitHub releases API, whose
  unauthenticated budget is per source IP and so is shared by everyone behind one office NAT), the
  architecture comes from `PROCESSOR_ARCHITEW6432`/`PROCESSOR_ARCHITECTURE` rather than a
  seconds-long `Get-ComputerInfo` call, and the download runs through the new
  `Save-WebFileWithTimeout` — an `HttpWebRequest` whose `ReadWriteTimeout` bounds every individual
  read on the response stream (the guarantee `Invoke-WebRequest` cannot give), plus an overall time
  limit for a link that trickles without ever formally stalling, periodic `X of 110.2 MB (N%)`
  progress lines, WinINET proxy credentials so an authenticating corporate proxy fails visibly
  instead of looking like another stall, and a short-read check so a truncated MSI is reported here
  rather than as an opaque msiexec failure. `msiexec /i <msi> /quiet /norestart` then runs under a
  bounded `WaitForExit` (killed and reported on timeout, the usual cause being another install
  holding the Windows Installer mutex), with exit code 3010 treated as success. The two
  `Invoke-RestMethod` calls in the same function — the upstream-script fetch and the `irm | iex`
  installer re-download — gained `-TimeoutSec` for the same reason. Verified against real Windows
  PowerShell 5.1: a full 110.2 MB download completing byte-exact with a valid MSI header, the
  overall-limit abort stopping a download mid-stream instead of hanging, and DNS-failure/404 paths
  returning `$false` rather than throwing. This closes the gap issue #230 left open — the run no
  longer *asks* anything, but it could still park forever with no way to tell slow from dead.
- Fixed the winget launch retry never recovering when the `winget.exe` app-execution alias breaks
  mid-run (issue #258): E2E run 30253761253's second (idempotence) pass failed
  `Microsoft.WindowsTerminal` — an app that was already installed — because a background
  Winget-AutoUpdate run (started by the installer itself via `RUN_WAU=YES` seconds earlier, and
  capable of upgrading App Installer/winget) invalidated the per-user
  `Microsoft.DesktopAppInstaller` alias for longer than the entire 15s retry window the #253 fix
  covered, so every `Start-Process winget` — pre-check, three install attempts, verify, and the
  whole retry pass — threw `ERROR_CANT_ACCESS_FILE` against the same broken alias. Two changes in
  `WingetAppSetup/Public/WingetCore.ps1` plus the new private helper
  `WingetAppSetup/Private/WingetLaunchResilience.ps1`: (1) launch failures now have their own
  retry budget in `Install-WingetPackage` (`MaxLaunchAttempts`, default 5, doubling backoff
  5s+10s+20s+40s = 75s — sized to outlast an App Installer re-registration; a failed launch no
  longer consumes an install attempt since no process ran, and the result gains a
  `LaunchAttempts` count), and each launch retry re-resolves the executable via
  `Resolve-WingetExecutable -BypassAlias`, launching the registered DesktopAppInstaller package's
  own `winget.exe` directly instead of the broken alias so the retry converges as soon as the new
  package registers; (2) `Test-WingetPackageInstalled`'s timeout-mode check retries once through
  the same alias bypass instead of silently swallowing the launch exception and misreporting an
  installed package as missing — which is exactly how the already-installed Windows Terminal got
  classified as a failed install. A launch failure of a concrete bypass path is always retried
  (even `ERROR_FILE_NOT_FOUND`, since the resolved package version can be deleted mid-backoff by
  the completing upgrade), while a non-transient failure of the plain `winget` alias still
  re-throws so a genuinely missing winget is not masked. Covered by new Pester coverage in
  `tests/WingetLaunchResilience.Tests.ps1` and `tests/WingetCore.Tests.ps1`
  ([#259](https://github.com/J-MaFf/winget-app-setup/pull/259)).
- Fixed `Install-WingetPackage` losing its whole retry budget to a single Start-Process launch
  failure (issue #253): on a scheduled E2E run, `winget.exe` was transiently inaccessible
  (`Start-Process` threw "This command cannot be run due to the error: The file cannot be
  accessed by the system." — Win32 `ERROR_CANT_ACCESS_FILE`, the classic AV-scan/AppX
  registration-race symptom) for every app that actually needed installing, and every one of them
  failed both the first pass and the one-shot app-level retry with zero delay in between. Because
  the exception is thrown before `Start-Process` ever returns a process object, it previously
  bypassed the function's exit-code-based backoff loop entirely on the very first attempt.
  `Install-WingetPackage` now wraps the `Start-Process` call in a `try`/`catch`: this specific,
  known-transient launch exception (plus its `ERROR_SHARING_VIOLATION` sibling) is retried with
  the same increasing backoff already used for the `0x80073d19` session error, consuming the same
  `MaxAttempts` budget and surfaced in the result as a new `LaunchErrorExhausted` flag
  (`ExitCode` is `$null` in that case, since no process ever ran); `Format-InstallFailureReason`
  reports it distinctly instead of a fabricated exit code. Any other launch exception (e.g.
  winget genuinely missing) is re-thrown unchanged. Covered by new Pester coverage in
  `tests/WingetCore.Tests.ps1` and `tests/Install.Tests.ps1`
  ([#257](https://github.com/J-MaFf/winget-app-setup/pull/257)).
- Fixed `-WhatIf` being ignored on the IEX/remote path when the invoking session is not
  administrator: `Invoke-WingetInstall`'s non-admin `else` branch for `Test-IsRunningLocally`
  returning `$false` (`WingetAppSetup/Public/Install.ps1`, every `irm <url> | iex` run, since there
  is no on-disk `$PSScriptRoot`) never checked `$WhatIf` at all — it unconditionally printed "This
  script requires administrator privileges" / "Auto-elevation is unavailable when running through
  IEX/remote execution", slept 5 seconds, and exited 1, unlike the sibling local-file branch which
  already honored `-WhatIf` by continuing the preview in the current non-elevated session. The
  IEX/remote branch now checks `$WhatIf` first and, when true, prints an analogous `[DRY-RUN]`
  message and falls through without elevating or exiting, so a non-admin user previewing the
  documented one-liner gets a dry run instead of an unconditional failure; the non-`-WhatIf`
  behavior on this path is unchanged. Covered by new Pester coverage in `tests/Install.Tests.ps1`.
- Fixed the retry pass in `Invoke-WingetInstall` mislabeling a pre-check timeout as a verification timeout: `Install-AppWithVerification`'s `FailureReason` can be `PreCheckTimeout` (the `winget list` pre-check never completed) or `VerifyTimeout` (post-install verification never completed) — the first pass already prints a distinct message for each, but the retry pass collapsed both into "Verification timed out for retry", telling whoever reads the output that the install itself likely succeeded and only verification couldn't confirm it, when the real story is that the pre-check never ran. The retry pass now branches on `FailureReason` the same way the first pass does, printing "Winget list timed out for retry: ..." for `PreCheckTimeout` and keeping the existing "Verification timed out for retry: ..." wording for `VerifyTimeout`; the generic "Retry failed: ... (reason)" fallback and the `$failedApps` tracking data are unchanged.
- Fixed `Install-PowerShellLatest`'s two self-verification calls to `Test-WingetPackageInstalled` (the MSI-path and native-MSIX-path checks) running without the timeout guard every other catalog app's verification already gets: `Install-AppWithVerification` passes `-TimeoutSeconds 15` on both its pre-check and post-verify calls, but `Install-PowerShellLatest` omitted the parameter entirely, falling through to the untimed inline `winget list` call — a hang there blocked the whole run instead of failing into the retry pass like any other app. Both calls now pass `-TimeoutSeconds 15`, matching `Install-AppWithVerification`'s `$checkTimeoutSeconds`.
- Implemented the package-id regex validation CLAUDE.md's "Winget Notes" section documented but never wired into production code (issue #235): `Test-AppDefinitions` (`WingetAppSetup/Public/AppValidation.ps1`) now rejects any catalog entry whose `name` does not match the `^[\w][\w.\-]+\.[\w][\w.\-]+` publisher.product shape, and `Test-WingetPackageInstalled`'s installed-check (`WingetAppSetup/Public/WingetCore.ps1`) no longer decides "installed" via a plain `.Contains($PackageId)` substring test against raw `winget list` output — a listed id like `Foo.BarBaz` could previously false-positive a `Foo.Bar` installed verdict. Both call sites share one pattern from the new `WingetAppSetup/Private/PackageIdValidation.ps1` (`Test-WingetPackageIdFormat` for shape checks, `Test-WingetListOutputContainsPackageId` for boundary-anchored output matching) so the regex cannot drift between the two places IDs are trusted. The entire curated catalog already matches the shape, so existing behavior is unchanged ([#235](https://github.com/J-MaFf/winget-app-setup/issues/235)).
- Closed a blind spot in the build's undefined-reference guard (full-repo review finding, 2026-07-16): `Get-UndefinedCommandReference` (`build/Build-WingetInstallScript.ps1`) walks `CommandAst.GetCommandName()`, which returns `$null` for the indirect `& $App.install` dispatch `Install-AppWithVerification` (`WingetAppSetup/Private/InstallVerification.ps1`) uses to invoke a catalog-carried function name — so a coordinated rename of e.g. `Install-PowerShellLatest` (updating its definition and the `.psd1`'s `FunctionsToExport`, but leaving `AppCatalog.ps1`'s `install = 'Install-PowerShellLatest'` string stale) passed the parse, ASCII, export, and undefined-reference guards plus `-Check` with zero errors, only breaking at runtime with a `CommandNotFoundException` the moment that one app installed. Chose to extend the build guard (over a Pester-only test, the spec's alternative) because it belongs to the same AST-walking guard family as the existing check, runs on every build and `-Check` rather than only when `Invoke-Pester ./tests` happens to run, and reuses the same defined-function lookup: the new `Get-UndefinedCatalogInstallReference` walks the assembled AST for `HashtableAst` key-value pairs keyed `'install'` with a string-literal value and validates each against the same defined-function lookup (now factored into `Get-DefinedFunctionLookup`, shared by both guards). Reproduced and verified against the exact empirical repro (rename `Install-PowerShellLatest` to `Install-PowerShellLatestX` in its definition and the manifest, leave the catalog string stale): the new check now fails the build with a message naming the stale reference, where it previously passed silently.
- Documented and hardened `Test-WingetSourceHealth`'s corruption detection (`WingetAppSetup/Private/WingetBootstrap.ps1`): the check keeps its original shape — any nonzero exit code fails it, ORed with an output-text match for the one documented scenario the exit code cannot catch (winget reportedly printing the corruption error while returning exit code 0; issues #150/#172/#174/#175/#177). The output regex retains the locale-independent `0x8a150` hex token as its load-bearing signal (an interim rework briefly dropped it, which would have made exit-0 corruption detection English-only; caught and restored by the integration-branch review), with the English "failed when opening"/"data required" phrases kept as extra coverage and explicitly commented as locale-sensitive, mirroring `winget-app-uninstall.ps1`'s locale note (issue #180). A code comment now documents the `0x8A15000F` (`APPINSTALLER_CLI_ERROR_SOURCE_DATA_MISSING`, `-1978335217`) HRESULT by name and value. New Pester coverage in `tests/WingetBootstrap.Tests.ps1` pins three cases independently: the nonzero-exit path catching the `0x8A15000F` exit code with non-matching text, exit-0 corruption caught via the English phrases, and exit-0 corruption caught via the hex token alone with localized (non-English) text.
- Fixed the pre-elevation `winget source update` call in `Invoke-WingetInstall` being able to hang the entire run forever on a corrupted/unreachable winget source: it ran via a bare `Start-Process -Wait` with no `-PassThru`, no exit-code check, and — the actual bug — no timeout, unlike its sibling probe `Invoke-WingetSourceProbe` (`WingetAppSetup/Private/WingetBootstrap.ps1`), which already runs the identical command under a 120-second `WaitForExit`/`Kill()` timeout guard (issue #177). The call site now reuses `Invoke-WingetSourceProbe` directly instead of duplicating that guard a third time, so a hung/broken source is killed and the run continues past it, before elevation, the same as before on a healthy source. Behavior is otherwise unchanged: same command, same arguments, still best-effort (its result was never checked before this fix either). Because `Invoke-WingetInstall`'s admin check is now the mockable shared `Test-IsAdmin` helper (issue #239) rather than an inline, unmockable .NET call, the non-admin/non-`-WhatIf` branch containing this call site is finally reachable by tests: a new test mocks `Test-IsAdmin` false and drives that real code path, asserting `Invoke-WingetSourceProbe` is genuinely invoked.
- Fixed the "Should exit with code 1 and show remote elevation guidance" Pester test (`tests/EntryPoint.Tests.ps1`, `IEX non-admin execution behavior`) being silently skipped on every run (issue #226): its `-Skip:` expression read `$script:isWindowsPlatform`/`$script:isElevated` assigned in `BeforeAll`, but Pester v5 binds `-Skip:` at discovery time — before any `BeforeAll` — so both were `$null` and the skip condition was permanently true, losing coverage of the IEX/remote non-admin guidance path without a failure to notice. The detection now runs in a `BeforeDiscovery` block (the pattern the 5.1 parse-safety Describe already uses); the test executes and passes on a non-elevated Windows session and still skips when elevated or non-Windows ([#227](https://github.com/J-MaFf/winget-app-setup/pull/227)).
- Fixed the pre-flight check reporting the wrong OS on Windows 11 (issue #221): `Test-SystemRequirements` printed the registry `ProductName`, which Microsoft never updated on Windows 11 — so a Windows 11 25H2 machine (build 26200) showed `[OK] OS Version: Windows 10 Pro`. The build number is the real discriminator, so the check now relabels a `Windows 10 ...` `ProductName` to `Windows 11` when the build is `>= 22000`; the `Windows 10` guard leaves genuine Windows 10, Windows Server (e.g. build-26100 "Windows Server 2025"), and an already-correct "Windows 11" name untouched. The build source also moved from `[System.Environment]::OSVersion.Version.Build` to the registry's `CurrentBuildNumber` (ground truth, never capped by the host compatibility manifest under Windows PowerShell 5.1, and — unlike the static .NET call — mockable), with the OSVersion read kept only as a fallback, so the version branches are finally unit-tested ([#221](https://github.com/J-MaFf/winget-app-setup/issues/221)).
- Fixed the Pester suite breaking under Pester 6 in CI: `.github/workflows/windows-tests.yml` installed and imported Pester with an unbounded `-MinimumVersion 5.0.0`, which resolves to the highest available version — now Pester 6.0.0 — but the suite uses `Assert-MockCalled` (193 call sites), removed in Pester 6, so discovery breaks (PowerShell auto-loads the stale bundled Pester 3.4.0 to satisfy the missing command and every file fails with "The Mock command may only be used inside a Describe block"). Only the self-hosted runner's cached 5.x masked it; a fresh runner would break. Both the availability guard and the import are now bounded to the 5.x major (`>= 5.0.0 -and < 6.0.0`; install adds `-MaximumVersion 5.999.999`), verified on a machine with 6.0.0/5.7.1/3.4.0 all present (selection picks 5.7.1, suite 259 passed / 0 failed / 3 skipped), and CLAUDE.md documents the Pester 5.x requirement; migrating the suite to `Should -Invoke` for Pester 6 compatibility stays tracked in bd `wgt-89n` ([#223](https://github.com/J-MaFf/winget-app-setup/pull/223)).
- Migrated the Pester suite off `Assert-MockCalled` (193 call sites across 9 test files) — removed in Pester 6 — to the modern `Should -Invoke`, a behavior-preserving rename (verified by probe that `Assert-MockCalled -Times N [-Exactly]` and `Should -Invoke -Times N [-Exactly]` are identical in Pester 5, and that Pester 6's `Should -Invoke` matches). Also fixed three `Install.Tests.ps1` structural tests that read `Invoke-WingetInstall`'s definition through a filtered `Get-Command` mock: Pester 6 throws instead of falling back to the real command when no `-ParameterFilter` matches and there is no default mock, so they now capture the definition once in `BeforeAll` before the mock exists. The suite is green on both Pester 5.7.1 and 6.0.0 (263 passed / 0 failed / 3 skipped), and `windows-tests.yml` + CLAUDE.md are repinned from the temporary 5.x pin to Pester 6.x (`>= 6.0.0 -and < 7.0.0`), retiring the `wgt-89n` stopgap ([#224](https://github.com/J-MaFf/winget-app-setup/pull/224)).
- Fixed unattended runs auto-cancelling on the measured-low-disk prompt (issue #214): `Test-SystemRequirements` called `Read-Host` unconditionally when C: had under 50 GB measured free, so a non-interactive run (CI, RMM, `irm | iex` with redirected stdin) read an empty string as "not Y" and cancelled the install. The effective non-interactive detection previously inlined in `Invoke-WingetInstall` (#176) is extracted into the shared private helper `Test-EffectiveNonInteractive` (`WingetAppSetup/Private/Interactivity.ps1`), both callers consume it, the entry script forwards `-NonInteractive` into the pre-flight checks, and a non-interactive low-disk run now warns and continues instead of prompting ([#216](https://github.com/J-MaFf/winget-app-setup/pull/216)).

- Fixed the generated installer failing to parse under Windows PowerShell 5.1 with 43 errors (issue #210): the BOM-less UTF-8 installer is decoded as ANSI by 5.1, where an em dash's 0x94 byte becomes a string-terminating curly quote inside double-quoted strings. Swept the em dash out of the 4 non-comment string tokens across the module and fragments (comments are unaffected by the misdecoding and keep their typography), and `build/Build-WingetInstallScript.ps1` now fails the build — and `-Check` — if any non-comment token of the assembled script contains a non-ASCII character, printing line/column/codepoint. Verified with real `powershell.exe` 5.1: `Parser::ParseFile` reports 0 errors ([#212](https://github.com/J-MaFf/winget-app-setup/pull/212)).
- The installer now fails fast under PowerShell older than 7 (which it never supported at runtime) instead of dying in the 5.1 parser: the dispatch's first statement — before the transcript starts or anything is touched — checks `$PSVersionTable.PSVersion.Major -lt 7` and exits 1 with guidance to run the one-liner from `pwsh`; reachable because the file now parses under 5.1. `readme.md` states the PowerShell 7+ requirement next to the run commands (with a `pwsh -Command "irm ... | iex"` escape hatch for 5.1 prompts), and new Pester tests pin the tokenizer rule, the 5.1 parse, and the 5.1 fail-fast behavior ([#212](https://github.com/J-MaFf/winget-app-setup/pull/212)).
- `Set-WindowsTerminalDefaults` now detects cross-user elevation (reusing the #159 `Get-ProcessUserName`/`Get-InteractiveSessionUserName` helpers) and warns loudly that the per-user Windows Terminal settings.json and `HKCU:\Console\%%Startup` delegation values are being applied to the **admin** account's profile — not the logged-on user's — closing with an "applied to '<admin>' only" caveat instead of an implied machine-wide success; it deliberately does not write to another user's profile or hive (issue #187, [#204](https://github.com/J-MaFf/winget-app-setup/pull/204)).
- Replaced the regex JSONC sanitizer in `ConvertFrom-TerminalSettingsJson` — which missed trailing inline `//` comments (silently skipping the default-profile update on Windows PowerShell 5.1) and could corrupt string values containing `/*` or `, ]` sequences that `Set-WindowsTerminalDefaultProfile` would then write back into settings.json — with a string-aware character scanner (`Convert-JsoncToJson`, `WingetAppSetup/Private/Jsonc.ps1`) that strips line/block comments and trailing commas while honoring `\"` escapes and never touching comment-like text inside JSON strings; the cross-user warning text is ASCII-only because an em-dash in a double-quoted literal misdecodes into a string-terminating curly quote when 5.1 reads the BOM-less UTF-8 installer as ANSI (issue #187, [#204](https://github.com/J-MaFf/winget-app-setup/pull/204)).
- `Test-WindowsTerminalConfiguration.ps1 -AsJson` no longer pollutes stdout with `Format-Table` records ahead of the JSON payload — the table now renders via `Out-Host`, so `-AsJson | ConvertFrom-Json` works (issue #187, [#204](https://github.com/J-MaFf/winget-app-setup/pull/204)).
- Fixed `Uninstall-WingetAutoUpdate` failing with msiexec exit 1605 ("unknown product") against any WAU version other than the pinned 2.12.0: it hardcoded the pinned ProductCode, but every MSI version of WAU carries its own. The uninstaller now resolves the actually-installed ProductCode from the MSI Uninstall registry entry (via the new private `Get-InstalledWauInfo`) and only falls back to the pinned code when the lookup finds none (issue #186, [#203](https://github.com/J-MaFf/winget-app-setup/pull/203)).
- Hardened the WAU MSI install against a TOCTOU swap (issue #186): the hash-verified MSI used to sit at the predictable, user-writable `%TEMP%\WAU-<version>.msi`, where a same-user non-elevated process could replace it between `Get-FileHash` and msiexec. The download/verify/install now happens in a unique per-run directory under `%ProgramData%\winget-app-setup\` whose ACL is locked to SYSTEM + Administrators by well-known SID with inheritance removed (`icacls`) **before** anything is downloaded — the base directory is restricted first so the per-run name cannot be observed or raced via parent-directory rights, an `icacls` failure marks the WAU setup FAILED instead of proceeding unsecured, and the staging directory is removed in `finally`. The SHA256 pin check is unchanged ([#203](https://github.com/J-MaFf/winget-app-setup/pull/203)).
- Fixed the Pester suite invoking the **real** `Repair-WinGetPackageManager` during `Test-AndInstallWinget` unit tests: production checks `Get-Command Repair-WinGetPackageManager` before the aka.ms fallback, but the Describe only mocked the `Get-Command` lookup for `winget`, so on any machine with Microsoft.WinGet.Client installed (dev machines, CI — which deliberately installs it) the "winget not available" tests performed a real network download and AppX re-registration of the App Installer. A `BeforeEach` now unconditionally mocks `Repair-WinGetPackageManager` and its `Get-Command` lookup, and two new tests cover the issue-#159 repair branch (repair succeeds → `$true` without the aka.ms fallback; repair throws → falls through to the App Installer download) ([#197](https://github.com/J-MaFf/winget-app-setup/pull/197)).
- Fixed two order-dependent `Test-WingetSources` tests ("sources missing entirely" and "source list throws") that passed only via a stale `$global:LASTEXITCODE` left in the shared runspace by earlier tests: their winget mocks set an exit code only on a second search call that never happens (production makes exactly one post-repair search in those scenarios), so each test failed when run in isolation. The mocks now set `$global:LASTEXITCODE` on every simulated winget call and each test poisons the exit code up front, making both tests self-contained (verified with isolated `Invoke-Pester -FullNameFilter` runs) ([#197](https://github.com/J-MaFf/winget-app-setup/pull/197)).
- Fixed `winget-app-uninstall.ps1` reporting every successful uninstall as **Failed** on non-English Windows: results were classified by matching the English output strings `'Successfully uninstalled'` / `'No installed package found matching input criteria.'` with no `$LASTEXITCODE` check. The script now classifies by `$LASTEXITCODE` captured immediately after each winget call (`winget list` exit 0 → installed, nonzero such as `0x8A150014` → skip; `winget uninstall` exit 0 → success, nonzero → failed with the hex code in the message), and passes `--accept-source-agreements --disable-interactivity` to `winget list` and `--disable-interactivity` to `winget uninstall` so the script can no longer hang on the first-run source-agreement prompt under cross-user elevation ([#193](https://github.com/J-MaFf/winget-app-setup/pull/193)).
- Hardened `build/Build-WingetInstallScript.ps1` against silently corrupted output (issue #183): parser errors in the assembled script now fail the build with line/column details (previously `ParseInput` discarded them, so an unbalanced brace in a module file shipped a broken installer that both the reference guard and `-Check` waved through); the undefined-reference guard matches module-defined function names ordinal case-sensitively and treats a call site that matches a module function only case-insensitively (e.g. `Install-WingetPackage` vs Microsoft.WinGet.Client's `Install-WinGetPackage`) as a build failure instead of letting `Get-Command` resolve the external cmdlet and mask the drift; every `Get-Content` passes `-Encoding UTF8` so Windows PowerShell 5.1 no longer decodes the BOM-less UTF-8 sources as ANSI (mojibake); `-Check` inspects the on-disk installer's raw bytes and rejects a leading UTF-8 BOM that `Get-Content -Raw` would silently strip; output is written as BOM-less UTF-8 via `[System.IO.File]::WriteAllText` (5.1's `Set-Content -Encoding UTF8` prepends a BOM); and the Private/Public file concatenation order uses an ordinal `[Array]::Sort` instead of culture-sensitive `Sort-Object`. The generated `winget-app-install.ps1` is byte-identical for the current module ([#201](https://github.com/J-MaFf/winget-app-setup/pull/201)).
- Fixed stale and misleading documentation found by the 2026-07-08 whole-repo review (issue #182): removed the deleted `Update-InstalledApps.ps1` from CLAUDE.md/STATUS.md, corrected CLAUDE.md's winget-source-probe description (the probe deliberately omits `--accept-source-agreements`, which is invalid for `winget source update` — the #174 regression), described updates as outsourced to Winget-AutoUpdate in STATUS.md and refreshed its Open Issues table (#176–#192), and repointed the dead `release-notes.md` link at the GitHub releases page ([#199](https://github.com/J-MaFf/winget-app-setup/pull/199)).
- Fixed the generated installer's comment-based help enumerating a stale app list that omitted `Git.Git` and `Klocman.BulkCrapUninstaller`; `build/fragments/head.ps1` now points at the authoritative `$apps` array in `WingetAppSetup/Public/Install.ps1` and suggests `-WhatIf` to preview planned installs ([#199](https://github.com/J-MaFf/winget-app-setup/pull/199)).
- Fixed `Invoke-AppxProvisioning` interpolating paths into its delegated elevated `powershell.exe -Command` string without escaping (issue #178). `PackagePath`, each `DependencyPackagePath` element, and `LicensePath` sat in bare single-quoted literals, so any path containing an apostrophe (e.g. `C:\Users\O'Brien\...`) unbalanced the quoting and broke DISM provisioning — and, since the PS7 DISM-path filenames come from `winget download` output, a crafted filename could break out of the literal and execute arbitrary commands in the elevated invocation. Every interpolated path now has embedded single quotes doubled (dependency paths escaped per-element before the join), with unit tests asserting the constructed command for apostrophe-bearing paths ([#194](https://github.com/J-MaFf/winget-app-setup/pull/194)).
- Removed the installer's persistent PATH-hijack surface: `Invoke-WingetInstall` no longer added its own directory (typically Downloads/ or an extracted zip) to the persistent User PATH, where a planted `winget.exe` could resolve and run elevated in the cross-user admin scenario this repo targets; nothing needed the entry since the homegrown updater removal in #168 ([#196](https://github.com/J-MaFf/winget-app-setup/pull/196)).
- Fixed `Test-PathInEnvironment` (and the process-PATH check in `Add-ToEnvironmentPath`) treating `C:\Program Files\Foo` and `c:\program files\foo\` as different entries — comparisons are now case-insensitive with trailing-separator normalization per split entry, so repeated runs no longer appended duplicates to the persistent PATH ([#196](https://github.com/J-MaFf/winget-app-setup/pull/196)).
- Replaced the bogus 2048-character process-PATH guard in `Add-ToEnvironmentPath` with the real 32767-character Windows environment-variable limit and corrected the warning text; machines with a ~2100-char PATH previously got the persistent update but not the session update ([#196](https://github.com/J-MaFf/winget-app-setup/pull/196)).
- Replaced the pre-flight network check's raw TCP `Test-NetConnection` probe with a proxy-aware HTTPS probe (`Invoke-WebRequest -Method Head` against `https://cdn.winget.microsoft.com/cache`, 10 s timeout), fixing the blocking false-FAIL on proxy-only corporate networks where winget itself works fine; any HTTP response — including 4xx/5xx — now counts as reachable, and only a transport-level failure (no response at all) blocks ([#195](https://github.com/J-MaFf/winget-app-setup/pull/195)).
- Gave the disk-space check's `Get-PSDrive` catch path its own `UNKNOWN` status (distinct from the low-space `WARN`) and made the low-disk `Read-Host` prompt fire only when free space was actually measured below 50 GB, removing the dead `$freeGB = 999` sentinel; an unattended run with an unreadable C: drive no longer gets cancelled by `Read-Host` returning an empty string on redirected stdin ([#195](https://github.com/J-MaFf/winget-app-setup/pull/195)).
- Made `-WhatIf` actually run `Test-SystemRequirements` (as head.ps1 documents) instead of printing a "[DRY-RUN] Would run pre-flight system checks" stub; a blocking failure in dry-run mode prints that a real run would abort but does not exit 1, and the `-SkipSystemCheck` bypass is unchanged ([#195](https://github.com/J-MaFf/winget-app-setup/pull/195)).
- Removed the msstore-era trusted-sources loop from `Invoke-WingetInstall` and deleted its helpers `Test-WingetSourceTrusted` and `Set-Sources` (issue #177): the loop re-checked the single `winget` source whose health `Test-WingetSources` already verified (and repaired) earlier in the flow, the `$sourceErrors` array it built was never read, and `Test-WingetSourceTrusted` matched error text merged from stderr with no `$LASTEXITCODE` check — so a broken source whose error output mentioned "winget" counted as trusted and skipped the repair ([#202](https://github.com/J-MaFf/winget-app-setup/pull/202)).
- Added `--accept-source-agreements` to the `winget search 7zip` functional probes in `Test-WingetSources` (the flag is valid for `winget search`, unlike `winget source update` — #174/#175), so a fresh account with unaccepted source agreements (0x8A150046) is no longer misdiagnosed as source corruption that triggered a pointless `winget source reset --force` + repair cycle ([#202](https://github.com/J-MaFf/winget-app-setup/pull/202)).
- `Test-AndInstallWinget`'s App Installer fallback now re-checks `Get-Command winget` after `Add-AppxPackage` (like the Repair path already did) and returns `$false` with a clear "install winget manually" error when winget is still unavailable, instead of returning `$true` unverified and letting downstream winget calls throw `CommandNotFoundException` ([#202](https://github.com/J-MaFf/winget-app-setup/pull/202)).
- `Invoke-WingetSourceProbe` now redirects winget output to unique per-run temp file names (random suffix) instead of fixed names, so concurrent runs or a stale locked file from a killed run can no longer make `Start-Process` throw and read as a false probe failure ([#202](https://github.com/J-MaFf/winget-app-setup/pull/202)).
- Fixed the install orchestrator exiting 0 on fatal failures (issue #176): the winget-unavailable and app-definition-validation/empty-list paths used a bare `Exit`, so RMM tools and wrappers saw success on total failure. They now exit with distinct codes — 2 = winget unavailable, 3 = validation failed / no valid apps remain — with 1 still meaning one or more apps failed to install; all codes are documented in `readme.md` ([#200](https://github.com/J-MaFf/winget-app-setup/pull/200)).
- Fixed unattended runs blocking forever (or crashing past the failure gate) on interactive prompts: added a `-NonInteractive` switch (also auto-detected via `[Environment]::UserInteractive` and redirected stdin) that skips the elevation `Pause`, the grid-view prompt, and the final `ReadKey`, keeping the `Exit 1` failure gate reachable; the effective state is forwarded through the elevation relaunch ([#200](https://github.com/J-MaFf/winget-app-setup/pull/200)).
- Fixed apps whose `winget list` probe timed out vanishing from the run entirely — never installed, never retried, omitted from the summary, exit 0. A probe timeout now marks the app failed so it flows through the retry pass, the summary, and the non-zero exit ([#200](https://github.com/J-MaFf/winget-app-setup/pull/200)).
- Forwarded `-SkipSystemCheck` across the elevation relaunch (issue #185). The non-elevated relaunch called `Restart-WithElevation` with empty `AdditionalArguments`, so the elevated session re-ran the pre-flight checks the caller explicitly bypassed and exited 1 on machines where the checks false-fail — defeating the documented headless-bypass switch. `Invoke-WingetInstall` now takes a `-SkipSystemCheck` pass-through parameter (forwarded by the entry script) and builds the elevation arguments from both `-WhatIf` and `-SkipSystemCheck`; the previous `-WhatIf`-only forwarding was unreachable dead code because a dry run never relaunches ([#198](https://github.com/J-MaFf/winget-app-setup/pull/198)).
- Guarded the elevation relaunch against module context (issue #185). Running `Invoke-WingetInstall` from the imported `WingetAppSetup` module without elevation relaunched `$PSCommandPath` — which in module context is the functions-only `WingetAppSetup/Public/Install.ps1` — so the elevated window defined a function and exited without installing anything. A new `Test-InvokedFromModuleContext` helper detects module invocation (or a `$PSCommandPath` resolving inside the module) and fails fast with guidance to run `winget-app-install.ps1` or start from an already-elevated session ([#198](https://github.com/J-MaFf/winget-app-setup/pull/198)).
- Fixed the winget source probe false-failing on every run with "Winget sources could not be initialized … may fail with 0x80073D19" (issue #174). `Invoke-WingetSourceProbe` (from #160) ran `winget source update --name winget --accept-source-agreements --disable-interactivity`, but `--accept-source-agreements` is **not a valid argument for `winget source update`** — winget rejected the whole command with `0x8A150002` (INVALID_CL_ARGUMENTS, `-1978335230`), so the probe always returned non-zero, always ran `Repair-WinGetPackageManager`, and always printed the scary warning even on healthy machines. Dropped the invalid flag (`winget source update --name winget --disable-interactivity`, verified exit 0); `source update` still forces the winget-source bootstrap so a genuine `0x80073D19` is still detected, and agreements are accepted by the install commands (which pass `--accept-source-agreements`) ([#174](https://github.com/J-MaFf/winget-app-setup/issues/174)).
- Stopped trusting/resetting the unused **msstore** source, which produced frequent `Failed to reset sources for msstore` noise (issue #172). The tool only ever installs from `--source winget`, but the trusted-sources loop iterated `@('winget','msstore')` and, per source, called a **global** `winget source reset --force` — which wipes and re-prompts source agreements and fails on msstore's cert/agreement/licensing handshake in elevated/cross-user/non-interactive contexts (0x8A150046 / 0x8a15005e / 0x8A150083), none of which affect winget-CDN installs. The loop now checks the winget source only, and the pre-elevation `winget source update` is scoped to `--name winget` so it never triggers the msstore handshake either ([#172](https://github.com/J-MaFf/winget-app-setup/issues/172)).
- Fixed the recurring `0x80073d19` install failure ("an error occurred because a user was logged off") that persisted through #81/#104/#107/#150 on machines where the script is elevated as a different account than the interactively logged-on user. Root cause: `0x80073d19` is `ERROR_DEPLOYMENT_BLOCKED_BY_USER_LOG_OFF` — the AppX deployment service blocks winget's per-user first-use bootstrap (registering `Microsoft.Winget.Source`) for an account with no interactive logon session, so no amount of retrying could recover. `Initialize-WingetSourcesForUser` is rewritten to probe with `winget source update --accept-source-agreements` (its old probe omitted the flag and its fallback checked a wrong exit code, making it a no-op) and to bootstrap the account via `Repair-WinGetPackageManager` when the probe fails; `Test-AndInstallWinget` prefers the same bootstrap over `Add-AppxPackage`; cross-user elevation is now detected and reported with remediation guidance; and `Install-WingetPackage` prefers `--scope machine` (falling back automatically for MSIX-only packages like Windows Terminal), which both avoids per-user MSIX deployment — the layer `0x80073d19` blocks, and what Microsoft.PowerShell's default user-scope MSIX installer hit — and stops installs from landing in the elevated admin account's profile instead of machine-wide ([#159](https://github.com/J-MaFf/winget-app-setup/issues/159)).

- Fixed `Microsoft.PowerShell` failing to install with "The current system configuration does not support the installation of this package" on elevated cross-user sessions. Since the winget package for PowerShell 7.6.0, winget installs the MSIX bundle by default, and winget's own machine-scope MSIX provisioning fails as a packaged app on Windows older than build 26100 (24H2) — deterministically, so the retry pass could not recover it. `Install-WingetPackage` now accepts an `-InstallerType` override and the PowerShell app entry forces `--installer-type wix`, installing the machine-wide MSI (which the other Win32 apps use) instead of the MSIX ([#163](https://github.com/J-MaFf/winget-app-setup/issues/163)).
- Fixed the scheduled-update setup throwing `Join-Path`/`Test-Path`/`Copy-Item` "Cannot bind argument to parameter 'Path'" errors under the `irm | iex` one-liner, where `$PSScriptRoot` is empty. The helper and module were never deployed to `%APPDATA%`, yet the weekly task was still registered pointing at the missing helper. `Install-UpdateHelperScript` now downloads the standalone helper plus the self-contained `winget-app-install.ps1` when running remotely (the helper dot-sources the self-contained script for its functions when the module folder is absent), and helper deployment is now best-effort so a failure warns and skips instead of aborting the install ([#164](https://github.com/J-MaFf/winget-app-setup/issues/164)).
- Fixed the `irm | iex` one-liner (and any local run without `-SkipSystemCheck`) failing immediately with `Test-SystemRequirements : The term 'Test-SystemRequirements' is not recognized ... CommandNotFoundException`. The installer's entry point (`build/fragments/tail.ps1`) calls `Test-SystemRequirements`, but the `#106` module extraction never carried the function into `WingetAppSetup/`, so the generated `winget-app-install.ps1` invoked an undefined command on the default path. Restored the pre-flight system-check function as `WingetAppSetup/Public/SystemChecks.ps1` (exported from the manifest), re-added its Pester coverage, and regenerated the single-file installer ([#154](https://github.com/J-MaFf/winget-app-setup/issues/154)).
- Hardened `build/Build-WingetInstallScript.ps1` to fail the build (and `-Check`) when the assembled installer invokes a hyphenated command that is neither defined in the module nor resolvable as an external cmdlet, so a fragment calling a dropped module function can no longer ship undetected. Enforced on Windows, where the installer's Windows-only cmdlets resolve; skipped with a notice on other platforms ([#154](https://github.com/J-MaFf/winget-app-setup/issues/154)).
- Reconciled the README one-line install command with the CHANGELOG: the `Set-ExecutionPolicy Unrestricted -Scope Process` snippet now includes `-Force`, matching the documented simplified form (#136).
- Fixed double winget command execution in `Invoke-WingetCommand`: the function previously ran each winget command twice (once to display output, once to capture it), causing duplicate prompts and spurious "already installed" failures. It now invokes winget a single time, reading the exit code directly before any pipeline can reset `$LASTEXITCODE` (#134).
- Fixed the post-install update phase hanging indefinitely on a stalled package upgrade. Each upgrade now runs through a timeout-guarded helper (`Invoke-WingetPackageUpgrade`) that kills a non-responsive `winget upgrade` and continues with the remaining packages, instead of piping every outdated package into a single unbounded `Update-WinGetPackage` call ([#120](https://github.com/J-MaFf/winget-app-setup/issues/120)).
- Fixed `-WhatIf` (dry-run) silently performing a real install: when run non-elevated, the script relaunched itself elevated but dropped the `-WhatIf` flag, so the admin session installed the full app list. A dry run now never elevates, and `Restart-WithElevation` forwards `-WhatIf` as a safety net ([#117](https://github.com/J-MaFf/winget-app-setup/issues/117)).
- Corrected the CLAUDE.md winget note that referenced a non-existent `Invoke-WingetInstallWithSessionRetry`; it now describes the actual `0x80073d19` mitigation (user-context source init plus the single failed-install retry pass) ([#111](https://github.com/J-MaFf/winget-app-setup/issues/111)).
- Cleaned up `Test-WingetAppInstall.Tests.ps1` so it no longer defines unused variables and satisfies the linter.
- Fixed all 17 Pester tests that failed on the new Windows CI (#132): install `Microsoft.WinGet.Client` in CI so the winget cmdlet mocks resolve, removed orphaned `Invoke-WingetInstallWithRetry` tests for the reverted retry feature (#83), and restored the missing `Test-SystemRequirements` implementation (into the then-monolithic script; the later #106 module extraction dropped it again — see #154).
- Made `Enable-ScheduledUpdatesCheck` resilient to `[WindowsIdentity]::GetCurrent()` failing in restricted execution contexts (e.g. CI or service accounts): it now falls back to environment variables for the task principal so scheduled-task creation no longer aborts (#132).
- Fixed broken winget source scenario: when running as admin on a standard user account the "winget" source registration may be missing or broken; the script now detects and auto-repairs this condition instead of silently failing (#66).
- Added Pester coverage for Windows Terminal default profile and terminal delegation configuration paths, and corrected an `IsWindows` read-only variable name collision in the test suite.
- Fixed corrupted winget source data detection: `Test-WingetSources` now verifies source functionality with `winget source update`, detects corruption errors like `0x8a15000f`, and uses `winget source reset` as part of repair attempts (#77).

## [1.0.0] - 2025-11-07

### Added (1.0.0)

- Initial PowerShell automation suite for managing Windows applications using winget
- **winget-app-install.ps1** - Main installation script with update management
- **winget-app-uninstall.ps1** - Companion uninstallation script for removing applications
- **launch.ps1** - Launcher script for execution policy bypass
- **Test-WingetAppInstall.Tests.ps1** - Comprehensive Pester test suite
- Automated installation of 10 curated Windows applications
- Dry-Run/WhatIf mode for previewing actions without making system changes
- Smart application checking to detect and skip already-installed applications
- Automatic update detection and installation
- Admin privilege handling with automatic elevation (preferring Windows Terminal when available)
- Winget source trust verification and management
- Timeout protection for all winget commands (prevents hanging)
- Formatted output with Format-Table and optional Out-GridView support
- Color-coded status messages for visual feedback
- Self-healing winget tooling (auto-installs CLI and PowerShell module dependencies)
- Execution policy bypass via launcher script
- Comprehensive inline documentation
- Reusable utility functions for common operations

### Fixed

- Installation checks now use correct winget list syntax (`--id` flag instead of `-q`)
- Timeout protection prevents hanging on source operations (30s for source ops, 15s for package ops)
- Execution policy handling via dedicated launcher script
- Robust error handling with graceful degradation
- Network error resilience and package not found scenarios

### Features

- **Comprehensive Error Handling**
  - Timeout protection for all winget commands
  - Graceful handling of network errors and package not found scenarios
  - Detailed failure tracking and reporting

- **Smart Application Management**
  - Pre-installation checks to skip already-installed applications
  - Post-installation verification to confirm successful installation
  - Fallback mechanisms for update detection

- **Flexible Output Options**
  - Text-based table output with automatic column sizing
  - Interactive Out-GridView GUI when available
  - Color-coded status messages for easy identification

- **Developer-Friendly**
  - Extensive inline documentation
  - Reusable utility functions
  - Comprehensive Pester test suite
  - Clear code patterns and conventions

### Default Applications

The following 10 applications are included in this release:

- 7-Zip (`7zip.7zip`)
- TightVNC (`GlavSoft.TightVNC`)
- Adobe Acrobat Reader 64-bit (`Adobe.Acrobat.Reader.64-bit`)
- Google Chrome (`Google.Chrome`)
- Google Drive (`Google.GoogleDrive`)
- Git (`Git.Git`)
- Bulk Crap Uninstaller (`Klocman.BulkCrapUninstaller`)
- Dell Command Update - Universal (`Dell.CommandUpdate.Universal`)
- PowerShell (`Microsoft.PowerShell`)
- Windows Terminal (`Microsoft.WindowsTerminal`)

### Requirements

- Windows 10/11
- Administrator privileges
- Winget package manager
- PowerShell 5.1+ (PowerShell 7+ recommended)

### Known Limitations

- Requires Windows 10/11
- Requires administrator privileges
- Winget source trust requires source agreements
- Out-GridView support requires Windows Terminal or PowerShell with GraphicalTools module

### Documentation

- Comprehensive README.md with feature descriptions, troubleshooting, and customization guides
- Inline code documentation with comment-based help
- Pester test suite for validation and examples

---

For detailed release information, see the [GitHub releases page](https://github.com/J-MaFf/winget-app-setup/releases).
