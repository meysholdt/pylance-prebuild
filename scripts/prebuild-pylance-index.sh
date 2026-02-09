#!/usr/bin/env bash
#
# Prebuild script that starts a headless VS Code web server, installs Pylance,
# and triggers indexing via a headless browser connection.
#
# The VS Code extension host only activates when a client connects,
# so we use Puppeteer to open the workspace in a headless browser.
#
# During a prebuild the VS Code CLI (which provides `serve-web`) is not
# pre-installed. This script downloads it from update.code.visualstudio.com,
# matching the commit used by the environment's vscode-browser-agent.
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
    rm -rf "$SERVER_DATA_DIR"
}
trap cleanup EXIT

# --- Step 0: Ensure Puppeteer's Chrome is installed ---
if [[ ! -d "$HOME/.cache/puppeteer/chrome" ]]; then
    log "Installing Chrome for Puppeteer..."
    node node_modules/puppeteer/install.mjs 2>&1 | tail -3
fi

# --- Step 1: Find or download the VS Code CLI ---
log "Finding VS Code CLI..."
VSCODE_CLI=""

# Try existing locations first
for f in /home/vscode/.vscode-server/code-*; do
    if [[ -x "$f" && ! -d "$f" ]]; then
        VSCODE_CLI="$f"
        break
    fi
done

if [[ -z "$VSCODE_CLI" ]]; then
    log "VS Code CLI not found locally, downloading..."

    # Detect the commit hash from the running vscode-browser-agent, the
    # shared VS Code server installation, or fall back to latest stable.
    COMMIT=""

    # Try 1: running vscode-browser-agent process
    AGENT_CMD=$(ps -eo args 2>/dev/null | grep "vscode-browser-agent run" | grep -v grep | head -1 || true)
    if [[ -n "$AGENT_CMD" ]]; then
        COMMIT=$(echo "$AGENT_CMD" | grep -oP '(?<=--commit )\S+' || true)
    fi

    # Try 2: shared VS Code server path (only if directory actually exists)
    if [[ -z "$COMMIT" && -d "/usr/local/gitpod/shared/vscode/vscode-server/bin" ]]; then
        COMMIT=$(ls /usr/local/gitpod/shared/vscode/vscode-server/bin/ 2>/dev/null | head -1 || true)
    fi

    # Try 3: product.json from any installed server
    if [[ -z "$COMMIT" ]]; then
        for pj in /home/vscode/.vscode-server/cli/serve-web/*/product.json \
                  /home/vscode/.vscode-browser-server/product.json; do
            if [[ -f "$pj" ]]; then
                COMMIT=$(grep -oP '"commit"\s*:\s*"\K[a-f0-9]+' "$pj" 2>/dev/null | head -1 || true)
                [[ -n "$COMMIT" ]] && break
            fi
        done
    fi

    # Fallback: latest stable
    if [[ -z "$COMMIT" ]]; then
        COMMIT="latest"
    fi

    # Detect architecture
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  CLI_ARCH="x64" ;;
        aarch64) CLI_ARCH="arm64" ;;
        armv7l)  CLI_ARCH="armhf" ;;
        *)       CLI_ARCH="$ARCH" ;;
    esac

    if [[ "$COMMIT" == "latest" ]]; then
        DOWNLOAD_URL="https://update.code.visualstudio.com/latest/cli-linux-${CLI_ARCH}/stable"
    else
        DOWNLOAD_URL="https://update.code.visualstudio.com/commit:${COMMIT}/cli-linux-${CLI_ARCH}/stable"
    fi

    log "Downloading VS Code CLI (commit: $COMMIT, arch: $CLI_ARCH)..."
    CLI_DIR="/tmp/vscode-cli-$$"
    mkdir -p "$CLI_DIR"
    curl -sfL "$DOWNLOAD_URL" | tar xz -C "$CLI_DIR"

    VSCODE_CLI="$CLI_DIR/code"
    if [[ ! -x "$VSCODE_CLI" ]]; then
        log "ERROR: Failed to download VS Code CLI"
        ls -la "$CLI_DIR/" 2>/dev/null
        exit 1
    fi
    log "Downloaded VS Code CLI to $VSCODE_CLI"
fi

log "Using VS Code CLI: $VSCODE_CLI"

# --- Step 2: Start serve-web (downloads the server on first run) ---
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
    tail -20 "$SERVER_DATA_DIR/server.log"
    exit 1
fi

# --- Step 3: Install Pylance extensions ---
# Find the code-server binary that serve-web downloaded
SERVE_WEB_DIR=""
for d in /home/vscode/.vscode/cli/serve-web/*/; do
    if [[ -x "${d}bin/code-server" ]]; then
        SERVE_WEB_DIR="$d"
        break
    fi
done

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

# --- Step 4: Connect Puppeteer to trigger Pylance indexing ---
log "Connecting headless browser to trigger Pylance indexing..."
node "$SCRIPT_DIR/prebuild-pylance-connect.js" "$PORT" "$SERVER_DATA_DIR" "$WORKSPACE" "$TIMEOUT"
EXIT_CODE=$?

# --- Step 5: Copy index data to the browser server data dir ---
# so it's available when the real VS Code server starts
BROWSER_DATA="/home/vscode/.vscode-browser-server"
if [[ -d "$SERVER_DATA_DIR/data/User/globalStorage/ms-python.vscode-pylance" ]]; then
    mkdir -p "$BROWSER_DATA/data/User/globalStorage/"
    cp -r "$SERVER_DATA_DIR/data/User/globalStorage/ms-python.vscode-pylance" \
          "$BROWSER_DATA/data/User/globalStorage/" 2>/dev/null || true
    log "Copied Pylance index data to browser server"
fi

if [[ $EXIT_CODE -eq 0 ]]; then
    log "Pylance prebuild indexing completed successfully"
else
    log "Pylance prebuild indexing finished with warnings (exit code $EXIT_CODE)"
fi

exit $EXIT_CODE
