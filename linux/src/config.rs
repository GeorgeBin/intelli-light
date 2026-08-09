use crate::{AgentProvider, LightState};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

pub const DEFAULT_GEORGE_LIGHT_ADDRESS: &str = "http://george-light-zero.local";

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Config {
    #[serde(default = "default_providers")]
    pub enabled_providers: Vec<AgentProvider>,
    #[serde(default)]
    pub george_light: GeorgeLightConfig,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GeorgeLightConfig {
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default = "default_address")]
    pub address: String,
    #[serde(default)]
    pub effects: Effects,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Effects {
    #[serde(default = "Effect::working")]
    pub working: Effect,
    #[serde(default = "Effect::action_required")]
    pub action_required: Effect,
    #[serde(default = "Effect::error")]
    pub error: Effect,
    #[serde(default = "Effect::done")]
    pub done: Effect,
}

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Effect {
    pub color: String,
    pub mode_id: u8,
    pub duration_sec: u32,
    pub brightness: u8,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            enabled_providers: default_providers(),
            george_light: GeorgeLightConfig::default(),
        }
    }
}

impl Default for GeorgeLightConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            address: default_address(),
            effects: Effects::default(),
        }
    }
}

impl Default for Effects {
    fn default() -> Self {
        Self {
            working: Effect::working(),
            action_required: Effect::action_required(),
            error: Effect::error(),
            done: Effect::done(),
        }
    }
}

impl Effect {
    pub fn working() -> Self {
        Self::new("#4D8FFF", 3, 300, 70)
    }

    pub fn action_required() -> Self {
        Self::new("#F2BA2E", 4, 300, 90)
    }

    pub fn error() -> Self {
        Self::new("#FF0000", 4, 10, 90)
    }

    pub fn done() -> Self {
        Self::new("#4DC766", 1, 10, 80)
    }

    fn new(color: &str, mode_id: u8, duration_sec: u32, brightness: u8) -> Self {
        Self {
            color: color.to_owned(),
            mode_id,
            duration_sec,
            brightness,
        }
    }
}

impl Effects {
    pub fn for_state(&self, state: LightState) -> Option<&Effect> {
        match state {
            LightState::Working => Some(&self.working),
            LightState::ActionRequired => Some(&self.action_required),
            LightState::Error => Some(&self.error),
            LightState::Done => Some(&self.done),
            LightState::Idle => None,
        }
    }

    fn for_name_mut(&mut self, name: &str) -> Option<&mut Effect> {
        match name {
            "working" => Some(&mut self.working),
            "actionRequired" => Some(&mut self.action_required),
            "error" => Some(&mut self.error),
            "done" => Some(&mut self.done),
            _ => None,
        }
    }
}

impl Config {
    pub fn load(path: &Path) -> Result<Self, String> {
        if !path.exists() {
            return Ok(Self::default());
        }
        let data = fs::read(path).map_err(|error| format!("{}: {error}", path.display()))?;
        let config: Self = serde_json::from_slice(&data)
            .map_err(|error| format!("{}: {error}", path.display()))?;
        config.validate()?;
        Ok(config)
    }

    pub fn save(&self, path: &Path) -> Result<(), String> {
        self.validate()?;
        let parent = path.parent().ok_or("config path has no parent")?;
        fs::create_dir_all(parent).map_err(|error| error.to_string())?;
        set_private_directory(parent).map_err(|error| error.to_string())?;
        let data = serde_json::to_vec_pretty(self).map_err(|error| error.to_string())?;
        let temporary = path.with_extension(format!("tmp.{}", std::process::id()));
        fs::write(&temporary, [data, b"\n".to_vec()].concat())
            .map_err(|error| error.to_string())?;
        set_private_file(&temporary).map_err(|error| error.to_string())?;
        fs::rename(&temporary, path).map_err(|error| error.to_string())?;
        Ok(())
    }

    pub fn validate(&self) -> Result<(), String> {
        let providers: HashSet<_> = self.enabled_providers.iter().copied().collect();
        if providers.is_empty() || providers.len() != self.enabled_providers.len() {
            return Err("enabledProviders must contain one or two unique providers".to_owned());
        }
        validate_http_address(&self.george_light.address)?;
        for effect in [
            &self.george_light.effects.working,
            &self.george_light.effects.action_required,
            &self.george_light.effects.error,
            &self.george_light.effects.done,
        ] {
            if !is_hex_color(&effect.color) {
                return Err(format!("invalid effect color: {}", effect.color));
            }
            if !(1..=4).contains(&effect.mode_id) {
                return Err("effect modeId must be between 1 and 4".to_owned());
            }
            if effect.brightness > 100 {
                return Err("effect brightness must be at most 100".to_owned());
            }
        }
        Ok(())
    }

    pub fn set(&mut self, key: &str, value: &str) -> Result<(), String> {
        match key {
            "providers" | "enabledProviders" => {
                let parsed: Result<Vec<_>, _> = value.split(',').map(str::parse).collect();
                self.enabled_providers = parsed?;
            }
            "georgeLight.enabled" => {
                self.george_light.enabled = value
                    .parse()
                    .map_err(|_| "value must be true or false".to_owned())?;
            }
            "georgeLight.address" => self.george_light.address = value.to_owned(),
            _ => self.set_effect_field(key, value)?,
        }
        self.validate()
    }

    fn set_effect_field(&mut self, key: &str, value: &str) -> Result<(), String> {
        let parts: Vec<_> = key.split('.').collect();
        if parts.len() != 3 || parts[0] != "effects" {
            return Err(format!("unknown config key: {key}"));
        }
        let effect = self
            .george_light
            .effects
            .for_name_mut(parts[1])
            .ok_or_else(|| format!("unknown effect: {}", parts[1]))?;
        match parts[2] {
            "color" => effect.color = value.to_owned(),
            "modeId" => effect.mode_id = parse_number(value, "modeId")?,
            "durationSec" => effect.duration_sec = parse_number(value, "durationSec")?,
            "brightness" => effect.brightness = parse_number(value, "brightness")?,
            field => return Err(format!("unknown effect field: {field}")),
        }
        Ok(())
    }
}

pub fn config_path(home: &Path) -> PathBuf {
    home.join(".config/intelli-light/config.json")
}

pub fn validate_http_address(value: &str) -> Result<(), String> {
    let rest = value
        .strip_prefix("http://")
        .ok_or("GeorgeLight address must use http://")?;
    if rest.is_empty() || rest.contains(['/', '?', '#', '@']) {
        return Err(
            "GeorgeLight address must contain only an HTTP host and optional port".to_owned(),
        );
    }
    Ok(())
}

fn parse_number<T: std::str::FromStr>(value: &str, field: &str) -> Result<T, String> {
    value
        .parse()
        .map_err(|_| format!("invalid {field}: {value}"))
}

fn is_hex_color(value: &str) -> bool {
    value.len() == 7
        && value.starts_with('#')
        && value[1..].bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn default_providers() -> Vec<AgentProvider> {
    AgentProvider::ALL.to_vec()
}

fn default_true() -> bool {
    true
}

fn default_address() -> String {
    DEFAULT_GEORGE_LIGHT_ADDRESS.to_owned()
}

#[cfg(unix)]
fn set_private_directory(path: &Path) -> io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))
}

#[cfg(unix)]
fn set_private_file(path: &Path) -> io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))
}

#[cfg(not(unix))]
fn set_private_directory(_path: &Path) -> io::Result<()> {
    Ok(())
}

#[cfg(not(unix))]
fn set_private_file(_path: &Path) -> io::Result<()> {
    Ok(())
}
