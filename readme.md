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
