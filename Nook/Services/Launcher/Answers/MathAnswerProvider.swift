import Foundation

@objc(NookMathAnswerProvider)
final class MathAnswerProvider: LauncherAnswerModule, LauncherAnswerProvider {
    let id = "math"
    private let words: NumberFormatter = {
        let f = NumberFormatter(); f.locale = Locale(identifier: "en_US"); f.numberStyle = .spellOut
        _ = f.string(from: 212) // Warm ICU once, away from the keystroke path.
        return f
    }()
    func answer(for query: String, context: LauncherAnswerContext) -> LauncherAnswer? {
        guard context.hasTime, let value = LauncherMath.evaluate(query, deadline: context.deadline), context.hasTime else { return nil }
        let description = abs(value) < 1e15 ? words.string(from: NSNumber(value: value))?.capitalized : nil
        let normalized = AnswerText.normalized(query)
        let badge = normalized.contains("+") || normalized.contains("plus") ? "Sum" : "Expression"
        return LauncherAnswer(expression: query, leftBadge: badge,
                              result: AnswerText.format(value, locale: context.locale), rightBadge: description ?? "Number",
                              copyValue: AnswerText.copyNumber(value))
    }
}

/// Bounded recursive-descent grammar. No eval, NSExpression, shell, or implicit identifier lookup.
enum LauncherMath {
    private enum Token: Equatable { case number(Double), name(String), op(Character), end }
    private struct Value { var number: Double; var percent = false }
    private enum Invalid: Error { case syntax }

    static func evaluate(_ input: String, deadline: UInt64 = .max) -> Double? {
        guard input.utf8.count <= 512, !input.isEmpty else { return nil }
        var text = AnswerText.normalized(input).replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
        let replacements = [("multiplied by", "*"), ("divided by", "/"), ("to the power of", "^"),
                            ("plus", "+"), ("minus", "-"), ("times", "*"), ("of", "*")]
        for (word, symbol) in replacements {
            text = text.replacingOccurrences(of: "\\b" + word + "\\b", with: symbol, options: .regularExpression)
        }
        do {
            let tokens = try lex(text)
            // A bare number is usually an app/file search, not a request for an answer.
            guard tokens.count > 2 || tokens.contains(where: { if case .name = $0 { return true }; return false }) else { return nil }
            var parser = Parser(tokens: tokens, deadline: deadline)
            let result = try parser.sum(depth: 0)
            guard parser.current == .end, result.number.isFinite, DispatchTime.now().uptimeNanoseconds < deadline else { return nil }
            return result.number
        } catch { return nil }
    }

    private static func lex(_ text: String) throws -> [Token] {
        let chars = Array(text)
        var i = 0, tokens: [Token] = []
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if "+-*/^%()".contains(c) { tokens.append(.op(c)); i += 1; continue }
            if c.isASCII && c.isNumber || c == "." || c == "," {
                let start = i
                while i < chars.count, chars[i].isASCII && chars[i].isNumber || chars[i] == "." || chars[i] == "," { i += 1 }
                // Scientific notation is consumed only with a following exponent digit.
                if i < chars.count, chars[i] == "e" {
                    var end = i + 1
                    if end < chars.count, chars[end] == "+" || chars[end] == "-" { end += 1 }
                    let digits = end
                    while end < chars.count, chars[end].isASCII && chars[end].isNumber { end += 1 }
                    if end > digits { i = end }
                }
                guard let value = AnswerText.number(String(chars[start..<i])) else { throw Invalid.syntax }
                tokens.append(.number(value)); continue
            }
            if c.isASCII && c.isLetter || c == "π" {
                let start = i
                while i < chars.count, chars[i].isASCII && chars[i].isLetter || chars[i] == "π" { i += 1 }
                tokens.append(.name(String(chars[start..<i]))); continue
            }
            throw Invalid.syntax
        }
        guard tokens.count <= 256 else { throw Invalid.syntax }
        return tokens + [.end]
    }

    private struct Parser {
        let tokens: [Token]
        let deadline: UInt64
        var index = 0
        var current: Token { tokens[index] }
        mutating func take(_ c: Character) -> Bool { if current == .op(c) { index += 1; return true }; return false }
        func check(_ depth: Int) throws {
            guard depth < 48, DispatchTime.now().uptimeNanoseconds < deadline else { throw Invalid.syntax }
        }
        mutating func sum(depth: Int) throws -> Value {
            try check(depth)
            var value = try product(depth: depth + 1)
            while current == .op("+") || current == .op("-") {
                let add = take("+"); if !add { index += 1 }
                let rhs = try product(depth: depth + 1)
                let amount = rhs.percent ? value.number * rhs.number : rhs.number
                value = Value(number: value.number + (add ? amount : -amount))
                guard value.number.isFinite else { throw Invalid.syntax }
            }
            return value
        }
        mutating func product(depth: Int) throws -> Value {
            var value = try unary(depth: depth + 1)
            while current == .op("*") || current == .op("/") {
                let multiply = take("*"); if !multiply { index += 1 }
                let rhs = try unary(depth: depth + 1)
                guard multiply || rhs.number != 0 else { throw Invalid.syntax }
                value = Value(number: multiply ? value.number * rhs.number : value.number / rhs.number)
                guard value.number.isFinite else { throw Invalid.syntax }
            }
            return value
        }
        mutating func unary(depth: Int) throws -> Value {
            try check(depth)
            if take("+") { return try unary(depth: depth + 1) }
            if take("-") { var value = try unary(depth: depth + 1); value.number = -value.number; return value }
            return try power(depth: depth + 1)
        }
        mutating func power(depth: Int) throws -> Value {
            var value = try primary(depth: depth + 1)
            if take("%") { value.number /= 100; value.percent = true }
            if take("^") { value = Value(number: pow(value.number, try unary(depth: depth + 1).number)) }
            guard value.number.isFinite else { throw Invalid.syntax }
            return value
        }
        mutating func primary(depth: Int) throws -> Value {
            try check(depth)
            if case .number(let number) = current { index += 1; return Value(number: number) }
            if take("(") { let value = try sum(depth: depth + 1); guard take(")") else { throw Invalid.syntax }; return value }
            guard case .name(let name) = current else { throw Invalid.syntax }
            index += 1
            if name == "pi" || name == "π" { return Value(number: .pi) }
            if name == "e" { return Value(number: M_E) }
            guard take("(") else { throw Invalid.syntax }
            let x = try sum(depth: depth + 1).number
            guard take(")") else { throw Invalid.syntax }
            let result: Double
            switch name {
            case "sqrt": result = sqrt(x)
            case "sin": result = sin(x)
            case "cos": result = cos(x)
            case "tan": result = tan(x)
            case "log": result = log10(x)
            case "ln": result = log(x)
            case "abs": result = abs(x)
            case "round": result = x.rounded()
            case "floor": result = floor(x)
            case "ceil": result = ceil(x)
            default: throw Invalid.syntax
            }
            guard result.isFinite else { throw Invalid.syntax }
            return Value(number: result)
        }
    }
}
