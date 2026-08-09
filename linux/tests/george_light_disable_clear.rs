use intelli_light_linux::config::Config;
use intelli_light_linux::george_light::{
    Connectivity, GeorgeLightOutput, HttpRequest, HttpTransport,
};
use intelli_light_linux::LightState;
use serde_json::{json, Value};
use std::io;

struct StatusTransport(u16);

impl HttpTransport for StatusTransport {
    fn send(&mut self, _request: &HttpRequest) -> io::Result<u16> {
        Ok(self.0)
    }
}

fn output() -> GeorgeLightOutput {
    GeorgeLightOutput::new(Config::default().george_light).unwrap()
}

fn path_body(pending: &intelli_light_linux::george_light::PendingRequest) -> (String, Value) {
    let path = pending.request.path.clone();
    let body = pending
        .request
        .body
        .as_ref()
        .map(|bytes| serde_json::from_slice(bytes).unwrap())
        .unwrap_or(Value::Null);
    (path, body)
}

#[test]
fn disable_clear_success_enters_disabled() {
    let mut gl = output();
    gl.set_state(LightState::Working, 0.0);
    let display = gl.next_request(0.0).unwrap().unwrap();
    gl.complete(&display, true, 0.0);
    assert_eq!(gl.connectivity(), Connectivity::Connected);

    gl.set_enabled(false, 1.0);
    assert_eq!(gl.connectivity(), Connectivity::Retrying);
    let clear = gl.next_request(1.0).unwrap().unwrap();
    let (path, body) = path_body(&clear);
    assert_eq!(path, "/api/v1/codex/clear");
    assert_eq!(body, Value::Null);
    gl.complete(&clear, true, 1.0);
    assert_eq!(gl.connectivity(), Connectivity::Disabled);
    assert!(gl.next_request(1.0).unwrap().is_none());
}

#[test]
fn disable_clear_network_failure_retries() {
    let mut gl = output();
    gl.set_enabled(false, 0.0);
    let clear = gl.next_request(0.0).unwrap().unwrap();
    assert_eq!(clear.request.path, "/api/v1/codex/clear");
    // Network failure: not formally disabled and no false success report.
    gl.complete(&clear, false, 0.0);
    assert_eq!(gl.connectivity(), Connectivity::Retrying);
    // Backoff is [2, ...]: nothing fires before 2 s.
    assert!(gl.next_request(1.999).unwrap().is_none());
    let retry = gl.next_request(2.0).unwrap().unwrap();
    assert_eq!(retry.request.path, "/api/v1/codex/clear");
}

#[test]
fn disable_clear_http_non_2xx_retries() {
    let mut gl = output();
    gl.set_enabled(false, 0.0);
    let mut transport = StatusTransport(500);
    let ok = gl.drive(0.0, &mut transport).unwrap();
    assert!(!ok);
    assert_eq!(gl.connectivity(), Connectivity::Retrying);
    assert!(gl.next_request(1.999).unwrap().is_none());
    let retry = gl.next_request(2.0).unwrap().unwrap();
    assert_eq!(retry.request.path, "/api/v1/codex/clear");
}

#[test]
fn disable_clear_retries_until_success() {
    let mut gl = output();
    gl.set_enabled(false, 0.0);
    let clear = gl.next_request(0.0).unwrap().unwrap();
    gl.complete(&clear, false, 0.0);
    let retry = gl.next_request(2.0).unwrap().unwrap();
    assert_eq!(retry.request.path, "/api/v1/codex/clear");
    gl.complete(&retry, true, 2.0);
    assert_eq!(gl.connectivity(), Connectivity::Disabled);
    assert!(gl.next_request(2.0).unwrap().is_none());
}

#[test]
fn disable_clear_retries_cap_at_sixty_seconds() {
    let mut gl = output();
    gl.set_enabled(false, 0.0);
    // The schedule climbs 2, 5, 10, 30, 60 then stays at 60 s forever.
    let delays = [2.0, 5.0, 10.0, 30.0, 60.0, 60.0];
    let mut t = 0.0;
    for (index, &delay) in delays.iter().enumerate() {
        let clear = gl.next_request(t).unwrap().unwrap();
        assert_eq!(clear.request.path, "/api/v1/codex/clear");
        gl.complete(&clear, false, t);
        t += delay;
        if index < delays.len() - 1 {
            assert!(gl.next_request(t - 0.001).unwrap().is_none());
        }
    }
    assert_eq!(gl.connectivity(), Connectivity::Retrying);
    assert_eq!(
        gl.next_request(t).unwrap().unwrap().request.path,
        "/api/v1/codex/clear"
    );
}

#[test]
fn re_enable_during_disable_clear_retry_cancels_retry_and_outputs_desired() {
    let mut gl = output();
    gl.set_state(LightState::Working, 0.0);
    let display = gl.next_request(0.0).unwrap().unwrap();
    gl.complete(&display, true, 0.0);

    gl.set_enabled(false, 1.0);
    let clear = gl.next_request(1.0).unwrap().unwrap();
    gl.complete(&clear, false, 1.0); // retry armed at 3 s

    // Re-enable before the retry fires: the clear retry is canceled and the
    // current desired state is output immediately.
    gl.set_enabled(true, 1.5);
    gl.set_state(LightState::Error, 1.5);
    let request = gl.next_request(1.5).unwrap().unwrap();
    let (path, body) = path_body(&request);
    assert_eq!(path, "/api/v1/codex/display");
    assert_eq!(body["color"], "#FF0000");
    gl.complete(&request, true, 1.5);
    assert_eq!(gl.connectivity(), Connectivity::Connected);
}

#[test]
fn stale_disable_clear_completion_does_not_overwrite_new_state() {
    let mut gl = output();
    gl.set_state(LightState::Working, 0.0);
    let display = gl.next_request(0.0).unwrap().unwrap();
    gl.complete(&display, true, 0.0);

    gl.set_enabled(false, 1.0);
    let clear = gl.next_request(1.0).unwrap().unwrap(); // in flight

    // Re-enable while the clear is still in flight, then change the desired state.
    gl.set_enabled(true, 1.2);
    gl.set_state(LightState::Done, 1.2);

    // The stale disable-clear completes late: it must not report Disabled.
    gl.complete(&clear, true, 1.3);
    assert_ne!(gl.connectivity(), Connectivity::Disabled);

    let request = gl.next_request(1.3).unwrap().unwrap();
    let (path, body) = path_body(&request);
    assert_eq!(path, "/api/v1/codex/display");
    assert_eq!(body["color"], "#4DC766");
    gl.complete(&request, true, 1.3);
    assert_eq!(gl.connectivity(), Connectivity::Connected);
}

#[test]
fn disable_clear_retry_survives_disabled_config_update() {
    let mut gl = output();
    gl.set_state(LightState::Working, 0.0);
    let display = gl.next_request(0.0).unwrap().unwrap();
    gl.complete(&display, true, 0.0);

    gl.set_enabled(false, 1.0);
    let clear = gl.next_request(1.0).unwrap().unwrap();
    gl.complete(&clear, false, 1.0); // retry armed at 3 s

    // A config update while already disabled (retry pending) must not falsely
    // report Disabled nor cancel the retry.
    let config = serde_json::from_value(json!({
        "enabled": false,
        "address": "http://lamp.local",
        "effects": {
            "working": {"color": "#4D8FFF", "modeId": 3, "durationSec": 300, "brightness": 70},
            "actionRequired": {"color": "#F2BA2E", "modeId": 4, "durationSec": 300, "brightness": 90},
            "error": {"color": "#FF0000", "modeId": 4, "durationSec": 10, "brightness": 90},
            "done": {"color": "#4DC766", "modeId": 1, "durationSec": 10, "brightness": 80}
        }
    }))
    .unwrap();
    gl.update_config(config, 1.5).unwrap();
    assert_eq!(gl.connectivity(), Connectivity::Retrying);
    let clear = gl.next_request(1.5).unwrap().unwrap();
    assert_eq!(clear.request.path, "/api/v1/codex/clear");
    gl.complete(&clear, true, 1.5);
    assert_eq!(gl.connectivity(), Connectivity::Disabled);
}

#[test]
fn disable_config_update_while_clear_in_flight_rearms_clear() {
    for stale_clear_succeeded in [true, false] {
        let mut gl = output();
        gl.set_state(LightState::Working, 0.0);
        let display = gl.next_request(0.0).unwrap().unwrap();
        gl.complete(&display, true, 0.0);

        gl.set_enabled(false, 1.0);
        let old_clear = gl.next_request(1.0).unwrap().unwrap();
        assert_eq!(old_clear.request.path, "/api/v1/codex/clear");
        assert_eq!(old_clear.request.host, "george-light-zero.local");

        let mut updated = Config::default().george_light;
        updated.enabled = false;
        updated.address = "http://updated-lamp.local:8080".to_owned();
        gl.update_config(updated, 1.1).unwrap();

        // The old generation is still in flight, so the replacement clear must
        // be armed without allowing a second concurrent HTTP request.
        assert!(gl.next_request(1.1).unwrap().is_none());
        gl.complete(&old_clear, stale_clear_succeeded, 1.2);
        assert_ne!(gl.connectivity(), Connectivity::Disabled);

        let new_clear = gl.next_request(1.2).unwrap().unwrap();
        assert_eq!(new_clear.request.path, "/api/v1/codex/clear");
        assert_eq!(new_clear.request.host, "updated-lamp.local");
        assert_eq!(new_clear.request.port, 8080);
        assert_eq!(gl.connectivity(), Connectivity::Retrying);

        gl.complete(&new_clear, true, 1.2);
        assert_eq!(gl.connectivity(), Connectivity::Disabled);
        assert!(gl.next_request(1.2).unwrap().is_none());
    }
}

#[test]
fn json_output_uses_display_path_and_idle_maps_to_clear() {
    let config = json!({
        "enabled": true,
        "address": "http://george-light-zero.local",
        "effects": {
            "working": {"color": "#4D8FFF", "modeId": 3, "durationSec": 300, "brightness": 70},
            "actionRequired": {"color": "#F2BA2E", "modeId": 4, "durationSec": 300, "brightness": 90},
            "error": {"color": "#FF0000", "modeId": 4, "durationSec": 10, "brightness": 90},
            "done": {"color": "#4DC766", "modeId": 1, "durationSec": 10, "brightness": 80}
        }
    });
    let config = serde_json::from_value(config).unwrap();
    let mut gl = GeorgeLightOutput::new(config).unwrap();
    gl.set_state(LightState::Done, 0.0);
    let (path, body) = path_body(&gl.next_request(0.0).unwrap().unwrap());
    assert_eq!(path, "/api/v1/codex/display");
    assert_eq!(body["color"], "#4DC766");
    assert_eq!(body["mode_id"], 1);
}
