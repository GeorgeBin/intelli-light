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

    func succeed() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"ok\":true}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

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
        defaults.set("http://192.168.1.45", forKey: GeorgeLightConfiguration.baseURLDefaultsKey)
        eq(GeorgeLightConfiguration(userDefaults: defaults).baseURL.absoluteString,
           "http://192.168.1.45", "UserDefaults overrides mDNS base URL")
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
}
