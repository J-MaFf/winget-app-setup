# Spec: Close the build's undefined-reference guard's blind spot for indirect dispatch

## Goal
`build/Build-WingetInstallScript.ps1`'s undefined-reference guard must catch a stale
catalog-carried function name (e.g. after a rename) instead of passing silently while the generated
installer ships broken.

## Context
`Get-UndefinedCommandReference` (`build/Build-WingetInstallScript.ps1`, lines 32-82) walks the
assembled script's AST, collects every `CommandAst` node's `.GetCommandName()` (lines 68-71,
filtered to hyphenated names only), and checks each resolves to a module-defined function or a real
external command (lines 73-81).

`GetCommandName()` returns `$null` for an indirect invocation — the call operator `&` applied to a
variable/member-expression rather than a literal command name. `WingetAppSetup/Private/
InstallVerification.ps1:107` does exactly this: `$customResult = & $App.install`. The invoked name
is carried as **data**, not code: `WingetAppSetup/Public/AppCatalog.ps1:46` has
`@{name = 'Microsoft.PowerShell'; install = 'Install-PowerShellLatest' }`.

Reproduced empirically by an independent verifier agent (CONFIRMED, full-repo review, 2026-07-16):
renaming `Install-PowerShellLatest` (updating its definition and the `.psd1`'s
`FunctionsToExport` together, as a normal refactor would) while leaving the `AppCatalog.ps1` string
stale passes the parse guard, the ASCII guard, the export guard, the undefined-reference guard, and
`-Check` — all with zero errors. The installer only breaks at runtime, with a
`CommandNotFoundException` the moment it tries to install that one specific app.
`tests/AppCatalog.Tests.ps1:82` pins the catalog string against a fixed literal
(`Should -Be 'Install-PowerShellLatest'`), which does not catch a coordinated rename (the literal
in the test would need updating too, and nothing checks the string actually resolves to a live
function).

The verifier's suggested remediation: extend `Get-UndefinedCommandReference` with a second AST pass
over `HashtableAst`/key-value-pair nodes keyed `install` (or, more generally, string-literal values
later invoked via `& $var.<key>`), validating those strings against the same
`$definedExact`/`$definedFolded`/`Get-Command` checks already used for direct command references —
OR add a Pester assertion that iterates `Get-DefaultAppCatalog` and asserts
`Get-Command $app.install -ErrorAction SilentlyContinue` is non-null for every entry with an
`install` key. Either approach is acceptable; pick whichever fits the build's existing guard
architecture better.

This repo's convention: this guard exists specifically because a prior version of this exact bug
class (issue #154 — `Test-SystemRequirements` going missing) shipped silently once before.

## Deliverable
Either (a) an extension to `Get-UndefinedCommandReference` in
`build/Build-WingetInstallScript.ps1` that also validates catalog-carried `install` function-name
strings, or (b) a new Pester test in `tests/AppCatalog.Tests.ps1` that validates every catalog
entry's `install` field resolves to a real, currently-defined function — plus a `CHANGELOG.md`
entry documenting which approach was taken and why.

## Requirements
- R1. There must exist an automated check — as part of the build (`build/Build-WingetInstallScript.ps1`,
  either the plain build or `-Check`) or as part of the Pester suite (`Invoke-Pester ./tests`) — that
  fails when any `Get-DefaultAppCatalog` entry's `install` field (when present) does not name a
  function actually defined somewhere in `WingetAppSetup/Public/*.ps1` or
  `WingetAppSetup/Private/*.ps1`. [verify: reproduce the exact empirical repro from Context —
  rename `Install-PowerShellLatest` to `Install-PowerShellLatestX` in its definition and the
  `.psd1`'s `FunctionsToExport`, leave `AppCatalog.ps1`'s string as `'Install-PowerShellLatest'` —
  and confirm the new check now fails (nonzero exit / test failure) where it previously passed]
- R2. The check must not produce a false positive against the current, correct state of the repo
  (every catalog entry's `install` field already resolves to a real function). [verify: run the new
  check against the unmodified repo and confirm it passes]
- R3. If implemented as a build guard: it must integrate into the existing guard-stack output
  format (clear line/column-style or named-reference error message) rather than a generic crash.
  [verify: inspect the error message produced by the R1 repro — it must clearly name the offending
  catalog entry and the missing function]
- R4. If implemented as a Pester test: it must follow this repo's test conventions (dot-sources
  the module via `TestHelpers.ps1`, no reliance on real winget/system state). [verify: code review
  of the new test file/block]
- R5. `winget-app-install.ps1` is regenerated and `pwsh -File ./build/Build-WingetInstallScript.ps1
  -Check` passes against the CURRENT (non-broken) repo state. [verify: run the command against the
  actual repo, exit code 0]
- R6. The full Pester suite passes on Pester 6.x with zero new failures (beyond the intentionally
  new passing test) and no change to the pre-existing skip count. [verify: `Invoke-Pester ./tests`,
  compare before/after]

## Out of scope
- Do not rename `Install-PowerShellLatest` or change the actual catalog — the repro in R1 is a
  throwaway verification step, not a real change to ship.
- Do not attempt to make the guard understand arbitrary indirect dispatch patterns in general —
  scope this specifically to the catalog's `install`/similar known data-carried function-name
  fields.
- Do not remove or weaken any existing build guard (parse, ASCII/BOM, export, byte-compare
  `-Check`).

## Constraints
- PowerShell 7+ syntax throughout.
- If extending the build guard, it must remain 5.1-runtime-compatible where the build script itself
  requires it (check `build/Build-WingetInstallScript.ps1`'s own compatibility notes, if any).
- Whichever approach is taken, document the choice and its reasoning in a code comment, since this
  spec explicitly allows either.

## Acceptance rubric
- C1 (from R1): PASS iff the R1 repro (empirically the same one already used to discover this bug)
  now fails the new check where it previously passed silently.
- C2 (from R2): PASS iff the new check passes against the current, unmodified repo.
- C3 (from R3): PASS iff (when applicable) the failure message clearly names the broken catalog
  entry.
- C4 (from R4): PASS iff (when applicable) the new test follows repo test conventions.
- C5 (from R5): PASS iff `build/Build-WingetInstallScript.ps1 -Check` exits 0 against the current
  repo after the change.
- C6 (from R6): PASS iff the full Pester suite shows 0 unexpected new failures and the same
  pre-existing skip count.
- C-final: PASS iff a domain expert reviewing this artifact would accept it without substantive
  changes.

## Open questions
(none)
