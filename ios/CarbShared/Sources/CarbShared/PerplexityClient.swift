import Foundation

public struct PerplexityClient {
    private static var lastRequestTime: Date?
    private static let minInterval: TimeInterval = 1.5

    // Firebase Cloud Function endpoint
    private static let cloudFunctionURL = "https://us-central1-carpecarb.cloudfunctions.net/getMultipleCarbCounts"

    private static func enforceRateLimit() async {
        if let last = lastRequestTime {
            let elapsed = Date().timeIntervalSince(last)
            if elapsed < minInterval {
                try? await Task.sleep(nanoseconds: UInt64((minInterval - elapsed) * 1_000_000_000))
            }
        }
        lastRequestTime = Date()
    }

    public static func lookupCarbs(for foodItem: String) async throws -> (name: String, carbs: Double, details: String?, citations: [String]) {
        await enforceRateLimit()

        let url = URL(string: cloudFunctionURL)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        if let token = CarbDataStore.firebaseIdToken(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let body: [String: Any] = [
            "data": [
                "input": foodItem,
                // Lets the server count the free quota per local calendar day.
                "tzOffsetMinutes": TimeZone.current.secondsFromGMT() / 60,
            ] as [String: Any]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw IntentError.message("Invalid response from server.")
        }

        guard httpResponse.statusCode == 200 else {
            throw IntentError.message(errorMessage(status: httpResponse.statusCode, body: data))
        }

        // Firebase callable functions wrap the response in {"result": ...}
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let items = result["items"] as? [[String: Any]],
              let first = items.first else {
            throw IntentError.message("Could not parse server response.")
        }

        let name = first["name"] as? String ?? "Unknown"
        let carbs: Double
        if let carbNum = first["carbs"] as? NSNumber {
            carbs = carbNum.doubleValue
        } else if let carbStr = first["carbs"] as? String, let parsed = Double(carbStr) {
            carbs = parsed
        } else {
            carbs = 0
        }
        let details = first["details"] as? String

        let citations: [String]
        if let citationArray = result["citations"] as? [String] {
            citations = citationArray
        } else {
            citations = []
        }

        return (name: name, carbs: carbs, details: details, citations: citations)
    }

    /// Maps a non-200 response from the callable function to a message Siri
    /// can speak. Callable errors have the body
    /// `{"error": {"message", "status", "details"}}`.
    static func errorMessage(status: Int, body: Data) -> String {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let details = (json?["error"] as? [String: Any])?["details"] as? [String: Any]

        if status == 429, details?["reason"] as? String == "daily-quota" {
            let limit = (details?["limit"] as? NSNumber)?.intValue
            let count = limit.map { "\($0) " } ?? ""
            return "You've used today's \(count)free lookups. Open CarpeCarb to go unlimited."
        }
        if status == 429 {
            return "Rate limit exceeded. Try again shortly."
        }
        return "Server error (\(status))."
    }
}
