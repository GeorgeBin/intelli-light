#!/usr/bin/env node
// Claude Code status hook. Writes one provider-tagged state file per session and
// never prints to stdout, so it cannot inject context or alter hook decisions.

const fs = require("fs");
const os = require("os");
const path = require("path");
const cp = require("child_process");
const { ensurePrivateDir, writeFileAtomic, writePrivateFile } = require("./fs-utils.js");

const dir = path.join(os.homedir(), ".claude", "statusbar");
const statesDir = path.join(dir, "states.d");
const sessionsDir = path.join(dir, "sessions.d");
const event = process.argv[2] || "";
const truncate = (s, n) => (s.length <= n ? s : s.slice(0, n));
const safeId = (s) => {
  const clean = String(s || "").replace(/[^A-Za-z0-9_.-]/g, "").slice(0, 64);
  return (!clean || clean === "." || clean === "..") ? "unknown" : clean;
};

function ownerClaudeProcess() {
  if (process.env.CODEX_STATUSBAR_TEST === "1" && process.env.CLAUDE_STATUSBAR_TEST_OWNER_PID) {
    const pid = Number(process.env.CLAUDE_STATUSBAR_TEST_OWNER_PID);
    return Number.isFinite(pid) && pid > 0 ? pid : 0;
  }
  try {
    let pid = process.ppid;
    for (let i = 0; i < 6 && pid > 1; i++) {
      const out = cp.execFileSync("ps", ["-o", "ppid=,ucomm=", "-p", String(pid)], { encoding: "utf8" }).trim();
      const match = out.match(/^(\d+)\s+(\S+)/);
      if (!match) break;
      if (match[2] === "claude") return pid;
      pid = Number(match[1]);
    }
  } catch {}
  return 0;
}

let raw = "";
process.stdin.on("data", (data) => (raw += data));
process.stdin.on("end", () => {
  let payload = {};
  try { payload = JSON.parse(raw || "{}"); } catch {}

  const sessionId = safeId(payload.session_id);
  const statePath = path.join(statesDir, sessionId);
  let previous = {};
  try { previous = JSON.parse(fs.readFileSync(statePath, "utf8")); } catch {}

  const timestamp = Math.floor(Date.now() / 1000);
  const project = payload.cwd ? path.basename(payload.cwd) : previous.project || "";
  let state = "idle";
  let label = "";
  let startedAt = previous.startedAt || 0;
  let pausedTotal = previous.pausedTotal || 0;
  let pauseStart = previous.pauseStart || 0;

  switch (event) {
    case "prompt":
      state = "working"; label = "Working…";
      startedAt = timestamp; pausedTotal = 0; pauseStart = 0;
      break;
    case "pre": {
      const tool = String(payload.tool_name || "");
      state = "working"; label = tool ? truncate(tool, 20) : "Working…";
      if (!startedAt) startedAt = timestamp;
      break;
    }
    case "post":
    case "post-failure":
      state = "working"; label = "Working…";
      if (!startedAt) startedAt = timestamp;
      if (pauseStart > 0) { pausedTotal += timestamp - pauseStart; pauseStart = 0; }
      break;
    case "permission":
      state = "waitingApproval"; label = "Awaiting permission";
      if (!startedAt) startedAt = timestamp;
      if (!pauseStart) pauseStart = timestamp;
      break;
    case "stop":
      state = "done"; label = "Done";
      if (pauseStart > 0) pausedTotal += timestamp - pauseStart;
      startedAt = 0; pauseStart = 0;
      break;
    case "stop-failure":
      state = "error"; label = "Error";
      if (pauseStart > 0) pausedTotal += timestamp - pauseStart;
      startedAt = 0; pauseStart = 0;
      break;
    default:
      return;
  }

  const output = {
    provider: "claude", state, label, tool: payload.tool_name || "", project,
    sessionId: payload.session_id || "", transcript: payload.transcript_path || previous.transcript || "",
    startedAt, pausedTotal, pauseStart, ts: timestamp,
    ownerPid: previous.ownerPid || ownerClaudeProcess(), ownerKind: "session",
  };
  try {
    ensurePrivateDir(dir);
    ensurePrivateDir(statesDir);
    ensurePrivateDir(sessionsDir);
    writeFileAtomic(statePath, JSON.stringify(output));
    if (payload.session_id) writePrivateFile(path.join(sessionsDir, sessionId), "");
  } catch {}
});
