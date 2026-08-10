use crate::config::Config;
use crate::AgentProvider;
use serde_json::{json, Map, Value};
use std::fs;
use std::path::Path;

const CODEX_UPDATE: &str = include_str!("../../../../hooks/codex/update.js");
const CLAUDE_UPDATE: &str = include_str!("../../../../hooks/claude/claude-update.js");
const FILE_UTILS: &str = include_str!("../../../../hooks/fs-utils.js");
const LIFECYCLE: &str = include_str!("../../../../hooks/linux/linux-lifecycle.js");

pub fn install(home: &Path, config: &Config) -> Result<Vec<String>, String> {
    sync(home, config)
}

pub fn sync(home: &Path, config: &Config) -> Result<Vec<String>, String> {
    config.validate()?;
    let mut changed = Vec::new();
    for provider in AgentProvider::ALL {
        let enabled = config.enabled_providers.contains(&provider);
        if reconcile_provider(home, provider, enabled)? {
            changed.push(format!(
                "{} {} hooks",
                if enabled { "installed" } else { "removed" },
                provider
            ));
        }
    }
    Ok(changed)
}

pub fn uninstall(home: &Path) -> Result<Vec<String>, String> {
    let mut changed = Vec::new();
    for provider in AgentProvider::ALL {
        if reconcile_provider(home, provider, false)? {
            changed.push(format!("removed {provider} hooks"));
        }
    }
    Ok(changed)
}

fn reconcile_provider(home: &Path, provider: AgentProvider, enabled: bool) -> Result<bool, String> {
    let root = home.join(format!(".{}", provider.as_str()));
    let status = root.join("statusbar");
    let config_path = root.join(match provider {
        AgentProvider::Codex => "hooks.json",
        AgentProvider::Claude => "settings.json",
    });
    if !enabled && !config_path.exists() {
        return Ok(false);
    }

    let mut object = read_object(&config_path)?;
    let before = object.clone();
    remove_owned_hooks(&mut object, &status.to_string_lossy());
    if enabled {
        install_scripts(&status, provider)?;
        add_provider_hooks(&mut object, provider, &status);
    }
    if object == before {
        return Ok(false);
    }
    if config_path.exists() {
        let backup = config_path.with_file_name(format!(
            "{}.bak-intelli-light",
            config_path
                .file_name()
                .unwrap_or_default()
                .to_string_lossy()
        ));
        if !backup.exists() {
            fs::copy(&config_path, &backup).map_err(|error| error.to_string())?;
            private_file(&backup)?;
        }
    }
    write_json(&config_path, &Value::Object(object))?;
    Ok(true)
}

fn install_scripts(status: &Path, provider: AgentProvider) -> Result<(), String> {
    fs::create_dir_all(status).map_err(|error| error.to_string())?;
    private_directory(status)?;
    for (name, contents) in [
        ("fs-utils.js", FILE_UTILS),
        ("linux-lifecycle.js", LIFECYCLE),
        (
            match provider {
                AgentProvider::Codex => "update.js",
                AgentProvider::Claude => "claude-update.js",
            },
            match provider {
                AgentProvider::Codex => CODEX_UPDATE,
                AgentProvider::Claude => CLAUDE_UPDATE,
            },
        ),
    ] {
        let path = status.join(name);
        fs::write(&path, contents).map_err(|error| error.to_string())?;
        private_file(&path)?;
    }
    Ok(())
}

fn add_provider_hooks(object: &mut Map<String, Value>, provider: AgentProvider, status: &Path) {
    let update = match provider {
        AgentProvider::Codex => "update.js",
        AgentProvider::Claude => "claude-update.js",
    };
    let lifecycle = quoted_command(
        &status.join("linux-lifecycle.js"),
        &[provider.as_str(), "EVENT"],
    );
    let mut definitions = vec![
        ("SessionStart", lifecycle.replace("EVENT", "start"), None),
        ("SessionEnd", lifecycle.replace("EVENT", "end"), None),
        ("UserPromptSubmit", command(status, update, "prompt"), None),
        ("PreToolUse", command(status, update, "pre"), None),
        ("PostToolUse", command(status, update, "post"), None),
        (
            "PermissionRequest",
            command(status, update, "permission"),
            None,
        ),
        ("Stop", command(status, update, "stop"), None),
    ];
    if provider == AgentProvider::Codex {
        definitions[3].2 = Some("*");
        definitions[4].2 = Some("*");
    } else {
        definitions.push((
            "PostToolUseFailure",
            command(status, update, "post-failure"),
            None,
        ));
        definitions.push(("StopFailure", command(status, update, "stop-failure"), None));
    }
    for (event, hook_command, matcher) in definitions {
        add_hook(object, event, hook_command, matcher);
    }
}

fn add_hook(object: &mut Map<String, Value>, event: &str, command: String, matcher: Option<&str>) {
    let hooks = object
        .entry("hooks")
        .or_insert_with(|| Value::Object(Map::new()));
    if !hooks.is_object() {
        *hooks = Value::Object(Map::new());
    }
    let events = hooks.as_object_mut().expect("hooks was normalized");
    let entries = events
        .entry(event)
        .or_insert_with(|| Value::Array(Vec::new()));
    if !entries.is_array() {
        *entries = Value::Array(Vec::new());
    }
    let mut group = json!({"hooks": [{"type": "command", "command": command}]});
    if let Some(matcher) = matcher {
        group["matcher"] = Value::String(matcher.to_owned());
    }
    entries
        .as_array_mut()
        .expect("event was normalized")
        .push(group);
}

fn remove_owned_hooks(object: &mut Map<String, Value>, marker: &str) {
    let Some(events) = object.get_mut("hooks").and_then(Value::as_object_mut) else {
        return;
    };
    events.retain(|_, entries| {
        let Some(entries) = entries.as_array_mut() else {
            return true;
        };
        for entry in entries.iter_mut() {
            let Some(hooks) = entry.get_mut("hooks").and_then(Value::as_array_mut) else {
                continue;
            };
            hooks.retain(|hook| {
                !hook
                    .get("command")
                    .and_then(Value::as_str)
                    .is_some_and(|command| command.contains(marker))
            });
        }
        entries.retain(|entry| {
            entry
                .get("hooks")
                .and_then(Value::as_array)
                .is_none_or(|hooks| !hooks.is_empty())
        });
        !entries.is_empty()
    });
}

fn command(status: &Path, script: &str, event: &str) -> String {
    quoted_command(&status.join(script), &[event])
}

fn quoted_command(script: &Path, arguments: &[&str]) -> String {
    format!("node \"{}\" {}", script.display(), arguments.join(" "))
}

fn read_object(path: &Path) -> Result<Map<String, Value>, String> {
    if !path.exists() {
        return Ok(Map::new());
    }
    let value: Value = serde_json::from_slice(&fs::read(path).map_err(|error| error.to_string())?)
        .map_err(|error| format!("{}: {error}", path.display()))?;
    value
        .as_object()
        .cloned()
        .ok_or_else(|| format!("{} must contain a JSON object", path.display()))
}

fn write_json(path: &Path, value: &Value) -> Result<(), String> {
    let parent = path.parent().ok_or("hook config has no parent")?;
    fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    private_directory(parent)?;
    let mut data = serde_json::to_vec_pretty(value).map_err(|error| error.to_string())?;
    data.push(b'\n');
    let temporary = path.with_extension(format!("tmp.{}", std::process::id()));
    fs::write(&temporary, data).map_err(|error| error.to_string())?;
    private_file(&temporary)?;
    fs::rename(&temporary, path).map_err(|error| error.to_string())?;
    Ok(())
}

#[cfg(unix)]
fn private_directory(path: &Path) -> Result<(), String> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(0o700)).map_err(|error| error.to_string())
}

#[cfg(unix)]
fn private_file(path: &Path) -> Result<(), String> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600)).map_err(|error| error.to_string())
}

#[cfg(not(unix))]
fn private_directory(_path: &Path) -> Result<(), String> {
    Ok(())
}

#[cfg(not(unix))]
fn private_file(_path: &Path) -> Result<(), String> {
    Ok(())
}
