# Winget App Setup

A one-line guide for running the installer.

## Run the installer

> **Runs on PowerShell 7+ (`pwsh`), but bootstraps itself from Windows PowerShell 5.1.** The
> installer's logic requires PowerShell 7. Run from the built-in Windows PowerShell 5.1
> (`powershell.exe`) — the only shell on a fresh machine — and it finds PowerShell 7, or
> installs it with no consent prompt, then relaunches itself under `pwsh` in the same window
> with your switches forwarded ([#225](https://github.com/J-MaFf/winget-app-setup/issues/225)).
> A `-WhatIf` run never installs anything — without PowerShell 7 present it just previews the
> bootstrap.
>
> Installing it takes one of two paths, in order:
>
> 1. **winget**, when the invoking account has it.
> 2. **The official MSI**, when it does not — the usual reason being that you elevated as a
>    separate admin account, since winget is a per-user MSIX and a never-logged-in account has
>    no copy of it. This path downloads ~110 MB and then runs `msiexec`, so expect a couple of
>    minutes; it prints `X of 110.2 MB (N%)` progress lines throughout, and a download that gets
>    no data for 60 seconds fails with a message rather than waiting forever (a slow one gets up
>    to 60 minutes; [#263](https://github.com/J-MaFf/winget-app-setup/issues/263)). When another
>    installation is holding Windows Installer (`msiexec` exit code 1618, common on a freshly
>    enrolled machine), it waits 30 seconds and tries again, up to 6 times. `msiexec` writes a
>    verbose log next to the run's other logs (see [Logs](#logs)). It installs the current
>    PowerShell release while that still ships an MSI. PowerShell 7.7 and later ship none, so
>    from 7.7 on this path installs the newest LTS release before it (7.6); the installer runs on
>    any PowerShell 7. Before `msiexec` runs, the download must carry a valid Authenticode
>    signature from Microsoft Corporation. Anything else, such as a web page a proxy answered
>    with, is not installed, and the run says why.
>
> If neither path works, the run stops with exit code 7 (see [Exit codes](#exit-codes)). The
> bootstrap phase writes its own transcript, `install-<timestamp>-bootstrap.log`, before
> `pwsh` takes over and writes the run's main log.

From the repository root, execute (after cloning):

```powershell
pwsh -ExecutionPolicy Unrestricted -File .\winget-app-install.ps1
```

No download/clone needed (one-line-run, from any PowerShell prompt — `pwsh` or the built-in
Windows PowerShell 5.1, which self-bootstraps as described above):

```powershell
Set-ExecutionPolicy Unrestricted -Scope Process -Force; irm "https://raw.githubusercontent.com/J-MaFf/winget-app-setup/refs/heads/main/winget-app-install.ps1" | iex
```

> **`raw.githubusercontent.com` returns `429: Too Many Requests`?** That's GitHub throttling the
> machine's shared public IP (common behind corporate NAT/VPN egress), not a problem with the
> script. Retry in a few minutes, or fall back to the jsDelivr CDN mirror of the same file:
>
> ```powershell
> Set-ExecutionPolicy Unrestricted -Scope Process -Force; irm "https://cdn.jsdelivr.net/gh/J-MaFf/winget-app-setup@main/winget-app-install.ps1" | iex
> ```

Note for 5.1 starts via `irm | iex`: there is no script file on disk to relaunch, so the
bootstrap downloads the installer again to a temp file and runs that under `pwsh`, from
`raw.githubusercontent.com` first and then from the jsDelivr mirror above. It uses a copy only
when it is the same build as the one already running (the `Installer build:` id, see
[Logs](#logs)), so a run started from a branch URL, or just before `main` changed, never
relaunches different code. If no copy matches, the run stops with exit code 7. PowerShell 7 is
installed by then, so open `pwsh` as administrator and run the same one-liner there: it needs no
second download. Starting from a file (`-File .\winget-app-install.ps1`) relaunches the same file
instead.

The script will trust the required Winget sources, elevate if necessary, and install or update the curated app list. Repeat step 1 anytime you open a new PowerShell window before running it.

### Administrator rights

The installer needs administrator rights. Started from a PowerShell window that is not elevated, it
asks for them (Windows' UAC prompt) and carries on in a new, elevated Windows PowerShell window. The
window you started it in waits for that run, then exits with its exit code, so a script or RMM tool
that started the installer gets the real result rather than a 0 for having opened the prompt.

- The elevated window is always `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe`, which
  every account has. An admin account that has never signed in to this PC can approve the prompt:
  the elevated run then finds or installs PowerShell 7 for itself, as in the bootstrap above, and
  runs under it in the same window. (It used to reopen in Windows Terminal or a `pwsh.exe` found
  through the signed-in user's own app aliases, which that admin account does not have, so the
  elevated window could fail to start.)
- The elevated window does not run the file the first window ran. The first window checks that the
  file still has the SHA256 it had when the run started and copies it into its own `%TEMP%`, which
  administrators can read even when the elevating account cannot see the original (a mapped drive
  or a share). The elevated window compares that copy with the same SHA256, copies it into a new
  folder under `%SystemRoot%\Temp` that only SYSTEM and administrators can change, and runs that
  copy. A file rewritten while the prompt was up (the bootstrap's copy in `%TEMP%`, or a clone in
  Downloads, are writable by the signed-in user) is not run: the run stops with exit code 5.
- Declining the prompt ends the run with exit code 4, with no second prompt.
- A non-interactive run that is not elevated (`-NonInteractive`, a scheduled task, an RMM agent
  running as the signed-in user) shows no prompt and exits 4 at once: nobody would be there to
  approve it.
- Under `irm | iex` in PowerShell 7 there is no file to relaunch, so a run that is not elevated exits
  4 and asks you to open an elevated session. The Windows PowerShell 5.1 one-liner relaunches from
  the copy it downloads.
- `winget-app-uninstall.ps1` elevates the same way, but runs its own file in place, without the
  checked copy, because it imports the module from the `WingetAppSetup` folder next to it. The
  elevated window runs whatever those files hold when it starts, so when another account approves
  the prompt, run the uninstaller from a folder only administrators can change, or from an elevated
  session.

## App catalog

The curated app list is `Get-DefaultAppCatalog` (`WingetAppSetup/Public/AppCatalog.ps1`) — the
single source of truth shared by the installer and `winget-app-uninstall.ps1`. Entries may
declare an optional applicability **condition** (a scriptblock, with a human-readable
`conditionDescription`), evaluated before any winget call: an app whose condition is falsy on
the current machine is reported as `Skipping: <id> (not applicable: <reason>)` and counted as
Skipped in the summary instead of being pointlessly installed. A condition that throws fails
open — a warning, then a normal install — so a broken probe can never silently drop an app.
`Dell.CommandUpdate.Universal` is gated this way (`Dell hardware only`): it installs only when
`Win32_ComputerSystem` reports a Dell manufacturer ([#217](https://github.com/J-MaFf/winget-app-setup/issues/217)).
An entry may also name its MSIX package (`msixName`, set for `Microsoft.WindowsTerminal`): a run
as SYSTEM or under cross-user elevation then decides whether the app is installed from whether that
package is provisioned for every user, not from `winget list` (see
[Running as SYSTEM](#running-as-system-rmm-tools-such-as-endpoint-central)).

## Preview a run (`-WhatIf`)

```powershell
pwsh -ExecutionPolicy Unrestricted -File .\winget-app-install.ps1 -WhatIf
```

A dry run changes nothing on the machine and does not ask for elevation. It runs the checks a real
run starts with (the App Installer Group Policy and `winget --version`) and prints a `[DRY-RUN]`
line for each change a real run would make: installing the `Microsoft.PowerShell.GraphicalTools`
module (and the NuGet provider), setting up winget for the account (registering App Installer, then
`Repair-WinGetPackageManager`, after installing its `Microsoft.WinGet.Client` module), updating
the winget source and repairing it if needed (a real repair runs `winget source reset --force`,
which also removes any source added beyond the defaults), relaunching elevated, and each app it
would install. When the account has no winget yet, for example an admin account used only to
elevate, or winget is there but cannot be started, the preview lists every app as one a real run
would install, because it cannot check which are already there. A dry run still writes its
transcript (see [Logs](#logs)), and its `winget list` checks update winget's own per-user cache
and source-agreement state.

## Unattended runs

The installer never asks a yes/no question on any path — the PowerShell 7 bootstrap and low disk
space proceed without prompting. The one prompt left is Windows' own UAC prompt when the run is not
elevated (see [Administrator rights](#administrator-rights)), so an unattended run must already be
elevated or run as SYSTEM (see
[Running as SYSTEM](#running-as-system-rmm-tools-such-as-endpoint-central)): a non-interactive run
that is not elevated exits 4 without showing a prompt. A run as SYSTEM is always non-interactive.
Pass `-NonInteractive` for RMM, CI, or scheduled-task use to also suppress the interactive-only
extras: the summary grid-view window and the "press any key to exit" that holds the window at the
end of a run or after an early failure (see [Logs](#logs)):

```powershell
pwsh -ExecutionPolicy Unrestricted -File .\winget-app-install.ps1 -NonInteractive
```

Non-interactive mode is also auto-detected when the session is non-interactive (e.g.
`pwsh -NonInteractive`, services, scheduled tasks) or stdin is redirected. Under CI (the `CI`,
`GITHUB_ACTIONS` or `TF_BUILD` variable is set) an early failure never waits for a key press
either. In non-interactive mode winget also gets `--silent`, so MSI packages install with `/quiet`
instead of showing a progress window (`/passive`).

No winget or `msiexec` call can hang a run for good. Each has a time limit, and when it runs out
the installer stops that process and every process it started, then carries on:

| Call | Time limit |
|------|------------|
| One `winget install` (download, installer, and waiting for another winget install) | 30 minutes |
| `winget download` (the PowerShell MSIX fallback) | 30 minutes |
| The per-app `winget list` check before and after each install | 15 seconds |
| The `winget --version` check that winget can be started | 30 seconds |
| `winget source update` and other `winget list` calls | 2 minutes |
| `winget source reset` | 5 minutes |
| `msiexec` for Winget-AutoUpdate | 15 minutes |
| The Winget-AutoUpdate MSI download | 5 minutes until the server starts sending the file; on PowerShell 7.4 and newer, also 2 minutes without data while it arrives |

A stopped install is checked like any other: unless the app turns out to be installed anyway, it
fails, gets its one retry in the retry pass, and counts toward exit code 1, with
`winget install stopped after 30 minutes` in its failure reason. The limits are set in one place,
`Get-ProcessTimeoutSeconds` (`WingetAppSetup/Private/ProcessInvocation.ps1`).

Some steps still have no time limit of their own: the PowerShell cmdlets that set up winget and the
summary grid (`Install-Module` for Microsoft.WinGet.Client and Microsoft.PowerShell.GraphicalTools,
`Repair-WinGetPackageManager`, and `Add-AppxPackage` registering App Installer), and, on
PowerShell 7.3 and older, the Winget-AutoUpdate MSI download once the file has started to arrive.

**Setting winget up.** Before the installs, one step (`Initialize-Winget`) checks winget, works out
what is wrong from exit codes and HRESULTs, applies the fix for that, and runs each fix at most once
a run. When something cannot be fixed it prints one line that says why and what to do.

1. **Group Policy.** When App Installer's policy turns winget or its source off (`Enable App
   Installer`, `Enable Windows Package Manager command line interfaces` or `Enable App Installer
   Default Source` set to Disabled, under
   `HKLM\SOFTWARE\Policies\Microsoft\Windows\AppInstaller`), or winget answers
   `0x8A15003A BLOCKED_BY_POLICY`, no repair can help: the run stops with exit code 2 and names
   the policy, before any repair, source reset or Winget-AutoUpdate install.
2. **Can winget start?** `winget --version` has to run and print a version; being on PATH is not
   enough. A failure that can clear on its own (`winget.exe` locked, for example while App Installer
   updates) is checked again for up to 75 seconds first. If winget still cannot run, the installer
   sets it up for the account, cheapest first: it registers the App Installer already on the PC
   for the account (the fix for an admin account elevating on a user's PC; under PowerShell 7 this
   runs in Windows PowerShell, because the Appx module cannot load in PowerShell 7 on Windows 10
   and Windows Server 2022), then runs `Repair-WinGetPackageManager`. The
   `Microsoft.WinGet.Client` module that provides the repair is installed from the PowerShell
   Gallery only then, never on a PC whose winget works. When
   `Get-AppxPackage -AllUsers` shows the `Microsoft.WindowsAppRuntime.1.8` framework App Installer
   needs is missing, the repair runs for all users first (`-AllUsers`, which installs App
   Installer with its frameworks, as the cmdlet itself asks); on a PC with a newer framework it is
   never used, because there it aborts with `0x80073D06` (#265). `-Force`, which only closes
   running App Installer processes, follows only a failure nothing has explained: not after the
   registration or the repair saw a missing framework (`0x80073CF3`) or a newer one (`0x80073D06`),
   which fail the same way however often they are tried, nor after the all-users repair for a
   missing framework failed. When winget still does not start, the run exits with code 2, and
   the line names the AppX codes it saw and the fix (install the framework, update App Installer
   from the Microsoft Store, or install it from the Store or https://aka.ms/getwinget). The
   installer no longer downloads App Installer from aka.ms/getwinget itself: it installed the same
   bundle as `Repair-WinGetPackageManager -Latest`, without the frameworks it needs.
3. **The winget source.** `winget source update --name winget` also registers the source for an
   account that never used winget. `0x80073D19` (the account has no logon session) gets the account
   fixes that have not run yet; a missing or corrupted source (`0x8A15000B`, `0x8A15000F`,
   `0x8A150012`, `0x8A150015`, `0x8A15003F`) gets `winget source reset --force`. A timeout, a
   network error or any other code gets no fix: no repair fixes a network. A source that still
   fails is reported in one line and the run carries on; each install then says why it failed.

A run as SYSTEM checks the machine-wide `winget.exe` instead of step 2's account fixes, which cannot
work for SYSTEM (see [Running as SYSTEM](#running-as-system-rmm-tools-such-as-endpoint-central)).

A winget that cannot be started is not retried app by app either. If winget stops starting partway
through the installs, the app that hit it fails with
`winget could not be launched ...` and the installer
checks, for up to 75 seconds (six tries 15 seconds apart), whether winget can be started again. If
it can, the run carries on and the app gets its retry. If it cannot, every remaining app is marked
failed with `not attempted: winget cannot be launched on this machine (see above)` without running
winget, the retry pass is skipped, and the run ends with exit code 1 about 2.5 minutes later at
most (about 6 if every check hangs until its 30-second limit); `Access is denied` or a missing
winget stops the checks at once. Before, each app spent its own retries, twice, and the run took
about 24 minutes to fail. A `winget list` check that runs but fails (any exit code other than 0 or
`0x8A150014`, no packages found) is not read as "not installed" either: the app fails with
`winget list failed during the pre-install check with exit 0x...` (or `post-install check`) and
gets its retry.

Some install results clear on their own, and are waited out instead of failing at once:

- **Another installation in progress** (`0x8A150102`, `msiexec` 1618). Windows Installer runs one
  installation at a time and refuses a second one at once, which is common on a freshly enrolled PC
  while the management agent, OEM tools or Teams are still installing. The installer waits for
  that installation to finish (every 15 seconds it checks whether an installation owns the
  `Global\_MSIExecute` mutex; when none does, the check holds the mutex for an instant and
  releases it at once), then retries, up to 3 times per app. All the waiting in a run, the
  Winget-AutoUpdate `msiexec` included, comes out of one 10-minute budget, so a PC that stays busy
  costs the run 10 minutes at most. After that, the app fails with
  `another installation was in progress (Windows Installer was busy) - re-run the installer once it has finished`.
- **The app or its files are in use** (`0x8A150101`, `0x8A150103`, `0x8A150111`): one retry after
  60 seconds.
- **A restart is required before the installer can run** (`0x8A15010A`, for example an Inno
  setup while a Windows Update restart is pending) is never retried, not even in the retry pass:
  the summary says `Restart: REQUIRED before <app> can install - restart this PC, then re-run the installer.`

A failure reason names winget's exit code, for example
`winget exit 0x8A150102 INSTALL_INSTALL_IN_PROGRESS`, and when winget reported why the install
failed, the reason starts with what that code means instead of `package not found after install`.
Every place that prints a winget exit code uses the same table
(`WingetAppSetup/Private/WingetResultCodes.ps1`).

**Restart required.** The installer checks Windows' pending-restart state before and after the run
(component servicing, Windows Update, and file replacements queued for the next restart in
`PendingFileRenameOperations`; queued deletes are ignored, because programs queue those to clean
up temporary files). A run that needs a restart to finish ends with
`Restart: REQUIRED to finish this run - restart this PC before it is used (...)` and exit code 3010
when nothing failed. That is when an install said so (winget's
`Restart your PC to finish installation.`, recognized on an English Windows, or exit `0x8A150109`
or `0x8A15010B`), the Winget-AutoUpdate MSI returned 3010, a pending-restart indicator appeared
during the run, or, on a run started from Windows PowerShell, installing PowerShell 7 needed a
restart (its MSI returned 3010, or winget said so). The bootstrap reports that last case after the
PowerShell 7 run (`Restart: REQUIRED to finish the PowerShell 7 installation - ...`) and turns
that run's 0 into 3010. A restart that was already pending before the run is reported at the start
and next to the summary (`Restart: already pending before this run (...)`), but does not make the
run 3010 by itself. The installer never restarts the PC.

### Running as SYSTEM (RMM tools such as Endpoint Central)

A run as SYSTEM, which is how an RMM agent such as ManageEngine Endpoint Central runs a computer
script, is supported for the apps that install for the whole PC. Microsoft does not support the
winget command line as SYSTEM: winget is a per-user packaged app that cannot be registered for
SYSTEM ([WinGet troubleshooting, System
Context](https://learn.microsoft.com/windows/package-manager/winget/troubleshooting#system-context)),
and Microsoft's supported route there is the `Microsoft.WinGet.Client` PowerShell module on
PowerShell 7, which this installer does not use yet. So a SYSTEM run can fail where a run as a
signed-in user would not; test it on a pilot PC before rolling it out. What a SYSTEM run does
differently:

- It is never interactive: no grid view, no "press any key", and winget installs with `--silent`.
- It runs the `winget.exe` that App Installer installed for the PC, by its full path, for every
  winget call: the newest one whose package `Get-AppxPackage -AllUsers` lists with status `Ok`, or,
  when that query fails or finds none, the newest
  `%ProgramFiles%\WindowsApps\Microsoft.DesktopAppInstaller_<version>_<architecture>__8wekyb3d8bbwe\winget.exe`
  that the query did not list with another status (versions compared as numbers, the PC's own
  architecture first). It checks that it starts (`winget --version`) and tries the next one if it
  does not. When none starts, the run stops with exit code 2 and says why: no App Installer for the
  PC, or the `winget.exe` found could not be started. `0xC0000135 STATUS_DLL_NOT_FOUND` is reported
  for a `winget.exe` started outside its package when a DLL it needs, reportedly the Microsoft
  Visual C++ 2015-2022 runtime, is missing; that `winget.exe` is not checked again, since it fails
  the same way until the runtime is installed.
- It skips every step that sets winget up for one account, since SYSTEM cannot have one:
  registering App Installer and `Repair-WinGetPackageManager` (so the `Microsoft.WinGet.Client`
  module it comes from is never installed). It still updates the winget source, and resets it if
  it is missing or corrupted.
- Every app is installed with `--scope machine` only. An app that has no machine-wide installer is
  not installed at winget's default scope, which as SYSTEM is SYSTEM's own profile: it is reported
  as `Deferred` in the summary. A deferred app counts neither as installed nor as failed and does
  not change the exit code. A per-user app can only be installed in the signed-in user's own
  account: by this installer run as that user when the account is an administrator, otherwise by a
  per-user deployment, such as an RMM script that runs as the user or the Microsoft Store (on a
  standard user's PC, the UAC prompt elevates as an administrator account, which defers the app
  again). winget answers `--scope machine` with the same `0x8A150010 NO_APPLICABLE_INSTALLER` when
  no installer applies to the PC at all, so a deferred app can also be one winget cannot install
  on this PC at any scope.
- Windows Terminal is decided from the PC: when its package is provisioned for every user, as
  Windows 11 does, it is `Skipped (already provisioned for every user on this PC)`. `winget list`
  run as SYSTEM does not see the MSIX apps registered for the users, so Terminal would read as
  missing on every run, and its install would then fail the same check. The check for a
  Terminal-hosted console (#271) does not apply to SYSTEM, and the Windows Terminal defaults step
  is skipped (see [Windows Terminal defaults](#windows-terminal-defaults)).
- Its messages are written for SYSTEM: no "cross-user elevation" banner and no advice to sign in
  to Windows as `NT AUTHORITY\SYSTEM`.
- Started from Windows PowerShell 5.1 on a PC without PowerShell 7, it installs PowerShell 7 from
  the MSI download, not with winget, since SYSTEM has no `winget` command; the bootstrap says so
  instead of saying winget is missing. The MSI path reads its release list from GitHub, which can
  answer `429 Too Many Requests` when many PCs on one network ask at once (exit code 7).

A run elevated as a different account than the signed-in user (cross-user elevation) installs for
the whole PC the same way: an app with no machine-wide installer is `Deferred` instead of being
installed into the admin account's profile and reported as installed, and Windows Terminal is
decided from provisioning, not from the admin's `winget list`. That run still sets winget up for
the admin account as before.

Not there yet: a single-run lock and a time budget for the whole run, a machine-readable result
line, and per-user setup after a SYSTEM run (the deferred apps and the Windows Terminal defaults
need the signed-in user's own account, see above). RMM tools read success from the exit code: list
any other code you accept, such as 3010, as a success code for the script.

### Exit codes

| Code | Meaning |
|------|---------|
| 0 | Success — all apps installed or already present (apps reported as `Deferred` do not count against it) |
| 1 | One or more apps failed to install, including an install stopped at its time limit and the apps not attempted because winget could no longer be started partway through the run (also: a blocking pre-flight system check failed) |
| 2 | Winget is unavailable or cannot be started (`winget --version` must run and print a version) and could not be set up (as SYSTEM: no machine-wide `winget.exe` was found, or none could be started), App Installer's Group Policy turns winget or its source off (see **Setting winget up** above), or winget could no longer be launched at the end of the run (no app failed, but automatic updates and the next run would) |
| 3 | App-definition validation failed, or no valid app definitions remain |
| 4 | Administrator rights are required and the run was not elevated: the UAC prompt was declined or the elevated window could not be started, the run is non-interactive (no prompt is shown), it runs through `irm \| iex` in PowerShell 7, or `Invoke-WingetInstall` was called from the imported module (see [Administrator rights](#administrator-rights)) |
| 5 | The run was aborted before it finished: an unexpected error (the message and stack trace are in the log), the run was stopped from outside (Ctrl+C, the console closing, an installer stopping the console) when run from a file or non-interactively, or the installer file changed before its elevated copy could run (see [Administrator rights](#administrator-rights)) |
| 7 | Started from Windows PowerShell 5.1, the installer could not install PowerShell 7 or could not relaunch itself under it |
| 3010 | Success, but a restart is required to finish: an install said so, the Winget-AutoUpdate MSI returned 3010, Windows gained a pending restart during the run, or installing PowerShell 7 from Windows PowerShell needed a restart (see **Restart required** above). RMM tools and Intune treat 3010 as "succeeded, restart required". A restart that was already pending before the run does not cause it |

At the end of a run, when more than one applies, the code is the first of 1, 2, 3010 and 0. A run
that relaunched itself elevated exits with the elevated run's code. Apps reported as `Deferred` (a
run as SYSTEM or under cross-user elevation found no machine-wide installer for them) do not change
the code.

A script that imports the `WingetAppSetup` module and calls `Invoke-WingetInstall` itself gets
codes 0-4 and 3010 back as the function's return value; the function never exits. Pass the code on
with `exit (Invoke-WingetInstall -NonInteractive)`, or the wrapper exits 0 even after a failed run.
Codes 5 and 7, and code 1 for a failed pre-flight check, come from `winget-app-install.ps1`
itself, not from the function.

## Logs

Every run writes a full transcript to
`%ProgramData%\winget-app-setup\logs\install-<yyyyMMdd-HHmmss>.log` (dry runs get a `-whatif`
suffix, e.g. `install-20260708-143000-whatif.log`). The path is printed at startup and repeated
with the final summary. ProgramData is used — rather than the elevating account's `%TEMP%` — so
the log survives cross-user elevation and can be collected after a failed install on a remote
machine. If the transcript cannot be started, the installer warns and continues: logging never
blocks an install. A run that relaunched itself elevated leaves the first window's log, which ends
with `The elevated run ended with exit code N.`, next to the elevated run's own logs.

The transcript includes winget's own output. Each `winget install`, `winget download` and
`winget source reset` is logged as a `> winget ...` line with its full command line, followed by
what winget printed, indented: for example
`Installer failed with exit code: 1603` or a hash mismatch. The spinner and the download progress
bar are left out, apart from the last progress line of each download, and a message winget shows
next to its spinner, such as `Waiting for another install/uninstall to complete...`, is logged once
rather than at every redraw. The per-app `winget list` checks print nothing; the source update
prints winget's output only when it fails.

The same folder also holds:

- `install-<yyyyMMdd-HHmmss>-bootstrap.log` — the Windows PowerShell 5.1 phase of a run started
  from `powershell.exe`: finding or installing PowerShell 7 and relaunching under `pwsh`, ending
  with the exit code the relaunched run returned. The elevated window of a run that relaunched
  itself elevated starts in Windows PowerShell too, so it writes one of these as well.
- `pwsh-msi-<yyyyMMdd-HHmmss>-<attempt>.log` — `msiexec`'s verbose log when the bootstrap installs
  PowerShell 7 from the MSI.
- `winget-install-<package id>-<yyyyMMdd-HHmmss>.log` — the installer's own log for each
  `winget install` attempt (winget's `--log`), when the installer writes one: MSI, WiX, Burn and
  Inno installers do, most other EXE installers do not. A failed app's reason in the summary names
  this file.

An elevated run gives standard users read access to the `logs` folder, so the log can be opened
from the end user's own session after a cross-user elevated run. Installing Winget-AutoUpdate
makes the parent `%ProgramData%\winget-app-setup` folder admin-only, so open the logs by their full
path (for example, paste `C:\ProgramData\winget-app-setup\logs` into File Explorer's address
bar).

Each transcript begins with an `Installer build:` line carrying the content-derived build id
(`<module version>+<8-char SHA256 fragment of the whole generated script>`) stamped by
`build/Build-WingetInstallScript.ps1`, so you can tell exactly which installer build produced a
given log. The summary and failure tables are written at full width, so long app lists and
failure reasons are never cut off in the log.

### When a run fails

A run that stops early (a failed pre-flight check, winget missing, a declined elevation, a failed
PowerShell 7 setup, an unexpected error) ends with one block: the exit code and why, the log file
path, the installer build, and where to report it. When someone is at the console, it then waits
for a key press, so the window does not close before you can read it (under `irm | iex` the run
ends the PowerShell window it runs in). Unattended runs never wait.

To report a failure, open an
[install failure issue](https://github.com/J-MaFf/winget-app-setup/issues/new?template=install-failure.yml)
with the exit code, the installer build and the log file.

> **Privacy: this repository and its issues are public.** Every PowerShell transcript starts with a
> header that names the computer, the signed-in account and the account that ran the installer
> (`Username`, `RunAs User`, `Machine`). Delete that header, or replace the names in it, before
> you paste or attach a log, and check the rest for account or computer names. If a log cannot be
> shared publicly, send it to the maintainer privately.

## Automatic updates

Ongoing updates are handled by [Winget-AutoUpdate (WAU)](https://github.com/Romanitho/Winget-AutoUpdate),
which the installer sets up automatically (a pinned, SHA256-verified version). WAU runs as SYSTEM on a
weekly schedule (Tuesdays at 02:00; a missed run catches up shortly after the next start) and updates
installed apps machine-wide, plus a user-context pass for the logged-on user — which avoids the
cross-user `0x80073d19` problems a per-user scheduled task hits.

Every WAU run first updates winget itself, so the installer keeps WAU out of its own way: WAU is set
up last, after the retry pass, it is not started immediately and not at user logon (machines deployed
by older versions have their logon trigger removed on the next run), and if a WAU run is already in
progress when the installer starts, the installer waits up to 15 minutes for it to finish. WAU is only
installed when `Microsoft.WindowsAppRuntime.1.8` is present, because the winget releases it installs
need that framework and would otherwise leave winget unusable; the summary then shows
`Auto-updates: NOT CONFIGURED` (issues #279, #283, #284).
The WAU MSI is downloaded into a new folder inside `%ProgramData%\winget-app-setup`. The installer
first makes Administrators the owner of both folders, limits them to SYSTEM and Administrators, and
reads the result back; if a folder still has another owner or access entry, WAU is not downloaded,
the run says why and how to reset the folder, and the summary shows `Auto-updates: FAILED`. When a
folder cannot be set up for another reason (it cannot be created, or `icacls` does not start), the
run gives that reason without the reset advice, which would not help. The MSI is hashed from a
handle that stays open until `msiexec` has finished, so nothing can replace it in between.
WAU's own self-update is disabled so the version stays pinned; bump it via `Get-WauPin` in
`WingetAppSetup/Public/WingetAutoUpdate.ps1`. `winget-app-uninstall.ps1` removes WAU (and any legacy
scheduled-update task from older versions).

## Windows Terminal defaults

After the first install pass, the installer makes PowerShell 7 the default Windows Terminal profile
and Windows Terminal the default terminal application, for the logged-on user. It edits each
Windows Terminal `settings.json` it finds under `%LOCALAPPDATA%` (stable, preview, other Terminal
packages such as Canary, and unpackaged Terminal). Only the top-level `defaultProfile` changes, or
is added when it is missing: comments, commented-out profiles, formatting and key order stay as
they were, and the previous file is saved next to it as `settings.json.winget-app-setup.bak`. If
the edit would change anything else, or the file is not valid UTF-8, the file is left as it is and
the run prints a warning. A `settings.json` that is a symbolic or hard link is edited through the
link. The default terminal application (`HKCU:\Console\%%Startup`) is only set when Windows
Terminal is installed ([#271](https://github.com/J-MaFf/winget-app-setup/issues/271)).

Both settings are per-user, so the step is skipped, with one line in the log, when the run is
SYSTEM (for example under an RMM agent) or is elevated as a different account than the logged-on
user. It never writes to another user's profile.

## End-to-end monitoring (e2e tier 1)

The unit suite mocks every external call, so a real install is exercised by an end-to-end run
(`.github/workflows/e2e-install.yml`, issue #214) on GitHub-hosted `windows-latest` runners —
throwaway VMs by construction:

- **When it runs:** weekly (Mondays 06:00 UTC), on manual dispatch, and on pull requests. Every
  pull request starts the workflow. A `changes` job lets the two install jobs run only when the PR
  touches the product (`WingetAppSetup/**`, `build/**`, `winget-app-install.ps1`) or the e2e
  machinery (`.github/workflows/e2e-install.yml`, `e2e/**`), and they install anyway if that job
  does not succeed. The filter is a job rather than a `paths:` filter so that `e2e-install` can be
  a required check: a job skipped by its `if:` reports success, while a workflow that `paths:`
  skips reports no status and would block every other PR. `main` is production (the one-liner
  downloads it directly), so this is the only un-mocked run a product change gets before it
  reaches users.
- **Two legs:** each on its own VM, each installing the curated catalog twice. `e2e-install`
  starts every pass from PowerShell 7. `e2e-install-windows-powershell` starts every pass from
  Windows PowerShell 5.1, the way a fresh PC runs the one-liner. It removes PowerShell 7 first, so
  its first pass goes through the bootstrap that installs PowerShell 7 and relaunches the
  installer, and its second pass finds PowerShell 7 and relaunches. Before the first pass, both
  legs uninstall the catalog apps the runner image ships with (Google Chrome, 7-Zip and Git;
  `e2e/Remove-PreinstalledApps.ps1`), so the first pass really installs them. Every call there has
  a time limit (`winget list` 45 s, uninstall 150 s), each app's result prints as soon as it is
  done, and an app that cannot be removed gets a warning annotation and is skipped by the first
  pass as already installed.
- **What it does:** the weekly run uses the one-liner above, against raw `main`, in both passes.
  Pull-request and dispatched runs install the checkout (the PR's merge commit, or the dispatched
  branch). The first pass pipes it to `iex` like the one-liner, and the second runs it with
  `-File` like a clone or RMM run, so both entry points get an un-mocked run before a change
  ships. In the 5.1 leg, the first pass's bootstrap downloads the installer from raw `main` again
  for its PowerShell 7 relaunch; on checkout runs that one download is answered with the checkout,
  so the PowerShell 7 half of the pass tests the change too. `e2e/Invoke-InstallPass.ps1` starts
  every pass and decides whether it passed: it must exit 0, or 3010 (OK, restart required). Exit 1
  is tolerated only while `KNOWN_PLATFORM_INCOMPATIBLE` is non-empty, and the assertions then
  check that nothing outside that list failed. Any other code fails the pass with the installer's
  code. The second pass proves idempotence.
- **What it checks:** the shared assertion script
  `e2e/Assert-Install.ps1 -ExpectAllSkippedOnSecondRun` checks that every **applicable**
  `Get-DefaultAppCatalog` app resolves via `winget list` (exit-code classified) — the script
  evaluates each app's catalog condition on the runner, and not-applicable apps must instead show
  their `not applicable` skip line in the latest transcript — the WAU scheduled task exists and its
  version matches `Get-WauPin` (on a runner without `Microsoft.WindowsAppRuntime.1.8`, such as
  `windows-latest`, WAU must instead be absent and the transcript must say
  `Auto-updates: NOT CONFIGURED`), a transcript with the `Installer build` stamp exists, no app
  outside the skip list is still failed at the end of either pass (read from the summary's `Failed`
  row and every failure line the retry pass did not recover; a transcript with no summary fails),
  and every applicable app is Skipped on the second pass. In pull-request and dispatched runs,
  every transcript, the Windows PowerShell 5.1 `-bootstrap` ones included, must log the build id of
  the checkout's `winget-app-install.ps1` (`-InstallerPath`), so a run that quietly tested another
  copy fails. The weekly run fetches raw `main`, which can trail the checkout by a few minutes of
  CDN caching, so it is not checked. The 5.1 leg adds
  `-ExpectPowerShell7Bootstrap -ExpectPowerShell7Installed`: every pass went through the bootstrap
  and relaunched under PowerShell 7, and the first pass's bootstrap installed PowerShell 7 rather
  than finding it. The transcript checks live in `e2e/TranscriptAssertions.ps1` and are tested
  against sample transcripts in `tests/fixtures/e2e`. The script's `-SkipApps` parameter is an
  escape hatch for runner-platform incompatibilities only; each use must reference a GitHub issue
  at the call site. Dell Command Update is **no longer skip-listed** there: the catalog's
  manufacturer condition ([#217](https://github.com/J-MaFf/winget-app-setup/issues/217)) gates it
  in the product itself, so the non-Dell runners exercise the gating for real on every run.
- **Not covered yet:** Winget-AutoUpdate's own update run (`windows-latest` lacks
  `Microsoft.WindowsAppRuntime.1.8`, so the installer skips WAU there; the framework could be
  provisioned on the runner first, but that is untried on this image), the catalog's own
  PowerShell install (`Install-PowerShellLatest`: PowerShell 7 is preinstalled in one leg and
  installed by the bootstrap in the other), and cross-user elevation (tier 2, below).
- **Where the evidence lands:** transcripts are written on the runner under
  `%ProgramData%\winget-app-setup\logs` (the same place as production runs) and always uploaded
  as the `e2e-install-transcripts` artifact (`e2e-install-transcripts-windows-powershell` for the
  5.1 leg, which also holds its `-bootstrap` transcripts). `e2e/Collect-Diagnostics.ps1` runs in
  Windows PowerShell 5.1 before the first pass, after it and at the end of the job. It records the
  pwsh versions, the App Installer and `Microsoft.WindowsAppRuntime*` AppX packages registered for
  any user or provisioned, and the `\WAU\` tasks with their last run. The end-of-job snapshot adds
  MsiInstaller and RestartManager events, AppX deployment errors and warnings, and
  Winget-AutoUpdate's logs. A missing source is noted and the script still exits 0, so it never
  fails the job. The snapshots, plus the assertion output saved by the assertions step, are
  always uploaded as the `e2e-diagnostics` artifact (`e2e-diagnostics-windows-powershell` for the
  5.1 leg).
- **On failure:** when a scheduled run or a run dispatched on `main` fails, times out or is
  cancelled in either leg, a separate `report-failure` job on `ubuntu-latest` downloads the
  artifacts. It creates a GitHub issue titled `E2E install run failed`, or comments on an existing
  open one. The issue lists the run URL and which installer ran, then has one section per leg; a
  leg that passed says so. For a leg that did not succeed it shows the steps that did not succeed
  and how long each ran, the assertion PASS/FAIL table, the last 50 lines of the earliest and
  latest install transcripts, the last 50 lines of the latest Windows PowerShell 5.1 bootstrap
  transcript (5.1 leg), and the diagnostics snapshots. The same text goes to the run's summary
  page. The job runs outside the Windows jobs, so it still reports a run that lost PowerShell 7 or
  hit its time limit. Pull-request runs and runs dispatched on another branch never file the
  issue: they test unmerged code, and their result shows on the PR or the run. The assertions also
  run after a failed install pass (the idempotence checks only when the second pass ran). Removing
  the preinstalled apps has a 15-minute limit (20 in the 5.1 leg, which also removes PowerShell 7),
  each install pass 35 minutes and the assertions 40, under the job's 145 (150 in the 5.1 leg), so
  a hung step fails at its own limit while the diagnostics and uploads still run.
- **Trigger manually:** `gh workflow run e2e-install.yml` tests `main`.
  `gh workflow run e2e-install.yml --ref <branch>` installs that branch's checkout, so a change
  can be tested before it merges. The branch must already contain this version of the workflow,
  because `--ref` also runs that branch's copy of the workflow, and an older copy still installs
  raw `main`. Watch with `gh run list --workflow e2e-install.yml` / `gh run watch <run-id>`.

Tier 2 ([#215](https://github.com/J-MaFf/winget-app-setup/issues/215)) will reuse
`e2e/Assert-Install.ps1` for a cross-user elevation run on a snapshot-rollback VM.

## Project layout (for contributors)

The installer's logic lives in the **`WingetAppSetup` PowerShell module** under `WingetAppSetup/`
(`Public/` for exported functions, `Private/` for internal helpers). The single-file
`winget-app-install.ps1` is **generated** from that module so the `irm | iex` one-liner keeps
working — do not edit it by hand.

After changing anything under `WingetAppSetup/`, regenerate the installer:

```powershell
pwsh -File .\build\Build-WingetInstallScript.ps1
```

Verify the committed script is in sync with the module (useful in CI / pre-commit):

```powershell
pwsh -File .\build\Build-WingetInstallScript.ps1 -Check
```

Run the test suite (one `<Area>.Tests.ps1` per module file under `tests/`, plus
`EntryPoint.Tests.ps1`, `TestHarness.Tests.ps1`, `BuildGuards.Tests.ps1` and the `E2E*.Tests.ps1`
files for the entry point, the suite's own loading rules, the build guards and pre-commit hook,
and the `e2e/` scripts, with sample transcripts in `tests/fixtures/e2e`; each loads the module
directly via `tests/TestHelpers.ps1`):

```powershell
Invoke-Pester .\tests
```

The suite also runs on Linux and macOS (PowerShell 7 with Pester 6): `tests/TestHelpers.ps1`
stands in for the Windows-only commands the tests mock, so no test is known to fail there and any
failure is new. No test depends on whether the runner is elevated: the tests mock `Test-IsAdmin`.
The Windows CI run stays the verdict.

Start winget through `Invoke-WingetProcess` and `msiexec` through `Invoke-ExternalProcess`
(`WingetAppSetup/Private/ProcessInvocation.ps1`) rather than with `Start-Process` or a bare
`winget` call, so every call gets a time limit, its output in the transcript and an exit code read
from the process. One older caller still uses `Start-Process`, with its own time limit: the
PowerShell 7 bootstrap's `msiexec`. To check that winget can be started, use
`Test-WingetLaunchable` (`WingetAppSetup/Private/WingetLaunchResilience.ps1`), not
`Get-Command winget`.
Tests mock the two functions and build their results with `New-TestProcessResult` from
`tests/TestHelpers.ps1`; a test that scripts winget with `Mock winget` routes it through
`Invoke-TestWingetMock`.

### One-time setup: local pre-commit drift check

The repo tracks a pre-commit hook (`.githooks/pre-commit`) that runs the same `-Check`
before a commit lands. Enable it once per clone:

```powershell
git config core.hooksPath .githooks
```

The hook is fast and forgiving by design: it only runs when the staged files touch
`WingetAppSetup/`, `build/`, a `.psd1` manifest, or `winget-app-install.ps1` itself, and if
`pwsh` is not on `PATH` it prints a warning and lets the commit through — CI enforces the same
check on every push and pull request, so nothing ships unverified either way. It checks the
staged files (exported to a temporary directory with `git checkout-index`), not the working tree,
so a module change staged without its regenerated installer is blocked even when the working tree
was rebuilt. On failure it prints how to fix it: re-run the build and stage the regenerated
installer together with your module change.

> **If you also use the beads hooks:** `bd hooks install` (opt-in — the shims under
> `.beads/hooks/` are inert by default) writes its hooks into `.git/hooks/`, and setting
> `core.hooksPath` makes git ignore `.git/hooks/` entirely, silently disabling them. If you
> want both, leave `core.hooksPath` unset and instead add a line to your
> `.git/hooks/pre-commit` that invokes `.githooks/pre-commit` — the drift check runs the same
> way from either location.

### Why `winget-app-install.ps1` cannot drift from the module

The generated installer is guaranteed to match the `WingetAppSetup` module by a stack of
guards, most of which run in both build and `-Check` modes of
`build/Build-WingetInstallScript.ps1`:

1. **Byte-compare with BOM rejection** — `-Check` regenerates the installer in memory and
   compares it (LF-normalized) against the committed file byte for byte; it also inspects the
   raw bytes and rejects a leading UTF-8 BOM that a text comparison would silently strip
   ([#183](https://github.com/J-MaFf/winget-app-setup/issues/183)).
2. **Assembled-script parse guard** — the assembled script is parsed and any syntax error
   fails the build with line/column details, so an unbalanced brace in a module file can no
   longer ship a broken installer ([#183](https://github.com/J-MaFf/winget-app-setup/issues/183)).
3. **AST undefined-reference guard** — every hyphenated command the assembled script invokes
   must resolve to a module-defined function (matched case-sensitively, so a stale call site
   cannot silently resolve to an external cmdlet that differs only by case) or an external
   command; catches functions dropped from the module while still being called — the drift
   class that broke the one-liner in
   [#154](https://github.com/J-MaFf/winget-app-setup/issues/154). Runs on every platform. On
   Linux and macOS the Windows-only cmdlets the installer calls, listed in
   `build/windows-only-commands.txt`, count as resolvable and every other name is checked as on
   Windows; when an off-Windows build fails on a genuine Windows-only cmdlet, add it to that list.
   On Windows each listed name must resolve, so the list cannot hide a missing module function. On
   every platform a listed name the installer no longer calls draws a warning.
4. **psd1 export assertion** — `WingetAppSetup.psd1`'s `FunctionsToExport` must exactly
   (case-sensitively) match the functions defined under `WingetAppSetup/Public/*.ps1`, so a
   new public function cannot be silently filtered on manifest imports
   ([#191](https://github.com/J-MaFf/winget-app-setup/issues/191)).
5. **Windows PowerShell 5.1 parse-safety guards** — 5.1 parses the whole installer before it
   runs any of it, so the file must stay 5.1-parseable even though the install itself runs under
   PowerShell 7. Syntax that only PowerShell 7 parses (`??`, `??=`, `?.`, `?[`, the ternary `?:`,
   the `&&` / `||` pipeline chains, the background operator `&` as in `Get-Process &`, and
   `clean { }` blocks) fails the build; the guard reads token kinds and the AST, so the same
   characters inside strings, comments and regexes are fine, and so is the call operator
   `& $cmd`. And every non-comment token of the assembled script must be pure ASCII. The
   installer ships as BOM-less UTF-8, which 5.1 decodes as ANSI: a multi-byte character inside a
   string literal misdecodes (an em dash's 0x94 byte becomes a string-terminating curly quote)
   and cascades into parser errors before the version dispatch can run. Keeping code tokens ASCII keeps the file
   5.1-parseable so 5.1 reaches the version check and runs the PowerShell 7 bootstrap
   (find-or-install `pwsh`, then relaunch — [#225](https://github.com/J-MaFf/winget-app-setup/issues/225));
   comments are exempt because misdecoded bytes there cannot change tokenization
   ([#210](https://github.com/J-MaFf/winget-app-setup/issues/210)).
6. **Content-derived build id** — the banner and `$script:InstallerBuildId` are stamped with
   `<module version>+<8-hex SHA256 fragment of the whole generated script>` (hashed with the id
   slots blanked, so a change to `build/fragments/head.ps1` or `tail.ps1` changes the id too),
   derived from content only (never git metadata or timestamps) so rebuilding the same tree is
   byte-identical and the `-Check` byte-compare stays deterministic; transcripts log the id at
   startup so a log identifies the exact installer build
   ([#189](https://github.com/J-MaFf/winget-app-setup/issues/189)).
7. **CI enforcement** — `.github/workflows/windows-tests.yml` runs `-Check` on every push to
   `main` and on every pull request, so drift fails CI instead of shipping
   ([#156](https://github.com/J-MaFf/winget-app-setup/issues/156)).
8. **Local pre-commit hook** — `.githooks/pre-commit` (above) runs the same `-Check`, against
   the staged files, before a commit that touches the module, the build, a manifest, or the
   installer, catching drift before it is even committed
   ([#211](https://github.com/J-MaFf/winget-app-setup/issues/211)).
