# winget-app-setup — Repo-Specific Rules

Inherits global rules from `/Scripts/CLAUDE.md`. Rules here override or extend globals.

---

## Platform

This repo targets **Windows only**. All scripts are PowerShell.

- Use PowerShell 7+ syntax
- Use Pester for all unit tests (`tests/*.Tests.ps1`)
- Claude Code runs on an Ubuntu Linux VM — it cannot execute these scripts directly; test on Windows or a VM
- Cloud sessions: `.claude/hooks/session-start.sh` (SessionStart hook) installs PowerShell 7, Pester 6.2.0 (from nuget.org) and `bd` (built from source with Go), then runs `bd bootstrap`. The Pester suite and `build/Build-WingetInstallScript.ps1 -Check` then run on Linux (see Testing for how) and pass in full; Windows CI stays the verdict. `bd dolt push` is refused from cloud sessions (they can only push their own branch); export new beads with `bd export --include-memories` and import them on a dev machine.

---

## Key Files

| File | Purpose |
|------|---------|
| `WingetAppSetup/` | **Source of truth** — PowerShell module (`.psd1` manifest + `.psm1` loader) holding all install logic in `Public/` and `Private/` |
| `WingetAppSetup/Private/WingetClientModule.ps1`, `WingetClientEngine.ps1` | The opt-in Microsoft.WinGet.Client install engine of runs as SYSTEM (wgt-gq8.42): the pin (`Get-WingetClientModulePin`), the Gallery download and its size, SHA256 and signature checks (`Initialize-WingetClientModule`), the script each child `pwsh` runs, and the requests and their mapping onto winget result codes (`Invoke-WingetClientRequest`, `Get-WingetClientResultCode`) |
| `winget-app-install.ps1` | **Generated** single-file installer (local + `irm \| iex`). Do not edit by hand — edit the module and rebuild |
| `build/Build-WingetInstallScript.ps1` | Regenerates `winget-app-install.ps1` and `winget-app-uninstall.ps1` from the module. It runs every guard on both and writes neither unless both pass; `-Check` verifies that both are in sync. `-OutputPath` and `-UninstallerOutputPath` write elsewhere; the uninstaller defaults to the folder of `-OutputPath` |
| `build/Set-WingetClientModulePin.ps1` | Checks (`-Check`, exit 1 on a mismatch) or moves (`-Write`) the Microsoft.WinGet.Client pin in `Get-WingetClientModulePin` against the PowerShell Gallery package; rebuild and run the `e2e-install-system-winget-client` job after moving it. Its signature checks need Windows |
| `winget-app-uninstall.ps1` | **Generated** single-file uninstaller, built from `build/fragments/uninstall-head.ps1`, the module and `build/fragments/uninstall-tail.ps1`. Its entry block runs `Invoke-WingetUninstall` (`WingetAppSetup/Public/Uninstall.ps1`) and relaunches elevated as a SHA256-checked copy, like the installer. It runs only from a file: under `irm \| iex` it changes nothing and stops with exit code 5 (`$LASTEXITCODE` 5 in an interactive console, which stays open). Do not edit by hand: edit the module or the fragments and rebuild |
| `rmm/` | Standalone Endpoint Central scripts (not generated; Windows PowerShell 5.1-safe, ASCII only): `Invoke-WingetAppSetup.ps1` (machine phase, as SYSTEM: 64-bit relaunch through Sysnative, runs the installer from a pinned commit after a SHA256 check, passes on `-MaxRuntimeMinutes` with a deadline counted from its own start, before the relaunch, sets `WINGET_APP_SETUP_SYSTEM_ENGINE` for the installer from `-SystemInstallEngine` and restores it afterwards, passes its exit code back), `Invoke-WingetAppSetupUserPhase.ps1` (user phase, at each sign-in: installs the apps `last-run.json` lists as `Deferred` with `--scope user` and sets the Windows Terminal defaults, through `Invoke-WingetUserPhase`), `Get-WingetFleetHealth.ps1` (read-only health probe, `HEALTH:` line) and `Repair-WauLogonTrigger.ps1` (removes WAU's at-logon trigger, `REPAIR:` line). `build/Set-RmmInstallerPin.ps1 -Commit <commit on main>` sets the pins of both phases; they ship empty. See readme.md "Endpoint Central and other RMM tools" |
| `tests/` | Pester test suite, one `<Area>.Tests.ps1` per module file plus `EntryPoint.Tests.ps1`, `TestHarness.Tests.ps1` (the suite's own loading rules), `BuildGuards.Tests.ps1` (the build guards and the pre-commit hook), `Rmm*.Tests.ps1` (the `rmm/` scripts and the pin helper) and `E2E*.Tests.ps1` (the `e2e/` scripts, with sample transcripts in `tests/fixtures/e2e`, saved as `.txt` because the repo ignores `*.log`, and a sample `last-run.json` of the SYSTEM run, `system-last-run.json`, to update when the catalog changes; `Diagnostics.Tests.ps1` likewise has sample logs in `tests/fixtures/diagnostics`, and `WingetClientEngine.Tests.ps1` sample child `pwsh` results in `tests/fixtures/winget-client`); `tests/TestHelpers.ps1` loads the module once per file and stands in for Windows-only commands off Windows |
| `e2e/` (`Assert-Install.ps1` with `TranscriptAssertions.ps1`, `Invoke-InstallPass.ps1`, `Invoke-SystemInstallPass.ps1`, `Remove-PreinstalledApps.ps1`, `Collect-Diagnostics.ps1`) + `.github/workflows/e2e-install.yml` | Real-install e2e run on GitHub-hosted runners in four legs, `e2e-install` from PowerShell 7, `e2e-install-windows-powershell` from Windows PowerShell 5.1 through the bootstrap, `e2e-install-system` as SYSTEM through `rmm/Invoke-WingetAppSetup.ps1` started by a 32-bit `powershell.exe` scheduled task, and `e2e-install-system-winget-client`, that SYSTEM pass run twice with `-SystemInstallEngine WinGetClient` (`Invoke-SystemInstallPass.ps1 -PassCount 2`; it also runs the pin helper's `-Check`, which cannot fail the job): weekly against raw `main` (the SYSTEM legs always run the checkout); against the checkout on dispatch and on PRs that touch the product, `rmm/` or e2e files. Uploads transcripts and diagnostics; an ubuntu `report-failure` job files the failure issue for weekly and `main`-dispatched runs — see readme.md "End-to-end monitoring" |

---

## Module → script build

- All install logic lives in `WingetAppSetup/Public/*.ps1` and `WingetAppSetup/Private/*.ps1`.
- `winget-app-install.ps1` is assembled from `build/fragments/head.ps1` (the script's help and `param` block, kept as it is), those files and `build/fragments/tail.ps1`, the last two without their comments. `winget-app-uninstall.ps1` is assembled the same way from `build/fragments/uninstall-head.ps1`, the same module files and `build/fragments/uninstall-tail.ps1`. It has no build id: it keeps no transcript, and its elevated relaunch checks the file's SHA256. Never hand-edit either. Read and write comments in the source: a comment-only change to the module or to a tail fragment leaves both scripts, and the installer's build id, unchanged.
- After changing the module or `build/fragments/`, run `pwsh -File ./build/Build-WingetInstallScript.ps1` to regenerate both scripts, and commit them with the change.
- Comments say what the code does and why in 1-3 lines; incident history (issue threads, E2E runs, review findings) goes in the commit message and CHANGELOG, at most an issue or finding number in the comment. Comment-based help in the module uses `.OUTPUTS`, never `.RETURNS`: an unknown keyword makes `Get-Help` ignore the whole block (`tests/BuildGuards.Tests.ps1` checks every function under `WingetAppSetup/`; the `rmm/` and `e2e/` scripts still use `.RETURNS`).
- Drift is enforced end-to-end: `-Check` (ordinal byte-compare + BOM guard, parse guard, comment removal check, undefined-reference guard, PS 5.1 parse-safety guards for non-ASCII tokens and PowerShell-7-only syntax, and the installer's content-derived build id) runs on both generated scripts, in CI on every push/PR **and** locally via the tracked `.githooks/pre-commit` hook, which checks the staged files rather than the working tree. A guard's report names the file it is about: the generated script, or, for the comment check, the source file. Full guard-stack description: readme.md, "Why `winget-app-install.ps1` cannot drift from the module".
- The undefined-reference guard also runs on Linux/macOS, where it counts the Windows-only cmdlets listed in `build/windows-only-commands.txt` as resolvable. When module code starts calling another Windows-only cmdlet, add it to that list (a Windows build fails if an entry does not resolve there).
- The `rmm/` scripts are not generated and load nothing from the module: Endpoint Central pushes one file. They repeat the few parts of the module they need (the machine-wide `winget.exe` order, the Windows App Runtime requirement, the at-logon trigger rule, the run-record trust check, and the format of the time budget's `-RunDeadlineUtc`, which `Format-RunRecordTime` writes and `Resolve-InstallerRunBudget` reads), and `tests/RmmFleetHealth.Tests.ps1` and `tests/RmmWrapper.Tests.ps1` compare those copies with the module's functions and keep the shared helpers identical. When you change one of those module functions, change the `rmm/` copy too. Never commit a TightVNC password or any other secret into them: the repository is public.
- One-time per clone, enable the local hook: `git config core.hooksPath .githooks`. Caveat: `core.hooksPath` makes git ignore `.git/hooks/`, so anyone who ran the opt-in `bd hooks install` (beads shims) should instead leave it unset and invoke `.githooks/pre-commit` from `.git/hooks/pre-commit` — details in readme.md.

---

## Testing

- **Targets Pester 6.x** (also still passes on 5.x). The suite was migrated off `Assert-MockCalled` — removed in Pester 6 — to `Should -Invoke` (wgt-40e). CI (`windows-tests.yml`) pins to 6.x; run locally the same way, e.g. `Import-Module Pester -MinimumVersion 6.0.0 -MaximumVersion 6.999.999`. Note the Pester-6 mock rule: a `Mock <cmd> -ParameterFilter {…}` with no default `Mock <cmd> {…}` now throws on a non-matching call instead of falling through to the real command.
- Run tests with Pester: `Invoke-Pester ./tests` (or a single area file, e.g. `Invoke-Pester ./tests/WingetCore.Tests.ps1`)
- The suite mocks all external/Windows calls, so it runs on Linux/macOS too (wgt-gq8.5). Pester can only mock a command that exists, so `tests/TestHelpers.ps1` defines a stand-in for each Windows-only command the tests mock (`Get-AppxPackage`, `Add-AppxPackage`, `Get-CimInstance`, `Get-Acl`, `Get-AuthenticodeSignature`, the scheduled-task and service cmdlets, `Repair-WinGetPackageManager`, `winget`, `powershell.exe`), only when the command is missing, so on Windows the real cmdlet is what gets mocked. Each stand-in declares the real parameter names that `-ParameterFilter` blocks read (and the real `CimInstance` types for the scheduled-task objects, so a fake trigger needs `-RemoveParameterType` on Linux as on Windows), and throws `CommandNotFoundException` if a test calls it without a `Mock`. Production code that catches that error (e.g. around `Get-AppxPackage`) hides it on Linux, while on Windows the same unmocked call reads the real machine, so mock every Windows-only command the code under test reaches. TestHelpers also sets `TEMP`, `APPDATA`, `LOCALAPPDATA` and `ProgramData` when they are unset. When a test starts mocking another Windows-only command, add a stand-in there; `tests/TestHarness.Tests.ps1` fails and names the command otherwise. These stand-ins are the one place a conditional definition is right; tests themselves still `Mock` unconditionally (last bullet).
- Paths that reach `Join-Path` in a test use `TestDrive`, not `C:\...` literals: `Join-Path` checks that the drive exists, so off Windows a `C:` path turns into `$null` and the test fails or, worse, passes without checking anything.
- The whole suite passes on Linux (the last two Linux-only failures were fixed by wgt-gq8.11 and wgt-gq8.6), so any Linux failure is new.
- Each test file's top-level `BeforeAll` dot-sources `tests/TestHelpers.ps1`, which loads the module's function files once per file; do not re-declare production functions inline in `Describe` blocks (that reintroduces drift), and never dot-source a generated script (`winget-app-install.ps1` or `winget-app-uninstall.ps1`) in a test: it re-declares every function from the last build over the module source, so the test runs stale code until the next rebuild (`tests/TestHarness.Tests.ps1` enforces this). To run the uninstaller's real entry block, use `New-TestUninstallerScript` / `Invoke-TestUninstallerScript` from `tests/TestHelpers.ps1`, which insert overrides before the entry block and run the file in a child process. Short test-double stubs for orchestration tests are fine. A file whose `BeforeDiscovery` needs a module function (e.g. to compute a `-Skip:` condition — Pester evaluates `BeforeDiscovery` before any `BeforeAll` runs) also dot-sources `TestHelpers.ps1` once at the file's top level, outside any block, so discovery sees it too (no test file needs this today); the `BeforeAll` dot-source stays as the file's primary load and the top-level one is only for this discovery-time need.
- The Microsoft.WinGet.Client engine's tests never reach the PowerShell Gallery or a real module: `tests/WingetClientModule.Tests.ps1` builds packages in `TestDrive` and mocks `Invoke-WebRequest`, `Get-AuthenticodeSignature` and `Set-RestrictedDirectoryAcl`, and `tests/WingetClientEngine.Tests.ps1` reads the sample results in `tests/fixtures/winget-client` and runs a stand-in module through a real child `pwsh`. Mock `Invoke-WebRequest` in any test that reaches `Initialize-WingetClientModule`. A test of `Install-WingetPackage`, `Test-WingetPackageInstalled` or the circuit breaker takes the engine path only when the engine is active (`$script:WingetClientEngine` set, or `Test-WingetClientEngineActive` mocked to `$true`).
- Mock all external calls (winget, scheduled task cmdlets, registry) — never rely on real system state in unit tests
- Use unconditional `Mock` in `BeforeEach`, not conditional `if (-not (Get-Command...))` stubs

---

## Winget Notes

- Exit code `0x80073d19` (`ERROR_DEPLOYMENT_BLOCKED_BY_USER_LOG_OFF`) is an AppX deployment error: per-user MSIX registration is blocked when the invoking account has no interactive logon session — the classic case is elevating as a different admin account on a user's machine. Mitigations (issue #159): `Initialize-Winget` probes the source with `winget source update --name winget --disable-interactivity` — deliberately **without** `--accept-source-agreements`, which is invalid for `winget source update` and made the probe false-fail every run (issues #174/#175; agreements are accepted by the install commands instead) — and on `0x80073D19` sets the account up (registers the staged App Installer, then `Repair-WinGetPackageManager`, each at most once a run); `Install-WingetPackage` prefers `--scope machine` (auto-falls back to winget's default scope for MSIX-only packages, except in a run as SYSTEM or under cross-user elevation, where `-MachineScopeOnly` makes the app `Deferred` instead: review finding P3-22) and retries a still-transient `0x80073d19` with backoff (issue #150).
- SYSTEM (an RMM agent) has no winget alias: a SYSTEM run resolves the machine-wide `winget.exe` once (`Test-MachineWingetAvailable`, `WingetAppSetup/Private/MachineContext.ps1`) and `Resolve-WingetExecutable` returns it to every call, so launch winget only through `Invoke-WingetProcess`, never by the bare name. Detect SYSTEM only through `Test-IsSystemAccount` (or `Get-InstallAccountContext`), which tests mock.
- Opt-in SYSTEM engine (wgt-gq8.42): Microsoft documents the winget CLI as unsupported as SYSTEM and the Microsoft.WinGet.Client module as the supported route. With `WINGET_APP_SETUP_SYSTEM_ENGINE=WinGetClient` (read only by `Get-SystemInstallEngineRequest`; the machine phase's `-SystemInstallEngine` sets it), a run as SYSTEM installs and checks its apps through the pinned module (`WingetAppSetup/Private/WingetClientModule.ps1` and `WingetClientEngine.ps1`); any other run ignores the variable, and `winget.exe` stays the default. Get the engine's module only through `Initialize-WingetClientModule`, against `Get-WingetClientModulePin`: never with `Install-Module` (the `Install-Module` before `Repair-WinGetPackageManager` in a run that is not SYSTEM is a separate path), and never loaded into the installer's own process. Call its cmdlets only in a child `pwsh`, through `Invoke-WingetClientRequest`, and read results through `Get-WingetClientResultCode`, so the time limits (`WingetClientProbe`, `WingetClientVersion`, `WingetClientListCheck` in `Get-ProcessTimeoutSeconds`), the tree kill and the winget result codes still apply. It installs with `-Scope System` only. Any NOT READY falls back to `winget.exe` for the whole run, with the reason in `installEngine.fallbackReason`. The module never sets `RebootRequired` and prints no restart warning, so its restart is the installer's 3010 only, and its `InstallerErrorCode` counts only when an installer ran (Status `Ok`, or `InstallError` with a non-zero code). `Test-WingetClientEngineActive` says whether the engine is active; while it is, messages that blame winget name the engine instead. Winget-AutoUpdate, the end-of-run check, the uninstaller, the user phase and `Install-PowerShellLatest`'s `winget download` path always use `winget.exe`. To move the pin, run `build/Set-WingetClientModulePin.ps1` (see Key Files) and rebuild.
- Always capture `$LASTEXITCODE` immediately after a winget call — it goes stale fast
- `winget uninstall` has no restart result of its own: any non-zero return from the app's uninstaller, 3010 and 1641 included, ends with `0x8A150030` (`EXEC_UNINSTALL_COMMAND_FAILED`) after `Uninstall failed with exit code: <n>`. That text is localized, so match the number. `Test-WingetUninstallRestartRequiredResult` reads it; `Test-WingetRestartRequiredResult` covers install/upgrade only.
- Validate package IDs with regex before trusting winget output: `^[\w][\w.\-]+\.[\w][\w.\-]+\z` (anchored at both ends, with `\z` because .NET's `$` also matches before a final newline: it validates a whole id; to find an id inside a longer `winget list` line, use the boundary match in `Test-WingetListOutputContainsPackageId`)


<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:7510c1e2 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for task tracking in this repo — prefer it over ephemeral `TodoWrite`/`TaskCreate` for multi-step or cross-session work. A **GitHub Issue stays the shippable unit** (branch → PR → `Fixes #N`); beads are the execution layer underneath.
- Run `bd prime` for the full command reference.
- Use `bd remember` for **repo-scoped** knowledge that should travel with this repo. Cross-repo / user-level context still lives in the global Claude memory system — `bd remember` does **not** replace it.

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Session Completion

> **Reconciled with the `git-policies` skill.** Beads guards durability/sync; git-policies governs what lands on `main`. These steps make work durable **without** auto-merging.

When ending a work session:

1. **File follow-ups** — beads for sub-tasks; a GitHub issue for anything shippable.
2. **Run quality gates** (if code changed) — tests, linters, build.
3. **Update bead status** — close finished beads, update in-progress ones.
4. **Make work durable (do NOT merge to `main`):**
   ```bash
   git add <files> && git commit -S -m "..."   # signed, per git-policies
   git push -u origin <feature-branch>          # push the FEATURE branch, never main
   bd dolt push                                 # sync beads state (refs/dolt/data)
   ```
5. **Open / update the PR** — `Fixes #N`, `--assignee J-MaFf`, label; self-review the diff.
6. **Stop at the gate** — merging to `main` is **human-approved via PR**. Never auto-merge.

See the `git-policies` skill for the full issue → branch → PR → squash-merge workflow.
<!-- END BEADS INTEGRATION -->
