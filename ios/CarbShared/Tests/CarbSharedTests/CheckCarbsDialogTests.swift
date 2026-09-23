import Testing
@testable import CarbShared

/// The wording Siri speaks for "how many carbs have I had today?".
///
/// This logic lived inside `CheckCarbsIntent.perform()` and had no tests: the
/// only way to reach it was to run the intent. Every case below is one a
/// diabetic user actually hears.
struct CheckCarbsDialogTests {
    @Test func nothingLoggedInvitesTheUserToStart() {
        // Reciting a goal before anything is logged is noise.
        #expect(CheckCarbsDialog.text(total: 0, goal: 100, lastFood: "", lastCarbs: 0) ==
            "You haven't tracked any carbs today. Open CarpeCarb to start logging.")
    }

    @Test func nothingLoggedSaysTheSameWithNoGoalSet() {
        #expect(CheckCarbsDialog.text(total: 0, goal: nil, lastFood: "", lastCarbs: 0) ==
            "You haven't tracked any carbs today. Open CarpeCarb to start logging.")
    }

    @Test func underTheGoalReportsWhatIsLeft() {
        #expect(CheckCarbsDialog.text(total: 25, goal: 100, lastFood: "Apple", lastCarbs: 25) ==
            "You've had 25.0 grams of carbs today. You have 75.0 grams remaining of "
            + "your 100 gram goal. Your last entry was Apple at 25.0 grams.")
    }

    @Test func overTheGoalReportsTheExcess() {
        #expect(CheckCarbsDialog.text(total: 120, goal: 100, lastFood: "Bagel", lastCarbs: 48) ==
            "You've had 120.0 grams of carbs today. You're 20.0 grams over your "
            + "100 gram goal. Your last entry was Bagel at 48.0 grams.")
    }

    @Test func exactlyAtTheGoalCountsAsOver() {
        // The boundary matters to someone dosing insulin against it: at the
        // goal you are not "remaining 0 grams", you have arrived.
        let text = CheckCarbsDialog.text(total: 100, goal: 100, lastFood: "", lastCarbs: 0)
        #expect(text.contains("You're 0.0 grams over your 100 gram goal."))
        #expect(!text.contains("remaining"))
    }

    @Test func noGoalSetOmitsTheGoalSentenceEntirely() {
        #expect(CheckCarbsDialog.text(total: 25, goal: nil, lastFood: "Apple", lastCarbs: 25) ==
            "You've had 25.0 grams of carbs today. Your last entry was Apple at 25.0 grams.")
    }

    @Test func noLastEntryOmitsThatSentence() {
        #expect(CheckCarbsDialog.text(total: 25, goal: nil, lastFood: "", lastCarbs: 0) ==
            "You've had 25.0 grams of carbs today.")
    }
}
