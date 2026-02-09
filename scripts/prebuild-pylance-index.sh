#!/usr/bin/env bash
#
# Prebuild script that starts VS Code desktop server and triggers
# Pylance indexing via a headless browser connection.
#
# VS Code's extension host only activates when a client connects
# with a workspace folder. This script:
#   1. Starts a VS Code serve-web server
#   2. Installs Pylance extensions
#   3. Patches the extension to enable indexing in web mode
#   4. Connects Puppeteer to open the workspace and trigger Pylance
#   5. Waits for Pylance to finish indexing
#   6. Restores the original extension bundle
#
set -euo pipefail

WORKSPACE="${1:-/workspaces/pylance-prebuild}"
PORT="${PREBUILD_VSCODE_PORT:-19876}"
TIMEOUT="${PREBUILD_TIMEOUT:-180}"
SERVER_DATA_DIR="/tmp/vscode-prebuild-$$"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

cleanup() {
    log "Cleaning up..."
    if [[ -n "${SERVER_PID:-}" ]]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    # Restore patched extension bundles
    if [[ -n "${PYLANCE_BUNDLE_BAK:-}" && -f "$PYLANCE_BUNDLE_BAK" ]]; then
        cp "$PYLANCE_BUNDLE_BAK" "${PYLANCE_BUNDLE_BAK%.bak}"
        rm -f "$PYLANCE_BUNDLE_BAK"
        log "Restored Pylance extension bundle"
    fi
    rm -rf "$SERVER_DATA_DIR"
}
trap cleanup EXIT

# --- Step 1: Ensure Python dependencies are installed ---
if ! python -c "import django" 2>/dev/null; then
    log "Installing Python dependencies..."
    pip install -e "$WORKSPACE" 2>&1 | tail -5
else
    log "Python dependencies already installed"
fi

# --- Step 2: Ensure Puppeteer's Chrome is installed ---
if [[ ! -d "$HOME/.cache/puppeteer/chrome" ]]; then
    log "Installing Chrome for Puppeteer..."
    node node_modules/puppeteer/install.mjs 2>&1 | tail -3
fi

# --- Step 3: Find the VS Code CLI ---
log "Finding VS Code CLI..."
VSCODE_CLI=""

# Try existing CLI locations
for f in /home/vscode/.vscode-server/code-*; do
    if [[ -x "$f" && ! -d "$f" ]]; then
        VSCODE_CLI="$f"
        break
    fi
done

if [[ -z "$VSCODE_CLI" ]]; then
    log "VS Code CLI not found locally, downloading..."

    COMMIT=""

    # Try: shared VS Code server path
    if [[ -d "/usr/local/gitpod/shared/vscode/vscode-server/bin" ]]; then
        COMMIT=$(ls /usr/local/gitpod/shared/vscode/vscode-server/bin/ 2>/dev/null | head -1 || true)
    fi

    # Try: product.json from installed server
    if [[ -z "$COMMIT" ]]; then
        for pj in /home/vscode/.vscode-server/cli/serve-web/*/product.json \
                  /home/vscode/.vscode-browser-server/product.json; do
            if [[ -f "$pj" ]]; then
                COMMIT=$(grep -oP '"commit"\s*:\s*"\K[a-f0-9]+' "$pj" 2>/dev/null | head -1 || true)
                [[ -n "$COMMIT" ]] && break
            fi
        done
    fi

    [[ -z "$COMMIT" ]] && COMMIT="latest"

    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  CLI_ARCH="x64" ;;
        aarch64) CLI_ARCH="arm64" ;;
        *)       CLI_ARCH="$ARCH" ;;
    esac

    if [[ "$COMMIT" == "latest" ]]; then
        DOWNLOAD_URL="https://update.code.visualstudio.com/latest/cli-linux-${CLI_ARCH}/stable"
    else
        DOWNLOAD_URL="https://update.code.visualstudio.com/commit:${COMMIT}/cli-linux-${CLI_ARCH}/stable"
    fi

    log "Downloading VS Code CLI (commit: $COMMIT)..."
    CLI_DIR="/tmp/vscode-cli-$$"
    mkdir -p "$CLI_DIR"
    curl -sfL "$DOWNLOAD_URL" | tar xz -C "$CLI_DIR"

    VSCODE_CLI="$CLI_DIR/code"
    if [[ ! -x "$VSCODE_CLI" ]]; then
        log "ERROR: Failed to download VS Code CLI"
        exit 1
    fi
fi

log "Using VS Code CLI: $VSCODE_CLI"

# --- Step 4: Start VS Code desktop server via serve-web ---
# serve-web starts a code-server (VS Code desktop server) internally
# and serves a web UI that connects to it.
log "Starting VS Code desktop server on port $PORT..."
mkdir -p "$SERVER_DATA_DIR/data/Machine"

# Write Pylance settings
cat > "$SERVER_DATA_DIR/data/Machine/settings.json" << 'SETTINGS'
{
    "python.analysis.persistAllIndices": true,
    "python.analysis.indexing": true,
    "python.analysis.userFileIndexingLimit": -1,
    "python.analysis.packageIndexDepths": [
        { "name": "django", "depth": 3, "includeAllSymbols": true },
        { "name": "", "depth": 2, "includeAllSymbols": false }
    ],
    "python.defaultInterpreterPath": "/usr/local/bin/python"
}
SETTINGS

"$VSCODE_CLI" serve-web \
    --host 127.0.0.1 \
    --port "$PORT" \
    --without-connection-token \
    --accept-server-license-terms \
    --server-data-dir "$SERVER_DATA_DIR" \
    > "$SERVER_DATA_DIR/server.log" 2>&1 &
SERVER_PID=$!

# Wait for the server to be ready
log "Waiting for server to be ready..."
for i in $(seq 1 60); do
    if curl -sf -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null; then
        log "Server is ready"
        break
    fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        log "ERROR: Server process died"
        cat "$SERVER_DATA_DIR/server.log"
        exit 1
    fi
    sleep 2
done

if ! curl -sf -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null; then
    log "ERROR: Server failed to start within 120s"
    tail -20 "$SERVER_DATA_DIR/server.log"
    exit 1
fi

# --- Step 5: Install Pylance extensions ---
# serve-web downloads a code-server binary on first start.
# Find it and use it to install extensions into the server data dir.
log "Installing Pylance extensions..."
CODE_SERVER=""

# Look for code-server in known locations (serve-web downloads it here)
for i in $(seq 1 30); do
    for d in /home/vscode/.vscode/cli/serve-web/*/bin \
             /home/vscode/.vscode-server/cli/serve-web/*/bin; do
        if [[ -x "${d}/code-server" ]]; then
            CODE_SERVER="${d}/code-server"
            break 2
        fi
    done
    if [[ $i -eq 1 ]]; then
        log "Waiting for serve-web to download code-server..."
    fi
    sleep 2
done

if [[ -n "$CODE_SERVER" ]]; then
    log "Using code-server: $CODE_SERVER"
    "$CODE_SERVER" \
        --accept-server-license-terms \
        --server-data-dir "$SERVER_DATA_DIR" \
        --install-extension ms-python.python \
        --install-extension ms-python.vscode-pylance \
        2>&1 | grep -E "installed|Installing|already" || true
    log "Extensions installed"
else
    log "WARNING: code-server not found, extensions may not be available"
fi

# --- Step 6: Patch Pylance extension to enable indexing in web mode ---
# Pylance disables indexing (IDX thread) in VS Code Web by checking
# workspace kinds. We patch the extension bundle to skip this check.
log "Patching Pylance extension for web-mode indexing..."
PYLANCE_BUNDLE_BAK=""
PYLANCE_EXT_DIR=""

# Find the Pylance extension in known locations
for d in "$SERVER_DATA_DIR/extensions" \
         /home/vscode/.vscode-browser-server/extensions \
         /home/vscode/.vscode-server/extensions; do
    PYLANCE_EXT_DIR=$(ls -d "$d"/ms-python.vscode-pylance-* 2>/dev/null | head -1)
    if [[ -n "$PYLANCE_EXT_DIR" ]]; then
        break
    fi
done

if [[ -n "$PYLANCE_EXT_DIR" && -f "$PYLANCE_EXT_DIR/dist/extension.bundle.js" ]]; then
    BUNDLE="$PYLANCE_EXT_DIR/dist/extension.bundle.js"
    PYLANCE_BUNDLE_BAK="${BUNDLE}.bak"
    cp "$BUNDLE" "$PYLANCE_BUNDLE_BAK"

    python3 -c "
import sys
with open('$BUNDLE', 'r') as f:
    content = f.read()

# The extension sets indexing=false when the workspace kind is 'Default' (web mode).
# Pattern: (!workspace.rootUri || workspace.kinds.includes(WellKnownWorkspaceKinds.Default)) && (settings.indexing = false)
old = \"(!_0x1ddc26[_0x2c1599(0xe8d)]||_0x1ddc26[_0x2c1599(0xcb1)]['includes'](_0x4b18f1[_0x2c1599(0x1417)]['Default']))&&(_0x42a990[_0x2c1599(0xd6b)]=![])\"
if old in content:
    new = 'void(0)' + ' ' * (len(old) - 7)
    content = content.replace(old, new, 1)
    with open('$BUNDLE', 'w') as f:
        f.write(content)
    print('Patched: disabled web-mode indexing restriction')
else:
    print('WARNING: Patch pattern not found (Pylance version may have changed)')
    sys.exit(0)
"
    log "Pylance extension patched"
else
    log "WARNING: Pylance extension not found at any known location, skipping patch"
fi

# Restart server to load installed extensions and patch
log "Restarting server..."
kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
sleep 2

"$VSCODE_CLI" serve-web \
    --host 127.0.0.1 \
    --port "$PORT" \
    --without-connection-token \
    --accept-server-license-terms \
    --server-data-dir "$SERVER_DATA_DIR" \
    > "$SERVER_DATA_DIR/server.log" 2>&1 &
SERVER_PID=$!

for i in $(seq 1 30); do
    if curl -sf -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null; then
        log "Server restarted"
        break
    fi
    sleep 2
done

# --- Step 7: Connect Puppeteer to trigger Pylance indexing ---
log "Connecting headless browser to trigger Pylance indexing..."
node "$SCRIPT_DIR/prebuild-pylance-connect.js" "$PORT" "$SERVER_DATA_DIR" "$WORKSPACE" "$TIMEOUT"
EXIT_CODE=$?

# --- Step 8: Print Pylance Language Server log ---
log "--- Pylance Language Server log ---"
PYLANCE_LOG=$(find "$SERVER_DATA_DIR/data/logs" -name "Python Language Server.log" 2>/dev/null | sort | tail -1)
if [[ -n "$PYLANCE_LOG" && -f "$PYLANCE_LOG" ]]; then
    cat "$PYLANCE_LOG"
else
    log "WARNING: Pylance log not found in $SERVER_DATA_DIR/data/logs"
fi
log "--- End of Pylance log ---"

if [[ $EXIT_CODE -eq 0 ]]; then
    log "Pylance prebuild indexing completed successfully"
else
    log "Pylance prebuild indexing finished with warnings (exit code $EXIT_CODE)"
fi

exit $EXIT_CODE
