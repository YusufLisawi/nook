import Foundation

private final class RatesProtocol: URLProtocol {
    static let lock = NSLock()
    private static var requests = 0
    static var status = 200
    static var payload = Data()
    static var count: Int { lock.lock(); defer { lock.unlock() }; return requests }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.requests += 1; let status = Self.status, data = Self.payload; Self.lock.unlock()
        precondition(request.url?.absoluteString == "https://open.er-api.com/v6/latest/USD", "Only the fixed base endpoint is requested")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct CurrencyCacheTests {
    static func main() throws {
        func check(_ condition: @autoclosure () -> Bool, _ message: String) { precondition(condition(), message) }
        func until(_ ready: () -> Bool) {
            let end = Date().addingTimeInterval(2)
            while !ready(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.002)) }
            check(ready(), "Timed out waiting for mocked currency cache")
        }
        let now = Date(timeIntervalSince1970: 1792600000)
        let valid = Data(#"{"result":"success","base_code":"USD","time_last_update_unix":1792599940,"rates":{"USD":1,"MAD":10,"EUR":0.9}}"#.utf8)
        check(LauncherCurrencyStore.decode(valid, now: now)?.rates["MAD"] == 10, "Valid response decoded")
        for bad in ["{}", #"{"result":"error"}"#, #"{"result":"success","base_code":"USD","time_last_update_unix":1792599940,"rates":{"USD":0}}"#, #"{"result":"success","base_code":"USD","time_last_update_unix":1792599940,"rates":{"USD":1,"MAD":-10}}"#, #"{"result":"success","base_code":"EUR","time_last_update_unix":1792599940,"rates":{"USD":1}}"#] {
            check(LauncherCurrencyStore.decode(Data(bad.utf8), now: now) == nil, "Reject invalid API payload")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nook-rates-test-" + UUID().uuidString)
        let file = folder.appendingPathComponent("rates.json")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RatesProtocol.self]
        let session = URLSession(configuration: config)
        RatesProtocol.payload = valid
        let store = LauncherCurrencyStore(file: file, session: session)
        func snapshot(_ store: LauncherCurrencyStore, at date: Date = now) -> LauncherAnswerContext {
            var context = LauncherAnswerContext(now: date); store.fill(&context); return context
        }
        store.refreshIfNeeded(now: now) {}
        until { snapshot(store).currency != nil && !snapshot(store).currencyLoading }
        check(RatesProtocol.count == 1 && snapshot(store).currency?.rates["MAD"] == 10, "Fetch and cache first result")
        until { FileManager.default.fileExists(atPath: file.path) }
        for _ in 0..<10 { store.refreshIfNeeded(now: now.addingTimeInterval(3599)) {} }
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        check(RatesProtocol.count == 1, "At most one attempt an hour")
        let restored = LauncherCurrencyStore(file: file, session: session)
        restored.refreshIfNeeded(now: now.addingTimeInterval(120)) {}
        until { snapshot(restored).currency != nil }
        check(RatesProtocol.count == 1, "Disk cache survives restart without another request")
        RatesProtocol.lock.lock(); RatesProtocol.status = 503; RatesProtocol.lock.unlock()
        store.refreshIfNeeded(now: now.addingTimeInterval(3601)) {}
        until { snapshot(store).currencyError != nil }
        check(snapshot(store).currency?.rates["MAD"] == 10 && RatesProtocol.count == 2, "Offline failure keeps last good rates")
        store.refreshIfNeeded(now: now.addingTimeInterval(3700)) {}
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        check(RatesProtocol.count == 2, "Failures are also throttled")
        let failedFile = folder.appendingPathComponent("failed-first-use.json")
        let firstFailure = LauncherCurrencyStore(file: failedFile, session: session)
        firstFailure.refreshIfNeeded(now: now) {}
        until { snapshot(firstFailure).currencyError != nil }
        let beforeRestart = RatesProtocol.count
        let retryAfterRestart = LauncherCurrencyStore(file: failedFile, session: session)
        retryAfterRestart.refreshIfNeeded(now: now.addingTimeInterval(60)) {}
        until { !snapshot(retryAfterRestart).currencyLoading }
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        check(RatesProtocol.count == beforeRestart, "Failed first use remains throttled after restart even without any cached rates")
        // The test's data lives only under /tmp; leave it available to inspect along with other harness artifacts.
        print("Passed currency decode, cache persistence, hourly throttle, and offline fallback with URLProtocol; no network used")
    }
}
