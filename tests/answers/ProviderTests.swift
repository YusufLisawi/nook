import Foundation

@main
struct ProviderTests {
    static func main() {
        setbuf(stdout, nil)
        var checks = 0, failures: [String] = []
        func check(_ ok: @autoclosure () -> Bool, _ message: String) { checks += 1; if !ok() { failures.append(message); print("FAIL: " + message) } }
        var context = LauncherAnswerContext(now: Date(timeIntervalSince1970: 1792600000), locale: Locale(identifier: "en_MA"), timeZone: TimeZone(identifier: "Europe/Madrid")!)
        let math = MathAnswerProvider(), units = UnitsAnswerProvider(), currency = CurrencyAnswerProvider(), time = TimeAnswerProvider()
        let color = ColorAnswerProvider(), base = BaseAnswerProvider(), percent = PercentageAnswerProvider()
        let mathCases: [(String, Double)] = [
            ("200 + 12", 212), ("5 plus 3 times 2", 11), ("20% of 150", 30), ("150 + 20%", 180), ("150 - 20%", 120),
            ("(2 + 3) * 4", 20), ("2^3^2", 512), ("-2^2", -4), ("2^-2", 0.25), ("10 ÷ 4", 2.5), ("4 × 2 − 1", 7),
            ("1,5 + 2.5", 4), ("1.234,5 + 1", 1235.5), ("1,234.5 + 1", 1235.5), (".5 + ,25", 0.75),
            ("sqrt(81)", 9), ("sin(pi / 2)", 1), ("cos(0)", 1), ("tan(0)", 0), ("log(100)", 2), ("ln(e)", 1),
            ("abs(-7)", 7), ("round(2.6)", 3), ("floor(-2.1)", -3), ("ceil(2.1)", 3), ("pi", .pi), ("π * 2", .pi * 2), ("e", M_E),
            ("1e3 + 2", 1002), ("1e-3 * 2", 0.002), ("50%", 0.5), ("100 + 10% + 10%", 121), ("10 divided by 2", 5), ("2 to the power of 3", 8)]
        for (query, expected) in mathCases {
            let value = LauncherMath.evaluate(query)
            check(value.map { abs($0 - expected) < max(1, abs(expected)) * 1e-10 } ?? false, "Math \(query): \(String(describing: value)) != \(expected)")
        }
        for query in ["arc", "notes", "rewrite", "", "123", "1/0", "0/0", "sqrt(-1)", "log(0)", "2^^3", "sin", "foo(2)", "2+", "((3)", "2 3", "2pi", "1..2+3", "1e999+1", "2**3", "pi()", "2%3", "@sum(1)", "FUNCTION(1)", String(repeating: "(", count: 100) + "1" + String(repeating: ")", count: 100)] {
            check(LauncherMath.evaluate(query) == nil, "Math rejects \(query.prefix(50))")
        }
        check(math.answer(for: "200 + 12", context: context)?.rightBadge == "Two Hundred Twelve", "English number words")
        let unitCases: [(String, Double)] = [
            ("10 km in miles", 6.21371192237), ("5'11\" in cm", 180.34), ("5′11″ in cm", 180.34), ("100f to c", 37.7777777778),
            ("32 f to c", 0), ("0 c to f", 32), ("273.15 k to c", 0), ("3 cups to ml", 709.7647095), ("1.5 GB in MB", 1500),
            ("1 GiB in MB", 1073.741824), ("1 GB in GiB", 0.931322574615), ("8 bits to B", 1), ("10 miles", 16.09344),
            ("2 kg to lb", 4.4092452437), ("1 lb in g", 453.59237), ("1 oz to g", 28.349523125), ("2 l to ml", 2000),
            ("60 mph in km/h", 96.56064), ("10 m/s to km/h", 36), ("1 acre in m2", 4046.8564224), ("1 ha to m²", 10000),
            ("1 ft2 in cm2", 929.0304), ("90 min in h", 1.5), ("2 days in hours", 48), ("1 week to day", 7),
            ("1 kwh in kj", 3600), ("1 kcal to j", 4184), ("1 bar to pa", 100000), ("1 atm to kpa", 101.325),
            ("180 deg to rad", .pi), ("1 turn to deg", 360), ("1,5 km to m", 1500), ("1 imperial gallon to l", 4.54609)]
        for (query, expected) in unitCases {
            let answer = units.answer(for: query, context: context), value = answer.flatMap { Double($0.copyValue) }
            check(value.map { abs($0 - expected) < max(1, abs(expected)) * 1e-9 } ?? false, "Units \(query): \(String(describing: answer))")
        }
        for query in ["arc", "notes", "rewrite", "10", "10 elephants", "1 kg to km", "-300 c to f", "5'12\" in cm", "1 ml to l to cups", "100f garbage", "1e999 m to km", "1 km in"] {
            check(units.answer(for: query, context: context) == nil, "Units reject \(query)")
        }
        context.currency = .init(rates: ["USD": 1, "MAD": 10, "EUR": 0.9, "GBP": 0.8, "JPY": 150], updatedAt: context.now.addingTimeInterval(-60))
        let currencyCases: [(String, Double)] = [("1000$", 10000), ("€20", 20 / 0.9 * 10), ("100 eur to mad", 100 / 0.9 * 10), ("50 usd in gbp", 40),
            ("£20 in usd", 25), ("¥150 to usd", 1), ("20 dirham to usd", 2), ("20 dh in usd", 2), ("2 bucks in eur", 1.8), ("100 MAD", 100), ("-10$", -100), ("$-10", -100)]
        for (query, expected) in currencyCases {
            let answer = currency.answer(for: query, context: context), value = answer.flatMap { Double($0.copyValue) }
            check(value.map { abs($0 - expected) < max(1, abs(expected)) * 1e-9 } ?? false, "Currency \(query): \(String(describing: answer))")
        }
        for query in ["arc", "notes", "rewrite", "$", "100", "100 xyz to mad", "20 usd to wat", "usd 20", "20 usd trash"] {
            check(currency.answer(for: query, context: context) == nil, "Currency rejects \(query)")
        }
        check(currency.answer(for: "1000$", context: context)?.note == "Updated 1 minute ago", "Currency timestamp")
        check(currency.answer(for: "1000$", context: context)?.actions.last?.title == "Rates by ExchangeRate-API", "Visible attribution action")
        var offline = context; offline.currencyError = "Offline"
        check(currency.answer(for: "1000$", context: offline)?.note?.contains("Offline") == true, "Stale cached rates remain available offline")
        offline.currency = nil
        check(currency.answer(for: "1000$", context: offline)?.isAvailable == false, "No invented fallback rate")
        offline.currencyLoading = true
        check(currency.answer(for: "1000$", context: offline)?.result == "Loading rates…", "First-use loading state")
        let fixed = Date(timeIntervalSince1970: 1792600000)
        context.now = fixed
        let timeCases = ["time in spain", "time in tokyo", "time in America/New_York", "time in morocco", "time in san francisco", "time in nepal", "time in utc", "5pm london in new york", "17:30 london to tokyo", "12am tokyo in london", "2 hours from now in spain", "now + 90 min", "in 3 days", "in 2 weeks in tokyo", "days until christmas", "days until 2026-12-25", "days between 2026-01-01 and 2026-03-15", "unix 1792600000", "now in unix"]
        for query in timeCases { check(time.answer(for: query, context: context) != nil, "Time accepts \(query)") }
        check(time.answer(for: "days between 2026-01-01 and 2026-03-15", context: context)?.copyValue == "73", "Day difference")
        check(time.answer(for: "days between 2024-02-28 and 2024-03-01", context: context)?.copyValue == "2", "Leap year day difference")
        check(time.answer(for: "days between 2026-03-15 and 2026-01-01", context: context)?.copyValue == "-73", "Reversed difference")
        check(time.answer(for: "now in unix", context: context)?.copyValue == "1792600000", "Unix seconds")
        check(time.answer(for: "time in spain", context: context)?.rightBadge == "GMT+2", "Madrid summer offset")
        check(time.answer(for: "time in nepal", context: context)?.rightBadge == "GMT+5:45", "Fractional offset")
        context.now = Date(timeIntervalSince1970: 1767225600)
        check(time.answer(for: "time in spain", context: context)?.rightBadge == "GMT+1", "Madrid winter offset")
        check(time.answer(for: "5pm london in new york", context: context)?.copyValue == "12:00", "Zone conversion uses source local day")
        context.now = fixed
        for query in ["arc", "notes", "rewrite", "time in nowhere", "now", "in days", "25pm london in tokyo", "5:99pm london in tokyo", "0pm london in tokyo", "days until 2026-02-30", "days between 2026-13-01 and 2026-01-02", "unix 999999999999", "unix nan", "now + 1e999 min"] {
            check(time.answer(for: query, context: context) == nil, "Time rejects \(query)")
        }
        for (query, expected) in [("#fff", "rgb(255, 255, 255)"), ("#ff0000 to hsl", "hsl(0, 100%, 50%)"), ("rgb(255, 0, 128) in hex", "#FF0080"), ("hsl(120,100%,50%)", "#00FF00"), ("hsl(-120, 100%, 50%)", "#0000FF"), ("#000 in hsl", "hsl(0, 0%, 0%)")] {
            check(color.answer(for: query, context: context)?.copyValue == expected, "Color \(query)")
        }
        for query in ["notes", "fff", "#gggggg", "#12345", "rgb(256,0,0)", "hsl(0,101%,0%)", "rgb(1,2)", "#fff to notes"] { check(color.answer(for: query, context: context) == nil, "Color rejects \(query)") }
        for (query, expected) in [("255 in hex", "0xff"), ("0xff in binary", "0b11111111"), ("0b111 in decimal", "7"), ("-255 in hex", "-0xff"), ("0o77 to dec", "63"), ("18446744073709551615 in hex", "0xffffffffffffffff"), ("0 in binary", "0b0")] {
            check(base.answer(for: query, context: context)?.copyValue == expected, "Base \(query)")
        }
        for query in ["arc", "notes", "rewrite", "0xff", "0b102 in hex", "18446744073709551616 in hex", "1.5 in hex", "255 in notes"] { check(base.answer(for: query, context: context) == nil, "Base rejects \(query)") }
        for (query, expected) in [("from 80 to 100", "25%"), ("from 100 to 80", "-20%"), ("from 80 to 80", "0%"), ("from -100 to -80", "20%"), ("from 1,5 to 3", "100%")] {
            check(percent.answer(for: query, context: context)?.copyValue == expected, "Percent \(query)")
        }
        for query in ["arc", "notes", "rewrite", "from 0 to 100", "from notes to 100", "80 to 100"] { check(percent.answer(for: query, context: context) == nil, "Percent rejects \(query)") }
        // Deterministic fuzz: arbitrary UTF-8, malformed numbers, punctuation, and deep nesting never throw or trap.
        var seed: UInt64 = 0x4E4F4F4B
        let alphabet = Array("0123456789.,+-*/^%() sqrtincoaleπ🦆é\n\t[]{}'\"!@#$=\\")
        for _ in 0..<12000 {
            seed = seed &* 6364136223846793005 &+ 1
            let length = Int(seed % 150)
            var text = ""
            for _ in 0..<length { seed = seed &* 6364136223846793005 &+ 1; text.append(alphabet[Int(seed % UInt64(alphabet.count))]) }
            _ = LauncherMath.evaluate(text); checks += 1
        }
        // Benchmarks use warmed providers, like the registry's module initialization at launcher startup.
        let providers: [(LauncherAnswerProvider, String)] = [(math, "200 + 12"), (units, "5'11\" in cm"), (currency, "100 eur to mad"), (time, "5pm london in new york"), (color, "#ff0000 in hsl"), (base, "255 in hex"), (percent, "from 80 to 100")]
        for (provider, query) in providers {
            _ = provider.answer(for: query, context: context)
            var samples: [Double] = []
            for _ in 0..<200 {
                let start = DispatchTime.now().uptimeNanoseconds
                _ = provider.answer(for: query, context: context)
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            }
            samples.sort(); let p95 = samples[190]
            print("\(provider.id): median \(samples[100]) ms, p95 \(p95) ms, max \(samples[199]) ms")
            check(p95 < 2, "\(provider.id) p95 stays below 2 ms")
        }
        let registry = LauncherAnswers()
        check(Set(["math", "units", "currency", "time", "color", "base", "percentage-change", "zz-discovery-test"]).isSubset(of: Set(registry.providerIDs)), "Providers discover themselves from new files: \(registry.providerIDs)")
        var found: LauncherAnswer?
        registry.request("200 + 12", context: context) { found = $0 }
        let deadline = Date().addingTimeInterval(1)
        while found == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
        check(found?.copyValue == "212", "Background registry delivers a confident answer")
        check(found?.actions.map(\.title).prefix(3) == ["Copy result", "Copy expression", "Copy with units"], "Common action contract")
        print("\(checks) provider checks; \(failures.count) failures")
        if !failures.isEmpty { exit(1) }
    }
}
