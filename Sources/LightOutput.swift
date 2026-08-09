import Foundation

enum LightState: Equatable {
    case working
    case actionRequired
    case error
    case done
    case idle

    init(codexState: String?) {
        switch codexState {
        case "thinking", "tool": self = .working
        case "permission", "waitingApproval", "waitingImplementation": self = .actionRequired
        case "error": self = .error
        case "done": self = .done
        default: self = .idle
        }
    }

    var settingsTitle: String {
        switch self {
        case .working: return "Working"
        case .actionRequired: return "Action Required"
        case .error: return "Error"
        case .done: return "Done"
        case .idle: return "Idle"
        }
    }
}

protocol LightOutput: AnyObject {
    func setLightState(_ state: LightState)
}

protocol ConfigurableLightOutput: LightOutput {
    func setEnabled(_ enabled: Bool)
    func setBaseURL(_ baseURL: URL)
    func setEffect(_ effect: GeorgeLightEffectSettings, for state: LightState)
}

enum GeorgeLightMode: Int, CaseIterable, Equatable {
    case solid = 1
    case blink = 2
    case breath = 3
    case fastBlink = 4

    var title: String {
        switch self {
        case .solid: return "Solid"
        case .blink: return "Blink"
        case .breath: return "Breath"
        case .fastBlink: return "Fast Blink"
        }
    }
}

struct GeorgeLightColorOption: Equatable {
    let title: String
    let hex: String
}

enum GeorgeLightColors {
    // Exact preset palette from GeorgeLight Zero 1.0.1 firmware/web/index.html.
    static let firmwarePresets: [GeorgeLightColorOption] = [
        GeorgeLightColorOption(title: "Red", hex: "#FF0000"),
        GeorgeLightColorOption(title: "Green", hex: "#00FF00"),
        GeorgeLightColorOption(title: "Yellow", hex: "#FFFF00"),
        GeorgeLightColorOption(title: "White", hex: "#FFFFFF"),
        GeorgeLightColorOption(title: "Black", hex: "#000000"),
        GeorgeLightColorOption(title: "Orange", hex: "#FF8000"),
        GeorgeLightColorOption(title: "Blue", hex: "#0000FF"),
        GeorgeLightColorOption(title: "Purple", hex: "#8000FF"),
    ]

    static func options(for state: LightState) -> [GeorgeLightColorOption] {
        guard let effect = GeorgeLightEffectConfiguration.defaults.effect(for: state) else { return [] }
        if firmwarePresets.contains(where: { $0.hex.caseInsensitiveCompare(effect.color) == .orderedSame }) {
            return firmwarePresets
        }
        return [GeorgeLightColorOption(title: "Default", hex: effect.color)] + firmwarePresets
    }
}

struct GeorgeLightEffectSettings: Equatable {
    var color: String
    var mode: GeorgeLightMode
    let durationSeconds: Int
    let brightness: Int
}

struct GeorgeLightEffectConfiguration: Equatable {
    var working: GeorgeLightEffectSettings
    var actionRequired: GeorgeLightEffectSettings
    var error: GeorgeLightEffectSettings
    var done: GeorgeLightEffectSettings

    static let defaults = GeorgeLightEffectConfiguration(
        working: GeorgeLightEffectSettings(
            color: "#4D8FFF", mode: .breath, durationSeconds: 300, brightness: 70),
        actionRequired: GeorgeLightEffectSettings(
            color: "#F2BA2E", mode: .fastBlink, durationSeconds: 300, brightness: 90),
        error: GeorgeLightEffectSettings(
            color: "#FF0000", mode: .fastBlink, durationSeconds: 10, brightness: 90),
        done: GeorgeLightEffectSettings(
            color: "#4DC766", mode: .solid, durationSeconds: 10, brightness: 80))

    func effect(for state: LightState) -> GeorgeLightEffectSettings? {
        switch state {
        case .working: return working
        case .actionRequired: return actionRequired
        case .error: return error
        case .done: return done
        case .idle: return nil
        }
    }

    mutating func setEffect(_ effect: GeorgeLightEffectSettings, for state: LightState) {
        switch state {
        case .working: working = effect
        case .actionRequired: actionRequired = effect
        case .error: error = effect
        case .done: done = effect
        case .idle: break
        }
    }
}

struct GeorgeLightConfiguration {
    static let enabledDefaultsKey = "georgeLightEnabled"
    static let baseURLDefaultsKey = "georgeLightBaseURL"
    static let defaultBaseURL = URL(string: "http://george-light-zero.local")!

    var enabled: Bool
    var baseURL: URL
    var effects: GeorgeLightEffectConfiguration

    init(userDefaults: UserDefaults = .standard) {
        enabled = userDefaults.object(forKey: Self.enabledDefaultsKey) == nil
            ? true : userDefaults.bool(forKey: Self.enabledDefaultsKey)
        let configured = userDefaults.string(forKey: Self.baseURLDefaultsKey)
        baseURL = configured.flatMap(Self.validBaseURL) ?? Self.defaultBaseURL
        effects = .defaults
        for state in [LightState.working, .actionRequired, .error, .done] {
            guard var effect = effects.effect(for: state) else { continue }
            if let storedColor = userDefaults.string(forKey: Self.colorDefaultsKey(for: state)),
               let allowed = GeorgeLightColors.options(for: state).first(where: {
                   $0.hex.caseInsensitiveCompare(storedColor) == .orderedSame
               }) {
                effect.color = allowed.hex
            }
            if userDefaults.object(forKey: Self.modeDefaultsKey(for: state)) != nil,
               let mode = GeorgeLightMode(rawValue: userDefaults.integer(
                   forKey: Self.modeDefaultsKey(for: state))) {
                effect.mode = mode
            }
            effects.setEffect(effect, for: state)
        }
    }

    func persistEnabled(to userDefaults: UserDefaults = .standard) {
        userDefaults.set(enabled, forKey: Self.enabledDefaultsKey)
    }

    func persistBaseURL(to userDefaults: UserDefaults = .standard) {
        userDefaults.set(baseURL.absoluteString, forKey: Self.baseURLDefaultsKey)
    }

    func persistEffect(for state: LightState, to userDefaults: UserDefaults = .standard) {
        guard let effect = effects.effect(for: state), state != .idle else { return }
        userDefaults.set(effect.color, forKey: Self.colorDefaultsKey(for: state))
        userDefaults.set(effect.mode.rawValue, forKey: Self.modeDefaultsKey(for: state))
    }

    static func colorDefaultsKey(for state: LightState) -> String {
        "georgeLight\(defaultsStateName(state))Color"
    }

    static func modeDefaultsKey(for state: LightState) -> String {
        "georgeLight\(defaultsStateName(state))ModeID"
    }

    private static func defaultsStateName(_ state: LightState) -> String {
        switch state {
        case .working: return "Working"
        // Keep the legacy key so upgrades preserve the user's Waiting Approval effect.
        case .actionRequired: return "WaitingApproval"
        case .error: return "Error"
        case .done: return "Done"
        case .idle: return "Idle"
        }
    }

    static func validBaseURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "http",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/" else { return nil }
        components.scheme = "http"
        components.path = ""
        return components.url
    }
}
