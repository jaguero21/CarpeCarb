import Foundation

/// What Siri says after logging food.
public enum LogFoodDialog {
    public static func text(items: [LookupItem], totalToday: Double) -> String {
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

    private static func part(_ item: LookupItem) -> String {
        "\(item.name), \(grams(item.carbs)) grams"
    }

    private static func grams(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
