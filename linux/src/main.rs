use intelli_light_linux::config::{config_path, Config};
use intelli_light_linux::george_light::{GeorgeLightOutput, HttpTransport, TcpHttpTransport};
use intelli_light_linux::state_store;
use intelli_light_linux::user_lifecycle::{self, SystemdUser};
use intelli_light_linux::{arbitrate, hooks, LinuxPidLiveness};
use std::collections::{HashMap, HashSet};
use std::env;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

fn main() {
    let arguments: Vec<String> = env::args().collect();
    let program = arguments
        .first()
        .map(String::as_str)
        .unwrap_or("intelli-light-linux");
    if let Err(error) = dispatch(&arguments[1..]) {
        eprintln!("{program}: {error}");
        std::process::exit(1);
    }
}

fn dispatch(arguments: &[String]) -> Result<(), String> {
    let home = home_directory()?;
    let path = config_path(&home);
    match arguments {
        [command] if command == "status" => status(&home, &Config::load(&path)?),
        [command] if command == "daemon" => {
            intelli_light_linux::daemon::run(&home, Config::load(&path)?)
        }
        [command] if command == "setup-user" => {
            print_changes(user_lifecycle::setup(&home, &mut SystemdUser)?);
            Ok(())
        }
        [command] if command == "doctor" => intelli_light_linux::doctor::run(&home),
        [command] if command == "uninstall-user" => {
            print_changes(user_lifecycle::uninstall(&home, false, &mut SystemdUser)?);
            Ok(())
        }
        [command, flag] if command == "uninstall-user" && flag == "--remove-config" => {
            print_changes(user_lifecycle::uninstall(&home, true, &mut SystemdUser)?);
            Ok(())
        }
        [group, action] if group == "hooks" && action == "install" => {
            let config = Config::load(&path)?;
            if !path.exists() {
                config.save(&path)?;
            }
            print_changes(hooks::install(&home, &config)?);
            Ok(())
        }
        [group, action] if group == "hooks" && action == "sync" => {
            let config = Config::load(&path)?;
            print_changes(hooks::sync(&home, &config)?);
            Ok(())
        }
        [group, action] if group == "hooks" && action == "uninstall" => {
            print_changes(hooks::uninstall(&home)?);
            Ok(())
        }
        [group, action] if group == "config" && action == "show" => {
            let config = Config::load(&path)?;
            println!(
                "{}",
                serde_json::to_string_pretty(&config).map_err(|error| error.to_string())?
            );
            Ok(())
        }
        [group, action] if group == "george-light" && action == "probe" => {
            let config = Config::load(&path)?;
            let output = GeorgeLightOutput::new(config.george_light)?;
            let request = output.clear_request()?;
            let status = TcpHttpTransport
                .send(&request)
                .map_err(|error| error.to_string())?;
            println!("GeorgeLight clear response: HTTP {status}");
            if !(200..300).contains(&status) {
                return Err(format!("GeorgeLight returned HTTP {status}"));
            }
            Ok(())
        }
        [group, action, key, value] if group == "config" && action == "set" => {
            let mut config = Config::load(&path)?;
            config.set(key, value)?;
            config.save(&path)?;
            println!("updated {key} in {}", path.display());
            Ok(())
        }
        _ => Err(usage()),
    }
}

fn status(home: &Path, config: &Config) -> Result<(), String> {
    let snapshot = state_store::load(home);
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|error| error.to_string())?
        .as_secs_f64();
    let enabled: HashSet<_> = config.enabled_providers.iter().copied().collect();
    let result = arbitrate(
        &enabled,
        &snapshot.sessions,
        now,
        &LinuxPidLiveness,
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
    println!(
        "Lifecycle session files ({}): {}",
        snapshot.active_session_files.len(),
        if snapshot.active_session_files.is_empty() {
            "none".to_owned()
        } else {
            snapshot.active_session_files.join(", ")
        }
    );
    for warning in snapshot.warnings {
        eprintln!("warning: {warning}");
    }
    Ok(())
}

fn home_directory() -> Result<PathBuf, String> {
    env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or_else(|| "HOME is not set".to_owned())
}

fn print_changes(changes: Vec<String>) {
    if changes.is_empty() {
        println!("hooks already synchronized");
    } else {
        for change in changes {
            println!("{change}");
        }
    }
}

fn value_or_dash(value: &str) -> &str {
    if value.is_empty() {
        "-"
    } else {
        value
    }
}

fn usage() -> String {
    [
        "Usage:",
        "  intelli-light-linux status",
        "  intelli-light-linux daemon",
        "  intelli-light-linux setup-user",
        "  intelli-light-linux doctor",
        "  intelli-light-linux uninstall-user [--remove-config]",
        "  intelli-light-linux hooks install|uninstall|sync",
        "  intelli-light-linux config show",
        "  intelli-light-linux config set <key> <value>",
        "  intelli-light-linux george-light probe",
    ]
    .join("\n")
}
