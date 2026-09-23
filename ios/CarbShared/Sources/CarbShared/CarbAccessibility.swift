import Foundation

/// What VoiceOver reads for the widget's ring, which is otherwise two
/// undescribed circles.
///
/// The wording matches the app's (`lib/utils/a11y_labels.dart`) so the same
/// number is spoken the same way in both places.
public enum CarbAccessibility {
    /// A gram value as it should be spoken: "25 grams", "1 gram", "25.5 grams" —
    /// never "25.0", which is read aloud as "twenty five point zero".
    public static func grams(_ value: Double) -> String {
        let text = number(value)
        return "\(text) \(text == "1" ? "gram" : "grams")"
    }

    /// The ring's value: "45 of 100 grams", or "45 grams, no goal set".
    ///
    /// Over the goal this deliberately stops at the two numbers, where its
    /// Dart twin (`carbProgressValue`) appends ", 20 grams over goal": the
    /// widget draws "+20g over" as its own accessibility element beside the
    /// ring, so saying it here too would say it twice.
    public static func carbsValue(total: Double, goal: Double?) -> String {
        guard let goal, goal > 0 else {
            return "\(grams(total)), no goal set"
        }
        return "\(number(total)) of \(grams(goal))"
    }

    /// A number without a trailing ".0".
    static func number(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded()
            ? String(format: "%.0f", rounded)
            : String(format: "%.1f", rounded)
    }
}
