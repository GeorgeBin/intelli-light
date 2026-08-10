use intelli_light_linux::config::{Config, GeorgeLightConfig};
use intelli_light_linux::ipc::{handle_request, IpcRequest, IpcSnapshot};
use intelli_light_linux::led::Connectivity;
use intelli_light_linux::{AgentProvider, SessionState};
use std::fs;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

#[test]
fn ipc_serialization_preserves_waiting_state_names_and_light_mapping() {
    let now = unix_now();
    let sessions = [
        session("waitingApproval", "approval", now),
        session("waitingInput", "input", now),
        session("waitingImplementation", "implementation", now),
    ];
    let snapshot = IpcSnapshot::build(&Config::default(), &sessions, now, Connectivity::Connected);
    let value = serde_json::to_value(snapshot).unwrap();
    assert_eq!(value["globalAgentState"], "waitingApproval");
    assert_eq!(value["lightState"], "actionRequired");
    let states: Vec<_> = value["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .map(|session| session["state"].as_str().unwrap())
        .collect();
    assert!(states.contains(&"waitingApproval"));
    assert!(states.contains(&"waitingInput"));
    assert!(states.contains(&"waitingImplementation"));
    assert_eq!(value["georgeLight"]["connectivity"], "connected");
}

#[test]
fn ipc_provider_george_light_and_hook_operations_use_shared_config() {
    let home = TestHome::new("operations");
    let mut config = Config::default();
    let snapshot = IpcSnapshot::build(&config, &[], unix_now(), Connectivity::Unknown);
    let response = handle_request(
        &IpcRequest::SetProviders {
            providers: vec![AgentProvider::Claude],
        },
        home.path(),
        &mut config,
        &snapshot,
    );
    assert_eq!(response["ok"], true);
    assert_eq!(config.enabled_providers, vec![AgentProvider::Claude]);
    assert!(home.path().join(".claude/settings.json").exists());
    assert!(!home.path().join(".codex/hooks.json").exists());

    let light = GeorgeLightConfig {
        enabled: false,
        address: "http://127.0.0.1:9876".to_owned(),
        ..GeorgeLightConfig::default()
    };
    let response = handle_request(
        &IpcRequest::SetGeorgeLight {
            george_light: light.clone(),
        },
        home.path(),
        &mut config,
        &snapshot,
    );
    assert_eq!(response["ok"], true);
    assert_eq!(config.george_light, light);
    assert_eq!(
        Config::load(&home.path().join(".config/intelli-light/config.json"))
            .unwrap()
            .george_light,
        light
    );
}

#[test]
fn ipc_request_and_response_json_round_trip() {
    let request: IpcRequest = serde_json::from_str("{\"command\":\"getSnapshot\"}\n").unwrap();
    assert_eq!(request, IpcRequest::GetSnapshot);
    assert_eq!(
        serde_json::to_string(&request).unwrap(),
        "{\"command\":\"getSnapshot\"}"
    );
    let response = serde_json::json!({"ok": true, "transport": "unix"});
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(&response.to_string()).unwrap(),
        response
    );
}

#[test]
fn ipc_accepts_desktop_george_light_camel_case_field() {
    let request: IpcRequest = serde_json::from_value(serde_json::json!({
        "command": "setGeorgeLight",
        "georgeLight": GeorgeLightConfig::default()
    }))
    .unwrap();
    assert!(matches!(request, IpcRequest::SetGeorgeLight { .. }));
    let value = serde_json::to_value(request).unwrap();
    assert!(value.get("georgeLight").is_some());
    assert!(value.get("george_light").is_none());
}

fn session(state: &str, id: &str, now: f64) -> SessionState {
    serde_json::from_value(serde_json::json!({
        "provider": "codex",
        "state": state,
        "sessionId": id,
        "ts": now,
        "ownerPid": std::process::id(),
        "ownerKind": "session"
    }))
    .unwrap()
}

fn unix_now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs_f64()
}

struct TestHome(PathBuf);

impl TestHome {
    fn new(name: &str) -> Self {
        let path = std::env::temp_dir().join(format!(
            "intelli-light-ipc-{name}-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&path).unwrap();
        Self(path)
    }

    fn path(&self) -> &std::path::Path {
        &self.0
    }
}

impl Drop for TestHome {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
