use crate::{AgentProvider, SessionState};
use std::fs;
use std::path::Path;

#[derive(Debug, Default)]
pub struct StateSnapshot {
    pub sessions: Vec<SessionState>,
    pub active_session_files: Vec<String>,
    pub warnings: Vec<String>,
}

pub fn load(home: &Path) -> StateSnapshot {
    let mut snapshot = StateSnapshot::default();
    for provider in AgentProvider::ALL {
        let root = home.join(format!(".{provider}/statusbar"));
        read_states(&root.join("states.d"), provider, &mut snapshot);
        read_session_files(&root.join("sessions.d"), provider, &mut snapshot);
    }
    snapshot
}

fn read_states(directory: &Path, provider: AgentProvider, snapshot: &mut StateSnapshot) {
    let Ok(entries) = fs::read_dir(directory) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if entry.file_name().to_string_lossy().ends_with(".tmp")
            || !entry.file_type().is_ok_and(|kind| kind.is_file())
        {
            continue;
        }
        match fs::read(&path)
            .map_err(|error| error.to_string())
            .and_then(|data| SessionState::from_json(&data).map_err(|error| error.to_string()))
        {
            Ok(mut session) => {
                session.provider = provider;
                snapshot.sessions.push(session);
            }
            Err(error) => snapshot
                .warnings
                .push(format!("{}: {error}", path.display())),
        }
    }
}

fn read_session_files(directory: &Path, provider: AgentProvider, snapshot: &mut StateSnapshot) {
    let Ok(entries) = fs::read_dir(directory) else {
        return;
    };
    for entry in entries.flatten() {
        if entry.file_type().is_ok_and(|kind| kind.is_file()) {
            snapshot.active_session_files.push(format!(
                "{provider}:{}",
                entry.file_name().to_string_lossy()
            ));
        }
    }
}
