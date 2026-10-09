# Winget App Setup

Installs a curated set of apps on a Windows PC with winget, from one PowerShell line, and sets up
automatic updates for them.

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
instead. The bootstrap deletes its downloaded copy once the `pwsh` run has ended.

The installer asks for administrator rights when it needs them (see
[Administrator rights](#administrator-rights)), sets winget up, and installs each app of the
[curated list](#app-catalog) that is not there yet. It does not update an app that is already
installed: it prints `Skipping: <id> (already installed)`. It sets up
[Winget-AutoUpdate](#automatic-updates) last, which updates the apps from then on.

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
- The elevated run keeps its own files in `%ProgramData%\winget-app-setup`: its logs, the
  Winget-AutoUpdate, Windows App Runtime and Microsoft.WinGet.Client downloads, and that module's
  `cache` folder. Any user can create a folder in `%ProgramData%`, and turn an empty folder there
  into a junction (a link to another folder). So before an elevated run, or a run as SYSTEM,
  writes, locks or deletes anything there, it makes `%ProgramData%\winget-app-setup` and its
  `logs` or `cache` folder safe. A junction or symbolic link in a folder's place is removed without
  changing what it points to, and the run warns about it. A missing folder is created already
  locked. Each folder is then locked, so that only SYSTEM and Administrators can change it, with
  Administrators as its owner. A folder that a standard user created before the first elevated run,
  such as the ones the installer's own first, non-elevated window creates for its log, is locked in
  place: what is already in it stays. See [Logs](#logs) for what a run does when a folder cannot be
  made safe.
- Declining the prompt ends the run with exit code 4, with no second prompt.
- Group Policy can set the Windows PowerShell execution policy (`Turn on Script Execution`) to
  `AllSigned` (only signed scripts) or `Restricted` (no scripts). `-ExecutionPolicy Bypass`, which
  the elevated window is started with, does not override it, so that window could not run the
  installer. When the policy is set for the PC, the run says so in one line and exits 4 without
  showing the prompt. When it is set only for the signed-in account, the run warns and asks
  anyway, because another administrator may approve the prompt. The elevated window then checks
  the policy of the account that approved it. Under `AllSigned` or `Restricted` it prints
  `Did not run winget-app-install.ps1: Group Policy sets the execution policy to AllSigned, which -ExecutionPolicy Bypass cannot override`,
  waits for Enter, and the run exits 4. The uninstaller's elevated window makes the same check
  (`Did not run winget-app-uninstall.ps1: ...`).
- A non-interactive run that is not elevated (`-NonInteractive`, a scheduled task, an RMM agent
  running as the signed-in user) shows no prompt and exits 4 at once: nobody would be there to
  approve it.
- Under `irm | iex` in PowerShell 7 there is no file to relaunch, so a run that is not elevated exits
  4 and asks you to open an elevated session. The Windows PowerShell 5.1 one-liner relaunches from
  the copy it downloads.
- `winget-app-uninstall.ps1` elevates the same way, checked copy included. It is one generated
  file too, so its elevated window runs a copy checked against the SHA256 the file had when it
  started, from its own new folder under `%SystemRoot%\Temp`. A file rewritten while the prompt was
  up is not run (exit code 5). The copy runs under Windows PowerShell 5.1, with no PowerShell 7
  bootstrap.

## App catalog

The curated app list is `Get-DefaultAppCatalog` (`WingetAppSetup/Public/AppCatalog.ps1`) — the
single source of truth shared by the installer and `winget-app-uninstall.ps1`. Entries may
declare an optional applicability **condition** (a scriptblock) and an **`arch`** list (the OS
architectures the app is for), with a human-readable `conditionDescription` that serves as the
reason for both. The installer evaluates each entry's `arch` list, then its condition, once per
run, before it installs anything or runs any winget call for the app, and both the first pass and
the retry pass use that answer. An app whose `arch` list or condition does not hold on the current
machine is reported as
`Skipping: <id> (not applicable: <reason>)` and counted as Skipped in the summary instead of being
pointlessly installed. A condition that cannot answer (it throws or writes an error, such as a
failed CIM query) fails open: the run prints
`Condition for <id> failed to evaluate (<error>); treating as applicable and attempting the install.`
and installs the app as usual, so a broken probe can never silently drop an app. If that install
fails, it counts toward exit code 1. Gated entries:

- `Dell.CommandUpdate.Universal`
  (`Dell hardware with x64 Windows only; winget has no ARM64 installer for it`): installs only
  when `Win32_ComputerSystem` reports a Dell manufacturer
  ([#217](https://github.com/J-MaFf/winget-app-setup/issues/217)) and Windows is x64
  (`arch = 'X64'`). winget carries only Dell's x64 build; Dell publishes its ARM64 build for
  Snapdragon PCs separately. On ARM64, winget would also pair the x64 build with the Arm64 .NET
  Desktop Runtime its dependency resolves to. So an ARM64 Dell PC skips it, before any
  manufacturer query, and needs Dell's ARM64 build from Dell. A failed CIM query or an empty
  manufacturer is no answer, so the install is attempted on an x64 PC.
- `Adobe.Acrobat.Reader.64-bit` and `Adobe.Acrobat.Reader.32-bit`: one Reader per PC, chosen by
  the operating system's architecture through each entry's `arch` list. The 64-bit package's only
  installer is x64, and Adobe supports only the 32-bit (x86) Reader on Windows on ARM. So x64 PCs
  get `Adobe.Acrobat.Reader.64-bit` (`arch = 'X64'`), and ARM64 and 32-bit (x86) PCs get
  `Adobe.Acrobat.Reader.32-bit` (`arch = 'Arm64', 'X86'`; under emulation on ARM64). The other
  entry shows its `not applicable` skip line on every run (32-bit Arm Windows gets neither). The
  architecture comes from .NET's `RuntimeInformation.OSArchitecture`. On PowerShell 7.3 and later
  (the bootstrap installs 7.6) it reports the real architecture, even in a 32-bit PowerShell or in
  an x64 PowerShell running under emulation on an ARM64 PC. An x64 PowerShell 7.0-7.2 under
  emulation reads X64, so such a PC is offered the 64-bit Reader (and, on a Dell, Dell Command
  Update).
- `Microsoft.WindowsTerminal`: skipped while Windows Terminal hosts the run, because winget cannot
  replace the terminal it is running in ([#271](https://github.com/J-MaFf/winget-app-setup/issues/271)).
  The default-terminal registry values count as hosting only while Windows Terminal is installed,
  so values left behind after Windows Terminal was removed no longer make every later run skip it.

`Google.GoogleDrive` is deliberately not gated on ARM64. winget's only installer is labelled x64,
but Google's update server sends ARM64 PCs the same `setup.exe`, and Drive for desktop runs
natively on Windows 11 ARM64. Whether a winget install puts the native ARM64 file-system driver in
place is not yet confirmed on ARM64 hardware. Windows 10 ARM64 (end of servicing since 2025-10-14)
emulates only x86, so winget finds no applicable Drive installer there (`0x8A150010`): the app
fails on every run (exit code 1), or, in a run as SYSTEM or under cross-user elevation, is
`Deferred` as having no machine-wide installer. Google does not support Drive on Windows 10
ARM64, and an `arch` list cannot tell it from Windows 11 ARM64.

The uninstaller honours the same conditions and `arch` lists: it leaves an installed app alone when
they do not hold (see [Uninstall](#uninstall)).

An entry may also name its MSIX package (`msixName`, set for `Microsoft.WindowsTerminal`): a run
as SYSTEM or under cross-user elevation then decides whether the app is installed from whether that
package is provisioned for every user, not from `winget list` (see
[Running as SYSTEM](#running-as-system-rmm-tools-such-as-endpoint-central)). The uninstaller
leaves such an app alone in those runs (see [Uninstall](#uninstall)).

### Catalog entry fields

Every entry is a hashtable with the winget package id in `name`. The other fields are optional.
The installer checks every entry before it installs anything: a wrong value (an unknown `scope`, an
architecture name it does not know, a `postInstall` that names no function, a `userPhase` that is
not `$true` or `$false`, a `quietUninstall` without a braced-GUID `productCode` or with no
`arguments`) stops the run with exit code 3 and names the entry, and a field it does not know is
reported as a warning and ignored.

| Field | Meaning |
|-------|---------|
| `name` | The winget package id (`publisher.product`) |
| `condition`, `conditionDescription` | Applicability scriptblock and the reason shown when the app does not apply (see above). The description is shown for an `arch` skip too |
| `arch` | The OS architectures the app is for: one or more of `X86`, `X64`, `Arm`, `Arm64` (as `RuntimeInformation.OSArchitecture` names them; case does not matter). On another architecture the app is `not applicable`; without a `conditionDescription` the skip line says `for <list> Windows only; this PC is <architecture>`. When the architecture cannot be read, the list counts as met (fail open, as for conditions). The uninstaller honours it too |
| `scope` | `any` (default): install at machine scope, and fall back to winget's default scope when the package has no machine-wide installer, except as SYSTEM or under cross-user elevation, which reports the app `Deferred` instead. `machine`: machine scope only, in every run; a package with no machine-wide installer fails (exit code 1, and the retry pass leaves it alone: winget would give the same answer) rather than being installed for one account or deferred. `user`: `--scope user` in a run as the signed-in user; `Deferred` as SYSTEM or under cross-user elevation, without asking winget. The scope is how the installer installs an app, not a condition on an install that is already there: an app that `winget list` already shows for the account running the installer, at either scope, is `Skipped (already installed)` |
| `userPhase` | `$true` marks an app or setting that needs the signed-in user's own account (for example a hook that writes the user's settings): `Deferred` as SYSTEM or under cross-user elevation, installed as usual in any other run |
| `postInstall` | A scriptblock, or the name of a function of the installer, that configures the app once it is installed (see below) |
| `install` | A package-specific installer function that verifies its own install (`Install-PowerShellLatest`) |
| `installerType` | winget `--installer-type` override |
| `msixName` | The app's MSIX package name (see above) |
| `quietUninstall` | `@{ productCode = '{<GUID>}'; arguments = @('<switch>', ...) }`: for an exe app whose registered uninstall command waits for a click, the uninstaller runs the program the `productCode` uninstall entry names with these switches instead of `winget uninstall` (see [Uninstall](#uninstall)). `productCode` must be a braced GUID and `arguments` one or more strings without a double quote. Set for `Google.GoogleDrive` (`--silent --force_stop`) |

**Post-install hooks.** A `postInstall` hook runs after the install is verified, and on every run
that finds the app already installed (or provisioned for every user), so it must be idempotent:
check each setting and change only what differs. It never runs in a dry run (which prints
`[DRY-RUN] Would run the post-install configuration of <id>.`) or for an app that was not
installed. It is called with the catalog entry as its one argument, runs in the run's account
(SYSTEM in an RMM run, so per-user settings belong on a `userPhase` entry), and its last output is
its result:

- `'Configured'`: the run prints `Configured: <id>`.
- `@{ Status = 'NotConfigured'; Reason = '<why>' }`: the app stays installed, the run prints
  `Not configured: <id> (<why>)` and, under the summary,
  `Configuration: NOT DONE for <id> (<why>) - ...`. The exit code does not change.
- `@{ Status = 'Failed'; Reason = '<why>' }`, a hook that throws or writes an error, or any other
  result: the app is `Failed` with `installed, but its post-install configuration failed (<why>)`,
  the retry pass runs the hook again, and the run exits 1 if it still fails. The install stands
  either way: a restart it needs is counted (exit code 3010 when nothing else decides it) and its
  exit code stays in the app's entry, and an app that was already installed before the run is
  `Skipped`, not `Installed`, when the retry pass configures it.

The result is in the app's entry in [`last-run.json`](#run-result) (`postInstall`,
`postInstallReason`). `GlavSoft.TightVNC` has one (see below).

### TightVNC server password

winget installs TightVNC Server (`GlavSoft.TightVNC`, a machine-wide MSI) with its service running
and the firewall open, but with no password: until it has one it refuses every viewer ("Server is
not configured properly"), and with no control password any signed-in user can reconfigure or stop
it from its tray icon. Its post-install hook, `Set-TightVncServerPassword`, sets both from a secret
you supply at run time. The repository is public, so the password is never stored in it.

Where the password comes from, in this order:

1. `WINGET_APP_SETUP_TIGHTVNC_PASSWORD` in the run's environment, and optionally a different
   `WINGET_APP_SETUP_TIGHTVNC_CONTROL_PASSWORD` for the control interface (recommended). The
   PowerShell 7 run reads them at its start and removes them from its own environment before it
   starts winget or any installer, so those do not inherit them. Processes started before that
   keep a copy in their environment: on a PC without PowerShell 7, the Windows PowerShell 5.1
   bootstrap and the winget or `msiexec` it runs to install PowerShell 7, and, in every elevated
   run, the `icacls` runs that lock the installer's folders under `%ProgramData%` before the
   transcript starts.
2. Otherwise, in an interactive run, a prompt at the start of the run, before anything is installed:
   `TightVNC server password`, typed twice and shown as `*`. Press Enter without typing to skip
   it. It is asked only when TightVNC Server does not have its passwords yet, so a re-run does not
   ask again. The prompt waits at most 5 minutes for you to start typing, then counts as skipped:
   the run holds the [run lock](#one-run-at-a-time) meanwhile, so a window left at the prompt
   would otherwise make every other run exit 6. It is not asked when PowerShell itself was started
   with `-NonInteractive` (`pwsh -NonInteractive -File ...`), where it cannot read input.
3. Otherwise (a run as SYSTEM, `-NonInteractive`, or a skipped prompt) TightVNC is installed but
   **not configured**: the run prints `TightVNC installed but NOT configured: no server password was
   supplied. ...`, which says what the server lets through (it refuses every viewer, it accepts
   viewers without a password, or any signed-in user can reconfigure it), and the summary's
   `Configuration: NOT DONE for GlavSoft.TightVNC (...)` line. The exit code does not change: a
   run that exits 0 can still leave TightVNC unusable, so an RMM tool should check for that line,
   or for `"postInstall": "NotConfigured"` in [`last-run.json`](#run-result). Supply the password
   and run the installer again.

From an RMM tool such as Endpoint Central, set the variables in the script that starts the
installer (it runs as SYSTEM), so the password lives in the RMM's script store, not in this
repository. With the Endpoint Central scripts in `rmm/`, that is your uploaded copy of the machine
phase (see [TightVNC password from Endpoint Central](#tightvnc-password-from-endpoint-central)). An
RMM script that runs the one-liner itself looks like this:

```powershell
$env:WINGET_APP_SETUP_TIGHTVNC_PASSWORD = '<server password, up to 8 characters>'
$env:WINGET_APP_SETUP_TIGHTVNC_CONTROL_PASSWORD = '<a different control password>'
$env:WINGET_APP_SETUP_NONINTERACTIVE = '1'
Set-ExecutionPolicy Unrestricted -Scope Process -Force; irm "https://raw.githubusercontent.com/J-MaFf/winget-app-setup/refs/heads/main/winget-app-install.ps1" | iex
```

Anyone who can read that script, in the RMM console or on the PC while it runs, can read the
password, so limit who can. With PowerShell Script Block Logging turned on (Group Policy), Windows
also records the script's text, password included, in the PowerShell event log (event 4104): turn
on Protected Event Logging there, or use an RMM feature that sets the variable without putting the
password in the script text. Do not pass the password as a script argument: arguments are on the
process command line, which Windows process auditing and EDR tools record. Do not set the variables machine-wide or for a user
account either (`setx`, System Properties), where other processes can read them. At a console, set
them in an elevated session: a UAC relaunch starts a new process without them, which then asks for
the password instead. The installer removes them from the PowerShell 7 process that installs. A
console that started that process (Windows PowerShell running the bootstrap, or a console that ran
`pwsh -File ...`) keeps its own copy until you close it or remove them
(`Remove-Item Env:\WINGET_APP_SETUP_TIGHTVNC_*`).

What the hook does, on every run that finds TightVNC installed:

- It limits `HKLM\SOFTWARE\TightVNC\Server` to SYSTEM and Administrators, with no permissions
  inherited from `HKLM\SOFTWARE`, before it writes a password there: the stored value is
  reversible, and standard users could otherwise read it.
- It writes `Password` and `ControlPassword` (8-byte `REG_BINARY` values in VNC's DES encoding) and
  sets `UseVncAuthentication` and `UseControlAuthentication` to 1, directly in the registry. It
  never passes the password to the MSI or `tvnserver.exe`, whose command lines winget and MSI logs
  record. Without `WINGET_APP_SETUP_TIGHTVNC_CONTROL_PASSWORD`, a separate control password the
  server already has is kept; otherwise the server password also protects the control interface,
  with a warning.
- It writes only the values that differ and then restarts the `tvnserver` service (or starts it
  when it was stopped), which must end up running. A run with the same password changes nothing;
  a run with a different one updates it. A run without a password keeps the passwords a configured
  server already has. The service reads its passwords only when it starts, so before it changes a
  value the hook also writes a `WingetAppSetupRestartPending` value into the key, and removes it
  once the service has restarted: when the restart fails, or the run stops before it, the retry
  pass or the next run restarts the service instead of reporting the server as configured.
- It also limits the key of a server it leaves not configured when the key already holds a
  password.
- VNC uses only the first 8 characters of a password: a longer one is used with a warning. A
  password with a character that is not printable ASCII is refused (`Not configured`, the value is
  not shown).
- A step that fails (the key cannot be locked, the values do not read back, the service does not
  start) makes TightVNC `Failed` (exit code 1, retried once).
- The installer never prints the password or its encoded bytes, never writes them to its
  transcript or `last-run.json`, and never puts them on a command line or passes them to a
  cmdlet: it writes the registry through the .NET API, so PowerShell module logging does not
  record them either. (Module logging does record the parameters of a module's own functions:
  when a script imports the `WingetAppSetup` module and calls `Invoke-WingetInstall` with module
  logging on for that module, the encoded bytes can reach the event log. The generated installer
  is not a module.) A dry run (`-WhatIf`) leaves the variables in place and says only whether each
  is set and whether a real run could use it (`[DRY-RUN] TightVNC: ... (value not shown)`).

VNC authentication is weak: 8 characters at most, DES, and no encryption of the session in
TightVNC 2.x. Use a different, unpredictable password per site or PC, keep port 5900 reachable only
from the helpdesk network (firewall scope or TightVNC's IP access control) or through a VPN, and
consider dropping TightVNC from the catalog once Endpoint Central's own remote control is rolled
out.

## Preview a run (`-WhatIf`)

```powershell
pwsh -ExecutionPolicy Unrestricted -File .\winget-app-install.ps1 -WhatIf
```

A dry run installs, repairs and sets up nothing, and does not ask for elevation. It runs the
checks a real run starts with (the **Environment checks** under [Unattended runs](#unattended-runs),
App Installer's Group Policy among them, and `winget --version`) and prints a `[DRY-RUN]`
line for each change a real run would make: setting up winget for the account (registering App
Installer, then `Repair-WinGetPackageManager`, after installing its `Microsoft.WinGet.Client`
module), updating the winget source, checking that winget can open it and repairing it if needed
(registering the winget source package for the account, or `winget source reset --force`, which
also removes any source added beyond the defaults),
relaunching elevated, and each app it would install. When the account has no winget yet, for
example an admin account used only to elevate, or winget is there but cannot be started, the
preview lists every app as one a real run would install, because it cannot check which are already
there. A dry run still writes its transcript (see [Logs](#logs)), and its `winget list` checks
update winget's own per-user cache and source-agreement state. Started elevated or as SYSTEM, it
also makes `%ProgramData%\winget-app-setup` and its `logs` folder safe before its transcript starts,
as a real run does: it removes a link planted in place of either folder, creates a missing one, and
locks both so that only SYSTEM and Administrators can change them.

## Unattended runs

The installer never asks a yes/no question on any path — the PowerShell 7 bootstrap and low disk
space proceed without prompting. One question is left: TightVNC's server password, asked at the
start of an interactive run when `WINGET_APP_SETUP_TIGHTVNC_PASSWORD` is not set and TightVNC
Server has no password yet (see [TightVNC server password](#tightvnc-server-password)); a
non-interactive run never asks it, and nobody typing for 5 minutes skips it. The one other prompt is Windows' own UAC prompt when the run is not
elevated (see [Administrator rights](#administrator-rights)), so an unattended run must already be
elevated or run as SYSTEM (see
[Running as SYSTEM](#running-as-system-rmm-tools-such-as-endpoint-central)): a non-interactive run
that is not elevated exits 4 without showing a prompt. A run as SYSTEM is always non-interactive.
Pass `-NonInteractive` for RMM, CI, or scheduled-task use to also suppress the interactive-only
extra: the "press any key to exit" that holds the window at the end of a run or after an early
failure (see [Logs](#logs)). The summary is a text table in the console and the log either way:

```powershell
pwsh -ExecutionPolicy Unrestricted -File .\winget-app-install.ps1 -NonInteractive
```

Non-interactive mode is also auto-detected when the session is non-interactive (services,
scheduled tasks) or stdin is redirected. PowerShell's own `-NonInteractive` switch is not detected:
`pwsh -NonInteractive -File .\winget-app-install.ps1` in a console is treated as interactive (only the
TightVNC prompt is skipped there), so pass the script's `-NonInteractive` as well. Under CI (the `CI`,
`GITHUB_ACTIONS` or `TF_BUILD` variable is set) an early failure never waits for a key press
either. In non-interactive mode winget also gets `--silent`, so MSI packages install with `/quiet`
instead of showing a progress window (`/passive`).

The `irm | iex` one-liner cannot pass `-NonInteractive`. To run it unattended, for example from an
RMM job or a wrapper script that runs it elevated with nobody at the console, set
`WINGET_APP_SETUP_NONINTERACTIVE` first. `1`, `true` or `yes` (any case) turn non-interactive mode
on; any other value leaves the decision to the auto-detection. The variable carries over into the
PowerShell 7 run that the Windows PowerShell 5.1 bootstrap starts. `winget-app-uninstall.ps1`
reads it too.

```powershell
$env:WINGET_APP_SETUP_NONINTERACTIVE = '1'; Set-ExecutionPolicy Unrestricted -Scope Process -Force; irm "https://raw.githubusercontent.com/J-MaFf/winget-app-setup/refs/heads/main/winget-app-install.ps1" | iex
```

No winget or `msiexec` call, and no other step in this table, can hang a run for good. Each has a
time limit, and when it runs out the installer stops that process and every process it started, then
carries on:

| Call | Time limit |
|------|------------|
| One `winget install` (download, installer, and waiting for another winget install) | 30 minutes |
| `winget download` (the PowerShell MSIX fallback) | 30 minutes |
| The per-app `winget list` check before and after each install | 15 seconds |
| The `winget --version` check that winget can be started | 30 seconds |
| `winget source update` | 2 minutes |
| The `winget search --source winget` check that winget can open its source | 2 minutes |
| `winget source reset` | 5 minutes |
| One `winget uninstall` (`winget-app-uninstall.ps1`), the app's own uninstaller included; for an app with `quietUninstall`, its own uninstaller and the wait for its uninstall entry to go | 15 minutes |
| One `Install-WinGetPackage` of the opt-in Microsoft.WinGet.Client engine (as SYSTEM, see [Microsoft.WinGet.Client engine (opt-in)](#microsoftwingetclient-engine-opt-in)), the installer included | 30 minutes |
| The engine's per-app `Get-WinGetPackage` check before and after each install | 45 seconds |
| The engine's check that it can be started (`Get-WinGetVersion`) | 60 seconds |
| The engine's probe at the start of the run (loading the module, `Get-WinGetVersion` and one `Get-WinGetPackage`) | 3 minutes |
| `msiexec` for Winget-AutoUpdate (install and uninstall) | 15 minutes |
| The Winget-AutoUpdate MSI download, the Windows App Runtime package download (see [Automatic updates](#automatic-updates)), and the engine's Microsoft.WinGet.Client package download | 5 minutes until the server starts sending the file; on PowerShell 7.4 and newer, also 2 minutes without data while it arrives |
| `Add-AppxProvisionedPackage` for the Windows App Runtime framework | 10 minutes |
| Reading which Windows App Runtime the latest winget release needs (`DesktopAppInstaller_Dependencies.json`) | 30 seconds, and on PowerShell 7.4 and newer also 30 seconds without data; when it runs out, the built-in requirement is used |

A stopped install is checked like any other: unless the app turns out to be installed anyway, it
fails, gets its one retry in the retry pass, and counts toward exit code 1, with
`winget install stopped after 30 minutes` (with the engine,
`the WinGet client install stopped after 30 minutes`) in its failure reason. The engine's checks
get longer limits than `winget.exe`'s because each one starts `pwsh` and loads the module. The
limits are set in one place,
`Get-ProcessTimeoutSeconds` (`WingetAppSetup/Private/ProcessInvocation.ps1`).

Some steps still have no time limit of their own: the PowerShell cmdlets that set up winget
(`Install-Module` for Microsoft.WinGet.Client, `Repair-WinGetPackageManager`, and
`Add-AppxPackage` registering App Installer); the `Add-AppxProvisionedPackage` of the PowerShell
MSIX fallback (PowerShell 7.7 and later, which ship no MSI, on Windows builds before 26100);
and, on PowerShell 7.3 and older, the Winget-AutoUpdate MSI and Windows App Runtime downloads
once the file has started to arrive. For a time limit on the whole run, see
[Time budget for RMM jobs](#time-budget-for-rmm-jobs--maxruntimeminutes).

**Environment checks.** Before it changes anything, the installer looks for what would make the run
fail whatever it did, and prints one line for each problem it finds. These checks only read, so
`-WhatIf` runs them too and says what a real run would do.

- **Constrained Language Mode**, which an App Control for Business (WDAC) or AppLocker policy sets
  for untrusted scripts, stops the run at once with exit code 5. The run prints one line and its
  `RESULT` line, and writes no log. In an interactive `irm | iex` console the window stays open and
  `$LASTEXITCODE` is 5.
- **Group Policy's execution policy.** Group Policy can set PowerShell's execution policy
  (`Turn on Script Execution`) to `AllSigned` or `Restricted`, and `-ExecutionPolicy Bypass`, which
  the installer relaunches itself with, does not override that. So the Windows PowerShell 5.1
  bootstrap stops with exit code 7, before it installs PowerShell 7, when PowerShell 7's policy
  refuses scripts (`PowerShell Core` > `Turn on Script Execution`, or its setting to use the Windows
  PowerShell policy). A run that is not elevated stops with exit code 4, without a UAC prompt, when
  the PC's Windows PowerShell policy refuses them (see [Administrator rights](#administrator-rights)).
  As in PowerShell itself, a Group Policy execution policy does not count for a run that a Group
  Policy startup or logon script (`gpscript.exe`) started.
- **Proxy.** Once elevated, or as SYSTEM, the run warns when the signed-in user has a proxy in
  their Windows Internet settings that the account it runs as does not have, and shows both
  settings: on a network that only lets traffic out through that proxy, downloads fail. The WinHTTP
  proxy and a per-machine proxy policy apply to every account, so they are not reported. A failed
  network check of a run as SYSTEM or as another admin account names that proxy too.
- **Pending restart.** A restart Windows already wants is reported (see **Restart required**
  below).
- **App Installer's Group Policy** turning winget off stops the run with exit code 2, before it
  waits for Winget-AutoUpdate or sets winget up (see step 1 below).

**Setting winget up.** Before the installs, one step (`Initialize-Winget`) checks winget, works out
what is wrong from exit codes and HRESULTs, applies the fix for that, and runs each fix at most once
a run. When something cannot be fixed it prints one line that says why and what to do.

1. **Group Policy.** When App Installer's policy turns winget or its source off (`Enable App
   Installer`, `Enable Windows Package Manager command line interfaces` or `Enable App Installer
   Default Source` set to Disabled, under
   `HKLM\SOFTWARE\Policies\Microsoft\Windows\AppInstaller`), or winget answers
   `0x8A15003A BLOCKED_BY_POLICY`, no repair can help: the run stops with exit code 2 and names
   the policy, before any repair, source reset or Winget-AutoUpdate install. The environment checks
   above find the policy values first and stop the run there; this step still recognizes winget's
   own `0x8A15003A`, and it is the check the uninstaller relies on.
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
3. **The winget source.** `winget source update --name winget`, then
   `winget search --exact --id Microsoft.PowerShell --source winget`, which opens the source the
   way every install does. The search decides: `winget source update` exits 0 even when its update
   fails (it prints `Cancelled`), so on its own it proves nothing. winget deploys its source as an
   app package (`Microsoft.Winget.Source`) for each account, and when Windows refuses that
   deployment, as it does for an admin account elevated in another user's session, every install
   fails with `0x8A15000F` (`SOURCE_DATA_MISSING`). For that code the installer registers the
   source package for the account itself (not as SYSTEM, whose `winget.exe` keeps its source in a
   file): a fresh download of `https://cdn.winget.microsoft.com/cache/source2.msix` (then
   `source.msix`), saved in a folder only administrators can change and installed only with a valid
   Microsoft signature, or, only when that fails, the copy another account already has on the PC,
   which is usually older. Then, if
   `Microsoft.WinGet.Client` 1.28.190 or later is installed, `Repair-WinGetPackageManager`, which
   checks the source package too. `winget source reset --force` deploys no package, so it is used
   only for a corrupted or unconfigured source (`0x8A15000B`, `0x8A150012`, `0x8A150015`,
   `0x8A15003F`). `0x80073D19` (the account has no logon session) gets the account fixes that have
   not run yet. When the source still answers one of those codes, the run stops with exit code 2
   before it installs anything or sets up Winget-AutoUpdate, and one line names the account, the
   code, winget's log folder and what to do: under cross-user elevation, run the installer while
   signed in to Windows as that account (winget deploys its source package only in the account's
   own session, so signing in once is not enough) or run the machine phase as SYSTEM with
   `rmm/Invoke-WingetAppSetup.ps1`; otherwise check the
   `Microsoft-Windows-AppXDeploymentServer/Operational` event log and access to
   `cdn.winget.microsoft.com`. The uninstaller gives the same advice for itself: run it while
   signed in as that account, or run `winget-app-uninstall.ps1` as SYSTEM. When the run did
   register the source package for the account and `0x8A15000F` stays, the line says the
   registration succeeded, and how (the download, or the copy already on the PC), and points to
   winget's log and access to `cdn.winget.microsoft.com` instead of the AppX event log: Windows
   deployed the package, so that log has nothing to add. Under cross-user elevation it then adds
   the advice above (signed in as that account, or as SYSTEM) in case that does not help. A timeout, a network
   error or any other code gets no fix: no repair fixes a network. While the source already has
   data, such a source is reported in one line and the run carries on; each install then says why
   it failed. An account (or SYSTEM) with no source data yet that cannot download it gets
   `0x8A15000F` instead, and stops with exit code 2 as above.

A run as SYSTEM checks the machine-wide `winget.exe` instead of step 2's account fixes, which cannot
work for SYSTEM (see [Running as SYSTEM](#running-as-system-rmm-tools-such-as-endpoint-central)).
When a run as SYSTEM installs with the opt-in Microsoft.WinGet.Client engine, step 3 is skipped,
and a `winget.exe` that does not start is a warning instead of exit code 2 (see
[Microsoft.WinGet.Client engine (opt-in)](#microsoftwingetclient-engine-opt-in)). The checks below
then run against the engine (`Get-WinGetPackage`, `Get-WinGetVersion`), with the same tries; the
end of the next paragraph says what differs.

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
gets its retry. The check names the source (`winget list --exact --id <id> --source winget`): without
it, a winget source that cannot be opened is only a warning, and the list exits `0x8A150014` as if
the app were not installed; with it, the list fails with the source's own code, such as
`0x8A15000F`. With the Microsoft.WinGet.Client engine the reasons name it instead:
`the WinGet client engine could not be started ...`,
`not attempted: the WinGet client engine cannot be started on this machine (see above)` and
`Get-WinGetPackage failed during the pre-install check with exit 0x...`. Its launch checks
(`Get-WinGetVersion`) have a 60-second limit, so a run whose checks all hang ends about 3 minutes
later than with `winget.exe` (about 9 minutes), and a module that cannot load, a `pwsh` that
cannot start for a reason that does not clear on its own, or Group Policy (`0x8A15003A`) stops
the checks at once.

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

### Time budget for RMM jobs (`-MaxRuntimeMinutes`)

An RMM tool that stops a script after a fixed time would otherwise kill a long first run partway
through. `-MaxRuntimeMinutes <minutes>` (1 to 1440) gives the whole run a budget instead:

```powershell
pwsh -ExecutionPolicy Unrestricted -File .\winget-app-install.ps1 -NonInteractive -MaxRuntimeMinutes 60
```

The `irm | iex` one-liner cannot pass a parameter, so it reads
`WINGET_APP_SETUP_MAX_RUNTIME_MINUTES` (a whole number from 0 to 1440; unset, empty or 0 means no
budget, and anything else is ignored with a warning). A value given on the parameter wins over the
variable: `-MaxRuntimeMinutes 0` turns off a budget the variable sets. The Endpoint Central machine
phase takes `-MaxRuntimeMinutes` too (see [Machine phase](#machine-phase)).

The clock starts when the script starts, before the Windows PowerShell 5.1 hand-off to PowerShell
7, and the deadline travels on the command line to the PowerShell 7 run and to an elevated window
(`-RunDeadlineUtc`, internal). The run prints `Time budget: <n> minutes, until <time>` near its
start. The deadline is a clock time (UTC), so a correction of the PC's clock during the run moves
it.

Once the budget is used up, the run starts no further app install, retry or Winget-AutoUpdate setup
(the Windows App Runtime install included). Apps that do not apply are still skipped, and per-user
apps in a run for the whole PC are still deferred, since neither needs winget. Every other app left
is reported `Not attempted` (a summary row, `NotAttempted` in `last-run.json`, `notattempted=` in
the `RESULT` line), and the Winget-AutoUpdate setup as `Auto-updates: NOT ATTEMPTED`. A retry that
is not started leaves its app failed. The run ends with a `Time budget: USED UP` line and exit code
9, unless an app failed (1) or winget no longer works (2). Run it again to finish.

The budget does not stop a step that is already running. An app install ends within its own time
limits (see the table under [Unattended runs](#unattended-runs): 30 minutes for one
`winget install`), and waits for a busy Windows Installer no longer than the budget had left when
the install started. A Winget-AutoUpdate setup that started just before the deadline can take about
as long, and the end-of-run winget check then takes up to about 4 minutes. So set the budget about
45 minutes below the RMM tool's limit. That covers one `winget install` still running at the
deadline and the end-of-run check. It does not cover an app the installer runs `winget install` for
again within its install (after an in-use error, a busy Windows Installer or a logged-off session,
for example): each of those runs has its own 30-minute limit, so such an app can run more than 30
minutes past the deadline. A run that is killed anyway leaves `last-run.json` with `exitCode`
`null` (see [Run result](#run-result)). A dry run shows the budget but is not cut short.

### Running as SYSTEM (RMM tools such as Endpoint Central)

A run as SYSTEM, which is how an RMM agent such as ManageEngine Endpoint Central runs a computer
script, is supported for the apps that install for the whole PC. Microsoft does not support the
winget command line as SYSTEM: winget is a per-user packaged app that cannot be registered for
SYSTEM ([WinGet troubleshooting, System
Context](https://learn.microsoft.com/windows/package-manager/winget/troubleshooting#system-context)),
and Microsoft's supported route there is the `Microsoft.WinGet.Client` PowerShell module on
PowerShell 7. By default this installer still runs the winget command line as SYSTEM. The module is
an opt-in (see [Microsoft.WinGet.Client engine (opt-in)](#microsoftwingetclient-engine-opt-in)
below). So a SYSTEM run can fail where a run as a signed-in user would not; test it on a pilot PC
before rolling it out. What a SYSTEM run does differently:

- It is never interactive: no "press any key", and winget installs with `--silent`.
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
  the same way until the runtime is installed. With the opt-in module engine ready, a `winget.exe`
  that does not start is only a warning (see below).
- It skips every step that sets winget up for one account, since SYSTEM cannot have one:
  registering App Installer and `Repair-WinGetPackageManager` (so `Install-Module` never installs
  the `Microsoft.WinGet.Client` module it comes from), and registering the winget source package.
  Unless the module engine installs the apps, it still updates the winget source and checks that it
  opens (`winget search --source winget`), and resets it only when it is corrupted or unconfigured.
  Missing source data (`0x8A15000F`) gets no fix as SYSTEM: a source that still cannot be opened
  stops the run with exit code 2 before any install (check that the PC can reach
  `cdn.winget.microsoft.com`).
- Every app is installed with `--scope machine` only (`-Scope System` with the module engine). An
  app that has no machine-wide installer is
  not installed at winget's default scope, which as SYSTEM is SYSTEM's own profile: it is reported
  as `Deferred` in the summary. So is every app the catalog marks per-user (`scope = 'user'` or
  `userPhase = $true`, see [Catalog entry fields](#catalog-entry-fields)), before any winget call,
  with its own line saying so; an app marked `scope = 'machine'` that has no machine-wide installer
  fails instead, without a retry. A deferred app counts neither as installed nor as failed and does
  not change the exit code. A per-user app can only be installed in the signed-in user's own
  account: by this installer run as that user when the account is an administrator, otherwise by a
  per-user deployment, such as the user phase (`rmm/Invoke-WingetAppSetupUserPhase.ps1`, see
  [Endpoint Central and other RMM tools](#endpoint-central-and-other-rmm-tools)) or the Microsoft
  Store (on a standard user's PC, the UAC prompt elevates as an administrator account,
  which defers the app again). winget answers `--scope machine` with the same
  `0x8A150010 NO_APPLICABLE_INSTALLER` when no installer applies to the PC at all, so a deferred app
  can also be one winget cannot install on this PC at any scope.
- Windows Terminal is decided from the PC: when its package is provisioned for every user, as
  Windows 11 does, it is `Skipped (already provisioned for every user on this PC)`. `winget list`
  run as SYSTEM does not see the MSIX apps registered for the users, so Terminal would read as
  missing on every run, and its install would then fail the same check. The check for a
  Terminal-hosted console (#271) does not apply to SYSTEM, and the Windows Terminal defaults step
  is skipped (see [Windows Terminal defaults](#windows-terminal-defaults)).
- Its messages are written for SYSTEM: no "cross-user elevation" banner and no advice to sign in
  to Windows as `NT AUTHORITY\SYSTEM`.
- It does not use the signed-in user's own proxy settings. When that user has a proxy server or an
  automatic configuration script that SYSTEM lacks, the run says so at its start (see
  **Environment checks** above), because downloads fail on a network that only lets traffic out
  through that proxy.
- TightVNC gets its password only from `WINGET_APP_SETUP_TIGHTVNC_PASSWORD` (set it in the RMM
  script; see [TightVNC password from Endpoint Central](#tightvnc-password-from-endpoint-central)
  and [TightVNC server password](#tightvnc-server-password)). Without it TightVNC is
  installed but not configured, and the run still exits 0: look for
  `Configuration: NOT DONE for GlavSoft.TightVNC` in the output, or `"postInstall": "NotConfigured"`
  in `last-run.json`.
- Started from Windows PowerShell 5.1 on a PC without PowerShell 7, it installs PowerShell 7 from
  the MSI download, not with winget, since SYSTEM has no `winget` command; the bootstrap says so
  instead of saying winget is missing. The MSI path reads its release list from GitHub, which can
  answer `429 Too Many Requests` when many PCs on one network ask at once (exit code 7).

A run elevated as a different account than the signed-in user (cross-user elevation) installs for
the whole PC the same way: an app with no machine-wide installer is `Deferred` instead of being
installed into the admin account's profile and reported as installed, and Windows Terminal is
decided from provisioning, not from the admin's `winget list`. That run still sets winget up for
the admin account as before, and says so when it does (`Cross-user elevation detected: ...`).

The signed-in user is the user signed in to the elevated window's own Windows session, at the
console or over Remote Desktop: the owner of the oldest `explorer.exe` in that session, the shell
Windows started at sign-in. Only when no such owner can be read (session 0, no shell, or a query
that failed) is it the console's user from `Win32_ComputerSystem`, which is empty over Remote
Desktop.

Only one run works on a PC at a time: a run started while another one is in progress exits 6 at
once (see [One run at a time](#one-run-at-a-time)). A real run prints a machine-readable `RESULT`
line, and the run that did the work also writes `last-run.json` (see [Run result](#run-result)).

Each deferred app's entry in `last-run.json` says why it was deferred (`winget found no
machine-wide installer for it`, catalog scope `user`, or catalog `userPhase`). For Endpoint Central,
use the scripts in `rmm/`: a machine phase that runs this installer as SYSTEM, and a user phase
that installs the deferred apps for each user at sign-in (see the next section). RMM tools read
success from the exit code: list any other code you accept, such as 3010, as a success code for the
script. Exit code 8 means the apps are installed but automatic updates are not set up or will not
run; decide whether your RMM job should count it as a success. Exit code 9 means the run's
[time budget](#time-budget-for-rmm-jobs--maxruntimeminutes) ran out before every app, or the
Winget-AutoUpdate setup, was attempted. It is not a success: run the job again to finish.

#### Microsoft.WinGet.Client engine (opt-in)

A run as SYSTEM can install the apps with the `Microsoft.WinGet.Client` PowerShell module instead
of `winget.exe`. Microsoft documents the winget command line as unsupported in the system context,
and this module as the supported route there
([WinGet troubleshooting, System Context](https://learn.microsoft.com/windows/package-manager/winget/troubleshooting#system-context)).
The engine is opt-in and for runs as SYSTEM only. When the module is not ready, the run falls back
to `winget.exe`. The default stays `winget.exe`.

To opt in, set `WINGET_APP_SETUP_SYSTEM_ENGINE` to `WinGetClient` in the run's environment, or give
the Endpoint Central machine phase `-SystemInstallEngine WinGetClient` (see
[Machine phase](#machine-phase)). `Cli`, unset or empty keeps `winget.exe`. Any other value is
warned about and means `Cli`. A run that is not SYSTEM ignores the variable and says so. A dry run
(`-WhatIf`) downloads nothing and says what a real run would do.

- **What it needs.** PowerShell 7.4 or later, as an x64, x86 or Arm64 process, and Windows build
  17763 or later. A PC that already has an older PowerShell 7 falls back; the bootstrap installs
  the latest PowerShell 7 only on a PC that has none. The PC must reach the PowerShell Gallery:
  allow `www.powershellgallery.com` and `cdn.powershellgallery.com` on port 443. SYSTEM does not
  use the signed-in user's proxy settings (see **Environment checks** under
  [Unattended runs](#unattended-runs)). After the first download, later runs use the cache. The
  module's native engine imports no Visual C++ runtime DLL, only the Universal C Runtime that
  Windows includes.
- **Where the module comes from.** The installer downloads Microsoft.WinGet.Client 1.29.380 as its
  `.nupkg` straight from the PowerShell Gallery. It never uses `Install-Module` and installs nothing
  into PowerShell's module folders. It checks the package's size and SHA256 against the pin in
  `Get-WingetClientModulePin` (`WingetAppSetup/Private/WingetClientModule.ps1`), extracts only the
  PowerShell 7 build and this process's engine, and requires a valid Microsoft Corporation
  signature on the module's manifest, its cmdlet and engine DLLs and the native engine files. It
  extracts into a new `%ProgramData%\winget-app-setup\wingetclient-<id>` folder that only SYSTEM
  and Administrators can change, and removes that folder when the run ends. A folder a killed run
  left behind is removed by a later run once it is a day old, and only while
  `%ProgramData%\winget-app-setup` is locked to SYSTEM and Administrators. The checked package is
  kept in `%ProgramData%\winget-app-setup\cache` and checked again on every use. A link found where
  the cache folder should be is removed, never followed, and the folder is created again (see
  [Administrator rights](#administrator-rights)). A new download is written there under a new,
  random name, created only when nothing has that name yet, and then moved over the cached
  package, so a file another account left in the folder is never opened for writing. When these
  folders cannot be set up, the module is `NOT READY` and the reason says why: for a folder whose
  access list cannot be set, it gives the `ren` command described under
  [Automatic updates](#automatic-updates).
- **How it installs.** Each module call runs in its own `pwsh` under a time limit (see the table
  under [Unattended runs](#unattended-runs)), so a hung call is stopped together with what it
  started. Before any app, a probe (`Get-WinGetVersion` and one `Get-WinGetPackage`) must answer.
  Each app is checked with `Get-WinGetPackage`, as before, then installed with
  `Install-WinGetPackage -Id <id> -Source winget -MatchOption Equals -Scope System -Mode Silent`.
  Its installer log goes to the logs folder under the usual `winget-install-<id>-<time>.log` name.
  The transcript shows each call as a `> Install-WinGetPackage ...` line, the child `pwsh`'s own
  short output, and its outcome as a `WinGet client result: ...` line (see [Logs](#logs)). Results
  map onto winget's own result codes, so deferral, retries, the circuit breaker, restarts and
  failure reasons work as with `winget.exe`. The module prints no restart message, so a restart
  after a successful install is recognised from the installer's exit code 3010 (the MSI, WiX and
  Burn default). The module does not expose a manifest's other restart codes, so only the
  pending-restart check notices those.
- **What it reports.** Near its start the run prints
  `WinGet client module: ready - Microsoft.WinGet.Client 1.29.380, SHA256 <hash>, ...` (downloaded
  or from the cache) and an `Install engine:` line. A run as SYSTEM prints that line once
  `winget.exe` or the module is ready, with or without the opt-in: it names the engine, the folder
  of the engine's own logs (`WinGetCOM-*.log`, in `WinGet\defaultState` under
  `%SystemRoot%\SystemTemp` or the run's temp folder) and, after a fallback, why. A run that stops
  with exit code 2 before that (no `winget.exe` that starts and no ready module, or Group Policy
  turns winget off) prints none, and a dry run that asked for the module prints its `[DRY-RUN]`
  line instead.
  `last-run.json` records `installEngine` and, for each app, the installer's own exit code as
  `installerCode` (see [Run result](#run-result)).
- **When it is not ready.** The run prints `WinGet client module: NOT READY - <reason>.` and installs
  every app with the machine-wide `winget.exe`, as it would without the variable. The
  `Install engine:` line, a warning next to the summary and `installEngine.fallbackReason` in
  `last-run.json` say why. A fallback does not change the exit code. Typical reasons: the Gallery
  cannot be reached, a size, hash or signature does not match, PowerShell is older than 7.4, or the
  probe failed. The engine is decided once, at the start: one that stops working partway through
  trips the circuit breaker, as `winget.exe` does.
- **What still uses `winget.exe`.** Only the app installs and their checks move to the module.
  Winget-AutoUpdate runs `winget.exe` for every update, so its setup is unchanged and the
  end-of-run check still checks the machine-wide `winget.exe` (exit code 2 when it does not start).
  At the start of a run with the module ready, a `winget.exe` that does not start is only a
  warning: the apps install, and the warning says automatic updates will not work until App
  Installer is repaired. The Windows App Runtime install is unchanged: it calls no winget, and is
  there for `winget.exe` and Winget-AutoUpdate. The winget source update and reset are skipped,
  since the module cannot manage sources as SYSTEM. The uninstaller, and the `winget download` path
  of `Install-PowerShellLatest` (PowerShell 7.7 and later on Windows builds before 26100), use
  `winget.exe` as before; PowerShell's MSI install goes through the module like any other app.
- **Moving the pin.** On a Windows PC, run
  `pwsh -File build/Set-WingetClientModulePin.ps1 -Version <version>`. It downloads the Gallery
  package twice (and once more with `Save-PSResource` where that exists), checks it against the
  Gallery's own hash, lists every file with its SHA256 and signature, and prints the new `Size`
  and `Sha256`. Add `-Write` to write them into `Get-WingetClientModulePin`. When the package's
  layout changed, it fails and says so; then update the pin's `Framework` and `SignedFiles` by
  hand. Its report also compares each `WindowsPackageManager.dll` with nuget.org's
  `Microsoft.WindowsPackageManager.InProcCom` 1.29.380 build, whose hashes the script keeps. That
  comparison never fails it, and for another version it reports a difference until those hashes
  are updated. Then rebuild the installer (`build/Build-WingetInstallScript.ps1`) and let the
  `e2e-install-system-winget-client` job pass (see
  [End-to-end monitoring](#end-to-end-monitoring-e2e-tier-1)) before you move the Endpoint Central
  pin. `-Check` exits 1 when the Gallery's package no longer matches the pin.

What has been checked so far: a probe on a GitHub-hosted Windows Server 2025 runner (2026-10-06)
loaded the pinned module as SYSTEM under PowerShell 7.6, found each file the pin requires to be
signed valid from Microsoft Corporation, listed installed packages with `Get-WinGetPackage`, and
installed a package with `Install-WinGetPackage -Scope System`. The
`e2e-install-system-winget-client` job passed on its first run (2026-10-06): as SYSTEM the module
was downloaded and verified at its pin, every app that applies was installed through
`Install-WinGetPackage`, and the second pass took the module from the cache and found every app
there. No real PC has used the engine yet. Try it on a pilot PC first.

### Endpoint Central and other RMM tools

`rmm/` holds four scripts for ManageEngine Endpoint Central. Each is one file that needs nothing
beside it and runs in Windows PowerShell 5.1, so you upload it to Endpoint Central's Script
Repository as it is. Any RMM that can run a PowerShell script as SYSTEM (and, for the user phase,
as the signed-in user) can use them the same way.

| Script | Runs as | What it does |
|--------|---------|--------------|
| `rmm/Invoke-WingetAppSetup.ps1` (machine phase) | SYSTEM, once per PC | Runs this installer for the whole PC, from a pinned commit |
| `rmm/Invoke-WingetAppSetupUserPhase.ps1` (user phase) | The signed-in user, at every sign-in, never elevated | Installs the apps the machine phase deferred, and sets the user's Windows Terminal defaults |
| `rmm/Get-WingetFleetHealth.ps1` (health probe) | SYSTEM | Checks whether winget and Winget-AutoUpdate work, and changes nothing |
| `rmm/Repair-WauLogonTrigger.ps1` (at-logon fix) | SYSTEM | Removes Winget-AutoUpdate's at-logon trigger from PCs set up by older versions |

Endpoint Central's agent is 32-bit, and a 32-bit process sees a 32-bit System32, Program Files and
registry. So the machine phase, the probe and the fix run themselves again in 64-bit Windows
PowerShell (`%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe`) when a 32-bit
PowerShell starts them. The probe and the fix do the same when PowerShell 7 starts them. The user
phase needs no relaunch: it reads only files a 32-bit process sees as they are, and it runs the
64-bit PowerShell 7.

The machine phase runs this installer as SYSTEM, so the caveat above applies: Microsoft does not
support the winget command line as SYSTEM. `-SystemInstallEngine WinGetClient` moves the app
installs to the supported `Microsoft.WinGet.Client` module (see
[Microsoft.WinGet.Client engine (opt-in)](#microsoftwingetclient-engine-opt-in)). None of this has
run from Endpoint Central on a real PC yet. What this section says about Endpoint Central (its
32-bit agent, output in the Remarks only for frequency Once, User Configuration scripts running as
the signed-in user) comes from search results quoting its documentation, not from a test, and its
own time limit for a script has not been measured: check that it covers a first run, which
installs every app, or give the machine phase a time budget below it (`-MaxRuntimeMinutes`, see
[Setting it up](#setting-it-up)). Check all of it on a pilot PC first. The E2E run's SYSTEM legs
run the machine phase the way the 32-bit agent would (see
[End-to-end monitoring](#end-to-end-monitoring-e2e-tier-1)).

#### Setting it up

1. **Pin the installer.** The machine phase and the user phase download `winget-app-install.ps1`
   from one pinned commit
   (`https://raw.githubusercontent.com/J-MaFf/winget-app-setup/<commit>/winget-app-install.ps1`),
   never from `main`, and run it only when its SHA256 matches the pinned one. A change on `main`
   reaches the PCs only when you move the pin. Both scripts ship with empty pins
   (`$PinnedInstallerCommit` and `$PinnedInstallerSha256`), because no commit on `main` had this
   code when they were written, and they exit 5 without running anything until the pins are set.
   Once the change has merged to `main` and its E2E run has passed, run:

   ```powershell
   pwsh -File build/Set-RmmInstallerPin.ps1 -Commit <commit on main>
   ```

   It reads `winget-app-install.ps1` from that commit with git, hashes it, and writes both pins
   into both scripts. It writes nothing when either script does not have exactly one of each pin
   line, or when the file has no `Invoke-WingetUserPhase` (a commit older than the user phase,
   which would fail at every sign-in). It warns about a commit that is not on `origin/main`. Commit
   the two scripts. To roll back, pin an older commit that has the user phase.
2. **Script Repository** (Configurations > Settings > Script Repository): add the scripts you use.
   Upload the two phases again after every pin change.
3. **Machine phase:** Computer Configuration > Custom Script. Run As: System user. Script:
   `Invoke-WingetAppSetup.ps1`, no arguments needed. Success exit codes: `0,3010`. Frequency: Once,
   with **Enable logging for troubleshooting**, so the script's output shows in the configuration's
   Remarks. A PC that runs it before its network is up fails the download with exit code 5: deploy
   it again to those PCs. To finish within Endpoint Central's script time limit (not measured yet),
   add `-MaxRuntimeMinutes <n>` to the script's arguments, with n about 45 minutes below that limit
   (see [Time budget for RMM jobs](#time-budget-for-rmm-jobs--maxruntimeminutes)). The machine
   phase starts the clock as soon as it starts, before its 64-bit relaunch and the download, and a
   run whose budget runs out exits 9 with the rest not attempted. To install with the
   `Microsoft.WinGet.Client` module instead of `winget.exe`, add `-SystemInstallEngine WinGetClient`
   to the arguments (see
   [Microsoft.WinGet.Client engine (opt-in)](#microsoftwingetclient-engine-opt-in)).

   Exit codes 8 and 9 are left out of the success codes on purpose. Exit code 8 means the apps are
   installed but automatic updates are not set up or will not run (for example, the Windows App
   Runtime that winget needs could not be installed), and such a PC needs a look. Shown as failed,
   those PCs stand out. Add 8 to the success codes if that is too noisy for you. Exit code 9 means
   the time budget ran out before every app, or the Winget-AutoUpdate setup, was attempted. Shown
   as failed, those PCs stand out too: deploy the configuration to them again, and that run
   continues where this one stopped.
4. **User phase:** User Configuration > Custom Script, run as the signed-in user. Script:
   `Invoke-WingetAppSetupUserPhase.ps1`. Success exit codes: `0,3010`. Frequency: Every Logon. A
   user who was signed in when the machine phase ran gets it at their next sign-in.
5. **Health probe and at-logon fix** (optional): Computer Configuration > Custom Script. Run As:
   System user. Success exit code: `0`, so the failed PCs are the unhealthy ones, or the ones the
   fix could not fix. Frequency: Once, with **Enable logging for troubleshooting**, so the `HEALTH`
   or `REPAIR` line shows in the Remarks. Deploy the probe again to check again later. Neither
   needs arguments; see below for the optional ones.

#### Machine phase

`rmm/Invoke-WingetAppSetup.ps1`:

1. relaunches itself in 64-bit Windows PowerShell when a 32-bit PowerShell started it (with
   `-MaxRuntimeMinutes`, it first sets the budget's deadline and passes it on, so the relaunch
   counts too);
2. logs everything it does, the installer's console output included, to
   `%ProgramData%\winget-app-setup\logs\install-<yyyyMMdd-HHmmss>-rmm.log`, next to the
   installer's own logs. It writes there as SYSTEM before the installer runs (see
   [Administrator rights](#administrator-rights)), so it first removes a junction or symbolic
   link in place of `%ProgramData%\winget-app-setup` or its `logs` folder, creates a missing one
   with its access list already set, and logs only when both are real folders that no account
   other than SYSTEM and Administrators can change. Otherwise it says why and runs without its own
   log; the installer then locks the folders, so the next run logs;
3. downloads the pinned `winget-app-install.ps1` into a new folder under `%SystemRoot%\Temp` that
   only SYSTEM and Administrators can change, and checks its SHA256 before any of it runs;
4. runs it with `-NonInteractive` in Windows PowerShell, which finds or installs PowerShell 7 and
   relaunches under it. With `-MaxRuntimeMinutes`, it also passes the budget and the deadline
   counted from the machine phase's own start. Without it (0, the default), it passes no budget,
   and the installer reads `WINGET_APP_SETUP_MAX_RUNTIME_MINUTES` if the job sets it. Use
   `-MaxRuntimeMinutes` only with a pinned installer that has it. With `-SystemInstallEngine
   WinGetClient` (or `Cli`), it sets `WINGET_APP_SETUP_SYSTEM_ENGINE` for the installer only, logs
   `Install engine requested: <engine>`, and restores the job's own value afterwards (see
   [Microsoft.WinGet.Client engine (opt-in)](#microsoftwingetclient-engine-opt-in)). Without it,
   the installer uses `winget.exe` unless the job sets that variable itself. It takes effect only
   with an installer pin from a commit that has the engine; an older pinned installer ignores the
   variable. Allow `www.powershellgallery.com` and `cdn.powershellgallery.com` on port 443 for
   those PCs;
5. exits with the installer's exit code, unchanged (see [Exit codes](#exit-codes)). It exits 5
   without running the installer when the pins are not set, the download failed, the SHA256 does
   not match, or the 64-bit relaunch could not start.

As SYSTEM the installer is non-interactive, elevated, and installs for the whole PC only (see
[Running as SYSTEM](#running-as-system-rmm-tools-such-as-endpoint-central)). So the machine phase
needs no other switch. It passes `-NonInteractive` for an RMM that runs it as an administrator
account instead of SYSTEM. The apps the run defers and the per-user Windows Terminal defaults are
left to the user phase.

#### User phase

`rmm/Invoke-WingetAppSetupUserPhase.ps1` does the per-user work of a machine run, once per machine
run for each user. It keeps track in `%LOCALAPPDATA%\winget-app-setup\user-phase.json`, keyed to
that run's `last-run.json`.

- It decides from `last-run.json` and that file, before it downloads anything, whether there is
  work. There is none when there is no record, the machine run has not finished, or this account
  has already finished that run or tried it 3 times. Most sign-ins end there in under a second,
  exit 0 and print nothing. Run as SYSTEM, it does nothing.
- It uses `last-run.json` only when SYSTEM or Administrators own it and no other account can change
  it (write or append to it, delete it, change its permissions or take ownership). It checks this
  from the file's own access list while it holds the file open. The machine phase's record always
  passes. Any other record is ignored with one line and the user phase does nothing, because the
  apps it lists are installed in every account that signs in. A standard user who controls the
  logs folder can still delete the record, which stops the user phase until the next machine run,
  but cannot make it install other apps.
- When there is work, it finds PowerShell 7 (the machine phase installs it), downloads the pinned
  installer into the user's `%TEMP%`, checks its SHA256, and runs the installer's
  `Invoke-WingetUserPhase` under PowerShell 7.
- It checks that winget starts for this account (Windows sets winget up for an account shortly
  after its first sign-in), then updates the winget source for it
  (`winget source update --name winget`, with a 2-minute limit). At an account's first sign-in
  this also registers the source. A source that cannot be updated is reported in one line, and the
  installs go ahead. It runs no `winget source reset`, which needs administrator rights.
- It installs each deferred app with `--scope user` only, checked with `winget list` before and
  after. It never tries another scope, so it never picks a machine-wide installer that would ask
  for administrator rights. A per-user installer that elevates itself would still show a UAC
  prompt, so check each app the user phase installs once on a pilot PC. When the app's catalog
  entry has an `installerType`, it is used, and a `postInstall` hook runs in the user's account
  once the app is there.
- It sets the user's Windows Terminal defaults (see
  [Windows Terminal defaults](#windows-terminal-defaults)). Windows Terminal creates its
  `settings.json` the first time it is opened, so until then the default profile waits for a later
  sign-in.
- Its installs share a 15-minute budget (`-MaxMinutes`), and its PowerShell 7 run is stopped 5
  minutes after that.
- It tries again at a later sign-in when an app failed or was not reached, winget could not be
  started yet, a hook could not configure its app yet, or the Windows Terminal step did not finish:
  up to 3 sign-ins per machine run (`-MaxAttempts`). It counts an attempt before it starts work, so
  an attempt that is killed still counts.
- It logs to `%LOCALAPPDATA%\winget-app-setup\logs\install-<yyyyMMdd-HHmmss>-userphase.log` (the
  newest 10 are kept), with winget's per-app logs next to it, and ends with one
  `USER PHASE RESULT:` line.

The user phase exits with:

- 0: done, or nothing to do;
- 1: a deferred app failed, its post-install hook failed, or it was not reached within the time
  budget;
- 2: winget cannot be started for this account yet;
- 3010: done, and an install needs a restart to finish;
- 5: the installer could not be run (pins not set, download failed, SHA256 mismatch, or a pinned
  commit older than the user phase), the run did not end in time, or an unexpected error;
- 7: PowerShell 7 is not installed.

#### TightVNC password from Endpoint Central

The machine phase starts the installer as its own child process, so the installer gets the
[TightVNC variables](#tightvnc-server-password) that the machine phase sets. Endpoint Central runs
the file you uploaded as it is, so set them in your uploaded copy of `rmm/Invoke-WingetAppSetup.ps1`,
right after its pin block:

```powershell
$env:WINGET_APP_SETUP_TIGHTVNC_PASSWORD = '<server password, up to 8 characters>'
$env:WINGET_APP_SETUP_TIGHTVNC_CONTROL_PASSWORD = '<a different control password>'
```

- Never commit that copy: this repository is public. Add the lines again to each copy with new
  pins that you upload.
- Everyone who can read the script in the Endpoint Central console can read the password, and
  Script Block Logging records it too (see [TightVNC server password](#tightvnc-server-password)).
  Limit who can see the script.
- Do not pass the password as a script argument: arguments are on the process command line, which
  process auditing records.
- The user phase does not need it: TightVNC installs for the whole PC, and the machine phase
  configures it as SYSTEM.
- Without the password, TightVNC is installed but not configured, and the machine phase still exits
  0. Look for `"postInstall": "NotConfigured"` in `last-run.json`, or for the
  `Configuration: NOT DONE for GlavSoft.TightVNC` line in the `-rmm.log`.

This has not been tried on a real PC yet, and the E2E run sets no TightVNC password.

#### Fleet health probe

`rmm/Get-WingetFleetHealth.ps1` reports whether winget and Winget-AutoUpdate (WAU) work on a PC, and
changes nothing. A PC whose winget WAU has broken looks fine everywhere else: WAU logs
`No update found` and its task reports success, until the next installer run fails every app. The
probe finds such PCs first. It writes one line per check:

- each App Installer (`Microsoft.DesktopAppInstaller`) version, its status, and each account's
  install state (`Get-AppxPackage -AllUsers`);
- whether `Microsoft.WindowsAppRuntime.1.8` 8000.616.304.0 or newer is installed for the PC's
  architecture (winget 1.12 and later need it). This is the installer's built-in requirement: the
  probe makes no network call to read what the latest winget release needs;
- whether the machine-wide `winget.exe` prints its version within 30 seconds
  (`-WingetTimeoutSeconds`). That is the one a run as SYSTEM picks first: the newest App Installer
  with status `Ok` for the PC's architecture. When it does not, the next ones are tried and
  reported too. Only a run as SYSTEM makes this check. Run by an administrator, the probe starts no
  `winget.exe` and reports `winget=skipped`, because Windows can refuse an administrator's start of
  it (`Access is denied`) on a healthy PC;
- whether WAU is installed, its `WAU_UpdatesAtLogon` setting and Group Policy, and its
  `\WAU\Winget-AutoUpdate` task: state, triggers (and whether the at-logon one is still there),
  last run and result, next run;
- the last 20 (`-LogMatchCount`) entries of WAU's `updates.log` that tell what its runs did: each
  run's header, the `WinGet MSIXBundle` install of WAU's prerequisite step, `No update found` with
  the winget output after it, and errors.

Its last line can be read by a machine, for example:

```text
HEALTH: status=unhealthy problems=wau-logon-trigger computer=PC01 appinstaller=1.29.380.0 runtime=present winget=ok wingetversion=1.29.380 wau=2.12.0 wautask=Ready wauresult=0x00000000 logontrigger=yes wauwingetinstalls=0
```

`winget` is `ok`, `fallback`, `failed`, `timedout`, `notfound` or `skipped`. The probe exits 1 when
the PC is unhealthy and 0 otherwise. The `problems` codes:

| Code | Meaning |
|------|---------|
| `winget-notfound` | There is no machine-wide `winget.exe` |
| `winget-launch` | The machine-wide `winget.exe` does not print its version in time (`winget=failed` or `timedout`), or only an older one does (`winget=fallback`; WAU runs the newest) |
| `runtime-missing`, `runtime-unknown` | WAU is installed, and the Windows App Runtime above is missing or could not be read: WAU's next run can install a winget that cannot start |
| `wau-task-missing`, `wau-task-unknown`, `wau-task-disabled`, `wau-task-no-trigger` | WAU is installed, and its task does not exist, could not be read, is disabled, or has no enabled trigger: automatic updates never run |
| `wau-logon-trigger` | WAU's task still runs at every sign-in. Fix it with `rmm/Repair-WauLogonTrigger.ps1` |
| `not-elevated` | Not run as SYSTEM or elevated, so the probe could not read the machine |
| `probe-error` | The probe itself could not run |

A PC without WAU is not unhealthy for that reason alone: the installer leaves WAU off a PC that
lacks the Windows App Runtime. To check one PC by hand, run the probe as SYSTEM, for example
`psexec -s powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Get-WingetFleetHealth.ps1`.
From an elevated PowerShell every other check runs, and the probe reports `winget=skipped`. A run
that is not elevated at all reports `not-elevated`.

#### Winget-AutoUpdate at-logon fix

Installers from before the Winget-AutoUpdate fixes did not pass `UPDATESATLOGON` to WAU's MSI, so
WAU 2.12.0 also runs at every sign-in. That run reinstalls App Installer and resets winget's
sources exactly when a technician signs in to run the installer again. The installer removes the
trigger whenever it runs. `rmm/Repair-WauLogonTrigger.ps1` does the same on PCs set up earlier,
without a full installer run. The probe's `wau-logon-trigger` names the PCs that need it.

It removes every at-logon trigger from `\WAU\Winget-AutoUpdate` and keeps the others (WAU's
schedule). It sets `WAU_UpdatesAtLogon` to 0 (REG_DWORD) under
`HKLM:\SOFTWARE\Romanitho\Winget-AutoUpdate`, which WAU's MSI reads back when WAU is upgraded or
repaired, so the trigger does not come back. It reads both changes back. It changes nothing else,
and nothing at all when there is nothing to change. `-WhatIf` shows what it would change. A task
whose only trigger is the at-logon one is left alone, because WAU would otherwise never run again.
Its last line:

```text
REPAIR: status=fixed problems=none computer=PC01 logontrigger=removed updatesatlogon=set-0 policy=none
```

It exits 0 when no at-logon trigger is left and none will come back, also when WAU is not
installed, and with `-WhatIf` when the fix would succeed. It exits 1, with `-WhatIf` too, when:

- the at-logon trigger is the task's only one (`logon-only-trigger`);
- the trigger cannot be removed, or is still there afterwards (`trigger-not-removed`);
- `WAU_UpdatesAtLogon` cannot be set to 0 (`setting-not-written`);
- the task cannot be read (`task-unknown`);
- Group Policy sets `WAU_UpdatesAtLogon` to 1 under
  `HKLM:\SOFTWARE\Policies\Romanitho\Winget-AutoUpdate` (`policy-logon`): WAU's daily
  `Winget-AutoUpdate-Policies` task puts the trigger back, so change the policy;
- the script is not run as SYSTEM or elevated (`not-elevated`: nothing was read or changed);
- the script itself could not run, a failed 64-bit relaunch included (`repair-error`).

### Exit codes

| Code | Meaning |
|------|---------|
| 0 | Success — every app is installed, already present, or does not apply to this machine (`not applicable`); apps reported as `Deferred` do not count against it, and neither do apps whose post-install hook could not configure them (`Configuration: NOT DONE`) |
| 1 | One or more apps failed to install, including an install stopped at its time limit, the apps not attempted because winget could no longer be started partway through the run, an app with `scope = 'machine'` that has no machine-wide installer, and an installed app whose post-install hook failed (also: a blocking pre-flight system check failed). An app whose catalog condition could not be evaluated is attempted (fail open), so its failed install counts here too |
| 2 | Winget is unavailable or cannot be started (`winget --version` must run and print a version) and could not be set up (as SYSTEM: no machine-wide `winget.exe` was found, or none could be started, and the opt-in [Microsoft.WinGet.Client engine](#microsoftwingetclient-engine-opt-in) is not ready either), winget cannot open the winget source for the account even after the installer's repair (`0x8A15000F` and the other codes under **Setting winget up**, step 3; nothing is installed and Winget-AutoUpdate is not set up), App Installer's Group Policy turns winget or its source off (the pre-flight checks it before the run waits for anything or sets winget up; see **Setting winget up** above), or winget could no longer be launched at the end of the run (no app failed, but automatic updates and the next run would) |
| 3 | App-definition validation failed (for example an invalid `scope`, `arch`, `postInstall` or `userPhase` value, see [Catalog entry fields](#catalog-entry-fields)), or no valid app definitions remain |
| 4 | Administrator rights are required and the run was not elevated: the UAC prompt was declined or the elevated window could not be started, the run is non-interactive (no prompt is shown), it runs through `irm \| iex` in PowerShell 7, `Invoke-WingetInstall` was called from the imported module, or Group Policy sets the Windows PowerShell execution policy to `AllSigned` or `Restricted`: for the PC, so no UAC prompt is shown, or for the account that approved the prompt, so the elevated window stops before it runs anything (see [Administrator rights](#administrator-rights)) |
| 5 | The run was aborted before it finished: an unexpected error (the message and stack trace are in the log), the run was stopped from outside (Ctrl+C, the console closing, an installer stopping the console) when run from a file or non-interactively, the installer file changed before its elevated copy could run (see [Administrator rights](#administrator-rights)), or PowerShell runs the installer in Constrained Language Mode (an App Control for Business or AppLocker policy), which the installer checks before anything else. With `-CollectDiagnostics`, the installer installs nothing and exits 0 when it saved the diagnostics bundle, 5 when it could not (see [Diagnostics bundle](#diagnostics-bundle--collectdiagnostics)). The machine phase `rmm/Invoke-WingetAppSetup.ps1` also exits 5, without running the installer, when its pins are not set, the download failed or the SHA256 does not match; otherwise it passes the installer's code back unchanged |
| 6 | Another run of the installer is in progress on this PC (started by an RMM job, a scheduled task or someone else). This run stopped before its pre-flight checks and changed nothing. Run it again once the other run has finished (see [One run at a time](#one-run-at-a-time)) |
| 7 | Started from Windows PowerShell 5.1, the installer could not install PowerShell 7 or could not relaunch itself under it, including when Group Policy sets PowerShell 7's execution policy to `AllSigned` or `Restricted` (checked before PowerShell 7 is installed) |
| 8 | The apps are fine and winget still works, but automatic updates will not work or could not be verified. The summary's `Auto-updates:` line says which: `FAILED` (Winget-AutoUpdate could not be installed), `NOT CONFIGURED` (skipped because the Windows App Runtime the latest winget release needs, today `Microsoft.WindowsAppRuntime.1.8`, is missing and the installer could not install it, for example because that release needs a newer build or another family than the installer's pinned one), `AT RISK` (installed while that framework is missing and could not be installed) or `UNHEALTHY` (installed, but its `\WAU\Winget-AutoUpdate` task is missing, disabled, has no enabled trigger or could not be checked; see [Automatic updates](#automatic-updates)) |
| 9 | The run's time budget ran out (`-MaxRuntimeMinutes`, or `WINGET_APP_SETUP_MAX_RUNTIME_MINUTES` for the one-liner; see [Time budget for RMM jobs](#time-budget-for-rmm-jobs--maxruntimeminutes)): from then on the run started no app install, retry or Winget-AutoUpdate setup, so some apps (`Not attempted` in the summary, `NotAttempted` in `last-run.json`) or the Winget-AutoUpdate setup (`Auto-updates: NOT ATTEMPTED`) were not attempted. No app failed and winget still works. Run the installer again to finish; 9 is not a success code |
| 3010 | Success, but a restart is required to finish: an install said so, the Winget-AutoUpdate MSI returned 3010, Windows gained a pending restart during the run, or installing PowerShell 7 from Windows PowerShell needed a restart (see **Restart required** above). RMM tools and Intune treat 3010 as "succeeded, restart required". A restart that was already pending before the run does not cause it |

At the end of a run, when more than one applies, the code is the first of 1, 2, 9, 8, 3010 and 0.
A restart the run needs is still recorded (`restart=yes` in the `RESULT` line, `restartRequired`
in `last-run.json`) when another code wins. A run that relaunched itself elevated exits with the
elevated run's code. Apps reported as `Deferred` (a run as SYSTEM or under cross-user elevation
found no machine-wide installer for them, or the catalog marks them per-user) do not change the
code.

A script that imports the `WingetAppSetup` module and calls `Invoke-WingetInstall` itself gets
codes 0-4, 8, 9 and 3010 back as the function's return value; the function never exits. Pass the
code on with `exit (Invoke-WingetInstall -NonInteractive)`, or the wrapper exits 0 even after a
failed run. Codes 5, 6 and 7, and code 1 for a failed pre-flight check, come from
`winget-app-install.ps1` itself, not from the function.

### One run at a time

Only one real run works on a PC at a time. An elevated run, or one as SYSTEM, takes a machine-wide
lock (the `Global\winget-app-setup-run` mutex) before its pre-flight checks. A run started while
another one holds it stops at once with exit code 6
(`Another run of this installer is in progress on this PC ...`): it neither waits for that run nor
stops it. A dry run takes no lock, and neither does a run that is not elevated: the elevated run it
starts takes the lock. The lock is released as soon as the run's outcome is decided, before any
`Press any key to exit...`, so a window left open does not block the next scheduled run. The
[TightVNC password prompt](#tightvnc-server-password) at the start of an interactive run is asked
while the lock is held, so it waits at most 5 minutes for someone to start typing. A run that
is killed releases it too. Any process that holds the mutex's name makes a run exit 6, not only
another run of the installer.

### Run result

A real run prints one machine-readable line after its summary, or after the early-exit notice, and
before any `Press any key to exit...`:

```text
RESULT: exit=<code> installed=<n> skipped=<n> deferred=<n> failed=<n> notattempted=<n> autoupdates=<status> restart=<yes|no> build=<id> log=<path>
```

The fields are space-separated `key=value` pairs, always in this order:

- `exit`: the exit code the run ends with.
- `installed`, `skipped`, `deferred`, `failed`, `notattempted`: app counts after the retry pass
  (`notattempted`: apps the [time budget](#time-budget-for-rmm-jobs--maxruntimeminutes) did not
  reach); for a run that stopped early, the apps it had finished.
- `autoupdates`: `Configured`, `AlreadyPresent`, `AtRisk`, `Unhealthy`, `FrameworkMissing`,
  `Failed` or `NotAttempted` (the summary's `Auto-updates:` line; `NotAttempted`: skipped because
  the time budget was used up), or `NotRun` when the run stopped before that step.
- `restart`: `yes` when the run needs a restart to finish.
- `build`: the installer build id, or `unknown`.
- `log`: the transcript path, or `none`. It comes last, so everything after `log=` is the path.

Search the output for the line that starts with `RESULT: ` rather than reading the last line, and
take the exit code from the process. A dry run prints no `RESULT` line, and neither does the window
of a run that relaunched itself elevated (the elevated window prints it). A run started from
Windows PowerShell 5.1 prints the bootstrap's own lines after it; when installing PowerShell 7
needs a restart, the process exits 3010 while the line says `exit=0` and `restart=no`. A bootstrap
that fails with exit code 7 prints no `RESULT` line. A run that stops at once because PowerShell
runs it in Constrained Language Mode (exit code 5) prints
`RESULT: exit=5 installed=0 skipped=0 deferred=0 failed=0 notattempted=0 autoupdates=NotRun restart=no build=<id> log=none`,
from Windows PowerShell 5.1 too: it starts no log and writes no `last-run.json`.
`-CollectDiagnostics` prints no `RESULT` line.

The run that did the work (a real, elevated run that holds the run lock) also writes
`%ProgramData%\winget-app-setup\logs\last-run.json`, replacing the previous file in one step. It
does so as soon as it holds the lock, with `exitCode` and `endedUtc` set to `null`, and again with
its outcome when it ends: at its summary, at an early exit or when aborted. A record whose
`exitCode` is `null` therefore describes a run that is still going or was killed (an RMM time
limit, `taskkill /F`); `startedUtc` says which run. A dry run, a run that is not elevated, a run
without a transcript (see [Logs](#logs)) and a run that found another one in progress leave the
file alone. Fields:

| Field | Meaning |
|-------|---------|
| `schemaVersion` | `1` |
| `buildId` | Installer build id, or `null` |
| `startedUtc`, `endedUtc` | ISO 8601 UTC, e.g. `2026-10-04T14:30:05Z` (`endedUtc` is `null` until the run ends) |
| `exitCode` | The exit code the run ends with, or `null` until it ends |
| `summaryReached` | `false` for an early exit, an aborted run or a run still going |
| `counts` | `installed`, `skipped`, `deferred`, `failed`, `notAttempted` |
| `apps` | One entry per app processed, in catalog order: `id`; `status` (`Installed`, `Skipped`, `Deferred`, `Failed`, `NotAttempted`); `reason` (why it was skipped, deferred, not attempted or failed, as the run printed it, e.g. `already installed`, `not applicable: ...`, for a deferred app `winget found no machine-wide installer for it`, `per-user app (catalog scope 'user'): ...` or `per-user setup (catalog userPhase): ...`, or, for an app the time budget did not reach, `the run's <n>-minute time budget was used up`; `null` for an installed app); `code` (the winget or installer exit code, or `null`; with the Microsoft.WinGet.Client engine, the code `winget.exe` would have returned); `codeHex` (e.g. `0x8A150102`, or `null`); `installerCode` (the installer's own exit code when the [Microsoft.WinGet.Client engine](#microsoftwingetclient-engine-opt-in) ran an installer, otherwise `null`); `restartRequired`; `postInstall` (`Configured`, `NotConfigured` or `Failed` when the app's post-install hook ran, otherwise `null`) and `postInstallReason` (why it is not `Configured`, or `null`) |
| `autoUpdates` | `status` (as in the `RESULT` line) and `version` (or `null`) |
| `restartRequired` | The run needs a restart to finish |
| `wingetUsable` | Result of the end-of-run winget check; `null` when it did not run or could not complete |
| `installEngine` | Which engine installed the apps: `requested` and `used` (`Cli` for `winget.exe`, `WinGetClient` for the [Microsoft.WinGet.Client engine](#microsoftwingetclient-engine-opt-in); a run that is not SYSTEM is always `Cli`), `module` (`name`, `version`, `sha256` and `engineVersion` when the module installed the apps, otherwise `null`) and `fallbackReason` (why a requested module was not used, otherwise `null`) |
| `transcriptPath` | This run's transcript, or `null` |

An RMM tool can collect the file. It has no transcript header, but a failure reason can contain a
path, so check it before you attach it to a public issue.

## Logs

Every run writes a full transcript to
`%ProgramData%\winget-app-setup\logs\install-<yyyyMMdd-HHmmss>.log` (dry runs get a `-whatif`
suffix, e.g. `install-20260708-143000-whatif.log`). The path is printed at startup and repeated
with the final summary. ProgramData is used — rather than the elevating account's `%TEMP%` — so
the log survives cross-user elevation and can be collected after a failed install on a remote
machine. If the transcript cannot be started, the installer warns and continues: logging never
blocks an install. A run that relaunched itself elevated leaves the first window's log, which ends
with `The elevated run ended with exit code N.`, next to the elevated run's own logs. That first
window is not elevated, so it can write there only until an elevated run has locked the folder
(below): after that, it warns that it could not start its transcript and keeps no log.

The transcript includes winget's own output. Each `winget install`, `winget download` and
`winget source reset` is logged as a `> winget ...` line with its full command line, followed by
what winget printed, indented: for example
`Installer failed with exit code: 1603` or a hash mismatch. The spinner and the download progress
bar are left out, apart from the last progress line of each download, and a message winget shows
next to its spinner, such as `Waiting for another install/uninstall to complete...`, is logged once
rather than at every redraw. The per-app `winget list` checks print nothing; the source update
prints winget's output only when it exits with an error, and the source check when winget cannot
open the source. With the opt-in
[Microsoft.WinGet.Client engine](#microsoftwingetclient-engine-opt-in), each install is instead a
`> Install-WinGetPackage ...` line, then the child `pwsh`'s own output, indented (at most its last
20 lines, usually just `Microsoft.WinGet.Client Install <id>: Ok`), then one
`WinGet client result: ...` line.

The same folder also holds:

- `install-<yyyyMMdd-HHmmss>-bootstrap.log` — the Windows PowerShell 5.1 phase of a run started
  from `powershell.exe`: finding or installing PowerShell 7 and relaunching under `pwsh`, ending
  with the exit code the relaunched run returned. The elevated window of a run that relaunched
  itself elevated starts in Windows PowerShell too, so it writes one of these as well.
- `pwsh-msi-<yyyyMMdd-HHmmss>-<attempt>.log` — `msiexec`'s verbose log when the bootstrap installs
  PowerShell 7 from the MSI.
- `winget-install-<package id>-<yyyyMMdd-HHmmss>.log` — the installer's own log for each
  `winget install` attempt (winget's `--log`, or `Install-WinGetPackage -Log` with the module
  engine), when the installer writes one: MSI, WiX, Burn and Inno installers do, most other EXE
  installers do not. A failed app's reason in the summary names this file.
- `wau-msi-<install|uninstall>-<yyyyMMdd-HHmmss>-<attempt>.log` — `msiexec`'s verbose log of the
  Winget-AutoUpdate install, or of its removal by `winget-app-uninstall.ps1` (which writes it here
  although it keeps no transcript, after making the folder safe as below; when it cannot,
  `msiexec` runs without a log), one per attempt. A failed install or removal names it.
- `install-<yyyyMMdd-HHmmss>-rmm.log` — the log of the Endpoint Central machine phase
  (`rmm/Invoke-WingetAppSetup.ps1`): how it was started (including its relaunch from a 32-bit
  PowerShell), which installer it downloaded and its SHA256 check, the installer's console output,
  and the exit code it passed back.
- `last-run.json` — the outcome of the last real run (see [Run result](#run-result)).

The user phase (`rmm/Invoke-WingetAppSetupUserPhase.ps1`) runs as the signed-in user, who cannot
write here, so it logs to that user's own
`%LOCALAPPDATA%\winget-app-setup\logs\install-<yyyyMMdd-HHmmss>-userphase.log`, with winget's
per-app `--log` files next to it, and keeps its state in
`%LOCALAPPDATA%\winget-app-setup\user-phase.json`.

Old logs are removed automatically. The run that holds the run lock (a real, elevated run) keeps
the newest 30 `install-*.log` transcripts (bootstrap, `-rmm` and `-whatif` ones included) and
deletes the older ones, together with the `winget-*` and `pwsh-msi-*` logs older than the oldest transcript it
keeps. Other files there, such as `last-run.json` and the `wau-msi-*` logs, are left alone. It also
removes the installer's temporary copy folders (`winget-app-setup-<id>`,
`winget-app-setup-elevate-<id>`, `winget-app-setup-pwsh-<id>`) that a stopped run left behind, once
they are a day old (the uninstaller's elevated copies use the same folders, and a later installer
run removes the ones a stopped uninstall left behind): from `%SystemRoot%\Temp` and, for a run as
SYSTEM, from SYSTEM's own temp folders. Only a folder of files owned by SYSTEM or Administrators is
removed. An elevated run by an administrator does not clean that administrator's own `%TEMP%` (a
user profile folder), so copies a killed interactive run left there can be deleted by hand. It
removes the Microsoft.WinGet.Client engine's `wingetclient-<id>` folders that a killed run left in
`%ProgramData%\winget-app-setup` once they are a day old, under the same owner rule and only
while that folder is locked to SYSTEM and Administrators, and leaves the engine's `cache` folder
alone. Nothing is deleted through a link: when the `logs` folder or
`%ProgramData%\winget-app-setup` is one, that cleanup is skipped. These numbers are the defaults of
`Invoke-InstallerHousekeeping` (`WingetAppSetup/Private/Housekeeping.ps1`).

Every elevated run, and every run as SYSTEM (a `-WhatIf` dry run included), makes
`%ProgramData%\winget-app-setup` and its `logs` folder safe before its transcript starts (see
[Administrator rights](#administrator-rights)). A
junction or symbolic link planted in place of either folder is removed without changing what it
points to, and the run warns about it. The warning comes before the transcript starts, so it is on
the console but not in that run's log. Both folders are then owned by Administrators, and only
SYSTEM and Administrators can change them. Standard users can read the `logs` folder and the logs
in it, so a log can be opened from the end user's own session after a cross-user elevated run.
They cannot list the parent folder, so open the logs by their full path (for example, paste
`C:\ProgramData\winget-app-setup\logs` into File Explorer's address bar).

If the `logs` folder cannot be made safe, the run continues without a transcript and without
`last-run.json`, and the warning says why. When a link there cannot be removed, the warning says
how to remove it with `rmdir`. When the folder's access list cannot be set (`icacls` failed, or
another owner or access entry is still there), the warning ends with a `ren` command that renames
the folder aside, to `<name>-old-<yyyyMMdd-HHmmss>`; the next elevated run then creates a new
folder that only SYSTEM and Administrators can change. The run never suggests `takeown` or
`icacls /reset`: another account may still be able to change the folder, and both commands would
follow a link put in its place.

Each transcript begins with an `Installer build:` line carrying the content-derived build id
(`<module version>+<8-char SHA256 fragment of the whole generated script>`) stamped by
`build/Build-WingetInstallScript.ps1`, so you can tell exactly which installer build produced a
given log. The summary and failure tables are written at full width, so long app lists and
failure reasons are never cut off in the log.

### When a run fails

A run that stops early (a failed pre-flight check, winget missing, a declined elevation, a failed
PowerShell 7 setup, an unexpected error) ends with one block: the exit code and why, the log file
path, the installer build, where to report it, and the command that makes a diagnostics bundle
(below). The run's `RESULT` line follows (see [Run result](#run-result); a failed PowerShell 7
setup prints none). When someone is at the console, it then waits for a key press, so the window
does not close before you can read it (under `irm | iex` the run ends the PowerShell window it runs
in). Unattended runs never wait. A run that reaches its summary and fails (exit code 1, 2 or 8)
prints the same report hint after its `Full transcript of this run:` line.

To report a failure, open an
[install failure issue](https://github.com/J-MaFf/winget-app-setup/issues/new?template=install-failure.yml)
with the exit code, the installer build and a diagnostics bundle (or the log file). The form also
asks how the installer was started, the elevation style and the Windows build.

#### Diagnostics bundle (`-CollectDiagnostics`)

On the PC where the run failed, run this in PowerShell, started as administrator so it can read
everything. It works from Windows PowerShell 5.1 and PowerShell 7, and needs no execution policy
change:

```powershell
& ([scriptblock]::Create((irm "https://raw.githubusercontent.com/J-MaFf/winget-app-setup/refs/heads/main/winget-app-install.ps1"))) -CollectDiagnostics
```

From a clone, `pwsh -File .\winget-app-install.ps1 -CollectDiagnostics` does the same. From a
32-bit PowerShell on 64-bit Windows (some RMM agents), run it through
`%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe`: a 32-bit PowerShell reads the
32-bit registry, where PowerShell 7, Winget-AutoUpdate and the pending-restart keys are not. The
bundle says so in `system.txt` and `README.txt` when it was made that way.

It installs nothing and sets nothing up on the PC: no transcript, no run lock, no `last-run.json`,
no `RESULT` line, no PowerShell 7 install and no elevation, and it works when winget does not. Its
winget source check (`winget.txt`) opens the source as every install does, so winget may update
its source data for the account the bundle runs as, which needs the network and, for an account
without that data, deploys winget's source package (`Microsoft.Winget.Source`). It
saves `winget-app-setup-diagnostics-<yyyyMMdd-HHmmss>.zip` on the Desktop of the account that ran
it. For a run as SYSTEM, or as another admin account than the signed-in user, it saves it in
`C:\Users\Public\Documents`, which every account can open, and falls back to `%TEMP%`. It prints
the path and exits 0, or 5 when no folder takes the file. The bundle holds:

- `logs\`: the latest run's transcripts (up to six, started within an hour of the newest, so the
  bootstrap and PowerShell 7 transcripts of the window that asked for elevation and of the elevated
  one, and the machine phase's `-rmm.log`), the installer logs written since then
  (`winget-install-*`, `pwsh-msi-*`, `wau-msi-*`), and `last-run.json`. A log longer than 4 MB
  keeps its last 4 MB.
- `user-phase\`: when the user phase has run in this account, its `user-phase.json` and its latest
  transcript and winget logs.
- `system.txt`: the Windows build and architecture, the account it ran as and the signed-in user,
  the elevation style (same-user, cross-user or SYSTEM), the PowerShell 7 installs, the execution
  policy and its Group Policy keys, the App Installer and Microsoft Store Group Policy keys, the
  pending-restart state, the Windows App Runtime this build pins and its built-in requirement, and
  the Winget-AutoUpdate version and task.
- `winget.txt`: `winget --version` and `winget --info`, each with the 30-second time limit, and
  whether winget can open the winget source (`Winget source: opens`, or
  `CANNOT BE OPENED (0x8A15000F SOURCE_DATA_MISSING)`), from the installer's own source check with
  its 2-minute limit, which needs the network (as SYSTEM, the machine-wide `winget.exe`).
- `appx.txt`: `Get-AppxPackage -AllUsers` for `Microsoft.DesktopAppInstaller`,
  `Microsoft.Winget.Source` (the winget source package, deployed for each account) and
  `Microsoft.WindowsAppRuntime.*`, with each account's install state by SID, and
  `Get-AppxProvisionedPackage -Online` for App Installer and the Windows App Runtime. These run in
  Windows PowerShell.
- `wau-updates-log-tail.txt`: the last 400 lines of Winget-AutoUpdate's `updates.log`.
- `README.txt`: what each source returned, or why it could not be read, and the list of files in
  the logs folder.

Without elevation, the other accounts' AppX packages, the provisioned packages and possibly some
logs cannot be read. `README.txt` says which, and the command says so when it finishes.

Every file is redacted before it is zipped. Account names, the computer name, domain and DNS
domain names, user profile folder names, the identifying part of the SIDs of real accounts
(`S-1-5-21-...` and Azure AD's `S-1-12-1-...`) and email addresses become placeholders such as
`<user1>`, `<computer1>`, `<domain1>` and `S-1-5-21-<sid1>-1001`, with the same placeholder in
every file. Built-in accounts and well-known SIDs (`SYSTEM`, `Administrators`, `S-1-5-18`,
`S-1-5-32-544`) stay. IP addresses and the names of other machines (a proxy or a file server) are
not redacted. Look through the bundle before you attach it anyway.

> **Privacy: this repository and its issues are public.** Every PowerShell transcript starts with a
> header that names the computer, the signed-in account and the account that ran the installer
> (`Username`, `RunAs User`, `Machine`). Delete that header, or replace the names in it, before
> you paste or attach a log, and check the rest for account or computer names. If a log cannot be
> shared publicly, send it to the maintainer privately. The diagnostics bundle already has these
> names replaced (see above); look through it before you attach it anyway.

## Automatic updates

Ongoing updates are handled by [Winget-AutoUpdate (WAU)](https://github.com/Romanitho/Winget-AutoUpdate),
which the installer sets up automatically (a pinned, SHA256-verified version). WAU runs as SYSTEM on a
weekly schedule (Tuesdays at 02:00; a missed run catches up shortly after the next start) and updates
installed apps machine-wide, plus a user-context pass for the logged-on user — which avoids the
cross-user `0x80073d19` problems a per-user scheduled task hits.

Every WAU run first updates winget itself, so the installer keeps WAU out of its own way: WAU is set
up last, after the retry pass, it is not started immediately and not at user logon (machines deployed
by older versions have their logon trigger removed on the next run, or by
[`rmm/Repair-WauLogonTrigger.ps1`](#winget-autoupdate-at-logon-fix) without a run), and if a WAU
run is already in progress when the installer starts, the installer waits up to 15 minutes for it
to finish. WAU is only installed when the Windows App Runtime framework the newest winget release
needs is present, because WAU installs that release and it would otherwise leave winget unusable
(issues #279, #283, #284). Today that is `Microsoft.WindowsAppRuntime.1.8` 8000.616.304.0 or
newer.

**Which framework.** The installer reads it from the release WAU installs: the
`DesktopAppInstaller_Dependencies.json` of the latest winget release
(`https://github.com/microsoft/winget-cli/releases/latest/download/DesktopAppInstaller_Dependencies.json`,
the release GitHub marks latest, which is the one WAU's `api.github.com` query names; the download
link is not subject to the API's limit of 60 calls an hour per address), with a 30-second limit
(`Get-WindowsAppRuntimeRequirement`). The transcript says what it found:
`The latest winget release needs Microsoft.WindowsAppRuntime.1.8 >= 8000.616.304.0 ...`. When the
file cannot be read (no network, a proxy, GitHub down, a format the installer does not know) or lists
no Windows App Runtime, the run warns (one line, with the error's status line, such as
`Response status code does not indicate success: 403 (Forbidden)`, not the page a proxy sent with
it) and checks for the built-in requirement, `Microsoft.WindowsAppRuntime.1.8` 8000.616.304.0 or
newer; the lookup never stops or fails a run.
When a future winget needs a newer 1.8 build than the pinned framework below, or another framework
family (a newer family does not stand in for 1.8, nor 1.8 for a newer one), a PC that already has it
gets WAU as usual; on a PC that lacks it, the installer does not install its pinned 1.8 framework,
skips WAU (or reports it `AT RISK`) with
`Windows App Runtime: NOT INSTALLED - the latest winget release needs <framework>, and the framework
this installer installs, ..., does not meet that; a newer version of this installer is needed`, and
the run exits 8. That is the sign to move the pin, and the weekly E2E run fails on it (see
[End-to-end monitoring](#end-to-end-monitoring-e2e-tier-1)). When the release needs several frameworks, only the
ones the PC lacks count: a PC that has every other one and lacks only `Microsoft.WindowsAppRuntime.1.8`
still gets the pinned framework, and the messages name only the frameworks that are missing.

A freshly imaged PC, a PC whose Microsoft Store updates are blocked, and Windows Server often lack
that framework, so when the all-users check finds it missing (and the pinned copy meets what the
latest winget release needs), the installer first installs a pinned copy for every user of the PC
(`Install-WindowsAppRuntimeFramework`), on a first run and on a re-run that finds WAU already
installed alike:

- **What:** the framework file of Windows App Runtime 1.8.12 (`Microsoft.WindowsAppRuntime.1.8`
  8000.994.2142.0) for the PC's architecture (x64, x86 or ARM64), taken from Microsoft's
  `Microsoft.WindowsAppSDK.Runtime` 1.8.260921001 package on NuGet.org. That package is the
  developer package, published under the Windows App SDK license terms for developers, not one of
  the end-user runtime installers Microsoft documents for redistribution. The download is the whole
  package, about 150 MB, and happens only on a PC that lacks the framework, but a failed install is
  not remembered: until one succeeds, every run on that PC downloads it again. The version, the URL
  and each file's size and SHA256 are pinned in `Get-WindowsAppRuntimePin`.
- **Checks:** the package goes into a new folder inside `%ProgramData%\winget-app-setup` that is
  limited to SYSTEM and Administrators first, like the WAU MSI's (a link in place of
  `%ProgramData%\winget-app-setup` is removed first; see below). When that folder cannot be set
  up, nothing is downloaded and the `NOT INSTALLED` reason says why, with the same `ren` advice as
  for WAU when an access list cannot be set. The framework file must have the pinned size and
  SHA256 and a valid Authenticode signature from `Microsoft Corporation`; it is held open from the
  hash until it is provisioned, so what is provisioned is what was checked.
- **How:** `Add-AppxProvisionedPackage -Online -SkipLicense`, run in Windows PowerShell with a
  10-minute time limit, then the all-users check again (and `Get-AppxProvisionedPackage`, which
  only warns when it does not list the framework). When that check cannot run, the install counts
  as done, with a warning, and WAU is set up, as on any run where the check cannot run.
  Microsoft's `WindowsAppRuntimeInstall` program is not used: it registers the framework only for
  the account that runs it, and as SYSTEM only stages it.
- **Never:** when the latest winget release needs a newer build or another framework family than
  the pinned one (see "Which framework" above), on a run that is not elevated (a run as SYSTEM
  is), on 32-bit Arm Windows or a Windows build older than 17763, over a framework of the same or a
  newer version that is already provisioned, or when the all-users check itself could not run. It
  never uses `Repair-WinGetPackageManager -AllUsers` (#265).

The transcript then has one `Windows App Runtime: installed ...` or
`Windows App Runtime: NOT INSTALLED - <reason>` line. When the install is not possible or fails,
WAU is skipped as before: the summary shows `Auto-updates: NOT CONFIGURED` (or `AT RISK` when WAU
was already installed) with the reason on the next line, and the run exits 8. A dry run
(`-WhatIf`) says that it would install the framework first if it is missing, and installs nothing.
On the E2E run's Windows Server 2025 runners (see
[End-to-end monitoring](#end-to-end-monitoring-e2e-tier-1)) the install works in all three legs
(started from PowerShell 7, from Windows PowerShell 5.1, and as SYSTEM): the signature check passes, `Add-AppxProvisionedPackage`
reads the file the installer holds open, the all-users check then finds the framework, and WAU is
set up. Not yet checked on a real PC: whether provisioning the framework on its own registers it
for accounts that sign in later, and on Windows 10 and Windows 11.

WAU counts as set up only when its scheduled task `\WAU\Winget-AutoUpdate` exists, is enabled and
has an enabled trigger. The installer checks this after it installs WAU and on every run that finds
WAU already installed. Otherwise the summary shows `Auto-updates: UNHEALTHY - ...` with the reason;
to fix it, uninstall Winget-AutoUpdate in Settings > Apps and re-run the installer. When the task
cannot be checked at all (the Task Scheduler query fails, for example with `Access is denied`), the
run does not know whether WAU will run: the summary says
`it is not known whether apps will update automatically`, and the run asks you to check
`\WAU\Winget-AutoUpdate` in Task Scheduler instead of reinstalling WAU. The installer never repairs
the task itself. Each run that finds or installs WAU logs the task's state, triggers, last run,
last result and next run, then the last 20 lines of WAU's own log (`<install folder>\logs\updates.log`,
by default `C:\Program Files\Winget-AutoUpdate\logs\updates.log`), each indented behind a `|`. Any
auto-update outcome shown as an error (`FAILED`, `NOT CONFIGURED`, `AT RISK`, `UNHEALTHY`) makes the
run exit 8 when no app failed and winget still works (see [Exit codes](#exit-codes)), so an RMM job
sees it.

The WAU MSI is downloaded into a new folder inside `%ProgramData%\winget-app-setup`. The installer
first removes a junction or symbolic link in place of `%ProgramData%\winget-app-setup`, without
changing what it points to (see [Administrator rights](#administrator-rights)). It then makes
Administrators the owner of both folders, limits them to SYSTEM and Administrators, and reads the
result back. `icacls` runs with `/L` (act on a link itself, not on its target), and a folder that
is a link afterwards is refused. If `icacls` fails or a folder still has another owner or access
entry, WAU is not downloaded and the summary shows `Auto-updates: FAILED`. The run says why and
gives a `ren` command that renames `%ProgramData%\winget-app-setup` aside; the next run then
creates a new folder that only SYSTEM and Administrators can change. It never suggests `takeown`
or `icacls /reset`, which would follow a link put in the folder's place. When a folder cannot be
set up for another reason (a link that cannot be removed, a file in its place, a folder that
cannot be created, or `icacls` does not start), the run gives that reason without the `ren`
advice; for a link that could not be removed, the reason says how to remove it with `rmdir`. A
folder replaced by a link while it was being locked is refused, and the next run removes that
link. The MSI is hashed from a handle that stays open until `msiexec` has finished, so nothing can
replace it in between.
WAU's own self-update is disabled so the version stays pinned; bump it via `Get-WauPin` in
`WingetAppSetup/Public/WingetAutoUpdate.ps1`. `winget-app-uninstall.ps1` removes WAU (and any legacy
scheduled-update task from older versions) after the apps, and keeps it while an app could not be
removed (see [Uninstall](#uninstall)).

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
user (the user of the window's own session, at the console or over Remote Desktop, as in
[Running as SYSTEM](#running-as-system-rmm-tools-such-as-endpoint-central); the installer decides
this once, at the start of the run, for this step too). It never writes to
another user's profile. After a run as SYSTEM, the Endpoint Central user
phase (`rmm/Invoke-WingetAppSetupUserPhase.ps1`) sets them in each user's own account at sign-in.
Until the user has opened Windows Terminal once (it creates `settings.json` then), it sets the
default terminal application and leaves `defaultProfile` for a later sign-in.

## Uninstall

`winget-app-uninstall.ps1` removes what the installer set up: the catalog apps, then
Winget-AutoUpdate and any legacy scheduled-update task. It is one self-contained file, generated
from the `WingetAppSetup` module like the installer, so it needs nothing next to it: download
`winget-app-uninstall.ps1` on its own, or run it from a clone. It runs only from a file. Started
through `irm | iex` it changes nothing and stops with exit code 5: an unattended run exits, and an
interactive console stays open with `$LASTEXITCODE` 5.

```powershell
powershell -ExecutionPolicy Unrestricted -File .\winget-app-uninstall.ps1           # asks for elevation
powershell -ExecutionPolicy Unrestricted -File .\winget-app-uninstall.ps1 -WhatIf   # preview, changes nothing
```

- It first sets winget up the way the installer does (as SYSTEM, with the machine-wide
  `winget.exe`; it never uses the
  [Microsoft.WinGet.Client engine](#microsoftwingetclient-engine-opt-in), whatever
  `WINGET_APP_SETUP_SYSTEM_ENGINE` says). When winget still cannot be used, cannot open the winget
  source for the account (see **Setting winget up**, step 3), or Group Policy turns it off, it
  removes nothing, Winget-AutoUpdate included, and exits 2: without its source, winget lists no
  catalog app, so every app would read as not installed.
- An app counts as not installed only when `winget list --source winget` answered. A check that
  could not start winget, ran out of time or failed (a source that cannot be opened included) is a
  failure, so Winget-AutoUpdate is kept.
- Each app without `quietUninstall` (see the next point) is removed with
  `winget uninstall --exact --id <id> --silent` under a 15-minute limit. An app whose own
  uninstaller returns 3010 or 1641 (a restart finishes the removal) counts as removed, although
  winget reports it as `0x8A150030`.
- `--silent` only makes an MSI quiet. For an exe app, winget runs the command the app registered
  for removal (its `QuietUninstallString`, else its `UninstallString`) exactly as written, and
  `winget uninstall` has no way to add switches. Google Drive registers a bare `uninstall.exe`,
  which asks "Uninstall Google Drive?" and waits for a click: the run used to hang there for 15
  minutes and fail. Such an app carries `quietUninstall` in the catalog, and the uninstaller runs
  the program its uninstall entry under
  `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall` (64-bit view, then `WOW6432Node`)
  names, with the catalog's switches (for Drive, Google's `--silent --force_stop`, which also
  closes a running Drive), under the same 15-minute limit. It runs it only when the entry names an
  existing `.exe` under Program Files or Program Files (x86); otherwise the app fails at once
  (`its own uninstaller was not found: ...`), and `winget uninstall` is not tried, since it would
  hang. Drive's `uninstall.exe` hands its work to a copy of itself and exits, so the uninstaller
  then waits, for what is left of the 15 minutes, until the uninstall entry is gone, and counts
  the app removed only once `winget list` no longer shows it. The limit's tree kill reaches only
  a process still running when the limit runs out, so the uninstaller also records what
  `uninstall.exe` started before it exited; when the entry is still there at the limit, it stops
  those processes that are still running, and the failure names them. A preview (`-WhatIf`) prints
  the command line it would run.
- An installed app whose catalog condition or `arch` list does not hold on this PC is left alone
  (Dell Command Update on other hardware or on ARM64 Windows, the 32-bit Reader on an x64 PC). A
  condition or architecture that cannot be read counts as holding, as in the installer.
- The shells the run depends on are kept: PowerShell 7 when the uninstaller runs in it (started
  from a window that is not elevated, it relaunches in Windows PowerShell, which can remove
  PowerShell 7), and Windows Terminal when it hosts this window, or the default terminal
  application is set to Windows Terminal (what the installer sets). The skip line says how to
  remove them. Windows' automatic choice ("Let Windows decide", the Windows 11 default, which hands
  console windows to Windows Terminal when it is installed) is not detected: to remove Windows
  Terminal on such a PC, start the uninstaller from a Windows Console Host window, or first set the
  default terminal application (Settings, For developers, Terminal) to Windows Console Host.
- A per-user app (an entry with `msixName`: Windows Terminal) is kept in a run as SYSTEM or under
  cross-user elevation (see [Running as SYSTEM](#running-as-system-rmm-tools-such-as-endpoint-central)),
  before any winget call: `Skipping: Microsoft.WindowsTerminal (a per-user app that this run cannot
  remove: it runs as '<admin>' in the session of '<user>'; ...)`. There, even `winget list` answers
  for SYSTEM or the admin account, not for the user the app belongs to. In the same runs the
  installer decides Windows Terminal from the PC: it skips it when its package is provisioned for
  every user (as on Windows 11), and otherwise installs it for every user with `--scope machine`.
  The uninstaller removes no provisioned package, and a run signed in as the user removes only that
  user's copy. It counts as kept on purpose, so Winget-AutoUpdate is still removed and the
  default-terminal setting is left as it is. A preview (`-WhatIf`) started from the same elevated
  window, or as SYSTEM, shows the same skip; a preview in a window that is not elevated runs as the
  signed-in user and cannot know which account the UAC prompt will elevate as, so it may list
  Windows Terminal (it says so). To remove it, run the uninstaller signed in as that user. A
  standard user cannot: the UAC prompt elevates as another account, which is cross-user elevation
  again.
- Once winget no longer lists Windows Terminal, and the package check agrees, the default-terminal
  setting (`HKCU:\Console\%%Startup`) that still names it is removed for the account that runs the
  uninstaller, so Windows chooses the terminal again and a later installer run no longer skips
  Windows Terminal.
- Winget-AutoUpdate is removed last, and only when no app failed: an app that could not be removed
  keeps its updates. When WAU is installed, the run says it was kept; fix the failure and run the
  uninstaller again.
- When someone is at the console, the run ends with `Press any key to exit...`, as the installer
  does, so the summary and the failure reasons stay on screen: the elevated window closes as soon
  as the run ends, and the uninstaller keeps no transcript. A run as SYSTEM or under CI does not
  wait.
- `-NonInteractive` (or `WINGET_APP_SETUP_NONINTERACTIVE`, see
  [Unattended runs](#unattended-runs)) never shows a UAC prompt (it exits 4 when not elevated) and
  does not wait for a key press at the end.

| Code | Meaning |
|------|---------|
| 0 | Done: every app was removed, was not installed, or was kept on purpose (a shell the run depends on, a per-user app in a run as SYSTEM or under cross-user elevation, or an app whose condition or `arch` list does not hold), and Winget-AutoUpdate was removed or was not installed |
| 1 | An app could not be removed or checked (Winget-AutoUpdate is then kept), or Winget-AutoUpdate could not be removed |
| 2 | winget cannot be started for this account, cannot open its source, or Group Policy turns it off, so nothing was removed (Winget-AutoUpdate included) |
| 3 | The app list has invalid entries or is empty |
| 4 | Not elevated, and the UAC prompt was declined or could not be shown (a non-interactive run shows none), or the execution policy Group Policy sets would refuse the elevated run |
| 5 | Stopped by an unexpected error; started without a script file (`irm \| iex`); or the file changed after the run started, or could not be read or copied, before its elevated run |
| 3010 | Done, and a restart finishes removing an app (its uninstaller returned 3010 or 1641) or Winget-AutoUpdate (its `msiexec` returned 3010) |

When more than one applies, 1 ranks above 3010. A preview (`-WhatIf`) needs no administrator
rights, exits 0 when winget cannot be started yet, and never exits 3010. Started without
administrator rights, the window you started it in waits for the elevated run and exits with its
code. The elevated window runs a checked copy of the file, as the installer's does (see
[Administrator rights](#administrator-rights)). The uninstaller keeps no transcript, prints no
`RESULT` line and takes no run lock.

## Testing on a real PC

The end-to-end workflow (below) exercises a real install on throwaway GitHub runners, but some of
the owner test plan needs a real desktop PC: cross-user elevation, a TightVNC viewer, an ARM64 PC.
`e2e/Invoke-RealPcTestPlan.ps1` is one command that runs every *automatable* item of that plan on a
**disposable** Windows 10 22H2+ or Windows 11 test machine (a VM with a checkpoint, or a spare PC —
**not a work PC**: it installs and removes apps, sets up Winget-AutoUpdate and changes
`%ProgramData%`).

- **What it does:** a first unattended install and its re-run, a run as SYSTEM through the Endpoint
  Central machine-phase wrapper, the `%ProgramData%` link guard (a temporary standard user plants a
  junction there from a one-shot S4U task, registered with the user's random password, which stays
  in memory and which Task Scheduler does not store; if the task cannot be registered or run, the
  admin plants it and that row is SKIP with the failing step, and the report lists who holds "Log
  on as a batch job"), a time-budget run that exits 9 and then finishes (the harness's own
  `winget uninstall` of 7-Zip before it is kept in that stage's `winget-uninstall.txt`), the
  `-CollectDiagnostics` bundle, and the uninstaller (preview then real; it runs in Windows
  PowerShell, so it must remove PowerShell 7 too). Each check is a
  PASS/FAIL/SKIP row with evidence, and each stage keeps its console output, transcripts,
  `last-run.json` and winget logs (of a long stage the first 15 and the last 25 per source, with a
  `README.txt` of the counts). `arp.txt` lists the Apps & features entries (name, version, install
  date, hive and key) before Preflight and after each stage that installs or uninstalls; it is
  evidence only.
- **winget's source in your account:** Preflight records who is signed in (the owner of the oldest
  `explorer.exe` in the window's session, the installer's own rule) and who the window is
  elevated as (compared by SID: "Cross-user elevation: yes/no/unknown"), winget's and App
  Installer's versions and whether winget's source package (`Microsoft.Winget.Source`) is
  registered for your account, with the raw `winget --info`, `winget source list` and every
  account's registration in `evidence\0-Preflight\winget-info.txt`. It then checks that winget can
  open its `winget` source in your account (`winget search --id Microsoft.PowerShell --exact
  --source winget`; PASS only on exit 0, the code named otherwise), again after the first run, and
  again before the uninstaller stage. At Preflight the check is SKIP when winget is not on the PC
  yet: the check after the first run decides. Preflight's check is also SKIP, its code kept, when
  the latest check opened the source: that was the PC before the run, not a product result. That
  row and the report's warning say when it opened: at the first check that opened after the last
  failed one (for example "after the first run"), not at the latest check, which may only have
  found it still open.
  Without that source, winget reads every installed app as not installed in your account
  (`winget list` and `winget uninstall` without `--source` only warn). So when the check fails,
  the report starts with a warning, the rows that ask winget what is installed in your account are
  SKIP or FAIL, never PASS, and the run goes on to collect evidence. The uninstaller must then
  refuse: the real uninstall passes only with exit 2 (it reported success otherwise), each
  "Skipping: <id> (not installed)" it printed fails, and Winget-AutoUpdate must be kept. Unless
  the uninstaller's own check opened the source (its console says `The winget source opens for`):
  then a PASS row quotes that line ("The uninstaller repaired winget's source for this account"
  when a fix's success line comes before it, such as the source package registered for the
  account; "The uninstaller found winget's source open" otherwise), the stage is judged as usual
  on the lookups made after the uninstall, and the preview row is SKIP, since its lookups ran
  before the repair. The harness then checks the source once more ("after the uninstaller"), so
  the report's warning and Preflight's row say when it opened. The harness's own lookups and
  removals name `--source winget` and have time limits (`winget list` 45 s; `winget search`,
  `--version`, `--info` and `source list` 120 s, the installer's own limit for its source check;
  `winget uninstall` 150 s). A call that runs out is stopped with everything it started and counts
  as no answer, never as "not installed". The re-run and the SYSTEM run expect
  an app found already there only when the first run's `last-run.json` recorded it installed or
  already there; any other app may be installed or found (one SKIP row names them). An app the
  first run deferred because winget found no machine-wide installer for it (cross-user elevation)
  may also be deferred again, for that reason, by the re-run and by the SYSTEM run.
- **Cross-user elevation and the source repair:** FirstRun checks that the installer agrees with
  Preflight. "The installer detected the cross-user elevation as Preflight did" passes when the
  installer printed `Cross-user elevation detected` exactly when Preflight said yes, fails
  otherwise, and is SKIP when Preflight could not tell. Under cross-user elevation the installer
  installs machine-wide only, as SYSTEM does, so FirstRun and ReRun expect the same: an app may be
  `Deferred` as having no machine-wide installer, and Windows Terminal counts as already there only
  when it is provisioned for every user. "The installer registered winget's source package for
  this account" passes when the first run says it registered the package, and names how (the
  download URL, or the copy already on the PC), whatever Preflight saw: Preflight makes no source
  check while winget cannot be started in your account yet (as on a freshly imaged PC), and its
  check can run out of time. Without that line, the row is judged only when Preflight's check
  failed with `0x8A15000F` (`SOURCE_DATA_MISSING`): it fails when the source was still closed
  after the run, quoting the installer's "cannot be opened" line, and is SKIP otherwise; when the
  source already opened at Preflight, the row says how to exercise the repair
  (`Get-AppxPackage Microsoft.Winget.Source* | Remove-AppxPackage`). The uninstaller stage
  counts an app as kept on purpose only when the uninstaller's console says so: its skip line for
  PowerShell 7 (when it runs in it), Windows Terminal (when it hosts the window or is the default
  terminal) or a per-user app (as SYSTEM or under cross-user elevation).
- **The code under test:** the report's machine facts include "Installer build", the build id of
  the checkout's `winget-app-install.ps1`, or, with `-UseOneLiner`, the build id the first run
  printed (`Installer build: <id>`), so the report names the code it tested.
- **How to run it:** from a checkout of the branch on the test machine, in an **administrator**
  window, starting under Windows PowerShell (a fresh PC has no PowerShell 7):
  `powershell -ExecutionPolicy Bypass -File .\e2e\Invoke-RealPcTestPlan.ps1`. It refuses unless
  elevated and asks you to confirm the machine is disposable (type the phrase, or pass
  `-ConfirmDisposableMachine` for unattended use). `-WhatIf` (or `-Plan`) prints exactly what it
  would change and changes nothing. `-IncludeWinGetClient` adds the Microsoft.WinGet.Client SYSTEM
  pass; `-Stage` / `-SkipStage` run a subset (with dependencies); `-UseOneLiner -Branch <name>` runs
  the production `irm | iex` one-liner instead of the checkout; `-TimeoutMinutes` (default 60) limits
  each install run.
- **How long:** about 30-60 minutes.
- **What to send back:** it writes a report (`report.md` and `report.txt`) and a zip to
  `%PUBLIC%\winget-app-setup-testplan-<timestamp>` (or a new or empty `-ReportPath`), and exits 0
  when every non-skipped row passed, 1 otherwise, 2 if it refused. It ends with the overall result,
  `report.txt`'s exact path, a line to paste into any PowerShell window that copies the report
  (`Get-Content -LiteralPath '<path>' -Raw -Encoding UTF8 | Set-Clipboard`), and the zip's exact
  path. Send the zip (or paste the report). **Privacy:** the report and the zip name this PC's
  accounts and their SIDs (the machine facts, `winget-info.txt`, the transcripts), so send them
  privately, or replace the names before you post them on a public issue or pull request (the
  privacy note under [Logs](#logs) says what to replace). A throwaway TightVNC test password for the
  manual viewer step is in `manual-steps.txt` in the `winget-app-setup-localsecrets-...` folder next
  to the report folder (the run prints its exact path; for the default report folder it is
  `winget-app-setup-localsecrets-<timestamp>`): do not send that one. Its name does not start with
  the report folder's, so a `winget-app-setup-testplan-*` wildcard cannot pick it up. The harness
  checks that neither the diagnostics bundle, the zip nor the report itself holds the password; when
  one does, it prints no copy line and says to send nothing. The uninstaller stage removes TightVNC,
  so to try a viewer, run with `-SkipStage Uninstaller`. The report's "Still to do by hand" section
  lists the items the harness cannot automate. `.github/workflows/real-pc-test-plan.yml` self-tests
  the harness end to end on a `windows-latest` runner.

## End-to-end monitoring (e2e tier 1)

The unit suite mocks every external call, so a real install is exercised by an end-to-end run
(`.github/workflows/e2e-install.yml`, issue #214) on GitHub-hosted `windows-latest` runners —
throwaway VMs by construction:

- **When it runs:** weekly (Mondays 06:00 UTC), on manual dispatch, and on pull requests. Every
  pull request starts the workflow. A `changes` job lets the four install jobs run only when the PR
  touches the product (`WingetAppSetup/**`, `build/**`, `winget-app-install.ps1`, `rmm/**`) or the e2e
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
  installer, and its second pass finds PowerShell 7 and relaunches. Before the first pass, every
  leg, the SYSTEM legs below included, uninstalls the catalog apps the runner image ships with
  (Google Chrome, 7-Zip and Git; `e2e/Remove-PreinstalledApps.ps1`), so the first pass really
  installs them. Every call there has a time limit (`winget list` 45 s, uninstall 150 s) and names
  `--source winget`, so a winget source that cannot open leaves an app 'unknown' rather than 'not
  installed'. Each app's result prints as soon as it is done, and an app that cannot be removed
  gets a warning annotation and is skipped by the first pass as already installed (the SYSTEM legs
  fail on it instead: see below).
- **The SYSTEM leg:** `e2e-install-system`, on a third VM, runs one pass the way Endpoint Central
  does, after the same removal of the preinstalled catalog apps. A one-shot scheduled task runs as
  SYSTEM and starts `rmm/Invoke-WingetAppSetup.ps1` with
  the 32-bit `%SystemRoot%\SysWOW64\WindowsPowerShell\v1.0\powershell.exe`, so the machine phase
  has to relaunch itself through Sysnative. It runs the checkout's installer (`-InstallerPath`,
  still SHA256-checked), never its pinned commit, on every trigger, the weekly run included.
  `e2e/Invoke-SystemInstallPass.ps1` checks the task's exit code: 0 and 3010 pass, 8 only for the
  missing `Microsoft.WindowsAppRuntime.1.8` when the installer could not try to install it, and 1
  only while `KNOWN_PLATFORM_INCOMPATIBLE` is non-empty and every app the run left failed is on that
  list. It also checks that the transcript says `Auto-updates: Configured` (or `Already present`)
  and that the run installed the framework once or did not need to; that the machine phase's
  `-rmm.log` shows the 64-bit relaunch, the SHA256 check and the exit code passed back unchanged;
  that the transcript says the run was SYSTEM; that `last-run.json` records the same exit code, a
  run that reached its summary, and Deferred entries that each have a package id and a reason and
  match the summary; and that nothing was installed per-user into SYSTEM's own profile (no new
  uninstall entry under `HKEY_USERS\S-1-5-18` and no new folder under either systemprofile's
  `AppData\Local\Programs`). It also checks every catalog app's entry in `last-run.json`, as the
  other legs check each app with `winget list`. The catalog and which apps apply come from the
  checkout's module, decided before the run the way the run as SYSTEM decides them: Windows
  Terminal's condition holds as SYSTEM, and an app with `msixName` counts as already there only
  when it is provisioned for every user. An app that applies must be `Installed` or `Skipped` as
  already there, and `Installed` for Chrome, 7-Zip and Git, which the job removes first
  (`e2e/Remove-PreinstalledApps.ps1`'s defaults). An app that does not apply must be `Skipped` with
  its `not applicable:` reason, and per-user work must be `Deferred` with its reason. `Failed`, any
  other `Deferred`, a missing entry, an entry for an app the catalog lacks, or a record that is not
  schema 1 fails the step. Apps on `KNOWN_PLATFORM_INCOMPATIBLE` are not checked. Unlike the other
  legs, an app the removal step could not remove fails this leg. The user phase is not run here: it
  would change the runner account's Windows Terminal settings.
- **The SYSTEM leg with Microsoft.WinGet.Client:** `e2e-install-system-winget-client`, on a fourth
  VM, runs the SYSTEM leg's pass twice through the machine phase with
  `-SystemInstallEngine WinGetClient`
  (`e2e/Invoke-SystemInstallPass.ps1 -SystemInstallEngine WinGetClient -PassCount 2`; see
  [Microsoft.WinGet.Client engine (opt-in)](#microsoftwingetclient-engine-opt-in)). Each pass makes
  every check of the SYSTEM leg. On top of those, it fails unless the machine phase logged the
  request, the module was ready at its pin (`WinGet client module: ready - ` with the pin's version
  and SHA256, and no `NOT READY` line), the `Install engine:` line and `last-run.json`'s
  `installEngine` name the module at its pin, each app the job removed has a
  `> Install-WinGetPackage -Id <id>` line, and no `> winget install` line appears. After the first
  pass, it looks up the removed apps with `winget list` as the runner account, a check that does
  not trust the engine's own detection. The second pass must take the module from the cache, find
  every app that applies already there, and not install the framework again. Before the passes, a
  step runs `build/Set-WingetClientModulePin.ps1 -Check` against the Gallery and saves its report;
  it cannot fail the job. The job passed on its first run, on 2026-10-06.
- **What it does:** the weekly run uses the one-liner above, against raw `main`, in both passes.
  Pull-request and dispatched runs install the checkout (the PR's merge commit, or the dispatched
  branch). The first pass pipes it to `iex` like the one-liner, and the second runs it with
  `-File` like a clone or RMM run, so both entry points get an un-mocked run before a change
  ships. In the 5.1 leg, the first pass's bootstrap downloads the installer from raw `main` again
  for its PowerShell 7 relaunch; on checkout runs that one download is answered with the checkout,
  so the PowerShell 7 half of the pass tests the change too. `e2e/Invoke-InstallPass.ps1` starts
  every pass and decides whether it passed: it must exit 0, or 3010 (OK, restart required).
  `windows-latest` ships without `Microsoft.WindowsAppRuntime.1.8`, but the installer now installs
  the pinned framework there, so both passes are expected to exit 0 with Winget-AutoUpdate set up.
  Exit 8 passes only when that pass's own transcript says
  `Auto-updates: NOT CONFIGURED - Microsoft.WindowsAppRuntime.1.8 is missing` and the installer
  could not try to install the framework (the run was not elevated, Windows or its architecture is
  not one the framework supports, or a framework was already provisioned); the verdict then quotes
  the transcript's `Windows App Runtime:` line with the reason. An install of the framework that
  started and then failed (download, checks or provisioning) fails the pass, as does 8 for any
  other reason or with no transcript to check. So does a `Windows App Runtime:` line that says the
  latest winget release needs a framework the installer's pinned one does not meet, whether a newer
  1.8 build or another family: every PC without that framework goes without Winget-AutoUpdate
  until the pin (`Get-WindowsAppRuntimePin`) moves, so the weekly run goes red and files its issue.
  The assertions check for the built-in framework requirement, not the one the run read from the
  latest winget release; a pass whose pin no longer meets that release has already failed.
  Exit 1 is tolerated only while `KNOWN_PLATFORM_INCOMPATIBLE` is non-empty, and the assertions
  then check that nothing outside that list failed. Any other code fails the pass with the
  installer's code. The second pass proves idempotence.
- **What it checks:** the shared assertion script
  `e2e/Assert-Install.ps1 -ExpectAllSkippedOnSecondRun` checks that every **applicable**
  `Get-DefaultAppCatalog` app resolves via `winget list` (exit-code classified) — the script
  decides each app's applicability on the runner with the installer's own rule
  (`Test-AppApplicability`: the `arch` list and the condition, through
  `Get-CatalogAppApplicability` in `e2e/TranscriptAssertions.ps1`), as it stood just before the
  pass whose transcript it reads: `e2e/Invoke-InstallPass.ps1 -ApplicabilityPath` records it before
  each pass, because the first pass's Windows Terminal step changes what Terminal's condition
  reads, and a record that is missing or cannot be read fails the
  `Applicability recorded before the latest pass` assertion. An app with neither
  an `arch` list nor a condition is always expected installed, and the module finding one not
  applicable fails the `Apps with no arch list or condition apply` assertion; not-applicable apps
  must instead show their `not applicable` skip line in the latest transcript — the WAU scheduled
  task exists and its version matches `Get-WauPin` (on a runner where
  `Microsoft.WindowsAppRuntime.1.8` is still missing after the run, because the installer could not
  install it, WAU must instead be absent and the transcript must say
  `Auto-updates: NOT CONFIGURED`), a transcript with the `Installer build` stamp
  exists, no app outside the skip list is still failed at the end of either pass (read from the
  summary's `Failed` row and every failure line the retry pass did not recover; a transcript with no
  summary fails), and every applicable app is Skipped on the second pass, which also must not
  install the framework again. In pull-request and dispatched runs,
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
  manufacturer condition ([#217](https://github.com/J-MaFf/winget-app-setup/issues/217)) and
  `arch` list gate it in the product itself, so the non-Dell runners exercise the gating for real
  on every run. The runners are x64, so the ARM64 side of the Reader split and of the Dell gate
  is not exercised.
- **Not covered yet:** Winget-AutoUpdate's own update run (the installer now installs
  `Microsoft.WindowsAppRuntime.1.8` and WAU on `windows-latest`, but no step starts WAU's task and
  checks that winget still starts afterwards), the catalog's own
  PowerShell install (`Install-PowerShellLatest`: PowerShell 7 is preinstalled in one leg and
  installed by the bootstrap in the other), the Endpoint Central user phase, the fleet health probe
  and the at-logon fix, a TightVNC password, the uninstaller, a time budget that runs out (exit
  code 9), an ARM64 PC, cross-user elevation (tier 2, below), and the Microsoft.WinGet.Client
  engine's fallback to `winget.exe` and its rarer results (an installer's 3010, an unknown id,
  Group Policy), which only the unit tests cover.
- **Where the evidence lands:** transcripts are written on the runner under
  `%ProgramData%\winget-app-setup\logs` (the same place as production runs) and always uploaded
  as the `e2e-install-transcripts` artifact (`e2e-install-transcripts-windows-powershell` for the
  5.1 leg, which also holds its `-bootstrap` transcripts, `e2e-install-transcripts-system` for
  the SYSTEM leg, with the machine phase's `-rmm.log` and `last-run.json`, and
  `e2e-install-transcripts-system-winget-client` for the SYSTEM leg with Microsoft.WinGet.Client,
  with the same files). `e2e/Collect-Diagnostics.ps1` runs in
  Windows PowerShell 5.1 before the first pass, after it and at the end of the job. It records the
  pwsh versions, the App Installer and `Microsoft.WindowsAppRuntime*` AppX packages registered for
  any user or provisioned, and the `\WAU\` tasks with their last run. The end-of-job snapshot adds
  MsiInstaller and RestartManager events, AppX deployment errors and warnings,
  Winget-AutoUpdate's logs, and the newest 10 `WinGetCOM-*.log` files of the WinGet engine that
  Microsoft.WinGet.Client runs as SYSTEM (`winget-engine-logs`). A missing source is noted and the
  script still exits 0, so it never fails the job. The snapshots, plus the assertion output saved
  by the assertions step, are always uploaded as the `e2e-diagnostics` artifact
  (`e2e-diagnostics-windows-powershell` for the 5.1 leg, `e2e-diagnostics-system` for the SYSTEM
  leg, and `e2e-diagnostics-system-winget-client`, which also holds the pin check's report
  `pin-check.txt`, for the SYSTEM leg with Microsoft.WinGet.Client).
- **On failure:** when a scheduled run or a run dispatched on `main` fails, times out or is
  cancelled in any leg, a separate `report-failure` job on `ubuntu-latest` downloads the
  artifacts. It creates a GitHub issue titled `E2E install run failed`, or comments on an existing
  open one. The issue lists the run URL and which installer ran, then has one section per leg; a
  leg that passed says so. For a leg that did not succeed it shows the steps that did not succeed
  and how long each ran, the assertion PASS/FAIL table, the last 50 lines of the earliest and
  latest install transcripts, the last 50 lines of the latest Windows PowerShell 5.1 bootstrap
  transcript (5.1 leg), the last 30 lines of the latest machine phase log (SYSTEM legs), and the
  diagnostics snapshots. The same text goes to the run's summary
  page. The job runs outside the Windows jobs, so it still reports a run that lost PowerShell 7 or
  hit its time limit. Pull-request runs and runs dispatched on another branch never file the
  issue: they test unmerged code, and their result shows on the PR or the run. The assertions also
  run after a failed install pass (the idempotence checks only when the second pass ran). Removing
  the preinstalled apps has a 15-minute limit (20 in the 5.1 leg, which also removes PowerShell 7),
  each install pass 35 minutes and the assertions 40, under the job's 145 (150 in the 5.1 leg);
  the SYSTEM leg's pass has 45 minutes under its job's 80, and the Microsoft.WinGet.Client leg's
  pin check 10 minutes and its two passes 100 under its job's 145. So a hung step fails at its
  own limit while the diagnostics and uploads still run.
- **Trigger manually:** `gh workflow run e2e-install.yml` tests `main`.
  `gh workflow run e2e-install.yml --ref <branch>` installs that branch's checkout, so a change
  can be tested before it merges. The branch must already contain this version of the workflow,
  because `--ref` also runs that branch's copy of the workflow, and an older copy still installs
  raw `main`. Watch with `gh run list --workflow e2e-install.yml` / `gh run watch <run-id>`.

Tier 2 ([#215](https://github.com/J-MaFf/winget-app-setup/issues/215)) will reuse
`e2e/Assert-Install.ps1` for a cross-user elevation run on a snapshot-rollback VM.

## Project layout (for contributors)

The installer's logic lives in the **`WingetAppSetup` PowerShell module** under `WingetAppSetup/`
(`Public/` for the entry points and the run's main steps, `Private/` for their helpers; the
module exports every function, so moving one between the two folders changes nothing else). The
single-file `winget-app-install.ps1` is **generated** from that module so the `irm | iex`
one-liner keeps working — do not edit it by hand. It leaves out the comments of the module, which
are about half of it, and of its entry block (`build/fragments/tail.ps1`), so read them in the
source; a change to one of those comments alone leaves the installer, and its build id, unchanged.
The uninstaller, `winget-app-uninstall.ps1`, is generated the same way from
`build/fragments/uninstall-head.ps1`, the module and `build/fragments/uninstall-tail.ps1`, so that
its elevated run can be a checked copy of one file. It has no build id.

`rmm/` holds the Endpoint Central scripts (see
[Endpoint Central and other RMM tools](#endpoint-central-and-other-rmm-tools)). They are not
generated and load nothing from the module or from beside them, because Endpoint Central pushes one
file. So they repeat the few parts of the installer's logic they need: the machine-wide
`winget.exe` order, the Windows App Runtime requirement, the at-logon trigger rule, the run-record
trust check and the format of the time budget's `-RunDeadlineUtc`. `tests/RmmFleetHealth.Tests.ps1`
and `tests/RmmWrapper.Tests.ps1` check those parts against the module's own functions
(`Get-MachineWingetCandidate`, `Get-WindowsAppRuntimeStatus`, `Format-ScheduledTaskTrigger`,
`Disable-WauLogonTrigger`, `Get-RunRecordTrustProblem`, `Format-RunRecordTime`,
`Resolve-InstallerRunBudget`), so a change to one of them fails there until the scripts follow.
They also keep the helpers the scripts share identical, keep the two phases' pins equal, and check
that every script stays ASCII-only Windows PowerShell 5.1 code. `build/Set-RmmInstallerPin.ps1`
sets the pins.

The opt-in Microsoft.WinGet.Client engine of runs as SYSTEM lives in
`WingetAppSetup/Private/WingetClientModule.ps1` (the pin, the download and its checks, and the
script each child `pwsh` runs) and `WingetAppSetup/Private/WingetClientEngine.ps1` (the requests
and how their results map onto winget's result codes). `build/Set-WingetClientModulePin.ps1`
checks the pin against the PowerShell Gallery (`-Check`) or moves it (`-Write`; see
[Microsoft.WinGet.Client engine (opt-in)](#microsoftwingetclient-engine-opt-in)).

After changing anything under `WingetAppSetup/` or `build/fragments/`, regenerate both scripts and
commit them with the change:

```powershell
pwsh -File .\build\Build-WingetInstallScript.ps1
```

The build writes neither script unless every guard passes on both. `-OutputPath` and
`-UninstallerOutputPath` write them elsewhere; the uninstaller defaults to the folder of
`-OutputPath`.

Verify the committed scripts are in sync with the module (useful in CI / pre-commit):

```powershell
pwsh -File .\build\Build-WingetInstallScript.ps1 -Check
```

Run the test suite (one `<Area>.Tests.ps1` per module file under `tests/`, plus
`EntryPoint.Tests.ps1`, `TestHarness.Tests.ps1`, `BuildGuards.Tests.ps1`, the `Rmm*.Tests.ps1`
files and the `E2E*.Tests.ps1` files for the entry point, the suite's own loading rules, the build
guards and pre-commit hook, the `rmm/` scripts and the pin helper, and the `e2e/` scripts, with
sample transcripts and a sample `last-run.json` of the SYSTEM run (`system-last-run.json`, to
update when the catalog changes) in `tests/fixtures/e2e`, the sample logs the diagnostics
bundle's redaction is tested on in `tests/fixtures/diagnostics`, and the sample results of the
Microsoft.WinGet.Client engine's child `pwsh` in `tests/fixtures/winget-client`; each loads the
module directly via `tests/TestHelpers.ps1`, and none dot-sources a generated script):

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
`Get-Command winget`. The engine's cmdlets (`Get-WinGetVersion`, `Get-WinGetPackage`,
`Install-WinGetPackage`) run only in a child `pwsh`, through `Invoke-WingetClientRequest`; the
pinned module is never loaded into the installer's own process.
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
`WingetAppSetup/`, `build/`, a `.psd1` manifest, or either generated script
(`winget-app-install.ps1`, `winget-app-uninstall.ps1`), and if
`pwsh` is not on `PATH` it prints a warning and lets the commit through — CI enforces the same
check on every push and pull request, so nothing ships unverified either way. It checks the
staged files (exported to a temporary directory with `git checkout-index`), not the working tree,
so a module change staged without its regenerated scripts is blocked even when the working tree
was rebuilt. On failure it prints how to fix it: re-run the build and stage both regenerated
scripts together with your module change.

> **If you also use the beads hooks:** `bd hooks install` (opt-in — the shims under
> `.beads/hooks/` are inert by default) writes its hooks into `.git/hooks/`, and setting
> `core.hooksPath` makes git ignore `.git/hooks/` entirely, silently disabling them. If you
> want both, leave `core.hooksPath` unset and instead add a line to your
> `.git/hooks/pre-commit` that invokes `.githooks/pre-commit` — the drift check runs the same
> way from either location.

### Why `winget-app-install.ps1` cannot drift from the module

The generated installer and uninstaller are guaranteed to match the `WingetAppSetup` module by a
stack of guards, most of which run in both build and `-Check` modes of
`build/Build-WingetInstallScript.ps1`. Every guard runs on both generated scripts,
`winget-app-install.ps1` and `winget-app-uninstall.ps1`; the build writes neither unless both pass,
and a guard's report names the file it is about: the generated script, or, for the comment check,
the source file.

1. **Byte-compare with BOM rejection** — `-Check` regenerates each script in memory and compares
   it (LF-normalized) against the committed file byte for byte (an ordinal comparison, so a hand
   edit that changes only letter case, or adds an invisible character such as U+00AD, fails it
   too); it also inspects the raw bytes and rejects a leading UTF-8 BOM that a text comparison
   would silently strip ([#183](https://github.com/J-MaFf/winget-app-setup/issues/183)).
2. **Assembled-script parse guard** — the assembled script is parsed and any syntax error
   fails the build with line/column details, so an unbalanced brace in a module file can no
   longer ship a broken installer ([#183](https://github.com/J-MaFf/winget-app-setup/issues/183)).
   This guard and the 5.1 guards below also name the source file and line behind each line they
   report, such as `[WingetAppSetup/Private/Jsonc.ps1:120]`, because the assembled script's line
   numbers match no file.
3. **Comment removal check** — the build leaves the comments of the module and of
   `build/fragments/tail.ps1` (the entry block; for the uninstaller,
   `build/fragments/uninstall-tail.ps1`) out of the generated scripts (they are about half of the
   module, and every `irm | iex` run downloads the file; review finding P3-53). It removes only the
   tokenizer's comment tokens that end their line, so a `#` inside a string or regex stays, and it
   keeps `build/fragments/head.ps1` and `build/fragments/uninstall-head.ps1` (the scripts' help)
   as they are. It then compares the code tokens of each module file and of each tail fragment
   before and after, case-sensitively, and fails the build if removing the comments changed any of
   them.
4. **AST undefined-reference guard** — every hyphenated command the assembled script invokes
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
5. **Windows PowerShell 5.1 parse-safety guards** — 5.1 parses the whole installer before it
   runs any of it, so the file must stay 5.1-parseable even though the install itself runs under
   PowerShell 7, and the uninstaller's elevated window runs entirely under 5.1. Syntax that only
   PowerShell 7 parses (`??`, `??=`, `?.`, `?[`, the ternary `?:`, the `&&` / `||` pipeline
   chains, the background operator `&` as in `Get-Process &`, and `clean { }` blocks) fails the
   build; the guard reads token kinds and the AST, so the same
   characters inside strings, comments and regexes are fine, and so is the call operator
   `& $cmd`. And every non-comment token of the assembled script must be pure ASCII. The
   installer ships as BOM-less UTF-8, which 5.1 decodes as ANSI: a multi-byte character inside a
   string literal misdecodes (an em dash's 0x94 byte becomes a string-terminating curly quote)
   and cascades into parser errors before the version dispatch can run. Keeping code tokens ASCII keeps the file
   5.1-parseable so 5.1 reaches the version check and runs the PowerShell 7 bootstrap
   (find-or-install `pwsh`, then relaunch — [#225](https://github.com/J-MaFf/winget-app-setup/issues/225));
   comments are exempt because misdecoded bytes there cannot change tokenization
   ([#210](https://github.com/J-MaFf/winget-app-setup/issues/210)).
6. **Content-derived build id** (the installer only: the uninstaller keeps no transcript, and its
   elevated relaunch checks the file's SHA256) — the banner and `$script:InstallerBuildId` are
   stamped with `<module version>+<8-hex SHA256 fragment of the whole generated script>` (hashed
   with the id slots blanked, so a change to `build/fragments/head.ps1` or to the code of
   `tail.ps1` changes the id too), derived from content only (never git metadata or timestamps) so
   rebuilding the same tree is byte-identical and the `-Check` byte-compare stays deterministic;
   transcripts log the id at startup so a log identifies the exact installer build
   ([#189](https://github.com/J-MaFf/winget-app-setup/issues/189)).
7. **CI enforcement** — `.github/workflows/windows-tests.yml` runs `-Check` on every push to
   `main` and on every pull request, so drift fails CI instead of shipping
   ([#156](https://github.com/J-MaFf/winget-app-setup/issues/156)).
8. **Local pre-commit hook** — `.githooks/pre-commit` (above) runs the same `-Check`, against
   the staged files, before a commit that touches the module, the build, a manifest, or either
   generated script, catching drift before it is even committed
   ([#211](https://github.com/J-MaFf/winget-app-setup/issues/211)).

The module manifest has no export list to drift: `FunctionsToExport` is `'*'`, so
`e2e/Assert-Install.ps1` and `e2e/Invoke-SystemInstallPass.ps1`, which import the module through
it, get every function (the installer and the uninstaller are generated files and do not read the
manifest). There used to be an explicit list that the build checked against `Public/*.ps1`
([#191](https://github.com/J-MaFf/winget-app-setup/issues/191): a function missing from it failed
only at the uninstaller's prompt); `tests/EntryPoint.Tests.ps1` now checks that a manifest import
exports every function the module defines.
