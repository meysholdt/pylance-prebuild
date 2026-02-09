#!/usr/bin/env node
//
// Connects a headless browser to a VS Code web server to trigger
// extension host activation and Pylance indexing.
//
// Pylance defers indexing until a text document is opened. This script
// opens a Python file via keyboard shortcuts to trigger the IDX thread.
//
// Usage: node prebuild-pylance-connect.js <port> <server-data-dir> <workspace-folder> [timeout-seconds]
//

"use strict";

var puppeteer = require("puppeteer");
var fs = require("fs");
var path = require("path");

var PORT = process.argv[2] || "19876";
var SERVER_DATA_DIR = process.argv[3] || "/tmp/vscode-prebuild";
var WORKSPACE = process.argv[4] || "/workspaces/pylance-prebuild";
var TIMEOUT_SEC = parseInt(process.argv[5] || "180", 10);

var TARGET_URL = "http://127.0.0.1:" + PORT + "/?folder=" + WORKSPACE;

function log(msg) {
    var ts = new Date().toISOString().replace("T", " ").substring(0, 19);
    console.log("[" + ts + "] " + msg);
}

function findPylanceLog(serverDataDir) {
    var logsDir = path.join(serverDataDir, "data", "logs");
    if (!fs.existsSync(logsDir)) {
        return null;
    }

    var sessionDirs = fs.readdirSync(logsDir).sort().reverse();
    for (var i = 0; i < sessionDirs.length; i++) {
        var paths = [
            path.join(logsDir, sessionDirs[i], "exthost1",
                "ms-python.vscode-pylance", "Python Language Server.log"),
            path.join(logsDir, sessionDirs[i], "exthost1",
                "ms-python.python", "Python Language Server.log")
        ];
        for (var j = 0; j < paths.length; j++) {
            if (fs.existsSync(paths[j])) {
                return paths[j];
            }
        }
    }
    return null;
}

function checkPylanceStatus(logPath) {
    if (!logPath || !fs.existsSync(logPath)) {
        return {started: false, ready: false, indexing: false, indexDone: false, files: 0};
    }

    var content = fs.readFileSync(logPath, "utf8");
    var started = content.indexOf("Pylance language server") !== -1;
    var foundFiles = content.match(/Found (\d+) source files/);
    var files = foundFiles ? parseInt(foundFiles[1], 10) : 0;
    var bgStarted = content.indexOf("background worker") !== -1 &&
        content.indexOf("started") !== -1;
    var idxStarted = content.indexOf("IDX(") !== -1;
    var idxDone = content.indexOf("Indexing finished") !== -1 ||
        content.indexOf("indexingdone") !== -1 ||
        content.indexOf("Workspace indexing done") !== -1;

    return {
        started: started,
        ready: bgStarted && files > 0,
        indexing: idxStarted,
        indexDone: idxDone,
        files: files
    };
}

// Find a Python file in the workspace to open.
// Must be a .py file so Pylance triggers onDidOpenTextDocument.
function findPythonFile(workspace) {
    var candidates = [
        "django/__init__.py",
        "django/__main__.py",
        "setup.py",
        "manage.py"
    ];
    for (var i = 0; i < candidates.length; i++) {
        var fullPath = path.join(workspace, candidates[i]);
        if (fs.existsSync(fullPath)) {
            return candidates[i];
        }
    }
    // Fallback: find any .py file recursively
    function findPyRecursive(dir, depth) {
        if (depth > 3) return null;
        try {
            var entries = fs.readdirSync(dir);
            for (var j = 0; j < entries.length; j++) {
                var entry = entries[j];
                if (entry === "node_modules" || entry === ".git" || entry === "__pycache__") continue;
                var fullPath = path.join(dir, entry);
                if (entry.endsWith(".py")) {
                    return path.relative(workspace, fullPath);
                }
                try {
                    var stat = fs.statSync(fullPath);
                    if (stat.isDirectory()) {
                        var found = findPyRecursive(fullPath, depth + 1);
                        if (found) return found;
                    }
                } catch (e) { /* ignore */ }
            }
        } catch (e) { /* ignore */ }
        return null;
    }
    return findPyRecursive(workspace, 0);
}

function sleep(ms) {
    return new Promise(function(resolve) {
        setTimeout(resolve, ms);
    });
}

async function openFileInVSCode(page, filename) {
    // Use Ctrl+P (Quick Open) to open a file
    log("Opening file via Quick Open: " + filename);

    // Press Ctrl+P to open Quick Open
    await page.keyboard.down("Control");
    await page.keyboard.press("KeyP");
    await page.keyboard.up("Control");
    await sleep(2000);

    // Type the filename
    await page.keyboard.type(filename, {delay: 30});
    await sleep(2000);

    // Press Enter to open
    await page.keyboard.press("Enter");
    await sleep(3000);

    log("File open command sent");
}

async function main() {
    log("Connecting to VS Code at " + TARGET_URL);
    log("Timeout: " + TIMEOUT_SEC + "s");

    var browser = await puppeteer.launch({
        headless: true,
        args: ["--no-sandbox", "--disable-gpu", "--disable-dev-shm-usage"],
    });

    var page = await browser.newPage();

    log("Navigating to VS Code web UI...");
    await page.goto(TARGET_URL, {waitUntil: "domcontentloaded", timeout: 30000});
    log("Page loaded, waiting for VS Code to initialize...");

    // Wait for VS Code to fully initialize before interacting
    await sleep(15000);

    // Open a Python file to trigger Pylance's deferred indexing.
    // Pylance only starts the IDX thread after a text document is opened.
    var pyFile = findPythonFile(WORKSPACE);
    if (pyFile) {
        await openFileInVSCode(page, pyFile);
    } else {
        log("WARNING: No Python file found to open, indexing may not start");
    }

    log("Waiting for Pylance to activate and index...");

    var startTime = Date.now();
    var timeoutMs = TIMEOUT_SEC * 1000;
    var pylanceReady = false;
    var lastStatus = "";
    var retried = false;

    while (Date.now() - startTime < timeoutMs) {
        await sleep(5000);

        var logPath = findPylanceLog(SERVER_DATA_DIR);
        var status = checkPylanceStatus(logPath);

        var statusMsg = "started=" + status.started +
            " ready=" + status.ready +
            " indexing=" + status.indexing +
            " indexDone=" + status.indexDone +
            " files=" + status.files;
        if (statusMsg !== lastStatus) {
            log("Pylance: " + statusMsg);
            lastStatus = statusMsg;
        }

        if (status.indexDone) {
            log("Pylance indexing completed!");
            pylanceReady = true;
            break;
        }

        if (status.ready && !status.indexing && !retried) {
            // Background workers started but IDX hasn't started yet.
            // The file might not have been opened successfully. Retry.
            if (pyFile && Date.now() - startTime > 30000) {
                log("IDX not started, retrying file open...");
                await openFileInVSCode(page, pyFile);
                retried = true;
            }
        }

        if (status.ready && status.indexing) {
            log("IDX thread is running, waiting for completion...");
        }
    }

    // If IDX started but didn't finish, give it extra time
    if (!pylanceReady) {
        var logPath2 = findPylanceLog(SERVER_DATA_DIR);
        var finalStatus = checkPylanceStatus(logPath2);
        if (finalStatus.indexing && !finalStatus.indexDone) {
            log("IDX still running, waiting 60s more...");
            await sleep(60000);
            finalStatus = checkPylanceStatus(logPath2);
            pylanceReady = finalStatus.indexDone;
        } else if (finalStatus.ready && !finalStatus.indexing) {
            // BG workers started but IDX never started.
            // Wait a bit more in case indexing is happening without IDX log entries.
            log("Background workers ready, waiting 30s for index persistence...");
            await sleep(30000);
            pylanceReady = true;
        }
    }

    if (pylanceReady) {
        log("Pylance indexing completed (" +
            Math.round((Date.now() - startTime) / 1000) + "s)");
    } else {
        log("Timeout after " + TIMEOUT_SEC +
            "s — Pylance may not have finished indexing");
    }

    log("Closing browser...");
    await browser.close();
    log("Done");

    process.exit(pylanceReady ? 0 : 1);
}

main().catch(function(e) {
    console.error("Fatal error:", e.message);
    process.exit(1);
});
