# winget-app-setup — Repo-Specific Rules

Inherits global rules from `/Scripts/CLAUDE.md`. Rules here override or extend globals.

---

## Platform

This repo targets **Windows only**. All scripts are PowerShell.

- Use PowerShell 7+ syntax
- Use Pester for all unit tests (`tests/*.Tests.ps1`)
- Claude Code runs on an Ubuntu Linux VM — it cannot execute these scripts directly; test on Windows or a VM

---

## Key Files

| File | Purpose |
|------|---------|
| `WingetAppSetup/` | **Source of truth** — PowerShell module (`.psd1` manifest + `.psm1` loader) holding all install logic in `Public/` and `Private/` |
| `winget-app-install.ps1` | **Generated** single-file installer (local + `irm \| iex`). Do not edit by hand — edit the module and rebuild |
| `build/Build-WingetInstallScript.ps1` | Regenerates `winget-app-install.ps1` from the module (`-Check` verifies it is in sync) |
| `winget-app-uninstall.ps1` | Uninstall helper |
| `tests/` | Pester test suite, one `<Area>.Tests.ps1` per module file plus `EntryPoint.Tests.ps1`; `tests/TestHelpers.ps1` loads the module once per file |

---

## Module → script build

- All install logic lives in `WingetAppSetup/Public/*.ps1` and `WingetAppSetup/Private/*.ps1`.
- `winget-app-install.ps1` is assembled from those files plus `build/fragments/{head,tail}.ps1`. Never hand-edit it.
- After changing the module, run `pwsh -File ./build/Build-WingetInstallScript.ps1` to regenerate, and commit both.
- Drift is enforced end-to-end: `-Check` (byte-compare + BOM guard, parse guard, undefined-reference guard, psd1 export assertion, non-ASCII/PS 5.1 token guard, content-derived build id) runs in CI on every push/PR **and** locally via the tracked `.githooks/pre-commit` hook. Full guard-stack description: readme.md, "Why `winget-app-install.ps1` cannot drift from the module".
- One-time per clone, enable the local hook: `git config core.hooksPath .githooks`. Caveat: `core.hooksPath` makes git ignore `.git/hooks/`, so anyone who ran the opt-in `bd hooks install` (beads shims) should instead leave it unset and invoke `.githooks/pre-commit` from `.git/hooks/pre-commit` — details in readme.md.

---

## Testing

- Run tests with Pester: `Invoke-Pester ./tests` (or a single area file, e.g. `Invoke-Pester ./tests/WingetCore.Tests.ps1`)
- The suite mocks all external/Windows calls, so it runs on Linux/macOS too — though winget/`Get-WinGetPackage`/`Test-NetConnection`-dependent tests only pass on Windows where those cmdlets exist.
- Each test file's top-level `BeforeAll` dot-sources `tests/TestHelpers.ps1`, which loads the module's function files once per file; do not re-declare production functions inline in `Describe` blocks (that reintroduces drift). Short test-double stubs for orchestration tests are fine.
- Mock all external calls (winget, scheduled task cmdlets, registry) — never rely on real system state in unit tests
- Use unconditional `Mock` in `BeforeEach`, not conditional `if (-not (Get-Command...))` stubs

---

## Winget Notes

- Exit code `0x80073d19` (`ERROR_DEPLOYMENT_BLOCKED_BY_USER_LOG_OFF`) is an AppX deployment error: per-user MSIX registration is blocked when the invoking account has no interactive logon session — the classic case is elevating as a different admin account on a user's machine. Mitigations (issue #159): `Initialize-WingetSourcesForUser` probes with `winget source update --name winget --disable-interactivity` — deliberately **without** `--accept-source-agreements`, which is invalid for `winget source update` and made the probe false-fail every run (issues #174/#175; agreements are accepted by the install commands instead) — and bootstraps the account via `Repair-WinGetPackageManager` on failure; `Install-WingetPackage` prefers `--scope machine` (auto-falls back for MSIX-only packages) and retries a still-transient `0x80073d19` with backoff (issue #150).
- Always capture `$LASTEXITCODE` immediately after a winget call — it goes stale fast
- Validate package IDs with regex before trusting winget output: `^[\w][\w.\-]+\.[\w][\w.\-]+`


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
