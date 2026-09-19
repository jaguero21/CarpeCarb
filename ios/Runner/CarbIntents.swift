import AppIntents
import CarbShared

// MARK: - Log Food Intent

struct LogFoodIntent: AppIntent {
    static var title: LocalizedStringResource = "Log Food in CarpeCarb"
    static var description = IntentDescription("Look up carbs for a food item and add it to today's total.")

    static var openAppWhenRun: Bool = false

    @Parameter(title: "Food Item", requestValueDialog: "What food would you like to log?")
    var foodItem: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let idToken = try await SiriAuth.idToken()
        let result = try await PerplexityClient.lookupCarbs(for: foodItem, idToken: idToken)

        let now = Date()
        for item in result.items {
            await CarbDataStore.shared.addFood(LoggedFood(item: item, citations: result.citations), now: now)
        }
        let totalToday = CarbDataStore.shared.snapshot(now: now).totalCarbs

        return .result(dialog: IntentDialog(stringLiteral: LogFoodDialog.text(items: result.items, totalToday: totalToday)))
    }
}

// MARK: - Check Carbs Intent

struct CheckCarbsIntent: AppIntent {
    static var title: LocalizedStringResource = "Check Today's Carbs"
    static var description = IntentDescription("Check how many carbs you've eaten today.")

    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let today = CarbDataStore.shared.snapshot()
        let total = today.totalCarbs
        let lastFood = today.lastFoodName
        let lastCarbs = today.lastFoodCarbs
        let goal = today.dailyGoal

        let formattedTotal = String(format: "%.1f", total)

        if total == 0.0 {
            return .result(dialog: "You haven't tracked any carbs today. Open CarpeCarb to start logging.")
        }

        var message = "You've had \(formattedTotal) grams of carbs today."

        if let goal = goal {
            let formattedGoal = String(format: "%.0f", goal)
            if total >= goal {
                let over = String(format: "%.1f", total - goal)
                message += " You're \(over) grams over your \(formattedGoal) gram goal."
            } else {
                let remaining = String(format: "%.1f", goal - total)
                message += " You have \(remaining) grams remaining of your \(formattedGoal) gram goal."
            }
        }

        if !lastFood.isEmpty {
            let formattedLast = String(format: "%.1f", lastCarbs)
            message += " Your last entry was \(lastFood) at \(formattedLast) grams."
        }

        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

// MARK: - Open App Intent

struct OpenCarpeCarbIntent: AppIntent {
    static var title: LocalizedStringResource = "Open CarpeCarb"
    static var description = IntentDescription("Open the CarpeCarb app.")

    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        return .result()
    }
}
