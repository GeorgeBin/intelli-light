#!/usr/bin/env node
// Invoked by Codex hooks. Reads the hook JSON payload on stdin, maps the
// event to a status, and atomically writes ~/.codex/statusbar/states.d/<session_id>.json
// (one file per session, so concurrent sessions never overwrite each other).
// Usage: node update.js <prompt|pre|post|permission|stop>

const fs = require("fs");
const os = require("os");
const path = require("path");
const cp = require("child_process");
const { appendPrivateFile, ensurePrivateDir, writeFileAtomic, writePrivateFile } = require("./fs-utils.js");

const dir = path.join(os.homedir(), ".codex", "statusbar");
const sessDir = path.join(dir, "sessions.d");
const statesDir = path.join(dir, "states.d");
const event = process.argv[2] || "";

const TOOL_LABELS = {
  Bash: "Running command", apply_patch: "Editing", read_file: "Reading",
  read: "Reading", view_image: "Viewing", update_plan: "Planning",
  spawn_agent: "Delegating", web_search: "Searching web",
};
const TRANSCRIPT_TAIL_BYTES = 1024 * 1024;
const truncate = (s, n) => (s.length <= n ? s : s.slice(0, n));
// Reject the bare "."/".." segments so a crafted session_id can't escape states.d via
// path.join normalization; the raw id is still stored verbatim in the JSON content.
const safeId = (s) => { const c = String(s || "").replace(/[^A-Za-z0-9_.-]/g, "").slice(0, 64); return (!c || c === "." || c === "..") ? "unknown" : c; };

function hasCompleteProposedPlan(value) {
  return /<proposed_plan>[\s\S]*<\/proposed_plan>/.test(String(value || ""));
}

function transcriptEndsWithPlan(transcriptPath) {
  if (!transcriptPath || typeof transcriptPath !== "string") return false;
  let fd;
  try {
    fd = fs.openSync(transcriptPath, "r");
    const stat = fs.fstatSync(fd);
    if (!stat.isFile() || stat.size <= 0) return false;
    const start = Math.max(0, stat.size - TRANSCRIPT_TAIL_BYTES);
    const buffer = Buffer.alloc(stat.size - start);
    fs.readSync(fd, buffer, 0, buffer.length, start);
    let text = buffer.toString("utf8");
    if (start > 0) text = text.slice(text.indexOf("\n") + 1);

    let currentMode = null;
    let lastAssistant = null;
    for (const line of text.split("\n")) {
      if (!line) continue;
      let item;
      try { item = JSON.parse(line); } catch { continue; }
      const payload = item && item.payload;
      if (item.type === "event_msg" && payload?.type === "task_started") {
        currentMode = payload.collaboration_mode_kind || null;
      }
      if (item.type === "response_item" && payload?.type === "message" && payload.role === "assistant") {
        const message = Array.isArray(payload.content)
          ? payload.content.map((part) => part?.text || "").join("\n") : "";
        lastAssistant = { message, mode: currentMode, phase: payload.phase || "" };
      }
    }
    return lastAssistant?.mode === "plan" && lastAssistant.phase === "final_answer"
      && hasCompleteProposedPlan(lastAssistant.message);
  } catch {
    return false;
  } finally {
    if (fd !== undefined) { try { fs.closeSync(fd); } catch {} }
  }
}

function stopCompletedPlan(payload) {
  if (hasCompleteProposedPlan(payload.last_assistant_message)) return true;
  return transcriptEndsWithPlan(payload.transcript_path);
}

function classifyOwnerKind(args) {
  return /(^|\s)app-server(\s|$)/.test(args) ? "global" : "session";
}

function forcedOwnerFromEnv() {
  if (process.env.CODEX_STATUSBAR_TEST !== "1") return null;
  const args = process.env.CODEX_STATUSBAR_TEST_OWNER_ARGS;
  if (!args) return null;
  const pid = Number(process.env.CODEX_STATUSBAR_TEST_OWNER_PID || 0);
  return {
    pid: Number.isFinite(pid) && pid > 0 ? pid : 0,
    kind: classifyOwnerKind(args),
  };
}

function ownerCodexProcess() {
  const forced = forcedOwnerFromEnv();
  if (forced) return forced;
  try {
    let pid = process.ppid;
    for (let i = 0; i < 6 && pid > 1; i++) {
      const out = cp.execFileSync("ps", ["-o", "ppid=,ucomm=,args=", "-p", String(pid)], { encoding: "utf8" }).trim();
      const match = out.match(/^(\d+)\s+(\S+)\s+([\s\S]*)$/);
      if (!match) break;
      const ppid = parseInt(match[1], 10);
      const ucomm = match[2];
      const args = match[3] || "";
      if (ucomm === "codex") return { pid, kind: classifyOwnerKind(args) };
      if (!Number.isInteger(ppid) || ppid <= 1) break;
      pid = ppid;
    }
  } catch {}
  return { pid: 0, kind: "unknown" };
}

let raw = "";
process.stdin.on("data", (d) => (raw += d));
process.stdin.on("end", () => {
  let p = {};
  try { p = JSON.parse(raw || "{}"); } catch {}

  if (process.env.CODEX_STATUSBAR_DEBUG === "1") {
    try {
      ensurePrivateDir(dir);
      appendPrivateFile(path.join(dir, "hooks.log"),
        `${new Date().toISOString()} [${event}] tool=${p.tool_name || "-"} mode=${p.permission_mode || "-"} keys=${Object.keys(p).join(",")}\n`);
    } catch {}
  }

  const sessionId = safeId(p.session_id);
  const statePath = path.join(statesDir, sessionId);
  let prev = {};
  try { prev = JSON.parse(fs.readFileSync(statePath, "utf8")); } catch {}

  const project = p.cwd ? path.basename(p.cwd) : prev.project || "";
  const ts = Math.floor(Date.now() / 1000);
  let state = "idle", label = "";
  let startedAt = prev.startedAt || 0;
  let pausedTotal = prev.pausedTotal || 0;
  let pauseStart = prev.pauseStart || 0;

  switch (event) {
    case "prompt":
      state = "thinking"; label = "Thinking…";
      startedAt = ts; pausedTotal = 0; pauseStart = 0;
      break;
    case "pre": {
      const t = p.tool_name || "";
      state = "tool"; label = TOOL_LABELS[t] || (t ? truncate(t, 20) : "Working…");
      if (!startedAt) startedAt = ts;
      break;
    }
    case "post":
      state = "thinking"; label = "Thinking…";
      if (!startedAt) startedAt = ts;
      if (pauseStart > 0) { pausedTotal += (ts - pauseStart); pauseStart = 0; }
      break;
    case "permission":
      state = "permission"; label = "Awaiting permission";
      if (!pauseStart) pauseStart = ts;   // don't overwrite an existing pause window
      break;
    case "stop":
      if (stopCompletedPlan(p)) {
        state = "waitingImplementation"; label = "Awaiting implementation";
      } else {
        state = "done"; label = "Done";
      }
      if (pauseStart > 0) { pausedTotal += (ts - pauseStart); }   // close any open pause first
      startedAt = 0; pauseStart = 0;
      break;
    default:
      return;
  }

  let ownerPid = prev.ownerPid || 0;
  let ownerKind = prev.ownerKind || "unknown";
  if (event === "prompt" || ownerKind === "unknown") {
    const owner = ownerCodexProcess();
    ownerPid = owner.pid;
    ownerKind = owner.kind;
  }

  const out = {
    provider: "codex", state, label, tool: p.tool_name || "", project,
    sessionId: p.session_id || "", transcript: p.transcript_path || prev.transcript || "",
    startedAt, pausedTotal, pauseStart, ts, ownerPid, ownerKind,
  };
  try {
    ensurePrivateDir(dir);
    ensurePrivateDir(statesDir);
    writeFileAtomic(statePath, JSON.stringify(out));
  } catch {}

  // Refresh the session liveness file (unchanged behavior).
  if (p.session_id) {
    try {
      ensurePrivateDir(dir);
      ensurePrivateDir(sessDir);
      writePrivateFile(path.join(sessDir, safeId(p.session_id)), "");
    } catch {}
  }
});
