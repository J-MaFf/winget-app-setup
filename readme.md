# Winget App Setup

A one-line guide for running the installer.

## Run the installer

From the repository root, execute (after cloning):

```powershell
powershell -ExecutionPolicy Unrestricted -File .\winget-app-install.ps1
```

No download/clone needed (one-line-run):

```powershell
Set-ExecutionPolicy Unrestricted -Scope Process; irm "https://raw.githubusercontent.com/J-MaFf/winget-app-setup/refs/heads/main/winget-app-install.ps1" | iex
```

The script will trust the required Winget sources, elevate if necessary, and install or update the curated app list. Repeat step 1 anytime you open a new PowerShell window before running it.

## Scheduled and on-demand update options

- `-EnableScheduledUpdates` enables a weekly (Sunday 2:00 AM) or daily scheduled update check
- `-DisableScheduledUpdates` removes the scheduled task
- `-CheckForUpdates` runs an immediate update check for installed applications
- `-AutoInstallUpdates` auto-installs updates when used with `-CheckForUpdates` or `-EnableScheduledUpdates`
- `-UpdateFrequency Weekly|Daily` selects the schedule frequency (default: `Weekly`)

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

Run the test suite (loads the module directly):

```powershell
Invoke-Pester .\Test-WingetAppInstall.Tests.ps1
```
