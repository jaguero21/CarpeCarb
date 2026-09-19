import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Today's totals as Siri and the widget should show them.
public struct CarbSnapshot: Equatable, Sendable {
    public let totalCarbs: Double
    public let lastFoodName: String
    public let lastFoodCarbs: Double
    public let dailyGoal: Double?

    public init(totalCarbs: Double, lastFoodName: String, lastFoodCarbs: Double, dailyGoal: Double?) {
        self.totalCarbs = totalCarbs
        self.lastFoodName = lastFoodName
        self.lastFoodCarbs = lastFoodCarbs
        self.dailyGoal = dailyGoal
    }

    /// The same snapshot at the start of a new day: nothing logged yet, goal kept.
    public var startingNewDay: CarbSnapshot {
        CarbSnapshot(totalCarbs: 0, lastFoodName: "", lastFoodCarbs: 0, dailyGoal: dailyGoal)
    }
}

/// A food logged outside the app (Siri), buffered for the app to import.
public struct LoggedFood: Equatable, Sendable {
    public let name: String
    public let carbs: Double
    public let protein: Double?
    public let fat: Double?
    public let fiber: Double?
    public let calories: Double?
    public let details: String?
    public let citations: [String]

    public init(name: String, carbs: Double, protein: Double? = nil, fat: Double? = nil,
                fiber: Double? = nil, calories: Double? = nil, details: String? = nil,
                citations: [String] = []) {
        self.name = name
        self.carbs = carbs
        self.protein = protein
        self.fat = fat
        self.fiber = fiber
        self.calories = calories
        self.details = details
        self.citations = citations
    }
}

/// The App Group store shared by the app (via HomeWidget), Siri, and the widget.
///
/// The app writes the totals together with the day they belong to (`dayKey`)
/// and the user's reset hour, so readers can tell when the stored totals are
/// from a previous day.
public struct CarbDataStore {
    public static let appGroupID = "group.com.carpecarb.shared"

    /// UserDefaults key constants — must match StorageKeys in Dart.
    public struct Keys {
        public static let totalCarbs = "totalCarbs"
        public static let lastFoodName = "lastFoodName"
        public static let lastFoodCarbs = "lastFoodCarbs"
        public static let dailyCarbGoal = "dailyCarbGoal"
        public static let siriLoggedItems = "siriLoggedItems"
        public static let dayKey = "dayKey"
        public static let dailyResetHour = "dailyResetHour"
        public static let flutterTotalCarbs = "flutter.total_carbs"
    }

    /// The App Group store used by the app, Siri, and the widget.
    public static let shared = CarbDataStore(defaults: UserDefaults(suiteName: appGroupID))

    private let defaults: UserDefaults?

    /// - Parameter defaults: the backing store; tests pass a throwaway suite.
    public init(defaults: UserDefaults?) {
        self.defaults = defaults
    }

    /// Hour the user's day starts at (0 = midnight). Missing means 0.
    public var resetHour: Int {
        defaults?.integer(forKey: Keys.dailyResetHour) ?? 0
    }

    /// Today's totals. If the stored totals belong to an earlier day, total and
    /// last food are empty; the goal is kept. A missing `dayKey` (written by an
    /// app build from before day tracking) is trusted as today.
    public func snapshot(now: Date = Date()) -> CarbSnapshot {
        let goal = defaults?.double(forKey: Keys.dailyCarbGoal) ?? 0
        let stored = CarbSnapshot(
            totalCarbs: defaults?.double(forKey: Keys.totalCarbs) ?? 0,
            lastFoodName: defaults?.string(forKey: Keys.lastFoodName) ?? "",
            lastFoodCarbs: defaults?.double(forKey: Keys.lastFoodCarbs) ?? 0,
            dailyGoal: goal > 0 ? goal : nil
        )
        return isStoredDayCurrent(now: now) ? stored : stored.startingNewDay
    }

    /// Adds a food logged outside the app: updates today's totals (starting
    /// from 0 on a new day), stamps today's `dayKey`, and appends the item to
    /// the buffer the app imports on its next launch or resume.
    ///
    /// Main-actor isolated: Siri runs in the app's process, so this keeps its
    /// read-modify-write from interleaving with the app's own App Group writes.
    @MainActor
    public func addFood(_ food: LoggedFood, now: Date = Date()) {
        let newTotal = snapshot(now: now).totalCarbs + food.carbs
        defaults?.set(newTotal, forKey: Keys.totalCarbs)
        defaults?.set(food.name, forKey: Keys.lastFoodName)
        defaults?.set(food.carbs, forKey: Keys.lastFoodCarbs)
        defaults?.set(CarbDay.key(for: now, resetHour: resetHour), forKey: Keys.dayKey)
        defaults?.set(newTotal, forKey: Keys.flutterTotalCarbs)

        var buffer = siriLoggedItems()
        var entry: [String: Any] = [
            "name": food.name,
            "carbs": food.carbs,
            "loggedAt": ISO8601DateFormatter().string(from: now),
        ]
        if let protein = food.protein { entry["protein"] = protein }
        if let fat = food.fat { entry["fat"] = fat }
        if let fiber = food.fiber { entry["fiber"] = fiber }
        if let calories = food.calories { entry["calories"] = calories }
        if let details = food.details { entry["details"] = details }
        if !food.citations.isEmpty { entry["citations"] = food.citations }
        buffer.append(entry)
        if let data = try? JSONSerialization.data(withJSONObject: buffer),
           let json = String(data: data, encoding: .utf8) {
            defaults?.set(json, forKey: Keys.siriLoggedItems)
        }

        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    /// Items waiting for the app to import, as written by `addFood`.
    func siriLoggedItems() -> [[String: Any]] {
        guard let json = defaults?.string(forKey: Keys.siriLoggedItems),
              let data = json.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return items
    }

    private func isStoredDayCurrent(now: Date) -> Bool {
        guard let storedDay = defaults?.string(forKey: Keys.dayKey) else { return true }
        return storedDay == CarbDay.key(for: now, resetHour: resetHour)
    }
}
