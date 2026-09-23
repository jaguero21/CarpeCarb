import Foundation
import Testing
@testable import CarbShared

struct PerplexityClientErrorMessageTests {
    private func errorBody(reason: String? = nil, limit: Int? = nil) throws -> Data {
        var details: [String: Any] = [:]
        if let reason { details["reason"] = reason }
        if let limit { details["limit"] = limit }
        let body: [String: Any] = [
            "error": [
                "status": "RESOURCE_EXHAUSTED",
                "message": "irrelevant",
                "details": details,
            ] as [String: Any]
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    @Test func dailyQuotaNamesTheLimit() throws {
        let message = PerplexityClient.errorMessage(status: 429, body: try errorBody(reason: "daily-quota", limit: 4))
        #expect(message == "You've used today's 4 free lookups. Open CarpeCarb to go unlimited.")
    }

    @Test func dailyQuotaWithoutLimitStillReadsNaturally() throws {
        let message = PerplexityClient.errorMessage(status: 429, body: try errorBody(reason: "daily-quota"))
        #expect(message == "You've used today's free lookups. Open CarpeCarb to go unlimited.")
    }

    @Test func perMinuteRateLimitKeepsItsMessage() throws {
        let message = PerplexityClient.errorMessage(status: 429, body: try errorBody())
        #expect(message == "Rate limit exceeded. Try again shortly.")
    }

    @Test func otherStatusesReportTheCode() {
        #expect(PerplexityClient.errorMessage(status: 500, body: Data("oops".utf8)) == "Server error (500).")
    }
}

struct PerplexityClientParseTests {
    private func body(_ result: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["result": result])
    }

    @Test func parsesEveryItemWithMacros() throws {
        let data = try body([
            "items": [
                ["name": "Big Mac", "carbs": 45, "protein": 25, "fat": 30, "fiber": 3, "calories": 590, "details": "McDonald's [1]"],
                ["name": "Fries", "carbs": "48", "protein": NSNull()],
            ],
            "citations": ["https://example.com"],
        ])
        let result = try PerplexityClient.parseResponse(data)
        #expect(result == LookupResult(items: [
            LookupItem(name: "Big Mac", carbs: 45, protein: 25, fat: 30, fiber: 3, calories: 590, details: "McDonald's [1]"),
            LookupItem(name: "Fries", carbs: 48),
        ], citations: ["https://example.com"]))
    }

    @Test func nonFiniteOrNegativeMacrosAreDropped() throws {
        let data = try body([
            "items": [
                ["name": "Mystery", "carbs": 12, "protein": "inf", "fat": -3],
            ],
        ])
        let result = try PerplexityClient.parseResponse(data)
        #expect(result.items == [LookupItem(name: "Mystery", carbs: 12, protein: nil, fat: nil)])
    }

    @Test func aFoodWithNoCarbValueIsSkippedNotZero() throws {
        let data = try body([
            "items": [
                ["name": "Burger", "carbs": 30],
                ["name": "Fries", "carbs": NSNull()],
                ["name": "Mystery", "carbs": "nan"],
            ],
        ])
        let result = try PerplexityClient.parseResponse(data)
        // A confident 0 g is worse than no answer for someone dosing insulin.
        #expect(result.items == [LookupItem(name: "Burger", carbs: 30)])
        #expect(result.unknownCarbs == ["Fries", "Mystery"])
    }

    @Test func aRealZeroIsLogged() throws {
        let data = try body(["items": [["name": "Water", "carbs": 0]]])
        #expect(try PerplexityClient.parseResponse(data).items == [LookupItem(name: "Water", carbs: 0)])
    }

    @Test func noCarbValuesAtAllSaysNothingWasFound() throws {
        let data = try body(["items": [["name": "Fries", "carbs": NSNull()]]])
        do {
            _ = try PerplexityClient.parseResponse(data)
            Issue.record("expected an error")
        } catch let IntentError.message(message) {
            #expect(message == "I couldn't find nutrition info for that.")
        }
    }

    @Test func emptyItemsSaysNothingWasFound() throws {
        let data = try body(["items": [] as [Any]])
        #expect(throws: IntentError.self) { try PerplexityClient.parseResponse(data) }
        do {
            _ = try PerplexityClient.parseResponse(data)
        } catch let IntentError.message(message) {
            #expect(message == "I couldn't find nutrition info for that.")
        }
    }

    @Test func malformedBodyIsAParseError() {
        #expect(throws: IntentError.self) { try PerplexityClient.parseResponse(Data("oops".utf8)) }
    }

    @Test func requestTellsTheServerThisBuildHandlesUnknownCarbs() throws {
        let data = PerplexityClient.requestData(for: "an apple", tzOffsetMinutes: -300)

        // Without this the server drops foods with no carb value and Siri
        // never says it skipped one.
        #expect(data["acceptsUnknownCarbs"] as? Bool == true)
        #expect(data["input"] as? String == "an apple")
        #expect(data["tzOffsetMinutes"] as? Int == -300)
    }
}

@Suite("RequestPacer")
struct RequestPacerTests {
    /// A monotonic instant the test moves by hand.
    ///
    /// A box rather than a captured `var`: the pacer's clock is a Sendable
    /// closure, and Swift 6 rightly refuses to let one capture mutable local
    /// state. Only this test's single task touches it, and every access is
    /// ordered by an `await`.
    final class Clock: @unchecked Sendable {
        var now = ContinuousClock.now
    }

    /// Two callers overlapping must not be given the same moment.
    ///
    /// The bug this guards: an actor releases isolation at `await`, so a pacer
    /// that sleeps before writing lets the second caller read the first's
    /// stale timestamp. Both then wait the same amount, wake together, and hit
    /// the server back to back — the floor the limiter exists for is not
    /// applied, and the second request comes back 429 with the food unlogged.
    @Test func concurrentCallersAreSpacedRatherThanCollapsed() async {
        let clock = Clock()
        let pacer = RequestPacer(minInterval: .milliseconds(1500), now: { clock.now })

        // Reserved without any sleeping, so the ordering is what is asserted,
        // not the timing.
        let first = await pacer.reserveSlot()
        let second = await pacer.reserveSlot()
        let third = await pacer.reserveSlot()

        #expect(first == .zero)
        #expect(second == .milliseconds(1500))
        #expect(third == .milliseconds(3000))
    }

    @Test func aCallerAfterTheGapHasAlreadyPassedWaitsNoTime() async {
        let clock = Clock()
        let pacer = RequestPacer(minInterval: .milliseconds(1500), now: { clock.now })

        _ = await pacer.reserveSlot()
        clock.now = clock.now.advanced(by: .seconds(10))

        #expect(await pacer.reserveSlot() == .zero)
    }
}
