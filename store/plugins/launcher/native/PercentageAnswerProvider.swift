import Foundation

@objc(NookPercentageAnswerProvider)
final class PercentageAnswerProvider: LauncherAnswerModule, LauncherAnswerProvider {
    let id = "percentage-change"
    func answer(for query: String, context: LauncherAnswerContext) -> LauncherAnswer? {
        guard context.hasTime, let match = AnswerText.match(#"from\s+("# + AnswerText.quantity + #")\s+to\s+("# + AnswerText.quantity + ")", AnswerText.normalized(query)),
              let from = AnswerText.number(match[0]), let to = AnswerText.number(match[1]), from != 0 else { return nil }
        let change = (to - from) / abs(from) * 100
        guard change.isFinite else { return nil }
        let result = (change > 0 ? "+" : "") + AnswerText.format(change, locale: context.locale) + "%"
        return LauncherAnswer(expression: query, leftBadge: "Percentage change", result: result,
                              rightBadge: change == 0 ? "No change" : change > 0 ? "Increase" : "Decrease", copyValue: AnswerText.copyNumber(change) + "%")
    }
}
