# Spec: Consolidate the duplicated winget agreement/interactivity flag-triple into one helper

## Goal
The `--accept-source-agreements --accept-package-agreements --disable-interactivity` flag
combination (and its subcommand-specific variants) is built by one shared helper instead of being
hand-duplicated across call sites, so the exact class of bug that already shipped once (a missing
flag caught only after the fact, issue #230) becomes structurally impossible instead of relying on
manual re-auditing.

## Context
Three call sites independently build this flag combination as inline literal arrays:

- `WingetAppSetup/Public/WingetCore.ps1:347-353` — `Install-WingetPackage`'s `$installArgs`:
  `'install', '-e', '--accept-source-agreements', '--accept-package-agreements',
  '--disable-interactivity', '--source', 'winget', '--id', $PackageId`. Carries a comment (lines
  342-346) explicitly citing issue #230: this exact array was the one missing
  `--disable-interactivity` while every other winget call in the module already had it.
- `WingetAppSetup/Public/WingetCore.ps1:606-610` — `Install-MsixProvisionedPackage`'s
  `$downloadArgs`: same three flags plus `download`-specific arguments.
- `WingetAppSetup/Private/PowerShell7Bootstrap.ps1:201` — `$wingetArguments` for the PowerShell 7
  winget install: same three flags plus its own subcommand-specific arguments.

Verified via an independent verifier agent (CONFIRMED, full-repo review, 2026-07-16), confirmed by
the commit that fixed issue #230 (`ba6bd91`) touching exactly these call sites (plus a fourth,
`Invoke-WingetInstall`'s source-update call, which needed only `--disable-interactivity` since
`winget source update` cannot take `--accept-source-agreements` — see
`WingetAppSetup/Private/WingetBootstrap.ps1:10`). The verifier's own honest assessment: this is
real but "marginal, not urgent" — other winget call sites (`source list`, `search`, `source reset`,
`source update`) use different, subcommand-specific flag subsets, so a single one-size-fits-all
helper needs conditional logic per subcommand rather than being a clean drop-in replacement for
all winget calls; the team's actual chosen mitigation so far has been per-call `Should -Contain`
Pester assertions rather than structural consolidation.

## Deliverable
A shared helper function (e.g. `Get-WingetAgreementArgs` or similar) in
`WingetAppSetup/Private/` that returns the base agreement/interactivity flags, used by
`Install-WingetPackage`, `Install-MsixProvisionedPackage`, and the PowerShell 7 bootstrap's winget
install call — each still appending its own subcommand-specific arguments around the shared base —
plus new/updated Pester coverage, a regenerated `winget-app-install.ps1`, and a `CHANGELOG.md`
entry.

## Requirements
- R1. A single function/helper returns the base flag set (`--accept-source-agreements
  --accept-package-agreements --disable-interactivity`, or the correct subset for a given
  subcommand if the helper is parameterized by subcommand). [verify: unit test calls the helper
  directly and asserts it returns exactly the expected flags]
- R2. `Install-WingetPackage`, `Install-MsixProvisionedPackage`, and the PowerShell 7 bootstrap's
  winget-install call site each use the shared helper rather than a hand-written literal array for
  the shared flag portion. [verify: unit test mocks/spies the helper and asserts each of the three
  call sites' constructed argument list contains the helper's output, or — equivalently — `Grep` the
  repo for the raw three-flag literal combination outside the helper's own definition returns zero
  hits]
- R3. Each call site's own subcommand-specific arguments (e.g. `--source winget --id $PackageId` for
  install, `--installer-type msix --download-directory $downloadDir` for download) are unaffected —
  only the shared agreement/interactivity portion is deduplicated. [verify: existing
  `tests/WingetCore.Tests.ps1` / `tests/PowerShell7Bootstrap.Tests.ps1` argument-shape assertions
  (the `Should -Contain` checks the verifier found) continue to pass, updated only mechanically if
  the exact array construction changed]
- R4. `winget-app-install.ps1` is regenerated and `pwsh -File ./build/Build-WingetInstallScript.ps1
  -Check` passes. [verify: run the command, exit code 0]
- R5. The full Pester suite passes on Pester 6.x with zero new failures and no change to the
  pre-existing skip count. [verify: `Invoke-Pester ./tests`, compare before/after]

## Out of scope
- Do not touch `winget source update`, `winget source list`, `winget search`, or `winget source
  reset` call sites — their flag sets are already correct and are a different subset (some, like
  `source update`, must NOT take `--accept-source-agreements` per issues #174/#175 — do not add it).
- Do not change any winget subcommand's actual behavior or add new flags beyond what each call site
  already passes today.
- Do not attempt to build a fully generic "any winget command" wrapper — scope this to the shared
  agreement/interactivity portion only, per the verifier's own recommendation against
  over-engineering a one-size-fits-all abstraction.

## Constraints
- PowerShell 7+ syntax; module source only, never hand-edit `winget-app-install.ps1`.
- The helper must live in `WingetAppSetup/Private/` unless a call site outside the module needs it
  directly (none currently do — `winget-app-uninstall.ps1`'s raw `winget uninstall` call is
  explicitly out of scope here, tracked separately).
- Tests must mock all external winget calls per repo CLAUDE.md.
- Rebuild via `build/Build-WingetInstallScript.ps1` and commit the regenerated file alongside the
  module change.

## Acceptance rubric
- C1 (from R1): PASS iff a direct unit test of the new helper returns the expected flag set.
- C2 (from R2): PASS iff all three call sites use the helper and no raw duplicate of the three-flag
  literal remains outside it.
- C3 (from R3): PASS iff each call site's subcommand-specific arguments are provably unaffected.
- C4 (from R4): PASS iff `build/Build-WingetInstallScript.ps1 -Check` exits 0 after the change.
- C5 (from R5): PASS iff the full Pester suite shows 0 new failures and the same skip count.
- C-final: PASS iff a domain expert reviewing this artifact would accept it without substantive
  changes.

## Open questions
(none)
