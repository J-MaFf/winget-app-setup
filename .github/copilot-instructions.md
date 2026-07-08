# Copilot Instructions

**`CLAUDE.md` (repo root) is the single source of truth for this repository's workflow rules** — platform constraints (Windows-only PowerShell), key files, the module → generated-script build, testing conventions, and winget notes. Read it first; this file only adds commit/PR formatting specifics.

## Repo-Critical Rules

- `WingetAppSetup/` (module) is the source of truth. **Never hand-edit `winget-app-install.ps1`** — it is generated. After changing the module or `build/fragments/`, regenerate with `pwsh -File ./build/Build-WingetInstallScript.ps1` and commit both.
- Run the Pester suite before pushing: `Invoke-Pester ./Test-WingetAppInstall.Tests.ps1`.
- Always capture `$LASTEXITCODE` immediately after a winget call.

## Commit Messages (Conventional Commits)

Use `<type>: <short summary>` with these prefixes:

- `feat:` New features
- `fix:` Bug fixes
- `docs:` Documentation changes
- `style:` Code style changes (formatting, etc.)
- `refactor:` Code refactoring without changing behavior
- `perf:` Performance improvements
- `test:` Add or update tests
- `chore:` Maintenance, dependency updates, CI/CD
- `ci:` CI/CD pipeline changes
- `revert:` Revert a previous commit

Example: `fix: capture winget exit code before the pipeline resets it`

## PR Titles

Plain conventional-commit style, matching the squash-merge convention: `<type>: <short summary>` (no emoji prefixes).

## PR Body

- Start with the issue reference: `Fixes #N`
- Then `## Changes` (bulleted) and `## Testing` (what was run and the results)

## PR Metadata

Always set on every PR:

- **Labels**: relevant GitHub labels (e.g. `bug`, `enhancement`, `documentation`)
- **Assignee**: `J-MaFf`
- **Linked issues**: reference all related issues in the description

```bash
# Set labels and assignee on an existing PR
gh pr edit <PR_NUMBER> --add-label "documentation" --add-assignee "J-MaFf"
```

Note: use `gh pr edit` for pull requests and `gh issue edit` for issues — they are separate commands. Labels must already exist in the repository; check with `gh label list`.
