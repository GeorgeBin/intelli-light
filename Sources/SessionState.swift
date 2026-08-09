import Foundation

enum AgentProvider: String, CaseIterable, Codable, Hashable {
    case codex
    case claude

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        }
    }
}

struct AgentProviderConfiguration {
    static let defaultsKey = "enabledAgentProviders"
    static let defaultProviders = Set(AgentProvider.allCases)

    private(set) var enabledProviders: Set<AgentProvider>

    init(userDefaults: UserDefaults = .standard) {
        let stored = userDefaults.array(forKey: Self.defaultsKey) as? [String]
        let parsed = Set((stored ?? []).compactMap(AgentProvider.init(rawValue:)))
        enabledProviders = stored == nil || parsed.isEmpty ? Self.defaultProviders : parsed
    }

    @discardableResult
    mutating func toggle(_ provider: AgentProvider) -> Bool {
        if enabledProviders.contains(provider) {
            guard enabledProviders.count > 1 else { return false }
            enabledProviders.remove(provider)
        } else {
            enabledProviders.insert(provider)
        }
        return true
    }

    func persist(to userDefaults: UserDefaults = .standard) {
        let values = enabledProviders.map(\.rawValue).sorted()
        userDefaults.set(values, forKey: Self.defaultsKey)
    }
}

enum AgentState: Int, Equatable, Comparable {
    case idle = 0
    case done = 1
    case working = 2
    case error = 3
    case waitingApproval = 4

    static func < (lhs: AgentState, rhs: AgentState) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var menuTitle: String {
        switch self {
        case .working: return "Working"
        case .waitingApproval: return "Waiting Approval"
        case .error: return "Error"
        case .done: return "Done"
        case .idle: return "Idle"
        }
    }
}

struct AgentSessionKey: Hashable, Codable {
    let provider: AgentProvider
    let sessionId: String

    var persistedValue: String { "\(provider.rawValue):\(sessionId)" }

    init(provider: AgentProvider, sessionId: String) {
        self.provider = provider
        self.sessionId = sessionId
    }

    init?(persistedValue: String) {
        guard let separator = persistedValue.firstIndex(of: ":"),
              let provider = AgentProvider(rawValue: String(persistedValue[..<separator])) else { return nil }
        self.provider = provider
        self.sessionId = String(persistedValue[persistedValue.index(after: separator)...])
    }
}

// Pure data + pure logic for the status-bar state model. Foundation-only so it can be
// unit-tested by compiling alongside Tests/logic_tests.swift WITHOUT main.swift (which
// would otherwise launch the GUI via `app.run()`).

struct SessionState {
    var state: String       // thinking | tool | permission | done | idle
    var label: String
    var tool: String
    var project: String
    var sessionId: String
    var transcript: String
    var startedAt: TimeInterval   // unix seconds the current turn began; 0 = no clock
    var pausedTotal: TimeInterval // seconds already spent awaiting permission this turn
    var pauseStart: TimeInterval  // unix seconds the current pause began; 0 = not paused
    var ts: TimeInterval          // unix seconds the writer last touched this file
    var ownerPid: Int = 0
    var ownerKind: String = "unknown"
    var provider: AgentProvider = .codex

    /// A session counts as alive while its writer has updated it within this window.
    /// Mirrors the 900s safety net in main.swift's evaluate().
    static let staleAfter: TimeInterval = 900
    static let unreliableOwnerDisplayAfter: TimeInterval = 60
    static let terminalVisibleFor: TimeInterval = 2
}

extension SessionState {
    init?(json: [String: Any]) {
        guard let state = json["state"] as? String else { return nil }
        self.state = state
        self.label = (json["label"] as? String) ?? ""
        self.tool = (json["tool"] as? String) ?? ""
        self.project = (json["project"] as? String) ?? ""
        self.sessionId = (json["sessionId"] as? String) ?? ""
        self.transcript = (json["transcript"] as? String) ?? ""
        self.startedAt = (json["startedAt"] as? NSNumber)?.doubleValue ?? 0
        self.pausedTotal = (json["pausedTotal"] as? NSNumber)?.doubleValue ?? 0
        self.pauseStart = (json["pauseStart"] as? NSNumber)?.doubleValue ?? 0
        self.ts = (json["ts"] as? NSNumber)?.doubleValue ?? 0
        self.ownerPid = (json["ownerPid"] as? NSNumber)?.intValue ?? 0
        self.ownerKind = (json["ownerKind"] as? String) ?? "unknown"
        self.provider = (json["provider"] as? String).flatMap(AgentProvider.init(rawValue:)) ?? .codex
    }

    var key: AgentSessionKey { AgentSessionKey(provider: provider, sessionId: sessionId) }

    var normalizedState: AgentState {
        switch state {
        case "thinking", "tool", "working": return .working
        case "permission", "waitingApproval": return .waitingApproval
        case "error": return .error
        case "done": return .done
        default: return .idle
        }
    }

    func isAlive(now: TimeInterval) -> Bool {
        now - ts <= SessionState.staleAfter
    }

    func hasReliableOwner() -> Bool {
        ownerKind == "session" && ownerPid > 0
    }

    func isDisplayEligible(now: TimeInterval, ownerAlive: Bool) -> Bool {
        guard isAlive(now: now) else { return false }
        switch normalizedState {
        case .working, .waitingApproval:
            if hasReliableOwner() { return ownerAlive }
            return now - ts <= SessionState.unreliableOwnerDisplayAfter
        default:
            return true
        }
    }

    func isRenderable(now: TimeInterval, terminalShownAt: TimeInterval?) -> Bool {
        guard normalizedState == .done || normalizedState == .error else { return true }
        return now - (terminalShownAt ?? ts) <= SessionState.terminalVisibleFor
    }

    func endedByOwnerExit(ownerAlive: Bool) -> Bool {
        guard hasReliableOwner() else { return false }
        switch normalizedState {
        case .working, .waitingApproval: return !ownerAlive
        default: return false
        }
    }
}

func pinnedSessionMatches(_ pinned: String?, _ session: SessionState) -> Bool {
    guard let pinned else { return false }
    if let key = AgentSessionKey(persistedValue: pinned) { return key == session.key }
    return session.provider == .codex && session.sessionId == pinned
}

private func terminalTimestamp(for session: SessionState, in values: [String: TimeInterval]) -> TimeInterval? {
    values[session.key.persistedValue] ?? (session.provider == .codex ? values[session.sessionId] : nil)
}

/// Net working time for the current turn, subtracting accumulated + in-progress pauses.
/// Pure. Returns 0 when there is no clock (startedAt == 0) or the inputs are non-sensical.
func elapsedSeconds(now: TimeInterval, startedAt: TimeInterval, pausedTotal: TimeInterval, pauseStart: TimeInterval) -> Int {
    guard startedAt > 0 else { return 0 }
    var elapsed = now - startedAt - pausedTotal
    if pauseStart > 0 { elapsed -= (now - pauseStart) }
    return max(0, Int(elapsed))
}

/// Decide which session to render in the single menu-bar slot.
/// Priority: pinned (if alive) → most-recently-updated alive → none.
///
/// Tradeoff (spec §8 "文档明示"): when two or more sessions are active and none is
/// pinned, the slot follows the most recently written session. Fast interleaved writes
/// therefore make the displayed session jump between ticks — an inherent cost of the
/// click-to-pin model; pinning is the escape hatch when stable focus is needed.
/// Pure.
func selectDisplay(pinned: String?, sessions: [SessionState], now: TimeInterval,
                   terminalShownAt: [String: TimeInterval] = [:]) -> SessionState? {
    let alive = sessions.filter {
        $0.isAlive(now: now) && $0.isRenderable(
            now: now, terminalShownAt: terminalTimestamp(for: $0, in: terminalShownAt))
    }
    if let match = alive.first(where: { pinnedSessionMatches(pinned, $0) }) {
        return match
    }
    return alive.max(by: { $0.ts < $1.ts })
}

/// Global state for provider-independent outputs such as GeorgeLight. The caller may
/// pre-filter owner liveness; this function owns provider filtering, staleness, the
/// Done/Error terminal visibility window, and cross-session priority.
func arbitrateAgentState(enabledProviders: Set<AgentProvider>, sessions: [SessionState],
                         now: TimeInterval, terminalShownAt: [String: TimeInterval] = [:]) -> AgentState {
    sessions.lazy
        .filter { enabledProviders.contains($0.provider) && $0.isAlive(now: now) }
        .filter { $0.isRenderable(
            now: now, terminalShownAt: terminalTimestamp(for: $0, in: terminalShownAt)) }
        .map(\.normalizedState)
        .max() ?? .idle
}

/// Build the ordered list of sessions for the dropdown menu.
/// Pinned (if alive) is always first and counts toward `limit`; remaining slots fill by
/// most-recent ts. Stale sessions are excluded. Pure.
func menuOrder(pinned: String?, sessions: [SessionState], now: TimeInterval, limit: Int) -> [SessionState] {
    var alive = sessions.filter { $0.isAlive(now: now) }
    var result: [SessionState] = []
    if let idx = alive.firstIndex(where: { pinnedSessionMatches(pinned, $0) }) {
        result.append(alive.remove(at: idx))
    }
    alive.sort { $0.ts > $1.ts }
    while result.count < limit, !alive.isEmpty {
        result.append(alive.removeFirst())
    }
    return result
}
