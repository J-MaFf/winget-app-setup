# Winget App Setup

A one-line guide for running the installer.

## Run the installer

From the repository root, execute (after cloning):

```powershell
powershell -ExecutionPolicy Unrestricted -File .\winget-app-install.ps1
```

No download/clone needed (one-line-run):

```powershell
Set-ExecutionPolicy Unrestricted -Scope Process -Force; irm "https://raw.githubusercontent.com/J-MaFf/winget-app-setup/refs/heads/main/winget-app-install.ps1" | iex
```

The script will trust the required Winget sources, elevate if necessary, and install or update the curated app list. Repeat step 1 anytime you open a new PowerShell window before running it.

## Unattended runs

Pass `-NonInteractive` to suppress all interactive prompts (the elevation pause, the grid-view
prompt, and the final "press any key") for RMM, CI, or scheduled-task use:

```powershell
powershell -ExecutionPolicy Unrestricted -File .\winget-app-install.ps1 -NonInteractive
```

Non-interactive mode is also auto-detected when the session is non-interactive (e.g.
`pwsh -NonInteractive`, services, scheduled tasks) or stdin is redirected.

### Exit codes

| Code | Meaning |
|------|---------|
| 0 | Success — all apps installed or already present |
| 1 | One or more apps failed to install (also: pre-flight system checks failed, or elevation unavailable under remote execution) |
| 2 | Winget is unavailable and could not be installed |
| 3 | App-definition validation failed, or no valid app definitions remain |

## Logs

Every run writes a full transcript to
`%ProgramData%\winget-app-setup\logs\install-<yyyyMMdd-HHmmss>.log` (dry runs get a `-whatif`
suffix, e.g. `install-20260708-143000-whatif.log`). The path is printed at startup and repeated
with the final summary. ProgramData is used — rather than the elevating account's `%TEMP%` — so
the log survives cross-user elevation and can be collected after a failed install on a remote
machine. If the transcript cannot be started, the installer warns and continues: logging never
blocks an install.

Each transcript begins with an `Installer build:` line carrying the content-derived build id
(`<module version>+<8-char SHA256 fragment of the assembled functions>`) stamped by
`build/Build-WingetInstallScript.ps1`, so you can tell exactly which installer build produced a
given log.

## Automatic updates

Ongoing updates are handled by [Winget-AutoUpdate (WAU)](https://github.com/Romanitho/Winget-AutoUpdate),
which the installer sets up automatically (a pinned, SHA256-verified version). WAU runs as SYSTEM on a
weekly schedule (2 AM) and updates installed apps machine-wide, plus a user-context pass for the
logged-on user — which avoids the cross-user `0x80073d19` problems a per-user scheduled task hits.
WAU's own self-update is disabled so the version stays pinned; bump it via `Get-WauPin` in
`WingetAppSetup/Public/WingetAutoUpdate.ps1`. `winget-app-uninstall.ps1` removes WAU (and any legacy
scheduled-update task from older versions).

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

Run the test suite (one `<Area>.Tests.ps1` per module file under `tests/`; each loads the
module directly via `tests/TestHelpers.ps1`):

```powershell
Invoke-Pester .\tests
```
