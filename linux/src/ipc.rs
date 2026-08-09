use crate::config::{config_path, Config, GeorgeLightConfig};
use crate::george_light::Connectivity;
use crate::{arbitrate, hooks, AgentProvider, AgentState, LinuxPidLiveness, SessionState};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::{self, BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::time::Duration;

pub const IPC_VERSION: u32 = 1;

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(tag = "command", rename_all = "camelCase")]
pub enum IpcRequest {
    GetSnapshot,
    SetProviders {
        providers: Vec<AgentProvider>,
    },
    SetGeorgeLight {
        #[serde(rename = "georgeLight")]
        george_light: GeorgeLightConfig,
    },
    SyncHooks,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct IpcSnapshot {
    pub version: u32,
    pub global_agent_state: String,
    pub light_state: String,
    pub display_session: Option<String>,
    pub provider_states: ProviderStates,
    pub sessions: Vec<SessionSummary>,
    pub enabled_providers: Vec<AgentProvider>,
    pub george_light: GeorgeLightStatus,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderStates {
    pub codex: String,
    pub claude: String,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionSummary {
    pub key: String,
    pub provider: AgentProvider,
    pub state: String,
    pub label: String,
    pub project: String,
    pub session_id: String,
    pub tool: String,
    pub ts: f64,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GeorgeLightStatus {
    #[serde(flatten)]
    pub config: GeorgeLightConfig,
    pub connectivity: String,
}

impl IpcSnapshot {
    pub fn build(
        config: &Config,
        sessions: &[SessionState],
        now: f64,
        connectivity: Connectivity,
    ) -> Self {
        let enabled: HashSet<_> = config.enabled_providers.iter().copied().collect();
        let result = arbitrate(
            &enabled,
            sessions,
            now,
            &LinuxPidLiveness,
            &HashMap::new(),
            None,
        );
        let state_for = |provider| {
            if !enabled.contains(&provider) {
                return AgentState::Idle;
            }
            arbitrate(
                &HashSet::from([provider]),
                sessions,
                now,
                &LinuxPidLiveness,
                &HashMap::new(),
                None,
            )
            .agent_state
        };
        Self {
            version: IPC_VERSION,
            global_agent_state: result.agent_state.wire_value().to_owned(),
            light_state: result.light_state.wire_value().to_owned(),
            display_session: result
                .display_session
                .map(|session| session.key().to_string()),
            provider_states: ProviderStates {
                codex: state_for(AgentProvider::Codex).wire_value().to_owned(),
                claude: state_for(AgentProvider::Claude).wire_value().to_owned(),
            },
            sessions: result
                .eligible_sessions
                .iter()
                .map(|session| SessionSummary {
                    key: session.key().to_string(),
                    provider: session.provider,
                    state: session.normalized_state().wire_value().to_owned(),
                    label: session.label.clone(),
                    project: session.project.clone(),
                    session_id: session.session_id.clone(),
                    tool: session.tool.clone(),
                    ts: session.ts,
                })
                .collect(),
            enabled_providers: config.enabled_providers.clone(),
            george_light: GeorgeLightStatus {
                config: config.george_light.clone(),
                connectivity: connectivity.as_str().to_owned(),
            },
        }
    }
}

pub struct IpcServer {
    listener: UnixListener,
    path: PathBuf,
}

impl IpcServer {
    pub fn bind(path: PathBuf) -> Result<Self, String> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(|error| error.to_string())?;
            fs::set_permissions(parent, fs::Permissions::from_mode(0o700))
                .map_err(|error| error.to_string())?;
        }
        if path.exists() {
            if UnixStream::connect(&path).is_ok() {
                return Err(format!(
                    "daemon IPC socket is already active: {}",
                    path.display()
                ));
            }
            fs::remove_file(&path).map_err(|error| error.to_string())?;
        }
        let listener = UnixListener::bind(&path).map_err(|error| error.to_string())?;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600))
            .map_err(|error| error.to_string())?;
        listener
            .set_nonblocking(true)
            .map_err(|error| error.to_string())?;
        Ok(Self { listener, path })
    }

    pub fn accept(&self) -> Result<Option<IpcClient>, String> {
        match self.listener.accept() {
            Ok((stream, _)) => IpcClient::read(stream).map(Some),
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => Ok(None),
            Err(error) => Err(error.to_string()),
        }
    }
}

impl Drop for IpcServer {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}

pub struct IpcClient {
    stream: UnixStream,
    pub request: IpcRequest,
}

impl IpcClient {
    fn read(stream: UnixStream) -> Result<Self, String> {
        stream
            .set_read_timeout(Some(Duration::from_millis(200)))
            .map_err(|error| error.to_string())?;
        let mut line = String::new();
        BufReader::new(&stream)
            .read_line(&mut line)
            .map_err(|error| error.to_string())?;
        let request = serde_json::from_str(&line).map_err(|error| error.to_string())?;
        Ok(Self { stream, request })
    }

    pub fn respond(mut self, response: &Value) -> Result<(), String> {
        serde_json::to_writer(&mut self.stream, response).map_err(|error| error.to_string())?;
        self.stream
            .write_all(b"\n")
            .map_err(|error| error.to_string())
    }
}

pub fn handle_request(
    request: &IpcRequest,
    home: &Path,
    config: &mut Config,
    snapshot: &IpcSnapshot,
) -> Value {
    let result = match request {
        IpcRequest::GetSnapshot => return json!({"ok": true, "snapshot": snapshot}),
        IpcRequest::SetProviders { providers } => {
            let mut updated = config.clone();
            updated.enabled_providers = providers.clone();
            update_config(home, config, updated)
                .and_then(|()| hooks::sync(home, config).map(|_| ()))
        }
        IpcRequest::SetGeorgeLight { george_light } => {
            let mut updated = config.clone();
            updated.george_light = george_light.clone();
            update_config(home, config, updated)
        }
        IpcRequest::SyncHooks => hooks::sync(home, config).map(|_| ()),
    };
    match result {
        Ok(()) => json!({"ok": true}),
        Err(error) => json!({"ok": false, "error": error}),
    }
}

pub fn socket_path() -> PathBuf {
    if let Some(runtime) = std::env::var_os("XDG_RUNTIME_DIR") {
        PathBuf::from(runtime).join("intelli-light/daemon.sock")
    } else {
        std::env::temp_dir().join(format!(
            "intelli-light-{}/daemon.sock",
            // SAFETY: geteuid has no preconditions and does not mutate memory.
            unsafe { libc::geteuid() }
        ))
    }
}

pub fn request(request: &IpcRequest) -> Result<Value, String> {
    let mut stream = UnixStream::connect(socket_path()).map_err(|error| error.to_string())?;
    stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .map_err(|error| error.to_string())?;
    serde_json::to_writer(&mut stream, request).map_err(|error| error.to_string())?;
    stream.write_all(b"\n").map_err(|error| error.to_string())?;
    let mut line = String::new();
    BufReader::new(stream)
        .read_line(&mut line)
        .map_err(|error| error.to_string())?;
    serde_json::from_str(&line).map_err(|error| error.to_string())
}

fn update_config(home: &Path, config: &mut Config, updated: Config) -> Result<(), String> {
    updated.validate()?;
    updated.save(&config_path(home))?;
    *config = updated;
    Ok(())
}
