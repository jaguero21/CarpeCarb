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

    @Test func storedDayKeyIsSetOnceFoodIsAdded() {
        #expect(store.storedDayKey == nil)
        store.addFood(LoggedFood(name: "Apple", carbs: 25), now: noon)
        #expect(store.storedDayKey == "2026-09-18")
    }

    @Test func addFoodAddsToTodaysTotal() {
        store.addFood(LoggedFood(name: "Apple", carbs: 25), now: noon)
        store.addFood(LoggedFood(name: "Fries", carbs: 48), now: noon)
        #expect(store.snapshot(now: noon) == CarbSnapshot(totalCarbs: 73, lastFoodName: "Fries", lastFoodCarbs: 48, dailyGoal: nil))
    }

    @Test func addFoodBuffersItemsWithMacrosForTheApp() throws {
        store.addFood(LoggedFood(name: "Big Mac", carbs: 45, protein: 25, fat: 30, fiber: 3, calories: 590,
                                 details: "McDonald's", citations: ["https://example.com"]), now: noon)
        store.addFood(LoggedFood(name: "Water", carbs: 0), now: noon)
        let buffer = store.siriLoggedItems()
        #expect(buffer.count == 2)
        #expect(buffer[0]["name"] as? String == "Big Mac")
        #expect(buffer[0]["protein"] as? Double == 25)
        #expect(buffer[0]["calories"] as? Double == 590)
        #expect(buffer[0]["citations"] as? [String] == ["https://example.com"])
        // The time the food was logged, with milliseconds, so foods from one
        // lookup stay apart.
        let stamp = try #require(buffer[0]["loggedAt"] as? String)
        let withMilliseconds = ISO8601DateFormatter()
        withMilliseconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        #expect(withMilliseconds.date(from: stamp) == noon)
        #expect(stamp.hasSuffix(".000Z"))
        #expect(buffer[1]["protein"] == nil)
    }

    @Test func takeSiriLoggedItemsReturnsTheBufferAndEmptiesIt() {
        store.addFood(LoggedFood(name: "Toast", carbs: 15), now: noon)

        let taken = store.takeSiriLoggedItems()

        #expect(taken?.contains("Toast") == true)
        #expect(defaults.string(forKey: CarbDataStore.Keys.siriLoggedItems) == nil)
        // A second take finds nothing, so nothing is imported twice.
        #expect(store.takeSiriLoggedItems() == nil)
    }

    @Test func takeSiriLoggedItemsReturnsNilWhenNothingIsWaiting() {
        #expect(store.takeSiriLoggedItems() == nil)
    }

    @Test func foodsFromOneLookupAreLoggedOneMillisecondApart() throws {
        let total = store.addFoods(
            [LoggedFood(name: "Burger", carbs: 30), LoggedFood(name: "Fries", carbs: 48)],
            now: noon
        )

        #expect(total == 78)
        // Each gets its own Apple Health entry when the app imports them, and
        // the app deletes an entry by the millisecond it starts in.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let times = try store.siriLoggedItems().map { entry -> Date in
            let stamp = try #require(entry["loggedAt"] as? String)
            return try #require(formatter.date(from: stamp))
        }
        #expect(times.count == 2)
        #expect(abs(times[1].timeIntervalSince(times[0]) - 0.001) < 0.0001)
    }

    @Test func siriTimestampsKeepMilliseconds() throws {
        store.addFood(LoggedFood(name: "Toast", carbs: 15), now: noon.addingTimeInterval(0.25))

        let stamp = try #require(store.siriLoggedItems().first?["loggedAt"] as? String)
        #expect(stamp.contains(".250"))
    }
}
