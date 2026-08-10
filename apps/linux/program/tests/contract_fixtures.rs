use intelli_light_linux::{arbitrate, AgentProvider, AgentState, LightState, SessionState};
use serde::Deserialize;
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct FixtureFile {
    contract_version: u32,
    scenarios: Vec<Scenario>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Scenario {
    name: String,
    now: f64,
    enabled_providers: Vec<AgentProvider>,
    #[serde(default)]
    owner_liveness: HashMap<String, bool>,
    #[serde(default)]
    terminal_shown_at: HashMap<String, f64>,
    #[serde(default)]
    pinned_session: Option<String>,
    sessions: Vec<SessionState>,
    expected: Expected,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Expected {
    agent_state: String,
    light_state: String,
    display_session: Option<String>,
}

#[test]
fn existing_cross_platform_contract_fixtures_match() {
    let fixture_directory =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../Tests/fixtures/state-contract");
    let mut files: Vec<PathBuf> = fs::read_dir(&fixture_directory)
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .filter(|path| {
            path.extension()
                .is_some_and(|extension| extension == "json")
        })
        .collect();
    files.sort();
    assert!(!files.is_empty(), "no contract fixtures found");

    let mut scenario_count = 0;
    for path in files {
        let fixture: FixtureFile = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        assert_eq!(fixture.contract_version, 1, "{}", path.display());
        for scenario in fixture.scenarios {
            scenario_count += 1;
            let context = format!("{} / {}", path.display(), scenario.name);
            let enabled: HashSet<_> = scenario.enabled_providers.into_iter().collect();
            let result = arbitrate(
                &enabled,
                &scenario.sessions,
                scenario.now,
                &|session: &SessionState| {
                    scenario
                        .owner_liveness
                        .get(&session.key().to_string())
                        .copied()
                        .unwrap_or(false)
                },
                &scenario.terminal_shown_at,
                scenario.pinned_session.as_deref(),
            );
            assert_eq!(
                result.agent_state,
                agent_state(&scenario.expected.agent_state),
                "{context}"
            );
            assert_eq!(
                result.light_state,
                light_state(&scenario.expected.light_state),
                "{context}"
            );
            assert_eq!(
                result
                    .display_session
                    .map(|session| session.key().to_string()),
                scenario.expected.display_session,
                "{context}"
            );
        }
    }
    assert_eq!(scenario_count, 36, "fixture scenario count changed");
}

fn agent_state(value: &str) -> AgentState {
    match value {
        "waitingApproval" => AgentState::WaitingApproval,
        "waitingInput" => AgentState::WaitingInput,
        "waitingImplementation" => AgentState::WaitingImplementation,
        "error" => AgentState::Error,
        "working" => AgentState::Working,
        "done" => AgentState::Done,
        "idle" => AgentState::Idle,
        _ => panic!("unknown expected AgentState: {value}"),
    }
}

fn light_state(value: &str) -> LightState {
    match value {
        "working" => LightState::Working,
        "actionRequired" => LightState::ActionRequired,
        "error" => LightState::Error,
        "done" => LightState::Done,
        "idle" => LightState::Idle,
        _ => panic!("unknown expected LightState: {value}"),
    }
}
