use crate::config::Config;
use crate::george_light::{GeorgeLightOutput, HttpTransport, TcpHttpTransport};
use crate::state_store;
use crate::{arbitrate, AgentProvider, LightState, LinuxPidLiveness};
use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

static RUNNING: AtomicBool = AtomicBool::new(true);

extern "C" fn stop(_signal: libc::c_int) {
    RUNNING.store(false, Ordering::SeqCst);
}

pub fn run(home: &Path, config: Config) -> Result<(), String> {
    install_signal_handlers();
    let enabled: HashSet<_> = config.enabled_providers.iter().copied().collect();
    let mut output = GeorgeLightOutput::new(config.george_light.clone())?;
    let mut transport = TcpHttpTransport;
    let started = Instant::now();
    let mut previous = None;

    while RUNNING.load(Ordering::SeqCst) {
        let snapshot = state_store::load(home);
        let now = unix_now()?;
        let result = arbitrate(
            &enabled,
            &snapshot.sessions,
            now,
            &LinuxPidLiveness,
            &HashMap::new(),
            None,
        );
        if previous != Some(result.light_state) {
            println!(
                "state={} light={} display={} sessions={} lifecycle={}",
                result.agent_state,
                result.light_state,
                result
                    .display_session
                    .map(|session| session.key().to_string())
                    .unwrap_or_else(|| "none".to_owned()),
                result.eligible_sessions.len(),
                snapshot.active_session_files.len()
            );
            previous = Some(result.light_state);
            output.set_state(result.light_state, started.elapsed().as_secs_f64());
        }
        let monotonic = started.elapsed().as_secs_f64();
        if let Err(error) = output.drive(monotonic, &mut transport) {
            eprintln!("GeorgeLight request failed: {error}");
        }
        thread::sleep(Duration::from_millis(250));
    }

    if config.george_light.enabled {
        best_effort_clear(&output, &mut transport);
    }
    println!("daemon stopped; GeorgeLight cleared");
    Ok(())
}

pub fn evaluate_light(home: &Path, config: &Config, now: f64) -> LightState {
    let snapshot = state_store::load(home);
    let enabled: HashSet<AgentProvider> = config.enabled_providers.iter().copied().collect();
    arbitrate(
        &enabled,
        &snapshot.sessions,
        now,
        &LinuxPidLiveness,
        &HashMap::new(),
        None,
    )
    .light_state
}

fn best_effort_clear<T: HttpTransport>(output: &GeorgeLightOutput, transport: &mut T) {
    if let Ok(request) = output.clear_request() {
        let _ = transport.send(&request);
    }
}

fn unix_now() -> Result<f64, String> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs_f64())
        .map_err(|error| error.to_string())
}

fn install_signal_handlers() {
    RUNNING.store(true, Ordering::SeqCst);
    // SAFETY: the handler only performs an atomic store, which is signal-safe.
    unsafe {
        libc::signal(libc::SIGTERM, stop as *const () as libc::sighandler_t);
        libc::signal(libc::SIGINT, stop as *const () as libc::sighandler_t);
    }
}
