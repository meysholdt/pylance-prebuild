#!/usr/bin/env bash
#
# Prebuild script that starts a headless VS Code server, installs Pylance,
# and triggers indexing via a headless browser connection.
#
# The VS Code extension host only activates when a client connects,
# so we use Puppeteer to open the workspace in a headless browser.
#
set -euo pipefail

WORKSPACE="${1:-/workspaces/pylance-prebuild}"
PORT="${PREBUILD_VSCODE_PORT:-19876}"
TIMEOUT="${PREBUILD_TIMEOUT:-180}"
SERVER_DATA_DIR="/tmp/vscode-prebuild-$$"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# --- Step 0: Ensure Puppeteer's Chrome is installed ---
if [[ ! -d "$HOME/.cache/puppeteer/chrome" ]]; then
    log "Installing Chrome for Puppeteer..."
    node node_modules/puppeteer/install.mjs 2>&1 | tail -3
fi

cleanup() {
    log "Cleaning up..."
    if [[ -n "${SERVER_PID:-}" ]]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    rm -rf "$SERVER_DATA_DIR"
}
trap cleanup EXIT

# --- Step 1: Find the VS Code CLI binary ---
log "Finding VS Code CLI..."
VSCODE_CLI=""
for f in /home/vscode/.vscode-server/code-*; do
    if [[ -x "$f" && ! -d "$f" ]]; then
        VSCODE_CLI="$f"
        break
    fi
done

if [[ -z "$VSCODE_CLI" ]]; then
    log "ERROR: VS Code CLI not found in /home/vscode/.vscode-server/"
    exit 1
fi
log "Using VS Code CLI: $VSCODE_CLI"

# --- Step 2: Find the code-server binary for extension installation ---
SERVE_WEB_DIR=""
for d in /home/vscode/.vscode/cli/serve-web/*/; do
    if [[ -x "${d}bin/code-server" ]]; then
        SERVE_WEB_DIR="$d"
        break
    fi
done

# --- Step 3: Start serve-web to download the server if needed ---
log "Starting VS Code web server on port $PORT..."
mkdir -p "$SERVER_DATA_DIR"

"$VSCODE_CLI" serve-web \
    --host 127.0.0.1 \
    --port "$PORT" \
    --without-connection-token \
    --accept-server-license-terms \
    --server-data-dir "$SERVER_DATA_DIR" \
    > "$SERVER_DATA_DIR/server.log" 2>&1 &
SERVER_PID=$!

# Wait for the server to be ready (it may need to download assets first)
log "Waiting for server to be ready..."
for i in $(seq 1 60); do
    if curl -sf -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null; then
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/")
        if [[ "$HTTP_CODE" == "200" ]]; then
            log "Server is ready (HTTP $HTTP_CODE)"
            break
        fi
        log "Server downloading assets (HTTP $HTTP_CODE)..."
    fi
    sleep 2
done

if ! curl -sf -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null; then
    log "ERROR: Server failed to start within 120s"
    cat "$SERVER_DATA_DIR/server.log" | tail -20
    exit 1
fi

# --- Step 4: Find the serve-web code-server and install extensions ---
# After serve-web downloads, the code-server binary should be available
if [[ -z "$SERVE_WEB_DIR" ]]; then
    for d in /home/vscode/.vscode/cli/serve-web/*/; do
        if [[ -x "${d}bin/code-server" ]]; then
            SERVE_WEB_DIR="$d"
            break
        fi
    done
fi

if [[ -n "$SERVE_WEB_DIR" ]]; then
    log "Installing Pylance extensions..."
    "${SERVE_WEB_DIR}bin/code-server" \
        --accept-server-license-terms \
        --server-data-dir "$SERVER_DATA_DIR" \
        --install-extension ms-python.python \
        --install-extension ms-python.vscode-pylance \
        2>&1 | grep -E "installed|Installing" || true

    # Configure settings for index persistence
    mkdir -p "$SERVER_DATA_DIR/data/Machine"
    cat > "$SERVER_DATA_DIR/data/Machine/settings.json" << 'SETTINGS'
{
    "python.analysis.persistAllIndices": true,
    "python.analysis.indexing": true,
    "python.defaultInterpreterPath": "/usr/local/bin/python"
}
SETTINGS
    log "Extensions installed and settings configured"
else
    log "WARNING: code-server binary not found, extensions may not be installed"
fi

# Restart the server so it picks up the newly installed extensions
log "Restarting server with extensions..."
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

# Wait for restart
for i in $(seq 1 30); do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/" 2>/dev/null || echo "000")
    if [[ "$HTTP_CODE" == "200" ]]; then
        break
    fi
    sleep 2
done

# --- Step 5: Connect Puppeteer to trigger Pylance indexing ---
log "Connecting headless browser to trigger Pylance indexing..."
node "$SCRIPT_DIR/prebuild-pylance-connect.js" "$PORT" "$SERVER_DATA_DIR" "$WORKSPACE" "$TIMEOUT"
EXIT_CODE=$?

# --- Step 6: Copy index data to the browser server data dir ---
# so it's available when the real VS Code server starts
BROWSER_DATA="/home/vscode/.vscode-browser-server"
if [[ -d "$SERVER_DATA_DIR/extensions" && -d "$BROWSER_DATA" ]]; then
    log "Copying extension data to browser server..."
    # Copy any persisted index data from globalStorage
    if [[ -d "$SERVER_DATA_DIR/data/User/globalStorage/ms-python.vscode-pylance" ]]; then
        mkdir -p "$BROWSER_DATA/data/User/globalStorage/"
        cp -r "$SERVER_DATA_DIR/data/User/globalStorage/ms-python.vscode-pylance" \
              "$BROWSER_DATA/data/User/globalStorage/" 2>/dev/null || true
        log "Copied Pylance index data to browser server"
    fi
fi

if [[ $EXIT_CODE -eq 0 ]]; then
    log "Pylance prebuild indexing completed successfully"
else
    log "Pylance prebuild indexing finished with warnings (exit code $EXIT_CODE)"
fi

exit $EXIT_CODE
