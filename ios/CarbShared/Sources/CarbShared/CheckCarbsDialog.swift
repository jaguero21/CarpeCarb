import Foundation

/// What Siri says when asked how many carbs you've had today.
///
/// Lives here rather than inside the intent so the wording can be tested
/// without running the intent — the same reason `LogFoodDialog` does.
public enum CheckCarbsDialog {
    /// - Parameters:
    ///   - total: carbs logged today.
    ///   - goal: the daily goal, or nil when none is set.
    ///   - lastFood: the most recent entry's name; empty when there is none.
    ///   - lastCarbs: that entry's carbs.
    public static func text(
        total: Double,
        goal: Double?,
        lastFood: String,
        lastCarbs: Double
    ) -> String {
        // Nothing logged: say so plainly rather than reciting a goal the user
        // hasn't started against.
        if total == 0.0 {
            return "You haven't tracked any carbs today. Open CarpeCarb to start logging."
        }

        var message = "You've had \(grams(total)) grams of carbs today."

        if let goal {
            let formattedGoal = String(format: "%.0f", goal)
            if total >= goal {
                message += " You're \(grams(total - goal)) grams over your \(formattedGoal) gram goal."
            } else {
                message += " You have \(grams(goal - total)) grams remaining of your \(formattedGoal) gram goal."
            }
        }

        if !lastFood.isEmpty {
            message += " Your last entry was \(lastFood) at \(grams(lastCarbs)) grams."
        }

        return message
    }

    private static func grams(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
