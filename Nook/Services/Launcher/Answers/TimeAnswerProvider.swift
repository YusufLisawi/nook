import Foundation

@objc(NookTimeAnswerProvider)
final class TimeAnswerProvider: LauncherAnswerModule, LauncherAnswerProvider {
    let id = "time"
    /// Countries with several zones use their capital/mainland zone. Explicit IANA IDs are always accepted.
    private static let zones: [String: String] = {
        var aliases: [String: String] = [:]
        for identifier in TimeZone.knownTimeZoneIdentifiers {
            aliases[identifier.lowercased()] = identifier
            let city = identifier.split(separator: "/").last.map(String.init)?.replacingOccurrences(of: "_", with: " ").lowercased() ?? ""
            if aliases[city] == nil { aliases[city] = identifier }
        }
        let countries = ["spain": "Europe/Madrid", "uk": "Europe/London", "united kingdom": "Europe/London", "england": "Europe/London",
            "france": "Europe/Paris", "germany": "Europe/Berlin", "italy": "Europe/Rome", "portugal": "Europe/Lisbon",
            "netherlands": "Europe/Amsterdam", "belgium": "Europe/Brussels", "switzerland": "Europe/Zurich", "austria": "Europe/Vienna",
            "ireland": "Europe/Dublin", "sweden": "Europe/Stockholm", "norway": "Europe/Oslo", "denmark": "Europe/Copenhagen",
            "finland": "Europe/Helsinki", "greece": "Europe/Athens", "poland": "Europe/Warsaw", "ukraine": "Europe/Kyiv",
            "turkey": "Europe/Istanbul", "russia": "Europe/Moscow", "romania": "Europe/Bucharest", "czechia": "Europe/Prague",
            "morocco": "Africa/Casablanca", "rabat": "Africa/Casablanca", "algeria": "Africa/Algiers", "tunisia": "Africa/Tunis",
            "egypt": "Africa/Cairo", "south africa": "Africa/Johannesburg", "nigeria": "Africa/Lagos", "kenya": "Africa/Nairobi",
            "ghana": "Africa/Accra", "senegal": "Africa/Dakar", "ethiopia": "Africa/Addis_Ababa",
            "japan": "Asia/Tokyo", "china": "Asia/Shanghai", "beijing": "Asia/Shanghai", "india": "Asia/Kolkata",
            "new delhi": "Asia/Kolkata", "mumbai": "Asia/Kolkata", "south korea": "Asia/Seoul", "korea": "Asia/Seoul",
            "thailand": "Asia/Bangkok", "vietnam": "Asia/Ho_Chi_Minh", "indonesia": "Asia/Jakarta", "malaysia": "Asia/Kuala_Lumpur",
            "philippines": "Asia/Manila", "taiwan": "Asia/Taipei", "pakistan": "Asia/Karachi", "bangladesh": "Asia/Dhaka",
            "uae": "Asia/Dubai", "united arab emirates": "Asia/Dubai", "saudi arabia": "Asia/Riyadh", "qatar": "Asia/Qatar",
            "israel": "Asia/Jerusalem", "iran": "Asia/Tehran", "nepal": "Asia/Kathmandu",
            "usa": "America/New_York", "us": "America/New_York", "united states": "America/New_York", "nyc": "America/New_York",
            "la": "America/Los_Angeles", "san francisco": "America/Los_Angeles", "washington": "America/New_York",
            "canada": "America/Toronto", "ottawa": "America/Toronto", "mexico": "America/Mexico_City",
            "brazil": "America/Sao_Paulo", "brasilia": "America/Sao_Paulo", "argentina": "America/Argentina/Buenos_Aires",
            "chile": "America/Santiago", "colombia": "America/Bogota", "peru": "America/Lima",
            "australia": "Australia/Sydney", "canberra": "Australia/Sydney", "new zealand": "Pacific/Auckland",
            "wellington": "Pacific/Auckland", "hawaii": "Pacific/Honolulu", "utc": "GMT", "gmt": "GMT"]
        aliases.merge(countries) { _, explicit in explicit }
        return aliases
    }()
    required init() { super.init(); _ = Self.zones }
    private func zone(_ text: String, context: LauncherAnswerContext) -> TimeZone? {
        if ["here", "local"].contains(text) { return context.timeZone }
        return Self.zones[text].flatMap(TimeZone.init(identifier:))
    }
    private func calendar(_ zone: TimeZone) -> Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = zone; return c }
    private func isoDate(_ string: String, calendar: Calendar) -> Date? {
        let pieces = string.split(separator: "-").compactMap { Int($0) }
        guard pieces.count == 3, (1...9999).contains(pieces[0]),
              let date = calendar.date(from: DateComponents(year: pieces[0], month: pieces[1], day: pieces[2])) else { return nil }
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard components.year == pieces[0], components.month == pieces[1], components.day == pieces[2] else { return nil }
        return date
    }
    private func timeAnswer(_ query: String, at date: Date, zone: TimeZone, badge: String, dateBadge: Bool = false, context: LauncherAnswerContext) -> LauncherAnswer {
        let formatter = DateFormatter(); formatter.locale = AnswerText.posix; formatter.timeZone = zone; formatter.dateFormat = "HH:mm"
        let time = formatter.string(from: date)
        formatter.dateFormat = "EEEE, MMMM d" + (calendar(zone).component(.year, from: date) == calendar(zone).component(.year, from: context.now) ? "" : ", yyyy")
        let day = formatter.string(from: date)
        let offset = zone.secondsFromGMT(for: date) / 60
        let gmt = offset == 0 ? "GMT" : "GMT\(offset < 0 ? "−" : "+")\(abs(offset) / 60)" + (offset % 60 == 0 ? "" : String(format: ":%02d", abs(offset) % 60))
        return LauncherAnswer(expression: query, leftBadge: badge, result: time, rightBadge: dateBadge ? day : gmt,
                              copyValue: time, copyWithUnits: "\(time) · \(day) · \(zone.identifier) (\(gmt))")
    }
    func answer(for query: String, context: LauncherAnswerContext) -> LauncherAnswer? {
        guard context.hasTime else { return nil }
        let text = AnswerText.normalized(query), cal = calendar(context.timeZone)
        if text == "now in unix" || text == "unix now" {
            let result = String(Int64(context.now.timeIntervalSince1970.rounded(.down)))
            return LauncherAnswer(expression: query, leftBadge: "Now", result: result, rightBadge: "Unix seconds", copyValue: result)
        }
        if let match = AnswerText.match(#"unix\s+(-?\d{1,12})"#, text), let seconds = Double(match[0]),
           seconds >= -62135596800, seconds < 253402300800 {
            let date = Date(timeIntervalSince1970: seconds)
            let f = DateFormatter(); f.locale = AnswerText.posix; f.timeZone = context.timeZone; f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            let value = f.string(from: date)
            return LauncherAnswer(expression: query, leftBadge: "Unix seconds", result: value, rightBadge: context.timeZone.identifier, copyValue: value)
        }
        if let match = AnswerText.match(#"time in (.+)"#, text), let zone = zone(match[0], context: context) {
            return timeAnswer(query, at: context.now, zone: zone, badge: match[0].capitalized, context: context)
        }
        if let match = AnswerText.match(#"days between (\d{4}-\d{2}-\d{2}) and (\d{4}-\d{2}-\d{2})"#, text),
           let start = isoDate(match[0], calendar: cal), let end = isoDate(match[1], calendar: cal),
           let count = cal.dateComponents([.day], from: start, to: end).day {
            return LauncherAnswer(expression: query, leftBadge: "Date difference", result: String(count), rightBadge: "Days", copyValue: String(count), copyWithUnits: "\(count) days")
        }
        if let match = AnswerText.match(#"days until (christmas|new year|\d{4}-\d{2}-\d{2})"#, text) {
            let target: Date?
            if match[0] == "christmas" || match[0] == "new year" {
                let year = cal.component(.year, from: context.now), month = match[0] == "christmas" ? 12 : 1, day = match[0] == "christmas" ? 25 : 1
                let thisYear = cal.date(from: DateComponents(year: year, month: month, day: day))!
                target = thisYear < cal.startOfDay(for: context.now) ? cal.date(byAdding: .year, value: 1, to: thisYear) : thisYear
            } else { target = isoDate(match[0], calendar: cal) }
            guard let target, let count = cal.dateComponents([.day], from: cal.startOfDay(for: context.now), to: target).day else { return nil }
            return LauncherAnswer(expression: query, leftBadge: "Countdown", result: String(count), rightBadge: "Days", copyValue: String(count), copyWithUnits: "\(count) days")
        }
        if let match = AnswerText.match(#"(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\s+(.+?)\s+(?:in|to)\s+(.+)"#, text),
           let hourValue = Int(match[0]), let source = zone(match[3], context: context), let target = zone(match[4], context: context) {
            let minute = Int(match[1]) ?? 0, period = match[2]
            guard minute < 60, period.isEmpty ? hourValue < 24 : (1...12).contains(hourValue) else { return nil }
            let hour = period.isEmpty ? hourValue : hourValue % 12 + (period == "pm" ? 12 : 0)
            let sourceCal = calendar(source)
            guard let date = sourceCal.date(bySettingHour: hour, minute: minute, second: 0, of: context.now, matchingPolicy: .strict, repeatedTimePolicy: .first),
                  sourceCal.isDate(date, inSameDayAs: context.now), sourceCal.component(.hour, from: date) == hour else { return nil }
            return timeAnswer(query, at: date, zone: target, badge: match[3].capitalized, dateBadge: true, context: context)
        }
        let relative = AnswerText.match(#"("# + AnswerText.quantity + #")\s+(seconds?|secs?|minutes?|mins?|hours?|hrs?|days?|weeks?) from now(?: in (.+))?"#, text)
            ?? AnswerText.match(#"now\s*\+\s*("# + AnswerText.quantity + #")\s*(seconds?|secs?|minutes?|mins?|hours?|hrs?|days?|weeks?)(?: in (.+))?"#, text)
            ?? AnswerText.match(#"in\s+("# + AnswerText.quantity + #")\s+(seconds?|secs?|minutes?|mins?|hours?|hrs?|days?|weeks?)(?: in (.+))?"#, text)
        if let match = relative, let amount = AnswerText.number(match[0]), abs(amount) <= 1e7,
           let zone = match[2].isEmpty ? context.timeZone : zone(match[2], context: context) {
            let unit = match[1]
            let seconds: Double
            if unit.hasPrefix("sec") { seconds = amount }
            else if unit.hasPrefix("min") { seconds = amount * 60 }
            else if unit.hasPrefix("h") { seconds = amount * 3600 }
            else {
                let days = amount * (unit.hasPrefix("week") ? 7 : 1)
                guard let date = calendar(zone).date(byAdding: .day, value: Int(days), to: context.now) else { return nil }
                seconds = date.timeIntervalSince(context.now) + (days - days.rounded(.towardZero)) * 86400
            }
            let date = context.now.addingTimeInterval(seconds)
            guard date.timeIntervalSince1970 >= -62135596800, date.timeIntervalSince1970 < 253402300800 else { return nil }
            return timeAnswer(query, at: date, zone: zone, badge: "Expression", dateBadge: true, context: context)
        }
        return nil
    }
}
