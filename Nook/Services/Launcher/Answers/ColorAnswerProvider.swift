import Foundation

@objc(NookColorAnswerProvider)
final class ColorAnswerProvider: LauncherAnswerModule, LauncherAnswerProvider {
    let id = "color"
    func answer(for query: String, context: LauncherAnswerContext) -> LauncherAnswer? {
        guard context.hasTime else { return nil }
        var text = AnswerText.normalized(query), target: String?
        if let match = AnswerText.match(#"(.+?)\s+(?:in|to)\s+(hex|rgb|hsl)"#, text) { text = match[0]; target = match[1] }
        let r: Double, g: Double, b: Double, source: String
        if let match = AnswerText.match(#"#([0-9a-f]{3}|[0-9a-f]{6})"#, text) {
            let hex = match[0].count == 3 ? match[0].map { "\($0)\($0)" }.joined() : match[0]
            guard let value = UInt32(hex, radix: 16) else { return nil }
            r = Double((value >> 16) & 255) / 255; g = Double((value >> 8) & 255) / 255; b = Double(value & 255) / 255; source = "HEX"
        } else if let match = AnswerText.match(#"rgb\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})\s*\)"#, text),
                  let red = Double(match[0]), let green = Double(match[1]), let blue = Double(match[2]), [red, green, blue].allSatisfy({ $0 <= 255 }) {
            r = red / 255; g = green / 255; b = blue / 255; source = "RGB"
        } else if let match = AnswerText.match(#"hsl\(\s*([+-]?\d+(?:\.\d+)?)\s*,\s*(\d+(?:\.\d+)?)%\s*,\s*(\d+(?:\.\d+)?)%\s*\)"#, text),
                  let hue = Double(match[0]), let saturation = Double(match[1]), let lightness = Double(match[2]), hue.isFinite, saturation <= 100, lightness <= 100 {
            let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
            let s = saturation / 100, l = lightness / 100, chroma = (1 - abs(2 * l - 1)) * s
            let x = chroma * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)), m = l - chroma / 2
            let components: (Double, Double, Double)
            switch h { case ..<1: components = (chroma, x, 0); case ..<2: components = (x, chroma, 0)
            case ..<3: components = (0, chroma, x); case ..<4: components = (0, x, chroma)
            case ..<5: components = (x, 0, chroma); default: components = (chroma, 0, x) }
            r = components.0 + m; g = components.1 + m; b = components.2 + m; source = "HSL"
        } else { return nil }
        let rgb = "rgb(\(Int((r * 255).rounded())), \(Int((g * 255).rounded())), \(Int((b * 255).rounded())))"
        let hex = String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
        let maxValue = max(r, g, b), minValue = min(r, g, b), delta = maxValue - minValue, l = (maxValue + minValue) / 2
        var h = 0.0
        if delta > 0 {
            if maxValue == r { h = ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
            else if maxValue == g { h = (b - r) / delta + 2 }
            else { h = (r - g) / delta + 4 }
            h = (h * 60 + 360).truncatingRemainder(dividingBy: 360)
        }
        let s = delta == 0 ? 0 : delta / (1 - abs(2 * l - 1))
        let hsl = "hsl(\(Int(h.rounded()) % 360), \(Int((s * 100).rounded()))%, \(Int((l * 100).rounded()))%)"
        let format = target ?? (source == "HEX" ? "rgb" : "hex")
        let result = format == "hex" ? hex : format == "hsl" ? hsl : rgb
        return LauncherAnswer(section: "Color", expression: query, leftBadge: source, result: result, rightBadge: format.uppercased(),
                              copyValue: result, swatch: .init(red: r, green: g, blue: b), secondaryActions: [
                                .init(title: "Copy HEX", value: .copy(hex)), .init(title: "Copy RGB", value: .copy(rgb)), .init(title: "Copy HSL", value: .copy(hsl))])
    }
}
