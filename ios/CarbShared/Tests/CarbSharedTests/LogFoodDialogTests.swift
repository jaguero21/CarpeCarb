import Testing
@testable import CarbShared

struct LogFoodDialogTests {
    private let bigMac = LookupItem(name: "Big Mac", carbs: 45)
    private let fries = LookupItem(name: "fries", carbs: 48)
    private let coke = LookupItem(name: "Coke", carbs: 39)

    @Test func oneItemKeepsTheOriginalWording() {
        #expect(LogFoodDialog.text(items: [bigMac], totalToday: 88) ==
            "Big Mac has 45.0 grams of carbs. Your total today is 88.0 grams.")
    }

    @Test func twoItemsAreListed() {
        #expect(LogFoodDialog.text(items: [bigMac, fries], totalToday: 136) ==
            "Logged Big Mac, 45.0 grams, and fries, 48.0 grams: 93.0 grams. Your total today is 136.0 grams.")
    }

    @Test func threeItemsAreListed() {
        #expect(LogFoodDialog.text(items: [bigMac, fries, coke], totalToday: 132) ==
            "Logged Big Mac, 45.0 grams, fries, 48.0 grams, and Coke, 39.0 grams: 132.0 grams. Your total today is 132.0 grams.")
    }

    @Test func aSkippedFoodIsNamed() {
        #expect(LogFoodDialog.text(items: [bigMac], totalToday: 88, skipped: ["fries"]) ==
            "Big Mac has 45.0 grams of carbs. Your total today is 88.0 grams. I couldn't find carbs for fries, so I didn't log it.")
    }

    @Test func severalSkippedFoodsAreNamed() {
        #expect(LogFoodDialog.text(items: [bigMac], totalToday: 88, skipped: ["fries", "shake", "pie"]) ==
            "Big Mac has 45.0 grams of carbs. Your total today is 88.0 grams. I couldn't find carbs for fries, shake, and pie, so I didn't log them.")
    }

    @Test func fourOrMoreItemsAreCounted() {
        #expect(LogFoodDialog.text(items: [bigMac, fries, coke, bigMac], totalToday: 177) ==
            "Logged 4 items, 177.0 grams. Your total today is 177.0 grams.")
    }
}
