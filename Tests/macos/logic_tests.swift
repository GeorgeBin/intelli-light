import Foundation

// Standalone assertion harness. Compiled WITHOUT main.swift so it does not launch the GUI.
// Build: swiftc Tests/macos/logic_tests.swift apps/macos/program/SessionState.swift apps/macos/program/AppSupport.swift apps/macos/led/LightOutput.swift -o "$TMPDIR/csbt"
// Run:   "$TMPDIR/csbt"

var failures = 0
func check(_ cond: Bool, _ msg: String, file: String = #file, line: Int = #line) {
    if !cond { print("FAIL \(file):\(line) — \(msg)"); failures += 1 }
}
func eq<T: Equatable>(_ a: T, _ b: T, _ msg: String) { check(a == b, "\(a) != \(b) — \(msg)") }

func fixtureAgentState(_ value: String) -> AgentState? {
    switch value {
    case "waitingApproval": return .waitingApproval
    case "waitingInput": return .waitingInput
    case "waitingImplementation": return .waitingImplementation
    case "error": return .error
    case "working": return .working
    case "done": return .done
    case "idle": return .idle
    default: return nil
    }
}

func fixtureLightState(_ value: String) -> LightState? {
    switch value {
    case "working": return .working
    case "actionRequired": return .actionRequired
    case "error": return .error
    case "done": return .done
    case "idle": return .idle
    default: return nil
    }
}

func runStateContractFixtures() {
    let fixtureDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("fixtures/state-contract", isDirectory: true)
    let files: [URL]
    do {
        files = try FileManager.default.contentsOfDirectory(
            at: fixtureDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    } catch {
        check(false, "state-contract fixtures are unreadable: \(error)")
        return
    }
    check(!files.isEmpty, "state-contract fixtures exist")

    for file in files {
        let root: [String: Any]
        do {
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
            guard let dictionary = object as? [String: Any] else {
                check(false, "\(file.lastPathComponent): root is not an object")
                continue
            }
            root = dictionary
        } catch {
            check(false, "\(file.lastPathComponent): invalid JSON: \(error)")
            continue
        }
        eq((root["contractVersion"] as? NSNumber)?.intValue, 1,
           "\(file.lastPathComponent): supported contract version")
        guard let scenarios = root["scenarios"] as? [[String: Any]] else {
            check(false, "\(file.lastPathComponent): scenarios are missing")
            continue
        }

        for scenario in scenarios {
            let name = (scenario["name"] as? String) ?? "unnamed scenario"
            let context = "\(file.lastPathComponent) / \(name)"
            guard let now = (scenario["now"] as? NSNumber)?.doubleValue,
                  let providerValues = scenario["enabledProviders"] as? [String],
                  let sessionObjects = scenario["sessions"] as? [[String: Any]],
                  let expected = scenario["expected"] as? [String: Any],
                  let expectedAgentValue = expected["agentState"] as? String,
                  let expectedAgent = fixtureAgentState(expectedAgentValue),
                  let expectedLightValue = expected["lightState"] as? String,
                  let expectedLight = fixtureLightState(expectedLightValue) else {
                check(false, "\(context): required fixture fields are invalid")
                continue
            }
            let enabledProviders = Set(providerValues.compactMap(AgentProvider.init(rawValue:)))
            guard enabledProviders.count == providerValues.count else {
                check(false, "\(context): enabledProviders contains an unknown provider")
                continue
            }
            let parsedSessions = sessionObjects.compactMap(SessionState.init(json:))
            guard parsedSessions.count == sessionObjects.count else {
                check(false, "\(context): a SessionState object is invalid")
                continue
            }
            let ownerLiveness = (scenario["ownerLiveness"] as? [String: Bool]) ?? [:]
            let terminalNumbers = (scenario["terminalShownAt"] as? [String: NSNumber]) ?? [:]
            let terminalShownAt = terminalNumbers.mapValues(\.doubleValue)
            let eligible = parsedSessions.filter {
                enabledProviders.contains($0.provider) && $0.isDisplayEligible(
                    now: now, ownerAlive: ownerLiveness[$0.key.persistedValue] ?? false)
            }
            let actualAgent = arbitrateAgentState(
                enabledProviders: enabledProviders, sessions: eligible, now: now,
                terminalShownAt: terminalShownAt)
            let selected = selectDisplay(
                pinned: scenario["pinnedSession"] as? String, sessions: eligible, now: now,
                terminalShownAt: terminalShownAt)
            let expectedDisplay = expected["displaySession"] as? String

            eq(actualAgent, expectedAgent, "\(context): global AgentState")
            eq(actualAgent.lightState, expectedLight, "\(context): global LightState")
            eq(selected?.key.persistedValue, expectedDisplay, "\(context): UI display session")
        }
    }
}

// NOTE: Swift forbids top-level expressions outside main.swift. The build command pins
// this file's name (logic_tests.swift), so we wrap the executable body in an @main type.
@main
struct LogicTests {
    static func main() {
// ---- elapsedSeconds: net time ----
let now: TimeInterval = 1_000_000
eq(elapsedSeconds(now: now, startedAt: now - 100, pausedTotal: 30, pauseStart: 0), 70, "basic net")
eq(elapsedSeconds(now: now, startedAt: now - 100, pausedTotal: 0, pauseStart: 0), 100, "no pause")
eq(elapsedSeconds(now: now, startedAt: now - 100, pausedTotal: 30, pauseStart: now - 10), 60, "in active pause subtracts current pause")
eq(elapsedSeconds(now: now, startedAt: 0, pausedTotal: 0, pauseStart: 0), 0, "no startedAt -> 0")
eq(elapsedSeconds(now: now, startedAt: now + 50, pausedTotal: 0, pauseStart: 0), 0, "future startedAt clamps to 0")

// ---- display eligibility: global owners cannot keep old active sessions visible ----
func owned(_ state: String, _ pid: Int, _ ownerKind: String, _ age: TimeInterval = 0) -> SessionState {
    SessionState(state: state, label: "", tool: "", project: "", sessionId: "o", transcript: "", startedAt: 1, pausedTotal: 0, pauseStart: 0, ts: now - age, ownerPid: pid, ownerKind: ownerKind)
}

check(owned("thinking", 4242, "session").endedByOwnerExit(ownerAlive: false), "thinking + dead session owner -> ended")
check(!owned("thinking", 4242, "session").endedByOwnerExit(ownerAlive: true), "thinking + live session owner -> not ended")
check(!owned("thinking", 4242, "global").endedByOwnerExit(ownerAlive: false), "global owner is not a session owner exit")
check(!owned("done", 4242, "session").endedByOwnerExit(ownerAlive: false), "done is never ended by owner exit")
check(!owned("thinking", 0, "unknown").endedByOwnerExit(ownerAlive: false), "unknown owner -> freshness governs")

check(owned("thinking", 4242, "session").isDisplayEligible(now: now, ownerAlive: true), "live session owner keeps active state eligible")
check(!owned("thinking", 4242, "session").isDisplayEligible(now: now, ownerAlive: false), "dead session owner removes active state")
check(owned("tool", 79378, "global", 30).isDisplayEligible(now: now, ownerAlive: true), "recent global owner active state stays briefly visible")
check(!owned("tool", 79378, "global", 61).isDisplayEligible(now: now, ownerAlive: true), "old global owner active state stops displaying")
check(owned("permission", 0, "unknown", 30).isDisplayEligible(now: now, ownerAlive: false), "recent unknown owner active state stays briefly visible")
check(!owned("permission", 0, "unknown", 61).isDisplayEligible(now: now, ownerAlive: false), "old unknown owner active state stops displaying")
check(owned("permission", 4242, "global", 901).isDisplayEligible(now: now, ownerAlive: true), "live owner keeps approval visible past stale timeout")
check(!owned("permission", 4242, "global", 901).isDisplayEligible(now: now, ownerAlive: false), "dead owner removes stale approval")
check(owned("waitingInput", 4242, "global", 901).isDisplayEligible(now: now, ownerAlive: true), "live owner keeps input wait visible past stale timeout")
check(!owned("waitingInput", 4242, "global", 901).isDisplayEligible(now: now, ownerAlive: false), "dead owner removes stale input wait")
check(owned("waitingInput", 4242, "global", 901).endedByOwnerExit(ownerAlive: false), "input wait ends with any recorded owner")
check(owned("waitingInput", 4242, "global", 901).isRenderable(now: now, terminalShownAt: now - 100), "input wait never uses terminal timeout")
check(owned("waitingImplementation", 4242, "global", 901).isDisplayEligible(now: now, ownerAlive: true), "live owner keeps implementation wait visible past stale timeout")
check(!owned("waitingImplementation", 4242, "global", 901).isDisplayEligible(now: now, ownerAlive: false), "dead owner removes implementation wait")
check(owned("waitingImplementation", 4242, "global", 901).endedByOwnerExit(ownerAlive: false), "action wait ends with any recorded owner")
check(owned("waitingImplementation", 4242, "global", 901).isRenderable(now: now, terminalShownAt: now - 100), "implementation wait never uses terminal timeout")
check(owned("done", 0, "unknown", 600).isDisplayEligible(now: now, ownerAlive: false), "recent done state remains selectable for done rendering")
check(!owned("done", 0, "unknown", 901).isDisplayEligible(now: now, ownerAlive: false), "stale done state is not selectable")

if let parsedOwner = SessionState(json: ["state": "thinking", "ownerKind": "session", "ownerPid": 123]) {
    eq(parsedOwner.ownerKind, "session", "json ownerKind parses")
    eq(parsedOwner.ownerPid, 123, "json ownerPid parses")
} else {
    check(false, "json with owner fields parses")
}

if let parsedDefaultOwner = SessionState(json: ["state": "thinking"]) {
    eq(parsedDefaultOwner.ownerKind, "unknown", "missing json ownerKind defaults to unknown")
    eq(parsedDefaultOwner.ownerPid, 0, "missing json ownerPid defaults to 0")
} else {
    check(false, "json without owner fields parses")
}

if let parsedClaude = SessionState(json: ["state": "waitingApproval", "provider": "claude", "sessionId": "c1"]) {
    eq(parsedClaude.provider, .claude, "provider parses from unified state JSON")
    eq(parsedClaude.normalizedState, .waitingApproval, "Claude state normalizes")
} else {
    check(false, "Claude state JSON parses")
}
if let parsedLegacyCodex = SessionState(json: ["state": "tool", "sessionId": "legacy"]) {
    eq(parsedLegacyCodex.provider, .codex, "legacy Codex JSON defaults provider")
    eq(parsedLegacyCodex.normalizedState, .working, "legacy Codex tool normalizes")
}
if let parsedImplementation = SessionState(json: ["state": "waitingImplementation", "sessionId": "plan"]) {
    eq(parsedImplementation.normalizedState, .waitingImplementation, "implementation wait normalizes")
    eq(parsedImplementation.normalizedState.menuTitle, "Waiting Implementation", "implementation menu title")
} else {
    check(false, "implementation wait JSON parses")
}
if let parsedInput = SessionState(json: ["state": "waitingInput", "sessionId": "input"]) {
    eq(parsedInput.normalizedState, .waitingInput, "input wait normalizes")
    eq(parsedInput.normalizedState.menuTitle, "Waiting Input", "input wait menu title")
    check(parsedInput.normalizedState.requiresUserAction, "input wait requires user action")
} else {
    check(false, "input wait JSON parses")
}

// ---- selectDisplay: pinned wins if alive, else most recent alive, else nil ----
let sA = SessionState(state: "thinking", label: "A", tool: "", project: "A", sessionId: "a", transcript: "", startedAt: 1, pausedTotal: 0, pauseStart: 0, ts: now - 5)
let sB = SessionState(state: "tool", label: "B", tool: "Bash", project: "B", sessionId: "b", transcript: "", startedAt: 1, pausedTotal: 0, pauseStart: 0, ts: now - 1)
let sC = SessionState(state: "idle", label: "", tool: "", project: "C", sessionId: "c", transcript: "", startedAt: 0, pausedTotal: 0, pauseStart: 0, ts: now - 1000) // stale
let doneRecent = SessionState(state: "done", label: "Done", tool: "", project: "D", sessionId: "done-recent", transcript: "", startedAt: 0, pausedTotal: 0, pauseStart: 0, ts: now - 1)
let doneExpired = SessionState(state: "done", label: "Done", tool: "", project: "D", sessionId: "done-expired", transcript: "", startedAt: 0, pausedTotal: 0, pauseStart: 0, ts: now - 1)
let doneStaleNoSentinel = SessionState(state: "done", label: "Done", tool: "", project: "D", sessionId: "done-stale", transcript: "", startedAt: 0, pausedTotal: 0, pauseStart: 0, ts: now - 3)
let errorRecent = SessionState(state: "error", label: "Error", tool: "", project: "E", sessionId: "error-recent", transcript: "", startedAt: 0, pausedTotal: 0, pauseStart: 0, ts: now - 1)
let errorExpired = SessionState(state: "error", label: "Error", tool: "", project: "E", sessionId: "error-expired", transcript: "", startedAt: 0, pausedTotal: 0, pauseStart: 0, ts: now - 3)

eq(selectDisplay(pinned: nil, sessions: [sA, sB], now: now)?.sessionId, "b", "most recent wins when no pin")
eq(selectDisplay(pinned: "a", sessions: [sA, sB], now: now)?.sessionId, "a", "pinned wins when alive")
eq(selectDisplay(pinned: "c", sessions: [sA, sB, sC], now: now)?.sessionId, "b", "stale pinned falls back to recent alive")
eq(selectDisplay(pinned: nil, sessions: [sC], now: now).map { $0.sessionId }, .none, "only stale -> nil")
eq(selectDisplay(pinned: nil, sessions: [sA, doneExpired], now: now, terminalShownAt: ["done-expired": now - 3])?.sessionId, "a", "expired recent done falls back to older active session")
eq(selectDisplay(pinned: nil, sessions: [sA, doneRecent], now: now, terminalShownAt: ["done-recent": now - 1])?.sessionId, "done-recent", "non-expired done still wins by recency")
eq(selectDisplay(pinned: "done-expired", sessions: [sA, doneExpired], now: now, terminalShownAt: ["done-expired": now - 3])?.sessionId, "a", "pinned expired done falls back to active session")
eq(selectDisplay(pinned: nil, sessions: [sA, doneStaleNoSentinel], now: now)?.sessionId, "a", "done without sentinel uses state timestamp and does not replay after window")
eq(selectDisplay(pinned: nil, sessions: [sA, errorRecent], now: now)?.sessionId,
   "error-recent", "recent error is renderable")
eq(selectDisplay(pinned: nil, sessions: [sA, errorExpired], now: now)?.sessionId,
   "a", "expired error falls back to active session")

// ---- provider-independent arbitration and composite identities ----
var claudeWorking = sA
claudeWorking.provider = .claude
claudeWorking.sessionId = "shared"
claudeWorking.state = "working"
var codexSameId = sB
codexSameId.sessionId = "shared"
eq(claudeWorking.key.persistedValue, "claude:shared", "Claude session key is namespaced")
eq(codexSameId.key.persistedValue, "codex:shared", "Codex session key is namespaced")
eq(selectDisplay(pinned: "claude:shared", sessions: [codexSameId, claudeWorking], now: now)?.provider,
   .claude, "composite pin selects the intended provider")
eq(selectDisplay(pinned: "shared", sessions: [claudeWorking, codexSameId], now: now)?.provider,
   .codex, "legacy raw pin migrates as Codex")

var claudeApproval = claudeWorking
claudeApproval.sessionId = "approval"
claudeApproval.state = "waitingApproval"
claudeApproval.ts = now
var codexImplementation = codexSameId
codexImplementation.sessionId = "implementation"
codexImplementation.state = "waitingImplementation"
codexImplementation.ts = now
var codexInput = codexSameId
codexInput.sessionId = "input"
codexInput.state = "waitingInput"
codexInput.ts = now
var codexDone = doneRecent
codexDone.provider = .codex
var claudeError = errorRecent
claudeError.provider = .claude
eq(arbitrateAgentState(enabledProviders: [.codex, .claude],
                       sessions: [codexSameId, claudeApproval, codexDone], now: now),
   .waitingApproval, "approval wins across providers")
eq(arbitrateAgentState(enabledProviders: [.codex, .claude],
                       sessions: [codexSameId, claudeError, codexDone], now: now),
   .error, "error wins over working and done across providers")
eq(arbitrateAgentState(enabledProviders: [.codex, .claude],
                       sessions: [claudeApproval, claudeError], now: now),
   .waitingApproval, "approval wins over error")
eq(arbitrateAgentState(enabledProviders: [.codex, .claude],
                       sessions: [codexImplementation, claudeError, claudeWorking], now: now),
   .waitingImplementation, "implementation wait wins over error and working")
eq(arbitrateAgentState(enabledProviders: [.codex, .claude],
                       sessions: [codexImplementation, claudeApproval], now: now),
   .waitingApproval, "approval wins over implementation wait")
eq(arbitrateAgentState(enabledProviders: [.codex, .claude],
                       sessions: [codexInput, claudeApproval, codexImplementation], now: now),
   .waitingApproval, "approval wins over input and implementation waits")
eq(arbitrateAgentState(enabledProviders: [.codex, .claude],
                       sessions: [codexInput, codexImplementation, claudeError], now: now),
   .waitingInput, "input wait wins over implementation wait and error")
eq(arbitrateAgentState(enabledProviders: [.codex, .claude],
                       sessions: [codexImplementation, claudeError, codexSameId], now: now),
   .waitingImplementation, "implementation wait wins over error and working")
eq(arbitrateAgentState(enabledProviders: [.codex, .claude],
                       sessions: [codexSameId, claudeWorking, codexDone], now: now),
   .working, "working wins over done across providers")
eq(arbitrateAgentState(enabledProviders: [.codex],
                       sessions: [claudeApproval, codexDone], now: now),
   .done, "disabled Claude state is ignored")
eq(arbitrateAgentState(enabledProviders: [.claude],
                       sessions: [codexImplementation, claudeWorking], now: now),
   .working, "disabled Codex implementation wait is ignored")
eq(arbitrateAgentState(enabledProviders: [.codex], sessions: [doneStaleNoSentinel], now: now),
   .idle, "expired done arbitrates to idle")
eq(arbitrateAgentState(enabledProviders: [.claude], sessions: [codexSameId], now: now),
   .idle, "no enabled-provider session yields idle")
eq(arbitrateAgentState(enabledProviders: [.codex], sessions: [claudeError, codexDone], now: now),
   .done, "disabled provider error is ignored")

let providerSuiteName = "agent-provider-tests-\(UUID().uuidString)"
let providerDefaults = UserDefaults(suiteName: providerSuiteName)!
providerDefaults.removePersistentDomain(forName: providerSuiteName)
var providerConfiguration = AgentProviderConfiguration(userDefaults: providerDefaults)
eq(providerConfiguration.enabledProviders, Set(AgentProvider.allCases), "both providers enabled by default")
check(providerConfiguration.toggle(.claude), "one provider can be disabled")
check(!providerConfiguration.toggle(.codex), "last provider cannot be disabled")
providerConfiguration.persist(to: providerDefaults)
eq(AgentProviderConfiguration(userDefaults: providerDefaults).enabledProviders, [.codex],
   "provider selection persists")
providerDefaults.removePersistentDomain(forName: providerSuiteName)

// ---- final Codex state -> GeorgeLight state ----
eq(LightState(codexState: "thinking"), .working, "thinking maps to working")
eq(LightState(codexState: "tool"), .working, "tool maps to working")
eq(LightState(codexState: "permission"), .actionRequired, "permission maps to action required")
eq(LightState(codexState: "waitingApproval"), .actionRequired, "Claude approval maps to action required")
eq(LightState(codexState: "waitingInput"), .actionRequired, "input wait maps to action required")
eq(LightState(codexState: "waitingImplementation"), .actionRequired, "implementation wait maps to action required")
eq(LightState(codexState: "error"), .error, "error maps to error")
eq(LightState(codexState: "done"), .done, "done maps to done")
eq(LightState(codexState: "idle"), .idle, "idle maps to idle")
eq(LightState(codexState: nil), .idle, "no selected session maps to idle")
eq(LightState(codexState: "future-state"), .idle, "unknown states fail safe to idle")
runStateContractFixtures()

let defaultEffects = GeorgeLightEffectConfiguration.defaults
eq(defaultEffects.working.mode, .breath, "working uses built-in breath mode")
eq(defaultEffects.actionRequired.mode, .fastBlink, "action required uses built-in fast blink mode")
eq(defaultEffects.error.color, "#FF0000", "error uses firmware red")
eq(defaultEffects.error.mode, .fastBlink, "error uses fast blink mode")
eq(defaultEffects.error.durationSeconds, 10, "error is a short display effect")
eq(defaultEffects.done.mode, .solid, "done uses built-in solid mode")
eq(defaultEffects.effect(for: .idle), nil, "idle has no display effect")

eq(GeorgeLightMode.allCases.map { $0.rawValue }, [1, 2, 3, 4], "only firmware built-in mode IDs are exposed")
eq(GeorgeLightMode.allCases.map { $0.title }, ["Solid", "Blink", "Breath", "Fast Blink"],
   "built-in mode titles")
eq(GeorgeLightColors.firmwarePresets.map { $0.hex },
   ["#FF0000", "#00FF00", "#FFFF00", "#FFFFFF", "#000000", "#FF8000", "#0000FF", "#8000FF"],
   "firmware 1.0.1 preset palette")
eq(GeorgeLightColors.options(for: .working).first?.hex, "#4D8FFF", "working default color is first")
eq(GeorgeLightColors.options(for: .actionRequired).first?.hex, "#F2BA2E", "action-required default color is first")
eq(GeorgeLightColors.options(for: .error).first?.title, "Red", "error starts with firmware Red preset")
eq(GeorgeLightColors.options(for: .error).filter { $0.hex == "#FF0000" }.count, 1,
   "error red option is not duplicated")
eq(GeorgeLightColors.options(for: .done).first?.hex, "#4DC766", "done default color is first")

// ---- installer launch and private log helpers ----
let oddInstaller = "/Applications/Codex \" $(touch /tmp/nope) Status Bar.app/Contents/Resources/install.js"
let installConfig = installerLaunchConfiguration(
    installer: oddInstaller, providers: [.claude, .codex], environment: ["PATH": "/usr/bin"])
eq(installConfig.executablePath, "/usr/bin/env", "installer runs through env")
eq(installConfig.arguments, ["node", oddInstaller, "--providers=claude,codex"],
   "installer receives a stable provider argument")
check(!(installConfig.arguments.joined(separator: " ").contains("-lc")), "installer launch does not build a shell command")
eq(installConfig.environment["PATH"], "/opt/homebrew/bin:/usr/local/bin:/usr/bin", "installer PATH is augmented")
eq(shellQuoted(oddInstaller), "'/Applications/Codex \" $(touch /tmp/nope) Status Bar.app/Contents/Resources/install.js'", "manual fallback command is single-quoted")

let logDir = FileManager.default.temporaryDirectory.appendingPathComponent("csb-log-\(UUID().uuidString)")
let logPath = logDir.appendingPathComponent("app.log").path
appendPrivateLogLine("one\n", toPath: logPath)
appendPrivateLogLine("two\n", toPath: logPath)
eq((try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "", "one\ntwo\n", "private log appends lines")
if let attrs = try? FileManager.default.attributesOfItem(atPath: logPath),
   let perms = attrs[.posixPermissions] as? NSNumber {
    eq(perms.intValue & 0o777, 0o600, "private log file mode")
} else {
    check(false, "private log permissions readable")
}
let oldLogPath = logDir.appendingPathComponent("old-app.log").path
_ = FileManager.default.createFile(atPath: oldLogPath, contents: "old\n".data(using: .utf8), attributes: [.posixPermissions: 0o644])
appendPrivateLogLine("new\n", toPath: oldLogPath)
eq((try? String(contentsOfFile: oldLogPath, encoding: .utf8)) ?? "", "old\nnew\n", "existing private log appends lines")
if let oldAttrs = try? FileManager.default.attributesOfItem(atPath: oldLogPath),
   let oldPerms = oldAttrs[.posixPermissions] as? NSNumber {
    eq(oldPerms.intValue & 0o777, 0o600, "existing private log file mode")
} else {
    check(false, "existing private log permissions readable")
}
try? FileManager.default.removeItem(at: logDir)

// ---- menuOrder: pinned first (if alive), then by ts desc, capped at limit ----
let ordered = menuOrder(pinned: "a", sessions: [sA, sB, sC], now: now, limit: 5)
eq(ordered.count, 2, "stale excluded from menu")
eq(ordered.first?.sessionId, "a", "pinned first")
eq(ordered.last?.sessionId, "b", "non-pinned after, by recency")

let orderedNoPin = menuOrder(pinned: nil, sessions: [sA, sB], now: now, limit: 5)
eq(orderedNoPin.first?.sessionId, "b", "no pin: pure recency")

// cap at 5: pinned counts toward 5
var many: [SessionState] = []
for i in 0..<7 {
    many.append(SessionState(state: "thinking", label: "x", tool: "", project: "p\(i)", sessionId: "s\(i)", transcript: "", startedAt: 1, pausedTotal: 0, pauseStart: 0, ts: now - Double(i)))
}
let capped = menuOrder(pinned: "s3", sessions: many, now: now, limit: 5)
eq(capped.count, 5, "capped at 5")
eq(capped.first?.sessionId, "s3", "pinned stays first within cap")

if failures == 0 { print("ALL OK"); exit(0) } else { print("\(failures) FAILED"); exit(1) }
    }
}
