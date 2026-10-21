import Foundation

/// Value-only presentation. Providers never know about SwiftUI, focus, or the launcher result list.
struct LauncherAnswer: Equatable {
    struct Action: Equatable {
        enum Value: Equatable { case copy(String), open(URL) }
        let title: String
        let value: Value
    }
    struct Swatch: Equatable { let red: Double; let green: Double; let blue: Double }

    var pluginID: String? = nil
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

struct LauncherAnswerContext { var now = Date(); var locale = Locale.current; var timeZone = TimeZone.current; var deadline = UInt64.max; var hasTime: Bool { DispatchTime.now().uptimeNanoseconds < deadline } }
protocol LauncherAnswerProvider { var id: String { get }; func answer(for query: String, context: LauncherAnswerContext) -> LauncherAnswer? }
protocol LauncherAnswerRefining { func refine(for query: String, context: LauncherAnswerContext, completion: @escaping () -> Void) }

extension LauncherAnswer {
    static func decode(_ row: [String: Any]) -> LauncherAnswer? {
        guard let result = row["result"] as? String, result.count <= 10000 else { return nil }
        var answer = LauncherAnswer(section: row["section"] as? String ?? "Plugin", expression: row["expression"] as? String ?? "", leftBadge: row["leftBadge"] as? String ?? "", result: result, rightBadge: row["rightBadge"] as? String ?? "", note: row["note"] as? String, copyValue: row["copyValue"] as? String ?? result, isAvailable: row["isAvailable"] as? Bool ?? true)
        answer.copyWithUnits = row["copyWithUnits"] as? String
        answer.secondaryActions = (row["secondaryActions"] as? [[String: Any]] ?? []).prefix(16).compactMap { item in
            guard let title = item["title"] as? String else { return nil }
            if let value = item["copy"] as? String { return Action(title: title, value: .copy(value)) }
            if let value = item["url"] as? String, let url = URL(string: value), ["https", "http"].contains(url.scheme ?? "") { return Action(title: title, value: .open(url)) }
            return nil
        }
        if let color = row["swatch"] as? [String: Double], let red = color["red"], let green = color["green"], let blue = color["blue"], [red, green, blue].allSatisfy({ $0.isFinite && (0...1).contains($0) }) { answer.swatch = Swatch(red: red, green: green, blue: blue) }
        return answer
    }
}
