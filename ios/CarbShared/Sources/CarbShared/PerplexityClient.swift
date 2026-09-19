import Foundation

/// One food from a carb lookup.
public struct LookupItem: Equatable, Sendable {
    public let name: String
    public let carbs: Double
    public let protein: Double?
    public let fat: Double?
    public let fiber: Double?
    public let calories: Double?
    public let details: String?

    public init(name: String, carbs: Double, protein: Double? = nil, fat: Double? = nil,
                fiber: Double? = nil, calories: Double? = nil, details: String? = nil) {
        self.name = name
        self.carbs = carbs
        self.protein = protein
        self.fat = fat
        self.fiber = fiber
        self.calories = calories
        self.details = details
    }
}

/// Every food the server found for one lookup ("burger and fries" → 2 items).
public struct LookupResult: Equatable, Sendable {
    public let items: [LookupItem]
    public let citations: [String]

    public init(items: [LookupItem], citations: [String]) {
        self.items = items
        self.citations = citations
    }
}

extension LoggedFood {
    /// The buffered form of a looked-up item, keeping its macros.
    public init(item: LookupItem, citations: [String]) {
        self.init(name: item.name, carbs: item.carbs, protein: item.protein, fat: item.fat,
                  fiber: item.fiber, calories: item.calories, details: item.details,
                  citations: citations)
    }
}

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

    /// Looks up every food in `foodItem` via the Cloud Function.
    ///
    /// - Parameter idToken: a current Firebase ID token for the signed-in user.
    ///   CarbShared stays free of Firebase, so the caller supplies it.
    public static func lookupCarbs(for foodItem: String, idToken: String) async throws -> LookupResult {
        await enforceRateLimit()

        guard let url = URL(string: cloudFunctionURL) else {
            throw IntentError.message("Invalid server address.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60

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

        return try parseResponse(data)
    }

    /// Parses a 200 response. Firebase callable functions wrap it in
    /// `{"result": {"items": [...], "citations": [...]}}`.
    static func parseResponse(_ data: Data) throws -> LookupResult {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let rawItems = result["items"] as? [[String: Any]] else {
            throw IntentError.message("Could not parse server response.")
        }

        let items = rawItems.map { raw in
            LookupItem(
                name: raw["name"] as? String ?? "Unknown",
                carbs: number(raw["carbs"]) ?? 0,
                protein: number(raw["protein"]),
                fat: number(raw["fat"]),
                fiber: number(raw["fiber"]),
                calories: number(raw["calories"]),
                details: raw["details"] as? String
            )
        }
        guard !items.isEmpty else {
            throw IntentError.message("I couldn't find nutrition info for that.")
        }
        return LookupResult(items: items, citations: result["citations"] as? [String] ?? [])
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
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
