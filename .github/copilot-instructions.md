# GitHub Copilot Custom Instructions

This file provides custom instructions for GitHub Copilot when working on this repository. These guidelines ensure consistency, maintainability, and adherence to project standards.

## Overview

This repository provides PowerShell automation for managing Windows applications using the winget package manager. When contributing code or making changes, follow the patterns, conventions, and practices documented below.

## Contributing Guidelines

When working on code in this repository:

- **Branching Strategy**: 
  - **Never commit directly to main branch**
  - Create a new feature branch with a descriptive name (e.g., `feature/winget-update`, `bugfix/install-checks`, `docs/update-docs-v1.0.0`)
  - Use existing branches if the change aligns with their purpose
  - Branch naming convention: `<type>/<description>` (type: feature, bugfix, docs, refactor, etc.)
  - Submit changes via pull request for review before merging to main
- **Minimal Changes**: Make the smallest possible changes to achieve the goal
- **Preserve Working Code**: Never delete or modify working code unless absolutely necessary
- **Test Thoroughly**: Run Pester tests after making changes: `Invoke-Pester -Path .\Test-WingetAppInstall.Tests.ps1 -Output Detailed`
- **Follow Existing Patterns**: Match the coding style and patterns already present in the codebase
- **Document Changes**: Update comments and documentation when changing functionality
- **Validate Scripts**: Test scripts manually before committing, especially admin elevation and winget operations

## Project Context
- **Purpose**: PowerShell automation for installing/uninstalling Windows applications via winget
- **Key Components**: PowerShell scripts using winget package manager
- **Architecture**: Script-based with shared utility functions and consistent error handling patterns
- **Launcher Script**: `launch.ps1` handles execution policy bypass - users should run this instead of calling scripts directly

### Baseline Application Set
- 7-Zip (`7zip.7zip`)
- TightVNC (`GlavSoft.TightVNC`)
- Adobe Acrobat Reader (`Adobe.Acrobat.Reader.64-bit`)
- Google Chrome (`Google.Chrome`)
- Google Drive (`Google.GoogleDrive`)
- Git (`Git.Git`)
- Bulk Crap Uninstaller (`Klocman.BulkCrapUninstaller`)
- Dell Command Update (`Dell.CommandUpdate.Universal`)
- PowerShell (`Microsoft.PowerShell`)
- Windows Terminal (`Microsoft.WindowsTerminal`)

## Coding Style & Conventions

### PowerShell Specific
- **Indentation**: Tabs (not spaces)
- **Naming**: PascalCase for global variables/parameters, camelCase for internal variables
- **Functions**: Use comment-based help with `.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER` blocks
- **Error Handling**: Try-catch blocks with specific error messages and result tracking arrays
- **Administrator Checks**: Always include admin privilege verification that relaunches script elevated (prefer Windows Terminal when available)

### Winget Integration Patterns
- **App Definition**: Use array of hash tables: `@(@{name = 'Publisher.AppName'})`
- **Command Flags**: CRITICAL - Flag usage depends on command type:
  - **Source commands** (`winget source list`, `winget source reset`): Use `--disable-interactivity` (NOT `--accept-source-agreements`)
  - **Package commands** (`winget list`, `winget install`): Use `--accept-source-agreements` and `--accept-package-agreements`
  - Using wrong flags causes "source agreements not agreed to" errors
- **Timeout Protection**: Wrap all winget commands in `Start-Process` with timeout (30s for source ops, 15s for package ops) to prevent hanging from interactive prompts
- **Source Trust**: Verify and trust 'winget' and 'msstore' sources before operations using `--disable-interactivity` flag
- **Installation Check**: Use `winget list --exact --id $app.name --accept-source-agreements` to check if app is installed
- **Result Tracking**: Maintain separate arrays for `$installedApps`, `$skippedApps`, `$failedApps`

### Output & Display
- **Table Formatting**: Use `Write-Table` function with PowerShell's built-in `Format-Table -AutoSize` for result summaries
- **Interactive GUI**: Automatically prompts user to use `Out-GridView` when available via `-PromptForGridView $true` parameter
- **Manual Override**: Can force GUI mode with `-UseGridView $true` parameter (skips prompt)
- **Graceful Fallback**: Automatically falls back to text output when Out-GridView is unavailable (Server Core, remote sessions)
- **Messaging Helpers**: Always use helper functions instead of direct `Write-Host` calls for consistency
  - `Write-Info`: Blue for informational/action messages (e.g., "Installing: AppName", "Checking for updates...")
  - `Write-Success`: Green for success messages (e.g., "Successfully installed: AppName")
  - `Write-WarningMessage`: Yellow for warnings/skips (e.g., "Skipping: AppName (already installed)")
  - `Write-ErrorMessage`: Red for errors (e.g., "Failed to install: AppName")
  - `Write-Prompt`: Blue for user prompts (e.g., "Press any key to exit...")
- **Summary Display**: Always show final table with operation counts

## Key Functions to Reuse

### Messaging Helper Functions
- `Write-Info()`: Display informational/action messages in blue (replaces `Write-Host ... -ForegroundColor Blue`)
- `Write-Success()`: Display success messages in green (replaces `Write-Host ... -ForegroundColor Green`)
- `Write-WarningMessage()`: Display warning/skip messages in yellow (replaces `Write-Host ... -ForegroundColor Yellow`)
- `Write-ErrorMessage()`: Display error messages in red (replaces `Write-Host ... -ForegroundColor Red`)
- `Write-Prompt()`: Display user prompt messages in blue (replaces `Write-Host ... -ForegroundColor Blue` for prompts)

### Core Utility Functions
- `Test-AndInstallWingetModule()`: Ensure the Microsoft.WinGet.Client PowerShell module is installed and usable
- `Test-AndInstallWinget()`: Check winget availability and install if missing
- `Test-Source-IsTrusted()`: Verify winget source trust status
- `Set-Sources()`: Add and trust winget sources
- `Add-ToEnvironmentPath()`: Add paths to user/system PATH
- `ConvertTo-CommandArguments()`: Parse command strings with quoted arguments
- `Write-Table()`: Display formatted tables using Format-Table or Out-GridView (with optional `-UseGridView` and `-PromptForGridView` parameters)
- `Invoke-WingetCommand()`: Execute winget commands with exit code capture, error code mapping, and output parsing. Returns hashtable with `ExitCode` and `ExitMessage`. Automatically reports failures to `$failedApps` when exit code is non-zero and no output patterns match.
- `Restart-WithElevation()`: Relaunch the script with elevation, preferring Windows Terminal before falling back to classic PowerShell windows

**Note**: Execution policy handling is now managed by the `launch.ps1` launcher script instead of within the main scripts.

#### Exit Code Handling in Invoke-WingetCommand
- Captures `$LASTEXITCODE` after each winget execution
- Maps common winget exit codes (0, -1978335189, -1978335191, -1978335192, -1978335212, -1978335213, -1978335215, -1978335216, -1978335221, -1978335226) to meaningful messages
- Returns hashtable: `@{ ExitCode = <int>; ExitMessage = <string> }`
- Automatically adds failures with actionable diagnostics when exit code indicates error but output parsing finds no matches
- Backward compatible - callers can ignore the return value if only using array references

## Workflow Patterns
1. **Launcher Script**: Users run `launch.ps1` to bypass execution policy restrictions
2. **Admin Check**: Verify elevated privileges, relaunch if needed
3. **Winget Tooling Remediation**: Ensure winget CLI (via `Test-AndInstallWinget`) and Microsoft.WinGet.Client module (`Test-AndInstallWingetModule`) are available
4. **PATH Setup**: Add script directory to user PATH
5. **Source Verification**: Ensure winget sources are trusted
6. **App Processing**: Loop through app array with existence checks
7. **Result Summary**: Display formatted table of all operations
8. **User Interaction**: Keep console open with `[System.Console]::ReadKey($true)`

## Common Tasks
- **New App Addition**: Add to `$apps` array using format `@{name = 'Publisher.AppName'}`
- **Error Testing**: Include fake packages like `@{name = 'Fake.Package'}` for testing
- **Update Operations**: Use `winget upgrade --all` with JSON parsing fallback
- **PATH Management**: Use `Add-ToEnvironmentPath` for script accessibility

## Security Practices
- **No Hardcoded Secrets**: Never commit API keys, passwords, or credentials to the repository
- **Execution Policy**: Use launcher script (`launch.ps1`) to bypass restrictions securely. Do not attempt to change execution policies in main scripts.
- **Input Validation**: Always validate application names and package IDs before passing to winget commands
- **Administrator Privileges**: Only request elevation when necessary; clearly document when admin rights are required
- **Source Trust**: Verify and trust only official winget sources (`winget`, `msstore`)
- **Error Messages**: Avoid exposing sensitive system information in error messages or logs
- **PowerShell Best Practices**: Follow Microsoft's PowerShell security guidelines for script signing and execution

## Testing Approach
- **Comprehensive Test Suite**: Use Pester for unit testing with comprehensive coverage in `Test-WingetAppInstall.Tests.ps1`
- **Test Coverage**: All functions and main script logic are tested, including edge cases and error scenarios
- **Running Tests**: Execute tests with `Invoke-Pester -Path .\Test-WingetAppInstall.Tests.ps1 -Output Detailed`
- **Adding New Tests**: When creating new functions or functionality in `winget-app-install.ps1`, add corresponding tests to `Test-WingetAppInstall.Tests.ps1`
- **Mocking Strategy**: Use Pester mocks for external commands (winget, Get-Command, etc.) to test logic without real system changes
- **Error Scenarios**: Test with non-existent packages, network failures, and permission issues

## Deployment
- **Current State**: Local repository only - not yet published to PowerShell Gallery
- **PowerShell Gallery Preparation**:
  - Add proper PSScriptInfo metadata to script files (already present in winget-app-install.ps1)
  - Create module manifest (.psd1) for `InstallSoftware` command (as specified in README.md)
  - Test script publishing with `Publish-Script -Path .\winget-app-install.ps1 -NuGetApiKey $apiKey`
  - Update README.md with PowerShell Gallery installation instructions
- **Local Execution**: Run from cloned repository with full paths
- **Admin Requirements**: All scripts require administrator privileges

## Architecture Insights

### Big Picture Architecture
- **Script-Based Design**: Two primary scripts (`winget-app-install.ps1`, `winget-app-uninstall.ps1`) with shared patterns
- **Modular Functions**: Reusable utility functions for common operations (PATH management, source trust, table display)
- **Result Tracking Pattern**: Consistent use of separate arrays for different operation outcomes
- **Fallback Mechanisms**: Multiple approaches for operations (PowerShell module vs CLI fallback)

### Data Flow Patterns
- **App Array Processing**: Central `$apps` array drives all operations
- **Existence Checking**: Pre-flight checks using `winget list` before install/uninstall operations
- **Output Parsing**: Capture and parse winget command output for success/failure determination
- **State Tracking**: Maintain operation state in arrays throughout execution

### Cross-Component Communication
- **Shared App Lists**: Same application definitions used across install/uninstall scripts
- **Consistent Result Arrays**: `$installedApps`, `$skippedApps`, `$failedApps` pattern used universally
- **Common Utility Functions**: Shared functions like `Write-Table()` and `Test-Source-IsTrusted()`

## Developer Workflows

### Critical Commands & Operations
- **Admin Elevation**: `Restart-WithElevation -PowerShellExecutable $psExecutable -ScriptPath $PSCommandPath` (helper prefers `wt.exe` when present, otherwise falls back to the classic `Start-Process` pattern)
- **Source Trust Check**: `winget source list --disable-interactivity` and pattern matching for trusted sources
- **Source Reset**: `winget source reset --force --disable-interactivity` (wrapped in Start-Process with 30-second timeout)
- **App Installation**: `winget install -e --accept-source-agreements --accept-package-agreements --id $app.name`
- **Existence Verification**: `winget list --exact --id $app.name --accept-source-agreements` (wrapped in Start-Process with 15-second timeout)
- **Update Detection**: `Get-WinGetPackage | Where-Object IsUpdateAvailable` (PowerShell module) or `winget upgrade` (CLI)
- **Table Display**: `Write-Table -Headers $headers -Rows $rows -PromptForGridView $true` (prompts user) or `Write-Table -Headers $headers -Rows $rows -UseGridView $true` (forces GUI mode)

### Timeout Mechanisms & Process Management
Winget commands can hang indefinitely when prompting for source agreements in non-interactive script execution. All potentially hanging commands must use `Start-Process` with timeout protection:

```powershell
# Example: 30-second timeout for source operations
$process = Start-Process -FilePath 'winget' `
    -ArgumentList 'source', 'reset', '--force', '--disable-interactivity' `
    -NoNewWindow -PassThru `
    -RedirectStandardOutput "$env:TEMP\winget_output.txt" `
    -RedirectStandardError "$env:TEMP\winget_error.txt"

if (-not $process.WaitForExit(30000)) {
    Write-WarningMessage "Command timed out. Terminating..."
    $process.Kill()
    # Clean up temp files
}

# Example: 15-second timeout for package operations
$listProcess = Start-Process -FilePath 'winget' `
    -ArgumentList 'list', '--exact', '--id', $app.name, '--accept-source-agreements' `
    -NoNewWindow -PassThru `
    -RedirectStandardOutput "$env:TEMP\winget_list_output.txt"

if (-not $listProcess.WaitForExit(15000)) {
    Write-WarningMessage "List command timed out for $($app.name)"
    $listProcess.Kill()
}

$output = Get-Content "$env:TEMP\winget_list_output.txt" -ErrorAction SilentlyContinue
Remove-Item "$env:TEMP\winget_list_output.txt" -ErrorAction SilentlyContinue
```

**Key Points:**
- Use `-NoNewWindow` and `-PassThru` for non-visible execution and process reference
- Redirect output to temp files to prevent console blocking
- Always clean up temp files in finally blocks or after processing
- Timeout values: 30s for source operations, 15s for package operations
- Check exit code after timeout for proper error handling

### Build & Test Workflows
- **Function Testing**: Extract and test individual functions in separate files
- **Error Scenario Testing**: Use fake packages like `@{name = 'Fake.Package'}` to test error handling
- **Output Validation**: Test table formatting with `Write-Table()` function
- **Integration Testing**: Full script execution with real winget commands
- **Timeout Testing**: Test with hanging commands to verify timeout protection works

### Interaction Guidelines
- **Explain Before Acting**: Always explain the purpose and impact of any action before executing terminal commands, installing packages, or making system changes
- **Seek Confirmation**: For potentially disruptive actions (installations, system modifications), ask for user confirmation before proceeding
- **Provide Context**: When suggesting commands or changes, include why they're needed and what they accomplish

## Integration Points & Dependencies

### External Dependencies
- **Winget Package Manager**: Core dependency for all operations
- **Microsoft.WinGet.Client Module**: Optional PowerShell module for enhanced functionality
- **Microsoft App Installer**: Required for winget functionality
- **PowerShell Execution Policy**: Must allow script execution

### System Integration
- **Administrator Privileges**: Required for package installation/uninstallation
- **Environment PATH**: Modified to include script directory for accessibility
  - **Windows PATH Limit**: 2048 character limit - Add-ToEnvironmentPath validates this before updating current session
  - Graceful handling when limit is exceeded (persistent environment still updated, current session skips)
- **Winget Sources**: 'winget' and 'msstore' sources must be trusted using `--disable-interactivity` flag
- **User PATH**: Script directory added for command-line accessibility

## Documentation Maintenance

### When to Update Documentation

Update both README.md and copilot-instructions.md when making **significant changes**:

- **New Scripts**: Adding new PowerShell scripts or major functionality
- **Architecture Changes**: Modifying core patterns, functions, or workflow processes
- **New Features**: Adding substantial capabilities (update management, new app categories, etc.)
- **Breaking Changes**: Changes that affect how users interact with the scripts
- **Major Refactoring**: Restructuring code that changes the project's fundamental approach
- **New Dependencies**: Adding external tools, services, or package managers
- **Deployment Changes**: Publishing to PowerShell Gallery or changing distribution method

### Documentation Update Process

1. **Analyze the Codebase**: Read through all scripts to understand current functionality
2. **Identify Key Changes**: Determine what new patterns, features, or conventions were introduced
3. **Update README.md**: Rewrite comprehensively to reflect current state
4. **Update copilot-instructions.md**: Add new patterns, functions, and conventions discovered
5. **Validate Accuracy**: Ensure all examples and references are current
6. **Test Documentation**: Verify instructions work with the current codebase

### README.md Update Guidelines

- **Comprehensive Rewrite**: Don't just append - analyze and rewrite the entire document
- **Current State Focus**: Reflect actual current capabilities, not future plans
- **Complete Feature List**: Document all scripts, functions, and capabilities
- **Accurate Examples**: Use real code examples from the current scripts
- **Clear Prerequisites**: List all requirements for successful execution
- **Troubleshooting**: Include common issues and solutions based on actual usage

### copilot-instructions.md Update Guidelines

- **Pattern Discovery**: Identify and document new coding patterns, conventions, or workflows
- **Function Documentation**: Add newly created reusable functions to the "Key Functions" section
- **Workflow Updates**: Update workflow patterns if new processes are introduced
- **Convention Updates**: Document any new naming, error handling, or structural conventions
- **Example Updates**: Replace old examples with current code snippets
- **Completeness**: Ensure all discoverable patterns are documented, not just aspirational practices

### Best Practices

- **Regular Reviews**: Periodically review documentation for accuracy
- **User Feedback**: Update documentation based on user questions or confusion
- **Version Alignment**: Keep documentation synchronized with code changes
- **Clear Examples**: Always include specific code examples from the current codebase
- **Future-Proofing**: Document current state, not unproven future plans
