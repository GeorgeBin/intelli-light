import Foundation

var failures = 0
func check(_ cond: Bool, _ msg: String, file: String = #file, line: Int = #line) {
    if !cond { print("FAIL \(file):\(line) — \(msg)"); failures += 1 }
}
func eq<T: Equatable>(_ a: T, _ b: T, _ msg: String) { check(a == b, "\(a) != \(b) — \(msg)") }

final class MockURLProtocol: URLProtocol {
    static let lock = NSLock()
    static var handler: ((MockURLProtocol, URLRequest) -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let current = Self.handler
        Self.lock.unlock()
        current?(self, request)
    }

    override func stopLoading() {}

    func respond(statusCode: Int) {
        let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"ok\":true}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    func succeed() { respond(statusCode: 200) }

    func fail() {
        client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
    }
}

func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: configuration)
}

func setHandler(_ handler: @escaping (MockURLProtocol, URLRequest) -> Void) {
    MockURLProtocol.lock.lock()
    MockURLProtocol.handler = handler
    MockURLProtocol.lock.unlock()
}

func payload(_ request: URLRequest) -> [String: Any] {
    let body: Data?
    if let direct = request.httpBody {
        body = direct
    } else if let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        body = data
    } else {
        body = nil
    }
    guard let body,
          let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return [:] }
    return object
}

func wait(_ semaphore: DispatchSemaphore, _ message: String) {
    check(semaphore.wait(timeout: .now() + 2) == .success, message)
}

@main
struct LightOutputTests {
    static func main() {
        testBaseURLConfiguration()
        testDisplayPayloadAndDedupe()
        testLatestStateWaitsForOlderRequest()
        testFailureDoesNotBlockLaterClear()
        testWorkingLeaseRefreshes()
        testErrorPayloadDoesNotLeaseRefresh()
        testNetworkFailureRetries()
        testHTTP409Retries()
        testClearFailureRetries()
        testStateChangeInvalidatesPendingRetry()
        testIdleCancelsWorkingLease()
        testDisabledOutputRetainsLatestState()
        testDisableClearsOnceWithoutRetryOrLease()
        testDisableCancelsPendingRetry()
        testBaseURLChangeUsesNewAddressImmediately()
        testConfiguredEffectPayload()
        testActiveEffectChangeInvalidatesRetry()
        testInactiveEffectWaitsForMatchingState()

        if failures == 0 { print("ALL OK"); exit(0) }
        print("\(failures) FAILED"); exit(1)
    }

    static func testBaseURLConfiguration() {
        eq(GeorgeLightConfiguration.validBaseURL(" http://lamp.local/ ")?.absoluteString,
           "http://lamp.local", "valid HTTP base URL is normalized")
        eq(GeorgeLightConfiguration.validBaseURL("https://lamp.local"), nil, "HTTPS is not part of firmware 1.0.1")
        eq(GeorgeLightConfiguration.validBaseURL("http://lamp.local/api"), nil, "base URL cannot contain a path")

        let suite = "light-output-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        check(GeorgeLightConfiguration(userDefaults: defaults).enabled,
              "GeorgeLight defaults to enabled")
        defaults.set(false, forKey: GeorgeLightConfiguration.enabledDefaultsKey)
        check(!GeorgeLightConfiguration(userDefaults: defaults).enabled,
              "disabled setting is restored")
        defaults.set(true, forKey: GeorgeLightConfiguration.enabledDefaultsKey)
        check(GeorgeLightConfiguration(userDefaults: defaults).enabled,
              "enabled setting is restored")
        defaults.set("#00ff00", forKey: GeorgeLightConfiguration.colorDefaultsKey(for: .working))
        defaults.set(GeorgeLightMode.blink.rawValue,
                     forKey: GeorgeLightConfiguration.modeDefaultsKey(for: .working))
        defaults.set("#123456", forKey: GeorgeLightConfiguration.colorDefaultsKey(for: .waitingApproval))
        defaults.set(99, forKey: GeorgeLightConfiguration.modeDefaultsKey(for: .waitingApproval))
        defaults.set("http://192.168.1.45", forKey: GeorgeLightConfiguration.baseURLDefaultsKey)
        var restored = GeorgeLightConfiguration(userDefaults: defaults)
        eq(restored.baseURL.absoluteString,
           "http://192.168.1.45", "UserDefaults overrides mDNS base URL")
        eq(restored.effects.working.color, "#00FF00", "preset color restores and normalizes")
        eq(restored.effects.working.mode, .blink, "built-in mode restores")
        eq(restored.effects.working.brightness, 70, "working brightness remains fixed")
        eq(restored.effects.working.durationSeconds, 300, "working duration remains fixed")
        eq(restored.effects.waitingApproval.color, "#F2BA2E", "invalid color falls back")
        eq(restored.effects.waitingApproval.mode, .fastBlink, "invalid mode falls back")
        eq(restored.effects.error.color, "#FF0000", "error defaults to firmware red")
        eq(restored.effects.error.mode, .fastBlink, "error defaults to fast blink")

        var error = restored.effects.error
        error.color = "#8000FF"
        error.mode = .breath
        restored.effects.setEffect(error, for: .error)
        restored.persistEffect(for: .error, to: defaults)

        var done = restored.effects.done
        done.color = "#8000FF"
        done.mode = .breath
        restored.effects.setEffect(done, for: .done)
        restored.persistEffect(for: .done, to: defaults)
        let roundTrip = GeorgeLightConfiguration(userDefaults: defaults)
        eq(roundTrip.effects.done.color, "#8000FF", "effect color persists")
        eq(roundTrip.effects.done.mode, .breath, "effect mode persists")
        eq(roundTrip.effects.error.color, "#8000FF", "error color persists")
        eq(roundTrip.effects.error.mode, .breath, "error mode persists")
        defaults.set("not a URL", forKey: GeorgeLightConfiguration.baseURLDefaultsKey)
        eq(GeorgeLightConfiguration(userDefaults: defaults).baseURL,
           GeorgeLightConfiguration.defaultBaseURL, "invalid override falls back to default")
        defaults.removePersistentDomain(forName: suite)
    }

    static func testDisplayPayloadAndDedupe() {
        let received = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var requests: [URLRequest] = []
        setHandler { proto, request in
            lock.lock(); requests.append(request); lock.unlock()
            proto.succeed()
            received.signal()
        }
        let output = GeorgeLightHttpOutput(baseURL: URL(string: "http://lamp.local")!, session: makeSession())
        output.setLightState(.working)
        wait(received, "working request was not sent")
        output.setLightState(.working)
        Thread.sleep(forTimeInterval: 0.15)

        lock.lock(); let captured = requests; lock.unlock()
        eq(captured.count, 1, "identical LightState is sent only once")
        guard let request = captured.first else { return }
        eq(request.httpMethod, "POST", "display method")
        eq(request.url?.path, "/api/v1/codex/display", "display path")
        eq(request.value(forHTTPHeaderField: "Content-Type"), "application/json", "display content type")
        let json = payload(request)
        eq(Set(json.keys), Set(["color", "mode_id", "duration_sec", "brightness"]), "strict display fields")
        eq(json["color"] as? String, "#4D8FFF", "working color")
        eq((json["mode_id"] as? NSNumber)?.intValue, 3, "working mode")
        eq((json["duration_sec"] as? NSNumber)?.intValue, 300, "working duration")
        eq((json["brightness"] as? NSNumber)?.intValue, 70, "working brightness")
    }

    static func testLatestStateWaitsForOlderRequest() {
        let firstStarted = DispatchSemaphore(value: 0)
        let finalSent = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var count = 0
        var held: MockURLProtocol?
        var finalRequest: URLRequest?
        setHandler { proto, request in
            lock.lock()
            count += 1
            let index = count
            if index == 1 { held = proto } else { finalRequest = request }
            lock.unlock()
            if index == 1 {
                firstStarted.signal()
            } else {
                proto.succeed()
                finalSent.signal()
            }
        }

        let output = GeorgeLightHttpOutput(baseURL: URL(string: "http://lamp.local")!, session: makeSession())
        output.setLightState(.working)
        wait(firstStarted, "first request did not start")
        output.setLightState(.waitingApproval)
        output.setLightState(.done)
        Thread.sleep(forTimeInterval: 0.15)
        lock.lock(); let beforeCompletion = count; let first = held; lock.unlock()
        eq(beforeCompletion, 1, "new states do not create concurrent requests")
        first?.succeed()
        wait(finalSent, "latest state was not sent after old request completed")

        lock.lock(); let capturedFinal = finalRequest; let total = count; lock.unlock()
        eq(total, 2, "intermediate pending states are coalesced")
        if let capturedFinal {
            eq(payload(capturedFinal)["color"] as? String, "#4DC766", "newest done state wins")
        } else {
            check(false, "final request was not captured")
        }
    }

    static func testFailureDoesNotBlockLaterClear() {
        let failed = DispatchSemaphore(value: 0)
        let cleared = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var requests: [URLRequest] = []
        setHandler { proto, request in
            lock.lock(); requests.append(request); let index = requests.count; lock.unlock()
            if index == 1 {
                proto.fail()
                failed.signal()
            } else {
                proto.succeed()
                cleared.signal()
            }
        }

        let output = GeorgeLightHttpOutput(baseURL: URL(string: "http://lamp.local")!, session: makeSession())
        output.setLightState(.waitingApproval)
        wait(failed, "failed request did not complete")
        output.setLightState(.idle)
        wait(cleared, "network failure blocked later clear")

        lock.lock(); let clear = requests.last; lock.unlock()
        eq(clear?.httpMethod, "POST", "clear method")
        eq(clear?.url?.path, "/api/v1/codex/clear", "clear path")
        eq(clear?.httpBody, nil, "clear sends no guessed JSON fields")
    }

    static func testWorkingLeaseRefreshes() {
        let initial = DispatchSemaphore(value: 0)
        let refreshed = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var requests: [URLRequest] = []
        setHandler { proto, request in
            lock.lock(); requests.append(request); let count = requests.count; lock.unlock()
            proto.succeed()
            if count == 1 { initial.signal() }
            if count == 2 { refreshed.signal() }
        }

        let output = GeorgeLightHttpOutput(
            baseURL: URL(string: "http://lamp.local")!, session: makeSession(),
            leaseRefreshInterval: 0.05, retryDelays: [0.02])
        output.setLightState(.working)
        wait(initial, "initial working lease was not sent")
        wait(refreshed, "working lease was not refreshed")

        lock.lock(); let captured = Array(requests.prefix(2)); lock.unlock()
        eq(captured.count, 2, "working sends a lease refresh")
        check(captured.allSatisfy { $0.url?.path == "/api/v1/codex/display" },
              "lease refresh uses display endpoint")
        check(captured.allSatisfy { payload($0)["color"] as? String == "#4D8FFF" },
              "lease refresh preserves working state")
    }

    static func testErrorPayloadDoesNotLeaseRefresh() {
        let sent = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var requests: [URLRequest] = []
        setHandler { proto, request in
            lock.lock(); requests.append(request); lock.unlock()
            proto.succeed()
            sent.signal()
        }

        let output = GeorgeLightHttpOutput(
            baseURL: URL(string: "http://lamp.local")!, session: makeSession(),
            leaseRefreshInterval: 0.05, retryDelays: [0.02])
        output.setLightState(.error)
        wait(sent, "error request was not sent")
        Thread.sleep(forTimeInterval: 0.15)

        lock.lock(); let captured = requests; lock.unlock()
        eq(captured.count, 1, "error terminal state has no lease refresh")
        guard let request = captured.first else { return }
        let json = payload(request)
        eq(json["color"] as? String, "#FF0000", "error payload uses red")
        eq((json["mode_id"] as? NSNumber)?.intValue, 4, "error payload uses fast blink")
        eq((json["duration_sec"] as? NSNumber)?.intValue, 10, "error payload is short")
        eq((json["brightness"] as? NSNumber)?.intValue, 90, "error brightness")
    }

    static func testNetworkFailureRetries() {
        let retried = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var count = 0
        setHandler { proto, _ in
            lock.lock(); count += 1; let current = count; lock.unlock()
            if current == 1 { proto.fail() }
            else { proto.succeed(); retried.signal() }
        }

        let output = GeorgeLightHttpOutput(
            baseURL: URL(string: "http://lamp.local")!, session: makeSession(),
            leaseRefreshInterval: 10, retryDelays: [0.02])
        output.setLightState(.working)
        wait(retried, "network failure was not retried")
        lock.lock(); let total = count; lock.unlock()
        eq(total, 2, "network failure retries once before success")
    }

    static func testHTTP409Retries() {
        let retried = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var count = 0
        setHandler { proto, _ in
            lock.lock(); count += 1; let current = count; lock.unlock()
            if current == 1 { proto.respond(statusCode: 409) }
            else { proto.succeed(); retried.signal() }
        }

        let output = GeorgeLightHttpOutput(
            baseURL: URL(string: "http://lamp.local")!, session: makeSession(),
            leaseRefreshInterval: 10, retryDelays: [0.02])
        output.setLightState(.waitingApproval)
        wait(retried, "HTTP 409 was not retried")
        lock.lock(); let total = count; lock.unlock()
        eq(total, 2, "non-2xx response retries before success")
    }

    static func testClearFailureRetries() {
        let retried = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var requests: [URLRequest] = []
        setHandler { proto, request in
            lock.lock(); requests.append(request); let count = requests.count; lock.unlock()
            if count == 1 { proto.respond(statusCode: 500) }
            else { proto.succeed(); retried.signal() }
        }

        let output = GeorgeLightHttpOutput(
            baseURL: URL(string: "http://lamp.local")!, session: makeSession(),
            leaseRefreshInterval: 10, retryDelays: [0.02])
        output.setLightState(.idle)
        wait(retried, "failed clear was not retried")

        lock.lock(); let captured = requests; lock.unlock()
        eq(captured.count, 2, "clear retries after HTTP 500")
        check(captured.allSatisfy { $0.url?.path == "/api/v1/codex/clear" },
              "clear retry stays on clear endpoint")
    }

    static func testStateChangeInvalidatesPendingRetry() {
        let firstFailed = DispatchSemaphore(value: 0)
        let latestSent = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var requests: [URLRequest] = []
        setHandler { proto, request in
            lock.lock(); requests.append(request); let count = requests.count; lock.unlock()
            if count == 1 {
                proto.fail()
                firstFailed.signal()
            } else {
                proto.succeed()
                latestSent.signal()
            }
        }

        let output = GeorgeLightHttpOutput(
            baseURL: URL(string: "http://lamp.local")!, session: makeSession(),
            leaseRefreshInterval: 10, retryDelays: [0.2])
        output.setLightState(.working)
        wait(firstFailed, "initial working request did not fail")
        Thread.sleep(forTimeInterval: 0.05)
        output.setLightState(.waitingApproval)
        wait(latestSent, "latest state was not sent during retry wait")
        Thread.sleep(forTimeInterval: 0.25)

        lock.lock(); let captured = requests; lock.unlock()
        eq(captured.count, 2, "stale working retry is cancelled")
        if captured.count == 2 {
            eq(payload(captured[1])["color"] as? String, "#F2BA2E",
               "only latest waiting approval state is delivered")
        }
    }

    static func testIdleCancelsWorkingLease() {
        let workingSent = DispatchSemaphore(value: 0)
        let clearSent = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var requests: [URLRequest] = []
        setHandler { proto, request in
            lock.lock(); requests.append(request); let count = requests.count; lock.unlock()
            proto.succeed()
            if count == 1 { workingSent.signal() }
            if count == 2 { clearSent.signal() }
        }

        let output = GeorgeLightHttpOutput(
            baseURL: URL(string: "http://lamp.local")!, session: makeSession(),
            leaseRefreshInterval: 0.2, retryDelays: [0.02])
        output.setLightState(.working)
        wait(workingSent, "working request was not sent")
        Thread.sleep(forTimeInterval: 0.05)
        output.setLightState(.idle)
        wait(clearSent, "idle clear was not sent")
        Thread.sleep(forTimeInterval: 0.25)

        lock.lock(); let captured = requests; lock.unlock()
        eq(captured.count, 2, "idle prevents old working lease refresh")
        eq(captured.last?.url?.path, "/api/v1/codex/clear", "idle remains the latest request")
    }

    static func testDisabledOutputRetainsLatestState() {
        let enabledRequest = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var requests: [URLRequest] = []
        setHandler { proto, request in
            lock.lock(); requests.append(request); lock.unlock()
            proto.succeed()
            enabledRequest.signal()
        }

        let output = GeorgeLightHttpOutput(
            baseURL: URL(string: "http://lamp.local")!, enabled: false,
            session: makeSession(), leaseRefreshInterval: 10, retryDelays: [0.02])
        output.setLightState(.working)
        output.setLightState(.waitingApproval)
        Thread.sleep(forTimeInterval: 0.1)
        lock.lock(); let disabledCount = requests.count; lock.unlock()
        eq(disabledCount, 0, "disabled output sends no state requests")

        output.setEnabled(true)
        wait(enabledRequest, "re-enabled output did not immediately sync")
        lock.lock(); let captured = requests; lock.unlock()
        eq(captured.count, 1, "re-enable sends one latest state")
        if let request = captured.first {
            eq(payload(request)["color"] as? String, "#F2BA2E",
               "re-enable sends latest waiting approval state")
        }
    }

    static func testDisableClearsOnceWithoutRetryOrLease() {
        let workingSent = DispatchSemaphore(value: 0)
        let clearFailed = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var requests: [URLRequest] = []
        setHandler { proto, request in
            lock.lock(); requests.append(request); let count = requests.count; lock.unlock()
            if count == 1 {
                proto.succeed()
                workingSent.signal()
            } else {
                proto.respond(statusCode: 500)
                clearFailed.signal()
            }
        }

        let output = GeorgeLightHttpOutput(
            baseURL: URL(string: "http://lamp.local")!, enabled: true,
            session: makeSession(), leaseRefreshInterval: 0.2, retryDelays: [0.05])
        output.setLightState(.working)
        wait(workingSent, "working request was not sent before disable")
        output.setEnabled(false)
        wait(clearFailed, "disable did not attempt clear")
        Thread.sleep(forTimeInterval: 0.3)

        lock.lock(); let captured = requests; lock.unlock()
        eq(captured.count, 2, "disable clear failure is not retried and lease stays cancelled")
        eq(captured.last?.url?.path, "/api/v1/codex/clear", "disable sends clear once")
    }

    static func testDisableCancelsPendingRetry() {
        let workingFailed = DispatchSemaphore(value: 0)
        let clearSent = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var requests: [URLRequest] = []
        setHandler { proto, request in
            lock.lock(); requests.append(request); let count = requests.count; lock.unlock()
            if count == 1 {
                proto.fail()
                workingFailed.signal()
            } else {
                proto.succeed()
                clearSent.signal()
            }
        }

        let output = GeorgeLightHttpOutput(
            baseURL: URL(string: "http://lamp.local")!, enabled: true,
            session: makeSession(), leaseRefreshInterval: 10, retryDelays: [0.2])
        output.setLightState(.working)
        wait(workingFailed, "working request did not fail")
        Thread.sleep(forTimeInterval: 0.05)
        output.setEnabled(false)
        wait(clearSent, "disable did not clear during retry wait")
        Thread.sleep(forTimeInterval: 0.25)

        lock.lock(); let captured = requests; lock.unlock()
        eq(captured.count, 2, "disabled output does not run stale retry")
        eq(captured.last?.url?.path, "/api/v1/codex/clear", "clear is final request after disable")
    }

    static func testBaseURLChangeUsesNewAddressImmediately() {
        let oldFailed = DispatchSemaphore(value: 0)
        let newSent = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var requests: [URLRequest] = []
        setHandler { proto, request in
            lock.lock(); requests.append(request); let count = requests.count; lock.unlock()
            if count == 1 {
                proto.fail()
                oldFailed.signal()
            } else {
                proto.succeed()
                newSent.signal()
            }
        }

        let output = GeorgeLightHttpOutput(
            baseURL: URL(string: "http://old-lamp.local")!, enabled: true,
            session: makeSession(), leaseRefreshInterval: 10, retryDelays: [0.2])
        output.setLightState(.working)
        wait(oldFailed, "old address request did not fail")
        Thread.sleep(forTimeInterval: 0.05)
        output.setBaseURL(URL(string: "http://new-lamp.local")!)
        wait(newSent, "address change did not immediately sync current state")
        Thread.sleep(forTimeInterval: 0.25)

        lock.lock(); let captured = requests; lock.unlock()
        eq(captured.count, 2, "old-address retry is cancelled")
        eq(captured.first?.url?.host, "old-lamp.local", "first request uses old address")
        eq(captured.last?.url?.host, "new-lamp.local", "next request uses new address")
    }

    static func testConfiguredEffectPayload() {
        let sent = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var request: URLRequest?
        setHandler { proto, captured in
            lock.lock(); request = captured; lock.unlock()
            proto.succeed()
            sent.signal()
        }

        var effects = GeorgeLightEffectConfiguration.defaults
        var approval = effects.waitingApproval
        approval.color = "#8000FF"
        approval.mode = .solid
        effects.setEffect(approval, for: .waitingApproval)
        let output = GeorgeLightHttpOutput(
            baseURL: URL(string: "http://lamp.local")!, enabled: true, effects: effects,
            session: makeSession(), leaseRefreshInterval: 10, retryDelays: [0.02])
        output.setLightState(.waitingApproval)
        wait(sent, "configured effect was not sent")

        lock.lock(); let captured = request; lock.unlock()
        if let captured {
            let json = payload(captured)
            eq(json["color"] as? String, "#8000FF", "configured color reaches payload")
            eq((json["mode_id"] as? NSNumber)?.intValue, 1, "configured mode reaches payload")
            eq((json["brightness"] as? NSNumber)?.intValue, 90, "fixed brightness is preserved")
            eq((json["duration_sec"] as? NSNumber)?.intValue, 300, "fixed duration is preserved")
        } else {
            check(false, "configured request was not captured")
        }
    }

    static func testActiveEffectChangeInvalidatesRetry() {
        let initialFailed = DispatchSemaphore(value: 0)
        let updatedSent = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var requests: [URLRequest] = []
        setHandler { proto, request in
            lock.lock(); requests.append(request); let count = requests.count; lock.unlock()
            if count == 1 {
                proto.fail()
                initialFailed.signal()
            } else {
                proto.succeed()
                updatedSent.signal()
            }
        }

        let output = GeorgeLightHttpOutput(
            baseURL: URL(string: "http://lamp.local")!, session: makeSession(),
            leaseRefreshInterval: 10, retryDelays: [0.2])
        output.setLightState(.working)
        wait(initialFailed, "initial effect did not fail")
        Thread.sleep(forTimeInterval: 0.05)
        var updated = GeorgeLightEffectConfiguration.defaults.working
        updated.color = "#FF8000"
        updated.mode = .blink
        output.setEffect(updated, for: .working)
        wait(updatedSent, "active effect change was not sent immediately")
        Thread.sleep(forTimeInterval: 0.25)

        lock.lock(); let captured = requests; lock.unlock()
        eq(captured.count, 2, "active effect change cancels stale retry")
        if captured.count == 2 {
            let json = payload(captured[1])
            eq(json["color"] as? String, "#FF8000", "updated active color wins")
            eq((json["mode_id"] as? NSNumber)?.intValue, 2, "updated active mode wins")
        }
    }

    static func testInactiveEffectWaitsForMatchingState() {
        let workingSent = DispatchSemaphore(value: 0)
        let doneSent = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var requests: [URLRequest] = []
        setHandler { proto, request in
            lock.lock(); requests.append(request); let count = requests.count; lock.unlock()
            proto.succeed()
            if count == 1 { workingSent.signal() }
            if count == 2 { doneSent.signal() }
        }

        let output = GeorgeLightHttpOutput(
            baseURL: URL(string: "http://lamp.local")!, session: makeSession(),
            leaseRefreshInterval: 10, retryDelays: [0.02])
        output.setLightState(.working)
        wait(workingSent, "working state was not sent")
        var updatedDone = GeorgeLightEffectConfiguration.defaults.done
        updatedDone.color = "#0000FF"
        updatedDone.mode = .fastBlink
        output.setEffect(updatedDone, for: .done)
        Thread.sleep(forTimeInterval: 0.1)
        lock.lock(); let beforeDone = requests.count; lock.unlock()
        eq(beforeDone, 1, "inactive effect does not overwrite current lamp state")

        output.setLightState(.done)
        wait(doneSent, "updated done effect was not used")
        lock.lock(); let captured = requests; lock.unlock()
        if captured.count == 2 {
            let json = payload(captured[1])
            eq(json["color"] as? String, "#0000FF", "inactive color applies on matching state")
            eq((json["mode_id"] as? NSNumber)?.intValue, 4, "inactive mode applies on matching state")
        }
    }
}
