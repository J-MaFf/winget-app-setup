# Spec: Implement the package-ID regex validation CLAUDE.md already documents

## Goal
Package IDs are validated against the shape this repo's own CLAUDE.md mandates before being
trusted in winget output or passed to winget commands — closing the gap between a documented rule
and actual enforcement.

## Context
`CLAUDE.md` (repo root, "Winget Notes" section, line 55) states verbatim:

> Validate package IDs with regex before trusting winget output: `^[\w][\w.\-]+\.[\w][\w.\-]+`

Verified via direct read and an independent verifier agent (CONFIRMED, full-repo review,
2026-07-16): this pattern exists nowhere in production code. `Test-WingetPackageInstalled`
(`WingetAppSetup/Public/WingetCore.ps1`, lines 458 and 474) decides "is this installed" via a plain
`.Contains($PackageId)` against raw `winget list` text output — no regex, no anchoring.
`Install-WingetPackage` (same file, line 352) passes `$PackageId` into the `--id` argument with no
prior validation. `WingetAppSetup/Public/AppValidation.ps1`'s `Test-AppDefinitions` (lines 29-32)
only checks that `name` is a non-empty, non-whitespace string — no shape check. The only place the
regex appears is `tests/AppCatalog.Tests.ps1:64`, which uses it solely to assert the static
catalog's hardcoded names have the right shape at test time — it validates nothing at runtime.

Risk is partially mitigated today because `Test-WingetPackageInstalled` calls `winget list --exact
--id $PackageId`, so winget itself narrows the result set before the `.Contains` check runs — but
the CLAUDE.md rule is still unenforced as written, and an unanchored substring check against
`winget list` output remains theoretically exploitable to a false "installed" verdict.

This repo's convention: the module is the source of truth; `Get-DefaultAppCatalog`
(`WingetAppSetup/Public/AppCatalog.ps1`) is the curated, trusted source of package IDs — this
validation is a defense-in-depth check, not a defense against a hostile catalog.

## Deliverable
A code change adding package-ID shape validation at the two places IDs are trusted:
`Test-AppDefinitions` (`WingetAppSetup/Public/AppValidation.ps1`) for catalog entries at load time,
and `Test-WingetPackageInstalled`'s installed-check (`WingetAppSetup/Public/WingetCore.ps1`) for
runtime output matching — plus new/updated Pester coverage, a regenerated
`winget-app-install.ps1`, and a `CHANGELOG.md` entry.

## Requirements
- R1. `Test-AppDefinitions` must reject (add to its `Errors`/`Warnings` collection, per its
  existing return-shape contract) any catalog entry whose `name` does not match
  `^[\w][\w.\-]+\.[\w][\w.\-]+`. [verify: unit test passes a catalog entry with a malformed id
  (e.g. missing the dot-separated publisher.product shape) and asserts `Test-AppDefinitions`
  reports it as invalid, while every existing real catalog entry from `Get-DefaultAppCatalog`
  still passes]
- R2. `Test-WingetPackageInstalled`'s installed-determination must not treat a `winget list` output
  line as a match unless the matched substring corresponds to a package ID of the same validated
  shape (i.e. tighten the match so an unrelated line containing `$PackageId` as a pure substring of
  a different token cannot false-positive). [verify: unit test constructs mock `winget list` output
  containing a different package ID that contains the target `$PackageId` as a substring (e.g.
  target `Foo.Bar` inside listed id `Foo.BarBaz`), and asserts `Test-WingetPackageInstalled` returns
  `$false`/not-installed for that case, while a real matching line still returns `$true`]
- R3. Existing behavior for well-formed package IDs (the entire current catalog) must be completely
  unchanged. [verify: full existing `tests/WingetCore.Tests.ps1` and `tests/AppCatalog.Tests.ps1`
  suites pass unmodified]
- R4. `winget-app-install.ps1` is regenerated and `pwsh -File ./build/Build-WingetInstallScript.ps1
  -Check` passes. [verify: run the command, exit code 0]
- R5. The full Pester suite passes on Pester 6.x with zero new failures and no change to the
  pre-existing skip count. [verify: `Invoke-Pester ./tests`, compare before/after]

## Out of scope
- Do not change the curated catalog's actual entries in `AppCatalog.ps1` — all current entries are
  already well-formed and must continue to validate successfully.
- Do not add validation to `winget-app-uninstall.ps1`'s separate raw `winget uninstall` call — that
  is out of scope for this fix (track separately if desired).
- Do not change how `--exact --id` narrowing works in the underlying winget invocation.

## Constraints
- PowerShell 7+ syntax; module source only, never hand-edit `winget-app-install.ps1`.
- Use the exact regex CLAUDE.md specifies: `^[\w][\w.\-]+\.[\w][\w.\-]+` — do not invent a
  different pattern.
- Tests must mock all external winget calls per repo CLAUDE.md.
- Rebuild via `build/Build-WingetInstallScript.ps1` and commit the regenerated file alongside the
  module change.

## Acceptance rubric
- C1 (from R1): PASS iff a test proves `Test-AppDefinitions` rejects a malformed id and accepts
  every real catalog entry.
- C2 (from R2): PASS iff a test proves a substring-collision scenario no longer false-positives as
  installed, while a real match still succeeds.
- C3 (from R3): PASS iff `tests/WingetCore.Tests.ps1` and `tests/AppCatalog.Tests.ps1` pass
  unmodified.
- C4 (from R4): PASS iff `build/Build-WingetInstallScript.ps1 -Check` exits 0 after the change.
- C5 (from R5): PASS iff the full Pester suite shows 0 new failures and the same skip count.
- C-final: PASS iff a domain expert reviewing this artifact would accept it without substantive
  changes.

## Open questions
(none)
