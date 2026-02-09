#!/usr/bin/env node
//
// Connects a headless browser to a VS Code web server to trigger
// extension host activation and Pylance indexing.
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
        return {started: false, ready: false, files: 0};
    }

    var content = fs.readFileSync(logPath, "utf8");
    var started = content.indexOf("Pylance language server") !== -1;
    var foundFiles = content.match(/Found (\d+) source files/);
    var files = foundFiles ? parseInt(foundFiles[1], 10) : 0;
    var bgStarted = content.indexOf("background worker") !== -1 &&
        content.indexOf("started") !== -1;

    return {started: started, ready: bgStarted && files > 0, files: files};
}

function sleep(ms) {
    return new Promise(function(resolve) {
        setTimeout(resolve, ms);
    });
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
    log("Page loaded, waiting for Pylance to activate and index...");

    var startTime = Date.now();
    var timeoutMs = TIMEOUT_SEC * 1000;
    var pylanceReady = false;
    var lastStatus = "";

    while (Date.now() - startTime < timeoutMs) {
        await sleep(5000);

        var logPath = findPylanceLog(SERVER_DATA_DIR);
        var status = checkPylanceStatus(logPath);

        var statusMsg = "started=" + status.started +
            " ready=" + status.ready +
            " files=" + status.files;
        if (statusMsg !== lastStatus) {
            log("Pylance: " + statusMsg);
            lastStatus = statusMsg;
        }

        if (status.ready) {
            log("Pylance background workers started, waiting 30s for indexing...");
            await sleep(30000);
            pylanceReady = true;
            break;
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
