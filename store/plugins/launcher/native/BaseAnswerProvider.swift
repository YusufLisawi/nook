import Foundation

@objc(NookBaseAnswerProvider)
final class BaseAnswerProvider: LauncherAnswerModule, LauncherAnswerProvider {
    let id = "base"
    func answer(for query: String, context: LauncherAnswerContext) -> LauncherAnswer? {
        guard context.hasTime, let match = AnswerText.match(#"(-?(?:0x[0-9a-f]+|0b[01]+|0o[0-7]+|[0-9]+))\s+(?:in|to)\s+(hex|hexadecimal|binary|bin|octal|oct|decimal|dec)"#, AnswerText.normalized(query)) else { return nil }
        let negative = match[0].hasPrefix("-"), text = negative ? String(match[0].dropFirst()) : match[0]
        let source = text.hasPrefix("0x") ? 16 : text.hasPrefix("0b") ? 2 : text.hasPrefix("0o") ? 8 : 10
        guard let value = UInt64(source == 10 ? text : String(text.dropFirst(2)), radix: source) else { return nil }
        let target: Int
        switch match[1] { case "hex", "hexadecimal": target = 16; case "binary", "bin": target = 2; case "octal", "oct": target = 8; default: target = 10 }
        let names = [16: "Hexadecimal", 2: "Binary", 8: "Octal", 10: "Decimal"]
        let prefix = target == 16 ? "0x" : target == 2 ? "0b" : target == 8 ? "0o" : ""
        let result = (negative && value != 0 ? "-" : "") + prefix + String(value, radix: target)
        return LauncherAnswer(expression: query, leftBadge: names[source]!, result: result, rightBadge: names[target]!, copyValue: result)
    }
}
