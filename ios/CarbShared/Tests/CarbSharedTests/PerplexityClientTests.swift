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
}
