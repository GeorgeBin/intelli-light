import Foundation

final class GeorgeLightHttpOutput: LightOutput {
    private static let displayPath = "api/v1/codex/display"
    private static let clearPath = "api/v1/codex/clear"
    private static let requestTimeout: TimeInterval = 3
    private static let defaultLeaseRefreshInterval: TimeInterval = 240
    private static let defaultRetryDelays: [TimeInterval] = [2, 5, 10, 30, 60]

    private let baseURL: URL
    private let session: URLSession
    private let leaseRefreshInterval: TimeInterval
    private let retryDelays: [TimeInterval]
    private let queue = DispatchQueue(label: "io.github.kiwigaze.codexstatusbar.george-light-output")
    private var desiredState: LightState?
    private var desiredGeneration: UInt64 = 0
    private var requestInFlight = false
    private var retryAttempt = 0
    private var scheduledWork: DispatchWorkItem?

    init(baseURL: URL = GeorgeLightConfiguration().baseURL,
         session: URLSession? = nil,
         leaseRefreshInterval: TimeInterval = GeorgeLightHttpOutput.defaultLeaseRefreshInterval,
         retryDelays: [TimeInterval] = GeorgeLightHttpOutput.defaultRetryDelays) {
        self.baseURL = baseURL
        self.leaseRefreshInterval = max(0, leaseRefreshInterval)
        self.retryDelays = retryDelays.isEmpty ? Self.defaultRetryDelays : retryDelays.map { max(0, $0) }
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
            self.desiredGeneration &+= 1
            self.retryAttempt = 0
            self.scheduledWork?.cancel()
            self.scheduledWork = nil
            self.startLatestRequestIfNeeded()
        }
    }

    private func startLatestRequestIfNeeded() {
        guard !requestInFlight, let state = desiredState,
              let request = makeRequest(for: state) else { return }
        let generation = desiredGeneration
        requestInFlight = true
        session.dataTask(with: request) { [weak self] _, response, error in
            guard let self else { return }
            self.queue.async {
                self.requestInFlight = false
                guard self.desiredGeneration == generation, self.desiredState == state else {
                    // State changed while this request was running. Ignore its result
                    // and deliver only the newest desired state.
                    self.startLatestRequestIfNeeded()
                    return
                }

                let status = (response as? HTTPURLResponse)?.statusCode
                let succeeded = error == nil && status.map { (200..<300).contains($0) } == true
                if succeeded {
                    self.retryAttempt = 0
                    if self.needsLeaseRefresh(state) {
                        self.schedule(state: state, generation: generation,
                                      after: self.leaseRefreshInterval)
                    }
                } else {
                    let index = min(self.retryAttempt, self.retryDelays.count - 1)
                    let delay = self.retryDelays[index]
                    self.retryAttempt = min(self.retryAttempt + 1, self.retryDelays.count)
                    self.schedule(state: state, generation: generation, after: delay)
                }
            }
        }.resume()
    }

    private func schedule(state: LightState, generation: UInt64, after delay: TimeInterval) {
        scheduledWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.desiredGeneration == generation,
                  self.desiredState == state else { return }
            self.scheduledWork = nil
            self.startLatestRequestIfNeeded()
        }
        scheduledWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func needsLeaseRefresh(_ state: LightState) -> Bool {
        state == .working || state == .waitingApproval
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
