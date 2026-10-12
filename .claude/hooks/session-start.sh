#!/bin/bash
# SessionStart hook for Claude Code cloud sessions (Ubuntu containers).
#
# The installer is Windows-only, but a cloud session can still run the Pester unit suite and the
# build's -Check guard under PowerShell 7 on Linux, and use beads (bd) for task tracking. This
# installs those tools; the container is cached after the hook, so later sessions skip the work.
#   1. PowerShell 7 from Microsoft's apt feed.
#   2. Pester 6 from nuget.org (the PowerShell Gallery is often blocked by the network policy).
#   3. bd built from source with Go (npm's @beads/bd downloads from GitHub releases, which the
#      proxy blocks), then `bd bootstrap` clones the beads database from refs/dolt/data.
# Local sessions are left alone: the separate `bd prime` SessionStart hook covers them.
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

PESTER_VERSION=6.2.0
BD_VERSION=v1.3.1
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"

log() { echo "[session-start] $*" >&2; }

apt_updated=false
apt_install() {
  if [ "$apt_updated" = false ]; then
    apt-get update -qq >&2
    apt_updated=true
  fi
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >&2
}

# --- 1. PowerShell 7 --------------------------------------------------------------------------
if ! command -v pwsh >/dev/null 2>&1; then
  log "Installing PowerShell 7..."
  . /etc/os-release
  curl -fsSL -o /tmp/packages-microsoft-prod.deb \
    "https://packages.microsoft.com/config/${ID}/${VERSION_ID}/packages-microsoft-prod.deb"
  dpkg -i /tmp/packages-microsoft-prod.deb >&2
  rm -f /tmp/packages-microsoft-prod.deb
  apt_updated=false
  apt_install powershell
fi

# --- 2. Pester 6 ------------------------------------------------------------------------------
# CI pins Pester 6.x (windows-tests.yml); the nuget.org package ships the module under tools/.
PESTER_DIR="$HOME/.local/share/powershell/Modules/Pester/$PESTER_VERSION"
if [ ! -f "$PESTER_DIR/Pester.psd1" ]; then
  log "Installing Pester $PESTER_VERSION..."
  if ! command -v unzip >/dev/null 2>&1; then
    apt_install unzip
  fi
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/pester.nupkg" \
    "https://api.nuget.org/v3-flatcontainer/pester/$PESTER_VERSION/pester.$PESTER_VERSION.nupkg"
  unzip -qo "$tmp/pester.nupkg" -d "$tmp/extracted"
  mkdir -p "$PESTER_DIR"
  cp -r "$tmp/extracted/tools/." "$PESTER_DIR/"
  rm -rf "$tmp"
fi

# --- 3. beads (bd) ----------------------------------------------------------------------------
# Best-effort: a failure here must not block the session, since tests do not need bd.
install_bd() {
  if ! command -v go >/dev/null 2>&1; then
    log "Go is not installed; skipping bd."
    return 1
  fi
  if ! dpkg -s libicu-dev >/dev/null 2>&1; then
    apt_install libicu-dev pkg-config
  fi
  log "Building bd $BD_VERSION from source (a few minutes the first time)..."
  # bd needs a newer Go than the image ships; Go fetches that toolchain via proxy.golang.org.
  GOFLAGS=-mod=mod go install "github.com/steveyegge/beads/cmd/bd@${BD_VERSION}" >&2
  ln -sf "$(go env GOPATH)/bin/bd" /usr/local/bin/bd
}

if ! command -v bd >/dev/null 2>&1; then
  install_bd || log "bd could not be installed; beads commands will be unavailable this session."
fi

if command -v bd >/dev/null 2>&1; then
  cd "$PROJECT_DIR"
  chmod 700 .beads 2>/dev/null || true
  # bd's anonymous usage metrics: off (their endpoint is blocked by the proxy anyway).
  bd metrics off >/dev/null 2>&1 || true
  git config beads.role maintainer

  # A first `bd bootstrap` in a fresh clone rewrites two tracked files (cosmetic config
  # normalization by newer bd) and creates a lock file at the repo root. Undo the rewrite when the
  # files were clean beforehand, and keep the lock file out of `git status`.
  clean_before=()
  for f in .beads/.gitignore .beads/config.yaml; do
    if git diff --quiet -- "$f" 2>/dev/null; then
      clean_before+=("$f")
    fi
  done
  if ! BD_NON_INTERACTIVE=1 bd bootstrap --yes >&2; then
    log "bd bootstrap failed; run 'bd bootstrap' manually."
  fi
  if [ "${#clean_before[@]}" -gt 0 ]; then
    git checkout -- "${clean_before[@]}" 2>/dev/null || true
  fi
  if ! grep -qx '.beads.gate.lock' .git/info/exclude 2>/dev/null; then
    echo '.beads.gate.lock' >> .git/info/exclude
  fi

  # Workflow context for the session. The separate `bd prime` hook can run before bd exists on a
  # fresh container, so prime here too, once the database is in place.
  bd prime 2>/dev/null || true
fi
