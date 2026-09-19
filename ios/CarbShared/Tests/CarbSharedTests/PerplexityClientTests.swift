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

    @Test func nonFiniteOrNegativeNumbersAreDropped() throws {
        let data = try body([
            "items": [
                ["name": "Mystery", "carbs": "nan", "protein": "inf", "fat": -3],
            ],
        ])
        let result = try PerplexityClient.parseResponse(data)
        #expect(result.items == [LookupItem(name: "Mystery", carbs: 0, protein: nil, fat: nil)])
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
