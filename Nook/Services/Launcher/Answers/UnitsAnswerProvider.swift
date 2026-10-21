import Foundation

@objc(NookUnitsAnswerProvider)
final class UnitsAnswerProvider: LauncherAnswerModule, LauncherAnswerProvider {
    let id = "units"
    private struct Unit {
        let dimension: String
        let symbol: String
        let name: String
        let scale: Double
        var offset = 0.0
        let metric: String
        let imperial: String
    }
    private static let units: [String: Unit] = {
        var map: [String: Unit] = [:]
        func add(_ dimension: String, _ symbol: String, _ name: String, _ scale: Double, _ aliases: [String],
                 _ metric: String, _ imperial: String, offset: Double = 0) {
            let unit = Unit(dimension: dimension, symbol: symbol, name: name, scale: scale, offset: offset, metric: metric, imperial: imperial)
            for alias in aliases + [symbol.lowercased()] { map[alias] = unit }
        }
        add("length", "m", "Meters", 1, ["meter", "meters", "metre", "metres"], "m", "ft")
        add("length", "km", "Kilometers", 1000, ["kilometer", "kilometers", "kilometres"], "km", "mi")
        add("length", "cm", "Centimeters", 0.01, ["centimeter", "centimeters", "centimetres"], "cm", "in")
        add("length", "mm", "Millimeters", 0.001, ["millimeter", "millimeters"], "mm", "in")
        add("length", "mi", "Miles", 1609.344, ["mile", "miles"], "km", "mi")
        add("length", "ft", "Feet", 0.3048, ["foot", "feet", "'"], "m", "ft")
        add("length", "in", "Inches", 0.0254, ["inch", "inches", "\""], "cm", "in")
        add("length", "yd", "Yards", 0.9144, ["yard", "yards"], "m", "yd")
        add("length", "nmi", "Nautical miles", 1852, ["nautical mile", "nautical miles"], "km", "mi")
        add("mass", "kg", "Kilograms", 1, ["kilogram", "kilograms", "kilos"], "kg", "lb")
        add("mass", "g", "Grams", 0.001, ["gram", "grams"], "g", "oz")
        add("mass", "mg", "Milligrams", 0.000001, ["milligram", "milligrams"], "mg", "oz")
        add("mass", "lb", "Pounds", 0.45359237, ["pound", "pounds", "lbs"], "kg", "lb")
        add("mass", "oz", "Ounces", 0.028349523125, ["ounce", "ounces"], "g", "oz")
        add("mass", "st", "Stone", 6.35029318, ["stone", "stones"], "kg", "lb")
        add("mass", "t", "Metric tons", 1000, ["tonne", "tonnes", "metric ton"], "kg", "lb")
        add("volume", "L", "Liters", 1, ["l", "liter", "liters", "litre", "litres"], "l", "gal")
        add("volume", "mL", "Milliliters", 0.001, ["ml", "milliliter", "milliliters"], "ml", "fl oz")
        add("volume", "cup", "US cups", 0.2365882365, ["cups", "us cup", "us cups"], "ml", "cup")
        add("volume", "tbsp", "US tablespoons", 0.01478676478125, ["tablespoon", "tablespoons"], "ml", "tbsp")
        add("volume", "tsp", "US teaspoons", 0.00492892159375, ["teaspoon", "teaspoons"], "ml", "tsp")
        add("volume", "gal", "US gallons", 3.785411784, ["gallon", "gallons", "us gallon"], "l", "gal")
        add("volume", "imp gal", "Imperial gallons", 4.54609, ["imperial gallon", "imperial gallons"], "l", "imp gal")
        add("volume", "pt", "US pints", 0.473176473, ["pint", "pints"], "ml", "pt")
        add("volume", "fl oz", "US fluid ounces", 0.0295735295625, ["floz", "fluid ounce", "fluid ounces"], "ml", "fl oz")
        add("temperature", "°C", "Celsius", 1, ["c", "°c", "celsius"], "c", "f", offset: 273.15)
        add("temperature", "°F", "Fahrenheit", 5.0 / 9, ["f", "°f", "fahrenheit"], "c", "f", offset: 273.15 - 32 * 5.0 / 9)
        add("temperature", "K", "Kelvin", 1, ["k", "kelvin"], "c", "f")
        add("speed", "km/h", "Kilometers per hour", 1 / 3.6, ["kph", "kmh", "kilometers per hour"], "km/h", "mph")
        add("speed", "mph", "Miles per hour", 0.44704, ["miles per hour"], "km/h", "mph")
        add("speed", "m/s", "Meters per second", 1, ["mps", "meters per second"], "m/s", "mph")
        add("speed", "kn", "Knots", 1852.0 / 3600, ["knot", "knots"], "km/h", "mph")
        add("area", "m²", "Square meters", 1, ["m2", "sqm", "square meter", "square meters"], "m2", "ft2")
        add("area", "km²", "Square kilometers", 1e6, ["km2", "square kilometers"], "km2", "mi2")
        add("area", "cm²", "Square centimeters", 0.0001, ["cm2", "square centimeters"], "cm2", "in2")
        add("area", "ft²", "Square feet", 0.09290304, ["ft2", "sqft", "square feet"], "m2", "ft2")
        add("area", "in²", "Square inches", 0.00064516, ["in2", "square inches"], "cm2", "in2")
        add("area", "mi²", "Square miles", 2589988.110336, ["mi2", "square miles"], "km2", "mi2")
        add("area", "ha", "Hectares", 10000, ["hectare", "hectares"], "ha", "acre")
        add("area", "acre", "Acres", 4046.8564224, ["acres"], "ha", "acre")
        for (symbol, scale) in [("B", 1.0), ("KB", 1e3), ("MB", 1e6), ("GB", 1e9), ("TB", 1e12),
                                ("KiB", 1024), ("MiB", 1048576), ("GiB", 1073741824), ("TiB", 1099511627776)] {
            add("data", symbol, symbol, scale, symbol == "B" ? ["byte", "bytes"] : [], "mb", "mb")
        }
        add("data", "bit", "Bits", 0.125, ["bits"], "b", "b")
        add("duration", "s", "Seconds", 1, ["sec", "secs", "second", "seconds"], "min", "min")
        add("duration", "ms", "Milliseconds", 0.001, ["millisecond", "milliseconds"], "s", "s")
        add("duration", "min", "Minutes", 60, ["mins", "minute", "minutes"], "h", "h")
        add("duration", "h", "Hours", 3600, ["hr", "hrs", "hour", "hours"], "min", "min")
        add("duration", "day", "Days", 86400, ["d", "days"], "h", "h")
        add("duration", "week", "Weeks", 604800, ["weeks", "wk"], "day", "day")
        add("energy", "J", "Joules", 1, ["j", "joule", "joules"], "kj", "kcal")
        add("energy", "kJ", "Kilojoules", 1000, ["kj", "kilojoule", "kilojoules"], "kj", "kcal")
        add("energy", "cal", "Calories", 4.184, ["calorie", "calories"], "kj", "cal")
        add("energy", "kcal", "Kilocalories", 4184, ["kilocalorie", "kilocalories"], "kj", "kcal")
        add("energy", "Wh", "Watt hours", 3600, ["wh", "watt hour", "watt hours"], "kj", "wh")
        add("energy", "kWh", "Kilowatt hours", 3600000, ["kwh", "kilowatt hour", "kilowatt hours"], "kj", "kwh")
        add("pressure", "Pa", "Pascals", 1, ["pa", "pascal", "pascals"], "kpa", "psi")
        add("pressure", "kPa", "Kilopascals", 1000, ["kpa", "kilopascal", "kilopascals"], "kpa", "psi")
        add("pressure", "bar", "Bar", 100000, ["bars"], "bar", "psi")
        add("pressure", "psi", "PSI", 6894.757293168, [], "kpa", "psi")
        add("pressure", "atm", "Atmospheres", 101325, ["atmosphere", "atmospheres"], "kpa", "psi")
        add("angle", "°", "Degrees", .pi / 180, ["deg", "degree", "degrees"], "rad", "rad")
        add("angle", "rad", "Radians", 1, ["radian", "radians"], "deg", "deg")
        add("angle", "turn", "Turns", 2 * .pi, ["turns", "revolution", "revolutions"], "deg", "deg")
        return map
    }()
    required init() { super.init(); _ = Self.units }

    func answer(for query: String, context: LauncherAnswerContext) -> LauncherAnswer? {
        guard context.hasTime else { return nil }
        let text = AnswerText.normalized(query)
        let parts = text.components(separatedBy: try! NSRegularExpression(pattern: #"\s+(?:in|to)\s+"#))
        guard parts.count <= 2 else { return nil }
        let amount: Double, source: Unit
        if let height = AnswerText.match(#"(\d+)\s*'\s*(\d+(?:[.,]\d+)?)\s*"?"#, parts[0]),
           let feet = Double(height[0]), let inches = AnswerText.number(height[1]), inches < 12 {
            amount = feet * 12 + inches; source = Self.units["in"]!
        } else {
            guard let match = AnswerText.match("(" + AnswerText.quantity + #")\s*([a-z°²'"/ ]+[0-9²]?)"#, parts[0]),
                  let value = AnswerText.number(match[0]), let unit = Self.units[match[1].trimmingCharacters(in: .whitespaces)] else { return nil }
            amount = value; source = unit
        }
        var targetKey = parts.count == 2 ? parts[1].trimmingCharacters(in: .whitespaces) : (context.usesMetric ? source.metric : source.imperial)
        if parts.count == 1, Self.units[targetKey]?.symbol == source.symbol { targetKey = context.usesMetric ? source.imperial : source.metric }
        guard let target = Self.units[targetKey], source.dimension == target.dimension else { return nil }
        let base = amount * source.scale + source.offset
        guard source.dimension != "temperature" || base >= -1e-10 else { return nil }
        let result = (base - target.offset) / target.scale
        guard result.isFinite, context.hasTime else { return nil }
        let number = AnswerText.format(result, locale: context.locale)
        return LauncherAnswer(expression: query, leftBadge: source.name, result: number + " " + target.symbol,
                              rightBadge: target.name, copyValue: AnswerText.copyNumber(result),
                              copyWithUnits: number + " " + target.symbol)
    }
}

private extension String {
    func components(separatedBy regex: NSRegularExpression) -> [String] {
        let ranges = regex.matches(in: self, range: NSRange(startIndex..., in: self))
        var parts: [String] = [], start = startIndex
        for match in ranges {
            guard let range = Range(match.range, in: self) else { continue }
            parts.append(String(self[start..<range.lowerBound])); start = range.upperBound
        }
        parts.append(String(self[start...])); return parts
    }
}
