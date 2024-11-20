# InstallSoftware.ps1

This script installs the following programs from winget:

- 7-zip
- TightVNC
- Adobe Acrobat Reader 64 Bit
- Google Chrome
- Google Drive
- Dell Command Update (Universal)
- PowerShell
- Windows Terminal

## Table of Contents

- [Installation](#installation)
- [Usage](#usage)

## Installation

### PowerShell Gallery (Best)

```powershell
Install-Script -Name InstallSoftware -Force
```

### Clone the Repository

Another option is to Clone the repository to your local machine:

```powershell
https://github.com/J-MaFf/winget-app-setup.git
```

## Usage

Use the command `InstallSoftware` to run the script from any directory (If installed via PowerShell Gallery). If not, you must provide the full path or open your shell in the apropriate directory to the script to run.
