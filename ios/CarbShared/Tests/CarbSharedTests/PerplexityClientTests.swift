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
