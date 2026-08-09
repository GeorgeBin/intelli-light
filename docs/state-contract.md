# Cross-platform agent state contract

This document is the normative state and arbitration contract for intelli-light implementations. The current Swift/macOS implementation and future Rust/Linux implementations must produce the same results for the fixtures in `Tests/fixtures/state-contract/`.

## Providers and session identity

`AgentProvider` has two values:

| Wire value | Provider |
| --- | --- |
| `codex` | Codex |
| `claude` | Claude |

A session is uniquely identified by the pair `(provider, sessionId)`. Its persisted key is `<provider>:<sessionId>`, for example `claude:abc`. A legacy pin containing only a session ID is interpreted as a Codex session.

Provider enablement is applied before arbitration. Sessions from disabled providers do not affect the global state, light state, or UI selection.

## SessionState wire format

[`session-state.schema.json`](session-state.schema.json) is the machine-readable Draft 2020-12 schema. `state` is the only field required by the compatibility reader. Current writers should emit every field.

| Field | Type | Missing-field default | Meaning |
| --- | --- | --- | --- |
| `provider` | `codex \| claude` | `codex` | Agent provider. The default preserves legacy Codex state files. |
| `state` | string | required | Provider wire state, normalized below. |
| `label` | string | `""` | Human-readable current activity. |
| `tool` | string | `""` | Current or most recent tool name. |
| `project` | string | `""` | Human-readable project name. |
| `sessionId` | string | `""` | Provider-local session ID. |
| `transcript` | string | `""` | Provider transcript path, if known. |
| `startedAt` | number | `0` | Unix seconds when the turn began; `0` means no clock. |
| `pausedTotal` | number | `0` | Accumulated paused seconds in the turn. |
| `pauseStart` | number | `0` | Unix seconds when the current pause began; `0` means not paused. |
| `ts` | number | `0` | Unix seconds when the state writer last updated the record. |
| `ownerPid` | non-negative integer | `0` | Owning process ID; `0` means unavailable. |
| `ownerKind` | `session \| global \| unknown` | `unknown` | Reliability class of `ownerPid`. |

Readers ignore additional fields. Schema-invalid field values are non-conforming input. Unknown string values in `state` are intentionally accepted and fail safe to `Idle`.

## AgentState and normalization

`AgentState` has seven values. The first matching row defines wire normalization:

| AgentState | Wire `state` values |
| --- | --- |
| Waiting Approval | `permission`, `waitingApproval` |
| Waiting Input | `waitingInput` |
| Waiting Implementation | `waitingImplementation` |
| Error | `error` |
| Working | `thinking`, `tool`, `working` |
| Done | `done` |
| Idle | `idle`, any unknown value |

The total arbitration priority, from highest to lowest, is:

```text
Waiting Approval > Waiting Input > Waiting Implementation > Error > Working > Done > Idle
```

The global `AgentState` is the highest normalized state among all eligible sessions from enabled providers. If no eligible session remains, it is `Idle`.

## Liveness and terminal visibility

All comparisons use Unix seconds and are inclusive at the boundary.

- The general stale window is `now - ts <= 900` seconds.
- Waiting Approval, Waiting Input, and Waiting Implementation are action-required states. With `ownerPid > 0`, they bypass the 900-second stale window and remain eligible exactly while that process is alive. A dead owner makes them immediately ineligible, regardless of `ownerKind`.
- An action-required state without an owner PID is eligible only while `now - ts <= 60` seconds.
- Working with a reliable owner (`ownerKind == session` and `ownerPid > 0`) requires both general freshness and a live owner.
- Working without a reliable session owner is eligible only while `now - ts <= 60` seconds. A `global` owner does not extend Working visibility.
- Idle, Done, and Error use the general stale rule and are not ended by owner exit.
- Done and Error additionally participate in display and arbitration only while `now - terminalTimestamp <= 2` seconds. `terminalTimestamp` is the recorded time of the current terminal event, falling back to `ts`. After expiry, another eligible session may win; otherwise the result is `Idle`.

Process liveness is an input to the platform-independent contract. Each platform may use its native process probe, but must feed the same alive/dead result into these rules.

## LightState and arbitration

The global AgentState maps to the provider-independent `LightState` as follows:

| AgentState | LightState |
| --- | --- |
| Working | Working |
| Waiting Approval | Action Required |
| Waiting Input | Action Required |
| Waiting Implementation | Action Required |
| Error | Error |
| Done | Done |
| Idle | Idle |

Global arbitration is independent of UI focus:

1. Exclude disabled providers.
2. Exclude sessions that fail liveness or terminal visibility.
3. Select the highest AgentState priority across all remaining providers and sessions.
4. Map that AgentState to LightState.

`pinnedSession` affects only which eligible session is shown in the single UI slot. An eligible pinned session is shown even when another session has a higher AgentState. Without a valid pin, the most recently updated eligible session is shown. Pinning never changes the global AgentState or GeorgeLight state.

## Executable fixtures

Each JSON file under `Tests/fixtures/state-contract/` contains independent scenarios with a fixed `now`, enabled providers, synthetic owner-liveness results, terminal event timestamps, raw SessionState objects, and expected outputs. Composite session keys are used in `ownerLiveness`, `terminalShownAt`, `pinnedSession`, and `expected.displaySession`.

The fixture files are platform-neutral test inputs. Implementations must not replace their synthetic owner-liveness values with real PID probes or their fixed timestamps with the wall clock.
