import Foundation

final class GeorgeLightHttpOutput: LightOutput {
    private static let displayPath = "api/v1/codex/display"
    private static let clearPath = "api/v1/codex/clear"
    private static let requestTimeout: TimeInterval = 3

    private let baseURL: URL
    private let session: URLSession
    private let queue = DispatchQueue(label: "io.github.kiwigaze.codexstatusbar.george-light-output")
    private var desiredState: LightState?
    private var requestInFlight = false

    init(baseURL: URL = GeorgeLightConfiguration().baseURL, session: URLSession? = nil) {
        self.baseURL = baseURL
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = Self.requestTimeout
            configuration.timeoutIntervalForResource = Self.requestTimeout
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            configuration.httpShouldUsePipelining = false
            self.session = URLSession(configuration: configuration)
        }
    }

    func setLightState(_ state: LightState) {
        queue.async { [weak self] in
            guard let self, self.desiredState != state else { return }
            self.desiredState = state
            self.startLatestRequestIfNeeded()
        }
    }

    private func startLatestRequestIfNeeded() {
        guard !requestInFlight, let state = desiredState,
              let request = makeRequest(for: state) else { return }
        requestInFlight = true
        session.dataTask(with: request) { [weak self] _, _, _ in
            guard let self else { return }
            self.queue.async {
                self.requestInFlight = false
                // At most one request is ever in flight. If state changed while it was
                // running, send only the newest value after the old request completes.
                if self.desiredState != state {
                    self.startLatestRequestIfNeeded()
                }
            }
        }.resume()
    }

    private func makeRequest(for state: LightState) -> URLRequest? {
        let path = state == .idle ? Self.clearPath : Self.displayPath
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData

        if let effect = GeorgeLightEffects.effect(for: state) {
            let payload: [String: Any] = [
                "color": effect.color,
                "mode_id": effect.modeID,
                "duration_sec": effect.durationSeconds,
                "brightness": effect.brightness,
            ]
            guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }
}
