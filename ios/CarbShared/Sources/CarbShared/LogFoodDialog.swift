import Foundation

/// What Siri says after logging food.
public enum LogFoodDialog {
    /// - Parameter skipped: foods the lookup had no carb value for. They weren't
    ///   logged, and Siri says so rather than leaving the user to wonder.
    public static func text(items: [LookupItem], totalToday: Double, skipped: [String] = []) -> String {
        let logged = loggedText(items: items, totalToday: totalToday)
        guard !skipped.isEmpty else { return logged }
        let them = skipped.count == 1 ? "it" : "them"
        return "\(logged) I couldn't find carbs for \(names(skipped)), so I didn't log \(them)."
    }

    private static func loggedText(items: [LookupItem], totalToday: Double) -> String {
        let total = "Your total today is \(grams(totalToday)) grams."
        let sum = items.reduce(0) { $0 + $1.carbs }
        switch items.count {
        case 1:
            return "\(items[0].name) has \(grams(items[0].carbs)) grams of carbs. \(total)"
        case 2:
            // Each part already contains a comma ("fries, 48.0 grams"), so a comma
            // before "and" keeps the two parts distinct when spoken.
            return "Logged \(part(items[0])), and \(part(items[1])): \(grams(sum)) grams. \(total)"
        case 3:
            return "Logged \(part(items[0])), \(part(items[1])), and \(part(items[2])): \(grams(sum)) grams. \(total)"
        default:
            return "Logged \(items.count) items, \(grams(sum)) grams. \(total)"
        }
    }

    /// "fries", "fries and shake", "fries, shake, and cake" — the same serial
    /// comma the logged-items list uses when spoken.
    private static func names(_ names: [String]) -> String {
        switch names.count {
        case 0, 1: return names.joined()
        case 2: return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + ", and \(names[names.count - 1])"
        }
    }

    private static func part(_ item: LookupItem) -> String {
        "\(item.name), \(grams(item.carbs)) grams"
    }

    private static func grams(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
