# Winget App Setup

A one-line guide for running the installer.

## Run the installer

From the repository root execute:

```powershell
powershell -ExecutionPolicy Unrestricted -File .\winget-app-install.ps1
```

The script will trust the required winget sources, elevate if necessary, and install or update the curated app list. Repeat step 1 anytime you open a new PowerShell window before running it.
