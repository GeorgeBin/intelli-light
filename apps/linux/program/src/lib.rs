use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::fmt;
use std::str::FromStr;

pub mod config;
pub mod daemon;
pub mod doctor;
pub mod hooks;
pub mod ipc;
pub mod led;
pub mod state_store;
pub mod user_lifecycle;

pub const STALE_AFTER_SECONDS: f64 = 900.0;
pub const UNRELIABLE_OWNER_SECONDS: f64 = 60.0;
pub const TERMINAL_VISIBLE_SECONDS: f64 = 2.0;

#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum AgentProvider {
    Codex,
    Claude,
}

impl AgentProvider {
    pub const ALL: [Self; 2] = [Self::Codex, Self::Claude];

    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Codex => "codex",
            Self::Claude => "claude",
        }
    }
}

impl fmt::Display for AgentProvider {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.as_str())
    }
}

impl FromStr for AgentProvider {
    type Err = String;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value {
            "codex" => Ok(Self::Codex),
            "claude" => Ok(Self::Claude),
            _ => Err(format!("unknown agent provider: {value}")),
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub enum AgentState {
    Idle,
    Done,
    Working,
    Error,
    WaitingImplementation,
    WaitingInput,
    WaitingApproval,
}

impl AgentState {
    pub fn from_wire(value: &str) -> Self {
        match value {
            "permission" | "waitingApproval" => Self::WaitingApproval,
            "waitingInput" => Self::WaitingInput,
            "waitingImplementation" => Self::WaitingImplementation,
            "error" => Self::Error,
            "thinking" | "tool" | "working" => Self::Working,
            "done" => Self::Done,
            _ => Self::Idle,
        }
    }

    pub const fn requires_user_action(self) -> bool {
        matches!(
            self,
            Self::WaitingApproval | Self::WaitingInput | Self::WaitingImplementation
        )
    }

    pub const fn light_state(self) -> LightState {
        match self {
            Self::Working => LightState::Working,
            Self::WaitingApproval | Self::WaitingInput | Self::WaitingImplementation => {
                LightState::ActionRequired
            }
            Self::Error => LightState::Error,
            Self::Done => LightState::Done,
            Self::Idle => LightState::Idle,
        }
    }

    pub const fn wire_value(self) -> &'static str {
        match self {
            Self::WaitingApproval => "waitingApproval",
            Self::WaitingInput => "waitingInput",
            Self::WaitingImplementation => "waitingImplementation",
            Self::Error => "error",
            Self::Working => "working",
            Self::Done => "done",
            Self::Idle => "idle",
        }
    }
}

impl fmt::Display for AgentState {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::WaitingApproval => "Waiting Approval",
            Self::WaitingInput => "Waiting Input",
            Self::WaitingImplementation => "Waiting Implementation",
            Self::Error => "Error",
            Self::Working => "Working",
            Self::Done => "Done",
            Self::Idle => "Idle",
        })
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LightState {
    Working,
    ActionRequired,
    Error,
    Done,
    Idle,
}

impl fmt::Display for LightState {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::Working => "Working",
            Self::ActionRequired => "Action Required",
            Self::Error => "Error",
            Self::Done => "Done",
            Self::Idle => "Idle",
        })
    }
}

impl LightState {
    pub const fn wire_value(self) -> &'static str {
        match self {
            Self::Working => "working",
            Self::ActionRequired => "actionRequired",
            Self::Error => "error",
            Self::Done => "done",
            Self::Idle => "idle",
        }
    }
}

fn default_provider() -> AgentProvider {
    AgentProvider::Codex
}

fn default_owner_kind() -> String {
    "unknown".to_owned()
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SessionState {
    #[serde(default = "default_provider")]
    pub provider: AgentProvider,
    pub state: String,
    #[serde(default)]
    pub label: String,
    #[serde(default)]
    pub tool: String,
    #[serde(default)]
    pub project: String,
    #[serde(default)]
    pub session_id: String,
    #[serde(default)]
    pub transcript: String,
    #[serde(default)]
    pub started_at: f64,
    #[serde(default)]
    pub paused_total: f64,
    #[serde(default)]
    pub pause_start: f64,
    #[serde(default)]
    pub ts: f64,
    #[serde(default)]
    pub owner_pid: u32,
    #[serde(default = "default_owner_kind")]
    pub owner_kind: String,
}

impl SessionState {
    pub fn from_json(data: &[u8]) -> serde_json::Result<Self> {
        serde_json::from_slice(data)
    }

    pub fn key(&self) -> AgentSessionKey {
        AgentSessionKey::new(self.provider, self.session_id.clone())
    }

    pub fn normalized_state(&self) -> AgentState {
        AgentState::from_wire(&self.state)
    }

    pub fn has_reliable_owner(&self) -> bool {
        self.owner_kind == "session" && self.owner_pid > 0
    }

    pub fn is_alive(&self, now: f64) -> bool {
        if self.normalized_state().requires_user_action() && self.owner_pid > 0 {
            return true;
        }
        now - self.ts <= STALE_AFTER_SECONDS
    }

    pub fn is_eligible(&self, now: f64, owner_alive: bool) -> bool {
        if !self.is_alive(now) {
            return false;
        }
        match self.normalized_state() {
            AgentState::WaitingApproval
            | AgentState::WaitingInput
            | AgentState::WaitingImplementation => {
                if self.owner_pid > 0 {
                    owner_alive
                } else {
                    now - self.ts <= UNRELIABLE_OWNER_SECONDS
                }
            }
            AgentState::Working => {
                if self.has_reliable_owner() {
                    owner_alive
                } else {
                    now - self.ts <= UNRELIABLE_OWNER_SECONDS
                }
            }
            _ => true,
        }
    }

    pub fn is_terminal_visible(&self, now: f64, terminal_timestamp: Option<f64>) -> bool {
        if !matches!(
            self.normalized_state(),
            AgentState::Done | AgentState::Error
        ) {
            return true;
        }
        now - terminal_timestamp.unwrap_or(self.ts) <= TERMINAL_VISIBLE_SECONDS
    }
}

#[derive(Clone, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
pub struct AgentSessionKey {
    pub provider: AgentProvider,
    pub session_id: String,
}

impl AgentSessionKey {
    pub fn new(provider: AgentProvider, session_id: impl Into<String>) -> Self {
        Self {
            provider,
            session_id: session_id.into(),
        }
    }

    pub fn parse_persisted(value: &str) -> Option<Self> {
        let (provider, session_id) = value.split_once(':')?;
        Some(Self::new(provider.parse().ok()?, session_id))
    }
}

impl fmt::Display for AgentSessionKey {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{}:{}", self.provider, self.session_id)
    }
}

pub trait OwnerLiveness {
    fn is_alive(&self, session: &SessionState) -> bool;
}

#[derive(Clone, Copy, Debug, Default)]
pub struct LinuxPidLiveness;

impl OwnerLiveness for LinuxPidLiveness {
    fn is_alive(&self, session: &SessionState) -> bool {
        linux_pid_alive(session.owner_pid)
    }
}

pub fn linux_pid_alive(pid: u32) -> bool {
    pid > 0 && std::path::Path::new("/proc").join(pid.to_string()).exists()
}

impl<F> OwnerLiveness for F
where
    F: Fn(&SessionState) -> bool,
{
    fn is_alive(&self, session: &SessionState) -> bool {
        self(session)
    }
}

#[derive(Debug)]
pub struct Arbitration<'a> {
    pub agent_state: AgentState,
    pub light_state: LightState,
    pub display_session: Option<&'a SessionState>,
    pub eligible_sessions: Vec<&'a SessionState>,
}

pub fn pinned_session_matches(pinned: &str, session: &SessionState) -> bool {
    if let Some(key) = AgentSessionKey::parse_persisted(pinned) {
        key == session.key()
    } else {
        session.provider == AgentProvider::Codex && session.session_id == pinned
    }
}

pub fn arbitrate<'a, L: OwnerLiveness>(
    enabled_providers: &HashSet<AgentProvider>,
    sessions: &'a [SessionState],
    now: f64,
    liveness: &L,
    terminal_timestamps: &HashMap<String, f64>,
    pinned_session: Option<&str>,
) -> Arbitration<'a> {
    let eligible_sessions: Vec<_> = sessions
        .iter()
        .filter(|session| enabled_providers.contains(&session.provider))
        .filter(|session| session.is_eligible(now, liveness.is_alive(session)))
        .filter(|session| {
            session.is_terminal_visible(
                now,
                terminal_timestamps.get(&session.key().to_string()).copied(),
            )
        })
        .collect();

    let agent_state = eligible_sessions
        .iter()
        .map(|session| session.normalized_state())
        .max()
        .unwrap_or(AgentState::Idle);

    let display_session = pinned_session
        .and_then(|pinned| {
            eligible_sessions
                .iter()
                .copied()
                .find(|session| pinned_session_matches(pinned, session))
        })
        .or_else(|| {
            eligible_sessions
                .iter()
                .copied()
                .max_by(|left, right| left.ts.total_cmp(&right.ts))
        });

    Arbitration {
        agent_state,
        light_state: agent_state.light_state(),
        display_session,
        eligible_sessions,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_legacy_defaults_and_unknown_state() {
        let session = SessionState::from_json(br#"{"state":"future"}"#).unwrap();
        assert_eq!(session.provider, AgentProvider::Codex);
        assert_eq!(session.owner_kind, "unknown");
        assert_eq!(session.normalized_state(), AgentState::Idle);
        assert_eq!(session.key().to_string(), "codex:");
    }

    #[test]
    fn persisted_and_legacy_pins_match() {
        let session =
            SessionState::from_json(br#"{"provider":"codex","state":"working","sessionId":"abc"}"#)
                .unwrap();
        assert!(pinned_session_matches("codex:abc", &session));
        assert!(pinned_session_matches("abc", &session));
        assert!(!pinned_session_matches("claude:abc", &session));
    }

    #[test]
    fn linux_pid_liveness_finds_current_process() {
        assert!(linux_pid_alive(std::process::id()));
        assert!(!linux_pid_alive(0));
        assert!(!linux_pid_alive(u32::MAX));
    }
}
