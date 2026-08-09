import test from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const REPO = path.resolve(import.meta.dirname, "..");
const UPDATE = path.join(REPO, "hooks", "claude-update.js");
const LIFECYCLE = path.join(REPO, "hooks", "claude-lifecycle.js");

function withTempHome() {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "claude-statusbar-"));
  return { home, [Symbol.dispose]: () => fs.rmSync(home, { recursive: true, force: true }) };
}

function run(home, script, event, payload, extraEnv = {}) {
  return spawnSync(process.execPath, [script, event], {
    input: JSON.stringify(payload),
    env: { ...process.env, HOME: home, CODEX_STATUSBAR_TEST: "1", ...extraEnv },
    encoding: "utf8",
  });
}

function statePath(home, id) {
  return path.join(home, ".claude", "statusbar", "states.d", id);
}

function readState(home, id) {
  return JSON.parse(fs.readFileSync(statePath(home, id), "utf8"));
}

test("Claude events map to unified states without hook output", () => {
  using h = withTempHome();
  const payload = { session_id: "claude-a", cwd: "/work/projectA", transcript_path: "/tmp/a.jsonl" };
  for (const [event, expected] of [
    ["prompt", "working"], ["pre", "working"], ["post", "working"],
    ["post-failure", "working"], ["permission", "waitingApproval"], ["stop", "done"],
  ]) {
    const result = run(h.home, UPDATE, event, { ...payload, tool_name: "Bash" }, {
      CLAUDE_STATUSBAR_TEST_OWNER_PID: "4321",
    });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout, "", `${event} must not inject stdout`);
    const state = readState(h.home, "claude-a");
    assert.equal(state.provider, "claude");
    assert.equal(state.state, expected, event);
    assert.equal(state.project, "projectA");
    assert.equal(state.ownerPid, 4321);
  }
});

test("Claude permission pause closes on PostToolUseFailure", () => {
  using h = withTempHome();
  const payload = { session_id: "pause", cwd: "/work/p" };
  run(h.home, UPDATE, "prompt", payload);
  run(h.home, UPDATE, "permission", payload);
  const before = readState(h.home, "pause");
  assert.ok(before.pauseStart > 0);
  run(h.home, UPDATE, "post-failure", payload);
  const after = readState(h.home, "pause");
  assert.equal(after.state, "working");
  assert.equal(after.pauseStart, 0);
});

test("SessionStart registers and SessionEnd removes only its Claude session", () => {
  using h = withTempHome();
  assert.equal(run(h.home, LIFECYCLE, "start", { session_id: "one" }).status, 0);
  run(h.home, UPDATE, "prompt", { session_id: "one", cwd: "/p/one" });
  run(h.home, UPDATE, "prompt", { session_id: "two", cwd: "/p/two" });
  const sessionDir = path.join(h.home, ".claude", "statusbar", "sessions.d");
  assert.ok(fs.existsSync(path.join(sessionDir, "one")));
  assert.equal(run(h.home, LIFECYCLE, "end", { session_id: "one" }).status, 0);
  assert.ok(!fs.existsSync(path.join(sessionDir, "one")));
  assert.ok(!fs.existsSync(statePath(h.home, "one")));
  assert.ok(fs.existsSync(path.join(sessionDir, "two")), "other session remains registered");
  assert.ok(fs.existsSync(statePath(h.home, "two")), "other state remains");
});

test("Claude hook sanitizes traversal IDs and writes private files", () => {
  using h = withTempHome();
  const priorUmask = process.umask(0o022);
  try {
    assert.equal(run(h.home, UPDATE, "prompt", { session_id: "..", cwd: "/p" }).status, 0);
  } finally {
    process.umask(priorUmask);
  }
  const statusDir = path.join(h.home, ".claude", "statusbar");
  const state = statePath(h.home, "unknown");
  assert.equal(readState(h.home, "unknown").sessionId, "..");
  assert.equal(fs.statSync(statusDir).mode & 0o777, 0o700);
  assert.equal(fs.statSync(state).mode & 0o777, 0o600);
});
