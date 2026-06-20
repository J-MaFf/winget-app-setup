# winget-app-setup — Repo-Specific Rules

Inherits global rules from `/Scripts/CLAUDE.md`. Rules here override or extend globals.

---

## Platform

This repo targets **Windows only**. All scripts are PowerShell.

- Use PowerShell 7+ syntax
- Use Pester for all unit tests (`Test-WingetAppInstall.Tests.ps1`)
- Claude Code runs on an Ubuntu Linux VM — it cannot execute these scripts directly; test on Windows or a VM

---

## Key Files

| File | Purpose |
|------|---------|
| `WingetAppSetup/` | **Source of truth** — PowerShell module (`.psd1` manifest + `.psm1` loader) holding all install logic in `Public/` and `Private/` |
| `winget-app-install.ps1` | **Generated** single-file installer (local + `irm \| iex`). Do not edit by hand — edit the module and rebuild |
| `build/Build-WingetInstallScript.ps1` | Regenerates `winget-app-install.ps1` from the module (`-Check` verifies it is in sync) |
| `Update-InstalledApps.ps1` | Scheduled update helper, runs as a standalone task |
| `winget-app-uninstall.ps1` | Uninstall helper |
| `Test-WingetAppInstall.Tests.ps1` | Pester test suite; loads the module once |

---

## Module → script build

- All install logic lives in `WingetAppSetup/Public/*.ps1` and `WingetAppSetup/Private/*.ps1`.
- `winget-app-install.ps1` is assembled from those files plus `build/fragments/{head,tail}.ps1`. Never hand-edit it.
- After changing the module, run `pwsh -File ./build/Build-WingetInstallScript.ps1` to regenerate, and commit both.

---

## Testing

- Run tests with Pester: `Invoke-Pester ./Test-WingetAppInstall.Tests.ps1`
- The suite mocks all external/Windows calls, so it runs on Linux/macOS too — though winget/`Get-WinGetPackage`/`Test-NetConnection`-dependent tests only pass on Windows where those cmdlets exist.
- The top-level `BeforeAll` dot-sources the module's function files once; do not re-declare production functions inline in `Describe` blocks (that reintroduces drift). Short test-double stubs for orchestration tests are fine.
- Mock all external calls (winget, scheduled task cmdlets, registry) — never rely on real system state in unit tests
- Use unconditional `Mock` in `BeforeEach`, not conditional `if (-not (Get-Command...))` stubs

---

## Winget Notes

- Exit code `0x80073d19` is a transient Windows session error. It is mitigated by initializing winget sources in the user context before elevation (`Initialize-WingetSourcesForUser`, issues #104/#105); any install that still fails is retried once in the final retry pass of `Invoke-WingetInstall`. (There is no dedicated backoff-retry function.)
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

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->
