# STATUS

## What This Is

`winget-app-setup` is a Windows-only PowerShell toolkit that installs a curated list of
applications via winget, configures Windows Terminal, and bootstraps
[Winget-AutoUpdate (WAU)](https://github.com/Romanitho/Winget-AutoUpdate), which owns all ongoing
app updates. End users run a single self-contained `winget-app-install.ps1`, either locally or via a
remote `irm | iex` one-liner. Internally, the installer's logic now lives in the reusable
`WingetAppSetup` module, and the single-file script is generated from it by a build step. The
scripts target **Windows PowerShell / PowerShell 7 on Windows**; they cannot run end-to-end on
Linux or macOS because they depend on `winget`, the `Microsoft.WinGet.Client` module, and
Windows-only cmdlets.

## Current State — 2026-07-08

Healthy. **The 2026-07-08 whole-repo multi-agent code-review wave is fully resolved**: all 17
issues it filed ([#176](https://github.com/J-MaFf/winget-app-setup/issues/176)–[#192](https://github.com/J-MaFf/winget-app-setup/issues/192))
have landed via PRs #193–#209 — see the Resolved Issues table below. In review: Windows
PowerShell 5.1 parse safety for the generated installer
([#210](https://github.com/J-MaFf/winget-app-setup/issues/210), PR
[#212](https://github.com/J-MaFf/winget-app-setup/pull/212)) and the local pre-commit drift
check + guard-stack documentation
([#211](https://github.com/J-MaFf/winget-app-setup/issues/211), stacked on #212). The full
guard stack that keeps `winget-app-install.ps1` from drifting from the module is now
documented in readme.md ("Why `winget-app-install.ps1` cannot drift from the module").

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
runs under Windows PowerShell 5.1 so an MSIX-only pwsh can't break it. The DISM path is dormant until
7.7 GA and needs validation on a real Windows 10 machine before it is relied upon.

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
MSIX-only packages such as Windows Terminal).

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
The Windows CI workflow runs on the self-hosted **win-test** runner (Windows Server 2025,
pwsh 7.6.3) instead of GitHub-hosted `windows-latest`; the guarded Microsoft.WinGet.Client and
Pester installs persist across runs there ([#161](https://github.com/J-MaFf/winget-app-setup/issues/161)).

### Components

| Path | Description |
|------|-------------|
| `WingetAppSetup/` | Source-of-truth PowerShell module (`.psd1` manifest + `.psm1` loader) |
| `WingetAppSetup/Public/` | Exported functions: logging, winget core, app validation, Windows Terminal config, install orchestration (updates are outsourced to WAU) |
| `WingetAppSetup/Private/` | Internal helpers: environment/PATH, elevation, graphical tools |
| `build/Build-WingetInstallScript.ps1` | Concatenates the module + entry fragments into `winget-app-install.ps1` |
| `build/fragments/` | `head.ps1` (PSScriptInfo, help, `param`) and `tail.ps1` (entry-point dispatch) |
| `winget-app-install.ps1` | **Generated** single-file installer for local and `irm \| iex` use — do not edit by hand |
| `winget-app-uninstall.ps1` | Uninstall helper; imports the module from the repo |
| `tests/` | Pester suite, one `<Area>.Tests.ps1` per module file plus `EntryPoint.Tests.ps1`; `TestHelpers.ps1` loads the module once per file |
| `e2e/Assert-Install.ps1` | Shared post-install assertions for end-to-end runs (tier 1 workflow below; tier 2 [#215](https://github.com/J-MaFf/winget-app-setup/issues/215) reuses it) |
| `.github/workflows/e2e-install.yml` | E2E tier 1: weekly real install run on GitHub-hosted `windows-latest` (schedule + dispatch + self-validating PRs; failure auto-files an issue) |
| `Test-WindowsTerminalConfiguration.ps1` | Smoke-test validation for the Windows Terminal default-shell configuration. |
| `readme.md` | Quick-start run instructions (clone-and-run and one-line-run). |
| `CHANGELOG.md` | Keep a Changelog history. |

### Resolved Issues

| Issue | Description | PR |
|-------|-------------|----|
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
| [#210](https://github.com/J-MaFf/winget-app-setup/issues/210) | Generated installer fails to parse under Windows PowerShell 5.1 (BOM-less UTF-8 decoded as ANSI; em dashes corrupt string tokens) | In review — PR [#212](https://github.com/J-MaFf/winget-app-setup/pull/212) |
| [#211](https://github.com/J-MaFf/winget-app-setup/issues/211) | Local pre-commit drift check + document the generated-script guard stack | In review — [PR #213](https://github.com/J-MaFf/winget-app-setup/pull/213), stacked on #212 |
| [#217](https://github.com/J-MaFf/winget-app-setup/issues/217) | Dell Command Update cannot install on GitHub-hosted runners — manufacturer-aware catalog gating | In review — [PR #220](https://github.com/J-MaFf/winget-app-setup/pull/220) |
| [#226](https://github.com/J-MaFf/winget-app-setup/issues/226) | IEX non-admin guidance test silently always skipped (`-Skip` bound at discovery time reads `BeforeAll` variables as `$null`) | In review — PR [#227](https://github.com/J-MaFf/winget-app-setup/pull/227) |

## Natural Next Steps

- Watch the first scheduled e2e install runs (`.github/workflows/e2e-install.yml`, weekly Mondays 06:00 UTC, issue [#214](https://github.com/J-MaFf/winget-app-setup/issues/214)) — a failure auto-creates/comments the `E2E install run failed` issue with the transcript tail.
- **E2E tier 2** ([#215](https://github.com/J-MaFf/winget-app-setup/issues/215)): cross-user elevation end-to-end run on a snapshot-rollback Proxmox VM, reusing `e2e/Assert-Install.ps1` (the shared assertion script from tier 1).
- Watch the first Windows CI runs on the self-hosted win-test runner for environment drift — module versions now persist across runs instead of starting from a fresh `windows-latest` image (as of [#161](https://github.com/J-MaFf/winget-app-setup/issues/161)).
- Validate the dormant DISM MSIX-provisioning path in `Install-PowerShellLatest` end-to-end on a real Windows 10 machine before PowerShell 7.7 GA makes it load-bearing (as of [#166](https://github.com/J-MaFf/winget-app-setup/issues/166)).
- Cut a tagged release and move the `[Unreleased]` CHANGELOG entries under a versioned heading.

## Prerequisites to Run

- **Windows 10/11** with [App Installer / winget](https://www.microsoft.com/p/app-installer/9nblggh4nns1) available.
- **PowerShell 7+** recommended (Windows PowerShell 5.1 also works for the installer).
- Permission to temporarily relax the execution policy for the current process, e.g.:
  ```powershell
  Set-ExecutionPolicy Unrestricted -Scope Process -Force
  ```
- Run the installer: `powershell -ExecutionPolicy Unrestricted -File .\winget-app-install.ps1`.
- Run tests: `Invoke-Pester ./tests`.
- Regenerate the installer after editing the module: `pwsh -File ./build/Build-WingetInstallScript.ps1`.
