#!/usr/bin/env node
// Removes only this app's Codex and Claude Code hooks. Other settings and hooks remain.

const fs = require("fs");
const os = require("os");
const path = require("path");
const cp = require("child_process");
const { writeFileAtomic } = require("./fs-utils.js");

const home = os.homedir();
try { cp.execFileSync("pkill", ["-x", "CodexStatusBar"], { stdio: "ignore" }); } catch {}

function removeOwned(configPath, marker) {
  if (!fs.existsSync(configPath)) return;
  const object = JSON.parse(fs.readFileSync(configPath, "utf8"));
  for (const event of Object.keys(object.hooks || {})) {
    object.hooks[event] = (Array.isArray(object.hooks[event]) ? object.hooks[event] : [])
      .map((entry) => ({
        ...entry,
        hooks: (Array.isArray(entry.hooks) ? entry.hooks : [])
          .filter((hook) => !String(hook.command || "").includes(marker)),
      }))
      .filter((entry) => entry.hooks.length > 0);
    if (object.hooks[event].length === 0) delete object.hooks[event];
  }
  writeFileAtomic(configPath, JSON.stringify(object, null, 2) + "\n");
  console.log("Removed status-bar hooks from", configPath);
}

removeOwned(path.join(home, ".codex", "hooks.json"), path.join(home, ".codex", "statusbar"));
removeOwned(path.join(home, ".claude", "settings.json"), path.join(home, ".claude", "statusbar"));
