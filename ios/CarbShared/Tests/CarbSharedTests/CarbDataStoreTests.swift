import Foundation
import Testing
@testable import CarbShared

@MainActor
struct CarbDataStoreTests {
    private let suiteName = "CarbDataStoreTests-\(UUID().uuidString)"
    private let defaults: UserDefaults
    private let store: CarbDataStore
    private let noon: Date

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
        store = CarbDataStore(defaults: defaults)
        noon = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 12)))
    }

    private func seedYesterday() {
        defaults.set(80.0, forKey: CarbDataStore.Keys.totalCarbs)
        defaults.set("Pasta", forKey: CarbDataStore.Keys.lastFoodName)
        defaults.set(60.0, forKey: CarbDataStore.Keys.lastFoodCarbs)
        defaults.set(150.0, forKey: CarbDataStore.Keys.dailyCarbGoal)
        defaults.set("2026-09-17", forKey: CarbDataStore.Keys.dayKey)
    }

    @Test func snapshotOfTodaysTotals() {
        seedYesterday()
        defaults.set("2026-09-18", forKey: CarbDataStore.Keys.dayKey)
        #expect(store.snapshot(now: noon) == CarbSnapshot(totalCarbs: 80, lastFoodName: "Pasta", lastFoodCarbs: 60, dailyGoal: 150))
    }

    @Test func snapshotOnANewDayIsEmptyButKeepsTheGoal() {
        seedYesterday()
        #expect(store.snapshot(now: noon) == CarbSnapshot(totalCarbs: 0, lastFoodName: "", lastFoodCarbs: 0, dailyGoal: 150))
    }

    @Test func missingDayKeyIsTrustedAsToday() {
        seedYesterday()
        defaults.removeObject(forKey: CarbDataStore.Keys.dayKey)
        #expect(store.snapshot(now: noon).totalCarbs == 80)
    }

    @Test func resetHourMovesTheDayBoundary() throws {
        seedYesterday()
        defaults.set(4, forKey: CarbDataStore.Keys.dailyResetHour)
        let threeAM = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 3)))
        #expect(store.snapshot(now: threeAM).totalCarbs == 80) // still "2026-09-17" before 4 AM
        #expect(store.snapshot(now: noon).totalCarbs == 0)
    }

    @Test func addFoodOnANewDayStartsFromZeroAndStampsToday() {
        seedYesterday()
        store.addFood(LoggedFood(name: "Apple", carbs: 25), now: noon)
        #expect(store.snapshot(now: noon).totalCarbs == 25)
        #expect(defaults.string(forKey: CarbDataStore.Keys.dayKey) == "2026-09-18")
    }

    @Test func addFoodBeforeTheResetHourStampsThePreviousDay() throws {
        defaults.set(4, forKey: CarbDataStore.Keys.dailyResetHour)
        let threeAM = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 3)))
        store.addFood(LoggedFood(name: "Toast", carbs: 15), now: threeAM)
        #expect(defaults.string(forKey: CarbDataStore.Keys.dayKey) == "2026-09-17")
    }

    @Test func addFoodAddsToTodaysTotal() {
        store.addFood(LoggedFood(name: "Apple", carbs: 25), now: noon)
        store.addFood(LoggedFood(name: "Fries", carbs: 48), now: noon)
        #expect(store.snapshot(now: noon) == CarbSnapshot(totalCarbs: 73, lastFoodName: "Fries", lastFoodCarbs: 48, dailyGoal: nil))
    }

    @Test func addFoodBuffersItemsWithMacrosForTheApp() {
        store.addFood(LoggedFood(name: "Big Mac", carbs: 45, protein: 25, fat: 30, fiber: 3, calories: 590,
                                 details: "McDonald's", citations: ["https://example.com"]), now: noon)
        store.addFood(LoggedFood(name: "Water", carbs: 0), now: noon)
        let buffer = store.siriLoggedItems()
        #expect(buffer.count == 2)
        #expect(buffer[0]["name"] as? String == "Big Mac")
        #expect(buffer[0]["protein"] as? Double == 25)
        #expect(buffer[0]["calories"] as? Double == 590)
        #expect(buffer[0]["citations"] as? [String] == ["https://example.com"])
        #expect(buffer[0]["loggedAt"] as? String == ISO8601DateFormatter().string(from: noon))
        #expect(buffer[1]["protein"] == nil)
    }
}
