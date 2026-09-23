import Testing
@testable import CarbShared

struct CarbAccessibilityTests {
    @Test func gramsDropsThePointZeroVoiceOverWouldReadAloud() {
        #expect(CarbAccessibility.grams(25) == "25 grams")
        #expect(CarbAccessibility.grams(25.5) == "25.5 grams")
    }

    @Test func gramsIsSingularForOne() {
        #expect(CarbAccessibility.grams(1) == "1 gram")
    }

    @Test func valueReadsTheTotalAgainstTheGoal() {
        #expect(CarbAccessibility.carbsValue(total: 45, goal: 100) == "45 of 100 grams")
    }

    @Test func valueSaysWhenNoGoalIsSet() {
        #expect(CarbAccessibility.carbsValue(total: 45, goal: nil) == "45 grams, no goal set")
        // A zero goal means "no goal" everywhere else in the app.
        #expect(CarbAccessibility.carbsValue(total: 45, goal: 0) == "45 grams, no goal set")
    }
}
