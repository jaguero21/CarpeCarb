import AppIntents
import CarbShared

// MARK: - Log Food Intent

struct LogFoodIntent: AppIntent {
    static let title: LocalizedStringResource = "Log Food in CarpeCarb"
    static let description = IntentDescription("Look up carbs for a food item and add it to today's total.")

    static let openAppWhenRun: Bool = false

    @Parameter(title: "Food Item", requestValueDialog: "What food would you like to log?")
    var foodItem: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let idToken = try await SiriAuth.idToken()
        let result = try await PerplexityClient.lookupCarbs(for: foodItem, idToken: idToken)

        let foods = result.items.map { LoggedFood(item: $0, citations: result.citations) }
        let totalToday = await MainActor.run {
            CarbDataStore.shared.addFoods(foods, now: Date())
        }

        return .result(dialog: IntentDialog(stringLiteral: LogFoodDialog.text(
            items: result.items, totalToday: totalToday, skipped: result.unknownCarbs)))
    }
}

// MARK: - Check Carbs Intent

struct CheckCarbsIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Today's Carbs"
    static let description = IntentDescription("Check how many carbs you've eaten today.")

    static let openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let today = CarbDataStore.shared.snapshot()
        return .result(dialog: IntentDialog(stringLiteral: CheckCarbsDialog.text(
            total: today.totalCarbs,
            goal: today.dailyGoal,
            lastFood: today.lastFoodName,
            lastCarbs: today.lastFoodCarbs)))
    }
}

// MARK: - Open App Intent

struct OpenCarpeCarbIntent: AppIntent {
    static let title: LocalizedStringResource = "Open CarpeCarb"
    static let description = IntentDescription("Open the CarpeCarb app.")

    static let openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        return .result()
    }
}
