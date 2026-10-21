import Foundation

struct LauncherCurrencySnapshot: Codable {
    var rates: [String: Double]
    var updatedAt: Date
}

@objc(NookCurrencyAnswerProvider)
final class CurrencyAnswerProvider: LauncherAnswerModule, LauncherAnswerProvider, LauncherAnswerRefining {
    let id = "currency"
    private static let aliases = ["$": "USD", "dollar": "USD", "dollars": "USD", "bucks": "USD", "buck": "USD",
        "€": "EUR", "euro": "EUR", "euros": "EUR", "£": "GBP", "pound": "GBP", "pounds": "GBP",
        "¥": "JPY", "yen": "JPY", "yuan": "CNY", "dirham": "MAD", "dirhams": "MAD", "dh": "MAD", "dhs": "MAD"]
    private static let codes = Set(Locale.commonISOCurrencyCodes.map { $0.uppercased() })
    private static let names = ["USD": "US Dollar", "EUR": "Euro", "GBP": "British Pound", "JPY": "Japanese Yen", "MAD": "Moroccan Dirham"]
    private let store = LauncherCurrencyStore()
    required init() { super.init(); _ = Self.codes }

    private func code(_ token: String) -> String? {
        if let alias = Self.aliases[token.lowercased()] { return alias }
        let code = token.uppercased(); return Self.codes.contains(code) ? code : nil
    }
    private func parse(_ query: String, target: String) -> (Double, String, String)? {
        let text = AnswerText.normalized(query)
        guard let match = AnswerText.match(#"(?:([$€£¥])\s*("# + AnswerText.quantity + #")|("# + AnswerText.quantity + #")\s*([a-z$€£¥]+))(?:\s+(?:to|in)\s+([a-z$€£¥]+))?"#, text),
              let amount = AnswerText.number(match[1].isEmpty ? match[2] : match[1]),
              let from = code(match[0].isEmpty ? match[3] : match[0]),
              let to = code(match[4].isEmpty ? target : match[4]) else { return nil }
        return (amount, from, to)
    }
    func answer(for query: String, context: LauncherAnswerContext) -> LauncherAnswer? {
        var context = context
        if context.currency == nil { store.fill(&context) }
        guard context.hasTime, let (amount, from, to) = parse(query, target: context.defaultCurrency) else { return nil }
        let name: (String) -> String = { Self.names[$0] ?? AnswerText.posix.localizedString(forCurrencyCode: $0) ?? $0 }
        let attribution = LauncherAnswer.Action(title: "Rates by ExchangeRate-API", value: .open(URL(string: "https://www.exchangerate-api.com")!))
        if from == to {
            return LauncherAnswer(expression: query, leftBadge: name(from), result: AnswerText.format(amount, locale: context.locale, digits: 2) + " " + to,
                                  rightBadge: name(to), copyValue: AnswerText.copyNumber(amount), copyWithUnits: AnswerText.copyNumber(amount) + " " + to)
        }
        guard let snapshot = context.currency, let source = snapshot.rates[from], let target = snapshot.rates[to], source > 0, target > 0 else {
            return LauncherAnswer(expression: query, leftBadge: name(from), result: context.currencyLoading ? "Loading rates…" : "Rates unavailable",
                                  rightBadge: name(to), note: context.currencyError ?? "Connect once to cache exchange rates", copyValue: "",
                                  secondaryActions: [attribution], isAvailable: false)
        }
        let result = amount / source * target
        guard result.isFinite else { return nil }
        let age = max(0, context.now.timeIntervalSince(snapshot.updatedAt))
        let elapsed: String
        if age < 60 { elapsed = "just now" }
        else if age < 3600 { let n = Int(age / 60); elapsed = "\(n) minute\(n == 1 ? "" : "s") ago" }
        else if age < 86400 { let n = Int(age / 3600); elapsed = "\(n) hour\(n == 1 ? "" : "s") ago" }
        else { let n = Int(age / 86400); elapsed = "\(n) day\(n == 1 ? "" : "s") ago" }
        let formatted = AnswerText.format(result, locale: context.locale, digits: 2)
        return LauncherAnswer(expression: query, leftBadge: name(from), result: formatted + " " + to, rightBadge: name(to),
                              note: "Updated " + elapsed + (context.currencyError == nil ? "" : " · Offline"),
                              copyValue: AnswerText.copyNumber(result), copyWithUnits: formatted + " " + to, secondaryActions: [attribution])
    }
    func refine(for query: String, context: LauncherAnswerContext, completion: @escaping () -> Void) {
        guard let (_, from, to) = parse(query, target: context.defaultCurrency), from != to else { return }
        store.refreshIfNeeded(now: context.now, completion: completion)
    }
}

/// Only this cache service performs I/O. Queries, amounts and target currencies never leave the Mac.
final class LauncherCurrencyStore: @unchecked Sendable {
    private struct Disk: Codable { var snapshot: LauncherCurrencySnapshot?; var attemptedAt: Date? }
    private let queue = DispatchQueue(label: "nook.answers.currency", qos: .utility)
    private let lock = NSLock()
    private var disk = Disk()
    private var loaded = false
    private var loading = false
    private var failure: String?
    private var waiters: [() -> Void] = []
    private let file: URL
    private var task: URLSessionDataTask?
    private let session: URLSession

    init(file: URL = PluginRuntime.data.appendingPathComponent("Launcher/answers-currency.json"), session: URLSession = .shared) {
        self.file = file; self.session = session
    }
    func fill(_ context: inout LauncherAnswerContext) {
        lock.lock(); defer { lock.unlock() }
        context.currency = disk.snapshot; context.currencyLoading = loading || !loaded; context.currencyError = failure
    }
    func refreshIfNeeded(now: Date, completion: @escaping () -> Void) {
        queue.async { [self] in
            if !loaded {
                let cached = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Disk.self, from: $0) }
                lock.lock()
                if let cached {
                    if let snapshot = cached.snapshot, snapshot.rates["USD"] == 1, snapshot.rates.count <= 300,
                       snapshot.rates.values.allSatisfy({ $0.isFinite && $0 > 0 }),
                       snapshot.updatedAt.timeIntervalSince1970 > 0, snapshot.updatedAt <= now.addingTimeInterval(300) {
                        disk.snapshot = snapshot
                    }
                    // Keep failed first-use attempts too, so restarting cannot bypass the hourly throttle.
                    if let attempt = cached.attemptedAt, attempt <= now { disk.attemptedAt = attempt }
                }
                loaded = true
                lock.unlock()
                completion()
            }
            // The utility queue owns attempts/waiters; the lock protects snapshots read by answer workers.
            if loading { waiters.append(completion); return }
            if let attempt = disk.attemptedAt, now.timeIntervalSince(attempt) < 3600 { return }
            lock.lock(); disk.attemptedAt = now; loading = true; failure = nil; lock.unlock()
            persist()
            waiters.append(completion)
            completion()
            var request = URLRequest(url: URL(string: "https://open.er-api.com/v6/latest/USD")!)
            request.timeoutInterval = 12; request.cachePolicy = .reloadIgnoringLocalCacheData
            task = session.dataTask(with: request) { [weak self] data, response, _ in
                guard let self else { return }
                self.queue.async {
                    var snapshot: LauncherCurrencySnapshot?
                    if let data, data.count <= 100_000, let http = response as? HTTPURLResponse, http.statusCode == 200 {
                        snapshot = Self.decode(data, now: now)
                    }
                    self.lock.lock()
                    if let snapshot { self.disk.snapshot = snapshot }
                    self.failure = snapshot == nil ? "Couldn't refresh rates · Try again in an hour" : nil
                    self.loading = false
                    self.lock.unlock()
                    self.persist()
                    let callbacks = self.waiters; self.waiters = []
                    callbacks.forEach { $0() }
                }
            }
            task?.resume()
        }
    }
    deinit { task?.cancel() }

    static func decode(_ data: Data, now: Date) -> LauncherCurrencySnapshot? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              json["result"] as? String == "success", json["base_code"] as? String == "USD",
              let rates = json["rates"] as? [String: Double], rates["USD"] == 1,
              rates.count <= 300, rates.values.allSatisfy({ $0.isFinite && $0 > 0 }),
              let timestamp = json["time_last_update_unix"] as? Double,
              timestamp > 0, timestamp <= now.timeIntervalSince1970 + 300 else { return nil }
        return LauncherCurrencySnapshot(rates: rates, updatedAt: Date(timeIntervalSince1970: timestamp))
    }
    private func persist() {
        guard let data = try? JSONEncoder().encode(disk) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
