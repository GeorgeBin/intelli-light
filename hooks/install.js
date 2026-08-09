#!/usr/bin/env node
// Installs Codex and Claude Code user-scope hooks by merging only the entries owned
// by this app. Re-running is idempotent and preserves unrelated configuration.

const fs = require("fs");
const os = require("os");
const path = require("path");
const { copyPrivateFile, ensurePrivateDir, writeFileAtomic } = require("./fs-utils.js");

const home = os.homedir();
const node = process.execPath;

function readConfiguration(configPath) {
  if (!fs.existsSync(configPath)) return { object: {}, backedUp: false };
  const object = JSON.parse(fs.readFileSync(configPath, "utf8"));
  if (!object || Array.isArray(object) || typeof object !== "object") {
    throw new Error(`${configPath} must contain a JSON object`);
  }
  const backup = configPath + ".bak-statusbar";
  let backedUp = false;
  if (!fs.existsSync(backup)) {
    copyPrivateFile(configPath, backup);
    backedUp = true;
  }
  return { object, backedUp };
}

function stripOwned(entries, marker) {
  return (Array.isArray(entries) ? entries : [])
    .map((entry) => ({
      ...entry,
      hooks: (Array.isArray(entry.hooks) ? entry.hooks : [])
        .filter((hook) => !String(hook.command || "").includes(marker)),
    }))
    .filter((entry) => entry.hooks.length > 0);
}

function addHook(object, marker, event, command, matcher) {
  object.hooks = object.hooks && typeof object.hooks === "object" && !Array.isArray(object.hooks)
    ? object.hooks : {};
  const entries = stripOwned(object.hooks[event], marker);
  const group = { hooks: [{ type: "command", command }] };
  if (matcher !== undefined) group.matcher = matcher;
  entries.push(group);
  object.hooks[event] = entries;
}

function installCodex() {
  const statusDir = path.join(home, ".codex", "statusbar");
  const configPath = path.join(home, ".codex", "hooks.json");
  ensurePrivateDir(statusDir);
  for (const name of ["update.js", "lifecycle.js", "fs-utils.js"]) {
    copyPrivateFile(path.join(__dirname, name), path.join(statusDir, name));
  }
  const { object, backedUp } = readConfiguration(configPath);
  const command = (script, event) => `"${node}" "${path.join(statusDir, script)}" ${event}`;
  addHook(object, statusDir, "SessionStart", command("lifecycle.js", "start"));
  addHook(object, statusDir, "UserPromptSubmit", command("update.js", "prompt"));
  addHook(object, statusDir, "PreToolUse", command("update.js", "pre"), "*");
  addHook(object, statusDir, "PostToolUse", command("update.js", "post"), "*");
  addHook(object, statusDir, "PermissionRequest", command("update.js", "permission"));
  addHook(object, statusDir, "Stop", command("update.js", "stop"));
  writeFileAtomic(configPath, JSON.stringify(object, null, 2) + "\n");
  return { configPath, statusDir, backedUp };
}

function installClaude() {
  const statusDir = path.join(home, ".claude", "statusbar");
  const configPath = path.join(home, ".claude", "settings.json");
  ensurePrivateDir(statusDir);
  copyPrivateFile(path.join(__dirname, "claude-update.js"), path.join(statusDir, "claude-update.js"));
  copyPrivateFile(path.join(__dirname, "claude-lifecycle.js"), path.join(statusDir, "claude-lifecycle.js"));
  copyPrivateFile(path.join(__dirname, "fs-utils.js"), path.join(statusDir, "fs-utils.js"));
  const { object, backedUp } = readConfiguration(configPath);
  const command = (script, event) => `"${node}" "${path.join(statusDir, script)}" ${event}`;
  addHook(object, statusDir, "SessionStart", command("claude-lifecycle.js", "start"));
  addHook(object, statusDir, "UserPromptSubmit", command("claude-update.js", "prompt"));
  addHook(object, statusDir, "PreToolUse", command("claude-update.js", "pre"));
  addHook(object, statusDir, "PostToolUse", command("claude-update.js", "post"));
  addHook(object, statusDir, "PostToolUseFailure", command("claude-update.js", "post-failure"));
  addHook(object, statusDir, "PermissionRequest", command("claude-update.js", "permission"));
  addHook(object, statusDir, "Stop", command("claude-update.js", "stop"));
  addHook(object, statusDir, "SessionEnd", command("claude-lifecycle.js", "end"));
  writeFileAtomic(configPath, JSON.stringify(object, null, 2) + "\n");
  return { configPath, statusDir, backedUp };
}

const installed = [installCodex(), installClaude()];
for (const result of installed) {
  console.log("Installed status-bar hooks into", result.configPath);
  if (result.backedUp) console.log("Backup (first run only):", result.configPath + ".bak-statusbar");
}
console.log("IMPORTANT: Codex may ask you to approve changed command hooks on startup.");
