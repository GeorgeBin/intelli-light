use intelli_light_linux::config::{config_path, Config};
use intelli_light_linux::user_lifecycle::{setup, uninstall_with_socket, UserServiceManager};
use serde_json::{json, Value};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Default)]
struct Service {
    reloads: usize,
    starts: usize,
    stops: usize,
}

impl UserServiceManager for Service {
    fn daemon_reload(&mut self) -> Result<(), String> {
        self.reloads += 1;
        Ok(())
    }

    fn enable_start(&mut self) -> Result<(), String> {
        self.starts += 1;
        Ok(())
    }

    fn disable_stop(&mut self) -> Result<(), String> {
        self.stops += 1;
        Ok(())
    }
}

#[test]
fn setup_is_idempotent_and_migrates_owned_legacy_unit() {
    let home = TestHome::new("setup");
    write_json(
        &home.path().join(".codex/hooks.json"),
        &json!({"userSetting": true, "hooks": {"Stop": [{"hooks": [
            {"type": "command", "command": "echo keep-me"}
        ]}]}}),
    );
    let legacy = home
        .path()
        .join(".config/systemd/user/intelli-light.service");
    fs::create_dir_all(legacy.parent().unwrap()).unwrap();
    fs::write(
        &legacy,
        concat!(
            "[Unit]\nDescription=Intelli Light headless agent status daemon\n",
            "[Service]\nExecStart=%h/.local/bin/intelli-light-linux daemon\n"
        ),
    )
    .unwrap();

    let mut service = Service::default();
    setup(home.path(), &mut service).unwrap();
    setup(home.path(), &mut service).unwrap();
    assert!(!legacy.exists());
    assert!(config_path(home.path()).exists());
    let codex = read_json(&home.path().join(".codex/hooks.json"));
    assert_eq!(codex["userSetting"], true);
    assert!(codex.to_string().contains("echo keep-me"));
    assert_eq!(service.reloads, 2);
    assert_eq!(service.starts, 2);
}

#[test]
fn uninstall_removes_only_owned_hooks_and_preserves_config_by_default() {
    let home = TestHome::new("uninstall");
    let mut service = Service::default();
    setup(home.path(), &mut service).unwrap();
    let config = config_path(home.path());
    let socket = home.path().join("runtime/daemon.sock");
    fs::create_dir_all(socket.parent().unwrap()).unwrap();
    fs::write(&socket, "socket-placeholder").unwrap();

    uninstall_with_socket(home.path(), false, &mut service, &socket).unwrap();
    assert!(config.exists());
    assert!(!socket.exists());
    assert_eq!(service.stops, 1);
    for file in [
        home.path().join(".codex/hooks.json"),
        home.path().join(".claude/settings.json"),
    ] {
        assert!(!read_json(&file).to_string().contains("statusbar"));
    }

    uninstall_with_socket(home.path(), true, &mut service, &socket).unwrap();
    assert!(!config.exists());
}

fn write_json(path: &Path, value: &Value) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, serde_json::to_vec(value).unwrap()).unwrap();
}

fn read_json(path: &Path) -> Value {
    serde_json::from_slice(&fs::read(path).unwrap()).unwrap()
}

struct TestHome(PathBuf);

impl TestHome {
    fn new(name: &str) -> Self {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!(
            "intelli-light-user-{name}-{}-{nonce}",
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
fn default_config_remains_valid_for_packaged_setup() {
    Config::default().validate().unwrap();
}
