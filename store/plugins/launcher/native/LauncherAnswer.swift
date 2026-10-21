import Foundation

/// Value-only presentation. Providers never know about SwiftUI, focus, or the launcher result list.
struct LauncherAnswer: Equatable {
    struct Action: Equatable {
        enum Value: Equatable { case copy(String), open(URL) }
        let title: String
        let value: Value
    }
    struct Swatch: Equatable { let red: Double; let green: Double; let blue: Double }

    var section = "Calculator"
    let expression: String
    let leftBadge: String
    let result: String
    let rightBadge: String
    var note: String? = nil
    let copyValue: String
    var copyWithUnits: String? = nil
    var swatch: Swatch? = nil
    var secondaryActions: [Action] = []
    /// Loading/error answers still explain the recognized expression, but cannot copy a fictitious result.
    var isAvailable = true

    var actions: [Action] {
        (isAvailable ? [Action(title: "Copy result", value: .copy(copyValue)),
                       Action(title: "Copy expression", value: .copy(expression)),
                       Action(title: "Copy with units", value: .copy(copyWithUnits ?? copyValue))] : [Action(title: "Copy expression", value: .copy(expression))]) + secondaryActions
    }
}

struct LauncherAnswerContext {
    var now = Date()
    var locale = Locale.current
    var timeZone = TimeZone.current
    /// A cooperative deadline; the registry also independently bounds how long it waits.
    var deadline = UInt64.max
    var currency: LauncherCurrencySnapshot? = nil
    var currencyLoading = false
    var currencyError: String? = nil
    var hasTime: Bool { DispatchTime.now().uptimeNanoseconds < deadline }
    var defaultCurrency: String { locale.currency?.identifier ?? "USD" }
    var usesMetric: Bool { locale.measurementSystem == .metric }
}

protocol LauncherAnswerProvider {
    var id: String { get }
    func answer(for query: String, context: LauncherAnswerContext) -> LauncherAnswer?
}

protocol LauncherAnswerRefining {
    /// Work is optional, asynchronous, and outside the answer budget. Completion invalidates only this search.
    func refine(for query: String, context: LauncherAnswerContext, completion: @escaping () -> Void)
}

/// Subclass + conform in one new file. Objective-C class discovery installs modules without a central switch.
class LauncherAnswerModule: NSObject {
    required override init() { super.init() }
}

enum AnswerText {
    static let posix = Locale(identifier: "en_US_POSIX")
    static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "′", with: "'")
            .replacingOccurrences(of: "″", with: "\"")
    }
    static func match(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: "\\A(?:" + pattern + ")\\z", options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.range.length == (text as NSString).length else { return nil }
        return (1..<match.numberOfRanges).map { i in
            Range(match.range(at: i), in: text).map { String(text[$0]) } ?? ""
        }
    }
    static let quantity = #"[+-]?(?:\d+(?:[.,]\d+)*|[.,]\d+)(?:[eE][+-]?\d+)?"#
    /// Both decimal separators; mixed separators use the final one as the decimal mark.
    static func number(_ text: String) -> Double? {
        var s = text
        if s.contains(","), s.contains(".") {
            if s.lastIndex(of: ",")! > s.lastIndex(of: ".")! { s = s.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".") }
            else { s = s.replacingOccurrences(of: ",", with: "") }
        } else { s = s.replacingOccurrences(of: ",", with: ".") }
        guard let value = Double(s), value.isFinite else { return nil }
        return value
    }
    static func format(_ value: Double, locale: Locale, digits: Int = 10) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale; formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = digits; formatter.usesGroupingSeparator = true
        if digits != 2 { formatter.maximumSignificantDigits = 13; formatter.usesSignificantDigits = true }
        let normalized: Double = value == 0 ? 0.0 : value
        return formatter.string(from: NSNumber(value: normalized)) ?? String(value)
    }
    static func copyNumber(_ value: Double) -> String {
        let normalized: Double = value == 0 ? 0.0 : value
        return String(format: "%.13g", locale: posix, normalized)
    }
}
