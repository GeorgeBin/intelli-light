use crate::config::{config_path, Config};
use crate::{hooks, ipc};
use std::fs;
use std::path::Path;
use std::process::Command;

const SERVICE: &str = "intelli-light.service";
const OWNED_UNIT_MARKER: &str = "Description=Intelli Light headless agent status daemon";

pub trait UserServiceManager {
    fn daemon_reload(&mut self) -> Result<(), String>;
    fn enable_start(&mut self) -> Result<(), String>;
    fn disable_stop(&mut self) -> Result<(), String>;
}

pub struct SystemdUser;

impl UserServiceManager for SystemdUser {
    fn daemon_reload(&mut self) -> Result<(), String> {
        systemctl(&["daemon-reload"])
    }

    fn enable_start(&mut self) -> Result<(), String> {
        systemctl(&["enable", SERVICE])?;
        systemctl(&["restart", SERVICE])
    }

    fn disable_stop(&mut self) -> Result<(), String> {
        systemctl(&["disable", "--now", SERVICE])
    }
}

pub fn setup(home: &Path, service: &mut impl UserServiceManager) -> Result<Vec<String>, String> {
    let path = config_path(home);
    let config = Config::load(&path)?;
    let mut changes = Vec::new();
    if !path.exists() {
        config.save(&path)?;
        changes.push(format!("created {}", path.display()));
    }
    changes.extend(hooks::sync(home, &config)?);
    if remove_owned_legacy_unit(home)? {
        changes.push("removed legacy per-user service override".to_owned());
    }
    service.daemon_reload()?;
    service.enable_start()?;
    changes.push("enabled and started intelli-light.service".to_owned());
    Ok(changes)
}

pub fn uninstall(
    home: &Path,
    remove_config: bool,
    service: &mut impl UserServiceManager,
) -> Result<Vec<String>, String> {
    uninstall_with_socket(home, remove_config, service, &ipc::socket_path())
}

#[doc(hidden)]
pub fn uninstall_with_socket(
    home: &Path,
    remove_config: bool,
    service: &mut impl UserServiceManager,
    socket: &Path,
) -> Result<Vec<String>, String> {
    let mut changes = hooks::uninstall(home)?;
    service.disable_stop()?;
    changes.push("disabled and stopped intelli-light.service".to_owned());
    if remove_owned_legacy_unit(home)? {
        changes.push("removed legacy per-user service override".to_owned());
    }
    service.daemon_reload()?;
    if socket.exists() {
        fs::remove_file(socket).map_err(|error| format!("{}: {error}", socket.display()))?;
        changes.push(format!("removed {}", socket.display()));
    }
    if remove_config {
        let path = config_path(home);
        if path.exists() {
            fs::remove_file(&path).map_err(|error| format!("{}: {error}", path.display()))?;
            changes.push(format!("removed {}", path.display()));
        }
    }
    Ok(changes)
}

fn remove_owned_legacy_unit(home: &Path) -> Result<bool, String> {
    let path = home.join(".config/systemd/user/intelli-light.service");
    if !path.exists() {
        return Ok(false);
    }
    let contents = fs::read_to_string(&path).map_err(|error| error.to_string())?;
    if !contents.contains(OWNED_UNIT_MARKER)
        || !contents.contains("ExecStart=%h/.local/bin/intelli-light-linux daemon")
    {
        return Ok(false);
    }
    fs::remove_file(&path).map_err(|error| error.to_string())?;
    Ok(true)
}

fn systemctl(arguments: &[&str]) -> Result<(), String> {
    let output = Command::new("systemctl")
        .arg("--user")
        .args(arguments)
        .output()
        .map_err(|error| format!("could not run systemctl --user: {error}"))?;
    if output.status.success() {
        return Ok(());
    }
    let detail = String::from_utf8_lossy(&output.stderr).trim().to_owned();
    Err(if detail.is_empty() {
        format!("systemctl --user {} failed", arguments.join(" "))
    } else {
        detail
    })
}
