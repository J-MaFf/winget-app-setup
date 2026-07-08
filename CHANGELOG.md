# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

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

### Added

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

- Removed orphaned Pester `Describe` blocks that tested functions which no longer ship: `Test-AndSetExecutionPolicy` (its `launch.ps1` was already dropped), `Invoke-WingetInstallWithRetry`, and `Test-SystemRequirements` ([#111](https://github.com/J-MaFf/winget-app-setup/issues/111)).
- Dropped `launch.ps1`; the installer now runs directly when the required execution policy is temporarily relaxed.

### Fixed (Unreleased)

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
