#!/usr/bin/env bash
#
# Prebuild script that prepares the environment for fast Pylance startup.
#
# Pylance 2025.10.x does not persist its index to disk — indices live only
# in memory for the lifetime of the extension host process. Therefore this
# script focuses on what CAN be prebuilt:
#
#   1. Python packages installed (so Pylance can index them immediately)
#   2. pyrightconfig.json in place (so Pylance finds the right Python
#      without waiting for the ms-python.python extension to resolve it)
#
# Extensions are pre-installed via devcontainer.json customizations.
#
set -euo pipefail

WORKSPACE="${1:-/workspaces/pylance-prebuild}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# --- Ensure Python dependencies are installed ---
if ! python -c "import django" 2>/dev/null; then
    log "Installing Python dependencies..."
    pip install -e "$WORKSPACE" 2>&1 | tail -5
else
    log "Python dependencies already installed"
fi

# --- Verify pyrightconfig.json exists ---
if [[ -f "$WORKSPACE/pyrightconfig.json" ]]; then
    log "pyrightconfig.json found"
else
    log "WARNING: pyrightconfig.json not found — Pylance may be slow to resolve the Python interpreter"
fi

# --- Report what's ready for Pylance ---
SITE_PACKAGES=$(python -c "import site; print(site.getsitepackages()[0])" 2>/dev/null || echo "unknown")
PYTHON_VERSION=$(python --version 2>&1)
DJANGO_VERSION=$(python -c "import django; print(django.get_version())" 2>/dev/null || echo "not installed")

log "Prebuild complete:"
log "  Python: $PYTHON_VERSION"
log "  Django: $DJANGO_VERSION"
log "  Site packages: $SITE_PACKAGES"
log "  Pylance will index on first editor connection (~10s for 2885 files)"
