use intelli_light_linux::{arbitrate, AgentProvider, SessionState};
use std::collections::{HashMap, HashSet};
use std::env;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

fn main() {
    let mut arguments = env::args();
    let program = arguments
        .next()
        .unwrap_or_else(|| "intelli-light-linux".to_owned());
    match (arguments.next().as_deref(), arguments.next()) {
        (Some("status"), None) => {
            if let Err(error) = status() {
                eprintln!("{program}: {error}");
                std::process::exit(1);
            }
        }
        _ => {
            eprintln!("Usage: {program} status");
            std::process::exit(2);
        }
    }
}

fn status() -> Result<(), Box<dyn std::error::Error>> {
    let home = env::var_os("HOME").ok_or("HOME is not set")?;
    let home = PathBuf::from(home);
    let mut sessions = Vec::new();
    let mut warnings = Vec::new();
    for (provider, relative) in [
        (AgentProvider::Codex, ".codex/statusbar/states.d"),
        (AgentProvider::Claude, ".claude/statusbar/states.d"),
    ] {
        read_sessions(&home.join(relative), provider, &mut sessions, &mut warnings)?;
    }

    let now = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs_f64();
    let enabled: HashSet<_> = AgentProvider::ALL.into_iter().collect();
    let result = arbitrate(
        &enabled,
        &sessions,
        now,
        &|session: &SessionState| linux_pid_alive(session.owner_pid),
        &HashMap::new(),
        None,
    );

    println!("Global AgentState: {}", result.agent_state);
    println!("LightState: {}", result.light_state);
    match result.display_session {
        Some(session) => println!("Display session: {}", session.key()),
        None => println!("Display session: none"),
    }
    println!("Valid sessions ({}):", result.eligible_sessions.len());
    for session in result.eligible_sessions {
        println!(
            "  {} | {} | project={} | label={} | tool={} | ownerPid={}",
            session.key(),
            session.normalized_state(),
            value_or_dash(&session.project),
            value_or_dash(&session.label),
            value_or_dash(&session.tool),
            session.owner_pid
        );
    }
    for warning in warnings {
        eprintln!("warning: {warning}");
    }
    Ok(())
}

fn read_sessions(
    directory: &Path,
    provider: AgentProvider,
    sessions: &mut Vec<SessionState>,
    warnings: &mut Vec<String>,
) -> io::Result<()> {
    let entries = match fs::read_dir(directory) {
        Ok(entries) => entries,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error),
    };
    for entry in entries {
        let entry = entry?;
        if entry.file_name().to_string_lossy().ends_with(".tmp") || !entry.file_type()?.is_file() {
            continue;
        }
        match fs::read(entry.path())
            .map_err(|error| error.to_string())
            .and_then(|data| SessionState::from_json(&data).map_err(|error| error.to_string()))
        {
            Ok(mut session) => {
                session.provider = provider;
                sessions.push(session);
            }
            Err(error) => warnings.push(format!("{}: {error}", entry.path().display())),
        }
    }
    Ok(())
}

fn linux_pid_alive(pid: u32) -> bool {
    pid > 0 && Path::new("/proc").join(pid.to_string()).exists()
}

fn value_or_dash(value: &str) -> &str {
    if value.is_empty() {
        "-"
    } else {
        value
    }
}
