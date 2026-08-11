use intelli_light_linux::config::{config_path, Config, Effect, DEFAULT_GEORGE_LIGHT_ADDRESS};
use intelli_light_linux::daemon::evaluate_light;
use intelli_light_linux::led::{GeorgeLightOutput, LEASE_REFRESH_SECONDS};
use intelli_light_linux::{hooks, AgentProvider, LightState};
use serde_json::{json, Value};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

struct TestHome(PathBuf);

impl TestHome {
    fn new(name: &str) -> Self {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!(
            "intelli-light-{name}-{}-{nonce}",
            std::process::id()
        ));
        fs::create_dir_all(&path).unwrap();
        Self(path)
    }

    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for TestHome {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[test]
fn config_defaults_round_trip_and_set_all_required_fields() {
    let home = TestHome::new("config");
    let path = config_path(home.path());
    let mut config = Config::load(&path).unwrap();
    assert_eq!(
        config.enabled_providers,
        vec![AgentProvider::Codex, AgentProvider::Claude]
    );
    assert_eq!(config.george_light.address, DEFAULT_GEORGE_LIGHT_ADDRESS);
    assert_eq!(config.george_light.effects.working, Effect::working());
    config.set("providers", "claude").unwrap();
    config.set("georgeLight.enabled", "false").unwrap();
    config
        .set("georgeLight.address", "http://127.0.0.1:8080")
        .unwrap();
    config.set("effects.done.color", "#123ABC").unwrap();
    config.set("effects.done.modeId", "2").unwrap();
    config.set("effects.done.durationSec", "42").unwrap();
    config.set("effects.done.brightness", "55").unwrap();
    config.save(&path).unwrap();
    assert_eq!(Config::load(&path).unwrap(), config);
    assert!(config.set("providers", "").is_err());
}

#[test]
fn george_light_duration_contract_accepts_only_one_through_three_hundred() {
    for duration in [1, 300] {
        let mut config = Config::default();
        config.george_light.effects.done.duration_sec = duration;
        config.validate().unwrap();

        let mut cli_config = Config::default();
        cli_config
            .set("effects.done.durationSec", &duration.to_string())
            .unwrap();
    }

    for duration in [0, 301] {
        let mut config = Config::default();
        config.george_light.effects.done.duration_sec = duration;
        assert!(config.validate().is_err());

        let mut cli_config = Config::default();
        assert!(cli_config
            .set("effects.done.durationSec", &duration.to_string())
            .is_err());
    }
}

#[test]
fn hooks_are_idempotent_preserve_user_entries_and_follow_providers() {
    let home = TestHome::new("hooks");
    write_json(
        &home.path().join(".codex/hooks.json"),
        &json!({"custom": true, "hooks": {"Stop": [{"hooks": [
            {"type": "command", "command": "echo user-hook"}
        ]}]}}),
    );
    write_json(
        &home.path().join(".claude/settings.json"),
        &json!({"model": "user-model", "hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [
            {"type": "command", "command": "echo claude-user-hook"}
        ]}]}}),
    );
    let config = Config::default();
    assert_eq!(hooks::install(home.path(), &config).unwrap().len(), 2);
    assert!(hooks::sync(home.path(), &config).unwrap().is_empty());

    let codex = read_json(&home.path().join(".codex/hooks.json"));
    let claude = read_json(&home.path().join(".claude/settings.json"));
    assert_eq!(codex["custom"], true);
    assert_eq!(claude["model"], "user-model");
    assert!(commands(&codex)
        .iter()
        .any(|value| value == "echo user-hook"));
    assert!(commands(&claude)
        .iter()
        .any(|value| value == "echo claude-user-hook"));
    assert_eq!(owned_commands(&codex).len(), 7);
    assert_eq!(owned_commands(&claude).len(), 9);
    let lifecycle =
        fs::read_to_string(home.path().join(".codex/statusbar/linux-lifecycle.js")).unwrap();
    assert!(!lifecycle.contains("open -g"));
    assert!(!lifecycle.contains("disableAllHooks"));

    let mut codex_only = config;
    codex_only.enabled_providers = vec![AgentProvider::Codex];
    hooks::sync(home.path(), &codex_only).unwrap();
    assert_eq!(
        owned_commands(&read_json(&home.path().join(".codex/hooks.json"))).len(),
        7
    );
    let claude = read_json(&home.path().join(".claude/settings.json"));
    assert!(owned_commands(&claude).is_empty());
    assert!(commands(&claude)
        .iter()
        .any(|value| value == "echo claude-user-hook"));

    hooks::uninstall(home.path()).unwrap();
    let codex = read_json(&home.path().join(".codex/hooks.json"));
    assert!(owned_commands(&codex).is_empty());
    assert!(commands(&codex)
        .iter()
        .any(|value| value == "echo user-hook"));
}

#[test]
fn george_light_maps_payloads_refreshes_leases_and_backs_off() {
    let config = Config::default().george_light;
    let mut output = GeorgeLightOutput::new(config).unwrap();
    output.set_state(LightState::Working, 0.0);
    let working = output.next_request(0.0).unwrap().unwrap();
    assert_eq!(working.request.path, "/api/v1/codex/display");
    let body: Value = serde_json::from_slice(working.request.body.as_ref().unwrap()).unwrap();
    assert_eq!(body["color"], "#4D8FFF");
    assert_eq!(body["mode_id"], 3);
    output.complete(&working, true, 0.0);
    assert!(output
        .next_request(LEASE_REFRESH_SECONDS - 0.001)
        .unwrap()
        .is_none());
    let lease = output.next_request(LEASE_REFRESH_SECONDS).unwrap().unwrap();
    output.complete(&lease, false, LEASE_REFRESH_SECONDS);
    assert!(output
        .next_request(LEASE_REFRESH_SECONDS + 1.999)
        .unwrap()
        .is_none());
    assert!(output
        .next_request(LEASE_REFRESH_SECONDS + 2.0)
        .unwrap()
        .is_some());
}

#[test]
fn george_light_stale_completion_cannot_override_new_state() {
    let mut output = GeorgeLightOutput::new(Config::default().george_light).unwrap();
    output.set_state(LightState::Working, 0.0);
    let old = output.next_request(0.0).unwrap().unwrap();
    output.set_state(LightState::Idle, 0.1);
    output.complete(&old, true, 0.2);
    let clear = output.next_request(0.2).unwrap().unwrap();
    assert_eq!(clear.request.path, "/api/v1/codex/clear");
    assert!(clear.request.body.is_none());
}

#[test]
fn daemon_evaluation_reads_both_providers_and_tracks_state_changes() {
    let home = TestHome::new("daemon");
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs_f64();
    write_json(
        &home.path().join(".codex/statusbar/states.d/codex"),
        &json!({
            "provider": "codex", "state": "working", "sessionId": "codex",
            "ts": now, "ownerPid": std::process::id(), "ownerKind": "session"
        }),
    );
    write_json(
        &home.path().join(".claude/statusbar/states.d/claude"),
        &json!({
            "provider": "claude", "state": "waitingInput", "sessionId": "claude",
            "ts": now, "ownerPid": std::process::id(), "ownerKind": "session"
        }),
    );
    let config = Config::default();
    assert_eq!(
        evaluate_light(home.path(), &config, now),
        LightState::ActionRequired
    );
    let mut codex_only = config;
    codex_only.enabled_providers = vec![AgentProvider::Codex];
    assert_eq!(
        evaluate_light(home.path(), &codex_only, now),
        LightState::Working
    );
    fs::remove_file(home.path().join(".codex/statusbar/states.d/codex")).unwrap();
    assert_eq!(
        evaluate_light(home.path(), &codex_only, now),
        LightState::Idle
    );
}

fn write_json(path: &Path, value: &Value) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, serde_json::to_vec(value).unwrap()).unwrap();
}

fn read_json(path: &Path) -> Value {
    serde_json::from_slice(&fs::read(path).unwrap()).unwrap()
}

fn commands(value: &Value) -> Vec<String> {
    let mut result = Vec::new();
    if let Some(events) = value.get("hooks").and_then(Value::as_object) {
        for entries in events.values().filter_map(Value::as_array) {
            for entry in entries {
                if let Some(hooks) = entry.get("hooks").and_then(Value::as_array) {
                    for hook in hooks {
                        if let Some(command) = hook.get("command").and_then(Value::as_str) {
                            result.push(command.to_owned());
                        }
                    }
                }
            }
        }
    }
    result
}

fn owned_commands(value: &Value) -> Vec<String> {
    commands(value)
        .into_iter()
        .filter(|command| command.contains("statusbar"))
        .collect()
}
