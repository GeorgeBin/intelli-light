use crate::config::{config_path, Config};
use crate::ipc::{self, IpcRequest};
use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::thread;
use std::time::Duration;

pub fn run(home: &Path) -> Result<(), String> {
    let os = os_description();
    check("OS", true, &os);
    check("Architecture", true, debian_architecture());

    provider("Codex", "codex");
    provider("Claude Code", "claude");

    let config_path = config_path(home);
    match Config::load(&config_path) {
        Ok(config) => {
            check(
                "Config",
                config_path.exists(),
                &config_path.display().to_string(),
            );
            let hooks_ok = config.enabled_providers.iter().all(|provider| {
                let root = home.join(format!(".{}", provider.as_str()));
                let file = root.join(if provider.as_str() == "codex" {
                    "hooks.json"
                } else {
                    "settings.json"
                });
                fs::read_to_string(file).is_ok_and(|contents| contents.contains("statusbar"))
            });
            check("Hooks", hooks_ok, "enabled provider hooks");
            check("GeorgeLight address", true, &config.george_light.address);
        }
        Err(error) => check("Config", false, &error),
    }

    check_command(
        "systemd --user",
        &["systemctl", "--user", "show-environment"],
        "available",
    );
    check_command(
        "Daemon",
        &["systemctl", "--user", "is-active", "intelli-light.service"],
        "active",
    );
    check(
        "Session D-Bus",
        env::var_os("DBUS_SESSION_BUS_ADDRESS").is_some(),
        "DBUS_SESSION_BUS_ADDRESS",
    );
    let desktop = find_executable("intelli-light-desktop");
    check("KDE Desktop", desktop.is_some(), "intelli-light-desktop");
    match desktop {
        Some(path) => check_desktop_libraries(&path),
        None => check("Qt/KF6 runtime", false, "desktop executable unavailable"),
    }
    check_command(
        "Plasma tray",
        &[
            "busctl",
            "--user",
            "status",
            "org.kde.StatusNotifierWatcher",
        ],
        "StatusNotifierWatcher available",
    );

    match request_snapshot() {
        Ok(response) => {
            check(
                "IPC",
                response["ok"].as_bool() == Some(true),
                &ipc::socket_path().display().to_string(),
            );
            let light = &response["snapshot"]["georgeLight"];
            let connectivity = light["connectivity"].as_str().unwrap_or("unknown");
            check(
                "GeorgeLight connectivity",
                matches!(connectivity, "connected" | "disabled"),
                connectivity,
            );
        }
        Err(error) => {
            check("IPC", false, &error);
            check(
                "GeorgeLight connectivity",
                false,
                "unknown (daemon unavailable)",
            );
        }
    }
    Ok(())
}

fn request_snapshot() -> Result<serde_json::Value, String> {
    let mut last_error = "IPC unavailable".to_owned();
    for attempt in 0..3 {
        match ipc::request(&IpcRequest::GetSnapshot) {
            Ok(response) => return Ok(response),
            Err(error) => last_error = error,
        }
        if attempt < 2 {
            thread::sleep(Duration::from_millis(250));
        }
    }
    Err(last_error)
}

fn provider(label: &str, executable: &str) {
    match find_executable(executable) {
        Some(path) => check(label, true, &path.display().to_string()),
        None => println!("WARN  {label}: executable not found (provider unavailable)"),
    }
}

fn check_command(label: &str, command: &[&str], success_detail: &str) {
    let Some((program, arguments)) = command.split_first() else {
        return;
    };
    match Command::new(program).args(arguments).output() {
        Ok(output) if output.status.success() => check(label, true, success_detail),
        Ok(output) => {
            let text = String::from_utf8_lossy(&output.stderr);
            check(label, false, text.trim());
        }
        Err(error) => check(label, false, &error.to_string()),
    }
}

fn check(label: &str, ok: bool, detail: &str) {
    println!(
        "{}  {label}: {}",
        if ok { "OK  " } else { "WARN" },
        if detail.is_empty() { "-" } else { detail }
    );
}

fn find_executable(name: &str) -> Option<PathBuf> {
    let path = env::var_os("PATH")?;
    env::split_paths(&path)
        .map(|directory| directory.join(name))
        .find(|candidate| candidate.is_file())
}

fn check_desktop_libraries(executable: &Path) {
    match Command::new("ldd").arg(executable).output() {
        Ok(output) => {
            let libraries = String::from_utf8_lossy(&output.stdout);
            let ok = output.status.success() && !libraries.contains("not found");
            check(
                "Qt/KF6 runtime",
                ok,
                if ok {
                    "all desktop libraries resolved"
                } else {
                    "one or more desktop libraries are missing"
                },
            );
        }
        Err(error) => check("Qt/KF6 runtime", false, &error.to_string()),
    }
}

fn os_description() -> String {
    fs::read_to_string("/etc/os-release")
        .ok()
        .and_then(|contents| {
            contents.lines().find_map(|line| {
                line.strip_prefix("PRETTY_NAME=")
                    .map(|value| value.trim_matches('"').to_owned())
            })
        })
        .unwrap_or_else(|| env::consts::OS.to_owned())
}

fn debian_architecture() -> &'static str {
    match env::consts::ARCH {
        "x86_64" => "amd64",
        "aarch64" => "arm64",
        other => other,
    }
}
