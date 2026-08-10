#!/usr/bin/env node
// Claude SessionStart/SessionEnd lifecycle hook. It is deliberately silent and
// only owns files below ~/.claude/statusbar.

const fs = require("fs");
const os = require("os");
const path = require("path");
const cp = require("child_process");
const fsUtils = fs.existsSync(path.join(__dirname, "fs-utils.js")) ? "./fs-utils.js" : "../fs-utils.js";
const { ensurePrivateDir, writePrivateFile } = require(fsUtils);

const BUNDLE_ID = "io.github.georgebin.intelli-light";
const EXEC = "IntelliLight";
const dir = path.join(os.homedir(), ".claude", "statusbar");
const sessionsDir = path.join(dir, "sessions.d");
const statesDir = path.join(dir, "states.d");
const event = process.argv[2] || "";
const testMode = process.env.CODEX_STATUSBAR_TEST === "1";
const safeId = (s) => {
  const clean = String(s || "").replace(/[^A-Za-z0-9_.-]/g, "").slice(0, 64);
  return (!clean || clean === "." || clean === "..") ? "unknown" : clean;
};
const running = () => {
  if (testMode) return false;
  try { cp.execFileSync("pgrep", ["-x", EXEC], { stdio: "ignore" }); return true; } catch { return false; }
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
    ensurePrivateDir(dir);
    ensurePrivateDir(sessionsDir);
    ensurePrivateDir(statesDir);
    if (event === "end") {
      fs.rmSync(path.join(sessionsDir, id), { force: true });
      fs.rmSync(path.join(statesDir, id), { force: true });
    } else if (event === "start") {
      if (!running()) {
        for (const file of fs.readdirSync(sessionsDir)) {
          fs.rmSync(path.join(sessionsDir, file), { force: true });
        }
        const cutoff = Date.now() - 3600_000;
        for (const file of fs.readdirSync(statesDir)) {
          const filePath = path.join(statesDir, file);
          if (fs.statSync(filePath).mtimeMs < cutoff) fs.rmSync(filePath, { force: true });
        }
      }
      writePrivateFile(path.join(sessionsDir, id), "");
      if (!testMode) cp.spawn("open", ["-g", "-b", BUNDLE_ID], { stdio: "ignore", detached: true }).unref();
    }
  } catch {}
  process.exit(0);
}
