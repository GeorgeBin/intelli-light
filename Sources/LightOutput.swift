import Foundation

enum LightState: Equatable {
    case working
    case waitingApproval
    case done
    case idle

    init(codexState: String?) {
        switch codexState {
        case "thinking", "tool": self = .working
        case "permission": self = .waitingApproval
        case "done": self = .done
        default: self = .idle
        }
    }
}

protocol LightOutput: AnyObject {
    func setLightState(_ state: LightState)
}

protocol ConfigurableLightOutput: LightOutput {
    func setEnabled(_ enabled: Bool)
    func setBaseURL(_ baseURL: URL)
}

struct GeorgeLightEffect: Equatable {
    let color: String
    let modeID: Int
    let durationSeconds: Int
    let brightness: Int
}

enum GeorgeLightEffects {
    // GeorgeLight 1.0.1 built-in modes: 1 = solid, 3 = breath, 4 = fast blink.
    static let working = GeorgeLightEffect(
        color: "#4D8FFF", modeID: 3, durationSeconds: 300, brightness: 70)
    static let waitingApproval = GeorgeLightEffect(
        color: "#F2BA2E", modeID: 4, durationSeconds: 300, brightness: 90)
    static let done = GeorgeLightEffect(
        color: "#4DC766", modeID: 1, durationSeconds: 10, brightness: 80)

    static func effect(for state: LightState) -> GeorgeLightEffect? {
        switch state {
        case .working: return working
        case .waitingApproval: return waitingApproval
        case .done: return done
        case .idle: return nil
        }
    }
}

struct GeorgeLightConfiguration {
    static let enabledDefaultsKey = "georgeLightEnabled"
    static let baseURLDefaultsKey = "georgeLightBaseURL"
    static let defaultBaseURL = URL(string: "http://george-light-zero.local")!

    let enabled: Bool
    let baseURL: URL

    init(userDefaults: UserDefaults = .standard) {
        self.enabled = userDefaults.object(forKey: Self.enabledDefaultsKey) == nil
            ? true : userDefaults.bool(forKey: Self.enabledDefaultsKey)
        let configured = userDefaults.string(forKey: Self.baseURLDefaultsKey)
        self.baseURL = configured.flatMap(Self.validBaseURL) ?? Self.defaultBaseURL
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
