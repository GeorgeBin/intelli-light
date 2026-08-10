#!/usr/bin/env node
// Linux-only lifecycle hook. It owns session/state files and deliberately does not
// launch a GUI; the systemd --user daemon runs independently.

const fs = require("fs");
const os = require("os");
const path = require("path");
const fsUtils = fs.existsSync(path.join(__dirname, "fs-utils.js")) ? "./fs-utils.js" : "../fs-utils.js";
const { ensurePrivateDir, writePrivateFile } = require(fsUtils);

const provider = process.argv[2];
const event = process.argv[3];
if (!new Set(["codex", "claude"]).has(provider) || !new Set(["start", "end"]).has(event)) {
  process.exit(2);
}

const root = path.join(os.homedir(), `.${provider}`, "statusbar");
const sessionsDir = path.join(root, "sessions.d");
const statesDir = path.join(root, "states.d");
const safeId = (value) => {
  const clean = String(value || "").replace(/[^A-Za-z0-9_.-]/g, "").slice(0, 64);
  return (!clean || clean === "." || clean === "..") ? "unknown" : clean;
};

let input = "";
let completed = false;
process.stdin.on("data", (data) => (input += data));
process.stdin.on("end", run);
process.stdin.on("error", run);
setTimeout(run, 1000);

function run() {
  if (completed) return;
  completed = true;
  let id = "unknown";
  try { id = safeId(JSON.parse(input || "{}").session_id); } catch {}

  try {
    ensurePrivateDir(root);
    ensurePrivateDir(sessionsDir);
    ensurePrivateDir(statesDir);
    if (event === "end") {
      fs.rmSync(path.join(sessionsDir, id), { force: true });
      fs.rmSync(path.join(statesDir, id), { force: true });
    } else {
      const cutoff = Date.now() - 3600_000;
      for (const directory of [sessionsDir, statesDir]) {
        for (const file of fs.readdirSync(directory)) {
          const filePath = path.join(directory, file);
          if (fs.statSync(filePath).mtimeMs < cutoff) fs.rmSync(filePath, { force: true });
        }
      }
      writePrivateFile(path.join(sessionsDir, id), "");
    }
  } catch {}
  process.exit(0);
}
