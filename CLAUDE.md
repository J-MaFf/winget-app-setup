# winget-app-setup — Repo-Specific Rules

Inherits global rules from `/Scripts/CLAUDE.md`. Rules here override or extend globals.

---

## Platform

This repo targets **Windows only**. All scripts are PowerShell.

- Use PowerShell 7+ syntax
- Use Pester for all unit tests (`tests/*.Tests.ps1`)
- Claude Code runs on an Ubuntu Linux VM — it cannot execute these scripts directly; test on Windows or a VM
- Cloud sessions: `.claude/hooks/session-start.sh` (SessionStart hook) installs PowerShell 7, Pester 6.2.0 (from nuget.org) and `bd` (built from source with Go), then runs `bd bootstrap`. The Pester suite and `build/Build-WingetInstallScript.ps1 -Check` then run on Linux (see Testing for how, and for the two known Linux failures); Windows CI stays the verdict. `bd dolt push` is refused from cloud sessions (they can only push their own branch); export new beads with `bd export --include-memories` and import them on a dev machine.

---

## Key Files

| File | Purpose |
|------|---------|
| `WingetAppSetup/` | **Source of truth** — PowerShell module (`.psd1` manifest + `.psm1` loader) holding all install logic in `Public/` and `Private/` |
| `winget-app-install.ps1` | **Generated** single-file installer (local + `irm \| iex`). Do not edit by hand — edit the module and rebuild |
| `build/Build-WingetInstallScript.ps1` | Regenerates `winget-app-install.ps1` from the module (`-Check` verifies it is in sync) |
| `winget-app-uninstall.ps1` | Uninstall helper |
| `tests/` | Pester test suite, one `<Area>.Tests.ps1` per module file plus `EntryPoint.Tests.ps1`, `TestHarness.Tests.ps1` (the suite's own loading rules), `BuildGuards.Tests.ps1` (the build guards and the pre-commit hook) and `E2EDiagnostics.Tests.ps1` (`e2e/Collect-Diagnostics.ps1`); `tests/TestHelpers.ps1` loads the module once per file and stands in for Windows-only commands off Windows |
| `e2e/Assert-Install.ps1` + `e2e/Collect-Diagnostics.ps1` + `.github/workflows/e2e-install.yml` | Real-install e2e run on GitHub-hosted runners: weekly against raw `main`; against the checkout on dispatch and on PRs that touch the product or e2e files. Uploads transcripts and diagnostics; an ubuntu `report-failure` job files the failure issue for weekly and `main`-dispatched runs — see readme.md "End-to-end monitoring" |

---

## Module → script build

- All install logic lives in `WingetAppSetup/Public/*.ps1` and `WingetAppSetup/Private/*.ps1`.
- `winget-app-install.ps1` is assembled from those files plus `build/fragments/{head,tail}.ps1`. Never hand-edit it.
- After changing the module, run `pwsh -File ./build/Build-WingetInstallScript.ps1` to regenerate, and commit both.
- Drift is enforced end-to-end: `-Check` (byte-compare + BOM guard, parse guard, undefined-reference guard, psd1 export assertion, PS 5.1 parse-safety guards for non-ASCII tokens and PowerShell-7-only syntax, content-derived build id) runs in CI on every push/PR **and** locally via the tracked `.githooks/pre-commit` hook, which checks the staged files rather than the working tree. Full guard-stack description: readme.md, "Why `winget-app-install.ps1` cannot drift from the module".
- The undefined-reference guard also runs on Linux/macOS, where it counts the Windows-only cmdlets listed in `build/windows-only-commands.txt` as resolvable. When module code starts calling another Windows-only cmdlet, add it to that list (a Windows build fails if an entry does not resolve there).
- One-time per clone, enable the local hook: `git config core.hooksPath .githooks`. Caveat: `core.hooksPath` makes git ignore `.git/hooks/`, so anyone who ran the opt-in `bd hooks install` (beads shims) should instead leave it unset and invoke `.githooks/pre-commit` from `.git/hooks/pre-commit` — details in readme.md.

---

## Testing

- **Targets Pester 6.x** (also still passes on 5.x). The suite was migrated off `Assert-MockCalled` — removed in Pester 6 — to `Should -Invoke` (wgt-40e). CI (`windows-tests.yml`) pins to 6.x; run locally the same way, e.g. `Import-Module Pester -MinimumVersion 6.0.0 -MaximumVersion 6.999.999`. Note the Pester-6 mock rule: a `Mock <cmd> -ParameterFilter {…}` with no default `Mock <cmd> {…}` now throws on a non-matching call instead of falling through to the real command.
- Run tests with Pester: `Invoke-Pester ./tests` (or a single area file, e.g. `Invoke-Pester ./tests/WingetCore.Tests.ps1`)
- The suite mocks all external/Windows calls, so it runs on Linux/macOS too (wgt-gq8.5). Pester can only mock a command that exists, so `tests/TestHelpers.ps1` defines a stand-in for each Windows-only command the tests mock (`Get-AppxPackage`, `Add-AppxPackage`, `Get-CimInstance`, the scheduled-task cmdlets, `Repair-WinGetPackageManager`, `winget`, `powershell.exe`), only when the command is missing, so on Windows the real cmdlet is what gets mocked. Each stand-in declares the real parameter names that `-ParameterFilter` blocks read (and the real `CimInstance` types for the scheduled-task objects, so a fake trigger needs `-RemoveParameterType` on Linux as on Windows), and throws `CommandNotFoundException` if a test calls it without a `Mock`. Production code that catches that error (e.g. around `Get-AppxPackage`) hides it on Linux, while on Windows the same unmocked call reads the real machine, so mock every Windows-only command the code under test reaches. TestHelpers also sets `TEMP`, `APPDATA`, `LOCALAPPDATA` and `ProgramData` when they are unset. When a test starts mocking another Windows-only command, add a stand-in there; `tests/TestHarness.Tests.ps1` fails and names the command otherwise. These stand-ins are the one place a conditional definition is right; tests themselves still `Mock` unconditionally (last bullet).
- Paths that reach `Join-Path` in a test use `TestDrive`, not `C:\...` literals: `Join-Path` checks that the drive exists, so off Windows a `C:` path turns into `$null` and the test fails or, worse, passes without checking anything.
- Two tests still fail on Linux, both for real reasons: `Write-Table` renders nothing when there is no console (`Logging.Tests.ps1`, wgt-gq8.11), and the IEX dry-run elevation test depends on the real elevation state (`Install.Tests.ps1`, wgt-gq8.6). Any other Linux failure is new.
- Each test file's top-level `BeforeAll` dot-sources `tests/TestHelpers.ps1`, which loads the module's function files once per file; do not re-declare production functions inline in `Describe` blocks (that reintroduces drift), and never dot-source the generated `winget-app-install.ps1` in a test: it re-declares every function from the last build over the module source, so the test runs stale code until the next rebuild (`tests/TestHarness.Tests.ps1` enforces this). Short test-double stubs for orchestration tests are fine. A file whose `BeforeDiscovery` needs a module function (e.g. to compute a `-Skip:` condition — Pester evaluates `BeforeDiscovery` before any `BeforeAll` runs) also dot-sources `TestHelpers.ps1` once at the file's top level, outside any block, so discovery sees it too (`tests/EntryPoint.Tests.ps1`, `tests/Install.Tests.ps1`); the `BeforeAll` dot-source stays as the file's primary load and the top-level one is only for this discovery-time need.
- Mock all external calls (winget, scheduled task cmdlets, registry) — never rely on real system state in unit tests
- Use unconditional `Mock` in `BeforeEach`, not conditional `if (-not (Get-Command...))` stubs

---

## Winget Notes

- Exit code `0x80073d19` (`ERROR_DEPLOYMENT_BLOCKED_BY_USER_LOG_OFF`) is an AppX deployment error: per-user MSIX registration is blocked when the invoking account has no interactive logon session — the classic case is elevating as a different admin account on a user's machine. Mitigations (issue #159): `Initialize-WingetSourcesForUser` probes with `winget source update --name winget --disable-interactivity` — deliberately **without** `--accept-source-agreements`, which is invalid for `winget source update` and made the probe false-fail every run (issues #174/#175; agreements are accepted by the install commands instead) — and bootstraps the account via `Repair-WinGetPackageManager` on failure; `Install-WingetPackage` prefers `--scope machine` (auto-falls back for MSIX-only packages) and retries a still-transient `0x80073d19` with backoff (issue #150).
- Always capture `$LASTEXITCODE` immediately after a winget call — it goes stale fast
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
